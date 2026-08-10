`timescale 1ns/1ps

// Scale a positive normal binary32 value by 2^-amount by changing its exponent.
module vit_fp32_scale_pow2_down_comb (
    input  logic [31:0] value,
    input  logic [31:0] amount,
    output logic [31:0] result
);

    logic value_nan;
    logic value_inf;
    logic value_zero;
    integer result_exponent;

    always_comb begin
        value_nan = (value[30:23] == 8'hff) &&
                    (value[22:0] != 23'd0);
        value_inf = (value[30:23] == 8'hff) &&
                    (value[22:0] == 23'd0);
        value_zero = (value[30:0] == 31'd0);
        result_exponent = 0;

        if (value_nan)
            result = 32'h7fc0_0000;
        else if (value_inf || value_zero)
            result = value;
        else if (amount >= value[30:23])
            result = {value[31], 31'd0};
        else begin
            result_exponent = {24'd0, value[30:23]} - amount;
            result = {
                value[31],
                result_exponent[7:0],
                value[22:0]
            };
        end
    end

endmodule
