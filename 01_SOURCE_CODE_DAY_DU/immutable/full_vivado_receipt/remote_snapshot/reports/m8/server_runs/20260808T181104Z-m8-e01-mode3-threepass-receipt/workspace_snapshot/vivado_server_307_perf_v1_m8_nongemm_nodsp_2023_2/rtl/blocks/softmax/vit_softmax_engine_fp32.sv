`timescale 1ns/1ps

// Stable FP32 Softmax with one time-shared multiplier and one time-shared
// adder.  The FSM replays the same arithmetic edges and rounding points as the
// former combinational exp/reciprocal datapaths.
//
// The external memory is a flat row-major tensor:
//     data_index = row_index * row_length + element_index
//
// When ENABLE_ROW_EXP_BUFFER is nonzero and the configured row fits, each row
// is read from external memory once:
//   pass 0: find max and retain the row in one local 32-bit buffer
//   pass 1: read the local row, compute exp(x-max), accumulate the sum, and
//           replace each consumed input with its rounded FP32 exponential
//   pass 2: read the retained exponential, normalize, and write
//
// The buffer is deliberately one in-place, synchronous, single-port memory.
// It adds no arithmetic and stores the exact exponential_value that the legacy
// output pass would deterministically recompute.  Rows larger than the buffer
// fall back to the original three-read/recompute schedule.
(* use_dsp = "no" *)
module vit_softmax_engine_fp32 #(
    parameter integer USE_EXTERNAL_MUL = 0,
    parameter integer USE_EXTERNAL_ADD = 0,
    parameter integer ENABLE_ROW_EXP_BUFFER = 1,
    parameter integer ROW_EXP_BUFFER_DEPTH = 1024
) (
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
    output logic [31:0]   debug_exp_sum,

    output logic [31:0]   mul_operand_a,
    output logic [31:0]   mul_operand_b,
    input  logic [31:0]   external_mul_result,

    output logic [31:0]   add_operand_a,
    output logic [31:0]   add_operand_b,
    input  logic [31:0]   external_add_result
);

    localparam logic [1:0] SOFTMAX_PASS_MAX    = 2'd0;
    localparam logic [1:0] SOFTMAX_PASS_SUM    = 2'd1;
    localparam logic [1:0] SOFTMAX_PASS_OUTPUT = 2'd2;
    localparam logic [31:0] FP32_QNAN          = 32'h7fc0_0000;
    localparam logic [31:0] FP32_POS_ZERO      = 32'h0000_0000;
    localparam logic [31:0] FP32_POS_INF       = 32'h7f80_0000;
    localparam logic [31:0] FP32_NEG_INF       = 32'hff80_0000;
    localparam logic [31:0] FP32_ONE           = 32'h3f80_0000;
    localparam logic [31:0] FP32_TWO           = 32'h4000_0000;
    localparam logic [31:0] RECIP_MAGIC        = 32'h7ef3_11c3;
    localparam logic [31:0] EXP_LN2            = 32'h3f31_7218;
    localparam logic [31:0] EXP_INV_LN2        = 32'h3fb8_aa3b;
    localparam logic [31:0] EXP_C8             = 32'h37d0_0d01;
    localparam logic [31:0] EXP_C7             = 32'hb950_0d01;
    localparam logic [31:0] EXP_C6             = 32'h3ab6_0b61;
    localparam logic [31:0] EXP_C5             = 32'hbc08_8889;
    localparam logic [31:0] EXP_C4             = 32'h3d2a_aaab;
    localparam logic [31:0] EXP_C3             = 32'hbe2a_aaab;
    localparam logic [31:0] EXP_C2             = 32'h3f00_0000;
    localparam logic [31:0] EXP_C1             = 32'hbf80_0000;
    localparam logic [31:0] EXP_C0             = 32'h3f80_0000;
    localparam integer ROW_EXP_BUFFER_WORDS =
        (ROW_EXP_BUFFER_DEPTH < 1) ? 1 : ROW_EXP_BUFFER_DEPTH;
    localparam integer ROW_EXP_BUFFER_ADDR_WIDTH =
        (ROW_EXP_BUFFER_WORDS <= 1) ? 1 : $clog2(ROW_EXP_BUFFER_WORDS);
    localparam logic [31:0] ROW_EXP_BUFFER_LIMIT = ROW_EXP_BUFFER_WORDS;

    typedef enum logic [4:0] {
        STATE_IDLE,
        STATE_TOTAL_START,
        STATE_TOTAL_WAIT,
        STATE_MAX,
        STATE_EXP_SUM_READ,
        STATE_EXP_CENTER,
        STATE_EXP_SCALE,
        STATE_EXP_INITIAL_PRODUCT,
        STATE_EXP_INITIAL_REMAINDER,
        STATE_EXP_CORRECTED_PRODUCT,
        STATE_EXP_NEGATIVE_REMAINDER,
        STATE_EXP_POSITIVE_REMAINDER,
        STATE_EXP_POLY_MUL,
        STATE_EXP_POLY_ADD,
        STATE_EXP_SCALE_DOWN,
        STATE_EXP_ACCUMULATE,
        STATE_RECIPROCAL_INIT,
        STATE_RECIPROCAL_PRODUCT,
        STATE_RECIPROCAL_CORRECTION,
        STATE_RECIPROCAL_ESTIMATE,
        STATE_OUTPUT_READ,
        STATE_OUTPUT_NORMALIZE,
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
    logic [31:0] calculated_data_index;
    logic [31:0] maximum_candidate;
    logic        row_exp_buffer_active;
    logic [ROW_EXP_BUFFER_ADDR_WIDTH-1:0] row_exp_buffer_address;
    logic        row_exp_buffer_read_enable;
    logic        row_exp_buffer_write_enable;
    logic [31:0] row_exp_buffer_read_data;
    logic [31:0] row_exp_buffer_write_data;

    // No reset is intentional: validity is bounded by the active row FSM and
    // every location is initialized from external input before it is read.
    (* ram_style = "block" *)
    logic [31:0] row_exp_buffer [0:ROW_EXP_BUFFER_WORDS-1];

    generate
        if (ROW_EXP_BUFFER_DEPTH < 1) begin : gen_invalid_buffer_depth
            initial begin
                $error("ROW_EXP_BUFFER_DEPTH must be at least one");
            end
        end
    endgenerate

    logic [31:0] exp_input_value;
    logic [31:0] centered_value;
    logic        exp_output_phase;
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
    logic [2:0]  exp_polynomial_step;
    logic [31:0] exponential_value;
    logic [31:0] temporary_result;

    logic [31:0] reciprocal_operand;
    logic [31:0] reciprocal_estimate;
    logic [31:0] reciprocal_product;
    logic [31:0] reciprocal_correction;
    logic [1:0]  reciprocal_iteration;

    logic [31:0] mul_result;
    logic [31:0] add_result;
    logic [31:0] conversion_integer;
    logic [31:0] integer_as_fp32;
    logic [31:0] exp_scale_integer_comb;
    logic [31:0] scaled_exp_polynomial;
    logic [31:0] exp_add_coefficient;
    logic [31:0] exp_integer_after_negative_comb;
    logic [31:0] exp_remainder_after_negative_comb;
    logic        exp_correct_negative_comb;
    logic        exp_correct_positive_comb;
    logic        centered_value_nan;
    logic        centered_value_zero;
    logic        exponential_sum_nan;
    logic        exponential_sum_zero;
    logic        total_words_start;
    logic        total_words_done;
    logic [63:0] total_words_product;

    assign calculated_data_index = row_base_index + element_index;

    assign busy = (state != STATE_IDLE);
    assign done = (state == STATE_DONE);
    assign data_request =
        (state == STATE_MAX) ||
        ((state == STATE_EXP_SUM_READ) && !row_exp_buffer_active) ||
        ((state == STATE_OUTPUT_READ) && !row_exp_buffer_active);
    assign data_pass =
        (state == STATE_EXP_SUM_READ) ? SOFTMAX_PASS_SUM :
        (state == STATE_OUTPUT_READ)  ? SOFTMAX_PASS_OUTPUT :
                                       SOFTMAX_PASS_MAX;
    assign data_index = calculated_data_index;
    assign row_exp_buffer_address =
        element_index[ROW_EXP_BUFFER_ADDR_WIDTH-1:0];
    assign row_exp_buffer_read_enable =
        row_exp_buffer_active &&
        ((state == STATE_EXP_SUM_READ) ||
         (state == STATE_OUTPUT_READ));
    assign row_exp_buffer_write_enable =
        row_exp_buffer_active &&
        (((state == STATE_MAX) && input_valid) ||
         (state == STATE_EXP_ACCUMULATE));
    assign row_exp_buffer_write_data =
        (state == STATE_MAX) ? input_data : exponential_value;
    assign result_valid = (state == STATE_OUTPUT_WRITE);
    assign debug_row_max = row_maximum;
    assign debug_exp_sum = exponential_sum;
    assign total_words_start = (state == STATE_TOTAL_START);

    // One registered read destination and one mutually exclusive write/read
    // branch match the canonical synchronous single-port block-RAM template.
    always_ff @(posedge clk) begin
        if (row_exp_buffer_write_enable)
            row_exp_buffer[row_exp_buffer_address] <=
                row_exp_buffer_write_data;
        else if (row_exp_buffer_read_enable)
            row_exp_buffer_read_data <=
                row_exp_buffer[row_exp_buffer_address];
    end

    vit_u32_mul_iterative_nodsp u_total_words_multiplier (
        .clk       (clk),
        .rst       (rst),
        .start     (total_words_start),
        .operand_a (active_row_count),
        .operand_b (active_row_length),
        .busy      (),
        .done      (total_words_done),
        .product   (total_words_product)
    );

    assign centered_value_nan =
        (centered_value[30:23] == 8'hff) &&
        (centered_value[22:0] != 23'd0);
    assign centered_value_zero =
        (centered_value[30:0] == 31'd0);
    assign exponential_sum_nan =
        (exponential_sum[30:23] == 8'hff) &&
        (exponential_sum[22:0] != 23'd0);
    assign exponential_sum_zero =
        (exponential_sum[30:0] == 31'd0);

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
            STATE_EXP_CENTER: begin
                add_operand_a = row_exp_buffer_active
                    ? row_exp_buffer_read_data
                    : exp_input_value;
                add_operand_b = {
                    ~row_maximum[31],
                    row_maximum[30:0]
                };
            end

            STATE_EXP_SCALE: begin
                mul_operand_a = {1'b0, centered_value[30:0]};
                mul_operand_b = EXP_INV_LN2;
            end

            STATE_EXP_INITIAL_PRODUCT: begin
                conversion_integer = exp_scale_integer_comb;
                mul_operand_a = integer_as_fp32;
                mul_operand_b = EXP_LN2;
            end

            STATE_EXP_INITIAL_REMAINDER: begin
                add_operand_a = {1'b0, centered_value[30:0]};
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
                add_operand_a = {1'b0, centered_value[30:0]};
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

            STATE_EXP_ACCUMULATE: begin
                add_operand_a = exponential_sum;
                add_operand_b = exponential_value;
            end

            STATE_RECIPROCAL_PRODUCT: begin
                mul_operand_a = reciprocal_operand;
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

            STATE_OUTPUT_NORMALIZE: begin
                mul_operand_a = row_exp_buffer_active
                    ? row_exp_buffer_read_data
                    : exponential_value;
                mul_operand_b = reciprocal_sum;
            end

            default: begin
            end
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state                            <= STATE_IDLE;
            config_error                     <= 1'b0;
            active_row_count                 <= 32'd0;
            active_row_length                <= 32'd0;
            row_index                        <= 32'd0;
            row_base_index                   <= 32'd0;
            element_index                    <= 32'd0;
            row_maximum                      <= FP32_NEG_INF;
            exponential_sum                  <= FP32_POS_ZERO;
            reciprocal_sum                   <= FP32_POS_ZERO;
            result_index                     <= 32'd0;
            result_data                      <= FP32_POS_ZERO;
            exp_input_value                  <= FP32_POS_ZERO;
            centered_value                   <= FP32_POS_ZERO;
            exp_output_phase                 <= 1'b0;
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
            exponential_value                <= FP32_POS_ZERO;
            temporary_result                 <= FP32_POS_ZERO;
            reciprocal_operand               <= FP32_POS_ZERO;
            reciprocal_estimate              <= FP32_POS_ZERO;
            reciprocal_product               <= FP32_POS_ZERO;
            reciprocal_correction            <= FP32_POS_ZERO;
            reciprocal_iteration             <= 2'd0;
            row_exp_buffer_active             <= 1'b0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (start) begin
                        row_index       <= 32'd0;
                        row_base_index  <= 32'd0;
                        element_index   <= 32'd0;
                        row_maximum     <= FP32_NEG_INF;
                        exponential_sum <= FP32_POS_ZERO;
                        reciprocal_sum  <= FP32_POS_ZERO;
                        row_exp_buffer_active <=
                            (ENABLE_ROW_EXP_BUFFER != 0) &&
                            (cfg_row_length <= ROW_EXP_BUFFER_LIMIT);

                        if ((cfg_row_count == 0) ||
                            (cfg_row_length == 0)) begin
                            config_error <= 1'b1;
                            state <= STATE_DONE;
                        end else begin
                            config_error      <= 1'b0;
                            active_row_count  <= cfg_row_count;
                            active_row_length <= cfg_row_length;
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
                            state <= STATE_MAX;
                        end
                    end
                end

                STATE_MAX: begin
                    if (input_valid) begin
                        if (element_index == 0)
                            row_maximum <= input_data;
                        else
                            row_maximum <= maximum_candidate;

                        if ((element_index + 1) >=
                            active_row_length) begin
                            element_index   <= 32'd0;
                            exponential_sum <= FP32_POS_ZERO;
                            state           <= STATE_EXP_SUM_READ;
                        end else begin
                            element_index <= element_index + 1'b1;
                        end
                    end
                end

                STATE_EXP_SUM_READ: begin
                    if (row_exp_buffer_active) begin
                        exp_output_phase <= 1'b0;
                        state <= STATE_EXP_CENTER;
                    end else if (input_valid) begin
                        exp_input_value  <= input_data;
                        exp_output_phase <= 1'b0;
                        state            <= STATE_EXP_CENTER;
                    end
                end

                STATE_EXP_CENTER: begin
                    centered_value <= add_result;
                    state          <= STATE_EXP_SCALE;
                end

                STATE_EXP_SCALE: begin
                    if (centered_value_nan) begin
                        exponential_value <= FP32_QNAN;
                        if (exp_output_phase)
                            state <= STATE_OUTPUT_NORMALIZE;
                        else
                            state <= STATE_EXP_ACCUMULATE;
                    end else if (centered_value == FP32_NEG_INF) begin
                        exponential_value <= FP32_POS_ZERO;
                        if (exp_output_phase)
                            state <= STATE_OUTPUT_NORMALIZE;
                        else
                            state <= STATE_EXP_ACCUMULATE;
                    end else if (centered_value_zero) begin
                        exponential_value <= FP32_ONE;
                        if (exp_output_phase)
                            state <= STATE_OUTPUT_NORMALIZE;
                        else
                            state <= STATE_EXP_ACCUMULATE;
                    end else if (!centered_value[31]) begin
                        exponential_value <= FP32_QNAN;
                        if (exp_output_phase)
                            state <= STATE_OUTPUT_NORMALIZE;
                        else
                            state <= STATE_EXP_ACCUMULATE;
                    end else begin
                        exp_scaled <= mul_result;
                        state      <= STATE_EXP_INITIAL_PRODUCT;
                    end
                end

                STATE_EXP_INITIAL_PRODUCT: begin
                    exp_scale_integer_initial <= exp_scale_integer_comb;
                    if (exp_scale_integer_comb >= 32'd127) begin
                        exponential_value <= FP32_POS_ZERO;
                        if (exp_output_phase)
                            state <= STATE_OUTPUT_NORMALIZE;
                        else
                            state <= STATE_EXP_ACCUMULATE;
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
                    exponential_value <= scaled_exp_polynomial;
                    if (exp_output_phase)
                        state <= STATE_OUTPUT_NORMALIZE;
                    else
                        state <= STATE_EXP_ACCUMULATE;
                end

                STATE_EXP_ACCUMULATE: begin
                    exponential_sum <= add_result;
                    if ((element_index + 1) >=
                        active_row_length) begin
                        element_index <= 32'd0;
                        state         <= STATE_RECIPROCAL_INIT;
                    end else begin
                        element_index <= element_index + 1'b1;
                        state         <= STATE_EXP_SUM_READ;
                    end
                end

                STATE_RECIPROCAL_INIT: begin
                    reciprocal_operand   <= exponential_sum;
                    reciprocal_iteration <= 2'd0;

                    if (exponential_sum_nan ||
                        exponential_sum[31]) begin
                        reciprocal_sum <= FP32_QNAN;
                        element_index  <= 32'd0;
                        state          <= STATE_OUTPUT_READ;
                    end else if (exponential_sum == FP32_POS_INF) begin
                        reciprocal_sum <= FP32_POS_ZERO;
                        element_index  <= 32'd0;
                        state          <= STATE_OUTPUT_READ;
                    end else if (exponential_sum_zero) begin
                        reciprocal_sum <= FP32_POS_INF;
                        element_index  <= 32'd0;
                        state          <= STATE_OUTPUT_READ;
                    end else begin
                        reciprocal_estimate <=
                            RECIP_MAGIC - exponential_sum;
                        state <= STATE_RECIPROCAL_PRODUCT;
                    end
                end

                STATE_RECIPROCAL_PRODUCT: begin
                    reciprocal_product <= mul_result;
                    state              <= STATE_RECIPROCAL_CORRECTION;
                end

                STATE_RECIPROCAL_CORRECTION: begin
                    reciprocal_correction <= add_result;
                    state <= STATE_RECIPROCAL_ESTIMATE;
                end

                STATE_RECIPROCAL_ESTIMATE: begin
                    reciprocal_estimate <= mul_result;
                    if (reciprocal_iteration == 2'd3) begin
                        reciprocal_sum <= mul_result;
                        element_index  <= 32'd0;
                        state          <= STATE_OUTPUT_READ;
                    end else begin
                        reciprocal_iteration <=
                            reciprocal_iteration + 1'b1;
                        state <= STATE_RECIPROCAL_PRODUCT;
                    end
                end

                STATE_OUTPUT_READ: begin
                    if (row_exp_buffer_active) begin
                        result_index <= calculated_data_index;
                        state <= STATE_OUTPUT_NORMALIZE;
                    end else if (input_valid) begin
                        result_index     <= calculated_data_index;
                        exp_input_value  <= input_data;
                        exp_output_phase <= 1'b1;
                        state            <= STATE_EXP_CENTER;
                    end
                end

                STATE_OUTPUT_NORMALIZE: begin
                    result_data <= mul_result;
                    state       <= STATE_OUTPUT_WRITE;
                end

                STATE_OUTPUT_WRITE: begin
                    if (result_ready) begin
                        if ((element_index + 1) <
                            active_row_length) begin
                            element_index <= element_index + 1'b1;
                            state <= STATE_OUTPUT_READ;
                        end else if ((row_index + 1) <
                                     active_row_count) begin
                            row_index <= row_index + 1'b1;
                            row_base_index <=
                                row_base_index + active_row_length;
                            element_index   <= 32'd0;
                            row_maximum     <= FP32_NEG_INF;
                            exponential_sum <= FP32_POS_ZERO;
                            reciprocal_sum  <= FP32_POS_ZERO;
                            state           <= STATE_MAX;
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
