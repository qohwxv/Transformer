`timescale 1ns/1ps

module tb_vit_axi_read_linefill_experimental;

    localparam integer AXI_ADDR_WIDTH = 40;
    localparam integer AXI_ID_WIDTH = 2;
    localparam integer MAX_BURST_BEATS = 16;

    localparam logic [1:0] MEM_NONE    = 2'd0;
    localparam logic [1:0] MEM_SCRATCH = 2'd1;
    localparam logic [1:0] MEM_MODEL   = 2'd2;
    localparam logic [1:0] MEM_INPUT   = 2'd3;

    localparam logic [63:0] MODEL_BASE_INIT =
        64'h0000_0001_0000_1000;
    // Deliberately 16 bytes before a 4 KiB boundary.
    localparam logic [63:0] INPUT_BASE_INIT =
        64'h0000_0002_0000_0ff0;
    localparam logic [63:0] SCRATCH_BASE_INIT =
        64'h0000_0003_0000_2000;

    localparam logic [31:0] MODEL_WORDS_INIT = 32'd40;
    localparam logic [31:0] INPUT_WORDS_INIT = 32'd32;
    localparam logic [31:0] SCRATCH_WORDS_INIT = 32'd64;

    localparam logic [2:0] FAULT_NONE       = 3'd0;
    localparam logic [2:0] FAULT_RRESP      = 3'd1;
    localparam logic [2:0] FAULT_RID        = 3'd2;
    localparam logic [2:0] FAULT_EARLY_LAST = 3'd3;
    localparam logic [2:0] FAULT_LATE_LAST  = 3'd4;

    logic aclk;
    logic aresetn;

    logic [63:0] scratch_base;
    logic [63:0] model_base;
    logic [63:0] input_base;
    logic [31:0] scratch_words;
    logic [31:0] model_words;
    logic [31:0] input_words;

    logic cache_invalidate;
    logic cache_valid;

    logic req_valid;
    logic req_ready;
    logic req_read_ahead;
    logic [1:0] req_space;
    logic [31:0] req_word_address;

    logic rsp_valid;
    logic rsp_ready;
    logic [31:0] rsp_read_data;
    logic rsp_error;

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
    logic [31:0] m_axi_rdata;
    logic [1:0] m_axi_rresp;
    logic m_axi_rlast;
    logic m_axi_rvalid;
    logic m_axi_rready;

    logic [2:0] fault_mode;
    logic [2:0] fault_mode_hold;
    logic stall_enable;
    logic slave_read_active;
    logic [AXI_ADDR_WIDTH-1:0] slave_araddr_hold;
    logic [7:0] slave_arlen_hold;
    logic [8:0] slave_beat_index;
    logic [31:0] cycle_count;

    integer checks;
    integer ar_transactions;
    integer total_r_beats;
    integer burst_end_offset;
    logic [AXI_ADDR_WIDTH-1:0] last_araddr;
    logic [7:0] last_arlen;

    vit_axi_read_linefill_experimental #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_BEATS(MAX_BURST_BEATS)
    ) dut (
        .aclk(aclk),
        .aresetn(aresetn),
        .scratch_base_i(scratch_base),
        .model_base_i(model_base),
        .input_base_i(input_base),
        .scratch_words_i(scratch_words),
        .model_words_i(model_words),
        .input_words_i(input_words),
        .cache_invalidate_i(cache_invalidate),
        .cache_valid_o(cache_valid),
        .req_valid(req_valid),
        .req_ready(req_ready),
        .req_read_ahead_i(req_read_ahead),
        .req_space(req_space),
        .req_word_address(req_word_address),
        .rsp_valid(rsp_valid),
        .rsp_ready(rsp_ready),
        .rsp_read_data(rsp_read_data),
        .rsp_error(rsp_error),
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

    initial begin
        aclk = 1'b0;
        forever #5 aclk = ~aclk;
    end

    function automatic logic [31:0] memory_pattern(
        input logic [AXI_ADDR_WIDTH-1:0] byte_address
    );
        begin
            memory_pattern =
                32'hc001_0000 ^
                (byte_address >> 2);
        end
    endfunction

    always @* begin
        m_axi_arready =
            !slave_read_active &&
            (!stall_enable || (cycle_count[1:0] != 2'b00));

        m_axi_rvalid =
            slave_read_active &&
            (!stall_enable || (cycle_count[1:0] != 2'b10));
        m_axi_rdata = memory_pattern(
            slave_araddr_hold +
            ({{(AXI_ADDR_WIDTH-9){1'b0}}, slave_beat_index} << 2)
        );
        m_axi_rresp =
            ((fault_mode_hold == FAULT_RRESP) &&
             (slave_beat_index == 9'd0)) ?
            2'b10 : 2'b00;
        m_axi_rid =
            ((fault_mode_hold == FAULT_RID) &&
             (slave_beat_index == 9'd0)) ?
            {{(AXI_ID_WIDTH-1){1'b0}}, 1'b1} :
            {AXI_ID_WIDTH{1'b0}};

        case (fault_mode_hold)
            FAULT_EARLY_LAST:
                m_axi_rlast = (slave_beat_index == 9'd0);
            FAULT_LATE_LAST:
                m_axi_rlast =
                    (slave_beat_index ==
                     ({1'b0, slave_arlen_hold} + 9'd1));
            default:
                m_axi_rlast =
                    (slave_beat_index ==
                     {1'b0, slave_arlen_hold});
        endcase
    end

    always @(posedge aclk) begin
        if (!aresetn) begin
            slave_read_active <= 1'b0;
            slave_araddr_hold <= '0;
            slave_arlen_hold <= 8'b0;
            slave_beat_index <= 9'b0;
            fault_mode_hold <= FAULT_NONE;
            cycle_count <= 32'b0;
            ar_transactions <= 0;
            total_r_beats <= 0;
            last_araddr <= '0;
            last_arlen <= 8'b0;
        end else begin
            cycle_count <= cycle_count + 32'd1;

            if (m_axi_arvalid && m_axi_arready) begin
                if (m_axi_arid != {AXI_ID_WIDTH{1'b0}})
                    $fatal(1, "ARID must be zero");
                if (m_axi_arsize != 3'b010)
                    $fatal(1, "ARSIZE must describe four-byte beats");
                if (m_axi_arburst != 2'b01)
                    $fatal(1, "ARBURST must be INCR");
                if (m_axi_arlock)
                    $fatal(1, "ARLOCK must be deasserted");
                if (m_axi_araddr[1:0] != 2'b00)
                    $fatal(1, "ARADDR is not word aligned");
                if ((m_axi_arlen + 9'd1) > MAX_BURST_BEATS)
                    $fatal(1, "burst exceeds MAX_BURST_BEATS");

                burst_end_offset =
                    m_axi_araddr[11:0] +
                    ((m_axi_arlen + 1) * 4);
                if (burst_end_offset > 4096)
                    $fatal(1, "burst crosses a 4 KiB boundary");

                slave_read_active <= 1'b1;
                slave_araddr_hold <= m_axi_araddr;
                slave_arlen_hold <= m_axi_arlen;
                slave_beat_index <= 9'b0;
                fault_mode_hold <= fault_mode;
                ar_transactions <= ar_transactions + 1;
                last_araddr <= m_axi_araddr;
                last_arlen <= m_axi_arlen;
            end

            if (m_axi_rvalid && m_axi_rready) begin
                total_r_beats <= total_r_beats + 1;
                if (m_axi_rlast) begin
                    slave_read_active <= 1'b0;
                    slave_beat_index <= 9'b0;
                end else begin
                    slave_beat_index <= slave_beat_index + 9'd1;
                end
            end
        end
    end

    task automatic check(
        input logic condition,
        input string message
    );
        begin
            checks = checks + 1;
            if (!condition)
                $fatal(1, "CHECK FAILED: %s", message);
        end
    endtask

    task automatic pulse_invalidate;
        begin
            @(negedge aclk);
            cache_invalidate = 1'b1;
            @(negedge aclk);
            cache_invalidate = 1'b0;
        end
    endtask

    task automatic logical_read(
        input logic [1:0] space,
        input logic [31:0] word_address,
        input logic expected_error,
        input logic [31:0] expected_data
    );
        integer timeout_cycles;
        begin
            @(negedge aclk);
            req_space = space;
            req_word_address = word_address;
            req_valid = 1'b1;

            timeout_cycles = 0;
            do begin
                @(posedge aclk);
                timeout_cycles = timeout_cycles + 1;
                if (timeout_cycles > 100)
                    $fatal(1, "request handshake timeout");
            end while (!req_ready);

            @(negedge aclk);
            req_valid = 1'b0;

            timeout_cycles = 0;
            while (!rsp_valid) begin
                @(negedge aclk);
                timeout_cycles = timeout_cycles + 1;
                if (timeout_cycles > 1000)
                    $fatal(1, "response timeout");
            end

            check(rsp_error == expected_error,
                  "response error flag mismatch");
            if (!expected_error)
                check(rsp_read_data == expected_data,
                      "response data mismatch");

            // Allow the registered response handshake to return to IDLE.
            @(negedge aclk);
        end
    endtask

    task automatic logical_read_with_response_stall(
        input logic [1:0] space,
        input logic [31:0] word_address,
        input logic [31:0] expected_data
    );
        integer timeout_cycles;
        integer hold_cycle;
        begin
            @(negedge aclk);
            rsp_ready = 1'b0;
            req_space = space;
            req_word_address = word_address;
            req_valid = 1'b1;

            timeout_cycles = 0;
            do begin
                @(posedge aclk);
                timeout_cycles = timeout_cycles + 1;
                if (timeout_cycles > 100)
                    $fatal(1, "stalled request handshake timeout");
            end while (!req_ready);

            @(negedge aclk);
            req_valid = 1'b0;

            timeout_cycles = 0;
            while (!rsp_valid) begin
                @(negedge aclk);
                timeout_cycles = timeout_cycles + 1;
                if (timeout_cycles > 1000)
                    $fatal(1, "stalled response timeout");
            end

            check(!rsp_error, "stalled hit reported an error");
            check(rsp_read_data == expected_data,
                  "stalled hit data mismatch");
            for (hold_cycle = 0; hold_cycle < 3;
                 hold_cycle = hold_cycle + 1) begin
                @(negedge aclk);
                check(rsp_valid, "RSPVALID dropped under backpressure");
                check(!rsp_error,
                      "RSP error changed under backpressure");
                check(rsp_read_data == expected_data,
                      "RSP data changed under backpressure");
            end

            rsp_ready = 1'b1;
            @(negedge aclk);
        end
    endtask

    task automatic logical_read_with_concurrent_invalidate(
        input logic [1:0] space,
        input logic [31:0] word_address,
        input logic [31:0] expected_data
    );
        integer timeout_cycles;
        begin
            @(negedge aclk);
            cache_invalidate = 1'b1;
            req_space = space;
            req_word_address = word_address;
            req_valid = 1'b1;

            timeout_cycles = 0;
            do begin
                @(posedge aclk);
                timeout_cycles = timeout_cycles + 1;
                if (timeout_cycles > 100)
                    $fatal(1, "invalidate/request handshake timeout");
            end while (!req_ready);

            @(negedge aclk);
            cache_invalidate = 1'b0;
            req_valid = 1'b0;

            timeout_cycles = 0;
            while (!rsp_valid) begin
                @(negedge aclk);
                timeout_cycles = timeout_cycles + 1;
                if (timeout_cycles > 1000)
                    $fatal(1, "invalidate/request response timeout");
            end

            check(!rsp_error,
                  "new miss concurrent with idle invalidate failed");
            check(rsp_read_data == expected_data,
                  "concurrent invalidate/new miss data mismatch");
            @(negedge aclk);
        end
    endtask

    function automatic logic [AXI_ADDR_WIDTH-1:0] physical_address(
        input logic [63:0] base_address,
        input logic [31:0] word_address
    );
        logic [64:0] result;
        begin
            result =
                {1'b0, base_address} +
                ({33'b0, word_address} << 2);
            physical_address = result[AXI_ADDR_WIDTH-1:0];
        end
    endfunction

    initial begin
        checks = 0;
        aresetn = 1'b0;
        scratch_base = SCRATCH_BASE_INIT;
        model_base = MODEL_BASE_INIT;
        input_base = INPUT_BASE_INIT;
        scratch_words = SCRATCH_WORDS_INIT;
        model_words = MODEL_WORDS_INIT;
        input_words = INPUT_WORDS_INIT;
        cache_invalidate = 1'b0;
        req_valid = 1'b0;
        req_read_ahead = 1'b1;
        req_space = MEM_NONE;
        req_word_address = 32'b0;
        rsp_ready = 1'b1;
        fault_mode = FAULT_NONE;
        stall_enable = 1'b1;

        repeat (5) @(posedge aclk);
        @(negedge aclk);
        aresetn = 1'b1;

        // A 16-beat miss followed by hits within words [5, 20].
        logical_read(
            MEM_MODEL,
            32'd5,
            1'b0,
            memory_pattern(physical_address(MODEL_BASE_INIT, 32'd5))
        );
        check(ar_transactions == 1, "first miss did not issue one AR");
        check(last_araddr ==
              physical_address(MODEL_BASE_INIT, 32'd5),
              "first miss ARADDR mismatch");
        check(last_arlen == 8'd15, "first miss was not 16 beats");
        check(cache_valid, "successful fill did not validate cache");

        logical_read_with_response_stall(
            MEM_MODEL,
            32'd6,
            memory_pattern(physical_address(MODEL_BASE_INIT, 32'd6))
        );
        logical_read(
            MEM_MODEL,
            32'd20,
            1'b0,
            memory_pattern(physical_address(MODEL_BASE_INIT, 32'd20))
        );
        check(ar_transactions == 1, "line hits issued extra AR");

        // The next word misses; the final region word clamps to one beat.
        logical_read(
            MEM_MODEL,
            32'd21,
            1'b0,
            memory_pattern(physical_address(MODEL_BASE_INIT, 32'd21))
        );
        check(ar_transactions == 2, "next-line miss did not issue AR");
        check(last_arlen == 8'd15, "second line length mismatch");

        logical_read(
            MEM_MODEL,
            32'd39,
            1'b0,
            memory_pattern(physical_address(MODEL_BASE_INIT, 32'd39))
        );
        check(last_arlen == 8'd0, "region-end burst was not clamped");

        // INPUT starts at 0xff0, so only four words fit before 4 KiB.
        logical_read(
            MEM_INPUT,
            32'd0,
            1'b0,
            memory_pattern(physical_address(INPUT_BASE_INIT, 32'd0))
        );
        check(last_araddr[11:0] == 12'hff0,
              "boundary test did not start at 0xff0");
        check(last_arlen == 8'd3,
              "4 KiB boundary did not clamp burst to four beats");
        begin : check_boundary_line_hit
            integer ar_before;
            ar_before = ar_transactions;
            logical_read(
                MEM_INPUT,
                32'd3,
                1'b0,
                memory_pattern(physical_address(INPUT_BASE_INIT, 32'd3))
            );
            check(ar_transactions == ar_before,
                  "boundary-line hit issued AR");
        end

        logical_read(
            MEM_INPUT,
            32'd4,
            1'b0,
            memory_pattern(physical_address(INPUT_BASE_INIT, 32'd4))
        );
        check(last_araddr[11:0] == 12'h000,
              "post-boundary fill did not start on next page");
        check(last_arlen == 8'd15,
              "post-boundary fill did not recover full length");

        // A gather/unknown stream can explicitly disable speculative reads.
        pulse_invalidate();
        req_read_ahead = 1'b0;
        logical_read(
            MEM_MODEL,
            32'd0,
            1'b0,
            memory_pattern(physical_address(MODEL_BASE_INIT, 32'd0))
        );
        check(last_arlen == 8'd0,
              "read-ahead-disabled request was not scalar");
        begin : check_scalar_next_word_misses
            integer ar_before;
            ar_before = ar_transactions;
            logical_read(
                MEM_MODEL,
                32'd1,
                1'b0,
                memory_pattern(
                    physical_address(MODEL_BASE_INIT, 32'd1)
                )
            );
            check(ar_transactions == (ar_before + 1),
                  "scalar line unexpectedly covered next word");
            check(last_arlen == 8'd0,
                  "second read-ahead-disabled request was not scalar");
        end
        req_read_ahead = 1'b1;

        // A scratch fill can be reused until a write-alias invalidation pulse.
        logical_read(
            MEM_SCRATCH,
            32'd2,
            1'b0,
            memory_pattern(physical_address(SCRATCH_BASE_INIT, 32'd2))
        );
        begin : check_scratch_line_hit
            integer ar_before;
            ar_before = ar_transactions;
            logical_read(
                MEM_SCRATCH,
                32'd3,
                1'b0,
                memory_pattern(
                    physical_address(SCRATCH_BASE_INIT, 32'd3)
                )
            );
            check(ar_transactions == ar_before,
                  "scratch line hit issued AR");
        end
        check(cache_valid, "scratch line should be valid before write");
        pulse_invalidate();
        check(!cache_valid, "scratch write-alias pulse did not invalidate");
        begin : check_refill_after_invalidate
            integer ar_before;
            ar_before = ar_transactions;
            logical_read(
                MEM_SCRATCH,
                32'd3,
                1'b0,
                memory_pattern(
                    physical_address(SCRATCH_BASE_INIT, 32'd3)
                )
            );
            check(ar_transactions == (ar_before + 1),
                  "invalidated scratch word did not refill");
        end

        // When idle, invalidate applies to the old line. A new request accepted
        // on that same edge starts a fresh fill on the following cycle.
        begin : check_simultaneous_invalidate_and_request
            integer ar_before;
            ar_before = ar_transactions;
            logical_read_with_concurrent_invalidate(
                MEM_SCRATCH,
                32'd4,
                memory_pattern(
                    physical_address(SCRATCH_BASE_INIT, 32'd4)
                )
            );
            check(ar_transactions == (ar_before + 1),
                  "simultaneous invalidate/request reused old line");
            check(cache_valid,
                  "fresh fill after idle invalidate was discarded");
        end

        // Invalid logical requests are rejected locally without AXI traffic.
        begin : check_local_errors
            integer ar_before;
            ar_before = ar_transactions;
            logical_read(MEM_SCRATCH, 32'd64, 1'b1, 32'b0);
            logical_read(MEM_NONE, 32'd0, 1'b1, 32'b0);
            check(ar_transactions == ar_before,
                  "invalid logical request reached AXI");
        end

        // Every AXI read protocol fault must report an error and must not
        // leave a reusable line behind.
        pulse_invalidate();
        fault_mode = FAULT_RRESP;
        logical_read(MEM_SCRATCH, 32'd10, 1'b1, 32'b0);
        check(!cache_valid, "RRESP fault left cache valid");

        fault_mode = FAULT_NONE;
        begin : check_refill_after_rresp
            integer ar_before;
            ar_before = ar_transactions;
            logical_read(
                MEM_SCRATCH,
                32'd10,
                1'b0,
                memory_pattern(
                    physical_address(SCRATCH_BASE_INIT, 32'd10)
                )
            );
            check(ar_transactions == (ar_before + 1),
                  "RRESP-failed line was reused");
        end

        pulse_invalidate();
        fault_mode = FAULT_RID;
        logical_read(MEM_SCRATCH, 32'd20, 1'b1, 32'b0);
        check(!cache_valid, "RID fault left cache valid");

        pulse_invalidate();
        fault_mode = FAULT_EARLY_LAST;
        logical_read(MEM_SCRATCH, 32'd30, 1'b1, 32'b0);
        check(!cache_valid, "early RLAST left cache valid");

        pulse_invalidate();
        fault_mode = FAULT_LATE_LAST;
        logical_read(MEM_SCRATCH, 32'd40, 1'b1, 32'b0);
        check(!cache_valid, "late RLAST left cache valid");

        fault_mode = FAULT_NONE;
        logical_read(
            MEM_SCRATCH,
            32'd40,
            1'b0,
            memory_pattern(physical_address(SCRATCH_BASE_INIT, 32'd40))
        );

        $display(
            "PASS experimental AXI read line fill: checks=%0d AR=%0d R=%0d",
            checks,
            ar_transactions,
            total_r_beats
        );
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "global timeout");
    end

endmodule
