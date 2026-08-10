`timescale 1ns/1ps

// M7 bridge between the production R8/C2/K16 fixed-width tile seam and the M6
// exact FP16 streaming-dot primitive.
//
// The primary STREAMS=16 geometry maps physical stream s to row=s/2,
// column=s%2.  Every accepted K position converts the eight unique A values
// and two unique B values once, then broadcasts their Cartesian product to all
// sixteen streams.  In packed-B mode the lower 512 weight bits are sixteen
// lane-ordered words, with column 0 in bits [15:0] and column 1 in bits
// [31:16]; those FP16 values bypass the FP32-to-FP16 converters.  STREAMS=8 is
// a controlled fallback: one selected output column is evaluated per
// transaction, so an upstream scheduler must launch two transactions to cover
// both columns.
//
// This leaf deliberately does not prefetch or overlap tile chunks.  It is the
// functional/numerical integration gate before the tagged ping-pong feeder in
// M7.3.  A complete dot may contain up to 192 K16 chunks (K<=3072).
(* keep_hierarchy = "yes", use_dsp = "no" *)
module vit_gemm_fp16_stream_array #(
    parameter integer STREAMS = 16,
    parameter integer FLUSH_SUBNORMALS = 0
) (
    input  logic          clk,
    input  logic          rst,

    input  logic          start_valid_i,
    output logic          start_ready_o,
    input  logic          bias_enable_i,
    input  logic [7:0]    token_valid_i,
    input  logic [1:0]    output_valid_i,
    input  logic          fallback_column_i,
    input  logic          weight_fp16_packed2_i,
    input  logic [63:0]   bias_data_i,

    input  logic          chunk_valid_i,
    output logic          chunk_ready_o,
    input  logic          chunk_last_i,
    input  logic [15:0]   lane_valid_i,
    input  logic [4095:0] activation_data_i,
    input  logic [1023:0] weight_data_i,

    output logic          busy_o,
    output logic          result_valid_o,
    input  logic          result_ready_i,
    output logic [7:0]    result_token_mask_o,
    output logic [1:0]    result_output_mask_o,
    output logic [511:0]  result_data_o,
    output logic [15:0]   result_invalid_o,
    output logic [15:0]   result_overflow_o,
    output logic [15:0]   result_subnormal_flushed_o,
    output logic [15:0]   result_length_error_o,
    output logic          numerical_error_o,
    output logic          done_o,

    // One-cycle observability hooks for the later append-only M7 counters.
    output logic [4:0]    profile_term_accept_count_o,
    output logic [4:0]    profile_disabled_term_accept_count_o,
    output logic          profile_feeder_stall_o,
    output logic          profile_result_backpressure_o,
    output logic          profile_compute_active_o
);

    localparam integer ARRAY_ROWS = 8;
    localparam integer ARRAY_COLS = 2;
    localparam integer PE_LANES = 16;

    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_WAIT_CHUNK,
        STATE_FEED,
        STATE_WAIT_RESULTS,
        STATE_BIAS,
        STATE_OUTPUT
    } state_t;

    state_t state;

    logic        bias_enable_q;
    logic [7:0]  token_valid_q;
    logic [1:0]  output_valid_q;
    logic        fallback_column_q;
    logic        weight_fp16_packed2_q;
    logic [63:0] bias_data_q;

    logic          chunk_last_q;
    logic [15:0]   lane_valid_q;
    logic [4095:0] activation_data_q;
    logic [1023:0] weight_data_q;
    logic [3:0]    lane_index_q;

    logic [STREAMS-1:0] term_pending_q;
    logic [STREAMS-1:0] term_valid;
    logic [STREAMS-1:0] term_ready;
    logic [STREAMS*16-1:0] term_a;
    logic [STREAMS*16-1:0] term_b;
    logic [STREAMS-1:0] term_enable;
    logic [STREAMS-1:0] term_last;
    logic [STREAMS-1:0] term_fire;
    logic [STREAMS-1:0] term_pending_after_fire;

    logic [ARRAY_ROWS*16-1:0] converted_a;
    logic [ARRAY_COLS*16-1:0] converted_b_from_fp32;
    logic [ARRAY_COLS*16-1:0] converted_b;

    logic [STREAMS-1:0] m6_result_valid;
    logic [STREAMS-1:0] m6_result_ready;
    logic [STREAMS*32-1:0] m6_result_data;
    logic [STREAMS-1:0] m6_result_last;
    logic [STREAMS-1:0] m6_result_invalid;
    logic [STREAMS-1:0] m6_result_overflow;
    logic [STREAMS-1:0] m6_result_subnormal_flushed;
    logic [STREAMS-1:0] m6_result_length_error;
    logic [STREAMS-1:0] result_capture_q;
    logic [STREAMS-1:0] result_fire;
    logic [STREAMS-1:0] result_capture_after_fire;

    logic [STREAMS*32-1:0] raw_result_q;
    logic [STREAMS-1:0] raw_invalid_q;
    logic [STREAMS-1:0] raw_overflow_q;
    logic [STREAMS-1:0] raw_subnormal_flushed_q;
    logic [STREAMS-1:0] raw_length_error_q;

    logic [511:0] result_data_q;
    logic [15:0] result_invalid_q;
    logic [15:0] result_overflow_q;
    logic [15:0] result_subnormal_flushed_q;
    logic [15:0] result_length_error_q;
    logic [7:0] result_token_mask_q;
    logic [1:0] result_output_mask_q;
    logic [15:0] logical_result_mask;

    logic [3:0] bias_index_q;
    logic [31:0] bias_add_operand_a;
    logic [31:0] bias_add_operand_b;
    logic [31:0] bias_add_result;
    logic        bias_result_nan;
    logic        bias_result_inf;
    logic [2:0] bias_row_select;
    logic       bias_col_select;
    logic [3:0] bias_logical_index;

    integer route_stream_index;
    integer profile_stream_index;
    integer stream_row;
    integer stream_col;
    integer accept_count;
    integer disabled_accept_count;
    integer reset_index;
    integer mask_row;
    integer mask_col;

    initial begin
        if ((STREAMS != 16) && (STREAMS != 8))
            $fatal(1, "M7 bridge STREAMS must be 16 or 8");
    end

    assign start_ready_o = (state == STATE_IDLE);
    assign chunk_ready_o = (state == STATE_WAIT_CHUNK);
    assign busy_o = (state != STATE_IDLE);
    assign result_valid_o = (state == STATE_OUTPUT);
    assign result_token_mask_o = result_token_mask_q;
    assign result_output_mask_o = result_output_mask_q;
    assign result_data_o = result_data_q;
    assign result_invalid_o = result_invalid_q;
    assign result_overflow_o = result_overflow_q;
    assign result_subnormal_flushed_o = result_subnormal_flushed_q;
    assign result_length_error_o = result_length_error_q;
    assign numerical_error_o =
        (|(result_invalid_q & logical_result_mask)) ||
        (|(result_overflow_q & logical_result_mask)) ||
        (|(result_length_error_q & logical_result_mask));

    always_comb begin
        logical_result_mask = 16'd0;
        for (mask_row = 0; mask_row < ARRAY_ROWS; mask_row = mask_row + 1)
            for (mask_col = 0; mask_col < ARRAY_COLS;
                 mask_col = mask_col + 1)
                if (result_token_mask_q[mask_row] &&
                    result_output_mask_q[mask_col])
                    logical_result_mask[mask_row*ARRAY_COLS+mask_col] =
                        1'b1;
    end

    genvar a_row;
    generate
        for (a_row = 0; a_row < ARRAY_ROWS; a_row = a_row + 1) begin : gen_a_convert
            vit_fp32_to_fp16_rne_gradual u_a_convert (
                .fp32_i (
                    activation_data_q[
                        (a_row*PE_LANES + 32'(lane_index_q))*32 +: 32
                    ]
                ),
                .fp16_o (converted_a[a_row*16 +: 16])
            );
        end
    endgenerate

    genvar b_col;
    generate
        for (b_col = 0; b_col < ARRAY_COLS; b_col = b_col + 1) begin : gen_b_convert
            vit_fp32_to_fp16_rne_gradual u_b_convert (
                .fp32_i (
                    weight_data_q[
                        (b_col*PE_LANES + 32'(lane_index_q))*32 +: 32
                    ]
                ),
                .fp16_o (converted_b_from_fp32[b_col*16 +: 16])
            );
        end
    endgenerate

    // Packed-v3 B arrives in the low half of the unchanged 1024-bit tile
    // seam.  Word lane L is {column1_fp16, column0_fp16}.  Selecting those
    // halves directly avoids an unnecessary FP16->FP32->FP16 round trip while
    // leaving the established mode-5 FP32 storage path bit-for-bit intact.
    always_comb begin
        converted_b = converted_b_from_fp32;
        if (weight_fp16_packed2_q) begin
            converted_b[0*16 +: 16] =
                weight_data_q[lane_index_q*32 +: 16];
            converted_b[1*16 +: 16] =
                weight_data_q[lane_index_q*32 + 16 +: 16];
        end
    end

    always_comb begin
        term_a = '0;
        term_b = '0;
        term_enable = '0;
        term_last = '0;

        for (route_stream_index = 0; route_stream_index < STREAMS;
             route_stream_index = route_stream_index + 1) begin
            if (STREAMS == 16) begin
                stream_row = route_stream_index / ARRAY_COLS;
                stream_col = route_stream_index % ARRAY_COLS;
            end else begin
                stream_row = route_stream_index;
                stream_col = 32'(fallback_column_q);
            end

            term_a[route_stream_index*16 +: 16] =
                converted_a[stream_row*16 +: 16];
            term_b[route_stream_index*16 +: 16] =
                converted_b[stream_col*16 +: 16];
            term_enable[route_stream_index] =
                lane_valid_q[lane_index_q] &&
                token_valid_q[stream_row] &&
                output_valid_q[stream_col];
            term_last[route_stream_index] =
                chunk_last_q && (lane_index_q == 4'd15);
        end
    end

    assign term_valid =
        (state == STATE_FEED) ? term_pending_q : {STREAMS{1'b0}};
    assign term_fire = term_valid & term_ready;
    assign term_pending_after_fire = term_pending_q & ~term_fire;

    assign m6_result_ready =
        (state == STATE_WAIT_RESULTS)
            ? ~result_capture_q
            : {STREAMS{1'b0}};
    assign result_fire = m6_result_valid & m6_result_ready;
    assign result_capture_after_fire = result_capture_q | result_fire;

    always_comb begin
        accept_count = 0;
        disabled_accept_count = 0;
        for (profile_stream_index = 0; profile_stream_index < STREAMS;
             profile_stream_index = profile_stream_index + 1) begin
            if (term_fire[profile_stream_index]) begin
                accept_count = accept_count + 1;
                if (!term_enable[profile_stream_index])
                    disabled_accept_count = disabled_accept_count + 1;
            end
        end
        profile_term_accept_count_o = 5'(accept_count);
        profile_disabled_term_accept_count_o = 5'(disabled_accept_count);
    end

    assign profile_feeder_stall_o =
        (state == STATE_FEED) &&
        (|term_pending_q) &&
        (|(term_pending_q & ~term_ready));
    assign profile_result_backpressure_o =
        (state == STATE_OUTPUT) && !result_ready_i;
    // Exact M7 arithmetic/epilogue activity.  Waiting for the next chunk and
    // holding a completed result under downstream backpressure are excluded.
    assign profile_compute_active_o =
        (state == STATE_FEED) ||
        (state == STATE_WAIT_RESULTS) ||
        (state == STATE_BIAS);

    genvar physical_stream;
    generate
        for (physical_stream = 0; physical_stream < STREAMS;
             physical_stream = physical_stream + 1) begin : gen_stream
            vit_fp16_dot_stream_csa_nodsp #(
                .ACC_WIDTH   (93),
                .ACC_LSB     (-48),
                .K_MAX_TERMS (3072),
                .FLUSH_SUBNORMALS (FLUSH_SUBNORMALS)
            ) u_stream (
                .clk                            (clk),
                .rst_n                          (!rst),
                .s_axis_term_tvalid             (term_valid[physical_stream]),
                .s_axis_term_tready             (term_ready[physical_stream]),
                .s_axis_term_a                  (
                    term_a[physical_stream*16 +: 16]
                ),
                .s_axis_term_b                  (
                    term_b[physical_stream*16 +: 16]
                ),
                .s_axis_term_enable             (term_enable[physical_stream]),
                .s_axis_term_tlast              (term_last[physical_stream]),
                .m_axis_result_tvalid            (
                    m6_result_valid[physical_stream]
                ),
                .m_axis_result_tready            (
                    m6_result_ready[physical_stream]
                ),
                .m_axis_result_tdata             (
                    m6_result_data[physical_stream*32 +: 32]
                ),
                .m_axis_result_tlast             (
                    m6_result_last[physical_stream]
                ),
                .m_axis_result_invalid           (
                    m6_result_invalid[physical_stream]
                ),
                .m_axis_result_overflow          (
                    m6_result_overflow[physical_stream]
                ),
                .m_axis_result_subnormal_flushed (
                    m6_result_subnormal_flushed[physical_stream]
                ),
                .m_axis_result_length_error      (
                    m6_result_length_error[physical_stream]
                )
            );
        end
    endgenerate

    always_comb begin
        if (STREAMS == 16) begin
            bias_row_select = bias_index_q[3:1];
            bias_col_select = bias_index_q[0];
            bias_logical_index = bias_index_q;
        end else begin
            bias_row_select = bias_index_q[2:0];
            bias_col_select = fallback_column_q;
            bias_logical_index = {
                bias_index_q[2:0],
                fallback_column_q
            };
        end

        bias_add_operand_a = raw_result_q[bias_index_q*32 +: 32];
        bias_add_operand_b = bias_data_q[bias_col_select*32 +: 32];
    end

    vit_fp32_add_comb u_bias_adder (
        .a      (bias_add_operand_a),
        .b      (bias_add_operand_b),
        .result (bias_add_result)
    );

    assign bias_result_nan =
        (bias_add_result[30:23] == 8'hff) &&
        (bias_add_result[22:0] != 23'd0);
    assign bias_result_inf =
        (bias_add_result[30:23] == 8'hff) &&
        (bias_add_result[22:0] == 23'd0);

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= STATE_IDLE;
            bias_enable_q <= 1'b0;
            token_valid_q <= 8'd0;
            output_valid_q <= 2'd0;
            fallback_column_q <= 1'b0;
            weight_fp16_packed2_q <= 1'b0;
            bias_data_q <= 64'd0;
            chunk_last_q <= 1'b0;
            lane_valid_q <= 16'd0;
            activation_data_q <= '0;
            weight_data_q <= '0;
            lane_index_q <= 4'd0;
            term_pending_q <= '0;
            result_capture_q <= '0;
            raw_result_q <= '0;
            raw_invalid_q <= '0;
            raw_overflow_q <= '0;
            raw_subnormal_flushed_q <= '0;
            raw_length_error_q <= '0;
            result_data_q <= '0;
            result_invalid_q <= '0;
            result_overflow_q <= '0;
            result_subnormal_flushed_q <= '0;
            result_length_error_q <= '0;
            result_token_mask_q <= '0;
            result_output_mask_q <= '0;
            bias_index_q <= '0;
            done_o <= 1'b0;
        end else begin
            done_o <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    if (start_valid_i) begin
                        bias_enable_q <= bias_enable_i;
                        token_valid_q <= token_valid_i;
                        output_valid_q <= output_valid_i;
                        fallback_column_q <= fallback_column_i;
                        weight_fp16_packed2_q <= weight_fp16_packed2_i;
                        bias_data_q <= bias_data_i;
                        result_data_q <= '0;
                        result_invalid_q <= '0;
                        result_overflow_q <= '0;
                        result_subnormal_flushed_q <= '0;
                        result_length_error_q <= '0;
                        result_token_mask_q <= token_valid_i;
                        if (STREAMS == 16)
                            result_output_mask_q <= output_valid_i;
                        else if (fallback_column_i)
                            result_output_mask_q <=
                                output_valid_i & 2'b10;
                        else
                            result_output_mask_q <=
                                output_valid_i & 2'b01;
                        result_capture_q <= '0;
                        state <= STATE_WAIT_CHUNK;
                    end
                end

                STATE_WAIT_CHUNK: begin
                    if (chunk_valid_i) begin
                        chunk_last_q <= chunk_last_i;
                        lane_valid_q <= lane_valid_i;
                        activation_data_q <= activation_data_i;
                        weight_data_q <= weight_data_i;
                        // The production frontend supplies bias with the
                        // final K16 panel.  Refresh the tile-local snapshot on
                        // that accepted panel so K>16 uses the real bias,
                        // while retaining the start snapshot for K<=16 and
                        // direct leaf users.
                        if (chunk_last_i)
                            bias_data_q <= bias_data_i;
                        lane_index_q <= 4'd0;
                        term_pending_q <= {STREAMS{1'b1}};
                        state <= STATE_FEED;
                    end
                end

                STATE_FEED: begin
                    if (|term_fire) begin
                        term_pending_q <= term_pending_after_fire;
                        if (term_pending_after_fire == {STREAMS{1'b0}}) begin
                            if (lane_index_q == 4'd15) begin
                                term_pending_q <= '0;
                                if (chunk_last_q) begin
                                    result_capture_q <= '0;
                                    state <= STATE_WAIT_RESULTS;
                                end else begin
                                    state <= STATE_WAIT_CHUNK;
                                end
                            end else begin
                                lane_index_q <= lane_index_q + 1'b1;
                                term_pending_q <= {STREAMS{1'b1}};
                            end
                        end
                    end
                end

                STATE_WAIT_RESULTS: begin
                    for (reset_index = 0; reset_index < STREAMS;
                         reset_index = reset_index + 1) begin
                        if (result_fire[reset_index]) begin
                            raw_result_q[reset_index*32 +: 32] <=
                                m6_result_data[reset_index*32 +: 32];
                            raw_invalid_q[reset_index] <=
                                m6_result_invalid[reset_index];
                            raw_overflow_q[reset_index] <=
                                m6_result_overflow[reset_index];
                            raw_subnormal_flushed_q[reset_index] <=
                                m6_result_subnormal_flushed[reset_index];
                            raw_length_error_q[reset_index] <=
                                m6_result_length_error[reset_index];
                        end
                    end
                    result_capture_q <= result_capture_after_fire;
                    if (result_capture_after_fire == {STREAMS{1'b1}}) begin
                        bias_index_q <= '0;
                        state <= STATE_BIAS;
                    end
                end

                STATE_BIAS: begin
                    if (token_valid_q[bias_row_select] &&
                        output_valid_q[bias_col_select]) begin
                        if (bias_enable_q)
                            result_data_q[
                                bias_logical_index*32 +: 32
                            ] <= bias_add_result;
                        else
                            result_data_q[
                                bias_logical_index*32 +: 32
                            ] <= bias_add_operand_a;
                        result_invalid_q[bias_logical_index] <=
                            raw_invalid_q[bias_index_q] ||
                            (bias_enable_q && bias_result_nan);
                        result_overflow_q[bias_logical_index] <=
                            raw_overflow_q[bias_index_q] ||
                            (bias_enable_q && bias_result_inf);
                        result_subnormal_flushed_q[bias_logical_index] <=
                            raw_subnormal_flushed_q[bias_index_q];
                        result_length_error_q[bias_logical_index] <=
                            raw_length_error_q[bias_index_q];
                    end

                    if (bias_index_q == 4'(STREAMS - 1))
                        state <= STATE_OUTPUT;
                    else
                        bias_index_q <= bias_index_q + 1'b1;
                end

                STATE_OUTPUT: begin
                    if (result_ready_i) begin
                        done_o <= 1'b1;
                        state <= STATE_IDLE;
                    end
                end

                default: begin
                    state <= STATE_IDLE;
                end
            endcase
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst) begin
            if ((state == STATE_WAIT_RESULTS) && (|result_fire) &&
                (|(result_fire & ~m6_result_last)))
                $fatal(1, "M7 bridge observed a result without TLAST");
        end
    end
`endif

endmodule
