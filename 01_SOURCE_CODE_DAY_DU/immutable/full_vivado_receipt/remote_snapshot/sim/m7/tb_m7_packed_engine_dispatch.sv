`timescale 1ns/1ps

// Proves that the production dispatch count matches the physical gather
// seam: R8 A=128, packed-v3 B=16, bias=2 -> 146 words; blocked-v2 B=32
// -> 162 words.  This is deliberately independent of the frontend test.
module tb_m7_packed_engine_dispatch;

    import vit_phase_e_pkg::*;

    phase_e_cmd_t active_cmd = '0;
    logic launch = 1'b0;
    logic memory_error_latched = 1'b0;
    logic gemm_done = 1'b0;
    logic gemm_config_error = 1'b0;
    logic gemm_data_request = 1'b0;
    logic gemm_result_valid = 1'b0;
    logic vector_done = 1'b0;
    logic vector_config_error = 1'b0;
    logic vector_data_request = 1'b0;
    logic vector_result_valid = 1'b0;
    logic layout_done = 1'b0;
    logic layout_config_error = 1'b0;
    logic layout_data_request = 1'b0;
    logic layout_result_valid = 1'b0;
    logic ln_done = 1'b0;
    logic ln_config_error = 1'b0;
    logic ln_data_request = 1'b0;
    logic ln_result_valid = 1'b0;
    logic softmax_done = 1'b0;
    logic softmax_config_error = 1'b0;
    logic softmax_data_request = 1'b0;
    logic softmax_result_valid = 1'b0;
    logic gelu_done = 1'b0;
    logic gelu_config_error = 1'b0;
    logic gelu_data_request = 1'b0;
    logic gelu_result_valid = 1'b0;
    logic argmax_done = 1'b0;
    logic argmax_config_error = 1'b0;
    logic argmax_nonfinite_error = 1'b0;
    logic argmax_data_request = 1'b0;
    logic argmax_result_valid = 1'b0;
    logic gemm_start;
    logic vector_start;
    logic layout_start;
    logic ln_start;
    logic softmax_start;
    logic gelu_start;
    logic argmax_start;
    logic selected_done;
    logic selected_error;
    logic selected_data_request;
    logic selected_result_valid;
    logic [15:0] read_word_count;
    logic [15:0] write_word_count;
    logic [1:0] vector_engine_mode;

    integer checks = 0;
    integer failures = 0;

    vit_phase_e_engine_dispatch #(
        .ARRAY_ROWS(8),
        .ARRAY_COLS(2),
        .PE_LANES(16),
        .VECTOR_LANES(16)
    ) dut (.*);

    task automatic check_true(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $error("%s read=%0d write=%0d", message,
                       read_word_count, write_word_count);
            end
        end
    endtask

    initial begin
        active_cmd = '0;
        active_cmd.header.opcode = PHASE_E_OP_GEMM;
        active_cmd.header.flags = PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2;
        #1;
        check_true(read_word_count == 16'd162,
                   "legacy R8 blocked-v2 gather remains 162 words");
        check_true(write_word_count == 16'd16,
                   "R8/C2 GEMM result remains 16 words");

        active_cmd.header.flags =
            PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2 |
            PHASE_E_FLAG_GEMM_B_FP16_PACKED2;
        #1;
        check_true(read_word_count == 16'd146,
                   "packed-v3 R8 gather is 146 words");
        check_true(write_word_count == 16'd16,
                   "packed-v3 does not change result count");

        launch = 1'b1;
        #1;
        check_true(gemm_start, "packed-v3 GEMM launch reaches GEMM only");
        check_true(!(vector_start || layout_start || ln_start ||
                     softmax_start || gelu_start || argmax_start),
                   "packed-v3 flag does not perturb opcode decode");
        launch = 1'b0;

        active_cmd.header.opcode = PHASE_E_OP_VECTOR;
        active_cmd.header.flags = PHASE_E_FLAG_GEMM_B_FP16_PACKED2;
        #1;
        check_true(read_word_count == 16'd32,
                   "packed flag does not alter vector read count");
        check_true(write_word_count == 16'd16,
                   "packed flag does not alter vector write count");

        if (failures == 0) begin
            $display("PASS M7 packed engine dispatch: checks=%0d", checks);
            $finish;
        end
        $fatal(1, "FAIL M7 packed engine dispatch: %0d/%0d failed",
               failures, checks);
    end

endmodule
