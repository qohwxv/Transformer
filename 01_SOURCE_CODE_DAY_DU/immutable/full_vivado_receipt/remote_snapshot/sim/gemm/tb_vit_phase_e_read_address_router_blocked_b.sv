`timescale 1ns/1ps

// Leaf regression for the M3 GEMM-B address permutation.
//
// The address context supplies the base of the current output tile/K chunk.
// This test proves that the router preserves legacy row-major addressing when
// flag 0x20 is clear and emits [COL][LANE] order when it is set.  It also
// proves that K16/N2 tails suppress invalid reads, address overflow is not
// truncated silently, and one 32-word block respects a 4 KiB boundary.
module tb_vit_phase_e_read_address_router_blocked_b;

    import vit_phase_e_pkg::*;

    localparam integer ARRAY_ROWS = 2;
    localparam integer ARRAY_COLS = 2;
    localparam integer PE_LANES = 16;
    localparam integer VECTOR_LANES = 16;
    localparam integer GEMM_A_WORDS = ARRAY_ROWS * PE_LANES;

    phase_e_cmd_t active_cmd = '0;
    logic [15:0] word_index = 16'd0;
    logic [31:0] gemm_token_base = 32'd0;
    logic [31:0] gemm_output_base = 32'd0;
    logic [31:0] gemm_k_base = 32'd0;
    logic [65:0] gemm_activation_address_base = 66'd0;
    logic [65:0] gemm_weight_address_base = 66'd0;
    logic [65:0] gemm_bias_address_base = 66'd0;
    logic [31:0] vector_element_base = 32'd0;
    logic [31:0] layout_source_address = 32'd0;
    logic [1:0] ln_data_pass = 2'd0;
    logic [31:0] ln_data_index = 32'd0;
    logic [31:0] ln_data_channel_index = 32'd0;
    logic [31:0] softmax_data_index = 32'd0;
    logic [31:0] gelu_data_base_index = 32'd0;
    logic [VECTOR_LANES-1:0] gelu_data_lane_mask = '0;
    logic [31:0] argmax_element_index = 32'd0;

    logic candidate_needed;
    phase_e_mem_space_t candidate_space;
    logic [31:0] candidate_address;
    logic candidate_address_overflow;
    logic candidate_read_ahead_safe;
    logic [5:0] candidate_contiguous_words;

    integer checks = 0;
    integer failures = 0;
    integer tail_cases = 0;
    integer mode_cases = 0;

    vit_phase_e_read_address_router #(
        .ARRAY_ROWS   (ARRAY_ROWS),
        .ARRAY_COLS   (ARRAY_COLS),
        .PE_LANES     (PE_LANES),
        .VECTOR_LANES (VECTOR_LANES)
    ) dut (
        .active_cmd                    (active_cmd),
        .word_index                    (word_index),
        .gemm_token_base               (gemm_token_base),
        .gemm_output_base              (gemm_output_base),
        .gemm_k_base                   (gemm_k_base),
        .gemm_activation_address_base  (gemm_activation_address_base),
        .gemm_weight_address_base      (gemm_weight_address_base),
        .gemm_bias_address_base        (gemm_bias_address_base),
        .vector_element_base           (vector_element_base),
        .layout_source_address         (layout_source_address),
        .ln_data_pass                  (ln_data_pass),
        .ln_data_index                 (ln_data_index),
        .ln_data_channel_index         (ln_data_channel_index),
        .softmax_data_index            (softmax_data_index),
        .gelu_data_base_index          (gelu_data_base_index),
        .gelu_data_lane_mask           (gelu_data_lane_mask),
        .argmax_element_index          (argmax_element_index),
        .candidate_needed              (candidate_needed),
        .candidate_space               (candidate_space),
        .candidate_address             (candidate_address),
        .candidate_address_overflow    (candidate_address_overflow),
        .candidate_read_ahead_safe     (candidate_read_ahead_safe),
        .candidate_contiguous_words    (candidate_contiguous_words)
    );

    task automatic check(
        input logic condition,
        input string message
    );
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $error(
                    {
                        "%s: word=%0d output=%0d k=%0d needed=%0b ",
                        "space=%0d address=%08x overflow=%0b"
                    },
                    message,
                    word_index,
                    gemm_output_base,
                    gemm_k_base,
                    candidate_needed,
                    candidate_space,
                    candidate_address,
                    candidate_address_overflow
                );
            end
        end
    endtask

    task automatic configure_gemm(
        input logic blocked_mode,
        input logic [31:0] reduction,
        input logic [31:0] outputs,
        input logic [31:0] row_or_tile_stride
    );
        begin
            active_cmd = '0;
            active_cmd.header.opcode = PHASE_E_OP_GEMM;
            active_cmd.header.flags = PHASE_E_FLAG_BIAS_ENABLE;
            if (blocked_mode)
                active_cmd.header.flags =
                    active_cmd.header.flags |
                    PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2;
            active_cmd.route.src0_space = PHASE_E_MEM_INPUT;
            active_cmd.route.src1_space = PHASE_E_MEM_PARAM;
            active_cmd.route.src2_space = PHASE_E_MEM_PARAM;
            active_cmd.dim1 = 32'd8;
            active_cmd.dim2 = reduction;
            active_cmd.dim3 = outputs;
            active_cmd.stride1 = reduction + 32'd3;
            active_cmd.stride3 = row_or_tile_stride;
        end
    endtask

    task automatic check_b_slot(
        input integer col,
        input integer lane,
        input logic blocked_mode,
        input logic expected_needed,
        input logic [65:0] expected_address_wide
    );
        begin
            word_index = GEMM_A_WORDS + col * PE_LANES + lane;
            #1;
            check(
                candidate_needed == expected_needed,
                "B tail valid mask"
            );
            check(
                candidate_space == PHASE_E_MEM_PARAM,
                "B route remains parameter memory"
            );
            check(
                candidate_address == expected_address_wide[31:0],
                blocked_mode ?
                    "blocked [COL][LANE] address" :
                    "legacy row-major address"
            );
            check(
                candidate_address_overflow ==
                    (|expected_address_wide[65:32]),
                "B address overflow flag"
            );
            check(
                candidate_read_ahead_safe ==
                    (blocked_mode && expected_needed &&
                     !(|expected_address_wide[65:32])),
                "read-ahead is restricted to valid blocked PARAM B"
            );
            check(
                candidate_contiguous_words ==
                    ((blocked_mode && expected_needed &&
                      !(|expected_address_wide[65:32])) ?
                        6'(ARRAY_COLS * PE_LANES -
                           (col * PE_LANES + lane)) : 6'd1),
                "read-ahead contiguous-word tail"
            );
        end
    endtask

    task automatic run_tail_case(
        input logic blocked_mode,
        input logic [31:0] reduction,
        input logic [31:0] outputs,
        input logic [31:0] output_start,
        input logic [31:0] k_start,
        input logic [65:0] chunk_base
    );
        integer col;
        integer lane;
        logic needed_value;
        logic [65:0] expected_address_wide;
        logic [31:0] stride_value;
        begin
            if (blocked_mode)
                stride_value =
                    ((reduction + PE_LANES - 1) / PE_LANES) *
                    ARRAY_COLS * PE_LANES;
            else
                stride_value = outputs + 32'd5;

            configure_gemm(
                blocked_mode,
                reduction,
                outputs,
                stride_value
            );
            gemm_output_base = output_start;
            gemm_k_base = k_start;
            gemm_weight_address_base = chunk_base;
            #1;

            for (col = 0; col < ARRAY_COLS; col = col + 1)
                for (lane = 0; lane < PE_LANES; lane = lane + 1) begin
                    needed_value =
                        ((output_start + col) < outputs) &&
                        ((k_start + lane) < reduction);
                    if (blocked_mode)
                        expected_address_wide =
                            chunk_base + col * PE_LANES + lane;
                    else
                        expected_address_wide =
                            chunk_base + lane * stride_value + col;
                    check_b_slot(
                        col,
                        lane,
                        blocked_mode,
                        needed_value,
                        expected_address_wide
                    );
                end

            tail_cases = tail_cases + 1;
            mode_cases = mode_cases + 1;
        end
    endtask

    integer slot;

    initial begin
        // Legacy and blocked modes see identical logical tail masks, while
        // selecting different physical addresses.
        run_tail_case(1'b0, 32'd1,  32'd1, 32'd0,  32'd0, 66'd1000);
        run_tail_case(1'b1, 32'd1,  32'd1, 32'd0,  32'd0, 66'd2000);
        run_tail_case(1'b0, 32'd16, 32'd2, 32'd0,  32'd0, 66'd3000);
        run_tail_case(1'b1, 32'd16, 32'd2, 32'd0,  32'd0, 66'd4000);
        run_tail_case(1'b0, 32'd17, 32'd3, 32'd0, 32'd16, 66'd5000);
        run_tail_case(1'b1, 32'd17, 32'd3, 32'd0, 32'd16, 66'd6000);
        run_tail_case(1'b0, 32'd17, 32'd3, 32'd2,  32'd0, 66'd7000);
        run_tail_case(1'b1, 32'd17, 32'd3, 32'd2,  32'd0, 66'd8000);
        run_tail_case(1'b0, 32'd31, 32'd3, 32'd0, 32'd16, 66'd9000);
        run_tail_case(1'b1, 32'd31, 32'd3, 32'd0, 32'd16, 66'd10000);

        // Flag 0x20 must not alter A or bias addressing.
        configure_gemm(1'b0, 32'd17, 32'd3, 32'd3);
        gemm_token_base = 32'd7;
        gemm_k_base = 32'd16;
        gemm_output_base = 32'd2;
        gemm_activation_address_base = 66'd12000;
        gemm_bias_address_base = 66'd13000;
        word_index = 16'd0;
        #1;
        check(candidate_address == 32'd12000, "row-major A base");
        check(!candidate_read_ahead_safe, "A never enables read-ahead");
        active_cmd.header.flags =
            active_cmd.header.flags |
            PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2;
        #1;
        check(candidate_address == 32'd12000, "blocked mode preserves A base");
        check(!candidate_read_ahead_safe, "blocked flag does not prefetch A");
        word_index = GEMM_A_WORDS + ARRAY_COLS * PE_LANES;
        #1;
        check(candidate_address == 32'd13000, "blocked mode preserves bias");
        check(!candidate_read_ahead_safe, "bias never enables read-ahead");

        // The same blocked flag is not sufficient for scratch-resident QK/PV
        // matrices: only immutable package-v2 PARAM data may be speculated.
        word_index = GEMM_A_WORDS;
        active_cmd.route.src1_space = PHASE_E_MEM_SCRATCH;
        #1;
        check(!candidate_read_ahead_safe,
              "scratch blocked-B route is fail-closed");
        check(candidate_contiguous_words == 6'd1,
              "scratch fallback advertises one word");

        // The block at word offset 992 occupies byte offsets 3968..4095.
        // All 32 words stay on one page; the next chunk begins at word 1024.
        configure_gemm(1'b1, 32'd32, 32'd2, 32'd64);
        gemm_output_base = 32'd0;
        gemm_k_base = 32'd0;
        gemm_weight_address_base = 66'd992;
        for (slot = 0; slot < ARRAY_COLS * PE_LANES;
             slot = slot + 1) begin
            word_index = GEMM_A_WORDS + slot;
            #1;
            check(candidate_needed, "4 KiB block slot is valid");
            check(
                candidate_address[31:10] == 22'd0,
                "32-word block does not cross 4 KiB page"
            );
        end
        check(candidate_address == 32'd1023, "block ends at word 1023");
        gemm_k_base = 32'd16;
        gemm_weight_address_base = 66'd1024;
        word_index = GEMM_A_WORDS;
        #1;
        check(candidate_address == 32'd1024, "next block starts at word 1024");

        // Overflow is reported for both legacy and blocked permutations.
        configure_gemm(1'b0, 32'd16, 32'd2, 32'd16);
        gemm_weight_address_base = 66'h0_ffff_fff8;
        gemm_output_base = 32'd0;
        gemm_k_base = 32'd0;
        check_b_slot(0, 1, 1'b0, 1'b1, 66'h1_0000_0008);

        configure_gemm(1'b1, 32'd16, 32'd2, 32'd32);
        gemm_weight_address_base = 66'h0_ffff_fff0;
        check_b_slot(1, 15, 1'b1, 1'b1, 66'h1_0000_000f);

        gemm_weight_address_base = 66'h1_0000_0000;
        check_b_slot(0, 0, 1'b1, 1'b1, 66'h1_0000_0000);

        if (failures == 0) begin
            $display(
                "PASS vit_phase_e_read_address_router_blocked_b: %0d checks, %0d dual-mode tail cases",
                checks,
                tail_cases
            );
            $finish;
        end

        $fatal(
            1,
            "FAIL vit_phase_e_read_address_router_blocked_b: %0d/%0d failed",
            failures,
            checks
        );
    end

endmodule
