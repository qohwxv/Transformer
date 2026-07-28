`timescale 1ns/1ps

// Synthesizable streaming GELU engine.
//
// fp32_gelu_synth evaluates the exact-erf-style Abramowitz-Stegun boundary
// with binary32 add/multiply, a polynomial non-positive exponential, and a
// Newton-Raphson reciprocal, all implemented as bit-vector RTL.
//
// One input vector is latched, then one lane is evaluated per cycle.  This
// shares the special-function datapath across LANES instead of creating LANES
// deep combinational GELU copies.
module vit_gelu_engine_fp32 #(
    parameter integer LANES = 16
)(
    input  logic                         clk,
    input  logic                         rst,

    input  logic                         start,
    input  logic [31:0]                  cfg_length,
    output logic                         busy,
    output logic                         done,
    output logic                         config_error,

    output logic                         data_request,
    input  logic                         input_valid,
    output logic [31:0]                  data_base_index,
    output logic [LANES-1:0]             data_lane_mask,
    input  logic [LANES*32-1:0]          input_data,

    output logic                         result_valid,
    input  logic                         result_ready,
    output logic [31:0]                  result_base_index,
    output logic [LANES-1:0]             result_lane_mask,
    output logic [LANES*32-1:0]          result_data
);

    import vit_fp32_pkg::*;

    localparam integer LANE_INDEX_WIDTH = (LANES <= 1) ? 1 : $clog2(LANES);
    localparam logic [LANE_INDEX_WIDTH-1:0] LAST_LANE_INDEX =
        LANE_INDEX_WIDTH'(LANES - 1);
    localparam logic [32:0] LANES_WIDE = LANES;

    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_READ,
        STATE_COMPUTE,
        STATE_WRITE,
        STATE_DONE
    } state_t;

    state_t state;
    logic [31:0] active_length;
    logic [31:0] base_index;
    logic [LANES*32-1:0] latched_input_data;
    logic [LANES-1:0] latched_lane_mask;
    integer mask_lane;
    logic [LANE_INDEX_WIDTH-1:0] compute_lane_index;

    assign busy = (state != STATE_IDLE);
    assign done = (state == STATE_DONE);
    assign data_request = (state == STATE_READ);
    assign data_base_index = base_index;
    assign result_valid = (state == STATE_WRITE);

    always_comb begin
        data_lane_mask = '0;
        for (mask_lane = 0; mask_lane < LANES; mask_lane = mask_lane + 1)
            data_lane_mask[mask_lane] =
                (({1'b0, base_index} + mask_lane) <
                 {1'b0, active_length});
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state                  <= STATE_IDLE;
            config_error           <= 1'b0;
            active_length          <= 32'd0;
            base_index             <= 32'd0;
            result_base_index      <= 32'd0;
            result_lane_mask       <= '0;
            result_data            <= '0;
            latched_input_data     <= '0;
            latched_lane_mask      <= '0;
            compute_lane_index     <= '0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (start) begin
                        base_index <= 32'd0;
                        if (cfg_length == 0) begin
                            config_error <= 1'b1;
                            state <= STATE_DONE;
                        end else begin
                            config_error  <= 1'b0;
                            active_length <= cfg_length;
                            state         <= STATE_READ;
                        end
                    end
                end

                STATE_READ: begin
                    if (input_valid) begin
                        result_base_index <= base_index;
                        result_lane_mask <= data_lane_mask;
                        result_data <= '0;
                        latched_input_data <= input_data;
                        latched_lane_mask <= data_lane_mask;
                        compute_lane_index <= '0;
                        state <= STATE_COMPUTE;
                    end
                end

                STATE_COMPUTE: begin
                    if (latched_lane_mask[compute_lane_index]) begin
                        result_data[compute_lane_index*32 +: 32] <=
                            fp32_gelu_synth(
                                latched_input_data[
                                    compute_lane_index*32 +: 32
                                ]
                            );
                    end else begin
                        result_data[compute_lane_index*32 +: 32] <=
                            FP32_SYNTH_POS_ZERO;
                    end

                    if (compute_lane_index == LAST_LANE_INDEX) begin
                        state <= STATE_WRITE;
                    end else begin
                        compute_lane_index <= compute_lane_index + 1;
                    end
                end

                // Result vector, base index, and lane mask remain stable under
                // arbitrary output backpressure.
                STATE_WRITE: begin
                    if (result_ready) begin
                        if (({1'b0, base_index} + LANES_WIDE) <
                            {1'b0, active_length}) begin
                            base_index <= base_index + LANES;
                            state <= STATE_READ;
                        end else begin
                            state <= STATE_DONE;
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
