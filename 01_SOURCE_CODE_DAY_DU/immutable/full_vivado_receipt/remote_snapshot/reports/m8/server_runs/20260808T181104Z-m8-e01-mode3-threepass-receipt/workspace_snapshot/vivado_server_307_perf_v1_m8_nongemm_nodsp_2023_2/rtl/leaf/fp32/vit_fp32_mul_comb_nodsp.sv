`timescale 1ns/1ps

// Combinational binary32 multiplier used by the synthesizable ViT datapath.
//
// This module intentionally preserves the arithmetic contract of
// vit_fp32_pkg::fp32_mul:
//   * round to nearest, ties to even
//   * flush subnormal inputs and underflowed outputs to signed zero
//   * return the canonical quiet NaN 0x7fc00000
//
// USE_DSP is attached both to the hierarchy and the inferred mantissa
// multiplier so Vivado implements the 24x24 product in fabric.
(* use_dsp = "no" *)
module vit_fp32_mul_comb_nodsp (
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] result
);

    localparam logic [31:0] FP32_QNAN = 32'h7FC0_0000;

    logic        sign_result;
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
    logic [23:0] mant_a;
    logic [23:0] mant_b;
    (* use_dsp = "no" *) logic [47:0] product;
    logic [23:0] mantissa;
    logic        guard_bit;
    logic        sticky_bit;
    logic        round_up;
    logic [24:0] rounded_mantissa;
    integer      exp_result;

    always @* begin
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

        if (a_nan || b_nan ||
            ((a_inf || b_inf) && (a_zero || b_zero))) begin
            result = FP32_QNAN;
        end else if (a_inf || b_inf) begin
            result = {sign_result, 8'hFF, 23'd0};
        end else if (a_zero || b_zero) begin
            result = {sign_result, 31'd0};
        end else begin
            if (product[47]) begin
                mantissa = product[47:24];
                guard_bit = product[23];
                sticky_bit = |product[22:0];
                exp_result = {24'd0, exp_a};
                exp_result =
                    exp_result + {24'd0, exp_b} - 127 + 1;
            end else begin
                mantissa = product[46:23];
                guard_bit = product[22];
                sticky_bit = |product[21:0];
                exp_result = {24'd0, exp_a};
                exp_result =
                    exp_result + {24'd0, exp_b} - 127;
            end

            round_up = guard_bit && (sticky_bit || mantissa[0]);
            rounded_mantissa =
                {1'b0, mantissa} + {24'd0, round_up};

            if (rounded_mantissa[24]) begin
                mantissa = rounded_mantissa[24:1];
                exp_result = exp_result + 1;
            end else begin
                mantissa = rounded_mantissa[23:0];
            end

            if (exp_result >= 255)
                result = {sign_result, 8'hFF, 23'd0};
            else if (exp_result <= 0)
                result = {sign_result, 31'd0};
            else
                result = {
                    sign_result,
                    exp_result[7:0],
                    mantissa[22:0]
                };
        end
    end

endmodule
