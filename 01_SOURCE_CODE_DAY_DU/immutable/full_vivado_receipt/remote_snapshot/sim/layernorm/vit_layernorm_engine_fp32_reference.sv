`timescale 1ns/1ps

// Frozen LayerNorm engine from immediately before the shared-FP-datapath
// refactor.  It already uses the serial unsigned reciprocal reference, while
// statistics, rsqrt and affine arithmetic retain their parallel FP32 trees.
module vit_layernorm_engine_fp32_reference (
    input  logic          clk,
    input  logic          rst,

    input  logic          start,
    input  logic [31:0]   cfg_token_count,
    input  logic [31:0]   cfg_hidden_size,
    input  logic [31:0]   cfg_epsilon,
    output logic          busy,
    output logic          done,
    output logic          config_error,

    output logic          data_request,
    input  logic          input_valid,
    output logic [1:0]    data_pass,
    output logic [31:0]   data_index,
    input  logic [31:0]   input_data,
    input  logic [31:0]   gamma_data,
    input  logic [31:0]   beta_data,

    output logic          result_valid,
    input  logic          result_ready,
    output logic [31:0]   result_index,
    output logic [31:0]   result_data,

    output logic [31:0]   debug_mean,
    output logic [31:0]   debug_variance,
    output logic [31:0]   debug_inv_std
);

    localparam logic [1:0] LN_PASS_MEAN   = 2'd0;
    localparam logic [1:0] LN_PASS_VAR    = 2'd1;
    localparam logic [1:0] LN_PASS_AFFINE = 2'd2;
    localparam logic [31:0] FP32_QNAN     = 32'h7fc0_0000;
    localparam logic [31:0] FP32_POS_ZERO = 32'h0000_0000;
    localparam logic [31:0] FP32_POS_INF  = 32'h7f80_0000;
    localparam logic [31:0] FP32_NEG_INF  = 32'hff80_0000;
    localparam logic [31:0] RSQRT_MAGIC   = 32'h5f37_5a86;
    localparam logic [1:0] RSQRT_LAST_ITERATION = 2'd2;

    typedef enum logic [3:0] {
        STATE_IDLE,
        STATE_RECIP_START,
        STATE_RECIP_WAIT,
        STATE_SUM,
        STATE_MEAN,
        STATE_VARIANCE_SUM,
        STATE_VARIANCE,
        STATE_INV_STD_INIT,
        STATE_INV_STD_ITERATE,
        STATE_AFFINE_READ,
        STATE_AFFINE_WRITE,
        STATE_DONE
    } state_t;

    state_t state;

    logic [31:0] active_token_count;
    logic [31:0] active_hidden_size;
    logic [31:0] active_recip_hidden_size;
    logic [31:0] active_epsilon;
    logic [31:0] token_index;
    logic [31:0] token_base_index;
    logic [31:0] channel_index;
    logic [31:0] sum_accumulator;
    logic [31:0] variance_accumulator;
    logic [31:0] token_mean;
    logic [31:0] token_variance;
    logic [31:0] token_inv_std;
    logic [63:0] cfg_total_words;
    logic [31:0] calculated_data_index;
    logic [31:0] variance_plus_epsilon;
    logic [31:0] rsqrt_operand;
    logic [31:0] rsqrt_estimate;
    logic [1:0]  rsqrt_iteration;
    logic [31:0] rsqrt_next_estimate;
    logic [31:0] reciprocal_hidden_size_result;
    logic        reciprocal_hidden_size_start;
    logic        reciprocal_hidden_size_done;
    logic        statistics_variance_mode;
    logic [31:0] statistics_accumulator;
    logic [31:0] statistics_scale_operand;
    logic [31:0] statistics_accumulation_next;
    logic [31:0] statistics_scaled_value;
    logic [31:0] affine_result;

    assign cfg_total_words =
        {32'd0, cfg_token_count} * cfg_hidden_size;
    assign calculated_data_index =
        token_base_index + channel_index;
    assign statistics_variance_mode =
        (state == STATE_VARIANCE_SUM);
    assign statistics_accumulator =
        statistics_variance_mode ?
        variance_accumulator :
        sum_accumulator;
    assign statistics_scale_operand =
        (state == STATE_VARIANCE) ?
        variance_accumulator :
        sum_accumulator;

    assign reciprocal_hidden_size_start =
        (state == STATE_RECIP_START);

    vit_fp32_recip_u32_serial_reference u_reciprocal_hidden_size (
        .clk    (clk),
        .rst    (rst),
        .start  (reciprocal_hidden_size_start),
        .value  (active_hidden_size),
        .busy   (),
        .done   (reciprocal_hidden_size_done),
        .result (reciprocal_hidden_size_result)
    );

    vit_layernorm_statistics_datapath_reference u_statistics_datapath (
        .variance_mode          (statistics_variance_mode),
        .sample                 (input_data),
        .mean                   (token_mean),
        .accumulator            (statistics_accumulator),
        .scale_operand          (statistics_scale_operand),
        .reciprocal_hidden_size (active_recip_hidden_size),
        .variance               (token_variance),
        .epsilon                (active_epsilon),
        .accumulation_next      (statistics_accumulation_next),
        .scaled_statistic       (statistics_scaled_value),
        .variance_plus_epsilon  (variance_plus_epsilon)
    );

    vit_fp32_rsqrt_step_comb_reference u_rsqrt_step (
        .operand       (rsqrt_operand),
        .estimate      (rsqrt_estimate),
        .next_estimate (rsqrt_next_estimate)
    );

    vit_layernorm_affine_datapath_reference u_affine_datapath (
        .sample                     (input_data),
        .mean                       (token_mean),
        .inverse_standard_deviation (token_inv_std),
        .gamma                      (gamma_data),
        .beta                       (beta_data),
        .result                     (affine_result)
    );

    assign busy = (state != STATE_IDLE);
    assign done = (state == STATE_DONE);
    assign data_request = (state == STATE_SUM) ||
                          (state == STATE_VARIANCE_SUM) ||
                          (state == STATE_AFFINE_READ);
    assign data_pass = (state == STATE_VARIANCE_SUM) ? LN_PASS_VAR :
                       (state == STATE_AFFINE_READ)  ? LN_PASS_AFFINE :
                                                      LN_PASS_MEAN;
    assign data_index = calculated_data_index;
    assign result_valid = (state == STATE_AFFINE_WRITE);
    assign debug_mean = token_mean;
    assign debug_variance = token_variance;
    assign debug_inv_std = token_inv_std;

    always_ff @(posedge clk) begin
        if (rst) begin
            state                      <= STATE_IDLE;
            config_error               <= 1'b0;
            active_token_count         <= 32'd0;
            active_hidden_size         <= 32'd0;
            active_recip_hidden_size   <= 32'd0;
            active_epsilon             <= 32'd0;
            token_index                <= 32'd0;
            token_base_index           <= 32'd0;
            channel_index              <= 32'd0;
            sum_accumulator            <= 32'd0;
            variance_accumulator       <= 32'd0;
            token_mean                 <= 32'd0;
            token_variance             <= 32'd0;
            token_inv_std              <= 32'd0;
            rsqrt_operand               <= 32'd0;
            rsqrt_estimate              <= 32'd0;
            rsqrt_iteration             <= 2'd0;
            result_index                <= 32'd0;
            result_data                 <= 32'd0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (start) begin
                        token_index          <= 32'd0;
                        token_base_index     <= 32'd0;
                        channel_index        <= 32'd0;
                        sum_accumulator      <= 32'd0;
                        variance_accumulator <= 32'd0;
                        token_mean           <= 32'd0;
                        token_variance       <= 32'd0;
                        token_inv_std        <= 32'd0;
                        rsqrt_operand        <= 32'd0;
                        rsqrt_estimate       <= 32'd0;
                        rsqrt_iteration      <= 2'd0;

                        if ((cfg_token_count == 0) ||
                            (cfg_hidden_size == 0) ||
                            (cfg_total_words >
                             64'h0000_0000_ffff_ffff) ||
                            (cfg_epsilon[30:23] == 8'hff) ||
                            (cfg_epsilon[31] &&
                             (cfg_epsilon[30:0] != 0))) begin
                            config_error <= 1'b1;
                            state <= STATE_DONE;
                        end else begin
                            config_error             <= 1'b0;
                            active_token_count       <= cfg_token_count;
                            active_hidden_size       <= cfg_hidden_size;
                            active_epsilon           <= cfg_epsilon;
                            state <= STATE_RECIP_START;
                        end
                    end
                end

                STATE_RECIP_START:
                    state <= STATE_RECIP_WAIT;

                STATE_RECIP_WAIT: begin
                    if (reciprocal_hidden_size_done) begin
                        active_recip_hidden_size <=
                            reciprocal_hidden_size_result;
                        state <= STATE_SUM;
                    end
                end

                STATE_SUM: begin
                    if (input_valid) begin
                        sum_accumulator <= statistics_accumulation_next;
                        if ((channel_index + 1) >=
                            active_hidden_size) begin
                            channel_index <= 32'd0;
                            state <= STATE_MEAN;
                        end else begin
                            channel_index <= channel_index + 1;
                        end
                    end
                end

                STATE_MEAN: begin
                    token_mean <= statistics_scaled_value;
                    variance_accumulator <= 32'd0;
                    channel_index <= 32'd0;
                    state <= STATE_VARIANCE_SUM;
                end

                STATE_VARIANCE_SUM: begin
                    if (input_valid) begin
                        variance_accumulator <=
                            statistics_accumulation_next;
                        if ((channel_index + 1) >=
                            active_hidden_size) begin
                            channel_index <= 32'd0;
                            state <= STATE_VARIANCE;
                        end else begin
                            channel_index <= channel_index + 1;
                        end
                    end
                end

                STATE_VARIANCE: begin
                    token_variance <= statistics_scaled_value;
                    state <= STATE_INV_STD_INIT;
                end

                STATE_INV_STD_INIT: begin
                    rsqrt_operand <= variance_plus_epsilon;
                    rsqrt_iteration <= 2'd0;

                    if ((variance_plus_epsilon[30:23] == 8'hff) &&
                        (variance_plus_epsilon[22:0] != 0)) begin
                        token_inv_std <= FP32_QNAN;
                        channel_index <= 32'd0;
                        state <= STATE_AFFINE_READ;
                    end else if (variance_plus_epsilon[31] &&
                                 (variance_plus_epsilon[30:0] != 0)) begin
                        token_inv_std <= FP32_QNAN;
                        channel_index <= 32'd0;
                        state <= STATE_AFFINE_READ;
                    end else if (variance_plus_epsilon ==
                                 FP32_POS_INF) begin
                        token_inv_std <= FP32_POS_ZERO;
                        channel_index <= 32'd0;
                        state <= STATE_AFFINE_READ;
                    end else if ((variance_plus_epsilon[30:23] == 0) &&
                                 (variance_plus_epsilon[22:0] == 0)) begin
                        token_inv_std <= variance_plus_epsilon[31] ?
                                         FP32_NEG_INF : FP32_POS_INF;
                        channel_index <= 32'd0;
                        state <= STATE_AFFINE_READ;
                    end else begin
                        rsqrt_estimate <= RSQRT_MAGIC -
                                          (variance_plus_epsilon >> 1);
                        state <= STATE_INV_STD_ITERATE;
                    end
                end

                STATE_INV_STD_ITERATE: begin
                    rsqrt_estimate <= rsqrt_next_estimate;
                    if (rsqrt_iteration ==
                        RSQRT_LAST_ITERATION) begin
                        token_inv_std <= rsqrt_next_estimate;
                        channel_index <= 32'd0;
                        state <= STATE_AFFINE_READ;
                    end else begin
                        rsqrt_iteration <=
                            rsqrt_iteration + 1'b1;
                    end
                end

                STATE_AFFINE_READ: begin
                    if (input_valid) begin
                        result_index <= calculated_data_index;
                        result_data <= affine_result;
                        state <= STATE_AFFINE_WRITE;
                    end
                end

                STATE_AFFINE_WRITE: begin
                    if (result_ready) begin
                        if ((channel_index + 1) <
                            active_hidden_size) begin
                            channel_index <= channel_index + 1;
                            state <= STATE_AFFINE_READ;
                        end else if ((token_index + 1) <
                                     active_token_count) begin
                            token_index <= token_index + 1;
                            token_base_index <=
                                token_base_index + active_hidden_size;
                            channel_index          <= 32'd0;
                            sum_accumulator        <= 32'd0;
                            variance_accumulator   <= 32'd0;
                            token_mean             <= 32'd0;
                            token_variance         <= 32'd0;
                            token_inv_std          <= 32'd0;
                            rsqrt_operand          <= 32'd0;
                            rsqrt_estimate         <= 32'd0;
                            rsqrt_iteration        <= 2'd0;
                            state                  <= STATE_SUM;
                        end else begin
                            state <= STATE_DONE;
                        end
                    end
                end

                STATE_DONE:
                    state <= STATE_IDLE;

                default: begin
                    config_error <= 1'b1;
                    state <= STATE_IDLE;
                end
            endcase
        end
    end

endmodule
