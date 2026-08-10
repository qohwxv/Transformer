`timescale 1ns/1ps

// Round a signed fixed-point value to IEEE-754 binary32 using round-to-nearest,
// ties-to-even.  M6 uses ACC_WIDTH=93 and ACC_LSB=-48.  Every non-zero value
// in that contract is a normal FP32 number; generic underflow is flushed to
// signed zero and generic overflow becomes signed infinity.
module vit_fixed_to_fp32_rne #(
    parameter integer ACC_WIDTH = 93,
    parameter integer ACC_LSB   = -48
) (
    input  logic signed [ACC_WIDTH-1:0] value,
    input  logic                         invalid,
    input  logic                         force_inf,
    input  logic                         force_inf_sign,
    output logic [31:0]                  result
);

    localparam logic [31:0] FP32_QNAN = 32'h7FC0_0000;

    logic value_sign;
    logic [ACC_WIDTH-1:0] magnitude;
    logic [23:0] mantissa_main;
    logic [24:0] rounded_mantissa;
    logic guard_bit;
    logic sticky_bit;
    logic round_up;
    logic found_leading_one;
    integer leading_index;
    integer shift_right;
    integer shift_left;
    integer exponent_unbiased;
    integer exponent_field;
    integer scan_index;
    integer sticky_index;

    always_comb begin
        value_sign = value[ACC_WIDTH-1];
        if (value_sign)
            magnitude = (~value) + {{(ACC_WIDTH-1){1'b0}}, 1'b1};
        else
            magnitude = value;

        mantissa_main = 24'd0;
        rounded_mantissa = 25'd0;
        guard_bit = 1'b0;
        sticky_bit = 1'b0;
        round_up = 1'b0;
        found_leading_one = 1'b0;
        leading_index = 0;
        shift_right = 0;
        shift_left = 0;
        exponent_unbiased = 0;
        exponent_field = 0;

        for (scan_index = ACC_WIDTH - 1;
             scan_index >= 0;
             scan_index = scan_index - 1) begin
            if (!found_leading_one && magnitude[scan_index]) begin
                found_leading_one = 1'b1;
                leading_index = scan_index;
            end
        end

        if (invalid) begin
            result = FP32_QNAN;
        end else if (force_inf) begin
            result = {force_inf_sign, 8'hFF, 23'd0};
        end else if (!found_leading_one) begin
            result = 32'd0;
        end else begin
            exponent_unbiased = leading_index + ACC_LSB;
            exponent_field = exponent_unbiased + 127;

            if (leading_index > 23) begin
                shift_right = leading_index - 23;
                mantissa_main = magnitude >> shift_right;
                guard_bit = magnitude[shift_right - 1];
                sticky_bit = 1'b0;
                for (sticky_index = 0;
                     sticky_index < ACC_WIDTH;
                     sticky_index = sticky_index + 1)
                    if (sticky_index < (shift_right - 1))
                        sticky_bit = sticky_bit | magnitude[sticky_index];
            end else begin
                shift_left = 23 - leading_index;
                mantissa_main = magnitude << shift_left;
            end

            round_up = guard_bit && (sticky_bit || mantissa_main[0]);
            rounded_mantissa =
                {1'b0, mantissa_main} + {{24{1'b0}}, round_up};

            if (rounded_mantissa[24]) begin
                mantissa_main = rounded_mantissa[24:1];
                exponent_field = exponent_field + 1;
            end else begin
                mantissa_main = rounded_mantissa[23:0];
            end

            if (exponent_field >= 255)
                result = {value_sign, 8'hFF, 23'd0};
            else if (exponent_field <= 0)
                result = {value_sign, 31'd0};
            else
                result = {
                    value_sign,
                    exponent_field[7:0],
                    mantissa_main[22:0]
                };
        end
    end

endmodule
