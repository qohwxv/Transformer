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
module vit_phase_e_sequencer #(
    // E04-only dimensions are parameters so the complete production final
    // phase can be exercised quickly in simulation.  Defaults remain the
    // ViT-base dimensions used by E05 and by synthesis.
    parameter logic [31:0] E04_TOKEN_COUNT =
        vit_phase_e_pkg::VIT_TOKEN_COUNT,
    parameter logic [31:0] E04_HIDDEN_SIZE =
        vit_phase_e_pkg::VIT_HIDDEN_SIZE,
    parameter logic [31:0] E04_CLASS_COUNT =
        vit_phase_e_pkg::VIT_CLASS_COUNT,
    // E05 can use a compact, internally consistent model shape for a complete
    // production-RTL end-to-end simulation.  Every default remains ViT-base,
    // and the overrides are selected only while an E05 job is active.
    parameter logic [31:0] E05_PATCH_COUNT =
        vit_phase_e_pkg::VIT_PATCH_COUNT,
    parameter logic [31:0] E05_TOKEN_COUNT =
        vit_phase_e_pkg::VIT_TOKEN_COUNT,
    parameter logic [31:0] E05_HIDDEN_SIZE =
        vit_phase_e_pkg::VIT_HIDDEN_SIZE,
    parameter logic [31:0] E05_HEAD_COUNT =
        vit_phase_e_pkg::VIT_HEAD_COUNT,
    parameter logic [31:0] E05_HEAD_SIZE =
        vit_phase_e_pkg::VIT_HEAD_SIZE,
    parameter logic [31:0] E05_INTERMEDIATE_SIZE =
        vit_phase_e_pkg::VIT_INTERMEDIATE_SIZE,
    parameter logic [31:0] E05_CLASS_COUNT =
        vit_phase_e_pkg::VIT_CLASS_COUNT,
    // current_layer is four bits, so compact E05 supports 1..15 layers.
    parameter logic [3:0] E05_ENCODER_LAYERS =
        vit_phase_e_pkg::VIT_ENCODER_LAYERS,
    parameter logic [31:0] E05_ATTN_SCALE_FP32 =
        vit_phase_e_pkg::VIT_ATTN_SCALE_FP32
) (
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

    // Parameter products are elaboration-time constants.  Selecting between
    // these constants below therefore requires only muxing and cannot infer a
    // runtime dimension multiplier (or a DSP).
    localparam logic [31:0] E05_PATCH_WORDS =
        E05_PATCH_COUNT * E05_HIDDEN_SIZE;
    localparam logic [31:0] E05_HIDDEN_WORDS =
        E05_TOKEN_COUNT * E05_HIDDEN_SIZE;
    localparam logic [31:0] E05_HEAD_WORDS =
        E05_HEAD_COUNT * E05_TOKEN_COUNT * E05_HEAD_SIZE;
    localparam logic [31:0] E05_ONE_HEAD_WORDS =
        E05_TOKEN_COUNT * E05_HEAD_SIZE;
    localparam logic [31:0] E05_SCORE_ROW_WORDS =
        E05_TOKEN_COUNT * E05_TOKEN_COUNT;
    localparam logic [31:0] E05_SCORE_WORDS =
        E05_HEAD_COUNT * E05_TOKEN_COUNT * E05_TOKEN_COUNT;
    localparam logic [31:0] E05_FC1_WORDS =
        E05_TOKEN_COUNT * E05_INTERMEDIATE_SIZE;
    localparam logic [31:0] E05_ATTN_ROWS =
        E05_HEAD_COUNT * E05_TOKEN_COUNT;

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
    logic [7:0] model_weight_flags;
    logic [31:0] flow_patch_count;
    logic [31:0] flow_token_count;
    logic [31:0] flow_hidden_size;
    logic [31:0] flow_head_count;
    logic [31:0] flow_head_size;
    logic [31:0] flow_intermediate_size;
    logic [31:0] flow_class_count;
    logic [31:0] flow_patch_words;
    logic [31:0] flow_hidden_words;
    logic [31:0] flow_head_words;
    logic [31:0] flow_one_head_words;
    logic [31:0] flow_score_row_words;
    logic [31:0] flow_score_words;
    logic [31:0] flow_fc1_words;
    logic [31:0] flow_attn_rows;
    logic [31:0] flow_attn_scale_fp32;
    logic [31:0] final_token_count;
    logic [31:0] final_hidden_size;
    logic [31:0] final_class_count;
    phase_e_cmd_t generated_cmd;

    // One output tile stores two columns for every padded K16 chunk.
    // Addition and shifts keep this path DSP-free and also support compact
    // simulation dimensions that are not multiples of sixteen.
    function automatic logic [31:0] blocked_b_tile_stride_words(
        input logic [31:0] reduction
    );
        logic [32:0] rounded_reduction;
        logic [31:0] k_chunks;
        begin
            rounded_reduction = {1'b0, reduction} + 33'd15;
            k_chunks = rounded_reduction[32:4];
            blocked_b_tile_stride_words = k_chunks << 5;
        end
    endfunction

    // Package-v3 stores one K16/N2 tile as sixteen u32 containers, each
    // holding {column1_half,column0_half}.  One output tile therefore advances
    // by ceil(K/16)*16 physical words instead of package-v2's *32 words.
    function automatic logic [31:0] packed_b_tile_stride_words(
        input logic [31:0] reduction
    );
        logic [32:0] rounded_reduction;
        logic [31:0] k_chunks;
        begin
            rounded_reduction = {1'b0, reduction} + 33'd15;
            k_chunks = rounded_reduction[32:4];
            packed_b_tile_stride_words = k_chunks << 4;
        end
    endfunction

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
            // All built-in ViT GEMMs use disjoint source/destination tensor
            // regions, so the memory frontend may retain one activation panel
            // while output tiles advance. External descriptors must opt in
            // explicitly instead of assuming that arbitrary aliases are safe.
            value.header.flags =
                flags | PHASE_E_FLAG_GEMM_CACHE_SAFE |
                (active_job.fp16_gemm_compat_enable ?
                    PHASE_E_FLAG_GEMM_FP16 : 8'd0) |
                ((active_job.model_b_fp16_packed2 &&
                  ((flags & PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2) != 0) &&
                  (b_tensor == PHASE_E_TENSOR_WEIGHT)) ?
                    PHASE_E_FLAG_GEMM_B_FP16_PACKED2 : 8'd0);
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
            if ((value.header.flags &
                 PHASE_E_FLAG_GEMM_B_FP16_PACKED2) != 0)
                value.stride3 = packed_b_tile_stride_words(reduction);
            else if (
                ((flags & PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2) != 0) &&
                (b_tensor == PHASE_E_TENSOR_WEIGHT)
            )
                value.stride3 = blocked_b_tile_stride_words(reduction);
            else
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
        input logic [31:0] dst_base,
        input logic [31:0] token_count,
        input logic [31:0] hidden_size
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
            value.dim0 = token_count;
            value.dim1 = hidden_size;
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
        model_weight_flags = common_flags;
        if (active_job.model_b_blocked_k16_n2)
            model_weight_flags =
                model_weight_flags |
                PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2;

        // E01/E02/E03 retain the package's production dimensions.  Only E05
        // selects the compact-capable E05 parameter set.
        flow_patch_count       = VIT_PATCH_COUNT;
        flow_token_count       = VIT_TOKEN_COUNT;
        flow_hidden_size       = VIT_HIDDEN_SIZE;
        flow_head_count        = VIT_HEAD_COUNT;
        flow_head_size         = VIT_HEAD_SIZE;
        flow_intermediate_size = VIT_INTERMEDIATE_SIZE;
        flow_class_count       = VIT_CLASS_COUNT;
        flow_patch_words       = VIT_PATCH_WORDS;
        flow_hidden_words      = VIT_HIDDEN_WORDS;
        flow_head_words        = VIT_HEAD_WORDS;
        flow_one_head_words    = VIT_ONE_HEAD_WORDS;
        flow_score_row_words   = VIT_SCORE_ROW_WORDS;
        flow_score_words       = VIT_SCORE_WORDS;
        flow_fc1_words         = VIT_FC1_WORDS;
        flow_attn_rows         = VIT_HEAD_COUNT * VIT_TOKEN_COUNT;
        flow_attn_scale_fp32   = VIT_ATTN_SCALE_FP32;

        if (active_job.phase == PHASE_E_E05) begin
            flow_patch_count       = E05_PATCH_COUNT;
            flow_token_count       = E05_TOKEN_COUNT;
            flow_hidden_size       = E05_HIDDEN_SIZE;
            flow_head_count        = E05_HEAD_COUNT;
            flow_head_size         = E05_HEAD_SIZE;
            flow_intermediate_size = E05_INTERMEDIATE_SIZE;
            flow_class_count       = E05_CLASS_COUNT;
            flow_patch_words       = E05_PATCH_WORDS;
            flow_hidden_words      = E05_HIDDEN_WORDS;
            flow_head_words        = E05_HEAD_WORDS;
            flow_one_head_words    = E05_ONE_HEAD_WORDS;
            flow_score_row_words   = E05_SCORE_ROW_WORDS;
            flow_score_words       = E05_SCORE_WORDS;
            flow_fc1_words         = E05_FC1_WORDS;
            flow_attn_rows         = E05_ATTN_ROWS;
            flow_attn_scale_fp32   = E05_ATTN_SCALE_FP32;
        end

        final_token_count = flow_token_count;
        final_hidden_size = flow_hidden_size;
        final_class_count = flow_class_count;
        if (active_job.phase == PHASE_E_E04) begin
            final_token_count = E04_TOKEN_COUNT;
            final_hidden_size = E04_HIDDEN_SIZE;
            final_class_count = E04_CLASS_COUNT;
        end

        generated_cmd = '0;
        generated_cmd.header.opcode = PHASE_E_OP_NOP;
        generated_cmd.header.tag = active_job.job_tag + command_ordinal;

        case (section)
            PHASE_E_SECTION_EMBEDDING: begin
                case (current_step)
                    5'd0: generated_cmd = make_gemm(
                        active_job.job_tag + command_ordinal,
                        model_weight_flags | PHASE_E_FLAG_BIAS_ENABLE,
                        PHASE_E_TENSOR_PATCH_A,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        active_job.patch_a_base,
                        active_global_params.patch_weight_base,
                        active_global_params.patch_bias_base,
                        PHASE_E_ADDR_LINEAR_TMP,
                        32'd1, flow_patch_count,
                        flow_hidden_size, flow_hidden_size,
                        flow_patch_words, flow_hidden_size,
                        32'd0, flow_hidden_size,
                        flow_patch_words, flow_hidden_size
                    );

                    5'd1: generated_cmd = make_layout(
                        active_job.job_tag + command_ordinal,
                        common_flags,
                        PHASE_E_TENSOR_CLS,
                        PHASE_E_TENSOR_HIDDEN_A,
                        active_global_params.cls_base,
                        PHASE_E_ADDR_HIDDEN_A,
                        32'd1, 32'd1, flow_hidden_size,
                        32'd0, 32'd0, 32'd1
                    );

                    5'd2: generated_cmd = make_layout(
                        active_job.job_tag + command_ordinal,
                        common_flags,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_TENSOR_HIDDEN_A,
                        PHASE_E_ADDR_LINEAR_TMP,
                        PHASE_E_ADDR_HIDDEN_A + flow_hidden_size,
                        32'd1, flow_patch_count, flow_hidden_size,
                        32'd0, flow_hidden_size, 32'd1
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
                        flow_hidden_words,
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
                        PHASE_E_ADDR_HIDDEN_B,
                        flow_token_count,
                        flow_hidden_size
                    );

                    PHASE_E_LAYER_Q_GEMM: generated_cmd = make_gemm(
                        active_job.job_tag + command_ordinal,
                        model_weight_flags | PHASE_E_FLAG_BIAS_ENABLE,
                        PHASE_E_TENSOR_HIDDEN_B,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_ADDR_HIDDEN_B,
                        active_layer_params.q_weight_base,
                        active_layer_params.q_bias_base,
                        PHASE_E_ADDR_LINEAR_TMP,
                        32'd1, flow_token_count,
                        flow_hidden_size, flow_hidden_size,
                        flow_hidden_words, flow_hidden_size,
                        32'd0, flow_hidden_size,
                        flow_hidden_words, flow_hidden_size
                    );

                    PHASE_E_LAYER_Q_SPLIT: generated_cmd = make_layout(
                        active_job.job_tag + command_ordinal,
                        common_flags,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_TENSOR_Q_HEAD,
                        PHASE_E_ADDR_LINEAR_TMP,
                        PHASE_E_ADDR_Q_HEAD,
                        flow_head_count, flow_token_count, flow_head_size,
                        flow_head_size, flow_hidden_size, 32'd1
                    );

                    PHASE_E_LAYER_K_GEMM: generated_cmd = make_gemm(
                        active_job.job_tag + command_ordinal,
                        model_weight_flags | PHASE_E_FLAG_BIAS_ENABLE,
                        PHASE_E_TENSOR_HIDDEN_B,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_ADDR_HIDDEN_B,
                        active_layer_params.k_weight_base,
                        active_layer_params.k_bias_base,
                        PHASE_E_ADDR_LINEAR_TMP,
                        32'd1, flow_token_count,
                        flow_hidden_size, flow_hidden_size,
                        flow_hidden_words, flow_hidden_size,
                        32'd0, flow_hidden_size,
                        flow_hidden_words, flow_hidden_size
                    );

                    PHASE_E_LAYER_K_SPLIT: generated_cmd = make_layout(
                        active_job.job_tag + command_ordinal,
                        common_flags,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_TENSOR_K_HEAD,
                        PHASE_E_ADDR_LINEAR_TMP,
                        PHASE_E_ADDR_K_HEAD,
                        flow_head_count, flow_token_count, flow_head_size,
                        flow_head_size, flow_hidden_size, 32'd1
                    );

                    PHASE_E_LAYER_V_GEMM: generated_cmd = make_gemm(
                        active_job.job_tag + command_ordinal,
                        model_weight_flags | PHASE_E_FLAG_BIAS_ENABLE,
                        PHASE_E_TENSOR_HIDDEN_B,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_ADDR_HIDDEN_B,
                        active_layer_params.v_weight_base,
                        active_layer_params.v_bias_base,
                        PHASE_E_ADDR_LINEAR_TMP,
                        32'd1, flow_token_count,
                        flow_hidden_size, flow_hidden_size,
                        flow_hidden_words, flow_hidden_size,
                        32'd0, flow_hidden_size,
                        flow_hidden_words, flow_hidden_size
                    );

                    PHASE_E_LAYER_V_SPLIT: generated_cmd = make_layout(
                        active_job.job_tag + command_ordinal,
                        common_flags,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_TENSOR_V_HEAD,
                        PHASE_E_ADDR_LINEAR_TMP,
                        PHASE_E_ADDR_V_HEAD,
                        flow_head_count, flow_token_count, flow_head_size,
                        flow_head_size, flow_hidden_size, 32'd1
                    );

                    PHASE_E_LAYER_K_TRANSPOSE: generated_cmd = make_layout(
                        active_job.job_tag + command_ordinal,
                        common_flags,
                        PHASE_E_TENSOR_K_HEAD,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_ADDR_K_HEAD,
                        PHASE_E_ADDR_LINEAR_TMP,
                        flow_head_count, flow_head_size, flow_token_count,
                        flow_one_head_words, 32'd1, flow_head_size
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
                        flow_head_count, flow_token_count,
                        flow_head_size, flow_token_count,
                        flow_one_head_words, flow_head_size,
                        flow_one_head_words, flow_token_count,
                        flow_score_row_words, flow_token_count
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
                        flow_score_words,
                        flow_attn_scale_fp32
                    );

                    PHASE_E_LAYER_SOFTMAX: generated_cmd = make_softmax(
                        active_job.job_tag + command_ordinal,
                        common_flags | PHASE_E_FLAG_IN_PLACE,
                        PHASE_E_TENSOR_SCORE_PROB,
                        PHASE_E_TENSOR_SCORE_PROB,
                        PHASE_E_ADDR_SCORE_PROB,
                        PHASE_E_ADDR_SCORE_PROB,
                        flow_attn_rows,
                        flow_token_count
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
                        flow_head_count, flow_token_count,
                        flow_token_count, flow_head_size,
                        flow_score_row_words, flow_token_count,
                        flow_one_head_words, flow_head_size,
                        flow_one_head_words, flow_head_size
                    );

                    PHASE_E_LAYER_HEAD_MERGE: generated_cmd = make_layout(
                        active_job.job_tag + command_ordinal,
                        common_flags,
                        PHASE_E_TENSOR_Q_HEAD,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_ADDR_Q_HEAD,
                        PHASE_E_ADDR_LINEAR_TMP,
                        flow_token_count, flow_head_count, flow_head_size,
                        flow_head_size, flow_one_head_words, 32'd1
                    );

                    PHASE_E_LAYER_O_GEMM: generated_cmd = make_gemm(
                        active_job.job_tag + command_ordinal,
                        model_weight_flags | PHASE_E_FLAG_BIAS_ENABLE,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_HIDDEN_B,
                        PHASE_E_ADDR_LINEAR_TMP,
                        active_layer_params.o_weight_base,
                        active_layer_params.o_bias_base,
                        PHASE_E_ADDR_HIDDEN_B,
                        32'd1, flow_token_count,
                        flow_hidden_size, flow_hidden_size,
                        flow_hidden_words, flow_hidden_size,
                        32'd0, flow_hidden_size,
                        flow_hidden_words, flow_hidden_size
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
                        flow_hidden_words,
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
                        PHASE_E_ADDR_HIDDEN_A,
                        flow_token_count,
                        flow_hidden_size
                    );

                    PHASE_E_LAYER_FC1_GEMM: generated_cmd = make_gemm(
                        active_job.job_tag + command_ordinal,
                        model_weight_flags | PHASE_E_FLAG_BIAS_ENABLE,
                        PHASE_E_TENSOR_HIDDEN_A,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_FC1,
                        PHASE_E_ADDR_HIDDEN_A,
                        active_layer_params.fc1_weight_base,
                        active_layer_params.fc1_bias_base,
                        PHASE_E_ADDR_FC1,
                        32'd1, flow_token_count,
                        flow_hidden_size, flow_intermediate_size,
                        flow_hidden_words, flow_hidden_size,
                        32'd0, flow_intermediate_size,
                        flow_fc1_words, flow_intermediate_size
                    );

                    PHASE_E_LAYER_GELU: generated_cmd = make_gelu(
                        active_job.job_tag + command_ordinal,
                        common_flags | PHASE_E_FLAG_IN_PLACE,
                        PHASE_E_TENSOR_FC1,
                        PHASE_E_TENSOR_FC1,
                        PHASE_E_ADDR_FC1,
                        PHASE_E_ADDR_FC1,
                        flow_fc1_words
                    );

                    PHASE_E_LAYER_FC2_GEMM: generated_cmd = make_gemm(
                        active_job.job_tag + command_ordinal,
                        model_weight_flags | PHASE_E_FLAG_BIAS_ENABLE,
                        PHASE_E_TENSOR_FC1,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_ADDR_FC1,
                        active_layer_params.fc2_weight_base,
                        active_layer_params.fc2_bias_base,
                        PHASE_E_ADDR_LINEAR_TMP,
                        32'd1, flow_token_count,
                        flow_intermediate_size, flow_hidden_size,
                        flow_fc1_words, flow_intermediate_size,
                        32'd0, flow_hidden_size,
                        flow_hidden_words, flow_hidden_size
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
                        flow_hidden_words,
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
                        PHASE_E_ADDR_HIDDEN_B,
                        final_token_count,
                        final_hidden_size
                    );

                    5'd1: generated_cmd = make_layout(
                        active_job.job_tag + command_ordinal,
                        common_flags,
                        PHASE_E_TENSOR_HIDDEN_B,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_ADDR_HIDDEN_B,
                        PHASE_E_ADDR_LINEAR_TMP,
                        32'd1, 32'd1, final_hidden_size,
                        32'd0, 32'd0, 32'd1
                    );

                    5'd2: generated_cmd = make_gemm(
                        active_job.job_tag + command_ordinal,
                        model_weight_flags | PHASE_E_FLAG_BIAS_ENABLE,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_LOGITS,
                        PHASE_E_ADDR_LINEAR_TMP,
                        active_global_params.classifier_weight_base,
                        active_global_params.classifier_bias_base,
                        PHASE_E_ADDR_LOGITS,
                        32'd1, 32'd1, final_hidden_size, final_class_count,
                        final_hidden_size, final_hidden_size,
                        32'd0, final_class_count,
                        final_class_count, final_class_count
                    );

                    5'd3: generated_cmd = make_argmax(
                        active_job.job_tag + command_ordinal,
                        common_flags,
                        PHASE_E_TENSOR_LOGITS,
                        PHASE_E_ADDR_LOGITS,
                        final_class_count
                    );

                    5'd4: generated_cmd = make_softmax(
                        active_job.job_tag + command_ordinal,
                        common_flags,
                        PHASE_E_TENSOR_LOGITS,
                        PHASE_E_TENSOR_CLASS_PROB,
                        PHASE_E_ADDR_LOGITS,
                        PHASE_E_ADDR_CLASS_PROB,
                        32'd1,
                        final_class_count
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
                                if (E05_ENCODER_LAYERS == 0) begin
                                    section       <= PHASE_E_SECTION_ENCODER;
                                    error         <= 1'b1;
                                    error_code    <= PHASE_E_ERROR_BAD_LAYER;
                                    error_section <= PHASE_E_SECTION_ENCODER;
                                    error_layer   <= 4'd0;
                                    state         <= SEQ_DONE;
                                end else begin
                                    section <= PHASE_E_SECTION_EMBEDDING;
                                    state <= SEQ_ISSUE;
                                end
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
                                if ((current_layer + 4'd1) <
                                    E05_ENCODER_LAYERS) begin
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
