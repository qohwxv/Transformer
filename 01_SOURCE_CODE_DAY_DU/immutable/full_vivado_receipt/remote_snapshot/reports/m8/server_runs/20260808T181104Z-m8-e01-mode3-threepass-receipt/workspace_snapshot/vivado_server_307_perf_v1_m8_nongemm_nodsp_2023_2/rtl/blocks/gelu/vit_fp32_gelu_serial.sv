`timescale 1ns/1ps

// Bit-exact time-multiplexed implementation of vit_fp32_gelu_comb.
//
// The reciprocal refinement, GELU polynomial, exponential range reduction,
// exponential polynomial, and final epilogue replay the same FP32 operation
// order as the combinational reference.  Only one fabric FP32 multiplier and
// one fabric FP32 adder exist in this production datapath.
(* use_dsp = "no" *)
module vit_fp32_gelu_serial #(
    parameter integer USE_EXTERNAL_MUL = 0,
    parameter integer USE_EXTERNAL_ADD = 0
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic [31:0] value,
    output logic        busy,
    output logic        done,
    output logic [31:0] result,

    output logic [31:0] mul_operand_a,
    output logic [31:0] mul_operand_b,
    input  logic [31:0] external_mul_result,

    output logic [31:0] add_operand_a,
    output logic [31:0] add_operand_b,
    input  logic [31:0] external_add_result
);

    localparam logic [31:0] FP32_QNAN      = 32'h7fc0_0000;
    localparam logic [31:0] FP32_POS_ZERO  = 32'h0000_0000;
    localparam logic [31:0] FP32_POS_INF   = 32'h7f80_0000;
    localparam logic [31:0] FP32_NEG_INF   = 32'hff80_0000;
    localparam logic [31:0] FP32_ONE       = 32'h3f80_0000;
    localparam logic [31:0] FP32_HALF      = 32'h3f00_0000;
    localparam logic [31:0] FP32_TWO       = 32'h4000_0000;
    localparam logic [31:0] GELU_INV_SQRT2 = 32'h3f35_04f3;
    localparam logic [31:0] GELU_P         = 32'h3ea7_ba05;
    localparam logic [31:0] GELU_A1        = 32'h3e82_7906;
    localparam logic [31:0] GELU_A2        = 32'hbe91_a98e;
    localparam logic [31:0] GELU_A3        = 32'h3fb5_f0e3;
    localparam logic [31:0] GELU_A4        = 32'hbfba_00e3;
    localparam logic [31:0] GELU_A5        = 32'h3f87_dc22;
    localparam logic [31:0] RECIP_MAGIC    = 32'h7ef3_11c3;
    localparam logic [31:0] EXP_LN2        = 32'h3f31_7218;
    localparam logic [31:0] EXP_INV_LN2    = 32'h3fb8_aa3b;
    localparam logic [31:0] EXP_C8         = 32'h37d0_0d01;
    localparam logic [31:0] EXP_C7         = 32'hb950_0d01;
    localparam logic [31:0] EXP_C6         = 32'h3ab6_0b61;
    localparam logic [31:0] EXP_C5         = 32'hbc08_8889;
    localparam logic [31:0] EXP_C4         = 32'h3d2a_aaab;
    localparam logic [31:0] EXP_C3         = 32'hbe2a_aaab;
    localparam logic [31:0] EXP_C2         = 32'h3f00_0000;
    localparam logic [31:0] EXP_C1         = 32'hbf80_0000;
    localparam logic [31:0] EXP_C0         = 32'h3f80_0000;

    typedef enum logic [4:0] {
        STATE_IDLE,
        STATE_SCALE_VALUE,
        STATE_DENOMINATOR_MUL,
        STATE_DENOMINATOR_ADD,
        STATE_RECIPROCAL_INIT,
        STATE_RECIPROCAL_PRODUCT,
        STATE_RECIPROCAL_CORRECTION,
        STATE_RECIPROCAL_ESTIMATE,
        STATE_GELU_POLY_MUL,
        STATE_GELU_POLY_ADD,
        STATE_SQUARE,
        STATE_EXP_SCALE,
        STATE_EXP_INITIAL_PRODUCT,
        STATE_EXP_INITIAL_REMAINDER,
        STATE_EXP_CORRECTED_PRODUCT,
        STATE_EXP_NEGATIVE_REMAINDER,
        STATE_EXP_POSITIVE_REMAINDER,
        STATE_EXP_POLY_MUL,
        STATE_EXP_POLY_ADD,
        STATE_EXP_SCALE_DOWN,
        STATE_FINAL_POLY_EXP,
        STATE_FINAL_ERF_SUB,
        STATE_FINAL_ONE_PLUS,
        STATE_FINAL_HALF,
        STATE_FINAL_RESULT,
        STATE_DONE
    } state_t;

    state_t state;
    logic [31:0] input_value;
    logic [31:0] scaled_value;
    logic [31:0] reciprocal_denominator;
    logic [31:0] reciprocal_estimate;
    logic [31:0] reciprocal_product;
    logic [31:0] reciprocal_correction;
    logic [1:0] reciprocal_iteration;
    logic [31:0] gelu_polynomial;
    logic [2:0] gelu_polynomial_step;
    logic [31:0] squared_value;
    logic [31:0] exp_scaled;
    logic [31:0] exp_scale_integer_initial;
    logic [31:0] exp_scale_integer_after_negative;
    logic [31:0] exp_scale_integer_final;
    logic [31:0] exp_scale_product;
    logic [31:0] exp_remainder_initial;
    logic [31:0] exp_remainder_negative;
    logic [31:0] exp_remainder_final;
    logic        exp_correct_negative;
    logic [31:0] exp_polynomial;
    logic [2:0] exp_polynomial_step;
    logic [31:0] exponential;
    logic [31:0] polynomial_exponential;
    logic [31:0] erf_magnitude;
    logic [31:0] one_plus_erf;
    logic [31:0] half_value;
    logic [31:0] temporary_result;

    logic [31:0] mul_result;
    logic [31:0] add_result;
    logic [31:0] conversion_integer;
    logic [31:0] integer_as_fp32;
    logic [31:0] exp_scale_integer_comb;
    logic [31:0] scaled_exp_polynomial;
    logic [31:0] gelu_add_coefficient;
    logic [31:0] exp_add_coefficient;
    logic [31:0] exp_integer_after_negative_comb;
    logic [31:0] exp_remainder_after_negative_comb;
    logic        exp_correct_negative_comb;
    logic        exp_correct_positive_comb;
    logic        start_value_nan;
    logic        start_value_zero;

    assign busy = (state != STATE_IDLE);
    assign done = (state == STATE_DONE);
    assign start_value_nan =
        (value[30:23] == 8'hff) && (value[22:0] != 23'd0);
    assign start_value_zero = (value[30:0] == 31'd0);

    assign exp_correct_negative_comb =
        exp_remainder_initial[31] &&
        (exp_remainder_initial[30:0] != 31'd0) &&
        (exp_scale_integer_initial != 0);
    assign exp_integer_after_negative_comb =
        exp_correct_negative_comb
            ? (exp_scale_integer_initial - 1'b1)
            : exp_scale_integer_initial;
    assign exp_remainder_after_negative_comb =
        exp_correct_negative
            ? exp_remainder_negative
            : exp_remainder_initial;
    assign exp_correct_positive_comb =
        !exp_correct_negative &&
        !exp_remainder_after_negative_comb[31] &&
        (exp_remainder_after_negative_comb[30:0] >=
         EXP_LN2[30:0]);

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

    vit_fp32_to_u32_floor_comb u_exp_to_integer (
        .value  (exp_scaled),
        .result (exp_scale_integer_comb)
    );

    vit_fp32_from_u32_comb u_exp_from_integer (
        .value  (conversion_integer),
        .result (integer_as_fp32)
    );

    vit_fp32_scale_pow2_down_comb u_exp_scale_down (
        .value  (exp_polynomial),
        .amount (exp_scale_integer_final),
        .result (scaled_exp_polynomial)
    );

    always_comb begin
        case (gelu_polynomial_step)
            3'd0: gelu_add_coefficient = GELU_A4;
            3'd1: gelu_add_coefficient = GELU_A3;
            3'd2: gelu_add_coefficient = GELU_A2;
            default: gelu_add_coefficient = GELU_A1;
        endcase

        case (exp_polynomial_step)
            3'd0: exp_add_coefficient = EXP_C7;
            3'd1: exp_add_coefficient = EXP_C6;
            3'd2: exp_add_coefficient = EXP_C5;
            3'd3: exp_add_coefficient = EXP_C4;
            3'd4: exp_add_coefficient = EXP_C3;
            3'd5: exp_add_coefficient = EXP_C2;
            3'd6: exp_add_coefficient = EXP_C1;
            default: exp_add_coefficient = EXP_C0;
        endcase
    end

    always_comb begin
        mul_operand_a = FP32_POS_ZERO;
        mul_operand_b = FP32_POS_ZERO;
        add_operand_a = FP32_POS_ZERO;
        add_operand_b = FP32_POS_ZERO;
        conversion_integer = 32'd0;

        case (state)
            STATE_SCALE_VALUE: begin
                mul_operand_a = {1'b0, input_value[30:0]};
                mul_operand_b = GELU_INV_SQRT2;
            end

            STATE_DENOMINATOR_MUL: begin
                mul_operand_a = GELU_P;
                mul_operand_b = scaled_value;
            end

            STATE_DENOMINATOR_ADD: begin
                add_operand_a = FP32_ONE;
                add_operand_b = temporary_result;
            end

            STATE_RECIPROCAL_PRODUCT: begin
                mul_operand_a = reciprocal_denominator;
                mul_operand_b = reciprocal_estimate;
            end

            STATE_RECIPROCAL_CORRECTION: begin
                add_operand_a = FP32_TWO;
                add_operand_b = {
                    ~reciprocal_product[31],
                    reciprocal_product[30:0]
                };
            end

            STATE_RECIPROCAL_ESTIMATE: begin
                mul_operand_a = reciprocal_estimate;
                mul_operand_b = reciprocal_correction;
            end

            STATE_GELU_POLY_MUL: begin
                mul_operand_a =
                    (gelu_polynomial_step == 0)
                        ? GELU_A5
                        : gelu_polynomial;
                mul_operand_b = reciprocal_estimate;
            end

            STATE_GELU_POLY_ADD: begin
                add_operand_a = temporary_result;
                add_operand_b = gelu_add_coefficient;
            end

            STATE_SQUARE: begin
                mul_operand_a = scaled_value;
                mul_operand_b = scaled_value;
            end

            STATE_EXP_SCALE: begin
                mul_operand_a = squared_value;
                mul_operand_b = EXP_INV_LN2;
            end

            STATE_EXP_INITIAL_PRODUCT: begin
                conversion_integer = exp_scale_integer_comb;
                mul_operand_a = integer_as_fp32;
                mul_operand_b = EXP_LN2;
            end

            STATE_EXP_INITIAL_REMAINDER: begin
                add_operand_a = squared_value;
                add_operand_b = {
                    ~exp_scale_product[31],
                    exp_scale_product[30:0]
                };
            end

            STATE_EXP_CORRECTED_PRODUCT: begin
                conversion_integer = exp_integer_after_negative_comb;
                mul_operand_a = integer_as_fp32;
                mul_operand_b = EXP_LN2;
            end

            STATE_EXP_NEGATIVE_REMAINDER: begin
                add_operand_a = squared_value;
                add_operand_b = {
                    ~exp_scale_product[31],
                    exp_scale_product[30:0]
                };
            end

            STATE_EXP_POSITIVE_REMAINDER: begin
                add_operand_a = exp_remainder_after_negative_comb;
                add_operand_b = {~EXP_LN2[31], EXP_LN2[30:0]};
            end

            STATE_EXP_POLY_MUL: begin
                mul_operand_a = exp_remainder_final;
                mul_operand_b =
                    (exp_polynomial_step == 0)
                        ? EXP_C8
                        : exp_polynomial;
            end

            STATE_EXP_POLY_ADD: begin
                add_operand_a = exp_add_coefficient;
                add_operand_b = temporary_result;
            end

            STATE_FINAL_POLY_EXP: begin
                mul_operand_a = gelu_polynomial;
                mul_operand_b = exponential;
            end

            STATE_FINAL_ERF_SUB: begin
                add_operand_a = FP32_ONE;
                add_operand_b = {
                    ~polynomial_exponential[31],
                    polynomial_exponential[30:0]
                };
            end

            STATE_FINAL_ONE_PLUS: begin
                add_operand_a = FP32_ONE;
                add_operand_b =
                    input_value[31]
                        ? {1'b1, erf_magnitude[30:0]}
                        : erf_magnitude;
            end

            STATE_FINAL_HALF: begin
                mul_operand_a = FP32_HALF;
                mul_operand_b = input_value;
            end

            STATE_FINAL_RESULT: begin
                mul_operand_a = half_value;
                mul_operand_b = one_plus_erf;
            end

            default: begin
            end
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state                            <= STATE_IDLE;
            result                           <= FP32_POS_ZERO;
            input_value                      <= FP32_POS_ZERO;
            scaled_value                     <= FP32_POS_ZERO;
            reciprocal_denominator           <= FP32_POS_ZERO;
            reciprocal_estimate              <= FP32_POS_ZERO;
            reciprocal_product               <= FP32_POS_ZERO;
            reciprocal_correction            <= FP32_POS_ZERO;
            reciprocal_iteration             <= 2'd0;
            gelu_polynomial                  <= FP32_POS_ZERO;
            gelu_polynomial_step             <= 3'd0;
            squared_value                    <= FP32_POS_ZERO;
            exp_scaled                       <= FP32_POS_ZERO;
            exp_scale_integer_initial        <= 32'd0;
            exp_scale_integer_after_negative <= 32'd0;
            exp_scale_integer_final          <= 32'd0;
            exp_scale_product                <= FP32_POS_ZERO;
            exp_remainder_initial            <= FP32_POS_ZERO;
            exp_remainder_negative           <= FP32_POS_ZERO;
            exp_remainder_final              <= FP32_POS_ZERO;
            exp_correct_negative             <= 1'b0;
            exp_polynomial                   <= FP32_POS_ZERO;
            exp_polynomial_step              <= 3'd0;
            exponential                     <= FP32_POS_ZERO;
            polynomial_exponential           <= FP32_POS_ZERO;
            erf_magnitude                    <= FP32_POS_ZERO;
            one_plus_erf                     <= FP32_POS_ZERO;
            half_value                       <= FP32_POS_ZERO;
            temporary_result                 <= FP32_POS_ZERO;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (start) begin
                        input_value <= value;
                        if (start_value_nan ||
                            (value == FP32_NEG_INF)) begin
                            result <= FP32_QNAN;
                            state  <= STATE_DONE;
                        end else if (value == FP32_POS_INF) begin
                            result <= FP32_POS_INF;
                            state  <= STATE_DONE;
                        end else if (start_value_zero) begin
                            result <= FP32_POS_ZERO;
                            state  <= STATE_DONE;
                        end else begin
                            state <= STATE_SCALE_VALUE;
                        end
                    end
                end

                STATE_SCALE_VALUE: begin
                    scaled_value <= mul_result;
                    state        <= STATE_DENOMINATOR_MUL;
                end

                STATE_DENOMINATOR_MUL: begin
                    temporary_result <= mul_result;
                    state            <= STATE_DENOMINATOR_ADD;
                end

                STATE_DENOMINATOR_ADD: begin
                    reciprocal_denominator <= add_result;
                    state                  <= STATE_RECIPROCAL_INIT;
                end

                STATE_RECIPROCAL_INIT: begin
                    reciprocal_iteration <= 2'd0;
                    if (reciprocal_denominator == FP32_POS_INF) begin
                        reciprocal_estimate  <= FP32_POS_ZERO;
                        gelu_polynomial_step <= 3'd0;
                        state                <= STATE_GELU_POLY_MUL;
                    end else begin
                        reciprocal_estimate <=
                            RECIP_MAGIC - reciprocal_denominator;
                        state <= STATE_RECIPROCAL_PRODUCT;
                    end
                end

                STATE_RECIPROCAL_PRODUCT: begin
                    reciprocal_product <= mul_result;
                    state              <= STATE_RECIPROCAL_CORRECTION;
                end

                STATE_RECIPROCAL_CORRECTION: begin
                    reciprocal_correction <= add_result;
                    state                 <= STATE_RECIPROCAL_ESTIMATE;
                end

                STATE_RECIPROCAL_ESTIMATE: begin
                    reciprocal_estimate <= mul_result;
                    if (reciprocal_iteration == 2'd3) begin
                        gelu_polynomial_step <= 3'd0;
                        state <= STATE_GELU_POLY_MUL;
                    end else begin
                        reciprocal_iteration <=
                            reciprocal_iteration + 1'b1;
                        state <= STATE_RECIPROCAL_PRODUCT;
                    end
                end

                STATE_GELU_POLY_MUL: begin
                    if (gelu_polynomial_step == 3'd4) begin
                        gelu_polynomial <= mul_result;
                        state           <= STATE_SQUARE;
                    end else begin
                        temporary_result <= mul_result;
                        state            <= STATE_GELU_POLY_ADD;
                    end
                end

                STATE_GELU_POLY_ADD: begin
                    gelu_polynomial      <= add_result;
                    gelu_polynomial_step <= gelu_polynomial_step + 1'b1;
                    state                <= STATE_GELU_POLY_MUL;
                end

                STATE_SQUARE: begin
                    squared_value <= mul_result;
                    state         <= STATE_EXP_SCALE;
                end

                STATE_EXP_SCALE: begin
                    exp_scaled <= mul_result;
                    state      <= STATE_EXP_INITIAL_PRODUCT;
                end

                STATE_EXP_INITIAL_PRODUCT: begin
                    exp_scale_integer_initial <= exp_scale_integer_comb;
                    if (exp_scale_integer_comb >= 32'd127) begin
                        exponential <= FP32_POS_ZERO;
                        state       <= STATE_FINAL_POLY_EXP;
                    end else begin
                        exp_scale_product <= mul_result;
                        state <= STATE_EXP_INITIAL_REMAINDER;
                    end
                end

                STATE_EXP_INITIAL_REMAINDER: begin
                    exp_remainder_initial <= add_result;
                    state <= STATE_EXP_CORRECTED_PRODUCT;
                end

                STATE_EXP_CORRECTED_PRODUCT: begin
                    exp_correct_negative <= exp_correct_negative_comb;
                    exp_scale_integer_after_negative <=
                        exp_integer_after_negative_comb;
                    exp_scale_product <= mul_result;
                    state <= STATE_EXP_NEGATIVE_REMAINDER;
                end

                STATE_EXP_NEGATIVE_REMAINDER: begin
                    exp_remainder_negative <= add_result;
                    state <= STATE_EXP_POSITIVE_REMAINDER;
                end

                STATE_EXP_POSITIVE_REMAINDER: begin
                    exp_scale_integer_final <=
                        exp_scale_integer_after_negative +
                        (exp_correct_positive_comb ? 32'd1 : 32'd0);
                    exp_remainder_final <=
                        exp_correct_positive_comb
                            ? add_result
                            : exp_remainder_after_negative_comb;
                    exp_polynomial_step <= 3'd0;
                    state <= STATE_EXP_POLY_MUL;
                end

                STATE_EXP_POLY_MUL: begin
                    temporary_result <= mul_result;
                    state            <= STATE_EXP_POLY_ADD;
                end

                STATE_EXP_POLY_ADD: begin
                    exp_polynomial <= add_result;
                    if (exp_polynomial_step == 3'd7) begin
                        state <= STATE_EXP_SCALE_DOWN;
                    end else begin
                        exp_polynomial_step <=
                            exp_polynomial_step + 1'b1;
                        state <= STATE_EXP_POLY_MUL;
                    end
                end

                STATE_EXP_SCALE_DOWN: begin
                    exponential <= scaled_exp_polynomial;
                    state       <= STATE_FINAL_POLY_EXP;
                end

                STATE_FINAL_POLY_EXP: begin
                    polynomial_exponential <= mul_result;
                    state <= STATE_FINAL_ERF_SUB;
                end

                STATE_FINAL_ERF_SUB: begin
                    if (add_result[31])
                        erf_magnitude <= FP32_POS_ZERO;
                    else if (add_result[30:0] > FP32_ONE[30:0])
                        erf_magnitude <= FP32_ONE;
                    else
                        erf_magnitude <= add_result;
                    state <= STATE_FINAL_ONE_PLUS;
                end

                STATE_FINAL_ONE_PLUS: begin
                    one_plus_erf <= add_result;
                    state        <= STATE_FINAL_HALF;
                end

                STATE_FINAL_HALF: begin
                    half_value <= mul_result;
                    state      <= STATE_FINAL_RESULT;
                end

                STATE_FINAL_RESULT: begin
                    result <= mul_result;
                    state  <= STATE_DONE;
                end

                STATE_DONE: begin
                    state <= STATE_IDLE;
                end

                default: begin
                    state <= STATE_IDLE;
                end
            endcase
        end
    end

endmodule
