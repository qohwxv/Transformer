`timescale 1ns/1ps

// Maps one native engine result slot to the shared logical word interface.
// Argmax intentionally has no DDR candidate because its result uses the
// class-result sideband captured by vit_phase_e_command_controller.
(* use_dsp = "no" *)
module vit_phase_e_write_address_router #(
    parameter integer ARRAY_ROWS   = 2,
    parameter integer ARRAY_COLS   = 2,
    parameter integer VECTOR_LANES = 16
)(
    input  vit_phase_e_pkg::phase_e_cmd_t active_cmd,
    input  logic [15:0]                   word_index,

    input  logic [65:0] gemm_result_address_base,
    input  logic [ARRAY_ROWS-1:0] gemm_result_token_mask,
    input  logic [ARRAY_COLS-1:0] gemm_result_output_mask,
    input  logic [ARRAY_ROWS*ARRAY_COLS*32-1:0] gemm_result_data,

    input  logic [31:0] vector_result_base,
    input  logic [VECTOR_LANES-1:0] vector_result_lane_mask,
    input  logic [VECTOR_LANES*32-1:0] vector_result_data,

    input  logic [31:0] layout_result_address,
    input  logic [31:0] layout_result_data,
    input  logic [31:0] ln_result_index,
    input  logic [31:0] ln_result_data,
    input  logic [31:0] softmax_result_index,
    input  logic [31:0] softmax_result_data,

    input  logic [31:0] gelu_result_base_index,
    input  logic [VECTOR_LANES-1:0] gelu_result_lane_mask,
    input  logic [VECTOR_LANES*32-1:0] gelu_result_data,

    output logic                              candidate_needed,
    output vit_phase_e_pkg::phase_e_mem_space_t candidate_space,
    output logic [31:0]                       candidate_address,
    output logic                              candidate_address_overflow,
    output logic [31:0]                       candidate_data
);

    import vit_phase_e_pkg::*;

    (* use_dsp = "no" *) logic [95:0] candidate_address_wide;
    integer candidate_row;
    integer candidate_col;
    integer candidate_lane;

    function automatic logic [95:0] widen_word_address(
        input logic [31:0] value
    );
        begin
            widen_word_address = {64'd0, value};
        end
    endfunction

    localparam integer ROW_INDEX_WIDTH =
        (ARRAY_ROWS <= 1) ? 1 : $clog2(ARRAY_ROWS);
    localparam logic [31:0] ARRAY_COLS_U32 = 32'(ARRAY_COLS);

    logic [31:0] word_index_u32;

    assign word_index_u32 = {16'd0, word_index};

    initial begin
        if (ARRAY_ROWS <= 0)
            $fatal(1,
                   "vit_phase_e_write_address_router requires ARRAY_ROWS > 0");
        if (ARRAY_COLS <= 0)
            $fatal(1,
                   "vit_phase_e_write_address_router requires ARRAY_COLS > 0");
        if (VECTOR_LANES <= 0)
            $fatal(1,
                   "vit_phase_e_write_address_router requires VECTOR_LANES > 0");
        if ((ARRAY_ROWS * ARRAY_COLS) > 16'hffff)
            $fatal(1,
                   "GEMM write word count must fit the 16-bit word index");
        if (VECTOR_LANES > 16'hffff)
            $fatal(1,
                   "Vector write word count must fit the 16-bit word index");
    end

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

    always_comb begin
        candidate_needed = 1'b0;
        candidate_space = active_cmd.route.dst_space;
        candidate_address_wide = 96'd0;
        candidate_data = 32'd0;
        candidate_row = 0;
        candidate_col = 0;
        candidate_lane = 0;

        case (active_cmd.header.opcode)
            PHASE_E_OP_GEMM: begin
                candidate_row = word_index_u32 / ARRAY_COLS_U32;
                candidate_col = word_index_u32 % ARRAY_COLS_U32;
                candidate_needed =
                    gemm_result_token_mask[candidate_row] &&
                    gemm_result_output_mask[candidate_col];
                candidate_address_wide =
                    {30'd0, gemm_result_address_base} +
                    scale_stride_by_row(
                        active_cmd.immediate,
                        candidate_row[31:0]
                    ) +
                    widen_word_address(candidate_col[31:0]);
                candidate_data =
                    gemm_result_data[word_index*32 +: 32];
            end

            PHASE_E_OP_VECTOR: begin
                candidate_lane = word_index_u32;
                candidate_needed =
                    vector_result_lane_mask[candidate_lane];
                candidate_address_wide =
                    widen_word_address(active_cmd.dst_base) +
                    widen_word_address(vector_result_base) +
                    widen_word_address(candidate_lane[31:0]);
                candidate_data =
                    vector_result_data[candidate_lane*32 +: 32];
            end

            PHASE_E_OP_LAYOUT: begin
                candidate_needed = 1'b1;
                candidate_address_wide =
                    widen_word_address(layout_result_address);
                candidate_data = layout_result_data;
            end

            PHASE_E_OP_LAYERNORM: begin
                candidate_needed = 1'b1;
                candidate_address_wide =
                    widen_word_address(active_cmd.dst_base) +
                    widen_word_address(ln_result_index);
                candidate_data = ln_result_data;
            end

            PHASE_E_OP_SOFTMAX: begin
                candidate_needed = 1'b1;
                candidate_address_wide =
                    widen_word_address(active_cmd.dst_base) +
                    widen_word_address(softmax_result_index);
                candidate_data = softmax_result_data;
            end

            PHASE_E_OP_GELU: begin
                candidate_lane = word_index_u32;
                candidate_needed =
                    gelu_result_lane_mask[candidate_lane];
                candidate_address_wide =
                    widen_word_address(active_cmd.dst_base) +
                    widen_word_address(gelu_result_base_index) +
                    widen_word_address(candidate_lane[31:0]);
                candidate_data =
                    gelu_result_data[candidate_lane*32 +: 32];
            end

            default: begin
            end
        endcase

        candidate_address = candidate_address_wide[31:0];
        candidate_address_overflow = |candidate_address_wide[95:32];
    end

endmodule
