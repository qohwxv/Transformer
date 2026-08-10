`timescale 1ns/1ps

// One vector lane.  FP32 arithmetic is instantiated as visible leaf hardware
// instead of being hidden in package function calls.
module vit_vector_lane_alu (
    input  logic          lane_active,
    input  logic [1:0]    mode,
    input  logic          mask_enable,
    input  logic [31:0]   input_a,
    input  logic [31:0]   input_b,
    input  logic [31:0]   scalar,
    output logic [31:0]   result
);

    localparam logic [1:0] MODE_ADD        = 2'd0;
    localparam logic [1:0] MODE_SCALE_MASK = 2'd1;
    localparam logic [31:0] FP32_QNAN      = 32'h7fc0_0000;

    logic [31:0] scaled;
    logic [31:0] add_operand_a;
    logic [31:0] add_result;

    vit_fp32_mul_comb_nodsp u_multiplier (
        .a      (input_a),
        .b      (scalar),
        .result (scaled)
    );

    assign add_operand_a = (mode == MODE_ADD) ? input_a : scaled;

    vit_fp32_add_comb u_adder (
        .a      (add_operand_a),
        .b      (input_b),
        .result (add_result)
    );

    always_comb begin
        if (!lane_active)
            result = 32'd0;
        else begin
            case (mode)
                MODE_ADD:
                    result = add_result;
                MODE_SCALE_MASK:
                    result = mask_enable ? add_result : scaled;
                default:
                    result = FP32_QNAN;
            endcase
        end
    end

endmodule
