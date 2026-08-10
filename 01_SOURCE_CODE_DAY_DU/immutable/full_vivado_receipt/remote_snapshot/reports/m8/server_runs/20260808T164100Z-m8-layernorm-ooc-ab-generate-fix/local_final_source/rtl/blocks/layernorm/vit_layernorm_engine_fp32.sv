`timescale 1ns/1ps

// Three-pass LayerNorm with one time-shared FP32 multiplier and one
// time-shared FP32 adder.
//
//   pass 0: sum and mean
//   pass 1: centered biased variance
//   pass 2: beta + gamma * inv_std * (sample - mean)
//
// The reciprocal hidden-size divider is also sequential.  The controller
// replays the former statistics, rsqrt, and affine arithmetic graph in the
// same order, preserving every FP32 rounding point while reducing LUT cost.
//
// M8 optionally keeps the current row plus the first token's gamma/beta in
// three synchronous 1024x32 block memories.  For supported hidden sizes the
// mean pass fills the sample memory, the variance pass replays it locally,
// token zero's affine packet fills gamma/beta, and later tokens replay all
// three operands locally.  Hidden sizes above the cache capacity take the
// exact legacy three-read-pass path.
(* use_dsp = "no" *)
module vit_layernorm_engine_fp32 #(
    parameter integer USE_EXTERNAL_MUL = 0,
    parameter integer USE_EXTERNAL_ADD = 0,
    parameter integer ENABLE_ROW_AFFINE_BUFFER = 1,
    parameter integer ROW_AFFINE_BUFFER_DEPTH = 1024
) (
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
    output logic [31:0]   data_channel_index,
    input  logic [31:0]   input_data,
    input  logic [31:0]   gamma_data,
    input  logic [31:0]   beta_data,

    output logic          result_valid,
    input  logic          result_ready,
    output logic [31:0]   result_index,
    output logic [31:0]   result_data,

    output logic [31:0]   debug_mean,
    output logic [31:0]   debug_variance,
    output logic [31:0]   debug_inv_std,

    output logic [31:0]   mul_operand_a,
    output logic [31:0]   mul_operand_b,
    input  logic [31:0]   external_mul_result,

    output logic [31:0]   add_operand_a,
    output logic [31:0]   add_operand_b,
    input  logic [31:0]   external_add_result
);

    localparam logic [1:0] LN_PASS_MEAN   = 2'd0;
    localparam logic [1:0] LN_PASS_VAR    = 2'd1;
    localparam logic [1:0] LN_PASS_AFFINE = 2'd2;
    localparam logic [31:0] FP32_QNAN     = 32'h7fc0_0000;
    localparam logic [31:0] FP32_POS_ZERO = 32'h0000_0000;
    localparam logic [31:0] FP32_POS_INF  = 32'h7f80_0000;
    localparam logic [31:0] FP32_NEG_INF  = 32'hff80_0000;
    localparam logic [31:0] FP32_HALF     = 32'h3f00_0000;
    localparam logic [31:0] FP32_ONE_HALF = 32'h3fc0_0000;
    localparam logic [31:0] RSQRT_MAGIC   = 32'h5f37_5a86;

    typedef enum logic [4:0] {
        STATE_IDLE,
        STATE_TOTAL_START,
        STATE_TOTAL_WAIT,
        STATE_RECIP_START,
        STATE_RECIP_WAIT,
        STATE_SUM_READ,
        STATE_SUM_ADD,
        STATE_MEAN_SCALE,
        STATE_VARIANCE_READ,
        STATE_VARIANCE_CACHE_WAIT,
        STATE_VARIANCE_CENTER,
        STATE_VARIANCE_SQUARE,
        STATE_VARIANCE_ADD,
        STATE_VARIANCE_SCALE,
        STATE_EPSILON_ADD,
        STATE_INV_STD_INIT,
        STATE_RSQRT_SQUARE,
        STATE_RSQRT_OPERAND,
        STATE_RSQRT_HALF,
        STATE_RSQRT_CORRECTION,
        STATE_RSQRT_ESTIMATE,
        STATE_AFFINE_READ,
        STATE_AFFINE_CACHE_WAIT,
        STATE_AFFINE_CENTER,
        STATE_AFFINE_NORMALIZE,
        STATE_AFFINE_GAMMA,
        STATE_AFFINE_BETA,
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
    logic [31:0] calculated_data_index;
    logic use_row_affine_buffer;

    localparam integer ROW_AFFINE_BUFFER_WORDS =
        (ROW_AFFINE_BUFFER_DEPTH < 1) ? 1 :
        ROW_AFFINE_BUFFER_DEPTH;
    localparam integer ROW_AFFINE_ADDRESS_WIDTH =
        (ROW_AFFINE_BUFFER_WORDS <= 1) ? 1 :
        $clog2(ROW_AFFINE_BUFFER_WORDS);
    localparam logic [31:0] ROW_AFFINE_BUFFER_LIMIT =
        ROW_AFFINE_BUFFER_WORDS;

    generate
        if (ROW_AFFINE_BUFFER_DEPTH < 1) begin : gen_invalid_buffer_depth
            initial begin
                $error("ROW_AFFINE_BUFFER_DEPTH must be at least one");
            end
        end
    endgenerate

    logic [ROW_AFFINE_ADDRESS_WIDTH-1:0] row_affine_buffer_address;
    logic [31:0] sample_buffer_read_data;
    logic [31:0] gamma_buffer_read_data;
    logic [31:0] beta_buffer_read_data;
    logic sample_buffer_write_enable;
    logic sample_buffer_read_enable;
    logic gamma_beta_buffer_write_enable;
    logic gamma_beta_buffer_read_enable;

    generate
        if (ENABLE_ROW_AFFINE_BUFFER != 0) begin : gen_row_affine_buffers
            (* ram_style = "block" *)
            logic [31:0] sample_buffer [0:ROW_AFFINE_BUFFER_WORDS-1];
            (* ram_style = "block" *)
            logic [31:0] gamma_buffer [0:ROW_AFFINE_BUFFER_WORDS-1];
            (* ram_style = "block" *)
            logic [31:0] beta_buffer [0:ROW_AFFINE_BUFFER_WORDS-1];
            logic [31:0] sample_buffer_read_data_q;
            logic [31:0] gamma_buffer_read_data_q;
            logic [31:0] beta_buffer_read_data_q;

            // One synchronous address/operation per memory and no array
            // reset.  A command overwrites every entry it will later consume
            // before enabling a local read, so stale contents cannot become
            // architecturally visible.
            always_ff @(posedge clk) begin
                if (sample_buffer_write_enable)
                    sample_buffer[row_affine_buffer_address] <= input_data;
                else if (sample_buffer_read_enable)
                    sample_buffer_read_data_q <=
                        sample_buffer[row_affine_buffer_address];

                if (gamma_beta_buffer_write_enable) begin
                    gamma_buffer[row_affine_buffer_address] <= gamma_data;
                    beta_buffer[row_affine_buffer_address] <= beta_data;
                end else if (gamma_beta_buffer_read_enable) begin
                    gamma_buffer_read_data_q <=
                        gamma_buffer[row_affine_buffer_address];
                    beta_buffer_read_data_q <=
                        beta_buffer[row_affine_buffer_address];
                end
            end

            assign sample_buffer_read_data = sample_buffer_read_data_q;
            assign gamma_buffer_read_data = gamma_buffer_read_data_q;
            assign beta_buffer_read_data = beta_buffer_read_data_q;
        end else begin : gen_no_row_affine_buffers
            // Keep the shared FSM ports fully driven while removing the RAM
            // declarations themselves at elaboration time.  The disabled
            // configuration never enters either cache-wait state.
            assign sample_buffer_read_data = 32'd0;
            assign gamma_buffer_read_data = 32'd0;
            assign beta_buffer_read_data = 32'd0;
        end
    endgenerate

    logic total_words_start;
    logic total_words_done;
    logic [63:0] total_words_product;
    logic reciprocal_hidden_size_start;
    logic reciprocal_hidden_size_done;
    logic [31:0] reciprocal_hidden_size_result;

    logic [31:0] latched_sample;
    logic [31:0] latched_gamma;
    logic [31:0] latched_beta;
    logic [31:0] centered_sample;
    logic [31:0] squared_sample;
    logic [31:0] normalized_sample;
    logic [31:0] gamma_scaled_sample;

    logic [31:0] rsqrt_operand;
    logic [31:0] rsqrt_estimate;
    logic [31:0] rsqrt_estimate_squared;
    logic [31:0] rsqrt_operand_product;
    logic [31:0] rsqrt_scaled_product;
    logic [31:0] rsqrt_correction;
    logic [1:0] rsqrt_iteration;

    logic [31:0] mul_result;
    logic [31:0] add_result;

    assign calculated_data_index =
        token_base_index + channel_index;

    assign busy = (state != STATE_IDLE);
    assign done = (state == STATE_DONE);
    assign data_request =
        (state == STATE_SUM_READ) ||
        ((state == STATE_VARIANCE_READ) &&
         !use_row_affine_buffer) ||
        ((state == STATE_AFFINE_READ) &&
         (!use_row_affine_buffer || (token_index == 0)));
    assign data_pass =
        (state == STATE_VARIANCE_READ) ? LN_PASS_VAR :
        (state == STATE_AFFINE_READ)   ? LN_PASS_AFFINE :
                                         LN_PASS_MEAN;
    assign data_index = calculated_data_index;
    assign data_channel_index = channel_index;
    assign result_valid = (state == STATE_AFFINE_WRITE);
    assign debug_mean = token_mean;
    assign debug_variance = token_variance;
    assign debug_inv_std = token_inv_std;
    assign reciprocal_hidden_size_start =
        (state == STATE_RECIP_START);
    assign total_words_start = (state == STATE_TOTAL_START);

    assign row_affine_buffer_address =
        channel_index[ROW_AFFINE_ADDRESS_WIDTH-1:0];
    assign sample_buffer_write_enable =
        use_row_affine_buffer &&
        (state == STATE_SUM_READ) && input_valid;
    assign sample_buffer_read_enable =
        use_row_affine_buffer &&
        ((state == STATE_VARIANCE_READ) ||
         (state == STATE_AFFINE_READ));
    assign gamma_beta_buffer_write_enable =
        use_row_affine_buffer &&
        (state == STATE_AFFINE_READ) &&
        (token_index == 0) && input_valid;
    assign gamma_beta_buffer_read_enable =
        use_row_affine_buffer &&
        (state == STATE_AFFINE_READ) &&
        (token_index != 0);

    vit_u32_mul_iterative_nodsp u_total_words_multiplier (
        .clk       (clk),
        .rst       (rst),
        .start     (total_words_start),
        .operand_a (active_token_count),
        .operand_b (active_hidden_size),
        .busy      (),
        .done      (total_words_done),
        .product   (total_words_product)
    );

    vit_fp32_recip_u32_serial u_reciprocal_hidden_size (
        .clk    (clk),
        .rst    (rst),
        .start  (reciprocal_hidden_size_start),
        .value  (active_hidden_size),
        .busy   (),
        .done   (reciprocal_hidden_size_done),
        .result (reciprocal_hidden_size_result)
    );

    generate
        if (USE_EXTERNAL_MUL != 0) begin : gen_external_multiplier
            assign mul_result = external_mul_result;
        end else begin : gen_local_multiplier
            vit_fp32_mul_comb_nodsp u_shared_multiplier (
                .a      (mul_operand_a),
                .b      (mul_operand_b),
                .result (mul_result)
            );
        end
    endgenerate

    generate
        if (USE_EXTERNAL_ADD != 0) begin : gen_external_adder
            assign add_result = external_add_result;
        end else begin : gen_local_adder
            vit_fp32_add_comb u_shared_adder (
                .a      (add_operand_a),
                .b      (add_operand_b),
                .result (add_result)
            );
        end
    endgenerate

    always_comb begin
        mul_operand_a = FP32_POS_ZERO;
        mul_operand_b = FP32_POS_ZERO;
        add_operand_a = FP32_POS_ZERO;
        add_operand_b = FP32_POS_ZERO;

        case (state)
            STATE_SUM_ADD: begin
                add_operand_a = sum_accumulator;
                add_operand_b = latched_sample;
            end

            STATE_MEAN_SCALE: begin
                mul_operand_a = sum_accumulator;
                mul_operand_b = active_recip_hidden_size;
            end

            STATE_VARIANCE_CENTER,
            STATE_AFFINE_CENTER: begin
                add_operand_a = latched_sample;
                add_operand_b = {
                    ~token_mean[31],
                    token_mean[30:0]
                };
            end

            STATE_VARIANCE_SQUARE: begin
                mul_operand_a = centered_sample;
                mul_operand_b = centered_sample;
            end

            STATE_VARIANCE_ADD: begin
                add_operand_a = variance_accumulator;
                add_operand_b = squared_sample;
            end

            STATE_VARIANCE_SCALE: begin
                mul_operand_a = variance_accumulator;
                mul_operand_b = active_recip_hidden_size;
            end

            STATE_EPSILON_ADD: begin
                add_operand_a = token_variance;
                add_operand_b = active_epsilon;
            end

            STATE_RSQRT_SQUARE: begin
                mul_operand_a = rsqrt_estimate;
                mul_operand_b = rsqrt_estimate;
            end

            STATE_RSQRT_OPERAND: begin
                mul_operand_a = rsqrt_operand;
                mul_operand_b = rsqrt_estimate_squared;
            end

            STATE_RSQRT_HALF: begin
                mul_operand_a = FP32_HALF;
                mul_operand_b = rsqrt_operand_product;
            end

            STATE_RSQRT_CORRECTION: begin
                add_operand_a = FP32_ONE_HALF;
                add_operand_b = {
                    ~rsqrt_scaled_product[31],
                    rsqrt_scaled_product[30:0]
                };
            end

            STATE_RSQRT_ESTIMATE: begin
                mul_operand_a = rsqrt_estimate;
                mul_operand_b = rsqrt_correction;
            end

            STATE_AFFINE_NORMALIZE: begin
                mul_operand_a = centered_sample;
                mul_operand_b = token_inv_std;
            end

            STATE_AFFINE_GAMMA: begin
                mul_operand_a = normalized_sample;
                mul_operand_b = latched_gamma;
            end

            STATE_AFFINE_BETA: begin
                add_operand_a = gamma_scaled_sample;
                add_operand_b = latched_beta;
            end

            default: begin
            end
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state                    <= STATE_IDLE;
            config_error             <= 1'b0;
            active_token_count       <= 32'd0;
            active_hidden_size       <= 32'd0;
            active_recip_hidden_size <= 32'd0;
            active_epsilon           <= 32'd0;
            token_index              <= 32'd0;
            token_base_index         <= 32'd0;
            channel_index            <= 32'd0;
            sum_accumulator          <= FP32_POS_ZERO;
            variance_accumulator     <= FP32_POS_ZERO;
            token_mean               <= FP32_POS_ZERO;
            token_variance           <= FP32_POS_ZERO;
            token_inv_std            <= FP32_POS_ZERO;
            use_row_affine_buffer    <= 1'b0;
            result_index             <= 32'd0;
            result_data              <= FP32_POS_ZERO;
            latched_sample           <= FP32_POS_ZERO;
            latched_gamma            <= FP32_POS_ZERO;
            latched_beta             <= FP32_POS_ZERO;
            centered_sample          <= FP32_POS_ZERO;
            squared_sample           <= FP32_POS_ZERO;
            normalized_sample        <= FP32_POS_ZERO;
            gamma_scaled_sample      <= FP32_POS_ZERO;
            rsqrt_operand            <= FP32_POS_ZERO;
            rsqrt_estimate           <= FP32_POS_ZERO;
            rsqrt_estimate_squared   <= FP32_POS_ZERO;
            rsqrt_operand_product    <= FP32_POS_ZERO;
            rsqrt_scaled_product     <= FP32_POS_ZERO;
            rsqrt_correction         <= FP32_POS_ZERO;
            rsqrt_iteration          <= 2'd0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (start) begin
                        token_index          <= 32'd0;
                        token_base_index     <= 32'd0;
                        channel_index        <= 32'd0;
                        sum_accumulator      <= FP32_POS_ZERO;
                        variance_accumulator <= FP32_POS_ZERO;
                        token_mean           <= FP32_POS_ZERO;
                        token_variance       <= FP32_POS_ZERO;
                        token_inv_std        <= FP32_POS_ZERO;
                        use_row_affine_buffer <=
                            (ENABLE_ROW_AFFINE_BUFFER != 0) &&
                            (ROW_AFFINE_BUFFER_DEPTH > 0) &&
                            (cfg_hidden_size <=
                             ROW_AFFINE_BUFFER_LIMIT);

                        if ((cfg_token_count == 0) ||
                            (cfg_hidden_size == 0) ||
                            (cfg_epsilon[30:23] == 8'hff) ||
                            (cfg_epsilon[31] &&
                             (cfg_epsilon[30:0] != 0))) begin
                            config_error <= 1'b1;
                            state <= STATE_DONE;
                        end else begin
                            config_error       <= 1'b0;
                            active_token_count <= cfg_token_count;
                            active_hidden_size <= cfg_hidden_size;
                            active_epsilon     <= cfg_epsilon;
                            state <= STATE_TOTAL_START;
                        end
                    end
                end

                STATE_TOTAL_START: begin
                    state <= STATE_TOTAL_WAIT;
                end

                STATE_TOTAL_WAIT: begin
                    if (total_words_done) begin
                        if (|total_words_product[63:32]) begin
                            config_error <= 1'b1;
                            state <= STATE_DONE;
                        end else begin
                            state <= STATE_RECIP_START;
                        end
                    end
                end

                STATE_RECIP_START: begin
                    state <= STATE_RECIP_WAIT;
                end

                STATE_RECIP_WAIT: begin
                    if (reciprocal_hidden_size_done) begin
                        active_recip_hidden_size <=
                            reciprocal_hidden_size_result;
                        state <= STATE_SUM_READ;
                    end
                end

                STATE_SUM_READ: begin
                    if (input_valid) begin
                        latched_sample <= input_data;
                        state <= STATE_SUM_ADD;
                    end
                end

                STATE_SUM_ADD: begin
                    sum_accumulator <= add_result;
                    if ((channel_index + 1) >=
                        active_hidden_size) begin
                        channel_index <= 32'd0;
                        state <= STATE_MEAN_SCALE;
                    end else begin
                        channel_index <= channel_index + 1'b1;
                        state <= STATE_SUM_READ;
                    end
                end

                STATE_MEAN_SCALE: begin
                    token_mean           <= mul_result;
                    variance_accumulator <= FP32_POS_ZERO;
                    channel_index        <= 32'd0;
                    state                <= STATE_VARIANCE_READ;
                end

                STATE_VARIANCE_READ: begin
                    if (use_row_affine_buffer) begin
                        state <= STATE_VARIANCE_CACHE_WAIT;
                    end else if (input_valid) begin
                        latched_sample <= input_data;
                        state <= STATE_VARIANCE_CENTER;
                    end
                end

                STATE_VARIANCE_CACHE_WAIT: begin
                    latched_sample <= sample_buffer_read_data;
                    state <= STATE_VARIANCE_CENTER;
                end

                STATE_VARIANCE_CENTER: begin
                    centered_sample <= add_result;
                    state <= STATE_VARIANCE_SQUARE;
                end

                STATE_VARIANCE_SQUARE: begin
                    squared_sample <= mul_result;
                    state <= STATE_VARIANCE_ADD;
                end

                STATE_VARIANCE_ADD: begin
                    variance_accumulator <= add_result;
                    if ((channel_index + 1) >=
                        active_hidden_size) begin
                        channel_index <= 32'd0;
                        state <= STATE_VARIANCE_SCALE;
                    end else begin
                        channel_index <= channel_index + 1'b1;
                        state <= STATE_VARIANCE_READ;
                    end
                end

                STATE_VARIANCE_SCALE: begin
                    token_variance <= mul_result;
                    state <= STATE_EPSILON_ADD;
                end

                STATE_EPSILON_ADD: begin
                    rsqrt_operand  <= add_result;
                    rsqrt_iteration <= 2'd0;
                    state <= STATE_INV_STD_INIT;
                end

                STATE_INV_STD_INIT: begin
                    if ((rsqrt_operand[30:23] == 8'hff) &&
                        (rsqrt_operand[22:0] != 0)) begin
                        token_inv_std <= FP32_QNAN;
                        channel_index <= 32'd0;
                        state <= STATE_AFFINE_READ;
                    end else if (rsqrt_operand[31] &&
                                 (rsqrt_operand[30:0] != 0)) begin
                        token_inv_std <= FP32_QNAN;
                        channel_index <= 32'd0;
                        state <= STATE_AFFINE_READ;
                    end else if (rsqrt_operand == FP32_POS_INF) begin
                        token_inv_std <= FP32_POS_ZERO;
                        channel_index <= 32'd0;
                        state <= STATE_AFFINE_READ;
                    end else if ((rsqrt_operand[30:23] == 0) &&
                                 (rsqrt_operand[22:0] == 0)) begin
                        token_inv_std <= rsqrt_operand[31]
                            ? FP32_NEG_INF
                            : FP32_POS_INF;
                        channel_index <= 32'd0;
                        state <= STATE_AFFINE_READ;
                    end else begin
                        rsqrt_estimate <=
                            RSQRT_MAGIC - (rsqrt_operand >> 1);
                        state <= STATE_RSQRT_SQUARE;
                    end
                end

                STATE_RSQRT_SQUARE: begin
                    rsqrt_estimate_squared <= mul_result;
                    state <= STATE_RSQRT_OPERAND;
                end

                STATE_RSQRT_OPERAND: begin
                    rsqrt_operand_product <= mul_result;
                    state <= STATE_RSQRT_HALF;
                end

                STATE_RSQRT_HALF: begin
                    rsqrt_scaled_product <= mul_result;
                    state <= STATE_RSQRT_CORRECTION;
                end

                STATE_RSQRT_CORRECTION: begin
                    rsqrt_correction <= add_result;
                    state <= STATE_RSQRT_ESTIMATE;
                end

                STATE_RSQRT_ESTIMATE: begin
                    rsqrt_estimate <= mul_result;
                    if (rsqrt_iteration == 2'd2) begin
                        token_inv_std <= mul_result;
                        channel_index <= 32'd0;
                        state <= STATE_AFFINE_READ;
                    end else begin
                        rsqrt_iteration <= rsqrt_iteration + 1'b1;
                        state <= STATE_RSQRT_SQUARE;
                    end
                end

                STATE_AFFINE_READ: begin
                    if (use_row_affine_buffer &&
                        (token_index != 0)) begin
                        state <= STATE_AFFINE_CACHE_WAIT;
                    end else if (input_valid) begin
                        result_index   <= calculated_data_index;
                        latched_gamma  <= gamma_data;
                        latched_beta   <= beta_data;
                        if (use_row_affine_buffer) begin
                            // The frontend's token-zero packet is retained
                            // unchanged to fetch gamma/beta.  Its redundant
                            // sample word is deliberately ignored.
                            state <= STATE_AFFINE_CACHE_WAIT;
                        end else begin
                            latched_sample <= input_data;
                            state <= STATE_AFFINE_CENTER;
                        end
                    end
                end

                STATE_AFFINE_CACHE_WAIT: begin
                    result_index   <= calculated_data_index;
                    latched_sample <= sample_buffer_read_data;
                    if (token_index != 0) begin
                        latched_gamma <= gamma_buffer_read_data;
                        latched_beta  <= beta_buffer_read_data;
                    end
                    state <= STATE_AFFINE_CENTER;
                end

                STATE_AFFINE_CENTER: begin
                    centered_sample <= add_result;
                    state <= STATE_AFFINE_NORMALIZE;
                end

                STATE_AFFINE_NORMALIZE: begin
                    normalized_sample <= mul_result;
                    state <= STATE_AFFINE_GAMMA;
                end

                STATE_AFFINE_GAMMA: begin
                    gamma_scaled_sample <= mul_result;
                    state <= STATE_AFFINE_BETA;
                end

                STATE_AFFINE_BETA: begin
                    result_data <= add_result;
                    state <= STATE_AFFINE_WRITE;
                end

                STATE_AFFINE_WRITE: begin
                    if (result_ready) begin
                        if ((channel_index + 1) <
                            active_hidden_size) begin
                            channel_index <= channel_index + 1'b1;
                            state <= STATE_AFFINE_READ;
                        end else if ((token_index + 1) <
                                     active_token_count) begin
                            token_index <= token_index + 1'b1;
                            token_base_index <=
                                token_base_index + active_hidden_size;
                            channel_index        <= 32'd0;
                            sum_accumulator      <= FP32_POS_ZERO;
                            variance_accumulator <= FP32_POS_ZERO;
                            token_mean           <= FP32_POS_ZERO;
                            token_variance       <= FP32_POS_ZERO;
                            token_inv_std        <= FP32_POS_ZERO;
                            state <= STATE_SUM_READ;
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
