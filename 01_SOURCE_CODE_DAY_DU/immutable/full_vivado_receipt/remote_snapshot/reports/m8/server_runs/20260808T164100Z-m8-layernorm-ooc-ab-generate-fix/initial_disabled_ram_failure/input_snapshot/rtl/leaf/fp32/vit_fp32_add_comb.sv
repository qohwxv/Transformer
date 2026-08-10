`timescale 1ns/1ps

// Combinational binary32 adder. Its handling of exceptional values,
// subnormals, cancellation, and rounding is bit-for-bit compatible with
// vit_fp32_pkg::fp32_add.
//
// Every arithmetic stage below has a distinct output net.  In particular,
// alignment/sticky formation, normalization, and rounding never overwrite a
// value that they also read.  Keeping this cone strictly feed-forward avoids
// synthesis-dependent combinational SCCs while preserving the historical
// bit-level algorithm.
module vit_fp32_add_comb (
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] result
);

    localparam logic [31:0] FP32_QNAN = 32'h7FC0_0000;

    // Decode and magnitude ordering.
    logic        sign_a;
    logic        sign_b;
    logic [7:0]  exp_a;
    logic [7:0]  exp_b;
    logic [22:0] frac_a;
    logic [22:0] frac_b;
    logic        a_nan;
    logic        b_nan;
    logic        a_inf;
    logic        b_inf;
    logic        a_zero;
    logic        b_zero;
    logic        invalid_infinity_sum;
    logic        exact_cancellation;
    logic        a_is_large;
    logic        sign_large;
    logic        sign_small;
    logic [7:0]  exp_large;
    logic [7:0]  exp_small;
    logic [22:0] frac_large;
    logic [22:0] frac_small;

    // Alignment stage.
    logic [26:0] mant_large;
    logic [26:0] mant_small;
    logic [8:0]  exp_difference;
    logic        alignment_ge_width;
    logic [4:0]  alignment_shift;
    logic [26:0] alignment_shifted;
    logic [26:0] alignment_sticky_mask;
    logic        alignment_sticky;
    logic [26:0] mant_small_aligned;

    // Same-sign addition stage.
    logic [27:0] add_mantissa_raw;
    logic        add_normalize_carry;
    logic [26:0] add_mantissa_normalized;
    logic [8:0]  add_exp_normalized;

    // Opposite-sign subtraction and normalization stage.
    logic [26:0] sub_mantissa_raw;
    logic [5:0]  sub_leading_zero_count;
    logic [5:0]  sub_exp_shift_cap;
    logic [5:0]  sub_normalize_shift;
    logic [26:0] sub_mantissa_normalized;
    logic [8:0]  sub_exp_normalized;

    // Common round-to-nearest-even stage.
    logic [26:0] normal_mantissa_pre_round;
    logic [8:0]  exp_pre_round;
    logic        pre_round_zero;
    logic [23:0] mantissa_main_pre_round;
    logic        guard_bit;
    logic        round_bit;
    logic        sticky_bit;
    logic        round_increment;
    logic [24:0] rounded_mantissa_wide;
    logic        round_carry;
    logic [22:0] mantissa_fraction_post_round;
    logic [8:0]  exp_post_round;

    assign sign_a = a[31];
    assign sign_b = b[31];
    assign exp_a = a[30:23];
    assign exp_b = b[30:23];
    assign frac_a = a[22:0];
    assign frac_b = b[22:0];

    assign a_nan = (exp_a == 8'hFF) && (frac_a != 23'd0);
    assign b_nan = (exp_b == 8'hFF) && (frac_b != 23'd0);
    assign a_inf = (exp_a == 8'hFF) && (frac_a == 23'd0);
    assign b_inf = (exp_b == 8'hFF) && (frac_b == 23'd0);

    // Historical contract: every exponent-zero operand is handled as zero.
    // This intentionally includes encoded subnormals and must remain stable.
    assign a_zero = (exp_a == 8'd0);
    assign b_zero = (exp_b == 8'd0);
    assign invalid_infinity_sum =
        a_inf && b_inf && (sign_a != sign_b);
    assign exact_cancellation =
        (sign_a != sign_b) &&
        ({exp_a, frac_a} == {exp_b, frac_b});

    assign a_is_large = ({exp_a, frac_a} >= {exp_b, frac_b});
    assign sign_large = a_is_large ? sign_a : sign_b;
    assign sign_small = a_is_large ? sign_b : sign_a;
    assign exp_large = a_is_large ? exp_a : exp_b;
    assign exp_small = a_is_large ? exp_b : exp_a;
    assign frac_large = a_is_large ? frac_a : frac_b;
    assign frac_small = a_is_large ? frac_b : frac_a;

    assign mant_large = {1'b1, frac_large, 3'b000};
    assign mant_small = {1'b1, frac_small, 3'b000};
    assign exp_difference =
        {1'b0, exp_large} - {1'b0, exp_small};
    assign alignment_ge_width = (exp_difference >= 9'd27);
    assign alignment_shift = exp_difference[4:0];
    assign alignment_shifted = alignment_ge_width ?
        27'd0 : (mant_small >> alignment_shift);
    assign alignment_sticky_mask = alignment_ge_width ?
        {27{1'b1}} :
        ((27'd1 << alignment_shift) - 27'd1);
    assign alignment_sticky =
        |(mant_small & alignment_sticky_mask);
    assign mant_small_aligned = {
        alignment_shifted[26:1],
        alignment_shifted[0] | alignment_sticky
    };

    assign add_mantissa_raw =
        {1'b0, mant_large} + {1'b0, mant_small_aligned};
    assign add_normalize_carry = add_mantissa_raw[27];
    assign add_mantissa_normalized = add_normalize_carry ?
        {
            add_mantissa_raw[27:2],
            add_mantissa_raw[1] | add_mantissa_raw[0]
        } :
        add_mantissa_raw[26:0];
    assign add_exp_normalized =
        {1'b0, exp_large} + {8'd0, add_normalize_carry};

    assign sub_mantissa_raw = mant_large - mant_small_aligned;

    // Explicit priority encoder: one assignment, no stateful/self-referential
    // scan temporary.  The value is 27 only for an all-zero difference.
    assign sub_leading_zero_count =
        sub_mantissa_raw[26] ? 6'd0  :
        sub_mantissa_raw[25] ? 6'd1  :
        sub_mantissa_raw[24] ? 6'd2  :
        sub_mantissa_raw[23] ? 6'd3  :
        sub_mantissa_raw[22] ? 6'd4  :
        sub_mantissa_raw[21] ? 6'd5  :
        sub_mantissa_raw[20] ? 6'd6  :
        sub_mantissa_raw[19] ? 6'd7  :
        sub_mantissa_raw[18] ? 6'd8  :
        sub_mantissa_raw[17] ? 6'd9  :
        sub_mantissa_raw[16] ? 6'd10 :
        sub_mantissa_raw[15] ? 6'd11 :
        sub_mantissa_raw[14] ? 6'd12 :
        sub_mantissa_raw[13] ? 6'd13 :
        sub_mantissa_raw[12] ? 6'd14 :
        sub_mantissa_raw[11] ? 6'd15 :
        sub_mantissa_raw[10] ? 6'd16 :
        sub_mantissa_raw[9]  ? 6'd17 :
        sub_mantissa_raw[8]  ? 6'd18 :
        sub_mantissa_raw[7]  ? 6'd19 :
        sub_mantissa_raw[6]  ? 6'd20 :
        sub_mantissa_raw[5]  ? 6'd21 :
        sub_mantissa_raw[4]  ? 6'd22 :
        sub_mantissa_raw[3]  ? 6'd23 :
        sub_mantissa_raw[2]  ? 6'd24 :
        sub_mantissa_raw[1]  ? 6'd25 :
        sub_mantissa_raw[0]  ? 6'd26 : 6'd27;

    assign sub_exp_shift_cap = ({1'b0, exp_large} > 9'd27) ?
        6'd26 : (exp_large[5:0] - 6'd1);
    assign sub_normalize_shift =
        (sub_leading_zero_count < sub_exp_shift_cap) ?
        sub_leading_zero_count : sub_exp_shift_cap;
    assign sub_mantissa_normalized =
        sub_mantissa_raw << sub_normalize_shift;
    assign sub_exp_normalized =
        {1'b0, exp_large} - {3'd0, sub_normalize_shift};

    assign normal_mantissa_pre_round =
        (sign_large == sign_small) ?
        add_mantissa_normalized : sub_mantissa_normalized;
    assign exp_pre_round =
        (sign_large == sign_small) ?
        add_exp_normalized : sub_exp_normalized;
    assign pre_round_zero =
        (normal_mantissa_pre_round == 27'd0) ||
        ((exp_pre_round == 9'd1) && !normal_mantissa_pre_round[26]);

    assign mantissa_main_pre_round = normal_mantissa_pre_round[26:3];
    assign guard_bit = normal_mantissa_pre_round[2];
    assign round_bit = normal_mantissa_pre_round[1];
    assign sticky_bit = normal_mantissa_pre_round[0];
    assign round_increment = guard_bit &&
        (round_bit || sticky_bit || mantissa_main_pre_round[0]);
    assign rounded_mantissa_wide =
        {1'b0, mantissa_main_pre_round} + {24'd0, round_increment};
    assign round_carry = rounded_mantissa_wide[24];
    assign mantissa_fraction_post_round = round_carry ?
        rounded_mantissa_wide[23:1] : rounded_mantissa_wide[22:0];
    assign exp_post_round =
        exp_pre_round + {8'd0, round_carry};

    // Result precedence is intentionally identical to the historical adder.
    // A single continuous assignment completes the one-way dataflow cone.
    assign result =
        (a_nan || b_nan || invalid_infinity_sum) ? FP32_QNAN :
        a_inf ? {sign_a, 8'hFF, 23'd0} :
        b_inf ? {sign_b, 8'hFF, 23'd0} :
        (a_zero && b_zero) ? {(sign_a && sign_b), 31'd0} :
        a_zero ? b :
        b_zero ? a :
        exact_cancellation ? 32'd0 :
        pre_round_zero ? {sign_large, 31'd0} :
        (exp_post_round >= 9'd255) ? {sign_large, 8'hFF, 23'd0} :
        (exp_post_round == 9'd0) ? {sign_large, 31'd0} :
        {
            sign_large,
            exp_post_round[7:0],
            mantissa_fraction_post_round
        };

endmodule
