`timescale 1ns/1ps

// Synthesizable LayerNorm engine.
//
// All arithmetic is implemented with bit-vector/integer RTL and has no
// dependency on the simulation-only math package:
//   * 1 / hidden_size is converted directly to an IEEE-754 binary32 value with
//     an integer quotient and round-to-nearest-even.
//   * reciprocal square root uses the well-known exponent/mantissa seed
//     followed by three Newton-Raphson refinements:
//         y[n+1] = y[n] * (1.5 - 0.5 * x * y[n] * y[n])
//
// fp32_add/fp32_mul currently are combinational helpers.  This version is
// therefore suitable for synthesis/bring-up, but a timing-closed high-clock
// implementation should replace them with pipelined FP operators.
//
// The external memory is addressed as a flat token-major tensor:
//     data_index = token_index * hidden_size + channel_index
//
// Every token is read three times:
//   data_pass=0: accumulate the mean
//   data_pass=1: accumulate centered, biased variance
//   data_pass=2: produce affine output; gamma_data/beta_data are used here
//
// The producer may present gamma/beta on every pass; they are consumed only in
// pass 2 and correspond to channel = data_index % hidden_size.
module vit_layernorm_engine_fp32 (
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

    // Current token statistics are exposed for functional debug/comparison.
    output logic [31:0]   debug_mean,
    output logic [31:0]   debug_variance,
    output logic [31:0]   debug_inv_std
);

    import vit_fp32_pkg::*;

    localparam logic [1:0] LN_PASS_MEAN   = 2'd0;
    localparam logic [1:0] LN_PASS_VAR    = 2'd1;
    localparam logic [1:0] LN_PASS_AFFINE = 2'd2;
    localparam logic [31:0] FP32_POS_ZERO = 32'h0000_0000;
    localparam logic [31:0] FP32_POS_INF  = 32'h7f80_0000;
    localparam logic [31:0] FP32_NEG_INF  = 32'hff80_0000;
    localparam logic [31:0] FP32_HALF     = 32'h3f00_0000;
    localparam logic [31:0] FP32_ONE_HALF = 32'h3fc0_0000;
    localparam logic [31:0] RSQRT_MAGIC   = 32'h5f37_5a86;
    localparam logic [1:0] RSQRT_LAST_ITERATION = 2'd2;

    typedef enum logic [3:0] {
        STATE_IDLE,
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
    logic [31:0] channel_index;
    logic [31:0] sum_accumulator;
    logic [31:0] variance_accumulator;
    logic [31:0] token_mean;
    logic [31:0] token_variance;
    logic [31:0] token_inv_std;
    logic [63:0] cfg_total_words;
    logic [31:0] variance_plus_epsilon;
    logic [31:0] rsqrt_operand;
    logic [31:0] rsqrt_estimate;
    logic [1:0]  rsqrt_iteration;
    logic [31:0] rsqrt_estimate_squared;
    logic [31:0] rsqrt_scaled_product;
    logic [31:0] rsqrt_correction;
    logic [31:0] rsqrt_next_estimate;

    always_comb begin
        cfg_total_words = {32'd0, cfg_token_count} * cfg_hidden_size;
    end

    function automatic logic [31:0] fp32_sub_local(
        input logic [31:0] a,
        input logic [31:0] b
    );
        begin
            fp32_sub_local = fp32_add(a, {~b[31], b[30:0]});
        end
    endfunction

    // Convert the exact mathematical value 1/value to binary32 using only
    // unsigned integer arithmetic.  value is a runtime configuration field,
    // so synthesis infers one divider used only when a new LayerNorm job is
    // accepted.  The largest numerator is 2^55 for a 32-bit denominator and
    // therefore fits in the 64-bit intermediates below.
    function automatic logic [31:0] fp32_recip_u32_synth(
        input logic [31:0] value
    );
        logic [63:0] denominator;
        logic [63:0] numerator;
        logic [63:0] quotient;
        logic [63:0] remainder;
        logic [63:0] rounded_quotient;
        logic [63:0] doubled_remainder;
        logic        is_power_of_two;
        integer      bit_index;
        integer      msb_index;
        integer      unbiased_exponent;
        integer      biased_exponent;
        integer      numerator_shift;
        begin
            denominator       = {32'd0, value};
            numerator         = 64'd0;
            quotient          = 64'd0;
            remainder         = 64'd0;
            rounded_quotient  = 64'd0;
            doubled_remainder = 64'd0;
            is_power_of_two   = 1'b0;
            msb_index         = 0;
            unbiased_exponent = 0;
            biased_exponent   = 0;
            numerator_shift   = 0;

            for (bit_index = 0; bit_index < 32; bit_index = bit_index + 1) begin
                if (value[bit_index])
                    msb_index = bit_index;
            end

            if (value == 0) begin
                fp32_recip_u32_synth = FP32_POS_INF;
            end else begin
                is_power_of_two = ((value & (value - 1'b1)) == 0);
                if (is_power_of_two)
                    unbiased_exponent = -msb_index;
                else
                    unbiased_exponent = -(msb_index + 1);

                // normalized_significand =
                //     (1/value) * 2^(-unbiased_exponent)
                numerator_shift = 23 - unbiased_exponent;
                numerator = 64'd1 << numerator_shift;
                quotient = numerator / denominator;
                remainder = numerator % denominator;
                rounded_quotient = quotient;
                doubled_remainder = remainder << 1;

                // Round-to-nearest-even at the binary32 fraction boundary.
                if ((doubled_remainder > denominator) ||
                    ((doubled_remainder == denominator) && quotient[0]))
                    rounded_quotient = quotient + 1'b1;

                // Rounding a 1.111... significand may carry into 10.000...
                if (rounded_quotient[24]) begin
                    rounded_quotient = rounded_quotient >> 1;
                    unbiased_exponent = unbiased_exponent + 1;
                end

                biased_exponent = unbiased_exponent + 127;
                if (biased_exponent >= 255)
                    fp32_recip_u32_synth = FP32_POS_INF;
                else if (biased_exponent <= 0)
                    fp32_recip_u32_synth = FP32_POS_ZERO;
                else
                    fp32_recip_u32_synth = {
                        1'b0,
                        biased_exponent[7:0],
                        rounded_quotient[22:0]
                    };
            end
        end
    endfunction

    assign variance_plus_epsilon = fp32_add(
        token_variance,
        active_epsilon
    );

    // One Newton-Raphson reciprocal-square-root refinement.  Registers around
    // this expression make each refinement consume one controller cycle.
    always_comb begin
        rsqrt_estimate_squared = fp32_mul(
            rsqrt_estimate,
            rsqrt_estimate
        );
        rsqrt_scaled_product = fp32_mul(
            FP32_HALF,
            fp32_mul(rsqrt_operand, rsqrt_estimate_squared)
        );
        rsqrt_correction = fp32_sub_local(
            FP32_ONE_HALF,
            rsqrt_scaled_product
        );
        rsqrt_next_estimate = fp32_mul(
            rsqrt_estimate,
            rsqrt_correction
        );
    end

    assign busy = (state != STATE_IDLE);
    assign done = (state == STATE_DONE);
    assign data_request = (state == STATE_SUM) ||
                          (state == STATE_VARIANCE_SUM) ||
                          (state == STATE_AFFINE_READ);
    assign data_pass = (state == STATE_VARIANCE_SUM) ? LN_PASS_VAR :
                       (state == STATE_AFFINE_READ)  ? LN_PASS_AFFINE :
                                                      LN_PASS_MEAN;
    assign data_index = token_index * active_hidden_size + channel_index;
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
            channel_index              <= 32'd0;
            sum_accumulator            <= 32'd0;
            variance_accumulator       <= 32'd0;
            token_mean                 <= 32'd0;
            token_variance             <= 32'd0;
            token_inv_std              <= 32'd0;
            rsqrt_operand               <= 32'd0;
            rsqrt_estimate              <= 32'd0;
            rsqrt_iteration             <= 2'd0;
            result_index               <= 32'd0;
            result_data                <= 32'd0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (start) begin
                        token_index          <= 32'd0;
                        channel_index        <= 32'd0;
                        sum_accumulator      <= 32'd0;
                        variance_accumulator <= 32'd0;
                        token_mean           <= 32'd0;
                        token_variance       <= 32'd0;
                        token_inv_std        <= 32'd0;
                        rsqrt_operand        <= 32'd0;
                        rsqrt_estimate       <= 32'd0;
                        rsqrt_iteration      <= 2'd0;

                        if ((cfg_token_count == 0) || (cfg_hidden_size == 0) ||
                            (cfg_total_words > 64'h0000_0000_ffff_ffff) ||
                            (cfg_epsilon[30:23] == 8'hFF) ||
                            (cfg_epsilon[31] && (cfg_epsilon[30:0] != 0))) begin
                            config_error <= 1'b1;
                            state <= STATE_DONE;
                        end else begin
                            config_error             <= 1'b0;
                            active_token_count       <= cfg_token_count;
                            active_hidden_size       <= cfg_hidden_size;
                            active_recip_hidden_size <= fp32_recip_u32_synth(
                                cfg_hidden_size
                            );
                            active_epsilon           <= cfg_epsilon;
                            state                    <= STATE_SUM;
                        end
                    end
                end

                STATE_SUM: begin
                    if (input_valid) begin
                        sum_accumulator <= fp32_add(sum_accumulator, input_data);
                        if ((channel_index + 1) >= active_hidden_size) begin
                            channel_index <= 32'd0;
                            state <= STATE_MEAN;
                        end else begin
                            channel_index <= channel_index + 1;
                        end
                    end
                end

                // Separate calculation states ensure the preceding pass's
                // final nonblocking accumulator update is already visible.
                STATE_MEAN: begin
                    token_mean <= fp32_mul(
                        sum_accumulator,
                        active_recip_hidden_size
                    );
                    variance_accumulator <= 32'd0;
                    channel_index <= 32'd0;
                    state <= STATE_VARIANCE_SUM;
                end

                STATE_VARIANCE_SUM: begin
                    if (input_valid) begin
                        variance_accumulator <= fp32_add(
                            variance_accumulator,
                            fp32_mul(
                                fp32_sub_local(input_data, token_mean),
                                fp32_sub_local(input_data, token_mean)
                            )
                        );
                        if ((channel_index + 1) >= active_hidden_size) begin
                            channel_index <= 32'd0;
                            state <= STATE_VARIANCE;
                        end else begin
                            channel_index <= channel_index + 1;
                        end
                    end
                end

                STATE_VARIANCE: begin
                    token_variance <= fp32_mul(
                        variance_accumulator,
                        active_recip_hidden_size
                    );
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
                    end else if (variance_plus_epsilon == FP32_POS_INF) begin
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
                    if (rsqrt_iteration == RSQRT_LAST_ITERATION) begin
                        token_inv_std <= rsqrt_next_estimate;
                        channel_index <= 32'd0;
                        state <= STATE_AFFINE_READ;
                    end else begin
                        rsqrt_iteration <= rsqrt_iteration + 1'b1;
                    end
                end

                STATE_AFFINE_READ: begin
                    if (input_valid) begin
                        result_index <= token_index * active_hidden_size + channel_index;
                        result_data <= fp32_add(
                            fp32_mul(
                                fp32_mul(
                                    fp32_sub_local(input_data, token_mean),
                                    token_inv_std
                                ),
                                gamma_data
                            ),
                            beta_data
                        );
                        state <= STATE_AFFINE_WRITE;
                    end
                end

                // Result data/index stay registered and stable until accepted.
                STATE_AFFINE_WRITE: begin
                    if (result_ready) begin
                        if ((channel_index + 1) < active_hidden_size) begin
                            channel_index <= channel_index + 1;
                            state <= STATE_AFFINE_READ;
                        end else if ((token_index + 1) < active_token_count) begin
                            token_index <= token_index + 1;
                            channel_index <= 32'd0;
                            sum_accumulator <= 32'd0;
                            variance_accumulator <= 32'd0;
                            token_mean <= 32'd0;
                            token_variance <= 32'd0;
                            token_inv_std <= 32'd0;
                            rsqrt_operand <= 32'd0;
                            rsqrt_estimate <= 32'd0;
                            rsqrt_iteration <= 2'd0;
                            state <= STATE_SUM;
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
