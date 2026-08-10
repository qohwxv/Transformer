`timescale 1ns/1ps

// Maps one native engine operand slot to the shared logical word interface.
//
// Address math remains 96 bits until the overflow check, so malformed
// descriptors can never silently wrap into another logical memory region.
(* use_dsp = "no" *)
module vit_phase_e_read_address_router #(
    parameter integer ARRAY_ROWS   = 2,
    parameter integer ARRAY_COLS   = 2,
    parameter integer PE_LANES     = 16,
    parameter integer VECTOR_LANES = 16
)(
    input  vit_phase_e_pkg::phase_e_cmd_t active_cmd,
    input  logic [15:0]                   word_index,

    input  logic [31:0] gemm_token_base,
    input  logic [31:0] gemm_output_base,
    input  logic [31:0] gemm_k_base,
    input  logic [65:0] gemm_activation_address_base,
    input  logic [65:0] gemm_weight_address_base,
    input  logic [65:0] gemm_bias_address_base,
    input  logic [31:0] vector_element_base,
    input  logic [31:0] layout_source_address,
    input  logic [1:0]  ln_data_pass,
    input  logic [31:0] ln_data_index,
    input  logic [31:0] ln_data_channel_index,
    input  logic [31:0] softmax_data_index,
    input  logic [31:0] gelu_data_base_index,
    input  logic [VECTOR_LANES-1:0] gelu_data_lane_mask,
    input  logic [31:0] argmax_element_index,

    output logic                              candidate_needed,
    output vit_phase_e_pkg::phase_e_mem_space_t candidate_space,
    output logic [31:0]                       candidate_address,
    output logic                              candidate_address_overflow,
    // M5 contract: speculative line fill is legal only for explicitly
    // blocked, immutable model-B storage.  The count is the number of
    // physically contiguous FP32 words beginning at candidate_address.
    output logic                              candidate_read_ahead_safe,
    output logic [5:0]                        candidate_contiguous_words
);

    import vit_phase_e_pkg::*;

    localparam integer GEMM_A_WORDS =
        ARRAY_ROWS * PE_LANES;
    localparam integer GEMM_B_WORDS =
        ARRAY_COLS * PE_LANES;
    localparam integer GEMM_PACKED_B_WORDS =
        ((ARRAY_COLS + 1) / 2) * PE_LANES;
    localparam logic [31:0] GEMM_A_WORDS_U32 = 32'(GEMM_A_WORDS);
    localparam logic [31:0] GEMM_B_WORDS_U32 = 32'(GEMM_B_WORDS);
    localparam logic [31:0] GEMM_PACKED_B_WORDS_U32 =
        32'(GEMM_PACKED_B_WORDS);
    localparam logic [31:0] PE_LANES_U32 = 32'(PE_LANES);
    localparam logic [31:0] VECTOR_LANES_U32 = 32'(VECTOR_LANES);
    localparam integer ROW_INDEX_WIDTH =
        (ARRAY_ROWS <= 1) ? 1 : $clog2(ARRAY_ROWS);
    localparam integer LANE_INDEX_WIDTH =
        (PE_LANES <= 1) ? 1 : $clog2(PE_LANES);

    (* use_dsp = "no" *) logic [95:0] candidate_address_wide;
    logic [31:0] word_index_u32;
    integer candidate_row;
    integer candidate_col;
    integer candidate_lane;
    logic gemm_b_packed2;
    logic [31:0] gemm_b_storage_words_u32;

    assign word_index_u32 = {16'd0, word_index};
    assign gemm_b_packed2 =
        (active_cmd.header.flags &
         PHASE_E_FLAG_GEMM_B_FP16_PACKED2) != 0;
    assign gemm_b_storage_words_u32 = gemm_b_packed2 ?
        GEMM_PACKED_B_WORDS_U32 : GEMM_B_WORDS_U32;

    initial begin
        if (ARRAY_ROWS <= 0)
            $fatal(1,
                   "vit_phase_e_read_address_router requires ARRAY_ROWS > 0");
        if (ARRAY_COLS <= 0)
            $fatal(1,
                   "vit_phase_e_read_address_router requires ARRAY_COLS > 0");
        if (PE_LANES <= 0)
            $fatal(1,
                   "vit_phase_e_read_address_router requires PE_LANES > 0");
        if (VECTOR_LANES <= 0)
            $fatal(1,
                   "vit_phase_e_read_address_router requires VECTOR_LANES > 0");
        if ((GEMM_A_WORDS + GEMM_B_WORDS + ARRAY_COLS) > 16'hffff)
            $fatal(1,
                   "GEMM read word count must fit the 16-bit word index");
        if ((VECTOR_LANES + VECTOR_LANES) > 16'hffff)
            $fatal(1,
                   "Vector read word count must fit the 16-bit word index");
    end

    function automatic logic [95:0] widen_word_address(
        input logic [31:0] value
    );
        begin
            widen_word_address = {64'd0, value};
        end
    endfunction

    function automatic logic [95:0] scale_stride_by_row(
        input logic [31:0] stride,
        input logic [31:0] factor
    );
        integer scale_bit;
        begin
            scale_stride_by_row = 96'd0;
            for (scale_bit = 0; scale_bit < ROW_INDEX_WIDTH;
                 scale_bit = scale_bit + 1)
                if (factor[scale_bit])
                    scale_stride_by_row =
                        scale_stride_by_row +
                        (widen_word_address(stride) << scale_bit);
        end
    endfunction

    function automatic logic [95:0] scale_stride_by_lane(
        input logic [31:0] stride,
        input logic [31:0] factor
    );
        integer scale_bit;
        begin
            scale_stride_by_lane = 96'd0;
            for (scale_bit = 0; scale_bit < LANE_INDEX_WIDTH;
                 scale_bit = scale_bit + 1)
                if (factor[scale_bit])
                    scale_stride_by_lane =
                        scale_stride_by_lane +
                        (widen_word_address(stride) << scale_bit);
        end
    endfunction

    function automatic logic [95:0] scale_lanes_by_col(
        input logic [31:0] factor
    );
        integer col_step;
        begin
            scale_lanes_by_col = 96'd0;
            for (col_step = 0; col_step < ARRAY_COLS;
                 col_step = col_step + 1)
                if (factor > col_step)
                    scale_lanes_by_col =
                        scale_lanes_by_col +
                        widen_word_address(PE_LANES_U32);
        end
    endfunction

    always_comb begin
        candidate_needed = 1'b0;
        candidate_space = PHASE_E_MEM_NONE;
        candidate_address_wide = 96'd0;
        candidate_read_ahead_safe = 1'b0;
        candidate_contiguous_words = 6'd1;
        candidate_row = 0;
        candidate_col = 0;
        candidate_lane = 0;

        case (active_cmd.header.opcode)
            PHASE_E_OP_GEMM: begin
                if (word_index_u32 < GEMM_A_WORDS_U32) begin
                    candidate_row = word_index_u32 / PE_LANES_U32;
                    candidate_lane = word_index_u32 % PE_LANES_U32;
                    candidate_needed =
                        ((widen_word_address(gemm_token_base) +
                          widen_word_address(candidate_row[31:0])) <
                         widen_word_address(active_cmd.dim1)) &&
                        ((widen_word_address(gemm_k_base) +
                          widen_word_address(candidate_lane[31:0])) <
                         widen_word_address(active_cmd.dim2));
                    candidate_space = active_cmd.route.src0_space;
                    candidate_address_wide =
                        {30'd0, gemm_activation_address_base} +
                        scale_stride_by_row(
                            active_cmd.stride1,
                            candidate_row[31:0]
                        ) +
                        widen_word_address(candidate_lane[31:0]);
                end else if (
                    word_index_u32 <
                    (GEMM_A_WORDS_U32 + gemm_b_storage_words_u32)
                ) begin
                    candidate_space = active_cmd.route.src1_space;
                    if (gemm_b_packed2) begin
                        // Package-v3 order is [LANE][COL_PAIR].  For the
                        // locked C2 tile, physical word lane contains
                        // {column1_half,column0_half}.  The complete padded
                        // K16 block is present, but candidate_needed keeps
                        // semantically invalid K/N tails out of the logical
                        // read count just like package-v2.
                        candidate_col =
                            (word_index_u32 - GEMM_A_WORDS_U32) /
                            PE_LANES_U32;
                        candidate_lane =
                            (word_index_u32 - GEMM_A_WORDS_U32) %
                            PE_LANES_U32;
                        candidate_needed =
                            ((widen_word_address(gemm_output_base) +
                              (widen_word_address(candidate_col[31:0]) << 1)) <
                             widen_word_address(active_cmd.dim3)) &&
                            ((widen_word_address(gemm_k_base) +
                              widen_word_address(candidate_lane[31:0])) <
                             widen_word_address(active_cmd.dim2));
                        candidate_address_wide =
                            {30'd0, gemm_weight_address_base} +
                            widen_word_address(
                                word_index_u32 - GEMM_A_WORDS_U32
                            );
                        if (active_cmd.route.src1_space ==
                            PHASE_E_MEM_PARAM) begin
                            candidate_read_ahead_safe = 1'b1;
                            candidate_contiguous_words = 6'(
                                gemm_b_storage_words_u32 -
                                (word_index_u32 - GEMM_A_WORDS_U32)
                            );
                        end
                    end else begin
                        candidate_col =
                            (word_index_u32 - GEMM_A_WORDS_U32) /
                            PE_LANES_U32;
                        candidate_lane =
                            (word_index_u32 - GEMM_A_WORDS_U32) %
                            PE_LANES_U32;
                        candidate_needed =
                            ((widen_word_address(gemm_output_base) +
                              widen_word_address(candidate_col[31:0])) <
                             widen_word_address(active_cmd.dim3)) &&
                            ((widen_word_address(gemm_k_base) +
                              widen_word_address(candidate_lane[31:0])) <
                             widen_word_address(active_cmd.dim2));
                        if ((active_cmd.header.flags &
                         PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2) != 0) begin
                            candidate_address_wide =
                                {30'd0, gemm_weight_address_base} +
                                scale_lanes_by_col(candidate_col[31:0]) +
                                widen_word_address(candidate_lane[31:0]);
                            // Package-v2 guarantees the complete K16/N2
                            // block, including tail padding, exists in PARAM.
                            if (active_cmd.route.src1_space ==
                                PHASE_E_MEM_PARAM) begin
                                candidate_read_ahead_safe = 1'b1;
                                candidate_contiguous_words = 6'(
                                    GEMM_B_WORDS_U32 -
                                    (word_index_u32 - GEMM_A_WORDS_U32)
                                );
                            end
                        end else
                            candidate_address_wide =
                                {30'd0, gemm_weight_address_base} +
                                scale_stride_by_lane(
                                    active_cmd.stride3,
                                    candidate_lane[31:0]
                                ) +
                                widen_word_address(candidate_col[31:0]);
                    end
                end else begin
                    candidate_col =
                        word_index_u32 -
                        GEMM_A_WORDS_U32 -
                        gemm_b_storage_words_u32;
                    candidate_needed =
                        active_cmd.header.flags[0] &&
                        ((widen_word_address(gemm_k_base) +
                          widen_word_address(PE_LANES_U32)) >=
                         widen_word_address(active_cmd.dim2)) &&
                        ((widen_word_address(gemm_output_base) +
                          widen_word_address(candidate_col[31:0])) <
                         widen_word_address(active_cmd.dim3));
                    candidate_space = active_cmd.route.src2_space;
                    candidate_address_wide =
                        {30'd0, gemm_bias_address_base} +
                        widen_word_address(candidate_col[31:0]);
                end
            end

            PHASE_E_OP_VECTOR: begin
                if (word_index_u32 < VECTOR_LANES_U32) begin
                    candidate_lane = word_index_u32;
                    candidate_needed =
                        ((widen_word_address(vector_element_base) +
                          widen_word_address(candidate_lane[31:0])) <
                         widen_word_address(active_cmd.dim0));
                    candidate_space = active_cmd.route.src0_space;
                    candidate_address_wide =
                        widen_word_address(active_cmd.src0_base) +
                        widen_word_address(vector_element_base) +
                        widen_word_address(candidate_lane[31:0]);
                end else begin
                    candidate_lane =
                        word_index_u32 - VECTOR_LANES_U32;
                    candidate_needed =
                        ((widen_word_address(vector_element_base) +
                          widen_word_address(candidate_lane[31:0])) <
                         widen_word_address(active_cmd.dim0)) &&
                        ((active_cmd.header.subop ==
                            PHASE_E_SUBOP_VECTOR_ADD) ||
                         ((active_cmd.header.subop ==
                            PHASE_E_SUBOP_VECTOR_SCALE_MASK) &&
                          active_cmd.header.flags[1]));
                    candidate_space = active_cmd.route.src1_space;
                    candidate_address_wide =
                        widen_word_address(active_cmd.src1_base) +
                        widen_word_address(vector_element_base) +
                        widen_word_address(candidate_lane[31:0]);
                end
            end

            PHASE_E_OP_LAYOUT: begin
                candidate_needed = 1'b1;
                candidate_space = active_cmd.route.src0_space;
                candidate_address_wide =
                    widen_word_address(layout_source_address);
            end

            PHASE_E_OP_LAYERNORM: begin
                if (word_index == 0) begin
                    candidate_needed = 1'b1;
                    candidate_space = active_cmd.route.src0_space;
                    candidate_address_wide =
                        widen_word_address(active_cmd.src0_base) +
                        widen_word_address(ln_data_index);
                end else if (word_index == 1) begin
                    candidate_needed =
                        (ln_data_pass == 2'd2) && (active_cmd.dim1 != 0);
                    candidate_space = active_cmd.route.src1_space;
                    if (active_cmd.dim1 != 0)
                        candidate_address_wide =
                            widen_word_address(active_cmd.src1_base) +
                            widen_word_address(ln_data_channel_index);
                end else begin
                    candidate_needed =
                        (ln_data_pass == 2'd2) && (active_cmd.dim1 != 0);
                    candidate_space = active_cmd.route.src2_space;
                    if (active_cmd.dim1 != 0)
                        candidate_address_wide =
                            widen_word_address(active_cmd.src2_base) +
                            widen_word_address(ln_data_channel_index);
                end
            end

            PHASE_E_OP_SOFTMAX: begin
                candidate_needed = 1'b1;
                candidate_space = active_cmd.route.src0_space;
                candidate_address_wide =
                    widen_word_address(active_cmd.src0_base) +
                    widen_word_address(softmax_data_index);
            end

            PHASE_E_OP_GELU: begin
                candidate_lane = word_index_u32;
                candidate_needed =
                    gelu_data_lane_mask[candidate_lane];
                candidate_space = active_cmd.route.src0_space;
                candidate_address_wide =
                    widen_word_address(active_cmd.src0_base) +
                    widen_word_address(gelu_data_base_index) +
                    widen_word_address(candidate_lane[31:0]);
            end

            PHASE_E_OP_ARGMAX: begin
                candidate_needed = 1'b1;
                candidate_space = active_cmd.route.src0_space;
                candidate_address_wide =
                    widen_word_address(active_cmd.src0_base) +
                    widen_word_address(argmax_element_index);
            end

            default: begin
            end
        endcase

        candidate_address = candidate_address_wide[31:0];
        candidate_address_overflow = |candidate_address_wide[95:32];
        if (!candidate_needed || candidate_address_overflow) begin
            candidate_read_ahead_safe = 1'b0;
            candidate_contiguous_words = 6'd1;
        end
    end

endmodule
