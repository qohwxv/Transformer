`timescale 1ns/1ps

// Parallel vector datapath.  Each generated lane is a separately visible ALU
// instance in the RTL and post-synthesis hierarchy.
module vit_vector_datapath #(
    parameter integer LANES = 16
) (
    input  logic [1:0]              mode,
    input  logic                    mask_enable,
    input  logic [31:0]             scalar,
    input  logic [LANES-1:0]        lane_mask,
    input  logic [LANES*32-1:0]     input_a,
    input  logic [LANES*32-1:0]     input_b,
    output logic [LANES*32-1:0]     result_data
);

    genvar lane;
    generate
        for (lane = 0; lane < LANES; lane = lane + 1) begin : gen_lane
            vit_vector_lane_alu u_lane (
                .lane_active (lane_mask[lane]),
                .mode        (mode),
                .mask_enable (mask_enable),
                .input_a     (input_a[lane*32 +: 32]),
                .input_b     (input_b[lane*32 +: 32]),
                .scalar      (scalar),
                .result      (result_data[lane*32 +: 32])
            );
        end
    endgenerate

endmodule
