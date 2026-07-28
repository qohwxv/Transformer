`timescale 1ns/1ps

// Sixteen-lane FP32 vector engine for the first functional Phase-D datapath.
//
// MODE_ADD:
//     result[i] = input_a[i] + input_b[i]
//
// MODE_SCALE_MASK:
//     scaled = input_a[i] * cfg_scalar
//     result[i] = cfg_mask_enable ? scaled + input_b[i] : scaled
//
// input_b is therefore the second residual/vector operand in MODE_ADD and the
// additive attention mask in MODE_SCALE_MASK.  Bypassing the mask is explicit:
// a disabled mask bus may contain arbitrary data without affecting the result.
module vit_vector_engine_fp32 #(
    parameter integer LANES = 16
)(
    input  logic                    clk,
    input  logic                    rst,

    input  logic                    start,
    input  logic [1:0]              cfg_mode,
    input  logic [31:0]             cfg_length,
    input  logic [31:0]             cfg_scalar,
    input  logic                    cfg_mask_enable,
    output logic                    busy,
    output logic                    done,
    output logic                    config_error,

    // One packed vector is accepted only when data_request and data_valid are
    // both high. element_base is the first flat element represented by it.
    output logic                    data_request,
    input  logic                    data_valid,
    output logic [31:0]             element_base,
    input  logic [LANES*32-1:0]     input_a,
    input  logic [LANES*32-1:0]     input_b,

    // A result vector and its metadata remain stable until result_ready.
    output logic                    result_valid,
    input  logic                    result_ready,
    output logic [31:0]             result_base,
    output logic [LANES-1:0]        result_lane_mask,
    output logic [LANES*32-1:0]     result_data
);

    import vit_fp32_pkg::*;

    localparam logic [1:0] MODE_ADD        = 2'd0;
    localparam logic [1:0] MODE_SCALE_MASK = 2'd1;
    localparam logic [32:0] LANES_WIDE = LANES;

    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_COMPUTE,
        STATE_WRITE,
        STATE_DONE
    } state_t;

    state_t state;

    logic [1:0] active_mode;
    logic [31:0] active_length;
    logic [31:0] active_scalar;
    logic active_mask_enable;
    logic [LANES-1:0] current_lane_mask;
    logic [LANES*32-1:0] computed_data;
    logic [LANES*32-1:0] result_data_reg;
    logic [31:0] result_base_reg;
    logic [LANES-1:0] result_lane_mask_reg;

    integer lane;

    assign busy = (state != STATE_IDLE);
    assign done = (state == STATE_DONE);
    assign data_request = (state == STATE_COMPUTE);
    assign result_valid = (state == STATE_WRITE);
    assign result_base = result_base_reg;
    assign result_lane_mask = result_lane_mask_reg;
    assign result_data = result_data_reg;

    always_comb begin
        current_lane_mask = '0;
        computed_data = '0;

        for (lane = 0; lane < LANES; lane = lane + 1) begin
            if (({1'b0, element_base} + lane) <
                {1'b0, active_length}) begin
                current_lane_mask[lane] = 1'b1;
                case (active_mode)
                    MODE_ADD: begin
                        computed_data[lane*32 +: 32] = fp32_add(
                            input_a[lane*32 +: 32],
                            input_b[lane*32 +: 32]
                        );
                    end

                    MODE_SCALE_MASK: begin
                        if (active_mask_enable) begin
                            computed_data[lane*32 +: 32] = fp32_add(
                                fp32_mul(input_a[lane*32 +: 32], active_scalar),
                                input_b[lane*32 +: 32]
                            );
                        end else begin
                            computed_data[lane*32 +: 32] = fp32_mul(
                                input_a[lane*32 +: 32],
                                active_scalar
                            );
                        end
                    end

                    default: computed_data[lane*32 +: 32] = FP32_QNAN;
                endcase
            end
        end
    end

    initial begin
        if (LANES != 16)
            $fatal(1, "vit_vector_engine_fp32 requires LANES=16");
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state                    <= STATE_IDLE;
            config_error             <= 1'b0;
            active_mode              <= MODE_ADD;
            active_length            <= 32'd0;
            active_scalar            <= 32'd0;
            active_mask_enable       <= 1'b0;
            element_base             <= 32'd0;
            result_data_reg          <= '0;
            result_base_reg          <= 32'd0;
            result_lane_mask_reg     <= '0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (start) begin
                        element_base <= 32'd0;
                        if ((cfg_length == 0) ||
                            ((cfg_mode != MODE_ADD) &&
                             (cfg_mode != MODE_SCALE_MASK))) begin
                            config_error <= 1'b1;
                            state <= STATE_DONE;
                        end else begin
                            config_error       <= 1'b0;
                            active_mode        <= cfg_mode;
                            active_length      <= cfg_length;
                            active_scalar      <= cfg_scalar;
                            active_mask_enable <= cfg_mask_enable;
                            state              <= STATE_COMPUTE;
                        end
                    end
                end

                STATE_COMPUTE: begin
                    if (data_valid) begin
                        result_data_reg      <= computed_data;
                        result_base_reg      <= element_base;
                        result_lane_mask_reg <= current_lane_mask;
                        state                <= STATE_WRITE;
                    end
                end

                STATE_WRITE: begin
                    if (result_ready) begin
                        if (({1'b0, element_base} + LANES_WIDE) >=
                            {1'b0, active_length}) begin
                            state <= STATE_DONE;
                        end else begin
                            element_base <= element_base + LANES;
                            state <= STATE_COMPUTE;
                        end
                    end
                end

                STATE_DONE: begin
                    state <= STATE_IDLE;
                end

                default: begin
                    config_error <= 1'b1;
                    state <= STATE_IDLE;
                end
            endcase
        end
    end

endmodule
