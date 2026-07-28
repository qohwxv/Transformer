`timescale 1ns/1ps

// Descriptor-only model sequencer for ViT Phase E.
//
// This module deliberately does not instantiate arithmetic engines or memory.
// It emits one stable 512-bit command, waits for cmd_ready, and then waits for
// cmd_done or cmd_error before advancing.  A future engine top/memory adapter
// is therefore free to take an arbitrary number of cycles per command.
//
// Supported jobs:
//   E01: prepared patch-A embedding path (four commands)
//   E02: encoder layer 0
//   E03: configurable inclusive encoder layer range
//   E04: final LayerNorm, CLS select, classifier, argmax, optional Softmax
//   E05: E01, all twelve encoder layers, then E04
module vit_phase_e_sequencer (
    input  logic                                      clk,
    input  logic                                      rst,

    input  logic                                      job_valid,
    output logic                                      job_ready,
    input  vit_phase_e_pkg::phase_e_job_t             job,
    input  vit_phase_e_pkg::phase_e_global_params_t   global_params,

    // One parameter-table entry is requested before each encoder layer.  The
    // request and index remain stable until layer_param_valid is observed.
    output logic                                      layer_param_request,
    output logic [3:0]                                layer_param_index,
    input  logic                                      layer_param_valid,
    input  vit_phase_e_pkg::phase_e_layer_params_t    layer_param_data,

    // Execution-command handshake.  cmd is stable while cmd_valid is stalled.
    output logic                                      cmd_valid,
    input  logic                                      cmd_ready,
    output vit_phase_e_pkg::phase_e_cmd_t             cmd,
    input  logic                                      cmd_done,
    input  logic                                      cmd_error,

    // When enabled in the job, one checkpoint is emitted after every
    // successful command.  Backpressure here intentionally pauses sequencing.
    output logic                                      checkpoint_valid,
    input  logic                                      checkpoint_ready,
    output vit_phase_e_pkg::phase_e_phase_t           checkpoint_phase,
    output vit_phase_e_pkg::phase_e_section_t         checkpoint_section,
    output logic [3:0]                                checkpoint_layer,
    output logic [4:0]                                checkpoint_step,
    output logic [7:0]                                checkpoint_tag,
    output vit_phase_e_pkg::phase_e_opcode_t          checkpoint_opcode,
    output vit_phase_e_pkg::phase_e_tensor_id_t       checkpoint_dst_tensor,

    output logic                                      busy,
    output logic                                      done,
    output logic                                      error,
    output vit_phase_e_pkg::phase_e_error_t           error_code,
    output vit_phase_e_pkg::phase_e_section_t         error_section,
    output logic [3:0]                                error_layer,
    output logic [4:0]                                error_step
);

    import vit_phase_e_pkg::*;

    typedef enum logic [2:0] {
        SEQ_IDLE,
        SEQ_LOAD_LAYER,
        SEQ_ISSUE,
        SEQ_WAIT_COMMAND,
        SEQ_CHECKPOINT,
        SEQ_ADVANCE,
        SEQ_DONE
    } sequencer_state_t;

    sequencer_state_t state;
    phase_e_job_t active_job;
    phase_e_global_params_t active_global_params;
    phase_e_layer_params_t active_layer_params;
    phase_e_section_t section;
    logic [3:0] current_layer;
    logic [4:0] current_step;
    logic [7:0] command_ordinal;
    logic [7:0] common_flags;
    phase_e_cmd_t generated_cmd;

    function automatic phase_e_cmd_route_t make_route(
        input phase_e_tensor_id_t src0_tensor,
        input phase_e_tensor_id_t src1_tensor,
        input phase_e_tensor_id_t src2_tensor,
        input phase_e_tensor_id_t dst_tensor
    );
        phase_e_cmd_route_t value;
        begin
            value = '0;
            value.src0_tensor = src0_tensor;
            value.src1_tensor = src1_tensor;
            value.src2_tensor = src2_tensor;
            value.dst_tensor = dst_tensor;
            value.src0_space = phase_e_tensor_default_space(src0_tensor);
            value.src1_space = phase_e_tensor_default_space(src1_tensor);
            value.src2_space = phase_e_tensor_default_space(src2_tensor);
            value.dst_space = phase_e_tensor_default_space(dst_tensor);
            make_route = value;
        end
    endfunction

    function automatic phase_e_cmd_t make_gemm(
        input logic [7:0] tag,
        input logic [7:0] flags,
        input phase_e_tensor_id_t a_tensor,
        input phase_e_tensor_id_t b_tensor,
        input phase_e_tensor_id_t bias_tensor,
        input phase_e_tensor_id_t c_tensor,
        input logic [31:0] a_base,
        input logic [31:0] b_base,
        input logic [31:0] bias_base,
        input logic [31:0] c_base,
        input logic [31:0] batches,
        input logic [31:0] rows,
        input logic [31:0] reduction,
        input logic [31:0] columns,
        input logic [31:0] a_batch_stride,
        input logic [31:0] a_row_stride,
        input logic [31:0] b_batch_stride,
        input logic [31:0] b_row_stride,
        input logic [31:0] c_batch_stride,
        input logic [31:0] c_row_stride
    );
        phase_e_cmd_t value;
        begin
            value = '0;
            value.header.opcode = PHASE_E_OP_GEMM;
            value.header.subop = PHASE_E_SUBOP_NONE;
            value.header.flags = flags;
            value.header.tag = tag;
            value.route = make_route(a_tensor, b_tensor, bias_tensor, c_tensor);
            value.src0_base = a_base;
            value.src1_base = b_base;
            value.src2_base = bias_base;
            value.dst_base = c_base;
            value.dim0 = batches;
            value.dim1 = rows;
            value.dim2 = reduction;
            value.dim3 = columns;
            value.stride0 = a_batch_stride;
            value.stride1 = a_row_stride;
            value.stride2 = b_batch_stride;
            value.stride3 = b_row_stride;
            value.stride4 = c_batch_stride;
            value.immediate = c_row_stride;
            make_gemm = value;
        end
    endfunction

    function automatic phase_e_cmd_t make_vector(
        input logic [7:0] tag,
        input logic [7:0] flags,
        input phase_e_subop_t subop,
        input phase_e_tensor_id_t a_tensor,
        input phase_e_tensor_id_t b_tensor,
        input phase_e_tensor_id_t dst_tensor,
        input logic [31:0] a_base,
        input logic [31:0] b_base,
        input logic [31:0] dst_base,
        input logic [31:0] length,
        input logic [31:0] scalar
    );
        phase_e_cmd_t value;
        begin
            value = '0;
            value.header.opcode = PHASE_E_OP_VECTOR;
            value.header.subop = subop;
            value.header.flags = flags;
            value.header.tag = tag;
            value.route = make_route(
                a_tensor, b_tensor, PHASE_E_TENSOR_NONE, dst_tensor
            );
            value.src0_base = a_base;
            value.src1_base = b_base;
            value.dst_base = dst_base;
            value.dim0 = length;
            value.immediate = scalar;
            make_vector = value;
        end
    endfunction

    function automatic phase_e_cmd_t make_layout(
        input logic [7:0] tag,
        input logic [7:0] flags,
        input phase_e_tensor_id_t src_tensor,
        input phase_e_tensor_id_t dst_tensor,
        input logic [31:0] src_base,
        input logic [31:0] dst_base,
        input logic [31:0] dim0,
        input logic [31:0] dim1,
        input logic [31:0] dim2,
        input logic [31:0] src_stride0,
        input logic [31:0] src_stride1,
        input logic [31:0] src_stride2
    );
        phase_e_cmd_t value;
        begin
            value = '0;
            value.header.opcode = PHASE_E_OP_LAYOUT;
            value.header.subop = PHASE_E_SUBOP_LAYOUT_COPY;
            value.header.flags = flags;
            value.header.tag = tag;
            value.route = make_route(
                src_tensor, PHASE_E_TENSOR_NONE, PHASE_E_TENSOR_NONE, dst_tensor
            );
            value.src0_base = src_base;
            value.dst_base = dst_base;
            value.dim0 = dim0;
            value.dim1 = dim1;
            value.dim2 = dim2;
            value.stride0 = src_stride0;
            value.stride1 = src_stride1;
            value.stride2 = src_stride2;
            make_layout = value;
        end
    endfunction

    function automatic phase_e_cmd_t make_layernorm(
        input logic [7:0] tag,
        input logic [7:0] flags,
        input phase_e_tensor_id_t src_tensor,
        input phase_e_tensor_id_t dst_tensor,
        input logic [31:0] src_base,
        input logic [31:0] gamma_base,
        input logic [31:0] beta_base,
        input logic [31:0] dst_base
    );
        phase_e_cmd_t value;
        begin
            value = '0;
            value.header.opcode = PHASE_E_OP_LAYERNORM;
            value.header.subop = PHASE_E_SUBOP_NONE;
            value.header.flags = flags;
            value.header.tag = tag;
            value.route = make_route(
                src_tensor, PHASE_E_TENSOR_WEIGHT, PHASE_E_TENSOR_BIAS, dst_tensor
            );
            value.src0_base = src_base;
            value.src1_base = gamma_base;
            value.src2_base = beta_base;
            value.dst_base = dst_base;
            value.dim0 = VIT_TOKEN_COUNT;
            value.dim1 = VIT_HIDDEN_SIZE;
            value.immediate = VIT_LN_EPSILON_FP32;
            make_layernorm = value;
        end
    endfunction

    function automatic phase_e_cmd_t make_softmax(
        input logic [7:0] tag,
        input logic [7:0] flags,
        input phase_e_tensor_id_t src_tensor,
        input phase_e_tensor_id_t dst_tensor,
        input logic [31:0] src_base,
        input logic [31:0] dst_base,
        input logic [31:0] row_count,
        input logic [31:0] row_length
    );
        phase_e_cmd_t value;
        begin
            value = '0;
            value.header.opcode = PHASE_E_OP_SOFTMAX;
            value.header.subop = PHASE_E_SUBOP_NONE;
            value.header.flags = flags;
            value.header.tag = tag;
            value.route = make_route(
                src_tensor, PHASE_E_TENSOR_NONE, PHASE_E_TENSOR_NONE, dst_tensor
            );
            value.src0_base = src_base;
            value.dst_base = dst_base;
            value.dim0 = row_count;
            value.dim1 = row_length;
            make_softmax = value;
        end
    endfunction

    function automatic phase_e_cmd_t make_gelu(
        input logic [7:0] tag,
        input logic [7:0] flags,
        input phase_e_tensor_id_t src_tensor,
        input phase_e_tensor_id_t dst_tensor,
        input logic [31:0] src_base,
        input logic [31:0] dst_base,
        input logic [31:0] length
    );
        phase_e_cmd_t value;
        begin
            value = '0;
            value.header.opcode = PHASE_E_OP_GELU;
            value.header.subop = PHASE_E_SUBOP_NONE;
            value.header.flags = flags;
            value.header.tag = tag;
            value.route = make_route(
                src_tensor, PHASE_E_TENSOR_NONE, PHASE_E_TENSOR_NONE, dst_tensor
            );
            value.src0_base = src_base;
            value.dst_base = dst_base;
            value.dim0 = length;
            make_gelu = value;
        end
    endfunction

    function automatic phase_e_cmd_t make_argmax(
        input logic [7:0] tag,
        input logic [7:0] flags,
        input phase_e_tensor_id_t src_tensor,
        input logic [31:0] src_base,
        input logic [31:0] length
    );
        phase_e_cmd_t value;
        begin
            value = '0;
            value.header.opcode = PHASE_E_OP_ARGMAX;
            value.header.subop = PHASE_E_SUBOP_NONE;
            value.header.flags = flags;
            value.header.tag = tag;
            value.route = make_route(
                src_tensor,
                PHASE_E_TENSOR_NONE,
                PHASE_E_TENSOR_NONE,
                PHASE_E_TENSOR_NONE
            );
            value.src0_base = src_base;
            value.dim0 = length;
            make_argmax = value;
        end
    endfunction

    assign job_ready = (state == SEQ_IDLE);
    assign busy = (state != SEQ_IDLE);
    assign done = (state == SEQ_DONE);
    assign layer_param_request = (state == SEQ_LOAD_LAYER);
    assign layer_param_index = current_layer;
    assign cmd_valid = (state == SEQ_ISSUE);
    assign cmd = generated_cmd;
    assign checkpoint_valid = (state == SEQ_CHECKPOINT);
    assign checkpoint_phase = active_job.phase;
    assign checkpoint_section = section;
    assign checkpoint_layer =
        (section == PHASE_E_SECTION_ENCODER) ? current_layer : 4'hf;
    assign checkpoint_step = current_step;
    assign checkpoint_tag = generated_cmd.header.tag;
    assign checkpoint_opcode = generated_cmd.header.opcode;
    assign checkpoint_dst_tensor = generated_cmd.route.dst_tensor;

    always_comb begin
        common_flags = 8'd0;
        if (active_job.checkpoint_enable)
            common_flags = PHASE_E_FLAG_CHECKPOINT;

        generated_cmd = '0;
        generated_cmd.header.opcode = PHASE_E_OP_NOP;
        generated_cmd.header.tag = active_job.job_tag + command_ordinal;

        case (section)
            PHASE_E_SECTION_EMBEDDING: begin
                case (current_step)
                    5'd0: generated_cmd = make_gemm(
                        active_job.job_tag + command_ordinal,
                        common_flags | PHASE_E_FLAG_BIAS_ENABLE,
                        PHASE_E_TENSOR_PATCH_A,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        active_job.patch_a_base,
                        active_global_params.patch_weight_base,
                        active_global_params.patch_bias_base,
                        PHASE_E_ADDR_LINEAR_TMP,
                        32'd1, VIT_PATCH_COUNT, VIT_HIDDEN_SIZE, VIT_HIDDEN_SIZE,
                        VIT_PATCH_WORDS, VIT_HIDDEN_SIZE,
                        32'd0, VIT_HIDDEN_SIZE,
                        VIT_PATCH_WORDS, VIT_HIDDEN_SIZE
                    );

                    5'd1: generated_cmd = make_layout(
                        active_job.job_tag + command_ordinal,
                        common_flags,
                        PHASE_E_TENSOR_CLS,
                        PHASE_E_TENSOR_HIDDEN_A,
                        active_global_params.cls_base,
                        PHASE_E_ADDR_HIDDEN_A,
                        32'd1, 32'd1, VIT_HIDDEN_SIZE,
                        32'd0, 32'd0, 32'd1
                    );

                    5'd2: generated_cmd = make_layout(
                        active_job.job_tag + command_ordinal,
                        common_flags,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_TENSOR_HIDDEN_A,
                        PHASE_E_ADDR_LINEAR_TMP,
                        PHASE_E_ADDR_HIDDEN_A + VIT_HIDDEN_SIZE,
                        32'd1, VIT_PATCH_COUNT, VIT_HIDDEN_SIZE,
                        32'd0, VIT_HIDDEN_SIZE, 32'd1
                    );

                    5'd3: generated_cmd = make_vector(
                        active_job.job_tag + command_ordinal,
                        common_flags | PHASE_E_FLAG_IN_PLACE,
                        PHASE_E_SUBOP_VECTOR_ADD,
                        PHASE_E_TENSOR_HIDDEN_A,
                        PHASE_E_TENSOR_POSITION,
                        PHASE_E_TENSOR_HIDDEN_A,
                        PHASE_E_ADDR_HIDDEN_A,
                        active_global_params.position_base,
                        PHASE_E_ADDR_HIDDEN_A,
                        VIT_HIDDEN_WORDS,
                        32'd0
                    );

                    default: begin
                    end
                endcase
            end

            PHASE_E_SECTION_ENCODER: begin
                case (current_step)
                    PHASE_E_LAYER_LN1: generated_cmd = make_layernorm(
                        active_job.job_tag + command_ordinal,
                        common_flags,
                        PHASE_E_TENSOR_HIDDEN_A,
                        PHASE_E_TENSOR_HIDDEN_B,
                        PHASE_E_ADDR_HIDDEN_A,
                        active_layer_params.ln1_gamma_base,
                        active_layer_params.ln1_beta_base,
                        PHASE_E_ADDR_HIDDEN_B
                    );

                    PHASE_E_LAYER_Q_GEMM: generated_cmd = make_gemm(
                        active_job.job_tag + command_ordinal,
                        common_flags | PHASE_E_FLAG_BIAS_ENABLE,
                        PHASE_E_TENSOR_HIDDEN_B,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_ADDR_HIDDEN_B,
                        active_layer_params.q_weight_base,
                        active_layer_params.q_bias_base,
                        PHASE_E_ADDR_LINEAR_TMP,
                        32'd1, VIT_TOKEN_COUNT, VIT_HIDDEN_SIZE, VIT_HIDDEN_SIZE,
                        VIT_HIDDEN_WORDS, VIT_HIDDEN_SIZE,
                        32'd0, VIT_HIDDEN_SIZE,
                        VIT_HIDDEN_WORDS, VIT_HIDDEN_SIZE
                    );

                    PHASE_E_LAYER_Q_SPLIT: generated_cmd = make_layout(
                        active_job.job_tag + command_ordinal,
                        common_flags,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_TENSOR_Q_HEAD,
                        PHASE_E_ADDR_LINEAR_TMP,
                        PHASE_E_ADDR_Q_HEAD,
                        VIT_HEAD_COUNT, VIT_TOKEN_COUNT, VIT_HEAD_SIZE,
                        VIT_HEAD_SIZE, VIT_HIDDEN_SIZE, 32'd1
                    );

                    PHASE_E_LAYER_K_GEMM: generated_cmd = make_gemm(
                        active_job.job_tag + command_ordinal,
                        common_flags | PHASE_E_FLAG_BIAS_ENABLE,
                        PHASE_E_TENSOR_HIDDEN_B,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_ADDR_HIDDEN_B,
                        active_layer_params.k_weight_base,
                        active_layer_params.k_bias_base,
                        PHASE_E_ADDR_LINEAR_TMP,
                        32'd1, VIT_TOKEN_COUNT, VIT_HIDDEN_SIZE, VIT_HIDDEN_SIZE,
                        VIT_HIDDEN_WORDS, VIT_HIDDEN_SIZE,
                        32'd0, VIT_HIDDEN_SIZE,
                        VIT_HIDDEN_WORDS, VIT_HIDDEN_SIZE
                    );

                    PHASE_E_LAYER_K_SPLIT: generated_cmd = make_layout(
                        active_job.job_tag + command_ordinal,
                        common_flags,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_TENSOR_K_HEAD,
                        PHASE_E_ADDR_LINEAR_TMP,
                        PHASE_E_ADDR_K_HEAD,
                        VIT_HEAD_COUNT, VIT_TOKEN_COUNT, VIT_HEAD_SIZE,
                        VIT_HEAD_SIZE, VIT_HIDDEN_SIZE, 32'd1
                    );

                    PHASE_E_LAYER_V_GEMM: generated_cmd = make_gemm(
                        active_job.job_tag + command_ordinal,
                        common_flags | PHASE_E_FLAG_BIAS_ENABLE,
                        PHASE_E_TENSOR_HIDDEN_B,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_ADDR_HIDDEN_B,
                        active_layer_params.v_weight_base,
                        active_layer_params.v_bias_base,
                        PHASE_E_ADDR_LINEAR_TMP,
                        32'd1, VIT_TOKEN_COUNT, VIT_HIDDEN_SIZE, VIT_HIDDEN_SIZE,
                        VIT_HIDDEN_WORDS, VIT_HIDDEN_SIZE,
                        32'd0, VIT_HIDDEN_SIZE,
                        VIT_HIDDEN_WORDS, VIT_HIDDEN_SIZE
                    );

                    PHASE_E_LAYER_V_SPLIT: generated_cmd = make_layout(
                        active_job.job_tag + command_ordinal,
                        common_flags,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_TENSOR_V_HEAD,
                        PHASE_E_ADDR_LINEAR_TMP,
                        PHASE_E_ADDR_V_HEAD,
                        VIT_HEAD_COUNT, VIT_TOKEN_COUNT, VIT_HEAD_SIZE,
                        VIT_HEAD_SIZE, VIT_HIDDEN_SIZE, 32'd1
                    );

                    PHASE_E_LAYER_K_TRANSPOSE: generated_cmd = make_layout(
                        active_job.job_tag + command_ordinal,
                        common_flags,
                        PHASE_E_TENSOR_K_HEAD,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_ADDR_K_HEAD,
                        PHASE_E_ADDR_LINEAR_TMP,
                        VIT_HEAD_COUNT, VIT_HEAD_SIZE, VIT_TOKEN_COUNT,
                        VIT_ONE_HEAD_WORDS, 32'd1, VIT_HEAD_SIZE
                    );

                    PHASE_E_LAYER_QK_GEMM: generated_cmd = make_gemm(
                        active_job.job_tag + command_ordinal,
                        common_flags,
                        PHASE_E_TENSOR_Q_HEAD,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_SCORE_PROB,
                        PHASE_E_ADDR_Q_HEAD,
                        PHASE_E_ADDR_LINEAR_TMP,
                        32'd0,
                        PHASE_E_ADDR_SCORE_PROB,
                        VIT_HEAD_COUNT, VIT_TOKEN_COUNT, VIT_HEAD_SIZE, VIT_TOKEN_COUNT,
                        VIT_ONE_HEAD_WORDS, VIT_HEAD_SIZE,
                        VIT_ONE_HEAD_WORDS, VIT_TOKEN_COUNT,
                        VIT_SCORE_ROW_WORDS, VIT_TOKEN_COUNT
                    );

                    PHASE_E_LAYER_SCALE_MASK: generated_cmd = make_vector(
                        active_job.job_tag + command_ordinal,
                        common_flags | PHASE_E_FLAG_IN_PLACE,
                        PHASE_E_SUBOP_VECTOR_SCALE_MASK,
                        PHASE_E_TENSOR_SCORE_PROB,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_SCORE_PROB,
                        PHASE_E_ADDR_SCORE_PROB,
                        32'd0,
                        PHASE_E_ADDR_SCORE_PROB,
                        VIT_SCORE_WORDS,
                        VIT_ATTN_SCALE_FP32
                    );

                    PHASE_E_LAYER_SOFTMAX: generated_cmd = make_softmax(
                        active_job.job_tag + command_ordinal,
                        common_flags | PHASE_E_FLAG_IN_PLACE,
                        PHASE_E_TENSOR_SCORE_PROB,
                        PHASE_E_TENSOR_SCORE_PROB,
                        PHASE_E_ADDR_SCORE_PROB,
                        PHASE_E_ADDR_SCORE_PROB,
                        32'd2364,
                        VIT_TOKEN_COUNT
                    );

                    PHASE_E_LAYER_PV_GEMM: generated_cmd = make_gemm(
                        active_job.job_tag + command_ordinal,
                        common_flags,
                        PHASE_E_TENSOR_SCORE_PROB,
                        PHASE_E_TENSOR_V_HEAD,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_Q_HEAD,
                        PHASE_E_ADDR_SCORE_PROB,
                        PHASE_E_ADDR_V_HEAD,
                        32'd0,
                        PHASE_E_ADDR_Q_HEAD,
                        VIT_HEAD_COUNT, VIT_TOKEN_COUNT, VIT_TOKEN_COUNT, VIT_HEAD_SIZE,
                        VIT_SCORE_ROW_WORDS, VIT_TOKEN_COUNT,
                        VIT_ONE_HEAD_WORDS, VIT_HEAD_SIZE,
                        VIT_ONE_HEAD_WORDS, VIT_HEAD_SIZE
                    );

                    PHASE_E_LAYER_HEAD_MERGE: generated_cmd = make_layout(
                        active_job.job_tag + command_ordinal,
                        common_flags,
                        PHASE_E_TENSOR_Q_HEAD,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_ADDR_Q_HEAD,
                        PHASE_E_ADDR_LINEAR_TMP,
                        VIT_TOKEN_COUNT, VIT_HEAD_COUNT, VIT_HEAD_SIZE,
                        VIT_HEAD_SIZE, VIT_ONE_HEAD_WORDS, 32'd1
                    );

                    PHASE_E_LAYER_O_GEMM: generated_cmd = make_gemm(
                        active_job.job_tag + command_ordinal,
                        common_flags | PHASE_E_FLAG_BIAS_ENABLE,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_HIDDEN_B,
                        PHASE_E_ADDR_LINEAR_TMP,
                        active_layer_params.o_weight_base,
                        active_layer_params.o_bias_base,
                        PHASE_E_ADDR_HIDDEN_B,
                        32'd1, VIT_TOKEN_COUNT, VIT_HIDDEN_SIZE, VIT_HIDDEN_SIZE,
                        VIT_HIDDEN_WORDS, VIT_HIDDEN_SIZE,
                        32'd0, VIT_HIDDEN_SIZE,
                        VIT_HIDDEN_WORDS, VIT_HIDDEN_SIZE
                    );

                    PHASE_E_LAYER_ATTN_ADD: generated_cmd = make_vector(
                        active_job.job_tag + command_ordinal,
                        common_flags | PHASE_E_FLAG_IN_PLACE,
                        PHASE_E_SUBOP_VECTOR_ADD,
                        PHASE_E_TENSOR_HIDDEN_B,
                        PHASE_E_TENSOR_HIDDEN_A,
                        PHASE_E_TENSOR_HIDDEN_B,
                        PHASE_E_ADDR_HIDDEN_B,
                        PHASE_E_ADDR_HIDDEN_A,
                        PHASE_E_ADDR_HIDDEN_B,
                        VIT_HIDDEN_WORDS,
                        32'd0
                    );

                    PHASE_E_LAYER_LN2: generated_cmd = make_layernorm(
                        active_job.job_tag + command_ordinal,
                        common_flags,
                        PHASE_E_TENSOR_HIDDEN_B,
                        PHASE_E_TENSOR_HIDDEN_A,
                        PHASE_E_ADDR_HIDDEN_B,
                        active_layer_params.ln2_gamma_base,
                        active_layer_params.ln2_beta_base,
                        PHASE_E_ADDR_HIDDEN_A
                    );

                    PHASE_E_LAYER_FC1_GEMM: generated_cmd = make_gemm(
                        active_job.job_tag + command_ordinal,
                        common_flags | PHASE_E_FLAG_BIAS_ENABLE,
                        PHASE_E_TENSOR_HIDDEN_A,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_FC1,
                        PHASE_E_ADDR_HIDDEN_A,
                        active_layer_params.fc1_weight_base,
                        active_layer_params.fc1_bias_base,
                        PHASE_E_ADDR_FC1,
                        32'd1, VIT_TOKEN_COUNT, VIT_HIDDEN_SIZE, VIT_INTERMEDIATE_SIZE,
                        VIT_HIDDEN_WORDS, VIT_HIDDEN_SIZE,
                        32'd0, VIT_INTERMEDIATE_SIZE,
                        VIT_FC1_WORDS, VIT_INTERMEDIATE_SIZE
                    );

                    PHASE_E_LAYER_GELU: generated_cmd = make_gelu(
                        active_job.job_tag + command_ordinal,
                        common_flags | PHASE_E_FLAG_IN_PLACE,
                        PHASE_E_TENSOR_FC1,
                        PHASE_E_TENSOR_FC1,
                        PHASE_E_ADDR_FC1,
                        PHASE_E_ADDR_FC1,
                        VIT_FC1_WORDS
                    );

                    PHASE_E_LAYER_FC2_GEMM: generated_cmd = make_gemm(
                        active_job.job_tag + command_ordinal,
                        common_flags | PHASE_E_FLAG_BIAS_ENABLE,
                        PHASE_E_TENSOR_FC1,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_ADDR_FC1,
                        active_layer_params.fc2_weight_base,
                        active_layer_params.fc2_bias_base,
                        PHASE_E_ADDR_LINEAR_TMP,
                        32'd1, VIT_TOKEN_COUNT, VIT_INTERMEDIATE_SIZE, VIT_HIDDEN_SIZE,
                        VIT_FC1_WORDS, VIT_INTERMEDIATE_SIZE,
                        32'd0, VIT_HIDDEN_SIZE,
                        VIT_HIDDEN_WORDS, VIT_HIDDEN_SIZE
                    );

                    PHASE_E_LAYER_MLP_ADD: generated_cmd = make_vector(
                        active_job.job_tag + command_ordinal,
                        common_flags,
                        PHASE_E_SUBOP_VECTOR_ADD,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_TENSOR_HIDDEN_B,
                        PHASE_E_TENSOR_HIDDEN_A,
                        PHASE_E_ADDR_LINEAR_TMP,
                        PHASE_E_ADDR_HIDDEN_B,
                        PHASE_E_ADDR_HIDDEN_A,
                        VIT_HIDDEN_WORDS,
                        32'd0
                    );

                    default: begin
                    end
                endcase
            end

            PHASE_E_SECTION_FINAL: begin
                case (current_step)
                    5'd0: generated_cmd = make_layernorm(
                        active_job.job_tag + command_ordinal,
                        common_flags,
                        PHASE_E_TENSOR_HIDDEN_A,
                        PHASE_E_TENSOR_HIDDEN_B,
                        PHASE_E_ADDR_HIDDEN_A,
                        active_global_params.final_ln_gamma_base,
                        active_global_params.final_ln_beta_base,
                        PHASE_E_ADDR_HIDDEN_B
                    );

                    5'd1: generated_cmd = make_layout(
                        active_job.job_tag + command_ordinal,
                        common_flags,
                        PHASE_E_TENSOR_HIDDEN_B,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_ADDR_HIDDEN_B,
                        PHASE_E_ADDR_LINEAR_TMP,
                        32'd1, 32'd1, VIT_HIDDEN_SIZE,
                        32'd0, 32'd0, 32'd1
                    );

                    5'd2: generated_cmd = make_gemm(
                        active_job.job_tag + command_ordinal,
                        common_flags | PHASE_E_FLAG_BIAS_ENABLE,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_LOGITS,
                        PHASE_E_ADDR_LINEAR_TMP,
                        active_global_params.classifier_weight_base,
                        active_global_params.classifier_bias_base,
                        PHASE_E_ADDR_LOGITS,
                        32'd1, 32'd1, VIT_HIDDEN_SIZE, VIT_CLASS_COUNT,
                        VIT_HIDDEN_SIZE, VIT_HIDDEN_SIZE,
                        32'd0, VIT_CLASS_COUNT,
                        VIT_CLASS_COUNT, VIT_CLASS_COUNT
                    );

                    5'd3: generated_cmd = make_argmax(
                        active_job.job_tag + command_ordinal,
                        common_flags,
                        PHASE_E_TENSOR_LOGITS,
                        PHASE_E_ADDR_LOGITS,
                        VIT_CLASS_COUNT
                    );

                    5'd4: generated_cmd = make_softmax(
                        active_job.job_tag + command_ordinal,
                        common_flags,
                        PHASE_E_TENSOR_LOGITS,
                        PHASE_E_TENSOR_CLASS_PROB,
                        PHASE_E_ADDR_LOGITS,
                        PHASE_E_ADDR_CLASS_PROB,
                        32'd1,
                        VIT_CLASS_COUNT
                    );

                    default: begin
                    end
                endcase
            end

            default: begin
            end
        endcase

        // Reserved descriptor bits carry execution context for the functional
        // parameter loader and trace logic.  They do not participate in the
        // arithmetic address calculation.
        generated_cmd.header.reserved = {section, current_layer, 2'b00};
        generated_cmd.route.reserved = {3'd0, current_step};
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state                <= SEQ_IDLE;
            active_job           <= '0;
            active_global_params <= '0;
            active_layer_params  <= '0;
            section              <= PHASE_E_SECTION_NONE;
            current_layer        <= 4'd0;
            current_step         <= 5'd0;
            command_ordinal      <= 8'd0;
            error                <= 1'b0;
            error_code           <= PHASE_E_ERROR_NONE;
            error_section        <= PHASE_E_SECTION_NONE;
            error_layer          <= 4'd0;
            error_step           <= 5'd0;
        end else begin
            case (state)
                SEQ_IDLE: begin
                    if (job_valid) begin
                        active_job           <= job;
                        active_global_params <= global_params;
                        active_layer_params  <= '0;
                        current_layer        <= 4'd0;
                        current_step         <= 5'd0;
                        command_ordinal      <= 8'd0;
                        error                <= 1'b0;
                        error_code           <= PHASE_E_ERROR_NONE;
                        error_section        <= PHASE_E_SECTION_NONE;
                        error_layer          <= 4'd0;
                        error_step           <= 5'd0;

                        case (job.phase)
                            PHASE_E_E01: begin
                                section <= PHASE_E_SECTION_EMBEDDING;
                                state <= SEQ_ISSUE;
                            end

                            PHASE_E_E02: begin
                                section <= PHASE_E_SECTION_ENCODER;
                                current_layer <= 4'd0;
                                state <= SEQ_LOAD_LAYER;
                            end

                            PHASE_E_E03: begin
                                section <= PHASE_E_SECTION_ENCODER;
                                current_layer <= job.first_layer;
                                if ((job.first_layer > job.last_layer) ||
                                    (job.last_layer >= VIT_ENCODER_LAYERS[3:0])) begin
                                    error         <= 1'b1;
                                    error_code    <= PHASE_E_ERROR_BAD_LAYER;
                                    error_section <= PHASE_E_SECTION_ENCODER;
                                    error_layer   <= job.first_layer;
                                    state         <= SEQ_DONE;
                                end else begin
                                    state <= SEQ_LOAD_LAYER;
                                end
                            end

                            PHASE_E_E04: begin
                                section <= PHASE_E_SECTION_FINAL;
                                state <= SEQ_ISSUE;
                            end

                            PHASE_E_E05: begin
                                section <= PHASE_E_SECTION_EMBEDDING;
                                state <= SEQ_ISSUE;
                            end

                            default: begin
                                section       <= PHASE_E_SECTION_NONE;
                                error         <= 1'b1;
                                error_code    <= PHASE_E_ERROR_BAD_PHASE;
                                error_section <= PHASE_E_SECTION_NONE;
                                state         <= SEQ_DONE;
                            end
                        endcase
                    end
                end

                SEQ_LOAD_LAYER: begin
                    if (layer_param_valid) begin
                        active_layer_params <= layer_param_data;
                        current_step <= 5'd0;
                        state <= SEQ_ISSUE;
                    end
                end

                SEQ_ISSUE: begin
                    if (cmd_ready)
                        state <= SEQ_WAIT_COMMAND;
                end

                SEQ_WAIT_COMMAND: begin
                    if (cmd_error) begin
                        error         <= 1'b1;
                        error_code    <= PHASE_E_ERROR_COMMAND;
                        error_section <= section;
                        error_layer   <= (section == PHASE_E_SECTION_ENCODER) ?
                                         current_layer : 4'hf;
                        error_step    <= current_step;
                        state         <= SEQ_DONE;
                    end else if (cmd_done) begin
                        if (active_job.checkpoint_enable)
                            state <= SEQ_CHECKPOINT;
                        else
                            state <= SEQ_ADVANCE;
                    end
                end

                SEQ_CHECKPOINT: begin
                    if (checkpoint_ready)
                        state <= SEQ_ADVANCE;
                end

                SEQ_ADVANCE: begin
                    command_ordinal <= command_ordinal + 8'd1;
                    case (section)
                        PHASE_E_SECTION_EMBEDDING: begin
                            if ((current_step + 5'd1) < PHASE_E_EMBED_COMMANDS) begin
                                current_step <= current_step + 5'd1;
                                state <= SEQ_ISSUE;
                            end else if (active_job.phase == PHASE_E_E05) begin
                                section <= PHASE_E_SECTION_ENCODER;
                                current_layer <= 4'd0;
                                current_step <= 5'd0;
                                state <= SEQ_LOAD_LAYER;
                            end else begin
                                state <= SEQ_DONE;
                            end
                        end

                        PHASE_E_SECTION_ENCODER: begin
                            if ((current_step + 5'd1) < PHASE_E_ENCODER_COMMANDS) begin
                                current_step <= current_step + 5'd1;
                                state <= SEQ_ISSUE;
                            end else if (active_job.phase == PHASE_E_E05) begin
                                if ((current_layer + 4'd1) < VIT_ENCODER_LAYERS[3:0]) begin
                                    current_layer <= current_layer + 4'd1;
                                    current_step <= 5'd0;
                                    state <= SEQ_LOAD_LAYER;
                                end else begin
                                    section <= PHASE_E_SECTION_FINAL;
                                    current_step <= 5'd0;
                                    state <= SEQ_ISSUE;
                                end
                            end else if (active_job.phase == PHASE_E_E03) begin
                                if (current_layer < active_job.last_layer) begin
                                    current_layer <= current_layer + 4'd1;
                                    current_step <= 5'd0;
                                    state <= SEQ_LOAD_LAYER;
                                end else begin
                                    state <= SEQ_DONE;
                                end
                            end else begin
                                state <= SEQ_DONE;
                            end
                        end

                        PHASE_E_SECTION_FINAL: begin
                            if (current_step < 5'd3) begin
                                current_step <= current_step + 5'd1;
                                state <= SEQ_ISSUE;
                            end else if ((current_step == 5'd3) &&
                                         active_job.class_softmax_enable) begin
                                current_step <= 5'd4;
                                state <= SEQ_ISSUE;
                            end else begin
                                state <= SEQ_DONE;
                            end
                        end

                        default: begin
                            error         <= 1'b1;
                            error_code    <= PHASE_E_ERROR_BAD_PHASE;
                            error_section <= section;
                            error_layer   <= current_layer;
                            error_step    <= current_step;
                            state         <= SEQ_DONE;
                        end
                    endcase
                end

                SEQ_DONE: begin
                    state <= SEQ_IDLE;
                end

                default: begin
                    error         <= 1'b1;
                    error_code    <= PHASE_E_ERROR_BAD_PHASE;
                    error_section <= section;
                    error_layer   <= current_layer;
                    error_step    <= current_step;
                    state         <= SEQ_DONE;
                end
            endcase
        end
    end

endmodule
