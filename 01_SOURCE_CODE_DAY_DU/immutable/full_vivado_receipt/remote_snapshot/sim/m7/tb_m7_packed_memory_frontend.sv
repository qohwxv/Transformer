`timescale 1ns/1ps

// End-to-end gather-seam test around the production memory frontend.
// The memory response data is keyed by the frontend's physical gather slot,
// allowing exact checks of packed-v3 lower-512 placement and dynamic bias
// indices without changing or binding into production RTL.
module tb_m7_packed_memory_frontend;

    import vit_phase_e_pkg::*;

    localparam integer ARRAY_ROWS = 8;
    localparam integer ARRAY_COLS = 2;
    localparam integer PE_LANES = 16;
    localparam integer VECTOR_LANES = 16;
    localparam integer A_WORDS = ARRAY_ROWS * PE_LANES;
    localparam integer B_V2_WORDS = ARRAY_COLS * PE_LANES;
    localparam integer B_V3_WORDS =
        ((ARRAY_COLS + 1) / 2) * PE_LANES;
    localparam integer PACKED_READ_WORDS =
        A_WORDS + B_V3_WORDS + ARRAY_COLS;
    localparam integer LEGACY_READ_WORDS =
        A_WORDS + B_V2_WORDS + ARRAY_COLS;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic command_accept = 1'b0;
    logic execute = 1'b1;
    phase_e_cmd_t active_cmd = '0;
    logic selected_data_request = 1'b0;
    logic selected_result_valid = 1'b0;
    logic [15:0] read_word_count = '0;
    logic [15:0] write_word_count = 16'd16;
    logic memory_error_latched;
    logic [3:0] debug_mem_state;
    logic profile_logical_read_word_o;
    logic profile_b_bypass_o;
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
    logic [31:0] gemm_token_base = '0;
    logic [31:0] gemm_output_base = '0;
    logic [31:0] gemm_k_base = '0;
    logic [31:0] gemm_batch_index = '0;
    logic [ARRAY_ROWS*PE_LANES*32-1:0] gemm_activation_data;
    logic [ARRAY_COLS*PE_LANES*32-1:0] gemm_weight_data;
    logic [ARRAY_COLS*32-1:0] gemm_bias_data;
    logic gemm_data_valid;
    logic [65:0] gemm_result_address_base_current;
    logic [65:0] gemm_result_address_base_store = 66'd0;
    logic [7:0] gemm_result_generation_store = 8'd0;
    logic [7:0] gemm_result_generation_expected = 8'd0;
    logic profile_result_generation_error;
    logic [ARRAY_ROWS-1:0] gemm_result_token_mask = '0;
    logic [ARRAY_COLS-1:0] gemm_result_output_mask = '0;
    logic [ARRAY_ROWS*ARRAY_COLS*32-1:0] gemm_result_data = '0;
    logic gemm_result_ready;

    integer checks = 0;
    integer failures = 0;
    integer monitor_enable = 0;
    integer active_case = 0;
    integer physical_reads = 0;
    integer b_reads = 0;
    integer bias_reads = 0;
    integer logical_reads = 0;
    integer b_bypass_reads = 0;
    integer seen_bias_index0 = 0;
    integer seen_bias_index1 = 0;
    integer wait_cycles;
    integer word;
    integer current_bias_base;
    integer physical_writes;
    integer arbitration_reads;
    integer arbitration_seen_write;

    always #5 clk = ~clk;

    always_comb begin
        current_bias_base =
            (active_case == 2) ?
                (A_WORDS + B_V2_WORDS) :
                (A_WORDS + B_V3_WORDS);
        if (u_frontend.mem_word_index < A_WORDS)
            mem_rsp_read_data =
                32'ha000_0000 | {16'd0, u_frontend.mem_word_index};
        else if (u_frontend.mem_word_index < current_bias_base)
            mem_rsp_read_data =
                32'hb000_0000 |
                (u_frontend.mem_word_index - A_WORDS);
        else
            mem_rsp_read_data =
                32'hc000_0000 |
                (u_frontend.mem_word_index - current_bias_base);
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
        .write_word_count(write_word_count),
        .memory_error_latched(memory_error_latched),
        .debug_mem_state(debug_mem_state),
        .profile_logical_read_word_o(profile_logical_read_word_o),
        .profile_logical_write_word_o(),
        .profile_load_active_o(),
        .profile_store_active_o(),
        .profile_a_cache_lookup_o(),
        .profile_a_cache_hit_o(),
        .profile_a_cache_miss_o(),
        .profile_bias_cache_lookup_o(),
        .profile_bias_cache_hit_o(),
        .profile_bias_cache_miss_o(),
        .profile_b_bypass_o(profile_b_bypass_o),
        .profile_frontend_error_o(),
        .profile_result_generation_error_o(
            profile_result_generation_error
        ),
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
        .gemm_result_address_base_current_o(
            gemm_result_address_base_current
        ),
        .gemm_result_address_base_store_i(
            gemm_result_address_base_store
        ),
        .gemm_result_generation_store_i(
            gemm_result_generation_store
        ),
        .gemm_result_generation_expected_i(
            gemm_result_generation_expected
        ),
        .gemm_result_token_base_store_i(32'd0),
        .gemm_result_output_base_store_i(32'd0),
        .gemm_result_batch_index_store_i(32'd0),
        .gemm_result_token_mask(gemm_result_token_mask),
        .gemm_result_output_mask(gemm_result_output_mask),
        .gemm_result_data(gemm_result_data),
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
                    "%s case=%0d idx=%0d addr=%08x reads=%0d",
                    message,
                    active_case,
                    u_frontend.mem_word_index,
                    mem_req_word_address,
                    physical_reads
                );
            end
        end
    endtask

    task automatic apply_reset;
        begin
            @(negedge clk);
            selected_data_request = 1'b0;
            selected_result_valid = 1'b0;
            command_accept = 1'b0;
            rst = 1'b1;
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
        end
    endtask

    task automatic configure_case(
        input integer which_case,
        input logic [31:0] reduction,
        input logic [31:0] outputs
    );
        begin
            active_case = which_case;
            active_cmd = '0;
            active_cmd.header.opcode = PHASE_E_OP_GEMM;
            active_cmd.header.flags =
                PHASE_E_FLAG_BIAS_ENABLE |
                PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2;
            if (which_case != 2)
                active_cmd.header.flags =
                    active_cmd.header.flags |
                    PHASE_E_FLAG_GEMM_B_FP16_PACKED2;
            active_cmd.route.src0_space = PHASE_E_MEM_INPUT;
            active_cmd.route.src1_space = PHASE_E_MEM_PARAM;
            active_cmd.route.src2_space = PHASE_E_MEM_PARAM;
            active_cmd.route.dst_space = PHASE_E_MEM_SCRATCH;
            active_cmd.src0_base = 32'd100;
            active_cmd.src1_base = (which_case == 2) ? 32'd992 : 32'd1008;
            active_cmd.src2_base = 32'd7000;
            active_cmd.dim0 = 32'd1;
            active_cmd.dim1 = 32'd8;
            active_cmd.dim2 = reduction;
            active_cmd.dim3 = outputs;
            active_cmd.stride1 = reduction;
            active_cmd.stride3 =
                (which_case == 2) ? B_V2_WORDS : B_V3_WORDS;
            active_cmd.immediate = outputs;
            read_word_count =
                (which_case == 2) ?
                    16'(LEGACY_READ_WORDS) :
                    16'(PACKED_READ_WORDS);
        end
    endtask

    task automatic start_gather;
        begin
            physical_reads = 0;
            b_reads = 0;
            bias_reads = 0;
            logical_reads = 0;
            b_bypass_reads = 0;
            seen_bias_index0 = 0;
            seen_bias_index1 = 0;
            monitor_enable = 1;
            @(negedge clk);
            selected_data_request = 1'b1;
            @(posedge clk);
            #1;
            selected_data_request = 1'b0;
            wait_cycles = 0;
            while (!gemm_data_valid && (wait_cycles < 3000)) begin
                @(posedge clk);
                #1;
                wait_cycles = wait_cycles + 1;
            end
            check_true(gemm_data_valid, "gather reaches data_valid");
            monitor_enable = 0;
        end
    endtask

    always @(posedge clk) begin
        if (monitor_enable != 0) begin
            if (profile_logical_read_word_o)
                logical_reads = logical_reads + 1;
            if (profile_b_bypass_o)
                b_bypass_reads = b_bypass_reads + 1;
            if (mem_req_valid && mem_req_ready) begin
                physical_reads = physical_reads + 1;
                if ((u_frontend.mem_word_index >= A_WORDS) &&
                    (u_frontend.mem_word_index < current_bias_base)) begin
                    b_reads = b_reads + 1;
                    if (active_case != 2) begin
                        check_true(
                            mem_req_word_address ==
                                32'(1008 +
                                    u_frontend.mem_word_index - A_WORDS),
                            "packed B request address");
                        check_true(mem_req_read_ahead_safe,
                                   "packed B request is read-ahead safe");
                        check_true(
                            mem_req_contiguous_words ==
                                6'(B_V3_WORDS -
                                   (u_frontend.mem_word_index - A_WORDS)),
                            "packed B read-ahead extent");
                    end else begin
                        check_true(
                            mem_req_word_address ==
                                32'(992 +
                                    u_frontend.mem_word_index - A_WORDS),
                            "legacy B request address");
                    end
                end else if (u_frontend.mem_word_index >= current_bias_base) begin
                    bias_reads = bias_reads + 1;
                    if (u_frontend.mem_word_index == current_bias_base)
                        seen_bias_index0 = seen_bias_index0 + 1;
                    if (u_frontend.mem_word_index == current_bias_base + 1)
                        seen_bias_index1 = seen_bias_index1 + 1;
                    check_true(
                        mem_req_word_address ==
                            32'(7000 +
                                u_frontend.mem_word_index -
                                current_bias_base),
                        "bias request address follows dynamic B size");
                end
            end
        end
    end

    initial begin
        // Full packed-v3 gather.
        configure_case(1, 32'd16, 32'd2);
        apply_reset();
        start_gather();
        check_true(!memory_error_latched, "packed gather has no error");
        check_true(physical_reads == PACKED_READ_WORDS,
                   "packed full gather issues 146 physical reads");
        check_true(logical_reads == PACKED_READ_WORDS,
                   "packed full gather counts 146 logical reads");
        check_true(b_reads == B_V3_WORDS,
                   "packed full gather reads 16 B words");
        check_true(b_bypass_reads == B_V3_WORDS,
                   "packed B bypass count is 16");
        check_true(bias_reads == 2,
                   "packed full gather reads two bias words");
        check_true(seen_bias_index0 == 1 && seen_bias_index1 == 1,
                   "packed bias slots are exactly 144/145");
        for (word = 0; word < B_V3_WORDS; word = word + 1)
            check_true(
                gemm_weight_data[word*32 +: 32] ==
                    (32'hb000_0000 | word),
                "packed word is placed in lower 512 bits");
        check_true(gemm_weight_data[1023:512] == 512'd0,
                   "packed upper 512 bits remain zero");
        check_true(gemm_bias_data[31:0] == 32'hc000_0000,
                   "packed bias index 144 fills column zero");
        check_true(gemm_bias_data[63:32] == 32'hc000_0001,
                   "packed bias index 145 fills column one");

        // Full legacy blocked-v2 gather remains unchanged.
        configure_case(2, 32'd16, 32'd2);
        apply_reset();
        start_gather();
        check_true(!memory_error_latched, "legacy gather has no error");
        check_true(physical_reads == LEGACY_READ_WORDS,
                   "legacy full gather remains 162 physical reads");
        check_true(logical_reads == LEGACY_READ_WORDS,
                   "legacy full gather remains 162 logical reads");
        check_true(b_reads == B_V2_WORDS,
                   "legacy full gather retains 32 B words");
        check_true(b_bypass_reads == B_V2_WORDS,
                   "legacy B bypass count remains 32");
        check_true(seen_bias_index0 == 1 && seen_bias_index1 == 1,
                   "legacy bias slots are exactly 160/161");
        for (word = 0; word < B_V2_WORDS; word = word + 1)
            check_true(
                gemm_weight_data[word*32 +: 32] ==
                    (32'hb000_0000 | word),
                "legacy word placement remains all 1024 bits");
        check_true(gemm_bias_data[31:0] == 32'hc000_0000,
                   "legacy bias index 160 fills column zero");
        check_true(gemm_bias_data[63:32] == 32'hc000_0001,
                   "legacy bias index 161 fills column one");

        // Packed K=1/N=1 tails: 8 A words + one packed B pair + one bias.
        configure_case(3, 32'd1, 32'd1);
        apply_reset();
        start_gather();
        check_true(physical_reads == 10,
                   "packed K1/N1 tail issues only ten physical reads");
        check_true(logical_reads == 10,
                   "packed K1/N1 tail counts ten logical reads");
        check_true(b_reads == 1 && b_bypass_reads == 1,
                   "packed K tail reads only lane zero pair");
        check_true(bias_reads == 1,
                   "packed N tail reads only bias column zero");
        check_true(seen_bias_index0 == 1 && seen_bias_index1 == 0,
                   "packed bias tail suppresses index 145");
        check_true(gemm_weight_data[31:0] == 32'hb000_0000,
                   "packed tail places lane zero word");
        check_true(gemm_weight_data[1023:32] == '0,
                   "packed tail leaves all invalid B slots zero");
        check_true(gemm_bias_data[31:0] == 32'hc000_0000,
                   "packed tail places first bias");
        check_true(gemm_bias_data[63:32] == 32'd0,
                   "packed tail leaves second bias zero");

        // A queued result carries an absolute destination and generation.
        // Prove that the frontend snapshots both metadata fields, writes from
        // the queued base (not the live load context), wins arbitration over
        // a simultaneously held packed operand request, and rejects a stale
        // generation before issuing any memory request.
        apply_reset();
        configure_case(1, 32'd16, 32'd2);
        active_cmd.immediate = 32'd2;
        write_word_count = 16'd16;
        gemm_result_address_base_store = 66'd9000;
        gemm_result_generation_store = 8'h2a;
        gemm_result_generation_expected = 8'h2a;
        gemm_result_token_mask = 8'hff;
        gemm_result_output_mask = 2'b11;
        gemm_result_data = '0;
        for (word = 0; word < 16; word = word + 1)
            gemm_result_data[word*32 +: 32] = 32'hd000_0000 | word;
        physical_writes = 0;
        arbitration_reads = 0;
        arbitration_seen_write = 0;
        @(negedge clk);
        selected_data_request = 1'b1;
        selected_result_valid = 1'b1;
        while (!gemm_result_ready) begin
            @(posedge clk);
            #1;
            if (mem_req_valid && mem_req_ready) begin
                if (!mem_req_write) begin
                    check_true(arbitration_seen_write == 0,
                               "packed look-ahead load precedes queued store");
                    arbitration_reads = arbitration_reads + 1;
                end else begin
                    arbitration_seen_write = 1;
                    check_true(
                        mem_req_word_address == 32'(9000 + physical_writes),
                        "queued absolute result base drives write address"
                    );
                    check_true(mem_req_write_data ==
                               (32'hd000_0000 | physical_writes),
                               "queued result payload preserves slot order");
                    physical_writes = physical_writes + 1;
                end
            end
        end
        check_true(arbitration_reads == PACKED_READ_WORDS,
                   "one packed look-ahead panel precedes queued store");
        check_true(physical_writes == 16,
                   "queued result stores exactly sixteen words");
        check_true(!memory_error_latched,
                   "matching result generation stores cleanly");
        @(negedge clk);
        selected_data_request = 1'b0;
        selected_result_valid = 1'b0;

        apply_reset();
        configure_case(1, 32'd16, 32'd2);
        gemm_result_address_base_store = 66'd9100;
        gemm_result_generation_store = 8'h2b;
        gemm_result_generation_expected = 8'h2a;
        physical_writes = 0;
        @(negedge clk);
        selected_result_valid = 1'b1;
        @(posedge clk);
        #1;
        check_true(profile_result_generation_error,
                   "stale result generation raises typed protocol event");
        check_true(memory_error_latched,
                   "stale result generation fails frontend closed");
        check_true(!(mem_req_valid && mem_req_ready),
                   "stale result generation issues no memory request");
        @(negedge clk);
        selected_result_valid = 1'b0;

        if (failures == 0) begin
            $display(
                "PASS M7 packed memory frontend: checks=%0d packed=146 legacy=162 tail=10 queued_store=16 arb_load_then_store=146+16 stale_gen=1",
                checks
            );
            $finish;
        end
        $fatal(1, "FAIL M7 packed memory frontend: %0d/%0d failed",
               failures, checks);
    end

    initial begin
        repeat (12000) @(posedge clk);
        $fatal(1, "Timeout in tb_m7_packed_memory_frontend");
    end

endmodule
