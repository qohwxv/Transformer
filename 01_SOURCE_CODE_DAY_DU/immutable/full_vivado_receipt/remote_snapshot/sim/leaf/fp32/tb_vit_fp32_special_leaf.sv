`timescale 1ns/1ps

module tb_vit_fp32_special_leaf;

    import vit_fp32_pkg::*;

    logic [31:0] integer_value;
    logic [31:0] float_value;
    logic [31:0] scale_amount;
    logic [31:0] rsqrt_operand;
    logic [31:0] rsqrt_estimate;

    logic [31:0] from_u32_result;
    logic [31:0] to_u32_result;
    logic [31:0] scale_result;
    logic [31:0] exp_result;
    logic [31:0] recip_result;
    logic [31:0] rsqrt_result;

    integer checks;
    integer failures;
    integer test_index;
    integer random_seed;

    vit_fp32_from_u32_comb u_from_u32 (
        .value  (integer_value),
        .result (from_u32_result)
    );

    vit_fp32_to_u32_floor_comb u_to_u32 (
        .value  (float_value),
        .result (to_u32_result)
    );

    vit_fp32_scale_pow2_down_comb u_scale (
        .value  (float_value),
        .amount (scale_amount),
        .result (scale_result)
    );

    vit_fp32_exp_neg_comb u_exp (
        .value  (float_value),
        .result (exp_result)
    );

    vit_fp32_recip_comb u_recip (
        .value  (float_value),
        .result (recip_result)
    );

    vit_fp32_rsqrt_step_comb u_rsqrt_step (
        .operand      (rsqrt_operand),
        .estimate     (rsqrt_estimate),
        .next_estimate(rsqrt_result)
    );

    task automatic report_mismatch(
        input string       operation,
        input logic [31:0] input_a,
        input logic [31:0] input_b,
        input logic [31:0] expected,
        input logic [31:0] actual
    );
        begin
            failures = failures + 1;
            if (failures <= 20)
                $display(
                    "FAIL %-12s a=%08x b=%08x expected=%08x actual=%08x",
                    operation, input_a, input_b, expected, actual
                );
        end
    endtask

    task automatic check_conversion_and_scale(
        input logic [31:0] integer_input,
        input logic [31:0] float_input,
        input logic [31:0] amount_input
    );
        logic [31:0] expected;
        begin
            integer_value = integer_input;
            float_value = float_input;
            scale_amount = amount_input;
            #1;

            checks = checks + 1;
            expected = fp32_from_u32_synth(integer_input);
            if (from_u32_result !== expected)
                report_mismatch(
                    "from_u32", integer_input, 32'd0,
                    expected, from_u32_result
                );

            checks = checks + 1;
            expected = fp32_to_u32_floor_synth(float_input);
            if (to_u32_result !== expected)
                report_mismatch(
                    "to_u32", float_input, 32'd0,
                    expected, to_u32_result
                );

            checks = checks + 1;
            expected = fp32_scale_pow2_down_synth(
                float_input,
                amount_input
            );
            if (scale_result !== expected)
                report_mismatch(
                    "scale", float_input, amount_input,
                    expected, scale_result
                );
        end
    endtask

    task automatic check_exp_and_recip(
        input logic [31:0] input_value
    );
        logic [31:0] expected;
        begin
            float_value = input_value;
            #1;

            checks = checks + 1;
            expected = fp32_exp_neg_synth(input_value);
            if (exp_result !== expected)
                report_mismatch(
                    "exp_neg", input_value, 32'd0,
                    expected, exp_result
                );

            checks = checks + 1;
            expected = fp32_recip_positive_synth(input_value);
            if (recip_result !== expected)
                report_mismatch(
                    "reciprocal", input_value, 32'd0,
                    expected, recip_result
                );
        end
    endtask

    task automatic check_rsqrt_step(
        input logic [31:0] operand_input,
        input logic [31:0] estimate_input
    );
        logic [31:0] expected;
        begin
            rsqrt_operand = operand_input;
            rsqrt_estimate = estimate_input;
            #1;

            expected = fp32_mul(
                estimate_input,
                fp32_sub_synth(
                    32'h3fc0_0000,
                    fp32_mul(
                        32'h3f00_0000,
                        fp32_mul(
                            operand_input,
                            fp32_mul(estimate_input, estimate_input)
                        )
                    )
                )
            );
            checks = checks + 1;
            if (rsqrt_result !== expected)
                report_mismatch(
                    "rsqrt_step", operand_input, estimate_input,
                    expected, rsqrt_result
                );
        end
    endtask

    initial begin
        checks = 0;
        failures = 0;
        random_seed = 32'h51a7_2026;
        integer_value = 32'd0;
        float_value = 32'd0;
        scale_amount = 32'd0;
        rsqrt_operand = 32'h3f80_0000;
        rsqrt_estimate = 32'h3f80_0000;

        check_conversion_and_scale(32'd0,          32'h0000_0000, 32'd0);
        check_conversion_and_scale(32'd1,          32'h3f80_0000, 32'd1);
        check_conversion_and_scale(32'hffff_ffff,  32'h7f80_0000, 32'd127);
        check_conversion_and_scale(32'h0100_0001,  32'h7fc0_0001, 32'd4);
        check_conversion_and_scale(32'h7fff_ffff,  32'hbf80_0000, 32'd31);

        check_exp_and_recip(32'h0000_0000);
        check_exp_and_recip(32'h8000_0000);
        check_exp_and_recip(32'hbf80_0000);
        check_exp_and_recip(32'hc120_0000);
        check_exp_and_recip(32'hff80_0000);
        check_exp_and_recip(32'h7f80_0000);
        check_exp_and_recip(32'h7fc0_0001);

        check_rsqrt_step(32'h3f80_0000, 32'h3f80_0000);
        check_rsqrt_step(32'h4080_0000, 32'h3f00_0000);

        for (test_index = 0; test_index < 2000;
             test_index = test_index + 1) begin
            check_conversion_and_scale(
                $urandom(random_seed),
                $urandom(random_seed),
                $urandom(random_seed) & 32'h0000_00ff
            );

            check_exp_and_recip({
                1'b1,
                ($urandom(random_seed) & 31'h42ff_ffff)
            });

            check_rsqrt_step(
                {
                    1'b0,
                    (($urandom(random_seed) % 8'd126) + 8'd1),
                    $urandom(random_seed) & 23'h7f_ffff
                },
                {
                    1'b0,
                    (($urandom(random_seed) % 8'd126) + 8'd1),
                    $urandom(random_seed) & 23'h7f_ffff
                }
            );
        end

        if (failures == 0)
            $display(
                "PASS vit_fp32_special_leaf: %0d checks, 0 mismatches",
                checks
            );
        else begin
            $display(
                "FAIL vit_fp32_special_leaf: %0d checks, %0d mismatches",
                checks, failures
            );
            $fatal(1);
        end

        $finish;
    end

endmodule
