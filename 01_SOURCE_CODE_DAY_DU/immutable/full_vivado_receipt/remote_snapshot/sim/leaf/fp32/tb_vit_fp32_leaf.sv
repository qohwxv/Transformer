`timescale 1ns/1ps

module tb_vit_fp32_leaf;

    import vit_fp32_pkg::*;

    logic [31:0] a;
    logic [31:0] b;
    logic [31:0] add_result;
    logic [31:0] sub_result;
    logic [31:0] mul_result;

    logic        a_is_nan;
    logic        a_is_inf;
    logic        a_is_zero;
    logic        b_is_nan;
    logic        b_is_inf;
    logic        b_is_zero;
    logic        unordered;
    logic        equal;
    logic        a_greater;
    logic        a_greater_equal;
    logic [31:0] maximum;

    logic        clk;
    logic        rst_n;
    logic        accumulator_clear;
    logic        accumulator_enable;
    logic [31:0] accumulator_addend;
    logic [31:0] accumulator_result;
    logic [31:0] accumulator_reference;

    integer checks;
    integer failures;
    integer random_index;
    integer random_seed;
    logic [31:0] random_a;
    logic [31:0] random_b;

    vit_fp32_add_comb u_add (
        .a      (a),
        .b      (b),
        .result (add_result)
    );

    vit_fp32_sub_comb u_sub (
        .a      (a),
        .b      (b),
        .result (sub_result)
    );

    vit_fp32_mul_comb_nodsp u_mul (
        .a      (a),
        .b      (b),
        .result (mul_result)
    );

    vit_fp32_compare u_compare (
        .a               (a),
        .b               (b),
        .a_is_nan        (a_is_nan),
        .a_is_inf        (a_is_inf),
        .a_is_zero       (a_is_zero),
        .b_is_nan        (b_is_nan),
        .b_is_inf        (b_is_inf),
        .b_is_zero       (b_is_zero),
        .unordered       (unordered),
        .equal           (equal),
        .a_greater       (a_greater),
        .a_greater_equal (a_greater_equal),
        .maximum         (maximum)
    );

    vit_fp32_accumulator u_accumulator (
        .clk    (clk),
        .rst_n  (rst_n),
        .clear  (accumulator_clear),
        .enable (accumulator_enable),
        .addend (accumulator_addend),
        .result (accumulator_result)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function automatic logic ref_greater(
        input logic [31:0] lhs,
        input logic [31:0] rhs
    );
        logic lhs_nan;
        logic rhs_nan;
        logic lhs_zero;
        logic rhs_zero;
        begin
            lhs_nan = fp32_is_nan_synth(lhs);
            rhs_nan = fp32_is_nan_synth(rhs);
            lhs_zero = fp32_is_zero_synth(lhs);
            rhs_zero = fp32_is_zero_synth(rhs);

            if (lhs_nan || rhs_nan ||
                ((lhs_zero && rhs_zero) || (lhs == rhs))) begin
                ref_greater = 1'b0;
            end else if (lhs[31] != rhs[31]) begin
                ref_greater = !lhs[31];
            end else if (!lhs[31]) begin
                ref_greater = (lhs[30:0] > rhs[30:0]);
            end else begin
                ref_greater = (lhs[30:0] < rhs[30:0]);
            end
        end
    endfunction

    function automatic logic ref_equal(
        input logic [31:0] lhs,
        input logic [31:0] rhs
    );
        begin
            if (fp32_is_nan_synth(lhs) || fp32_is_nan_synth(rhs))
                ref_equal = 1'b0;
            else if (fp32_is_zero_synth(lhs) &&
                     fp32_is_zero_synth(rhs))
                ref_equal = 1'b1;
            else
                ref_equal = (lhs == rhs);
        end
    endfunction

    task automatic report_mismatch(
        input string       operation,
        input logic [31:0] lhs,
        input logic [31:0] rhs,
        input logic [31:0] expected,
        input logic [31:0] actual
    );
        begin
            failures = failures + 1;
            if (failures <= 20)
                $display(
                    "FAIL %-12s a=%08x b=%08x expected=%08x actual=%08x",
                    operation, lhs, rhs, expected, actual
                );
        end
    endtask

    task automatic check_pair(
        input logic [31:0] lhs,
        input logic [31:0] rhs
    );
        logic [31:0] expected_add;
        logic [31:0] expected_sub;
        logic [31:0] expected_mul;
        logic [31:0] expected_max;
        logic        expected_a_nan;
        logic        expected_a_inf;
        logic        expected_a_zero;
        logic        expected_b_nan;
        logic        expected_b_inf;
        logic        expected_b_zero;
        logic        expected_unordered;
        logic        expected_equal;
        logic        expected_greater;
        logic        expected_greater_equal;
        begin
            a = lhs;
            b = rhs;
            #1;

            expected_add = fp32_add(lhs, rhs);
            expected_sub = fp32_sub_synth(lhs, rhs);
            expected_mul = fp32_mul(lhs, rhs);
            expected_max = fp32_max_synth(lhs, rhs);
            expected_a_nan = fp32_is_nan_synth(lhs);
            expected_a_inf = fp32_is_inf_synth(lhs);
            expected_a_zero = fp32_is_zero_synth(lhs);
            expected_b_nan = fp32_is_nan_synth(rhs);
            expected_b_inf = fp32_is_inf_synth(rhs);
            expected_b_zero = fp32_is_zero_synth(rhs);
            expected_unordered = expected_a_nan || expected_b_nan;
            expected_equal = ref_equal(lhs, rhs);
            expected_greater = ref_greater(lhs, rhs);
            expected_greater_equal =
                !expected_unordered &&
                (expected_equal || expected_greater);

            checks = checks + 1;
            if (add_result !== expected_add)
                report_mismatch(
                    "add", lhs, rhs, expected_add, add_result
                );

            checks = checks + 1;
            if (sub_result !== expected_sub)
                report_mismatch(
                    "sub", lhs, rhs, expected_sub, sub_result
                );

            checks = checks + 1;
            if (mul_result !== expected_mul)
                report_mismatch(
                    "mul", lhs, rhs, expected_mul, mul_result
                );

            checks = checks + 1;
            if (maximum !== expected_max)
                report_mismatch(
                    "maximum", lhs, rhs, expected_max, maximum
                );

            checks = checks + 11;
            if (a_is_nan !== expected_a_nan) begin
                failures = failures + 1;
                if (failures <= 20)
                    $display("FAIL a_is_nan a=%08x", lhs);
            end
            if (a_is_inf !== expected_a_inf) begin
                failures = failures + 1;
                if (failures <= 20)
                    $display("FAIL a_is_inf a=%08x", lhs);
            end
            if (a_is_zero !== expected_a_zero) begin
                failures = failures + 1;
                if (failures <= 20)
                    $display("FAIL a_is_zero a=%08x", lhs);
            end
            if (b_is_nan !== expected_b_nan) begin
                failures = failures + 1;
                if (failures <= 20)
                    $display("FAIL b_is_nan b=%08x", rhs);
            end
            if (b_is_inf !== expected_b_inf) begin
                failures = failures + 1;
                if (failures <= 20)
                    $display("FAIL b_is_inf b=%08x", rhs);
            end
            if (b_is_zero !== expected_b_zero) begin
                failures = failures + 1;
                if (failures <= 20)
                    $display("FAIL b_is_zero b=%08x", rhs);
            end
            if (unordered !== expected_unordered) begin
                failures = failures + 1;
                if (failures <= 20)
                    $display("FAIL unordered a=%08x b=%08x", lhs, rhs);
            end
            if (equal !== expected_equal) begin
                failures = failures + 1;
                if (failures <= 20)
                    $display("FAIL equal a=%08x b=%08x", lhs, rhs);
            end
            if (a_greater !== expected_greater) begin
                failures = failures + 1;
                if (failures <= 20)
                    $display("FAIL a_greater a=%08x b=%08x", lhs, rhs);
            end
            if (a_greater_equal !== expected_greater_equal) begin
                failures = failures + 1;
                if (failures <= 20)
                    $display(
                        "FAIL a_greater_equal a=%08x b=%08x",
                        lhs, rhs
                    );
            end
            if (unordered && (equal || a_greater || a_greater_equal)) begin
                failures = failures + 1;
                if (failures <= 20)
                    $display(
                        "FAIL unordered compare outputs a=%08x b=%08x",
                        lhs, rhs
                    );
            end
        end
    endtask

    task automatic accumulator_cycle(
        input logic        clear_value,
        input logic        enable_value,
        input logic [31:0] addend_value
    );
        logic [31:0] expected_next;
        begin
            @(negedge clk);
            accumulator_clear = clear_value;
            accumulator_enable = enable_value;
            accumulator_addend = addend_value;

            if (clear_value)
                expected_next = 32'h0000_0000;
            else if (enable_value)
                expected_next =
                    fp32_add(accumulator_reference, addend_value);
            else
                expected_next = accumulator_reference;

            @(posedge clk);
            #1;
            accumulator_reference = expected_next;
            checks = checks + 1;
            if (accumulator_result !== accumulator_reference)
                report_mismatch(
                    "accumulator",
                    accumulator_reference,
                    addend_value,
                    accumulator_reference,
                    accumulator_result
                );
        end
    endtask

    initial begin
        a = 32'd0;
        b = 32'd0;
        rst_n = 1'b0;
        accumulator_clear = 1'b0;
        accumulator_enable = 1'b0;
        accumulator_addend = 32'd0;
        accumulator_reference = 32'd0;
        checks = 0;
        failures = 0;
        random_seed = 32'h51A7_2026;

        // Directed exceptional, rounding, overflow, underflow, and
        // cancellation cases.
        check_pair(32'h0000_0000, 32'h0000_0000);
        check_pair(32'h8000_0000, 32'h8000_0000);
        check_pair(32'h0000_0000, 32'h8000_0000);
        check_pair(32'h0000_0001, 32'h8000_0001);
        check_pair(32'h007F_FFFF, 32'h3F80_0000);
        check_pair(32'h0080_0000, 32'h3F00_0000);
        check_pair(32'h3F80_0000, 32'h3F80_0000);
        check_pair(32'h3F80_0000, 32'hBF80_0000);
        check_pair(32'h4060_0000, 32'hBFA0_0000);
        check_pair(32'h3F80_0000, 32'h3380_0000);
        check_pair(32'h3F80_0001, 32'h3380_0000);
        check_pair(32'h7F7F_FFFF, 32'h4000_0000);
        check_pair(32'hFF7F_FFFF, 32'h4000_0000);
        check_pair(32'h7F80_0000, 32'h0000_0000);
        check_pair(32'hFF80_0000, 32'h8000_0000);
        check_pair(32'h7F80_0000, 32'hFF80_0000);
        check_pair(32'h7FC0_0001, 32'h3F80_0000);
        check_pair(32'h7FA0_1234, 32'hFFC0_5678);
        check_pair(32'hBF80_0000, 32'hC000_0000);
        check_pair(32'hC040_0000, 32'hBF80_0000);

        // Broad bit-pattern regression against the package functions.
        for (random_index = 0; random_index < 4096;
             random_index = random_index + 1) begin
            random_a = $urandom(random_seed);
            random_b = $urandom;
            check_pair(random_a, random_b);
        end

        // The accumulator is checked separately because it adds state around
        // the same combinational leaf adder.
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        accumulator_cycle(1'b0, 1'b0, 32'h3F80_0000);
        accumulator_cycle(1'b0, 1'b1, 32'h3F80_0000);
        accumulator_cycle(1'b0, 1'b1, 32'h4000_0000);
        accumulator_cycle(1'b0, 1'b1, 32'hBF00_0000);
        accumulator_cycle(1'b1, 1'b1, 32'h7F80_0000);
        accumulator_cycle(1'b0, 1'b1, 32'h8000_0000);

        for (random_index = 0; random_index < 256;
             random_index = random_index + 1) begin
            random_a = $urandom;
            accumulator_cycle(
                (random_index == 127),
                (random_index[1:0] != 2'b00),
                random_a
            );
        end

        if (failures == 0) begin
            $display(
                "PASS tb_vit_fp32_leaf: %0d checks, 0 mismatches",
                checks
            );
            $finish;
        end

        $fatal(
            1,
            "FAIL tb_vit_fp32_leaf: %0d checks, %0d mismatches",
            checks,
            failures
        );
    end

endmodule
