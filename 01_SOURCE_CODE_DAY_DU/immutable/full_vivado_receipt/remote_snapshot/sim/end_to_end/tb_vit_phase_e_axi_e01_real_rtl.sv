`timescale 1ns/1ps

// Full-dimension, real-data production E01 test.
//
//   AXI4-Lite BFM -> vit_phase_e_axi_bd_wrapper
//                 -> production vit_phase_e_npu / engine
//                 -> production AXI4 memory adapter
//                 -> native 128-bit vit_axi_ddr_model_128
//
// The prepared 196x768 patch tensor and all four embedding tensors are the
// canonical FP32 assets.  The patch weight is repacked in the testbench into
// model-package-v2 blocked-B order before START.  No behavioral engine,
// direct logical memory seam, compact shape, or RTL hierarchy bypass is used.
module tb_vit_phase_e_axi_e01_real_rtl;

    import vit_phase_e_pkg::*;

    localparam integer AXI_ADDR_WIDTH = 40;
    localparam integer AXI_ID_WIDTH = 1;

    localparam integer PATCH_COUNT = 196;
    localparam integer TOKEN_COUNT = 197;
    localparam integer HIDDEN_SIZE = 768;
    localparam integer PATCH_WORDS = PATCH_COUNT * HIDDEN_SIZE;
    localparam integer HIDDEN_WORDS = TOKEN_COUNT * HIDDEN_SIZE;
    localparam integer PATCH_WEIGHT_WORDS = HIDDEN_SIZE * HIDDEN_SIZE;

    // These four global offsets are unchanged by model-package v2.
    localparam logic [31:0] PATCH_WEIGHT_BASE = 32'h0000_0000;
    localparam logic [31:0] PATCH_BIAS_BASE = 32'h0009_0000;
    localparam logic [31:0] CLS_BASE = 32'h0009_0300;
    localparam logic [31:0] POSITION_BASE = 32'h0009_0600;

    // Only the first four canonical tensors need simulation backing.  The
    // software-visible limit remains the complete model-package-v1 size.
    localparam integer MODEL_BACKING_WORDS =
        POSITION_BASE + HIDDEN_WORDS;
    localparam logic [31:0] MODEL_PACKAGE_V2_WORDS = 32'h0528_eb00;
    localparam integer INPUT_WORDS = PATCH_WORDS;
    localparam integer SCRATCH_WORDS = PHASE_E_SCRATCH_WORDS;

    localparam logic [63:0] MODEL_BASE =
        64'h0000_0010_0000_0000;
    localparam logic [63:0] INPUT_BASE =
        64'h0000_0020_0000_0000;
    localparam logic [63:0] SCRATCH_BASE =
        64'h0000_0030_0000_0000;

    localparam logic [7:0] JOB_TAG = 8'h20;
    localparam logic [31:0] FP32_SENTINEL = 32'hdead_beef;

    // The production tree uses balanced 16-value reductions followed by
    // rounded chunk accumulation.  The behavioral golden may round at
    // slightly different points, so every word is checked numerically with
    // this explicit absolute bound.  Exact mismatch count is also reported.
    localparam real EMBEDDING_MAX_ABS_TOLERANCE = 5.0e-4;

    localparam integer EXPECTED_COMMANDS = 4;
    // The bias router requests bias only on the final K chunk.  During the
    // first token tile this fills all 768 bias-cache entries exactly once;
    // later token tiles hit the cache.
    localparam logic [63:0] EXPECTED_MODEL_READS = 64'd14_898_432;
    localparam logic [63:0] EXPECTED_INPUT_READS = 64'd150_528;
    localparam logic [63:0] EXPECTED_SCRATCH_READS = 64'd301_824;
    localparam logic [63:0] EXPECTED_READS = 64'd15_350_784;
    localparam logic [63:0] EXPECTED_WRITES = 64'd453_120;
    localparam logic [31:0] EXPECTED_MODEL_MAX_WORD =
        POSITION_BASE + HIDDEN_WORDS - 1;
    localparam logic [31:0] EXPECTED_SCRATCH_MAX_WORD =
        PHASE_E_ADDR_LINEAR_TMP + PATCH_WORDS - 1;
    localparam longint WATCHDOG_CYCLES = 64'd1_500_000_000;

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
    longint next_progress_read_count = 1_000_000;
    longint next_progress_cycle_count = 5_000_000;
    integer progress_read_interval;
    integer progress_cycle_interval;
    integer probe_cycle_limit;
    integer progress_read_plusarg_status;
    integer progress_cycle_plusarg_status;
    integer probe_cycle_plusarg_status;
    integer checks = 0;
    integer failures = 0;
    integer command_count = 0;
    integer checkpoint_count = 0;
    integer parameter_request_count = 0;
    integer layer_request_count = 0;
    integer class_result_count = 0;
    integer compare_index;
    integer pack_n_tile;
    integer pack_k_chunk;
    integer pack_col;
    integer pack_lane;
    integer pack_src_k;
    integer pack_src_n;
    integer pack_dst;
    integer exact_mismatches;
    integer tolerance_failures;
    integer hidden_b_mismatches;
    integer max_error_index;
    logic [31:0] max_error_rtl_word;
    logic [31:0] max_error_golden_word;
    logic [31:0] golden_embedding [0:HIDDEN_WORDS-1];
    logic [31:0] row_major_patch_weight [0:PATCH_WEIGHT_WORDS-1];
    logic [1:0] response;
    logic [31:0] read_data;
    logic [31:0] job_config_value;
    real comparison_rtl_value;
    real comparison_golden_value;
    real comparison_abs_error;
    real max_abs_error;
    real sum_abs_error;
    real mean_abs_error;
    integer profile_index;
    logic [63:0] perf_read_value;
    logic [63:0] profile_logical_reads;
    logic [63:0] profile_r_beats;
    logic [63:0] profile_cache_hits;
    logic [63:0] profile_read_histogram_sum;
    logic [63:0] profile_histogram_value;
    logic [63:0] m5_axi_counter [0:7];

    always #1 aclk = ~aclk;

    initial begin
        progress_read_interval = 1_000_000;
        progress_cycle_interval = 5_000_000;
        probe_cycle_limit = 0;
        progress_read_plusarg_status = $value$plusargs(
            "E01_PROGRESS_READS=%d",
            progress_read_interval
        );
        progress_cycle_plusarg_status = $value$plusargs(
            "E01_PROGRESS_CYCLES=%d",
            progress_cycle_interval
        );
        probe_cycle_plusarg_status = $value$plusargs(
            "E01_PROBE_CYCLES=%d",
            probe_cycle_limit
        );
        if ((progress_read_interval <= 0) ||
            (progress_cycle_interval <= 0) ||
            (probe_cycle_limit < 0))
            $fatal(1, "E01 progress/probe intervals are invalid");
        $display(
            "E01_REAL_AXI_RUN_CONFIG progress_cycles=%0d progress_reads=%0d probe_cycles=%0d plusarg_hits=%0d/%0d/%0d",
            progress_cycle_interval,
            progress_read_interval,
            probe_cycle_limit,
            progress_cycle_plusarg_status,
            progress_read_plusarg_status,
            probe_cycle_plusarg_status
        );
        $fflush();
    end

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
                    "E01 REAL AXI CHECK FAILED cycle=%0d: %s",
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

    // No shape override: E01 always uses the fixed ViT-Base/16-224 shape.
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

    vit_axi_ddr_model_128 #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MODEL_WORDS(MODEL_BACKING_WORDS),
        .INPUT_WORDS(INPUT_WORDS),
        .SCRATCH_WORDS(SCRATCH_WORDS),
        .MODEL_BASE(MODEL_BASE),
        .INPUT_BASE(INPUT_BASE),
        .SCRATCH_BASE(SCRATCH_BASE),
        .MAX_BURST_BEATS(4),
        .READ_QUEUE_DEPTH(4),
        .WRITE_QUEUE_DEPTH(2),
        .W_QUEUE_DEPTH(4),
        // The no-stall setting shortens a multi-hour full-size test.  The
        // same DDR model still checks every AXI transaction and response.
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
            next_progress_read_count <= progress_read_interval;
            next_progress_cycle_count <= progress_cycle_interval;
        end else begin
            if (
                dut.u_core.u_npu.command_valid &&
                dut.u_core.u_npu.command_ready
            ) begin
                case (command_count)
                    0: begin
                        check(
                            dut.u_core.u_npu.command.header.opcode ==
                                PHASE_E_OP_GEMM,
                            "command 0 is patch projection GEMM"
                        );
                        check(
                            (dut.u_core.u_npu.command.header.flags &
                             PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2) != 0,
                            "patch GEMM selects blocked-B layout"
                        );
                        check(
                            dut.u_core.u_npu.command.stride3 == 32'd1536,
                            "patch blocked-B output-tile stride is 1536"
                        );
                    end
                    1: check(
                        dut.u_core.u_npu.command.header.opcode ==
                            PHASE_E_OP_LAYOUT,
                        "command 1 is CLS layout"
                    );
                    2: check(
                        dut.u_core.u_npu.command.header.opcode ==
                            PHASE_E_OP_LAYOUT,
                        "command 2 is patch layout"
                    );
                    3: check(
                        dut.u_core.u_npu.command.header.opcode ==
                            PHASE_E_OP_VECTOR,
                        "command 3 is position add"
                    );
                    default:
                        check(1'b0, "unexpected extra production command");
                endcase
                command_count <= command_count + 1;
            end

            if (dut.u_core.checkpoint_valid) begin
                check(
                    dut.u_core.checkpoint_phase == PHASE_E_E01,
                    "checkpoint phase is E01"
                );
                check(
                    dut.u_core.checkpoint_section ==
                        PHASE_E_SECTION_EMBEDDING,
                    "checkpoint section is EMBEDDING"
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
            if (dut.u_core.class_result_valid)
                class_result_count <= class_result_count + 1;

            if (
                dut.u_core.npu_busy &&
                (ddr_read_count >= next_progress_read_count)
            ) begin
                $display(
                    "E01_REAL_AXI_PROGRESS cycles=%0d commands=%0d checkpoints=%0d reads=%0d/%0d writes=%0d",
                    cycle_count,
                    command_count,
                    checkpoint_count,
                    ddr_read_count,
                    EXPECTED_READS,
                    ddr_write_count
                );
                $fflush();
                next_progress_read_count <=
                    next_progress_read_count + progress_read_interval;
            end
            if (
                dut.u_core.npu_busy &&
                (cycle_count >= next_progress_cycle_count)
            ) begin
                $display(
                    "E01_REAL_AXI_CYCLE_PROGRESS cycles=%0d commands=%0d checkpoints=%0d reads=%0d writes=%0d",
                    cycle_count,
                    command_count,
                    checkpoint_count,
                    ddr_read_count,
                    ddr_write_count
                );
                $fflush();
                next_progress_cycle_count <=
                    next_progress_cycle_count + progress_cycle_interval;
            end
        end
    end

    initial begin
        $readmemh(
            "parameters/embedding_patch_weight_B_f32.hex",
            row_major_patch_weight
        );
        for (pack_n_tile = 0; pack_n_tile < (HIDDEN_SIZE + 1) / 2;
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
                            (pack_src_n < HIDDEN_SIZE))
                            u_ddr.model_memory[
                                PATCH_WEIGHT_BASE + pack_dst
                            ] = row_major_patch_weight[
                                pack_src_k * HIDDEN_SIZE + pack_src_n
                            ];
                        else
                            u_ddr.model_memory[
                                PATCH_WEIGHT_BASE + pack_dst
                            ] = 32'h0000_0000;
                    end
        $readmemh(
            "parameters/embedding_patch_bias_f32.hex",
            u_ddr.model_memory,
            PATCH_BIAS_BASE,
            PATCH_BIAS_BASE + HIDDEN_SIZE - 1
        );
        $readmemh(
            "parameters/embedding_cls_token_f32.hex",
            u_ddr.model_memory,
            CLS_BASE,
            CLS_BASE + HIDDEN_SIZE - 1
        );
        $readmemh(
            "parameters/embedding_position_f32.hex",
            u_ddr.model_memory,
            POSITION_BASE,
            POSITION_BASE + HIDDEN_WORDS - 1
        );
        $readmemh(
            "preprocessed/embedding_input_patch_A_f32.hex",
            u_ddr.input_memory
        );
        $readmemh(
            "results/embedding_step_06_hidden_states_f32.hex",
            golden_embedding
        );

        for (compare_index = 0; compare_index < HIDDEN_WORDS;
             compare_index = compare_index + 1) begin
            u_ddr.scratch_memory[
                PHASE_E_ADDR_HIDDEN_A + compare_index
            ] = FP32_SENTINEL;
            u_ddr.scratch_memory[
                PHASE_E_ADDR_HIDDEN_B + compare_index
            ] = FP32_SENTINEL;
        end
        for (compare_index = 0; compare_index < PATCH_WORDS;
             compare_index = compare_index + 1)
            u_ddr.scratch_memory[
                PHASE_E_ADDR_LINEAR_TMP + compare_index
            ] = FP32_SENTINEL;

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
        axi_lite_write(REG_INPUT_WORDS, INPUT_WORDS);
        axi_lite_write(REG_SCRATCH_WORDS, SCRATCH_WORDS);

        axi_lite_write(REG_GLOBAL_BASE + 12'h000, PATCH_WEIGHT_BASE);
        axi_lite_write(REG_GLOBAL_BASE + 12'h004, PATCH_BIAS_BASE);
        axi_lite_write(REG_GLOBAL_BASE + 12'h008, CLS_BASE);
        axi_lite_write(REG_GLOBAL_BASE + 12'h00c, POSITION_BASE);
        axi_lite_write(REG_EXECUTION_MODE, 32'h0000_0001);
        axi_lite_read(REG_EXECUTION_MODE, read_data);
        check(read_data == 32'h0000_0001, "blocked-B execution mode readback");

        job_config_value = 32'd0;
        job_config_value[2:0] = PHASE_E_E01;
        job_config_value[11] = 1'b0;
        job_config_value[12] = 1'b1;
        job_config_value[20:13] = JOB_TAG;
        axi_lite_write(REG_JOB_CONFIG, job_config_value);
        axi_lite_read(REG_JOB_CONFIG, read_data);
        check(
            read_data == job_config_value,
            "JOB_CONFIG readback enables E01 checkpoints only"
        );
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
        check(read_data[4], "STATUS reflects asserted IRQ");
        axi_lite_read(REG_IRQ_STATUS, read_data);
        check(read_data[0] && !read_data[1], "done IRQ is sticky");
        axi_lite_read(REG_ERROR_CODE, read_data);
        check(read_data == 32'd0, "error code is zero");

        check(command_count == EXPECTED_COMMANDS, "four commands issued");
        check(
            checkpoint_count == EXPECTED_COMMANDS,
            "four command checkpoints observed"
        );
        check(
            parameter_request_count == 3,
            "patch, CLS, and position operands requested"
        );
        check(layer_request_count == 0, "E01 requested no layer table");
        check(class_result_count == 0, "E01 produced no class result");

        $display(
            "E01_REAL_AXI_TRAFFIC actual_total_r=%0d expected_total_r=%0d actual_total_w=%0d expected_total_w=%0d model_r=%0d expected_model_r=%0d input_r=%0d expected_input_r=%0d scratch_r=%0d expected_scratch_r=%0d scratch_w=%0d invalid=%0d",
            ddr_read_count,
            EXPECTED_READS,
            ddr_write_count,
            EXPECTED_WRITES,
            model_read_count,
            EXPECTED_MODEL_READS,
            input_read_count,
            EXPECTED_INPUT_READS,
            scratch_read_count,
            EXPECTED_SCRATCH_READS,
            scratch_write_count,
            invalid_access_count
        );
        $fflush();
        check(ddr_read_count == EXPECTED_READS, "exact E01 AXI read count");
        check(ddr_write_count == EXPECTED_WRITES, "exact E01 AXI write count");
        check(
            model_read_count == EXPECTED_MODEL_READS,
            "exact E01 MODEL read count"
        );
        check(
            input_read_count == EXPECTED_INPUT_READS,
            "prepared INPUT is read exactly once through activation cache"
        );
        check(
            scratch_read_count == EXPECTED_SCRATCH_READS,
            "exact E01 SCRATCH read count"
        );
        check(
            scratch_write_count == EXPECTED_WRITES,
            "every E01 write targets SCRATCH"
        );
        check(
            ddr_read_count ==
                model_read_count + input_read_count + scratch_read_count,
            "every useful external FP32 word maps to one DDR region"
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

        axi_lite_read(REG_PERF_CAPABILITY, read_data);
        check(read_data == 32'h0001_001f, "performance capability schema");
        axi_lite_read(REG_PERF_STATUS, read_data);
        check(read_data == 32'h0000_0002, "performance snapshot is valid");
        axi_lite_read64(REG_COMMANDS_LO, perf_read_value);
        check(perf_read_value == EXPECTED_COMMANDS,
              "legacy command counter matches E01 schedule");
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
            "E01_REAL_AXI128_TRAFFIC useful_fp32_words=%0d ar=%0d r_beats=%0d full_r_beats=%0d narrow_r_beats=%0d linefills=%0d line_hits=%0d writes=%0d",
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
        check(u_ddr.model_min_word == 0, "MODEL minimum word is zero");
        check(
            u_ddr.model_max_word == EXPECTED_MODEL_MAX_WORD,
            "MODEL maximum word is position tensor end"
        );
        check(u_ddr.input_min_word == 0, "INPUT minimum word is zero");
        check(
            u_ddr.input_max_word == INPUT_WORDS - 1,
            "INPUT maximum word is prepared patch end"
        );
        check(u_ddr.scratch_min_word == 0, "SCRATCH minimum word is zero");
        check(
            u_ddr.scratch_max_word == EXPECTED_SCRATCH_MAX_WORD,
            "SCRATCH maximum word is LINEAR_TMP patch end"
        );

        exact_mismatches = 0;
        tolerance_failures = 0;
        hidden_b_mismatches = 0;
        max_error_index = 0;
        max_error_rtl_word = 32'd0;
        max_error_golden_word = 32'd0;
        max_abs_error = 0.0;
        sum_abs_error = 0.0;

        for (compare_index = 0; compare_index < HIDDEN_WORDS;
             compare_index = compare_index + 1) begin
            if (
                u_ddr.scratch_memory[
                    PHASE_E_ADDR_HIDDEN_A + compare_index
                ] !== golden_embedding[compare_index]
            )
                exact_mismatches = exact_mismatches + 1;

            if (
                !fp32_is_finite(
                    u_ddr.scratch_memory[
                        PHASE_E_ADDR_HIDDEN_A + compare_index
                    ]
                ) ||
                !fp32_is_finite(golden_embedding[compare_index])
            ) begin
                tolerance_failures = tolerance_failures + 1;
            end else begin
                comparison_rtl_value = fp32_to_real(
                    u_ddr.scratch_memory[
                        PHASE_E_ADDR_HIDDEN_A + compare_index
                    ]
                );
                comparison_golden_value =
                    fp32_to_real(golden_embedding[compare_index]);
                comparison_abs_error =
                    comparison_rtl_value - comparison_golden_value;
                if (comparison_abs_error < 0.0)
                    comparison_abs_error = -comparison_abs_error;
                sum_abs_error = sum_abs_error + comparison_abs_error;
                if (comparison_abs_error > max_abs_error) begin
                    max_abs_error = comparison_abs_error;
                    max_error_index = compare_index;
                    max_error_rtl_word =
                        u_ddr.scratch_memory[
                            PHASE_E_ADDR_HIDDEN_A + compare_index
                        ];
                    max_error_golden_word =
                        golden_embedding[compare_index];
                end
                if (
                    comparison_abs_error >
                    EMBEDDING_MAX_ABS_TOLERANCE
                )
                    tolerance_failures = tolerance_failures + 1;
            end

            if (
                u_ddr.scratch_memory[
                    PHASE_E_ADDR_HIDDEN_B + compare_index
                ] !== FP32_SENTINEL
            )
                hidden_b_mismatches = hidden_b_mismatches + 1;
        end

        mean_abs_error = sum_abs_error / real'(HIDDEN_WORDS);
        $display(
            "E01_REAL_AXI_NUMERIC words=%0d exact_mismatch=%0d tolerance_failures=%0d max_abs=%0.9e mean_abs=%0.9e max_index=%0d rtl=%08x golden=%08x tolerance=%0.9e hidden_b_modified=%0d",
            HIDDEN_WORDS,
            exact_mismatches,
            tolerance_failures,
            max_abs_error,
            mean_abs_error,
            max_error_index,
            max_error_rtl_word,
            max_error_golden_word,
            EMBEDDING_MAX_ABS_TOLERANCE,
            hidden_b_mismatches
        );
        check(
            tolerance_failures == 0,
            "all 151296 HIDDEN_A words match behavioral tolerance"
        );
        check(
            hidden_b_mismatches == 0,
            "E01 leaves the alternate HIDDEN_B buffer untouched"
        );

        axi_lite_write(REG_IRQ_STATUS, 32'h0000_0001);
        @(posedge aclk);
        check(!irq_o, "RW1C clears the done IRQ");
        axi_lite_read(REG_IRQ_STATUS, read_data);
        check(read_data == 32'd0, "IRQ status reads clear");

        if (failures == 0) begin
            $display(
                "VIT_PHASE_E_AXI_E01_REAL_RTL_E2E_PASS checks=%0d cycles=%0d commands=%0d reads=%0d writes=%0d max_abs=%0.9e mean_abs=%0.9e",
                checks,
                cycle_count,
                command_count,
                ddr_read_count,
                ddr_write_count,
                max_abs_error,
                mean_abs_error
            );
            $finish;
        end else begin
            $fatal(
                1,
                "VIT_PHASE_E_AXI_E01_REAL_RTL_E2E_FAIL checks=%0d failures=%0d",
                checks,
                failures
            );
        end
    end

    initial begin
        wait (aresetn);
        if (probe_cycle_limit > 0) begin
            repeat (probe_cycle_limit)
                @(posedge aclk);
            $display(
                "VIT_PHASE_E_AXI_E01_REAL_RTL_PROBE_STOP cycles=%0d commands=%0d checkpoints=%0d reads=%0d writes=%0d model_reads=%0d input_reads=%0d scratch_reads=%0d invalid=%0d",
                cycle_count,
                command_count,
                checkpoint_count,
                ddr_read_count,
                ddr_write_count,
                model_read_count,
                input_read_count,
                scratch_read_count,
                invalid_access_count
            );
            $fflush();
            $finish;
        end
    end

    initial begin
        repeat (WATCHDOG_CYCLES)
            @(posedge aclk);
        $fatal(
            1,
            "E01 real AXI watchdog timeout after %0d cycles; reads=%0d writes=%0d commands=%0d checkpoints=%0d",
            WATCHDOG_CYCLES,
            ddr_read_count,
            ddr_write_count,
            command_count,
            checkpoint_count
        );
    end

endmodule
