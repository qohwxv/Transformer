`timescale 1ns/1ps

module tb_vit_fp32_add_feedforward_ab;

    localparam integer RANDOM_VECTOR_COUNT = 8192;

    logic [31:0] a;
    logic [31:0] b;
    logic [31:0] dut_result;
    logic [31:0] reference_result;

    integer checks;
    integer failures;
    integer directed_checks;
    integer expected_checks;
    integer random_checks;
    integer random_index;
    logic [31:0] random_state_a;
    logic [31:0] random_state_b;

    vit_fp32_add_comb u_dut (
        .a      (a),
        .b      (b),
        .result (dut_result)
    );

    vit_fp32_add_package_reference u_reference (
        .a      (a),
        .b      (b),
        .result (reference_result)
    );

    function automatic logic [31:0] next_xorshift32(
        input logic [31:0] state
    );
        logic [31:0] next_state;
        begin
            next_state = state ^ (state << 13);
            next_state = next_state ^ (next_state >> 17);
            next_state = next_state ^ (next_state << 5);
            next_xorshift32 = next_state;
        end
    endfunction

    task automatic report_failure(
        input string       category,
        input logic [31:0] input_a,
        input logic [31:0] input_b,
        input logic [31:0] expected,
        input logic [31:0] actual
    );
        begin
            failures = failures + 1;
            if (failures <= 24)
                $display(
                    "FAIL add_ab category=%s a=%08x b=%08x expected=%08x actual=%08x",
                    category, input_a, input_b, expected, actual
                );
        end
    endtask

    task automatic check_ab(
        input logic [31:0] input_a,
        input logic [31:0] input_b,
        input string       category,
        input logic        is_random
    );
        begin
            a = input_a;
            b = input_b;
            #1;
            checks = checks + 1;
            if (is_random)
                random_checks = random_checks + 1;
            else
                directed_checks = directed_checks + 1;
            if (dut_result !== reference_result)
                report_failure(
                    category,
                    input_a,
                    input_b,
                    reference_result,
                    dut_result
                );
        end
    endtask

    task automatic check_expected(
        input logic [31:0] input_a,
        input logic [31:0] input_b,
        input logic [31:0] expected,
        input string       category
    );
        begin
            check_ab(input_a, input_b, category, 1'b0);
            expected_checks = expected_checks + 1;
            checks = checks + 1;
            if (dut_result !== expected)
                report_failure(
                    category,
                    input_a,
                    input_b,
                    expected,
                    dut_result
                );
        end
    endtask

    initial begin
        checks = 0;
        failures = 0;
        directed_checks = 0;
        expected_checks = 0;
        random_checks = 0;
        random_state_a = 32'h6d7a_51c3;
        random_state_b = 32'hc915_28ef;
        a = 32'd0;
        b = 32'd0;

        // Canonical exceptional-value precedence.
        check_expected(32'h7fc0_0001, 32'h3f80_0000,
                       32'h7fc0_0000, "qnan_a");
        check_expected(32'h3f80_0000, 32'h7f80_0001,
                       32'h7fc0_0000, "snan_b");
        check_expected(32'h7f80_0000, 32'hff80_0000,
                       32'h7fc0_0000, "inf_invalid");
        check_expected(32'h7f80_0000, 32'h3f80_0000,
                       32'h7f80_0000, "pos_inf");
        check_expected(32'hff80_0000, 32'h3f80_0000,
                       32'hff80_0000, "neg_inf");
        check_ab(32'hffc1_2345, 32'h7f80_0000, "nan_payload", 1'b0);
        check_ab(32'h7f80_0000, 32'h7fa1_0001, "nan_order", 1'b0);

        // Signed-zero and historical flush-to-zero/subnormal behavior.
        check_expected(32'h0000_0000, 32'h8000_0000,
                       32'h0000_0000, "mixed_zero");
        check_expected(32'h8000_0000, 32'h8000_0000,
                       32'h8000_0000, "negative_zero");
        check_expected(32'h0000_0001, 32'h3f80_0000,
                       32'h3f80_0000, "subnormal_ftz_a");
        check_expected(32'hbf80_0000, 32'h807f_ffff,
                       32'hbf80_0000, "subnormal_ftz_b");
        check_expected(32'h007f_ffff, 32'h0000_0001,
                       32'h0000_0000, "two_subnormals_ftz");
        check_expected(32'h807f_ffff, 32'h8000_0001,
                       32'h8000_0000, "negative_subnormals_ftz");

        // Exact and near cancellation exercises the priority normalizer.
        check_expected(32'h3f80_0000, 32'hbf80_0000,
                       32'h0000_0000, "cancel_one");
        check_expected(32'hbf80_0000, 32'h3f80_0000,
                       32'h0000_0000, "cancel_one_reversed");
        check_expected(32'h7f7f_ffff, 32'hff7f_ffff,
                       32'h0000_0000, "cancel_max");
        check_ab(32'h3f80_0001, 32'hbf80_0000, "near_cancel_pos", 1'b0);
        check_ab(32'hbf80_0001, 32'h3f80_0000, "near_cancel_neg", 1'b0);
        check_ab(32'h0080_0001, 32'h8080_0000, "near_underflow", 1'b0);
        check_ab(32'h4b00_0001, 32'hcb00_0000, "cancel_large_ulp", 1'b0);

        // RNE tie-even/tie-odd, sticky, carry, and overflow boundaries.
        check_expected(32'h3f80_0000, 32'h3380_0000,
                       32'h3f80_0000, "tie_even");
        check_expected(32'h3f80_0001, 32'h3380_0000,
                       32'h3f80_0002, "tie_odd");
        check_expected(32'h3f00_0000, 32'h3f00_0000,
                       32'h3f80_0000, "normalize_carry");
        check_expected(32'h3f80_0000, 32'h3f80_0000,
                       32'h4000_0000, "one_plus_one");
        check_expected(32'hbf80_0000, 32'hbf80_0000,
                       32'hc000_0000, "negative_one_plus_one");
        check_expected(32'h7f7f_ffff, 32'h7f7f_ffff,
                       32'h7f80_0000, "positive_overflow");
        check_expected(32'hff7f_ffff, 32'hff7f_ffff,
                       32'hff80_0000, "negative_overflow");
        check_ab(32'h3f7f_ffff, 32'h3380_0000, "round_to_one", 1'b0);
        check_ab(32'h3f80_0000, 32'h3380_0001, "round_sticky_up", 1'b0);
        check_ab(32'h3f80_0000, 32'h3300_0000, "below_half_ulp", 1'b0);
        check_ab(32'h7f00_0000, 32'h7180_0001, "large_alignment", 1'b0);
        check_ab(32'h0080_0000, 32'h0080_0000, "minimum_normal_sum", 1'b0);

        // Deterministic full-bit-pattern A/B sweep.  This deliberately keeps
        // NaN, infinity, subnormal, cancellation, and wide-alignment cases.
        for (random_index = 0;
             random_index < RANDOM_VECTOR_COUNT;
             random_index = random_index + 1) begin
            random_state_a = next_xorshift32(random_state_a);
            random_state_b = next_xorshift32(random_state_b);
            check_ab(
                random_state_a,
                random_state_b,
                "random_full_bits",
                1'b1
            );
        end

        if (random_checks < 4096) begin
            $display("FAIL add_ab insufficient random coverage=%0d",
                     random_checks);
            $fatal(1);
        end

        if (failures == 0)
            $display(
                "PASS vit_fp32_add_feedforward_ab checks=%0d directed=%0d expected=%0d random=%0d mismatches=0",
                checks,
                directed_checks,
                expected_checks,
                random_checks
            );
        else begin
            $display(
                "FAIL vit_fp32_add_feedforward_ab checks=%0d failures=%0d",
                checks,
                failures
            );
            $fatal(1);
        end

        $finish;
    end

endmodule
