`timescale 1ns/1ps

module tb_vit_phase_e_axi_mem_adapter;

    localparam integer AXI_ADDR_WIDTH = 40;
    localparam integer AXI_ID_WIDTH = 1;

    localparam logic [1:0] MEM_NONE    = 2'd0;
    localparam logic [1:0] MEM_SCRATCH = 2'd1;
    localparam logic [1:0] MEM_MODEL   = 2'd2;
    localparam logic [1:0] MEM_INPUT   = 2'd3;

    logic aclk = 1'b0;
    logic aresetn = 1'b0;

    logic [63:0] scratch_base = 64'h0000_0000_2000_0000;
    logic [63:0] model_base   = 64'h0000_0012_3456_0000;
    logic [63:0] input_base   = 64'h0000_0001_0000_1000;
    logic [31:0] scratch_words = 32'h0000_1000;
    logic [31:0] model_words = 32'h0000_2000;
    logic [31:0] input_words = 32'h0000_0800;

    logic req_valid = 1'b0;
    logic req_ready;
    logic req_write = 1'b0;
    logic [1:0] req_space = MEM_NONE;
    logic [31:0] req_word_address = 32'b0;
    logic [31:0] req_write_data = 32'b0;
    logic [3:0] req_write_strobe = 4'b0;

    logic rsp_valid;
    logic rsp_ready = 1'b0;
    logic [31:0] rsp_read_data;
    logic rsp_error;

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
    logic m_axi_awready = 1'b0;

    logic [127:0] m_axi_wdata;
    logic [15:0] m_axi_wstrb;
    logic m_axi_wlast;
    logic m_axi_wvalid;
    logic m_axi_wready = 1'b0;

    logic [AXI_ID_WIDTH-1:0] m_axi_bid = '0;
    logic [1:0] m_axi_bresp = 2'b00;
    logic m_axi_bvalid = 1'b0;
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
    logic m_axi_arready = 1'b0;

    logic [AXI_ID_WIDTH-1:0] m_axi_rid = '0;
    logic [127:0] m_axi_rdata = 128'b0;
    logic [1:0] m_axi_rresp = 2'b00;
    logic m_axi_rlast = 1'b0;
    logic m_axi_rvalid = 1'b0;
    logic m_axi_rready;

    integer checks = 0;
    integer failures = 0;

    always #5 aclk = ~aclk;

    vit_phase_e_axi_mem_adapter #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH)
    ) dut (
        .aclk(aclk),
        .aresetn(aresetn),
        .scratch_base_i(scratch_base),
        .model_base_i(model_base),
        .input_base_i(input_base),
        .scratch_words_i(scratch_words),
        .model_words_i(model_words),
        .input_words_i(input_words),
        .cache_invalidate_i(1'b0),
        .req_valid(req_valid),
        .req_ready(req_ready),
        .req_write(req_write),
        .req_space(req_space),
        .req_word_address(req_word_address),
        .req_write_data(req_write_data),
        .req_write_strobe(req_write_strobe),
        .req_read_ahead_safe(1'b0),
        .req_contiguous_words(6'd1),
        .rsp_valid(rsp_valid),
        .rsp_ready(rsp_ready),
        .rsp_read_data(rsp_read_data),
        .rsp_error(rsp_error),
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

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $error("CHECK FAILED: %s", message);
            end
        end
    endtask

    task automatic issue_request(
        input logic write_request,
        input logic [1:0] space,
        input logic [31:0] word_address,
        input logic [31:0] write_data,
        input logic [3:0] write_strobe
    );
        begin
            @(negedge aclk);
            req_write = write_request;
            req_space = space;
            req_word_address = word_address;
            req_write_data = write_data;
            req_write_strobe = write_strobe;
            req_valid = 1'b1;
            do begin
                @(posedge aclk);
            end while (!(req_valid && req_ready));
            @(negedge aclk);
            req_valid = 1'b0;
        end
    endtask

    task automatic accept_response(
        input logic [31:0] expected_data,
        input logic expected_error,
        input integer stall_cycles
    );
        logic [31:0] held_data;
        logic held_error;
        integer cycle_index;
        begin
            while (!rsp_valid) begin
                @(posedge aclk);
                #1;
            end
            held_data = rsp_read_data;
            held_error = rsp_error;
            check(held_data == expected_data, "logical response data");
            check(held_error == expected_error, "logical response error");

            for (
                cycle_index = 0;
                cycle_index < stall_cycles;
                cycle_index = cycle_index + 1
            ) begin
                check(rsp_valid, "RSP_VALID dropped under backpressure");
                check(
                    rsp_read_data == held_data,
                    "response data changed under backpressure"
                );
                check(
                    rsp_error == held_error,
                    "response error changed under backpressure"
                );
                // M5 has independent depth-2 request/response FIFOs, so a
                // stalled response does not require req_ready to deassert.
                check(!$isunknown(req_ready),
                      "request readiness is known under response backpressure");
                @(posedge aclk);
                #1;
            end

            @(negedge aclk);
            rsp_ready = 1'b1;
            @(posedge aclk);
            @(negedge aclk);
            rsp_ready = 1'b0;
            #1;
            check(!rsp_valid, "response did not retire");
            check(req_ready, "adapter did not return idle after response");
        end
    endtask

    task automatic complete_read(
        input logic [AXI_ADDR_WIDTH-1:0] expected_address,
        input logic [31:0] response_data,
        input logic [1:0] response_code,
        input logic response_last,
        input integer address_stall_cycles,
        input integer data_stall_cycles
    );
        logic [AXI_ADDR_WIDTH-1:0] held_address;
        integer cycle_index;
        begin
            while (!m_axi_arvalid) begin
                @(posedge aclk);
                #1;
            end
            held_address = m_axi_araddr;
            check(held_address == expected_address, "AXI read address");
            check(m_axi_arid == 0, "ARID");
            check(m_axi_arlen == 0, "ARLEN is one beat");
            check(m_axi_arsize == 3'b010, "ARSIZE is four bytes");
            check(m_axi_arburst == 2'b01, "ARBURST is INCR");

            for (
                cycle_index = 0;
                cycle_index < address_stall_cycles;
                cycle_index = cycle_index + 1
            ) begin
                check(m_axi_arvalid, "ARVALID dropped while ARREADY low");
                check(
                    m_axi_araddr == held_address,
                    "ARADDR changed while stalled"
                );
                @(posedge aclk);
                #1;
            end

            @(negedge aclk);
            m_axi_arready = 1'b1;
            @(posedge aclk);
            @(negedge aclk);
            m_axi_arready = 1'b0;
            #1;
            check(!m_axi_arvalid, "ARVALID remained after handshake");

            repeat (data_stall_cycles)
                @(posedge aclk);

            @(negedge aclk);
            m_axi_rid = '0;
            m_axi_rdata = 128'b0;
            m_axi_rdata[expected_address[3:2]*32 +: 32] = response_data;
            m_axi_rresp = response_code;
            m_axi_rlast = response_last;
            m_axi_rvalid = 1'b1;
            check(m_axi_rready, "adapter not ready for read response");
            @(posedge aclk);
            @(negedge aclk);
            m_axi_rvalid = 1'b0;
            m_axi_rlast = 1'b0;
        end
    endtask

    task automatic complete_write_aw_first(
        input logic [AXI_ADDR_WIDTH-1:0] expected_address,
        input logic [31:0] expected_data,
        input logic [3:0] expected_strobe,
        input logic [1:0] response_code
    );
        logic [127:0] expected_bus_data;
        logic [15:0] expected_bus_strobe;
        begin
            expected_bus_data = 128'b0;
            expected_bus_strobe = 16'b0;
            expected_bus_data[expected_address[3:2]*32 +: 32] =
                expected_data;
            expected_bus_strobe[expected_address[3:2]*4 +: 4] =
                expected_strobe;
            while (!(m_axi_awvalid && m_axi_wvalid)) begin
                @(posedge aclk);
                #1;
            end
            check(m_axi_awaddr == expected_address, "AXI write address");
            check(m_axi_awid == 0, "AWID");
            check(m_axi_awlen == 0, "AWLEN is one beat");
            check(m_axi_awsize == 3'b010, "AWSIZE is four bytes");
            check(m_axi_awburst == 2'b01, "AWBURST is INCR");
            check(m_axi_wdata == expected_bus_data, "AXI write data");
            check(m_axi_wstrb == expected_bus_strobe, "AXI write strobe");
            check(m_axi_wlast, "WLAST asserted");

            // Accept AW while independently stalling W.
            @(negedge aclk);
            m_axi_awready = 1'b1;
            m_axi_wready = 1'b0;
            @(posedge aclk);
            @(negedge aclk);
            m_axi_awready = 1'b0;
            #1;
            check(!m_axi_awvalid, "AWVALID repeated after acceptance");
            check(m_axi_wvalid, "WVALID dropped while WREADY low");
            check(
                m_axi_wdata == expected_bus_data,
                "WDATA changed while stalled"
            );

            repeat (3) begin
                @(posedge aclk);
                #1;
                check(m_axi_wvalid, "WVALID not held under backpressure");
                check(
                    m_axi_wdata == expected_bus_data &&
                    m_axi_wstrb == expected_bus_strobe &&
                    m_axi_wlast,
                    "write payload changed under backpressure"
                );
            end

            @(negedge aclk);
            m_axi_wready = 1'b1;
            @(posedge aclk);
            @(negedge aclk);
            m_axi_wready = 1'b0;
            #1;
            check(!m_axi_wvalid, "WVALID repeated after acceptance");
            check(m_axi_bready, "BREADY not asserted after AW/W");

            repeat (2)
                @(posedge aclk);
            @(negedge aclk);
            m_axi_bid = '0;
            m_axi_bresp = response_code;
            m_axi_bvalid = 1'b1;
            @(posedge aclk);
            @(negedge aclk);
            m_axi_bvalid = 1'b0;
        end
    endtask

    task automatic complete_write_w_first(
        input logic [AXI_ADDR_WIDTH-1:0] expected_address,
        input logic [31:0] expected_data,
        input logic [3:0] expected_strobe,
        input logic [1:0] response_code
    );
        logic [127:0] expected_bus_data;
        logic [15:0] expected_bus_strobe;
        begin
            expected_bus_data = 128'b0;
            expected_bus_strobe = 16'b0;
            expected_bus_data[expected_address[3:2]*32 +: 32] =
                expected_data;
            expected_bus_strobe[expected_address[3:2]*4 +: 4] =
                expected_strobe;
            while (!(m_axi_awvalid && m_axi_wvalid)) begin
                @(posedge aclk);
                #1;
            end
            check(m_axi_awaddr == expected_address, "W-first AXI address");
            check(m_axi_wdata == expected_bus_data, "W-first AXI data");
            check(m_axi_wstrb == expected_bus_strobe, "W-first AXI strobe");

            // Accept W while independently stalling AW.
            @(negedge aclk);
            m_axi_awready = 1'b0;
            m_axi_wready = 1'b1;
            @(posedge aclk);
            @(negedge aclk);
            m_axi_wready = 1'b0;
            #1;
            check(!m_axi_wvalid, "WVALID repeated after W-first acceptance");
            check(m_axi_awvalid, "AWVALID dropped while AWREADY low");
            check(
                m_axi_awaddr == expected_address,
                "AWADDR changed while stalled"
            );

            repeat (2) begin
                @(posedge aclk);
                #1;
                check(m_axi_awvalid, "AWVALID not held under backpressure");
                check(
                    m_axi_awaddr == expected_address,
                    "AW payload changed under backpressure"
                );
            end

            @(negedge aclk);
            m_axi_awready = 1'b1;
            @(posedge aclk);
            @(negedge aclk);
            m_axi_awready = 1'b0;
            #1;
            check(!m_axi_awvalid, "AWVALID repeated after acceptance");
            check(m_axi_bready, "BREADY not asserted after W/AW");

            @(negedge aclk);
            m_axi_bid = '0;
            m_axi_bresp = response_code;
            m_axi_bvalid = 1'b1;
            @(posedge aclk);
            @(negedge aclk);
            m_axi_bvalid = 1'b0;
        end
    endtask

    initial begin
        fork
            begin
                #1_000_000;
                $fatal(1, "AXI memory adapter testbench watchdog timeout");
            end
        join_none

        repeat (4)
            @(posedge aclk);
        @(negedge aclk);
        aresetn = 1'b1;
        repeat (2)
            @(posedge aclk);
        #1;

        check(req_ready, "adapter not ready after reset");
        check(!rsp_valid, "response valid after reset");
        check(
            !m_axi_awvalid && !m_axi_wvalid && !m_axi_arvalid,
            "AXI request valid after reset"
        );
        check(
            !m_axi_bready && !m_axi_rready,
            "AXI response ready while idle"
        );

        // Model read: AR is stalled and the logical response is also stalled.
        issue_request(
            1'b0,
            MEM_MODEL,
            32'h0000_0012,
            32'b0,
            4'b0
        );
        complete_read(
            40'h12_3456_0048,
            32'h3f80_0000,
            2'b00,
            1'b1,
            4,
            3
        );
        accept_response(32'h3f80_0000, 1'b0, 4);

        // A high word offset proves widening occurs before the << 2.
        scratch_base = 64'h0000_0000_0000_1000;
        scratch_words = 32'h8000_0000;
        issue_request(
            1'b0,
            MEM_SCRATCH,
            32'h4000_0000,
            32'b0,
            4'b0
        );
        complete_read(
            40'h01_0000_1000,
            32'hdead_beef,
            2'b00,
            1'b1,
            0,
            0
        );
        accept_response(32'hdead_beef, 1'b0, 0);

        // RRESP errors and malformed RLAST are reported.
        issue_request(1'b0, MEM_INPUT, 32'd3, 32'b0, 4'b0);
        complete_read(
            40'h01_0000_100c,
            32'h1234_5678,
            2'b10,
            1'b1,
            1,
            1
        );
        accept_response(32'h1234_5678, 1'b1, 1);

        issue_request(1'b0, MEM_INPUT, 32'd4, 32'b0, 4'b0);
        complete_read(
            40'h01_0000_1010,
            32'h8765_4321,
            2'b00,
            1'b0,
            0,
            0
        );
        while (!rsp_valid) begin
            @(posedge aclk);
            #1;
        end
        check(rsp_read_data == 32'd0, "malformed RLAST response is zero");
        check(rsp_error, "malformed RLAST response reports error");
        @(negedge aclk);
        rsp_ready = 1'b1;
        @(posedge aclk);
        @(negedge aclk);
        rsp_ready = 1'b0;
        #1;
        check(!rsp_valid, "poison response did not retire");
        check(!req_ready, "malformed RLAST did not poison adapter");

        // Missing RLAST deliberately poisons the channel until reset.  The
        // remainder of this smoke validates an independent clean epoch.
        @(negedge aclk);
        aresetn = 1'b0;
        @(posedge aclk);
        @(negedge aclk);
        aresetn = 1'b1;
        repeat (2)
            @(posedge aclk);

        // AW-before-W with arbitrary WSTRB.
        scratch_base = 64'h0000_0000_2000_0000;
        scratch_words = 32'h0000_1000;
        issue_request(
            1'b1,
            MEM_SCRATCH,
            32'h0000_0007,
            32'ha5a5_5a5a,
            4'b0101
        );
        complete_write_aw_first(
            40'h00_2000_001c,
            32'ha5a5_5a5a,
            4'b0101,
            2'b00
        );
        accept_response(32'b0, 1'b0, 3);

        // W-before-A and an AXI write response error.
        issue_request(
            1'b1,
            MEM_SCRATCH,
            32'h0000_0008,
            32'hcafe_f00d,
            4'b1111
        );
        complete_write_w_first(
            40'h00_2000_0020,
            32'hcafe_f00d,
            4'b1111,
            2'b11
        );
        accept_response(32'b0, 1'b1, 0);

        // Invalid spaces and bounds fail locally and launch no AXI request.
        issue_request(1'b0, MEM_NONE, 32'd0, 32'b0, 4'b0);
        #1;
        check(
            !m_axi_awvalid && !m_axi_wvalid && !m_axi_arvalid,
            "MEM_NONE launched AXI"
        );
        accept_response(32'b0, 1'b1, 2);

        // MODEL and INPUT are read-only to the compute master. The PS loads
        // these regions outside this adapter.
        issue_request(
            1'b1,
            MEM_MODEL,
            32'd0,
            32'hffff_ffff,
            4'hf
        );
        #1;
        check(
            !m_axi_awvalid && !m_axi_wvalid && !m_axi_arvalid,
            "MODEL write launched AXI"
        );
        accept_response(32'b0, 1'b1, 0);

        issue_request(
            1'b1,
            MEM_INPUT,
            32'd0,
            32'hffff_ffff,
            4'hf
        );
        #1;
        check(
            !m_axi_awvalid && !m_axi_wvalid && !m_axi_arvalid,
            "INPUT write launched AXI"
        );
        accept_response(32'b0, 1'b1, 0);

        issue_request(
            1'b1,
            MEM_INPUT,
            input_words,
            32'hffff_ffff,
            4'hf
        );
        #1;
        check(
            !m_axi_awvalid && !m_axi_wvalid && !m_axi_arvalid,
            "out-of-bounds request launched AXI"
        );
        accept_response(32'b0, 1'b1, 0);

        // Misaligned base is rejected locally.
        input_base = 64'h0000_0001_0000_1002;
        issue_request(1'b0, MEM_INPUT, 32'd0, 32'b0, 4'b0);
        #1;
        check(!m_axi_arvalid, "misaligned base launched AXI");
        accept_response(32'b0, 1'b1, 0);
        input_base = 64'h0000_0001_0000_1000;

        // Address above the configured AXI address width is rejected.
        model_base = 64'h0000_0100_0000_0000;
        issue_request(1'b0, MEM_MODEL, 32'd0, 32'b0, 4'b0);
        #1;
        check(!m_axi_arvalid, "AXI-width overflow launched AXI");
        accept_response(32'b0, 1'b1, 0);
        model_base = 64'h0000_0012_3456_0000;

        // Reset aborts an AR request stalled before its handshake.
        issue_request(1'b0, MEM_MODEL, 32'd1, 32'b0, 4'b0);
        while (!m_axi_arvalid)
            @(posedge aclk);
        @(negedge aclk);
        aresetn = 1'b0;
        @(posedge aclk);
        #1;
        check(!m_axi_arvalid, "reset did not abort AR");
        check(!rsp_valid, "reset created logical response");
        @(negedge aclk);
        aresetn = 1'b1;
        repeat (2)
            @(posedge aclk);
        #1;
        check(req_ready, "adapter not ready after AR reset");

        // Reset also aborts a partial write after AW but before W.
        issue_request(
            1'b1,
            MEM_SCRATCH,
            32'd2,
            32'h0bad_f00d,
            4'hf
        );
        while (!(m_axi_awvalid && m_axi_wvalid))
            @(posedge aclk);
        @(negedge aclk);
        m_axi_awready = 1'b1;
        @(posedge aclk);
        @(negedge aclk);
        m_axi_awready = 1'b0;
        aresetn = 1'b0;
        @(posedge aclk);
        #1;
        check(
            !m_axi_awvalid && !m_axi_wvalid,
            "reset did not abort partial write"
        );
        check(!rsp_valid, "partial write reset created response");
        @(negedge aclk);
        aresetn = 1'b1;
        repeat (2)
            @(posedge aclk);
        #1;
        check(req_ready, "adapter not ready after write reset");

        if (failures == 0) begin
            $display(
                "VIT_PHASE_E_AXI_MEM_ADAPTER_TEST_PASS checks=%0d",
                checks
            );
            $finish;
        end

        $fatal(
            1,
            "VIT_PHASE_E_AXI_MEM_ADAPTER_TEST_FAIL failures=%0d checks=%0d",
            failures,
            checks
        );
    end

endmodule
