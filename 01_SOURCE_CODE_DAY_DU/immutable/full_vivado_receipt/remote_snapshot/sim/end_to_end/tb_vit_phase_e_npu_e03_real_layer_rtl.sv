`timescale 1ns/1ps

// Full-dimension, real-data E03 test for exactly one encoder layer selected
// from 1..11.  This is a production-RTL logical-memory test:
//
//   behavioral checkpoint for layer L-1 -> HIDDEN_A
//                                     -> vit_phase_e_npu (E03, L..L)
//                                     <-> checked logical DDR responder
//                                     -> behavioral layer-L comparison
//
// VIT_PURE_SV_BEHAVIORAL is deliberately not defined.  The NPU sees the
// canonical packed-model-v1 absolute word addresses.  The testbench stores
// only the selected layer's contiguous 0x006c2700-word package slice.
module tb_vit_phase_e_npu_e03_real_layer_rtl;

    import vit_phase_e_pkg::*;

    localparam integer ARRAY_ROWS = 2;
    localparam integer ARRAY_COLS = 2;
    localparam integer PE_LANES = 16;
    localparam integer VECTOR_LANES = 16;

    localparam integer TOKEN_COUNT = 197;
    localparam integer HIDDEN_SIZE = 768;
    localparam integer HEAD_COUNT = 12;
    localparam integer HEAD_SIZE = 64;
    localparam integer INTERMEDIATE_SIZE = 3072;
    localparam integer HIDDEN_WORDS = TOKEN_COUNT * HIDDEN_SIZE;
    localparam integer HEAD_WORDS = HIDDEN_WORDS;
    localparam integer ONE_HEAD_WORDS = TOKEN_COUNT * HEAD_SIZE;
    localparam integer SCORE_WORDS =
        HEAD_COUNT * TOKEN_COUNT * TOKEN_COUNT;
    localparam integer SCORE_ROW_WORDS = TOKEN_COUNT * TOKEN_COUNT;
    localparam integer ATTENTION_ROWS = HEAD_COUNT * TOKEN_COUNT;
    localparam integer FC1_WORDS = TOKEN_COUNT * INTERMEDIATE_SIZE;
    localparam integer QKV_WEIGHT_WORDS = HIDDEN_SIZE * HIDDEN_SIZE;
    localparam integer FC_WEIGHT_WORDS =
        HIDDEN_SIZE * INTERMEDIATE_SIZE;

    // Canonical packed-model-v1 encoder slice.  Every layer has the same
    // tensor order and extent, so its absolute base is:
    //   0x001716f0 + layer * 0x006c2700.
    localparam logic [31:0] LAYER0_MODEL_BASE = 32'h0017_16f0;
    localparam logic [31:0] LAYER_MODEL_WORDS = 32'h006c_2700;
    localparam logic [31:0] MODEL_PACKAGE_V1_WORDS = 32'h0528_eaf0;

    localparam logic [31:0] LN1_GAMMA_REL = 32'h0000_0000;
    localparam logic [31:0] LN1_BETA_REL = 32'h0000_0300;
    localparam logic [31:0] Q_WEIGHT_REL = 32'h0000_0600;
    localparam logic [31:0] Q_BIAS_REL = 32'h0009_0600;
    localparam logic [31:0] K_WEIGHT_REL = 32'h0009_0900;
    localparam logic [31:0] K_BIAS_REL = 32'h0012_0900;
    localparam logic [31:0] V_WEIGHT_REL = 32'h0012_0c00;
    localparam logic [31:0] V_BIAS_REL = 32'h001b_0c00;
    localparam logic [31:0] O_WEIGHT_REL = 32'h001b_0f00;
    localparam logic [31:0] O_BIAS_REL = 32'h0024_0f00;
    localparam logic [31:0] LN2_GAMMA_REL = 32'h0024_1200;
    localparam logic [31:0] LN2_BETA_REL = 32'h0024_1500;
    localparam logic [31:0] FC1_WEIGHT_REL = 32'h0024_1800;
    localparam logic [31:0] FC1_BIAS_REL = 32'h0048_1800;
    localparam logic [31:0] FC2_WEIGHT_REL = 32'h0048_2400;
    localparam logic [31:0] FC2_BIAS_REL = 32'h006c_2400;

    localparam integer INPUT_BACKING_WORDS = 1;
    localparam integer SCRATCH_WORDS = PHASE_E_SCRATCH_WORDS;
    localparam logic [7:0] JOB_TAG = 8'h30;
    localparam integer EXPECTED_COMMANDS = 20;
    localparam integer EXPECTED_PARAMETER_REQUESTS = 8;
    localparam logic [19:0] EXPECTED_PARAMETER_STEP_MASK = 20'h5a02b;
    localparam integer EXPECTED_LAYER_REQUESTS = 1;
    localparam integer EXPECTED_PARAMETER_FILES = 16;
    localparam integer TOKEN_TILES =
        (TOKEN_COUNT + ARRAY_ROWS - 1) / ARRAY_ROWS;

    // Current ARRAY_ROWS=2/ARRAY_COLS=2 production traffic contract.
    // GEMM A panels are read once per batch/token panel, B weights once per
    // output tile and M tile, and each enabled bias once per command. LN reads
    // input in three passes and gamma/beta in its affine pass. Softmax reads
    // MAX/SUM/OUTPUT passes. These formulae intentionally lock the current
    // cache schedule; a future cache optimization must update this contract.
    localparam longint unsigned EXPECTED_GEMM_PARAMETER_READS =
        (4 * HIDDEN_SIZE * HIDDEN_SIZE * TOKEN_TILES) +
        (4 * HIDDEN_SIZE) +
        (2 * HIDDEN_SIZE * INTERMEDIATE_SIZE * TOKEN_TILES) +
        INTERMEDIATE_SIZE + HIDDEN_SIZE;
    localparam longint unsigned EXPECTED_LN_PARAMETER_READS =
        2 * 2 * HIDDEN_WORDS;
    localparam longint unsigned EXPECTED_PARAMETER_READS =
        EXPECTED_GEMM_PARAMETER_READS + EXPECTED_LN_PARAMETER_READS;

    localparam longint unsigned EXPECTED_GEMM_SCRATCH_READS =
        // Q/K/V/O activation panels.
        (4 * TOKEN_COUNT * HIDDEN_SIZE) +
        // QK activation and scratch-B matrices.
        (HEAD_COUNT * TOKEN_COUNT * HEAD_SIZE) +
        (HEAD_COUNT * TOKEN_COUNT * HEAD_SIZE * TOKEN_TILES) +
        // PV activation and scratch-B matrices.
        (HEAD_COUNT * TOKEN_COUNT * TOKEN_COUNT) +
        (HEAD_COUNT * HEAD_SIZE * TOKEN_COUNT * TOKEN_TILES) +
        // FC1 and FC2 activation panels.
        HIDDEN_WORDS + FC1_WORDS;
    localparam longint unsigned EXPECTED_NON_GEMM_SCRATCH_READS =
        // Two layer norms, three input passes each.
        (2 * 3 * HIDDEN_WORDS) +
        // Q/K/V split, K transpose and head merge.
        (5 * HIDDEN_WORDS) +
        // Attention scale plus two residual adds (two sources each).
        SCORE_WORDS + (4 * HIDDEN_WORDS) +
        // Softmax MAX/SUM/OUTPUT passes.
        (3 * SCORE_WORDS) +
        // GELU reads FC1 once.
        FC1_WORDS;
    localparam longint unsigned EXPECTED_SCRATCH_READS =
        EXPECTED_GEMM_SCRATCH_READS +
        EXPECTED_NON_GEMM_SCRATCH_READS;
    localparam longint unsigned EXPECTED_READS =
        EXPECTED_PARAMETER_READS + EXPECTED_SCRATCH_READS;
    localparam integer EXPECTED_WRITES =
        (15 * HIDDEN_WORDS) + (3 * SCORE_WORDS) + (2 * FC1_WORDS);
    localparam longint unsigned EXPECTED_REQUESTS =
        EXPECTED_READS + EXPECTED_WRITES;
    localparam logic [31:0] EXPECTED_SCRATCH_MIN =
        PHASE_E_ADDR_HIDDEN_A;
    localparam logic [31:0] EXPECTED_SCRATCH_MAX =
        PHASE_E_ADDR_FC1 + FC1_WORDS - 1;

    // One layer starts from its behavioral predecessor rather than from the
    // previous RTL layer.  Therefore this threshold measures one production
    // layer only: abs(error) <= 2e-3 + 2e-3*abs(golden).
    localparam real OUTPUT_ABS_TOLERANCE = 2.0e-3;
    localparam real OUTPUT_REL_TOLERANCE = 2.0e-3;
    localparam logic [31:0] FP32_SENTINEL = 32'hdead_beef;
    localparam logic [31:0] FP32_QNAN = 32'h7fc0_0000;
    localparam logic [63:0] WATCHDOG_CYCLES = 64'd20_000_000_000;

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
    phase_e_layer_params_t selected_layer_params = '0;

    logic operand_load_request;
    logic operand_load_ready;
    phase_e_cmd_t operand_load_command;

    logic checkpoint_valid;
    logic checkpoint_ready;
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

    logic mem_req_valid;
    logic mem_req_ready;
    logic mem_req_write;
    phase_e_mem_space_t mem_req_space;
    logic [31:0] mem_req_word_address;
    logic [31:0] mem_req_write_data;
    logic [3:0] mem_req_write_strobe;
    logic mem_rsp_valid = 1'b0;
    logic mem_rsp_ready;
    logic [31:0] mem_rsp_read_data = 32'd0;
    logic mem_rsp_error = 1'b0;

    logic class_result_valid;
    logic [31:0] class_index;
    logic [31:0] class_logit;

    // A fast sequencer-only audit runs the same selected-layer job with an
    // immediate command-completion responder. It validates all 20 descriptors
    // and checkpoint metadata in roughly one hundred clocks, independently of
    // the multi-billion-cycle arithmetic execution below.
    logic descriptor_job_valid = 1'b0;
    logic descriptor_job_ready;
    phase_e_job_t descriptor_job = '0;
    logic descriptor_layer_param_request;
    logic [3:0] descriptor_layer_param_index;
    logic descriptor_layer_param_valid;
    phase_e_layer_params_t descriptor_layer_param_data;
    logic descriptor_cmd_valid;
    phase_e_cmd_t descriptor_cmd;
    logic descriptor_checkpoint_valid;
    phase_e_phase_t descriptor_checkpoint_phase;
    phase_e_section_t descriptor_checkpoint_section;
    logic [3:0] descriptor_checkpoint_layer;
    logic [4:0] descriptor_checkpoint_step;
    logic [7:0] descriptor_checkpoint_tag;
    phase_e_opcode_t descriptor_checkpoint_opcode;
    phase_e_tensor_id_t descriptor_checkpoint_dst_tensor;
    logic descriptor_done;
    logic descriptor_error;
    integer descriptor_command_count = 0;
    integer descriptor_checkpoint_count = 0;
    logic descriptor_audit_complete = 1'b0;

    logic [31:0] model_memory [0:LAYER_MODEL_WORDS-1];
    logic [31:0] scratch_memory [0:SCRATCH_WORDS-1];
    logic [31:0] golden_output [0:HIDDEN_WORDS-1];

    integer selected_layer = -1;
    logic [3:0] selected_layer_index = 4'hf;
    logic [31:0] selected_layer_base = 32'd0;
    logic [31:0] ln1_gamma_base = 32'd0;
    logic [31:0] ln1_beta_base = 32'd0;
    logic [31:0] q_weight_base = 32'd0;
    logic [31:0] q_bias_base = 32'd0;
    logic [31:0] k_weight_base = 32'd0;
    logic [31:0] k_bias_base = 32'd0;
    logic [31:0] v_weight_base = 32'd0;
    logic [31:0] v_bias_base = 32'd0;
    logic [31:0] o_weight_base = 32'd0;
    logic [31:0] o_bias_base = 32'd0;
    logic [31:0] ln2_gamma_base = 32'd0;
    logic [31:0] ln2_beta_base = 32'd0;
    logic [31:0] fc1_weight_base = 32'd0;
    logic [31:0] fc1_bias_base = 32'd0;
    logic [31:0] fc2_weight_base = 32'd0;
    logic [31:0] fc2_bias_base = 32'd0;

    logic response_pending = 1'b0;
    logic pending_write = 1'b0;
    logic [31:0] pending_address = 32'd0;
    logic [31:0] pending_write_data = 32'd0;
    logic [31:0] pending_read_data = 32'd0;
    logic request_address_valid;
    logic [31:0] request_read_data;

    logic stalled_request = 1'b0;
    logic stalled_write = 1'b0;
    phase_e_mem_space_t stalled_space = PHASE_E_MEM_NONE;
    logic [31:0] stalled_address = 32'd0;
    logic [31:0] stalled_write_data = 32'd0;
    logic [3:0] stalled_write_strobe = 4'd0;
    logic [63:0] backpressure_cycle_count = 64'd0;

    logic [63:0] cycle_count = 64'd0;
    logic [63:0] accepted_request_count = 64'd0;
    logic [63:0] response_handshake_count = 64'd0;
    logic [63:0] write_request_accept_count = 64'd0;
    logic [63:0] read_transaction_count = 64'd0;
    logic [63:0] write_transaction_count = 64'd0;
    logic [63:0] parameter_read_count = 64'd0;
    logic [63:0] scratch_read_count = 64'd0;
    logic [63:0] input_read_count = 64'd0;
    logic [31:0] invalid_transaction_count = 32'd0;
    logic [31:0] parameter_min_address = 32'hffff_ffff;
    logic [31:0] parameter_max_address = 32'd0;
    logic [31:0] scratch_min_address = 32'hffff_ffff;
    logic [31:0] scratch_max_address = 32'd0;
    logic [31:0] scratch_write_min_address = 32'hffff_ffff;
    logic [31:0] scratch_write_max_address = 32'd0;
    logic [15:0] parameter_tensor_seen = 16'd0;
    logic [7:0] scratch_read_region_seen = 8'd0;
    logic [7:0] scratch_write_region_seen = 8'd0;

    integer checks = 0;
    integer failures = 0;
    integer command_count = 0;
    integer checkpoint_count = 0;
    integer parameter_request_count = 0;
    integer layer_request_count = 0;
    integer class_result_count = 0;
    logic [19:0] parameter_step_seen = 20'd0;
    phase_e_cmd_t accepted_commands [0:EXPECTED_COMMANDS-1];
    integer loaded_parameter_file_count = 0;
    integer initialize_index;
    integer exact_mismatches;
    integer tolerance_failures;
    integer unknown_failures;
    integer nonfinite_failures;
    integer max_error_index;
    integer max_ratio_index;
    logic [31:0] max_error_rtl_word;
    logic [31:0] max_error_golden_word;
    real rtl_value;
    real golden_value;
    real absolute_error;
    real allowed_error;
    real normalized_error;
    real max_abs_error;
    real max_normalized_error;
    real sum_abs_error;
    real mean_abs_error;

    integer progress_cycle_interval;
    integer progress_transaction_interval;
    integer probe_cycle_limit;
    integer progress_cycle_plusarg_status;
    integer progress_transaction_plusarg_status;
    integer probe_cycle_plusarg_status;
    integer layer_plusarg_status;
    logic [63:0] next_progress_cycle;
    logic [63:0] next_progress_transaction;

    string previous_output_filename;
    string golden_output_filename;

    always #1 clk = ~clk;

    function automatic logic address_in_range(
        input logic [31:0] address,
        input logic [31:0] base,
        input logic [31:0] word_count
    );
        logic [32:0] limit;
        begin
            limit = {1'b0, base} + {1'b0, word_count};
            address_in_range =
                ({1'b0, address} >= {1'b0, base}) &&
                ({1'b0, address} < limit);
        end
    endfunction

    function automatic logic parameter_address_valid(
        input logic [31:0] address
    );
        begin
            parameter_address_valid =
                address_in_range(address, ln1_gamma_base, HIDDEN_SIZE) ||
                address_in_range(address, ln1_beta_base, HIDDEN_SIZE) ||
                address_in_range(
                    address, q_weight_base, QKV_WEIGHT_WORDS
                ) ||
                address_in_range(address, q_bias_base, HIDDEN_SIZE) ||
                address_in_range(
                    address, k_weight_base, QKV_WEIGHT_WORDS
                ) ||
                address_in_range(address, k_bias_base, HIDDEN_SIZE) ||
                address_in_range(
                    address, v_weight_base, QKV_WEIGHT_WORDS
                ) ||
                address_in_range(address, v_bias_base, HIDDEN_SIZE) ||
                address_in_range(
                    address, o_weight_base, QKV_WEIGHT_WORDS
                ) ||
                address_in_range(address, o_bias_base, HIDDEN_SIZE) ||
                address_in_range(address, ln2_gamma_base, HIDDEN_SIZE) ||
                address_in_range(address, ln2_beta_base, HIDDEN_SIZE) ||
                address_in_range(
                    address, fc1_weight_base, FC_WEIGHT_WORDS
                ) ||
                address_in_range(
                    address, fc1_bias_base, INTERMEDIATE_SIZE
                ) ||
                address_in_range(
                    address, fc2_weight_base, FC_WEIGHT_WORDS
                ) ||
                address_in_range(address, fc2_bias_base, HIDDEN_SIZE);
        end
    endfunction

    function automatic logic scratch_address_valid(
        input logic [31:0] address
    );
        begin
            scratch_address_valid =
                address_in_range(
                    address, PHASE_E_ADDR_HIDDEN_A, HIDDEN_WORDS
                ) ||
                address_in_range(
                    address, PHASE_E_ADDR_HIDDEN_B, HIDDEN_WORDS
                ) ||
                address_in_range(
                    address, PHASE_E_ADDR_LINEAR_TMP, HIDDEN_WORDS
                ) ||
                address_in_range(
                    address, PHASE_E_ADDR_Q_HEAD, HEAD_WORDS
                ) ||
                address_in_range(
                    address, PHASE_E_ADDR_K_HEAD, HEAD_WORDS
                ) ||
                address_in_range(
                    address, PHASE_E_ADDR_V_HEAD, HEAD_WORDS
                ) ||
                address_in_range(
                    address, PHASE_E_ADDR_SCORE_PROB, SCORE_WORDS
                ) ||
                address_in_range(
                    address, PHASE_E_ADDR_FC1, FC1_WORDS
                );
        end
    endfunction

    function automatic logic logical_request_valid(
        input logic write_request,
        input phase_e_mem_space_t space,
        input logic [31:0] address,
        input logic [3:0] write_strobe
    );
        begin
            if (write_request)
                logical_request_valid =
                    (space == PHASE_E_MEM_SCRATCH) &&
                    scratch_address_valid(address) &&
                    (write_strobe == 4'hf);
            else begin
                case (space)
                    PHASE_E_MEM_PARAM:
                        logical_request_valid =
                            parameter_address_valid(address);
                    PHASE_E_MEM_SCRATCH:
                        logical_request_valid =
                            scratch_address_valid(address);
                    default:
                        logical_request_valid = 1'b0;
                endcase
            end
        end
    endfunction

    function automatic logic [31:0] read_logical_word(
        input phase_e_mem_space_t space,
        input logic [31:0] address
    );
        begin
            case (space)
                PHASE_E_MEM_PARAM:
                    read_logical_word =
                        model_memory[address - selected_layer_base];
                PHASE_E_MEM_SCRATCH:
                    read_logical_word = scratch_memory[address];
                default:
                    read_logical_word = FP32_QNAN;
            endcase
        end
    endfunction

    function automatic logic [15:0] parameter_tensor_onehot(
        input logic [31:0] address
    );
        begin
            parameter_tensor_onehot = 16'd0;
            if (address_in_range(address, ln1_gamma_base, HIDDEN_SIZE))
                parameter_tensor_onehot[0] = 1'b1;
            else if (address_in_range(address, ln1_beta_base, HIDDEN_SIZE))
                parameter_tensor_onehot[1] = 1'b1;
            else if (
                address_in_range(address, q_weight_base, QKV_WEIGHT_WORDS)
            )
                parameter_tensor_onehot[2] = 1'b1;
            else if (address_in_range(address, q_bias_base, HIDDEN_SIZE))
                parameter_tensor_onehot[3] = 1'b1;
            else if (
                address_in_range(address, k_weight_base, QKV_WEIGHT_WORDS)
            )
                parameter_tensor_onehot[4] = 1'b1;
            else if (address_in_range(address, k_bias_base, HIDDEN_SIZE))
                parameter_tensor_onehot[5] = 1'b1;
            else if (
                address_in_range(address, v_weight_base, QKV_WEIGHT_WORDS)
            )
                parameter_tensor_onehot[6] = 1'b1;
            else if (address_in_range(address, v_bias_base, HIDDEN_SIZE))
                parameter_tensor_onehot[7] = 1'b1;
            else if (
                address_in_range(address, o_weight_base, QKV_WEIGHT_WORDS)
            )
                parameter_tensor_onehot[8] = 1'b1;
            else if (address_in_range(address, o_bias_base, HIDDEN_SIZE))
                parameter_tensor_onehot[9] = 1'b1;
            else if (address_in_range(address, ln2_gamma_base, HIDDEN_SIZE))
                parameter_tensor_onehot[10] = 1'b1;
            else if (address_in_range(address, ln2_beta_base, HIDDEN_SIZE))
                parameter_tensor_onehot[11] = 1'b1;
            else if (
                address_in_range(address, fc1_weight_base, FC_WEIGHT_WORDS)
            )
                parameter_tensor_onehot[12] = 1'b1;
            else if (
                address_in_range(
                    address, fc1_bias_base, INTERMEDIATE_SIZE
                )
            )
                parameter_tensor_onehot[13] = 1'b1;
            else if (
                address_in_range(address, fc2_weight_base, FC_WEIGHT_WORDS)
            )
                parameter_tensor_onehot[14] = 1'b1;
            else if (address_in_range(address, fc2_bias_base, HIDDEN_SIZE))
                parameter_tensor_onehot[15] = 1'b1;
        end
    endfunction

    function automatic logic [7:0] scratch_region_onehot(
        input logic [31:0] address
    );
        begin
            scratch_region_onehot = 8'd0;
            if (address_in_range(
                address, PHASE_E_ADDR_HIDDEN_A, HIDDEN_WORDS
            ))
                scratch_region_onehot[0] = 1'b1;
            else if (address_in_range(
                address, PHASE_E_ADDR_HIDDEN_B, HIDDEN_WORDS
            ))
                scratch_region_onehot[1] = 1'b1;
            else if (address_in_range(
                address, PHASE_E_ADDR_LINEAR_TMP, HIDDEN_WORDS
            ))
                scratch_region_onehot[2] = 1'b1;
            else if (address_in_range(
                address, PHASE_E_ADDR_Q_HEAD, HEAD_WORDS
            ))
                scratch_region_onehot[3] = 1'b1;
            else if (address_in_range(
                address, PHASE_E_ADDR_K_HEAD, HEAD_WORDS
            ))
                scratch_region_onehot[4] = 1'b1;
            else if (address_in_range(
                address, PHASE_E_ADDR_V_HEAD, HEAD_WORDS
            ))
                scratch_region_onehot[5] = 1'b1;
            else if (address_in_range(
                address, PHASE_E_ADDR_SCORE_PROB, SCORE_WORDS
            ))
                scratch_region_onehot[6] = 1'b1;
            else if (address_in_range(
                address, PHASE_E_ADDR_FC1, FC1_WORDS
            ))
                scratch_region_onehot[7] = 1'b1;
        end
    endfunction

    function automatic logic fp32_is_finite(
        input logic [31:0] word
    );
        begin
            fp32_is_finite = (word[30:23] != 8'hff);
        end
    endfunction

    function automatic real fp32_to_real(
        input logic [31:0] word
    );
        integer exponent;
        integer scale_index;
        real significand;
        real scale;
        begin
            exponent = word[30:23];
            scale = 1.0;
            significand = 0.0;
            if (exponent == 0) begin
                significand = real'(word[22:0]) / 8388608.0;
                for (scale_index = 0; scale_index < 126;
                     scale_index = scale_index + 1)
                    scale = scale * 0.5;
            end else if (exponent != 255) begin
                significand =
                    1.0 + (real'(word[22:0]) / 8388608.0);
                if (exponent >= 127)
                    for (scale_index = 127; scale_index < exponent;
                         scale_index = scale_index + 1)
                        scale = scale * 2.0;
                else
                    for (scale_index = exponent; scale_index < 127;
                         scale_index = scale_index + 1)
                        scale = scale * 0.5;
            end
            if (exponent == 255)
                fp32_to_real = 0.0;
            else begin
                fp32_to_real = significand * scale;
                if (word[31])
                    fp32_to_real = -fp32_to_real;
            end
        end
    endfunction

    function automatic phase_e_opcode_t expected_opcode(
        input integer ordinal
    );
        begin
            case (ordinal)
                0, 15:
                    expected_opcode = PHASE_E_OP_LAYERNORM;
                1, 3, 5, 8, 11, 13, 16, 18:
                    expected_opcode = PHASE_E_OP_GEMM;
                2, 4, 6, 7, 12:
                    expected_opcode = PHASE_E_OP_LAYOUT;
                9, 14, 19:
                    expected_opcode = PHASE_E_OP_VECTOR;
                10:
                    expected_opcode = PHASE_E_OP_SOFTMAX;
                17:
                    expected_opcode = PHASE_E_OP_GELU;
                default:
                    expected_opcode = PHASE_E_OP_NOP;
            endcase
        end
    endfunction

    function automatic phase_e_cmd_route_t expected_route(
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
            expected_route = value;
        end
    endfunction

    // Independent architectural contract for every encoder command. Comparing
    // all 512 bits catches wrong bases, dimensions, strides, flags, subops,
    // tensor IDs/spaces, tags and reserved execution context in one check.
    function automatic phase_e_cmd_t expected_command(
        input integer ordinal
    );
        phase_e_cmd_t value;
        begin
            value = '0;
            value.header.tag = JOB_TAG + ordinal[7:0];
            value.header.flags = PHASE_E_FLAG_CHECKPOINT;

            case (ordinal)
                0: begin
                    value.header.opcode = PHASE_E_OP_LAYERNORM;
                    value.route = expected_route(
                        PHASE_E_TENSOR_HIDDEN_A,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_HIDDEN_B
                    );
                    value.src0_base = PHASE_E_ADDR_HIDDEN_A;
                    value.src1_base = ln1_gamma_base;
                    value.src2_base = ln1_beta_base;
                    value.dst_base = PHASE_E_ADDR_HIDDEN_B;
                    value.dim0 = TOKEN_COUNT;
                    value.dim1 = HIDDEN_SIZE;
                    value.immediate = VIT_LN_EPSILON_FP32;
                end

                1, 3, 5: begin
                    value.header.opcode = PHASE_E_OP_GEMM;
                    value.header.flags =
                        PHASE_E_FLAG_CHECKPOINT |
                        PHASE_E_FLAG_BIAS_ENABLE |
                        PHASE_E_FLAG_GEMM_CACHE_SAFE;
                    value.route = expected_route(
                        PHASE_E_TENSOR_HIDDEN_B,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_LINEAR_TMP
                    );
                    value.src0_base = PHASE_E_ADDR_HIDDEN_B;
                    if (ordinal == 1) begin
                        value.src1_base = q_weight_base;
                        value.src2_base = q_bias_base;
                    end else if (ordinal == 3) begin
                        value.src1_base = k_weight_base;
                        value.src2_base = k_bias_base;
                    end else begin
                        value.src1_base = v_weight_base;
                        value.src2_base = v_bias_base;
                    end
                    value.dst_base = PHASE_E_ADDR_LINEAR_TMP;
                    value.dim0 = 1;
                    value.dim1 = TOKEN_COUNT;
                    value.dim2 = HIDDEN_SIZE;
                    value.dim3 = HIDDEN_SIZE;
                    value.stride0 = HIDDEN_WORDS;
                    value.stride1 = HIDDEN_SIZE;
                    value.stride2 = 0;
                    value.stride3 = HIDDEN_SIZE;
                    value.stride4 = HIDDEN_WORDS;
                    value.immediate = HIDDEN_SIZE;
                end

                2, 4, 6: begin
                    value.header.opcode = PHASE_E_OP_LAYOUT;
                    value.header.subop = PHASE_E_SUBOP_LAYOUT_COPY;
                    value.route = expected_route(
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_NONE,
                        (ordinal == 2) ? PHASE_E_TENSOR_Q_HEAD :
                        ((ordinal == 4) ? PHASE_E_TENSOR_K_HEAD :
                                          PHASE_E_TENSOR_V_HEAD)
                    );
                    value.src0_base = PHASE_E_ADDR_LINEAR_TMP;
                    value.dst_base =
                        (ordinal == 2) ? PHASE_E_ADDR_Q_HEAD :
                        ((ordinal == 4) ? PHASE_E_ADDR_K_HEAD :
                                          PHASE_E_ADDR_V_HEAD);
                    value.dim0 = HEAD_COUNT;
                    value.dim1 = TOKEN_COUNT;
                    value.dim2 = HEAD_SIZE;
                    value.stride0 = HEAD_SIZE;
                    value.stride1 = HIDDEN_SIZE;
                    value.stride2 = 1;
                end

                7: begin
                    value.header.opcode = PHASE_E_OP_LAYOUT;
                    value.header.subop = PHASE_E_SUBOP_LAYOUT_COPY;
                    value.route = expected_route(
                        PHASE_E_TENSOR_K_HEAD,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_LINEAR_TMP
                    );
                    value.src0_base = PHASE_E_ADDR_K_HEAD;
                    value.dst_base = PHASE_E_ADDR_LINEAR_TMP;
                    value.dim0 = HEAD_COUNT;
                    value.dim1 = HEAD_SIZE;
                    value.dim2 = TOKEN_COUNT;
                    value.stride0 = ONE_HEAD_WORDS;
                    value.stride1 = 1;
                    value.stride2 = HEAD_SIZE;
                end

                8: begin
                    value.header.opcode = PHASE_E_OP_GEMM;
                    value.header.flags =
                        PHASE_E_FLAG_CHECKPOINT |
                        PHASE_E_FLAG_GEMM_CACHE_SAFE;
                    value.route = expected_route(
                        PHASE_E_TENSOR_Q_HEAD,
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_SCORE_PROB
                    );
                    value.src0_base = PHASE_E_ADDR_Q_HEAD;
                    value.src1_base = PHASE_E_ADDR_LINEAR_TMP;
                    value.dst_base = PHASE_E_ADDR_SCORE_PROB;
                    value.dim0 = HEAD_COUNT;
                    value.dim1 = TOKEN_COUNT;
                    value.dim2 = HEAD_SIZE;
                    value.dim3 = TOKEN_COUNT;
                    value.stride0 = ONE_HEAD_WORDS;
                    value.stride1 = HEAD_SIZE;
                    value.stride2 = ONE_HEAD_WORDS;
                    value.stride3 = TOKEN_COUNT;
                    value.stride4 = SCORE_ROW_WORDS;
                    value.immediate = TOKEN_COUNT;
                end

                9: begin
                    value.header.opcode = PHASE_E_OP_VECTOR;
                    value.header.subop = PHASE_E_SUBOP_VECTOR_SCALE_MASK;
                    value.header.flags =
                        PHASE_E_FLAG_CHECKPOINT | PHASE_E_FLAG_IN_PLACE;
                    value.route = expected_route(
                        PHASE_E_TENSOR_SCORE_PROB,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_SCORE_PROB
                    );
                    value.src0_base = PHASE_E_ADDR_SCORE_PROB;
                    value.dst_base = PHASE_E_ADDR_SCORE_PROB;
                    value.dim0 = SCORE_WORDS;
                    value.immediate = VIT_ATTN_SCALE_FP32;
                end

                10: begin
                    value.header.opcode = PHASE_E_OP_SOFTMAX;
                    value.header.flags =
                        PHASE_E_FLAG_CHECKPOINT | PHASE_E_FLAG_IN_PLACE;
                    value.route = expected_route(
                        PHASE_E_TENSOR_SCORE_PROB,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_SCORE_PROB
                    );
                    value.src0_base = PHASE_E_ADDR_SCORE_PROB;
                    value.dst_base = PHASE_E_ADDR_SCORE_PROB;
                    value.dim0 = ATTENTION_ROWS;
                    value.dim1 = TOKEN_COUNT;
                end

                11: begin
                    value.header.opcode = PHASE_E_OP_GEMM;
                    value.header.flags =
                        PHASE_E_FLAG_CHECKPOINT |
                        PHASE_E_FLAG_GEMM_CACHE_SAFE;
                    value.route = expected_route(
                        PHASE_E_TENSOR_SCORE_PROB,
                        PHASE_E_TENSOR_V_HEAD,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_Q_HEAD
                    );
                    value.src0_base = PHASE_E_ADDR_SCORE_PROB;
                    value.src1_base = PHASE_E_ADDR_V_HEAD;
                    value.dst_base = PHASE_E_ADDR_Q_HEAD;
                    value.dim0 = HEAD_COUNT;
                    value.dim1 = TOKEN_COUNT;
                    value.dim2 = TOKEN_COUNT;
                    value.dim3 = HEAD_SIZE;
                    value.stride0 = SCORE_ROW_WORDS;
                    value.stride1 = TOKEN_COUNT;
                    value.stride2 = ONE_HEAD_WORDS;
                    value.stride3 = HEAD_SIZE;
                    value.stride4 = ONE_HEAD_WORDS;
                    value.immediate = HEAD_SIZE;
                end

                12: begin
                    value.header.opcode = PHASE_E_OP_LAYOUT;
                    value.header.subop = PHASE_E_SUBOP_LAYOUT_COPY;
                    value.route = expected_route(
                        PHASE_E_TENSOR_Q_HEAD,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_LINEAR_TMP
                    );
                    value.src0_base = PHASE_E_ADDR_Q_HEAD;
                    value.dst_base = PHASE_E_ADDR_LINEAR_TMP;
                    value.dim0 = TOKEN_COUNT;
                    value.dim1 = HEAD_COUNT;
                    value.dim2 = HEAD_SIZE;
                    value.stride0 = HEAD_SIZE;
                    value.stride1 = ONE_HEAD_WORDS;
                    value.stride2 = 1;
                end

                13: begin
                    value.header.opcode = PHASE_E_OP_GEMM;
                    value.header.flags =
                        PHASE_E_FLAG_CHECKPOINT |
                        PHASE_E_FLAG_BIAS_ENABLE |
                        PHASE_E_FLAG_GEMM_CACHE_SAFE;
                    value.route = expected_route(
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_HIDDEN_B
                    );
                    value.src0_base = PHASE_E_ADDR_LINEAR_TMP;
                    value.src1_base = o_weight_base;
                    value.src2_base = o_bias_base;
                    value.dst_base = PHASE_E_ADDR_HIDDEN_B;
                    value.dim0 = 1;
                    value.dim1 = TOKEN_COUNT;
                    value.dim2 = HIDDEN_SIZE;
                    value.dim3 = HIDDEN_SIZE;
                    value.stride0 = HIDDEN_WORDS;
                    value.stride1 = HIDDEN_SIZE;
                    value.stride2 = 0;
                    value.stride3 = HIDDEN_SIZE;
                    value.stride4 = HIDDEN_WORDS;
                    value.immediate = HIDDEN_SIZE;
                end

                14: begin
                    value.header.opcode = PHASE_E_OP_VECTOR;
                    value.header.subop = PHASE_E_SUBOP_VECTOR_ADD;
                    value.header.flags =
                        PHASE_E_FLAG_CHECKPOINT | PHASE_E_FLAG_IN_PLACE;
                    value.route = expected_route(
                        PHASE_E_TENSOR_HIDDEN_B,
                        PHASE_E_TENSOR_HIDDEN_A,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_HIDDEN_B
                    );
                    value.src0_base = PHASE_E_ADDR_HIDDEN_B;
                    value.src1_base = PHASE_E_ADDR_HIDDEN_A;
                    value.dst_base = PHASE_E_ADDR_HIDDEN_B;
                    value.dim0 = HIDDEN_WORDS;
                end

                15: begin
                    value.header.opcode = PHASE_E_OP_LAYERNORM;
                    value.route = expected_route(
                        PHASE_E_TENSOR_HIDDEN_B,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_HIDDEN_A
                    );
                    value.src0_base = PHASE_E_ADDR_HIDDEN_B;
                    value.src1_base = ln2_gamma_base;
                    value.src2_base = ln2_beta_base;
                    value.dst_base = PHASE_E_ADDR_HIDDEN_A;
                    value.dim0 = TOKEN_COUNT;
                    value.dim1 = HIDDEN_SIZE;
                    value.immediate = VIT_LN_EPSILON_FP32;
                end

                16: begin
                    value.header.opcode = PHASE_E_OP_GEMM;
                    value.header.flags =
                        PHASE_E_FLAG_CHECKPOINT |
                        PHASE_E_FLAG_BIAS_ENABLE |
                        PHASE_E_FLAG_GEMM_CACHE_SAFE;
                    value.route = expected_route(
                        PHASE_E_TENSOR_HIDDEN_A,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_FC1
                    );
                    value.src0_base = PHASE_E_ADDR_HIDDEN_A;
                    value.src1_base = fc1_weight_base;
                    value.src2_base = fc1_bias_base;
                    value.dst_base = PHASE_E_ADDR_FC1;
                    value.dim0 = 1;
                    value.dim1 = TOKEN_COUNT;
                    value.dim2 = HIDDEN_SIZE;
                    value.dim3 = INTERMEDIATE_SIZE;
                    value.stride0 = HIDDEN_WORDS;
                    value.stride1 = HIDDEN_SIZE;
                    value.stride2 = 0;
                    value.stride3 = INTERMEDIATE_SIZE;
                    value.stride4 = FC1_WORDS;
                    value.immediate = INTERMEDIATE_SIZE;
                end

                17: begin
                    value.header.opcode = PHASE_E_OP_GELU;
                    value.header.flags =
                        PHASE_E_FLAG_CHECKPOINT | PHASE_E_FLAG_IN_PLACE;
                    value.route = expected_route(
                        PHASE_E_TENSOR_FC1,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_FC1
                    );
                    value.src0_base = PHASE_E_ADDR_FC1;
                    value.dst_base = PHASE_E_ADDR_FC1;
                    value.dim0 = FC1_WORDS;
                end

                18: begin
                    value.header.opcode = PHASE_E_OP_GEMM;
                    value.header.flags =
                        PHASE_E_FLAG_CHECKPOINT |
                        PHASE_E_FLAG_BIAS_ENABLE |
                        PHASE_E_FLAG_GEMM_CACHE_SAFE;
                    value.route = expected_route(
                        PHASE_E_TENSOR_FC1,
                        PHASE_E_TENSOR_WEIGHT,
                        PHASE_E_TENSOR_BIAS,
                        PHASE_E_TENSOR_LINEAR_TMP
                    );
                    value.src0_base = PHASE_E_ADDR_FC1;
                    value.src1_base = fc2_weight_base;
                    value.src2_base = fc2_bias_base;
                    value.dst_base = PHASE_E_ADDR_LINEAR_TMP;
                    value.dim0 = 1;
                    value.dim1 = TOKEN_COUNT;
                    value.dim2 = INTERMEDIATE_SIZE;
                    value.dim3 = HIDDEN_SIZE;
                    value.stride0 = FC1_WORDS;
                    value.stride1 = INTERMEDIATE_SIZE;
                    value.stride2 = 0;
                    value.stride3 = HIDDEN_SIZE;
                    value.stride4 = HIDDEN_WORDS;
                    value.immediate = HIDDEN_SIZE;
                end

                19: begin
                    value.header.opcode = PHASE_E_OP_VECTOR;
                    value.header.subop = PHASE_E_SUBOP_VECTOR_ADD;
                    value.route = expected_route(
                        PHASE_E_TENSOR_LINEAR_TMP,
                        PHASE_E_TENSOR_HIDDEN_B,
                        PHASE_E_TENSOR_NONE,
                        PHASE_E_TENSOR_HIDDEN_A
                    );
                    value.src0_base = PHASE_E_ADDR_LINEAR_TMP;
                    value.src1_base = PHASE_E_ADDR_HIDDEN_B;
                    value.dst_base = PHASE_E_ADDR_HIDDEN_A;
                    value.dim0 = HIDDEN_WORDS;
                end

                default: begin
                    value.header.opcode = PHASE_E_OP_NOP;
                end
            endcase

            value.header.reserved = {
                PHASE_E_SECTION_ENCODER,
                selected_layer_index,
                2'b00
            };
            value.route.reserved = {3'd0, ordinal[4:0]};
            expected_command = value;
        end
    endfunction

    function automatic logic [4:0] expected_parameter_step(
        input integer request_ordinal
    );
        begin
            case (request_ordinal)
                0: expected_parameter_step = 5'd0;
                1: expected_parameter_step = 5'd1;
                2: expected_parameter_step = 5'd3;
                3: expected_parameter_step = 5'd5;
                4: expected_parameter_step = 5'd13;
                5: expected_parameter_step = 5'd15;
                6: expected_parameter_step = 5'd16;
                7: expected_parameter_step = 5'd18;
                default: expected_parameter_step = 5'h1f;
            endcase
        end
    endfunction

    function automatic logic parameter_step_expected(
        input logic [4:0] step
    );
        begin
            case (step)
                5'd0, 5'd1, 5'd3, 5'd5,
                5'd13, 5'd15, 5'd16, 5'd18:
                    parameter_step_expected = 1'b1;
                default:
                    parameter_step_expected = 1'b0;
            endcase
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
                $display(
                    "ERROR E03_REAL_LAYER_LOGICAL layer=%0d cycle=%0d command=%0d: %s",
                    selected_layer,
                    cycle_count,
                    command_count,
                    message
                );
                $fflush();
            end
        end
    endtask

    task automatic load_parameter_hex(
        input string tensor_suffix,
        input logic [31:0] local_base,
        input integer word_count
    );
        string parameter_filename;
        begin
            parameter_filename = $sformatf(
                "parameters/encoder_layer_%02d_%s_f32.hex",
                selected_layer,
                tensor_suffix
            );
            $readmemh(
                parameter_filename,
                model_memory,
                local_base,
                local_base + word_count - 1
            );
            loaded_parameter_file_count =
                loaded_parameter_file_count + 1;
        end
    endtask

    // A table response is legal only for the explicitly selected layer.
    assign layer_param_valid =
        layer_param_request &&
        (layer_param_index == selected_layer_index);
    assign layer_param_data = layer_param_valid
        ? selected_layer_params
        : '0;
    assign operand_load_ready = 1'b1;
    assign checkpoint_ready = 1'b1;
    // Inject a bounded deterministic stall window so the valid/payload hold
    // checker is exercised without penalizing the multi-hour full run.
    assign mem_req_ready =
        !response_pending &&
        !mem_rsp_valid &&
        ((cycle_count >= 64'd1024) || (cycle_count[2:0] != 3'b011));

    always_comb begin
        request_address_valid = logical_request_valid(
            mem_req_write,
            mem_req_space,
            mem_req_word_address,
            mem_req_write_strobe
        );
        if (
            !mem_req_write &&
            (request_address_valid === 1'b1)
        )
            request_read_data = read_logical_word(
                mem_req_space,
                mem_req_word_address
            );
        else
            request_read_data = 32'd0;
    end

    vit_phase_e_npu #(
        .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .PE_LANES(PE_LANES),
        .VECTOR_LANES(VECTOR_LANES),
        .SCRATCH_WORDS(SCRATCH_WORDS),
        .INPUT_WORDS(INPUT_BACKING_WORDS),
        .PARAM_WORDS(MODEL_PACKAGE_V1_WORDS)
    ) dut (
        .clk(clk),
        .rst(rst),
        .job_valid(job_valid),
        .job_ready(job_ready),
        .job(job),
        .global_params(global_params),
        .layer_param_request(layer_param_request),
        .layer_param_index(layer_param_index),
        .layer_param_valid(layer_param_valid),
        .layer_param_data(layer_param_data),
        .operand_load_request(operand_load_request),
        .operand_load_ready(operand_load_ready),
        .operand_load_command(operand_load_command),
        .checkpoint_valid(checkpoint_valid),
        .checkpoint_ready(checkpoint_ready),
        .checkpoint_phase(checkpoint_phase),
        .checkpoint_section(checkpoint_section),
        .checkpoint_layer(checkpoint_layer),
        .checkpoint_step(checkpoint_step),
        .checkpoint_tag(checkpoint_tag),
        .checkpoint_opcode(checkpoint_opcode),
        .checkpoint_dst_tensor(checkpoint_dst_tensor),
        .busy(busy),
        .done(done),
        .error(error),
        .error_code(error_code),
        .error_section(error_section),
        .error_layer(error_layer),
        .error_step(error_step),
        .input_write_enable(1'b0),
        .input_write_address(32'd0),
        .input_write_data(32'd0),
        .parameter_write_enable(1'b0),
        .parameter_write_address(32'd0),
        .parameter_write_data(32'd0),
        .scratch_write_enable(1'b0),
        .scratch_write_address(32'd0),
        .scratch_write_data(32'd0),
        .scratch_read_address(32'd0),
        .scratch_read_data(),
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_req_write(mem_req_write),
        .mem_req_space(mem_req_space),
        .mem_req_word_address(mem_req_word_address),
        .mem_req_write_data(mem_req_write_data),
        .mem_req_write_strobe(mem_req_write_strobe),
        .mem_rsp_valid(mem_rsp_valid),
        .mem_rsp_ready(mem_rsp_ready),
        .mem_rsp_read_data(mem_rsp_read_data),
        .mem_rsp_error(mem_rsp_error),
        .class_result_valid(class_result_valid),
        .class_index(class_index),
        .class_logit(class_logit)
    );

    assign descriptor_layer_param_valid =
        descriptor_layer_param_request &&
        (descriptor_layer_param_index == selected_layer_index);
    assign descriptor_layer_param_data = descriptor_layer_param_valid
        ? selected_layer_params
        : '0;

    vit_phase_e_sequencer descriptor_audit_sequencer (
        .clk(clk),
        .rst(rst),
        .job_valid(descriptor_job_valid),
        .job_ready(descriptor_job_ready),
        .job(descriptor_job),
        .global_params(global_params),
        .layer_param_request(descriptor_layer_param_request),
        .layer_param_index(descriptor_layer_param_index),
        .layer_param_valid(descriptor_layer_param_valid),
        .layer_param_data(descriptor_layer_param_data),
        .cmd_valid(descriptor_cmd_valid),
        .cmd_ready(1'b1),
        .cmd(descriptor_cmd),
        .cmd_done(1'b1),
        .cmd_error(1'b0),
        .checkpoint_valid(descriptor_checkpoint_valid),
        .checkpoint_ready(1'b1),
        .checkpoint_phase(descriptor_checkpoint_phase),
        .checkpoint_section(descriptor_checkpoint_section),
        .checkpoint_layer(descriptor_checkpoint_layer),
        .checkpoint_step(descriptor_checkpoint_step),
        .checkpoint_tag(descriptor_checkpoint_tag),
        .checkpoint_opcode(descriptor_checkpoint_opcode),
        .checkpoint_dst_tensor(descriptor_checkpoint_dst_tensor),
        .busy(),
        .done(descriptor_done),
        .error(descriptor_error),
        .error_code(),
        .error_section(),
        .error_layer(),
        .error_step()
    );

    always @(posedge clk) begin
        if (rst) begin
            descriptor_command_count <= 0;
            descriptor_checkpoint_count <= 0;
            descriptor_audit_complete <= 1'b0;
        end else begin
            if (descriptor_layer_param_request)
                check(
                    descriptor_layer_param_index == selected_layer_index,
                    "descriptor audit requests selected layer"
                );

            if (descriptor_cmd_valid) begin
                check(
                    descriptor_command_count < EXPECTED_COMMANDS,
                    "descriptor audit emits no command beyond step 19"
                );
                if (descriptor_command_count < EXPECTED_COMMANDS)
                    check(
                        descriptor_cmd === expected_command(
                            descriptor_command_count
                        ),
                        "descriptor audit matches exact 512-bit contract"
                    );
                descriptor_command_count <= descriptor_command_count + 1;
            end

            if (descriptor_checkpoint_valid) begin
                check(
                    descriptor_checkpoint_count < EXPECTED_COMMANDS,
                    "descriptor audit emits no checkpoint beyond step 19"
                );
                if (descriptor_checkpoint_count < EXPECTED_COMMANDS) begin
                    check(
                        descriptor_checkpoint_phase == PHASE_E_E03 &&
                        descriptor_checkpoint_section ==
                            PHASE_E_SECTION_ENCODER &&
                        descriptor_checkpoint_layer ==
                            selected_layer_index &&
                        descriptor_checkpoint_step ==
                            descriptor_checkpoint_count[4:0],
                        "descriptor-audit checkpoint context is exact"
                    );
                    check(
                        descriptor_checkpoint_tag ==
                            expected_command(
                                descriptor_checkpoint_count
                            ).header.tag &&
                        descriptor_checkpoint_opcode ==
                            expected_command(
                                descriptor_checkpoint_count
                            ).header.opcode &&
                        descriptor_checkpoint_dst_tensor ==
                            expected_command(
                                descriptor_checkpoint_count
                            ).route.dst_tensor,
                        "descriptor-audit checkpoint metadata is exact"
                    );
                end
                descriptor_checkpoint_count <=
                    descriptor_checkpoint_count + 1;
            end

            if (descriptor_done) begin
                check(!descriptor_error, "descriptor audit has no error");
                check(
                    descriptor_command_count == EXPECTED_COMMANDS,
                    "descriptor audit covers all twenty commands"
                );
                check(
                    descriptor_checkpoint_count == EXPECTED_COMMANDS,
                    "descriptor audit covers all twenty checkpoints"
                );
                descriptor_audit_complete <= 1'b1;
            end
        end
    end

    // One outstanding request and one registered response.  Every accepted
    // access is checked before data is returned or a write is committed.
    always @(posedge clk) begin
        if (rst) begin
            response_pending <= 1'b0;
            pending_write <= 1'b0;
            pending_address <= 32'd0;
            pending_write_data <= 32'd0;
            pending_read_data <= 32'd0;
            mem_rsp_valid <= 1'b0;
            mem_rsp_read_data <= 32'd0;
            mem_rsp_error <= 1'b0;
            accepted_request_count <= 64'd0;
            response_handshake_count <= 64'd0;
            write_request_accept_count <= 64'd0;
            read_transaction_count <= 64'd0;
            write_transaction_count <= 64'd0;
            parameter_read_count <= 64'd0;
            scratch_read_count <= 64'd0;
            input_read_count <= 64'd0;
            invalid_transaction_count <= 32'd0;
            parameter_min_address <= 32'hffff_ffff;
            parameter_max_address <= 32'd0;
            scratch_min_address <= 32'hffff_ffff;
            scratch_max_address <= 32'd0;
            scratch_write_min_address <= 32'hffff_ffff;
            scratch_write_max_address <= 32'd0;
            parameter_tensor_seen <= 16'd0;
            scratch_read_region_seen <= 8'd0;
            scratch_write_region_seen <= 8'd0;
        end else begin
            if (mem_rsp_valid && mem_rsp_ready) begin
                response_handshake_count <=
                    response_handshake_count + 1'b1;
                if (pending_write) begin
                    scratch_memory[pending_address] <=
                        pending_write_data;
                    write_transaction_count <=
                        write_transaction_count + 1'b1;
                end
                mem_rsp_valid <= 1'b0;
                mem_rsp_read_data <= 32'd0;
                mem_rsp_error <= 1'b0;
            end

            if (response_pending) begin
                mem_rsp_valid <= 1'b1;
                mem_rsp_read_data <= pending_read_data;
                mem_rsp_error <= 1'b0;
                response_pending <= 1'b0;
            end

            if (mem_req_valid && mem_req_ready) begin
                accepted_request_count <=
                    accepted_request_count + 1'b1;
                if (
                    ((^{mem_req_write,
                        mem_req_space,
                        mem_req_word_address}) === 1'bx) ||
                    (mem_req_write &&
                     ((^{mem_req_write_data,
                         mem_req_write_strobe}) === 1'bx))
                )
                    $fatal(
                        1,
                        "X/Z on accepted E03 logical-memory request"
                    );

                if (request_address_valid !== 1'b1) begin
                    invalid_transaction_count <=
                        invalid_transaction_count + 1'b1;
                    $fatal(
                        1,
                        "Invalid E03 layer-%0d request write=%0b space=%0d address=%08x strobe=%x",
                        selected_layer,
                        mem_req_write,
                        mem_req_space,
                        mem_req_word_address,
                        mem_req_write_strobe
                    );
                end

                pending_write <= mem_req_write;
                pending_address <= mem_req_word_address;
                pending_write_data <= mem_req_write_data;
                pending_read_data <= request_read_data;
                response_pending <= 1'b1;
                if (mem_req_write)
                    write_request_accept_count <=
                        write_request_accept_count + 1'b1;

                if (mem_req_space == PHASE_E_MEM_PARAM) begin
                    parameter_read_count <= parameter_read_count + 1'b1;
                    parameter_tensor_seen <=
                        parameter_tensor_seen |
                        parameter_tensor_onehot(mem_req_word_address);
                    if (mem_req_word_address < parameter_min_address)
                        parameter_min_address <= mem_req_word_address;
                    if (mem_req_word_address > parameter_max_address)
                        parameter_max_address <= mem_req_word_address;
                end else if (mem_req_space == PHASE_E_MEM_SCRATCH) begin
                    if (!mem_req_write) begin
                        scratch_read_count <= scratch_read_count + 1'b1;
                        scratch_read_region_seen <=
                            scratch_read_region_seen |
                            scratch_region_onehot(mem_req_word_address);
                    end else begin
                        scratch_write_region_seen <=
                            scratch_write_region_seen |
                            scratch_region_onehot(mem_req_word_address);
                    end
                    if (mem_req_word_address < scratch_min_address)
                        scratch_min_address <= mem_req_word_address;
                    if (mem_req_word_address > scratch_max_address)
                        scratch_max_address <= mem_req_word_address;
                    if (mem_req_write) begin
                        if (
                            mem_req_word_address <
                            scratch_write_min_address
                        )
                            scratch_write_min_address <=
                                mem_req_word_address;
                        if (
                            mem_req_word_address >
                            scratch_write_max_address
                        )
                            scratch_write_max_address <=
                                mem_req_word_address;
                    end
                end else if (mem_req_space == PHASE_E_MEM_INPUT) begin
                    input_read_count <= input_read_count + 1'b1;
                end

                if (!mem_req_write)
                    read_transaction_count <=
                        read_transaction_count + 1'b1;
            end
        end
    end

    // Requests must not change while the responder applies backpressure.
    always @(posedge clk) begin
        if (rst) begin
            stalled_request <= 1'b0;
            stalled_write <= 1'b0;
            stalled_space <= PHASE_E_MEM_NONE;
            stalled_address <= 32'd0;
            stalled_write_data <= 32'd0;
            stalled_write_strobe <= 4'd0;
            backpressure_cycle_count <= 64'd0;
        end else if (stalled_request) begin
            backpressure_cycle_count <= backpressure_cycle_count + 1'b1;
            check(
                mem_req_valid === 1'b1,
                "request valid remains asserted until handshake"
            );
            check(
                mem_req_write == stalled_write &&
                mem_req_space == stalled_space &&
                mem_req_word_address == stalled_address &&
                mem_req_write_data == stalled_write_data &&
                mem_req_write_strobe == stalled_write_strobe,
                "request payload remains stable until handshake"
            );
            if (mem_req_valid && mem_req_ready)
                stalled_request <= 1'b0;
        end else if (mem_req_valid && !mem_req_ready) begin
            backpressure_cycle_count <= backpressure_cycle_count + 1'b1;
            begin
                stalled_request <= 1'b1;
                stalled_write <= mem_req_write;
                stalled_space <= mem_req_space;
                stalled_address <= mem_req_word_address;
                stalled_write_data <= mem_req_write_data;
                stalled_write_strobe <= mem_req_write_strobe;
            end
        end
    end

    // Command, checkpoint and staging scoreboard.
    always @(posedge clk) begin
        if (rst) begin
            cycle_count <= 64'd0;
            command_count <= 0;
            checkpoint_count <= 0;
            parameter_request_count <= 0;
            parameter_step_seen <= 20'd0;
            layer_request_count <= 0;
            class_result_count <= 0;
            next_progress_cycle <= progress_cycle_interval;
            next_progress_transaction <= progress_transaction_interval;
        end else begin
            cycle_count <= cycle_count + 1'b1;

            if (layer_param_request) begin
                check(
                    layer_param_index == selected_layer_index,
                    "layer-table request selects only configured layer"
                );
            end

            if (dut.command_valid && dut.command_ready) begin
                check(
                    command_count < EXPECTED_COMMANDS,
                    "no command beyond the selected encoder layer"
                );
                if (command_count < EXPECTED_COMMANDS) begin
                    check(
                        dut.command === expected_command(command_count),
                        "all 512 command descriptor bits match encoder contract"
                    );
                    check(
                        dut.command.header.opcode ==
                            expected_opcode(command_count),
                        "command opcode follows encoder step order"
                    );
                    check(
                        dut.command.header.tag ==
                            JOB_TAG + command_count[7:0],
                        "command tag follows ordinal"
                    );
                    check(
                        dut.command.header.reserved[7:6] ==
                            PHASE_E_SECTION_ENCODER,
                        "command section is ENCODER"
                    );
                    check(
                        dut.command.header.reserved[5:2] ==
                            selected_layer_index,
                        "command layer matches configured layer"
                    );
                    check(
                        dut.command.route.reserved[4:0] ==
                            command_count[4:0],
                        "command step follows ordinal"
                    );
                    accepted_commands[command_count] <= dut.command;
                end
                command_count <= command_count + 1;
            end

            if (checkpoint_valid && checkpoint_ready) begin
                check(
                    checkpoint_count < EXPECTED_COMMANDS,
                    "no checkpoint beyond the selected encoder layer"
                );
                check(
                    checkpoint_phase == PHASE_E_E03,
                    "checkpoint phase is E03"
                );
                check(
                    checkpoint_section == PHASE_E_SECTION_ENCODER,
                    "checkpoint section is ENCODER"
                );
                check(
                    checkpoint_layer == selected_layer_index,
                    "checkpoint layer matches configured layer"
                );
                check(
                    checkpoint_step == checkpoint_count[4:0],
                    "checkpoint step is ordered"
                );
                if (checkpoint_count < EXPECTED_COMMANDS) begin
                    check(
                        checkpoint_count < command_count,
                        "checkpoint follows its accepted command"
                    );
                    check(
                        checkpoint_tag ==
                            accepted_commands[checkpoint_count].header.tag,
                        "checkpoint tag matches accepted descriptor"
                    );
                    check(
                        checkpoint_opcode ==
                            accepted_commands[checkpoint_count].header.opcode,
                        "checkpoint opcode matches accepted descriptor"
                    );
                    check(
                        checkpoint_dst_tensor ==
                            accepted_commands[checkpoint_count].
                                route.dst_tensor,
                        "checkpoint destination matches accepted descriptor"
                    );
                    check(
                        checkpoint_tag ==
                            expected_command(checkpoint_count).header.tag &&
                        checkpoint_opcode ==
                            expected_command(checkpoint_count).header.opcode &&
                        checkpoint_dst_tensor ==
                            expected_command(checkpoint_count).
                                route.dst_tensor,
                        "checkpoint metadata matches independent contract"
                    );
                end
                checkpoint_count <= checkpoint_count + 1;
            end

            if (operand_load_request && operand_load_ready) begin
                check(
                    parameter_request_count < EXPECTED_PARAMETER_REQUESTS,
                    "no operand request beyond eight parameter commands"
                );
                check(
                    operand_load_command.header.reserved[7:6] ==
                        PHASE_E_SECTION_ENCODER,
                    "operand request section is ENCODER"
                );
                check(
                    operand_load_command.header.reserved[5:2] ==
                        selected_layer_index,
                    "operand request selects configured layer"
                );
                check(
                    parameter_step_expected(
                        operand_load_command.route.reserved[4:0]
                    ),
                    "operand request is on a parameter-backed step"
                );
                if (
                    parameter_request_count <
                    EXPECTED_PARAMETER_REQUESTS
                ) begin
                    check(
                        operand_load_command.route.reserved[4:0] ==
                            expected_parameter_step(
                                parameter_request_count
                            ),
                        "operand request follows exact parameter-step order"
                    );
                    check(
                        !parameter_step_seen[
                            expected_parameter_step(
                                parameter_request_count
                            )
                        ],
                        "operand request step is unique"
                    );
                    check(
                        operand_load_command === expected_command(
                            expected_parameter_step(
                                parameter_request_count
                            )
                        ),
                        "operand request carries exact accepted descriptor"
                    );
                    parameter_step_seen[
                        expected_parameter_step(
                            parameter_request_count
                        )
                    ] <= 1'b1;
                end
                parameter_request_count <= parameter_request_count + 1;
            end

            if (layer_param_request && layer_param_valid)
                layer_request_count <= layer_request_count + 1;

            if (class_result_valid)
                class_result_count <= class_result_count + 1;

            if (busy && (cycle_count >= next_progress_cycle)) begin
                $display(
                    "E03_REAL_LAYER_LOGICAL_CYCLE_PROGRESS layer=%0d cycles=%0d commands=%0d checkpoints=%0d reads=%0d writes=%0d",
                    selected_layer,
                    cycle_count,
                    command_count,
                    checkpoint_count,
                    read_transaction_count,
                    write_transaction_count
                );
                $fflush();
                next_progress_cycle <=
                    next_progress_cycle + progress_cycle_interval;
            end

            if (
                busy &&
                (read_transaction_count >= next_progress_transaction)
            ) begin
                $display(
                    "E03_REAL_LAYER_LOGICAL_TRANSACTION_PROGRESS layer=%0d cycles=%0d commands=%0d reads=%0d writes=%0d parameter_reads=%0d scratch_reads=%0d",
                    selected_layer,
                    cycle_count,
                    command_count,
                    read_transaction_count,
                    write_transaction_count,
                    parameter_read_count,
                    scratch_read_count
                );
                $fflush();
                next_progress_transaction <=
                    next_progress_transaction +
                    progress_transaction_interval;
            end

            if (cycle_count >= WATCHDOG_CYCLES)
                $fatal(
                    1,
                    "E03 layer-%0d watchdog after %0d cycles",
                    selected_layer,
                    WATCHDOG_CYCLES
                );
        end
    end

    initial begin
        progress_cycle_interval = 50_000_000;
        progress_transaction_interval = 10_000_000;
        probe_cycle_limit = 0;
        progress_cycle_plusarg_status = $value$plusargs(
            "E03_LOGICAL_PROGRESS_CYCLES=%d",
            progress_cycle_interval
        );
        progress_transaction_plusarg_status = $value$plusargs(
            "E03_LOGICAL_PROGRESS_TRANSACTIONS=%d",
            progress_transaction_interval
        );
        probe_cycle_plusarg_status = $value$plusargs(
            "E03_LOGICAL_PROBE_CYCLES=%d",
            probe_cycle_limit
        );
        if (
            (progress_cycle_interval <= 0) ||
            (progress_transaction_interval <= 0) ||
            (probe_cycle_limit < 0)
        )
            $fatal(1, "E03 logical progress/probe configuration invalid");
        if (
            (EXPECTED_PARAMETER_READS != 64'd701_323_008) ||
            (EXPECTED_SCRATCH_READS != 64'd36_672_732) ||
            (EXPECTED_READS != 64'd737_995_740) ||
            (EXPECTED_WRITES != 4_876_932)
        )
            $fatal(
                1,
                "E03 traffic formula drift PARAM=%0d SCRATCH=%0d TOTAL=%0d WRITES=%0d",
                EXPECTED_PARAMETER_READS,
                EXPECTED_SCRATCH_READS,
                EXPECTED_READS,
                EXPECTED_WRITES
            );
    end

    initial begin
        descriptor_job_valid = 1'b0;
        wait (!rst);
        @(negedge clk);
        descriptor_job_valid = 1'b1;
        do begin
            @(posedge clk);
        end while (!descriptor_job_ready);
        @(negedge clk);
        descriptor_job_valid = 1'b0;
    end

    initial begin
        layer_plusarg_status = $value$plusargs(
            "E03_ENCODER_LAYER=%d",
            selected_layer
        );
        if (layer_plusarg_status != 1)
            $fatal(
                1,
                "Exactly one explicit +E03_ENCODER_LAYER=<1..11> selection is required"
            );
        if ((selected_layer < 1) || (selected_layer > 11))
            $fatal(
                1,
                "E03_ENCODER_LAYER must be an integer from 1 through 11, got %0d",
                selected_layer
            );

        selected_layer_index = selected_layer[3:0];
        selected_layer_base =
            LAYER0_MODEL_BASE + (selected_layer * LAYER_MODEL_WORDS);
        ln1_gamma_base = selected_layer_base + LN1_GAMMA_REL;
        ln1_beta_base = selected_layer_base + LN1_BETA_REL;
        q_weight_base = selected_layer_base + Q_WEIGHT_REL;
        q_bias_base = selected_layer_base + Q_BIAS_REL;
        k_weight_base = selected_layer_base + K_WEIGHT_REL;
        k_bias_base = selected_layer_base + K_BIAS_REL;
        v_weight_base = selected_layer_base + V_WEIGHT_REL;
        v_bias_base = selected_layer_base + V_BIAS_REL;
        o_weight_base = selected_layer_base + O_WEIGHT_REL;
        o_bias_base = selected_layer_base + O_BIAS_REL;
        ln2_gamma_base = selected_layer_base + LN2_GAMMA_REL;
        ln2_beta_base = selected_layer_base + LN2_BETA_REL;
        fc1_weight_base = selected_layer_base + FC1_WEIGHT_REL;
        fc1_bias_base = selected_layer_base + FC1_BIAS_REL;
        fc2_weight_base = selected_layer_base + FC2_WEIGHT_REL;
        fc2_bias_base = selected_layer_base + FC2_BIAS_REL;

        selected_layer_params = '0;
        selected_layer_params.ln1_gamma_base = ln1_gamma_base;
        selected_layer_params.ln1_beta_base = ln1_beta_base;
        selected_layer_params.q_weight_base = q_weight_base;
        selected_layer_params.q_bias_base = q_bias_base;
        selected_layer_params.k_weight_base = k_weight_base;
        selected_layer_params.k_bias_base = k_bias_base;
        selected_layer_params.v_weight_base = v_weight_base;
        selected_layer_params.v_bias_base = v_bias_base;
        selected_layer_params.o_weight_base = o_weight_base;
        selected_layer_params.o_bias_base = o_bias_base;
        selected_layer_params.ln2_gamma_base = ln2_gamma_base;
        selected_layer_params.ln2_beta_base = ln2_beta_base;
        selected_layer_params.fc1_weight_base = fc1_weight_base;
        selected_layer_params.fc1_bias_base = fc1_bias_base;
        selected_layer_params.fc2_weight_base = fc2_weight_base;
        selected_layer_params.fc2_bias_base = fc2_bias_base;

        previous_output_filename = $sformatf(
            "results/encoder_layer_%02d_step_20_layer_output_f32.hex",
            selected_layer - 1
        );
        golden_output_filename = $sformatf(
            "results/encoder_layer_%02d_step_20_layer_output_f32.hex",
            selected_layer
        );

        $display(
            "E03_REAL_LAYER_LOGICAL_RUN_CONFIG layer=%0d model_base=%08x progress_cycles=%0d progress_transactions=%0d probe_cycles=%0d plusarg_hits=%0d/%0d/%0d/%0d",
            selected_layer,
            selected_layer_base,
            progress_cycle_interval,
            progress_transaction_interval,
            probe_cycle_limit,
            layer_plusarg_status,
            progress_cycle_plusarg_status,
            progress_transaction_plusarg_status,
            probe_cycle_plusarg_status
        );
        $display(
            "E03_REAL_LAYER_LOGICAL_PRELOAD_BEGIN layer=%0d parameter_files=%0d predecessor=%s golden=%s",
            selected_layer,
            EXPECTED_PARAMETER_FILES,
            previous_output_filename,
            golden_output_filename
        );
        $fflush();

        $readmemh(
            previous_output_filename,
            scratch_memory,
            PHASE_E_ADDR_HIDDEN_A,
            PHASE_E_ADDR_HIDDEN_A + HIDDEN_WORDS - 1
        );
        $readmemh(golden_output_filename, golden_output);

        loaded_parameter_file_count = 0;
        load_parameter_hex(
            "ln_before_gamma", LN1_GAMMA_REL, HIDDEN_SIZE
        );
        load_parameter_hex(
            "ln_before_beta", LN1_BETA_REL, HIDDEN_SIZE
        );
        load_parameter_hex(
            "q_weight_B", Q_WEIGHT_REL, QKV_WEIGHT_WORDS
        );
        load_parameter_hex("q_bias", Q_BIAS_REL, HIDDEN_SIZE);
        load_parameter_hex(
            "k_weight_B", K_WEIGHT_REL, QKV_WEIGHT_WORDS
        );
        load_parameter_hex("k_bias", K_BIAS_REL, HIDDEN_SIZE);
        load_parameter_hex(
            "v_weight_B", V_WEIGHT_REL, QKV_WEIGHT_WORDS
        );
        load_parameter_hex("v_bias", V_BIAS_REL, HIDDEN_SIZE);
        load_parameter_hex(
            "o_weight_B", O_WEIGHT_REL, QKV_WEIGHT_WORDS
        );
        load_parameter_hex("o_bias", O_BIAS_REL, HIDDEN_SIZE);
        load_parameter_hex(
            "ln_after_gamma", LN2_GAMMA_REL, HIDDEN_SIZE
        );
        load_parameter_hex(
            "ln_after_beta", LN2_BETA_REL, HIDDEN_SIZE
        );
        load_parameter_hex(
            "fc1_weight_B", FC1_WEIGHT_REL, FC_WEIGHT_WORDS
        );
        load_parameter_hex(
            "fc1_bias", FC1_BIAS_REL, INTERMEDIATE_SIZE
        );
        load_parameter_hex(
            "fc2_weight_B", FC2_WEIGHT_REL, FC_WEIGHT_WORDS
        );
        load_parameter_hex("fc2_bias", FC2_BIAS_REL, HIDDEN_SIZE);
        if (loaded_parameter_file_count != EXPECTED_PARAMETER_FILES)
            $fatal(
                1,
                "Expected exactly %0d layer parameter files, loaded %0d",
                EXPECTED_PARAMETER_FILES,
                loaded_parameter_file_count
            );

        for (initialize_index = 0;
             initialize_index < HIDDEN_WORDS;
             initialize_index = initialize_index + 1) begin
            scratch_memory[
                PHASE_E_ADDR_HIDDEN_B + initialize_index
            ] = FP32_SENTINEL;
            scratch_memory[
                PHASE_E_ADDR_LINEAR_TMP + initialize_index
            ] = FP32_SENTINEL;
            scratch_memory[
                PHASE_E_ADDR_Q_HEAD + initialize_index
            ] = FP32_SENTINEL;
            scratch_memory[
                PHASE_E_ADDR_K_HEAD + initialize_index
            ] = FP32_SENTINEL;
            scratch_memory[
                PHASE_E_ADDR_V_HEAD + initialize_index
            ] = FP32_SENTINEL;
        end
        for (initialize_index = 0;
             initialize_index < SCORE_WORDS;
             initialize_index = initialize_index + 1)
            scratch_memory[
                PHASE_E_ADDR_SCORE_PROB + initialize_index
            ] = FP32_SENTINEL;
        for (initialize_index = 0;
             initialize_index < FC1_WORDS;
             initialize_index = initialize_index + 1)
            scratch_memory[
                PHASE_E_ADDR_FC1 + initialize_index
            ] = FP32_SENTINEL;

        $display(
            "E03_REAL_LAYER_LOGICAL_PRELOAD_DONE layer=%0d input_words=%0d parameter_files=%0d layer_backing_words=%0d golden_words=%0d",
            selected_layer,
            HIDDEN_WORDS,
            loaded_parameter_file_count,
            LAYER_MODEL_WORDS,
            HIDDEN_WORDS
        );
        $fflush();

        descriptor_job = '0;
        descriptor_job.phase = PHASE_E_E03;
        descriptor_job.first_layer = selected_layer_index;
        descriptor_job.last_layer = selected_layer_index;
        descriptor_job.class_softmax_enable = 1'b0;
        descriptor_job.checkpoint_enable = 1'b1;
        descriptor_job.job_tag = JOB_TAG;

        repeat (8)
            @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        job = '0;
        job.phase = PHASE_E_E03;
        job.first_layer = selected_layer_index;
        job.last_layer = selected_layer_index;
        job.class_softmax_enable = 1'b0;
        job.checkpoint_enable = 1'b1;
        job.job_tag = JOB_TAG;
        job.patch_a_base = 32'd0;
        global_params = '0;

        @(negedge clk);
        job_valid = 1'b1;
        do begin
            @(posedge clk);
        end while (!job_ready);
        @(negedge clk);
        job_valid = 1'b0;

        $display(
            "E03_REAL_LAYER_LOGICAL_STARTED layer=%0d cycle=%0d expected_commands=%0d expected_writes=%0d",
            selected_layer,
            cycle_count,
            EXPECTED_COMMANDS,
            EXPECTED_WRITES
        );
        $fflush();

        wait (done || error);
        #1;

        check(!error, "E03 completed without sequencer error");
        check(error_code == PHASE_E_ERROR_NONE, "error code is NONE");
        check(
            descriptor_audit_complete,
            "fast audit completed all twenty command descriptors"
        );
        check(command_count == EXPECTED_COMMANDS, "twenty commands issued");
        check(
            checkpoint_count == EXPECTED_COMMANDS,
            "twenty checkpoints observed"
        );
        check(
            parameter_request_count == EXPECTED_PARAMETER_REQUESTS,
            "eight parameter-bearing commands staged"
        );
        check(
            parameter_step_seen == EXPECTED_PARAMETER_STEP_MASK,
            "parameter requests cover each expected step exactly once"
        );
        check(
            layer_request_count == EXPECTED_LAYER_REQUESTS,
            "one layer-table request observed"
        );
        check(class_result_count == 0, "encoder emits no class result");

        check(
            accepted_request_count == EXPECTED_REQUESTS,
            "exact total logical-memory request count"
        );
        check(
            response_handshake_count == EXPECTED_REQUESTS,
            "exact total logical-memory response count"
        );
        check(
            write_request_accept_count == EXPECTED_WRITES,
            "every expected write request was accepted"
        );
        check(
            accepted_request_count == response_handshake_count,
            "no request remains outstanding at terminal state"
        );
        check(
            !response_pending && !mem_rsp_valid,
            "response channel is quiescent at terminal state"
        );
        check(
            !stalled_request,
            "request channel is quiescent at terminal state"
        );
        check(
            write_transaction_count == EXPECTED_WRITES,
            "exact encoder-layer scratch write count"
        );
        check(
            parameter_read_count == EXPECTED_PARAMETER_READS,
            "exact current-revision PARAM read traffic"
        );
        check(
            scratch_read_count == EXPECTED_SCRATCH_READS,
            "exact current-revision SCRATCH read traffic"
        );
        check(
            read_transaction_count == EXPECTED_READS,
            "exact current-revision total read traffic"
        );
        check(
            read_transaction_count ==
                parameter_read_count + scratch_read_count,
            "every read maps exactly to PARAM or SCRATCH"
        );
        check(input_read_count == 0, "E03 never reads INPUT");
        check(
            invalid_transaction_count == 0,
            "all logical-memory transactions are valid"
        );
        check(
            parameter_tensor_seen == 16'hffff,
            "all sixteen selected-layer parameter regions are read"
        );
        check(
            scratch_read_region_seen == 8'hff,
            "all eight encoder scratch regions are read"
        );
        check(
            scratch_write_region_seen == 8'hff,
            "all eight encoder scratch regions are written"
        );
        check(
            backpressure_cycle_count > 0,
            "valid/payload hold checker observed injected backpressure"
        );
        check(
            parameter_min_address == ln1_gamma_base,
            "PARAM minimum is selected-layer LN1 gamma"
        );
        check(
            parameter_max_address ==
                fc2_bias_base + HIDDEN_SIZE - 1,
            "PARAM maximum is selected-layer FC2 bias end"
        );
        check(
            scratch_min_address == EXPECTED_SCRATCH_MIN,
            "SCRATCH traffic minimum is HIDDEN_A"
        );
        check(
            scratch_max_address == EXPECTED_SCRATCH_MAX,
            "SCRATCH traffic maximum is FC1 end"
        );
        check(
            scratch_write_min_address == EXPECTED_SCRATCH_MIN,
            "SCRATCH write minimum is HIDDEN_A"
        );
        check(
            scratch_write_max_address == EXPECTED_SCRATCH_MAX,
            "SCRATCH write maximum is FC1 end"
        );

        exact_mismatches = 0;
        tolerance_failures = 0;
        unknown_failures = 0;
        nonfinite_failures = 0;
        max_error_index = 0;
        max_ratio_index = 0;
        max_error_rtl_word = 32'd0;
        max_error_golden_word = 32'd0;
        max_abs_error = 0.0;
        max_normalized_error = 0.0;
        sum_abs_error = 0.0;

        for (initialize_index = 0;
             initialize_index < HIDDEN_WORDS;
             initialize_index = initialize_index + 1) begin
            if (
                scratch_memory[
                    PHASE_E_ADDR_HIDDEN_A + initialize_index
                ] !== golden_output[initialize_index]
            )
                exact_mismatches = exact_mismatches + 1;

            if (
                $isunknown(
                    scratch_memory[
                        PHASE_E_ADDR_HIDDEN_A + initialize_index
                    ]
                ) ||
                $isunknown(golden_output[initialize_index])
            ) begin
                unknown_failures = unknown_failures + 1;
                tolerance_failures = tolerance_failures + 1;
            end else if (
                !fp32_is_finite(
                    scratch_memory[
                        PHASE_E_ADDR_HIDDEN_A + initialize_index
                    ]
                ) ||
                !fp32_is_finite(golden_output[initialize_index])
            ) begin
                nonfinite_failures = nonfinite_failures + 1;
                tolerance_failures = tolerance_failures + 1;
            end else begin
                rtl_value = fp32_to_real(
                    scratch_memory[
                        PHASE_E_ADDR_HIDDEN_A + initialize_index
                    ]
                );
                golden_value = fp32_to_real(golden_output[initialize_index]);
                absolute_error = rtl_value - golden_value;
                if (absolute_error < 0.0)
                    absolute_error = -absolute_error;
                allowed_error = golden_value;
                if (allowed_error < 0.0)
                    allowed_error = -allowed_error;
                allowed_error =
                    OUTPUT_ABS_TOLERANCE +
                    (OUTPUT_REL_TOLERANCE * allowed_error);
                normalized_error = absolute_error / allowed_error;
                sum_abs_error = sum_abs_error + absolute_error;
                if (absolute_error > max_abs_error) begin
                    max_abs_error = absolute_error;
                    max_error_index = initialize_index;
                    max_error_rtl_word =
                        scratch_memory[
                            PHASE_E_ADDR_HIDDEN_A + initialize_index
                        ];
                    max_error_golden_word =
                        golden_output[initialize_index];
                end
                if (normalized_error > max_normalized_error) begin
                    max_normalized_error = normalized_error;
                    max_ratio_index = initialize_index;
                end
                if (absolute_error > allowed_error)
                    tolerance_failures = tolerance_failures + 1;
            end
        end
        mean_abs_error = sum_abs_error / real'(HIDDEN_WORDS);

        $display(
            "E03_REAL_LAYER_LOGICAL_TRAFFIC layer=%0d reads=%0d writes=%0d parameter_reads=%0d scratch_reads=%0d input_reads=%0d invalid=%0d requests=%0d responses=%0d outstanding=%0d param_min=%08x param_max=%08x scratch_min=%08x scratch_max=%08x write_min=%08x write_max=%08x",
            selected_layer,
            read_transaction_count,
            write_transaction_count,
            parameter_read_count,
            scratch_read_count,
            input_read_count,
            invalid_transaction_count,
            accepted_request_count,
            response_handshake_count,
            accepted_request_count - response_handshake_count,
            parameter_min_address,
            parameter_max_address,
            scratch_min_address,
            scratch_max_address,
            scratch_write_min_address,
            scratch_write_max_address
        );
        $display(
            "E03_REAL_LAYER_LOGICAL_NUMERIC layer=%0d words=%0d exact_mismatch=%0d tolerance_failures=%0d unknown=%0d nonfinite=%0d max_abs=%0.9e mean_abs=%0.9e max_index=%0d max_ratio=%0.9e max_ratio_index=%0d rtl=%08x golden=%08x abs_tol=%0.9e rel_tol=%0.9e",
            selected_layer,
            HIDDEN_WORDS,
            exact_mismatches,
            tolerance_failures,
            unknown_failures,
            nonfinite_failures,
            max_abs_error,
            mean_abs_error,
            max_error_index,
            max_normalized_error,
            max_ratio_index,
            max_error_rtl_word,
            max_error_golden_word,
            OUTPUT_ABS_TOLERANCE,
            OUTPUT_REL_TOLERANCE
        );
        $fflush();

        check(unknown_failures == 0, "no X/Z output or golden word");
        check(nonfinite_failures == 0, "no NaN/Inf output or golden word");
        check(
            tolerance_failures == 0,
            "all 151296 outputs match documented absolute/relative tolerance"
        );

        if (failures == 0) begin
            $display(
                "VIT_PHASE_E_NPU_E03_REAL_LAYER_LOGICAL_RTL_E2E_PASS layer=%0d checks=%0d failures=0 cycles=%0d commands=%0d reads=%0d writes=%0d parameter_reads=%0d scratch_reads=%0d input_reads=%0d invalid=%0d requests=%0d responses=%0d outstanding=%0d tolerance_failures=%0d nonfinite=%0d unknown=%0d exact_mismatch=%0d max_abs=%0.9e mean_abs=%0.9e",
                selected_layer,
                checks,
                cycle_count,
                command_count,
                read_transaction_count,
                write_transaction_count,
                parameter_read_count,
                scratch_read_count,
                input_read_count,
                invalid_transaction_count,
                accepted_request_count,
                response_handshake_count,
                accepted_request_count - response_handshake_count,
                tolerance_failures,
                nonfinite_failures,
                unknown_failures,
                exact_mismatches,
                max_abs_error,
                mean_abs_error
            );
            $finish;
        end else begin
            $fatal(
                1,
                "VIT_PHASE_E_NPU_E03_REAL_LAYER_LOGICAL_RTL_E2E_FAIL layer=%0d checks=%0d failures=%0d commands=%0d",
                selected_layer,
                checks,
                failures,
                command_count
            );
        end
    end

    initial begin
        wait (!rst);
        if (probe_cycle_limit > 0) begin
            repeat (probe_cycle_limit)
                @(posedge clk);
            #1;
            check(
                error === 1'b0,
                "bounded probe has no sequencer error"
            );
            check(
                done === 1'b0,
                "bounded probe does not terminate the full layer early"
            );
            check(
                busy === 1'b1,
                "bounded probe observes the production NPU still busy"
            );
            check(
                invalid_transaction_count == 0,
                "bounded probe has no invalid logical-memory traffic"
            );
            check(
                layer_request_count == 1,
                "bounded probe accepted exactly one selected-layer request"
            );
            check(
                descriptor_audit_complete,
                "bounded probe completed all twenty descriptor checks"
            );
            check(
                backpressure_cycle_count > 0,
                "bounded probe exercised valid/payload backpressure hold"
            );
            check(
                accepted_request_count >= response_handshake_count,
                "bounded probe never observes a response without a request"
            );
            check(
                (accepted_request_count - response_handshake_count) <= 1,
                "bounded probe keeps at most one request outstanding"
            );
            if (failures != 0)
                $fatal(
                    1,
                    "E03 layer-%0d bounded probe failed",
                    selected_layer
                );
            $display(
                "VIT_PHASE_E_NPU_E03_REAL_LAYER_LOGICAL_RTL_PROBE_PASS layer=%0d cycles=%0d commands=%0d checkpoints=%0d layer_requests=%0d parameter_requests=%0d reads=%0d writes=%0d parameter_reads=%0d scratch_reads=%0d requests=%0d responses=%0d outstanding=%0d invalid=%0d backpressure_cycles=%0d checks=%0d failures=%0d",
                selected_layer,
                cycle_count,
                command_count,
                checkpoint_count,
                layer_request_count,
                parameter_request_count,
                read_transaction_count,
                write_transaction_count,
                parameter_read_count,
                scratch_read_count,
                accepted_request_count,
                response_handshake_count,
                accepted_request_count - response_handshake_count,
                invalid_transaction_count,
                backpressure_cycle_count,
                checks,
                failures
            );
            $fflush();
            $finish;
        end
    end

endmodule
