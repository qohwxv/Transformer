`timescale 1ns/1ps

// Compile-time specialization gate for the production M7-S8 GEMM.  The
// default-parameter testbench remains separate and continues to compare the
// legacy FP32 path against vit_gemm_tree_array cycle for cycle.
module tb_vit_gemm_dual_mode_array_fp16_only;
    localparam integer ARRAY_ROWS = 8;
    localparam integer ARRAY_COLS = 2;
    localparam integer PE_LANES = 16;
    localparam integer FP16_STREAMS = 8;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic start;
    logic [31:0] cfg_m;
    logic [31:0] cfg_k;
    logic [31:0] cfg_n;
    logic [31:0] cfg_batch_count;
    logic cfg_bias_enable;
    logic cfg_fp16_enable;
    logic cfg_weight_fp16_packed2;
    logic busy;
    logic done;
    logic config_error;
    logic data_request;
    logic data_valid;
    logic [31:0] token_base;
    logic [31:0] output_base;
    logic [31:0] k_base;
    logic [31:0] batch_index;
    logic [ARRAY_ROWS*PE_LANES*32-1:0] activation_data;
    logic [ARRAY_COLS*PE_LANES*32-1:0] weight_data;
    logic [ARRAY_COLS*32-1:0] bias_data;
    logic [65:0] result_address_base_i;
    logic [7:0] result_generation_i;
    logic result_valid;
    logic result_ready;
    logic [65:0] result_address_base_o;
    logic [7:0] result_generation_o;
    logic [31:0] result_token_base;
    logic [31:0] result_output_base;
    logic [31:0] result_batch_index;
    logic [ARRAY_ROWS-1:0] result_token_mask;
    logic [ARRAY_COLS-1:0] result_output_mask;
    logic [ARRAY_ROWS*ARRAY_COLS*32-1:0] result_data;
    logic [31:0] mul_operand_a;
    logic [31:0] mul_operand_b;
    logic [31:0] external_mul_result;
    logic [31:0] add_operand_a;
    logic [31:0] add_operand_b;
    logic [31:0] external_add_result;
    logic profile_gemm_tile_step_o;
    logic [15:0] profile_valid_mac_delta_o;
    logic [15:0] profile_tail_mac_delta_o;
    logic [4:0] profile_m7_term_accept_delta_o;
    logic [4:0] profile_m7_disabled_term_delta_o;
    logic profile_m7_input_wait_o;
    logic profile_m7_term_stall_o;
    logic profile_m7_result_backpressure_o;
    logic profile_m7_compute_active_o;
    logic profile_m7_dot_start_o;
    logic profile_m7_result_vector_o;
    logic [4:0] profile_m7_invalid_delta_o;
    logic [4:0] profile_m7_overflow_delta_o;
    logic [4:0] profile_m7_length_error_delta_o;
    logic [4:0] profile_m7_subnormal_flushed_delta_o;
    logic profile_m7_panel_load_active_o;
    logic profile_m7_panel_compute_active_o;
    logic profile_m7_panel_commit_o;
    logic profile_m7_panel_claim_o;
    logic [1:0] profile_m7_panel_claim_mask_o;
    logic profile_m7_panel_release_o;
    logic profile_m7_panel_empty_stall_o;
    logic profile_m7_panel_full_stall_o;
    logic [1:0] profile_m7_panel_occupancy_o;
    logic profile_m7_result_fifo_enqueue_o;
    logic profile_m7_result_fifo_dequeue_o;
    logic profile_m7_result_fifo_full_stall_o;
    logic [1:0] profile_m7_result_fifo_occupancy_o;

    integer checks = 0;
    integer errors = 0;
    integer row;
    integer col;
    integer lane;
    integer request_cycles;
    integer result_handshakes;

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (!condition) begin
                errors = errors + 1;
                $display("FAIL: %s", message);
            end
        end
    endtask

    task automatic pulse_start;
        begin
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    function automatic logic [31:0] fp32_weight(
        input integer column
    );
        begin
            fp32_weight = (column == 0) ? 32'h3f80_0000 :
                                         32'h4000_0000;
        end
    endfunction

    function automatic logic [15:0] fp16_weight(
        input integer column
    );
        begin
            fp16_weight = (column == 0) ? 16'h3c00 : 16'h4000;
        end
    endfunction

    always_comb begin
        activation_data = '0;
        weight_data = '0;
        bias_data = '0;
        for (row = 0; row < ARRAY_ROWS; row = row + 1)
            for (lane = 0; lane < PE_LANES; lane = lane + 1)
                activation_data[(row*PE_LANES+lane)*32 +: 32] =
                    32'h3f80_0000;

        if (cfg_weight_fp16_packed2) begin
            for (lane = 0; lane < PE_LANES; lane = lane + 1) begin
                weight_data[lane*32 +: 16] = fp16_weight(0);
                weight_data[lane*32+16 +: 16] = fp16_weight(1);
                // Packed mode must ignore the unused upper half.
                weight_data[(PE_LANES+lane)*32 +: 32] = 32'h7fc0_0000;
            end
        end else begin
            for (col = 0; col < ARRAY_COLS; col = col + 1)
                for (lane = 0; lane < PE_LANES; lane = lane + 1)
                    weight_data[(col*PE_LANES+lane)*32 +: 32] =
                        fp32_weight(col);
        end
    end

    assign data_valid = data_request;
    assign external_mul_result = 32'd0;
    assign external_add_result = 32'd0;

    vit_gemm_dual_mode_array #(
        .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .PE_LANES(PE_LANES),
        .FP16_STREAMS(FP16_STREAMS),
        .USE_EXTERNAL_MUL(1),
        .USE_EXTERNAL_ADD(1),
        .INCLUDE_LEGACY_GEMM(0)
    ) u_dut (.*);

    always_ff @(posedge clk) begin
        if (rst) begin
            request_cycles <= 0;
            result_handshakes <= 0;
        end else begin
            if (data_request)
                request_cycles <= request_cycles + 1;
            if (result_valid && result_ready)
                result_handshakes <= result_handshakes + 1;
        end
    end

    task automatic reject_non_fp16(input logic packed2);
        integer requests_before;
        integer results_before;
        begin
            requests_before = request_cycles;
            results_before = result_handshakes;
            cfg_fp16_enable = 1'b0;
            cfg_weight_fp16_packed2 = packed2;
            result_ready = 1'b1;
            pulse_start();
            wait (done === 1'b1);
            #1;
            check(busy && done && config_error,
                  "FP16-only build rejects non-FP16 start");
            check(u_dut.legacy_unavailable_q,
                  "compile-time legacy-unavailable rejection is active");
            check(!data_request && !result_valid,
                  "rejected non-FP16 start launches no traffic/result");
            check((request_cycles == requests_before) &&
                  (result_handshakes == results_before),
                  "rejected non-FP16 start has zero observed handshakes");
            @(posedge clk);
            #1;
            check(!busy && !done && !config_error,
                  "non-FP16 rejection is a bounded one-cycle pulse");
        end
    endtask

    task automatic run_fp16_mode(input logic packed2, input string label);
        integer pass;
        integer rr;
        integer requests_before;
        integer results_before;
        logic [1:0] expected_mask;
        logic [31:0] expected_word;
        begin
            requests_before = request_cycles;
            results_before = result_handshakes;
            cfg_fp16_enable = 1'b1;
            cfg_weight_fp16_packed2 = packed2;
            result_ready = 1'b0;
            pulse_start();
            for (pass = 0; pass < 2; pass = pass + 1) begin
                wait (result_valid === 1'b1);
                #1;
                expected_mask = pass ? 2'b10 : 2'b01;
                expected_word = pass ? 32'h4200_0000 : 32'h4180_0000;
                check(result_token_mask == 8'hff,
                      {label, " token mask"});
                check(result_output_mask == expected_mask,
                      {label, " S8 output mask/order"});
                check(result_address_base_o == result_address_base_i,
                      {label, " result address metadata"});
                check(result_generation_o == result_generation_i,
                      {label, " result generation metadata"});
                for (rr = 0; rr < ARRAY_ROWS; rr = rr + 1)
                    if (!pass)
                        check(result_data[(rr*2)*32 +: 32] == expected_word,
                              {label, " column-0 result"});
                    else
                        check(result_data[(rr*2+1)*32 +: 32] == expected_word,
                              {label, " column-1 result"});
                result_ready = 1'b1;
                @(posedge clk);
                #1;
                result_ready = 1'b0;
            end
            wait (done === 1'b1);
            #1;
            check(!config_error, {label, " completes cleanly"});
            check(request_cycles > requests_before,
                  {label, " performs nonvacuous operand traffic"});
            check(result_handshakes == (results_before + 2),
                  {label, " produces exactly two S8 result handshakes"});
            @(posedge clk);
            #1;
            check(!busy && !done, {label, " returns to idle"});
        end
    endtask

    initial begin
        start = 1'b0;
        cfg_m = 32'd8;
        cfg_k = 32'd16;
        cfg_n = 32'd2;
        cfg_batch_count = 32'd1;
        cfg_bias_enable = 1'b0;
        cfg_fp16_enable = 1'b0;
        cfg_weight_fp16_packed2 = 1'b0;
        result_address_base_i = 66'h2_3456_789a;
        result_generation_i = 8'h5a;
        result_ready = 1'b0;

        repeat (4) @(posedge clk);
        rst = 1'b0;

        // Both legal legacy encodings must fail closed when the production
        // compile-time specialization has removed the tree datapath.
        reject_non_fp16(1'b0);
        reject_non_fp16(1'b1);

        // Mode 3 (packed-v3 storage) and mode 5 (FP32 storage converted at
        // the seam) must remain functional with the same FP16 arithmetic.
        run_fp16_mode(1'b1, "mode3 packed FP16-only");
        run_fp16_mode(1'b0, "mode5 compatibility FP16-only");

        if (errors == 0)
            $display("PASS M7 FP16-only GEMM checks=%0d", checks);
        else
            $fatal(1, "FAIL M7 FP16-only GEMM errors=%0d checks=%0d",
                   errors, checks);
        $finish;
    end

    initial begin
        #1_000_000;
        $fatal(1, "timeout in M7 FP16-only GEMM test");
    end
endmodule
