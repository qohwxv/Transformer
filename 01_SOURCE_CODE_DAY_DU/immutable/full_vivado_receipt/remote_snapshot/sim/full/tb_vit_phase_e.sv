`timescale 1ns/1ps

// File-backed integration testbench for test_20 through test_24.
//
// Typical ModelSim run (from repository root):
//   vsim work.tb_vit_phase_e +TEST_ID=21 +CASE_ID=1 \
//        +CHECKPOINT_INJECT=1 +MAJOR_ONLY=0
//
// CHECKPOINT_INJECT=1 reloads the package's golden destination after dumping
// each NPU result.  This isolates every engine/controller boundary.  Use zero
// for a true continuous chain after the isolated run passes.
module tb_vit_phase_e #(
    parameter integer SCRATCH_WORDS = 32'h001e_6000,
    parameter integer INPUT_WORDS   = 150_528,
    parameter integer PARAM_WORDS   = 32'h0024_1000
);

    import vit_phase_e_pkg::*;
    import vit_fp32_math_ref_pkg::*;

    localparam integer PARAM_MAIN_BASE = 32'h0000_0000;
    localparam integer PARAM_AUX_BASE  = 32'h0024_0000;
`ifdef VIT_PURE_SV_BEHAVIORAL
    // Icarus requires a static unpacked memory as the destination of
    // $readmemh. One reusable window is enough for the largest FC weight.
    localparam integer PURE_SV_LOAD_WORDS = 2_359_296;
    logic [31:0] pure_sv_readmem_buffer [0:PURE_SV_LOAD_WORDS-1];
`endif

    logic clk;
    logic rst;
    logic job_valid;
    logic job_ready;
    phase_e_job_t job;
    phase_e_global_params_t global_params;
    logic layer_param_request;
    logic [3:0] layer_param_index;
    logic layer_param_valid;
    phase_e_layer_params_t layer_param_data;
    logic operand_load_request;
    logic operand_load_ready;
    phase_e_cmd_t operand_load_command;
    logic checkpoint_valid;
    logic checkpoint_ready;
    phase_e_phase_t checkpoint_phase;
    phase_e_section_t checkpoint_section;
    logic [3:0] checkpoint_layer;
    logic [4:0] checkpoint_step;
    logic [7:0] checkpoint_tag;
    phase_e_opcode_t checkpoint_opcode;
    phase_e_tensor_id_t checkpoint_dst_tensor;
    logic busy;
    logic done;
    logic error;
    phase_e_error_t error_code;
    phase_e_section_t error_section;
    logic [3:0] error_layer;
    logic [4:0] error_step;
    logic class_result_valid;
    logic [31:0] class_index;
    logic [31:0] class_logit;

    logic input_write_enable;
    logic [31:0] input_write_address;
    logic [31:0] input_write_data;
    logic parameter_write_enable;
    logic [31:0] parameter_write_address;
    logic [31:0] parameter_write_data;
    logic scratch_write_enable;
    logic [31:0] scratch_write_address;
    logic [31:0] scratch_write_data;
    logic [31:0] scratch_read_address;
    logic [31:0] scratch_read_data;

    integer test_id;
    integer case_id;
    integer first_layer_value;
    integer last_layer_value;
    integer checkpoint_inject;
    integer major_only;
    integer class_softmax_enable;
    integer plusarg_status;
    integer check_file_handle;
    integer output_file_handle;
    integer dump_index;
    integer parameter_load_count;
    integer checkpoint_count;
    integer command_count;
    integer layer_request_count;
    integer class_result_count;
    integer expected_commands;
    integer expected_class_valid;
    integer expected_class_value;
    integer expected_confidence_valid;
    logic [31:0] expected_confidence_word;
    longint cycle_count;
    longint timeout_cycles;
    logic operand_request_seen;
    logic checkpoint_seen;
    logic simulation_complete;
    string case_dir;
    string checkpoint_dir;
    string filename;

    vit_phase_e_npu #(
        .SCRATCH_WORDS(SCRATCH_WORDS),
        .INPUT_WORDS(INPUT_WORDS),
        .PARAM_WORDS(PARAM_WORDS)
    ) dut (
        .clk(clk),
        .rst(rst),
        .job_valid(job_valid),
        .job_ready(job_ready),
        .job(job),
        .global_params(global_params),
        .layer_param_request(layer_param_request),
        .layer_param_index(layer_param_index),
        .layer_param_valid(layer_param_valid),
        .layer_param_data(layer_param_data),
        .operand_load_request(operand_load_request),
        .operand_load_ready(operand_load_ready),
        .operand_load_command(operand_load_command),
        .checkpoint_valid(checkpoint_valid),
        .checkpoint_ready(checkpoint_ready),
        .checkpoint_phase(checkpoint_phase),
        .checkpoint_section(checkpoint_section),
        .checkpoint_layer(checkpoint_layer),
        .checkpoint_step(checkpoint_step),
        .checkpoint_tag(checkpoint_tag),
        .checkpoint_opcode(checkpoint_opcode),
        .checkpoint_dst_tensor(checkpoint_dst_tensor),
        .busy(busy),
        .done(done),
        .error(error),
        .error_code(error_code),
        .error_section(error_section),
        .error_layer(error_layer),
        .error_step(error_step),
        .input_write_enable(input_write_enable),
        .input_write_address(input_write_address),
        .input_write_data(input_write_data),
        .parameter_write_enable(parameter_write_enable),
        .parameter_write_address(parameter_write_address),
        .parameter_write_data(parameter_write_data),
        .scratch_write_enable(scratch_write_enable),
        .scratch_write_address(scratch_write_address),
        .scratch_write_data(scratch_write_data),
        .scratch_read_address(scratch_read_address),
        .scratch_read_data(scratch_read_data),
        .class_result_valid(class_result_valid),
        .class_index(class_index),
        .class_logit(class_logit)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic require_readable(input string path);
        begin
            check_file_handle = $fopen(path, "r");
            if (check_file_handle == 0)
                $fatal(1, "Cannot open required file %s", path);
            $fclose(check_file_handle);
        end
    endtask

`ifdef VIT_PURE_SV_BEHAVIORAL
    task automatic prepare_pure_sv_readmem(input integer word_count);
        integer prepare_index;
        begin
            if ((word_count < 0) || (word_count > PURE_SV_LOAD_WORDS))
                $fatal(
                    1,
                    "Pure-SV readmem request %0d exceeds staging capacity %0d",
                    word_count,
                    PURE_SV_LOAD_WORDS
                );
            // Poison the requested range so a short HEX file cannot silently
            // reuse words left behind by the preceding parameter tensor.
            for (prepare_index = 0; prepare_index < word_count;
                 prepare_index = prepare_index + 1)
                pure_sv_readmem_buffer[prepare_index] = 32'hxxxx_xxxx;
        end
    endtask

    task automatic validate_pure_sv_readmem(
        input string path,
        input integer word_count
    );
        integer validate_index;
        begin
            for (validate_index = 0; validate_index < word_count;
                 validate_index = validate_index + 1) begin
                if ((^pure_sv_readmem_buffer[validate_index]) === 1'bx)
                    $fatal(
                        1,
                        "Missing/invalid FP32 word %0d after $readmemh(%s)",
                        validate_index,
                        path
                    );
            end
        end
    endtask
`endif

    task automatic load_input_region(
        input string path,
        input integer start_address,
        input integer word_count
    );
        integer loader_file;
        integer loader_status;
        integer loader_index;
        reg [31:0] loader_word;
        begin
            require_readable(path);
            $display("Loading input: %s", path);
`ifdef VIT_PURE_SV_BEHAVIORAL
            prepare_pure_sv_readmem(word_count);
            $readmemh(path, pure_sv_readmem_buffer, 0, word_count - 1);
            validate_pure_sv_readmem(path, word_count);
            wait (dut.u_engine.shadow_ready === 1'b1);
            for (loader_index = 0; loader_index < word_count; loader_index = loader_index + 1)
                dut.u_engine.input_memory[start_address + loader_index] =
                    pure_sv_readmem_buffer[loader_index];
`elsif VIT_DYNAMIC_SIM_MEMORY
            #0;
            loader_file = $fopen(path, "r");
            for (loader_index = 0; loader_index < word_count; loader_index = loader_index + 1) begin
                loader_status = $fscanf(loader_file, "%h", loader_word);
                if (loader_status != 1)
                    $fatal(1, "Cannot read input word %0d from %s", loader_index, path);
                dut.u_engine.input_memory[start_address + loader_index] = loader_word;
            end
            $fclose(loader_file);
`else
            $readmemh(
                path,
                dut.u_engine.input_memory,
                start_address,
                start_address + word_count - 1
            );
`endif
`ifdef VIT_PURE_SV_BEHAVIORAL
            dut.u_engine.sync_input_region(start_address, word_count);
`endif
        end
    endtask

    task automatic load_scratch_region(
        input string path,
        input integer start_address,
        input integer word_count
    );
        integer loader_file;
        integer loader_status;
        integer loader_index;
        reg [31:0] loader_word;
        begin
            require_readable(path);
            $display("Loading scratch input: %s -> word 0x%08x", path, start_address);
`ifdef VIT_PURE_SV_BEHAVIORAL
            prepare_pure_sv_readmem(word_count);
            $readmemh(path, pure_sv_readmem_buffer, 0, word_count - 1);
            validate_pure_sv_readmem(path, word_count);
            wait (dut.u_engine.shadow_ready === 1'b1);
            for (loader_index = 0; loader_index < word_count; loader_index = loader_index + 1)
                dut.u_engine.scratch_memory[start_address + loader_index] =
                    pure_sv_readmem_buffer[loader_index];
`elsif VIT_DYNAMIC_SIM_MEMORY
            #0;
            loader_file = $fopen(path, "r");
            for (loader_index = 0; loader_index < word_count; loader_index = loader_index + 1) begin
                loader_status = $fscanf(loader_file, "%h", loader_word);
                if (loader_status != 1)
                    $fatal(1, "Cannot read scratch word %0d from %s", loader_index, path);
                dut.u_engine.scratch_memory[start_address + loader_index] = loader_word;
            end
            $fclose(loader_file);
`else
            $readmemh(
                path,
                dut.u_engine.scratch_memory,
                start_address,
                start_address + word_count - 1
            );
`endif
`ifdef VIT_PURE_SV_BEHAVIORAL
            dut.u_engine.sync_scratch_region(start_address, word_count);
`endif
        end
    endtask

    task automatic load_parameter_region(
        input string path,
        input integer start_address,
        input integer word_count
    );
        integer loader_file;
        integer loader_status;
        integer loader_index;
        reg [31:0] loader_word;
        begin
            require_readable(path);
            $display("Loading parameter: %s -> word 0x%08x", path, start_address);
`ifdef VIT_PURE_SV_BEHAVIORAL
            prepare_pure_sv_readmem(word_count);
            $readmemh(path, pure_sv_readmem_buffer, 0, word_count - 1);
            validate_pure_sv_readmem(path, word_count);
            wait (dut.u_engine.shadow_ready === 1'b1);
            for (loader_index = 0; loader_index < word_count; loader_index = loader_index + 1)
                dut.u_engine.parameter_memory[start_address + loader_index] =
                    pure_sv_readmem_buffer[loader_index];
`elsif VIT_DYNAMIC_SIM_MEMORY
            #0;
            loader_file = $fopen(path, "r");
            for (loader_index = 0; loader_index < word_count; loader_index = loader_index + 1) begin
                loader_status = $fscanf(loader_file, "%h", loader_word);
                if (loader_status != 1)
                    $fatal(1, "Cannot read parameter word %0d from %s", loader_index, path);
                dut.u_engine.parameter_memory[start_address + loader_index] = loader_word;
            end
            $fclose(loader_file);
`else
            $readmemh(
                path,
                dut.u_engine.parameter_memory,
                start_address,
                start_address + word_count - 1
            );
`endif
`ifdef VIT_PURE_SV_BEHAVIORAL
            dut.u_engine.sync_parameter_region(start_address, word_count);
`endif
        end
    endtask

    task automatic dump_scratch_region(
        input string path,
        input integer start_address,
        input integer word_count
    );
        begin
            output_file_handle = $fopen(path, "w");
            if (output_file_handle == 0)
                $fatal(1, "Cannot create checkpoint %s", path);
            for (dump_index = 0; dump_index < word_count; dump_index = dump_index + 1)
                $fdisplay(
                    output_file_handle,
                    "%08X",
                    dut.u_engine.scratch_memory[start_address + dump_index]
                );
            $fclose(output_file_handle);
            $display("Wrote checkpoint: %s (%0d words)", path, word_count);
        end
    endtask

    task automatic dump_scalar_word(input string path, input logic [31:0] value);
        begin
            output_file_handle = $fopen(path, "w");
            if (output_file_handle == 0)
                $fatal(1, "Cannot create scalar checkpoint %s", path);
            $fdisplay(output_file_handle, "%08X", value);
            $fclose(output_file_handle);
            $display("Wrote scalar checkpoint: %s = %08x", path, value);
        end
    endtask

    task automatic maybe_inject_scratch(
        input string path,
        input integer start_address,
        input integer word_count
    );
        integer loader_file;
        integer loader_status;
        integer loader_index;
        reg [31:0] loader_word;
        begin
            if (checkpoint_inject != 0) begin
                require_readable(path);
`ifdef VIT_PURE_SV_BEHAVIORAL
                prepare_pure_sv_readmem(word_count);
                $readmemh(path, pure_sv_readmem_buffer, 0, word_count - 1);
                validate_pure_sv_readmem(path, word_count);
                wait (dut.u_engine.shadow_ready === 1'b1);
                for (loader_index = 0; loader_index < word_count; loader_index = loader_index + 1)
                    dut.u_engine.scratch_memory[start_address + loader_index] =
                        pure_sv_readmem_buffer[loader_index];
`elsif VIT_DYNAMIC_SIM_MEMORY
                loader_file = $fopen(path, "r");
                for (loader_index = 0; loader_index < word_count; loader_index = loader_index + 1) begin
                    loader_status = $fscanf(loader_file, "%h", loader_word);
                    if (loader_status != 1)
                        $fatal(1, "Cannot inject scratch word %0d from %s", loader_index, path);
                    dut.u_engine.scratch_memory[start_address + loader_index] = loader_word;
                end
                $fclose(loader_file);
`else
                $readmemh(
                    path,
                    dut.u_engine.scratch_memory,
                    start_address,
                    start_address + word_count - 1
                );
`endif
`ifdef VIT_PURE_SV_BEHAVIORAL
                dut.u_engine.sync_scratch_region(start_address, word_count);
`endif
                $display("Injected golden destination: %s", path);
            end
        end
    endtask

    task automatic load_encoder_parameter_pair(
        input logic [3:0] layer_index_value,
        input string stem,
        input integer main_words,
        input integer aux_words
    );
        string main_path;
        string aux_path;
        string layer_name;
        begin
            // ModelSim 2020.1 space-pads %02d, so construct 00..11 explicitly.
            if (layer_index_value < 10)
                layer_name = $sformatf("0%0d", layer_index_value);
            else
                layer_name = $sformatf("%0d", layer_index_value);
            main_path = $sformatf(
                "%s/parameters/encoder_layer_%s_%s_f32.hex",
                case_dir,
                layer_name,
                stem
            );
            if ((stem == "ln_before_gamma") || (stem == "ln_after_gamma")) begin
                // LayerNorm filenames use gamma/beta rather than weight/bias.
                load_parameter_region(main_path, PARAM_MAIN_BASE, main_words);
                if (stem == "ln_before_gamma")
                    aux_path = $sformatf(
                        "%s/parameters/encoder_layer_%s_ln_before_beta_f32.hex",
                        case_dir,
                        layer_name
                    );
                else
                    aux_path = $sformatf(
                        "%s/parameters/encoder_layer_%s_ln_after_beta_f32.hex",
                        case_dir,
                        layer_name
                    );
            end else begin
                load_parameter_region(main_path, PARAM_MAIN_BASE, main_words);
                if (stem == "q_weight_B")
                    aux_path = $sformatf("%s/parameters/encoder_layer_%s_q_bias_f32.hex", case_dir, layer_name);
                else if (stem == "k_weight_B")
                    aux_path = $sformatf("%s/parameters/encoder_layer_%s_k_bias_f32.hex", case_dir, layer_name);
                else if (stem == "v_weight_B")
                    aux_path = $sformatf("%s/parameters/encoder_layer_%s_v_bias_f32.hex", case_dir, layer_name);
                else if (stem == "o_weight_B")
                    aux_path = $sformatf("%s/parameters/encoder_layer_%s_o_bias_f32.hex", case_dir, layer_name);
                else if (stem == "fc1_weight_B")
                    aux_path = $sformatf("%s/parameters/encoder_layer_%s_fc1_bias_f32.hex", case_dir, layer_name);
                else
                    aux_path = $sformatf("%s/parameters/encoder_layer_%s_fc2_bias_f32.hex", case_dir, layer_name);
            end
            load_parameter_region(aux_path, PARAM_AUX_BASE, aux_words);
        end
    endtask

    task automatic service_operand_load(input phase_e_cmd_t load_cmd);
        phase_e_section_t section_value;
        logic [3:0] layer_value;
        logic [4:0] step_value;
        begin
            section_value = phase_e_section_t'(load_cmd.header.reserved[7:6]);
            layer_value = load_cmd.header.reserved[5:2];
            step_value = load_cmd.route.reserved[4:0];
            $display(
                "Operand request: section=%0d layer=%0d step=%0d opcode=%0d",
                section_value,
                layer_value,
                step_value,
                load_cmd.header.opcode
            );

            case (section_value)
                PHASE_E_SECTION_EMBEDDING: begin
                    case (step_value)
                        0: begin
                            filename = {case_dir, "/parameters/embedding_patch_weight_B_f32.hex"};
                            load_parameter_region(filename, PARAM_MAIN_BASE, 589_824);
                            filename = {case_dir, "/parameters/embedding_patch_bias_f32.hex"};
                            load_parameter_region(filename, PARAM_AUX_BASE, 768);
                        end
                        1: begin
                            filename = {case_dir, "/parameters/embedding_cls_token_f32.hex"};
                            load_parameter_region(filename, PARAM_MAIN_BASE, 768);
                        end
                        3: begin
                            filename = {case_dir, "/parameters/embedding_position_f32.hex"};
                            load_parameter_region(filename, PARAM_MAIN_BASE, 151_296);
                        end
                        default: $fatal(1, "Unexpected embedding parameter request at step %0d", step_value);
                    endcase
                end

                PHASE_E_SECTION_ENCODER: begin
                    case (step_value)
                        0:  load_encoder_parameter_pair(layer_value, "ln_before_gamma", 768, 768);
                        1:  load_encoder_parameter_pair(layer_value, "q_weight_B", 589_824, 768);
                        3:  load_encoder_parameter_pair(layer_value, "k_weight_B", 589_824, 768);
                        5:  load_encoder_parameter_pair(layer_value, "v_weight_B", 589_824, 768);
                        13: load_encoder_parameter_pair(layer_value, "o_weight_B", 589_824, 768);
                        15: load_encoder_parameter_pair(layer_value, "ln_after_gamma", 768, 768);
                        16: load_encoder_parameter_pair(layer_value, "fc1_weight_B", 2_359_296, 3_072);
                        18: load_encoder_parameter_pair(layer_value, "fc2_weight_B", 2_359_296, 768);
                        default: $fatal(1, "Unexpected encoder parameter request at layer %0d step %0d", layer_value, step_value);
                    endcase
                end

                PHASE_E_SECTION_FINAL: begin
                    case (step_value)
                        0: begin
                            filename = {case_dir, "/parameters/post_encoder_final_ln_gamma_f32.hex"};
                            load_parameter_region(filename, PARAM_MAIN_BASE, 768);
                            filename = {case_dir, "/parameters/post_encoder_final_ln_beta_f32.hex"};
                            load_parameter_region(filename, PARAM_AUX_BASE, 768);
                        end
                        2: begin
                            filename = {case_dir, "/parameters/post_encoder_classifier_weight_B_f32.hex"};
                            load_parameter_region(filename, PARAM_MAIN_BASE, 768_000);
                            filename = {case_dir, "/parameters/post_encoder_classifier_bias_f32.hex"};
                            load_parameter_region(filename, PARAM_AUX_BASE, 1_000);
                        end
                        default: $fatal(1, "Unexpected final parameter request at step %0d", step_value);
                    endcase
                end

                default: $fatal(1, "Unexpected parameter-request section %0d", section_value);
            endcase
            parameter_load_count = parameter_load_count + 1;
        end
    endtask

    task automatic process_embedding_checkpoint(input logic [4:0] step_value);
        begin
            case (step_value)
                0: begin
                    if (major_only == 0) begin
                        dump_scratch_region(
                            {checkpoint_dir, "/embedding_step_02_patch_projection_f32.hex"},
                            PHASE_E_ADDR_LINEAR_TMP,
                            VIT_PATCH_WORDS
                        );
                        dump_scratch_region(
                            {checkpoint_dir, "/embedding_step_03_patch_embeddings_f32.hex"},
                            PHASE_E_ADDR_LINEAR_TMP,
                            VIT_PATCH_WORDS
                        );
                    end
                    maybe_inject_scratch(
                        {case_dir, "/checkpoints/embedding_step_02_patch_projection_f32.hex"},
                        PHASE_E_ADDR_LINEAR_TMP,
                        VIT_PATCH_WORDS
                    );
                end
                1: begin
                    if (major_only == 0)
                        dump_scratch_region(
                            {checkpoint_dir, "/embedding_step_04a_cls_slice_f32.hex"},
                            PHASE_E_ADDR_HIDDEN_A,
                            VIT_HIDDEN_SIZE
                        );
                    maybe_inject_scratch(
                        {case_dir, "/checkpoints/embedding_step_04a_cls_slice_f32.hex"},
                        PHASE_E_ADDR_HIDDEN_A,
                        VIT_HIDDEN_SIZE
                    );
                end
                2: begin
                    if (major_only == 0)
                        dump_scratch_region(
                            {checkpoint_dir, "/embedding_step_04_embeddings_with_cls_f32.hex"},
                            PHASE_E_ADDR_HIDDEN_A,
                            VIT_HIDDEN_WORDS
                        );
                    maybe_inject_scratch(
                        {case_dir, "/checkpoints/embedding_step_04_embeddings_with_cls_f32.hex"},
                        PHASE_E_ADDR_HIDDEN_A,
                        VIT_HIDDEN_WORDS
                    );
                end
                3: begin
                    if (major_only == 0)
                        dump_scratch_region(
                            {checkpoint_dir, "/embedding_step_05_embeddings_plus_position_f32.hex"},
                            PHASE_E_ADDR_HIDDEN_A,
                            VIT_HIDDEN_WORDS
                        );
                    dump_scratch_region(
                        {checkpoint_dir, "/embedding_step_06_hidden_states_f32.hex"},
                        PHASE_E_ADDR_HIDDEN_A,
                        VIT_HIDDEN_WORDS
                    );
                    maybe_inject_scratch(
                        {case_dir, "/checkpoints/embedding_step_06_hidden_states_f32_injection.hex"},
                        PHASE_E_ADDR_HIDDEN_A,
                        VIT_HIDDEN_WORDS
                    );
                end
                default: $fatal(1, "Unexpected embedding checkpoint step %0d", step_value);
            endcase
        end
    endtask

    task automatic encoder_checkpoint_metadata(
        input logic [4:0] step_value,
        output string basename,
        output integer base_address,
        output integer word_count
    );
        begin
            basename = "";
            base_address = 0;
            word_count = VIT_HIDDEN_WORDS;
            case (step_value)
                0:  begin basename = "02_layernorm_before"; base_address = PHASE_E_ADDR_HIDDEN_B; end
                1:  begin basename = "03_q_projection"; base_address = PHASE_E_ADDR_LINEAR_TMP; end
                2:  begin basename = "06_q_heads"; base_address = PHASE_E_ADDR_Q_HEAD; end
                3:  begin basename = "04_k_projection"; base_address = PHASE_E_ADDR_LINEAR_TMP; end
                4:  begin basename = "07_k_heads"; base_address = PHASE_E_ADDR_K_HEAD; end
                5:  begin basename = "05_v_projection"; base_address = PHASE_E_ADDR_LINEAR_TMP; end
                6:  begin basename = "08_v_heads"; base_address = PHASE_E_ADDR_V_HEAD; end
                7:  begin basename = "08a_k_heads_transposed"; base_address = PHASE_E_ADDR_LINEAR_TMP; end
                8:  begin basename = "09_raw_attention_scores"; base_address = PHASE_E_ADDR_SCORE_PROB; word_count = VIT_SCORE_WORDS; end
                9:  begin basename = "10_scaled_scores_after_full_mask"; base_address = PHASE_E_ADDR_SCORE_PROB; word_count = VIT_SCORE_WORDS; end
                10: begin basename = "11_attention_probabilities"; base_address = PHASE_E_ADDR_SCORE_PROB; word_count = VIT_SCORE_WORDS; end
                11: begin basename = "12_attention_head_outputs"; base_address = PHASE_E_ADDR_Q_HEAD; end
                12: begin basename = "13_attention_heads_merged"; base_address = PHASE_E_ADDR_LINEAR_TMP; end
                13: begin basename = "14_attention_output_projection"; base_address = PHASE_E_ADDR_HIDDEN_B; end
                14: begin basename = "15_attention_residual_2"; base_address = PHASE_E_ADDR_HIDDEN_B; end
                15: begin basename = "16_layernorm_after"; base_address = PHASE_E_ADDR_HIDDEN_A; end
                16: begin basename = "17_fc1_output"; base_address = PHASE_E_ADDR_FC1; word_count = VIT_FC1_WORDS; end
                17: begin basename = "18_gelu_output"; base_address = PHASE_E_ADDR_FC1; word_count = VIT_FC1_WORDS; end
                18: begin basename = "19_fc2_output"; base_address = PHASE_E_ADDR_LINEAR_TMP; end
                19: begin basename = "20_layer_output"; base_address = PHASE_E_ADDR_HIDDEN_A; end
                default: $fatal(1, "Unexpected encoder checkpoint step %0d", step_value);
            endcase
        end
    endtask

    task automatic process_encoder_checkpoint(
        input logic [3:0] layer_value,
        input logic [4:0] step_value
    );
        string basename;
        string actual_path;
        string injection_path;
        string layer_name;
        integer base_address;
        integer word_count;
        begin
            if (layer_value < 10)
                layer_name = $sformatf("0%0d", layer_value);
            else
                layer_name = $sformatf("%0d", layer_value);
            encoder_checkpoint_metadata(step_value, basename, base_address, word_count);
            actual_path = $sformatf(
                "%s/encoder_layer_%s_step_%s_f32.hex",
                checkpoint_dir,
                layer_name,
                basename
            );
            injection_path = $sformatf(
                "%s/checkpoints/encoder_layer_%s_step_%s_f32.hex",
                case_dir,
                layer_name,
                basename
            );
            if ((major_only == 0) || (step_value == 19))
                dump_scratch_region(actual_path, base_address, word_count);
            if ((test_id == 22) && (first_layer_value == 1) &&
                (last_layer_value == 11) && (layer_value == 11) &&
                (step_value == 19)) begin
                dump_scratch_region(
                    {checkpoint_dir, "/encoder_chain_step_29_encoder_layers_output_f32.hex"},
                    PHASE_E_ADDR_HIDDEN_A,
                    VIT_HIDDEN_WORDS
                );
            end
            maybe_inject_scratch(injection_path, base_address, word_count);
        end
    endtask

    task automatic process_final_checkpoint(input logic [4:0] step_value);
        logic [31:0] confidence_word;
        real confidence_real;
        real expected_confidence_real;
        real confidence_error;
        integer prediction_file_handle;
        begin
            case (step_value)
                0: begin
                    dump_scratch_region(
                        {checkpoint_dir, "/post_encoder_step_30_final_layernorm_f32.hex"},
                        PHASE_E_ADDR_HIDDEN_B,
                        VIT_HIDDEN_WORDS
                    );
                    maybe_inject_scratch(
                        {case_dir, "/checkpoints/post_encoder_step_30_final_layernorm_f32.hex"},
                        PHASE_E_ADDR_HIDDEN_B,
                        VIT_HIDDEN_WORDS
                    );
                end
                1: begin
                    if (major_only == 0)
                        dump_scratch_region(
                            {checkpoint_dir, "/post_encoder_step_31_cls_token_f32.hex"},
                            PHASE_E_ADDR_LINEAR_TMP,
                            VIT_HIDDEN_SIZE
                        );
                    maybe_inject_scratch(
                        {case_dir, "/checkpoints/post_encoder_step_31_cls_token_f32.hex"},
                        PHASE_E_ADDR_LINEAR_TMP,
                        VIT_HIDDEN_SIZE
                    );
                end
                2: begin
                    dump_scratch_region(
                        {checkpoint_dir, "/post_encoder_step_32_logits_f32.hex"},
                        PHASE_E_ADDR_LOGITS,
                        VIT_CLASS_COUNT
                    );
                    maybe_inject_scratch(
                        {case_dir, "/checkpoints/post_encoder_step_32_logits_f32.hex"},
                        PHASE_E_ADDR_LOGITS,
                        VIT_CLASS_COUNT
                    );
                end
                3: begin
                    dump_scalar_word(
                        {checkpoint_dir, "/post_encoder_step_33i_class_index_u32.hex"},
                        class_index
                    );
                    dump_scalar_word(
                        {checkpoint_dir, "/post_encoder_step_33v_max_logit_f32.hex"},
                        class_logit
                    );
                end
                4: begin
                    dump_scratch_region(
                        {checkpoint_dir, "/post_encoder_step_33p_probabilities_f32.hex"},
                        PHASE_E_ADDR_CLASS_PROB,
                        VIT_CLASS_COUNT
                    );
                    if (class_index < VIT_CLASS_COUNT)
                        confidence_word = dut.u_engine.scratch_memory[
                            PHASE_E_ADDR_CLASS_PROB + class_index
                        ];
                    else
                        confidence_word = 32'h7fc0_0000;
                    dump_scalar_word(
                        {checkpoint_dir, "/post_encoder_step_33c_confidence_f32.hex"},
                        confidence_word
                    );
                    confidence_real = fp32_ref_to_real(confidence_word);
                    if ((expected_class_valid != 0) &&
                        (class_index !== expected_class_value))
                        $fatal(
                            1,
                            "Prediction mismatch: expected class %0d, got %0d",
                            expected_class_value,
                            class_index
                        );
                    if (expected_confidence_valid != 0) begin
                        if (fp32_ref_is_nan(confidence_word) ||
                            fp32_ref_is_inf(confidence_word))
                            $fatal(
                                1,
                                "Prediction confidence is not finite: %08x",
                                confidence_word
                            );
                        expected_confidence_real = fp32_ref_to_real(
                            expected_confidence_word
                        );
                        confidence_error = confidence_real - expected_confidence_real;
                        if (confidence_error < 0.0)
                            confidence_error = -confidence_error;
                        if (confidence_error > 1.0e-5)
                            $fatal(
                                1,
                                "Confidence mismatch: expected %.9f, got %.9f (abs %.9g)",
                                expected_confidence_real,
                                confidence_real,
                                confidence_error
                            );
                        $display(
                            "PASS bundled prediction check: class=%0d confidence_abs_error=%.9g",
                            class_index,
                            confidence_error
                        );
                    end
                    $display(
                        "PREDICTION class_index=%0d confidence=%.9f percent=%.6f%%",
                        class_index,
                        confidence_real,
                        confidence_real * 100.0
                    );
                    prediction_file_handle = $fopen(
                        {checkpoint_dir, "/prediction.txt"},
                        "w"
                    );
                    if (prediction_file_handle == 0)
                        $fatal(1, "Cannot create prediction.txt");
                    $fdisplay(prediction_file_handle, "class_index=%0d", class_index);
                    $fdisplay(
                        prediction_file_handle,
                        "max_logit=%.9f",
                        fp32_ref_to_real(class_logit)
                    );
                    $fdisplay(
                        prediction_file_handle,
                        "confidence=%.9f",
                        confidence_real
                    );
                    $fdisplay(
                        prediction_file_handle,
                        "confidence_percent=%.6f%%",
                        confidence_real * 100.0
                    );
                    $fclose(prediction_file_handle);
                    maybe_inject_scratch(
                        {case_dir, "/checkpoints/post_encoder_step_33p_probabilities_f32.hex"},
                        PHASE_E_ADDR_CLASS_PROB,
                        VIT_CLASS_COUNT
                    );
                end
                default: $fatal(1, "Unexpected final checkpoint step %0d", step_value);
            endcase
        end
    endtask

    task automatic process_checkpoint;
        begin
            $display(
                "Checkpoint: section=%0d layer=%0d step=%0d opcode=%0d tag=%0d",
                checkpoint_section,
                checkpoint_layer,
                checkpoint_step,
                checkpoint_opcode,
                checkpoint_tag
            );
            case (checkpoint_section)
                PHASE_E_SECTION_EMBEDDING:
                    process_embedding_checkpoint(checkpoint_step);
                PHASE_E_SECTION_ENCODER:
                    process_encoder_checkpoint(checkpoint_layer, checkpoint_step);
                PHASE_E_SECTION_FINAL:
                    process_final_checkpoint(checkpoint_step);
                default: $fatal(1, "Unexpected checkpoint section %0d", checkpoint_section);
            endcase
            checkpoint_count = checkpoint_count + 1;
        end
    endtask

    // The functional parameter table reuses one MAIN and one AUX staging
    // window.  operand_load_request ensures contents are replaced only after
    // the prior command has stopped reading them.
    always_comb begin
        layer_param_valid = layer_param_request;
        layer_param_data = '0;
        layer_param_data.ln1_gamma_base = PHASE_E_PARAM_MAIN_BASE;
        layer_param_data.ln1_beta_base = PHASE_E_PARAM_AUX_BASE;
        layer_param_data.q_weight_base = PHASE_E_PARAM_MAIN_BASE;
        layer_param_data.q_bias_base = PHASE_E_PARAM_AUX_BASE;
        layer_param_data.k_weight_base = PHASE_E_PARAM_MAIN_BASE;
        layer_param_data.k_bias_base = PHASE_E_PARAM_AUX_BASE;
        layer_param_data.v_weight_base = PHASE_E_PARAM_MAIN_BASE;
        layer_param_data.v_bias_base = PHASE_E_PARAM_AUX_BASE;
        layer_param_data.o_weight_base = PHASE_E_PARAM_MAIN_BASE;
        layer_param_data.o_bias_base = PHASE_E_PARAM_AUX_BASE;
        layer_param_data.ln2_gamma_base = PHASE_E_PARAM_MAIN_BASE;
        layer_param_data.ln2_beta_base = PHASE_E_PARAM_AUX_BASE;
        layer_param_data.fc1_weight_base = PHASE_E_PARAM_MAIN_BASE;
        layer_param_data.fc1_bias_base = PHASE_E_PARAM_AUX_BASE;
        layer_param_data.fc2_weight_base = PHASE_E_PARAM_MAIN_BASE;
        layer_param_data.fc2_bias_base = PHASE_E_PARAM_AUX_BASE;
    end

    always @(posedge clk) begin
        if (rst) begin
            operand_load_ready <= 1'b0;
            operand_request_seen <= 1'b0;
            checkpoint_ready <= 1'b0;
            checkpoint_seen <= 1'b0;
        end else begin
            operand_load_ready <= 1'b0;
            checkpoint_ready <= 1'b0;

            if (operand_load_request && !operand_request_seen) begin
                service_operand_load(operand_load_command);
                operand_load_ready <= 1'b1;
                operand_request_seen <= 1'b1;
            end else if (!operand_load_request) begin
                operand_request_seen <= 1'b0;
            end

            if (checkpoint_valid && !checkpoint_seen) begin
                process_checkpoint();
                checkpoint_ready <= 1'b1;
                checkpoint_seen <= 1'b1;
            end else if (!checkpoint_valid) begin
                checkpoint_seen <= 1'b0;
            end
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            cycle_count <= 0;
            command_count <= 0;
            layer_request_count <= 0;
            class_result_count <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (dut.command_valid && dut.command_ready)
                command_count <= command_count + 1;
            if (layer_param_request && layer_param_valid)
                layer_request_count <= layer_request_count + 1;
            if (class_result_valid)
                class_result_count <= class_result_count + 1;
        end
    end

    always @(negedge clk) begin
        if (!rst && !simulation_complete && (cycle_count >= timeout_cycles))
            $fatal(
                1,
                "Phase-E timeout after %0d cycles: commands=%0d checkpoints=%0d",
                cycle_count,
                command_count,
                checkpoint_count
            );
    end

    initial begin
        rst = 1'b1;
        job_valid = 1'b0;
        job = '0;
        global_params = '0;
        operand_load_ready = 1'b0;
        checkpoint_ready = 1'b0;
        input_write_enable = 1'b0;
        input_write_address = 32'd0;
        input_write_data = 32'd0;
        parameter_write_enable = 1'b0;
        parameter_write_address = 32'd0;
        parameter_write_data = 32'd0;
        scratch_write_enable = 1'b0;
        scratch_write_address = 32'd0;
        scratch_write_data = 32'd0;
        scratch_read_address = 32'd0;
        operand_request_seen = 1'b0;
        checkpoint_seen = 1'b0;
        simulation_complete = 1'b0;
        parameter_load_count = 0;
        checkpoint_count = 0;

        test_id = 20;
        case_id = 1;
        checkpoint_inject = 1;
        major_only = -1;
        expected_class_valid = 0;
        expected_class_value = 0;
        expected_confidence_valid = 0;
        expected_confidence_word = 32'd0;
        plusarg_status = $value$plusargs("TEST_ID=%d", test_id);
        plusarg_status = $value$plusargs("CASE_ID=%d", case_id);
        plusarg_status = $value$plusargs("CHECKPOINT_INJECT=%d", checkpoint_inject);
        plusarg_status = $value$plusargs("MAJOR_ONLY=%d", major_only);
        expected_class_valid = $value$plusargs(
            "EXPECTED_CLASS=%d",
            expected_class_value
        );
        expected_confidence_valid = $value$plusargs(
            "EXPECTED_CONFIDENCE_WORD=%h",
            expected_confidence_word
        );

        case (test_id)
            20: begin
                case_dir = "test_20/case_01_prepared_patch_a";
                job.phase = PHASE_E_E01;
                first_layer_value = 0;
                last_layer_value = 0;
                class_softmax_enable = 0;
                expected_commands = 4;
                timeout_cycles = 5_000_000;
            end
            21: begin
                case_dir = "test_21/case_01_layer_00";
                job.phase = PHASE_E_E02;
                first_layer_value = 0;
                last_layer_value = 0;
                class_softmax_enable = 0;
                expected_commands = 20;
                timeout_cycles = 40_000_000;
            end
            22: begin
                if ((case_id >= 1) && (case_id <= 11)) begin
                    case_dir = $sformatf("test_22/case_layer_%02d", case_id);
                    first_layer_value = case_id;
                    last_layer_value = case_id;
                    expected_commands = 20;
                    timeout_cycles = 40_000_000;
                end else begin
                    case_dir = "test_22/case_chained_layers_01_11";
                    first_layer_value = 1;
                    last_layer_value = 11;
                    expected_commands = 220;
                    timeout_cycles = 440_000_000;
                end
                job.phase = PHASE_E_E03;
                class_softmax_enable = 0;
            end
            23: begin
                if (case_id == 2) begin
                    case_dir = "test_23/case_02_probability";
                    class_softmax_enable = 1;
                    expected_commands = 5;
                end else begin
                    case_dir = "test_23/case_01_logits_argmax";
                    class_softmax_enable = 0;
                    expected_commands = 4;
                end
                job.phase = PHASE_E_E04;
                first_layer_value = 0;
                last_layer_value = 0;
                timeout_cycles = 5_000_000;
            end
            24: begin
                if (case_id == 2) begin
                    case_dir = "test_24/case_02_prepared_patch_a_probability";
                    class_softmax_enable = 1;
                    expected_commands = 249;
                end else if (case_id == 3) begin
                    $fatal(1, "test_24 case 3 is manifest-only: normalized-pixel patch extraction is not implemented");
                end else begin
                    case_dir = "test_24/case_01_prepared_patch_a_logits";
                    class_softmax_enable = 0;
                    expected_commands = 248;
                end
                job.phase = PHASE_E_E05;
                first_layer_value = 0;
                last_layer_value = 11;
                timeout_cycles = 520_000_000;
            end
            default: $fatal(1, "TEST_ID must be 20 through 24, got %0d", test_id);
        endcase

        plusarg_status = $value$plusargs("CASE_DIR=%s", case_dir);
        checkpoint_dir = {case_dir, "/npu_checkpoints"};
        plusarg_status = $value$plusargs("OUTPUT_DIR=%s", checkpoint_dir);
        if (major_only < 0)
            major_only = ((test_id == 24) || ((test_id == 22) && (case_id == 12))) ? 1 : 0;

        job.first_layer = first_layer_value[3:0];
        job.last_layer = last_layer_value[3:0];
        job.class_softmax_enable = class_softmax_enable != 0;
        job.checkpoint_enable = 1'b1;
        job.job_tag = 8'd0;
        job.patch_a_base = 32'd0;

        global_params.patch_weight_base = PHASE_E_PARAM_MAIN_BASE;
        global_params.patch_bias_base = PHASE_E_PARAM_AUX_BASE;
        global_params.cls_base = PHASE_E_PARAM_MAIN_BASE;
        global_params.position_base = PHASE_E_PARAM_MAIN_BASE;
        global_params.final_ln_gamma_base = PHASE_E_PARAM_MAIN_BASE;
        global_params.final_ln_beta_base = PHASE_E_PARAM_AUX_BASE;
        global_params.classifier_weight_base = PHASE_E_PARAM_MAIN_BASE;
        global_params.classifier_bias_base = PHASE_E_PARAM_AUX_BASE;

        if ((test_id == 20) || (test_id == 24)) begin
            filename = {case_dir, "/inputs/embedding_input_patch_A_f32.hex"};
            plusarg_status = $value$plusargs("INPUT_HEX=%s", filename);
            $display("Prepared image input: %s", filename);
            load_input_region(filename, 0, VIT_PATCH_WORDS);
        end else if (test_id == 21) begin
            filename = {case_dir, "/inputs/encoder_layer_00_residual_input_f32.hex"};
            load_scratch_region(filename, PHASE_E_ADDR_HIDDEN_A, VIT_HIDDEN_WORDS);
        end else if (test_id == 22) begin
            filename = $sformatf(
                "%s/inputs/encoder_layer_%02d_residual_input_f32.hex",
                case_dir,
                first_layer_value
            );
            load_scratch_region(filename, PHASE_E_ADDR_HIDDEN_A, VIT_HIDDEN_WORDS);
        end else begin
            filename = {case_dir, "/inputs/post_encoder_input_sequence_f32.hex"};
            load_scratch_region(filename, PHASE_E_ADDR_HIDDEN_A, VIT_HIDDEN_WORDS);
        end

        $display("Running Phase-E test %0d case %0d from %s", test_id, case_id, case_dir);
        $display("checkpoint_inject=%0d major_only=%0d", checkpoint_inject, major_only);
        $display("checkpoint output directory=%s", checkpoint_dir);

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        while (!job_ready)
            @(negedge clk);
        job_valid = 1'b1;
        @(negedge clk);
        job_valid = 1'b0;

        wait (done || error);
        @(negedge clk);
        simulation_complete = 1'b1;

        if (error)
            $fatal(
                1,
                "Phase-E sequencer error code=%0d section=%0d layer=%0d step=%0d",
                error_code,
                error_section,
                error_layer,
                error_step
            );
        if (command_count != expected_commands)
            $fatal(1, "Expected %0d commands, observed %0d", expected_commands, command_count);
        if ((test_id == 23 || test_id == 24) && (class_result_count != 1))
            $fatal(1, "Expected one argmax result, observed %0d", class_result_count);

        $display(
            "PASS functional run complete: commands=%0d checkpoints=%0d parameter_loads=%0d cycles=%0d",
            command_count,  
            checkpoint_count,
            parameter_load_count,
            cycle_count
        );
        if ((test_id == 23) || (test_id == 24))
            $display("Class index=%0d logit_word=%08x", class_index, class_logit);
        $display("Compare with: .venv/bin/python prepare_phase_e_tests.py --compare %s%s",
                 case_dir, major_only != 0 ? " --major-only" : "");
        $finish;
    end

endmodule
