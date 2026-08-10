`timescale 1ns/1ps

module tb_vit_axi_ddr_model_128;

    localparam integer AXI_ADDR_WIDTH = 40;
    localparam integer AXI_ID_WIDTH = 1;
    localparam integer MODEL_WORDS = 2048;
    localparam integer INPUT_WORDS = 256;
    localparam integer SCRATCH_WORDS = 2048;
    localparam integer MAX_BURST_BEATS = 4;

    localparam logic [63:0] MODEL_BASE = 64'h0000_0001_0000_1000;
    localparam logic [63:0] INPUT_BASE = 64'h0000_0002_0000_0000;
    localparam logic [63:0] SCRATCH_BASE = 64'h0000_0003_0000_2000;

    logic aclk;
    logic aresetn;

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
    logic [AXI_ID_WIDTH-1:0] fault_rresp_id;
    logic [7:0] fault_rresp_beat;
    logic [1:0] fault_rresp_value;
    logic fault_rid_enable;
    logic [AXI_ID_WIDTH-1:0] fault_rid_value;
    logic [1:0] fault_rlast_mode;
    logic fault_bresp_enable;
    logic [AXI_ID_WIDTH-1:0] fault_bresp_id;
    logic [1:0] fault_bresp_value;
    logic fault_bid_enable;
    logic [AXI_ID_WIDTH-1:0] fault_bid_value;

    logic [63:0] read_count;
    logic [63:0] write_count;
    logic [63:0] model_read_count;
    logic [63:0] input_read_count;
    logic [63:0] scratch_read_count;
    logic [63:0] scratch_write_count;
    logic [63:0] ar_transaction_count;
    logic [63:0] aw_transaction_count;
    logic [63:0] r_beat_count;
    logic [63:0] w_beat_count;
    logic [63:0] b_response_count;
    logic [63:0] ar_requested_beat_count;
    logic [63:0] aw_requested_beat_count;
    logic [63:0] ar_backpressure_cycles;
    logic [63:0] aw_backpressure_cycles;
    logic [63:0] w_backpressure_cycles;
    logic [63:0] r_backpressure_cycles;
    logic [63:0] b_backpressure_cycles;
    logic [31:0] invalid_access_count;
    logic [31:0] protocol_error_count;
    logic [31:0] four_kib_error_count;
    logic [31:0] read_outstanding_count;
    logic [31:0] write_outstanding_count;
    logic [31:0] read_outstanding_high_water;
    logic [31:0] write_outstanding_high_water;

    logic [31:0] scratch_expected [0:SCRATCH_WORDS-1];

    integer checks;
    integer seed;
    integer initial_seed;
    integer random_iterations;
    integer expected_ar_transactions;
    integer expected_aw_transactions;
    integer expected_r_beats;
    integer expected_w_beats;
    integer expected_b_responses;
    integer expected_requested_r_beats;
    integer expected_requested_w_beats;
    integer expected_valid_read_words;
    integer expected_valid_write_words;
    integer expected_invalid_accesses;
    integer expected_protocol_errors;
    integer expected_four_kib_errors;

    integer init_index;
    integer iteration;
    integer lane;
    integer length_value;
    integer word_offset;
    integer random_value;
    logic [63:0] random_address_a;
    logic [63:0] random_address_b;
    logic [2:0] random_size_a;
    logic [2:0] random_size_b;
    logic [31:0] random_write_value;
    logic [3:0] random_byte_strobe;
    logic [127:0] random_write_bus_data;
    logic [15:0] random_write_bus_strobe;

    logic r_hold_active;
    logic [AXI_ID_WIDTH-1:0] r_hold_id;
    logic [127:0] r_hold_data;
    logic [1:0] r_hold_resp;
    logic r_hold_last;
    logic b_hold_active;
    logic [AXI_ID_WIDTH-1:0] b_hold_id;
    logic [1:0] b_hold_resp;

    vit_axi_ddr_model_128 #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MODEL_WORDS(MODEL_WORDS),
        .INPUT_WORDS(INPUT_WORDS),
        .SCRATCH_WORDS(SCRATCH_WORDS),
        .MODEL_BASE(MODEL_BASE),
        .INPUT_BASE(INPUT_BASE),
        .SCRATCH_BASE(SCRATCH_BASE),
        .MAX_BURST_BEATS(MAX_BURST_BEATS),
        .READ_QUEUE_DEPTH(4),
        .WRITE_QUEUE_DEPTH(4),
        .W_QUEUE_DEPTH(8),
        .STALL_ENABLE(1'b1)
    ) dut (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axi_awid(awid),
        .s_axi_awaddr(awaddr),
        .s_axi_awlen(awlen),
        .s_axi_awsize(awsize),
        .s_axi_awburst(awburst),
        .s_axi_awlock(awlock),
        .s_axi_awcache(awcache),
        .s_axi_awprot(awprot),
        .s_axi_awqos(awqos),
        .s_axi_awvalid(awvalid),
        .s_axi_awready(awready),
        .s_axi_wdata(wdata),
        .s_axi_wstrb(wstrb),
        .s_axi_wlast(wlast),
        .s_axi_wvalid(wvalid),
        .s_axi_wready(wready),
        .s_axi_bid(bid),
        .s_axi_bresp(bresp),
        .s_axi_bvalid(bvalid),
        .s_axi_bready(bready),
        .s_axi_arid(arid),
        .s_axi_araddr(araddr),
        .s_axi_arlen(arlen),
        .s_axi_arsize(arsize),
        .s_axi_arburst(arburst),
        .s_axi_arlock(arlock),
        .s_axi_arcache(arcache),
        .s_axi_arprot(arprot),
        .s_axi_arqos(arqos),
        .s_axi_arvalid(arvalid),
        .s_axi_arready(arready),
        .s_axi_rid(rid),
        .s_axi_rdata(rdata),
        .s_axi_rresp(rresp),
        .s_axi_rlast(rlast),
        .s_axi_rvalid(rvalid),
        .s_axi_rready(rready),
        .fault_rresp_enable_i(fault_rresp_enable),
        .fault_rresp_id_i(fault_rresp_id),
        .fault_rresp_beat_i(fault_rresp_beat),
        .fault_rresp_value_i(fault_rresp_value),
        .fault_rid_enable_i(fault_rid_enable),
        .fault_rid_value_i(fault_rid_value),
        .fault_rlast_mode_i(fault_rlast_mode),
        .fault_bresp_enable_i(fault_bresp_enable),
        .fault_bresp_id_i(fault_bresp_id),
        .fault_bresp_value_i(fault_bresp_value),
        .fault_bid_enable_i(fault_bid_enable),
        .fault_bid_value_i(fault_bid_value),
        .read_count_o(read_count),
        .write_count_o(write_count),
        .model_read_count_o(model_read_count),
        .input_read_count_o(input_read_count),
        .scratch_read_count_o(scratch_read_count),
        .scratch_write_count_o(scratch_write_count),
        .ar_transaction_count_o(ar_transaction_count),
        .aw_transaction_count_o(aw_transaction_count),
        .r_beat_count_o(r_beat_count),
        .w_beat_count_o(w_beat_count),
        .b_response_count_o(b_response_count),
        .ar_requested_beat_count_o(ar_requested_beat_count),
        .aw_requested_beat_count_o(aw_requested_beat_count),
        .ar_backpressure_cycle_count_o(ar_backpressure_cycles),
        .aw_backpressure_cycle_count_o(aw_backpressure_cycles),
        .w_backpressure_cycle_count_o(w_backpressure_cycles),
        .r_backpressure_cycle_count_o(r_backpressure_cycles),
        .b_backpressure_cycle_count_o(b_backpressure_cycles),
        .invalid_access_count_o(invalid_access_count),
        .protocol_error_count_o(protocol_error_count),
        .four_kib_error_count_o(four_kib_error_count),
        .read_outstanding_count_o(read_outstanding_count),
        .write_outstanding_count_o(write_outstanding_count),
        .read_outstanding_high_water_o(read_outstanding_high_water),
        .write_outstanding_high_water_o(write_outstanding_high_water)
    );

    initial begin
        aclk = 1'b0;
        forever #5 aclk = ~aclk;
    end

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (!condition)
                $fatal(1, "CHECK FAILED: %s", message);
        end
    endtask

    function automatic logic [31:0] model_pattern(input integer index);
        model_pattern = 32'h1100_0000 ^ index;
    endfunction

    function automatic logic [31:0] input_pattern(input integer index);
        input_pattern = 32'h2200_0000 ^ (index * 32'd3);
    endfunction

    function automatic logic [7:0] expected_byte(
        input logic [63:0] address
    );
        integer index;
        logic [31:0] word_value;
        begin
            word_value = 32'b0;
            if ((address >= MODEL_BASE) &&
                (address < MODEL_BASE + MODEL_WORDS*4)) begin
                index = (address - MODEL_BASE) >> 2;
                word_value = model_pattern(index);
            end else if ((address >= INPUT_BASE) &&
                         (address < INPUT_BASE + INPUT_WORDS*4)) begin
                index = (address - INPUT_BASE) >> 2;
                word_value = input_pattern(index);
            end else if ((address >= SCRATCH_BASE) &&
                         (address < SCRATCH_BASE + SCRATCH_WORDS*4)) begin
                index = (address - SCRATCH_BASE) >> 2;
                word_value = scratch_expected[index];
            end
            expected_byte = word_value[address[1:0]*8 +: 8];
        end
    endfunction

    function automatic logic [127:0] expected_read_payload(
        input logic [63:0] address,
        input logic [2:0] size,
        input logic valid_contract
    );
        integer index;
        integer bus_lane;
        integer bytes_in_beat;
        logic [127:0] result;
        begin
            result = 128'b0;
            bytes_in_beat = 1 << size;
            if (valid_contract) begin
                for (index = 0; index < 16; index = index + 1) begin
                    bus_lane = address[3:0] + index;
                    if ((index < bytes_in_beat) && (bus_lane < 16))
                        result[bus_lane*8 +: 8] =
                            expected_byte(address + index);
                end
            end
            expected_read_payload = result;
        end
    endfunction

    task automatic clear_faults;
        begin
            fault_rresp_enable = 1'b0;
            fault_rresp_id = '0;
            fault_rresp_beat = 8'd0;
            fault_rresp_value = 2'b10;
            fault_rid_enable = 1'b0;
            fault_rid_value = '0;
            fault_rlast_mode = 2'd0;
            fault_bresp_enable = 1'b0;
            fault_bresp_id = '0;
            fault_bresp_value = 2'b10;
            fault_bid_enable = 1'b0;
            fault_bid_value = '0;
        end
    endtask

    task automatic send_ar(
        input logic [63:0] address,
        input logic [7:0] length,
        input logic [2:0] size
    );
        integer watchdog;
        begin
            @(negedge aclk);
            arid = '0;
            araddr = address[AXI_ADDR_WIDTH-1:0];
            arlen = length;
            arsize = size;
            arburst = 2'b01;
            arlock = 1'b0;
            arvalid = 1'b1;
            watchdog = 0;
            while (!arready) begin
                @(negedge aclk);
                watchdog = watchdog + 1;
                if (watchdog > 100)
                    $fatal(1, "AR handshake timeout");
            end
            @(negedge aclk);
            arvalid = 1'b0;
            expected_ar_transactions = expected_ar_transactions + 1;
            expected_requested_r_beats =
                expected_requested_r_beats + length + 1;
        end
    endtask

    task automatic receive_read(
        input logic [63:0] address,
        input logic [7:0] length,
        input logic [2:0] size,
        input logic valid_contract,
        input logic [1:0] expected_default_resp,
        input integer response_fault_beat,
        input logic [1:0] response_fault_value,
        input logic expected_id,
        input logic [1:0] expected_last_mode,
        input logic random_backpressure
    );
        integer beat;
        integer watchdog;
        logic [63:0] beat_address;
        logic expected_last;
        logic [1:0] beat_response;
        begin
            for (beat = 0; beat <= length; beat = beat + 1) begin
                watchdog = 0;
                while (1) begin
                    @(negedge aclk);
                    if (random_backpressure)
                        rready = (($urandom(seed) & 32'h3) != 0);
                    else
                        rready = 1'b1;
                    if (rvalid && rready) begin
                        beat_address = address + (beat << size);
                        beat_response = expected_default_resp;
                        if (beat == response_fault_beat)
                            beat_response = response_fault_value;
                        case (expected_last_mode)
                            2'd1: expected_last = (beat == 0);
                            2'd2: expected_last = 1'b0;
                            default: expected_last = (beat == length);
                        endcase
                        check(rid === expected_id,
                              "RID mismatch or reordering");
                        check(rresp === beat_response,
                              "RRESP mismatch");
                        check(rlast === expected_last,
                              "RLAST mismatch");
                        check(rdata === expected_read_payload(
                                  beat_address, size, valid_contract),
                              "RDATA lane/payload mismatch");
                        expected_r_beats = expected_r_beats + 1;
                        if (valid_contract) begin
                            if (size == 3'd4)
                                expected_valid_read_words =
                                    expected_valid_read_words + 4;
                            else
                                expected_valid_read_words =
                                    expected_valid_read_words + 1;
                        end
                        @(negedge aclk);
                        rready = 1'b0;
                        break;
                    end
                    watchdog = watchdog + 1;
                    if (watchdog > 300)
                        $fatal(1, "R beat timeout");
                end
            end
        end
    endtask

    task automatic send_aw(
        input logic [63:0] address,
        input logic [7:0] length,
        input logic [2:0] size
    );
        integer watchdog;
        begin
            @(negedge aclk);
            awid = '0;
            awaddr = address[AXI_ADDR_WIDTH-1:0];
            awlen = length;
            awsize = size;
            awburst = 2'b01;
            awlock = 1'b0;
            awvalid = 1'b1;
            watchdog = 0;
            while (!awready) begin
                @(negedge aclk);
                watchdog = watchdog + 1;
                if (watchdog > 100)
                    $fatal(1, "AW handshake timeout");
            end
            @(negedge aclk);
            awvalid = 1'b0;
            expected_aw_transactions = expected_aw_transactions + 1;
            expected_requested_w_beats =
                expected_requested_w_beats + length + 1;
        end
    endtask

    task automatic send_w(
        input logic [127:0] data,
        input logic [15:0] strobe,
        input logic last
    );
        integer watchdog;
        begin
            @(negedge aclk);
            wdata = data;
            wstrb = strobe;
            wlast = last;
            wvalid = 1'b1;
            watchdog = 0;
            while (!wready) begin
                @(negedge aclk);
                watchdog = watchdog + 1;
                if (watchdog > 100)
                    $fatal(1, "W handshake timeout");
            end
            @(negedge aclk);
            wvalid = 1'b0;
            expected_w_beats = expected_w_beats + 1;
        end
    endtask

    task automatic receive_b(
        input logic [1:0] expected_resp,
        input logic expected_id,
        input logic random_backpressure
    );
        integer watchdog;
        begin
            watchdog = 0;
            while (1) begin
                @(negedge aclk);
                if (random_backpressure)
                    bready = (($urandom(seed) & 32'h1) != 0);
                else
                    bready = 1'b1;
                if (bvalid && bready) begin
                    check(bresp === expected_resp, "BRESP mismatch");
                    check(bid === expected_id, "BID mismatch");
                    expected_b_responses = expected_b_responses + 1;
                    @(negedge aclk);
                    bready = 1'b0;
                    break;
                end
                watchdog = watchdog + 1;
                if (watchdog > 300)
                    $fatal(1, "B response timeout");
            end
        end
    endtask

    task automatic update_expected_scratch(
        input logic [63:0] address,
        input logic [127:0] data,
        input logic [15:0] strobe
    );
        integer byte_number;
        integer index;
        logic [63:0] bus_base;
        logic [63:0] target_address;
        begin
            bus_base = {address[63:4], 4'b0000};
            for (byte_number = 0; byte_number < 16;
                 byte_number = byte_number + 1) begin
                if (strobe[byte_number]) begin
                    target_address = bus_base + byte_number;
                    index = (target_address - SCRATCH_BASE) >> 2;
                    scratch_expected[index]
                        [target_address[1:0]*8 +: 8] =
                        data[byte_number*8 +: 8];
                end
            end
        end
    endtask

    // AXI requires response payloads to remain stable while VALID is held
    // against backpressure.  This monitor makes that property fail-fast.
    always @(posedge aclk) begin
        if (!aresetn) begin
            r_hold_active <= 1'b0;
            b_hold_active <= 1'b0;
        end else begin
            if (r_hold_active) begin
                if ((rdata !== r_hold_data) || (rid !== r_hold_id) ||
                    (rresp !== r_hold_resp) || (rlast !== r_hold_last) ||
                    !rvalid)
                    $fatal(1, "R payload changed under backpressure");
            end
            r_hold_active <= rvalid && !rready;
            if (rvalid && !rready) begin
                r_hold_data <= rdata;
                r_hold_id <= rid;
                r_hold_resp <= rresp;
                r_hold_last <= rlast;
            end

            if (b_hold_active) begin
                if ((bid !== b_hold_id) || (bresp !== b_hold_resp) ||
                    !bvalid)
                    $fatal(1, "B payload changed under backpressure");
            end
            b_hold_active <= bvalid && !bready;
            if (bvalid && !bready) begin
                b_hold_id <= bid;
                b_hold_resp <= bresp;
            end
        end
    end

    initial begin
        checks = 0;
        seed = 32'h5a17_2026;
        random_iterations = 40;
        if ($value$plusargs("SEED=%d", seed)) begin end
        if ($value$plusargs("ITERATIONS=%d", random_iterations)) begin end
        initial_seed = seed;
        $display("M5 AXI128 DDR seed=%0d iterations=%0d",
                 seed, random_iterations);

        expected_ar_transactions = 0;
        expected_aw_transactions = 0;
        expected_r_beats = 0;
        expected_w_beats = 0;
        expected_b_responses = 0;
        expected_requested_r_beats = 0;
        expected_requested_w_beats = 0;
        expected_valid_read_words = 0;
        expected_valid_write_words = 0;
        expected_invalid_accesses = 0;
        expected_protocol_errors = 0;
        expected_four_kib_errors = 0;

        aresetn = 1'b0;
        awid = '0;
        awaddr = '0;
        awlen = 8'd0;
        awsize = 3'd2;
        awburst = 2'b01;
        awlock = 1'b0;
        awcache = 4'd0;
        awprot = 3'd0;
        awqos = 4'd0;
        awvalid = 1'b0;
        wdata = 128'd0;
        wstrb = 16'd0;
        wlast = 1'b1;
        wvalid = 1'b0;
        bready = 1'b0;
        arid = '0;
        araddr = '0;
        arlen = 8'd0;
        arsize = 3'd2;
        arburst = 2'b01;
        arlock = 1'b0;
        arcache = 4'd0;
        arprot = 3'd0;
        arqos = 4'd0;
        arvalid = 1'b0;
        rready = 1'b0;
        clear_faults();

        for (init_index = 0; init_index < MODEL_WORDS;
             init_index = init_index + 1)
            dut.model_memory[init_index] = model_pattern(init_index);
        for (init_index = 0; init_index < INPUT_WORDS;
             init_index = init_index + 1)
            dut.input_memory[init_index] = input_pattern(init_index);
        for (init_index = 0; init_index < SCRATCH_WORDS;
             init_index = init_index + 1) begin
            scratch_expected[init_index] =
                32'h3300_0000 ^ (init_index * 32'd5);
            dut.scratch_memory[init_index] = scratch_expected[init_index];
        end

        repeat (5) @(posedge aclk);
        @(negedge aclk);
        aresetn = 1'b1;

        // Full-width four-beat burst.
        send_ar(MODEL_BASE + 64'h100, 8'd3, 3'd4);
        receive_read(MODEL_BASE + 64'h100, 8'd3, 3'd4,
                     1'b1, 2'b00, -1, 2'b00, 1'b0, 2'd0, 1'b1);

        // Narrow INCR burst begins in lane one and wraps through all lanes.
        send_ar(MODEL_BASE + 64'h004, 8'd3, 3'd2);
        receive_read(MODEL_BASE + 64'h004, 8'd3, 3'd2,
                     1'b1, 2'b00, -1, 2'b00, 1'b0, 2'd0, 1'b1);

        // Two same-ID requests must both be accepted before response drain,
        // then return in AR issue order.
        rready = 1'b0;
        send_ar(INPUT_BASE + 64'h020, 8'd1, 3'd4);
        send_ar(INPUT_BASE + 64'h080, 8'd2, 3'd4);
        repeat (5) @(posedge aclk);
        check(read_outstanding_count >= 2,
              "two same-ID reads were not outstanding");
        receive_read(INPUT_BASE + 64'h020, 8'd1, 3'd4,
                     1'b1, 2'b00, -1, 2'b00, 1'b0, 2'd0, 1'b1);
        receive_read(INPUT_BASE + 64'h080, 8'd2, 3'd4,
                     1'b1, 2'b00, -1, 2'b00, 1'b0, 2'd0, 1'b1);

        // The final 16-byte transfer before a page boundary is legal.
        send_ar(MODEL_BASE + 64'h0ff0, 8'd0, 3'd4);
        receive_read(MODEL_BASE + 64'h0ff0, 8'd0, 3'd4,
                     1'b1, 2'b00, -1, 2'b00, 1'b0, 2'd0, 1'b0);

        // Crossing 4 KiB is rejected but returns the declared beat count.
        send_ar(MODEL_BASE + 64'h0ff0, 8'd1, 3'd4);
        expected_invalid_accesses = expected_invalid_accesses + 1;
        expected_four_kib_errors = expected_four_kib_errors + 1;
        receive_read(MODEL_BASE + 64'h0ff0, 8'd1, 3'd4,
                     1'b0, 2'b10, -1, 2'b00, 1'b0, 2'd0, 1'b1);

        // Region tail, alignment and maximum-burst failures.
        send_ar(INPUT_BASE + INPUT_WORDS*4 - 16, 8'd1, 3'd4);
        expected_invalid_accesses = expected_invalid_accesses + 1;
        receive_read(INPUT_BASE + INPUT_WORDS*4 - 16, 8'd1, 3'd4,
                     1'b0, 2'b10, -1, 2'b00, 1'b0, 2'd0, 1'b0);

        send_ar(MODEL_BASE + 64'h004, 8'd0, 3'd4);
        expected_invalid_accesses = expected_invalid_accesses + 1;
        expected_protocol_errors = expected_protocol_errors + 1;
        receive_read(MODEL_BASE + 64'h004, 8'd0, 3'd4,
                     1'b0, 2'b10, -1, 2'b00, 1'b0, 2'd0, 1'b0);

        send_ar(MODEL_BASE + 64'h200, 8'd4, 3'd4);
        expected_invalid_accesses = expected_invalid_accesses + 1;
        expected_protocol_errors = expected_protocol_errors + 1;
        receive_read(MODEL_BASE + 64'h200, 8'd4, 3'd4,
                     1'b0, 2'b10, -1, 2'b00, 1'b0, 2'd0, 1'b1);

        // Typed read-channel faults are sampled with AR.
        fault_rresp_enable = 1'b1;
        fault_rresp_beat = 8'd1;
        fault_rresp_value = 2'b11;
        send_ar(MODEL_BASE + 64'h300, 8'd2, 3'd4);
        clear_faults();
        receive_read(MODEL_BASE + 64'h300, 8'd2, 3'd4,
                     1'b1, 2'b00, 1, 2'b11, 1'b0, 2'd0, 1'b1);

        fault_rid_enable = 1'b1;
        fault_rid_value = 1'b1;
        send_ar(MODEL_BASE + 64'h340, 8'd0, 3'd4);
        clear_faults();
        receive_read(MODEL_BASE + 64'h340, 8'd0, 3'd4,
                     1'b1, 2'b00, -1, 2'b00, 1'b1, 2'd0, 1'b0);

        fault_rlast_mode = 2'd1;
        send_ar(MODEL_BASE + 64'h380, 8'd2, 3'd4);
        clear_faults();
        receive_read(MODEL_BASE + 64'h380, 8'd2, 3'd4,
                     1'b1, 2'b00, -1, 2'b00, 1'b0, 2'd1, 1'b1);

        fault_rlast_mode = 2'd2;
        send_ar(MODEL_BASE + 64'h3c0, 8'd1, 3'd4);
        clear_faults();
        receive_read(MODEL_BASE + 64'h3c0, 8'd1, 3'd4,
                     1'b1, 2'b00, -1, 2'b00, 1'b0, 2'd2, 1'b0);

        // W-before-AW narrow write in lane one.
        random_write_bus_data = 128'b0;
        random_write_bus_data[63:32] = 32'ha1b2_c3d4;
        random_write_bus_strobe = 16'h00f0;
        send_w(random_write_bus_data, random_write_bus_strobe, 1'b1);
        send_aw(SCRATCH_BASE + 64'h004, 8'd0, 3'd2);
        update_expected_scratch(SCRATCH_BASE + 64'h004,
                                random_write_bus_data,
                                random_write_bus_strobe);
        expected_valid_write_words = expected_valid_write_words + 1;
        receive_b(2'b00, 1'b0, 1'b1);
        check(dut.scratch_memory[1] === scratch_expected[1],
              "W-before-AW write data mismatch");

        // AW-before-W with two-byte partial strobe in lane three.
        random_write_bus_data = 128'b0;
        random_write_bus_data[127:96] = 32'h5566_7788;
        random_write_bus_strobe = 16'hc000;
        send_aw(SCRATCH_BASE + 64'h00c, 8'd0, 3'd2);
        send_w(random_write_bus_data, random_write_bus_strobe, 1'b1);
        update_expected_scratch(SCRATCH_BASE + 64'h00c,
                                random_write_bus_data,
                                random_write_bus_strobe);
        expected_valid_write_words = expected_valid_write_words + 1;
        receive_b(2'b00, 1'b0, 1'b1);
        check(dut.scratch_memory[3] === scratch_expected[3],
              "partial WSTRB write data mismatch");

        // Writes to MODEL fail closed and preserve the backing store.
        random_write_bus_data = 128'b0;
        random_write_bus_data[31:0] = 32'hdead_beef;
        send_aw(MODEL_BASE, 8'd0, 3'd2);
        expected_invalid_accesses = expected_invalid_accesses + 1;
        send_w(random_write_bus_data, 16'h000f, 1'b1);
        receive_b(2'b10, 1'b0, 1'b0);
        check(dut.model_memory[0] === model_pattern(0),
              "read-only MODEL memory was modified");

        // BRESP and BID corruption are independent injectable faults.
        fault_bresp_enable = 1'b1;
        fault_bresp_value = 2'b11;
        send_aw(SCRATCH_BASE + 64'h010, 8'd0, 3'd2);
        clear_faults();
        random_write_bus_data = 128'b0;
        random_write_bus_data[31:0] = 32'h0102_0304;
        send_w(random_write_bus_data, 16'h000f, 1'b1);
        update_expected_scratch(SCRATCH_BASE + 64'h010,
                                random_write_bus_data, 16'h000f);
        expected_valid_write_words = expected_valid_write_words + 1;
        receive_b(2'b11, 1'b0, 1'b1);

        fault_bid_enable = 1'b1;
        fault_bid_value = 1'b1;
        send_aw(SCRATCH_BASE + 64'h014, 8'd0, 3'd2);
        clear_faults();
        random_write_bus_data = 128'b0;
        random_write_bus_data[63:32] = 32'h0506_0708;
        send_w(random_write_bus_data, 16'h00f0, 1'b1);
        update_expected_scratch(SCRATCH_BASE + 64'h014,
                                random_write_bus_data, 16'h00f0);
        expected_valid_write_words = expected_valid_write_words + 1;
        receive_b(2'b00, 1'b1, 1'b0);

        // Deterministic randomized read batches.  Each pair is issued before
        // draining, continuously exercising same-ID outstanding ordering.
        for (iteration = 0; iteration < random_iterations;
             iteration = iteration + 1) begin
            random_value = $urandom(seed);
            random_size_a = random_value[0] ? 3'd4 : 3'd2;
            length_value = (random_value >> 1) & 3;
            if (random_size_a == 3'd4) begin
                word_offset = ((random_value >> 5) % 100) * 4;
                random_address_a = MODEL_BASE + word_offset*4;
            end else begin
                word_offset = (random_value >> 5) % 400;
                random_address_a = MODEL_BASE + word_offset*4;
            end

            random_value = $urandom(seed);
            random_size_b = random_value[0] ? 3'd4 : 3'd2;
            if (random_size_b == 3'd4) begin
                word_offset = ((random_value >> 5) % 40) * 4;
                random_address_b = INPUT_BASE + word_offset*4;
            end else begin
                word_offset = (random_value >> 5) % 180;
                random_address_b = INPUT_BASE + word_offset*4;
            end

            rready = 1'b0;
            send_ar(random_address_a, length_value[7:0], random_size_a);
            send_ar(random_address_b, length_value[7:0], random_size_b);
            receive_read(random_address_a, length_value[7:0], random_size_a,
                         1'b1, 2'b00, -1, 2'b00,
                         1'b0, 2'd0, 1'b1);
            receive_read(random_address_b, length_value[7:0], random_size_b,
                         1'b1, 2'b00, -1, 2'b00,
                         1'b0, 2'd0, 1'b1);
        end

        // Random scalar writes cover all four lanes and all nonzero byte
        // strobe combinations, with randomized B-channel backpressure.
        for (iteration = 0; iteration < random_iterations;
             iteration = iteration + 1) begin
            random_value = $urandom(seed);
            lane = random_value & 3;
            word_offset = 32 + ((random_value >> 4) % 400);
            random_write_value = $urandom(seed);
            random_byte_strobe = ($urandom(seed) & 4'hf);
            if (random_byte_strobe == 4'h0)
                random_byte_strobe = 4'hf;
            random_write_bus_data = 128'b0;
            random_write_bus_data[lane*32 +: 32] = random_write_value;
            random_write_bus_strobe =
                {{12{1'b0}}, random_byte_strobe} << (lane*4);
            random_address_a =
                SCRATCH_BASE + (word_offset & ~3)*4 + lane*4;

            if (iteration[0]) begin
                send_aw(random_address_a, 8'd0, 3'd2);
                send_w(random_write_bus_data,
                       random_write_bus_strobe, 1'b1);
            end else begin
                send_w(random_write_bus_data,
                       random_write_bus_strobe, 1'b1);
                send_aw(random_address_a, 8'd0, 3'd2);
            end
            update_expected_scratch(random_address_a,
                                    random_write_bus_data,
                                    random_write_bus_strobe);
            expected_valid_write_words = expected_valid_write_words + 1;
            receive_b(2'b00, 1'b0, 1'b1);
            check(dut.scratch_memory[word_offset] ===
                  scratch_expected[word_offset],
                  "random scalar write scoreboard mismatch");
        end

        repeat (10) @(posedge aclk);
        check(read_outstanding_count == 0,
              "read outstanding count did not drain");
        check(write_outstanding_count == 0,
              "write outstanding count did not drain");
        check(read_outstanding_high_water >= 2,
              "read outstanding high-water did not prove >=2");
        check(write_outstanding_high_water >= 1,
              "write outstanding high-water did not prove activity");
        check(ar_transaction_count == expected_ar_transactions,
              "AR transaction counter mismatch");
        check(aw_transaction_count == expected_aw_transactions,
              "AW transaction counter mismatch");
        check(r_beat_count == expected_r_beats,
              "R beat counter mismatch");
        check(w_beat_count == expected_w_beats,
              "W beat counter mismatch");
        check(b_response_count == expected_b_responses,
              "B response counter mismatch");
        check(ar_requested_beat_count == expected_requested_r_beats,
              "AR requested-beat sum mismatch");
        check(aw_requested_beat_count == expected_requested_w_beats,
              "AW requested-beat sum mismatch");
        check(read_count == expected_valid_read_words,
              "useful read-word counter mismatch");
        check(write_count == expected_valid_write_words,
              "useful write-word counter mismatch");
        check(invalid_access_count == expected_invalid_accesses,
              "invalid-access counter mismatch");
        check(protocol_error_count == expected_protocol_errors,
              "protocol-error counter mismatch");
        check(four_kib_error_count == expected_four_kib_errors,
              "4 KiB counter mismatch");
        check((ar_backpressure_cycles != 0) ||
              (r_backpressure_cycles != 0),
              "read-side backpressure was not exercised");
        check((aw_backpressure_cycles != 0) ||
              (w_backpressure_cycles != 0) ||
              (b_backpressure_cycles != 0),
              "write-side backpressure was not exercised");

        $display("M5_AXI128_DDR_MODEL PASS checks=%0d seed=%0d AR=%0d Rbeats=%0d AW=%0d Wbeats=%0d B=%0d",
                 checks, initial_seed, ar_transaction_count, r_beat_count,
                 aw_transaction_count, w_beat_count, b_response_count);
        $finish;
    end

    initial begin
        #5_000_000;
        $fatal(1, "M5 AXI128 DDR testbench timeout");
    end

endmodule
