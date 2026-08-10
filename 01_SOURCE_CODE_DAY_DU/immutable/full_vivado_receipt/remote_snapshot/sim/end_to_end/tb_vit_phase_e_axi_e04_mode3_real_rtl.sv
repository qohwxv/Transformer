`timescale 1ns/1ps

// Production E04 mode-3 test with the real post-encoder activation and exact
// package-v3 final-tensor slices.  This test deliberately uses the exact
// Vivado module-reference top:
//
//   AXI4-Lite BFM -> vit_phase_e_axi_bd_wrapper
//                 -> production vit_phase_e_npu / engine
//                 -> production AXI4 memory adapter
//                 -> three-region AXI DDR model
//
// No behavioral-engine define is used.  The wrapper keeps its default
// ViT-Base/16-224 dimensions (197 tokens, hidden size 768, 1000 classes).
// The test emits structural/protocol evidence and raw output dumps.  Separate
// external behavioral-golden and M6-classifier gates qualify the FP16 result;
// this test never promotes a structural PASS into an accuracy PASS.
module tb_vit_phase_e_axi_e04_mode3_real_rtl;

    import vit_phase_e_pkg::*;

    localparam integer AXI_ADDR_WIDTH = 40;
    localparam integer AXI_ID_WIDTH = 1;

    localparam integer TOKEN_COUNT = 197;
    localparam integer HIDDEN_SIZE = 768;
    localparam integer CLASS_COUNT = 1000;
    localparam integer HIDDEN_WORDS = TOKEN_COUNT * HIDDEN_SIZE;

    // Exact package-v3 U32-storage-word offsets.  Every tensor start and the
    // physical MODEL base are 128-byte aligned.
    localparam logic [31:0] FINAL_LN_GAMMA_BASE = 32'h0006_d500;
    localparam logic [31:0] FINAL_LN_BETA_BASE = 32'h0006_d800;
    localparam logic [31:0] CLASSIFIER_WEIGHT_BASE = 32'h0006_db00;
    localparam logic [31:0] CLASSIFIER_BIAS_BASE = 32'h000c_b700;

    localparam integer CLASSIFIER_WEIGHT_WORDS =
        ((HIDDEN_SIZE + 15) / 16) * ((CLASS_COUNT + 1) / 2) * 16;
    localparam integer MODEL_BACKING_WORDS =
        CLASSIFIER_BIAS_BASE + CLASS_COUNT;
    localparam logic [31:0] MODEL_PACKAGE_V3_WORDS = 32'h0296_8f00;
    localparam integer INPUT_BACKING_WORDS = 1;
    localparam integer SCRATCH_WORDS = PHASE_E_SCRATCH_WORDS;

    localparam logic [63:0] MODEL_BASE =
        64'h0000_0010_0000_0000;
    localparam logic [63:0] INPUT_BASE =
        64'h0000_0020_0000_0000;
    localparam logic [63:0] SCRATCH_BASE =
        64'h0000_0030_0000_0000;

    localparam logic [31:0] GOLDEN_CLASS = 32'd879;
    localparam logic [7:0] JOB_TAG = 8'h40;
    localparam logic [31:0] FP32_SENTINEL = 32'hdead_beef;

    localparam integer EXPECTED_COMMANDS = 5;
    localparam integer EXPECTED_WRITES =
        HIDDEN_WORDS + HIDDEN_SIZE + CLASS_COUNT + CLASS_COUNT;
    localparam integer WATCHDOG_CYCLES = 80_000_000;

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
    localparam logic [11:0] REG_COMMANDS_LO = 12'h058;
    localparam logic [11:0] REG_AXI_READS_LO = 12'h060;
    localparam logic [11:0] REG_AXI_WRITES_LO = 12'h068;
    localparam logic [11:0] REG_GLOBAL_BASE = 12'h080;
    localparam logic [11:0] REG_JOB_CONFIG = 12'h0a0;
    localparam logic [11:0] REG_JOB_PATCH_BASE = 12'h0a4;
    localparam logic [11:0] REG_CLASS_INDEX = 12'h180;
    localparam logic [11:0] REG_CLASS_LOGIT = 12'h184;
    localparam logic [11:0] REG_PROFILE_GLOBAL_BASE = 12'h1a0;
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

    longint cycle_count = 0;
    integer checks = 0;
    integer failures = 0;
    integer command_count = 0;
    integer checkpoint_count = 0;
    integer parameter_request_count = 0;
    integer layer_request_count = 0;
    integer class_result_count = 0;
    integer initialize_index;
    integer asset_evidence_fd;
    integer class_result_fd;
    logic [1:0] response;
    logic [31:0] read_data;
    logic [31:0] job_config_value;
    logic [31:0] captured_class_index = 32'd0;
    logic [31:0] captured_class_logit = 32'h7fc0_0000;
    logic [31:0] register_class_logit = 32'h7fc0_0000;
    integer final_ln_nonfinite_count;
    integer logits_nonfinite_count;
    integer probabilities_nonfinite_count;
    integer final_ln_sentinel_count;
    integer logits_sentinel_count;
    integer probabilities_sentinel_count;
    integer layout_copy_mismatches;
    integer profile_index;
    logic [63:0] perf_read_value;
    logic [63:0] profile_logical_reads;
    logic [63:0] profile_r_beats;
    logic [63:0] profile_cache_hits;
    logic [63:0] profile_read_histogram_sum;
    logic [63:0] profile_histogram_value;
    logic [63:0] m5_axi_counter [0:7];
    string activation_hex_path;
    string final_ln_gamma_hex_path;
    string final_ln_beta_hex_path;
    string classifier_weight_hex_path;
    string classifier_bias_hex_path;
    string asset_evidence_json_path;
    string final_ln_dump_path;
    string logits_dump_path;
    string probabilities_dump_path;
    string class_result_dump_path;

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

    task automatic check(
        input logic condition,
        input string message
    );
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $error(
                    "E04 REAL AXI CHECK FAILED cycle=%0d: %s",
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

    // No shape override: this is the production ViT-Base wrapper.
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

    // The allocated backing ends exactly after the last global tensor used by
    // E04.  The control register below still advertises the full v1 package,
    // so the production adapter sees the board ABI rather than a compact ABI.
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

    always @(posedge aclk) begin
        cycle_count <= cycle_count + 1'b1;
        if (!aresetn) begin
            command_count <= 0;
            checkpoint_count <= 0;
            parameter_request_count <= 0;
            layer_request_count <= 0;
            class_result_count <= 0;
            captured_class_index <= 32'd0;
            captured_class_logit <= 32'h7fc0_0000;
        end else begin
            if (
                dut.u_core.u_npu.command_valid &&
                dut.u_core.u_npu.command_ready
            ) begin
                check(
                    dut.u_core.u_npu.command.header.tag ==
                        JOB_TAG + command_count,
                    "command tag is exact E04 ordinal"
                );
                case (command_count)
                    0: begin
                        check(
                            dut.u_core.u_npu.command.header.opcode ==
                                PHASE_E_OP_LAYERNORM &&
                            dut.u_core.u_npu.command.header.flags ==
                                PHASE_E_FLAG_CHECKPOINT,
                            "command 0 is exact checkpointed final LayerNorm"
                        );
                        check(
                            dut.u_core.u_npu.command.route.src0_tensor ==
                                PHASE_E_TENSOR_HIDDEN_A &&
                            dut.u_core.u_npu.command.route.src1_tensor ==
                                PHASE_E_TENSOR_WEIGHT &&
                            dut.u_core.u_npu.command.route.src2_tensor ==
                                PHASE_E_TENSOR_BIAS &&
                            dut.u_core.u_npu.command.route.dst_tensor ==
                                PHASE_E_TENSOR_HIDDEN_B &&
                            dut.u_core.u_npu.command.route.src0_space ==
                                PHASE_E_MEM_SCRATCH &&
                            dut.u_core.u_npu.command.route.src1_space ==
                                PHASE_E_MEM_PARAM &&
                            dut.u_core.u_npu.command.route.src2_space ==
                                PHASE_E_MEM_PARAM &&
                            dut.u_core.u_npu.command.route.dst_space ==
                                PHASE_E_MEM_SCRATCH,
                            "final LayerNorm route is exact"
                        );
                        check(
                            dut.u_core.u_npu.command.src0_base ==
                                PHASE_E_ADDR_HIDDEN_A &&
                            dut.u_core.u_npu.command.src1_base ==
                                FINAL_LN_GAMMA_BASE &&
                            dut.u_core.u_npu.command.src2_base ==
                                FINAL_LN_BETA_BASE &&
                            dut.u_core.u_npu.command.dst_base ==
                                PHASE_E_ADDR_HIDDEN_B &&
                            dut.u_core.u_npu.command.dim0 == TOKEN_COUNT &&
                            dut.u_core.u_npu.command.dim1 == HIDDEN_SIZE &&
                            dut.u_core.u_npu.command.immediate ==
                                VIT_LN_EPSILON_FP32,
                            "final LayerNorm bases/dimensions/epsilon are exact"
                        );
                    end
                    1: begin
                        check(
                            dut.u_core.u_npu.command.header.opcode ==
                                PHASE_E_OP_LAYOUT &&
                            dut.u_core.u_npu.command.header.subop ==
                                PHASE_E_SUBOP_LAYOUT_COPY &&
                            dut.u_core.u_npu.command.header.flags ==
                                PHASE_E_FLAG_CHECKPOINT,
                            "command 1 is exact checkpointed CLS layout"
                        );
                        check(
                            dut.u_core.u_npu.command.route.src0_tensor ==
                                PHASE_E_TENSOR_HIDDEN_B &&
                            dut.u_core.u_npu.command.route.dst_tensor ==
                                PHASE_E_TENSOR_LINEAR_TMP &&
                            dut.u_core.u_npu.command.route.src0_space ==
                                PHASE_E_MEM_SCRATCH &&
                            dut.u_core.u_npu.command.route.dst_space ==
                                PHASE_E_MEM_SCRATCH &&
                            dut.u_core.u_npu.command.src0_base ==
                                PHASE_E_ADDR_HIDDEN_B &&
                            dut.u_core.u_npu.command.dst_base ==
                                PHASE_E_ADDR_LINEAR_TMP,
                            "CLS layout route/bases are exact"
                        );
                        check(
                            dut.u_core.u_npu.command.dim0 == 32'd1 &&
                            dut.u_core.u_npu.command.dim1 == 32'd1 &&
                            dut.u_core.u_npu.command.dim2 == HIDDEN_SIZE &&
                            dut.u_core.u_npu.command.stride0 == 32'd0 &&
                            dut.u_core.u_npu.command.stride1 == 32'd0 &&
                            dut.u_core.u_npu.command.stride2 == 32'd1,
                            "CLS layout dimensions/strides are exact"
                        );
                    end
                    2: begin
                        check(
                            dut.u_core.u_npu.command.header.opcode ==
                                PHASE_E_OP_GEMM &&
                            dut.u_core.u_npu.command.header.flags ==
                                (PHASE_E_FLAG_CHECKPOINT |
                                 PHASE_E_FLAG_BIAS_ENABLE |
                                 PHASE_E_FLAG_GEMM_CACHE_SAFE |
                                 PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2 |
                                 PHASE_E_FLAG_GEMM_FP16 |
                                 PHASE_E_FLAG_GEMM_B_FP16_PACKED2),
                            "command 2 is exact checkpointed packed-FP16 classifier GEMM"
                        );
                        check(
                            dut.u_core.u_npu.command.route.src0_tensor ==
                                PHASE_E_TENSOR_LINEAR_TMP &&
                            dut.u_core.u_npu.command.route.src1_tensor ==
                                PHASE_E_TENSOR_WEIGHT &&
                            dut.u_core.u_npu.command.route.src2_tensor ==
                                PHASE_E_TENSOR_BIAS &&
                            dut.u_core.u_npu.command.route.dst_tensor ==
                                PHASE_E_TENSOR_LOGITS &&
                            dut.u_core.u_npu.command.route.src0_space ==
                                PHASE_E_MEM_SCRATCH &&
                            dut.u_core.u_npu.command.route.src1_space ==
                                PHASE_E_MEM_PARAM &&
                            dut.u_core.u_npu.command.route.src2_space ==
                                PHASE_E_MEM_PARAM &&
                            dut.u_core.u_npu.command.route.dst_space ==
                                PHASE_E_MEM_SCRATCH,
                            "classifier GEMM route is exact"
                        );
                        check(
                            dut.u_core.u_npu.command.src0_base ==
                                PHASE_E_ADDR_LINEAR_TMP &&
                            dut.u_core.u_npu.command.src1_base ==
                                CLASSIFIER_WEIGHT_BASE &&
                            dut.u_core.u_npu.command.src2_base ==
                                CLASSIFIER_BIAS_BASE &&
                            dut.u_core.u_npu.command.dst_base ==
                                PHASE_E_ADDR_LOGITS,
                            "classifier GEMM bases are exact"
                        );
                        check(
                            dut.u_core.u_npu.command.dim0 == 32'd1 &&
                            dut.u_core.u_npu.command.dim1 == 32'd1 &&
                            dut.u_core.u_npu.command.dim2 == HIDDEN_SIZE &&
                            dut.u_core.u_npu.command.dim3 == CLASS_COUNT,
                            "classifier GEMM shape is 1x1x768x1000"
                        );
                        check(
                            dut.u_core.u_npu.command.stride0 == HIDDEN_SIZE &&
                            dut.u_core.u_npu.command.stride1 == HIDDEN_SIZE &&
                            dut.u_core.u_npu.command.stride2 == 32'd0 &&
                            dut.u_core.u_npu.command.stride3 == 32'd768 &&
                            dut.u_core.u_npu.command.stride4 == CLASS_COUNT &&
                            dut.u_core.u_npu.command.immediate == CLASS_COUNT,
                            "classifier GEMM strides are exact for packed K768/N1000"
                        );
                    end
                    3: begin
                        check(
                            dut.u_core.u_npu.command.header.opcode ==
                                PHASE_E_OP_ARGMAX &&
                            dut.u_core.u_npu.command.header.flags ==
                                PHASE_E_FLAG_CHECKPOINT,
                            "command 3 is exact checkpointed Argmax"
                        );
                        check(
                            dut.u_core.u_npu.command.route.src0_tensor ==
                                PHASE_E_TENSOR_LOGITS &&
                            dut.u_core.u_npu.command.route.src0_space ==
                                PHASE_E_MEM_SCRATCH &&
                            dut.u_core.u_npu.command.src0_base ==
                                PHASE_E_ADDR_LOGITS &&
                            dut.u_core.u_npu.command.dim0 == CLASS_COUNT,
                            "Argmax route/base/length are exact"
                        );
                    end
                    4: begin
                        check(
                            dut.u_core.u_npu.command.header.opcode ==
                                PHASE_E_OP_SOFTMAX &&
                            dut.u_core.u_npu.command.header.flags ==
                                PHASE_E_FLAG_CHECKPOINT,
                            "command 4 is exact checkpointed class Softmax"
                        );
                        check(
                            dut.u_core.u_npu.command.route.src0_tensor ==
                                PHASE_E_TENSOR_LOGITS &&
                            dut.u_core.u_npu.command.route.dst_tensor ==
                                PHASE_E_TENSOR_CLASS_PROB &&
                            dut.u_core.u_npu.command.route.src0_space ==
                                PHASE_E_MEM_SCRATCH &&
                            dut.u_core.u_npu.command.route.dst_space ==
                                PHASE_E_MEM_SCRATCH &&
                            dut.u_core.u_npu.command.src0_base ==
                                PHASE_E_ADDR_LOGITS &&
                            dut.u_core.u_npu.command.dst_base ==
                                PHASE_E_ADDR_CLASS_PROB &&
                            dut.u_core.u_npu.command.dim0 == 32'd1 &&
                            dut.u_core.u_npu.command.dim1 == CLASS_COUNT,
                            "class Softmax route/bases/dimensions are exact"
                        );
                    end
                    default:
                        check(1'b0, "unexpected extra production command");
                endcase
                command_count <= command_count + 1;
            end

            if (dut.u_core.checkpoint_valid) begin
                check(
                    dut.u_core.checkpoint_phase == PHASE_E_E04,
                    "checkpoint phase is E04"
                );
                check(
                    dut.u_core.checkpoint_section ==
                        PHASE_E_SECTION_FINAL,
                    "checkpoint section is FINAL"
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
                layer_request_count <= layer_request_count + 1;
            if (dut.u_core.class_result_valid) begin
                class_result_count <= class_result_count + 1;
                captured_class_index <= dut.u_core.class_index;
                captured_class_logit <= dut.u_core.class_logit;
            end

            if (
                dut.u_core.npu_busy &&
                (cycle_count != 0) &&
                ((cycle_count % 5_000_000) == 0)
            )
                $display(
                    "E04_REAL_AXI_PROGRESS cycles=%0d commands=%0d checkpoints=%0d reads=%0d writes=%0d",
                    cycle_count,
                    command_count,
                    checkpoint_count,
                    ddr_read_count,
                    ddr_write_count
                );
        end
    end

    initial begin
        if (!$value$plusargs(
                "M7_MODE3_ACTIVATION_HEX=%s", activation_hex_path))
            $fatal(1, "missing +M7_MODE3_ACTIVATION_HEX absolute path");
        if (!$value$plusargs(
                "M7_MODE3_FINAL_LN_GAMMA_HEX=%s",
                final_ln_gamma_hex_path))
            $fatal(1, "missing +M7_MODE3_FINAL_LN_GAMMA_HEX absolute path");
        if (!$value$plusargs(
                "M7_MODE3_FINAL_LN_BETA_HEX=%s",
                final_ln_beta_hex_path))
            $fatal(1, "missing +M7_MODE3_FINAL_LN_BETA_HEX absolute path");
        if (!$value$plusargs(
                "M7_MODE3_CLASSIFIER_WEIGHT_HEX=%s",
                classifier_weight_hex_path))
            $fatal(1, "missing +M7_MODE3_CLASSIFIER_WEIGHT_HEX absolute path");
        if (!$value$plusargs(
                "M7_MODE3_CLASSIFIER_BIAS_HEX=%s",
                classifier_bias_hex_path))
            $fatal(1, "missing +M7_MODE3_CLASSIFIER_BIAS_HEX absolute path");
        if (!$value$plusargs(
                "M7_MODE3_ASSET_EVIDENCE_JSON=%s",
                asset_evidence_json_path))
            $fatal(1, "missing +M7_MODE3_ASSET_EVIDENCE_JSON absolute path");
        if (!$value$plusargs(
                "M7_MODE3_FINAL_LN_DUMP=%s", final_ln_dump_path))
            $fatal(1, "missing +M7_MODE3_FINAL_LN_DUMP absolute path");
        if (!$value$plusargs(
                "M7_MODE3_LOGITS_DUMP=%s", logits_dump_path))
            $fatal(1, "missing +M7_MODE3_LOGITS_DUMP absolute path");
        if (!$value$plusargs(
                "M7_MODE3_PROBABILITIES_DUMP=%s",
                probabilities_dump_path))
            $fatal(1, "missing +M7_MODE3_PROBABILITIES_DUMP absolute path");
        if (!$value$plusargs(
                "M7_MODE3_CLASS_RESULT_DUMP=%s",
                class_result_dump_path))
            $fatal(1, "missing +M7_MODE3_CLASS_RESULT_DUMP absolute path");

        asset_evidence_fd = $fopen(asset_evidence_json_path, "r");
        if (asset_evidence_fd == 0)
            $fatal(1, "cannot open staged asset evidence JSON");
        $fclose(asset_evidence_fd);
        $display(
            "M7_MODE3_E04_ASSET_PATHS activation=%s gamma=%s beta=%s weight=%s bias=%s evidence=%s",
            activation_hex_path,
            final_ln_gamma_hex_path,
            final_ln_beta_hex_path,
            classifier_weight_hex_path,
            classifier_bias_hex_path,
            asset_evidence_json_path
        );

        // The activation is the preserved real encoder-11 handoff.  The four
        // model slices are staged directly from package-v3 storage and are
        // never reconstructed or repacked inside the testbench.
        $readmemh(
            activation_hex_path,
            u_ddr.scratch_memory,
            PHASE_E_ADDR_HIDDEN_A,
            PHASE_E_ADDR_HIDDEN_A + HIDDEN_WORDS - 1
        );
        $readmemh(
            final_ln_gamma_hex_path,
            u_ddr.model_memory,
            FINAL_LN_GAMMA_BASE,
            FINAL_LN_GAMMA_BASE + HIDDEN_SIZE - 1
        );
        $readmemh(
            final_ln_beta_hex_path,
            u_ddr.model_memory,
            FINAL_LN_BETA_BASE,
            FINAL_LN_BETA_BASE + HIDDEN_SIZE - 1
        );
        $readmemh(
            classifier_weight_hex_path,
            u_ddr.model_memory,
            CLASSIFIER_WEIGHT_BASE,
            CLASSIFIER_WEIGHT_BASE + CLASSIFIER_WEIGHT_WORDS - 1
        );
        $readmemh(
            classifier_bias_hex_path,
            u_ddr.model_memory,
            CLASSIFIER_BIAS_BASE,
            CLASSIFIER_BIAS_BASE + CLASS_COUNT - 1
        );

        for (initialize_index = 0;
             initialize_index < HIDDEN_WORDS;
             initialize_index = initialize_index + 1)
            u_ddr.scratch_memory[
                PHASE_E_ADDR_HIDDEN_B + initialize_index
            ] = FP32_SENTINEL;
        for (initialize_index = 0;
             initialize_index < HIDDEN_SIZE;
             initialize_index = initialize_index + 1)
            u_ddr.scratch_memory[
                PHASE_E_ADDR_LINEAR_TMP + initialize_index
            ] = FP32_SENTINEL;
        for (initialize_index = 0;
             initialize_index < CLASS_COUNT;
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
            MODEL_BASE[6:0] == 7'd0 &&
            FINAL_LN_GAMMA_BASE[4:0] == 5'd0 &&
            FINAL_LN_BETA_BASE[4:0] == 5'd0 &&
            CLASSIFIER_WEIGHT_BASE[4:0] == 5'd0 &&
            CLASSIFIER_BIAS_BASE[4:0] == 5'd0,
            "physical MODEL base and all v3 E04 slices are 128B aligned"
        );
        check(
            CLASSIFIER_WEIGHT_WORDS == 384000 &&
            CLASSIFIER_WEIGHT_BASE + CLASSIFIER_WEIGHT_WORDS <=
                CLASSIFIER_BIAS_BASE,
            "v3 classifier is exactly 384000 packed u32 words without bias overlap"
        );

        axi_lite_write(REG_MODEL_BASE_LO, MODEL_BASE[31:0]);
        axi_lite_write(REG_MODEL_BASE_HI, MODEL_BASE[63:32]);
        axi_lite_write(REG_INPUT_BASE_LO, INPUT_BASE[31:0]);
        axi_lite_write(REG_INPUT_BASE_HI, INPUT_BASE[63:32]);
        axi_lite_write(REG_SCRATCH_BASE_LO, SCRATCH_BASE[31:0]);
        axi_lite_write(REG_SCRATCH_BASE_HI, SCRATCH_BASE[63:32]);
        axi_lite_write(REG_MODEL_WORDS, MODEL_PACKAGE_V3_WORDS);
        axi_lite_write(REG_INPUT_WORDS, INPUT_BACKING_WORDS);
        axi_lite_write(REG_SCRATCH_WORDS, SCRATCH_WORDS);

        // Only the four final offsets are consumed by E04.  The four
        // embedding offsets remain zero and are never dereferenced.
        axi_lite_write(REG_GLOBAL_BASE + 12'h010, FINAL_LN_GAMMA_BASE);
        axi_lite_write(REG_GLOBAL_BASE + 12'h014, FINAL_LN_BETA_BASE);
        axi_lite_write(REG_GLOBAL_BASE + 12'h018, CLASSIFIER_WEIGHT_BASE);
        axi_lite_write(REG_GLOBAL_BASE + 12'h01c, CLASSIFIER_BIAS_BASE);
        // v1.13 retains modes 3 and 5 only. Check both legal encodings at the
        // actual wrapper seam, then leave the job configured for packed-v3
        // mode 3.  No START is issued while mode 5 is selected.
        axi_lite_write(REG_EXECUTION_MODE, 32'h0000_0005);
        axi_lite_read(REG_EXECUTION_MODE, read_data);
        check(read_data == 32'h0000_0005 && dut.u_core.execution_mode_legal,
              "v1.13 compatibility mode 5 is legal");
        axi_lite_write(REG_EXECUTION_MODE, 32'h0000_0003);
        axi_lite_read(REG_EXECUTION_MODE, read_data);
        check(read_data == 32'h0000_0003 && dut.u_core.execution_mode_legal,
              "v1.13 packed-v3 execution mode 3 is legal and selected");

        // Build gates use this explicit early-exit path to prove that every
        // absolute plusarg is accepted, every staged slice loads at its v3
        // address, and the v1.13 mode seam is live without starting the heavy
        // production-size E04 workload.
        if ($test$plusargs("M7_MODE3_PLUSARG_SMOKE_ONLY")) begin
            check(MODEL_PACKAGE_V3_WORDS == 32'd43421440,
                  "v3 MODEL_WORDS is exactly 43421440");
            check(MODEL_BACKING_WORDS == 834280,
                  "E04 sparse backing ends after classifier bias");
            check(CLASSIFIER_WEIGHT_WORDS == 384000,
                  "staged classifier span is 384000 packed u32 words");
            axi_lite_read(REG_M7_CAPABILITY, read_data);
            check(read_data == 32'h01ff_0817,
                  "M7 capability is present in plusarg smoke");
            axi_lite_read(REG_M7_GEOMETRY, read_data);
            check(read_data == 32'h0810_0208,
                  "M7 smoke geometry is logical R8/C2/L16 with S8 streams");
            $display(
                "M7_MODE3_E04_PLUSARG_SMOKE_PASS checks=%0d model_words=43421440 backing_words=834280 packed_classifier_words=384000 mode=3 ip=0001000d geometry=R8C2L16S8",
                checks
            );
            $finish;
        end

        job_config_value = 32'd0;
        job_config_value[2:0] = PHASE_E_E04;
        job_config_value[11] = 1'b1;
        job_config_value[12] = 1'b1;
        job_config_value[20:13] = JOB_TAG;
        axi_lite_write(REG_JOB_CONFIG, job_config_value);
        axi_lite_write(REG_JOB_PATCH_BASE, 32'd0);
        axi_lite_write(REG_IRQ_ENABLE, 32'h0000_0001);

        axi_lite_read(REG_STATUS, read_data);
        check(read_data[0] && !read_data[1], "idle before START");
        check(!read_data[2] && !read_data[3], "flags clear before START");

        axi_lite_write(REG_CONTROL, 32'h0000_0001);
        axi_lite_read(REG_STATUS, read_data);
        check(read_data[1] && !read_data[0], "BUSY after START");

        wait (irq_o);

        axi_lite_read(REG_STATUS, read_data);
        check(read_data[0] && !read_data[1], "idle after completion");
        check(read_data[2] && !read_data[3], "DONE without ERROR");
        check(read_data[4], "STATUS reflects IRQ");
        axi_lite_read(REG_IRQ_STATUS, read_data);
        check(read_data[0] && !read_data[1], "done IRQ is sticky");
        axi_lite_read(REG_ERROR_CODE, read_data);
        check(read_data == 32'd0, "error code is zero");
        axi_lite_read(REG_CLASS_INDEX, read_data);
        check(read_data == captured_class_index,
              "AXI-Lite and sideband class indices agree");
        check(read_data == GOLDEN_CLASS,
              "AXI-Lite class index is exact expected class 879");
        axi_lite_read(REG_CLASS_LOGIT, read_data);
        register_class_logit = read_data;
        check(fp32_is_finite(register_class_logit), "class logit is finite");
        check(
            captured_class_logit == register_class_logit,
            "sideband and AXI-Lite class logits agree"
        );
        check(
            register_class_logit ==
                u_ddr.scratch_memory[PHASE_E_ADDR_LOGITS + GOLDEN_CLASS],
            "class register logit equals scratch logits[879]"
        );

        // Keep the RTL gate structural and deterministic.  Every produced
        // FP32 word must be finite and must replace the sentinel; raw dumps
        // are then qualified by the external M6 numerical oracle.
        final_ln_nonfinite_count = 0;
        logits_nonfinite_count = 0;
        probabilities_nonfinite_count = 0;
        final_ln_sentinel_count = 0;
        logits_sentinel_count = 0;
        probabilities_sentinel_count = 0;
        layout_copy_mismatches = 0;

        for (initialize_index = 0;
             initialize_index < HIDDEN_WORDS;
             initialize_index = initialize_index + 1) begin
            if (!fp32_is_finite(u_ddr.scratch_memory[
                    PHASE_E_ADDR_HIDDEN_B + initialize_index]))
                final_ln_nonfinite_count = final_ln_nonfinite_count + 1;
            if (u_ddr.scratch_memory[
                    PHASE_E_ADDR_HIDDEN_B + initialize_index] ===
                FP32_SENTINEL)
                final_ln_sentinel_count = final_ln_sentinel_count + 1;
        end

        for (initialize_index = 0;
             initialize_index < HIDDEN_SIZE;
             initialize_index = initialize_index + 1)
            if (
                u_ddr.scratch_memory[
                    PHASE_E_ADDR_LINEAR_TMP + initialize_index
                ] !== u_ddr.scratch_memory[
                    PHASE_E_ADDR_HIDDEN_B + initialize_index
                ]
            )
                layout_copy_mismatches = layout_copy_mismatches + 1;

        for (initialize_index = 0;
             initialize_index < CLASS_COUNT;
             initialize_index = initialize_index + 1) begin
            if (!fp32_is_finite(u_ddr.scratch_memory[
                    PHASE_E_ADDR_LOGITS + initialize_index]))
                logits_nonfinite_count = logits_nonfinite_count + 1;
            if (u_ddr.scratch_memory[
                    PHASE_E_ADDR_LOGITS + initialize_index] ===
                FP32_SENTINEL)
                logits_sentinel_count = logits_sentinel_count + 1;
            if (!fp32_is_finite(u_ddr.scratch_memory[
                    PHASE_E_ADDR_CLASS_PROB + initialize_index]))
                probabilities_nonfinite_count =
                    probabilities_nonfinite_count + 1;
            if (u_ddr.scratch_memory[
                    PHASE_E_ADDR_CLASS_PROB + initialize_index] ===
                FP32_SENTINEL)
                probabilities_sentinel_count =
                    probabilities_sentinel_count + 1;
        end

        $display(
            "M7_MODE3_E04_OUTPUT_STRUCTURE final_ln_words=%0d final_ln_nonfinite=%0d final_ln_sentinel=%0d layout_mismatch=%0d logits_words=%0d logits_nonfinite=%0d logits_sentinel=%0d probabilities_words=%0d probabilities_nonfinite=%0d probabilities_sentinel=%0d",
            HIDDEN_WORDS,
            final_ln_nonfinite_count,
            final_ln_sentinel_count,
            layout_copy_mismatches,
            CLASS_COUNT,
            logits_nonfinite_count,
            logits_sentinel_count,
            CLASS_COUNT,
            probabilities_nonfinite_count,
            probabilities_sentinel_count
        );
        check(final_ln_nonfinite_count == 0,
              "all 151296 final LayerNorm words are finite");
        check(final_ln_sentinel_count == 0,
              "all 151296 final LayerNorm words were produced");
        check(
            layout_copy_mismatches == 0,
            "CLS layout copy is bit exact for all 768 words"
        );
        check(logits_nonfinite_count == 0 && logits_sentinel_count == 0,
              "all 1000 logits are finite and produced");
        check(probabilities_nonfinite_count == 0 &&
                  probabilities_sentinel_count == 0,
              "all 1000 class probabilities are finite and produced");

        $writememh(
            final_ln_dump_path,
            u_ddr.scratch_memory,
            PHASE_E_ADDR_HIDDEN_B,
            PHASE_E_ADDR_HIDDEN_B + HIDDEN_WORDS - 1
        );
        $writememh(
            logits_dump_path,
            u_ddr.scratch_memory,
            PHASE_E_ADDR_LOGITS,
            PHASE_E_ADDR_LOGITS + CLASS_COUNT - 1
        );
        $writememh(
            probabilities_dump_path,
            u_ddr.scratch_memory,
            PHASE_E_ADDR_CLASS_PROB,
            PHASE_E_ADDR_CLASS_PROB + CLASS_COUNT - 1
        );
        class_result_fd = $fopen(class_result_dump_path, "w");
        if (class_result_fd == 0)
            $fatal(1, "cannot open class-result dump");
        $fdisplay(class_result_fd, "%08x", captured_class_index);
        $fdisplay(class_result_fd, "%08x", register_class_logit);
        $fclose(class_result_fd);
        $display(
            "M7_MODE3_E04_OUTPUT_DUMPS final_ln_words=%0d logits_words=%0d probabilities_words=%0d class_result_words=2 final_ln=%s logits=%s probabilities=%s class_result=%s",
            HIDDEN_WORDS,
            CLASS_COUNT,
            CLASS_COUNT,
            final_ln_dump_path,
            logits_dump_path,
            probabilities_dump_path,
            class_result_dump_path
        );
        $display(
            "M7_MODE3_E04_RESULT class=%0d logit=%08x logit_real=%0.9f numerical_status=PENDING_EXTERNAL_BEHAVIORAL_AND_M6_ORACLES",
            captured_class_index,
            register_class_logit,
            fp32_to_real(register_class_logit)
        );

        check(command_count == EXPECTED_COMMANDS, "five commands issued");
        check(
            checkpoint_count == EXPECTED_COMMANDS,
            "five command checkpoints observed"
        );
        check(
            parameter_request_count == 2,
            "LayerNorm and classifier requested operands"
        );
        check(layer_request_count == 0, "E04 requested no layer table");
        check(class_result_count == 1, "one class result produced");
        check(captured_class_index == GOLDEN_CLASS,
              "sideband class result is exact expected class 879");

        check(
            ddr_write_count == EXPECTED_WRITES,
            "exact E04 scratch write count"
        );
        check(
            scratch_write_count == ddr_write_count,
            "all writes target SCRATCH"
        );
        check(model_read_count > 0, "MODEL was read");
        check(input_read_count == 0, "E04 did not read INPUT");
        check(scratch_read_count > 0, "SCRATCH was read");
        check(
            ddr_read_count == model_read_count + scratch_read_count,
            "every useful external FP32 word maps to MODEL or SCRATCH"
        );
        check(ddr_aw_transaction_count == ddr_write_count &&
                  ddr_w_beat_count == ddr_write_count &&
                  ddr_b_response_count == ddr_write_count,
              "scalar writes have exact AW/W/B accounting");
        check(ddr_aw_requested_beat_count == ddr_w_beat_count,
              "requested and accepted W beat totals match");
        check(ddr_ar_requested_beat_count == ddr_r_beat_count,
              "requested and returned R beat totals match");
        check(ddr_protocol_error_count == 0 &&
                  ddr_four_kib_error_count == 0,
              "DDR model reports no protocol or 4 KiB violation");
        check(ddr_read_outstanding == 0 && ddr_write_outstanding == 0,
              "all AXI transactions retired before DONE");
        check(ddr_read_outstanding_high_water >= 1 &&
                  ddr_read_outstanding_high_water <= 2,
              "DDR read-outstanding high-water stays inside the M5 bound");

        // Legacy v1.1 read accounting is an AR-transaction count.  Useful
        // external FP32 words remain independently available from the DDR
        // model so a 128-bit beat is never mislabeled as one logical word.
        axi_lite_read(REG_PERF_CAPABILITY, read_data);
        check(read_data == 32'h0001_001f, "performance capability schema");
        axi_lite_read(REG_PERF_STATUS, read_data);
        check(read_data == 32'h0000_0002, "performance snapshot is valid");
        axi_lite_read64(REG_COMMANDS_LO, perf_read_value);
        check(perf_read_value == EXPECTED_COMMANDS,
              "legacy command counter matches E04 schedule");
        axi_lite_read64(REG_AXI_READS_LO, perf_read_value);
        check(perf_read_value == ddr_ar_transaction_count,
              "legacy AXI read count matches AR transactions");
        axi_lite_read64(REG_AXI_WRITES_LO, perf_read_value);
        check(perf_read_value == ddr_aw_transaction_count,
              "legacy AXI write count matches AW transactions");

        axi_lite_read64(
            REG_PROFILE_GLOBAL_BASE +
                (PHASE_E_PROFILE_GLOBAL_LOGICAL_READ * 8),
            profile_logical_reads
        );
        axi_lite_read64(
            REG_PROFILE_GLOBAL_BASE +
                (PHASE_E_PROFILE_GLOBAL_R_BEATS * 8),
            profile_r_beats
        );
        axi_lite_read64(
            REG_PROFILE_GLOBAL_BASE +
                (PHASE_E_PROFILE_GLOBAL_CACHE_HIT * 8),
            profile_cache_hits
        );
        check(profile_r_beats == ddr_r_beat_count,
              "profile R beats match physical DDR R beats");
        check(profile_logical_reads >= ddr_read_count &&
                  profile_cache_hits <= profile_logical_reads,
              "logical/cache read accounting is nonnegative and covers external u32 storage");

        axi_lite_read(REG_HIST_CAPABILITY, read_data);
        check(read_data == 32'h0108_0802, "read/write histogram schema");
        axi_lite_read(REG_HIST_OVERFLOW, read_data);
        check(read_data == 32'd0, "histogram overflow mask is clear");
        profile_read_histogram_sum = 64'd0;
        for (profile_index = 0; profile_index < 8;
             profile_index = profile_index + 1) begin
            axi_lite_read64(
                REG_HIST_BASE + (profile_index * 8),
                profile_histogram_value
            );
            profile_read_histogram_sum = profile_read_histogram_sum +
                profile_histogram_value;
        end
        check(profile_read_histogram_sum == ddr_ar_transaction_count,
              "read histogram population equals retired AR transactions");

        axi_lite_read(REG_M5_CAPABILITY, read_data);
        check(read_data == 32'h01f2_1008, "M5 AXI capability schema");
        axi_lite_read(REG_M5_STATUS, read_data);
        check(read_data[1], "M5 snapshot is valid");
        axi_lite_read(REG_M5_OVERFLOW, read_data);
        check(read_data == 32'd0, "M5 counter overflow mask is clear");
        axi_lite_read(REG_M5_PROTOCOL, read_data);
        check(read_data == 32'd0, "M5 protocol status is clear");
        for (profile_index = 0; profile_index < 8;
             profile_index = profile_index + 1)
            axi_lite_read64(
                REG_M5_COUNTER_BASE + (profile_index * 8),
                m5_axi_counter[profile_index]
            );
        $display(
            "M7_MODE3_E04_TRAFFIC cycles=%0d logical_reads=%0d cache_hits=%0d external_u32=%0d ar=%0d r_beats=%0d full_r_beats=%0d narrow_r_beats=%0d linefills=%0d line_hits=%0d writes=%0d",
            cycle_count,
            profile_logical_reads,
            profile_cache_hits,
            ddr_read_count,
            ddr_ar_transaction_count,
            ddr_r_beat_count,
            m5_axi_counter[0],
            m5_axi_counter[1],
            m5_axi_counter[2],
            m5_axi_counter[3],
            ddr_write_count
        );
        check(m5_axi_counter[0] + m5_axi_counter[1] == ddr_r_beat_count,
              "M5 full and narrow counters partition R beats");
        check(m5_axi_counter[1] + (m5_axi_counter[0] * 4) ==
                  ddr_read_count,
              "M5 beat classes reconstruct external u32 storage words");
        check(ddr_ar_transaction_count ==
                  m5_axi_counter[1] + m5_axi_counter[2],
              "packed-v3 AR count equals narrow reads plus one burst per linefill");
        check(m5_axi_counter[4] == 0 && m5_axi_counter[5] == 1 &&
                  m5_axi_counter[6] == 0 && m5_axi_counter[7] == 0,
              "packed-v3 has no split/error/discard and uses one four-beat linefill");
        axi_lite_read(REG_M7_CAPABILITY, read_data);
        check(read_data == 32'h01ff_0817, "M7 counter capability schema");
        axi_lite_read(REG_M7_STATUS, read_data);
        check(!read_data[0] && read_data[1],
              "M7 snapshot is valid and no longer running");
        axi_lite_read(REG_M7_OVF_LO, read_data);
        check(read_data == 32'd0, "M7 overflow low mask is clear");
        axi_lite_read(REG_M7_OVF_HI, read_data);
        check(read_data == 32'd0, "M7 overflow high mask is clear");
        axi_lite_read(REG_M7_ERROR, read_data);
        check(read_data == 32'd0, "M7 typed error status is clear");
        axi_lite_read(REG_M7_GEOMETRY, read_data);
        check(read_data == 32'h0810_0208,
              "M7 geometry is logical R8/C2/L16 with S8 physical streams");
        axi_lite_read(REG_M7_BUFFER_CONFIG, read_data);
        check(read_data == 32'h0008_0202,
              "M7 uses two operand banks, depth-two FIFO and eight-bit generation");
        axi_lite_read(REG_M7_NUMERIC_CONFIG, read_data);
        check(read_data == 32'h07c0_d05d, "M7 numerical contract is preserved by M8 v1.13");
        check(invalid_access_count == 0, "no invalid AXI access");
        check(
            u_ddr.model_min_word == FINAL_LN_GAMMA_BASE,
            "MODEL minimum offset is final LN gamma"
        );
        check(
            u_ddr.model_max_word ==
                CLASSIFIER_BIAS_BASE + CLASS_COUNT - 1,
            "MODEL maximum offset is classifier bias end"
        );
        check(
            u_ddr.scratch_min_word == PHASE_E_ADDR_HIDDEN_A,
            "SCRATCH minimum offset is HIDDEN_A"
        );
        check(
            u_ddr.scratch_max_word ==
                PHASE_E_ADDR_CLASS_PROB + CLASS_COUNT - 1,
            "SCRATCH maximum offset is class probability end"
        );

        axi_lite_write(REG_IRQ_STATUS, 32'h0000_0001);
        @(posedge aclk);
        check(!irq_o, "RW1C clears done IRQ");
        axi_lite_read(REG_IRQ_STATUS, read_data);
        check(read_data == 32'd0, "IRQ status reads clear");

        if (failures == 0) begin
            $display(
                "VIT_PHASE_E_AXI_E04_MODE3_REAL_RTL_STRUCTURAL_PASS checks=%0d cycles=%0d commands=%0d external_u32=%0d writes=%0d model_reads=%0d scratch_reads=%0d class=%0d logit=%08x numerical_status=PENDING_EXTERNAL_BEHAVIORAL_AND_M6_ORACLES",
                checks,
                cycle_count,
                command_count,
                ddr_read_count,
                ddr_write_count,
                model_read_count,
                scratch_read_count,
                captured_class_index,
                register_class_logit
            );
            $finish;
        end else begin
            $fatal(
                1,
                "VIT_PHASE_E_AXI_E04_MODE3_REAL_RTL_STRUCTURAL_FAIL checks=%0d failures=%0d class=%0d logit=%08x",
                checks,
                failures,
                captured_class_index,
                register_class_logit
            );
        end
    end

    initial begin
        repeat (WATCHDOG_CYCLES)
            @(posedge aclk);
        $fatal(
            1,
            "M7 mode-3 E04 real-data AXI watchdog timeout after %0d cycles",
            WATCHDOG_CYCLES
        );
    end

endmodule
