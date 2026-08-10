`timescale 1ns/1ps

// One-bit-per-cycle unsigned multiplier.  The shift/add implementation is
// intentionally small and contains no '*' operator, DSP primitive, or vendor
// IP.  A single instance can be shared by descriptor/control logic.
(* use_dsp = "no" *)
module vit_u32_mul_iterative_nodsp (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic [31:0] operand_a,
    input  logic [31:0] operand_b,
    output logic        busy,
    output logic        done,
    output logic [63:0] product
);

    logic [63:0] shifted_multiplicand;
    logic [31:0] shifted_multiplier;
    logic [5:0]  bit_index;

    always_ff @(posedge clk) begin
        if (rst) begin
            busy                   <= 1'b0;
            done                   <= 1'b0;
            product                <= 64'd0;
            shifted_multiplicand   <= 64'd0;
            shifted_multiplier     <= 32'd0;
            bit_index              <= 6'd0;
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                busy                 <= 1'b1;
                product              <= 64'd0;
                shifted_multiplicand <= {32'd0, operand_a};
                shifted_multiplier   <= operand_b;
                bit_index            <= 6'd0;
            end else if (busy) begin
                if (shifted_multiplier[0])
                    product <= product + shifted_multiplicand;

                shifted_multiplicand <= shifted_multiplicand << 1;
                shifted_multiplier   <= shifted_multiplier >> 1;

                if (bit_index == 6'd31) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end else begin
                    bit_index <= bit_index + 1'b1;
                end
            end
        end
    end

endmodule
