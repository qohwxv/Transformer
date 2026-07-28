`timescale 1ns/1ps

// Synthesizable stable Softmax engine.
//
// Maximum comparison, non-positive exponential, and reciprocal are all
// bit-vector binary32 RTL.  exp(x) uses ln(2) range reduction and a degree-8
// polynomial; 1/sum uses four registered Newton-Raphson refinements.  The
// datapath has no dependency on the simulation-only math package.
//
// The external memory is a flat row-major tensor:
//     data_index = row_index * row_length + element_index
//
// Each row is read three times:
//   data_pass=0: find the row maximum
//   data_pass=1: sum exp(x-row_max)
//   data_pass=2: recompute exp(x-row_max) and emit normalized values
//
// Recomputing exp avoids an internal 197-word intermediate buffer. A future
// hardware implementation may instead retain exponentials in local SRAM.
module vit_softmax_engine_fp32 (
    input  logic          clk,
    input  logic          rst,

    input  logic          start,
    input  logic [31:0]   cfg_row_count,
    input  logic [31:0]   cfg_row_length,
    output logic          busy,
    output logic          done,
    output logic          config_error,

    output logic          data_request,
    input  logic          input_valid,
    output logic [1:0]    data_pass,
    output logic [31:0]   data_index,
    input  logic [31:0]   input_data,

    output logic          result_valid,
    input  logic          result_ready,
    output logic [31:0]   result_index,
    output logic [31:0]   result_data,

    output logic [31:0]   debug_row_max,
    output logic [31:0]   debug_exp_sum
);

    import vit_fp32_pkg::*;

    localparam logic [1:0] SOFTMAX_PASS_MAX    = 2'd0;
    localparam logic [1:0] SOFTMAX_PASS_SUM    = 2'd1;
    localparam logic [1:0] SOFTMAX_PASS_OUTPUT = 2'd2;
    localparam logic [31:0] RECIP_MAGIC = 32'h7ef3_11c3;
    localparam logic [1:0] RECIP_LAST_ITERATION = 2'd3;

    typedef enum logic [3:0] {
        STATE_IDLE,
        STATE_MAX,
        STATE_EXP_SUM,
        STATE_RECIPROCAL_INIT,
        STATE_RECIPROCAL_ITERATE,
        STATE_OUTPUT_READ,
        STATE_OUTPUT_WRITE,
        STATE_DONE
    } state_t;

    state_t state;

    logic [31:0] active_row_count;
    logic [31:0] active_row_length;
    logic [31:0] row_index;
    logic [31:0] element_index;
    logic [31:0] row_maximum;
    logic [31:0] exponential_sum;
    logic [31:0] reciprocal_sum;
    logic [63:0] cfg_total_words;
    logic [31:0] reciprocal_operand;
    logic [31:0] reciprocal_estimate;
    logic [1:0] reciprocal_iteration;
    logic [31:0] reciprocal_next_estimate;

    always_comb begin
        cfg_total_words = {32'd0, cfg_row_count} * cfg_row_length;
    end

    always_comb begin
        reciprocal_next_estimate = fp32_mul(
            reciprocal_estimate,
            fp32_sub_synth(
                FP32_SYNTH_TWO,
                fp32_mul(reciprocal_operand, reciprocal_estimate)
            )
        );
    end

    assign busy = (state != STATE_IDLE);
    assign done = (state == STATE_DONE);
    assign data_request = (state == STATE_MAX) ||
                          (state == STATE_EXP_SUM) ||
                          (state == STATE_OUTPUT_READ);
    assign data_pass = (state == STATE_EXP_SUM)     ? SOFTMAX_PASS_SUM :
                       (state == STATE_OUTPUT_READ) ? SOFTMAX_PASS_OUTPUT :
                                                     SOFTMAX_PASS_MAX;
    assign data_index = row_index * active_row_length + element_index;
    assign result_valid = (state == STATE_OUTPUT_WRITE);
    assign debug_row_max = row_maximum;
    assign debug_exp_sum = exponential_sum;

    always_ff @(posedge clk) begin
        if (rst) begin
            state             <= STATE_IDLE;
            config_error      <= 1'b0;
            active_row_count  <= 32'd0;
            active_row_length <= 32'd0;
            row_index         <= 32'd0;
            element_index     <= 32'd0;
            row_maximum       <= FP32_SYNTH_NEG_INF;
            exponential_sum   <= FP32_SYNTH_POS_ZERO;
            reciprocal_sum    <= FP32_SYNTH_POS_ZERO;
            reciprocal_operand <= FP32_SYNTH_POS_ZERO;
            reciprocal_estimate <= FP32_SYNTH_POS_ZERO;
            reciprocal_iteration <= 2'd0;
            result_index      <= 32'd0;
            result_data       <= FP32_SYNTH_POS_ZERO;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (start) begin
                        row_index       <= 32'd0;
                        element_index   <= 32'd0;
                        row_maximum     <= FP32_SYNTH_NEG_INF;
                        exponential_sum <= FP32_SYNTH_POS_ZERO;
                        reciprocal_sum  <= FP32_SYNTH_POS_ZERO;
                        reciprocal_operand <= FP32_SYNTH_POS_ZERO;
                        reciprocal_estimate <= FP32_SYNTH_POS_ZERO;
                        reciprocal_iteration <= 2'd0;

                        if ((cfg_row_count == 0) || (cfg_row_length == 0) ||
                            (cfg_total_words > 64'h0000_0000_ffff_ffff)) begin
                            config_error <= 1'b1;
                            state <= STATE_DONE;
                        end else begin
                            config_error      <= 1'b0;
                            active_row_count  <= cfg_row_count;
                            active_row_length <= cfg_row_length;
                            state             <= STATE_MAX;
                        end
                    end
                end

                STATE_MAX: begin
                    if (input_valid) begin
                        if (element_index == 0)
                            row_maximum <= input_data;
                        else
                            row_maximum <= fp32_max_synth(
                                row_maximum,
                                input_data
                            );

                        if ((element_index + 1) >= active_row_length) begin
                            element_index <= 32'd0;
                            exponential_sum <= FP32_SYNTH_POS_ZERO;
                            state <= STATE_EXP_SUM;
                        end else begin
                            element_index <= element_index + 1;
                        end
                    end
                end

                STATE_EXP_SUM: begin
                    if (input_valid) begin
                        exponential_sum <= fp32_add(
                            exponential_sum,
                            fp32_exp_neg_synth(
                                fp32_sub_synth(input_data, row_maximum)
                            )
                        );
                        if ((element_index + 1) >= active_row_length) begin
                            element_index <= 32'd0;
                            state <= STATE_RECIPROCAL_INIT;
                        end else begin
                            element_index <= element_index + 1;
                        end
                    end
                end

                // The separate state includes the final exp term committed by
                // the previous cycle's nonblocking accumulator assignment.
                STATE_RECIPROCAL_INIT: begin
                    reciprocal_operand <= exponential_sum;
                    reciprocal_iteration <= 2'd0;

                    if (fp32_is_nan_synth(exponential_sum) ||
                        exponential_sum[31]) begin
                        reciprocal_sum <= FP32_QNAN;
                        element_index <= 32'd0;
                        state <= STATE_OUTPUT_READ;
                    end else if (exponential_sum == FP32_SYNTH_POS_INF) begin
                        reciprocal_sum <= FP32_SYNTH_POS_ZERO;
                        element_index <= 32'd0;
                        state <= STATE_OUTPUT_READ;
                    end else if (fp32_is_zero_synth(exponential_sum)) begin
                        reciprocal_sum <= FP32_SYNTH_POS_INF;
                        element_index <= 32'd0;
                        state <= STATE_OUTPUT_READ;
                    end else begin
                        reciprocal_estimate <= RECIP_MAGIC - exponential_sum;
                        state <= STATE_RECIPROCAL_ITERATE;
                    end
                end

                STATE_RECIPROCAL_ITERATE: begin
                    reciprocal_estimate <= reciprocal_next_estimate;
                    if (reciprocal_iteration == RECIP_LAST_ITERATION) begin
                        reciprocal_sum <= reciprocal_next_estimate;
                        element_index <= 32'd0;
                        state <= STATE_OUTPUT_READ;
                    end else begin
                        reciprocal_iteration <= reciprocal_iteration + 1'b1;
                    end
                end

                STATE_OUTPUT_READ: begin
                    if (input_valid) begin
                        result_index <= row_index * active_row_length + element_index;
                        result_data <= fp32_mul(
                            fp32_exp_neg_synth(
                                fp32_sub_synth(input_data, row_maximum)
                            ),
                            reciprocal_sum
                        );
                        state <= STATE_OUTPUT_WRITE;
                    end
                end

                // Result data/index stay registered and stable until accepted.
                STATE_OUTPUT_WRITE: begin
                    if (result_ready) begin
                        if ((element_index + 1) < active_row_length) begin
                            element_index <= element_index + 1;
                            state <= STATE_OUTPUT_READ;
                        end else if ((row_index + 1) < active_row_count) begin
                            row_index <= row_index + 1;
                            element_index <= 32'd0;
                            row_maximum <= FP32_SYNTH_NEG_INF;
                            exponential_sum <= FP32_SYNTH_POS_ZERO;
                            reciprocal_sum <= FP32_SYNTH_POS_ZERO;
                            reciprocal_operand <= FP32_SYNTH_POS_ZERO;
                            reciprocal_estimate <= FP32_SYNTH_POS_ZERO;
                            reciprocal_iteration <= 2'd0;
                            state <= STATE_MAX;
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
