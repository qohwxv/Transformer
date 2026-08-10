`timescale 1ns/1ps

// Runtime tail mask shared by vector-style engines.
module vit_lane_mask #(
    parameter integer LANES = 16
) (
    input  logic [31:0]             base_index,
    input  logic [31:0]             length,
    output logic [LANES-1:0]        lane_mask
);

    integer lane;

    always_comb begin
        lane_mask = '0;
        for (lane = 0; lane < LANES; lane = lane + 1)
            lane_mask[lane] =
                (({1'b0, base_index} + lane) < {1'b0, length});
    end

endmodule
