`timescale 1ns/1ps

// Convert the exact binary32 representation of a normal binary16 product to
// a signed fixed-point addend with LSB 2^-48.
//
// For normal FP16 operands the product exponent is 99..158.  Its 24-bit FP32
// significand therefore shifts by -3..56 relative to 2^-48.  The only right
// shifts discard zeros introduced by the exact FP16-to-FP32 product packing;
// alignment_lost must consequently remain zero for a valid M6 product.
module vit_fp32_product_to_fixed_exact #(
    parameter integer ACC_WIDTH = 93,
    parameter integer ACC_LSB = -48
) (
    input  logic [31:0] product,
    input  logic        product_nonfinite,
    output logic signed [ACC_WIDTH-1:0] addend,
    output logic                         alignment_lost,
    output logic                         range_overflow
);

    logic        product_sign;
    logic [7:0]  product_exponent;
    logic [22:0] product_fraction;
    logic [23:0] product_mantissa;
    logic [ACC_WIDTH-1:0] magnitude;
    integer shift_amount;
    integer right_shift;
    integer discarded_index;

    always_comb begin
        product_sign = product[31];
        product_exponent = product[30:23];
        product_fraction = product[22:0];
        product_mantissa = {1'b1, product_fraction};
        magnitude = '0;
        addend = '0;
        alignment_lost = 1'b0;
        range_overflow = 1'b0;
        shift_amount = 0;
        right_shift = 0;

        if (!product_nonfinite && (product_exponent != 8'd0)) begin
            // FP32 value = mantissa * 2^(exponent-150).  Divide by the
            // fixed-point quantum 2^ACC_LSB to obtain the integer addend.
            shift_amount =
                {24'd0, product_exponent} - 150 - ACC_LSB;
            if (shift_amount >= 0) begin
                if ((shift_amount + 23) >= (ACC_WIDTH - 1)) begin
                    range_overflow = 1'b1;
                end else begin
                    magnitude[23:0] = product_mantissa;
                    magnitude = magnitude << shift_amount;
                end
            end else begin
                right_shift = -shift_amount;
                if (right_shift >= 24) begin
                    magnitude = '0;
                    alignment_lost = |product_mantissa;
                end else begin
                    magnitude[23:0] = product_mantissa >> right_shift;
                    for (discarded_index = 0;
                         discarded_index < 24;
                         discarded_index = discarded_index + 1)
                        if (discarded_index < right_shift)
                            alignment_lost = alignment_lost |
                                product_mantissa[discarded_index];
                end
            end

            if (!range_overflow) begin
                if (product_sign)
                    addend = -$signed(magnitude);
                else
                    addend = $signed(magnitude);
            end
        end
    end

endmodule
