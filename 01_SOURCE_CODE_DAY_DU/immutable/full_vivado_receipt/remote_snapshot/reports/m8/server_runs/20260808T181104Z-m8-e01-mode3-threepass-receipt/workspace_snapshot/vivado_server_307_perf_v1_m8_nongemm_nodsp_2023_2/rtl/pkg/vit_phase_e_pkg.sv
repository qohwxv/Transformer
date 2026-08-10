`timescale 1ns/1ps

// Shared command and configuration definitions for the functional Phase-E
// integration controller.  Every address in this package is an FP32 *word*
// address, not a byte address.
package vit_phase_e_pkg;

    localparam logic [31:0] VIT_PATCH_COUNT       = 32'd196;
    localparam logic [31:0] VIT_TOKEN_COUNT       = 32'd197;
    localparam logic [31:0] VIT_HIDDEN_SIZE       = 32'd768;
    localparam logic [31:0] VIT_HEAD_COUNT        = 32'd12;
    localparam logic [31:0] VIT_HEAD_SIZE         = 32'd64;
    localparam logic [31:0] VIT_INTERMEDIATE_SIZE = 32'd3072;
    localparam logic [31:0] VIT_CLASS_COUNT       = 32'd1000;
    localparam logic [31:0] VIT_ENCODER_LAYERS    = 32'd12;

    localparam logic [31:0] VIT_PATCH_WORDS = 32'd150528; // 196*768
    localparam logic [31:0] VIT_HIDDEN_WORDS = 32'd151296; // 197*768
    localparam logic [31:0] VIT_HEAD_WORDS = 32'd151296; // 12*197*64
    localparam logic [31:0] VIT_ONE_HEAD_WORDS = 32'd12608; // 197*64
    localparam logic [31:0] VIT_SCORE_ROW_WORDS = 32'd38809; // 197*197
    localparam logic [31:0] VIT_SCORE_WORDS = 32'd465708; // 12*197*197
    localparam logic [31:0] VIT_FC1_WORDS = 32'd605184; // 197*3072

    localparam logic [31:0] VIT_ATTN_SCALE_FP32 = 32'h3e00_0000; // 0.125
    localparam logic [31:0] VIT_LN_EPSILON_FP32 = 32'h2b8c_bccc; // float32(1e-12)

    // Scratch regions are deliberately 4-Kword aligned.  CLASS_PROB is a
    // separate 4-Kword allocation so optional class Softmax does not destroy
    // the classifier logits used by argmax/debugging.
    localparam logic [31:0] PHASE_E_ADDR_HIDDEN_A   = 32'h0000_0000;
    localparam logic [31:0] PHASE_E_ADDR_HIDDEN_B   = 32'h0002_5000;
    localparam logic [31:0] PHASE_E_ADDR_LINEAR_TMP = 32'h0004_a000;
    localparam logic [31:0] PHASE_E_ADDR_Q_HEAD     = 32'h0006_f000;
    localparam logic [31:0] PHASE_E_ADDR_K_HEAD     = 32'h0009_4000;
    localparam logic [31:0] PHASE_E_ADDR_V_HEAD     = 32'h000b_9000;
    localparam logic [31:0] PHASE_E_ADDR_SCORE_PROB = 32'h000d_e000;
    localparam logic [31:0] PHASE_E_ADDR_FC1        = 32'h0015_0000;
    localparam logic [31:0] PHASE_E_ADDR_LOGITS     = 32'h001e_4000;
    localparam logic [31:0] PHASE_E_ADDR_CLASS_PROB = 32'h001e_5000;
    localparam logic [31:0] PHASE_E_SCRATCH_WORDS   = 32'h001e_6000;

    // One command's largest parameter is the FC1/FC2 B matrix
    // (3,072*768 words).  The file-backed integration top reuses MAIN for a
    // weight/gamma/constant operand and AUX for its bias/beta operand.
    localparam logic [31:0] PHASE_E_PARAM_MAIN_BASE = 32'h0000_0000;
    localparam logic [31:0] PHASE_E_PARAM_AUX_BASE  = 32'h0024_0000;
    localparam logic [31:0] PHASE_E_PARAM_WORDS     = 32'h0024_1000;

    typedef enum logic [2:0] {
        PHASE_E_NONE = 3'd0,
        PHASE_E_E01  = 3'd1,
        PHASE_E_E02  = 3'd2,
        PHASE_E_E03  = 3'd3,
        PHASE_E_E04  = 3'd4,
        PHASE_E_E05  = 3'd5
    } phase_e_phase_t;

    typedef enum logic [1:0] {
        PHASE_E_SECTION_EMBEDDING = 2'd0,
        PHASE_E_SECTION_ENCODER   = 2'd1,
        PHASE_E_SECTION_FINAL     = 2'd2,
        PHASE_E_SECTION_NONE      = 2'd3
    } phase_e_section_t;

    typedef enum logic [3:0] {
        PHASE_E_OP_NOP       = 4'd0,
        PHASE_E_OP_GEMM      = 4'd1,
        PHASE_E_OP_VECTOR    = 4'd2,
        PHASE_E_OP_LAYOUT    = 4'd3,
        PHASE_E_OP_LAYERNORM = 4'd4,
        PHASE_E_OP_SOFTMAX   = 4'd5,
        PHASE_E_OP_GELU      = 4'd6,
        PHASE_E_OP_ARGMAX    = 4'd7,
        PHASE_E_OP_END       = 4'd8
    } phase_e_opcode_t;

    typedef enum logic [3:0] {
        PHASE_E_SUBOP_NONE              = 4'd0,
        PHASE_E_SUBOP_VECTOR_ADD        = 4'd1,
        PHASE_E_SUBOP_VECTOR_SCALE_MASK = 4'd2,
        PHASE_E_SUBOP_LAYOUT_COPY       = 4'd3
    } phase_e_subop_t;

    typedef enum logic [1:0] {
        PHASE_E_MEM_NONE    = 2'd0,
        PHASE_E_MEM_SCRATCH = 2'd1,
        PHASE_E_MEM_PARAM   = 2'd2,
        PHASE_E_MEM_INPUT   = 2'd3
    } phase_e_mem_space_t;

    // Four bits deliberately cover all fixed activation regions plus generic
    // parameter/bias operands.  The ID is metadata; address and memory-space
    // fields remain authoritative for execution.
    typedef enum logic [3:0] {
        PHASE_E_TENSOR_NONE        = 4'd0,
        PHASE_E_TENSOR_PATCH_A     = 4'd1,
        PHASE_E_TENSOR_CLS         = 4'd2,
        PHASE_E_TENSOR_POSITION    = 4'd3,
        PHASE_E_TENSOR_HIDDEN_A    = 4'd4,
        PHASE_E_TENSOR_HIDDEN_B    = 4'd5,
        PHASE_E_TENSOR_LINEAR_TMP  = 4'd6,
        PHASE_E_TENSOR_Q_HEAD      = 4'd7,
        PHASE_E_TENSOR_K_HEAD      = 4'd8,
        PHASE_E_TENSOR_V_HEAD      = 4'd9,
        PHASE_E_TENSOR_SCORE_PROB  = 4'd10,
        PHASE_E_TENSOR_FC1         = 4'd11,
        PHASE_E_TENSOR_LOGITS      = 4'd12,
        PHASE_E_TENSOR_CLASS_PROB  = 4'd13,
        PHASE_E_TENSOR_WEIGHT      = 4'd14,
        PHASE_E_TENSOR_BIAS        = 4'd15
    } phase_e_tensor_id_t;

    localparam logic [7:0] PHASE_E_FLAG_BIAS_ENABLE = 8'h01;
    localparam logic [7:0] PHASE_E_FLAG_MASK_ENABLE = 8'h02;
    localparam logic [7:0] PHASE_E_FLAG_IN_PLACE    = 8'h04;
    localparam logic [7:0] PHASE_E_FLAG_CHECKPOINT  = 8'h08;
    // GEMM may reuse activation/bias operands only when software guarantees
    // they remain immutable and destination writes cannot alias them.
    localparam logic [7:0] PHASE_E_FLAG_GEMM_CACHE_SAFE = 8'h10;
    // GEMM src1 is stored as [N_TILE][K_CHUNK][COL][LANE], with the
    // production K16/N2 geometry.  This flag is command-local so attention
    // QK/PV matrices in scratch remain row-major even when package v2 is on.
    localparam logic [7:0] PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2 = 8'h20;
    // M7 numerical mode.  This flag is command-local and is emitted only by
    // make_gemm; LayerNorm, Softmax, GELU, residual/statistics and every other
    // non-GEMM engine remain FP32.
    localparam logic [7:0] PHASE_E_FLAG_GEMM_FP16 = 8'h40;
    // GEMM src1 is package-v3 packed FP16 storage.  Each physical u32 word
    // holds {column1_half,column0_half} for one K lane.  The flag is emitted
    // only for persistent PARAM/WEIGHT operands; attention scratch B stays
    // row-major FP32 even when the job selects FP16 compute.
    localparam logic [7:0] PHASE_E_FLAG_GEMM_B_FP16_PACKED2 = 8'h80;

    // Header is command word 0.  The tag is an 8-bit command ordinal/tag and
    // naturally wraps modulo 256 if a non-zero job tag is used.
    typedef struct packed {
        logic [7:0]         reserved;
        logic [7:0]         tag;
        logic [7:0]         flags;
        phase_e_subop_t     subop;
        phase_e_opcode_t    opcode;
    } phase_e_cmd_header_t;

    // Route is command word 1.  IDs support tracing/checkpoints while spaces
    // let the future memory adapter distinguish scratch, model parameters,
    // and prepared host input.
    typedef struct packed {
        logic [7:0]              reserved;
        phase_e_mem_space_t      dst_space;
        phase_e_mem_space_t      src2_space;
        phase_e_mem_space_t      src1_space;
        phase_e_mem_space_t      src0_space;
        phase_e_tensor_id_t      dst_tensor;
        phase_e_tensor_id_t      src2_tensor;
        phase_e_tensor_id_t      src1_tensor;
        phase_e_tensor_id_t      src0_tensor;
    } phase_e_cmd_route_t;

    // Exact 16-word / 512-bit execution descriptor.  The declaration order
    // intentionally places header at bits [31:0], so phase_e_cmd_word(cmd, 0)
    // returns the header and word 15 returns immediate.
    //
    // GEMM:
    //   dim0..3 = batch,M,K,N
    //   stride0/1 = A batch/row, stride2/3 = B batch/row
    //   stride4 = C batch, immediate = C row stride
    // VECTOR: dim0=length, immediate=scalar
    // LAYOUT: dim0..2=dims, stride0..2=source strides
    // LAYERNORM: dim0=token count, dim1=hidden size, immediate=epsilon
    // SOFTMAX: dim0=row count, dim1=row length
    // GELU/ARGMAX: dim0=flat length
    typedef struct packed {
        logic [31:0]         immediate; // W15
        logic [31:0]         stride4;   // W14
        logic [31:0]         stride3;   // W13
        logic [31:0]         stride2;   // W12
        logic [31:0]         stride1;   // W11
        logic [31:0]         stride0;   // W10
        logic [31:0]         dim3;      // W9
        logic [31:0]         dim2;      // W8
        logic [31:0]         dim1;      // W7
        logic [31:0]         dim0;      // W6
        logic [31:0]         dst_base;  // W5
        logic [31:0]         src2_base; // W4
        logic [31:0]         src1_base; // W3
        logic [31:0]         src0_base; // W2
        phase_e_cmd_route_t  route;     // W1
        phase_e_cmd_header_t header;    // W0
    } phase_e_cmd_t;

    // Registered/profile-event seam between the production engine and the
    // AXI wrapper.  Every one-bit field is a pulse unless its name ends in
    // "_active".  Logical word events are counted before the frontend caches,
    // while the A/bias hit/miss events describe how those logical reads were
    // serviced.  The GEMM deltas are valid only with gemm_tile_step asserted.
    typedef struct packed {
        logic                 command_accept;
        logic                 command_complete;
        logic                 command_error;
        phase_e_opcode_t      command_opcode;
        logic [7:0]           command_tag;
        phase_e_section_t     command_section;
        logic [3:0]           command_layer;
        logic [4:0]           command_step;
        logic                 logical_read_word;
        logic                 logical_write_word;
        logic                 load_active;
        logic                 compute_active;
        logic                 store_active;
        logic                 a_cache_lookup;
        logic                 a_cache_hit;
        logic                 a_cache_miss;
        logic                 bias_cache_lookup;
        logic                 bias_cache_hit;
        logic                 bias_cache_miss;
        logic                 b_bypass;
        logic                 gemm_tile_step;
        logic [15:0]          gemm_valid_mac_delta;
        logic [15:0]          gemm_tail_mac_delta;
        logic                 frontend_error;
    } phase_e_profile_core_events_t;

    // M7-local observability is deliberately a separate seam and register bank.
    // It must never change the width/meaning of the frozen v1.2 core event ABI.
    typedef struct packed {
        // Exact logical A-cache words serviced by the M7 vector read port in
        // this cycle.  The legacy v1.2 logical/cache counters consume this
        // internal delta without changing any host-visible address/meaning.
        logic [3:0]           m7_a_vector_hit_word_delta;
        logic [4:0]           m7_fp16_term_accept_delta;
        logic [4:0]           m7_fp16_disabled_term_delta;
        logic                 m7_fp16_input_wait;
        logic                 m7_fp16_term_stall;
        logic                 m7_fp16_result_backpressure;
        logic                 m7_fp16_compute_active;
        logic                 m7_fp16_dot_start;
        logic                 m7_fp16_result_vector;
        logic [4:0]           m7_fp16_invalid_delta;
        logic [4:0]           m7_fp16_overflow_delta;
        logic [4:0]           m7_fp16_length_error_delta;
        logic [4:0]           m7_fp16_subnormal_flushed_delta;
        logic                 m7_panel_load_active;
        logic                 m7_panel_compute_active;
        logic                 m7_panel_store_active;
        logic                 m7_panel_commit;
        logic                 m7_panel_claim;
        logic [1:0]           m7_panel_claim_mask;
        logic                 m7_panel_release;
        logic                 m7_panel_empty_stall;
        logic                 m7_panel_full_stall;
        logic [1:0]           m7_panel_occupancy;
        logic                 m7_result_fifo_enqueue;
        logic                 m7_result_fifo_dequeue;
        logic [1:0]           m7_result_fifo_occupancy;
        logic [19:0]          m7_error_events;
    } phase_e_m7_profile_events_t;

    localparam integer PHASE_E_CMD_WORDS = 16;
    localparam integer PHASE_E_CMD_BITS = 512;
    localparam integer PHASE_E_CMD_W_HEADER = 0;
    localparam integer PHASE_E_CMD_W_ROUTE = 1;
    localparam integer PHASE_E_CMD_W_SRC0_BASE = 2;
    localparam integer PHASE_E_CMD_W_SRC1_BASE = 3;
    localparam integer PHASE_E_CMD_W_SRC2_BASE = 4;
    localparam integer PHASE_E_CMD_W_DST_BASE = 5;
    localparam integer PHASE_E_CMD_W_DIM0 = 6;
    localparam integer PHASE_E_CMD_W_DIM1 = 7;
    localparam integer PHASE_E_CMD_W_DIM2 = 8;
    localparam integer PHASE_E_CMD_W_DIM3 = 9;
    localparam integer PHASE_E_CMD_W_STRIDE0 = 10;
    localparam integer PHASE_E_CMD_W_STRIDE1 = 11;
    localparam integer PHASE_E_CMD_W_STRIDE2 = 12;
    localparam integer PHASE_E_CMD_W_STRIDE3 = 13;
    localparam integer PHASE_E_CMD_W_STRIDE4 = 14;
    localparam integer PHASE_E_CMD_W_IMMEDIATE = 15;

    // Schema-v2 profile array geometry.  The 44 global indices are an ABI:
    // append new counters after PHASE_E_PROFILE_GLOBAL_COUNT; never renumber
    // an existing entry.
    localparam integer PHASE_E_PROFILE_GLOBAL_LOGICAL_READ = 0;
    localparam integer PHASE_E_PROFILE_GLOBAL_LOGICAL_WRITE = 1;
    localparam integer PHASE_E_PROFILE_GLOBAL_R_BEATS = 2;
    localparam integer PHASE_E_PROFILE_GLOBAL_W_BEATS = 3;
    localparam integer PHASE_E_PROFILE_GLOBAL_COMMAND_ACTIVE = 4;
    localparam integer PHASE_E_PROFILE_GLOBAL_LOGICAL_REQ_BP = 5;
    localparam integer PHASE_E_PROFILE_GLOBAL_AR_BP = 6;
    localparam integer PHASE_E_PROFILE_GLOBAL_AW_BP = 7;
    localparam integer PHASE_E_PROFILE_GLOBAL_W_BP = 8;
    localparam integer PHASE_E_PROFILE_GLOBAL_R_WAIT = 9;
    localparam integer PHASE_E_PROFILE_GLOBAL_B_WAIT = 10;
    localparam integer PHASE_E_PROFILE_GLOBAL_R_BP = 11;
    localparam integer PHASE_E_PROFILE_GLOBAL_B_BP = 12;
    localparam integer PHASE_E_PROFILE_GLOBAL_LOAD = 13;
    localparam integer PHASE_E_PROFILE_GLOBAL_COMPUTE = 14;
    localparam integer PHASE_E_PROFILE_GLOBAL_STORE = 15;
    localparam integer PHASE_E_PROFILE_GLOBAL_UNION = 16;
    localparam integer PHASE_E_PROFILE_GLOBAL_OVERLAP = 17;
    localparam integer PHASE_E_PROFILE_GLOBAL_CACHE_LOOKUP = 18;
    localparam integer PHASE_E_PROFILE_GLOBAL_CACHE_HIT = 19;
    localparam integer PHASE_E_PROFILE_GLOBAL_CACHE_MISS = 20;
    localparam integer PHASE_E_PROFILE_GLOBAL_GEMM_TILE_STEPS = 21;
    localparam integer PHASE_E_PROFILE_GLOBAL_VALID_MAC = 22;
    localparam integer PHASE_E_PROFILE_GLOBAL_TAIL_MAC = 23;
    localparam integer PHASE_E_PROFILE_GLOBAL_COMMAND_ERRORS = 24;
    localparam integer PHASE_E_PROFILE_GLOBAL_AXI_RESPONSE_ERRORS = 25;
    localparam integer PHASE_E_PROFILE_GLOBAL_TRACE_DROPPED = 26;
    localparam integer PHASE_E_PROFILE_GLOBAL_LOGICAL_RSP_BP = 27;
    localparam integer PHASE_E_PROFILE_GLOBAL_B_RESPONSES = 28;
    localparam integer PHASE_E_PROFILE_GLOBAL_LOGICAL_RSP_ERRORS = 29;
    localparam integer PHASE_E_PROFILE_GLOBAL_JOB_ERRORS = 30;
    localparam integer PHASE_E_PROFILE_GLOBAL_A_LOOKUP = 31;
    localparam integer PHASE_E_PROFILE_GLOBAL_A_HIT = 32;
    localparam integer PHASE_E_PROFILE_GLOBAL_A_MISS = 33;
    localparam integer PHASE_E_PROFILE_GLOBAL_BIAS_LOOKUP = 34;
    localparam integer PHASE_E_PROFILE_GLOBAL_BIAS_HIT = 35;
    localparam integer PHASE_E_PROFILE_GLOBAL_BIAS_MISS = 36;
    localparam integer PHASE_E_PROFILE_GLOBAL_B_BYPASS = 37;
    localparam integer PHASE_E_PROFILE_GLOBAL_LOAD_COMPUTE_OVERLAP = 38;
    localparam integer PHASE_E_PROFILE_GLOBAL_COMPUTE_STORE_OVERLAP = 39;
    localparam integer PHASE_E_PROFILE_GLOBAL_LOAD_STORE_OVERLAP = 40;
    localparam integer PHASE_E_PROFILE_GLOBAL_THREE_WAY = 41;
    localparam integer PHASE_E_PROFILE_GLOBAL_LOGICAL_READ_RSP_WAIT = 42;
    localparam integer PHASE_E_PROFILE_GLOBAL_LOGICAL_WRITE_RSP_WAIT = 43;
    localparam integer PHASE_E_PROFILE_GLOBAL_COUNT = 44;
    localparam integer PHASE_E_PROFILE_OPCODE_SLOTS = 16;
    localparam integer PHASE_E_PROFILE_TRACE_DEPTH = 256;
    localparam integer PHASE_E_PROFILE_HIST_COUNT = 18;
    localparam integer PHASE_E_M7_COUNTER_COUNT = 23;

    localparam logic [5:0] PHASE_E_EMBED_COMMANDS = 6'd4;
    localparam logic [5:0] PHASE_E_ENCODER_COMMANDS = 6'd20;
    localparam logic [5:0] PHASE_E_FINAL_COMMANDS = 6'd4;
    localparam logic [5:0] PHASE_E_FINAL_SOFTMAX_COMMANDS = 6'd5;

    typedef enum logic [4:0] {
        PHASE_E_LAYER_LN1         = 5'd0,
        PHASE_E_LAYER_Q_GEMM      = 5'd1,
        PHASE_E_LAYER_Q_SPLIT     = 5'd2,
        PHASE_E_LAYER_K_GEMM      = 5'd3,
        PHASE_E_LAYER_K_SPLIT     = 5'd4,
        PHASE_E_LAYER_V_GEMM      = 5'd5,
        PHASE_E_LAYER_V_SPLIT     = 5'd6,
        PHASE_E_LAYER_K_TRANSPOSE = 5'd7,
        PHASE_E_LAYER_QK_GEMM     = 5'd8,
        PHASE_E_LAYER_SCALE_MASK  = 5'd9,
        PHASE_E_LAYER_SOFTMAX     = 5'd10,
        PHASE_E_LAYER_PV_GEMM     = 5'd11,
        PHASE_E_LAYER_HEAD_MERGE  = 5'd12,
        PHASE_E_LAYER_O_GEMM      = 5'd13,
        PHASE_E_LAYER_ATTN_ADD    = 5'd14,
        PHASE_E_LAYER_LN2         = 5'd15,
        PHASE_E_LAYER_FC1_GEMM    = 5'd16,
        PHASE_E_LAYER_GELU        = 5'd17,
        PHASE_E_LAYER_FC2_GEMM    = 5'd18,
        PHASE_E_LAYER_MLP_ADD     = 5'd19
    } phase_e_layer_step_t;

    // All fields are sampled with job_valid/job_ready.  E02 forces layer 0;
    // E03 uses first_layer..last_layer; E05 forces layers 0..11.
    typedef struct packed {
        phase_e_phase_t phase;
        logic [3:0]     first_layer;
        logic [3:0]     last_layer;
        logic           class_softmax_enable;
        logic           checkpoint_enable;
        logic [7:0]     job_tag;
        // Snapshotted from AXI-Lite EXECUTION_MODE at accepted START.
        logic           model_b_blocked_k16_n2;
        // EXECUTION_MODE[1]: package-v3 persistent B uses two packed FP16
        // values per physical u32 word.  This never applies to scratch B.
        logic           model_b_fp16_packed2;
        // FP16 GEMM compute selector.  It is asserted by packed-v3 mode 3 or
        // by bounded compatibility mode 5 (v2 FP32 storage, FP16 compute).
        logic           fp16_gemm_compat_enable;
        logic [31:0]    patch_a_base;
    } phase_e_job_t;

    typedef struct packed {
        logic [31:0] patch_weight_base;
        logic [31:0] patch_bias_base;
        logic [31:0] cls_base;
        logic [31:0] position_base;
        logic [31:0] final_ln_gamma_base;
        logic [31:0] final_ln_beta_base;
        logic [31:0] classifier_weight_base;
        logic [31:0] classifier_bias_base;
    } phase_e_global_params_t;

    // The parameter provider returns one entry when layer_param_request is
    // asserted.  Linear B matrices must already be stored as hardware [K,N],
    // not the PyTorch [N,K] layout.
    typedef struct packed {
        logic [31:0] ln1_gamma_base;
        logic [31:0] ln1_beta_base;
        logic [31:0] q_weight_base;
        logic [31:0] q_bias_base;
        logic [31:0] k_weight_base;
        logic [31:0] k_bias_base;
        logic [31:0] v_weight_base;
        logic [31:0] v_bias_base;
        logic [31:0] o_weight_base;
        logic [31:0] o_bias_base;
        logic [31:0] ln2_gamma_base;
        logic [31:0] ln2_beta_base;
        logic [31:0] fc1_weight_base;
        logic [31:0] fc1_bias_base;
        logic [31:0] fc2_weight_base;
        logic [31:0] fc2_bias_base;
    } phase_e_layer_params_t;

    typedef enum logic [2:0] {
        PHASE_E_ERROR_NONE        = 3'd0,
        PHASE_E_ERROR_BAD_PHASE   = 3'd1,
        PHASE_E_ERROR_BAD_LAYER   = 3'd2,
        PHASE_E_ERROR_COMMAND     = 3'd3
    } phase_e_error_t;

    function automatic logic [31:0] phase_e_cmd_word(
        input phase_e_cmd_t value,
        input logic [3:0] word_index
    );
        begin
            case (word_index)
                4'd0:  phase_e_cmd_word = value.header;
                4'd1:  phase_e_cmd_word = value.route;
                4'd2:  phase_e_cmd_word = value.src0_base;
                4'd3:  phase_e_cmd_word = value.src1_base;
                4'd4:  phase_e_cmd_word = value.src2_base;
                4'd5:  phase_e_cmd_word = value.dst_base;
                4'd6:  phase_e_cmd_word = value.dim0;
                4'd7:  phase_e_cmd_word = value.dim1;
                4'd8:  phase_e_cmd_word = value.dim2;
                4'd9:  phase_e_cmd_word = value.dim3;
                4'd10: phase_e_cmd_word = value.stride0;
                4'd11: phase_e_cmd_word = value.stride1;
                4'd12: phase_e_cmd_word = value.stride2;
                4'd13: phase_e_cmd_word = value.stride3;
                4'd14: phase_e_cmd_word = value.stride4;
                4'd15: phase_e_cmd_word = value.immediate;
                default: phase_e_cmd_word = 32'd0;
            endcase
        end
    endfunction

    function automatic phase_e_mem_space_t phase_e_tensor_default_space(
        input phase_e_tensor_id_t tensor_id
    );
        begin
            case (tensor_id)
                PHASE_E_TENSOR_PATCH_A:
                    phase_e_tensor_default_space = PHASE_E_MEM_INPUT;
                PHASE_E_TENSOR_CLS,
                PHASE_E_TENSOR_POSITION,
                PHASE_E_TENSOR_WEIGHT,
                PHASE_E_TENSOR_BIAS:
                    phase_e_tensor_default_space = PHASE_E_MEM_PARAM;
                PHASE_E_TENSOR_HIDDEN_A,
                PHASE_E_TENSOR_HIDDEN_B,
                PHASE_E_TENSOR_LINEAR_TMP,
                PHASE_E_TENSOR_Q_HEAD,
                PHASE_E_TENSOR_K_HEAD,
                PHASE_E_TENSOR_V_HEAD,
                PHASE_E_TENSOR_SCORE_PROB,
                PHASE_E_TENSOR_FC1,
                PHASE_E_TENSOR_LOGITS,
                PHASE_E_TENSOR_CLASS_PROB:
                    phase_e_tensor_default_space = PHASE_E_MEM_SCRATCH;
                default:
                    phase_e_tensor_default_space = PHASE_E_MEM_NONE;
            endcase
        end
    endfunction

    function automatic logic [31:0] phase_e_tensor_scratch_base(
        input phase_e_tensor_id_t tensor_id
    );
        begin
            case (tensor_id)
                PHASE_E_TENSOR_HIDDEN_A:
                    phase_e_tensor_scratch_base = PHASE_E_ADDR_HIDDEN_A;
                PHASE_E_TENSOR_HIDDEN_B:
                    phase_e_tensor_scratch_base = PHASE_E_ADDR_HIDDEN_B;
                PHASE_E_TENSOR_LINEAR_TMP:
                    phase_e_tensor_scratch_base = PHASE_E_ADDR_LINEAR_TMP;
                PHASE_E_TENSOR_Q_HEAD:
                    phase_e_tensor_scratch_base = PHASE_E_ADDR_Q_HEAD;
                PHASE_E_TENSOR_K_HEAD:
                    phase_e_tensor_scratch_base = PHASE_E_ADDR_K_HEAD;
                PHASE_E_TENSOR_V_HEAD:
                    phase_e_tensor_scratch_base = PHASE_E_ADDR_V_HEAD;
                PHASE_E_TENSOR_SCORE_PROB:
                    phase_e_tensor_scratch_base = PHASE_E_ADDR_SCORE_PROB;
                PHASE_E_TENSOR_FC1:
                    phase_e_tensor_scratch_base = PHASE_E_ADDR_FC1;
                PHASE_E_TENSOR_LOGITS:
                    phase_e_tensor_scratch_base = PHASE_E_ADDR_LOGITS;
                PHASE_E_TENSOR_CLASS_PROB:
                    phase_e_tensor_scratch_base = PHASE_E_ADDR_CLASS_PROB;
                default:
                    phase_e_tensor_scratch_base = 32'd0;
            endcase
        end
    endfunction

    function automatic logic [31:0] phase_e_tensor_word_count(
        input phase_e_tensor_id_t tensor_id
    );
        begin
            case (tensor_id)
                PHASE_E_TENSOR_PATCH_A:
                    phase_e_tensor_word_count = VIT_PATCH_WORDS;
                PHASE_E_TENSOR_CLS:
                    phase_e_tensor_word_count = VIT_HIDDEN_SIZE;
                PHASE_E_TENSOR_POSITION,
                PHASE_E_TENSOR_HIDDEN_A,
                PHASE_E_TENSOR_HIDDEN_B,
                PHASE_E_TENSOR_LINEAR_TMP,
                PHASE_E_TENSOR_Q_HEAD,
                PHASE_E_TENSOR_K_HEAD,
                PHASE_E_TENSOR_V_HEAD:
                    phase_e_tensor_word_count = VIT_HIDDEN_WORDS;
                PHASE_E_TENSOR_SCORE_PROB:
                    phase_e_tensor_word_count = VIT_SCORE_WORDS;
                PHASE_E_TENSOR_FC1:
                    phase_e_tensor_word_count = VIT_FC1_WORDS;
                PHASE_E_TENSOR_LOGITS,
                PHASE_E_TENSOR_CLASS_PROB:
                    phase_e_tensor_word_count = VIT_CLASS_COUNT;
                default:
                    phase_e_tensor_word_count = 32'd0;
            endcase
        end
    endfunction

endpackage
