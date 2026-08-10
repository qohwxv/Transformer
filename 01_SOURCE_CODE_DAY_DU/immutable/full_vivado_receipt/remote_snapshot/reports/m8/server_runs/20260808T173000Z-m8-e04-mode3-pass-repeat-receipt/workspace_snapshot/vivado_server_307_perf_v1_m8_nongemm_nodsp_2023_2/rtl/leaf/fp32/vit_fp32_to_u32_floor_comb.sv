`timescale 1ns/1ps

// Floor a positive finite binary32 value to unsigned integer.  Negative values
// produce zero and overflow saturates.
module vit_fp32_to_u32_floor_comb (
    input  logic [31:0] value,
    output logic [31:0] result
);

    logic [23:0] mantissa;
    integer unbiased_exponent;

    always_comb begin
        mantissa = {1'b1, value[22:0]};
        unbiased_exponent = {24'd0, value[30:23]} - 32'd127;

        if (value[31] || (value[30:23] < 127))
            result = 32'd0;
        else if ((value[30:23] == 8'hff) ||
                 (unbiased_exponent >= 32))
            result = 32'hffff_ffff;
        else if (unbiased_exponent >= 23)
            result = {8'd0, mantissa} << (unbiased_exponent - 23);
        else
            result = {8'd0, mantissa} >> (23 - unbiased_exponent);
    end

endmodule
