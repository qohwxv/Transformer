`timescale 1ns/1ps

// IEEE-754 binary32 to binary16 conversion.
//
// Finite values are rounded once with round-to-nearest, ties-to-even.  Half
// subnormals are generated gradually; binary32 subnormals are all below the
// half-precision rounding threshold and therefore become signed zero.  NaNs
// are canonicalized to the positive quiet-NaN required by the M6/M7 numerical
// contract.  The implementation is purely combinational and uses no DSP.
(* use_dsp = "no" *)
module vit_fp32_to_fp16_rne_gradual (
    input  logic [31:0] fp32_i,
    output logic [15:0] fp16_o
);

    logic        sign;
    logic [7:0]  exponent;
    logic [22:0] fraction;
    logic [23:0] significand;

    logic [10:0] normal_retained;
    logic [11:0] normal_rounded;
    logic        normal_round_up;

    logic [24:0] subnormal_truncated;
    logic [24:0] subnormal_rounded;
    logic        subnormal_guard;
    logic        subnormal_sticky;
    logic        subnormal_round_up;

    integer unbiased_exponent;
    integer half_exponent;
    integer subnormal_shift;
    integer sticky_index;

    always_comb begin
        sign = fp32_i[31];
        exponent = fp32_i[30:23];
        fraction = fp32_i[22:0];
        significand = {1'b1, fraction};

        fp16_o = {sign, 15'd0};

        normal_retained = {1'b1, fraction[22:13]};
        normal_round_up =
            fraction[12] && ((|fraction[11:0]) || normal_retained[0]);
        normal_rounded =
            {1'b0, normal_retained} + {{11{1'b0}}, normal_round_up};

        subnormal_truncated = 25'd0;
        subnormal_rounded = 25'd0;
        subnormal_guard = 1'b0;
        subnormal_sticky = 1'b0;
        subnormal_round_up = 1'b0;

        unbiased_exponent = 0;
        half_exponent = 0;
        subnormal_shift = 0;

        if (exponent == 8'hff) begin
            if (fraction == 23'd0)
                fp16_o = {sign, 5'h1f, 10'd0};
            else
                fp16_o = 16'h7e00;
        end else if (exponent == 8'd0) begin
            // The largest binary32 subnormal is far below half of the least
            // positive binary16 subnormal, so RNE always produces signed zero.
            fp16_o = {sign, 15'd0};
        end else begin
            unbiased_exponent = integer'($unsigned(exponent)) - 127;

            if (unbiased_exponent > 15) begin
                fp16_o = {sign, 5'h1f, 10'd0};
            end else if (unbiased_exponent >= -14) begin
                if (normal_rounded[11]) begin
                    half_exponent = unbiased_exponent + 16;
                    if (half_exponent >= 31)
                        fp16_o = {sign, 5'h1f, 10'd0};
                    else
                        fp16_o = {sign, half_exponent[4:0], 10'd0};
                end else begin
                    half_exponent = unbiased_exponent + 15;
                    fp16_o = {
                        sign,
                        half_exponent[4:0],
                        normal_rounded[9:0]
                    };
                end
            end else if (unbiased_exponent >= -25) begin
                // Scale the 24-bit binary32 significand into units of 2^-24,
                // the binary16 subnormal quantum.  For E=-15..-25 the shift
                // range is 14..24, so every dynamic index below is bounded.
                subnormal_shift = -unbiased_exponent - 1;
                subnormal_truncated =
                    {1'b0, significand} >> subnormal_shift;
                subnormal_guard = significand[subnormal_shift-1];
                subnormal_sticky = 1'b0;
                for (sticky_index = 0; sticky_index < 24;
                     sticky_index = sticky_index + 1)
                    if (sticky_index < (subnormal_shift - 1))
                        subnormal_sticky =
                            subnormal_sticky | significand[sticky_index];
                subnormal_round_up =
                    subnormal_guard &&
                    (subnormal_sticky || subnormal_truncated[0]);
                subnormal_rounded =
                    subnormal_truncated +
                    {{24{1'b0}}, subnormal_round_up};

                if (subnormal_rounded >= 25'h0000400)
                    fp16_o = {sign, 5'd1, 10'd0};
                else
                    fp16_o = {sign, 5'd0, subnormal_rounded[9:0]};
            end else begin
                fp16_o = {sign, 15'd0};
            end
        end
    end

endmodule
