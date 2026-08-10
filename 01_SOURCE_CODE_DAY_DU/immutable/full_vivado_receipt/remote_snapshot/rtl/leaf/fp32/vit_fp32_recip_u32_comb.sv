`timescale 1ns/1ps

// Convert the exact mathematical value 1/value to binary32 with unsigned
// integer arithmetic and round-to-nearest-even.  This is configuration-path
// logic; USE_DSP keeps the inferred divider and surrounding arithmetic in
// fabric for the strict DSP=0 build.
(* use_dsp = "no" *)
module vit_fp32_recip_u32_comb (
    input  logic [31:0] value,
    output logic [31:0] result
);

    localparam logic [31:0] FP32_POS_ZERO = 32'h0000_0000;
    localparam logic [31:0] FP32_POS_INF  = 32'h7f80_0000;

    logic [63:0] denominator;
    logic [63:0] numerator;
    logic [63:0] quotient;
    logic [63:0] remainder;
    logic [63:0] rounded_quotient;
    logic [63:0] doubled_remainder;
    logic        is_power_of_two;
    integer      bit_index;
    integer      msb_index;
    integer      unbiased_exponent;
    integer      biased_exponent;
    integer      numerator_shift;

    always_comb begin
        denominator       = {32'd0, value};
        numerator         = 64'd0;
        quotient          = 64'd0;
        remainder         = 64'd0;
        rounded_quotient  = 64'd0;
        doubled_remainder = 64'd0;
        is_power_of_two   = 1'b0;
        msb_index         = 0;
        unbiased_exponent = 0;
        biased_exponent   = 0;
        numerator_shift   = 0;
        result            = FP32_POS_ZERO;

        for (bit_index = 0; bit_index < 32; bit_index = bit_index + 1)
            if (value[bit_index])
                msb_index = bit_index;

        if (value == 0) begin
            result = FP32_POS_INF;
        end else begin
            is_power_of_two = ((value & (value - 1'b1)) == 0);
            if (is_power_of_two)
                unbiased_exponent = -msb_index;
            else
                unbiased_exponent = -(msb_index + 1);

            numerator_shift = 23 - unbiased_exponent;
            numerator = 64'd1 << numerator_shift;
            quotient = numerator / denominator;
            remainder = numerator % denominator;
            rounded_quotient = quotient;
            doubled_remainder = remainder << 1;

            if ((doubled_remainder > denominator) ||
                ((doubled_remainder == denominator) && quotient[0]))
                rounded_quotient = quotient + 1'b1;

            if (rounded_quotient[24]) begin
                rounded_quotient = rounded_quotient >> 1;
                unbiased_exponent = unbiased_exponent + 1;
            end

            biased_exponent = unbiased_exponent + 127;
            if (biased_exponent >= 255)
                result = FP32_POS_INF;
            else if (biased_exponent <= 0)
                result = FP32_POS_ZERO;
            else
                result = {
                    1'b0,
                    biased_exponent[7:0],
                    rounded_quotient[22:0]
                };
        end
    end

endmodule
