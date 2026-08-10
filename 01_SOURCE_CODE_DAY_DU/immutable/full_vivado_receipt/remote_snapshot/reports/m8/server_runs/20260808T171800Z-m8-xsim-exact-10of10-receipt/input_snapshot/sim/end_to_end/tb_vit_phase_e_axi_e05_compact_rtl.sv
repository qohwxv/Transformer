`timescale 1ns/1ps

// Production-hierarchy compact E05 test through the exact Vivado module-
// reference top.  Control travels over AXI4-Lite and every tensor access
// travels through the production AXI4 memory adapter into a three-region DDR
// model.  No behavioral engine or direct logical-memory seam is used.
module tb_vit_phase_e_axi_e05_compact_rtl #(
    parameter integer DUT_ARRAY_ROWS = 8,
    parameter integer DUT_ARRAY_COLS = 2,
    // Mode 1 preserves the promoted M5 blocked-FP32 path.  Mode 3 opts into
    // package-v3 packed-FP16 MODEL B plus FP16 GEMM compute.
    parameter integer DUT_EXECUTION_MODE = 1
);

    import vit_phase_e_pkg::*;

    localparam integer AXI_ADDR_WIDTH = 40;
    localparam integer AXI_ID_WIDTH = 1;

    localparam logic [31:0] E05_PATCH_COUNT = 32'd2;
    localparam logic [31:0] E05_TOKEN_COUNT = 32'd3;
    localparam logic [31:0] E05_HIDDEN_SIZE = 32'd16;
    localparam logic [31:0] E05_HEAD_COUNT = 32'd2;
    localparam logic [31:0] E05_HEAD_SIZE = 32'd8;
    localparam logic [31:0] E05_INTERMEDIATE_SIZE = 32'd16;
    localparam logic [31:0] E05_CLASS_COUNT = 32'd7;
    localparam logic [3:0] E05_ENCODER_LAYERS = 4'd12;
    localparam logic [31:0] E05_ATTN_SCALE_FP32 = 32'h3f80_0000;

    localparam integer PATCH_WORDS = 2 * 16;
    localparam integer HIDDEN_WORDS = 3 * 16;
    localparam integer HEAD_WORDS = 2 * 3 * 8;
    localparam integer SCORE_WORDS = 2 * 3 * 3;
    localparam integer FC1_WORDS = 3 * 16;
    localparam integer CLASS_WORDS = 7;

    localparam integer TARGET_CLASS = 3;
    localparam logic [7:0] JOB_TAG = 8'h80;
    localparam logic [31:0] FP32_POS_ZERO = 32'h0000_0000;
    localparam logic [31:0] FP32_ONE = 32'h3f80_0000;
    localparam logic [31:0] FP32_SEVEN = 32'h40e0_0000;
    localparam logic [31:0] FP32_SENTINEL = 32'hdead_beef;

    // M3 package-v2 compact layout.  Every tensor begins on a 32-word
    // (128-byte) boundary so each K16/N2 block is also naturally aligned.
    localparam logic [31:0] PATCH_WEIGHT_BASE = 32'd0;
    localparam logic [31:0] PATCH_BIAS_BASE = 32'd256;
    localparam logic [31:0] CLS_BASE = 32'd288;
    localparam logic [31:0] POSITION_BASE = 32'd320;
    localparam logic [31:0] FINAL_LN_GAMMA_BASE = 32'd384;
    localparam logic [31:0] FINAL_LN_BETA_BASE = 32'd416;
    localparam logic [31:0] CLASSIFIER_WEIGHT_BASE = 32'd448;
    localparam logic [31:0] CLASSIFIER_BIAS_BASE = 32'd576;
    localparam integer CLASSIFIER_BLOCKED_WORDS =
        ((16 + 15) / 16) * ((7 + 1) / 2) * 32;
    localparam integer CLASSIFIER_PACKED_WORDS =
        ((16 + 15) / 16) * ((7 + 1) / 2) * 16;

    localparam logic [31:0] LAYER_PARAM_BASE = 32'd1024;
    localparam logic [31:0] LAYER_PARAM_STRIDE = 32'd2048;
    localparam logic [31:0] LAYER_LN1_GAMMA_OFFSET = 32'd0;
    localparam logic [31:0] LAYER_LN1_BETA_OFFSET = 32'd32;
    localparam logic [31:0] LAYER_Q_WEIGHT_OFFSET = 32'd64;
    localparam logic [31:0] LAYER_Q_BIAS_OFFSET = 32'd320;
    localparam logic [31:0] LAYER_K_WEIGHT_OFFSET = 32'd352;
    localparam logic [31:0] LAYER_K_BIAS_OFFSET = 32'd608;
    localparam logic [31:0] LAYER_V_WEIGHT_OFFSET = 32'd640;
    localparam logic [31:0] LAYER_V_BIAS_OFFSET = 32'd896;
    localparam logic [31:0] LAYER_O_WEIGHT_OFFSET = 32'd928;
    localparam logic [31:0] LAYER_O_BIAS_OFFSET = 32'd1184;
    localparam logic [31:0] LAYER_LN2_GAMMA_OFFSET = 32'd1216;
    localparam logic [31:0] LAYER_LN2_BETA_OFFSET = 32'd1248;
    localparam logic [31:0] LAYER_FC1_WEIGHT_OFFSET = 32'd1280;
    localparam logic [31:0] LAYER_FC1_BIAS_OFFSET = 32'd1536;
    localparam logic [31:0] LAYER_FC2_WEIGHT_OFFSET = 32'd1568;
    localparam logic [31:0] LAYER_FC2_BIAS_OFFSET = 32'd1824;

    localparam integer MODEL_WORDS = 32768;
    localparam integer INPUT_WORDS = PATCH_WORDS;
    localparam integer SCRATCH_WORDS = PHASE_E_SCRATCH_WORDS;

    localparam logic [63:0] MODEL_BASE = 64'h0000_0010_0000_0000;
    localparam logic [63:0] INPUT_BASE = 64'h0000_0020_0000_0000;
    localparam logic [63:0] SCRATCH_BASE = 64'h0000_0030_0000_0000;

    localparam integer EXPECTED_READS = 57819;
    localparam integer EXPECTED_R4_READS = 38235;
    // The compact classifier has seven columns.  Its final blocked K16/N2
    // line physically contains one padded column (16 words), so the M5
    // adapter fetches 38,235 useful words plus 16 explicitly counted unused
    // tail words.  The production 1,000-column classifier has no odd-N pad.
    localparam integer EXPECTED_R8_READS = 38251;
    // The controlled S8 fallback executes the two logical R8xC2 columns as
    // ordered R8xC1 physical passes.  The compact fixture therefore performs
    // 1,175 persistent MODEL-B passes and 264 row-major scratch-B passes.
    // This is the exact first-run S8 payload oracle; unlike the S16 parent it
    // intentionally includes the second-column pass traffic.
    localparam integer EXPECTED_PACKED_R8_READS = 35139;
    localparam integer EXPECTED_PACKED_R8_LOGICAL_READS = 91403;
    localparam integer EXPECTED_PACKED_R8_CORE_HITS = 55080;
    localparam integer EXPECTED_PACKED_R8_LINE_STARTS = 1299;
    localparam integer EXPECTED_PACKED_R8_LINE_HITS = 20669;
    localparam integer EXPECTED_WRITES =
        128 + (12 * 870) + 78;
    localparam logic [31:0] EXPECTED_MODEL_MAX_WORD =
        LAYER_PARAM_BASE + (11 * LAYER_PARAM_STRIDE) +
        LAYER_FC2_BIAS_OFFSET + 15;
    localparam logic [31:0] EXPECTED_SCRATCH_MAX_WORD =
        PHASE_E_ADDR_CLASS_PROB + CLASS_WORDS - 1;
    localparam integer WATCHDOG_CYCLES = 5_000_000;

    localparam logic [1:0] AXI_RESP_OKAY = 2'b00;

    localparam logic [11:0] REG_IP_ID = 12'h000;
    localparam logic [11:0] REG_IP_VERSION = 12'h004;
    localparam logic [11:0] REG_CONTROL = 12'h008;
    localparam logic [11:0] REG_STATUS = 12'h00c;
    localparam logic [11:0] REG_IRQ_ENABLE = 12'h010;
    localparam logic [11:0] REG_IRQ_STATUS = 12'h014;
    localparam logic [11:0] REG_ERROR_CODE = 12'h018;
    localparam logic [11:0] REG_ERROR_INFO = 12'h01c;
    localparam logic [11:0] REG_MODEL_BASE_LO = 12'h020;
    localparam logic [11:0] REG_MODEL_BASE_HI = 12'h024;
    localparam logic [11:0] REG_INPUT_BASE_LO = 12'h028;
    localparam logic [11:0] REG_INPUT_BASE_HI = 12'h02c;
    localparam logic [11:0] REG_SCRATCH_BASE_LO = 12'h030;
    localparam logic [11:0] REG_SCRATCH_BASE_HI = 12'h034;
    localparam logic [11:0] REG_MODEL_WORDS = 12'h038;
    localparam logic [11:0] REG_INPUT_WORDS = 12'h03c;
    localparam logic [11:0] REG_SCRATCH_WORDS = 12'h040;
    localparam logic [11:0] REG_EXECUTION_MODE = 12'h044;
    localparam logic [11:0] REG_PERF_CAPABILITY = 12'h048;
    localparam logic [11:0] REG_PERF_STATUS = 12'h04c;
    localparam logic [11:0] REG_JOB_CYCLES_LO = 12'h050;
    localparam logic [11:0] REG_COMMANDS_LO = 12'h058;
    localparam logic [11:0] REG_AXI_READS_LO = 12'h060;
    localparam logic [11:0] REG_AXI_WRITES_LO = 12'h068;
    localparam logic [11:0] REG_AXI_STALL_LO = 12'h070;
    localparam logic [11:0] REG_GLOBAL_BASE = 12'h080;
    localparam logic [11:0] REG_JOB_CONFIG = 12'h0a0;
    localparam logic [11:0] REG_JOB_PATCH_BASE = 12'h0a4;
    localparam logic [11:0] REG_CLASS_INDEX = 12'h180;
    localparam logic [11:0] REG_CLASS_LOGIT = 12'h184;
    localparam logic [11:0] REG_PROFILE_CAP2 = 12'h188;
    localparam logic [11:0] REG_PROFILE_STATUS2 = 12'h18c;
    localparam logic [11:0] REG_PROFILE_OVF_LO = 12'h190;
    localparam logic [11:0] REG_PROFILE_OVF_HI = 12'h194;
    localparam logic [11:0] REG_OPCODE_COUNT_OVF = 12'h198;
    localparam logic [11:0] REG_OPCODE_CYCLE_OVF = 12'h19c;
    localparam logic [11:0] REG_PROFILE_GLOBAL_BASE = 12'h1a0;
    localparam logic [11:0] REG_PROFILE_OPCODE_BASE = 12'h300;
    localparam logic [11:0] REG_LAYER_BASE = 12'h400;
    localparam logic [11:0] REG_TRACE_CAPABILITY = 12'h700;
    localparam logic [11:0] REG_TRACE_SELECT = 12'h704;
    localparam logic [11:0] REG_TRACE_STATUS = 12'h708;
    localparam logic [11:0] REG_TRACE_META = 12'h70c;
    localparam logic [11:0] REG_TRACE_CYCLES_LO = 12'h710;
    localparam logic [11:0] REG_TRACE_COUNT = 12'h718;
    localparam logic [11:0] REG_PROFILE_ERROR = 12'h71c;
    localparam logic [11:0] REG_HIST_CAPABILITY = 12'h720;
    localparam logic [11:0] REG_HIST_OVERFLOW = 12'h724;
    localparam logic [11:0] REG_HIST_BASE = 12'h728;
    localparam logic [11:0] REG_M5_CAPABILITY = 12'h7c0;
    localparam logic [11:0] REG_M5_STATUS = 12'h7c4;
    localparam logic [11:0] REG_M5_OVERFLOW = 12'h7c8;
    localparam logic [11:0] REG_M5_PROTOCOL = 12'h7cc;
    localparam logic [11:0] REG_M5_COUNTER_BASE = 12'h7d0;
    localparam logic [11:0] REG_M7_CAPABILITY = 12'h810;
    localparam logic [11:0] REG_M7_STATUS = 12'h814;
    localparam logic [11:0] REG_M7_OVF_LO = 12'h818;
    localparam logic [11:0] REG_M7_OVF_HI = 12'h81c;
    localparam logic [11:0] REG_M7_ERROR = 12'h820;
    localparam logic [11:0] REG_M7_GEOMETRY = 12'h824;
    localparam logic [11:0] REG_M7_BUFFER_CONFIG = 12'h828;
    localparam logic [11:0] REG_M7_NUMERIC_CONFIG = 12'h82c;
    localparam logic [11:0] REG_M7_COUNTER_BASE = 12'h830;

    localparam integer MAC_SLOTS_PER_TILE =
        DUT_ARRAY_ROWS * DUT_ARRAY_COLS * 16;
    localparam integer M7_S8_MAC_SLOTS_PER_PASS = DUT_ARRAY_ROWS * 16;

    logic aclk = 1'b0;
    logic aresetn = 1'b0;

    logic [11:0] s_axi_awaddr = 12'd0;
    logic [2:0] s_axi_awprot = 3'd0;
    logic s_axi_awvalid = 1'b0;
    logic s_axi_awready;
    logic [31:0] s_axi_wdata = 32'd0;
    logic [3:0] s_axi_wstrb = 4'd0;
    logic s_axi_wvalid = 1'b0;
    logic s_axi_wready;
    logic [1:0] s_axi_bresp;
    logic s_axi_bvalid;
    logic s_axi_bready = 1'b0;
    logic [11:0] s_axi_araddr = 12'd0;
    logic [2:0] s_axi_arprot = 3'd0;
    logic s_axi_arvalid = 1'b0;
    logic s_axi_arready;
    logic [31:0] s_axi_rdata;
    logic [1:0] s_axi_rresp;
    logic s_axi_rvalid;
    logic s_axi_rready = 1'b0;

    logic [AXI_ID_WIDTH-1:0] m_axi_awid;
    logic [AXI_ADDR_WIDTH-1:0] m_axi_awaddr;
    logic [7:0] m_axi_awlen;
    logic [2:0] m_axi_awsize;
    logic [1:0] m_axi_awburst;
    logic m_axi_awlock;
    logic [3:0] m_axi_awcache;
    logic [2:0] m_axi_awprot;
    logic [3:0] m_axi_awqos;
    logic m_axi_awvalid;
    logic m_axi_awready;
    logic [127:0] m_axi_wdata;
    logic [15:0] m_axi_wstrb;
    logic m_axi_wlast;
    logic m_axi_wvalid;
    logic m_axi_wready;
    logic [AXI_ID_WIDTH-1:0] m_axi_bid;
    logic [1:0] m_axi_bresp;
    logic m_axi_bvalid;
    logic m_axi_bready;
    logic [AXI_ID_WIDTH-1:0] m_axi_arid;
    logic [AXI_ADDR_WIDTH-1:0] m_axi_araddr;
    logic [7:0] m_axi_arlen;
    logic [2:0] m_axi_arsize;
    logic [1:0] m_axi_arburst;
    logic m_axi_arlock;
    logic [3:0] m_axi_arcache;
    logic [2:0] m_axi_arprot;
    logic [3:0] m_axi_arqos;
    logic m_axi_arvalid;
    logic m_axi_arready;
    logic [AXI_ID_WIDTH-1:0] m_axi_rid;
    logic [127:0] m_axi_rdata;
    logic [1:0] m_axi_rresp;
    logic m_axi_rlast;
    logic m_axi_rvalid;
    logic m_axi_rready;
    logic irq_o;

    logic [63:0] ddr_read_count;
    logic [63:0] ddr_write_count;
    logic [63:0] model_read_count;
    logic [63:0] input_read_count;
    logic [63:0] scratch_read_count;
    logic [63:0] scratch_write_count;
    logic [63:0] ddr_ar_transaction_count;
    logic [63:0] ddr_aw_transaction_count;
    logic [63:0] ddr_r_beat_count;
    logic [63:0] ddr_w_beat_count;
    logic [63:0] ddr_b_response_count;
    logic [63:0] ddr_ar_requested_beat_count;
    logic [63:0] ddr_aw_requested_beat_count;
    logic [31:0] ddr_protocol_error_count;
    logic [31:0] ddr_four_kib_error_count;
    logic [31:0] ddr_read_outstanding;
    logic [31:0] ddr_write_outstanding;
    logic [31:0] ddr_read_outstanding_high_water;
    logic [31:0] invalid_access_count;

    longint cycle_count = 0;
    integer checks = 0;
    integer failures = 0;
    integer checkpoint_count = 0;
    integer layer_request_count = 0;
    integer parameter_request_count = 0;
    integer class_result_count = 0;
    integer gemm_command_count = 0;
    integer blocked_model_gemm_count = 0;
    integer packed_model_gemm_count = 0;
    integer fp16_gemm_count = 0;
    integer fp16_scratch_gemm_count = 0;
    integer row_major_scratch_gemm_count = 0;
    integer gemm_layout_monitor_failures = 0;
    integer packed_model_tile_load_count = 0;
    integer nonpacked_tile_load_count = 0;
    integer gemm_read_contract_failures = 0;
    integer m7_load_result_conflict_cycles = 0;
    integer m7_idle_load_result_conflict_cycles = 0;
    integer m7_result_queued_compute_cycles = 0;
    integer m7_data_deliver_result_queued_cycles = 0;
    integer initialize_index;
    integer layer_index;
    integer slot_index;
    integer verify_index;
    logic [1:0] response;
    logic [31:0] read_data;
    logic [31:0] job_config_value;
    logic perf_monitor_running = 1'b0;
    logic [63:0] monitored_job_cycles = 64'd0;
    logic [63:0] monitored_axi_stall_cycles = 64'd0;
    logic [63:0] perf_read_value;
    logic [63:0] profile_global_value [0:PHASE_E_PROFILE_GLOBAL_COUNT-1];
    logic [63:0] profile_opcode_count [0:PHASE_E_PROFILE_OPCODE_SLOTS-1];
    logic [63:0] profile_opcode_cycles [0:PHASE_E_PROFILE_OPCODE_SLOTS-1];
    logic [63:0] profile_histogram [0:PHASE_E_PROFILE_HIST_COUNT-1];
    logic [63:0] m5_axi_counter [0:7];
    logic [63:0] m7_counter [0:PHASE_E_M7_COUNTER_COUNT-1];
    logic [31:0] m7_status_value;
    logic [63:0] profile_opcode_count_sum;
    logic [63:0] profile_opcode_cycle_sum;
    logic [63:0] profile_read_histogram_sum;
    logic [63:0] profile_write_histogram_sum;
    logic [31:0] profile_trace_meta;
    logic [63:0] profile_trace_cycles;
    logic [63:0] profile_trace_duration_sum;
    logic [63:0] profile_trace_opcode_count
        [0:PHASE_E_PROFILE_OPCODE_SLOTS-1];
    integer profile_trace_failures;
    integer profile_index;

    always #1 aclk = ~aclk;

    always @(posedge aclk) begin
        cycle_count <= cycle_count + 1'b1;
        if (!aresetn) begin
            checkpoint_count <= 0;
            layer_request_count <= 0;
            parameter_request_count <= 0;
            class_result_count <= 0;
            gemm_command_count <= 0;
            blocked_model_gemm_count <= 0;
            packed_model_gemm_count <= 0;
            fp16_gemm_count <= 0;
            fp16_scratch_gemm_count <= 0;
            row_major_scratch_gemm_count <= 0;
            gemm_layout_monitor_failures <= 0;
            packed_model_tile_load_count <= 0;
            nonpacked_tile_load_count <= 0;
            gemm_read_contract_failures <= 0;
            m7_load_result_conflict_cycles <= 0;
            m7_idle_load_result_conflict_cycles <= 0;
            m7_result_queued_compute_cycles <= 0;
            m7_data_deliver_result_queued_cycles <= 0;
            perf_monitor_running <= 1'b0;
            monitored_job_cycles <= 64'd0;
            monitored_axi_stall_cycles <= 64'd0;
        end else begin
            if (dut.u_core.checkpoint_valid)
                checkpoint_count <= checkpoint_count + 1;
            if (
                dut.u_core.layer_param_request
                && dut.u_core.layer_param_valid
            )
                layer_request_count <= layer_request_count + 1;
            if (dut.u_core.operand_load_request)
                parameter_request_count <= parameter_request_count + 1;
            if (dut.u_core.class_result_valid)
                class_result_count <= class_result_count + 1;

            // The accepted descriptor itself is the authority for whether a
            // GEMM consumes package-v2 MODEL weights or a row-major SCRATCH
            // matrix.  E05 must contain 74/24 of these respectively.
            if (
                dut.u_core.npu_command_accept &&
                (dut.u_core.u_npu.command.header.opcode == PHASE_E_OP_GEMM)
            ) begin
                gemm_command_count <= gemm_command_count + 1;
                if ((dut.u_core.u_npu.command.header.flags &
                     PHASE_E_FLAG_GEMM_FP16) != 0)
                    fp16_gemm_count <= fp16_gemm_count + 1;
                if ((dut.u_core.u_npu.command.header.flags &
                     PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2) != 0) begin
                    blocked_model_gemm_count <=
                        blocked_model_gemm_count + 1;
                    if ((dut.u_core.u_npu.command.header.flags &
                         PHASE_E_FLAG_GEMM_B_FP16_PACKED2) != 0)
                        packed_model_gemm_count <=
                            packed_model_gemm_count + 1;
                    if (
                        (dut.u_core.u_npu.command.route.src1_tensor !=
                         PHASE_E_TENSOR_WEIGHT) ||
                        (dut.u_core.u_npu.command.route.src1_space !=
                         PHASE_E_MEM_PARAM)
                    )
                        gemm_layout_monitor_failures <=
                            gemm_layout_monitor_failures + 1;
                end else begin
                    row_major_scratch_gemm_count <=
                        row_major_scratch_gemm_count + 1;
                    if ((dut.u_core.u_npu.command.header.flags &
                         PHASE_E_FLAG_GEMM_FP16) != 0)
                        fp16_scratch_gemm_count <=
                            fp16_scratch_gemm_count + 1;
                    if (
                        dut.u_core.u_npu.command.route.src1_space !=
                        PHASE_E_MEM_SCRATCH
                    )
                        gemm_layout_monitor_failures <=
                            gemm_layout_monitor_failures + 1;
                end
            end

            // One data_valid pulse retires one complete GEMM input tile.
            // Check the dispatch/frontend word contract at that exact seam:
            // A128+B16+bias2 for packed MODEL B, versus A128+B32+bias2 for
            // legacy blocked MODEL B and row-major SCRATCH B.
            if (dut.u_core.u_npu.u_engine.gemm_data_valid) begin
                if ((dut.u_core.u_npu.u_engine.active_cmd.header.flags &
                     PHASE_E_FLAG_GEMM_B_FP16_PACKED2) != 0) begin
                    packed_model_tile_load_count <=
                        packed_model_tile_load_count + 1;
                    if (dut.u_core.u_npu.u_engine.read_word_count != 16'd146)
                        gemm_read_contract_failures <=
                            gemm_read_contract_failures + 1;
                end else begin
                    nonpacked_tile_load_count <=
                        nonpacked_tile_load_count + 1;
                    if (dut.u_core.u_npu.u_engine.read_word_count != 16'd162)
                        gemm_read_contract_failures <=
                            gemm_read_contract_failures + 1;
                end
            end

            if (
                dut.u_core.u_npu.u_engine.gemm_data_request &&
                dut.u_core.u_npu.u_engine.gemm_result_valid
            )
                m7_load_result_conflict_cycles <=
                    m7_load_result_conflict_cycles + 1;
            if (
                (dut.u_core.u_npu.u_engine.u_memory_frontend.mem_state == 0) &&
                dut.u_core.u_npu.u_engine.gemm_data_request &&
                dut.u_core.u_npu.u_engine.gemm_result_valid
            )
                m7_idle_load_result_conflict_cycles <=
                    m7_idle_load_result_conflict_cycles + 1;
            if (
                dut.u_core.u_npu.u_engine.gemm_result_valid &&
                dut.u_core.u_npu.u_engine.profile_m7_compute_active
            )
                m7_result_queued_compute_cycles <=
                    m7_result_queued_compute_cycles + 1;
            if (
                dut.u_core.u_npu.u_engine.gemm_data_valid &&
                dut.u_core.u_npu.u_engine.gemm_result_valid
            )
                m7_data_deliver_result_queued_cycles <=
                    m7_data_deliver_result_queued_cycles + 1;

            if (dut.u_core.perf_start_accept) begin
                perf_monitor_running <= 1'b1;
                monitored_job_cycles <= 64'd0;
                monitored_axi_stall_cycles <= 64'd0;
            end else if (perf_monitor_running) begin
                monitored_job_cycles <= monitored_job_cycles + 64'd1;
                if (
                    (m_axi_arvalid && !m_axi_arready) ||
                    (m_axi_awvalid && !m_axi_awready) ||
                    (m_axi_wvalid && !m_axi_wready)
                )
                    monitored_axi_stall_cycles <=
                        monitored_axi_stall_cycles + 64'd1;
                if (dut.u_core.npu_done)
                    perf_monitor_running <= 1'b0;
            end
        end
    end

    task automatic check(
        input logic condition,
        input string message
    );
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                failures = failures + 1;
                // Accumulate all contract failures so a burst-semantics
                // migration exposes the complete mismatch set in one run.
                // The test still terminates with $fatal below when nonzero.
                $display("CHECK FAILED: %s", message);
            end
        end
    endtask

    function automatic logic word_base_is_128_aligned(
        input logic [31:0] word_base
    );
        begin
            word_base_is_128_aligned = (word_base[4:0] == 5'd0);
        end
    endfunction

    task automatic initialize_blocked_weight(
        input integer tensor_base,
        input integer reduction_size,
        input integer output_size
    );
        integer n_tile;
        integer k_chunk;
        integer column;
        integer lane;
        integer n_tiles;
        integer k_chunks;
        integer tensor_word;
        begin
            n_tiles = (output_size + 1) / 2;
            k_chunks = (reduction_size + 15) / 16;
            for (n_tile = 0; n_tile < n_tiles;
                 n_tile = n_tile + 1)
                for (k_chunk = 0; k_chunk < k_chunks;
                     k_chunk = k_chunk + 1)
                    for (column = 0; column < 2;
                         column = column + 1)
                        for (lane = 0; lane < 16;
                             lane = lane + 1) begin
                            tensor_word = tensor_base +
                                ((((n_tile * k_chunks) + k_chunk) * 2 +
                                  column) * 16) + lane;
                            if (
                                ((n_tile * 2 + column) < output_size) &&
                                ((k_chunk * 16 + lane) < reduction_size)
                            )
                                u_ddr.model_memory[tensor_word] = FP32_ONE;
                            else
                                u_ddr.model_memory[tensor_word] =
                                    FP32_POS_ZERO;
                        end
        end
    endtask

    // Package-v3 physical order is [N_TILE][K_CHUNK][LANE], one u32 per
    // lane.  The low half stores column 0 and the high half column 1.
    task automatic initialize_packed_fp16_weight(
        input integer tensor_base,
        input integer reduction_size,
        input integer output_size
    );
        integer n_tile;
        integer k_chunk;
        integer lane;
        integer n_tiles;
        integer k_chunks;
        integer tensor_word;
        logic [15:0] column0_half;
        logic [15:0] column1_half;
        begin
            n_tiles = (output_size + 1) / 2;
            k_chunks = (reduction_size + 15) / 16;
            for (n_tile = 0; n_tile < n_tiles;
                 n_tile = n_tile + 1)
                for (k_chunk = 0; k_chunk < k_chunks;
                     k_chunk = k_chunk + 1)
                    for (lane = 0; lane < 16;
                         lane = lane + 1) begin
                        tensor_word = tensor_base +
                            (((n_tile * k_chunks) + k_chunk) * 16) + lane;
                        column0_half =
                            (((n_tile * 2) < output_size) &&
                             ((k_chunk * 16 + lane) < reduction_size)) ?
                                16'h3c00 : 16'h0000;
                        column1_half =
                            (((n_tile * 2 + 1) < output_size) &&
                             ((k_chunk * 16 + lane) < reduction_size)) ?
                                16'h3c00 : 16'h0000;
                        u_ddr.model_memory[tensor_word] =
                            {column1_half, column0_half};
                    end
        end
    endtask

    task automatic initialize_persistent_weight(
        input integer tensor_base,
        input integer reduction_size,
        input integer output_size
    );
        begin
            if (DUT_EXECUTION_MODE == 3)
                initialize_packed_fp16_weight(
                    tensor_base,
                    reduction_size,
                    output_size
                );
            else
                initialize_blocked_weight(
                    tensor_base,
                    reduction_size,
                    output_size
                );
        end
    endtask

    task automatic axi_lite_read64(
        input logic [11:0] low_address,
        output logic [63:0] data
    );
        logic [31:0] low_word;
        logic [31:0] high_word;
        begin
            axi_lite_read(low_address, low_word);
            axi_lite_read(low_address + 12'h004, high_word);
            data = {high_word, low_word};
        end
    endtask

    task automatic profile_global_read(
        input integer counter_index,
        output logic [63:0] counter_value
    );
        logic [11:0] counter_address;
        begin
            counter_address = REG_PROFILE_GLOBAL_BASE +
                (counter_index * 12'h008);
            axi_lite_read64(counter_address, counter_value);
        end
    endtask

    task automatic profile_opcode_read(
        input integer opcode_index,
        output logic [63:0] count_value,
        output logic [63:0] cycle_value
    );
        logic [11:0] opcode_address;
        begin
            opcode_address = REG_PROFILE_OPCODE_BASE +
                (opcode_index * 12'h010);
            axi_lite_read64(opcode_address, count_value);
            axi_lite_read64(opcode_address + 12'h008, cycle_value);
        end
    endtask

    task automatic profile_histogram_read(
        input integer histogram_index,
        output logic [63:0] histogram_value
    );
        logic [11:0] histogram_address;
        begin
            histogram_address = REG_HIST_BASE +
                (histogram_index * 12'h008);
            axi_lite_read64(histogram_address, histogram_value);
        end
    endtask

    task automatic axi_lite_write(
        input logic [11:0] address,
        input logic [31:0] data
    );
        logic aw_done;
        logic w_done;
        begin
            aw_done = 1'b0;
            w_done = 1'b0;
            @(negedge aclk);
            s_axi_awaddr = address;
            s_axi_awvalid = 1'b1;
            s_axi_wdata = data;
            s_axi_wstrb = 4'hf;
            s_axi_wvalid = 1'b1;

            while (!aw_done || !w_done) begin
                @(posedge aclk);
                if (s_axi_awvalid && s_axi_awready)
                    aw_done = 1'b1;
                if (s_axi_wvalid && s_axi_wready)
                    w_done = 1'b1;
                @(negedge aclk);
                if (aw_done)
                    s_axi_awvalid = 1'b0;
                if (w_done)
                    s_axi_wvalid = 1'b0;
            end

            while (!s_axi_bvalid)
                @(posedge aclk);
            response = s_axi_bresp;
            @(negedge aclk);
            s_axi_bready = 1'b1;
            @(posedge aclk);
            @(negedge aclk);
            s_axi_bready = 1'b0;
            check(response == AXI_RESP_OKAY, "AXI-Lite write response is OKAY");
        end
    endtask

    task automatic axi_lite_read(
        input logic [11:0] address,
        output logic [31:0] data
    );
        begin
            @(negedge aclk);
            s_axi_araddr = address;
            s_axi_arvalid = 1'b1;
            do begin
                @(posedge aclk);
            end while (!(s_axi_arvalid && s_axi_arready));
            @(negedge aclk);
            s_axi_arvalid = 1'b0;

            while (!s_axi_rvalid)
                @(posedge aclk);
            data = s_axi_rdata;
            response = s_axi_rresp;
            @(negedge aclk);
            s_axi_rready = 1'b1;
            @(posedge aclk);
            @(negedge aclk);
            s_axi_rready = 1'b0;
            check(response == AXI_RESP_OKAY, "AXI-Lite read response is OKAY");
        end
    endtask

    task automatic configure_layer(
        input integer layer_number
    );
        logic [31:0] parameter_base;
        logic [31:0] parameter_value [0:15];
        logic [11:0] register_address;
        logic layer_bases_aligned;
        begin
            parameter_base =
                LAYER_PARAM_BASE + (layer_number * LAYER_PARAM_STRIDE);
            parameter_value[0] = parameter_base + LAYER_LN1_GAMMA_OFFSET;
            parameter_value[1] = parameter_base + LAYER_LN1_BETA_OFFSET;
            parameter_value[2] = parameter_base + LAYER_Q_WEIGHT_OFFSET;
            parameter_value[3] = parameter_base + LAYER_Q_BIAS_OFFSET;
            parameter_value[4] = parameter_base + LAYER_K_WEIGHT_OFFSET;
            parameter_value[5] = parameter_base + LAYER_K_BIAS_OFFSET;
            parameter_value[6] = parameter_base + LAYER_V_WEIGHT_OFFSET;
            parameter_value[7] = parameter_base + LAYER_V_BIAS_OFFSET;
            parameter_value[8] = parameter_base + LAYER_O_WEIGHT_OFFSET;
            parameter_value[9] = parameter_base + LAYER_O_BIAS_OFFSET;
            parameter_value[10] = parameter_base + LAYER_LN2_GAMMA_OFFSET;
            parameter_value[11] = parameter_base + LAYER_LN2_BETA_OFFSET;
            parameter_value[12] = parameter_base + LAYER_FC1_WEIGHT_OFFSET;
            parameter_value[13] = parameter_base + LAYER_FC1_BIAS_OFFSET;
            parameter_value[14] = parameter_base + LAYER_FC2_WEIGHT_OFFSET;
            parameter_value[15] = parameter_base + LAYER_FC2_BIAS_OFFSET;

            layer_bases_aligned = 1'b1;
            for (slot_index = 0; slot_index < 16;
                 slot_index = slot_index + 1) begin
                layer_bases_aligned = layer_bases_aligned &&
                    word_base_is_128_aligned(parameter_value[slot_index]);
                register_address =
                    REG_LAYER_BASE + ((layer_number * 16 + slot_index) * 4);
                axi_lite_write(
                    register_address,
                    parameter_value[slot_index]
                );
            end
            check(
                layer_bases_aligned,
                $sformatf(
                    "all tensor bases for encoder layer %0d are 128B-aligned",
                    layer_number
                )
            );
        end
    endtask

    vit_phase_e_axi_bd_wrapper #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .ARRAY_ROWS(DUT_ARRAY_ROWS),
        .ARRAY_COLS(DUT_ARRAY_COLS),
        .PE_LANES(16),
        .VECTOR_LANES(16),
        .E05_PATCH_COUNT(E05_PATCH_COUNT),
        .E05_TOKEN_COUNT(E05_TOKEN_COUNT),
        .E05_HIDDEN_SIZE(E05_HIDDEN_SIZE),
        .E05_HEAD_COUNT(E05_HEAD_COUNT),
        .E05_HEAD_SIZE(E05_HEAD_SIZE),
        .E05_INTERMEDIATE_SIZE(E05_INTERMEDIATE_SIZE),
        .E05_CLASS_COUNT(E05_CLASS_COUNT),
        .E05_ENCODER_LAYERS(E05_ENCODER_LAYERS),
        .E05_ATTN_SCALE_FP32(E05_ATTN_SCALE_FP32)
    ) dut (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awprot(s_axi_awprot),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arprot(s_axi_arprot),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .m_axi_awid(m_axi_awid),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awlock(m_axi_awlock),
        .m_axi_awcache(m_axi_awcache),
        .m_axi_awprot(m_axi_awprot),
        .m_axi_awqos(m_axi_awqos),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .m_axi_arid(m_axi_arid),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache),
        .m_axi_arprot(m_axi_arprot),
        .m_axi_arqos(m_axi_arqos),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .irq_o(irq_o)
    );

    vit_axi_ddr_model_128 #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MODEL_WORDS(MODEL_WORDS),
        .INPUT_WORDS(INPUT_WORDS),
        .SCRATCH_WORDS(SCRATCH_WORDS),
        .MODEL_BASE(MODEL_BASE),
        .INPUT_BASE(INPUT_BASE),
        .SCRATCH_BASE(SCRATCH_BASE),
        .MAX_BURST_BEATS(4),
        .READ_QUEUE_DEPTH(4),
        .WRITE_QUEUE_DEPTH(2),
        .W_QUEUE_DEPTH(4),
        .STALL_ENABLE(1'b1)
    ) u_ddr (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axi_awid(m_axi_awid),
        .s_axi_awaddr(m_axi_awaddr),
        .s_axi_awlen(m_axi_awlen),
        .s_axi_awsize(m_axi_awsize),
        .s_axi_awburst(m_axi_awburst),
        .s_axi_awlock(m_axi_awlock),
        .s_axi_awcache(m_axi_awcache),
        .s_axi_awprot(m_axi_awprot),
        .s_axi_awqos(m_axi_awqos),
        .s_axi_awvalid(m_axi_awvalid),
        .s_axi_awready(m_axi_awready),
        .s_axi_wdata(m_axi_wdata),
        .s_axi_wstrb(m_axi_wstrb),
        .s_axi_wlast(m_axi_wlast),
        .s_axi_wvalid(m_axi_wvalid),
        .s_axi_wready(m_axi_wready),
        .s_axi_bid(m_axi_bid),
        .s_axi_bresp(m_axi_bresp),
        .s_axi_bvalid(m_axi_bvalid),
        .s_axi_bready(m_axi_bready),
        .s_axi_arid(m_axi_arid),
        .s_axi_araddr(m_axi_araddr),
        .s_axi_arlen(m_axi_arlen),
        .s_axi_arsize(m_axi_arsize),
        .s_axi_arburst(m_axi_arburst),
        .s_axi_arlock(m_axi_arlock),
        .s_axi_arcache(m_axi_arcache),
        .s_axi_arprot(m_axi_arprot),
        .s_axi_arqos(m_axi_arqos),
        .s_axi_arvalid(m_axi_arvalid),
        .s_axi_arready(m_axi_arready),
        .s_axi_rid(m_axi_rid),
        .s_axi_rdata(m_axi_rdata),
        .s_axi_rresp(m_axi_rresp),
        .s_axi_rlast(m_axi_rlast),
        .s_axi_rvalid(m_axi_rvalid),
        .s_axi_rready(m_axi_rready),
        .fault_rresp_enable_i(1'b0),
        .fault_rresp_id_i('0),
        .fault_rresp_beat_i('0),
        .fault_rresp_value_i('0),
        .fault_rid_enable_i(1'b0),
        .fault_rid_value_i('0),
        .fault_rlast_mode_i('0),
        .fault_bresp_enable_i(1'b0),
        .fault_bresp_id_i('0),
        .fault_bresp_value_i('0),
        .fault_bid_enable_i(1'b0),
        .fault_bid_value_i('0),
        .read_count_o(ddr_read_count),
        .write_count_o(ddr_write_count),
        .model_read_count_o(model_read_count),
        .input_read_count_o(input_read_count),
        .scratch_read_count_o(scratch_read_count),
        .scratch_write_count_o(scratch_write_count),
        .ar_transaction_count_o(ddr_ar_transaction_count),
        .aw_transaction_count_o(ddr_aw_transaction_count),
        .r_beat_count_o(ddr_r_beat_count),
        .w_beat_count_o(ddr_w_beat_count),
        .b_response_count_o(ddr_b_response_count),
        .ar_requested_beat_count_o(ddr_ar_requested_beat_count),
        .aw_requested_beat_count_o(ddr_aw_requested_beat_count),
        .ar_backpressure_cycle_count_o(),
        .aw_backpressure_cycle_count_o(),
        .w_backpressure_cycle_count_o(),
        .r_backpressure_cycle_count_o(),
        .b_backpressure_cycle_count_o(),
        .invalid_access_count_o(invalid_access_count),
        .protocol_error_count_o(ddr_protocol_error_count),
        .four_kib_error_count_o(ddr_four_kib_error_count),
        .read_outstanding_count_o(ddr_read_outstanding),
        .write_outstanding_count_o(ddr_write_outstanding),
        .read_outstanding_high_water_o(
            ddr_read_outstanding_high_water
        ),
        .write_outstanding_high_water_o()
    );

    initial begin
        if ((DUT_EXECUTION_MODE != 0) &&
            (DUT_EXECUTION_MODE != 1) &&
            (DUT_EXECUTION_MODE != 3))
            $fatal(1, "DUT_EXECUTION_MODE must be rejection mode 0/1 or executable mode 3");

        // Compact model: all zeros except LayerNorm gamma and one classifier
        // bias.  This is the same deterministic golden used by the direct
        // production-hierarchy E05 test.
        for (initialize_index = 0; initialize_index < MODEL_WORDS;
             initialize_index = initialize_index + 1)
            u_ddr.model_memory[initialize_index] = FP32_POS_ZERO;
        for (initialize_index = 0; initialize_index < INPUT_WORDS;
             initialize_index = initialize_index + 1)
            u_ddr.input_memory[initialize_index] = FP32_POS_ZERO;

        // Populate all 74 persistent MODEL B tensors.  Mode 1 uses package-v2
        // blocked FP32; mode 3 uses package-v3 packed FP16.  Scratch B is
        // generated by earlier commands and remains row-major FP32.
        // Activations remain zero, so using +1.0 for every valid weight keeps
        // the deterministic compact golden while making the blocked payload
        // explicit.  The odd seven-class tensor also emits one padded column.
        initialize_persistent_weight(PATCH_WEIGHT_BASE, 16, 16);
        initialize_persistent_weight(CLASSIFIER_WEIGHT_BASE, 16, 7);
        for (layer_index = 0; layer_index < E05_ENCODER_LAYERS;
             layer_index = layer_index + 1) begin
            initialize_persistent_weight(
                LAYER_PARAM_BASE +
                (layer_index * LAYER_PARAM_STRIDE) +
                LAYER_Q_WEIGHT_OFFSET,
                16,
                16
            );
            initialize_persistent_weight(
                LAYER_PARAM_BASE +
                (layer_index * LAYER_PARAM_STRIDE) +
                LAYER_K_WEIGHT_OFFSET,
                16,
                16
            );
            initialize_persistent_weight(
                LAYER_PARAM_BASE +
                (layer_index * LAYER_PARAM_STRIDE) +
                LAYER_V_WEIGHT_OFFSET,
                16,
                16
            );
            initialize_persistent_weight(
                LAYER_PARAM_BASE +
                (layer_index * LAYER_PARAM_STRIDE) +
                LAYER_O_WEIGHT_OFFSET,
                16,
                16
            );
            initialize_persistent_weight(
                LAYER_PARAM_BASE +
                (layer_index * LAYER_PARAM_STRIDE) +
                LAYER_FC1_WEIGHT_OFFSET,
                16,
                16
            );
            initialize_persistent_weight(
                LAYER_PARAM_BASE +
                (layer_index * LAYER_PARAM_STRIDE) +
                LAYER_FC2_WEIGHT_OFFSET,
                16,
                16
            );
        end

        for (initialize_index = 0; initialize_index < E05_HIDDEN_SIZE;
             initialize_index = initialize_index + 1)
            u_ddr.model_memory[
                FINAL_LN_GAMMA_BASE + initialize_index
            ] = FP32_ONE;

        for (layer_index = 0; layer_index < E05_ENCODER_LAYERS;
             layer_index = layer_index + 1)
            for (initialize_index = 0;
                 initialize_index < E05_HIDDEN_SIZE;
                 initialize_index = initialize_index + 1) begin
                u_ddr.model_memory[
                    LAYER_PARAM_BASE +
                    (layer_index * LAYER_PARAM_STRIDE) +
                    LAYER_LN1_GAMMA_OFFSET +
                    initialize_index
                ] = FP32_ONE;
                u_ddr.model_memory[
                    LAYER_PARAM_BASE +
                    (layer_index * LAYER_PARAM_STRIDE) +
                    LAYER_LN2_GAMMA_OFFSET +
                    initialize_index
                ] = FP32_ONE;
            end

        u_ddr.model_memory[
            CLASSIFIER_BIAS_BASE + TARGET_CLASS
        ] = FP32_SEVEN;

        for (initialize_index = 0; initialize_index < HIDDEN_WORDS;
             initialize_index = initialize_index + 1) begin
            u_ddr.scratch_memory[
                PHASE_E_ADDR_HIDDEN_A + initialize_index
            ] = FP32_SENTINEL;
            u_ddr.scratch_memory[
                PHASE_E_ADDR_HIDDEN_B + initialize_index
            ] = FP32_SENTINEL;
            u_ddr.scratch_memory[
                PHASE_E_ADDR_LINEAR_TMP + initialize_index
            ] = FP32_SENTINEL;
        end
        for (initialize_index = 0; initialize_index < HEAD_WORDS;
             initialize_index = initialize_index + 1) begin
            u_ddr.scratch_memory[
                PHASE_E_ADDR_Q_HEAD + initialize_index
            ] = FP32_SENTINEL;
            u_ddr.scratch_memory[
                PHASE_E_ADDR_K_HEAD + initialize_index
            ] = FP32_SENTINEL;
            u_ddr.scratch_memory[
                PHASE_E_ADDR_V_HEAD + initialize_index
            ] = FP32_SENTINEL;
        end
        for (initialize_index = 0; initialize_index < SCORE_WORDS;
             initialize_index = initialize_index + 1)
            u_ddr.scratch_memory[
                PHASE_E_ADDR_SCORE_PROB + initialize_index
            ] = FP32_SENTINEL;
        for (initialize_index = 0; initialize_index < FC1_WORDS;
             initialize_index = initialize_index + 1)
            u_ddr.scratch_memory[
                PHASE_E_ADDR_FC1 + initialize_index
            ] = FP32_SENTINEL;
        for (initialize_index = 0; initialize_index < CLASS_WORDS;
             initialize_index = initialize_index + 1) begin
            u_ddr.scratch_memory[
                PHASE_E_ADDR_LOGITS + initialize_index
            ] = FP32_SENTINEL;
            u_ddr.scratch_memory[
                PHASE_E_ADDR_CLASS_PROB + initialize_index
            ] = FP32_SENTINEL;
        end

        repeat (8)
            @(posedge aclk);
        @(negedge aclk);
        aresetn = 1'b1;

        axi_lite_read(REG_IP_ID, read_data);
        check(read_data == 32'h5649_544e, "IP identity register");
        axi_lite_read(REG_IP_VERSION, read_data);
        check(read_data == 32'h0001_000d, "M8 profile IP version is v1.13");
        check(
            (MODEL_BASE[6:0] == 7'd0) &&
            word_base_is_128_aligned(PATCH_WEIGHT_BASE) &&
            word_base_is_128_aligned(PATCH_BIAS_BASE) &&
            word_base_is_128_aligned(CLS_BASE) &&
            word_base_is_128_aligned(POSITION_BASE) &&
            word_base_is_128_aligned(FINAL_LN_GAMMA_BASE) &&
            word_base_is_128_aligned(FINAL_LN_BETA_BASE) &&
            word_base_is_128_aligned(CLASSIFIER_WEIGHT_BASE) &&
            word_base_is_128_aligned(CLASSIFIER_BIAS_BASE),
            "MODEL base and all eight global tensor bases are 128B-aligned"
        );
        if (DUT_EXECUTION_MODE == 3)
            check(
                (E05_CLASS_COUNT[0] == 1'b1) &&
                (CLASSIFIER_PACKED_WORDS == 64) &&
                ((CLASSIFIER_WEIGHT_BASE + CLASSIFIER_PACKED_WORDS) <=
                 CLASSIFIER_BIAS_BASE),
                "odd-N packed classifier carries zero high halves without bias overlap"
            );
        else
            check(
                (E05_CLASS_COUNT[0] == 1'b1) &&
                (CLASSIFIER_BLOCKED_WORDS == 128) &&
                ((CLASSIFIER_WEIGHT_BASE + CLASSIFIER_BLOCKED_WORDS) ==
                 CLASSIFIER_BIAS_BASE),
                "odd-N blocked classifier span is padded without bias overlap"
            );

        axi_lite_write(REG_MODEL_BASE_LO, MODEL_BASE[31:0]);
        axi_lite_write(REG_MODEL_BASE_HI, MODEL_BASE[63:32]);
        axi_lite_write(REG_INPUT_BASE_LO, INPUT_BASE[31:0]);
        axi_lite_write(REG_INPUT_BASE_HI, INPUT_BASE[63:32]);
        axi_lite_write(REG_SCRATCH_BASE_LO, SCRATCH_BASE[31:0]);
        axi_lite_write(REG_SCRATCH_BASE_HI, SCRATCH_BASE[63:32]);
        axi_lite_write(REG_MODEL_WORDS, MODEL_WORDS);
        axi_lite_write(REG_INPUT_WORDS, INPUT_WORDS);
        axi_lite_write(REG_SCRATCH_WORDS, SCRATCH_WORDS);
        axi_lite_write(REG_EXECUTION_MODE, DUT_EXECUTION_MODE);
        axi_lite_read(REG_EXECUTION_MODE, read_data);
        check(read_data == DUT_EXECUTION_MODE,
              "EXECUTION_MODE selects requested compact GEMM path");

        // The FP16-only board specialization deliberately keeps the public
        // register writable while removing the mode-0/mode-1 FP32 compute
        // paths.  Exercise the exact production hierarchy and prove both
        // historical modes fail closed at START before any job/profile/DDR
        // activity.  Mode 3 continues into the cycle-exact compact E05 gate.
        if (DUT_EXECUTION_MODE != 3) begin
            axi_lite_write(REG_IRQ_ENABLE, 32'h0000_0002);
            axi_lite_write(REG_CONTROL, 32'h0000_0001);
            repeat (4) @(posedge aclk);

            axi_lite_read(REG_STATUS, read_data);
            check(read_data[0] && !read_data[1] && read_data[3],
                  "rejected FP32 mode stays idle and reports ERROR");
            check(read_data[4],
                  "rejected FP32 mode asserts the enabled error IRQ");
            axi_lite_read(REG_IRQ_STATUS, read_data);
            check(!read_data[0] && read_data[1],
                  "rejected FP32 mode latches only the error IRQ event");
            axi_lite_read(REG_ERROR_CODE, read_data);
            check(read_data == 32'h8000_0003,
                  "rejected FP32 mode reports WRAPPER_ERROR_EXECUTION_MODE");
            axi_lite_read(REG_ERROR_INFO, read_data);
            check(read_data == DUT_EXECUTION_MODE,
                  "rejected FP32 mode preserves its encoding in ERROR_INFO");
            axi_lite_read(REG_PERF_STATUS, read_data);
            check(read_data == 32'd0,
                  "rejected FP32 mode opens no performance epoch");

            check(!perf_monitor_running && monitored_job_cycles == 0 &&
                  monitored_axi_stall_cycles == 0,
                  "rejected FP32 mode never starts the independent job monitor");
            check(checkpoint_count == 0 && gemm_command_count == 0 &&
                  class_result_count == 0,
                  "rejected FP32 mode accepts no production command");
            check(ddr_read_count == 0 && ddr_write_count == 0 &&
                  ddr_ar_transaction_count == 0 &&
                  ddr_aw_transaction_count == 0 &&
                  ddr_r_beat_count == 0 && ddr_w_beat_count == 0 &&
                  ddr_b_response_count == 0,
                  "rejected FP32 mode performs no modeled DDR transaction");
            check(model_read_count == 0 && input_read_count == 0 &&
                  scratch_read_count == 0 && scratch_write_count == 0,
                  "rejected FP32 mode performs no region access");
            check(ddr_protocol_error_count == 0 &&
                  ddr_four_kib_error_count == 0 &&
                  invalid_access_count == 0,
                  "rejected FP32 mode leaves DDR protocol checks clean");

            if (failures == 0)
                $display(
                    "VIT_PHASE_E_AXI_E05_COMPACT_RTL_MODE_REJECT_PASS mode=%0d checks=%0d error=80000003 info=%08x",
                    DUT_EXECUTION_MODE,
                    checks,
                    DUT_EXECUTION_MODE
                );
            else
                $fatal(1,
                       "compact mode-rejection failures=%0d checks=%0d",
                       failures,
                       checks);
            $finish;
        end

        axi_lite_write(REG_GLOBAL_BASE + 12'h000, PATCH_WEIGHT_BASE);
        axi_lite_write(REG_GLOBAL_BASE + 12'h004, PATCH_BIAS_BASE);
        axi_lite_write(REG_GLOBAL_BASE + 12'h008, CLS_BASE);
        axi_lite_write(REG_GLOBAL_BASE + 12'h00c, POSITION_BASE);
        axi_lite_write(REG_GLOBAL_BASE + 12'h010, FINAL_LN_GAMMA_BASE);
        axi_lite_write(REG_GLOBAL_BASE + 12'h014, FINAL_LN_BETA_BASE);
        axi_lite_write(REG_GLOBAL_BASE + 12'h018, CLASSIFIER_WEIGHT_BASE);
        axi_lite_write(REG_GLOBAL_BASE + 12'h01c, CLASSIFIER_BIAS_BASE);

        for (layer_index = 0; layer_index < 12;
             layer_index = layer_index + 1)
            configure_layer(layer_index);

        job_config_value = 32'd0;
        job_config_value[2:0] = PHASE_E_E05;
        job_config_value[6:3] = 4'd0;
        job_config_value[10:7] = 4'd11;
        job_config_value[11] = 1'b1;
        job_config_value[12] = 1'b1;
        job_config_value[20:13] = JOB_TAG;
        axi_lite_write(REG_JOB_CONFIG, job_config_value);
        axi_lite_write(REG_JOB_PATCH_BASE, 32'd0);
        axi_lite_write(REG_IRQ_ENABLE, 32'h0000_0001);

        axi_lite_read(REG_STATUS, read_data);
        check(read_data[0] && !read_data[1], "wrapper is idle before START");
        check(!read_data[2] && !read_data[3], "completion flags clear before START");

        axi_lite_write(REG_CONTROL, 32'h0000_0001);
        axi_lite_read(REG_STATUS, read_data);
        check(read_data[1] && !read_data[0], "wrapper reports BUSY after START");
        axi_lite_read(REG_PERF_STATUS, read_data);
        check(read_data == 32'h0000_0001, "performance monitor reports RUNNING");

        wait (irq_o);

        axi_lite_read(REG_STATUS, read_data);
        check(read_data[0] && !read_data[1], "wrapper returns to IDLE");
        check(read_data[2] && !read_data[3], "DONE set without ERROR");
        check(read_data[4], "STATUS reflects asserted IRQ");

        axi_lite_read(REG_IRQ_STATUS, read_data);
        check(read_data[0] && !read_data[1], "done IRQ is sticky");
        axi_lite_read(REG_ERROR_CODE, read_data);
        check(read_data == 32'd0, "error code remains zero");
        axi_lite_read(REG_CLASS_INDEX, read_data);
        check(read_data == TARGET_CLASS, "class index is target class 3");
        axi_lite_read(REG_CLASS_LOGIT, read_data);
        check(read_data == FP32_SEVEN, "class logit is exactly +7.0");
        axi_lite_read(REG_PERF_CAPABILITY, read_data);
        check(read_data == 32'h0001_001f, "performance capability schema");
        axi_lite_read(REG_PERF_STATUS, read_data);
        check(read_data == 32'h0000_0002, "performance snapshot is valid");
        axi_lite_read64(REG_JOB_CYCLES_LO, perf_read_value);
        check(
            perf_read_value == monitored_job_cycles,
            "hardware job cycles match independent edge monitor"
        );
        axi_lite_read64(REG_COMMANDS_LO, perf_read_value);
        check(perf_read_value == 64'd249, "hardware command count is 249");
        axi_lite_read64(REG_AXI_READS_LO, perf_read_value);
        check(
            perf_read_value == ddr_ar_transaction_count,
            "legacy AXI read count matches AR transactions"
        );
        axi_lite_read64(REG_AXI_WRITES_LO, perf_read_value);
        check(
            perf_read_value == ddr_write_count,
            "hardware AXI write count matches DDR model"
        );
        axi_lite_read64(REG_AXI_STALL_LO, perf_read_value);
        check(
            perf_read_value == monitored_axi_stall_cycles,
            "hardware AXI request-stall cycles match independent monitor"
        );

        // Profile ABI v1.2 is checked only through the production AXI-Lite
        // interface.  These invariants independently tie core-level events,
        // logical requests, physical AXI traffic, opcode attribution, trace
        // storage and response-latency histograms to this completed job.
        axi_lite_read(REG_PROFILE_CAP2, read_data);
        check(read_data == 32'h0002_7fff, "profile capability schema v2");
        axi_lite_read(REG_PROFILE_STATUS2, read_data);
        check(read_data == 32'd0, "profile status has no overflow/truncation");
        axi_lite_read(REG_PROFILE_OVF_LO, read_data);
        check(read_data == 32'd0, "profile overflow low mask is clear");
        axi_lite_read(REG_PROFILE_OVF_HI, read_data);
        check(read_data == 32'd0, "profile overflow high mask is clear");
        axi_lite_read(REG_OPCODE_COUNT_OVF, read_data);
        check(read_data == 32'd0, "opcode count overflow mask is clear");
        axi_lite_read(REG_OPCODE_CYCLE_OVF, read_data);
        check(read_data == 32'd0, "opcode cycle overflow mask is clear");
        axi_lite_read(REG_PROFILE_ERROR, read_data);
        check(read_data == 32'd0, "profile typed error status is clear");

        for (profile_index = 0;
             profile_index < PHASE_E_PROFILE_GLOBAL_COUNT;
             profile_index = profile_index + 1) begin
            profile_global_read(
                profile_index,
                profile_global_value[profile_index]
            );
            check(
                !$isunknown(profile_global_value[profile_index]),
                "every published global profile counter is known"
            );
        end

        for (profile_index = 0; profile_index < 8;
             profile_index = profile_index + 1)
            axi_lite_read64(
                REG_M5_COUNTER_BASE + (profile_index * 8),
                m5_axi_counter[profile_index]
            );
        for (profile_index = 0;
             profile_index < PHASE_E_M7_COUNTER_COUNT;
             profile_index = profile_index + 1)
            axi_lite_read64(
                REG_M7_COUNTER_BASE + (profile_index * 8),
                m7_counter[profile_index]
            );
        $display(
            "M5_COMPACT_COUNTERS logical=%0d core_hits=%0d payload_words=%0d ar=%0d rbeats=%0d full=%0d narrow=%0d starts=%0d line_hits=%0d split=%0d max_out=%0d errors=%0d discarded=%0d",
            profile_global_value[PHASE_E_PROFILE_GLOBAL_LOGICAL_READ],
            profile_global_value[PHASE_E_PROFILE_GLOBAL_CACHE_HIT],
            ddr_read_count,
            ddr_ar_transaction_count,
            ddr_r_beat_count,
            m5_axi_counter[0], m5_axi_counter[1], m5_axi_counter[2],
            m5_axi_counter[3], m5_axi_counter[4], m5_axi_counter[5],
            m5_axi_counter[6], m5_axi_counter[7]
        );

        if (DUT_EXECUTION_MODE == 3) begin
            // S8 replays the same logical R8xC2 tile as two physical column
            // passes.  The existing aggregate cache-hit counter does not
            // classify all replay hits, so retain the exact independently
            // observed triplet instead of applying the S16 partition identity.
            check(
                profile_global_value[
                    PHASE_E_PROFILE_GLOBAL_LOGICAL_READ
                ] == EXPECTED_PACKED_R8_LOGICAL_READS &&
                profile_global_value[
                    PHASE_E_PROFILE_GLOBAL_CACHE_HIT
                ] == EXPECTED_PACKED_R8_CORE_HITS &&
                ddr_read_count == EXPECTED_PACKED_R8_READS,
                "S8 logical, core-hit and external read totals are exact"
            );
        end else begin
            check(
                profile_global_value[
                    PHASE_E_PROFILE_GLOBAL_LOGICAL_READ
                ] == ddr_read_count - m5_axi_counter[7] +
                    profile_global_value[
                        PHASE_E_PROFILE_GLOBAL_CACHE_HIT
                    ],
                "logical reads equal useful external payload plus core-cache hits"
            );
        end
        check(
            profile_global_value[PHASE_E_PROFILE_GLOBAL_LOGICAL_WRITE] ==
                ddr_write_count,
            "logical writes match complete AXI writes"
        );
        check(
            profile_global_value[PHASE_E_PROFILE_GLOBAL_R_BEATS] ==
                ddr_r_beat_count,
            "profile R beats match DDR model"
        );
        check(
            profile_global_value[PHASE_E_PROFILE_GLOBAL_W_BEATS] ==
                ddr_write_count,
            "profile W beats match DDR model"
        );
        check(
            profile_global_value[PHASE_E_PROFILE_GLOBAL_B_RESPONSES] ==
                ddr_b_response_count,
            "profile B responses match accepted writes"
        );

        // Append-only M5 bank separates 128-bit beats from logical FP32
        // demand.  Counter order is fixed by profile ABI v1.6.
        axi_lite_read(REG_M5_CAPABILITY, read_data);
        check(read_data == 32'h01f2_1008, "M5 AXI capability schema");
        axi_lite_read(REG_M5_STATUS, read_data);
        if (DUT_EXECUTION_MODE == 3)
            check(read_data == 32'h0000_0002,
                  "M5 snapshot valid with one packed burst outstanding and no tail drop");
        else
            check(read_data == 32'h0000_0092,
                  "M5 snapshot valid, max outstanding two and compact tail drop");
        axi_lite_read(REG_M5_OVERFLOW, read_data);
        check(read_data == 32'd0, "M5 counter overflow mask is clear");
        axi_lite_read(REG_M5_PROTOCOL, read_data);
        check(read_data == 32'd0, "M5 protocol status is clear");
        check(m5_axi_counter[0] == ddr_r_beat_count - m5_axi_counter[1],
              "M5 full plus narrow beats partition all R beats");
        check(m5_axi_counter[1] + (m5_axi_counter[0] * 4) ==
                  ddr_read_count,
              "M5 beat classes reconstruct external FP32 payload words");
        if (DUT_EXECUTION_MODE == 3) begin
            check(
                m5_axi_counter[2] == EXPECTED_PACKED_R8_LINE_STARTS &&
                m5_axi_counter[3] == EXPECTED_PACKED_R8_LINE_HITS &&
                m5_axi_counter[7] == 0,
                "S8 linefill starts, replay hits and discarded words are exact"
            );
        end else begin
            check(m5_axi_counter[2] + m5_axi_counter[3] +
                      m5_axi_counter[7] == (m5_axi_counter[0] * 4),
                  "linefill starts, hits and unused words partition full payload");
        end
        if (DUT_EXECUTION_MODE == 3)
            check(ddr_ar_transaction_count ==
                      m5_axi_counter[1] + m5_axi_counter[2],
                  "packed AR count equals narrow reads plus one burst per linefill");
        else
            check(ddr_ar_transaction_count ==
                      m5_axi_counter[1] + (m5_axi_counter[2] * 2),
                  "legacy AR count equals narrow reads plus two bursts per linefill");
        check(m5_axi_counter[4] == 0, "no 4 KiB split in aligned package");
        if (DUT_EXECUTION_MODE == 3)
            check(m5_axi_counter[5] == 1,
                  "one four-beat read serves each packed linefill");
        else
            check(m5_axi_counter[5] == 2,
                  "two reads were outstanding for the legacy eight-beat line");
        check(m5_axi_counter[6] == 0, "no M5 protocol error events");
        if (DUT_EXECUTION_MODE == 3)
            check(m5_axi_counter[7] == 0,
                  "packed odd-N high-half padding creates no discarded u32");
        else
            check(m5_axi_counter[7] == 16,
                  "odd-N blocked classifier reports one discarded FP32 column");

        // M8 v1.13 preserves the exact-stage bank append-only and independent of the
        // frozen profile-v1.2 and M5 banks.  Legacy mode must publish zeros;
        // mode3 ties accepted/disabled terms back to the old MAC-slot totals.
        axi_lite_read(REG_M7_CAPABILITY, read_data);
        check(read_data == 32'h01ff_0817, "M7 counter capability schema");
        axi_lite_read(REG_M7_STATUS, m7_status_value);
        check(!m7_status_value[0] && m7_status_value[1],
              "M7 snapshot is valid and no longer running");
        axi_lite_read(REG_M7_OVF_LO, read_data);
        check(read_data == 32'd0, "M7 overflow low mask is clear");
        axi_lite_read(REG_M7_OVF_HI, read_data);
        check(read_data == 32'd0, "M7 overflow high mask is clear");
        axi_lite_read(REG_M7_ERROR, read_data);
        check(read_data == 32'd0, "M7 typed error status is clear");
        axi_lite_read(REG_M7_GEOMETRY, read_data);
        check(read_data == 32'h0810_0208, "M7 R8/C2/L16/S8 geometry");
        axi_lite_read(REG_M7_BUFFER_CONFIG, read_data);
        check(read_data == 32'h0008_0202,
              "M7 two-bank/depth-two-FIFO/eight-bit-generation contract");
        axi_lite_read(REG_M7_NUMERIC_CONFIG, read_data);
        check(read_data == 32'h07c0_d05d, "M7 numerical contract");
        if (DUT_EXECUTION_MODE == 3) begin
            check(m7_counter[0] == 64'd184192,
                  "M7-S8 compact accepted-term total is exact");
            check(m7_counter[1] == 64'd124816,
                  "M7-S8 compact disabled-term total is exact");
            check(profile_global_value[PHASE_E_PROFILE_GLOBAL_VALID_MAC] ==
                      64'd59376,
                  "M7-S8 compact useful-MAC total is unchanged");
            check((m7_counter[2] == 64'd1439) &&
                  (m7_counter[3] == 64'd1439),
                  "M7-S8 compact dot/result physical-pass totals are exact");
            check(
                m7_counter[0] ==
                    profile_global_value[
                        PHASE_E_PROFILE_GLOBAL_VALID_MAC
                    ] +
                    profile_global_value[
                        PHASE_E_PROFILE_GLOBAL_TAIL_MAC
                    ],
                "M7 accepted terms equal all scheduled MAC slots"
            );
            check(
                m7_counter[1] ==
                    profile_global_value[
                        PHASE_E_PROFILE_GLOBAL_TAIL_MAC
                    ],
                "M7 disabled terms equal legacy tail MAC slots"
            );
            check(m7_counter[2] == m7_counter[3] && m7_counter[2] > 0,
                  "M7 dot starts equal completed result vectors");
            check(m7_counter[6] > 0 && m7_counter[7] > 0 &&
                      m7_counter[8] > 0,
                  "M7 load/compute/store stages are all non-vacuous");
            check(
                m7_counter[9] ==
                    m7_counter[6] + m7_counter[7] + m7_counter[8] -
                    m7_counter[10] - m7_counter[11] - m7_counter[12] +
                    m7_counter[13],
                "M7 stage union obeys inclusion-exclusion"
            );
            check(m7_status_value[4] == (m7_counter[10] != 0) &&
                      m7_status_value[5] == (m7_counter[11] != 0) &&
                      m7_status_value[6] == (m7_counter[13] != 0),
                  "M7 overlap status agrees with published counters");
            check(m7_counter[14] == m7_counter[15] &&
                      m7_counter[15] == m7_counter[16] &&
                      m7_counter[16] == 64'd1175 &&
                      packed_model_tile_load_count == 1175,
                  "M7 panel ownership counts equal packed-model K16 tiles");
            check(m7_counter[17] > 0,
                  "M7 panel-empty wait path is non-vacuous");
            check(m7_counter[18] <= m7_counter[6],
                  "panel-full wait is bounded by the load-active interval");
            check(m7_counter[19] > 0 && m7_counter[19] <= 2,
                  "packed schedule uses no more than two operand banks");
            check(m7_counter[20] == m7_counter[21] &&
                      m7_counter[20] == 64'd1175,
                  "every compact packed result is enqueued and drained once");
            check(m7_counter[22] > 0 && m7_counter[22] <= 2,
                  "packed result FIFO occupancy respects depth two");
            check(m7_counter[11] > 0,
                  "packed production schedule overlaps compute and store");
            check(m7_status_value[15:12] == m7_counter[22][3:0],
                  "M7 status publishes the observed FIFO high-water mark");
        end else begin
            for (profile_index = 0; profile_index < 23;
                 profile_index = profile_index + 1)
                check(m7_counter[profile_index] == 0,
                      "legacy mode leaves all M7 counters zero");
        end
        $display(
            "M7_COMPACT_COUNTERS mode=%0d terms=%0d disabled=%0d dots=%0d results=%0d feeder_stall=%0d result_bp=%0d load=%0d compute=%0d store=%0d union=%0d lc=%0d cs=%0d ls=%0d three=%0d commits=%0d claims=%0d releases=%0d empty_wait=%0d full_wait=%0d max_panel=%0d fifo_enq=%0d fifo_deq=%0d max_fifo=%0d",
            DUT_EXECUTION_MODE, m7_counter[0], m7_counter[1],
            m7_counter[2], m7_counter[3], m7_counter[4], m7_counter[5],
            m7_counter[6], m7_counter[7], m7_counter[8], m7_counter[9],
            m7_counter[10], m7_counter[11], m7_counter[12], m7_counter[13],
            m7_counter[14], m7_counter[15], m7_counter[16], m7_counter[17],
            m7_counter[18], m7_counter[19], m7_counter[20], m7_counter[21],
            m7_counter[22]
        );
        $display(
            "M7_COMPACT_ARBITRATION conflict=%0d idle_conflict=%0d queued_compute=%0d deliver_queued=%0d",
            m7_load_result_conflict_cycles,
            m7_idle_load_result_conflict_cycles,
            m7_result_queued_compute_cycles,
            m7_data_deliver_result_queued_cycles
        );
        check(ddr_ar_requested_beat_count == ddr_r_beat_count,
              "requested and returned R beat totals match");
        check(ddr_aw_transaction_count == ddr_write_count &&
                  ddr_w_beat_count == ddr_write_count &&
                  ddr_b_response_count == ddr_write_count,
              "scalar writes have exact AW/W/B accounting");
        check(ddr_aw_requested_beat_count == ddr_w_beat_count,
              "requested and accepted W beat totals match");
        check(ddr_protocol_error_count == 0 &&
                  ddr_four_kib_error_count == 0,
              "DDR model reports no protocol or 4 KiB violation");
        check(ddr_read_outstanding == 0 && ddr_write_outstanding == 0,
              "all AXI transactions retired before DONE");
        if (DUT_EXECUTION_MODE == 3)
            check(ddr_read_outstanding_high_water == 1,
                  "DDR model observed one packed read transaction outstanding");
        else
            check(ddr_read_outstanding_high_water >= 2,
                  "DDR model observed at least two legacy reads outstanding");
        check(
            profile_global_value[PHASE_E_PROFILE_GLOBAL_CACHE_LOOKUP] ==
                profile_global_value[PHASE_E_PROFILE_GLOBAL_CACHE_HIT] +
                profile_global_value[PHASE_E_PROFILE_GLOBAL_CACHE_MISS],
            "aggregate cache lookups partition into hit and miss"
        );
        check(
            profile_global_value[PHASE_E_PROFILE_GLOBAL_A_LOOKUP] ==
                profile_global_value[PHASE_E_PROFILE_GLOBAL_A_HIT] +
                profile_global_value[PHASE_E_PROFILE_GLOBAL_A_MISS],
            "A-cache lookups partition into hit and miss"
        );
        check(
            profile_global_value[PHASE_E_PROFILE_GLOBAL_BIAS_LOOKUP] ==
                profile_global_value[PHASE_E_PROFILE_GLOBAL_BIAS_HIT] +
                profile_global_value[PHASE_E_PROFILE_GLOBAL_BIAS_MISS],
            "bias-cache lookups partition into hit and miss"
        );
        check(
            profile_global_value[PHASE_E_PROFILE_GLOBAL_CACHE_LOOKUP] ==
                profile_global_value[PHASE_E_PROFILE_GLOBAL_A_LOOKUP] +
                profile_global_value[PHASE_E_PROFILE_GLOBAL_BIAS_LOOKUP],
            "aggregate cache lookups equal A plus bias lookups"
        );
        check(
            profile_global_value[PHASE_E_PROFILE_GLOBAL_VALID_MAC] +
                profile_global_value[PHASE_E_PROFILE_GLOBAL_TAIL_MAC] ==
                profile_global_value[
                    PHASE_E_PROFILE_GLOBAL_GEMM_TILE_STEPS
                ] * ((DUT_EXECUTION_MODE == 3) ?
                    M7_S8_MAC_SLOTS_PER_PASS : MAC_SLOTS_PER_TILE),
            "valid plus tail MAC slots equal physical-pass capacity"
        );
        check(
            profile_global_value[PHASE_E_PROFILE_GLOBAL_OVERLAP] <=
                profile_global_value[PHASE_E_PROFILE_GLOBAL_UNION],
            "overlap cycles do not exceed stage-union cycles"
        );
        check(
            profile_global_value[PHASE_E_PROFILE_GLOBAL_THREE_WAY] <=
                profile_global_value[
                    PHASE_E_PROFILE_GLOBAL_LOAD_COMPUTE_OVERLAP
                ],
            "three-way overlap is contained by pairwise overlap"
        );
        check(
            profile_global_value[PHASE_E_PROFILE_GLOBAL_COMMAND_ERRORS] == 0 &&
            profile_global_value[
                PHASE_E_PROFILE_GLOBAL_AXI_RESPONSE_ERRORS
            ] == 0 &&
            profile_global_value[
                PHASE_E_PROFILE_GLOBAL_LOGICAL_RSP_ERRORS
            ] == 0 &&
            profile_global_value[PHASE_E_PROFILE_GLOBAL_JOB_ERRORS] == 0,
            "all profile error counters remain zero"
        );
        check(
            profile_global_value[PHASE_E_PROFILE_GLOBAL_TRACE_DROPPED] == 0,
            "249-command trace fits without drops"
        );

        profile_opcode_count_sum = 64'd0;
        profile_opcode_cycle_sum = 64'd0;
        for (profile_index = 0;
             profile_index < PHASE_E_PROFILE_OPCODE_SLOTS;
             profile_index = profile_index + 1) begin
            profile_opcode_read(
                profile_index,
                profile_opcode_count[profile_index],
                profile_opcode_cycles[profile_index]
            );
            profile_opcode_count_sum = profile_opcode_count_sum +
                profile_opcode_count[profile_index];
            profile_opcode_cycle_sum = profile_opcode_cycle_sum +
                profile_opcode_cycles[profile_index];
        end
        check(
            profile_opcode_count_sum == 64'd249,
            "sum of per-opcode command counts is 249"
        );
        check(
            profile_opcode_cycle_sum ==
                profile_global_value[
                    PHASE_E_PROFILE_GLOBAL_COMMAND_ACTIVE
                ],
            "sum of per-opcode cycles equals command-active cycles"
        );
        check(profile_opcode_count[PHASE_E_OP_GEMM] == 64'd98,
              "compact E05 GEMM command count is 98");
        check(profile_opcode_count[PHASE_E_OP_VECTOR] == 64'd37,
              "compact E05 VECTOR command count is 37");
        check(profile_opcode_count[PHASE_E_OP_LAYOUT] == 64'd63,
              "compact E05 LAYOUT command count is 63");
        check(profile_opcode_count[PHASE_E_OP_LAYERNORM] == 64'd25,
              "compact E05 LAYERNORM command count is 25");
        check(profile_opcode_count[PHASE_E_OP_SOFTMAX] == 64'd13,
              "compact E05 SOFTMAX command count is 13");
        check(profile_opcode_count[PHASE_E_OP_GELU] == 64'd12,
              "compact E05 GELU command count is 12");
        check(profile_opcode_count[PHASE_E_OP_ARGMAX] == 64'd1,
              "compact E05 ARGMAX command count is 1");

        axi_lite_read(REG_TRACE_CAPABILITY, read_data);
        check(read_data == 32'h0103_0100, "trace is 256 by 96 bits");
        axi_lite_read(REG_TRACE_COUNT, read_data);
        check(read_data == 32'd249, "trace contains all 249 commands");
        axi_lite_write(REG_TRACE_SELECT, 32'd0);
        axi_lite_read(REG_TRACE_STATUS, read_data);
        check(read_data[1] && !read_data[2] && !read_data[3],
              "first trace entry prefetch is valid");
        axi_lite_read(REG_TRACE_META, profile_trace_meta);
        axi_lite_read64(REG_TRACE_CYCLES_LO, profile_trace_cycles);
        check(
            (profile_trace_meta[3:0] >= PHASE_E_OP_GEMM) &&
            (profile_trace_meta[3:0] <= PHASE_E_OP_ARGMAX) &&
            !profile_trace_meta[12] && (profile_trace_cycles > 0),
            "first trace entry has valid opcode, duration and no error"
        );
        axi_lite_write(REG_TRACE_SELECT, 32'd248);
        axi_lite_read(REG_TRACE_STATUS, read_data);
        check(read_data[1] && !read_data[2] && !read_data[3],
              "last trace entry prefetch is valid");
        axi_lite_read(REG_TRACE_META, profile_trace_meta);
        axi_lite_read64(REG_TRACE_CYCLES_LO, profile_trace_cycles);
        check(
            (profile_trace_meta[3:0] >= PHASE_E_OP_GEMM) &&
            (profile_trace_meta[3:0] <= PHASE_E_OP_ARGMAX) &&
            !profile_trace_meta[12] && (profile_trace_cycles > 0),
            "last trace entry has valid opcode, duration and no error"
        );

        profile_trace_duration_sum = 64'd0;
        profile_trace_failures = 0;
        for (profile_index = 0;
             profile_index < PHASE_E_PROFILE_OPCODE_SLOTS;
             profile_index = profile_index + 1)
            profile_trace_opcode_count[profile_index] = 64'd0;
        for (profile_index = 0; profile_index < 249;
             profile_index = profile_index + 1) begin
            axi_lite_write(REG_TRACE_SELECT, profile_index);
            axi_lite_read(REG_TRACE_STATUS, read_data);
            axi_lite_read(REG_TRACE_META, profile_trace_meta);
            axi_lite_read64(REG_TRACE_CYCLES_LO, profile_trace_cycles);
            if ($isunknown({
                    read_data[3:1],
                    profile_trace_meta,
                    profile_trace_cycles
                }) ||
                (read_data[1] !== 1'b1) ||
                (read_data[2] !== 1'b0) ||
                (read_data[3] !== 1'b0) ||
                (profile_trace_meta[12] !== 1'b0) ||
                (profile_trace_meta[3:0] < PHASE_E_OP_GEMM) ||
                (profile_trace_meta[3:0] > PHASE_E_OP_ARGMAX) ||
                (profile_trace_cycles == 0)) begin
                profile_trace_failures = profile_trace_failures + 1;
            end else begin
                profile_trace_opcode_count[profile_trace_meta[3:0]] =
                    profile_trace_opcode_count[profile_trace_meta[3:0]] +
                    64'd1;
                profile_trace_duration_sum = profile_trace_duration_sum +
                    profile_trace_cycles;
            end
        end
        check(profile_trace_failures == 0,
              "all 249 trace entries are valid and error-free");
        check(
            profile_trace_duration_sum ==
                profile_global_value[
                    PHASE_E_PROFILE_GLOBAL_COMMAND_ACTIVE
                ],
            "sum of trace durations equals command-active cycles"
        );
        for (profile_index = 0;
             profile_index < PHASE_E_PROFILE_OPCODE_SLOTS;
             profile_index = profile_index + 1)
            check(
                profile_trace_opcode_count[profile_index] ==
                    profile_opcode_count[profile_index],
                $sformatf(
                    "trace opcode %0d population matches opcode counter",
                    profile_index
                )
            );

        axi_lite_read(REG_HIST_CAPABILITY, read_data);
        check(read_data == 32'h0108_0802, "read/write wait histogram schema");
        axi_lite_read(REG_HIST_OVERFLOW, read_data);
        check(read_data == 32'd0, "histogram overflow mask is clear");
        profile_read_histogram_sum = 64'd0;
        profile_write_histogram_sum = 64'd0;
        for (profile_index = 0;
             profile_index < PHASE_E_PROFILE_HIST_COUNT;
             profile_index = profile_index + 1) begin
            profile_histogram_read(
                profile_index,
                profile_histogram[profile_index]
            );
            if (profile_index < 8)
                profile_read_histogram_sum =
                    profile_read_histogram_sum +
                    profile_histogram[profile_index];
            else if (profile_index < 16)
                profile_write_histogram_sum =
                    profile_write_histogram_sum +
                    profile_histogram[profile_index];
        end
        check(
            profile_read_histogram_sum == ddr_ar_transaction_count,
            "read-wait histogram population equals retired AR transactions"
        );
        check(
            profile_write_histogram_sum == ddr_write_count,
            "write-wait histogram population equals B responses"
        );
        check(
            checkpoint_count == 249,
            "exactly 249 production command checkpoints completed"
        );
        check(gemm_command_count == 98,
              "all 98 GEMM descriptors were independently observed");
        check(blocked_model_gemm_count == 74,
              "74 MODEL-weight GEMMs use blocked K16/N2 layout");
        check(row_major_scratch_gemm_count == 24,
              "24 attention GEMMs keep row-major SCRATCH layout");
        if (DUT_EXECUTION_MODE == 3) begin
            check(packed_model_gemm_count == 74,
                  "74 persistent MODEL GEMMs select packed-v3 B");
            check(fp16_gemm_count == 98,
                  "all 98 GEMMs select FP16 operands and wide accumulation");
            check(fp16_scratch_gemm_count == 24,
                  "24 scratch-B attention GEMMs use row-major FP32 storage with FP16 compute");
            check(packed_model_tile_load_count == 1175,
                  "packed-v3 S8 E05 retires exactly 1175 persistent B column passes");
            check(nonpacked_tile_load_count == 264,
                  "scratch attention S8 GEMMs retire exactly 264 row-major column passes");
        end else begin
            check(packed_model_gemm_count == 0,
                  "legacy mode emits no packed-v3 descriptors");
            check(fp16_gemm_count == 0,
                  "legacy mode keeps all GEMMs on the promoted FP32 path");
            check(fp16_scratch_gemm_count == 0,
                  "legacy scratch GEMMs remain FP32");
            check(packed_model_tile_load_count == 0,
                  "legacy mode retires no packed tile loads");
            check(nonpacked_tile_load_count == 732,
                  "legacy E05 retires all 732 tiles through the 162-word contract");
        end
        check(gemm_read_contract_failures == 0,
              "every GEMM tile obeys its 146-word or 162-word read contract");
        check(gemm_layout_monitor_failures == 0,
              "blocked flag agrees with MODEL/SCRATCH command routing");
        check(
            layer_request_count == 12,
            "all 12 layer parameter-table handshakes completed"
        );
        check(
            parameter_request_count == 101,
            "all 101 parameter command handshakes completed"
        );
        check(
            class_result_count == 1,
            "exactly one class result was produced"
        );

        if ((DUT_ARRAY_ROWS == 2) && (DUT_ARRAY_COLS == 2))
            check(
                ddr_read_count == EXPECTED_READS,
                "default 2x2 E05 schedule has exact AXI read traffic"
            );
        else if ((DUT_ARRAY_ROWS == 4) && (DUT_ARRAY_COLS == 2))
            check(
                ddr_read_count == EXPECTED_R4_READS,
                "M4-R4 E05 schedule has exact AXI read traffic"
            );
        else if ((DUT_ARRAY_ROWS == 8) && (DUT_ARRAY_COLS == 2)) begin
            if (DUT_EXECUTION_MODE == 3)
                check(
                    ddr_read_count == EXPECTED_PACKED_R8_READS,
                    "M7 packed-R8 E05 has exact external u32 read payload"
                );
            else
                check(
                    ddr_read_count == EXPECTED_R8_READS,
                    "M5-R8 E05 schedule has exact external FP32 read payload"
                );
        end
        else if (
            (DUT_ARRAY_ROWS > 2) &&
            (DUT_ARRAY_COLS == 2)
        )
            check(
                ddr_read_count < EXPECTED_READS,
                "taller E05 tile reduces AXI read traffic"
            );
        else
            check(
                ddr_read_count > 0,
                "non-default E05 tile produces AXI read traffic"
            );
        check(
            ddr_write_count == EXPECTED_WRITES,
            "complete 249-command E05 schedule has exact AXI write traffic"
        );
        check(
            ddr_write_count == scratch_write_count,
            "every AXI write targets SCRATCH"
        );
        check(
            ddr_read_count ==
                model_read_count + input_read_count + scratch_read_count,
            "all AXI reads map to exactly one DDR region"
        );
        check(model_read_count > 0, "MODEL region was read");
        check(input_read_count > 0, "INPUT region was read");
        check(scratch_read_count > 0, "SCRATCH region was read");
        check(invalid_access_count == 0, "no AXI access crossed a region boundary");

        check(u_ddr.model_min_word == 0, "MODEL minimum word offset is zero");
        check(
            u_ddr.model_max_word == EXPECTED_MODEL_MAX_WORD,
            "MODEL maximum word offset stays inside configured limit"
        );
        check(u_ddr.input_min_word == 0, "INPUT minimum word offset is zero");
        check(
            u_ddr.input_max_word == INPUT_WORDS - 1,
            "INPUT maximum word offset reaches but does not cross its limit"
        );
        check(u_ddr.scratch_min_word == 0, "SCRATCH minimum word offset is zero");
        check(
            u_ddr.scratch_max_word == EXPECTED_SCRATCH_MAX_WORD,
            "SCRATCH maximum word offset stays inside configured limit"
        );

        for (verify_index = 0; verify_index < HIDDEN_WORDS;
             verify_index = verify_index + 1) begin
            check(
                u_ddr.scratch_memory[
                    PHASE_E_ADDR_HIDDEN_A + verify_index
                ] == FP32_POS_ZERO,
                "final HIDDEN_A is +0"
            );
            check(
                u_ddr.scratch_memory[
                    PHASE_E_ADDR_HIDDEN_B + verify_index
                ] == FP32_POS_ZERO,
                "final HIDDEN_B is +0"
            );
        end
        for (verify_index = 0; verify_index < CLASS_WORDS;
             verify_index = verify_index + 1)
            check(
                u_ddr.scratch_memory[
                    PHASE_E_ADDR_LOGITS + verify_index
                ] ==
                    ((verify_index == TARGET_CLASS)
                        ? FP32_SEVEN : FP32_POS_ZERO),
                "classifier logits match compact golden"
            );

        axi_lite_write(REG_IRQ_STATUS, 32'h0000_0001);
        @(posedge aclk);
        check(!irq_o, "RW1C clears the done IRQ");
        axi_lite_read(REG_IRQ_STATUS, read_data);
        check(read_data == 32'd0, "IRQ status reads clear");

        if (failures == 0) begin
            $display(
                "VIT_PHASE_E_AXI_E05_COMPACT_RTL_E2E_PASS mode=%0d rows=%0d cols=%0d checks=%0d cycles=%0d job_cycles=%0d commands=%0d blocked_gemm=%0d packed_gemm=%0d fp16_gemm=%0d row_major_gemm=%0d packed_tiles=%0d nonpacked_tiles=%0d reads=%0d writes=%0d axi_stalls=%0d model_reads=%0d input_reads=%0d scratch_reads=%0d cmd_active=%0d logical_reads=%0d cache_hits=%0d valid_mac=%0d tail_mac=%0d class=%0d logit=%08x",
                DUT_EXECUTION_MODE,
                DUT_ARRAY_ROWS,
                DUT_ARRAY_COLS,
                checks,
                cycle_count,
                monitored_job_cycles,
                checkpoint_count,
                blocked_model_gemm_count,
                packed_model_gemm_count,
                fp16_gemm_count,
                row_major_scratch_gemm_count,
                packed_model_tile_load_count,
                nonpacked_tile_load_count,
                ddr_read_count,
                ddr_write_count,
                monitored_axi_stall_cycles,
                model_read_count,
                input_read_count,
                scratch_read_count,
                profile_global_value[
                    PHASE_E_PROFILE_GLOBAL_COMMAND_ACTIVE
                ],
                profile_global_value[
                    PHASE_E_PROFILE_GLOBAL_LOGICAL_READ
                ],
                profile_global_value[
                    PHASE_E_PROFILE_GLOBAL_CACHE_HIT
                ],
                profile_global_value[
                    PHASE_E_PROFILE_GLOBAL_VALID_MAC
                ],
                profile_global_value[
                    PHASE_E_PROFILE_GLOBAL_TAIL_MAC
                ],
                TARGET_CLASS,
                FP32_SEVEN
            );
            $finish;
        end else begin
            $fatal(
                1,
                "VIT_PHASE_E_AXI_E05_COMPACT_RTL_E2E_FAIL checks=%0d failures=%0d",
                checks,
                failures
            );
        end
    end

    initial begin
        repeat (WATCHDOG_CYCLES)
            @(posedge aclk);
        $fatal(
            1,
            "AXI compact E05 watchdog timeout after %0d cycles",
            WATCHDOG_CYCLES
        );
    end

endmodule
