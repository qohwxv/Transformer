`timescale 1ns/1ps

// Focused production-frontend proof for the M7 packed-mode activation-vector
// cache path.  The first output tile fills the scalar row banks over two K
// chunks.  A later output tile must then fetch one value from every valid row
// per cycle while preserving exact logical/physical/cache accounting.
module tb_m7_vector_activation_cache_frontend;

    import vit_phase_e_pkg::*;

    localparam integer ARRAY_ROWS = 8;
    localparam integer ARRAY_COLS = 2;
    localparam integer PE_LANES = 16;
    localparam integer VECTOR_LANES = 16;
    localparam integer A_WORDS = ARRAY_ROWS * PE_LANES;
    localparam integer PACKED_B_WORDS = PE_LANES;
    localparam integer READ_WORDS = A_WORDS + PACKED_B_WORDS + ARRAY_COLS;

    localparam logic [31:0] M_DIM = 32'd6;
    localparam logic [31:0] K_DIM = 32'd19;
    localparam logic [31:0] N_DIM = 32'd3;
    localparam logic [31:0] A_BASE = 32'd256;
    localparam logic [31:0] B_BASE = 32'd4096;
    localparam logic [31:0] B_OUTPUT_STRIDE = 32'd32;
    localparam logic [31:0] BIAS_BASE = 32'd12288;

    localparam logic [3:0] MEM_IDLE = 4'd0;
    localparam logic [3:0] MEM_READ_REQUEST = 4'd2;
    localparam logic [3:0] MEM_READ_RESPONSE = 4'd3;
    localparam logic [3:0] MEM_READ_DELIVER = 4'd5;
    localparam logic [3:0] MEM_GEMM_A_VECTOR_PRIME = 4'd10;
    localparam logic [3:0] MEM_GEMM_A_VECTOR_RUN = 4'd11;
    localparam logic [3:0] MEM_GEMM_A_VECTOR_DRAIN = 4'd12;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic command_accept = 1'b0;
    logic execute = 1'b1;
    phase_e_cmd_t active_cmd = '0;
    logic selected_data_request = 1'b0;
    logic selected_result_valid = 1'b0;
    logic [15:0] read_word_count = 16'(READ_WORDS);
    logic memory_error_latched;
    logic [3:0] debug_mem_state;

    logic profile_logical_read_word;
    logic profile_a_cache_lookup;
    logic profile_a_cache_hit;
    logic profile_a_cache_miss;
    logic profile_b_bypass;
    logic profile_frontend_error;
    logic [3:0] profile_a_vector_hit_word_delta;
    logic profile_a_vector_protocol_error;

    logic mem_req_valid;
    logic mem_req_ready = 1'b1;
    logic mem_req_write;
    phase_e_mem_space_t mem_req_space;
    logic [31:0] mem_req_word_address;
    logic [31:0] mem_req_write_data;
    logic [3:0] mem_req_write_strobe;
    logic mem_req_read_ahead_safe;
    logic [5:0] mem_req_contiguous_words;
    logic mem_rsp_valid = 1'b1;
    logic mem_rsp_ready;
    logic [31:0] mem_rsp_read_data;
    logic mem_rsp_error = 1'b0;

    logic [31:0] gemm_token_base = 32'd0;
    logic [31:0] gemm_output_base = 32'd0;
    logic [31:0] gemm_k_base = 32'd0;
    logic [31:0] gemm_batch_index = 32'd0;
    logic [ARRAY_ROWS*PE_LANES*32-1:0] gemm_activation_data;
    logic [ARRAY_COLS*PE_LANES*32-1:0] gemm_weight_data;
    logic [ARRAY_COLS*32-1:0] gemm_bias_data;
    logic gemm_data_valid;
    logic gemm_result_ready;

    integer checks = 0;
    integer failures = 0;
    integer monitor_enable = 0;
    integer physical_reads = 0;
    integer scalar_logical_reads = 0;
    integer vector_hit_words = 0;
    integer scalar_a_lookups = 0;
    integer scalar_a_hits = 0;
    integer scalar_a_misses = 0;
    integer b_bypass_reads = 0;
    integer frontend_errors = 0;
    integer vector_protocol_errors = 0;
    integer vector_state_cycles = 0;
    integer data_valid_cycles = 0;
    integer wait_cycles;
    integer row_index;
    integer lane_index;

    always #5 clk = ~clk;

    function automatic logic [31:0] activation_word(
        input logic [31:0] word_address
    );
        begin
            // Address-keyed data makes every row and absolute K coordinate
            // distinct, so a lane replay/reorder cannot pass accidentally.
            activation_word = 32'ha500_0000 ^ word_address;
        end
    endfunction

    function automatic logic [31:0] parameter_word(
        input logic [31:0] word_address
    );
        logic [15:0] low_half;
        logic [15:0] high_half;
        begin
            if (word_address >= BIAS_BASE) begin
                parameter_word = 32'hc500_0000 ^ word_address;
            end else begin
                low_half = 16'h4000 ^ word_address[15:0];
                // The physical v3 package owns N-tail padding.  Model that
                // contract explicitly for output tile 2 of N=3.
                high_half = ((gemm_output_base + 1) < N_DIM) ?
                    (16'h6000 ^ word_address[15:0]) : 16'd0;
                parameter_word = {high_half, low_half};
            end
        end
    endfunction

    always_comb begin
        case (mem_req_space)
            PHASE_E_MEM_INPUT:
                mem_rsp_read_data = activation_word(mem_req_word_address);
            PHASE_E_MEM_PARAM:
                mem_rsp_read_data = parameter_word(mem_req_word_address);
            default:
                mem_rsp_read_data = 32'hdead_beef;
        endcase
    end

    vit_phase_e_memory_frontend #(
        .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .PE_LANES(PE_LANES),
        .VECTOR_LANES(VECTOR_LANES),
        .GEMM_A_CACHE_DEPTH_WORDS(3072),
        .GEMM_BIAS_CACHE_DEPTH_WORDS(3072)
    ) u_frontend (
        .clk(clk),
        .rst(rst),
        .command_accept(command_accept),
        .execute(execute),
        .active_cmd(active_cmd),
        .selected_data_request(selected_data_request),
        .selected_result_valid(selected_result_valid),
        .read_word_count(read_word_count),
        .write_word_count(16'(ARRAY_ROWS * ARRAY_COLS)),
        .memory_error_latched(memory_error_latched),
        .debug_mem_state(debug_mem_state),
        .profile_logical_read_word_o(profile_logical_read_word),
        .profile_logical_write_word_o(),
        .profile_load_active_o(),
        .profile_store_active_o(),
        .profile_a_cache_lookup_o(profile_a_cache_lookup),
        .profile_a_cache_hit_o(profile_a_cache_hit),
        .profile_a_cache_miss_o(profile_a_cache_miss),
        .profile_bias_cache_lookup_o(),
        .profile_bias_cache_hit_o(),
        .profile_bias_cache_miss_o(),
        .profile_b_bypass_o(profile_b_bypass),
        .profile_frontend_error_o(profile_frontend_error),
        .profile_a_vector_hit_word_delta_o(
            profile_a_vector_hit_word_delta
        ),
        .profile_a_vector_protocol_error_o(
            profile_a_vector_protocol_error
        ),
        .profile_result_generation_error_o(),
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_req_write(mem_req_write),
        .mem_req_space(mem_req_space),
        .mem_req_word_address(mem_req_word_address),
        .mem_req_write_data(mem_req_write_data),
        .mem_req_write_strobe(mem_req_write_strobe),
        .mem_req_read_ahead_safe(mem_req_read_ahead_safe),
        .mem_req_contiguous_words(mem_req_contiguous_words),
        .mem_rsp_valid(mem_rsp_valid),
        .mem_rsp_ready(mem_rsp_ready),
        .mem_rsp_read_data(mem_rsp_read_data),
        .mem_rsp_error(mem_rsp_error),
        .gemm_token_base(gemm_token_base),
        .gemm_output_base(gemm_output_base),
        .gemm_k_base(gemm_k_base),
        .gemm_batch_index(gemm_batch_index),
        .gemm_activation_data(gemm_activation_data),
        .gemm_weight_data(gemm_weight_data),
        .gemm_bias_data(gemm_bias_data),
        .gemm_data_valid(gemm_data_valid),
        .gemm_result_address_base_current_o(),
        .gemm_result_address_base_store_i(66'd0),
        .gemm_result_generation_store_i(8'd0),
        .gemm_result_generation_expected_i(8'd0),
        .gemm_result_token_base_store_i(32'd0),
        .gemm_result_output_base_store_i(32'd0),
        .gemm_result_batch_index_store_i(32'd0),
        .gemm_result_token_mask('0),
        .gemm_result_output_mask('0),
        .gemm_result_data('0),
        .gemm_result_ready(gemm_result_ready),
        .vector_element_base('0),
        .vector_input_a(),
        .vector_input_b(),
        .vector_data_valid(),
        .vector_result_base('0),
        .vector_result_lane_mask('0),
        .vector_result_data('0),
        .vector_result_ready(),
        .layout_source_address('0),
        .layout_source_data(),
        .layout_data_valid(),
        .layout_result_address('0),
        .layout_result_data('0),
        .layout_result_ready(),
        .ln_data_pass('0),
        .ln_data_index('0),
        .ln_data_channel_index('0),
        .ln_input_data(),
        .ln_gamma_data(),
        .ln_beta_data(),
        .ln_input_valid(),
        .ln_result_index('0),
        .ln_result_data('0),
        .ln_result_ready(),
        .softmax_data_index('0),
        .softmax_input_data(),
        .softmax_input_valid(),
        .softmax_result_index('0),
        .softmax_result_data('0),
        .softmax_result_ready(),
        .gelu_data_base_index('0),
        .gelu_data_lane_mask('0),
        .gelu_input_data(),
        .gelu_input_valid(),
        .gelu_result_base_index('0),
        .gelu_result_lane_mask('0),
        .gelu_result_data('0),
        .gelu_result_ready(),
        .argmax_element_index('0),
        .argmax_input_data(),
        .argmax_data_valid(),
        .argmax_result_ready()
    );

    task automatic check_true(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $error(
                    "%s state=%0d out=%0d k=%0d phys=%0d logical=%0d vhit=%0d",
                    message,
                    debug_mem_state,
                    gemm_output_base,
                    gemm_k_base,
                    physical_reads,
                    scalar_logical_reads,
                    vector_hit_words
                );
            end
        end
    endtask

    task automatic configure_command;
        begin
            active_cmd = '0;
            active_cmd.header.opcode = PHASE_E_OP_GEMM;
            active_cmd.header.flags =
                PHASE_E_FLAG_BIAS_ENABLE |
                PHASE_E_FLAG_GEMM_CACHE_SAFE |
                PHASE_E_FLAG_GEMM_FP16 |
                PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2 |
                PHASE_E_FLAG_GEMM_B_FP16_PACKED2;
            active_cmd.route.src0_space = PHASE_E_MEM_INPUT;
            active_cmd.route.src1_space = PHASE_E_MEM_PARAM;
            active_cmd.route.src2_space = PHASE_E_MEM_PARAM;
            active_cmd.route.dst_space = PHASE_E_MEM_SCRATCH;
            active_cmd.src0_base = A_BASE;
            active_cmd.src1_base = B_BASE;
            active_cmd.src2_base = BIAS_BASE;
            active_cmd.dst_base = 32'd16384;
            active_cmd.dim0 = 32'd1;
            active_cmd.dim1 = M_DIM;
            active_cmd.dim2 = K_DIM;
            active_cmd.dim3 = N_DIM;
            active_cmd.stride0 = M_DIM * K_DIM;
            active_cmd.stride1 = K_DIM;
            active_cmd.stride2 = B_OUTPUT_STRIDE * 2;
            active_cmd.stride3 = B_OUTPUT_STRIDE;
            active_cmd.stride4 = M_DIM * N_DIM;
            active_cmd.immediate = N_DIM;
            read_word_count = 16'(READ_WORDS);
        end
    endtask

    task automatic apply_reset;
        begin
            @(negedge clk);
            selected_data_request = 1'b0;
            command_accept = 1'b0;
            rst = 1'b1;
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
            @(posedge clk);
            #1;
        end
    endtask

    task automatic pulse_command_accept;
        begin
            @(negedge clk);
            command_accept = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            command_accept = 1'b0;
        end
    endtask

    task automatic clear_monitors;
        begin
            physical_reads = 0;
            scalar_logical_reads = 0;
            vector_hit_words = 0;
            scalar_a_lookups = 0;
            scalar_a_hits = 0;
            scalar_a_misses = 0;
            b_bypass_reads = 0;
            frontend_errors = 0;
            vector_protocol_errors = 0;
            vector_state_cycles = 0;
            data_valid_cycles = 0;
        end
    endtask

    task automatic run_gather(
        input logic [31:0] output_base,
        input logic [31:0] k_base
    );
        begin
            gemm_output_base = output_base;
            gemm_k_base = k_base;
            clear_monitors();
            monitor_enable = 1;
            @(negedge clk);
            selected_data_request = 1'b1;
            @(posedge clk);
            #1;
            selected_data_request = 1'b0;
            wait_cycles = 0;
            while (!gemm_data_valid && (wait_cycles < 4000)) begin
                @(posedge clk);
                #1;
                wait_cycles = wait_cycles + 1;
            end
            check_true(gemm_data_valid, "gather reaches data_valid");
            @(posedge clk);
            #1;
            monitor_enable = 0;
            check_true(debug_mem_state == MEM_IDLE,
                       "gather returns to MEM_IDLE");
        end
    endtask

    task automatic check_counters(
        input integer expected_physical,
        input integer expected_scalar_logical,
        input integer expected_vector_hit,
        input integer expected_a_miss,
        input integer expected_b_bypass,
        input string label
    );
        begin
            check_true(
                physical_reads == expected_physical,
                $sformatf("%s physical reads got=%0d expected=%0d",
                          label, physical_reads, expected_physical)
            );
            check_true(
                scalar_logical_reads == expected_scalar_logical,
                $sformatf("%s scalar logical got=%0d expected=%0d",
                          label, scalar_logical_reads,
                          expected_scalar_logical)
            );
            check_true(
                vector_hit_words == expected_vector_hit,
                $sformatf("%s vector cache-hit delta got=%0d expected=%0d",
                          label, vector_hit_words, expected_vector_hit)
            );
            check_true(
                (scalar_logical_reads + vector_hit_words) ==
                    (expected_scalar_logical + expected_vector_hit),
                $sformatf("%s effective logical count", label)
            );
            check_true(
                scalar_a_misses == expected_a_miss,
                $sformatf("%s A misses got=%0d expected=%0d",
                          label, scalar_a_misses, expected_a_miss)
            );
            check_true(
                scalar_a_lookups == expected_a_miss,
                $sformatf("%s scalar A lookups got=%0d expected=%0d",
                          label, scalar_a_lookups, expected_a_miss)
            );
            check_true(scalar_a_hits == 0,
                       $sformatf("%s scalar A-hit path stays unused", label));
            check_true(
                b_bypass_reads == expected_b_bypass,
                $sformatf("%s B bypass got=%0d expected=%0d",
                          label, b_bypass_reads, expected_b_bypass)
            );
            check_true(frontend_errors == 0,
                       $sformatf("%s has no frontend error", label));
            check_true(vector_protocol_errors == 0,
                       $sformatf("%s has no vector protocol error", label));
            if (expected_vector_hit != 0)
                check_true(vector_state_cycles != 0,
                           $sformatf("%s exercised vector states", label));
            else
                check_true(vector_state_cycles == 0,
                           $sformatf("%s did not enter vector states", label));
        end
    endtask

    task automatic check_activation_tile(
        input logic [31:0] k_base,
        input integer valid_k_lanes,
        input string label
    );
        logic [31:0] expected_word;
        begin
            for (row_index = 0; row_index < ARRAY_ROWS;
                 row_index = row_index + 1)
                for (lane_index = 0; lane_index < PE_LANES;
                     lane_index = lane_index + 1) begin
                    expected_word = 32'd0;
                    if ((row_index < M_DIM) &&
                        (lane_index < valid_k_lanes))
                        expected_word = activation_word(
                            A_BASE + row_index*K_DIM + k_base + lane_index
                        );
                    check_true(
                        gemm_activation_data[
                            (row_index*PE_LANES + lane_index)*32 +: 32
                        ] == expected_word,
                        $sformatf("%s A row=%0d lane=%0d",
                                  label, row_index, lane_index)
                    );
                end
        end
    endtask

    task automatic check_scalar_cache_fallback(
        input integer expected_physical,
        input integer expected_logical,
        input integer expected_a_hits,
        input integer expected_a_misses,
        input integer expected_b_bypass,
        input string label
    );
        begin
            check_true(
                physical_reads == expected_physical,
                $sformatf("%s physical reads got=%0d expected=%0d",
                          label, physical_reads, expected_physical)
            );
            check_true(
                scalar_logical_reads == expected_logical,
                $sformatf("%s logical reads got=%0d expected=%0d",
                          label, scalar_logical_reads, expected_logical)
            );
            check_true(vector_hit_words == 0,
                       $sformatf("%s has no vector hit delta", label));
            check_true(vector_state_cycles == 0,
                       $sformatf("%s stays on scalar fallback", label));
            check_true(
                scalar_a_lookups == expected_a_hits + expected_a_misses,
                $sformatf("%s A lookup count", label)
            );
            check_true(
                scalar_a_hits == expected_a_hits,
                $sformatf("%s A hits got=%0d expected=%0d",
                          label, scalar_a_hits, expected_a_hits)
            );
            check_true(
                scalar_a_misses == expected_a_misses,
                $sformatf("%s A misses got=%0d expected=%0d",
                          label, scalar_a_misses, expected_a_misses)
            );
            check_true(
                b_bypass_reads == expected_b_bypass,
                $sformatf("%s B bypass got=%0d expected=%0d",
                          label, b_bypass_reads, expected_b_bypass)
            );
            check_true(frontend_errors == 0,
                       $sformatf("%s has no frontend error", label));
            check_true(vector_protocol_errors == 0,
                       $sformatf("%s has no vector protocol error", label));
        end
    endtask

    task automatic prepare_filled_cache;
        begin
            configure_command();
            gemm_token_base = 32'd0;
            gemm_output_base = 32'd0;
            gemm_k_base = 32'd0;
            gemm_batch_index = 32'd0;
            apply_reset();
            pulse_command_accept();
            run_gather(32'd0, 32'd0);
            run_gather(32'd0, 32'd16);
            check_true(u_frontend.gemm_a_cache_valid,
                       "cache preparation reaches valid state");
        end
    endtask

    // mutation_phase: 0=vector stage, 1=packed-B request/response,
    // 2=bias request/response, 3=READ_DELIVER guard window.
    task automatic run_coordinate_mutation(
        input integer mutation_phase,
        input string label
    );
        logic target_reached;
        begin
            gemm_token_base = 32'd0;
            gemm_output_base = 32'd2;
            gemm_k_base = (mutation_phase == 2) ? 32'd16 : 32'd0;
            gemm_batch_index = 32'd0;
            clear_monitors();
            monitor_enable = 1;
            @(negedge clk);
            selected_data_request = 1'b1;
            @(posedge clk);
            #1;
            selected_data_request = 1'b0;

            wait_cycles = 0;
            target_reached = 1'b0;
            while (!target_reached && (wait_cycles < 500)) begin
                case (mutation_phase)
                    0: target_reached =
                        (debug_mem_state == MEM_GEMM_A_VECTOR_PRIME) ||
                        (debug_mem_state == MEM_GEMM_A_VECTOR_RUN);
                    1: target_reached =
                        ((debug_mem_state == MEM_READ_REQUEST) ||
                         (debug_mem_state == MEM_READ_RESPONSE)) &&
                        (u_frontend.mem_word_index >= A_WORDS) &&
                        (u_frontend.mem_word_index <
                         (A_WORDS + PACKED_B_WORDS));
                    2: target_reached =
                        ((debug_mem_state == MEM_READ_REQUEST) ||
                         (debug_mem_state == MEM_READ_RESPONSE)) &&
                        (u_frontend.mem_word_index >=
                         (A_WORDS + PACKED_B_WORDS));
                    default: target_reached =
                        (debug_mem_state == MEM_READ_DELIVER);
                endcase
                if (!target_reached) begin
                    @(posedge clk);
                    #1;
                    wait_cycles = wait_cycles + 1;
                end
            end
            check_true(target_reached,
                       $sformatf("%s reaches requested mutation phase", label));

            // Change a held coordinate after the vector A read has started.
            // The hardened guard remains armed through B, bias and DELIVER.
            @(negedge clk);
            gemm_output_base = 32'd0;
            #1;
            check_true(profile_a_vector_protocol_error,
                       $sformatf("%s asserts protocol-error event", label));
            check_true(!gemm_data_valid,
                       $sformatf("%s suppresses combinational data_valid", label));
            @(posedge clk);
            #1;
            check_true(memory_error_latched,
                       $sformatf("%s latches memory error", label));
            check_true(debug_mem_state == MEM_IDLE,
                       $sformatf("%s returns to idle", label));
            check_true(frontend_errors == 1,
                       $sformatf("%s emits one frontend error pulse", label));
            check_true(vector_protocol_errors == 1,
                       $sformatf("%s emits one protocol error pulse", label));
            check_true(data_valid_cycles == 0,
                       $sformatf("%s never delivers mixed data", label));
            check_true(!u_frontend.gemm_a_cache_valid,
                       $sformatf("%s invalidates activation cache", label));
            repeat (2) begin
                @(posedge clk);
                #1;
                check_true(!mem_req_valid && !gemm_data_valid,
                           $sformatf("%s remains fail closed", label));
            end
            monitor_enable = 0;
            gemm_output_base = 32'd2;
        end
    endtask

    always @(posedge clk) begin
        if (monitor_enable != 0) begin
            if (mem_req_valid && mem_req_ready)
                physical_reads = physical_reads + 1;
            if (profile_logical_read_word)
                scalar_logical_reads = scalar_logical_reads + 1;
            vector_hit_words = vector_hit_words +
                profile_a_vector_hit_word_delta;
            if (profile_a_cache_lookup)
                scalar_a_lookups = scalar_a_lookups + 1;
            if (profile_a_cache_hit)
                scalar_a_hits = scalar_a_hits + 1;
            if (profile_a_cache_miss)
                scalar_a_misses = scalar_a_misses + 1;
            if (profile_b_bypass)
                b_bypass_reads = b_bypass_reads + 1;
            if (profile_frontend_error)
                frontend_errors = frontend_errors + 1;
            if (profile_a_vector_protocol_error)
                vector_protocol_errors = vector_protocol_errors + 1;
            if ((debug_mem_state == MEM_GEMM_A_VECTOR_PRIME) ||
                (debug_mem_state == MEM_GEMM_A_VECTOR_RUN) ||
                (debug_mem_state == MEM_GEMM_A_VECTOR_DRAIN))
                vector_state_cycles = vector_state_cycles + 1;
            if (gemm_data_valid)
                data_valid_cycles = data_valid_cycles + 1;
        end
    end

    initial begin
        configure_command();
        apply_reset();
        pulse_command_accept();

        // Output tile zero fills six valid row banks across K16 plus K3.
        run_gather(32'd0, 32'd0);
        check_counters(112, 112, 0, 96, 16, "fill K0");
        check_activation_tile(32'd0, 16, "fill K0");
        check_true(!u_frontend.gemm_a_cache_valid,
                   "cache is not valid before final K chunk");

        run_gather(32'd0, 32'd16);
        check_counters(23, 23, 0, 18, 3, "fill K16 tail");
        check_activation_tile(32'd16, 3, "fill K16 tail");
        check_true(u_frontend.gemm_a_cache_valid,
                   "cache becomes valid after final K chunk");

        // Controlled S8 column one replays the same output/tile coordinates
        // from K0.  It must hit the completed A cache rather than clear and
        // refill it merely because output_base==0 and k_base==0 recur.
        run_gather(32'd0, 32'd0);
        check_counters(16, 16, 96, 0, 16, "S8 same-tile K rewind hit");
        check_activation_tile(32'd0, 16, "S8 same-tile K rewind hit");
        check_true(u_frontend.gemm_a_cache_valid,
                   "S8 second column preserves activation cache validity");

        // Output tile two reuses A as six words/cycle.  It has an M=6 tail,
        // a K=19 tail and an N=3 tail; all invalid A lanes/rows remain zero.
        run_gather(32'd2, 32'd0);
        check_counters(16, 16, 96, 0, 16, "vector hit K0");
        check_activation_tile(32'd0, 16, "vector hit K0");
        check_true((scalar_logical_reads + vector_hit_words) == 112,
                   "vector K0 logical demand is preserved");
        check_true((scalar_a_lookups + vector_hit_words) == 96,
                   "vector K0 A lookup count is preserved");
        check_true((scalar_a_hits + vector_hit_words) == 96,
                   "vector K0 A hit count is preserved");
        for (lane_index = 0; lane_index < PE_LANES;
             lane_index = lane_index + 1) begin
            check_true(gemm_weight_data[lane_index*32 +: 16] != 16'd0,
                       "N-tail valid packed half is present");
            check_true(gemm_weight_data[lane_index*32 + 16 +: 16] == 16'd0,
                       "N-tail invalid packed half is zero padded");
        end

        run_gather(32'd2, 32'd16);
        check_counters(4, 4, 18, 0, 3, "vector hit K16 tail");
        check_activation_tile(32'd16, 3, "vector hit K16 tail");
        check_true((scalar_logical_reads + vector_hit_words) == 22,
                   "vector K tail logical demand is preserved");
        check_true((scalar_a_lookups + vector_hit_words) == 18,
                   "vector K tail A lookup count is preserved");
        check_true((scalar_a_hits + vector_hit_words) == 18,
                   "vector K tail A hit count is preserved");
        check_true(gemm_bias_data[31:0] != 32'd0,
                   "N-tail valid bias is present");
        check_true(gemm_bias_data[63:32] == 32'd0,
                   "N-tail invalid bias remains zero");

        // A packed flag by itself is not authority to use the vector path.
        // Missing either the FP16-compute or blocked-layout flag takes the
        // safe scalar cache path without raising a protocol error.
        active_cmd.header.flags = active_cmd.header.flags &
            ~PHASE_E_FLAG_GEMM_FP16;
        run_gather(32'd2, 32'd0);
        check_scalar_cache_fallback(
            16, 112, 96, 0, 16, "missing FP16 flag fallback"
        );
        check_activation_tile(32'd0, 16, "missing FP16 flag fallback");

        active_cmd.header.flags = active_cmd.header.flags |
            PHASE_E_FLAG_GEMM_FP16;
        active_cmd.header.flags = active_cmd.header.flags &
            ~PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2;
        run_gather(32'd2, 32'd0);
        check_scalar_cache_fallback(
            16, 112, 96, 0, 16, "missing blocked flag fallback"
        );
        check_activation_tile(32'd0, 16, "missing blocked flag fallback");
        active_cmd.header.flags = active_cmd.header.flags |
            PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2;

        // A valid cache with a different token tag must not enter the vector
        // path.  Five M-tail rows are read physically for token base one.
        gemm_token_base = 32'd1;
        run_gather(32'd2, 32'd0);
        check_scalar_cache_fallback(
            96, 96, 0, 80, 16, "activation tag miss fallback"
        );
        check_true(u_frontend.gemm_a_cache_valid,
                   "tag miss does not consume or relabel valid cache");
        gemm_token_base = 32'd0;

        // The held-coordinate contract is checked at every stage of a vector
        // cache request, not only while row banks are being read.
        prepare_filled_cache();
        run_coordinate_mutation(0, "mutation during vector A");
        prepare_filled_cache();
        run_coordinate_mutation(1, "mutation during packed B");
        prepare_filled_cache();
        run_coordinate_mutation(2, "mutation during bias");
        prepare_filled_cache();
        run_coordinate_mutation(3, "mutation during READ_DELIVER");

        // Reset is the only recovery operation.  It clears the sticky error,
        // vector pipeline and cache tag; the next output-zero request refills
        // through physical A reads rather than reusing stale RAM contents.
        gemm_output_base = 32'd0;
        gemm_k_base = 32'd0;
        apply_reset();
        check_true(!memory_error_latched,
                   "reset clears coordinate-mutation error");
        check_true(debug_mem_state == MEM_IDLE,
                   "reset leaves frontend idle");
        check_true(!u_frontend.gemm_a_cache_valid,
                   "reset invalidates activation cache tag");
        run_gather(32'd0, 32'd0);
        check_counters(112, 112, 0, 96, 16, "post-reset refill");
        check_activation_tile(32'd0, 16, "post-reset refill");

        // Capacity overflow is a deterministic physical-read fallback.  It
        // must neither alias the 3072-entry RAM nor advertise vector hits.
        configure_command();
        active_cmd.dim2 = 32'd3073;
        active_cmd.stride0 = M_DIM * 32'd3073;
        active_cmd.stride1 = 32'd3073;
        gemm_token_base = 32'd0;
        gemm_output_base = 32'd0;
        gemm_k_base = 32'd0;
        gemm_batch_index = 32'd0;
        pulse_command_accept();
        check_true(!u_frontend.gemm_a_cache_allowed,
                   "K=3073 disables activation cache");
        run_gather(32'd0, 32'd0);
        check_scalar_cache_fallback(
            112, 112, 0, 0, 16, "K3073 capacity fallback"
        );
        check_true(!u_frontend.gemm_a_cache_valid,
                   "K=3073 cannot mark activation cache valid");

        if (failures == 0) begin
            $display(
                "PASS M7 vector activation cache frontend: checks=%0d fill_phys=112+23 hit_phys=16+4 hit_words=96+18 malformed_fallback=2 tag_miss=1 mutation_stages=4 K3073_fallback=1",
                checks
            );
            $finish;
        end
        $fatal(1,
               "FAIL M7 vector activation cache frontend: %0d/%0d failed",
               failures, checks);
    end

    initial begin
        repeat (20000) @(posedge clk);
        $fatal(1, "Timeout in tb_m7_vector_activation_cache_frontend");
    end

endmodule
