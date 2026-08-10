`timescale 1ns/1ps

// Fixed-shape balanced FP32 reduction:
//   16 inputs -> 8 -> 4 -> 2 -> 1.
//
// Keeping each adder as an explicit leaf instance makes the PE resource tree
// visible in the Vivado hierarchy instead of hiding it inside a package
// function.
module vit_fp32_reduce16 (
    input  logic [16*32-1:0] values,
    output logic [31:0]      result
);

    logic [8*32-1:0] level_1;
    logic [4*32-1:0] level_2;
    logic [2*32-1:0] level_3;

    genvar add_index;
    generate
        for (add_index = 0; add_index < 8; add_index = add_index + 1) begin : gen_level_1
            vit_fp32_add_comb u_add (
                .a      (values[(2*add_index)*32 +: 32]),
                .b      (values[(2*add_index+1)*32 +: 32]),
                .result (level_1[add_index*32 +: 32])
            );
        end

        for (add_index = 0; add_index < 4; add_index = add_index + 1) begin : gen_level_2
            vit_fp32_add_comb u_add (
                .a      (level_1[(2*add_index)*32 +: 32]),
                .b      (level_1[(2*add_index+1)*32 +: 32]),
                .result (level_2[add_index*32 +: 32])
            );
        end

        for (add_index = 0; add_index < 2; add_index = add_index + 1) begin : gen_level_3
            vit_fp32_add_comb u_add (
                .a      (level_2[(2*add_index)*32 +: 32]),
                .b      (level_2[(2*add_index+1)*32 +: 32]),
                .result (level_3[add_index*32 +: 32])
            );
        end
    endgenerate

    vit_fp32_add_comb u_add_root (
        .a      (level_3[0*32 +: 32]),
        .b      (level_3[1*32 +: 32]),
        .result (result)
    );

endmodule
