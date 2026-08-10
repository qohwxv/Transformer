`timescale 1ns/1ps

// Frozen simulation-only copies of the LayerNorm datapaths that preceded the
// shared-FP-ALU refactor.  All module names are private to the equivalence
// test so production hierarchy may change independently.

module vit_fp32_recip_u32_serial_reference (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic [31:0] value,
    output logic        busy,
    output logic        done,
    output logic [31:0] result
);

    localparam logic [31:0] FP32_POS_ZERO = 32'h0000_0000;
    localparam logic [31:0] FP32_POS_INF  = 32'h7f80_0000;

    typedef enum logic [1:0] {
        STATE_IDLE,
        STATE_DIVIDE,
        STATE_ROUND,
        STATE_DONE
    } state_t;

    state_t state;
    logic [63:0] denominator;
    logic [63:0] dividend;
    logic [63:0] quotient;
    logic [63:0] remainder;
    logic [5:0] division_index;
    logic signed [7:0] unbiased_exponent;

    logic [4:0] start_msb_index;
    logic start_power_of_two;
    logic [5:0] start_numerator_shift;
    logic [63:0] shifted_remainder;
    logic [63:0] rounded_quotient;
    logic [63:0] normalized_quotient;
    logic signed [8:0] biased_exponent;
    integer scan_index;

    assign busy = (state != STATE_IDLE);
    assign done = (state == STATE_DONE);
    assign start_power_of_two =
        (value != 0) && ((value & (value - 1'b1)) == 0);
    assign start_numerator_shift =
        start_power_of_two
            ? (6'd23 + {1'b0, start_msb_index})
            : (6'd24 + {1'b0, start_msb_index});
    assign shifted_remainder = {
        remainder[62:0],
        dividend[division_index]
    };

    always_comb begin
        start_msb_index = 5'd0;
        for (scan_index = 0; scan_index < 32;
             scan_index = scan_index + 1)
            if (value[scan_index])
                start_msb_index = 5'(scan_index);
    end

    always_comb begin
        rounded_quotient = quotient;
        if (((remainder << 1) > denominator) ||
            (((remainder << 1) == denominator) && quotient[0]))
            rounded_quotient = quotient + 1'b1;

        normalized_quotient = rounded_quotient;
        biased_exponent =
            $signed(unbiased_exponent) + 9'sd127;
        if (rounded_quotient[24]) begin
            normalized_quotient = rounded_quotient >> 1;
            biased_exponent =
                $signed(unbiased_exponent) + 9'sd128;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state             <= STATE_IDLE;
            denominator       <= 64'd0;
            dividend          <= 64'd0;
            quotient          <= 64'd0;
            remainder         <= 64'd0;
            division_index    <= 6'd0;
            unbiased_exponent <= 8'sd0;
            result            <= FP32_POS_ZERO;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (start) begin
                        if (value == 0) begin
                            result <= FP32_POS_INF;
                            state  <= STATE_DONE;
                        end else begin
                            denominator <= {32'd0, value};
                            dividend <=
                                64'd1 << start_numerator_shift;
                            quotient       <= 64'd0;
                            remainder      <= 64'd0;
                            division_index <= start_numerator_shift;
                            if (start_power_of_two)
                                unbiased_exponent <=
                                    -$signed({3'd0, start_msb_index});
                            else
                                unbiased_exponent <=
                                    -$signed({
                                        3'd0,
                                        start_msb_index
                                    }) - 1'b1;
                            state <= STATE_DIVIDE;
                        end
                    end
                end

                STATE_DIVIDE: begin
                    if (shifted_remainder >= denominator) begin
                        remainder <= shifted_remainder - denominator;
                        quotient[division_index] <= 1'b1;
                    end else begin
                        remainder <= shifted_remainder;
                        quotient[division_index] <= 1'b0;
                    end

                    if (division_index == 0)
                        state <= STATE_ROUND;
                    else
                        division_index <= division_index - 1'b1;
                end

                STATE_ROUND: begin
                    if (biased_exponent >= 9'sd255)
                        result <= FP32_POS_INF;
                    else if (biased_exponent <= 0)
                        result <= FP32_POS_ZERO;
                    else
                        result <= {
                            1'b0,
                            biased_exponent[7:0],
                            normalized_quotient[22:0]
                        };
                    state <= STATE_DONE;
                end

                STATE_DONE:
                    state <= STATE_IDLE;

                default:
                    state <= STATE_IDLE;
            endcase
        end
    end

endmodule

module vit_fp32_rsqrt_step_comb_reference (
    input  logic [31:0] operand,
    input  logic [31:0] estimate,
    output logic [31:0] next_estimate
);

    localparam logic [31:0] FP32_HALF     = 32'h3f00_0000;
    localparam logic [31:0] FP32_ONE_HALF = 32'h3fc0_0000;

    logic [31:0] estimate_squared;
    logic [31:0] operand_product;
    logic [31:0] scaled_product;
    logic [31:0] correction;

    vit_fp32_mul_comb_nodsp u_square (
        .a(estimate), .b(estimate), .result(estimate_squared)
    );
    vit_fp32_mul_comb_nodsp u_operand_product (
        .a(operand), .b(estimate_squared), .result(operand_product)
    );
    vit_fp32_mul_comb_nodsp u_half_product (
        .a(FP32_HALF), .b(operand_product), .result(scaled_product)
    );
    vit_fp32_sub_comb u_correction (
        .a(FP32_ONE_HALF), .b(scaled_product), .result(correction)
    );
    vit_fp32_mul_comb_nodsp u_next_estimate (
        .a(estimate), .b(correction), .result(next_estimate)
    );

endmodule

module vit_layernorm_statistics_datapath_reference (
    input  logic        variance_mode,
    input  logic [31:0] sample,
    input  logic [31:0] mean,
    input  logic [31:0] accumulator,
    input  logic [31:0] scale_operand,
    input  logic [31:0] reciprocal_hidden_size,
    input  logic [31:0] variance,
    input  logic [31:0] epsilon,
    output logic [31:0] accumulation_next,
    output logic [31:0] scaled_statistic,
    output logic [31:0] variance_plus_epsilon
);

    logic [31:0] centered_sample;
    logic [31:0] centered_square;
    logic [31:0] accumulation_addend;

    vit_fp32_sub_comb u_center_sample (
        .a(sample), .b(mean), .result(centered_sample)
    );
    vit_fp32_mul_comb_nodsp u_square_sample (
        .a(centered_sample),
        .b(centered_sample),
        .result(centered_square)
    );

    assign accumulation_addend =
        variance_mode ? centered_square : sample;

    vit_fp32_add_comb u_accumulate (
        .a(accumulator),
        .b(accumulation_addend),
        .result(accumulation_next)
    );
    vit_fp32_mul_comb_nodsp u_scale_statistic (
        .a(scale_operand),
        .b(reciprocal_hidden_size),
        .result(scaled_statistic)
    );
    vit_fp32_add_comb u_add_epsilon (
        .a(variance),
        .b(epsilon),
        .result(variance_plus_epsilon)
    );

endmodule

module vit_layernorm_affine_datapath_reference (
    input  logic [31:0] sample,
    input  logic [31:0] mean,
    input  logic [31:0] inverse_standard_deviation,
    input  logic [31:0] gamma,
    input  logic [31:0] beta,
    output logic [31:0] result
);

    logic [31:0] centered_sample;
    logic [31:0] normalized_sample;
    logic [31:0] scaled_sample;

    vit_fp32_sub_comb u_center (
        .a(sample), .b(mean), .result(centered_sample)
    );
    vit_fp32_mul_comb_nodsp u_normalize (
        .a(centered_sample),
        .b(inverse_standard_deviation),
        .result(normalized_sample)
    );
    vit_fp32_mul_comb_nodsp u_gamma (
        .a(normalized_sample), .b(gamma), .result(scaled_sample)
    );
    vit_fp32_add_comb u_beta (
        .a(scaled_sample), .b(beta), .result(result)
    );

endmodule
