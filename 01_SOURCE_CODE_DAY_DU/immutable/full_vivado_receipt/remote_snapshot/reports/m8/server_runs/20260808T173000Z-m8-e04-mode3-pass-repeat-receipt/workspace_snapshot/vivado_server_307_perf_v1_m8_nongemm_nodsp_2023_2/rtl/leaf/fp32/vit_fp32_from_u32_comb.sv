`timescale 1ns/1ps

// Unsigned integer to binary32 conversion with round-to-nearest-even.
module vit_fp32_from_u32_comb (
    input  logic [31:0] value,
    output logic [31:0] result
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

    always_comb begin
        wide_value = {32'd0, value};
        shifted_value = 64'd0;
        remainder_mask = 64'd0;
        remainder = 64'd0;
        halfway = 64'd0;
        rounded_mantissa = 25'd0;
        msb_index = 0;
        right_shift = 0;
        biased_exponent = 0;
        result = 32'd0;

        for (bit_index = 0; bit_index < 32; bit_index = bit_index + 1)
            if (value[bit_index])
                msb_index = bit_index;

        if (value != 0) begin
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
                result = 32'h7f80_0000;
            else
                result = {
                    1'b0,
                    biased_exponent[7:0],
                    rounded_mantissa[22:0]
                };
        end
    end

endmodule
