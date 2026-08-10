`timescale 1ns/1ps

// Synthesizable streaming GELU engine.
//
// One input vector is latched, then each active lane is launched into the
// time-multiplexed GELU core.  The core replays the original exact-erf-style
// arithmetic graph with one FP32 multiplier and one FP32 adder.
(* use_dsp = "no" *)
module vit_gelu_engine_fp32 #(
    parameter integer LANES = 16,
    parameter integer USE_EXTERNAL_MUL = 0,
    parameter integer USE_EXTERNAL_ADD = 0
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
    output logic [LANES*32-1:0]          result_data,

    output logic [31:0]                  mul_operand_a,
    output logic [31:0]                  mul_operand_b,
    input  logic [31:0]                  external_mul_result,

    output logic [31:0]                  add_operand_a,
    output logic [31:0]                  add_operand_b,
    input  logic [31:0]                  external_add_result
);

    localparam integer LANE_INDEX_WIDTH = (LANES <= 1) ? 1 : $clog2(LANES);
    localparam logic [LANE_INDEX_WIDTH-1:0] LAST_LANE_INDEX =
        LANE_INDEX_WIDTH'(LANES - 1);
    localparam logic [32:0] LANES_WIDE = 33'(LANES);

    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_READ,
        STATE_LAUNCH_LANE,
        STATE_WAIT_LANE,
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
    logic [31:0] selected_lane_value;
    logic lane_core_start;
    logic lane_core_done;
    logic [31:0] lane_core_result;

    assign busy = (state != STATE_IDLE);
    assign done = (state == STATE_DONE);
    assign data_request = (state == STATE_READ);
    assign data_base_index = base_index;
    assign result_valid = (state == STATE_WRITE);
    assign selected_lane_value =
        latched_input_data[compute_lane_index*32 +: 32];
    assign lane_core_start =
        (state == STATE_LAUNCH_LANE) &&
        latched_lane_mask[compute_lane_index];

    vit_fp32_gelu_serial #(
        .USE_EXTERNAL_MUL (USE_EXTERNAL_MUL),
        .USE_EXTERNAL_ADD (USE_EXTERNAL_ADD)
    ) u_serial_core (
        .clk                (clk),
        .rst                (rst),
        .start              (lane_core_start),
        .value              (selected_lane_value),
        .busy               (),
        .done               (lane_core_done),
        .result             (lane_core_result),
        .mul_operand_a      (mul_operand_a),
        .mul_operand_b      (mul_operand_b),
        .external_mul_result(external_mul_result),
        .add_operand_a      (add_operand_a),
        .add_operand_b      (add_operand_b),
        .external_add_result(external_add_result)
    );

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
                        state <= STATE_LAUNCH_LANE;
                    end
                end

                STATE_LAUNCH_LANE: begin
                    if (!latched_lane_mask[compute_lane_index]) begin
                        result_data[compute_lane_index*32 +: 32] <=
                            32'h0000_0000;

                        if (compute_lane_index == LAST_LANE_INDEX) begin
                            state <= STATE_WRITE;
                        end else begin
                            compute_lane_index <=
                                compute_lane_index + 1'b1;
                        end
                    end else begin
                        state <= STATE_WAIT_LANE;
                    end
                end

                STATE_WAIT_LANE: begin
                    if (lane_core_done) begin
                        result_data[
                            compute_lane_index*32 +: 32
                        ] <= lane_core_result;

                        if (compute_lane_index == LAST_LANE_INDEX) begin
                            state <= STATE_WRITE;
                        end else begin
                            compute_lane_index <=
                                compute_lane_index + 1'b1;
                            state <= STATE_LAUNCH_LANE;
                        end
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
