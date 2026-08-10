`timescale 1ns/1ps

// One exact 16-lane FP32 dot-product datapath.
//
// The balanced reduction order is intentionally identical to the original PE:
// 16 products -> 8 sums -> 4 sums -> 2 sums -> 1 partial sum. Keeping this
// operation separate allows the PE array to share one expensive dot-product
// datapath across all output-stationary accumulators without changing FP32
// rounding order.
(* use_dsp = "no" *)
module vit_gemm_dot16 (
    input  logic [15:0]  lane_valid,
    input  logic [511:0] activation_lanes,
    input  logic [511:0] weight_lanes,
    output logic [31:0]  partial_sum
);

    logic [511:0] raw_products;
    logic [511:0] valid_products;

    genvar lane_index;
    generate
        for (lane_index = 0; lane_index < 16;
             lane_index = lane_index + 1) begin : gen_lane_multiplier
            vit_fp32_mul_comb_nodsp u_multiplier (
                .a      (activation_lanes[lane_index*32 +: 32]),
                .b      (weight_lanes[lane_index*32 +: 32]),
                .result (raw_products[lane_index*32 +: 32])
            );

            // Suppress a K-tail lane before it can affect the reduction.
            // This is stronger than forcing an operand to zero because
            // 0*Inf and 0*NaN must not inject a NaN into a valid dot product.
            assign valid_products[lane_index*32 +: 32] =
                lane_valid[lane_index]
                    ? raw_products[lane_index*32 +: 32]
                    : 32'd0;
        end
    endgenerate

    vit_fp32_reduce16 u_reduction_tree (
        .values (valid_products),
        .result (partial_sum)
    );

endmodule
