`timescale 1ns/1ps

// Focused integration regression: logical 32-bit requests -> M5 adapter ->
// native AXI128 DDR model.  The raw DDR-model test covers malformed slave
// behavior in detail; this test proves adapter lane steering, line-fill/cache
// behavior, two same-ID bursts, 4 KiB split, tail fallback, scalar writes and
// bounded fault propagation.
module tb_vit_phase_e_axi_mem_adapter_m5;

    localparam integer AXI_ADDR_WIDTH = 40;
    localparam integer AXI_ID_WIDTH = 1;
    localparam integer MODEL_WORDS = 2048;
    localparam integer INPUT_WORDS = 256;
    localparam integer SCRATCH_WORDS = 2048;

    localparam logic [1:0] MEM_NONE    = 2'd0;
    localparam logic [1:0] MEM_SCRATCH = 2'd1;
    localparam logic [1:0] MEM_MODEL   = 2'd2;
    localparam logic [1:0] MEM_INPUT   = 2'd3;

    localparam logic [63:0] MODEL_BASE = 64'h0000_0001_0000_1000;
    localparam logic [63:0] INPUT_BASE = 64'h0000_0002_0000_0000;
    localparam logic [63:0] SCRATCH_BASE = 64'h0000_0003_0000_2000;

    logic aclk;
    logic aresetn;

    logic cache_invalidate;
    logic req_valid;
    logic req_ready;
    logic req_write;
    logic [1:0] req_space;
    logic [31:0] req_word_address;
    logic [31:0] req_write_data;
    logic [3:0] req_write_strobe;
    logic req_read_ahead_safe;
    logic [5:0] req_contiguous_words;
    logic rsp_valid;
    logic rsp_ready;
    logic [31:0] rsp_read_data;
    logic rsp_error;

    logic axi_r_protocol_error;
    logic axi_b_protocol_error;
    logic linefill_start;
    logic linefill_hit;
    logic full_r_beat;
    logic narrow_r_beat;
    logic four_k_split;
    logic [5:0] prefetched_words_discarded;
    logic [1:0] adapter_read_outstanding;

    logic [AXI_ID_WIDTH-1:0] awid;
    logic [AXI_ADDR_WIDTH-1:0] awaddr;
    logic [7:0] awlen;
    logic [2:0] awsize;
    logic [1:0] awburst;
    logic awlock;
    logic [3:0] awcache;
    logic [2:0] awprot;
    logic [3:0] awqos;
    logic awvalid;
    logic awready;
    logic [127:0] wdata;
    logic [15:0] wstrb;
    logic wlast;
    logic wvalid;
    logic wready;
    logic [AXI_ID_WIDTH-1:0] bid;
    logic [1:0] bresp;
    logic bvalid;
    logic bready;
    logic [AXI_ID_WIDTH-1:0] arid;
    logic [AXI_ADDR_WIDTH-1:0] araddr;
    logic [7:0] arlen;
    logic [2:0] arsize;
    logic [1:0] arburst;
    logic arlock;
    logic [3:0] arcache;
    logic [2:0] arprot;
    logic [3:0] arqos;
    logic arvalid;
    logic arready;
    logic [AXI_ID_WIDTH-1:0] rid;
    logic [127:0] rdata;
    logic [1:0] rresp;
    logic rlast;
    logic rvalid;
    logic rready;

    logic fault_rresp_enable;
    logic [7:0] fault_rresp_beat;
    logic [1:0] fault_rresp_value;
    logic fault_rid_enable;
    logic [AXI_ID_WIDTH-1:0] fault_rid_value;
    logic [1:0] fault_rlast_mode;
    logic fault_bresp_enable;
    logic [1:0] fault_bresp_value;
    logic fault_bid_enable;
    logic [AXI_ID_WIDTH-1:0] fault_bid_value;

    logic [63:0] ddr_read_words;
    logic [63:0] ddr_write_words;
    logic [63:0] ddr_ar_transactions;
    logic [63:0] ddr_aw_transactions;
    logic [63:0] ddr_r_beats;
    logic [63:0] ddr_w_beats;
    logic [63:0] ddr_b_responses;
    logic [31:0] ddr_invalid_accesses;
    logic [31:0] ddr_protocol_errors;
    logic [31:0] ddr_four_kib_errors;
    logic [31:0] ddr_read_outstanding;
    logic [31:0] ddr_read_outstanding_high_water;

    logic [31:0] scratch_expected [0:SCRATCH_WORDS-1];
    integer checks;
    integer seed;
    integer initial_seed;
    integer iterations;
    integer init_index;
    integer test_index;
    integer ar_observed;
    integer full_ar_observed;
    integer narrow_ar_observed;
    integer linefill_start_observed;
    integer linefill_hit_observed;
    integer four_k_split_observed;
    integer full_r_beat_observed;
    integer narrow_r_beat_observed;
    integer r_protocol_error_observed;
    integer b_protocol_error_observed;
    integer random_word;
    integer random_lane;
    logic [31:0] random_data;
    logic [3:0] random_strobe;
    logic [31:0] prior_word;
    logic [31:0] expected_word;

    vit_phase_e_axi_mem_adapter #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_BEATS(4),
        .MAX_LINE_WORDS(32),
        .MAX_READ_OUTSTANDING(2)
    ) dut (
        .aclk(aclk),
        .aresetn(aresetn),
        .scratch_base_i(SCRATCH_BASE),
        .model_base_i(MODEL_BASE),
        .input_base_i(INPUT_BASE),
        .scratch_words_i(SCRATCH_WORDS),
        .model_words_i(MODEL_WORDS),
        .input_words_i(INPUT_WORDS),
        .cache_invalidate_i(cache_invalidate),
        .req_valid(req_valid),
        .req_ready(req_ready),
        .req_write(req_write),
        .req_space(req_space),
        .req_word_address(req_word_address),
        .req_write_data(req_write_data),
        .req_write_strobe(req_write_strobe),
        .req_read_ahead_safe(req_read_ahead_safe),
        .req_contiguous_words(req_contiguous_words),
        .rsp_valid(rsp_valid),
        .rsp_ready(rsp_ready),
        .rsp_read_data(rsp_read_data),
        .rsp_error(rsp_error),
        .axi_r_protocol_error_o(axi_r_protocol_error),
        .axi_b_protocol_error_o(axi_b_protocol_error),
        .linefill_start_o(linefill_start),
        .linefill_hit_o(linefill_hit),
        .full_r_beat_o(full_r_beat),
        .narrow_r_beat_o(narrow_r_beat),
        .four_k_split_o(four_k_split),
        .prefetched_words_discarded_o(prefetched_words_discarded),
        .read_outstanding_o(adapter_read_outstanding),
        .m_axi_awid(awid),
        .m_axi_awaddr(awaddr),
        .m_axi_awlen(awlen),
        .m_axi_awsize(awsize),
        .m_axi_awburst(awburst),
        .m_axi_awlock(awlock),
        .m_axi_awcache(awcache),
        .m_axi_awprot(awprot),
        .m_axi_awqos(awqos),
        .m_axi_awvalid(awvalid),
        .m_axi_awready(awready),
        .m_axi_wdata(wdata),
        .m_axi_wstrb(wstrb),
        .m_axi_wlast(wlast),
        .m_axi_wvalid(wvalid),
        .m_axi_wready(wready),
        .m_axi_bid(bid),
        .m_axi_bresp(bresp),
        .m_axi_bvalid(bvalid),
        .m_axi_bready(bready),
        .m_axi_arid(arid),
        .m_axi_araddr(araddr),
        .m_axi_arlen(arlen),
        .m_axi_arsize(arsize),
        .m_axi_arburst(arburst),
        .m_axi_arlock(arlock),
        .m_axi_arcache(arcache),
        .m_axi_arprot(arprot),
        .m_axi_arqos(arqos),
        .m_axi_arvalid(arvalid),
        .m_axi_arready(arready),
        .m_axi_rid(rid),
        .m_axi_rdata(rdata),
        .m_axi_rresp(rresp),
        .m_axi_rlast(rlast),
        .m_axi_rvalid(rvalid),
        .m_axi_rready(rready)
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
    ) ddr (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axi_awid(awid), .s_axi_awaddr(awaddr),
        .s_axi_awlen(awlen), .s_axi_awsize(awsize),
        .s_axi_awburst(awburst), .s_axi_awlock(awlock),
        .s_axi_awcache(awcache), .s_axi_awprot(awprot),
        .s_axi_awqos(awqos), .s_axi_awvalid(awvalid),
        .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb),
        .s_axi_wlast(wlast), .s_axi_wvalid(wvalid),
        .s_axi_wready(wready),
        .s_axi_bid(bid), .s_axi_bresp(bresp),
        .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_arid(arid), .s_axi_araddr(araddr),
        .s_axi_arlen(arlen), .s_axi_arsize(arsize),
        .s_axi_arburst(arburst), .s_axi_arlock(arlock),
        .s_axi_arcache(arcache), .s_axi_arprot(arprot),
        .s_axi_arqos(arqos), .s_axi_arvalid(arvalid),
        .s_axi_arready(arready),
        .s_axi_rid(rid), .s_axi_rdata(rdata),
        .s_axi_rresp(rresp), .s_axi_rlast(rlast),
        .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .fault_rresp_enable_i(fault_rresp_enable),
        .fault_rresp_id_i('0),
        .fault_rresp_beat_i(fault_rresp_beat),
        .fault_rresp_value_i(fault_rresp_value),
        .fault_rid_enable_i(fault_rid_enable),
        .fault_rid_value_i(fault_rid_value),
        .fault_rlast_mode_i(fault_rlast_mode),
        .fault_bresp_enable_i(fault_bresp_enable),
        .fault_bresp_id_i('0),
        .fault_bresp_value_i(fault_bresp_value),
        .fault_bid_enable_i(fault_bid_enable),
        .fault_bid_value_i(fault_bid_value),
        .read_count_o(ddr_read_words),
        .write_count_o(ddr_write_words),
        .model_read_count_o(), .input_read_count_o(),
        .scratch_read_count_o(), .scratch_write_count_o(),
        .ar_transaction_count_o(ddr_ar_transactions),
        .aw_transaction_count_o(ddr_aw_transactions),
        .r_beat_count_o(ddr_r_beats),
        .w_beat_count_o(ddr_w_beats),
        .b_response_count_o(ddr_b_responses),
        .ar_requested_beat_count_o(),
        .aw_requested_beat_count_o(),
        .ar_backpressure_cycle_count_o(),
        .aw_backpressure_cycle_count_o(),
        .w_backpressure_cycle_count_o(),
        .r_backpressure_cycle_count_o(),
        .b_backpressure_cycle_count_o(),
        .invalid_access_count_o(ddr_invalid_accesses),
        .protocol_error_count_o(ddr_protocol_errors),
        .four_kib_error_count_o(ddr_four_kib_errors),
        .read_outstanding_count_o(ddr_read_outstanding),
        .write_outstanding_count_o(),
        .read_outstanding_high_water_o(
            ddr_read_outstanding_high_water
        ),
        .write_outstanding_high_water_o()
    );

    initial begin
        aclk = 1'b0;
        forever #5 aclk = ~aclk;
    end

    function automatic logic [31:0] model_pattern(input integer index);
        model_pattern = 32'h4100_0000 ^ index;
    endfunction

    function automatic logic [31:0] input_pattern(input integer index);
        input_pattern = 32'h5200_0000 ^ (index * 32'd7);
    endfunction

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (!condition)
                $fatal(1, "CHECK FAILED: %s", message);
        end
    endtask

    task automatic clear_faults;
        begin
            fault_rresp_enable = 1'b0;
            fault_rresp_beat = 8'd0;
            fault_rresp_value = 2'b10;
            fault_rid_enable = 1'b0;
            fault_rid_value = '0;
            fault_rlast_mode = 2'd0;
            fault_bresp_enable = 1'b0;
            fault_bresp_value = 2'b10;
            fault_bid_enable = 1'b0;
            fault_bid_value = '0;
        end
    endtask

    task automatic issue_request(
        input logic write_request,
        input logic [1:0] space,
        input logic [31:0] word_address,
        input logic [31:0] write_data_value,
        input logic [3:0] write_strobe_value,
        input logic read_ahead_safe,
        input logic [5:0] contiguous_words
    );
        integer watchdog;
        begin
            @(negedge aclk);
            req_write = write_request;
            req_space = space;
            req_word_address = word_address;
            req_write_data = write_data_value;
            req_write_strobe = write_strobe_value;
            req_read_ahead_safe = read_ahead_safe;
            req_contiguous_words = contiguous_words;
            req_valid = 1'b1;
            watchdog = 0;
            while (!req_ready) begin
                @(negedge aclk);
                watchdog = watchdog + 1;
                if (watchdog > 1000)
                    $fatal(1, "logical request timeout");
            end
            @(negedge aclk);
            req_valid = 1'b0;
        end
    endtask

    task automatic accept_response(
        input logic [31:0] expected_data,
        input logic expected_error,
        input integer hold_cycles
    );
        integer watchdog;
        integer hold_index;
        logic [31:0] held_data;
        logic held_error;
        begin
            rsp_ready = 1'b0;
            watchdog = 0;
            while (!rsp_valid) begin
                @(negedge aclk);
                watchdog = watchdog + 1;
                if (watchdog > 5000)
                    $fatal(1, "logical response timeout");
            end
            held_data = rsp_read_data;
            held_error = rsp_error;
            check(held_data === expected_data, "logical response data");
            check(held_error === expected_error, "logical response error");
            for (hold_index = 0; hold_index < hold_cycles;
                 hold_index = hold_index + 1) begin
                @(negedge aclk);
                check(rsp_valid, "RSP_VALID dropped under backpressure");
                check(rsp_read_data === held_data,
                      "logical response data changed while stalled");
                check(rsp_error === held_error,
                      "logical response error changed while stalled");
                // The M5 adapter has independent depth-2 request and
                // response FIFOs.  A stalled response must remain stable,
                // but it is legal for req_ready to stay asserted while the
                // request FIFO still has capacity.
            end
            @(negedge aclk);
            rsp_ready = 1'b1;
            @(negedge aclk);
            rsp_ready = 1'b0;
            check(!rsp_valid, "logical response failed to retire");
        end
    endtask

    function automatic logic [31:0] apply_strobe(
        input logic [31:0] prior_value,
        input logic [31:0] new_value,
        input logic [3:0] strobe
    );
        integer byte_index;
        logic [31:0] result;
        begin
            result = prior_value;
            for (byte_index = 0; byte_index < 4;
                 byte_index = byte_index + 1)
                if (strobe[byte_index])
                    result[byte_index*8 +: 8] =
                        new_value[byte_index*8 +: 8];
            apply_strobe = result;
        end
    endfunction

    always @(posedge aclk) begin
        integer page_end;
        if (aresetn) begin
            if (arvalid && arready) begin
                ar_observed = ar_observed + 1;
                check(arid == 0, "ARID is not zero");
                check(arburst == 2'b01, "ARBURST is not INCR");
                check(!arlock, "ARLOCK asserted");
                check((arlen + 1) <= 4, "AR burst exceeds four beats");
                page_end = araddr[11:0] + ((arlen + 1) << arsize);
                check(page_end <= 4096, "AR burst crosses 4 KiB");
                if (arsize == 3'd4) begin
                    full_ar_observed = full_ar_observed + 1;
                    check(araddr[3:0] == 0,
                          "full-width AR is not 16-byte aligned");
                end else begin
                    narrow_ar_observed = narrow_ar_observed + 1;
                    check(arsize == 3'd2,
                          "unsupported narrow ARSIZE");
                    check(arlen == 0, "scalar ARLEN is nonzero");
                end
            end
            if (awvalid && awready) begin
                check(awid == 0, "AWID is not zero");
                check(awlen == 0, "scalar AWLEN is nonzero");
                check(awsize == 3'd2, "scalar AWSIZE is not four bytes");
                check(awburst == 2'b01, "AWBURST is not INCR");
            end
            if (wvalid && wready)
                check(wlast, "scalar WLAST is not asserted");
            if (linefill_start)
                linefill_start_observed = linefill_start_observed + 1;
            if (linefill_hit)
                linefill_hit_observed = linefill_hit_observed + 1;
            if (four_k_split)
                four_k_split_observed = four_k_split_observed + 1;
            if (full_r_beat)
                full_r_beat_observed = full_r_beat_observed + 1;
            if (narrow_r_beat)
                narrow_r_beat_observed = narrow_r_beat_observed + 1;
            if (axi_r_protocol_error)
                r_protocol_error_observed =
                    r_protocol_error_observed + 1;
            if (axi_b_protocol_error)
                b_protocol_error_observed =
                    b_protocol_error_observed + 1;
        end
    end

    initial begin
        checks = 0;
        seed = 32'h1280_2026;
        iterations = 40;
        if ($value$plusargs("SEED=%d", seed)) begin end
        if ($value$plusargs("ITERATIONS=%d", iterations)) begin end
        initial_seed = seed;
        $display("M5 adapter seed=%0d iterations=%0d", seed, iterations);
        ar_observed = 0;
        full_ar_observed = 0;
        narrow_ar_observed = 0;
        linefill_start_observed = 0;
        linefill_hit_observed = 0;
        four_k_split_observed = 0;
        full_r_beat_observed = 0;
        narrow_r_beat_observed = 0;
        r_protocol_error_observed = 0;
        b_protocol_error_observed = 0;

        aresetn = 1'b0;
        cache_invalidate = 1'b0;
        req_valid = 1'b0;
        req_write = 1'b0;
        req_space = MEM_NONE;
        req_word_address = 32'd0;
        req_write_data = 32'd0;
        req_write_strobe = 4'd0;
        req_read_ahead_safe = 1'b0;
        req_contiguous_words = 6'd0;
        rsp_ready = 1'b0;
        clear_faults();

        for (init_index = 0; init_index < MODEL_WORDS;
             init_index = init_index + 1)
            ddr.model_memory[init_index] = model_pattern(init_index);
        for (init_index = 0; init_index < INPUT_WORDS;
             init_index = init_index + 1)
            ddr.input_memory[init_index] = input_pattern(init_index);
        for (init_index = 0; init_index < SCRATCH_WORDS;
             init_index = init_index + 1) begin
            scratch_expected[init_index] =
                32'h6300_0000 ^ (init_index * 32'd9);
            ddr.scratch_memory[init_index] = scratch_expected[init_index];
        end

        repeat (5) @(posedge aclk);
        @(negedge aclk);
        aresetn = 1'b1;

        // Unsafe/scalar reads prove all four native lanes.
        for (test_index = 0; test_index < 4;
             test_index = test_index + 1) begin
            issue_request(1'b0, MEM_MODEL, test_index, 32'd0, 4'd0,
                          1'b0, 6'd1);
            accept_response(model_pattern(test_index), 1'b0,
                            test_index + 1);
        end
        check(narrow_ar_observed == 4,
              "scalar lane sweep did not use four narrow ARs");

        // 32 contiguous words produce two four-beat same-ID bursts.  The
        // first logical word is returned, then later words are cache hits.
        ar_observed = 0;
        issue_request(1'b0, MEM_MODEL, 32'd16, 32'd0, 4'd0,
                      1'b1, 6'd32);
        accept_response(model_pattern(16), 1'b0, 3);
        check(ar_observed == 2, "32-word linefill did not issue two ARs");
        check(ddr_read_outstanding_high_water >= 2,
              "two same-ID read transactions were not outstanding");
        check(adapter_read_outstanding == 0,
              "adapter outstanding count did not drain");
        for (test_index = 17; test_index < 24;
             test_index = test_index + 1) begin
            issue_request(1'b0, MEM_MODEL, test_index, 32'd0, 4'd0,
                          1'b0, 6'd1);
            accept_response(model_pattern(test_index), 1'b0, 0);
        end
        check(ar_observed == 2, "line hits unexpectedly accessed DDR");
        check(linefill_hit_observed >= 7,
              "linefill cache hits were not observed");

        // Start 16 bytes before a page boundary.  The adapter must emit one
        // one-beat burst and one boundary-safe burst, never a crossing burst.
        ar_observed = 0;
        issue_request(1'b0, MEM_MODEL, 32'd1020, 32'd0, 4'd0,
                      1'b1, 6'd32);
        accept_response(model_pattern(1020), 1'b0, 2);
        check(ar_observed == 2, "4 KiB split did not issue two ARs");
        check(four_k_split_observed >= 1,
              "4 KiB split event not observed");
        check(ddr_four_kib_errors == 0,
              "DDR model observed a 4 KiB violation");

        // A sub-four-word region tail must fall back to an exact scalar read.
        ar_observed = 0;
        issue_request(1'b0, MEM_MODEL, 32'd2046, 32'd0, 4'd0,
                      1'b1, 6'd2);
        accept_response(model_pattern(2046), 1'b0, 1);
        check((ar_observed == 1) && (narrow_ar_observed >= 5),
              "tail request did not use scalar fallback");

        // Scalar writes sweep every lane and arbitrary byte strobes.
        for (test_index = 0; test_index < 4;
             test_index = test_index + 1) begin
            random_data = 32'ha500_0000 ^ test_index;
            random_strobe = 4'b1011 ^ test_index[3:0];
            if (random_strobe == 0)
                random_strobe = 4'hf;
            prior_word = scratch_expected[test_index];
            expected_word = apply_strobe(
                prior_word, random_data, random_strobe
            );
            issue_request(1'b1, MEM_SCRATCH, test_index, random_data,
                          random_strobe, 1'b0, 6'd1);
            accept_response(32'd0, 1'b0, test_index);
            scratch_expected[test_index] = expected_word;
            check(ddr.scratch_memory[test_index] === expected_word,
                  "scalar write lane/strobe mismatch");
        end

        // Invalid logical requests are rejected locally without AXI traffic.
        ar_observed = 0;
        issue_request(1'b0, MEM_NONE, 32'd0, 32'd0, 4'd0,
                      1'b0, 6'd1);
        accept_response(32'd0, 1'b1, 1);
        issue_request(1'b0, MEM_INPUT, INPUT_WORDS, 32'd0, 4'd0,
                      1'b0, 6'd1);
        accept_response(32'd0, 1'b1, 0);
        issue_request(1'b1, MEM_MODEL, 32'd0, 32'hffff_ffff, 4'hf,
                      1'b0, 6'd1);
        accept_response(32'd0, 1'b1, 0);
        check(ar_observed == 0,
              "invalid logical request reached AXI AR");

        // Randomized scalar scoreboard: unsafe reads never prefetch, and
        // scratch writes cover lane placement under model channel stalls.
        for (test_index = 0; test_index < iterations;
             test_index = test_index + 1) begin
            random_word = $urandom(seed) % 180;
            issue_request(1'b0, MEM_INPUT, random_word, 32'd0, 4'd0,
                          1'b0, 6'd1);
            accept_response(input_pattern(random_word), 1'b0,
                            $urandom(seed) % 3);

            random_lane = $urandom(seed) & 3;
            random_word = 64 + (($urandom(seed) % 100) * 4) +
                random_lane;
            random_data = $urandom(seed);
            random_strobe = $urandom(seed) & 4'hf;
            if (random_strobe == 0)
                random_strobe = 4'hf;
            expected_word = apply_strobe(
                scratch_expected[random_word],
                random_data,
                random_strobe
            );
            issue_request(1'b1, MEM_SCRATCH, random_word,
                          random_data, random_strobe, 1'b0, 6'd1);
            accept_response(32'd0, 1'b0, $urandom(seed) % 3);
            scratch_expected[random_word] = expected_word;
            check(ddr.scratch_memory[random_word] === expected_word,
                  "random adapter write scoreboard mismatch");
        end

        // RRESP is a bounded logical error and the failed line is not cached.
        ar_observed = 0;
        fault_rresp_enable = 1'b1;
        fault_rresp_beat = 8'd1;
        fault_rresp_value = 2'b10;
        issue_request(1'b0, MEM_MODEL, 32'd128, 32'd0, 4'd0,
                      1'b1, 6'd16);
        accept_response(model_pattern(128), 1'b1, 2);
        clear_faults();
        check(ar_observed == 1,
              "16-word faulted linefill AR count mismatch");
        issue_request(1'b0, MEM_MODEL, 32'd129, 32'd0, 4'd0,
                      1'b0, 6'd1);
        accept_response(model_pattern(129), 1'b0, 0);
        check(ar_observed == 2,
              "faulted line was incorrectly reused as a cache hit");

        // BRESP and BID faults both propagate through the logical response.
        fault_bresp_enable = 1'b1;
        fault_bresp_value = 2'b11;
        issue_request(1'b1, MEM_SCRATCH, 32'd8,
                      32'hbad0_0001, 4'hf, 1'b0, 6'd1);
        accept_response(32'd0, 1'b1, 1);
        clear_faults();
        fault_bid_enable = 1'b1;
        fault_bid_value = 1'b1;
        issue_request(1'b1, MEM_SCRATCH, 32'd9,
                      32'hbad0_0002, 4'hf, 1'b0, 6'd1);
        accept_response(32'd0, 1'b1, 0);
        clear_faults();
        check(b_protocol_error_observed >= 2,
              "B channel faults were not typed by adapter");

        // A RID framing fault returns exactly one error then fail-closes the
        // adapter in poison state, avoiding silent beat re-attribution.
        fault_rid_enable = 1'b1;
        fault_rid_value = 1'b1;
        issue_request(1'b0, MEM_MODEL, 32'd192, 32'd0, 4'd0,
                      1'b0, 6'd1);
        accept_response(32'd0, 1'b1, 2);
        clear_faults();
        repeat (5) @(posedge aclk);
        check(!req_ready, "RID fault did not fail-close adapter");
        check(r_protocol_error_observed >= 1,
              "RID fault was not typed by adapter");

        check(ddr_invalid_accesses == 0,
              "valid adapter AXI traffic failed DDR range checks");
        check(ddr_protocol_errors == 0,
              "adapter emitted unsupported AXI traffic");
        check(ddr_read_outstanding == 0,
              "DDR outstanding reads did not drain");
        // Direct, non-scalar counter identities.
        check(ddr_r_beats >= ddr_ar_transactions,
              "R beat count is below AR transaction count");
        check(ddr_b_responses == ddr_aw_transactions,
              "B response count does not match AW transactions");
        check(ddr_w_beats == ddr_aw_transactions,
              "scalar write beat count does not match AW transactions");
        check(full_ar_observed >= 5,
              "full-width burst coverage was insufficient");
        check(full_r_beat_observed > 0,
              "full-width R beat event was not observed");
        check(narrow_r_beat_observed > 0,
              "narrow R beat event was not observed");
        check(linefill_start_observed >= 3,
              "linefill-start coverage was insufficient");

        $display("M5_AXI128_ADAPTER_INTEGRATION PASS checks=%0d seed=%0d AR=%0d Rbeats=%0d AW=%0d writes=%0d",
                 checks, initial_seed, ddr_ar_transactions, ddr_r_beats,
                 ddr_aw_transactions, ddr_write_words);
        $finish;
    end

    initial begin
        #10_000_000;
        $fatal(1, "M5 adapter integration testbench timeout");
    end

endmodule
