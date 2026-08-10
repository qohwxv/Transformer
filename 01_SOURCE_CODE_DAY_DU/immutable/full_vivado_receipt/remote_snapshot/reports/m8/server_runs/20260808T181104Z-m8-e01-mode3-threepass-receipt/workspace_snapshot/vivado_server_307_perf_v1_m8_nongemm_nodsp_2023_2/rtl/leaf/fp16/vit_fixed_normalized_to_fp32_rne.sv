`timescale 1ns/1ps

// Second half of the pipelined fixed-to-FP32 conversion.  The magnitude and
// leading-one index are registered before this block, limiting the 100-MHz
// path to normalization, sticky generation and RNE packing.
module vit_fixed_normalized_to_fp32_rne #(
    parameter integer ACC_WIDTH = 93,
    parameter integer ACC_LSB = -48,
    parameter integer INDEX_WIDTH = $clog2(ACC_WIDTH)
) (
    input  logic [ACC_WIDTH-1:0]   magnitude,
    input  logic                   value_sign,
    input  logic                   is_zero,
    input  logic [INDEX_WIDTH-1:0] leading_index,
    input  logic                   invalid,
    input  logic                   force_inf,
    input  logic                   force_inf_sign,
    output logic [31:0]            result
);

    localparam logic [31:0] FP32_QNAN = 32'h7FC0_0000;

    logic [23:0] mantissa_main;
    logic [24:0] rounded_mantissa;
    logic guard_bit;
    logic sticky_bit;
    logic round_up;
    logic [ACC_WIDTH-1:0] shifted_magnitude;
    integer leading_index_integer;
    integer shift_right;
    integer shift_left;
    integer exponent_field;
    integer sticky_index;

    always_comb begin
        mantissa_main = 24'd0;
        rounded_mantissa = 25'd0;
        guard_bit = 1'b0;
        sticky_bit = 1'b0;
        round_up = 1'b0;
        shifted_magnitude = '0;
        leading_index_integer = integer'(leading_index);
        shift_right = 0;
        shift_left = 0;
        exponent_field = leading_index_integer + ACC_LSB + 127;

        if (invalid) begin
            result = FP32_QNAN;
        end else if (force_inf) begin
            result = {force_inf_sign, 8'hFF, 23'd0};
        end else if (is_zero) begin
            result = 32'd0;
        end else begin
            if (leading_index_integer > 23) begin
                shift_right = leading_index_integer - 23;
                shifted_magnitude = magnitude >> shift_right;
                mantissa_main = shifted_magnitude[23:0];
                guard_bit = magnitude[shift_right - 1];
                for (sticky_index = 0;
                     sticky_index < ACC_WIDTH;
                     sticky_index = sticky_index + 1)
                    if (sticky_index < (shift_right - 1))
                        sticky_bit = sticky_bit | magnitude[sticky_index];
            end else begin
                shift_left = 23 - leading_index_integer;
                shifted_magnitude = magnitude << shift_left;
                mantissa_main = shifted_magnitude[23:0];
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
