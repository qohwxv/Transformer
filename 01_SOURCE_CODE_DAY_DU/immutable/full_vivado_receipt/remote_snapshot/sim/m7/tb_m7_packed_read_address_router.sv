`timescale 1ns/1ps

// Focused package-v3 packed-B address-contract regression.
//
// R8/C2/K16 fixes the physical gather slots at:
//   A      0..127
//   B-v3 128..143 (one {col1,col0} FP16 pair per K lane)
//   bias  144..145
// Legacy blocked-v2 keeps B at 128..159 and bias at 160..161.
module tb_m7_packed_read_address_router;

    import vit_phase_e_pkg::*;

    localparam integer ARRAY_ROWS = 8;
    localparam integer ARRAY_COLS = 2;
    localparam integer PE_LANES = 16;
    localparam integer VECTOR_LANES = 16;
    localparam integer A_WORDS = ARRAY_ROWS * PE_LANES;
    localparam integer B_V2_WORDS = ARRAY_COLS * PE_LANES;
    localparam integer B_V3_WORDS =
        ((ARRAY_COLS + 1) / 2) * PE_LANES;

    phase_e_cmd_t active_cmd = '0;
    logic [15:0] word_index = '0;
    logic [31:0] gemm_token_base = '0;
    logic [31:0] gemm_output_base = '0;
    logic [31:0] gemm_k_base = '0;
    logic [65:0] gemm_activation_address_base = '0;
    logic [65:0] gemm_weight_address_base = '0;
    logic [65:0] gemm_bias_address_base = '0;
    logic [31:0] vector_element_base = '0;
    logic [31:0] layout_source_address = '0;
    logic [1:0] ln_data_pass = '0;
    logic [31:0] ln_data_index = '0;
    logic [31:0] ln_data_channel_index = '0;
    logic [31:0] softmax_data_index = '0;
    logic [31:0] gelu_data_base_index = '0;
    logic [VECTOR_LANES-1:0] gelu_data_lane_mask = '0;
    logic [31:0] argmax_element_index = '0;

    logic candidate_needed;
    phase_e_mem_space_t candidate_space;
    logic [31:0] candidate_address;
    logic candidate_address_overflow;
    logic candidate_read_ahead_safe;
    logic [5:0] candidate_contiguous_words;

    integer checks = 0;
    integer failures = 0;
    integer lane;

    vit_phase_e_read_address_router #(
        .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .PE_LANES(PE_LANES),
        .VECTOR_LANES(VECTOR_LANES)
    ) dut (
        .active_cmd(active_cmd),
        .word_index(word_index),
        .gemm_token_base(gemm_token_base),
        .gemm_output_base(gemm_output_base),
        .gemm_k_base(gemm_k_base),
        .gemm_activation_address_base(gemm_activation_address_base),
        .gemm_weight_address_base(gemm_weight_address_base),
        .gemm_bias_address_base(gemm_bias_address_base),
        .vector_element_base(vector_element_base),
        .layout_source_address(layout_source_address),
        .ln_data_pass(ln_data_pass),
        .ln_data_index(ln_data_index),
        .ln_data_channel_index(ln_data_channel_index),
        .softmax_data_index(softmax_data_index),
        .gelu_data_base_index(gelu_data_base_index),
        .gelu_data_lane_mask(gelu_data_lane_mask),
        .argmax_element_index(argmax_element_index),
        .candidate_needed(candidate_needed),
        .candidate_space(candidate_space),
        .candidate_address(candidate_address),
        .candidate_address_overflow(candidate_address_overflow),
        .candidate_read_ahead_safe(candidate_read_ahead_safe),
        .candidate_contiguous_words(candidate_contiguous_words)
    );

    task automatic check_true(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $error(
                    "%s idx=%0d needed=%0b addr=%08x safe=%0b contiguous=%0d",
                    message,
                    word_index,
                    candidate_needed,
                    candidate_address,
                    candidate_read_ahead_safe,
                    candidate_contiguous_words
                );
            end
        end
    endtask

    task automatic configure_packed(
        input logic [31:0] reduction,
        input logic [31:0] outputs
    );
        begin
            active_cmd = '0;
            active_cmd.header.opcode = PHASE_E_OP_GEMM;
            active_cmd.header.flags =
                PHASE_E_FLAG_BIAS_ENABLE |
                PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2 |
                PHASE_E_FLAG_GEMM_B_FP16_PACKED2;
            active_cmd.route.src0_space = PHASE_E_MEM_INPUT;
            active_cmd.route.src1_space = PHASE_E_MEM_PARAM;
            active_cmd.route.src2_space = PHASE_E_MEM_PARAM;
            active_cmd.dim1 = 32'd8;
            active_cmd.dim2 = reduction;
            active_cmd.dim3 = outputs;
            active_cmd.stride1 = reduction;
            active_cmd.stride3 =
                ((reduction + PE_LANES - 1) / PE_LANES) * B_V3_WORDS;
        end
    endtask

    initial begin
        // Exact packed block: 16 sequential words and decreasing read-ahead
        // extent.  A block beginning at word 1008 ends exactly at the 4 KiB
        // boundary (word 1023), never crossing it.
        configure_packed(32'd16, 32'd2);
        gemm_weight_address_base = 66'd1008;
        for (lane = 0; lane < PE_LANES; lane = lane + 1) begin
            word_index = 16'(A_WORDS + lane);
            #1;
            check_true(candidate_needed, "packed full tile lane needed");
            check_true(candidate_space == PHASE_E_MEM_PARAM,
                       "packed B remains in PARAM");
            check_true(candidate_address == 32'(1008 + lane),
                       "packed B address is one word per lane");
            check_true(!candidate_address_overflow,
                       "packed boundary address does not overflow");
            check_true(candidate_read_ahead_safe,
                       "packed PARAM B permits read-ahead");
            check_true(candidate_contiguous_words == 6'(16 - lane),
                       "packed read-ahead extent reaches block end");
            check_true(candidate_address[31:10] == 22'd0,
                       "packed 64-byte block stays in one 4 KiB page");
        end
        check_true(candidate_address == 32'd1023,
                   "packed block ends at word 1023");

        // The next K16 chunk begins at the next page and preserves one-word
        // addressing per physical packed lane.
        gemm_k_base = 32'd16;
        gemm_weight_address_base = 66'd1024;
        word_index = 16'(A_WORDS);
        #1;
        check_true(candidate_address == 32'd1024,
                   "next packed K chunk starts on next 4 KiB page");

        // K=17 tail: only lane zero is a semantic read.  N=3/output_base=2
        // proves a valid first column with a padded second half in each word.
        configure_packed(32'd17, 32'd3);
        gemm_output_base = 32'd2;
        gemm_k_base = 32'd16;
        gemm_weight_address_base = 66'd4096;
        for (lane = 0; lane < PE_LANES; lane = lane + 1) begin
            word_index = 16'(A_WORDS + lane);
            #1;
            check_true(candidate_needed == (lane == 0),
                       "packed K tail suppresses invalid lanes");
            check_true(candidate_address == 32'(4096 + lane),
                       "packed K-tail address remains contiguous");
            if (lane == 0) begin
                check_true(candidate_read_ahead_safe,
                           "valid packed tail lane permits line fill");
                check_true(candidate_contiguous_words == 6'd16,
                           "tail line fill is clamped by packed block");
            end
        end

        // An output tile wholly beyond N requests no packed word.
        gemm_output_base = 32'd4;
        for (lane = 0; lane < PE_LANES; lane = lane + 1) begin
            word_index = 16'(A_WORDS + lane);
            #1;
            check_true(!candidate_needed,
                       "packed output tail suppresses whole pair");
        end

        // Speculation is fail-closed for scratch-resident B.
        gemm_output_base = 32'd0;
        gemm_k_base = 32'd0;
        active_cmd.dim2 = 32'd16;
        active_cmd.dim3 = 32'd2;
        active_cmd.route.src1_space = PHASE_E_MEM_SCRATCH;
        word_index = 16'(A_WORDS);
        #1;
        check_true(candidate_needed, "scratch packed word remains demanded");
        check_true(!candidate_read_ahead_safe,
                   "scratch packed-B read-ahead is disabled");
        check_true(candidate_contiguous_words == 6'd1,
                   "scratch fallback exposes one word");

        // Bias begins immediately after physical packed storage: 144/145.
        active_cmd.route.src1_space = PHASE_E_MEM_PARAM;
        gemm_bias_address_base = 66'd7000;
        gemm_k_base = 32'd0;
        word_index = 16'(A_WORDS + B_V3_WORDS);
        #1;
        check_true(candidate_needed, "packed bias column zero is needed");
        check_true(candidate_address == 32'd7000,
                   "packed bias index 144 maps to column zero");
        word_index = 16'(A_WORDS + B_V3_WORDS + 1);
        #1;
        check_true(candidate_needed, "packed bias column one is needed");
        check_true(candidate_address == 32'd7001,
                   "packed bias index 145 maps to column one");

        // Clearing only packed2 restores the exact blocked-v2 seam.
        active_cmd.header.flags =
            PHASE_E_FLAG_BIAS_ENABLE |
            PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2;
        gemm_weight_address_base = 66'd8000;
        word_index = 16'(A_WORDS + B_V2_WORDS - 1);
        #1;
        check_true(candidate_address == 32'd8031,
                   "legacy blocked-v2 retains 32-word B block");
        word_index = 16'(A_WORDS + B_V2_WORDS);
        #1;
        check_true(candidate_address == 32'd7000,
                   "legacy bias index 160 maps to column zero");
        word_index = 16'(A_WORDS + B_V2_WORDS + 1);
        #1;
        check_true(candidate_address == 32'd7001,
                   "legacy bias index 161 maps to column one");

        // A 66-bit base must report overflow rather than truncate silently.
        active_cmd.header.flags =
            PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2 |
            PHASE_E_FLAG_GEMM_B_FP16_PACKED2;
        gemm_weight_address_base = 66'h1_0000_0000;
        word_index = 16'(A_WORDS);
        #1;
        check_true(candidate_address_overflow,
                   "packed address overflow is reported");

        if (failures == 0) begin
            $display(
                "PASS M7 packed read router: checks=%0d R8/A=%0d Bv3=%0d Bv2=%0d",
                checks,
                A_WORDS,
                B_V3_WORDS,
                B_V2_WORDS
            );
            $finish;
        end
        $fatal(1, "FAIL M7 packed read router: %0d/%0d failed",
               failures, checks);
    end

endmodule
