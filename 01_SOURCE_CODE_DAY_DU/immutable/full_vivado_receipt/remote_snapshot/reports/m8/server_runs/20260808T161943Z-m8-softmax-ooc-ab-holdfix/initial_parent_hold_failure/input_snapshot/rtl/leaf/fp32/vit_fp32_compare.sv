`timescale 1ns/1ps

// Binary32 classification, ordered comparison, and propagating maximum.
// `maximum` is bit-for-bit compatible with
// vit_fp32_pkg::fp32_max_synth. Ordered compare outputs are deasserted when
// either input is NaN; +0 and -0 compare equal.
module vit_fp32_compare (
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic        a_is_nan,
    output logic        a_is_inf,
    output logic        a_is_zero,
    output logic        b_is_nan,
    output logic        b_is_inf,
    output logic        b_is_zero,
    output logic        unordered,
    output logic        equal,
    output logic        a_greater,
    output logic        a_greater_equal,
    output logic [31:0] maximum
);

    localparam logic [31:0] FP32_QNAN    = 32'h7FC0_0000;
    localparam logic [31:0] FP32_POS_ZERO = 32'h0000_0000;

    logic [30:0] magnitude_a;
    logic [30:0] magnitude_b;

    always @* begin
        magnitude_a = a[30:0];
        magnitude_b = b[30:0];

        a_is_nan = (a[30:23] == 8'hFF) && (a[22:0] != 23'd0);
        a_is_inf = (a[30:23] == 8'hFF) && (a[22:0] == 23'd0);
        a_is_zero = (a[30:0] == 31'd0);
        b_is_nan = (b[30:23] == 8'hFF) && (b[22:0] != 23'd0);
        b_is_inf = (b[30:23] == 8'hFF) && (b[22:0] == 23'd0);
        b_is_zero = (b[30:0] == 31'd0);

        unordered = a_is_nan || b_is_nan;
        equal = 1'b0;
        a_greater = 1'b0;

        if (!unordered) begin
            if (a_is_zero && b_is_zero) begin
                equal = 1'b1;
            end else if (a == b) begin
                equal = 1'b1;
            end else if (a[31] != b[31]) begin
                a_greater = !a[31];
            end else if (!a[31]) begin
                a_greater = (magnitude_a > magnitude_b);
            end else begin
                a_greater = (magnitude_a < magnitude_b);
            end
        end

        a_greater_equal = !unordered && (equal || a_greater);

        if (unordered) begin
            maximum = FP32_QNAN;
        end else if (a_is_zero && b_is_zero) begin
            maximum = FP32_POS_ZERO;
        end else if (a[31] != b[31]) begin
            maximum = a[31] ? b : a;
        end else if (!a[31]) begin
            maximum = (magnitude_a >= magnitude_b) ? a : b;
        end else begin
            maximum = (magnitude_a <= magnitude_b) ? a : b;
        end
    end

endmodule
