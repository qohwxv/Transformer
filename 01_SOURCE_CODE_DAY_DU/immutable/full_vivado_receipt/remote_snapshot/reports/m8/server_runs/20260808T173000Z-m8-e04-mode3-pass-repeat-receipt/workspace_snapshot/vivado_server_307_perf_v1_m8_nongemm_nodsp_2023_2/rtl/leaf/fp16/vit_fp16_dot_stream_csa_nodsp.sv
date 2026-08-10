`timescale 1ns/1ps

// One fully independent M6 FP16 dot-product stream.
//
// The recurrence is a 3:2 carry-save compressor, not an FP32 feedback adder.
// It therefore accepts one enabled/disabled term every cycle when the result
// consumer is ready.  A 93-bit fixed-point state represents bit positions
// -48..44 and exactly covers every finite FP16 product and the worst-case sum
// of K_MAX_TERMS=3072 products.  Carry propagation and FP32 RNE conversion are
// moved into the post-TLAST result pipeline.
//
// term_enable suppresses both data and special flags.  This is the tail-safe
// behavior required before an arbitrary disabled lane can enter the primitive.
(* use_dsp = "no" *)
module vit_fp16_dot_stream_csa_nodsp #(
    parameter integer ACC_WIDTH   = 93,
    parameter integer ACC_LSB     = -48,
    parameter integer K_MAX_TERMS = 3072,
    parameter integer FLUSH_SUBNORMALS = 0
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        s_axis_term_tvalid,
    output logic        s_axis_term_tready,
    input  logic [15:0] s_axis_term_a,
    input  logic [15:0] s_axis_term_b,
    input  logic        s_axis_term_enable,
    input  logic        s_axis_term_tlast,

    output logic        m_axis_result_tvalid,
    input  logic        m_axis_result_tready,
    output logic [31:0] m_axis_result_tdata,
    output logic        m_axis_result_tlast,
    output logic        m_axis_result_invalid,
    output logic        m_axis_result_overflow,
    output logic        m_axis_result_subnormal_flushed,
    output logic        m_axis_result_length_error
);

    localparam integer COUNT_WIDTH = $clog2(K_MAX_TERMS + 2);
    localparam integer INDEX_WIDTH = $clog2(ACC_WIDTH);
    localparam logic [COUNT_WIDTH-1:0] K_MAX_COUNT =
        COUNT_WIDTH'(K_MAX_TERMS);

    logic advance_pipeline;

    logic        s0_valid;
    logic [15:0] s0_a;
    logic [15:0] s0_b;
    logic        s0_enable;
    logic        s0_last;

    logic [31:0] mul_result;
    logic        mul_nonfinite;
    logic        mul_is_nan;
    logic        mul_is_inf;
    logic        mul_inf_sign;
    logic        mul_subnormal_flushed;

    logic        s1_valid;
    logic [31:0] s1_product;
    logic        s1_is_nan;
    logic        s1_is_inf;
    logic        s1_inf_sign;
    logic        s1_subnormal_flushed;
    logic        s1_last;

    logic signed [ACC_WIDTH-1:0] aligned_addend;
    logic alignment_lost;
    logic alignment_range_overflow;

    logic        s2_valid;
    logic signed [ACC_WIDTH-1:0] s2_addend;
    logic        s2_is_nan;
    logic        s2_is_inf;
    logic        s2_inf_sign;
    logic        s2_subnormal_flushed;
    logic        s2_alignment_error;
    logic        s2_last;

    logic [ACC_WIDTH-1:0] accumulator_sum;
    logic [ACC_WIDTH-1:0] accumulator_carry;
    logic [COUNT_WIDTH-1:0] accumulator_term_count;
    logic accumulator_nan;
    logic accumulator_pos_inf;
    logic accumulator_neg_inf;
    logic accumulator_subnormal_flushed;
    logic accumulator_alignment_error;
    logic accumulator_length_error;

    logic [ACC_WIDTH-1:0] csa_next_sum;
    logic [ACC_WIDTH-1:0] csa_next_carry;
    logic next_nan;
    logic next_pos_inf;
    logic next_neg_inf;
    logic next_subnormal_flushed;
    logic next_alignment_error;
    logic next_length_error;

    logic f0_valid;
    logic [ACC_WIDTH-1:0] f0_sum;
    logic [ACC_WIDTH-1:0] f0_carry;
    logic f0_invalid;
    logic f0_force_inf;
    logic f0_inf_sign;
    logic f0_subnormal_flushed;
    logic f0_length_error;
    logic f0_overflow;

    logic f1_valid;
    logic signed [ACC_WIDTH-1:0] f1_total;
    logic f1_invalid;
    logic f1_force_inf;
    logic f1_inf_sign;
    logic f1_subnormal_flushed;
    logic f1_length_error;
    logic f1_overflow;
    logic f1_value_sign;
    logic [ACC_WIDTH-1:0] f1_magnitude;
    logic f1_is_zero;
    logic [INDEX_WIDTH-1:0] f1_leading_index;

    logic f2_valid;
    logic f2_value_sign;
    logic [ACC_WIDTH-1:0] f2_magnitude;
    logic f2_is_zero;
    logic [INDEX_WIDTH-1:0] f2_leading_index;
    logic f2_invalid;
    logic f2_force_inf;
    logic f2_inf_sign;
    logic f2_subnormal_flushed;
    logic f2_length_error;
    logic f2_overflow;
    logic [31:0] f2_fp32_result;

    logic out_valid;
    logic [31:0] out_data;
    logic out_invalid;
    logic out_overflow;
    logic out_subnormal_flushed;
    logic out_length_error;

    assign advance_pipeline = !out_valid || m_axis_result_tready;
    assign s_axis_term_tready = rst_n && advance_pipeline;

    assign m_axis_result_tvalid = out_valid;
    assign m_axis_result_tdata = out_data;
    assign m_axis_result_tlast = 1'b1;
    assign m_axis_result_invalid = out_invalid;
    assign m_axis_result_overflow = out_overflow;
    assign m_axis_result_subnormal_flushed = out_subnormal_flushed;
    assign m_axis_result_length_error = out_length_error;

    vit_fp16_mul_to_fp32_comb_nodsp #(
        .FLUSH_SUBNORMALS (FLUSH_SUBNORMALS)
    ) u_multiplier (
        .a                    (s0_a),
        .b                    (s0_b),
        .result               (mul_result),
        .nonfinite            (mul_nonfinite),
        .result_is_nan        (mul_is_nan),
        .result_is_inf        (mul_is_inf),
        .result_inf_sign      (mul_inf_sign),
        .subnormal_flushed    (mul_subnormal_flushed)
    );

    vit_fp32_product_to_fixed_exact #(
        .ACC_WIDTH (ACC_WIDTH),
        .ACC_LSB   (ACC_LSB)
    ) u_product_align (
        .product            (s1_product),
        .product_nonfinite  (s1_is_nan || s1_is_inf),
        .addend             (aligned_addend),
        .alignment_lost     (alignment_lost),
        .range_overflow     (alignment_range_overflow)
    );

    assign csa_next_sum =
        accumulator_sum ^ accumulator_carry ^ s2_addend;
    assign csa_next_carry =
        ((accumulator_sum & accumulator_carry) |
         (accumulator_sum & s2_addend) |
         (accumulator_carry & s2_addend)) << 1;

    assign next_pos_inf =
        accumulator_pos_inf || (s2_is_inf && !s2_inf_sign);
    assign next_neg_inf =
        accumulator_neg_inf || (s2_is_inf && s2_inf_sign);
    assign next_nan =
        accumulator_nan || s2_is_nan ||
        (next_pos_inf && next_neg_inf);
    assign next_subnormal_flushed =
        accumulator_subnormal_flushed || s2_subnormal_flushed;
    assign next_alignment_error =
        accumulator_alignment_error || s2_alignment_error;
    assign next_length_error =
        accumulator_length_error ||
        (accumulator_term_count >= K_MAX_COUNT);

    vit_fixed_analyze #(
        .ACC_WIDTH (ACC_WIDTH),
        .INDEX_WIDTH (INDEX_WIDTH)
    ) u_final_analyze (
        .value          (f1_total),
        .value_sign     (f1_value_sign),
        .magnitude      (f1_magnitude),
        .is_zero        (f1_is_zero),
        .leading_index  (f1_leading_index)
    );

    vit_fixed_normalized_to_fp32_rne #(
        .ACC_WIDTH  (ACC_WIDTH),
        .ACC_LSB    (ACC_LSB),
        .INDEX_WIDTH(INDEX_WIDTH)
    ) u_final_round (
        .magnitude       (f2_magnitude),
        .value_sign      (f2_value_sign),
        .is_zero         (f2_is_zero),
        .leading_index   (f2_leading_index),
        .invalid         (f2_invalid),
        .force_inf       (f2_force_inf),
        .force_inf_sign  (f2_inf_sign),
        .result          (f2_fp32_result)
    );

    initial begin
        if (ACC_WIDTH < 2)
            $fatal(1, "M6 ACC_WIDTH must be at least 2");
        if (K_MAX_TERMS < 1)
            $fatal(1, "M6 K_MAX_TERMS must be positive");
        if ((ACC_WIDTH == 93) && (ACC_LSB != -48))
            $fatal(1, "M6 93-bit full-range proof requires ACC_LSB=-48");
        if ((ACC_LSB == -48) && (K_MAX_TERMS > 3072))
            $fatal(1, "M6 full-range proof is limited to K<=3072");
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            s0_valid <= 1'b0;
            s0_a <= 16'd0;
            s0_b <= 16'd0;
            s0_enable <= 1'b0;
            s0_last <= 1'b0;

            s1_valid <= 1'b0;
            s1_product <= 32'd0;
            s1_is_nan <= 1'b0;
            s1_is_inf <= 1'b0;
            s1_inf_sign <= 1'b0;
            s1_subnormal_flushed <= 1'b0;
            s1_last <= 1'b0;

            s2_valid <= 1'b0;
            s2_addend <= '0;
            s2_is_nan <= 1'b0;
            s2_is_inf <= 1'b0;
            s2_inf_sign <= 1'b0;
            s2_subnormal_flushed <= 1'b0;
            s2_alignment_error <= 1'b0;
            s2_last <= 1'b0;

            accumulator_sum <= '0;
            accumulator_carry <= '0;
            accumulator_term_count <= '0;
            accumulator_nan <= 1'b0;
            accumulator_pos_inf <= 1'b0;
            accumulator_neg_inf <= 1'b0;
            accumulator_subnormal_flushed <= 1'b0;
            accumulator_alignment_error <= 1'b0;
            accumulator_length_error <= 1'b0;

            f0_valid <= 1'b0;
            f0_sum <= '0;
            f0_carry <= '0;
            f0_invalid <= 1'b0;
            f0_force_inf <= 1'b0;
            f0_inf_sign <= 1'b0;
            f0_subnormal_flushed <= 1'b0;
            f0_length_error <= 1'b0;
            f0_overflow <= 1'b0;

            f1_valid <= 1'b0;
            f1_total <= '0;
            f1_invalid <= 1'b0;
            f1_force_inf <= 1'b0;
            f1_inf_sign <= 1'b0;
            f1_subnormal_flushed <= 1'b0;
            f1_length_error <= 1'b0;
            f1_overflow <= 1'b0;

            f2_valid <= 1'b0;
            f2_value_sign <= 1'b0;
            f2_magnitude <= '0;
            f2_is_zero <= 1'b1;
            f2_leading_index <= '0;
            f2_invalid <= 1'b0;
            f2_force_inf <= 1'b0;
            f2_inf_sign <= 1'b0;
            f2_subnormal_flushed <= 1'b0;
            f2_length_error <= 1'b0;
            f2_overflow <= 1'b0;

            out_valid <= 1'b0;
            out_data <= 32'd0;
            out_invalid <= 1'b0;
            out_overflow <= 1'b0;
            out_subnormal_flushed <= 1'b0;
            out_length_error <= 1'b0;
        end else if (advance_pipeline) begin
            // Fully elastic output/finalization pipeline.  If the output is
            // blocked, every state element above it holds and no term is
            // accepted, so no result can be lost or overwritten.
            out_valid <= f2_valid;
            if (f2_valid) begin
                out_data <= f2_fp32_result;
                out_invalid <= f2_invalid;
                out_overflow <= f2_overflow;
                out_subnormal_flushed <= f2_subnormal_flushed;
                out_length_error <= f2_length_error;
            end

            f2_valid <= f1_valid;
            if (f1_valid) begin
                f2_value_sign <= f1_value_sign;
                f2_magnitude <= f1_magnitude;
                f2_is_zero <= f1_is_zero;
                f2_leading_index <= f1_leading_index;
                f2_invalid <= f1_invalid;
                f2_force_inf <= f1_force_inf;
                f2_inf_sign <= f1_inf_sign;
                f2_subnormal_flushed <= f1_subnormal_flushed;
                f2_length_error <= f1_length_error;
                f2_overflow <= f1_overflow;
            end

            f1_valid <= f0_valid;
            if (f0_valid) begin
                f1_total <= $signed(f0_sum) + $signed(f0_carry);
                f1_invalid <= f0_invalid;
                f1_force_inf <= f0_force_inf;
                f1_inf_sign <= f0_inf_sign;
                f1_subnormal_flushed <= f0_subnormal_flushed;
                f1_length_error <= f0_length_error;
                f1_overflow <= f0_overflow;
            end

            f0_valid <= 1'b0;

            if (s2_valid) begin
                if (s2_last) begin
                    f0_valid <= 1'b1;
                    f0_sum <= csa_next_sum;
                    f0_carry <= csa_next_carry;
                    f0_invalid <=
                        next_nan || next_alignment_error ||
                        next_length_error;
                    f0_force_inf <=
                        !next_nan && !next_alignment_error &&
                        !next_length_error &&
                        (next_pos_inf || next_neg_inf);
                    f0_inf_sign <= next_neg_inf;
                    f0_subnormal_flushed <= next_subnormal_flushed;
                    f0_length_error <= next_length_error;
                    f0_overflow <= next_alignment_error;

                    accumulator_sum <= '0;
                    accumulator_carry <= '0;
                    accumulator_term_count <= '0;
                    accumulator_nan <= 1'b0;
                    accumulator_pos_inf <= 1'b0;
                    accumulator_neg_inf <= 1'b0;
                    accumulator_subnormal_flushed <= 1'b0;
                    accumulator_alignment_error <= 1'b0;
                    accumulator_length_error <= 1'b0;
                end else begin
                    accumulator_sum <= csa_next_sum;
                    accumulator_carry <= csa_next_carry;
                    accumulator_term_count <=
                        accumulator_term_count + 1'b1;
                    accumulator_nan <= next_nan;
                    accumulator_pos_inf <= next_pos_inf;
                    accumulator_neg_inf <= next_neg_inf;
                    accumulator_subnormal_flushed <=
                        next_subnormal_flushed;
                    accumulator_alignment_error <= next_alignment_error;
                    accumulator_length_error <= next_length_error;
                end
            end

            s2_valid <= s1_valid;
            if (s1_valid) begin
                s2_addend <= aligned_addend;
                s2_is_nan <= s1_is_nan;
                s2_is_inf <= s1_is_inf;
                s2_inf_sign <= s1_inf_sign;
                s2_subnormal_flushed <= s1_subnormal_flushed;
                s2_alignment_error <=
                    alignment_lost || alignment_range_overflow;
                s2_last <= s1_last;
            end

            s1_valid <= s0_valid;
            if (s0_valid) begin
                if (s0_enable) begin
                    s1_product <= mul_result;
                    s1_is_nan <=
                        mul_is_nan || (mul_nonfinite && !mul_is_inf);
                    s1_is_inf <= mul_is_inf;
                    s1_inf_sign <= mul_inf_sign;
                    s1_subnormal_flushed <= mul_subnormal_flushed;
                end else begin
                    s1_product <= 32'd0;
                    s1_is_nan <= 1'b0;
                    s1_is_inf <= 1'b0;
                    s1_inf_sign <= 1'b0;
                    s1_subnormal_flushed <= 1'b0;
                end
                s1_last <= s0_last;
            end

            s0_valid <= s_axis_term_tvalid;
            if (s_axis_term_tvalid) begin
                s0_a <= s_axis_term_a;
                s0_b <= s_axis_term_b;
                s0_enable <= s_axis_term_enable;
                s0_last <= s_axis_term_tlast;
            end
        end
    end

endmodule
