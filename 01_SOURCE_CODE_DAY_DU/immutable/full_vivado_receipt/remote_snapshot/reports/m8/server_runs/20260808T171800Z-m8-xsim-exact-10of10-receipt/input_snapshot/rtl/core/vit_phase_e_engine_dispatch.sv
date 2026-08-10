`timescale 1ns/1ps

// Pure command dispatch and status selection.
//
// The stable opcode in active_cmd selects exactly one compute block.  Keeping
// this decode outside the command controller makes the control path explicit:
// command lifecycle -> opcode dispatch -> compute block.
(* use_dsp = "no" *)
module vit_phase_e_engine_dispatch #(
    parameter integer ARRAY_ROWS   = 2,
    parameter integer ARRAY_COLS   = 2,
    parameter integer PE_LANES     = 16,
    parameter integer VECTOR_LANES = 16
)(
    input  vit_phase_e_pkg::phase_e_cmd_t active_cmd,
    input  logic                          launch,
    input  logic                          memory_error_latched,

    input  logic gemm_done,
    input  logic gemm_config_error,
    input  logic gemm_data_request,
    input  logic gemm_result_valid,

    input  logic vector_done,
    input  logic vector_config_error,
    input  logic vector_data_request,
    input  logic vector_result_valid,

    input  logic layout_done,
    input  logic layout_config_error,
    input  logic layout_data_request,
    input  logic layout_result_valid,

    input  logic ln_done,
    input  logic ln_config_error,
    input  logic ln_data_request,
    input  logic ln_result_valid,

    input  logic softmax_done,
    input  logic softmax_config_error,
    input  logic softmax_data_request,
    input  logic softmax_result_valid,

    input  logic gelu_done,
    input  logic gelu_config_error,
    input  logic gelu_data_request,
    input  logic gelu_result_valid,

    input  logic argmax_done,
    input  logic argmax_config_error,
    input  logic argmax_nonfinite_error,
    input  logic argmax_data_request,
    input  logic argmax_result_valid,

    output logic gemm_start,
    output logic vector_start,
    output logic layout_start,
    output logic ln_start,
    output logic softmax_start,
    output logic gelu_start,
    output logic argmax_start,

    output logic selected_done,
    output logic selected_error,
    output logic selected_data_request,
    output logic selected_result_valid,
    output logic [15:0] read_word_count,
    output logic [15:0] write_word_count,
    output logic [1:0] vector_engine_mode
);

    import vit_phase_e_pkg::*;

    localparam integer GEMM_RESULT_WORDS =
        ARRAY_ROWS * ARRAY_COLS;
    localparam integer GEMM_READ_WORDS =
        (ARRAY_ROWS * PE_LANES) +
        (ARRAY_COLS * PE_LANES) +
        ARRAY_COLS;
    localparam integer GEMM_PACKED_B_WORDS =
        ((ARRAY_COLS + 1) / 2) * PE_LANES;
    localparam integer GEMM_PACKED_READ_WORDS =
        (ARRAY_ROWS * PE_LANES) +
        GEMM_PACKED_B_WORDS +
        ARRAY_COLS;
    localparam integer VECTOR_READ_WORDS =
        VECTOR_LANES + VECTOR_LANES;
    localparam logic [15:0] GEMM_RESULT_WORD_COUNT =
        16'(GEMM_RESULT_WORDS);
    localparam logic [15:0] GEMM_READ_WORD_COUNT =
        16'(GEMM_READ_WORDS);
    localparam logic [15:0] GEMM_PACKED_READ_WORD_COUNT =
        16'(GEMM_PACKED_READ_WORDS);
    localparam logic [15:0] VECTOR_READ_WORD_COUNT =
        16'(VECTOR_READ_WORDS);
    localparam logic [15:0] VECTOR_WORD_COUNT =
        16'(VECTOR_LANES);

    initial begin
        if (ARRAY_ROWS <= 0)
            $fatal(1,
                   "vit_phase_e_engine_dispatch requires ARRAY_ROWS > 0");
        if (ARRAY_COLS <= 0)
            $fatal(1,
                   "vit_phase_e_engine_dispatch requires ARRAY_COLS > 0");
        if (PE_LANES <= 0)
            $fatal(1,
                   "vit_phase_e_engine_dispatch requires PE_LANES > 0");
        if (VECTOR_LANES <= 0)
            $fatal(1,
                   "vit_phase_e_engine_dispatch requires VECTOR_LANES > 0");
        if (GEMM_READ_WORDS > 16'hffff)
            $fatal(1, "GEMM read word count must fit 16 bits");
        if (GEMM_PACKED_READ_WORDS > 16'hffff)
            $fatal(1, "packed GEMM read word count must fit 16 bits");
        if (GEMM_RESULT_WORDS > 16'hffff)
            $fatal(1, "GEMM result word count must fit 16 bits");
        if (VECTOR_READ_WORDS > 16'hffff)
            $fatal(1, "Vector read word count must fit 16 bits");
        if (VECTOR_LANES > 16'hffff)
            $fatal(1, "Vector write word count must fit 16 bits");
    end

    assign gemm_start = launch &&
                        (active_cmd.header.opcode == PHASE_E_OP_GEMM);
    assign vector_start = launch &&
                          (active_cmd.header.opcode == PHASE_E_OP_VECTOR);
    assign layout_start = launch &&
                          (active_cmd.header.opcode == PHASE_E_OP_LAYOUT);
    assign ln_start = launch &&
                      (active_cmd.header.opcode == PHASE_E_OP_LAYERNORM);
    assign softmax_start = launch &&
                           (active_cmd.header.opcode == PHASE_E_OP_SOFTMAX);
    assign gelu_start = launch &&
                        (active_cmd.header.opcode == PHASE_E_OP_GELU);
    assign argmax_start = launch &&
                          (active_cmd.header.opcode == PHASE_E_OP_ARGMAX);

    assign vector_engine_mode =
        (active_cmd.header.subop == PHASE_E_SUBOP_VECTOR_SCALE_MASK) ?
        2'd1 : 2'd0;

    always_comb begin
        selected_done = 1'b0;
        selected_error = memory_error_latched;
        selected_data_request = 1'b0;
        selected_result_valid = 1'b0;
        read_word_count = 16'd1;
        write_word_count = 16'd1;

        case (active_cmd.header.opcode)
            PHASE_E_OP_GEMM: begin
                selected_done = gemm_done;
                selected_error =
                    memory_error_latched || gemm_config_error;
                selected_data_request = gemm_data_request;
                selected_result_valid = gemm_result_valid;
                read_word_count =
                    ((active_cmd.header.flags &
                      PHASE_E_FLAG_GEMM_B_FP16_PACKED2) != 0) ?
                    GEMM_PACKED_READ_WORD_COUNT :
                    GEMM_READ_WORD_COUNT;
                write_word_count = GEMM_RESULT_WORD_COUNT;
            end

            PHASE_E_OP_VECTOR: begin
                selected_done = vector_done;
                selected_error =
                    memory_error_latched || vector_config_error;
                selected_data_request = vector_data_request;
                selected_result_valid = vector_result_valid;
                read_word_count = VECTOR_READ_WORD_COUNT;
                write_word_count = VECTOR_WORD_COUNT;
            end

            PHASE_E_OP_LAYOUT: begin
                selected_done = layout_done;
                selected_error =
                    memory_error_latched || layout_config_error;
                selected_data_request = layout_data_request;
                selected_result_valid = layout_result_valid;
            end

            PHASE_E_OP_LAYERNORM: begin
                selected_done = ln_done;
                selected_error =
                    memory_error_latched || ln_config_error;
                selected_data_request = ln_data_request;
                selected_result_valid = ln_result_valid;
                read_word_count = 16'd3;
            end

            PHASE_E_OP_SOFTMAX: begin
                selected_done = softmax_done;
                selected_error =
                    memory_error_latched || softmax_config_error;
                selected_data_request = softmax_data_request;
                selected_result_valid = softmax_result_valid;
            end

            PHASE_E_OP_GELU: begin
                selected_done = gelu_done;
                selected_error =
                    memory_error_latched || gelu_config_error;
                selected_data_request = gelu_data_request;
                selected_result_valid = gelu_result_valid;
                read_word_count = VECTOR_WORD_COUNT;
                write_word_count = VECTOR_WORD_COUNT;
            end

            PHASE_E_OP_ARGMAX: begin
                selected_done = argmax_done;
                selected_error =
                    memory_error_latched ||
                    argmax_config_error ||
                    argmax_nonfinite_error;
                selected_data_request = argmax_data_request;
                selected_result_valid = argmax_result_valid;
            end

            default: begin
                selected_done = 1'b1;
                selected_error = 1'b1;
            end
        endcase
    end

endmodule
