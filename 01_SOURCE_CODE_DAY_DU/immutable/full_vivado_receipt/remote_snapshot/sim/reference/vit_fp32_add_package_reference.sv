`timescale 1ns/1ps

// Simulation-only oracle for the production combinational adder.  Keep this
// module out of every production/synthesis filelist: fp32_add intentionally
// retains the historical procedural implementation for independent A/B use.
module vit_fp32_add_package_reference (
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] result
);

    import vit_fp32_pkg::*;

    always_comb begin
        result = fp32_add(a, b);
    end

endmodule
