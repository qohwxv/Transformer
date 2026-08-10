`timescale 1ns/1ps

// Lightweight descriptor regression for the default ViT-base E05 program.
//
// This test instantiates only the production sequencer.  A zero-latency-ready,
// one-cycle-done command sink replaces the compute engine, so all 249 default
// descriptors can be checked without executing billions of MAC operations.
// Four jobs run back to back: legacy mode 0, blocked-v2 mode 1, packed-v3
// mode 3, and blocked-v2/FP16 compatibility mode 5.  The live job input is
// inverted immediately after each accepted handshake, proving that the
// sequencer uses the snapshotted job configuration for all commands.
module tb_vit_phase_e_sequencer_e05;

    import vit_phase_e_pkg::*;

    localparam integer EXPECTED_COMMANDS =
        PHASE_E_EMBED_COMMANDS +
        VIT_ENCODER_LAYERS * PHASE_E_ENCODER_COMMANDS +
        PHASE_E_FINAL_SOFTMAX_COMMANDS;
    localparam integer EXPECTED_LAYER_REQUESTS = VIT_ENCODER_LAYERS;
    localparam integer WATCHDOG_CYCLES = 5_000;

    localparam logic [7:0] JOB_TAG = 8'h07;
    localparam logic [31:0] PATCH_A_BASE = 32'h0001_2345;

    localparam logic [31:0] PATCH_WEIGHT_BASE = 32'h0100_0000;
    localparam logic [31:0] PATCH_BIAS_BASE = 32'h0200_0000;
    localparam logic [31:0] CLS_BASE = 32'h0300_0000;
    localparam logic [31:0] POSITION_BASE = 32'h0400_0000;
    localparam logic [31:0] FINAL_LN_GAMMA_BASE = 32'h0500_0000;
    localparam logic [31:0] FINAL_LN_BETA_BASE = 32'h0600_0000;
    localparam logic [31:0] CLASSIFIER_WEIGHT_BASE = 32'h0700_0000;
    localparam logic [31:0] CLASSIFIER_BIAS_BASE = 32'h0800_0000;

    logic clk = 1'b0;
    logic rst = 1'b1;

    logic job_valid = 1'b0;
    logic job_ready;
    phase_e_job_t job = '0;
    phase_e_global_params_t global_params = '0;

    logic layer_param_request;
    logic [3:0] layer_param_index;
    logic layer_param_valid;
    phase_e_layer_params_t layer_param_data;

    logic cmd_valid;
    logic cmd_ready = 1'b1;
    phase_e_cmd_t cmd;
    logic cmd_done = 1'b0;
    logic cmd_error = 1'b0;

    logic checkpoint_valid;
    logic checkpoint_ready = 1'b1;
    phase_e_phase_t checkpoint_phase;
    phase_e_section_t checkpoint_section;
    logic [3:0] checkpoint_layer;
    logic [4:0] checkpoint_step;
    logic [7:0] checkpoint_tag;
    phase_e_opcode_t checkpoint_opcode;
    phase_e_tensor_id_t checkpoint_dst_tensor;

    logic busy;
    logic done;
    logic error;
    phase_e_error_t error_code;
    phase_e_section_t error_section;
    logic [3:0] error_layer;
    logic [4:0] error_step;

    integer checks = 0;
    integer failures = 0;
    integer command_count = 0;
    integer checkpoint_count = 0;
    integer layer_request_count = 0;
    integer cycle_count = 0;
    integer opcode_counts [0:15];
    integer eligible_model_gemm_count = 0;
    integer legacy_model_gemm_count = 0;
    integer blocked_model_gemm_count = 0;
    integer blocked_v2_model_gemm_count = 0;
    integer packed_model_gemm_count = 0;
    integer scratch_rowmajor_gemm_count = 0;
    integer scratch_fp16_gemm_count = 0;
    integer blocked_stride_1536_count = 0;
    integer blocked_stride_6144_count = 0;
    integer packed_stride_768_count = 0;
    integer packed_stride_3072_count = 0;
    integer active_run = 0;
    logic expected_blocked_mode = 1'b0;
    logic expected_packed_mode = 1'b0;
    logic expected_fp16_mode = 1'b0;
    integer reset_index;
    logic test_finished = 1'b0;

    always #5 clk = ~clk;

    function automatic logic [31:0] layer_base(
        input logic [3:0] index
    );
        begin
            layer_base =
                32'h1000_0000 + ({28'd0, index} << 24);
        end
    endfunction

    function automatic phase_e_layer_params_t params_for_layer(
        input logic [3:0] index
    );
        phase_e_layer_params_t value;
        logic [31:0] base;
        begin
            base = layer_base(index);
            value = '0;
            value.ln1_gamma_base = base + 32'h0000_0000;
            value.ln1_beta_base  = base + 32'h0000_0100;
            value.q_weight_base  = base + 32'h0000_0200;
            value.q_bias_base    = base + 32'h0000_0300;
            value.k_weight_base  = base + 32'h0000_0400;
            value.k_bias_base    = base + 32'h0000_0500;
            value.v_weight_base  = base + 32'h0000_0600;
            value.v_bias_base    = base + 32'h0000_0700;
            value.o_weight_base  = base + 32'h0000_0800;
            value.o_bias_base    = base + 32'h0000_0900;
            value.ln2_gamma_base = base + 32'h0000_0a00;
            value.ln2_beta_base  = base + 32'h0000_0b00;
            value.fc1_weight_base = base + 32'h0000_0c00;
            value.fc1_bias_base   = base + 32'h0000_0d00;
            value.fc2_weight_base = base + 32'h0000_0e00;
            value.fc2_bias_base   = base + 32'h0000_0f00;
            params_for_layer = value;
        end
    endfunction

    function automatic phase_e_section_t expected_section(
        input integer ordinal
    );
        begin
            if (ordinal < PHASE_E_EMBED_COMMANDS)
                expected_section = PHASE_E_SECTION_EMBEDDING;
            else if (
                ordinal <
                PHASE_E_EMBED_COMMANDS +
                VIT_ENCODER_LAYERS * PHASE_E_ENCODER_COMMANDS
            )
                expected_section = PHASE_E_SECTION_ENCODER;
            else
                expected_section = PHASE_E_SECTION_FINAL;
        end
    endfunction

    function automatic integer expected_layer(
        input integer ordinal
    );
        begin
            if (expected_section(ordinal) == PHASE_E_SECTION_ENCODER)
                expected_layer =
                    (ordinal - PHASE_E_EMBED_COMMANDS) /
                    PHASE_E_ENCODER_COMMANDS;
            else
                expected_layer = 15;
        end
    endfunction

    function automatic integer expected_raw_layer(
        input integer ordinal
    );
        begin
            case (expected_section(ordinal))
                PHASE_E_SECTION_EMBEDDING:
                    expected_raw_layer = 0;
                PHASE_E_SECTION_ENCODER:
                    expected_raw_layer = expected_layer(ordinal);
                default:
                    // E05 transitions directly from encoder layer 11 to FINAL.
                    expected_raw_layer = VIT_ENCODER_LAYERS - 1;
            endcase
        end
    endfunction

    function automatic integer expected_step(
        input integer ordinal
    );
        begin
            case (expected_section(ordinal))
                PHASE_E_SECTION_EMBEDDING:
                    expected_step = ordinal;
                PHASE_E_SECTION_ENCODER:
                    expected_step =
                        (ordinal - PHASE_E_EMBED_COMMANDS) %
                        PHASE_E_ENCODER_COMMANDS;
                default:
                    expected_step =
                        ordinal -
                        PHASE_E_EMBED_COMMANDS -
                        VIT_ENCODER_LAYERS * PHASE_E_ENCODER_COMMANDS;
            endcase
        end
    endfunction

    function automatic phase_e_opcode_t encoder_opcode(
        input integer step
    );
        begin
            case (step)
                0:  encoder_opcode = PHASE_E_OP_LAYERNORM;
                1:  encoder_opcode = PHASE_E_OP_GEMM;
                2:  encoder_opcode = PHASE_E_OP_LAYOUT;
                3:  encoder_opcode = PHASE_E_OP_GEMM;
                4:  encoder_opcode = PHASE_E_OP_LAYOUT;
                5:  encoder_opcode = PHASE_E_OP_GEMM;
                6:  encoder_opcode = PHASE_E_OP_LAYOUT;
                7:  encoder_opcode = PHASE_E_OP_LAYOUT;
                8:  encoder_opcode = PHASE_E_OP_GEMM;
                9:  encoder_opcode = PHASE_E_OP_VECTOR;
                10: encoder_opcode = PHASE_E_OP_SOFTMAX;
                11: encoder_opcode = PHASE_E_OP_GEMM;
                12: encoder_opcode = PHASE_E_OP_LAYOUT;
                13: encoder_opcode = PHASE_E_OP_GEMM;
                14: encoder_opcode = PHASE_E_OP_VECTOR;
                15: encoder_opcode = PHASE_E_OP_LAYERNORM;
                16: encoder_opcode = PHASE_E_OP_GEMM;
                17: encoder_opcode = PHASE_E_OP_GELU;
                18: encoder_opcode = PHASE_E_OP_GEMM;
                19: encoder_opcode = PHASE_E_OP_VECTOR;
                default: encoder_opcode = PHASE_E_OP_NOP;
            endcase
        end
    endfunction

    function automatic phase_e_opcode_t expected_opcode(
        input integer ordinal
    );
        integer step;
        begin
            step = expected_step(ordinal);
            case (expected_section(ordinal))
                PHASE_E_SECTION_EMBEDDING: begin
                    case (step)
                        0: expected_opcode = PHASE_E_OP_GEMM;
                        1: expected_opcode = PHASE_E_OP_LAYOUT;
                        2: expected_opcode = PHASE_E_OP_LAYOUT;
                        3: expected_opcode = PHASE_E_OP_VECTOR;
                        default: expected_opcode = PHASE_E_OP_NOP;
                    endcase
                end
                PHASE_E_SECTION_ENCODER:
                    expected_opcode = encoder_opcode(step);
                default: begin
                    case (step)
                        0: expected_opcode = PHASE_E_OP_LAYERNORM;
                        1: expected_opcode = PHASE_E_OP_LAYOUT;
                        2: expected_opcode = PHASE_E_OP_GEMM;
                        3: expected_opcode = PHASE_E_OP_ARGMAX;
                        4: expected_opcode = PHASE_E_OP_SOFTMAX;
                        default: expected_opcode = PHASE_E_OP_NOP;
                    endcase
                end
            endcase
        end
    endfunction

    function automatic logic [31:0] expected_blocked_stride(
        input logic [31:0] reduction
    );
        begin
            expected_blocked_stride =
                ((reduction + 32'd15) >> 4) << 5;
        end
    endfunction

    function automatic logic [31:0] expected_packed_stride(
        input logic [31:0] reduction
    );
        begin
            expected_packed_stride =
                ((reduction + 32'd15) >> 4) << 4;
        end
    endfunction

    function automatic logic is_model_weight_gemm(
        input phase_e_cmd_t value
    );
        begin
            is_model_weight_gemm =
                (value.header.opcode == PHASE_E_OP_GEMM) &&
                (value.route.src1_tensor == PHASE_E_TENSOR_WEIGHT) &&
                (value.route.src1_space == PHASE_E_MEM_PARAM);
        end
    endfunction

    task automatic check(
        input logic condition,
        input string message
    );
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $error(
                    "E05 sequencer check failed cycle=%0d command=%0d checkpoint=%0d: %s",
                    cycle_count,
                    command_count,
                    checkpoint_count,
                    message
                );
            end
        end
    endtask

    task automatic check_dims4(
        input phase_e_cmd_t value,
        input logic [31:0] dim0,
        input logic [31:0] dim1,
        input logic [31:0] dim2,
        input logic [31:0] dim3,
        input string name
    );
        begin
            check(
                value.dim0 == dim0 &&
                value.dim1 == dim1 &&
                value.dim2 == dim2 &&
                value.dim3 == dim3,
                {name, " dimensions"}
            );
        end
    endtask

    task automatic check_embedding_descriptor(
        input integer step,
        input phase_e_cmd_t value
    );
        begin
            case (step)
                0: begin
                    check_dims4(
                        value,
                        32'd1,
                        VIT_PATCH_COUNT,
                        VIT_HIDDEN_SIZE,
                        VIT_HIDDEN_SIZE,
                        "embedding projection GEMM"
                    );
                    check(
                        value.src0_base == PATCH_A_BASE &&
                        value.src1_base == PATCH_WEIGHT_BASE &&
                        value.src2_base == PATCH_BIAS_BASE &&
                        value.dst_base == PHASE_E_ADDR_LINEAR_TMP,
                        "embedding projection bases"
                    );
                    check(
                        value.stride0 == VIT_PATCH_WORDS &&
                        value.stride1 == VIT_HIDDEN_SIZE &&
                        value.stride2 == 32'd0 &&
                        value.stride3 ==
                            (expected_packed_mode ?
                                expected_packed_stride(VIT_HIDDEN_SIZE) :
                             expected_blocked_mode ?
                                expected_blocked_stride(VIT_HIDDEN_SIZE) :
                                VIT_HIDDEN_SIZE) &&
                        value.stride4 == VIT_PATCH_WORDS &&
                        value.immediate == VIT_HIDDEN_SIZE,
                        "embedding projection strides"
                    );
                end
                1: begin
                    check_dims4(
                        value,
                        32'd1,
                        32'd1,
                        VIT_HIDDEN_SIZE,
                        32'd0,
                        "CLS layout"
                    );
                    check(
                        value.src0_base == CLS_BASE &&
                        value.dst_base == PHASE_E_ADDR_HIDDEN_A,
                        "CLS layout bases"
                    );
                end
                2: begin
                    check_dims4(
                        value,
                        32'd1,
                        VIT_PATCH_COUNT,
                        VIT_HIDDEN_SIZE,
                        32'd0,
                        "patch-token layout"
                    );
                    check(
                        value.src0_base == PHASE_E_ADDR_LINEAR_TMP &&
                        value.dst_base ==
                            PHASE_E_ADDR_HIDDEN_A + VIT_HIDDEN_SIZE,
                        "patch-token layout bases"
                    );
                end
                3: begin
                    check(
                        value.header.subop == PHASE_E_SUBOP_VECTOR_ADD,
                        "position command is VECTOR_ADD"
                    );
                    check(
                        value.dim0 == VIT_HIDDEN_WORDS &&
                        value.src0_base == PHASE_E_ADDR_HIDDEN_A &&
                        value.src1_base == POSITION_BASE &&
                        value.dst_base == PHASE_E_ADDR_HIDDEN_A,
                        "position-add descriptor"
                    );
                end
                default:
                    check(1'b0, "unexpected embedding step");
            endcase
        end
    endtask

    task automatic check_encoder_descriptor(
        input integer layer,
        input integer step,
        input phase_e_cmd_t value
    );
        phase_e_layer_params_t expected_params;
        begin
            expected_params = params_for_layer(layer[3:0]);

            case (step)
                0: begin
                    check(
                        value.dim0 == VIT_TOKEN_COUNT &&
                        value.dim1 == VIT_HIDDEN_SIZE,
                        "LN1 uses 197 tokens x 768 hidden"
                    );
                    check(
                        value.src1_base == expected_params.ln1_gamma_base &&
                        value.src2_base == expected_params.ln1_beta_base,
                        "LN1 uses requested layer parameters"
                    );
                end
                1, 3, 5, 13: begin
                    check_dims4(
                        value,
                        32'd1,
                        VIT_TOKEN_COUNT,
                        VIT_HIDDEN_SIZE,
                        VIT_HIDDEN_SIZE,
                        "hidden projection GEMM"
                    );
                    case (step)
                        1: check(
                            value.src1_base == expected_params.q_weight_base &&
                            value.src2_base == expected_params.q_bias_base,
                            "Q projection parameter bases"
                        );
                        3: check(
                            value.src1_base == expected_params.k_weight_base &&
                            value.src2_base == expected_params.k_bias_base,
                            "K projection parameter bases"
                        );
                        5: check(
                            value.src1_base == expected_params.v_weight_base &&
                            value.src2_base == expected_params.v_bias_base,
                            "V projection parameter bases"
                        );
                        default: check(
                            value.src1_base == expected_params.o_weight_base &&
                            value.src2_base == expected_params.o_bias_base,
                            "O projection parameter bases"
                        );
                    endcase
                end
                2, 4, 6: begin
                    check(
                        value.dim0 == VIT_HEAD_COUNT &&
                        value.dim1 == VIT_TOKEN_COUNT &&
                        value.dim2 == VIT_HEAD_SIZE,
                        "Q/K/V split uses 12 x 197 x 64"
                    );
                    check(
                        value.stride0 == VIT_HEAD_SIZE &&
                        value.stride1 == VIT_HIDDEN_SIZE &&
                        value.stride2 == 32'd1,
                        "Q/K/V split strides"
                    );
                end
                7: begin
                    check(
                        value.dim0 == VIT_HEAD_COUNT &&
                        value.dim1 == VIT_HEAD_SIZE &&
                        value.dim2 == VIT_TOKEN_COUNT,
                        "K transpose uses 12 x 64 x 197"
                    );
                    check(
                        value.stride0 == VIT_ONE_HEAD_WORDS &&
                        value.stride1 == 32'd1 &&
                        value.stride2 == VIT_HEAD_SIZE,
                        "K transpose strides"
                    );
                end
                8: begin
                    check_dims4(
                        value,
                        VIT_HEAD_COUNT,
                        VIT_TOKEN_COUNT,
                        VIT_HEAD_SIZE,
                        VIT_TOKEN_COUNT,
                        "QK attention GEMM"
                    );
                    check(
                        value.stride0 == VIT_ONE_HEAD_WORDS &&
                        value.stride1 == VIT_HEAD_SIZE &&
                        value.stride2 == VIT_ONE_HEAD_WORDS &&
                        value.stride3 == VIT_TOKEN_COUNT &&
                        value.stride4 == VIT_SCORE_ROW_WORDS &&
                        value.immediate == VIT_TOKEN_COUNT,
                        "QK attention strides"
                    );
                end
                9: begin
                    check(
                        value.header.subop ==
                            PHASE_E_SUBOP_VECTOR_SCALE_MASK &&
                        value.dim0 == VIT_SCORE_WORDS &&
                        value.immediate == VIT_ATTN_SCALE_FP32,
                        "attention scale covers all score words"
                    );
                end
                10: begin
                    check(
                        value.dim0 == 32'd2364 &&
                        value.dim0 == VIT_HEAD_COUNT * VIT_TOKEN_COUNT &&
                        value.dim1 == VIT_TOKEN_COUNT,
                        "attention Softmax is 2364 rows x 197"
                    );
                    check(
                        value.src0_base == PHASE_E_ADDR_SCORE_PROB &&
                        value.dst_base == PHASE_E_ADDR_SCORE_PROB,
                        "attention Softmax is in place"
                    );
                end
                11: begin
                    check_dims4(
                        value,
                        VIT_HEAD_COUNT,
                        VIT_TOKEN_COUNT,
                        VIT_TOKEN_COUNT,
                        VIT_HEAD_SIZE,
                        "probability-times-V GEMM"
                    );
                    check(
                        value.stride0 == VIT_SCORE_ROW_WORDS &&
                        value.stride1 == VIT_TOKEN_COUNT &&
                        value.stride2 == VIT_ONE_HEAD_WORDS &&
                        value.stride3 == VIT_HEAD_SIZE &&
                        value.stride4 == VIT_ONE_HEAD_WORDS &&
                        value.immediate == VIT_HEAD_SIZE,
                        "probability-times-V strides"
                    );
                end
                12: begin
                    check(
                        value.dim0 == VIT_TOKEN_COUNT &&
                        value.dim1 == VIT_HEAD_COUNT &&
                        value.dim2 == VIT_HEAD_SIZE,
                        "head merge uses 197 x 12 x 64"
                    );
                end
                14, 19: begin
                    check(
                        value.header.subop == PHASE_E_SUBOP_VECTOR_ADD &&
                        value.dim0 == VIT_HIDDEN_WORDS,
                        "residual add covers 197 x 768"
                    );
                end
                15: begin
                    check(
                        value.dim0 == VIT_TOKEN_COUNT &&
                        value.dim1 == VIT_HIDDEN_SIZE,
                        "LN2 uses 197 tokens x 768 hidden"
                    );
                    check(
                        value.src1_base == expected_params.ln2_gamma_base &&
                        value.src2_base == expected_params.ln2_beta_base,
                        "LN2 uses requested layer parameters"
                    );
                end
                16: begin
                    check_dims4(
                        value,
                        32'd1,
                        VIT_TOKEN_COUNT,
                        VIT_HIDDEN_SIZE,
                        VIT_INTERMEDIATE_SIZE,
                        "FC1 GEMM"
                    );
                    check(
                        value.src1_base == expected_params.fc1_weight_base &&
                        value.src2_base == expected_params.fc1_bias_base,
                        "FC1 parameter bases"
                    );
                end
                17: begin
                    check(
                        value.dim0 == VIT_FC1_WORDS &&
                        value.src0_base == PHASE_E_ADDR_FC1 &&
                        value.dst_base == PHASE_E_ADDR_FC1,
                        "GELU covers 197 x 3072 in place"
                    );
                end
                18: begin
                    check_dims4(
                        value,
                        32'd1,
                        VIT_TOKEN_COUNT,
                        VIT_INTERMEDIATE_SIZE,
                        VIT_HIDDEN_SIZE,
                        "FC2 GEMM"
                    );
                    check(
                        value.src1_base == expected_params.fc2_weight_base &&
                        value.src2_base == expected_params.fc2_bias_base,
                        "FC2 parameter bases"
                    );
                end
                default: begin
                    // Steps 13 and the other explicitly listed cases are
                    // already checked above.
                end
            endcase
        end
    endtask

    task automatic check_final_descriptor(
        input integer step,
        input phase_e_cmd_t value
    );
        begin
            case (step)
                0: begin
                    check(
                        value.dim0 == VIT_TOKEN_COUNT &&
                        value.dim1 == VIT_HIDDEN_SIZE,
                        "final LayerNorm uses 197 x 768"
                    );
                    check(
                        value.src1_base == FINAL_LN_GAMMA_BASE &&
                        value.src2_base == FINAL_LN_BETA_BASE,
                        "final LayerNorm parameter bases"
                    );
                end
                1: begin
                    check(
                        value.dim0 == 32'd1 &&
                        value.dim1 == 32'd1 &&
                        value.dim2 == VIT_HIDDEN_SIZE,
                        "final CLS layout copies 768 words"
                    );
                end
                2: begin
                    check_dims4(
                        value,
                        32'd1,
                        32'd1,
                        VIT_HIDDEN_SIZE,
                        VIT_CLASS_COUNT,
                        "classifier GEMM"
                    );
                    check(
                        value.src1_base == CLASSIFIER_WEIGHT_BASE &&
                        value.src2_base == CLASSIFIER_BIAS_BASE &&
                        value.dst_base == PHASE_E_ADDR_LOGITS,
                        "classifier parameter and destination bases"
                    );
                end
                3: begin
                    check(
                        value.dim0 == VIT_CLASS_COUNT &&
                        value.src0_base == PHASE_E_ADDR_LOGITS,
                        "Argmax scans 1000 logits"
                    );
                end
                4: begin
                    check(
                        value.dim0 == 32'd1 &&
                        value.dim1 == VIT_CLASS_COUNT &&
                        value.src0_base == PHASE_E_ADDR_LOGITS &&
                        value.dst_base == PHASE_E_ADDR_CLASS_PROB,
                        "class Softmax is 1 x 1000"
                    );
                end
                default:
                    check(1'b0, "unexpected final step");
            endcase
        end
    endtask

    task automatic check_command_descriptor(
        input integer ordinal,
        input phase_e_cmd_t value
    );
        phase_e_section_t section_value;
        phase_e_opcode_t opcode_value;
        integer layer_value;
        integer raw_layer_value;
        integer step_value;
        logic [7:0] tag_value;
        logic blocked_flag;
        logic packed_flag;
        logic model_weight_gemm;
        begin
            section_value = expected_section(ordinal);
            opcode_value = expected_opcode(ordinal);
            layer_value = expected_layer(ordinal);
            raw_layer_value = expected_raw_layer(ordinal);
            step_value = expected_step(ordinal);
            tag_value = JOB_TAG + ordinal;
            blocked_flag =
                (value.header.flags &
                 PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2) != 0;
            packed_flag =
                (value.header.flags &
                 PHASE_E_FLAG_GEMM_B_FP16_PACKED2) != 0;
            model_weight_gemm = is_model_weight_gemm(value);

            check(
                value.header.opcode == opcode_value,
                "opcode sequence"
            );
            check(
                value.header.tag == tag_value,
                "command tag sequence"
            );
            check(
                (value.header.flags & PHASE_E_FLAG_CHECKPOINT) != 0,
                "checkpoint flag on every command"
            );
            check(
                value.header.reserved[7:6] == section_value &&
                value.header.reserved[5:2] == raw_layer_value[3:0] &&
                value.header.reserved[1:0] == 2'b00,
                "command section/layer execution context"
            );
            check(
                value.route.reserved[7:5] == 3'd0 &&
                value.route.reserved[4:0] == step_value[4:0],
                "command step execution context"
            );

            if (opcode_value == PHASE_E_OP_GEMM)
                check(
                    (value.header.flags &
                     PHASE_E_FLAG_GEMM_CACHE_SAFE) != 0,
                    "built-in GEMM cache-safe flag"
                );
            check(
                ((value.header.flags & PHASE_E_FLAG_GEMM_FP16) != 0) ==
                    (expected_fp16_mode &&
                     (opcode_value == PHASE_E_OP_GEMM)),
                "FP16 flag is job-selected and GEMM-only"
            );
            check(
                blocked_flag ==
                    (expected_blocked_mode && model_weight_gemm),
                "blocked-B flag is mode- and model-weight-selective"
            );
            check(
                packed_flag ==
                    (expected_packed_mode && model_weight_gemm),
                "packed-FP16 B flag is mode- and model-weight-selective"
            );
            check(
                !packed_flag || blocked_flag,
                "packed-FP16 B flag never appears without blocked-B"
            );
            if (model_weight_gemm) begin
                check(
                    value.stride3 ==
                        (expected_packed_mode ?
                            expected_packed_stride(value.dim2) :
                         expected_blocked_mode ?
                            expected_blocked_stride(value.dim2) :
                            value.dim3),
                    "model-weight GEMM uses selected B stride"
                );
            end else if (opcode_value == PHASE_E_OP_GEMM) begin
                check(
                    value.route.src1_space == PHASE_E_MEM_SCRATCH,
                    "non-model GEMM B remains scratch"
                );
                check(
                    value.stride3 == value.dim3,
                    "QK/PV scratch GEMM remains row-major"
                );
                check(
                    (value.header.flags &
                     (PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2 |
                      PHASE_E_FLAG_GEMM_B_FP16_PACKED2)) == 0,
                    "QK/PV scratch GEMM never uses persistent-B layout flags"
                );
            end
            if (opcode_value == PHASE_E_OP_LAYOUT)
                check(
                    value.header.subop == PHASE_E_SUBOP_LAYOUT_COPY,
                    "layout subop"
                );

            case (section_value)
                PHASE_E_SECTION_EMBEDDING:
                    check_embedding_descriptor(step_value, value);
                PHASE_E_SECTION_ENCODER:
                    check_encoder_descriptor(
                        layer_value,
                        step_value,
                        value
                    );
                default:
                    check_final_descriptor(step_value, value);
            endcase
        end
    endtask

    assign layer_param_valid = layer_param_request;
    assign layer_param_data = params_for_layer(layer_param_index);

    vit_phase_e_sequencer dut (
        .clk                   (clk),
        .rst                   (rst),
        .job_valid             (job_valid),
        .job_ready             (job_ready),
        .job                   (job),
        .global_params         (global_params),
        .layer_param_request   (layer_param_request),
        .layer_param_index     (layer_param_index),
        .layer_param_valid     (layer_param_valid),
        .layer_param_data      (layer_param_data),
        .cmd_valid             (cmd_valid),
        .cmd_ready             (cmd_ready),
        .cmd                   (cmd),
        .cmd_done              (cmd_done),
        .cmd_error             (cmd_error),
        .checkpoint_valid      (checkpoint_valid),
        .checkpoint_ready      (checkpoint_ready),
        .checkpoint_phase      (checkpoint_phase),
        .checkpoint_section    (checkpoint_section),
        .checkpoint_layer      (checkpoint_layer),
        .checkpoint_step       (checkpoint_step),
        .checkpoint_tag        (checkpoint_tag),
        .checkpoint_opcode     (checkpoint_opcode),
        .checkpoint_dst_tensor (checkpoint_dst_tensor),
        .busy                  (busy),
        .done                  (done),
        .error                 (error),
        .error_code            (error_code),
        .error_section         (error_section),
        .error_layer           (error_layer),
        .error_step            (error_step)
    );

    // Command sink: accept every descriptor immediately, then report success
    // one clock later while the sequencer is in SEQ_WAIT_COMMAND.
    always @(posedge clk) begin
        if (rst) begin
            cmd_done <= 1'b0;
            cmd_error <= 1'b0;
            command_count <= 0;
            checkpoint_count <= 0;
            layer_request_count <= 0;
            cycle_count <= 0;
            checks <= 0;
            failures <= 0;
            for (reset_index = 0; reset_index < 16;
                 reset_index = reset_index + 1)
                opcode_counts[reset_index] <= 0;
            eligible_model_gemm_count <= 0;
            legacy_model_gemm_count <= 0;
            blocked_model_gemm_count <= 0;
            blocked_v2_model_gemm_count <= 0;
            packed_model_gemm_count <= 0;
            scratch_rowmajor_gemm_count <= 0;
            scratch_fp16_gemm_count <= 0;
            blocked_stride_1536_count <= 0;
            blocked_stride_6144_count <= 0;
            packed_stride_768_count <= 0;
            packed_stride_3072_count <= 0;
        end else begin
            cmd_done <= 1'b0;
            cmd_error <= 1'b0;
            cycle_count <= cycle_count + 1;

            if (cmd_valid && cmd_ready) begin
                check(
                    command_count <
                        ((active_run + 1) * EXPECTED_COMMANDS),
                    "no extra command"
                );
                check_command_descriptor(
                    command_count - active_run * EXPECTED_COMMANDS,
                    cmd
                );
                opcode_counts[cmd.header.opcode] <=
                    opcode_counts[cmd.header.opcode] + 1;
                if (is_model_weight_gemm(cmd)) begin
                    eligible_model_gemm_count <=
                        eligible_model_gemm_count + 1;
                    if ((cmd.header.flags &
                         PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2) != 0) begin
                        blocked_model_gemm_count <=
                            blocked_model_gemm_count + 1;
                        if ((cmd.header.flags &
                             PHASE_E_FLAG_GEMM_B_FP16_PACKED2) != 0) begin
                            packed_model_gemm_count <=
                                packed_model_gemm_count + 1;
                            if (cmd.stride3 == 32'd768)
                                packed_stride_768_count <=
                                    packed_stride_768_count + 1;
                            if (cmd.stride3 == 32'd3072)
                                packed_stride_3072_count <=
                                    packed_stride_3072_count + 1;
                        end else begin
                            blocked_v2_model_gemm_count <=
                                blocked_v2_model_gemm_count + 1;
                            if (cmd.stride3 == 32'd1536)
                                blocked_stride_1536_count <=
                                    blocked_stride_1536_count + 1;
                            if (cmd.stride3 == 32'd6144)
                                blocked_stride_6144_count <=
                                    blocked_stride_6144_count + 1;
                        end
                    end else begin
                        legacy_model_gemm_count <=
                            legacy_model_gemm_count + 1;
                    end
                end else if (cmd.header.opcode == PHASE_E_OP_GEMM) begin
                    scratch_rowmajor_gemm_count <=
                        scratch_rowmajor_gemm_count + 1;
                    if ((cmd.header.flags &
                         PHASE_E_FLAG_GEMM_FP16) != 0)
                        scratch_fp16_gemm_count <=
                            scratch_fp16_gemm_count + 1;
                end
                command_count <= command_count + 1;
                cmd_done <= 1'b1;
            end

            if (checkpoint_valid && checkpoint_ready) begin
                check(
                    checkpoint_count <
                        ((active_run + 1) * EXPECTED_COMMANDS),
                    "no extra checkpoint"
                );
                check(
                    checkpoint_phase == PHASE_E_E05,
                    "checkpoint phase is E05"
                );
                check(
                    checkpoint_section ==
                        expected_section(
                            checkpoint_count -
                            active_run * EXPECTED_COMMANDS
                        ),
                    "checkpoint section sequence"
                );
                check(
                    checkpoint_layer ==
                        expected_layer(
                            checkpoint_count -
                            active_run * EXPECTED_COMMANDS
                        ),
                    "checkpoint layer sequence"
                );
                check(
                    checkpoint_step ==
                        expected_step(
                            checkpoint_count -
                            active_run * EXPECTED_COMMANDS
                        ),
                    "checkpoint step sequence"
                );
                check(
                    checkpoint_tag ==
                        (JOB_TAG + checkpoint_count -
                         active_run * EXPECTED_COMMANDS),
                    "checkpoint tag sequence"
                );
                check(
                    checkpoint_opcode ==
                        expected_opcode(
                            checkpoint_count -
                            active_run * EXPECTED_COMMANDS
                        ),
                    "checkpoint opcode sequence"
                );
                checkpoint_count <= checkpoint_count + 1;
            end

            if (layer_param_request && layer_param_valid) begin
                check(
                    layer_request_count <
                        ((active_run + 1) * EXPECTED_LAYER_REQUESTS),
                    "no extra layer-parameter request"
                );
                check(
                    layer_param_index ==
                        (layer_request_count -
                         active_run * EXPECTED_LAYER_REQUESTS),
                    "layer parameters requested in order 0 through 11"
                );
                layer_request_count <= layer_request_count + 1;
            end
        end
    end

    task automatic launch_and_check_job(
        input integer run_number,
        input logic accepted_blocked_mode,
        input logic accepted_packed_mode,
        input logic accepted_fp16_mode
    );
        integer expected_jobs;
        begin
            active_run = run_number;
            expected_blocked_mode = accepted_blocked_mode;
            expected_packed_mode = accepted_packed_mode;
            expected_fp16_mode = accepted_fp16_mode;
            job.model_b_blocked_k16_n2 = accepted_blocked_mode;
            job.model_b_fp16_packed2 = accepted_packed_mode;
            job.fp16_gemm_compat_enable = accepted_fp16_mode;

            @(negedge clk);
            while (!job_ready)
                @(negedge clk);
            job_valid = 1'b1;
            @(negedge clk);
            job_valid = 1'b0;

            // Invert the live input immediately after acceptance.  Every
            // descriptor must still follow the accepted execution mode.
            job.model_b_blocked_k16_n2 = !accepted_blocked_mode;
            job.model_b_fp16_packed2 = !accepted_packed_mode;
            job.fp16_gemm_compat_enable = !accepted_fp16_mode;
            #1;
            check(
                dut.active_job.model_b_blocked_k16_n2 ==
                    accepted_blocked_mode,
                "accepted job snapshots blocked-B mode"
            );
            check(
                dut.active_job.model_b_fp16_packed2 ==
                    accepted_packed_mode,
                "accepted job snapshots packed-FP16 B mode"
            );
            check(
                dut.active_job.fp16_gemm_compat_enable ==
                    accepted_fp16_mode,
                "accepted job snapshots FP16 compute mode"
            );

            wait (done || error);
            #1;
            expected_jobs = run_number + 1;
            check(done, "sequencer asserted done");
            check(!error, "sequencer completed without error");
            check(
                error_code == PHASE_E_ERROR_NONE,
                "sequencer error code remains NONE"
            );
            check(
                command_count == expected_jobs * EXPECTED_COMMANDS,
                "exactly 249 commands in this job"
            );
            check(
                checkpoint_count == expected_jobs * EXPECTED_COMMANDS,
                "exactly 249 checkpoints in this job"
            );
            check(
                layer_request_count ==
                    expected_jobs * EXPECTED_LAYER_REQUESTS,
                "exactly 12 layer-parameter requests in this job"
            );
            check(
                eligible_model_gemm_count == (run_number + 1) * 74,
                "each mode adds exactly 74 model-weight GEMMs"
            );
            check(
                legacy_model_gemm_count == 74 &&
                blocked_model_gemm_count == run_number * 74,
                "only mode 0 is row-major; modes 1/3/5 are blocked"
            );
            check(
                packed_model_gemm_count ==
                    ((run_number < 2) ? 0 : 74),
                "only mode 3 uses packed-v3 persistent B"
            );
            check(
                scratch_rowmajor_gemm_count == (run_number + 1) * 24,
                "each mode keeps 24 QK/PV GEMMs row-major"
            );
            check(
                scratch_fp16_gemm_count ==
                    ((run_number < 2) ? 0 : (run_number - 1) * 24),
                "modes 3/5 select FP16 compute for all QK/PV GEMMs"
            );

            while (!job_ready)
                @(posedge clk);
            #1;
        end
    endtask

    initial begin
        job = '0;
        global_params = '0;

        repeat (5)
            @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        job.phase = PHASE_E_E05;
        job.first_layer = 4'd0;
        job.last_layer = 4'd11;
        job.class_softmax_enable = 1'b1;
        job.checkpoint_enable = 1'b1;
        job.job_tag = JOB_TAG;
        job.patch_a_base = PATCH_A_BASE;

        global_params.patch_weight_base = PATCH_WEIGHT_BASE;
        global_params.patch_bias_base = PATCH_BIAS_BASE;
        global_params.cls_base = CLS_BASE;
        global_params.position_base = POSITION_BASE;
        global_params.final_ln_gamma_base = FINAL_LN_GAMMA_BASE;
        global_params.final_ln_beta_base = FINAL_LN_BETA_BASE;
        global_params.classifier_weight_base =
            CLASSIFIER_WEIGHT_BASE;
        global_params.classifier_bias_base =
            CLASSIFIER_BIAS_BASE;

        launch_and_check_job(0, 1'b0, 1'b0, 1'b0);
        launch_and_check_job(1, 1'b1, 1'b0, 1'b0);
        launch_and_check_job(2, 1'b1, 1'b1, 1'b1);
        launch_and_check_job(3, 1'b1, 1'b0, 1'b1);

        check(opcode_counts[PHASE_E_OP_GEMM] == 392, "4 x 98 GEMM commands");
        check(opcode_counts[PHASE_E_OP_VECTOR] == 148, "4 x 37 VECTOR commands");
        check(opcode_counts[PHASE_E_OP_LAYOUT] == 252, "4 x 63 LAYOUT commands");
        check(
            opcode_counts[PHASE_E_OP_LAYERNORM] == 100,
            "4 x 25 LAYERNORM commands"
        );
        check(
            opcode_counts[PHASE_E_OP_SOFTMAX] == 52,
            "4 x 13 SOFTMAX commands"
        );
        check(opcode_counts[PHASE_E_OP_GELU] == 48, "4 x 12 GELU commands");
        check(opcode_counts[PHASE_E_OP_ARGMAX] == 4, "four ARGMAX commands");
        check(opcode_counts[PHASE_E_OP_NOP] == 0, "no NOP command");
        check(
            eligible_model_gemm_count == 296,
            "74 eligible model-weight GEMMs per job across four modes"
        );
        check(
            legacy_model_gemm_count == 74,
            "mode 0 leaves all 74 model GEMMs row-major"
        );
        check(
            blocked_model_gemm_count == 222,
            "modes 1, 3, and 5 each block all 74 model GEMMs"
        );
        check(
            blocked_v2_model_gemm_count == 148,
            "modes 1 and 5 each use blocked-v2 for 74 model GEMMs"
        );
        check(
            packed_model_gemm_count == 74,
            "mode 3 packs all 74 persistent model GEMMs"
        );
        check(
            scratch_rowmajor_gemm_count == 96,
            "24 QK/PV scratch GEMMs per job remain row-major in four modes"
        );
        check(
            scratch_fp16_gemm_count == 48,
            "modes 3 and 5 each use FP16 compute on 24 QK/PV GEMMs"
        );
        check(
            blocked_stride_1536_count == 124,
            "2 x 62 blocked K=768 model GEMMs use stride 1536"
        );
        check(
            blocked_stride_6144_count == 24,
            "2 x 12 blocked K=3072 model GEMMs use stride 6144"
        );
        check(
            packed_stride_768_count == 62,
            "mode 3 K=768 model GEMMs use packed stride 768"
        );
        check(
            packed_stride_3072_count == 12,
            "mode 3 K=3072 model GEMMs use packed stride 3072"
        );

        test_finished = 1'b1;
        if (failures == 0) begin
            $display(
                "VIT_PHASE_E_SEQUENCER_E05_M7_MODE_PASS checks=%0d cycles=%0d commands=%0d blocked=%0d scratch_rowmajor=%0d",
                checks,
                cycle_count,
                command_count,
                blocked_model_gemm_count,
                scratch_rowmajor_gemm_count
            );
            $finish;
        end else begin
            $fatal(
                1,
                "VIT_PHASE_E_SEQUENCER_E05_FAIL checks=%0d failures=%0d",
                checks,
                failures
            );
        end
    end

    initial begin
        repeat (WATCHDOG_CYCLES)
            @(posedge clk);
        if (!test_finished)
            $fatal(
                1,
                "E05 sequencer timeout after %0d cycles commands=%0d checkpoints=%0d",
                WATCHDOG_CYCLES,
                command_count,
                checkpoint_count
            );
    end

endmodule
