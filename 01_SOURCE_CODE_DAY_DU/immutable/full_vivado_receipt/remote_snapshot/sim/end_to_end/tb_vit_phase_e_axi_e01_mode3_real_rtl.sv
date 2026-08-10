`timescale 1ns/1ps

// Full-dimension, real-data package-v3 execution-mode-3 E01 test.
//
//   AXI4-Lite BFM -> vit_phase_e_axi_bd_wrapper
//                 -> production vit_phase_e_npu / engine
//                 -> production AXI4 memory adapter
//                 -> native 128-bit vit_axi_ddr_model_128
//
// The prepared 196x768 patch tensor and all four model tensors are staged from
// the hash-pinned v3 package.  The patch weight is consumed exactly as packed
// FP16 K16/N2 storage; the testbench never repacks or reconstructs it.  This
// test emits structural/protocol evidence and one raw embedding dump.  Two
// external gates separately prove exact M6/current-adder arithmetic and the
// independent FP32 model-quality tolerance.
module tb_vit_phase_e_axi_e01_mode3_real_rtl;

    import vit_phase_e_pkg::*;

    localparam integer AXI_ADDR_WIDTH = 40;
    localparam integer AXI_ID_WIDTH = 1;

    localparam integer PATCH_COUNT = 196;
    localparam integer TOKEN_COUNT = 197;
    localparam integer HIDDEN_SIZE = 768;
    localparam integer PATCH_WORDS = PATCH_COUNT * HIDDEN_SIZE;
    localparam integer HIDDEN_WORDS = TOKEN_COUNT * HIDDEN_SIZE;
    localparam integer PATCH_WEIGHT_WORDS =
        ((HIDDEN_SIZE + 15) / 16) * ((HIDDEN_SIZE + 1) / 2) * 16;

    // Exact package-v3 U32-storage-word offsets.
    localparam logic [31:0] PATCH_WEIGHT_BASE = 32'h0000_0000;
    localparam logic [31:0] PATCH_BIAS_BASE = 32'h0004_8000;
    localparam logic [31:0] CLS_BASE = 32'h0004_8300;
    localparam logic [31:0] POSITION_BASE = 32'h0004_8600;

    // Only the first four canonical tensors need simulation backing.  The
    // software-visible limit remains the complete model-package-v3 size.
    localparam integer MODEL_BACKING_WORDS =
        POSITION_BASE + HIDDEN_WORDS;
    localparam logic [31:0] MODEL_PACKAGE_V3_WORDS = 32'h0296_8f00;
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

    localparam integer EXPECTED_COMMANDS = 4;
    // Packed-B demand is one 16-word K panel per physical R8/C1 pass.
    // The bias router requests two words only on the final K chunk.  The
    // current cache has one whole-vector valid bit: for token tile zero it
    // therefore refetches both bias words on pass 1 of the first 383 logical
    // C2 tiles.  Storing pass 0 of the final tile makes the cache valid, so
    // that tile's pass 1 and every later token tile hit.  Hence the exact
    // external bias demand is 383*4 + 2 = 1,534 words, not 768.
    localparam logic [63:0] EXPECTED_PACKED_WEIGHT_READS =
        64'd14_745_600;
    localparam logic [63:0] EXPECTED_BIAS_READS = 64'd1_534;
    localparam logic [63:0] EXPECTED_CLS_READS = 64'd768;
    localparam logic [63:0] EXPECTED_POSITION_READS = 64'd151_296;
    localparam logic [63:0] EXPECTED_MODEL_READS = 64'd14_899_198;
    localparam logic [63:0] EXPECTED_INPUT_READS = 64'd150_528;
    localparam logic [63:0] EXPECTED_SCRATCH_READS = 64'd301_824;
    localparam logic [63:0] EXPECTED_READS = 64'd15_351_550;
    localparam logic [63:0] EXPECTED_WRITES = 64'd453_120;
    // M8 additionally linefills the bounded Vector/GELU gathers.  Useful
    // payload and semantic reads are unchanged; only the AXI transaction/
    // beat partition moves from narrow reads into aligned full linefills.
    localparam logic [63:0] EXPECTED_AXI_AR = 64'd1_243_870;
    localparam logic [63:0] EXPECTED_AXI_R_BEATS = 64'd4_065_406;
    localparam logic [63:0] EXPECTED_FULL_R_BEATS = 64'd3_762_048;
    localparam logic [63:0] EXPECTED_NARROW_R_BEATS = 64'd303_358;
    localparam logic [63:0] EXPECTED_LINEFILLS = 64'd940_512;
    localparam logic [63:0] EXPECTED_LINE_HITS = 64'd14_107_680;
    localparam logic [63:0] EXPECTED_BIAS_LOOKUPS = 64'd38_400;
    localparam logic [63:0] EXPECTED_BIAS_HITS = 64'd36_866;
    localparam logic [63:0] EXPECTED_BIAS_MISSES = 64'd1_534;
    localparam logic [63:0] EXPECTED_FP16_TERMS = 64'd117_964_800;
    localparam logic [63:0] EXPECTED_DISABLED_TERMS = 64'd2_359_296;
    localparam logic [63:0] EXPECTED_DOT_VECTORS = 64'd19_200;
    localparam logic [63:0] EXPECTED_PANELS = 64'd921_600;
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
    localparam logic [11:0] REG_M7_CAPABILITY = 12'h810;
    localparam logic [11:0] REG_M7_STATUS = 12'h814;
    localparam logic [11:0] REG_M7_OVF_LO = 12'h818;
    localparam logic [11:0] REG_M7_OVF_HI = 12'h81c;
    localparam logic [11:0] REG_M7_ERROR = 12'h820;
    localparam logic [11:0] REG_M7_GEOMETRY = 12'h824;
    localparam logic [11:0] REG_M7_BUFFER_CONFIG = 12'h828;
    localparam logic [11:0] REG_M7_NUMERIC_CONFIG = 12'h82c;
    localparam logic [11:0] REG_M7_COUNTER_BASE = 12'h830;

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
    integer embedding_nonfinite_count;
    integer embedding_sentinel_count;
    integer hidden_b_modified_count;
    integer asset_evidence_fd;
    integer embedding_golden_fd;
    logic [1:0] response;
    logic [31:0] read_data;
    logic [31:0] job_config_value;
    integer profile_index;
    logic [63:0] perf_read_value;
    logic [63:0] profile_logical_reads;
    logic [63:0] profile_r_beats;
    logic [63:0] profile_cache_hits;
    logic [63:0] profile_bias_lookups;
    logic [63:0] profile_bias_hits;
    logic [63:0] profile_bias_misses;
    logic [63:0] profile_read_histogram_sum;
    logic [63:0] profile_histogram_value;
    logic [63:0] m5_axi_counter [0:7];
    logic [31:0] m7_status_value;
    logic [63:0] m7_counter [0:22];
    string prepared_input_hex_path;
    string patch_weight_hex_path;
    string patch_bias_hex_path;
    string cls_token_hex_path;
    string position_hex_path;
    string embedding_golden_hex_path;
    string asset_evidence_json_path;
    string embedding_dump_path;

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
                check(
                    dut.u_core.u_npu.command.header.tag ==
                        JOB_TAG + command_count,
                    "command tag is exact E01 ordinal"
                );
                case (command_count)
                    0: begin
                        check(
                            dut.u_core.u_npu.command.header.opcode ==
                                PHASE_E_OP_GEMM &&
                            dut.u_core.u_npu.command.header.subop ==
                                PHASE_E_SUBOP_NONE &&
                            dut.u_core.u_npu.command.header.flags == 8'hf9,
                            "command 0 is exact packed-FP16 patch GEMM"
                        );
                        check(
                            dut.u_core.u_npu.command.route.src0_tensor ==
                                PHASE_E_TENSOR_PATCH_A &&
                            dut.u_core.u_npu.command.route.src1_tensor ==
                                PHASE_E_TENSOR_WEIGHT &&
                            dut.u_core.u_npu.command.route.src2_tensor ==
                                PHASE_E_TENSOR_BIAS &&
                            dut.u_core.u_npu.command.route.dst_tensor ==
                                PHASE_E_TENSOR_LINEAR_TMP &&
                            dut.u_core.u_npu.command.route.src0_space ==
                                PHASE_E_MEM_INPUT &&
                            dut.u_core.u_npu.command.route.src1_space ==
                                PHASE_E_MEM_PARAM &&
                            dut.u_core.u_npu.command.route.src2_space ==
                                PHASE_E_MEM_PARAM &&
                            dut.u_core.u_npu.command.route.dst_space ==
                                PHASE_E_MEM_SCRATCH,
                            "patch GEMM route is exact"
                        );
                        check(
                            dut.u_core.u_npu.command.src0_base == 32'd0 &&
                            dut.u_core.u_npu.command.src1_base ==
                                PATCH_WEIGHT_BASE &&
                            dut.u_core.u_npu.command.src2_base ==
                                PATCH_BIAS_BASE &&
                            dut.u_core.u_npu.command.dst_base ==
                                PHASE_E_ADDR_LINEAR_TMP &&
                            dut.u_core.u_npu.command.dim0 == 32'd1 &&
                            dut.u_core.u_npu.command.dim1 == PATCH_COUNT &&
                            dut.u_core.u_npu.command.dim2 == HIDDEN_SIZE &&
                            dut.u_core.u_npu.command.dim3 == HIDDEN_SIZE,
                            "patch GEMM bases and dimensions are exact"
                        );
                        check(
                            dut.u_core.u_npu.command.stride0 == PATCH_WORDS &&
                            dut.u_core.u_npu.command.stride1 == HIDDEN_SIZE &&
                            dut.u_core.u_npu.command.stride2 == 32'd0 &&
                            dut.u_core.u_npu.command.stride3 == HIDDEN_SIZE &&
                            dut.u_core.u_npu.command.stride4 == PATCH_WORDS &&
                            dut.u_core.u_npu.command.immediate == HIDDEN_SIZE,
                            "patch packed-FP16 strides are exact"
                        );
                    end
                    1: begin
                        check(
                            dut.u_core.u_npu.command.header.opcode ==
                                PHASE_E_OP_LAYOUT &&
                            dut.u_core.u_npu.command.header.subop ==
                                PHASE_E_SUBOP_LAYOUT_COPY &&
                            dut.u_core.u_npu.command.header.flags == 8'h08,
                            "command 1 is exact checkpointed CLS copy"
                        );
                        check(
                            dut.u_core.u_npu.command.route.src0_tensor ==
                                PHASE_E_TENSOR_CLS &&
                            dut.u_core.u_npu.command.route.dst_tensor ==
                                PHASE_E_TENSOR_HIDDEN_A &&
                            dut.u_core.u_npu.command.route.src0_space ==
                                PHASE_E_MEM_PARAM &&
                            dut.u_core.u_npu.command.route.dst_space ==
                                PHASE_E_MEM_SCRATCH &&
                            dut.u_core.u_npu.command.src0_base == CLS_BASE &&
                            dut.u_core.u_npu.command.dst_base ==
                                PHASE_E_ADDR_HIDDEN_A,
                            "CLS copy route and bases are exact"
                        );
                        check(
                            dut.u_core.u_npu.command.dim0 == 32'd1 &&
                            dut.u_core.u_npu.command.dim1 == 32'd1 &&
                            dut.u_core.u_npu.command.dim2 == HIDDEN_SIZE &&
                            dut.u_core.u_npu.command.stride0 == 32'd0 &&
                            dut.u_core.u_npu.command.stride1 == 32'd0 &&
                            dut.u_core.u_npu.command.stride2 == 32'd1,
                            "CLS copy dimensions and strides are exact"
                        );
                    end
                    2: begin
                        check(
                            dut.u_core.u_npu.command.header.opcode ==
                                PHASE_E_OP_LAYOUT &&
                            dut.u_core.u_npu.command.header.subop ==
                                PHASE_E_SUBOP_LAYOUT_COPY &&
                            dut.u_core.u_npu.command.header.flags == 8'h08,
                            "command 2 is exact checkpointed patch copy"
                        );
                        check(
                            dut.u_core.u_npu.command.route.src0_tensor ==
                                PHASE_E_TENSOR_LINEAR_TMP &&
                            dut.u_core.u_npu.command.route.dst_tensor ==
                                PHASE_E_TENSOR_HIDDEN_A &&
                            dut.u_core.u_npu.command.route.src0_space ==
                                PHASE_E_MEM_SCRATCH &&
                            dut.u_core.u_npu.command.route.dst_space ==
                                PHASE_E_MEM_SCRATCH &&
                            dut.u_core.u_npu.command.src0_base ==
                                PHASE_E_ADDR_LINEAR_TMP &&
                            dut.u_core.u_npu.command.dst_base ==
                                PHASE_E_ADDR_HIDDEN_A + HIDDEN_SIZE,
                            "patch copy route and bases are exact"
                        );
                        check(
                            dut.u_core.u_npu.command.dim0 == 32'd1 &&
                            dut.u_core.u_npu.command.dim1 == PATCH_COUNT &&
                            dut.u_core.u_npu.command.dim2 == HIDDEN_SIZE &&
                            dut.u_core.u_npu.command.stride0 == 32'd0 &&
                            dut.u_core.u_npu.command.stride1 == HIDDEN_SIZE &&
                            dut.u_core.u_npu.command.stride2 == 32'd1,
                            "patch copy dimensions and strides are exact"
                        );
                    end
                    3: begin
                        check(
                            dut.u_core.u_npu.command.header.opcode ==
                                PHASE_E_OP_VECTOR &&
                            dut.u_core.u_npu.command.header.subop ==
                                PHASE_E_SUBOP_VECTOR_ADD &&
                            dut.u_core.u_npu.command.header.flags == 8'h0c,
                            "command 3 is exact in-place position add"
                        );
                        check(
                            dut.u_core.u_npu.command.route.src0_tensor ==
                                PHASE_E_TENSOR_HIDDEN_A &&
                            dut.u_core.u_npu.command.route.src1_tensor ==
                                PHASE_E_TENSOR_POSITION &&
                            dut.u_core.u_npu.command.route.dst_tensor ==
                                PHASE_E_TENSOR_HIDDEN_A &&
                            dut.u_core.u_npu.command.route.src0_space ==
                                PHASE_E_MEM_SCRATCH &&
                            dut.u_core.u_npu.command.route.src1_space ==
                                PHASE_E_MEM_PARAM &&
                            dut.u_core.u_npu.command.route.dst_space ==
                                PHASE_E_MEM_SCRATCH,
                            "position-add route is exact"
                        );
                        check(
                            dut.u_core.u_npu.command.src0_base ==
                                PHASE_E_ADDR_HIDDEN_A &&
                            dut.u_core.u_npu.command.src1_base == POSITION_BASE &&
                            dut.u_core.u_npu.command.dst_base ==
                                PHASE_E_ADDR_HIDDEN_A &&
                            dut.u_core.u_npu.command.dim0 == HIDDEN_WORDS &&
                            dut.u_core.u_npu.command.immediate == 32'd0,
                            "position-add bases and length are exact"
                        );
                    end
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
        if (!$value$plusargs(
                "M7_MODE3_E01_PREPARED_INPUT_HEX=%s",
                prepared_input_hex_path))
            $fatal(1, "missing E01 prepared-input plusarg");
        if (!$value$plusargs(
                "M7_MODE3_E01_PATCH_WEIGHT_HEX=%s",
                patch_weight_hex_path))
            $fatal(1, "missing E01 packed-weight plusarg");
        if (!$value$plusargs(
                "M7_MODE3_E01_PATCH_BIAS_HEX=%s",
                patch_bias_hex_path))
            $fatal(1, "missing E01 patch-bias plusarg");
        if (!$value$plusargs(
                "M7_MODE3_E01_CLS_HEX=%s", cls_token_hex_path))
            $fatal(1, "missing E01 CLS plusarg");
        if (!$value$plusargs(
                "M7_MODE3_E01_POSITION_HEX=%s", position_hex_path))
            $fatal(1, "missing E01 position plusarg");
        if (!$value$plusargs(
                "M7_MODE3_E01_EMBEDDING_GOLDEN_HEX=%s",
                embedding_golden_hex_path))
            $fatal(1, "missing E01 golden plusarg");
        if (!$value$plusargs(
                "M7_MODE3_E01_ASSET_EVIDENCE_JSON=%s",
                asset_evidence_json_path))
            $fatal(1, "missing E01 asset-evidence plusarg");
        if (!$value$plusargs(
                "M7_MODE3_E01_EMBEDDING_DUMP=%s",
                embedding_dump_path))
            $fatal(1, "missing E01 embedding-dump plusarg");

        asset_evidence_fd = $fopen(asset_evidence_json_path, "r");
        if (asset_evidence_fd == 0)
            $fatal(1, "cannot open staged E01 asset evidence JSON");
        $fclose(asset_evidence_fd);
        embedding_golden_fd = $fopen(embedding_golden_hex_path, "r");
        if (embedding_golden_fd == 0)
            $fatal(1, "cannot open staged E01 behavioral golden");
        $fclose(embedding_golden_fd);
        $display(
            "M7_MODE3_E01_ASSET_PATHS input=%s weight=%s bias=%s cls=%s position=%s golden=%s evidence=%s dump=%s",
            prepared_input_hex_path,
            patch_weight_hex_path,
            patch_bias_hex_path,
            cls_token_hex_path,
            position_hex_path,
            embedding_golden_hex_path,
            asset_evidence_json_path,
            embedding_dump_path
        );

        $readmemh(
            patch_weight_hex_path,
            u_ddr.model_memory,
            PATCH_WEIGHT_BASE,
            PATCH_WEIGHT_BASE + PATCH_WEIGHT_WORDS - 1
        );
        $readmemh(
            patch_bias_hex_path,
            u_ddr.model_memory,
            PATCH_BIAS_BASE,
            PATCH_BIAS_BASE + HIDDEN_SIZE - 1
        );
        $readmemh(
            cls_token_hex_path,
            u_ddr.model_memory,
            CLS_BASE,
            CLS_BASE + HIDDEN_SIZE - 1
        );
        $readmemh(
            position_hex_path,
            u_ddr.model_memory,
            POSITION_BASE,
            POSITION_BASE + HIDDEN_WORDS - 1
        );
        $readmemh(
            prepared_input_hex_path,
            u_ddr.input_memory
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
        check(
            MODEL_BASE[6:0] == 7'd0 &&
            PATCH_WEIGHT_BASE[4:0] == 5'd0 &&
            PATCH_BIAS_BASE[4:0] == 5'd0 &&
            CLS_BASE[4:0] == 5'd0 && POSITION_BASE[4:0] == 5'd0,
            "physical MODEL base and every E01 v3 tensor are 128B aligned"
        );
        check(
            PATCH_WEIGHT_WORDS == 294912 &&
            MODEL_BACKING_WORDS == 447744,
            "E01 packed weight and sparse MODEL backing extents are exact"
        );

        axi_lite_write(REG_MODEL_BASE_LO, MODEL_BASE[31:0]);
        axi_lite_write(REG_MODEL_BASE_HI, MODEL_BASE[63:32]);
        axi_lite_write(REG_INPUT_BASE_LO, INPUT_BASE[31:0]);
        axi_lite_write(REG_INPUT_BASE_HI, INPUT_BASE[63:32]);
        axi_lite_write(REG_SCRATCH_BASE_LO, SCRATCH_BASE[31:0]);
        axi_lite_write(REG_SCRATCH_BASE_HI, SCRATCH_BASE[63:32]);
        axi_lite_write(REG_MODEL_WORDS, MODEL_PACKAGE_V3_WORDS);
        axi_lite_write(REG_INPUT_WORDS, INPUT_WORDS);
        axi_lite_write(REG_SCRATCH_WORDS, SCRATCH_WORDS);

        axi_lite_write(REG_GLOBAL_BASE + 12'h000, PATCH_WEIGHT_BASE);
        axi_lite_write(REG_GLOBAL_BASE + 12'h004, PATCH_BIAS_BASE);
        axi_lite_write(REG_GLOBAL_BASE + 12'h008, CLS_BASE);
        axi_lite_write(REG_GLOBAL_BASE + 12'h00c, POSITION_BASE);
        axi_lite_write(REG_EXECUTION_MODE, 32'h0000_0005);
        axi_lite_read(REG_EXECUTION_MODE, read_data);
        check(read_data == 32'h0000_0005 && dut.u_core.execution_mode_legal,
              "v1.13 compatibility mode 5 is legal");
        axi_lite_write(REG_EXECUTION_MODE, 32'h0000_0003);
        axi_lite_read(REG_EXECUTION_MODE, read_data);
        check(read_data == 32'h0000_0003 && dut.u_core.execution_mode_legal,
              "v1.13 package-v3 execution mode 3 is selected");

        job_config_value = 32'd0;
        job_config_value[2:0] = PHASE_E_E01;
        job_config_value[11] = 1'b0;
        job_config_value[12] = 1'b1;
        job_config_value[20:13] = JOB_TAG;
        check(job_config_value == 32'h0004_1001,
              "E01 JOB_CONFIG encoding is exactly 0x00041001");
        axi_lite_write(REG_JOB_CONFIG, job_config_value);
        axi_lite_read(REG_JOB_CONFIG, read_data);
        check(read_data == 32'h0004_1001,
              "E01 JOB_CONFIG exact value reads back");

        if ($test$plusargs("M7_MODE3_E01_PLUSARG_SMOKE_ONLY")) begin
            check(MODEL_PACKAGE_V3_WORDS == 32'd43421440,
                  "v3 MODEL_WORDS is exactly 43421440");
            check(INPUT_WORDS == 150528,
                  "prepared input is exactly 150528 words");
            axi_lite_read(REG_M7_CAPABILITY, read_data);
            check(read_data == 32'h01ff_0817,
                  "M7 capability is present in E01 plusarg smoke");
            axi_lite_read(REG_M7_GEOMETRY, read_data);
            check(read_data == 32'h0810_0208,
                  "M7 geometry is logical R8/C2/L16 with S8 streams");
            $display(
                "M7_MODE3_E01_PLUSARG_SMOKE_PASS checks=%0d staged_files=6 staged_words=749568 model_words=43421440 backing_words=447744 packed_patch_words=294912 input_words=150528 golden_words=151296 mode=3 job_config=00041001 ip=0001000d geometry=R8C2L16S8",
                checks
            );
            $finish;
        end

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
            EXPECTED_MODEL_READS ==
                EXPECTED_PACKED_WEIGHT_READS + EXPECTED_BIAS_READS +
                EXPECTED_CLS_READS + EXPECTED_POSITION_READS,
            "E01 MODEL oracle partitions packed B, bias, CLS, and position"
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
        check(ddr_ar_transaction_count == EXPECTED_AXI_AR,
              "exact packed-v3 E01 AR transaction count");
        check(ddr_r_beat_count == EXPECTED_AXI_R_BEATS,
              "exact packed-v3 E01 R beat count");
        check(ddr_protocol_error_count == 0 &&
                  ddr_four_kib_error_count == 0,
              "DDR model reports no protocol or 4 KiB violation");
        check(ddr_read_outstanding == 0 && ddr_write_outstanding == 0,
              "all AXI transactions retired before DONE");
        check(ddr_read_outstanding_high_water == 1,
              "packed-v3 E01 reaches exactly one outstanding read");

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
        axi_lite_read64(
            REG_PROFILE_GLOBAL_BASE +
                (PHASE_E_PROFILE_GLOBAL_BIAS_LOOKUP * 8),
            profile_bias_lookups
        );
        axi_lite_read64(
            REG_PROFILE_GLOBAL_BASE +
                (PHASE_E_PROFILE_GLOBAL_BIAS_HIT * 8),
            profile_bias_hits
        );
        axi_lite_read64(
            REG_PROFILE_GLOBAL_BASE +
                (PHASE_E_PROFILE_GLOBAL_BIAS_MISS * 8),
            profile_bias_misses
        );
        check(profile_r_beats == ddr_r_beat_count,
              "profile R beats match physical DDR R beats");
        check(profile_logical_reads == ddr_read_count + profile_cache_hits,
              "logical reads equal useful external FP32 words plus core hits");
        check(profile_bias_lookups == EXPECTED_BIAS_LOOKUPS &&
                  profile_bias_hits == EXPECTED_BIAS_HITS &&
                  profile_bias_misses == EXPECTED_BIAS_MISSES,
              "S8 two-pass bias cache lookup/hit/miss counts are exact");
        check(profile_bias_lookups ==
                  profile_bias_hits + profile_bias_misses,
              "bias cache lookups partition exactly into hits and misses");
        $display(
            "M7_MODE3_E01_BIAS_CACHE lookups=%0d hits=%0d misses=%0d two_pass_refetch=%0d",
            profile_bias_lookups,
            profile_bias_hits,
            profile_bias_misses,
            profile_bias_misses - HIDDEN_SIZE
        );

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
        check(read_data == 32'h0000_0002,
              "M5 snapshot valid with maximum outstanding below two");
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
            "M7_MODE3_E01_TRAFFIC external_u32=%0d model_reads=%0d input_reads=%0d scratch_reads=%0d ar=%0d r_beats=%0d full_r_beats=%0d narrow_r_beats=%0d linefills=%0d line_hits=%0d writes=%0d maxout=%0d",
            ddr_read_count,
            model_read_count,
            input_read_count,
            scratch_read_count,
            ddr_ar_transaction_count,
            ddr_r_beat_count,
            m5_axi_counter[0],
            m5_axi_counter[1],
            m5_axi_counter[2],
            m5_axi_counter[3],
            ddr_write_count,
            m5_axi_counter[5]
        );
        check(m5_axi_counter[0] == EXPECTED_FULL_R_BEATS &&
                  m5_axi_counter[1] == EXPECTED_NARROW_R_BEATS &&
                  m5_axi_counter[2] == EXPECTED_LINEFILLS &&
                  m5_axi_counter[3] == EXPECTED_LINE_HITS,
              "all packed-v3 E01 M5 traffic counters are exact");
        check(m5_axi_counter[0] + m5_axi_counter[1] == ddr_r_beat_count,
              "M5 full and narrow counters partition R beats");
        check(m5_axi_counter[1] + (m5_axi_counter[0] * 4) ==
                  ddr_read_count,
              "M5 beat classes reconstruct external FP32 words");
        check(m5_axi_counter[2] + m5_axi_counter[3] +
                  m5_axi_counter[7] == (m5_axi_counter[0] * 4),
              "M5 linefill demand, hits and discard partition full payload");
        check(ddr_ar_transaction_count ==
                  m5_axi_counter[1] + m5_axi_counter[2],
              "packed-v3 AR count equals narrow reads plus linefills");
        check(m5_axi_counter[4] == 0 && m5_axi_counter[5] == 1 &&
                  m5_axi_counter[6] == 0 && m5_axi_counter[7] == 0,
              "M5 has no split/error/discard and reaches outstanding one");

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
        check(read_data == 32'h0810_0208,
              "M7 geometry is logical R8/C2/L16 with S8 streams");
        axi_lite_read(REG_M7_BUFFER_CONFIG, read_data);
        check(read_data == 32'h0008_0202,
              "M7 buffer contract is banks2/FIFO2/generation8");
        axi_lite_read(REG_M7_NUMERIC_CONFIG, read_data);
        check(read_data == 32'h07c0_d05d,
              "M7 numerical contract is preserved by M8 v1.13");
        for (profile_index = 0; profile_index < 23;
             profile_index = profile_index + 1)
            axi_lite_read64(
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
        $display(
            "M7_MODE3_E01_M7_STATUS raw=%08x running=%0d snapshot=%0d overflow=%0d error=%0d lc=%0d cs=%0d three=%0d both_claimed=%0d claim_mask=%0d bank_max=%0d fifo_max=%0d feeder_wait=%0d result_bp=%0d empty_wait=%0d full_wait=%0d",
            m7_status_value,
            m7_status_value[0],
            m7_status_value[1],
            m7_status_value[2],
            m7_status_value[3],
            m7_status_value[4],
            m7_status_value[5],
            m7_status_value[6],
            m7_status_value[7],
            m7_status_value[9:8],
            m7_status_value[11:10],
            m7_status_value[15:12],
            m7_status_value[16],
            m7_status_value[17],
            m7_status_value[18],
            m7_status_value[19]
        );
        check(m7_counter[0] == EXPECTED_FP16_TERMS,
              "M7 accepted-term count is exact");
        check(m7_counter[1] == EXPECTED_DISABLED_TERMS,
              "M7 disabled-tail term count is exact");
        check(m7_counter[0] - m7_counter[1] == 64'd115_605_504,
              "M7 enabled terms equal 196x768x768");
        check(m7_counter[2] == EXPECTED_DOT_VECTORS &&
                  m7_counter[3] == EXPECTED_DOT_VECTORS,
              "M7 dot-start and result-vector counts are exact");
        check(m7_counter[14] == EXPECTED_PANELS &&
                  m7_counter[15] == EXPECTED_PANELS &&
                  m7_counter[16] == EXPECTED_PANELS,
              "M7 panel commit/claim/release counts are exact");
        check(m7_counter[19] >= 1 && m7_counter[19] <= 2,
              "M7 operand-bank maximum occupancy is bounded 1..2");
        check(m7_counter[20] == EXPECTED_DOT_VECTORS &&
                  m7_counter[21] == EXPECTED_DOT_VECTORS,
              "M7 FIFO enqueue/dequeue counts are exact");
        check(m7_counter[22] >= 1 && m7_counter[22] <= 2,
              "M7 FIFO maximum occupancy is bounded 1..2");
        check(m7_counter[9] + m7_counter[10] + m7_counter[11] +
                  m7_counter[12] ==
              m7_counter[6] + m7_counter[7] + m7_counter[8] +
                  m7_counter[13],
              "M7 stage-union inclusion/exclusion identity is exact");
        $display(
            "M7_MODE3_E01_M7_COUNTERS terms=%0d disabled=%0d enabled=%0d dots=%0d results=%0d commits=%0d claims=%0d releases=%0d bank_max=%0d fifo_enqueue=%0d fifo_dequeue=%0d fifo_max=%0d load=%0d compute=%0d store=%0d union=%0d load_compute=%0d compute_store=%0d load_store=%0d three_way=%0d",
            m7_counter[0], m7_counter[1],
            m7_counter[0] - m7_counter[1],
            m7_counter[2], m7_counter[3],
            m7_counter[14], m7_counter[15], m7_counter[16],
            m7_counter[19], m7_counter[20], m7_counter[21],
            m7_counter[22], m7_counter[6], m7_counter[7],
            m7_counter[8], m7_counter[9], m7_counter[10],
            m7_counter[11], m7_counter[12], m7_counter[13]
        );
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

        embedding_nonfinite_count = 0;
        embedding_sentinel_count = 0;
        hidden_b_modified_count = 0;

        for (compare_index = 0; compare_index < HIDDEN_WORDS;
             compare_index = compare_index + 1) begin
            if (!fp32_is_finite(u_ddr.scratch_memory[
                    PHASE_E_ADDR_HIDDEN_A + compare_index]))
                embedding_nonfinite_count = embedding_nonfinite_count + 1;
            if (u_ddr.scratch_memory[
                    PHASE_E_ADDR_HIDDEN_A + compare_index] === FP32_SENTINEL)
                embedding_sentinel_count = embedding_sentinel_count + 1;
            if (
                u_ddr.scratch_memory[
                    PHASE_E_ADDR_HIDDEN_B + compare_index
                ] !== FP32_SENTINEL
            )
                hidden_b_modified_count = hidden_b_modified_count + 1;
        end

        $display(
            "M7_MODE3_E01_OUTPUT_STRUCTURE embedding_words=%0d embedding_nonfinite=%0d embedding_sentinel=%0d hidden_b_modified=%0d",
            HIDDEN_WORDS,
            embedding_nonfinite_count,
            embedding_sentinel_count,
            hidden_b_modified_count
        );
        check(embedding_nonfinite_count == 0,
              "all 151296 HIDDEN_A words are finite");
        check(embedding_sentinel_count == 0,
              "all 151296 HIDDEN_A words were produced");
        check(hidden_b_modified_count == 0,
            "E01 leaves the alternate HIDDEN_B buffer untouched"
        );
        $writememh(
            embedding_dump_path,
            u_ddr.scratch_memory,
            PHASE_E_ADDR_HIDDEN_A,
            PHASE_E_ADDR_HIDDEN_A + HIDDEN_WORDS - 1
        );
        $display(
            "M7_MODE3_E01_OUTPUT_DUMP embedding_words=%0d embedding=%s numerical_status=PENDING_EXTERNAL_M6_CURRENT_ADDER_AND_BEHAVIORAL_ORACLES",
            HIDDEN_WORDS,
            embedding_dump_path
        );

        axi_lite_write(REG_IRQ_STATUS, 32'h0000_0001);
        @(posedge aclk);
        check(!irq_o, "RW1C clears the done IRQ");
        axi_lite_read(REG_IRQ_STATUS, read_data);
        check(read_data == 32'd0, "IRQ status reads clear");

        if (failures == 0) begin
            $display(
                "VIT_PHASE_E_AXI_E01_MODE3_REAL_RTL_STRUCTURAL_PASS checks=%0d cycles=%0d commands=%0d external_u32=%0d writes=%0d model_reads=%0d input_reads=%0d scratch_reads=%0d numerical_status=PENDING_EXTERNAL_M6_CURRENT_ADDER_AND_BEHAVIORAL_ORACLES",
                checks,
                cycle_count,
                command_count,
                ddr_read_count,
                ddr_write_count,
                model_read_count,
                input_read_count,
                scratch_read_count
            );
            $finish;
        end else begin
            $fatal(
                1,
                "VIT_PHASE_E_AXI_E01_MODE3_REAL_RTL_STRUCTURAL_FAIL checks=%0d failures=%0d",
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
