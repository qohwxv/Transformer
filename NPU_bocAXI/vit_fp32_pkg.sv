`timescale 1ns/1ps

package vit_fp32_pkg;

    localparam logic [31:0] FP32_QNAN = 32'h7FC00000;
    localparam logic [31:0] FP32_SYNTH_POS_ZERO = 32'h00000000;
    localparam logic [31:0] FP32_SYNTH_POS_INF  = 32'h7F800000;
    localparam logic [31:0] FP32_SYNTH_NEG_INF  = 32'hFF800000;
    localparam logic [31:0] FP32_SYNTH_ONE      = 32'h3F800000;
    localparam logic [31:0] FP32_SYNTH_TWO      = 32'h40000000;
    localparam logic [31:0] FP32_SYNTH_HALF     = 32'h3F000000;

    // Shift a mantissa right and merge every discarded one bit into the
    // sticky bit. The input convention is {hidden, fraction, G, R, S}.
    function automatic logic [26:0] fp32_shift_right_sticky(
        input logic [26:0] value,
        input integer      amount
    );
        logic [26:0] shifted;
        logic sticky;
        integer bit_index;
        begin
            shifted = 27'd0;
            sticky = 1'b0;

            if (amount <= 0) begin
                shifted = value;
            end else if (amount >= 27) begin
                shifted = 27'd0;
                shifted[0] = |value;
            end else begin
                shifted = value >> amount;
                for (bit_index = 0; bit_index < 27; bit_index = bit_index + 1) begin
                    if (bit_index < amount)
                        sticky = sticky | value[bit_index];
                end
                shifted[0] = shifted[0] | sticky;
            end

            fp32_shift_right_sticky = shifted;
        end
    endfunction

    // Combinational IEEE-754 binary32 multiplier with round-to-nearest-even.
    // Subnormal inputs and underflowed outputs are flushed to signed zero. The
    // ViT test_1 tensors contain normal finite values and exact zeros.
    function automatic logic [31:0] fp32_mul(
        input logic [31:0] a,
        input logic [31:0] b
    );
        logic sign_result;
        logic [7:0] exp_a;
        logic [7:0] exp_b;
        logic [22:0] frac_a;
        logic [22:0] frac_b;
        logic a_nan;
        logic b_nan;
        logic a_inf;
        logic b_inf;
        logic a_zero;
        logic b_zero;
        logic [23:0] mant_a;
        logic [23:0] mant_b;
        logic [47:0] product;
        logic [23:0] mantissa;
        logic guard_bit;
        logic sticky_bit;
        logic round_up;
        logic [24:0] rounded_mantissa;
        integer exp_result;
        begin
            sign_result = a[31] ^ b[31];
            exp_a = a[30:23];
            exp_b = b[30:23];
            frac_a = a[22:0];
            frac_b = b[22:0];

            a_nan = (exp_a == 8'hFF) && (frac_a != 23'd0);
            b_nan = (exp_b == 8'hFF) && (frac_b != 23'd0);
            a_inf = (exp_a == 8'hFF) && (frac_a == 23'd0);
            b_inf = (exp_b == 8'hFF) && (frac_b == 23'd0);
            a_zero = (exp_a == 8'd0);
            b_zero = (exp_b == 8'd0);

            mant_a = {1'b1, frac_a};
            mant_b = {1'b1, frac_b};
            product = mant_a * mant_b;
            mantissa = 24'd0;
            guard_bit = 1'b0;
            sticky_bit = 1'b0;
            round_up = 1'b0;
            rounded_mantissa = 25'd0;
            exp_result = 0;

            if (a_nan || b_nan || ((a_inf || b_inf) && (a_zero || b_zero))) begin
                fp32_mul = FP32_QNAN;
            end else if (a_inf || b_inf) begin
                fp32_mul = {sign_result, 8'hFF, 23'd0};
            end else if (a_zero || b_zero) begin
                fp32_mul = {sign_result, 31'd0};
            end else begin
                if (product[47]) begin
                    mantissa = product[47:24];
                    guard_bit = product[23];
                    sticky_bit = |product[22:0];
                    exp_result = exp_a;
                    exp_result = exp_result + exp_b - 127 + 1;
                end else begin
                    mantissa = product[46:23];
                    guard_bit = product[22];
                    sticky_bit = |product[21:0];
                    exp_result = exp_a;
                    exp_result = exp_result + exp_b - 127;
                end

                round_up = guard_bit && (sticky_bit || mantissa[0]);
                rounded_mantissa = {1'b0, mantissa} + round_up;

                if (rounded_mantissa[24]) begin
                    mantissa = rounded_mantissa[24:1];
                    exp_result = exp_result + 1;
                end else begin
                    mantissa = rounded_mantissa[23:0];
                end

                if (exp_result >= 255)
                    fp32_mul = {sign_result, 8'hFF, 23'd0};
                else if (exp_result <= 0)
                    fp32_mul = {sign_result, 31'd0};
                else
                    fp32_mul = {sign_result, exp_result[7:0], mantissa[22:0]};
            end
        end
    endfunction

    // Combinational IEEE-754 binary32 adder with round-to-nearest-even.
    // Like fp32_mul, this initial PE implementation uses flush-to-zero for
    // subnormal inputs and results.
    function automatic logic [31:0] fp32_add(
        input logic [31:0] a,
        input logic [31:0] b
    );
        logic sign_a;
        logic sign_b;
        logic [7:0] exp_a;
        logic [7:0] exp_b;
        logic [22:0] frac_a;
        logic [22:0] frac_b;
        logic a_nan;
        logic b_nan;
        logic a_inf;
        logic b_inf;
        logic a_zero;
        logic b_zero;
        logic a_is_large;
        logic sign_large;
        logic sign_small;
        logic [7:0] exp_large;
        logic [7:0] exp_small;
        logic [22:0] frac_large;
        logic [22:0] frac_small;
        logic [26:0] mant_large;
        logic [26:0] mant_small;
        logic [26:0] mant_small_aligned;
        logic [27:0] add_mantissa;
        logic [26:0] normal_mantissa;
        logic [23:0] mantissa_main;
        logic [24:0] rounded_mantissa;
        logic guard_bit;
        logic round_bit;
        logic sticky_bit;
        logic round_up;
        integer exp_difference;
        integer exp_result;
        integer normalize_step;
        begin
            sign_a = a[31];
            sign_b = b[31];
            exp_a = a[30:23];
            exp_b = b[30:23];
            frac_a = a[22:0];
            frac_b = b[22:0];

            a_nan = (exp_a == 8'hFF) && (frac_a != 23'd0);
            b_nan = (exp_b == 8'hFF) && (frac_b != 23'd0);
            a_inf = (exp_a == 8'hFF) && (frac_a == 23'd0);
            b_inf = (exp_b == 8'hFF) && (frac_b == 23'd0);
            a_zero = (exp_a == 8'd0);
            b_zero = (exp_b == 8'd0);

            a_is_large = ({exp_a, frac_a} >= {exp_b, frac_b});
            sign_large = a_is_large ? sign_a : sign_b;
            sign_small = a_is_large ? sign_b : sign_a;
            exp_large = a_is_large ? exp_a : exp_b;
            exp_small = a_is_large ? exp_b : exp_a;
            frac_large = a_is_large ? frac_a : frac_b;
            frac_small = a_is_large ? frac_b : frac_a;
            mant_large = {1'b1, frac_large, 3'b000};
            mant_small = {1'b1, frac_small, 3'b000};
            mant_small_aligned = 27'd0;
            add_mantissa = 28'd0;
            normal_mantissa = 27'd0;
            mantissa_main = 24'd0;
            rounded_mantissa = 25'd0;
            guard_bit = 1'b0;
            round_bit = 1'b0;
            sticky_bit = 1'b0;
            round_up = 1'b0;
            exp_difference = 0;
            exp_result = 0;

            if (a_nan || b_nan || (a_inf && b_inf && (sign_a != sign_b))) begin
                fp32_add = FP32_QNAN;
            end else if (a_inf) begin
                fp32_add = {sign_a, 8'hFF, 23'd0};
            end else if (b_inf) begin
                fp32_add = {sign_b, 8'hFF, 23'd0};
            end else if (a_zero && b_zero) begin
                fp32_add = {(sign_a && sign_b), 31'd0};
            end else if (a_zero) begin
                fp32_add = b_zero ? 32'd0 : b;
            end else if (b_zero) begin
                fp32_add = a;
            end else if ((sign_a != sign_b) && ({exp_a, frac_a} == {exp_b, frac_b})) begin
                fp32_add = 32'd0;
            end else begin
                exp_difference = exp_large - exp_small;
                exp_result = exp_large;
                mant_small_aligned = fp32_shift_right_sticky(mant_small, exp_difference);

                if (sign_large == sign_small) begin
                    add_mantissa = {1'b0, mant_large} + {1'b0, mant_small_aligned};
                    if (add_mantissa[27]) begin
                        normal_mantissa = add_mantissa[27:1];
                        normal_mantissa[0] = normal_mantissa[0] | add_mantissa[0];
                        exp_result = exp_result + 1;
                    end else begin
                        normal_mantissa = add_mantissa[26:0];
                    end
                end else begin
                    normal_mantissa = mant_large - mant_small_aligned;
                    for (normalize_step = 0; normalize_step < 26; normalize_step = normalize_step + 1) begin
                        if (!normal_mantissa[26] && (exp_result > 1)) begin
                            normal_mantissa = normal_mantissa << 1;
                            exp_result = exp_result - 1;
                        end
                    end
                end

                if ((normal_mantissa == 27'd0) ||
                    ((exp_result == 1) && !normal_mantissa[26])) begin
                    fp32_add = {sign_large, 31'd0};
                end else begin
                    mantissa_main = normal_mantissa[26:3];
                    guard_bit = normal_mantissa[2];
                    round_bit = normal_mantissa[1];
                    sticky_bit = normal_mantissa[0];
                    round_up = guard_bit && (round_bit || sticky_bit || mantissa_main[0]);
                    rounded_mantissa = {1'b0, mantissa_main} + round_up;

                    if (rounded_mantissa[24]) begin
                        mantissa_main = rounded_mantissa[24:1];
                        exp_result = exp_result + 1;
                    end else begin
                        mantissa_main = rounded_mantissa[23:0];
                    end

                    if (exp_result >= 255)
                        fp32_add = {sign_large, 8'hFF, 23'd0};
                    else if (exp_result <= 0)
                        fp32_add = {sign_large, 31'd0};
                    else
                        fp32_add = {sign_large, exp_result[7:0], mantissa_main[22:0]};
                end
            end
        end
    endfunction

    function automatic logic fp32_is_nan_synth(input logic [31:0] value);
        begin
            fp32_is_nan_synth = (value[30:23] == 8'hFF) &&
                                 (value[22:0] != 23'd0);
        end
    endfunction

    function automatic logic fp32_is_inf_synth(input logic [31:0] value);
        begin
            fp32_is_inf_synth = (value[30:23] == 8'hFF) &&
                                 (value[22:0] == 23'd0);
        end
    endfunction

    function automatic logic fp32_is_zero_synth(input logic [31:0] value);
        begin
            fp32_is_zero_synth = (value[30:0] == 31'd0);
        end
    endfunction

    function automatic logic [31:0] fp32_sub_synth(
        input logic [31:0] a,
        input logic [31:0] b
    );
        begin
            fp32_sub_synth = fp32_add(a, {~b[31], b[30:0]});
        end
    endfunction

    // IEEE-style propagating maximum used by stable Softmax.  Equal signed
    // zeros select +0, and any NaN produces the package quiet NaN.
    function automatic logic [31:0] fp32_max_synth(
        input logic [31:0] a,
        input logic [31:0] b
    );
        logic [30:0] magnitude_a;
        logic [30:0] magnitude_b;
        begin
            magnitude_a = a[30:0];
            magnitude_b = b[30:0];

            if (fp32_is_nan_synth(a) || fp32_is_nan_synth(b)) begin
                fp32_max_synth = FP32_QNAN;
            end else if (fp32_is_zero_synth(a) &&
                         fp32_is_zero_synth(b)) begin
                fp32_max_synth = FP32_SYNTH_POS_ZERO;
            end else if (a[31] != b[31]) begin
                fp32_max_synth = a[31] ? b : a;
            end else if (!a[31]) begin
                fp32_max_synth = (magnitude_a >= magnitude_b) ? a : b;
            end else begin
                fp32_max_synth = (magnitude_a <= magnitude_b) ? a : b;
            end
        end
    endfunction

    // Unsigned integer to binary32 conversion with round-to-nearest-even.
    function automatic logic [31:0] fp32_from_u32_synth(
        input logic [31:0] value
    );
        logic [63:0] wide_value;
        logic [63:0] shifted_value;
        logic [63:0] remainder_mask;
        logic [63:0] remainder;
        logic [63:0] halfway;
        logic [24:0] rounded_mantissa;
        integer bit_index;
        integer msb_index;
        integer right_shift;
        integer biased_exponent;
        begin
            wide_value = {32'd0, value};
            shifted_value = 64'd0;
            remainder_mask = 64'd0;
            remainder = 64'd0;
            halfway = 64'd0;
            rounded_mantissa = 25'd0;
            msb_index = 0;
            right_shift = 0;
            biased_exponent = 0;

            for (bit_index = 0; bit_index < 32; bit_index = bit_index + 1) begin
                if (value[bit_index])
                    msb_index = bit_index;
            end

            if (value == 0) begin
                fp32_from_u32_synth = FP32_SYNTH_POS_ZERO;
            end else begin
                biased_exponent = 127 + msb_index;
                if (msb_index <= 23) begin
                    shifted_value = wide_value << (23 - msb_index);
                    rounded_mantissa = {1'b0, shifted_value[23:0]};
                end else begin
                    right_shift = msb_index - 23;
                    shifted_value = wide_value >> right_shift;
                    rounded_mantissa = {1'b0, shifted_value[23:0]};
                    remainder_mask = (64'd1 << right_shift) - 1'b1;
                    remainder = wide_value & remainder_mask;
                    halfway = 64'd1 << (right_shift - 1);
                    if ((remainder > halfway) ||
                        ((remainder == halfway) && rounded_mantissa[0]))
                        rounded_mantissa = rounded_mantissa + 1'b1;
                end

                if (rounded_mantissa[24]) begin
                    rounded_mantissa = rounded_mantissa >> 1;
                    biased_exponent = biased_exponent + 1;
                end

                if (biased_exponent >= 255)
                    fp32_from_u32_synth = FP32_SYNTH_POS_INF;
                else
                    fp32_from_u32_synth = {
                        1'b0,
                        biased_exponent[7:0],
                        rounded_mantissa[22:0]
                    };
            end
        end
    endfunction

    // Floor a positive finite binary32 value to an unsigned integer. Values
    // outside the 32-bit range saturate.
    function automatic logic [31:0] fp32_to_u32_floor_synth(
        input logic [31:0] value
    );
        logic [23:0] mantissa;
        integer unbiased_exponent;
        begin
            mantissa = {1'b1, value[22:0]};
            unbiased_exponent = {24'd0, value[30:23]} - 32'd127;

            if (value[31] || (value[30:23] < 127)) begin
                fp32_to_u32_floor_synth = 32'd0;
            end else if ((value[30:23] == 8'hFF) ||
                         (unbiased_exponent >= 32)) begin
                fp32_to_u32_floor_synth = 32'hFFFF_FFFF;
            end else if (unbiased_exponent >= 23) begin
                fp32_to_u32_floor_synth =
                    {8'd0, mantissa} << (unbiased_exponent - 23);
            end else begin
                fp32_to_u32_floor_synth =
                    {8'd0, mantissa} >> (23 - unbiased_exponent);
            end
        end
    endfunction

    // Scale a positive normal value by 2^-amount by editing its exponent.
    // Like fp32_add/fp32_mul, underflow is flushed to zero.
    function automatic logic [31:0] fp32_scale_pow2_down_synth(
        input logic [31:0] value,
        input logic [31:0] amount
    );
        integer result_exponent;
        begin
            result_exponent = 0;
            if (fp32_is_nan_synth(value)) begin
                fp32_scale_pow2_down_synth = FP32_QNAN;
            end else if (fp32_is_inf_synth(value) ||
                         fp32_is_zero_synth(value)) begin
                fp32_scale_pow2_down_synth = value;
            end else if (amount >= value[30:23]) begin
                fp32_scale_pow2_down_synth = {
                    value[31],
                    31'd0
                };
            end else begin
                result_exponent = {24'd0, value[30:23]} - amount;
                fp32_scale_pow2_down_synth = {
                    value[31],
                    result_exponent[7:0],
                    value[22:0]
                };
            end
        end
    endfunction

    // exp(value) for value <= 0. Stable Softmax and the GELU erf polynomial
    // only require this half-domain. Range reduction uses ln(2), followed by a
    // degree-8 Taylor polynomial on [0, ln(2)) and an exact power-of-two scale.
    function automatic logic [31:0] fp32_exp_neg_synth(
        input logic [31:0] value
    );
        localparam logic [31:0] EXP_LN2        = 32'h3F317218;
        localparam logic [31:0] EXP_INV_LN2    = 32'h3FB8AA3B;
        localparam logic [31:0] EXP_C8         = 32'h37D00D01;
        localparam logic [31:0] EXP_C7         = 32'hB9500D01;
        localparam logic [31:0] EXP_C6         = 32'h3AB60B61;
        localparam logic [31:0] EXP_C5         = 32'hBC088889;
        localparam logic [31:0] EXP_C4         = 32'h3D2AAAAB;
        localparam logic [31:0] EXP_C3         = 32'hBE2AAAAB;
        localparam logic [31:0] EXP_C2         = 32'h3F000000;
        localparam logic [31:0] EXP_C1         = 32'hBF800000;
        localparam logic [31:0] EXP_C0         = 32'h3F800000;
        logic [31:0] magnitude;
        logic [31:0] scaled;
        logic [31:0] scale_integer;
        logic [31:0] scale_fp32;
        logic [31:0] remainder;
        logic [31:0] polynomial;
        begin
            magnitude = {1'b0, value[30:0]};
            scaled = FP32_SYNTH_POS_ZERO;
            scale_integer = 32'd0;
            scale_fp32 = FP32_SYNTH_POS_ZERO;
            remainder = FP32_SYNTH_POS_ZERO;
            polynomial = FP32_SYNTH_POS_ZERO;

            if (fp32_is_nan_synth(value)) begin
                fp32_exp_neg_synth = FP32_QNAN;
            end else if (value == FP32_SYNTH_NEG_INF) begin
                fp32_exp_neg_synth = FP32_SYNTH_POS_ZERO;
            end else if (fp32_is_zero_synth(value)) begin
                fp32_exp_neg_synth = FP32_SYNTH_ONE;
            end else if (!value[31]) begin
                // The hardware contract is the non-positive half-domain.
                fp32_exp_neg_synth = FP32_QNAN;
            end else begin
                scaled = fp32_mul(magnitude, EXP_INV_LN2);
                scale_integer = fp32_to_u32_floor_synth(scaled);

                if (scale_integer >= 32'd127) begin
                    fp32_exp_neg_synth = FP32_SYNTH_POS_ZERO;
                end else begin
                    scale_fp32 = fp32_from_u32_synth(scale_integer);
                    remainder = fp32_sub_synth(
                        magnitude,
                        fp32_mul(scale_fp32, EXP_LN2)
                    );

                    // Correct a possible one-bin error caused by the rounded
                    // binary32 range-reduction multiply.
                    if (remainder[31] && !fp32_is_zero_synth(remainder) &&
                        (scale_integer != 0)) begin
                        scale_integer = scale_integer - 1'b1;
                        scale_fp32 = fp32_from_u32_synth(scale_integer);
                        remainder = fp32_sub_synth(
                            magnitude,
                            fp32_mul(scale_fp32, EXP_LN2)
                        );
                    end else if (!remainder[31] &&
                                 (remainder[30:0] >= EXP_LN2[30:0])) begin
                        scale_integer = scale_integer + 1'b1;
                        remainder = fp32_sub_synth(remainder, EXP_LN2);
                    end

                    polynomial = EXP_C8;
                    polynomial = fp32_add(
                        EXP_C7,
                        fp32_mul(remainder, polynomial)
                    );
                    polynomial = fp32_add(
                        EXP_C6,
                        fp32_mul(remainder, polynomial)
                    );
                    polynomial = fp32_add(
                        EXP_C5,
                        fp32_mul(remainder, polynomial)
                    );
                    polynomial = fp32_add(
                        EXP_C4,
                        fp32_mul(remainder, polynomial)
                    );
                    polynomial = fp32_add(
                        EXP_C3,
                        fp32_mul(remainder, polynomial)
                    );
                    polynomial = fp32_add(
                        EXP_C2,
                        fp32_mul(remainder, polynomial)
                    );
                    polynomial = fp32_add(
                        EXP_C1,
                        fp32_mul(remainder, polynomial)
                    );
                    polynomial = fp32_add(
                        EXP_C0,
                        fp32_mul(remainder, polynomial)
                    );
                    fp32_exp_neg_synth = fp32_scale_pow2_down_synth(
                        polynomial,
                        scale_integer
                    );
                end
            end
        end
    endfunction

    // Positive finite reciprocal with four Newton-Raphson refinements.
    function automatic logic [31:0] fp32_recip_positive_synth(
        input logic [31:0] value
    );
        localparam logic [31:0] RECIP_MAGIC = 32'h7EF311C3;
        logic [31:0] estimate;
        integer iteration;
        begin
            estimate = FP32_SYNTH_POS_ZERO;
            if (fp32_is_nan_synth(value) || value[31]) begin
                fp32_recip_positive_synth = FP32_QNAN;
            end else if (value == FP32_SYNTH_POS_INF) begin
                fp32_recip_positive_synth = FP32_SYNTH_POS_ZERO;
            end else if (fp32_is_zero_synth(value)) begin
                fp32_recip_positive_synth = FP32_SYNTH_POS_INF;
            end else begin
                estimate = RECIP_MAGIC - value;
                for (iteration = 0; iteration < 4; iteration = iteration + 1) begin
                    estimate = fp32_mul(
                        estimate,
                        fp32_sub_synth(
                            FP32_SYNTH_TWO,
                            fp32_mul(value, estimate)
                        )
                    );
                end
                fp32_recip_positive_synth = estimate;
            end
        end
    endfunction

    // Exact-erf-style GELU boundary using the same Abramowitz-Stegun 7.1.26
    // polynomial as the behavioral reference, evaluated entirely in binary32
    // RTL arithmetic.
    function automatic logic [31:0] fp32_gelu_synth(
        input logic [31:0] value
    );
        localparam logic [31:0] GELU_INV_SQRT2 = 32'h3F3504F3;
        localparam logic [31:0] GELU_P         = 32'h3EA7BA05;
        localparam logic [31:0] GELU_A1        = 32'h3E827906;
        localparam logic [31:0] GELU_A2        = 32'hBE91A98E;
        localparam logic [31:0] GELU_A3        = 32'h3FB5F0E3;
        localparam logic [31:0] GELU_A4        = 32'hBFBA00E3;
        localparam logic [31:0] GELU_A5        = 32'h3F87DC22;
        logic [31:0] absolute_value;
        logic [31:0] scaled_value;
        logic [31:0] reciprocal_term;
        logic [31:0] polynomial;
        logic [31:0] squared_value;
        logic [31:0] exponential;
        logic [31:0] erf_magnitude;
        logic [31:0] signed_erf;
        logic [31:0] one_plus_erf;
        logic [31:0] half_value;
        begin
            absolute_value = {1'b0, value[30:0]};
            scaled_value = FP32_SYNTH_POS_ZERO;
            reciprocal_term = FP32_SYNTH_POS_ZERO;
            polynomial = FP32_SYNTH_POS_ZERO;
            squared_value = FP32_SYNTH_POS_ZERO;
            exponential = FP32_SYNTH_POS_ZERO;
            erf_magnitude = FP32_SYNTH_POS_ZERO;
            signed_erf = FP32_SYNTH_POS_ZERO;
            one_plus_erf = FP32_SYNTH_POS_ZERO;
            half_value = FP32_SYNTH_POS_ZERO;

            if (fp32_is_nan_synth(value) ||
                (value == FP32_SYNTH_NEG_INF)) begin
                fp32_gelu_synth = FP32_QNAN;
            end else if (value == FP32_SYNTH_POS_INF) begin
                fp32_gelu_synth = FP32_SYNTH_POS_INF;
            end else if (fp32_is_zero_synth(value)) begin
                fp32_gelu_synth = FP32_SYNTH_POS_ZERO;
            end else begin
                scaled_value = fp32_mul(absolute_value, GELU_INV_SQRT2);
                reciprocal_term = fp32_recip_positive_synth(
                    fp32_add(
                        FP32_SYNTH_ONE,
                        fp32_mul(GELU_P, scaled_value)
                    )
                );

                polynomial = fp32_add(
                    fp32_mul(GELU_A5, reciprocal_term),
                    GELU_A4
                );
                polynomial = fp32_add(
                    fp32_mul(polynomial, reciprocal_term),
                    GELU_A3
                );
                polynomial = fp32_add(
                    fp32_mul(polynomial, reciprocal_term),
                    GELU_A2
                );
                polynomial = fp32_add(
                    fp32_mul(polynomial, reciprocal_term),
                    GELU_A1
                );
                polynomial = fp32_mul(polynomial, reciprocal_term);

                squared_value = fp32_mul(scaled_value, scaled_value);
                exponential = fp32_exp_neg_synth({
                    1'b1,
                    squared_value[30:0]
                });
                erf_magnitude = fp32_sub_synth(
                    FP32_SYNTH_ONE,
                    fp32_mul(polynomial, exponential)
                );

                if (erf_magnitude[31])
                    erf_magnitude = FP32_SYNTH_POS_ZERO;
                else if (erf_magnitude[30:0] > FP32_SYNTH_ONE[30:0])
                    erf_magnitude = FP32_SYNTH_ONE;

                signed_erf = value[31] ?
                             {1'b1, erf_magnitude[30:0]} :
                             erf_magnitude;
                one_plus_erf = fp32_add(FP32_SYNTH_ONE, signed_erf);
                half_value = fp32_mul(FP32_SYNTH_HALF, value);
                fp32_gelu_synth = fp32_mul(half_value, one_plus_erf);
            end
        end
    endfunction

endpackage
