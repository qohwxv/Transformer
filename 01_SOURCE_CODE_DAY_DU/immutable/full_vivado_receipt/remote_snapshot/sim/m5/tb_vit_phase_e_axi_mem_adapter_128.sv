`timescale 1ns/1ps

module tb_vit_phase_e_axi_mem_adapter_128;
    localparam integer AXI_ADDR_WIDTH = 40;
    localparam integer AXI_ID_WIDTH = 1;

    logic clk = 1'b0;
    logic resetn = 1'b0;
    always #5 clk = ~clk;

    logic [63:0] scratch_base;
    logic [63:0] model_base;
    logic [63:0] input_base;
    logic [31:0] scratch_words;
    logic [31:0] model_words;
    logic [31:0] input_words;
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
    logic [1:0] read_outstanding;

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

    integer checks;
    integer ar_count;
    integer aw_count;
    integer w_count;
    integer linefill_start_count;
    integer linefill_hit_count;
    integer full_beat_count;
    integer narrow_beat_count;
    integer r_protocol_error_count;
    integer b_protocol_error_count;
    integer four_k_split_count;
    integer discard_event_count;
    integer discard_word_total;
    integer last_discard_words;
    integer max_read_outstanding;
    logic [AXI_ADDR_WIDTH-1:0] araddr_log [0:15];
    logic [7:0] arlen_log [0:15];
    logic [2:0] arsize_log [0:15];
    logic [AXI_ID_WIDTH-1:0] arid_log [0:15];
    logic [AXI_ADDR_WIDTH-1:0] awaddr_log;
    logic [7:0] awlen_log;
    logic [2:0] awsize_log;
    logic [127:0] wdata_log;
    logic [15:0] wstrb_log;
    logic wlast_log;

    vit_phase_e_axi_mem_adapter #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_BEATS(4),
        .MAX_LINE_WORDS(32),
        .MAX_READ_OUTSTANDING(2)
    ) dut (
        .aclk(clk),
        .aresetn(resetn),
        .scratch_base_i(scratch_base),
        .model_base_i(model_base),
        .input_base_i(input_base),
        .scratch_words_i(scratch_words),
        .model_words_i(model_words),
        .input_words_i(input_words),
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
        .read_outstanding_o(read_outstanding),
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

    function automatic [31:0] word_value(input integer word_index);
        word_value = 32'h5a000000 + word_index;
    endfunction

    function automatic [127:0] beat_value(input integer first_word);
        beat_value = {
            word_value(first_word + 3),
            word_value(first_word + 2),
            word_value(first_word + 1),
            word_value(first_word + 0)
        };
    endfunction

    function automatic [127:0] narrow_beat_value(
        input integer word_index,
        input logic [31:0] value
    );
        narrow_beat_value =
            {96'd0, value} << ((word_index & 3) * 32);
    endfunction

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (!condition) begin
                $display("FAIL check=%0d: %s", checks, message);
                $fatal(1);
            end
        end
    endtask

    task automatic reset_dut;
        integer cycle;
        begin
            resetn = 1'b0;
            req_valid = 1'b0;
            req_write = 1'b0;
            req_space = 2'd2;
            req_word_address = 32'd0;
            req_write_data = 32'd0;
            req_write_strobe = 4'hf;
            req_read_ahead_safe = 1'b0;
            req_contiguous_words = 6'd1;
            rsp_ready = 1'b1;
            cache_invalidate = 1'b0;
            arready = 1'b0;
            awready = 1'b0;
            wready = 1'b0;
            rid = '0;
            rdata = 128'd0;
            rresp = 2'b00;
            rlast = 1'b0;
            rvalid = 1'b0;
            bid = '0;
            bresp = 2'b00;
            bvalid = 1'b0;
            scratch_base = 64'h0000_0000_2700_0000;
            model_base = 64'h0000_0000_1000_0000;
            input_base = 64'h0000_0000_24b0_0000;
            scratch_words = 32'h0010_0000;
            model_words = 32'h0100_0000;
            input_words = 32'h0004_0000;
            for (cycle = 0; cycle < 4; cycle = cycle + 1)
                @(posedge clk);
            @(negedge clk);
            resetn = 1'b1;
            @(posedge clk);
        end
    endtask

    task automatic issue_request(
        input logic write_request,
        input logic [1:0] space,
        input logic [31:0] word_address,
        input logic [31:0] write_value,
        input logic [3:0] write_mask,
        input logic read_ahead,
        input logic [5:0] contiguous_words
    );
        integer timeout;
        begin
            @(negedge clk);
            req_write = write_request;
            req_space = space;
            req_word_address = word_address;
            req_write_data = write_value;
            req_write_strobe = write_mask;
            req_read_ahead_safe = read_ahead;
            req_contiguous_words = contiguous_words;
            req_valid = 1'b1;
            timeout = 0;
            while (!req_ready && timeout < 100) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            check(req_ready, "logical request timed out waiting for ready");
            @(posedge clk);
            @(negedge clk);
            req_valid = 1'b0;
        end
    endtask

    task automatic send_r_beat(
        input logic [127:0] value,
        input logic last,
        input logic [1:0] response,
        input logic [AXI_ID_WIDTH-1:0] response_id
    );
        integer timeout;
        begin
            @(negedge clk);
            rdata = value;
            rlast = last;
            rresp = response;
            rid = response_id;
            rvalid = 1'b1;
            timeout = 0;
            while (!rready && timeout < 100) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            check(rready, "AXI R beat timed out waiting for RREADY");
            @(posedge clk);
            @(negedge clk);
            rvalid = 1'b0;
            rlast = 1'b0;
            rresp = 2'b00;
            rid = '0;
            rdata = 128'd0;
        end
    endtask

    task automatic send_b_response(
        input logic [1:0] response,
        input logic [AXI_ID_WIDTH-1:0] response_id
    );
        integer timeout;
        begin
            @(negedge clk);
            bresp = response;
            bid = response_id;
            bvalid = 1'b1;
            timeout = 0;
            while (!bready && timeout < 100) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            check(bready, "AXI B response timed out waiting for BREADY");
            @(posedge clk);
            @(negedge clk);
            bvalid = 1'b0;
            bresp = 2'b00;
            bid = '0;
        end
    endtask

    task automatic accept_response(
        input logic [31:0] expected_data,
        input logic expected_error
    );
        integer timeout;
        begin
            timeout = 0;
            while (!rsp_valid && timeout < 100) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            check(rsp_valid, "logical response timed out");
            check(rsp_read_data === expected_data,
                  "logical response data mismatch");
            check(rsp_error === expected_error,
                  "logical response error mismatch");
            rsp_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
        end
    endtask

    task automatic pop_one_response(
        input logic [31:0] expected_data,
        input logic expected_error
    );
        integer timeout;
        begin
            rsp_ready = 1'b0;
            timeout = 0;
            while (!rsp_valid && timeout < 100) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            check(rsp_valid, "response FIFO pop timed out");
            check(rsp_read_data === expected_data,
                  "response FIFO data order mismatch");
            check(rsp_error === expected_error,
                  "response FIFO error order mismatch");
            @(negedge clk);
            rsp_ready = 1'b1;
            @(posedge clk);
            @(negedge clk);
            rsp_ready = 1'b0;
        end
    endtask

    task automatic wait_for_ar_count(input integer target);
        integer timeout;
        begin
            timeout = 0;
            while ((ar_count < target) && (timeout < 100)) begin
                @(negedge clk);
                timeout = timeout + 1;
            end
            check(ar_count >= target, "AR handshake count timed out");
        end
    endtask

    always @(posedge clk) begin
        if (!resetn) begin
            ar_count = 0;
            aw_count = 0;
            w_count = 0;
            linefill_start_count = 0;
            linefill_hit_count = 0;
            full_beat_count = 0;
            narrow_beat_count = 0;
            r_protocol_error_count = 0;
            b_protocol_error_count = 0;
            four_k_split_count = 0;
            discard_event_count = 0;
            discard_word_total = 0;
            last_discard_words = 0;
            max_read_outstanding = 0;
        end else begin
            if (arvalid && arready) begin
                araddr_log[ar_count] = araddr;
                arlen_log[ar_count] = arlen;
                arsize_log[ar_count] = arsize;
                arid_log[ar_count] = arid;
                ar_count = ar_count + 1;
            end
            if (awvalid && awready) begin
                awaddr_log = awaddr;
                awlen_log = awlen;
                awsize_log = awsize;
                aw_count = aw_count + 1;
            end
            if (wvalid && wready) begin
                wdata_log = wdata;
                wstrb_log = wstrb;
                wlast_log = wlast;
                w_count = w_count + 1;
            end
            if (linefill_start)
                linefill_start_count = linefill_start_count + 1;
            if (linefill_hit)
                linefill_hit_count = linefill_hit_count + 1;
            if (full_r_beat)
                full_beat_count = full_beat_count + 1;
            if (narrow_r_beat)
                narrow_beat_count = narrow_beat_count + 1;
            if (axi_r_protocol_error)
                r_protocol_error_count = r_protocol_error_count + 1;
            if (axi_b_protocol_error)
                b_protocol_error_count = b_protocol_error_count + 1;
            if (four_k_split)
                four_k_split_count = four_k_split_count + 1;
            if (prefetched_words_discarded != 0) begin
                discard_event_count = discard_event_count + 1;
                discard_word_total = discard_word_total +
                    prefetched_words_discarded;
                last_discard_words = prefetched_words_discarded;
            end
            if (read_outstanding > max_read_outstanding)
                max_read_outstanding = read_outstanding;
        end
    end

    integer beat;
    integer word_index;
    integer ar_before;
    integer fifo_timeout;
    logic [31:0] held_rsp_data;
    logic held_rsp_error;

    initial begin
        checks = 0;

        // 32 words become two same-ID four-beat native transfers.  Both ARs
        // are deliberately accepted before any R data, proving two reads can
        // be outstanding.  Every cached scalar word is then checked.
        $display("TEST 1: two-burst line fill and hits");
        reset_dut();
        issue_request(1'b0, 2'd2, 32'd0, 32'd0, 4'h0, 1'b1, 6'd32);
        while (!arvalid) @(negedge clk);
        repeat (3) begin
            @(negedge clk);
            check(arvalid && (araddr == 40'h0010000000) &&
                  (arlen == 8'd3) && (arsize == 3'd4),
                  "AR payload changed while ARREADY was low");
        end
        arready = 1'b1;
        wait_for_ar_count(2);
        @(negedge clk);
        check(ar_count == 2, "line fill must issue exactly two ARs");
        check(araddr_log[0] == 40'h0010000000,
              "first burst address mismatch");
        check(araddr_log[1] == 40'h0010000040,
              "second burst address mismatch");
        check((arlen_log[0] == 8'd3) && (arlen_log[1] == 8'd3),
              "32-word line must use two four-beat bursts");
        check((arsize_log[0] == 3'd4) && (arsize_log[1] == 3'd4),
              "line-fill ARSIZE must encode 16 bytes");
        check((arid_log[0] == 0) && (arid_log[1] == 0),
              "line-fill bursts must use the same zero ID");
        check(max_read_outstanding == 2,
              "two ARs were not simultaneously outstanding");
        check(!rsp_valid,
              "logical response appeared before burst retirement");
        for (beat = 0; beat < 8; beat = beat + 1) begin
            send_r_beat(beat_value(beat * 4),
                        (beat == 3) || (beat == 7), 2'b00, 1'b0);
            if (beat != 7)
                check(!rsp_valid,
                      "logical response appeared before all bursts retired");
        end
        accept_response(word_value(0), 1'b0);
        check(full_beat_count == 8, "full-width beat event count mismatch");
        ar_before = ar_count;
        for (word_index = 1; word_index < 32;
             word_index = word_index + 1) begin
            issue_request(1'b0, 2'd2, word_index, 32'd0, 4'h0,
                          1'b1, 6'd1);
            accept_response(word_value(word_index), 1'b0);
        end
        check(ar_count == ar_before,
              "cached line generated an unexpected AXI request");
        check(linefill_start_count == 1,
              "line-fill start event count mismatch");
        check(linefill_hit_count == 31,
              "line-fill hit event count mismatch");

        // Unsafe/noncontiguous requests use one exact narrow read and extract
        // the AXI lane selected by address[3:2].
        $display("TEST 2: scalar narrow read");
        reset_dut();
        arready = 1'b1;
        issue_request(1'b0, 2'd2, 32'd33, 32'd0, 4'h0, 1'b0, 6'd32);
        wait_for_ar_count(1);
        check(araddr_log[0] == 40'h0010000084,
              "narrow read address mismatch");
        check((arlen_log[0] == 0) && (arsize_log[0] == 3'd2),
              "narrow read attributes mismatch");
        send_r_beat({32'h44444444, 32'h33333333,
                     32'h22222222, 32'h11111111},
                    1'b1, 2'b00, 1'b0);
        accept_response(32'h22222222, 1'b0);
        check((narrow_beat_count == 1) && (full_beat_count == 0),
              "narrow/full beat classification mismatch");

        // AW and W may handshake independently.  The single 32-bit write is
        // placed in lane three with matching WSTRB and completes only on B.
        $display("TEST 3: scalar narrow write");
        reset_dut();
        wready = 1'b1;
        awready = 1'b0;
        issue_request(1'b1, 2'd1, 32'd3, 32'hdeadbeef, 4'b1011,
                      1'b0, 6'd1);
        repeat (3) @(posedge clk);
        check((w_count == 1) && (aw_count == 0),
              "independent W-before-AW handshake failed");
        check(!rsp_valid, "write acknowledged before BRESP");
        @(negedge clk);
        awready = 1'b1;
        repeat (3) @(posedge clk);
        check(aw_count == 1, "AW did not handshake after AWREADY");
        check(awaddr_log == 40'h002700000c, "write address mismatch");
        check((awlen_log == 0) && (awsize_log == 3'd2),
              "narrow write attributes mismatch");
        check(wdata_log[127:96] == 32'hdeadbeef,
              "write data was not placed in lane three");
        check(wstrb_log == 16'hb000, "write strobe lane mismatch");
        check(wlast_log, "single-beat write must assert WLAST");
        send_b_response(2'b00, 1'b0);
        accept_response(32'd0, 1'b0);

        // A line starting at the final 16 bytes of a page is split/clamped:
        // one beat before the boundary and four after it.  No burst crosses
        // 4 KiB, and only the 20 safely fetched words become valid.
        $display("TEST 4: 4 KiB clamp");
        reset_dut();
        model_base = 64'h0000_0000_1000_0ff0;
        arready = 1'b1;
        issue_request(1'b0, 2'd2, 32'd0, 32'd0, 4'h0, 1'b1, 6'd32);
        wait_for_ar_count(2);
        check((araddr_log[0] == 40'h0010000ff0) &&
              (arlen_log[0] == 0), "pre-boundary burst mismatch");
        check((araddr_log[1] == 40'h0010001000) &&
              (arlen_log[1] == 3), "post-boundary burst mismatch");
        check(four_k_split_count == 1,
              "4 KiB split event was not emitted");
        for (beat = 0; beat < 5; beat = beat + 1)
            send_r_beat(beat_value(beat * 4),
                        (beat == 0) || (beat == 4), 2'b00, 1'b0);
        accept_response(word_value(0), 1'b0);
        ar_before = ar_count;
        issue_request(1'b0, 2'd2, 32'd19, 32'd0, 4'h0, 1'b0, 6'd1);
        accept_response(word_value(19), 1'b0);
        check(ar_count == ar_before,
              "last clamped line word did not hit cache");

        // Region tail clamps to one complete wide beat.  The remaining two
        // words use exact narrow reads and are never fetched past bounds.
        $display("TEST 5: logical region tail");
        reset_dut();
        model_words = 32'd6;
        arready = 1'b1;
        issue_request(1'b0, 2'd2, 32'd0, 32'd0, 4'h0, 1'b1, 6'd32);
        wait_for_ar_count(1);
        check((arlen_log[0] == 0) && (arsize_log[0] == 4),
              "tail line-fill clamp mismatch");
        send_r_beat(beat_value(0), 1'b1, 2'b00, 1'b0);
        accept_response(word_value(0), 1'b0);
        issue_request(1'b0, 2'd2, 32'd4, 32'd0, 4'h0, 1'b1, 6'd2);
        wait_for_ar_count(2);
        check((araddr_log[1] == 40'h0010000010) &&
              (arlen_log[1] == 0) && (arsize_log[1] == 2),
              "partial region tail must fall back to narrow read");
        send_r_beat({32'h0, 32'h0, 32'h0, word_value(4)},
                    1'b1, 2'b00, 1'b0);
        accept_response(word_value(4), 1'b0);

        // Logical response data/error remain stable under response-channel
        // backpressure, and no new request is accepted meanwhile.
        $display("TEST 6: logical response backpressure");
        reset_dut();
        arready = 1'b1;
        rsp_ready = 1'b0;
        issue_request(1'b0, 2'd2, 32'd0, 32'd0, 4'h0, 1'b0, 6'd1);
        wait_for_ar_count(1);
        send_r_beat({96'd0, 32'hcafef00d}, 1'b1, 2'b00, 1'b0);
        while (!rsp_valid) @(negedge clk);
        held_rsp_data = rsp_read_data;
        held_rsp_error = rsp_error;
        repeat (5) begin
            @(negedge clk);
            check(rsp_valid && (rsp_read_data == held_rsp_data) &&
                  (rsp_error == held_rsp_error),
                  "logical response changed under backpressure");
        end
        rsp_ready = 1'b1;
        accept_response(32'hcafef00d, 1'b0);

        // A non-OK RRESP with correct framing is reported but does not poison
        // transaction boundaries.
        $display("TEST 7: RRESP error");
        reset_dut();
        arready = 1'b1;
        issue_request(1'b0, 2'd2, 32'd0, 32'd0, 4'h0, 1'b0, 6'd1);
        wait_for_ar_count(1);
        send_r_beat(128'd0, 1'b1, 2'b10, 1'b0);
        accept_response(32'd0, 1'b1);
        check(r_protocol_error_count == 1,
              "RRESP error event count mismatch");
        check(req_ready, "correctly framed RRESP error poisoned adapter");

        // A response error inside a full-width fill is accumulated while the
        // remaining correctly framed beats are drained.  The bad line is not
        // published into the scalar cache.
        $display("TEST 8: line-fill RRESP error drain");
        reset_dut();
        arready = 1'b1;
        issue_request(1'b0, 2'd2, 32'd0, 32'd0, 4'h0, 1'b1, 6'd16);
        wait_for_ar_count(1);
        for (beat = 0; beat < 4; beat = beat + 1)
            send_r_beat(beat_value(beat * 4), (beat == 3),
                        (beat == 1) ? 2'b10 : 2'b00, 1'b0);
        accept_response(word_value(0), 1'b1);
        check(r_protocol_error_count == 1,
              "line-fill RRESP error event count mismatch");
        ar_before = ar_count;
        issue_request(1'b0, 2'd2, 32'd1, 32'd0, 4'h0, 1'b0, 6'd1);
        wait_for_ar_count(ar_before + 1);
        check(ar_count == ar_before + 1,
              "failed line fill was incorrectly published as cache-valid");
        send_r_beat({64'd0, word_value(1), 32'd0},
                    1'b1, 2'b00, 1'b0);
        accept_response(word_value(1), 1'b0);

        // BID/BRESP are both checked.  A completed malformed write response
        // reports an error and protocol event but leaves boundaries known.
        $display("TEST 9: BID/BRESP error");
        reset_dut();
        awready = 1'b1;
        wready = 1'b1;
        issue_request(1'b1, 2'd1, 32'd0, 32'h12345678, 4'hf,
                      1'b0, 6'd1);
        while ((aw_count == 0) || (w_count == 0)) @(negedge clk);
        send_b_response(2'b10, 1'b1);
        accept_response(32'd0, 1'b1);
        check(b_protocol_error_count == 1,
              "BID/BRESP protocol event count mismatch");
        check(req_ready, "completed bad BRESP unexpectedly poisoned adapter");

        // Explicit invalidation removes a completed line; the same word then
        // generates a new AXI request.
        $display("TEST 10: cache invalidation");
        reset_dut();
        arready = 1'b1;
        issue_request(1'b0, 2'd2, 32'd0, 32'd0, 4'h0, 1'b1, 6'd4);
        wait_for_ar_count(1);
        send_r_beat(beat_value(0), 1'b1, 2'b00, 1'b0);
        accept_response(word_value(0), 1'b0);
        @(negedge clk);
        cache_invalidate = 1'b1;
        @(posedge clk);
        @(negedge clk);
        cache_invalidate = 1'b0;
        ar_before = ar_count;
        issue_request(1'b0, 2'd2, 32'd1, 32'd0, 4'h0, 1'b0, 6'd1);
        wait_for_ar_count(ar_before + 1);
        check(ar_count == ar_before + 1,
              "cache invalidation failed to force a refill");
        send_r_beat({64'd0, word_value(1), 32'd0},
                    1'b1, 2'b00, 1'b0);
        accept_response(word_value(1), 1'b0);

        // Missing RLAST on the expected final beat is terminal framing loss.
        // The adapter returns one bounded error and then fail-closes until
        // reset; it never waits forever for a hypothetical extra beat.
        $display("TEST 11: missing RLAST poison");
        reset_dut();
        arready = 1'b1;
        issue_request(1'b0, 2'd2, 32'd0, 32'd0, 4'h0, 1'b1, 6'd16);
        wait_for_ar_count(1);
        for (beat = 0; beat < 4; beat = beat + 1)
            send_r_beat(beat_value(beat * 4), 1'b0, 2'b00, 1'b0);
        accept_response(32'd0, 1'b1);
        check(r_protocol_error_count == 1,
              "missing RLAST protocol event count mismatch");
        repeat (3) @(negedge clk);
        check(!req_ready && !rready,
              "missing RLAST did not leave adapter fail-closed");

        // Early RLAST and RID mismatch use the same bounded poison policy.
        $display("TEST 12: early RLAST poison");
        reset_dut();
        arready = 1'b1;
        issue_request(1'b0, 2'd2, 32'd0, 32'd0, 4'h0, 1'b1, 6'd16);
        wait_for_ar_count(1);
        send_r_beat(beat_value(0), 1'b1, 2'b00, 1'b0);
        accept_response(32'd0, 1'b1);
        check(!req_ready && !rready,
              "early RLAST did not leave adapter fail-closed");

        $display("TEST 13: RID mismatch poison");
        reset_dut();
        arready = 1'b1;
        issue_request(1'b0, 2'd2, 32'd0, 32'd0, 4'h0, 1'b0, 6'd1);
        wait_for_ar_count(1);
        send_r_beat(128'd0, 1'b1, 2'b00, 1'b1);
        accept_response(32'd0, 1'b1);
        check(!req_ready && !rready,
              "RID mismatch did not leave adapter fail-closed");

        // The final R beat may legally be presented in the same cycle that
        // the final AR handshakes in a zero-latency test slave.  Completion
        // must use the effective accepted count, not the stale register.
        $display("TEST 14: final AR and final R same-cycle race");
        reset_dut();
        rsp_ready = 1'b1;
        issue_request(1'b0, 2'd2, 32'd0, 32'd0, 4'h0, 1'b1, 6'd4);
        while (!arvalid || !rready) @(negedge clk);
        @(negedge clk);
        arready = 1'b1;
        rvalid = 1'b1;
        rdata = beat_value(0);
        rresp = 2'b00;
        rid = 1'b0;
        rlast = 1'b1;
        @(posedge clk);
        @(negedge clk);
        rvalid = 1'b0;
        rlast = 1'b0;
        rdata = 128'd0;
        accept_response(word_value(0), 1'b0);
        check((ar_count == 1) && (r_protocol_error_count == 0),
              "same-cycle final AR/R was falsely poisoned");
        check(req_ready, "same-cycle final AR/R did not return to service");

        // Duplicate and out-of-order cache hits mark an idempotent consumed
        // bitmap.  Of eight valid words, only indices 0, 5 and 2 are used, so
        // invalidation must report exactly five unique unused words.
        $display("TEST 15: unique unused-prefetch bitmap");
        reset_dut();
        arready = 1'b1;
        issue_request(1'b0, 2'd2, 32'd0, 32'd0, 4'h0, 1'b1, 6'd8);
        wait_for_ar_count(1);
        send_r_beat(beat_value(0), 1'b0, 2'b00, 1'b0);
        send_r_beat(beat_value(4), 1'b1, 2'b00, 1'b0);
        accept_response(word_value(0), 1'b0);
        issue_request(1'b0, 2'd2, 32'd5, 32'd0, 4'h0, 1'b0, 6'd1);
        accept_response(word_value(5), 1'b0);
        issue_request(1'b0, 2'd2, 32'd5, 32'd0, 4'h0, 1'b0, 6'd1);
        accept_response(word_value(5), 1'b0);
        issue_request(1'b0, 2'd2, 32'd2, 32'd0, 4'h0, 1'b0, 6'd1);
        accept_response(word_value(2), 1'b0);
        @(negedge clk);
        cache_invalidate = 1'b1;
        @(posedge clk);
        @(negedge clk);
        cache_invalidate = 1'b0;
        repeat (2) @(posedge clk);
        check((discard_event_count == 1) &&
              (last_discard_words == 5) && (discard_word_total == 5),
              "discard counter did not use unique consumed-word bitmap");

        // Fill the request FIFO behind a stalled scalar read.  A fourth
        // request is held while full, then accepted in the same cycle that
        // the engine dequeues the oldest entry.  With RSPREADY low, two
        // responses fill the response FIFO and block further issue.  Popping
        // responses restarts requests without changing response order.
        $display("TEST 16: depth-2 request/response FIFO ordering");
        reset_dut();
        rsp_ready = 1'b0;
        arready = 1'b0;
        issue_request(1'b0, 2'd2, 32'd0, 32'd0, 4'h0, 1'b0, 6'd1);
        while (!arvalid) @(negedge clk);
        issue_request(1'b0, 2'd2, 32'd1, 32'd0, 4'h0, 1'b0, 6'd1);
        issue_request(1'b0, 2'd2, 32'd2, 32'd0, 4'h0, 1'b0, 6'd1);
        check(dut.req_fifo_count == 2,
              "request FIFO did not reach depth two");
        @(negedge clk);
        req_write = 1'b0;
        req_space = 2'd2;
        req_word_address = 32'd3;
        req_write_data = 32'd0;
        req_write_strobe = 4'h0;
        req_read_ahead_safe = 1'b0;
        req_contiguous_words = 6'd1;
        req_valid = 1'b1;
        repeat (3) begin
            @(negedge clk);
            check(!req_ready,
                  "full request FIFO asserted ready without a dequeue");
        end
        arready = 1'b1;
        wait_for_ar_count(1);
        send_r_beat(narrow_beat_value(0, word_value(0)),
                    1'b1, 2'b00, 1'b0);
        fifo_timeout = 0;
        while (!req_ready && fifo_timeout < 100) begin
            @(negedge clk);
            fifo_timeout = fifo_timeout + 1;
        end
        check(req_ready,
              "full FIFO did not allow simultaneous dequeue/enqueue");
        @(posedge clk);
        @(negedge clk);
        req_valid = 1'b0;
        check(dut.req_fifo_count == 2,
              "simultaneous full-FIFO push/pop changed occupancy");
        model_base = 64'h0000_0000_1100_0000;
        wait_for_ar_count(2);
        check(araddr_log[1] == 40'h0010000004,
              "queued request did not preserve captured base/address");
        send_r_beat(narrow_beat_value(1, word_value(1)),
                    1'b1, 2'b00, 1'b0);
        fifo_timeout = 0;
        while ((dut.rsp_fifo_count != 2) && fifo_timeout < 100) begin
            @(negedge clk);
            fifo_timeout = fifo_timeout + 1;
        end
        check(dut.rsp_fifo_count == 2,
              "response FIFO did not reach depth two");
        repeat (3) @(posedge clk);
        check((ar_count == 2) && !req_ready,
              "full response FIFO did not backpressure request issue");
        pop_one_response(word_value(0), 1'b0);
        wait_for_ar_count(3);
        check(araddr_log[2] == 40'h0010000008,
              "third queued read address/order mismatch");
        send_r_beat(narrow_beat_value(2, word_value(2)),
                    1'b1, 2'b00, 1'b0);
        pop_one_response(word_value(1), 1'b0);
        wait_for_ar_count(4);
        check(araddr_log[3] == 40'h001000000c,
              "fourth same-cycle-enqueued read order mismatch");
        send_r_beat(narrow_beat_value(3, word_value(3)),
                    1'b1, 2'b00, 1'b0);
        pop_one_response(word_value(2), 1'b0);
        pop_one_response(word_value(3), 1'b0);
        check((dut.req_fifo_count == 0) &&
              (dut.rsp_fifo_count == 0),
              "logical FIFOs did not drain to empty");

        // An invalid local request, a write and a read are queued together.
        // Their response tokens must remain in request order even though the
        // operations complete through three different core paths.
        $display("TEST 17: mixed invalid/write/read FIFO ordering");
        reset_dut();
        rsp_ready = 1'b0;
        arready = 1'b1;
        awready = 1'b1;
        wready = 1'b1;
        issue_request(1'b0, 2'd0, 32'd0, 32'd0, 4'h0, 1'b0, 6'd1);
        issue_request(1'b1, 2'd1, 32'd0, 32'h13579bdf, 4'hf,
                      1'b0, 6'd1);
        issue_request(1'b0, 2'd2, 32'd4, 32'd0, 4'h0, 1'b0, 6'd1);
        fifo_timeout = 0;
        while (((aw_count == 0) || (w_count == 0)) &&
               fifo_timeout < 100) begin
            @(negedge clk);
            fifo_timeout = fifo_timeout + 1;
        end
        check((aw_count == 1) && (w_count == 1),
              "queued write did not issue after invalid request");
        send_b_response(2'b00, 1'b0);
        fifo_timeout = 0;
        while ((dut.rsp_fifo_count != 2) && fifo_timeout < 100) begin
            @(negedge clk);
            fifo_timeout = fifo_timeout + 1;
        end
        check(dut.rsp_fifo_count == 2,
              "mixed-path responses did not fill response FIFO");
        pop_one_response(32'd0, 1'b1);
        wait_for_ar_count(1);
        send_r_beat(narrow_beat_value(4, word_value(4)),
                    1'b1, 2'b00, 1'b0);
        pop_one_response(32'd0, 1'b0);
        pop_one_response(word_value(4), 1'b0);

        // Preserve an older normal response, fault the active read, and keep
        // two more accepted requests queued.  Poison appends the active error
        // and one error token per queued request without issuing new AXI.
        $display("TEST 18: poison flush preserves accepted-request order");
        reset_dut();
        rsp_ready = 1'b0;
        arready = 1'b1;
        issue_request(1'b0, 2'd2, 32'd0, 32'd0, 4'h0, 1'b0, 6'd1);
        wait_for_ar_count(1);
        send_r_beat(narrow_beat_value(0, word_value(0)),
                    1'b1, 2'b00, 1'b0);
        fifo_timeout = 0;
        while ((dut.rsp_fifo_count != 1) && fifo_timeout < 100) begin
            @(negedge clk);
            fifo_timeout = fifo_timeout + 1;
        end
        check(dut.rsp_fifo_count == 1,
              "older normal response was not queued");
        issue_request(1'b0, 2'd2, 32'd1, 32'd0, 4'h0, 1'b0, 6'd1);
        wait_for_ar_count(2);
        issue_request(1'b0, 2'd0, 32'd0, 32'd0, 4'h0, 1'b0, 6'd1);
        issue_request(1'b0, 2'd2, 32'd2, 32'd0, 4'h0, 1'b0, 6'd1);
        check(dut.req_fifo_count == 2,
              "pre-poison accepted-request queue depth mismatch");
        send_r_beat(128'd0, 1'b1, 2'b00, 1'b1);
        fifo_timeout = 0;
        while ((dut.rsp_fifo_count != 2) && fifo_timeout < 100) begin
            @(negedge clk);
            fifo_timeout = fifo_timeout + 1;
        end
        check(dut.rsp_fifo_count == 2,
              "active poison response was not ordered after old response");
        check(!req_ready && !rready,
              "poison did not stop new logical/AXI acceptance");
        pop_one_response(word_value(0), 1'b0);
        pop_one_response(32'd0, 1'b1);
        pop_one_response(32'd0, 1'b1);
        pop_one_response(32'd0, 1'b1);
        repeat (3) @(posedge clk);
        check((ar_count == 2) && (dut.req_fifo_count == 0) &&
              (dut.rsp_fifo_count == 0) && !req_ready,
              "poison flush lost, duplicated or issued queued requests");

        // Reset is the only recovery from poison and also atomically flushes
        // partial/full logical FIFOs.  Build two local error responses plus a
        // queued third request, then reset without delivering any response.
        $display("TEST 19: reset flushes partial/full logical FIFOs");
        reset_dut();
        rsp_ready = 1'b0;
        issue_request(1'b0, 2'd0, 32'd0, 32'd0, 4'h0, 1'b0, 6'd1);
        issue_request(1'b0, 2'd0, 32'd1, 32'd0, 4'h0, 1'b0, 6'd1);
        issue_request(1'b0, 2'd0, 32'd2, 32'd0, 4'h0, 1'b0, 6'd1);
        fifo_timeout = 0;
        while (((dut.rsp_fifo_count != 2) ||
                (dut.req_fifo_count == 0)) && fifo_timeout < 100) begin
            @(negedge clk);
            fifo_timeout = fifo_timeout + 1;
        end
        check((dut.rsp_fifo_count == 2) &&
              (dut.req_fifo_count == 1),
              "reset precondition did not contain full RSP and queued REQ");
        reset_dut();
        check((dut.req_fifo_count == 0) &&
              (dut.rsp_fifo_count == 0) && !rsp_valid && req_ready,
              "reset did not atomically clear logical FIFOs");
        check(!arvalid && !awvalid && !wvalid && !rready && !bready,
              "reset left an AXI transaction active");

        // With both FIFOs empty, a request handshake must drive the core FSM
        // immediately and a ready response must fall through without first
        // occupying the stored response FIFO.  These two assertions prevent
        // reintroducing one shell cycle at either side of every logical AXI
        // operation.
        $display("TEST 20: empty-FIFO fall-through latency");
        reset_dut();
        rsp_ready = 1'b1;
        arready = 1'b0;
        issue_request(1'b0, 2'd2, 32'd3, 32'd0, 4'h0, 1'b0, 6'd1);
        check((dut.req_fifo_count == 0) && arvalid,
              "empty request FIFO did not fall through to AR state");
        arready = 1'b1;
        wait_for_ar_count(1);
        send_r_beat(narrow_beat_value(3, word_value(3)),
                    1'b1, 2'b00, 1'b0);
        check(rsp_valid && (rsp_read_data == word_value(3)) &&
              !rsp_error && (dut.rsp_fifo_count == 0),
              "ready response did not fall through the empty FIFO");
        @(posedge clk);
        @(negedge clk);
        check(!rsp_valid && req_ready,
              "fall-through response did not retire in one cycle");

        $display("PASS native AXI128 adapter: checks=%0d", checks);
        $finish;
    end

    initial begin
        #500000;
        $fatal(1, "FAIL global simulation timeout");
    end

endmodule
