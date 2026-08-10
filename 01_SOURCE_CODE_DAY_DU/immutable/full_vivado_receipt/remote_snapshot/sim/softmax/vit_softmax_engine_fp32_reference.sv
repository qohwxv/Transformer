`timescale 1ns/1ps

// Frozen pre-serialization Softmax hierarchy.  This simulation-only reference
// deliberately retains the old combinational exp tree and reciprocal step so
// future time-shared production RTL can be checked bit-for-bit.
module vit_softmax_exp_datapath_reference (
    input  logic [31:0] input_value,
    input  logic [31:0] row_maximum,
    input  logic [31:0] exponential_sum,
    input  logic [31:0] reciprocal_sum,
    output logic [31:0] exponential_value,
    output logic [31:0] next_exponential_sum,
    output logic [31:0] normalized_value
);

    logic [31:0] centered_value;

    vit_fp32_sub_comb u_center (
        .a(input_value), .b(row_maximum), .result(centered_value)
    );
    vit_fp32_exp_neg_comb_reference u_exponential (
        .value(centered_value), .result(exponential_value)
    );
    vit_fp32_add_comb u_accumulate (
        .a(exponential_sum),
        .b(exponential_value),
        .result(next_exponential_sum)
    );
    vit_fp32_mul_comb_nodsp u_normalize (
        .a(exponential_value),
        .b(reciprocal_sum),
        .result(normalized_value)
    );

endmodule

module vit_softmax_reciprocal_step_reference (
    input  logic [31:0] operand,
    input  logic [31:0] estimate,
    output logic [31:0] next_estimate
);

    localparam logic [31:0] FP32_TWO = 32'h4000_0000;

    logic [31:0] operand_product;
    logic [31:0] correction;

    vit_fp32_mul_comb_nodsp u_operand_product (
        .a(operand), .b(estimate), .result(operand_product)
    );
    vit_fp32_sub_comb u_correction (
        .a(FP32_TWO), .b(operand_product), .result(correction)
    );
    vit_fp32_mul_comb_nodsp u_next_estimate (
        .a(estimate), .b(correction), .result(next_estimate)
    );

endmodule

module vit_softmax_engine_fp32_reference (
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

    localparam logic [1:0] SOFTMAX_PASS_MAX    = 2'd0;
    localparam logic [1:0] SOFTMAX_PASS_SUM    = 2'd1;
    localparam logic [1:0] SOFTMAX_PASS_OUTPUT = 2'd2;
    localparam logic [31:0] FP32_QNAN          = 32'h7fc0_0000;
    localparam logic [31:0] FP32_POS_ZERO      = 32'h0000_0000;
    localparam logic [31:0] FP32_POS_INF       = 32'h7f80_0000;
    localparam logic [31:0] FP32_NEG_INF       = 32'hff80_0000;
    localparam logic [31:0] RECIP_MAGIC        = 32'h7ef3_11c3;
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
    logic [31:0] row_base_index;
    logic [31:0] element_index;
    logic [31:0] row_maximum;
    logic [31:0] exponential_sum;
    logic [31:0] reciprocal_sum;
    logic [63:0] cfg_total_words;
    logic [31:0] calculated_data_index;
    logic [31:0] reciprocal_operand;
    logic [31:0] reciprocal_estimate;
    logic [1:0] reciprocal_iteration;
    logic [31:0] reciprocal_next_estimate;
    logic [31:0] maximum_candidate;
    logic [31:0] exponential_value;
    logic [31:0] next_exponential_sum;
    logic [31:0] normalized_value;
    logic        exponential_sum_is_nan;
    logic        exponential_sum_is_zero;

    assign cfg_total_words =
        {32'd0, cfg_row_count} * cfg_row_length;
    assign calculated_data_index =
        row_base_index + element_index;

    vit_fp32_compare u_row_maximum (
        .a                 (row_maximum),
        .b                 (input_data),
        .a_is_nan          (),
        .a_is_inf          (),
        .a_is_zero         (),
        .b_is_nan          (),
        .b_is_inf          (),
        .b_is_zero         (),
        .unordered         (),
        .equal             (),
        .a_greater         (),
        .a_greater_equal   (),
        .maximum           (maximum_candidate)
    );

    vit_softmax_exp_datapath_reference u_exponential_datapath (
        .input_value          (input_data),
        .row_maximum          (row_maximum),
        .exponential_sum      (exponential_sum),
        .reciprocal_sum       (reciprocal_sum),
        .exponential_value    (exponential_value),
        .next_exponential_sum (next_exponential_sum),
        .normalized_value     (normalized_value)
    );

    vit_softmax_reciprocal_step_reference u_reciprocal_step (
        .operand       (reciprocal_operand),
        .estimate      (reciprocal_estimate),
        .next_estimate (reciprocal_next_estimate)
    );

    assign exponential_sum_is_nan =
        (exponential_sum[30:23] == 8'hff) &&
        (exponential_sum[22:0] != 23'd0);
    assign exponential_sum_is_zero =
        (exponential_sum[30:0] == 31'd0);

    assign busy = (state != STATE_IDLE);
    assign done = (state == STATE_DONE);
    assign data_request = (state == STATE_MAX) ||
                          (state == STATE_EXP_SUM) ||
                          (state == STATE_OUTPUT_READ);
    assign data_pass = (state == STATE_EXP_SUM)     ? SOFTMAX_PASS_SUM :
                       (state == STATE_OUTPUT_READ) ? SOFTMAX_PASS_OUTPUT :
                                                     SOFTMAX_PASS_MAX;
    assign data_index = calculated_data_index;
    assign result_valid = (state == STATE_OUTPUT_WRITE);
    assign debug_row_max = row_maximum;
    assign debug_exp_sum = exponential_sum;

    always_ff @(posedge clk) begin
        if (rst) begin
            state                  <= STATE_IDLE;
            config_error           <= 1'b0;
            active_row_count       <= 32'd0;
            active_row_length      <= 32'd0;
            row_index              <= 32'd0;
            row_base_index         <= 32'd0;
            element_index          <= 32'd0;
            row_maximum            <= FP32_NEG_INF;
            exponential_sum        <= FP32_POS_ZERO;
            reciprocal_sum         <= FP32_POS_ZERO;
            reciprocal_operand     <= FP32_POS_ZERO;
            reciprocal_estimate    <= FP32_POS_ZERO;
            reciprocal_iteration   <= 2'd0;
            result_index           <= 32'd0;
            result_data            <= FP32_POS_ZERO;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (start) begin
                        row_index            <= 32'd0;
                        row_base_index       <= 32'd0;
                        element_index        <= 32'd0;
                        row_maximum          <= FP32_NEG_INF;
                        exponential_sum      <= FP32_POS_ZERO;
                        reciprocal_sum       <= FP32_POS_ZERO;
                        reciprocal_operand   <= FP32_POS_ZERO;
                        reciprocal_estimate  <= FP32_POS_ZERO;
                        reciprocal_iteration <= 2'd0;

                        if ((cfg_row_count == 0) ||
                            (cfg_row_length == 0) ||
                            (cfg_total_words >
                             64'h0000_0000_ffff_ffff)) begin
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
                            row_maximum <= maximum_candidate;

                        if ((element_index + 1) >= active_row_length) begin
                            element_index <= 32'd0;
                            exponential_sum <= FP32_POS_ZERO;
                            state <= STATE_EXP_SUM;
                        end else begin
                            element_index <= element_index + 1;
                        end
                    end
                end

                STATE_EXP_SUM: begin
                    if (input_valid) begin
                        exponential_sum <= next_exponential_sum;
                        if ((element_index + 1) >= active_row_length) begin
                            element_index <= 32'd0;
                            state <= STATE_RECIPROCAL_INIT;
                        end else begin
                            element_index <= element_index + 1;
                        end
                    end
                end

                STATE_RECIPROCAL_INIT: begin
                    reciprocal_operand <= exponential_sum;
                    reciprocal_iteration <= 2'd0;

                    if (exponential_sum_is_nan ||
                        exponential_sum[31]) begin
                        reciprocal_sum <= FP32_QNAN;
                        element_index <= 32'd0;
                        state <= STATE_OUTPUT_READ;
                    end else if (exponential_sum == FP32_POS_INF) begin
                        reciprocal_sum <= FP32_POS_ZERO;
                        element_index <= 32'd0;
                        state <= STATE_OUTPUT_READ;
                    end else if (exponential_sum_is_zero) begin
                        reciprocal_sum <= FP32_POS_INF;
                        element_index <= 32'd0;
                        state <= STATE_OUTPUT_READ;
                    end else begin
                        reciprocal_estimate <=
                            RECIP_MAGIC - exponential_sum;
                        state <= STATE_RECIPROCAL_ITERATE;
                    end
                end

                STATE_RECIPROCAL_ITERATE: begin
                    reciprocal_estimate <= reciprocal_next_estimate;
                    if (reciprocal_iteration ==
                        RECIP_LAST_ITERATION) begin
                        reciprocal_sum <= reciprocal_next_estimate;
                        element_index <= 32'd0;
                        state <= STATE_OUTPUT_READ;
                    end else begin
                        reciprocal_iteration <=
                            reciprocal_iteration + 1'b1;
                    end
                end

                STATE_OUTPUT_READ: begin
                    if (input_valid) begin
                        result_index <= calculated_data_index;
                        result_data <= normalized_value;
                        state <= STATE_OUTPUT_WRITE;
                    end
                end

                STATE_OUTPUT_WRITE: begin
                    if (result_ready) begin
                        if ((element_index + 1) <
                            active_row_length) begin
                            element_index <= element_index + 1;
                            state <= STATE_OUTPUT_READ;
                        end else if ((row_index + 1) <
                                     active_row_count) begin
                            row_index <= row_index + 1;
                            row_base_index <=
                                row_base_index + active_row_length;
                            element_index          <= 32'd0;
                            row_maximum            <= FP32_NEG_INF;
                            exponential_sum        <= FP32_POS_ZERO;
                            reciprocal_sum         <= FP32_POS_ZERO;
                            reciprocal_operand     <= FP32_POS_ZERO;
                            reciprocal_estimate    <= FP32_POS_ZERO;
                            reciprocal_iteration   <= 2'd0;
                            state                  <= STATE_MAX;
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
