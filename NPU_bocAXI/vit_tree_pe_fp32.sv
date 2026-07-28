`timescale 1ns/1ps

module vit_tree_pe_fp32 (
    input  logic          clk,
    input  logic          rst,
    input  logic          clear_accumulator,
    input  logic          step_valid,
    input  logic          finish,
    input  logic          bias_enable,
    input  logic [15:0]   lane_valid,
    input  logic [511:0]  activation_lanes,
    input  logic [511:0]  weight_lanes,
    input  logic [31:0]   bias,
    output logic [31:0]   result
);

    import vit_fp32_pkg::*;

    // n=16 vector PE:
    //   16 multipliers
    //   8 + 4 + 2 + 1 = 15 tree adders
    //   1 output-stationary accumulator adder
    logic [31:0] product [0:15];
    logic [31:0] tree_l1 [0:7];
    logic [31:0] tree_l2 [0:3];
    logic [31:0] tree_l3 [0:1];
    logic [31:0] dot_partial;
    logic [31:0] accumulator;

    integer lane;
    integer pair_index;

    always_comb begin
        for (lane = 0; lane < 16; lane = lane + 1) begin
            if (lane_valid[lane]) begin
                product[lane] = fp32_mul(
                    activation_lanes[lane*32 +: 32],
                    weight_lanes[lane*32 +: 32]
                );
            end else begin
                // Suppress a K-tail lane before the multiplier. Merely forcing
                // one operand to zero could still produce NaN for 0*Inf/NaN.
                product[lane] = 32'd0;
            end
        end

        for (pair_index = 0; pair_index < 8; pair_index = pair_index + 1)
            tree_l1[pair_index] = fp32_add(product[2*pair_index], product[2*pair_index+1]);

        for (pair_index = 0; pair_index < 4; pair_index = pair_index + 1)
            tree_l2[pair_index] = fp32_add(tree_l1[2*pair_index], tree_l1[2*pair_index+1]);

        for (pair_index = 0; pair_index < 2; pair_index = pair_index + 1)
            tree_l3[pair_index] = fp32_add(tree_l2[2*pair_index], tree_l2[2*pair_index+1]);

        dot_partial = fp32_add(tree_l3[0], tree_l3[1]);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            accumulator <= 32'd0;
            result <= 32'd0;
        end else if (clear_accumulator) begin
            accumulator <= 32'd0;
            result <= 32'd0;
        end else begin
            if (step_valid)
                accumulator <= fp32_add(accumulator, dot_partial);

            // finish is asserted one cycle after the runtime job's final K
            // chunk, so the accumulator already contains every partial sum.
            if (finish) begin
                if (bias_enable)
                    result <= fp32_add(accumulator, bias);
                else
                    result <= accumulator;
            end
        end
    end

endmodule
