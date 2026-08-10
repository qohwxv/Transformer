`timescale 1ns/1ps

// Production E04 test with the real post-encoder activation and the real
// final model tensors.  This test deliberately uses the exact Vivado
// module-reference top:
//
//   AXI4-Lite BFM -> vit_phase_e_axi_bd_wrapper
//                 -> production vit_phase_e_npu / engine
//                 -> production AXI4 memory adapter
//                 -> three-region AXI DDR model
//
// No behavioral-engine define is used.  The wrapper keeps its default
// ViT-Base/16-224 dimensions (197 tokens, hidden size 768, 1000 classes).
module tb_vit_phase_e_axi_e04_real_rtl;

    import vit_phase_e_pkg::*;

    localparam integer AXI_ADDR_WIDTH = 40;
    localparam integer AXI_ID_WIDTH = 1;

    localparam integer TOKEN_COUNT = 197;
    localparam integer HIDDEN_SIZE = 768;
    localparam integer CLASS_COUNT = 1000;
    localparam integer HIDDEN_WORDS = TOKEN_COUNT * HIDDEN_SIZE;

    // These four global offsets are unchanged by model-package v2.
    localparam logic [31:0] FINAL_LN_GAMMA_BASE = 32'h000b_5500;
    localparam logic [31:0] FINAL_LN_BETA_BASE = 32'h000b_5800;
    localparam logic [31:0] CLASSIFIER_WEIGHT_BASE = 32'h000b_5b00;
    localparam logic [31:0] CLASSIFIER_BIAS_BASE = 32'h0017_1300;

    localparam integer CLASSIFIER_WEIGHT_WORDS =
        HIDDEN_SIZE * CLASS_COUNT;
    localparam integer MODEL_BACKING_WORDS =
        CLASSIFIER_BIAS_BASE + CLASS_COUNT;
    localparam logic [31:0] MODEL_PACKAGE_V2_WORDS = 32'h0528_eb00;
    localparam integer INPUT_BACKING_WORDS = 1;
    localparam integer SCRATCH_WORDS = PHASE_E_SCRATCH_WORDS;

    localparam logic [63:0] MODEL_BASE =
        64'h0000_0010_0000_0000;
    localparam logic [63:0] INPUT_BASE =
        64'h0000_0020_0000_0000;
    localparam logic [63:0] SCRATCH_BASE =
        64'h0000_0030_0000_0000;

    localparam logic [31:0] GOLDEN_CLASS = 32'd879;
    localparam logic [31:0] GOLDEN_LOGIT = 32'h4148_87b7;
    localparam real FINAL_LN_MAX_ABS_TOLERANCE = 1.0e-4;
    localparam real LOGIT_MAX_ABS_TOLERANCE = 1.0e-4;
    localparam real PROBABILITY_MAX_ABS_TOLERANCE = 1.0e-5;
    localparam integer CLASS_LOGIT_MAX_WORD_DELTA = 8;
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
    integer pack_n_tile;
    integer pack_k_chunk;
    integer pack_col;
    integer pack_lane;
    integer pack_src_k;
    integer pack_src_n;
    integer pack_dst;
    logic [1:0] response;
    logic [31:0] read_data;
    logic [31:0] job_config_value;
    logic [31:0] captured_class_index = 32'd0;
    logic [31:0] captured_class_logit = 32'h7fc0_0000;
    logic [31:0] register_class_logit = 32'h7fc0_0000;
    logic [31:0] golden_final_layernorm [0:HIDDEN_WORDS-1];
    logic [31:0] golden_logits [0:CLASS_COUNT-1];
    logic [31:0] golden_probabilities [0:CLASS_COUNT-1];
    logic [31:0] row_major_classifier_weight
        [0:CLASSIFIER_WEIGHT_WORDS-1];
    longint signed raw_word_delta;
    real rtl_logit_real;
    real golden_logit_real;
    real numeric_delta;
    real comparison_rtl_value;
    real comparison_golden_value;
    real comparison_abs_error;
    real final_ln_max_abs_error;
    real logits_max_abs_error;
    real probabilities_max_abs_error;
    integer final_ln_exact_mismatches;
    integer logits_exact_mismatches;
    integer probabilities_exact_mismatches;
    integer final_ln_tolerance_failures;
    integer logits_tolerance_failures;
    integer probabilities_tolerance_failures;
    integer final_ln_max_error_index;
    integer logits_max_error_index;
    integer probabilities_max_error_index;
    integer layout_copy_mismatches;
    integer profile_index;
    logic [63:0] perf_read_value;
    logic [63:0] profile_logical_reads;
    logic [63:0] profile_r_beats;
    logic [63:0] profile_cache_hits;
    logic [63:0] profile_read_histogram_sum;
    logic [63:0] profile_histogram_value;
    logic [63:0] m5_axi_counter [0:7];

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
                case (command_count)
                    0: check(
                        dut.u_core.u_npu.command.header.opcode ==
                            PHASE_E_OP_LAYERNORM,
                        "command 0 is final LayerNorm"
                    );
                    1: check(
                        dut.u_core.u_npu.command.header.opcode ==
                            PHASE_E_OP_LAYOUT,
                        "command 1 is CLS layout"
                    );
                    2: begin
                        check(
                            dut.u_core.u_npu.command.header.opcode ==
                                PHASE_E_OP_GEMM,
                            "command 2 is classifier GEMM"
                        );
                        check(
                            (dut.u_core.u_npu.command.header.flags &
                             PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2) != 0,
                            "classifier GEMM selects blocked-B layout"
                        );
                        check(
                            dut.u_core.u_npu.command.stride3 == 32'd1536,
                            "classifier blocked-B output-tile stride is 1536"
                        );
                    end
                    3: check(
                        dut.u_core.u_npu.command.header.opcode ==
                            PHASE_E_OP_ARGMAX,
                        "command 3 is Argmax"
                    );
                    4: check(
                        dut.u_core.u_npu.command.header.opcode ==
                            PHASE_E_OP_SOFTMAX,
                        "command 4 is class Softmax"
                    );
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
        // These five files are the current behavioral-golden handoff at the
        // boundary between encoder layer 11 and the production final phase.
        $readmemh(
            "results/encoder_layer_11_step_20_layer_output_f32.hex",
            u_ddr.scratch_memory,
            PHASE_E_ADDR_HIDDEN_A,
            PHASE_E_ADDR_HIDDEN_A + HIDDEN_WORDS - 1
        );
        $readmemh(
            "parameters/post_encoder_final_ln_gamma_f32.hex",
            u_ddr.model_memory,
            FINAL_LN_GAMMA_BASE,
            FINAL_LN_GAMMA_BASE + HIDDEN_SIZE - 1
        );
        $readmemh(
            "parameters/post_encoder_final_ln_beta_f32.hex",
            u_ddr.model_memory,
            FINAL_LN_BETA_BASE,
            FINAL_LN_BETA_BASE + HIDDEN_SIZE - 1
        );
        $readmemh(
            "parameters/post_encoder_classifier_weight_B_f32.hex",
            row_major_classifier_weight
        );
        for (pack_n_tile = 0; pack_n_tile < (CLASS_COUNT + 1) / 2;
             pack_n_tile = pack_n_tile + 1)
            for (pack_k_chunk = 0;
                 pack_k_chunk < (HIDDEN_SIZE + 15) / 16;
                 pack_k_chunk = pack_k_chunk + 1)
                for (pack_col = 0; pack_col < 2;
                     pack_col = pack_col + 1)
                    for (pack_lane = 0; pack_lane < 16;
                         pack_lane = pack_lane + 1) begin
                        pack_src_k = pack_k_chunk * 16 + pack_lane;
                        pack_src_n = pack_n_tile * 2 + pack_col;
                        pack_dst =
                            (((pack_n_tile * ((HIDDEN_SIZE + 15) / 16) +
                               pack_k_chunk) * 2 + pack_col) * 16 +
                             pack_lane);
                        if ((pack_src_k < HIDDEN_SIZE) &&
                            (pack_src_n < CLASS_COUNT))
                            u_ddr.model_memory[
                                CLASSIFIER_WEIGHT_BASE + pack_dst
                            ] = row_major_classifier_weight[
                                pack_src_k * CLASS_COUNT + pack_src_n
                            ];
                        else
                            u_ddr.model_memory[
                                CLASSIFIER_WEIGHT_BASE + pack_dst
                            ] = 32'h0000_0000;
                    end
        $readmemh(
            "parameters/post_encoder_classifier_bias_f32.hex",
            u_ddr.model_memory,
            CLASSIFIER_BIAS_BASE,
            CLASSIFIER_BIAS_BASE + CLASS_COUNT - 1
        );
        $readmemh(
            "results/post_encoder_step_30_final_layernorm_f32.hex",
            golden_final_layernorm
        );
        $readmemh(
            "results/post_encoder_step_32_logits_f32.hex",
            golden_logits
        );
        $readmemh(
            "results/post_encoder_step_33p_probabilities_f32.hex",
            golden_probabilities
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

        axi_lite_write(REG_MODEL_BASE_LO, MODEL_BASE[31:0]);
        axi_lite_write(REG_MODEL_BASE_HI, MODEL_BASE[63:32]);
        axi_lite_write(REG_INPUT_BASE_LO, INPUT_BASE[31:0]);
        axi_lite_write(REG_INPUT_BASE_HI, INPUT_BASE[63:32]);
        axi_lite_write(REG_SCRATCH_BASE_LO, SCRATCH_BASE[31:0]);
        axi_lite_write(REG_SCRATCH_BASE_HI, SCRATCH_BASE[63:32]);
        axi_lite_write(REG_MODEL_WORDS, MODEL_PACKAGE_V2_WORDS);
        axi_lite_write(REG_INPUT_WORDS, INPUT_BACKING_WORDS);
        axi_lite_write(REG_SCRATCH_WORDS, SCRATCH_WORDS);

        // Only the four final offsets are consumed by E04.  The four
        // embedding offsets remain zero and are never dereferenced.
        axi_lite_write(REG_GLOBAL_BASE + 12'h010, FINAL_LN_GAMMA_BASE);
        axi_lite_write(REG_GLOBAL_BASE + 12'h014, FINAL_LN_BETA_BASE);
        axi_lite_write(REG_GLOBAL_BASE + 12'h018, CLASSIFIER_WEIGHT_BASE);
        axi_lite_write(REG_GLOBAL_BASE + 12'h01c, CLASSIFIER_BIAS_BASE);
        axi_lite_write(REG_EXECUTION_MODE, 32'h0000_0001);
        axi_lite_read(REG_EXECUTION_MODE, read_data);
        check(read_data == 32'h0000_0001, "blocked-B execution mode readback");

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
        check(read_data == GOLDEN_CLASS, "class index is 879");
        axi_lite_read(REG_CLASS_LOGIT, read_data);

        // Report both the IEEE-754 word distance and the numeric difference.
        // Exact equality is intentionally not required because the production
        // finite-state datapaths round differently from the behavioral oracle.
        register_class_logit = read_data;
        raw_word_delta =
            $signed({1'b0, register_class_logit}) -
            $signed({1'b0, GOLDEN_LOGIT});
        rtl_logit_real = fp32_to_real(register_class_logit);
        golden_logit_real = fp32_to_real(GOLDEN_LOGIT);
        numeric_delta = rtl_logit_real - golden_logit_real;
        $display(
            "E04_REAL_AXI_LOGIT rtl_word=%08x golden_word=%08x raw_word_delta=%0d rtl=%0.9f golden=%0.9f numeric_delta=%0.9f",
            register_class_logit,
            GOLDEN_LOGIT,
            raw_word_delta,
            rtl_logit_real,
            golden_logit_real,
            numeric_delta
        );
        check(fp32_is_finite(register_class_logit), "class logit is finite");
        check(
            (raw_word_delta >= -CLASS_LOGIT_MAX_WORD_DELTA) &&
            (raw_word_delta <= CLASS_LOGIT_MAX_WORD_DELTA),
            "class logit stays within eight positive-FP32 word codes"
        );
        if (numeric_delta < 0.0)
            comparison_abs_error = -numeric_delta;
        else
            comparison_abs_error = numeric_delta;
        check(
            comparison_abs_error <= LOGIT_MAX_ABS_TOLERANCE,
            "class logit stays within numeric tolerance"
        );
        check(
            captured_class_logit == register_class_logit,
            "sideband and AXI-Lite class logits agree"
        );

        // Compare every real-data E04 checkpoint, not only the top-1 result.
        // Layout is a pure copy and must remain bit exact.  LayerNorm, GEMM
        // and Softmax use finite-state FP32 datapaths, so their results are
        // checked numerically against the behavioral golden with explicit,
        // tight absolute tolerances.
        final_ln_max_abs_error = 0.0;
        logits_max_abs_error = 0.0;
        probabilities_max_abs_error = 0.0;
        final_ln_exact_mismatches = 0;
        logits_exact_mismatches = 0;
        probabilities_exact_mismatches = 0;
        final_ln_tolerance_failures = 0;
        logits_tolerance_failures = 0;
        probabilities_tolerance_failures = 0;
        final_ln_max_error_index = 0;
        logits_max_error_index = 0;
        probabilities_max_error_index = 0;
        layout_copy_mismatches = 0;

        for (initialize_index = 0;
             initialize_index < HIDDEN_WORDS;
             initialize_index = initialize_index + 1) begin
            if (
                u_ddr.scratch_memory[
                    PHASE_E_ADDR_HIDDEN_B + initialize_index
                ] !== golden_final_layernorm[initialize_index]
            )
                final_ln_exact_mismatches =
                    final_ln_exact_mismatches + 1;

            if (
                !fp32_is_finite(
                    u_ddr.scratch_memory[
                        PHASE_E_ADDR_HIDDEN_B + initialize_index
                    ]
                ) ||
                !fp32_is_finite(golden_final_layernorm[initialize_index])
            ) begin
                final_ln_tolerance_failures =
                    final_ln_tolerance_failures + 1;
            end else begin
                comparison_rtl_value = fp32_to_real(
                    u_ddr.scratch_memory[
                        PHASE_E_ADDR_HIDDEN_B + initialize_index
                    ]
                );
                comparison_golden_value =
                    fp32_to_real(golden_final_layernorm[initialize_index]);
                comparison_abs_error =
                    comparison_rtl_value - comparison_golden_value;
                if (comparison_abs_error < 0.0)
                    comparison_abs_error = -comparison_abs_error;
                if (comparison_abs_error > final_ln_max_abs_error) begin
                    final_ln_max_abs_error = comparison_abs_error;
                    final_ln_max_error_index = initialize_index;
                end
                if (
                    comparison_abs_error >
                    FINAL_LN_MAX_ABS_TOLERANCE
                )
                    final_ln_tolerance_failures =
                        final_ln_tolerance_failures + 1;
            end
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
            if (
                u_ddr.scratch_memory[
                    PHASE_E_ADDR_LOGITS + initialize_index
                ] !== golden_logits[initialize_index]
            )
                logits_exact_mismatches = logits_exact_mismatches + 1;
            if (
                !fp32_is_finite(
                    u_ddr.scratch_memory[
                        PHASE_E_ADDR_LOGITS + initialize_index
                    ]
                ) ||
                !fp32_is_finite(golden_logits[initialize_index])
            ) begin
                logits_tolerance_failures =
                    logits_tolerance_failures + 1;
            end else begin
                comparison_rtl_value = fp32_to_real(
                    u_ddr.scratch_memory[
                        PHASE_E_ADDR_LOGITS + initialize_index
                    ]
                );
                comparison_golden_value =
                    fp32_to_real(golden_logits[initialize_index]);
                comparison_abs_error =
                    comparison_rtl_value - comparison_golden_value;
                if (comparison_abs_error < 0.0)
                    comparison_abs_error = -comparison_abs_error;
                if (comparison_abs_error > logits_max_abs_error) begin
                    logits_max_abs_error = comparison_abs_error;
                    logits_max_error_index = initialize_index;
                end
                if (comparison_abs_error > LOGIT_MAX_ABS_TOLERANCE)
                    logits_tolerance_failures =
                        logits_tolerance_failures + 1;
            end

            if (
                u_ddr.scratch_memory[
                    PHASE_E_ADDR_CLASS_PROB + initialize_index
                ] !== golden_probabilities[initialize_index]
            )
                probabilities_exact_mismatches =
                    probabilities_exact_mismatches + 1;
            if (
                !fp32_is_finite(
                    u_ddr.scratch_memory[
                        PHASE_E_ADDR_CLASS_PROB + initialize_index
                    ]
                ) ||
                !fp32_is_finite(golden_probabilities[initialize_index])
            ) begin
                probabilities_tolerance_failures =
                    probabilities_tolerance_failures + 1;
            end else begin
                comparison_rtl_value = fp32_to_real(
                    u_ddr.scratch_memory[
                        PHASE_E_ADDR_CLASS_PROB + initialize_index
                    ]
                );
                comparison_golden_value =
                    fp32_to_real(golden_probabilities[initialize_index]);
                comparison_abs_error =
                    comparison_rtl_value - comparison_golden_value;
                if (comparison_abs_error < 0.0)
                    comparison_abs_error = -comparison_abs_error;
                if (comparison_abs_error > probabilities_max_abs_error) begin
                    probabilities_max_abs_error = comparison_abs_error;
                    probabilities_max_error_index = initialize_index;
                end
                if (
                    comparison_abs_error >
                    PROBABILITY_MAX_ABS_TOLERANCE
                )
                    probabilities_tolerance_failures =
                        probabilities_tolerance_failures + 1;
            end
        end

        $display(
            "E04_REAL_AXI_NUMERIC final_ln_exact_mismatch=%0d final_ln_max_abs=%0.9e final_ln_max_index=%0d logits_exact_mismatch=%0d logits_max_abs=%0.9e logits_max_index=%0d probabilities_exact_mismatch=%0d probabilities_max_abs=%0.9e probabilities_max_index=%0d",
            final_ln_exact_mismatches,
            final_ln_max_abs_error,
            final_ln_max_error_index,
            logits_exact_mismatches,
            logits_max_abs_error,
            logits_max_error_index,
            probabilities_exact_mismatches,
            probabilities_max_abs_error,
            probabilities_max_error_index
        );
        check(
            final_ln_tolerance_failures == 0,
            "all 151296 final LayerNorm words match behavioral tolerance"
        );
        check(
            layout_copy_mismatches == 0,
            "CLS layout copy is bit exact for all 768 words"
        );
        check(
            logits_tolerance_failures == 0,
            "all 1000 logits match behavioral tolerance"
        );
        check(
            probabilities_tolerance_failures == 0,
            "all 1000 class probabilities match behavioral tolerance"
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
        check(
            captured_class_index == GOLDEN_CLASS,
            "sideband class result is 879"
        );

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
        check(ddr_read_outstanding_high_water >= 2,
              "DDR model observed two outstanding read transactions");

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
        check(profile_logical_reads == ddr_read_count + profile_cache_hits,
              "logical reads equal useful external FP32 words plus core hits");

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
        check(read_data == 32'h0000_0012,
              "M5 snapshot valid with max outstanding two");
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
            "E04_REAL_AXI128_TRAFFIC useful_fp32_words=%0d ar=%0d r_beats=%0d full_r_beats=%0d narrow_r_beats=%0d linefills=%0d line_hits=%0d writes=%0d",
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
              "M5 beat classes reconstruct external FP32 words");
        check(m5_axi_counter[2] + m5_axi_counter[3] +
                  m5_axi_counter[7] == (m5_axi_counter[0] * 4),
              "M5 linefill demand, hits and discard partition full payload");
        check(ddr_ar_transaction_count ==
                  m5_axi_counter[1] + (m5_axi_counter[2] * 2),
              "AR count equals narrow reads plus two bursts per linefill");
        check(m5_axi_counter[4] == 0 && m5_axi_counter[5] == 2 &&
                  m5_axi_counter[6] == 0 && m5_axi_counter[7] == 0,
              "M5 has no split/error/discard and reaches outstanding two");
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
                "VIT_PHASE_E_AXI_E04_REAL_RTL_E2E_PASS checks=%0d cycles=%0d commands=%0d reads=%0d writes=%0d model_reads=%0d scratch_reads=%0d class=%0d logit=%08x golden=%08x raw_delta=%0d",
                checks,
                cycle_count,
                command_count,
                ddr_read_count,
                ddr_write_count,
                model_read_count,
                scratch_read_count,
                captured_class_index,
                register_class_logit,
                GOLDEN_LOGIT,
                raw_word_delta
            );
            $finish;
        end else begin
            $fatal(
                1,
                "VIT_PHASE_E_AXI_E04_REAL_RTL_E2E_FAIL checks=%0d failures=%0d class=%0d logit=%08x",
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
            "E04 real-data AXI watchdog timeout after %0d cycles",
            WATCHDOG_CYCLES
        );
    end

endmodule
