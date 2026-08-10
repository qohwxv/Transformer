`timescale 1ns/1ps

module tb_vit_phase_e_engine_axi;

    import vit_phase_e_pkg::*;
    import vit_fp32_pkg::*;

    localparam integer AXI_ADDR_WIDTH = 40;
    localparam integer AXI_ID_WIDTH = 1;
    localparam integer RAM_WORDS = 512;
    localparam logic [63:0] SCRATCH_BASE = 64'h0000_0000_0000_1000;
    localparam logic [31:0] SRC0_WORD = 32'd0;
    localparam logic [31:0] SRC1_WORD = 32'd64;
    localparam logic [31:0] DST_WORD = 32'd128;
    localparam integer VECTOR_LENGTH = 17;

    logic clk = 1'b0;
    logic rst = 1'b1;
    wire aresetn = !rst;

    logic cmd_valid = 1'b0;
    logic cmd_ready;
    phase_e_cmd_t cmd;
    logic cmd_done;
    logic cmd_error;
    logic busy;

    logic parameter_request;
    phase_e_cmd_t parameter_command;

    logic mem_req_valid;
    logic mem_req_ready;
    logic mem_req_write;
    phase_e_mem_space_t mem_req_space;
    logic [31:0] mem_req_word_address;
    logic [31:0] mem_req_write_data;
    logic [3:0] mem_req_write_strobe;
    logic mem_req_read_ahead_safe;
    logic [5:0] mem_req_contiguous_words;
    logic mem_rsp_valid;
    logic mem_rsp_ready;
    logic [31:0] mem_rsp_read_data;
    logic mem_rsp_error;

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

    logic [63:0] ram_read_count;
    logic [63:0] ram_ar_count;
    logic [63:0] ram_aw_count;
    logic [63:0] ram_w_count;
    logic [63:0] ram_b_count;
    logic [63:0] ram_ar_stall_cycles;
    logic [63:0] ram_aw_stall_cycles;
    logic [63:0] ram_w_stall_cycles;
    logic [31:0] ram_aw_first_count;
    logic [31:0] ram_w_first_count;
    logic [31:0] ram_last_b_cycle;
    logic [31:0] ram_invalid_access_count;
    logic [31:0] ram_protocol_error_count;
    logic [31:0] ram_four_kib_error_count;
    logic [31:0] ram_read_outstanding;
    logic [31:0] ram_write_outstanding;
    logic write_aw_seen;
    logic write_w_seen;

    integer checks = 0;
    integer failures = 0;
    integer test_cycle = 0;
    integer done_count = 0;
    integer done_cycle = -1;
    integer index;
    logic [31:0] expected_word;

    always #5 clk = ~clk;

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $error("CHECK FAILED: %s", message);
            end
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            test_cycle <= 0;
            done_count <= 0;
            done_cycle <= -1;
            ram_aw_first_count <= 0;
            ram_w_first_count <= 0;
            ram_last_b_cycle <= 0;
            write_aw_seen <= 1'b0;
            write_w_seen <= 1'b0;
        end else begin
            test_cycle <= test_cycle + 1;
            if (m_axi_awvalid && m_axi_awready) begin
                if (!write_w_seen && !(m_axi_wvalid && m_axi_wready))
                    ram_aw_first_count <= ram_aw_first_count + 1'b1;
                write_aw_seen <= 1'b1;
            end
            if (m_axi_wvalid && m_axi_wready) begin
                if (!write_aw_seen && !(m_axi_awvalid && m_axi_awready))
                    ram_w_first_count <= ram_w_first_count + 1'b1;
                write_w_seen <= 1'b1;
            end
            if (m_axi_bvalid && m_axi_bready) begin
                ram_last_b_cycle <= test_cycle;
                write_aw_seen <= 1'b0;
                write_w_seen <= 1'b0;
            end
            if (cmd_error) begin
                failures = failures + 1;
                $error("engine asserted cmd_error");
            end
            if (cmd_done) begin
                done_count <= done_count + 1;
                done_cycle <= test_cycle;
                if (ram_b_count != VECTOR_LENGTH) begin
                    failures = failures + 1;
                    $error(
                        "cmd_done before final B: b_count=%0d expected=%0d",
                        ram_b_count,
                        VECTOR_LENGTH
                    );
                end
                if (test_cycle <= ram_last_b_cycle) begin
                    failures = failures + 1;
                    $error(
                        "cmd_done cycle %0d is not after final B cycle %0d",
                        test_cycle,
                        ram_last_b_cycle
                    );
                end
            end
        end
    end

    vit_phase_e_engine_top #(
        .ARRAY_ROWS(2),
        .ARRAY_COLS(2),
        .PE_LANES(16),
        .VECTOR_LANES(16),
        .SCRATCH_WORDS(RAM_WORDS),
        .INPUT_WORDS(RAM_WORDS),
        .PARAM_WORDS(RAM_WORDS)
    ) u_engine (
        .clk(clk),
        .rst(rst),
        .cmd_valid(cmd_valid),
        .cmd_ready(cmd_ready),
        .cmd(cmd),
        .cmd_done(cmd_done),
        .cmd_error(cmd_error),
        .busy(busy),
        .parameter_request(parameter_request),
        .parameter_ready(1'b1),
        .parameter_command(parameter_command),
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_req_write(mem_req_write),
        .mem_req_space(mem_req_space),
        .mem_req_word_address(mem_req_word_address),
        .mem_req_write_data(mem_req_write_data),
        .mem_req_write_strobe(mem_req_write_strobe),
        .mem_req_read_ahead_safe(mem_req_read_ahead_safe),
        .mem_req_contiguous_words(mem_req_contiguous_words),
        .mem_rsp_valid(mem_rsp_valid),
        .mem_rsp_ready(mem_rsp_ready),
        .mem_rsp_read_data(mem_rsp_read_data),
        .mem_rsp_error(mem_rsp_error),
        .input_write_enable(1'b0),
        .input_write_address(32'b0),
        .input_write_data(32'b0),
        .parameter_write_enable(1'b0),
        .parameter_write_address(32'b0),
        .parameter_write_data(32'b0),
        .scratch_write_enable(1'b0),
        .scratch_write_address(32'b0),
        .scratch_write_data(32'b0),
        .scratch_read_address(32'b0),
        .scratch_read_data(),
        .class_result_valid(),
        .class_index(),
        .class_logit()
    );

    vit_phase_e_axi_mem_adapter #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH)
    ) u_adapter (
        .aclk(clk),
        .aresetn(aresetn),
        .scratch_base_i(SCRATCH_BASE),
        .model_base_i(64'h0000_0000_0100_0000),
        .input_base_i(64'h0000_0000_0200_0000),
        .scratch_words_i(RAM_WORDS),
        .model_words_i(RAM_WORDS),
        .input_words_i(RAM_WORDS),
        .cache_invalidate_i(1'b0),
        .req_valid(mem_req_valid),
        .req_ready(mem_req_ready),
        .req_write(mem_req_write),
        .req_space(mem_req_space),
        .req_word_address(mem_req_word_address),
        .req_write_data(mem_req_write_data),
        .req_write_strobe(mem_req_write_strobe),
        .req_read_ahead_safe(mem_req_read_ahead_safe),
        .req_contiguous_words(mem_req_contiguous_words),
        .rsp_valid(mem_rsp_valid),
        .rsp_ready(mem_rsp_ready),
        .rsp_read_data(mem_rsp_read_data),
        .rsp_error(mem_rsp_error),
        .axi_r_protocol_error_o(),
        .axi_b_protocol_error_o(),
        .linefill_start_o(),
        .linefill_hit_o(),
        .full_r_beat_o(),
        .narrow_r_beat_o(),
        .four_k_split_o(),
        .prefetched_words_discarded_o(),
        .read_outstanding_o(),
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
        .m_axi_rready(m_axi_rready)
    );

    vit_axi_ddr_model_128 #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MODEL_WORDS(RAM_WORDS),
        .INPUT_WORDS(RAM_WORDS),
        .SCRATCH_WORDS(RAM_WORDS),
        .MODEL_BASE(64'h0000_0000_0100_0000),
        .INPUT_BASE(64'h0000_0000_0200_0000),
        .SCRATCH_BASE(SCRATCH_BASE),
        .MAX_BURST_BEATS(4),
        .READ_QUEUE_DEPTH(4),
        .WRITE_QUEUE_DEPTH(2),
        .W_QUEUE_DEPTH(4),
        .STALL_ENABLE(1'b1)
    ) u_ram (
        .aclk(clk),
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
        .read_count_o(ram_read_count),
        .write_count_o(),
        .model_read_count_o(),
        .input_read_count_o(),
        .scratch_read_count_o(),
        .scratch_write_count_o(),
        .ar_transaction_count_o(ram_ar_count),
        .aw_transaction_count_o(ram_aw_count),
        .r_beat_count_o(),
        .w_beat_count_o(ram_w_count),
        .b_response_count_o(ram_b_count),
        .ar_requested_beat_count_o(),
        .aw_requested_beat_count_o(),
        .ar_backpressure_cycle_count_o(ram_ar_stall_cycles),
        .aw_backpressure_cycle_count_o(ram_aw_stall_cycles),
        .w_backpressure_cycle_count_o(ram_w_stall_cycles),
        .r_backpressure_cycle_count_o(),
        .b_backpressure_cycle_count_o(),
        .invalid_access_count_o(ram_invalid_access_count),
        .protocol_error_count_o(ram_protocol_error_count),
        .four_kib_error_count_o(ram_four_kib_error_count),
        .read_outstanding_count_o(ram_read_outstanding),
        .write_outstanding_count_o(ram_write_outstanding),
        .read_outstanding_high_water_o(),
        .write_outstanding_high_water_o()
    );

    initial begin
        fork
            begin
                #5_000_000;
                $fatal(1, "engine/AXI integration watchdog timeout");
            end
        join_none

        cmd = '0;

        repeat (5)
            @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        repeat (2)
            @(posedge clk);

        for (index = 0; index < VECTOR_LENGTH; index = index + 1) begin
            u_ram.scratch_memory[SRC0_WORD + index] =
                fp32_from_u32_synth(index + 1);
            u_ram.scratch_memory[SRC1_WORD + index] =
                fp32_from_u32_synth(index + 100);
            u_ram.scratch_memory[DST_WORD + index] = 32'hdead_beef;
        end
        u_ram.scratch_memory[DST_WORD + VECTOR_LENGTH] = 32'hfeed_face;

        cmd.header.opcode = PHASE_E_OP_VECTOR;
        cmd.header.subop = PHASE_E_SUBOP_VECTOR_ADD;
        cmd.header.tag = 8'h5a;
        cmd.route.src0_space = PHASE_E_MEM_SCRATCH;
        cmd.route.src1_space = PHASE_E_MEM_SCRATCH;
        cmd.route.src2_space = PHASE_E_MEM_NONE;
        cmd.route.dst_space = PHASE_E_MEM_SCRATCH;
        cmd.src0_base = SRC0_WORD;
        cmd.src1_base = SRC1_WORD;
        cmd.dst_base = DST_WORD;
        cmd.dim0 = VECTOR_LENGTH;

        check(cmd_ready, "engine not ready before command");
        @(negedge clk);
        cmd_valid = 1'b1;
        do begin
            @(posedge clk);
        end while (!(cmd_valid && cmd_ready));
        @(negedge clk);
        cmd_valid = 1'b0;

        while (done_count == 0)
            @(posedge clk);
        repeat (3)
            @(posedge clk);
        #1;

        check(done_count == 1, "cmd_done pulse count");
        check(!cmd_error, "cmd_error after successful vector command");
        check(!busy, "engine remained busy after cmd_done");
        check(!parameter_request, "scratch-only command requested parameter");
        // M8 gathers each aligned 16-word vector chunk through the existing
        // AXI128 linefill, followed by one narrow tail read per source.
        check(
            ram_ar_count == 4,
            "M8 physical DDR read transaction count"
        );
        check(
            ram_read_count == (2 * VECTOR_LENGTH),
            "physical DDR useful read-word count"
        );
        check(
            ram_aw_count == VECTOR_LENGTH,
            "physical DDR AW transaction count"
        );
        check(
            ram_w_count == VECTOR_LENGTH,
            "physical DDR W transaction count"
        );
        check(
            ram_b_count == VECTOR_LENGTH,
            "physical DDR B response count"
        );
        check(
            done_cycle > ram_last_b_cycle,
            "cmd_done did not follow final B response"
        );
        // Exact ready phasing is covered by the dedicated randomized M5
        // protocol tests.  This production integration test keeps the
        // engine's numerical result and end-to-end AXI accounting invariant
        // independent of the deterministic model phase at reset release.
        check(ram_invalid_access_count == 0, "DDR invalid access observed");
        check(ram_protocol_error_count == 0, "DDR protocol error observed");
        check(ram_four_kib_error_count == 0, "DDR 4 KiB error observed");
        check(ram_read_outstanding == 0, "read outstanding at command end");
        check(ram_write_outstanding == 0, "write outstanding at command end");

        for (index = 0; index < VECTOR_LENGTH; index = index + 1) begin
            expected_word = fp32_from_u32_synth(101 + 2*index);
            check(
                u_ram.scratch_memory[DST_WORD + index] == expected_word,
                "physical DDR vector result word"
            );
        end
        check(
            u_ram.scratch_memory[DST_WORD + VECTOR_LENGTH] == 32'hfeed_face,
            "write crossed the 17-word destination boundary"
        );

        if (failures == 0) begin
            $display(
                "VIT_PHASE_E_ENGINE_AXI_TEST_PASS checks=%0d reads=%0d writes=%0d",
                checks,
                ram_read_count,
                ram_b_count
            );
            $finish;
        end

        $fatal(
            1,
            "VIT_PHASE_E_ENGINE_AXI_TEST_FAIL failures=%0d checks=%0d",
            failures,
            checks
        );
    end

endmodule

// Small AXI4 RAM model with deterministic, independent channel stalls.
// It supports the single-beat, one-outstanding traffic generated by
// vit_phase_e_axi_mem_adapter and intentionally delays every R/B response.
module axi_stall_ram_32 #(
    parameter integer AXI_ADDR_WIDTH = 40,
    parameter integer AXI_ID_WIDTH = 1,
    parameter integer RAM_WORDS = 512,
    parameter logic [AXI_ADDR_WIDTH-1:0] BASE_ADDRESS = '0
) (
    input  logic                         aclk,
    input  logic                         aresetn,

    input  logic [AXI_ID_WIDTH-1:0]      s_axi_awid,
    input  logic [AXI_ADDR_WIDTH-1:0]    s_axi_awaddr,
    input  logic [7:0]                   s_axi_awlen,
    input  logic [2:0]                   s_axi_awsize,
    input  logic [1:0]                   s_axi_awburst,
    input  logic                         s_axi_awvalid,
    output logic                         s_axi_awready,

    input  logic [31:0]                  s_axi_wdata,
    input  logic [3:0]                   s_axi_wstrb,
    input  logic                         s_axi_wlast,
    input  logic                         s_axi_wvalid,
    output logic                         s_axi_wready,

    output logic [AXI_ID_WIDTH-1:0]      s_axi_bid,
    output logic [1:0]                   s_axi_bresp,
    output logic                         s_axi_bvalid,
    input  logic                         s_axi_bready,

    input  logic [AXI_ID_WIDTH-1:0]      s_axi_arid,
    input  logic [AXI_ADDR_WIDTH-1:0]    s_axi_araddr,
    input  logic [7:0]                   s_axi_arlen,
    input  logic [2:0]                   s_axi_arsize,
    input  logic [1:0]                   s_axi_arburst,
    input  logic                         s_axi_arvalid,
    output logic                         s_axi_arready,

    output logic [AXI_ID_WIDTH-1:0]      s_axi_rid,
    output logic [31:0]                  s_axi_rdata,
    output logic [1:0]                   s_axi_rresp,
    output logic                         s_axi_rlast,
    output logic                         s_axi_rvalid,
    input  logic                         s_axi_rready,

    output logic [31:0]                  read_count_o,
    output logic [31:0]                  aw_count_o,
    output logic [31:0]                  w_count_o,
    output logic [31:0]                  b_count_o,
    output logic [31:0]                  ar_stall_cycles_o,
    output logic [31:0]                  aw_stall_cycles_o,
    output logic [31:0]                  w_stall_cycles_o,
    output logic [31:0]                  aw_first_count_o,
    output logic [31:0]                  w_first_count_o,
    output logic [31:0]                  last_b_cycle_o
);

    logic [31:0] memory [0:RAM_WORDS-1];

    logic [31:0] cycle_count;
    logic aw_held;
    logic [AXI_ID_WIDTH-1:0] awid_held;
    logic [AXI_ADDR_WIDTH-1:0] awaddr_held;
    logic aw_protocol_error;
    logic w_held;
    logic [31:0] wdata_held;
    logic [3:0] wstrb_held;
    logic w_protocol_error;
    logic write_pending;
    logic [2:0] write_delay;

    logic read_pending;
    logic [2:0] read_delay;
    logic [AXI_ID_WIDTH-1:0] read_id_held;
    logic [31:0] read_data_held;
    logic read_error_held;

    logic [AXI_ADDR_WIDTH:0] write_byte_offset;
    logic [AXI_ADDR_WIDTH:0] read_byte_offset;
    logic write_address_valid;
    logic read_address_valid;
    integer write_word_index;
    integer read_word_index;
    integer byte_index;

    always_comb begin
        write_byte_offset = {1'b0, awaddr_held} -
                            {1'b0, BASE_ADDRESS};
        read_byte_offset = {1'b0, s_axi_araddr} -
                           {1'b0, BASE_ADDRESS};
        write_word_index = write_byte_offset >> 2;
        read_word_index = read_byte_offset >> 2;
        write_address_valid =
            (awaddr_held >= BASE_ADDRESS) &&
            (awaddr_held[1:0] == 2'b00) &&
            (write_word_index < RAM_WORDS);
        read_address_valid =
            (s_axi_araddr >= BASE_ADDRESS) &&
            (s_axi_araddr[1:0] == 2'b00) &&
            (read_word_index < RAM_WORDS);
    end

    // Different modulo schedules force AW and W to be accepted independently.
    assign s_axi_awready =
        aresetn && !aw_held && !s_axi_bvalid &&
        (cycle_count[1:0] == 2'b01);
    assign s_axi_wready =
        aresetn && !w_held && !s_axi_bvalid &&
        (cycle_count[2:0] == 3'b011);
    assign s_axi_arready =
        aresetn && !read_pending && !s_axi_rvalid &&
        (cycle_count[1:0] == 2'b10);

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            cycle_count <= 32'd0;
            aw_held <= 1'b0;
            awid_held <= '0;
            awaddr_held <= '0;
            aw_protocol_error <= 1'b0;
            w_held <= 1'b0;
            wdata_held <= 32'b0;
            wstrb_held <= 4'b0;
            w_protocol_error <= 1'b0;
            write_pending <= 1'b0;
            write_delay <= 3'd0;
            s_axi_bid <= '0;
            s_axi_bresp <= 2'b00;
            s_axi_bvalid <= 1'b0;
            read_pending <= 1'b0;
            read_delay <= 3'd0;
            read_id_held <= '0;
            read_data_held <= 32'b0;
            read_error_held <= 1'b0;
            s_axi_rid <= '0;
            s_axi_rdata <= 32'b0;
            s_axi_rresp <= 2'b00;
            s_axi_rlast <= 1'b0;
            s_axi_rvalid <= 1'b0;
            read_count_o <= 32'd0;
            aw_count_o <= 32'd0;
            w_count_o <= 32'd0;
            b_count_o <= 32'd0;
            ar_stall_cycles_o <= 32'd0;
            aw_stall_cycles_o <= 32'd0;
            w_stall_cycles_o <= 32'd0;
            aw_first_count_o <= 32'd0;
            w_first_count_o <= 32'd0;
            last_b_cycle_o <= 32'd0;
        end else begin
            cycle_count <= cycle_count + 1'b1;

            if (s_axi_arvalid && !s_axi_arready)
                ar_stall_cycles_o <= ar_stall_cycles_o + 1'b1;
            if (s_axi_awvalid && !s_axi_awready)
                aw_stall_cycles_o <= aw_stall_cycles_o + 1'b1;
            if (s_axi_wvalid && !s_axi_wready)
                w_stall_cycles_o <= w_stall_cycles_o + 1'b1;

            if (s_axi_awvalid && s_axi_awready) begin
                aw_held <= 1'b1;
                awid_held <= s_axi_awid;
                awaddr_held <= s_axi_awaddr;
                aw_protocol_error <=
                    (s_axi_awlen != 0) ||
                    (s_axi_awsize != 3'b010) ||
                    (s_axi_awburst != 2'b01);
                aw_count_o <= aw_count_o + 1'b1;
                if (!w_held &&
                    !(s_axi_wvalid && s_axi_wready))
                    aw_first_count_o <= aw_first_count_o + 1'b1;
            end

            if (s_axi_wvalid && s_axi_wready) begin
                w_held <= 1'b1;
                wdata_held <= s_axi_wdata;
                wstrb_held <= s_axi_wstrb;
                w_protocol_error <= !s_axi_wlast;
                w_count_o <= w_count_o + 1'b1;
                if (!aw_held &&
                    !(s_axi_awvalid && s_axi_awready))
                    w_first_count_o <= w_first_count_o + 1'b1;
            end

            if (aw_held && w_held &&
                !write_pending && !s_axi_bvalid) begin
                if (write_address_valid &&
                    !aw_protocol_error &&
                    !w_protocol_error) begin
                    for (
                        byte_index = 0;
                        byte_index < 4;
                        byte_index = byte_index + 1
                    )
                        if (wstrb_held[byte_index])
                            memory[write_word_index][byte_index*8 +: 8] <=
                                wdata_held[byte_index*8 +: 8];
                    s_axi_bresp <= 2'b00;
                end else begin
                    s_axi_bresp <= 2'b10;
                end
                s_axi_bid <= awid_held;
                write_pending <= 1'b1;
                write_delay <= 3'd3;
            end

            if (write_pending) begin
                if (write_delay != 0)
                    write_delay <= write_delay - 1'b1;
                else begin
                    write_pending <= 1'b0;
                    s_axi_bvalid <= 1'b1;
                end
            end

            if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
                aw_held <= 1'b0;
                w_held <= 1'b0;
                b_count_o <= b_count_o + 1'b1;
                last_b_cycle_o <= cycle_count;
            end

            if (s_axi_arvalid && s_axi_arready) begin
                read_id_held <= s_axi_arid;
                read_pending <= 1'b1;
                read_delay <= 3'd2;
                read_error_held <=
                    !read_address_valid ||
                    (s_axi_arlen != 0) ||
                    (s_axi_arsize != 3'b010) ||
                    (s_axi_arburst != 2'b01);
                if (read_address_valid)
                    read_data_held <= memory[read_word_index];
                else
                    read_data_held <= 32'b0;
            end

            if (read_pending) begin
                if (read_delay != 0)
                    read_delay <= read_delay - 1'b1;
                else begin
                    read_pending <= 1'b0;
                    s_axi_rid <= read_id_held;
                    s_axi_rdata <= read_data_held;
                    s_axi_rresp <= read_error_held ? 2'b10 : 2'b00;
                    s_axi_rlast <= 1'b1;
                    s_axi_rvalid <= 1'b1;
                end
            end

            if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
                s_axi_rlast <= 1'b0;
                read_count_o <= read_count_o + 1'b1;
            end
        end
    end

endmodule
