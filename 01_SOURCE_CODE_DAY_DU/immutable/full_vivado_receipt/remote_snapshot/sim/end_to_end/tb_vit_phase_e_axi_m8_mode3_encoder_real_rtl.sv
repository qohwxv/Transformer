`timescale 1ns/1ps

// Additive M8 package-v3/mode-3 test for one complete full-dimension encoder
// layer selected at runtime (E02 for layer 0, E03 for layers 1..11).
//
//   AXI4-Lite BFM -> vit_phase_e_axi_bd_wrapper
//                 -> production vit_phase_e_npu / engine
//                 -> production native-128 AXI memory adapter
//                 -> native-128 three-region AXI DDR model
//
// The test does not define VIT_PURE_SV_BEHAVIORAL and does not override any
// ViT-Base dimension.  It emits structural/protocol/traffic/status/counter
// evidence and a raw 197x768 output dump.  A separate Python gate binds that
// dump to an independently pinned T004 FP32 golden and, in chain mode, to the
// preceding M8 layer PASS report.
module tb_vit_phase_e_axi_m8_mode3_encoder_real_rtl;

    import vit_phase_e_pkg::*;

    localparam integer AXI_ADDR_WIDTH = 40;
    localparam integer AXI_ID_WIDTH = 1;

    localparam integer TOKEN_COUNT = 197;
    localparam integer HIDDEN_SIZE = 768;
    localparam integer HEAD_COUNT = 12;
    localparam integer INTERMEDIATE_SIZE = 3072;
    localparam integer HIDDEN_WORDS = TOKEN_COUNT * HIDDEN_SIZE;
    localparam integer SCORE_WORDS =
        HEAD_COUNT * TOKEN_COUNT * TOKEN_COUNT;
    localparam integer FC1_WORDS = TOKEN_COUNT * INTERMEDIATE_SIZE;

    // Canonical package-v3 U32-storage layout.  Every encoder layer occupies
    // exactly 0x00362700 words.  Persistent GEMM-B tensors are packed FP16
    // K16/N2; vectors remain FP32.
    localparam logic [31:0] LAYER0_MODEL_BASE = 32'h000c_bb00;
    localparam logic [31:0] LAYER_MODEL_WORDS = 32'h0036_2700;
    localparam logic [31:0] LN1_GAMMA_REL = 32'h0000_0000;
    localparam logic [31:0] LN1_BETA_REL = 32'h0000_0300;
    localparam logic [31:0] Q_WEIGHT_REL = 32'h0000_0600;
    localparam logic [31:0] Q_BIAS_REL = 32'h0004_8600;
    localparam logic [31:0] K_WEIGHT_REL = 32'h0004_8900;
    localparam logic [31:0] K_BIAS_REL = 32'h0009_0900;
    localparam logic [31:0] V_WEIGHT_REL = 32'h0009_0c00;
    localparam logic [31:0] V_BIAS_REL = 32'h000d_8c00;
    localparam logic [31:0] O_WEIGHT_REL = 32'h000d_8f00;
    localparam logic [31:0] O_BIAS_REL = 32'h0012_0f00;
    localparam logic [31:0] LN2_GAMMA_REL = 32'h0012_1200;
    localparam logic [31:0] LN2_BETA_REL = 32'h0012_1500;
    localparam logic [31:0] FC1_WEIGHT_REL = 32'h0012_1800;
    localparam logic [31:0] FC1_BIAS_REL = 32'h0024_1800;
    localparam logic [31:0] FC2_WEIGHT_REL = 32'h0024_2400;
    localparam logic [31:0] FC2_BIAS_REL = 32'h0036_2400;

    localparam integer QKV_WEIGHT_WORDS = 294_912;
    localparam integer FC_WEIGHT_WORDS = 1_179_648;
    localparam integer LAYER_PARAMETER_WORDS = 3_548_928;
    localparam integer MODEL_BACKING_WORDS = 43_421_440;
    localparam logic [31:0] MODEL_PACKAGE_V3_WORDS = 32'h0296_8f00;
    localparam integer INPUT_BACKING_WORDS = 1;
    localparam integer SCRATCH_WORDS = PHASE_E_SCRATCH_WORDS;

    localparam logic [63:0] MODEL_BASE =
        64'h0000_0010_0000_0000;
    localparam logic [63:0] INPUT_BASE =
        64'h0000_0020_0000_0000;
    localparam logic [63:0] SCRATCH_BASE =
        64'h0000_0030_0000_0000;

    localparam logic [7:0] JOB_TAG = 8'h30;
    localparam integer EXPECTED_COMMANDS = 20;
    localparam integer EXPECTED_PARAMETER_REQUESTS = 8;
    localparam integer EXPECTED_WRITES =
        (15 * HIDDEN_WORDS) + (3 * SCORE_WORDS) + (2 * FC1_WORDS);
    localparam logic [31:0] EXPECTED_SCRATCH_MIN =
        PHASE_E_ADDR_HIDDEN_A;
    localparam logic [31:0] EXPECTED_SCRATCH_MAX =
        PHASE_E_ADDR_FC1 + FC1_WORDS - 1;

    localparam logic [31:0] FP32_SENTINEL = 32'hdead_beef;
    localparam logic [63:0] WATCHDOG_CYCLES = 64'd20_000_000_000;
    localparam logic [1:0] AXI_RESP_OKAY = 2'b00;

    localparam logic [11:0] REG_IP_ID = 12'h000;
    localparam logic [11:0] REG_IP_VERSION = 12'h004;
    localparam logic [11:0] REG_CONTROL = 12'h008;
    localparam logic [11:0] REG_STATUS = 12'h00c;
    localparam logic [11:0] REG_IRQ_ENABLE = 12'h010;
    localparam logic [11:0] REG_IRQ_STATUS = 12'h014;
    localparam logic [11:0] REG_ERROR_CODE = 12'h018;
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
    localparam logic [11:0] REG_JOB_CONFIG = 12'h0a0;
    localparam logic [11:0] REG_JOB_PATCH_BASE = 12'h0a4;
    localparam logic [11:0] REG_LAYER0_BASE = 12'h400;
    localparam logic [11:0] REG_PROFILE_GLOBAL_BASE = 12'h1a0;
    localparam logic [11:0] REG_HIST_OVERFLOW = 12'h724;
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

    // Source-derived one-layer projections of the exact full-E05 schedule.
    // Panel/FIFO ownership covers the six persistent packed-B GEMMs; QK/PV
    // remain scratch-B commands and still contribute to term/result totals.
    localparam logic [63:0] EXPECTED_FP16_TERMS = 64'd1_477_785_600;
    localparam logic [63:0] EXPECTED_DISABLED_TERMS = 64'd23_831_040;
    localparam logic [63:0] EXPECTED_DOT_VECTORS = 64'd251_100;
    localparam logic [63:0] EXPECTED_PANELS = 64'd11_059_200;
    localparam logic [63:0] EXPECTED_FIFO_RESULTS = 64'd172_800;

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
    logic [31:0] invalid_access_count;
    logic [31:0] ddr_protocol_error_count;
    logic [31:0] ddr_four_kib_error_count;
    logic [31:0] ddr_read_outstanding;
    logic [31:0] ddr_write_outstanding;
    logic [31:0] ddr_read_outstanding_high_water;

    logic [63:0] cycle_count = 64'd0;
    logic perf_monitor_running = 1'b0;
    logic [63:0] monitored_job_cycles = 64'd0;
    integer checks = 0;
    integer failures = 0;
    integer command_count = 0;
    integer checkpoint_count = 0;
    integer parameter_request_count = 0;
    integer layer_request_count = 0;
    integer layer_request_high_cycle_count = 0;
    integer class_result_count = 0;
    integer initialize_index;
    integer output_nonfinite_count;
    integer output_sentinel_count;
    integer layer_request_smoke_wait_cycles;
    integer asset_evidence_fd;
    integer output_fd;
    integer layer_plusarg_status;
    integer profile_index;
    logic [1:0] response;
    logic [31:0] read_data;
    logic [31:0] job_config_value;
    logic [31:0] selected_layer_base;
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
    logic [31:0] expected_model_min;
    logic [31:0] expected_model_max;
    integer selected_layer;
    logic [3:0] selected_layer_index;
    logic [2:0] selected_phase;
    logic [11:0] selected_layer_register_base;
    logic [63:0] perf_value;
    logic [63:0] profile_logical_reads;
    logic [63:0] profile_r_beats;
    logic [63:0] profile_cache_hits;
    logic [63:0] profile_bias_lookups;
    logic [63:0] profile_bias_hits;
    logic [63:0] profile_bias_misses;
    logic [63:0] m5_axi_counter [0:7];
    logic [63:0] m7_counter [0:22];
    logic [31:0] m7_status_value;
    string asset_dir_path;
    string input_hex_path;
    string asset_evidence_json_path;
    string output_dump_path;
    string parameter_hex_path [0:15];

    always #1 aclk = ~aclk;

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

    task automatic check(
        input logic condition,
        input string message
    );
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $error(
                    "M8 MODE3 ENCODER REAL AXI CHECK FAILED layer=%0d cycle=%0d: %s",
                    selected_layer,
                    cycle_count,
                    message
                );
            end
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
            check(response == AXI_RESP_OKAY, "AXI-Lite write response");
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
            check(response == AXI_RESP_OKAY, "AXI-Lite read response");
        end
    endtask

    task automatic read_counter64(
        input logic [11:0] address,
        output logic [63:0] value
    );
        logic [31:0] low_word;
        logic [31:0] high_word;
        begin
            axi_lite_read(address, low_word);
            axi_lite_read(address + 12'd4, high_word);
            value = {high_word, low_word};
        end
    endtask

    task automatic program_selected_layer_table;
        begin
            axi_lite_write(selected_layer_register_base + 12'h000, ln1_gamma_base);
            axi_lite_write(selected_layer_register_base + 12'h004, ln1_beta_base);
            axi_lite_write(selected_layer_register_base + 12'h008, q_weight_base);
            axi_lite_write(selected_layer_register_base + 12'h00c, q_bias_base);
            axi_lite_write(selected_layer_register_base + 12'h010, k_weight_base);
            axi_lite_write(selected_layer_register_base + 12'h014, k_bias_base);
            axi_lite_write(selected_layer_register_base + 12'h018, v_weight_base);
            axi_lite_write(selected_layer_register_base + 12'h01c, v_bias_base);
            axi_lite_write(selected_layer_register_base + 12'h020, o_weight_base);
            axi_lite_write(selected_layer_register_base + 12'h024, o_bias_base);
            axi_lite_write(selected_layer_register_base + 12'h028, ln2_gamma_base);
            axi_lite_write(selected_layer_register_base + 12'h02c, ln2_beta_base);
            axi_lite_write(selected_layer_register_base + 12'h030, fc1_weight_base);
            axi_lite_write(selected_layer_register_base + 12'h034, fc1_bias_base);
            axi_lite_write(selected_layer_register_base + 12'h038, fc2_weight_base);
            axi_lite_write(selected_layer_register_base + 12'h03c, fc2_bias_base);
        end
    endtask

    // No E05 shape override: every selected E02/E03 layer uses ViT-Base shape.
    vit_phase_e_axi_bd_wrapper #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH)
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

    // Backpressure/fault injection is covered by focused gates.  The no-stall
    // mode keeps this full-size encoder test bounded while the same model
    // continues to check every native-128 AXI frame, lane and response.
    vit_axi_ddr_model_128 #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MODEL_WORDS(MODEL_BACKING_WORDS),
        .INPUT_WORDS(INPUT_BACKING_WORDS),
        .SCRATCH_WORDS(SCRATCH_WORDS),
        .MODEL_BASE(MODEL_BASE),
        .INPUT_BASE(INPUT_BASE),
        .SCRATCH_BASE(SCRATCH_BASE),
        .MAX_BURST_BEATS(4),
        .READ_QUEUE_DEPTH(4),
        .WRITE_QUEUE_DEPTH(2),
        .W_QUEUE_DEPTH(4),
        .STALL_ENABLE(1'b0)
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
        .read_outstanding_high_water_o(ddr_read_outstanding_high_water),
        .write_outstanding_high_water_o()
    );

    always @(posedge aclk) begin
        cycle_count <= cycle_count + 1'b1;
        if (!aresetn) begin
            perf_monitor_running <= 1'b0;
            monitored_job_cycles <= 64'd0;
            command_count <= 0;
            checkpoint_count <= 0;
            parameter_request_count <= 0;
            layer_request_count <= 0;
            layer_request_high_cycle_count <= 0;
            class_result_count <= 0;
        end else begin
            if (dut.u_core.perf_start_accept) begin
                perf_monitor_running <= 1'b1;
                monitored_job_cycles <= 64'd0;
            end else if (perf_monitor_running) begin
                monitored_job_cycles <= monitored_job_cycles + 64'd1;
                if (dut.u_core.npu_done)
                    perf_monitor_running <= 1'b0;
            end
            if (
                dut.u_core.u_npu.command_valid &&
                dut.u_core.u_npu.command_ready
            ) begin
                check(
                    command_count < EXPECTED_COMMANDS,
                    "no command beyond the twenty-step layer"
                );
                if (command_count < EXPECTED_COMMANDS) begin
                    check(
                        dut.u_core.u_npu.command.header.opcode ==
                            expected_opcode(command_count),
                        "command opcode follows encoder step order"
                    );
                    check(
                        dut.u_core.u_npu.command.header.tag ==
                            JOB_TAG + command_count[7:0],
                        "command tag follows ordinal"
                    );
                    check(
                        dut.u_core.u_npu.command.header.reserved[7:6] ==
                            PHASE_E_SECTION_ENCODER,
                        "command section is ENCODER"
                    );
                    check(
                        dut.u_core.u_npu.command.header.reserved[5:2] ==
                            selected_layer_index,
                        "command layer matches runtime selection"
                    );
                end
                command_count <= command_count + 1;
            end

            if (dut.u_core.checkpoint_valid) begin
                check(
                    dut.u_core.checkpoint_phase == selected_phase,
                    "checkpoint phase matches E02/E03 selection"
                );
                check(
                    dut.u_core.checkpoint_section ==
                        PHASE_E_SECTION_ENCODER,
                    "checkpoint section is ENCODER"
                );
                check(
                    dut.u_core.checkpoint_layer == selected_layer_index,
                    "checkpoint layer matches runtime selection"
                );
                check(
                    dut.u_core.checkpoint_step ==
                        checkpoint_count[4:0],
                    "checkpoint step is ordered"
                );
                checkpoint_count <= checkpoint_count + 1;
            end

            if (dut.u_core.operand_load_request)
                parameter_request_count <= parameter_request_count + 1;
            if (dut.u_core.layer_param_request)
                layer_request_high_cycle_count <=
                    layer_request_high_cycle_count + 1;
            if (
                dut.u_core.layer_param_request &&
                dut.u_core.layer_param_valid
            ) begin
                check(
                    dut.u_core.layer_param_index == selected_layer_index,
                    "completed layer-table request selects the runtime layer"
                );
                layer_request_count <= layer_request_count + 1;
            end
            if (dut.u_core.class_result_valid)
                class_result_count <= class_result_count + 1;

            if (
                dut.u_core.npu_busy &&
                (cycle_count != 0) &&
                (
                    (
                        (cycle_count < 64'd10_000_000) &&
                        ((cycle_count % 64'd1_000_000) == 0)
                    ) ||
                    (
                        (cycle_count >= 64'd10_000_000) &&
                        ((cycle_count % 64'd50_000_000) == 0)
                    )
                )
            )
                begin
                    $display(
                        "M8_MODE3_ENCODER_PROGRESS layer=%0d cycles=%0d commands=%0d checkpoints=%0d reads=%0d writes=%0d model_reads=%0d scratch_reads=%0d",
                        selected_layer,
                        cycle_count,
                        command_count,
                        checkpoint_count,
                        ddr_read_count,
                        ddr_write_count,
                        model_read_count,
                        scratch_read_count
                    );
                    $fflush();
                end

            if (cycle_count >= WATCHDOG_CYCLES)
                $fatal(
                    1,
                    "M8 encoder layer %0d AXI watchdog after %0d cycles",
                    selected_layer,
                    WATCHDOG_CYCLES
                );
        end
    end

    initial begin
        selected_layer = -1;
        layer_plusarg_status = $value$plusargs(
            "M8_MODE3_ENCODER_LAYER=%d", selected_layer
        );
        if (layer_plusarg_status != 1 || selected_layer < 0 || selected_layer > 11)
            $fatal(1, "M8_MODE3_ENCODER_LAYER must select 0..11");
        if (!$value$plusargs("M8_MODE3_ENCODER_ASSET_DIR=%s", asset_dir_path))
            $fatal(1, "missing M8 encoder asset-directory plusarg");
        if (!$value$plusargs("M8_MODE3_ENCODER_INPUT_HEX=%s", input_hex_path))
            $fatal(1, "missing M8 encoder runtime-input plusarg");
        if (!$value$plusargs(
                "M8_MODE3_ENCODER_ASSET_EVIDENCE_JSON=%s",
                asset_evidence_json_path))
            $fatal(1, "missing M8 encoder asset-evidence plusarg");
        if (!$value$plusargs("M8_MODE3_ENCODER_OUTPUT_DUMP=%s", output_dump_path))
            $fatal(1, "missing M8 encoder output-dump plusarg");

        parameter_hex_path[0] = $sformatf("%s/ln1_gamma_f32.hex", asset_dir_path);
        parameter_hex_path[1] = $sformatf("%s/ln1_beta_f32.hex", asset_dir_path);
        parameter_hex_path[2] = $sformatf("%s/q_weight_packed_fp16_u32.hex", asset_dir_path);
        parameter_hex_path[3] = $sformatf("%s/q_bias_f32.hex", asset_dir_path);
        parameter_hex_path[4] = $sformatf("%s/k_weight_packed_fp16_u32.hex", asset_dir_path);
        parameter_hex_path[5] = $sformatf("%s/k_bias_f32.hex", asset_dir_path);
        parameter_hex_path[6] = $sformatf("%s/v_weight_packed_fp16_u32.hex", asset_dir_path);
        parameter_hex_path[7] = $sformatf("%s/v_bias_f32.hex", asset_dir_path);
        parameter_hex_path[8] = $sformatf("%s/o_weight_packed_fp16_u32.hex", asset_dir_path);
        parameter_hex_path[9] = $sformatf("%s/o_bias_f32.hex", asset_dir_path);
        parameter_hex_path[10] = $sformatf("%s/ln2_gamma_f32.hex", asset_dir_path);
        parameter_hex_path[11] = $sformatf("%s/ln2_beta_f32.hex", asset_dir_path);
        parameter_hex_path[12] = $sformatf("%s/fc1_weight_packed_fp16_u32.hex", asset_dir_path);
        parameter_hex_path[13] = $sformatf("%s/fc1_bias_f32.hex", asset_dir_path);
        parameter_hex_path[14] = $sformatf("%s/fc2_weight_packed_fp16_u32.hex", asset_dir_path);
        parameter_hex_path[15] = $sformatf("%s/fc2_bias_f32.hex", asset_dir_path);

        selected_layer_index = selected_layer[3:0];
        selected_phase = (selected_layer == 0) ? PHASE_E_E02 : PHASE_E_E03;
        selected_layer_base = LAYER0_MODEL_BASE + selected_layer * LAYER_MODEL_WORDS;
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
        expected_model_min = ln1_gamma_base;
        expected_model_max = fc2_bias_base + HIDDEN_SIZE - 1;
        selected_layer_register_base = REG_LAYER0_BASE + selected_layer * 12'h040;

        asset_evidence_fd = $fopen(asset_evidence_json_path, "r");
        if (asset_evidence_fd == 0)
            $fatal(1, "cannot open M8 encoder asset evidence");
        $fclose(asset_evidence_fd);
        output_fd = $fopen(output_dump_path, "w");
        if (output_fd == 0)
            $fatal(1, "cannot create M8 encoder output dump");
        $fclose(output_fd);

        $display(
            "M8_MODE3_ENCODER_PRELOAD_BEGIN layer=%0d phase=%0d tensors=18 parameter_words=%0d",
            selected_layer,
            selected_phase,
            LAYER_PARAMETER_WORDS
        );
        $fflush();

        for (initialize_index = 0;
             initialize_index < SCRATCH_WORDS;
             initialize_index = initialize_index + 1)
            u_ddr.scratch_memory[initialize_index] = FP32_SENTINEL;
        $readmemh(input_hex_path, u_ddr.scratch_memory,
                  PHASE_E_ADDR_HIDDEN_A,
                  PHASE_E_ADDR_HIDDEN_A + HIDDEN_WORDS - 1);

        $readmemh(parameter_hex_path[0], u_ddr.model_memory,
                  ln1_gamma_base, ln1_gamma_base + HIDDEN_SIZE - 1);
        $readmemh(parameter_hex_path[1], u_ddr.model_memory,
                  ln1_beta_base, ln1_beta_base + HIDDEN_SIZE - 1);
        $readmemh(parameter_hex_path[2], u_ddr.model_memory,
                  q_weight_base, q_weight_base + QKV_WEIGHT_WORDS - 1);
        $readmemh(parameter_hex_path[3], u_ddr.model_memory,
                  q_bias_base, q_bias_base + HIDDEN_SIZE - 1);
        $readmemh(parameter_hex_path[4], u_ddr.model_memory,
                  k_weight_base, k_weight_base + QKV_WEIGHT_WORDS - 1);
        $readmemh(parameter_hex_path[5], u_ddr.model_memory,
                  k_bias_base, k_bias_base + HIDDEN_SIZE - 1);
        $readmemh(parameter_hex_path[6], u_ddr.model_memory,
                  v_weight_base, v_weight_base + QKV_WEIGHT_WORDS - 1);
        $readmemh(parameter_hex_path[7], u_ddr.model_memory,
                  v_bias_base, v_bias_base + HIDDEN_SIZE - 1);
        $readmemh(parameter_hex_path[8], u_ddr.model_memory,
                  o_weight_base, o_weight_base + QKV_WEIGHT_WORDS - 1);
        $readmemh(parameter_hex_path[9], u_ddr.model_memory,
                  o_bias_base, o_bias_base + HIDDEN_SIZE - 1);
        $readmemh(parameter_hex_path[10], u_ddr.model_memory,
                  ln2_gamma_base, ln2_gamma_base + HIDDEN_SIZE - 1);
        $readmemh(parameter_hex_path[11], u_ddr.model_memory,
                  ln2_beta_base, ln2_beta_base + HIDDEN_SIZE - 1);
        $readmemh(parameter_hex_path[12], u_ddr.model_memory,
                  fc1_weight_base, fc1_weight_base + FC_WEIGHT_WORDS - 1);
        $readmemh(parameter_hex_path[13], u_ddr.model_memory,
                  fc1_bias_base, fc1_bias_base + INTERMEDIATE_SIZE - 1);
        $readmemh(parameter_hex_path[14], u_ddr.model_memory,
                  fc2_weight_base, fc2_weight_base + FC_WEIGHT_WORDS - 1);
        $readmemh(parameter_hex_path[15], u_ddr.model_memory,
                  fc2_bias_base, fc2_bias_base + HIDDEN_SIZE - 1);
        $display(
            "M8_MODE3_ENCODER_PRELOAD_DONE layer=%0d input_words=%0d package_words=%0d layer_parameter_words=%0d",
            selected_layer,
            HIDDEN_WORDS,
            MODEL_PACKAGE_V3_WORDS,
            LAYER_PARAMETER_WORDS
        );
        $fflush();

        repeat (8)
            @(posedge aclk);
        @(negedge aclk);
        aresetn = 1'b1;

        axi_lite_read(REG_IP_ID, read_data);
        check(read_data == 32'h5649_544e, "IP identity register");
        axi_lite_read(REG_IP_VERSION, read_data);
        check(read_data == 32'h0001_000d, "M8 IP identity is v1.13");

        axi_lite_write(REG_MODEL_BASE_LO, MODEL_BASE[31:0]);
        axi_lite_write(REG_MODEL_BASE_HI, MODEL_BASE[63:32]);
        axi_lite_write(REG_INPUT_BASE_LO, INPUT_BASE[31:0]);
        axi_lite_write(REG_INPUT_BASE_HI, INPUT_BASE[63:32]);
        axi_lite_write(REG_SCRATCH_BASE_LO, SCRATCH_BASE[31:0]);
        axi_lite_write(REG_SCRATCH_BASE_HI, SCRATCH_BASE[63:32]);
        axi_lite_write(REG_MODEL_WORDS, MODEL_PACKAGE_V3_WORDS);
        axi_lite_write(REG_INPUT_WORDS, INPUT_BACKING_WORDS);
        axi_lite_write(REG_SCRATCH_WORDS, SCRATCH_WORDS);
        program_selected_layer_table();
        axi_lite_write(REG_EXECUTION_MODE, 32'h0000_0003);
        axi_lite_read(REG_EXECUTION_MODE, read_data);
        check(read_data == 32'h0000_0003,
              "package-v3 execution mode 3 is selected");

        job_config_value = 32'd0;
        job_config_value[2:0] = selected_phase;
        job_config_value[6:3] = selected_layer_index;
        job_config_value[10:7] = selected_layer_index;
        job_config_value[12] = 1'b1;
        job_config_value[20:13] = JOB_TAG;
        axi_lite_write(REG_JOB_CONFIG, job_config_value);
        axi_lite_write(REG_JOB_PATCH_BASE, 32'd0);
        axi_lite_write(REG_IRQ_ENABLE, 32'h0000_0001);

        axi_lite_read(REG_STATUS, read_data);
        check(read_data[0] && !read_data[1], "idle before START");
        check(!read_data[2] && !read_data[3], "flags clear before START");

        if ($test$plusargs("M8_MODE3_ENCODER_PLUSARG_SMOKE_ONLY")) begin
            check(selected_layer_base[4:0] == 0,
                  "selected package-v3 layer base is 128-bit aligned");
            check(expected_model_max < MODEL_PACKAGE_V3_WORDS,
                  "selected package-v3 layer stays inside MODEL_WORDS");
            check(q_weight_base[4:0] == 0 && k_weight_base[4:0] == 0 &&
                  v_weight_base[4:0] == 0 && o_weight_base[4:0] == 0 &&
                  fc1_weight_base[4:0] == 0 && fc2_weight_base[4:0] == 0,
                  "all six packed weights are 128-byte aligned");
            $display(
                "M8_MODE3_ENCODER_PLUSARG_SMOKE_PASS checks=%0d layer=%0d phase=%0d files=18 package_words=43421440 layer_words=3548928 mode=3 ip=0001000d geometry=R8C2L16S8",
                checks,
                selected_layer,
                selected_phase
            );
            $finish;
        end

        axi_lite_write(REG_CONTROL, 32'h0000_0001);
        axi_lite_read(REG_STATUS, read_data);
        check(read_data[1] && !read_data[0], "BUSY after START");
        $display(
            "M8_MODE3_ENCODER_STARTED layer=%0d phase=%0d cycle=%0d expected_commands=%0d expected_writes=%0d",
            selected_layer,
            selected_phase,
            cycle_count,
            EXPECTED_COMMANDS,
            EXPECTED_WRITES
        );
        $fflush();

        if ($test$plusargs(
                "M8_MODE3_ENCODER_LAYER_REQUEST_SMOKE_ONLY")) begin
            layer_request_smoke_wait_cycles = 0;
            while (
                (layer_request_count == 0) &&
                (layer_request_smoke_wait_cycles < 200)
            ) begin
                @(posedge aclk);
                layer_request_smoke_wait_cycles =
                    layer_request_smoke_wait_cycles + 1;
            end
            check(
                layer_request_count == 1,
                "layer-request smoke observes one completed transaction"
            );
            check(
                layer_request_high_cycle_count > layer_request_count,
                "layer-request smoke observes the held request contract"
            );
            check(
                dut.u_core.layer_param_index == selected_layer_index,
                "layer-request smoke preserves the selected layer"
            );
            if (failures == 0) begin
                $display(
                    "M8_MODE3_ENCODER_LAYER_REQUEST_SMOKE_PASS checks=%0d layer=%0d phase=%0d completions=%0d high_cycles=%0d",
                    checks,
                    selected_layer,
                    selected_phase,
                    layer_request_count,
                    layer_request_high_cycle_count
                );
                $finish;
            end else begin
                $fatal(
                    1,
                    "M8 layer-request smoke failures=%0d checks=%0d",
                    failures,
                    checks
                );
            end
        end

        wait (irq_o);

        axi_lite_read(REG_STATUS, read_data);
        check(read_data[0] && !read_data[1], "idle after completion");
        check(read_data[2] && !read_data[3], "DONE without ERROR");
        check(read_data[4], "STATUS reflects IRQ");
        axi_lite_read(REG_IRQ_STATUS, read_data);
        check(read_data[0] && !read_data[1], "done IRQ is sticky");
        axi_lite_read(REG_ERROR_CODE, read_data);
        check(read_data == 32'd0, "error code is zero");

        output_nonfinite_count = 0;
        output_sentinel_count = 0;
        for (initialize_index = 0;
             initialize_index < HIDDEN_WORDS;
             initialize_index = initialize_index + 1) begin
            if (!fp32_is_finite(u_ddr.scratch_memory[
                    PHASE_E_ADDR_HIDDEN_A + initialize_index]))
                output_nonfinite_count = output_nonfinite_count + 1;
            if (u_ddr.scratch_memory[
                    PHASE_E_ADDR_HIDDEN_A + initialize_index] === FP32_SENTINEL)
                output_sentinel_count = output_sentinel_count + 1;
        end
        $display(
            "M8_MODE3_ENCODER_OUTPUT_STRUCTURE layer=%0d words=%0d nonfinite=%0d sentinel=%0d",
            selected_layer,
            HIDDEN_WORDS,
            output_nonfinite_count,
            output_sentinel_count
        );
        check(output_nonfinite_count == 0,
              "all 151296 encoder outputs are finite");
        check(output_sentinel_count == 0,
              "all 151296 encoder outputs replace the sentinel");
        $writememh(output_dump_path, u_ddr.scratch_memory,
                   PHASE_E_ADDR_HIDDEN_A,
                   PHASE_E_ADDR_HIDDEN_A + HIDDEN_WORDS - 1);

        $display(
            "M8_MODE3_ENCODER_TERMINAL_COUNTS layer=%0d commands=%0d checkpoints=%0d parameter_requests=%0d layer_request_completions=%0d layer_request_high_cycles=%0d class_results=%0d",
            selected_layer,
            command_count,
            checkpoint_count,
            parameter_request_count,
            layer_request_count,
            layer_request_high_cycle_count,
            class_result_count
        );
        $fflush();

        check(command_count == EXPECTED_COMMANDS, "twenty commands issued");
        check(
            checkpoint_count == EXPECTED_COMMANDS,
            "twenty command checkpoints observed"
        );
        check(
            parameter_request_count == EXPECTED_PARAMETER_REQUESTS,
            "eight parameter-bearing commands observed"
        );
        check(
            layer_request_count == 1,
            "one completed layer-table transaction observed"
        );
        check(
            layer_request_high_cycle_count >= layer_request_count,
            "held layer-table request covers every completed transaction"
        );
        check(class_result_count == 0, "encoder emits no class result");

        check(
            ddr_write_count == EXPECTED_WRITES,
            "exact encoder-layer scratch write count"
        );
        check(
            scratch_write_count == ddr_write_count,
            "all writes target SCRATCH"
        );
        check(model_read_count > 0, "MODEL was read");
        check(input_read_count == 0, "E02 did not read INPUT");
        check(scratch_read_count > 0, "SCRATCH was read");
        check(
            ddr_read_count == model_read_count + scratch_read_count,
            "every read maps to MODEL or SCRATCH"
        );
        check(invalid_access_count == 0, "no invalid AXI access");
        check(ddr_protocol_error_count == 0 && ddr_four_kib_error_count == 0,
              "DDR model reports no AXI protocol or 4KiB error");
        check(ddr_aw_transaction_count == ddr_write_count &&
                  ddr_w_beat_count == ddr_write_count &&
                  ddr_b_response_count == ddr_write_count,
              "all narrow writes have one AW/W/B frame");
        check(ddr_aw_requested_beat_count == ddr_w_beat_count,
              "requested and delivered write beats agree");
        check(ddr_ar_requested_beat_count == ddr_r_beat_count,
              "requested and delivered read beats agree");
        check(ddr_read_outstanding == 0 && ddr_write_outstanding == 0,
              "all AXI traffic drains before DONE snapshot");
        check(ddr_read_outstanding_high_water >= 1 &&
                  ddr_read_outstanding_high_water <= 2,
              "native-128 read outstanding stays within depth two");
        check(
            u_ddr.model_min_word == expected_model_min,
            "MODEL minimum is selected-layer LN1 gamma"
        );
        check(
            u_ddr.model_max_word == expected_model_max,
            "MODEL maximum is selected-layer FC2 bias end"
        );
        check(
            u_ddr.scratch_min_word == EXPECTED_SCRATCH_MIN,
            "SCRATCH minimum is HIDDEN_A"
        );
        check(
            u_ddr.scratch_max_word == EXPECTED_SCRATCH_MAX,
            "SCRATCH maximum is FC1 end"
        );

        axi_lite_read(REG_PERF_CAPABILITY, read_data);
        check(read_data == 32'h0001_001f,
              "performance-counter capability schema is v1.2 compatible");
        read_counter64(REG_JOB_CYCLES_LO, perf_value);
        check(perf_value == monitored_job_cycles,
              "published job cycles match independent edge monitor");
        read_counter64(REG_COMMANDS_LO, perf_value);
        check(perf_value == EXPECTED_COMMANDS,
              "published command counter is exactly twenty");
        read_counter64(REG_AXI_READS_LO, perf_value);
        check(perf_value == ddr_ar_transaction_count,
              "published AXI AR counter matches DDR model");
        read_counter64(REG_AXI_WRITES_LO, perf_value);
        check(perf_value == ddr_aw_transaction_count,
              "published AXI AW counter matches DDR model");
        axi_lite_read(REG_PERF_STATUS, read_data);
        check(read_data == 32'h0000_0002,
              "performance snapshot is valid with no overflow/error");
        axi_lite_read(REG_HIST_OVERFLOW, read_data);
        check(read_data == 0, "wait histogram has no overflow");

        read_counter64(
            REG_PROFILE_GLOBAL_BASE +
                (PHASE_E_PROFILE_GLOBAL_LOGICAL_READ * 8),
            profile_logical_reads
        );
        read_counter64(
            REG_PROFILE_GLOBAL_BASE +
                (PHASE_E_PROFILE_GLOBAL_R_BEATS * 8),
            profile_r_beats
        );
        read_counter64(
            REG_PROFILE_GLOBAL_BASE +
                (PHASE_E_PROFILE_GLOBAL_CACHE_HIT * 8),
            profile_cache_hits
        );
        read_counter64(
            REG_PROFILE_GLOBAL_BASE +
                (PHASE_E_PROFILE_GLOBAL_BIAS_LOOKUP * 8),
            profile_bias_lookups
        );
        read_counter64(
            REG_PROFILE_GLOBAL_BASE +
                (PHASE_E_PROFILE_GLOBAL_BIAS_HIT * 8),
            profile_bias_hits
        );
        read_counter64(
            REG_PROFILE_GLOBAL_BASE +
                (PHASE_E_PROFILE_GLOBAL_BIAS_MISS * 8),
            profile_bias_misses
        );
        check(profile_r_beats == ddr_r_beat_count,
              "profile R-beat counter matches DDR model");
        check(profile_logical_reads == ddr_read_count + profile_cache_hits,
              "logical reads partition into external words and cache hits");
        check(profile_bias_lookups == profile_bias_hits + profile_bias_misses,
              "bias-cache lookups partition into hits and misses");

        axi_lite_read(REG_M5_CAPABILITY, read_data);
        check(read_data == 32'h01f2_1008,
              "M5 native-128 AXI capability schema is exact");
        axi_lite_read(REG_M5_STATUS, read_data);
        check(read_data == 32'h0000_0002,
              "M5 snapshot is valid with no running/error/status residue");
        axi_lite_read(REG_M5_OVERFLOW, read_data);
        check(read_data == 0, "M5 counter overflow mask is clear");
        axi_lite_read(REG_M5_PROTOCOL, read_data);
        check(read_data == 0, "M5 typed protocol status is clear");
        for (profile_index = 0; profile_index < 8;
             profile_index = profile_index + 1)
            read_counter64(
                REG_M5_COUNTER_BASE + (profile_index * 8),
                m5_axi_counter[profile_index]
            );
        check(m5_axi_counter[0] + m5_axi_counter[1] == ddr_r_beat_count,
              "M5 full/narrow beat classes reconstruct R beats");
        check((m5_axi_counter[0] * 4) + m5_axi_counter[1] == ddr_read_count,
              "M5 beat classes reconstruct external u32 words");
        check(m5_axi_counter[2] + m5_axi_counter[3] +
                  m5_axi_counter[7] == (m5_axi_counter[0] * 4),
              "M5 linefill starts/hits/discards partition full payload");
        check(ddr_ar_transaction_count ==
                  m5_axi_counter[1] + m5_axi_counter[2],
              "AXI AR count equals narrow requests plus linefills");
        check(m5_axi_counter[4] == 0 && m5_axi_counter[6] == 0 &&
                  m5_axi_counter[7] == 0,
              "M5 reports no split, protocol error, or discarded prefetch");
        check(m5_axi_counter[5] == ddr_read_outstanding_high_water,
              "M5 outstanding maximum matches DDR model");

        axi_lite_read(REG_M7_CAPABILITY, read_data);
        check(read_data == 32'h01ff_0817,
              "M7 exact-stage counter capability schema is exact");
        axi_lite_read(REG_M7_STATUS, m7_status_value);
        check(!m7_status_value[0] && m7_status_value[1] &&
                  !m7_status_value[2] && !m7_status_value[3],
              "M7 snapshot is valid with no running/overflow/error bit");
        axi_lite_read(REG_M7_OVF_LO, read_data);
        check(read_data == 0, "M7 low overflow mask is clear");
        axi_lite_read(REG_M7_OVF_HI, read_data);
        check(read_data == 0, "M7 high overflow mask is clear");
        axi_lite_read(REG_M7_ERROR, read_data);
        check(read_data == 0, "M7 typed error status is clear");
        axi_lite_read(REG_M7_GEOMETRY, read_data);
        check(read_data == 32'h0810_0208,
              "M7 geometry is logical R8/C2/L16 with eight streams");
        axi_lite_read(REG_M7_BUFFER_CONFIG, read_data);
        check(read_data == 32'h0008_0202,
              "M7 buffer contract is banks2/FIFO2/generation8");
        axi_lite_read(REG_M7_NUMERIC_CONFIG, read_data);
        check(read_data == 32'h07c0_d05d,
              "M7 exact FP16-product/Kulisch numeric contract is preserved");
        for (profile_index = 0; profile_index < 23;
             profile_index = profile_index + 1)
            read_counter64(
                REG_M7_COUNTER_BASE + (profile_index * 8),
                m7_counter[profile_index]
            );
        check(!m7_status_value[2] && !m7_status_value[3] &&
                  (m7_status_value[21:20] == 2'b00),
              "M7 status publishes no overflow or typed error class");
        check(m7_status_value[4] == (m7_counter[10] != 0) &&
                  m7_status_value[5] == (m7_counter[11] != 0) &&
                  m7_status_value[6] == (m7_counter[13] != 0),
              "M7 status overlap flags agree with published counters");
        check(m7_status_value[7] &&
                  (m7_status_value[9:8] == 2'b11),
              "M7 status records claims from both operand banks");
        check(m7_status_value[11:10] == m7_counter[19][1:0] &&
                  m7_status_value[15:12] == m7_counter[22][3:0],
              "M7 status occupancy maxima agree with published counters");
        check(m7_status_value[16] == (m7_counter[4] != 0) &&
                  m7_status_value[17] == (m7_counter[5] != 0) &&
                  m7_status_value[18] == (m7_counter[17] != 0) &&
                  m7_status_value[19] == (m7_counter[18] != 0),
              "M7 status wait flags agree with published counters");
        check(m7_status_value[31:22] == 10'd0,
              "M7 status reserved high bits remain zero");
        check(m7_counter[0] == EXPECTED_FP16_TERMS,
              "M7 accepted FP16-term count is exact for one encoder layer");
        check(m7_counter[1] == EXPECTED_DISABLED_TERMS,
              "M7 disabled-tail term count is exact for one encoder layer");
        check(m7_counter[0] - m7_counter[1] == 64'd1_453_954_560,
              "M7 enabled terms equal the semantic encoder MAC schedule");
        check(m7_counter[2] == EXPECTED_DOT_VECTORS &&
                  m7_counter[3] == EXPECTED_DOT_VECTORS,
              "M7 dot-start/result-vector counts are exact");
        check(m7_counter[14] == EXPECTED_PANELS &&
                  m7_counter[15] == EXPECTED_PANELS &&
                  m7_counter[16] == EXPECTED_PANELS,
              "M7 panel commit/claim/release counts are exact");
        check(m7_counter[19] >= 1 && m7_counter[19] <= 2,
              "M7 operand-bank maximum occupancy is bounded 1..2");
        check(m7_counter[20] == EXPECTED_FIFO_RESULTS &&
                  m7_counter[21] == EXPECTED_FIFO_RESULTS,
              "M7 packed-result FIFO enqueue/dequeue counts are exact");
        check(m7_counter[22] >= 1 && m7_counter[22] <= 2,
              "M7 FIFO maximum occupancy is bounded 1..2");
        check(m7_counter[9] + m7_counter[10] + m7_counter[11] +
                  m7_counter[12] ==
              m7_counter[6] + m7_counter[7] + m7_counter[8] +
                  m7_counter[13],
              "M7 load/compute/store overlap inclusion-exclusion is exact");

        $display(
            "M8_MODE3_ENCODER_TRAFFIC layer=%0d external_u32=%0d model_reads=%0d scratch_reads=%0d ar=%0d r_beats=%0d writes=%0d cache_hits=%0d bias_lookups=%0d bias_hits=%0d bias_misses=%0d",
            selected_layer, ddr_read_count, model_read_count,
            scratch_read_count, ddr_ar_transaction_count, ddr_r_beat_count,
            ddr_write_count, profile_cache_hits, profile_bias_lookups,
            profile_bias_hits, profile_bias_misses
        );
        $display(
            "M8_MODE3_ENCODER_M7_COUNTERS layer=%0d terms=%0d disabled=%0d enabled=%0d dots=%0d results=%0d panels=%0d bank_max=%0d fifo_enqueue=%0d fifo_dequeue=%0d fifo_max=%0d",
            selected_layer, m7_counter[0], m7_counter[1],
            m7_counter[0] - m7_counter[1], m7_counter[2], m7_counter[3],
            m7_counter[14], m7_counter[19], m7_counter[20],
            m7_counter[21], m7_counter[22]
        );
        $display(
            "M8_MODE3_ENCODER_OUTPUT_DUMP layer=%0d words=%0d path=%s numerical_status=PENDING_EXTERNAL_T004_GATE",
            selected_layer, HIDDEN_WORDS, output_dump_path
        );

        axi_lite_write(REG_IRQ_STATUS, 32'h0000_0001);
        @(posedge aclk);
        check(!irq_o, "RW1C clears done IRQ");
        axi_lite_read(REG_IRQ_STATUS, read_data);
        check(read_data == 32'd0, "IRQ status reads clear");

        if (failures == 0) begin
            $display(
                "VIT_PHASE_E_AXI_M8_MODE3_ENCODER_REAL_RTL_STRUCTURAL_PASS checks=%0d layer=%0d phase=%0d job_cycles=%0d testbench_cycles=%0d commands=%0d reads=%0d writes=%0d model_reads=%0d scratch_reads=%0d output_words=151296 numerical_status=PENDING_EXTERNAL_T004_GATE",
                checks,
                selected_layer,
                selected_phase,
                monitored_job_cycles,
                cycle_count,
                command_count,
                ddr_read_count,
                ddr_write_count,
                model_read_count,
                scratch_read_count
            );
            $finish;
        end else begin
            $fatal(
                1,
                "VIT_PHASE_E_AXI_M8_MODE3_ENCODER_REAL_RTL_STRUCTURAL_FAIL checks=%0d failures=%0d layer=%0d commands=%0d",
                checks,
                failures,
                selected_layer,
                command_count
            );
        end
    end

endmodule
