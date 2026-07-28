`timescale 1ns/1ps

// Streaming argmax for finite IEEE-754 binary32 logits. The comparison is
// numeric rather than an unsigned comparison of the raw FP32 word. Equal
// values, including +0 versus -0, do not replace the current winner, so the
// lowest class index is retained exactly like PyTorch argmax.
module vit_argmax_engine_fp32 (
    input  logic            clk,
    input  logic            rst,

    input  logic            start,
    input  logic [31:0]     cfg_length,
    output logic            busy,
    output logic            done,
    output logic            config_error,
    output logic            input_nonfinite_error,

    output logic            data_request,
    input  logic            data_valid,
    output logic [31:0]     element_index,
    input  logic [31:0]     input_data,

    output logic            result_valid,
    input  logic            result_ready,
    output logic [31:0]     result_index,
    output logic [31:0]     result_value
);

    localparam logic [31:0] FP32_QNAN = 32'h7fc0_0000;

    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_SCAN,
        STATE_RESULT,
        STATE_DONE
    } state_t;

    state_t state;

    logic [31:0] active_length;
    logic have_best;
    logic [31:0] best_index;
    logic [31:0] best_value;
    logic [31:0] result_index_reg;
    logic [31:0] result_value_reg;
    logic current_is_finite;
    logic current_is_better;

    function automatic logic fp32_greater_finite(
        input logic [31:0] a,
        input logic [31:0] b
    );
        begin
            // Both signed-zero encodings represent the same numeric value.
            if ((a[30:0] == 31'd0) && (b[30:0] == 31'd0)) begin
                fp32_greater_finite = 1'b0;
            end else if (a[31] != b[31]) begin
                fp32_greater_finite = !a[31];
            end else if (!a[31]) begin
                fp32_greater_finite = (a[30:0] > b[30:0]);
            end else begin
                // For two negative values, the smaller magnitude is greater.
                fp32_greater_finite = (a[30:0] < b[30:0]);
            end
        end
    endfunction

    assign busy = (state != STATE_IDLE);
    assign done = (state == STATE_DONE);
    assign data_request = (state == STATE_SCAN);
    assign result_valid = (state == STATE_RESULT);
    assign result_index = result_index_reg;
    assign result_value = result_value_reg;

    always_comb begin
        current_is_finite = (input_data[30:23] != 8'hff);
        current_is_better =
            current_is_finite &&
            (!have_best || fp32_greater_finite(input_data, best_value));
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state                 <= STATE_IDLE;
            config_error          <= 1'b0;
            input_nonfinite_error <= 1'b0;
            active_length         <= 32'd0;
            element_index         <= 32'd0;
            have_best             <= 1'b0;
            best_index            <= 32'd0;
            best_value            <= 32'd0;
            result_index_reg      <= 32'd0;
            result_value_reg      <= FP32_QNAN;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (start) begin
                        element_index         <= 32'd0;
                        have_best             <= 1'b0;
                        input_nonfinite_error <= 1'b0;
                        if (cfg_length == 0) begin
                            config_error <= 1'b1;
                            state <= STATE_DONE;
                        end else begin
                            config_error  <= 1'b0;
                            active_length <= cfg_length;
                            state         <= STATE_SCAN;
                        end
                    end
                end

                STATE_SCAN: begin
                    if (data_valid) begin
                        if (!current_is_finite)
                            input_nonfinite_error <= 1'b1;

                        if (current_is_better) begin
                            have_best  <= 1'b1;
                            best_index <= element_index;
                            best_value <= input_data;
                        end

                        if ((element_index + 1) >= active_length) begin
                            if (current_is_better) begin
                                result_index_reg <= element_index;
                                result_value_reg <= input_data;
                            end else if (have_best) begin
                                result_index_reg <= best_index;
                                result_value_reg <= best_value;
                            end else begin
                                // All inputs were non-finite. The sticky error
                                // distinguishes this deterministic placeholder.
                                result_index_reg <= 32'd0;
                                result_value_reg <= FP32_QNAN;
                            end
                            state <= STATE_RESULT;
                        end else begin
                            element_index <= element_index + 1;
                        end
                    end
                end

                STATE_RESULT: begin
                    if (result_ready)
                        state <= STATE_DONE;
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
