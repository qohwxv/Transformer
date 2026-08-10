`timescale 1ns/1ps

// Simulation-only AXI4 memory model used by the M5 native-128 regressions.
//
// The backing stores remain arrays of 32-bit words so existing model/input
// preload code can use the same representation as the scalar DDR model.  The
// AXI data path is 128 bits and implements:
//   * INCR reads with narrow (32-bit) or full-width (128-bit) beats;
//   * a queued read-address path (including two same-ID requests);
//   * scalar narrow writes, with independent AW and W buffering;
//   * stable R/B payloads under master backpressure;
//   * deterministic, independent stalls on every AXI channel;
//   * fail-closed range, alignment, burst-length and 4 KiB validation;
//   * optional response/ID/RLAST fault injection for negative tests.
//
// Requests are serviced in global AR order.  This is stricter than AXI's
// cross-ID ordering rule and therefore guarantees same-ID ordering.
module vit_axi_ddr_model_128 #(
    parameter integer AXI_ADDR_WIDTH = 40,
    parameter integer AXI_ID_WIDTH = 1,
    parameter integer MODEL_WORDS = 32768,
    parameter integer INPUT_WORDS = 32,
    parameter integer SCRATCH_WORDS = 32'h001e_6000,
    parameter logic [63:0] MODEL_BASE = 64'h0000_0010_0000_0000,
    parameter logic [63:0] INPUT_BASE = 64'h0000_0020_0000_0000,
    parameter logic [63:0] SCRATCH_BASE = 64'h0000_0030_0000_0000,
    parameter integer MAX_BURST_BEATS = 4,
    parameter integer READ_QUEUE_DEPTH = 4,
    parameter integer WRITE_QUEUE_DEPTH = 4,
    parameter integer W_QUEUE_DEPTH = 16,
    parameter logic STALL_ENABLE = 1'b1
) (
    input  logic                          aclk,
    input  logic                          aresetn,

    input  logic [AXI_ID_WIDTH-1:0]       s_axi_awid,
    input  logic [AXI_ADDR_WIDTH-1:0]     s_axi_awaddr,
    input  logic [7:0]                    s_axi_awlen,
    input  logic [2:0]                    s_axi_awsize,
    input  logic [1:0]                    s_axi_awburst,
    input  logic                          s_axi_awlock,
    input  logic [3:0]                    s_axi_awcache,
    input  logic [2:0]                    s_axi_awprot,
    input  logic [3:0]                    s_axi_awqos,
    input  logic                          s_axi_awvalid,
    output logic                          s_axi_awready,

    input  logic [127:0]                  s_axi_wdata,
    input  logic [15:0]                   s_axi_wstrb,
    input  logic                          s_axi_wlast,
    input  logic                          s_axi_wvalid,
    output logic                          s_axi_wready,

    output logic [AXI_ID_WIDTH-1:0]       s_axi_bid,
    output logic [1:0]                    s_axi_bresp,
    output logic                          s_axi_bvalid,
    input  logic                          s_axi_bready,

    input  logic [AXI_ID_WIDTH-1:0]       s_axi_arid,
    input  logic [AXI_ADDR_WIDTH-1:0]     s_axi_araddr,
    input  logic [7:0]                    s_axi_arlen,
    input  logic [2:0]                    s_axi_arsize,
    input  logic [1:0]                    s_axi_arburst,
    input  logic                          s_axi_arlock,
    input  logic [3:0]                    s_axi_arcache,
    input  logic [2:0]                    s_axi_arprot,
    input  logic [3:0]                    s_axi_arqos,
    input  logic                          s_axi_arvalid,
    output logic                          s_axi_arready,

    output logic [AXI_ID_WIDTH-1:0]       s_axi_rid,
    output logic [127:0]                  s_axi_rdata,
    output logic [1:0]                    s_axi_rresp,
    output logic                          s_axi_rlast,
    output logic                          s_axi_rvalid,
    input  logic                          s_axi_rready,

    // Simulation controls.  Fault controls are sampled with AR/AW, making
    // their behavior deterministic even if the test changes them later.
    input  logic                          fault_rresp_enable_i,
    input  logic [AXI_ID_WIDTH-1:0]       fault_rresp_id_i,
    input  logic [7:0]                    fault_rresp_beat_i,
    input  logic [1:0]                    fault_rresp_value_i,
    input  logic                          fault_rid_enable_i,
    input  logic [AXI_ID_WIDTH-1:0]       fault_rid_value_i,
    // 0: normal, 1: early RLAST on beat zero, 2: suppress final RLAST.
    input  logic [1:0]                    fault_rlast_mode_i,
    input  logic                          fault_bresp_enable_i,
    input  logic [AXI_ID_WIDTH-1:0]       fault_bresp_id_i,
    input  logic [1:0]                    fault_bresp_value_i,
    input  logic                          fault_bid_enable_i,
    input  logic [AXI_ID_WIDTH-1:0]       fault_bid_value_i,

    // Counts below are handshake based.  read_count_o/write_count_o and the
    // region counts are useful 32-bit words, while the explicit channel
    // counters count AXI transactions or 128-bit bus beats.
    output logic [63:0]                   read_count_o,
    output logic [63:0]                   write_count_o,
    output logic [63:0]                   model_read_count_o,
    output logic [63:0]                   input_read_count_o,
    output logic [63:0]                   scratch_read_count_o,
    output logic [63:0]                   scratch_write_count_o,
    output logic [63:0]                   ar_transaction_count_o,
    output logic [63:0]                   aw_transaction_count_o,
    output logic [63:0]                   r_beat_count_o,
    output logic [63:0]                   w_beat_count_o,
    output logic [63:0]                   b_response_count_o,
    output logic [63:0]                   ar_requested_beat_count_o,
    output logic [63:0]                   aw_requested_beat_count_o,
    output logic [63:0]                   ar_backpressure_cycle_count_o,
    output logic [63:0]                   aw_backpressure_cycle_count_o,
    output logic [63:0]                   w_backpressure_cycle_count_o,
    output logic [63:0]                   r_backpressure_cycle_count_o,
    output logic [63:0]                   b_backpressure_cycle_count_o,
    output logic [31:0]                   invalid_access_count_o,
    output logic [31:0]                   protocol_error_count_o,
    output logic [31:0]                   four_kib_error_count_o,
    output logic [31:0]                   read_outstanding_count_o,
    output logic [31:0]                   write_outstanding_count_o,
    output logic [31:0]                   read_outstanding_high_water_o,
    output logic [31:0]                   write_outstanding_high_water_o
);

    localparam logic [1:0] AXI_RESP_OKAY   = 2'b00;
    localparam logic [1:0] AXI_RESP_SLVERR = 2'b10;
    localparam logic [1:0] AXI_BURST_INCR  = 2'b01;

    localparam logic [1:0] REGION_NONE    = 2'd0;
    localparam logic [1:0] REGION_MODEL   = 2'd1;
    localparam logic [1:0] REGION_INPUT   = 2'd2;
    localparam logic [1:0] REGION_SCRATCH = 2'd3;

    localparam integer AR_PTR_WIDTH =
        (READ_QUEUE_DEPTH <= 1) ? 1 : $clog2(READ_QUEUE_DEPTH);
    localparam integer AW_PTR_WIDTH =
        (WRITE_QUEUE_DEPTH <= 1) ? 1 : $clog2(WRITE_QUEUE_DEPTH);
    localparam integer W_PTR_WIDTH =
        (W_QUEUE_DEPTH <= 1) ? 1 : $clog2(W_QUEUE_DEPTH);

    logic [31:0] model_memory [0:MODEL_WORDS-1];
    logic [31:0] input_memory [0:INPUT_WORDS-1];
    logic [31:0] scratch_memory [0:SCRATCH_WORDS-1];

    logic [63:0] cycle_count;

    // These range monitors intentionally remain public for hierarchical use.
    logic [31:0] model_min_word;
    logic [31:0] model_max_word;
    logic [31:0] input_min_word;
    logic [31:0] input_max_word;
    logic [31:0] scratch_min_word;
    logic [31:0] scratch_max_word;

    // AR FIFO.
    logic [AXI_ID_WIDTH-1:0] ar_id_fifo [0:READ_QUEUE_DEPTH-1];
    logic [AXI_ADDR_WIDTH-1:0] ar_addr_fifo [0:READ_QUEUE_DEPTH-1];
    logic [7:0] ar_len_fifo [0:READ_QUEUE_DEPTH-1];
    logic [2:0] ar_size_fifo [0:READ_QUEUE_DEPTH-1];
    logic [1:0] ar_region_fifo [0:READ_QUEUE_DEPTH-1];
    logic ar_valid_fifo [0:READ_QUEUE_DEPTH-1];
    logic ar_rresp_fault_fifo [0:READ_QUEUE_DEPTH-1];
    logic [7:0] ar_rresp_beat_fifo [0:READ_QUEUE_DEPTH-1];
    logic [1:0] ar_rresp_value_fifo [0:READ_QUEUE_DEPTH-1];
    logic ar_rid_fault_fifo [0:READ_QUEUE_DEPTH-1];
    logic [AXI_ID_WIDTH-1:0] ar_rid_value_fifo [0:READ_QUEUE_DEPTH-1];
    logic [1:0] ar_rlast_mode_fifo [0:READ_QUEUE_DEPTH-1];
    logic [AR_PTR_WIDTH-1:0] ar_write_pointer;
    logic [AR_PTR_WIDTH-1:0] ar_read_pointer;
    integer ar_fifo_count;

    logic read_active;
    logic [AXI_ID_WIDTH-1:0] read_id;
    logic [AXI_ADDR_WIDTH-1:0] read_address;
    logic [7:0] read_length;
    logic [2:0] read_size;
    logic [1:0] read_region;
    logic read_contract_valid;
    logic read_rresp_fault;
    logic [7:0] read_rresp_fault_beat;
    logic [1:0] read_rresp_fault_value;
    logic read_rid_fault;
    logic [AXI_ID_WIDTH-1:0] read_rid_fault_value;
    logic [1:0] read_rlast_mode;
    logic [8:0] read_beat_index;

    // AW FIFO and independent W FIFO.
    logic [AXI_ID_WIDTH-1:0] aw_id_fifo [0:WRITE_QUEUE_DEPTH-1];
    logic [AXI_ADDR_WIDTH-1:0] aw_addr_fifo [0:WRITE_QUEUE_DEPTH-1];
    logic [7:0] aw_len_fifo [0:WRITE_QUEUE_DEPTH-1];
    logic [2:0] aw_size_fifo [0:WRITE_QUEUE_DEPTH-1];
    logic [1:0] aw_region_fifo [0:WRITE_QUEUE_DEPTH-1];
    logic aw_valid_fifo [0:WRITE_QUEUE_DEPTH-1];
    logic aw_bresp_fault_fifo [0:WRITE_QUEUE_DEPTH-1];
    logic [1:0] aw_bresp_value_fifo [0:WRITE_QUEUE_DEPTH-1];
    logic aw_bid_fault_fifo [0:WRITE_QUEUE_DEPTH-1];
    logic [AXI_ID_WIDTH-1:0] aw_bid_value_fifo [0:WRITE_QUEUE_DEPTH-1];
    logic [AW_PTR_WIDTH-1:0] aw_write_pointer;
    logic [AW_PTR_WIDTH-1:0] aw_read_pointer;
    integer aw_fifo_count;

    logic [127:0] w_data_fifo [0:W_QUEUE_DEPTH-1];
    logic [15:0] w_strb_fifo [0:W_QUEUE_DEPTH-1];
    logic w_last_fifo [0:W_QUEUE_DEPTH-1];
    logic [W_PTR_WIDTH-1:0] w_write_pointer;
    logic [W_PTR_WIDTH-1:0] w_read_pointer;
    integer w_fifo_count;
    wire [15:0] w_head_strobe = w_strb_fifo[w_read_pointer];
    wire w_head_last = w_last_fifo[w_read_pointer];

    logic write_active;
    logic [AXI_ID_WIDTH-1:0] write_id;
    logic [AXI_ADDR_WIDTH-1:0] write_address;
    logic [7:0] write_length;
    logic [2:0] write_size;
    logic [1:0] write_region;
    logic write_contract_valid;
    logic write_error_accumulated;
    logic write_bresp_fault;
    logic [1:0] write_bresp_fault_value;
    logic write_bid_fault;
    logic [AXI_ID_WIDTH-1:0] write_bid_fault_value;
    logic [8:0] write_beat_index;

    // B responses cannot overtake because this queue is FIFO ordered.
    logic [AXI_ID_WIDTH-1:0] b_id_fifo [0:WRITE_QUEUE_DEPTH-1];
    logic [1:0] b_resp_fifo [0:WRITE_QUEUE_DEPTH-1];
    logic [AW_PTR_WIDTH-1:0] b_write_pointer;
    logic [AW_PTR_WIDTH-1:0] b_read_pointer;
    integer b_fifo_count;

    logic [63:0] ar_address_64;
    logic [63:0] aw_address_64;
    logic [64:0] ar_total_bytes;
    logic [64:0] aw_total_bytes;
    logic [1:0] ar_decoded_region;
    logic [1:0] aw_decoded_region;
    logic ar_alignment_valid;
    logic aw_alignment_valid;
    logic ar_page_valid;
    logic aw_page_valid;
    logic ar_range_valid;
    logic aw_range_valid;
    logic ar_protocol_valid;
    logic aw_protocol_valid;
    logic current_ar_valid;
    logic current_aw_valid;

    logic [63:0] current_read_beat_address;
    logic [63:0] current_write_beat_address;
    logic [63:0] current_write_bus_base;
    logic current_write_expected_last;
    logic current_write_last_matches;
    logic current_write_strobe_valid;
    logic current_write_finishes;

    integer combinational_byte_index;
    logic [63:0] combinational_byte_address;

    function automatic logic [63:0] extend_address(
        input logic [AXI_ADDR_WIDTH-1:0] address
    );
        begin
            extend_address = 64'b0;
            extend_address[AXI_ADDR_WIDTH-1:0] = address;
        end
    endfunction

    function automatic logic [63:0] region_base(
        input logic [1:0] region
    );
        begin
            case (region)
                REGION_MODEL:   region_base = MODEL_BASE;
                REGION_INPUT:   region_base = INPUT_BASE;
                REGION_SCRATCH: region_base = SCRATCH_BASE;
                default:        region_base = 64'b0;
            endcase
        end
    endfunction

    function automatic logic [63:0] region_bytes(
        input logic [1:0] region
    );
        begin
            case (region)
                REGION_MODEL:   region_bytes = MODEL_WORDS * 64'd4;
                REGION_INPUT:   region_bytes = INPUT_WORDS * 64'd4;
                REGION_SCRATCH: region_bytes = SCRATCH_WORDS * 64'd4;
                default:        region_bytes = 64'b0;
            endcase
        end
    endfunction

    function automatic logic [1:0] decode_region_64(
        input logic [63:0] address
    );
        logic [64:0] model_end;
        logic [64:0] input_end;
        logic [64:0] scratch_end;
        begin
            model_end = {1'b0, MODEL_BASE} +
                (65'(MODEL_WORDS) << 2);
            input_end = {1'b0, INPUT_BASE} +
                (65'(INPUT_WORDS) << 2);
            scratch_end = {1'b0, SCRATCH_BASE} +
                (65'(SCRATCH_WORDS) << 2);
            if ((address >= MODEL_BASE) &&
                ({1'b0, address} < model_end))
                decode_region_64 = REGION_MODEL;
            else if ((address >= INPUT_BASE) &&
                     ({1'b0, address} < input_end))
                decode_region_64 = REGION_INPUT;
            else if ((address >= SCRATCH_BASE) &&
                     ({1'b0, address} < scratch_end))
                decode_region_64 = REGION_SCRATCH;
            else
                decode_region_64 = REGION_NONE;
        end
    endfunction

    function automatic logic transfer_in_region(
        input logic [63:0] start_address,
        input logic [64:0] total_bytes,
        input logic [1:0] region
    );
        logic [64:0] end_exclusive;
        logic [64:0] region_end;
        begin
            end_exclusive = {1'b0, start_address} + total_bytes;
            region_end = {1'b0, region_base(region)} +
                {1'b0, region_bytes(region)};
            transfer_in_region =
                (region != REGION_NONE) &&
                (start_address >= region_base(region)) &&
                (end_exclusive <= region_end) &&
                (end_exclusive > {1'b0, start_address});
        end
    endfunction

    function automatic logic [31:0] address_word_index(
        input logic [63:0] address,
        input logic [1:0] region
    );
        begin
            address_word_index =
                32'((address - region_base(region)) >> 2);
        end
    endfunction

    function automatic logic [7:0] read_memory_byte(
        input logic [63:0] address,
        input logic [1:0] region
    );
        logic [31:0] index;
        logic [31:0] word_value;
        begin
            index = address_word_index(address, region);
            case (region)
                REGION_MODEL:   word_value = model_memory[index];
                REGION_INPUT:   word_value = input_memory[index];
                REGION_SCRATCH: word_value = scratch_memory[index];
                default:        word_value = 32'b0;
            endcase
            read_memory_byte =
                word_value[address[1:0] * 8 +: 8];
        end
    endfunction

    function automatic logic [127:0] build_read_data(
        input logic [63:0] beat_address,
        input logic [2:0] beat_size,
        input logic [1:0] region,
        input logic contract_valid
    );
        integer lane;
        integer transfer_byte;
        integer bytes_in_beat;
        logic [127:0] result;
        begin
            result = 128'b0;
            bytes_in_beat = 1 << beat_size;
            if (contract_valid) begin
                for (transfer_byte = 0; transfer_byte < 16;
                     transfer_byte = transfer_byte + 1) begin
                    lane = beat_address[3:0] + transfer_byte;
                    if ((transfer_byte < bytes_in_beat) && (lane < 16))
                        result[lane*8 +: 8] = read_memory_byte(
                            beat_address + transfer_byte,
                            region
                        );
                end
            end
            build_read_data = result;
        end
    endfunction

    function automatic logic [31:0] words_per_beat(
        input logic [2:0] beat_size
    );
        begin
            if (beat_size >= 3'd2)
                words_per_beat = 32'd1 << (beat_size - 3'd2);
            else
                words_per_beat = 32'd1;
        end
    endfunction

    function automatic logic [AR_PTR_WIDTH-1:0] ar_pointer_next(
        input logic [AR_PTR_WIDTH-1:0] pointer
    );
        begin
            if (pointer == AR_PTR_WIDTH'(READ_QUEUE_DEPTH-1))
                ar_pointer_next = '0;
            else
                ar_pointer_next = pointer + 1'b1;
        end
    endfunction

    function automatic logic [AW_PTR_WIDTH-1:0] aw_pointer_next(
        input logic [AW_PTR_WIDTH-1:0] pointer
    );
        begin
            if (pointer == AW_PTR_WIDTH'(WRITE_QUEUE_DEPTH-1))
                aw_pointer_next = '0;
            else
                aw_pointer_next = pointer + 1'b1;
        end
    endfunction

    function automatic logic [W_PTR_WIDTH-1:0] w_pointer_next(
        input logic [W_PTR_WIDTH-1:0] pointer
    );
        begin
            if (pointer == W_PTR_WIDTH'(W_QUEUE_DEPTH-1))
                w_pointer_next = '0;
            else
                w_pointer_next = pointer + 1'b1;
        end
    endfunction

    // Use an explicit simulation combinational process; some Icarus builds
    // emit noisy constant-select sensitivity diagnostics for always_comb.
    always @* begin
        ar_address_64 = extend_address(s_axi_araddr);
        aw_address_64 = extend_address(s_axi_awaddr);
        ar_total_bytes = ({57'b0, s_axi_arlen} + 65'd1) <<
            s_axi_arsize;
        aw_total_bytes = ({57'b0, s_axi_awlen} + 65'd1) <<
            s_axi_awsize;
        ar_decoded_region = decode_region_64(ar_address_64);
        aw_decoded_region = decode_region_64(aw_address_64);

        ar_alignment_valid =
            (s_axi_arsize <= 3'd4) &&
            ((ar_address_64 & ((64'd1 << s_axi_arsize) - 1'b1)) == 0);
        aw_alignment_valid =
            (s_axi_awsize <= 3'd4) &&
            ((aw_address_64 & ((64'd1 << s_axi_awsize) - 1'b1)) == 0);
        ar_page_valid =
            ({{53{1'b0}}, ar_address_64[11:0]} +
             ar_total_bytes <= 65'd4096);
        aw_page_valid =
            ({{53{1'b0}}, aw_address_64[11:0]} +
             aw_total_bytes <= 65'd4096);
        ar_range_valid = transfer_in_region(
            ar_address_64, ar_total_bytes, ar_decoded_region
        );
        aw_range_valid = transfer_in_region(
            aw_address_64, aw_total_bytes, aw_decoded_region
        );
        ar_protocol_valid =
            (s_axi_arburst == AXI_BURST_INCR) &&
            !s_axi_arlock &&
            (s_axi_arsize <= 3'd4) &&
            (({1'b0, s_axi_arlen} + 9'd1) <=
             9'(MAX_BURST_BEATS));
        // The production M5 write path is deliberately scalar/narrow.
        aw_protocol_valid =
            (s_axi_awburst == AXI_BURST_INCR) &&
            !s_axi_awlock &&
            (s_axi_awsize == 3'd2) &&
            (s_axi_awlen == 8'd0);
        current_ar_valid = ar_protocol_valid && ar_alignment_valid &&
            ar_page_valid && ar_range_valid;
        current_aw_valid = aw_protocol_valid && aw_alignment_valid &&
            aw_page_valid && aw_range_valid &&
            (aw_decoded_region == REGION_SCRATCH);

        current_read_beat_address = extend_address(read_address) +
            ({{55{1'b0}}, read_beat_index} << read_size);
        current_write_beat_address = extend_address(write_address) +
            ({{55{1'b0}}, write_beat_index} << write_size);
        current_write_bus_base =
            {current_write_beat_address[63:4], 4'b0000};
        current_write_expected_last =
            (write_beat_index == {1'b0, write_length});
        current_write_last_matches =
            (w_head_last == current_write_expected_last);
        current_write_finishes =
            w_head_last || current_write_expected_last;

        current_write_strobe_valid = 1'b1;
        combinational_byte_address = 64'd0;
        for (combinational_byte_index = 0;
             combinational_byte_index < 16;
             combinational_byte_index = combinational_byte_index + 1) begin
            if (w_head_strobe[combinational_byte_index]) begin
                combinational_byte_address = current_write_bus_base +
                    64'(combinational_byte_index);
                if ((combinational_byte_address <
                     current_write_beat_address) ||
                    (combinational_byte_address >=
                     (current_write_beat_address +
                      (64'd1 << write_size))))
                    current_write_strobe_valid = 1'b0;
            end
        end
    end

    assign s_axi_arready =
        (ar_fifo_count < READ_QUEUE_DEPTH) &&
        (!STALL_ENABLE || (cycle_count[2:0] != 3'd1));
    assign s_axi_awready =
        (aw_fifo_count < WRITE_QUEUE_DEPTH) &&
        (!STALL_ENABLE || (cycle_count[2:0] != 3'd2));
    assign s_axi_wready =
        (w_fifo_count < W_QUEUE_DEPTH) &&
        (!STALL_ENABLE || (cycle_count[2:0] != 3'd3));

    // Sideband values are accepted but do not alter this functional model.
    logic unused_sideband;
    assign unused_sideband =
        s_axi_awcache[0] ^ s_axi_awprot[0] ^ s_axi_awqos[0] ^
        s_axi_arcache[0] ^ s_axi_arprot[0] ^ s_axi_arqos[0];

    always_ff @(posedge aclk) begin : model_state
        logic ar_push;
        logic ar_pop;
        logic aw_push;
        logic aw_pop;
        logic w_push;
        logic w_pop;
        logic b_push;
        logic b_pop_to_channel;
        logic read_terminal_handshake;
        logic write_response_handshake;
        logic [1:0] new_bresp;
        logic [AXI_ID_WIDTH-1:0] new_bid;
        logic [31:0] beat_words;
        integer sequential_byte_index;
        logic [63:0] sequential_byte_address;
        logic [31:0] sequential_word_index;
        logic [1:0] sequential_byte_region;

        ar_push = s_axi_arvalid && s_axi_arready;
        ar_pop = !read_active && (ar_fifo_count != 0);
        aw_push = s_axi_awvalid && s_axi_awready;
        aw_pop = !write_active && (aw_fifo_count != 0);
        w_push = s_axi_wvalid && s_axi_wready;
        w_pop = write_active && (w_fifo_count != 0) &&
            (b_fifo_count < WRITE_QUEUE_DEPTH);
        b_push = w_pop && current_write_finishes;
        b_pop_to_channel = !s_axi_bvalid && (b_fifo_count != 0) &&
            (!STALL_ENABLE || (cycle_count[2:0] != 3'd6));
        read_terminal_handshake = s_axi_rvalid && s_axi_rready &&
            (read_beat_index == {1'b0, read_length});
        write_response_handshake = s_axi_bvalid && s_axi_bready;
        beat_words = words_per_beat(read_size);

        new_bresp = AXI_RESP_OKAY;
        if (!write_contract_valid || write_error_accumulated ||
            !current_write_last_matches || !current_write_strobe_valid)
            new_bresp = AXI_RESP_SLVERR;
        if (write_bresp_fault)
            new_bresp = write_bresp_fault_value;
        new_bid = write_bid_fault ? write_bid_fault_value : write_id;

        if (!aresetn) begin
            cycle_count <= 64'd0;
            ar_write_pointer <= '0;
            ar_read_pointer <= '0;
            ar_fifo_count <= 0;
            read_active <= 1'b0;
            read_id <= '0;
            read_address <= '0;
            read_length <= 8'd0;
            read_size <= 3'd0;
            read_region <= REGION_NONE;
            read_contract_valid <= 1'b0;
            read_rresp_fault <= 1'b0;
            read_rresp_fault_beat <= 8'd0;
            read_rresp_fault_value <= AXI_RESP_SLVERR;
            read_rid_fault <= 1'b0;
            read_rid_fault_value <= '0;
            read_rlast_mode <= 2'd0;
            read_beat_index <= 9'd0;
            s_axi_rid <= '0;
            s_axi_rdata <= 128'd0;
            s_axi_rresp <= AXI_RESP_OKAY;
            s_axi_rlast <= 1'b0;
            s_axi_rvalid <= 1'b0;

            aw_write_pointer <= '0;
            aw_read_pointer <= '0;
            aw_fifo_count <= 0;
            w_write_pointer <= '0;
            w_read_pointer <= '0;
            w_fifo_count <= 0;
            write_active <= 1'b0;
            write_id <= '0;
            write_address <= '0;
            write_length <= 8'd0;
            write_size <= 3'd0;
            write_region <= REGION_NONE;
            write_contract_valid <= 1'b0;
            write_error_accumulated <= 1'b0;
            write_bresp_fault <= 1'b0;
            write_bresp_fault_value <= AXI_RESP_SLVERR;
            write_bid_fault <= 1'b0;
            write_bid_fault_value <= '0;
            write_beat_index <= 9'd0;
            b_write_pointer <= '0;
            b_read_pointer <= '0;
            b_fifo_count <= 0;
            s_axi_bid <= '0;
            s_axi_bresp <= AXI_RESP_OKAY;
            s_axi_bvalid <= 1'b0;

            read_count_o <= 64'd0;
            write_count_o <= 64'd0;
            model_read_count_o <= 64'd0;
            input_read_count_o <= 64'd0;
            scratch_read_count_o <= 64'd0;
            scratch_write_count_o <= 64'd0;
            ar_transaction_count_o <= 64'd0;
            aw_transaction_count_o <= 64'd0;
            r_beat_count_o <= 64'd0;
            w_beat_count_o <= 64'd0;
            b_response_count_o <= 64'd0;
            ar_requested_beat_count_o <= 64'd0;
            aw_requested_beat_count_o <= 64'd0;
            ar_backpressure_cycle_count_o <= 64'd0;
            aw_backpressure_cycle_count_o <= 64'd0;
            w_backpressure_cycle_count_o <= 64'd0;
            r_backpressure_cycle_count_o <= 64'd0;
            b_backpressure_cycle_count_o <= 64'd0;
            invalid_access_count_o <= 32'd0;
            protocol_error_count_o <= 32'd0;
            four_kib_error_count_o <= 32'd0;
            read_outstanding_count_o <= 32'd0;
            write_outstanding_count_o <= 32'd0;
            read_outstanding_high_water_o <= 32'd0;
            write_outstanding_high_water_o <= 32'd0;
            model_min_word <= 32'hffff_ffff;
            model_max_word <= 32'd0;
            input_min_word <= 32'hffff_ffff;
            input_max_word <= 32'd0;
            scratch_min_word <= 32'hffff_ffff;
            scratch_max_word <= 32'd0;
        end else begin
            cycle_count <= cycle_count + 1'b1;

            if (s_axi_arvalid && !s_axi_arready)
                ar_backpressure_cycle_count_o <=
                    ar_backpressure_cycle_count_o + 1'b1;
            if (s_axi_awvalid && !s_axi_awready)
                aw_backpressure_cycle_count_o <=
                    aw_backpressure_cycle_count_o + 1'b1;
            if (s_axi_wvalid && !s_axi_wready)
                w_backpressure_cycle_count_o <=
                    w_backpressure_cycle_count_o + 1'b1;
            if (s_axi_rvalid && !s_axi_rready)
                r_backpressure_cycle_count_o <=
                    r_backpressure_cycle_count_o + 1'b1;
            if (s_axi_bvalid && !s_axi_bready)
                b_backpressure_cycle_count_o <=
                    b_backpressure_cycle_count_o + 1'b1;

            if (ar_push) begin
                ar_id_fifo[ar_write_pointer] <= s_axi_arid;
                ar_addr_fifo[ar_write_pointer] <= s_axi_araddr;
                ar_len_fifo[ar_write_pointer] <= s_axi_arlen;
                ar_size_fifo[ar_write_pointer] <= s_axi_arsize;
                ar_region_fifo[ar_write_pointer] <= ar_decoded_region;
                ar_valid_fifo[ar_write_pointer] <= current_ar_valid;
                ar_rresp_fault_fifo[ar_write_pointer] <=
                    fault_rresp_enable_i &&
                    (fault_rresp_id_i == s_axi_arid);
                ar_rresp_beat_fifo[ar_write_pointer] <=
                    fault_rresp_beat_i;
                ar_rresp_value_fifo[ar_write_pointer] <=
                    fault_rresp_value_i;
                ar_rid_fault_fifo[ar_write_pointer] <=
                    fault_rid_enable_i;
                ar_rid_value_fifo[ar_write_pointer] <= fault_rid_value_i;
                ar_rlast_mode_fifo[ar_write_pointer] <= fault_rlast_mode_i;
                ar_write_pointer <= ar_pointer_next(ar_write_pointer);

                ar_transaction_count_o <= ar_transaction_count_o + 1'b1;
                ar_requested_beat_count_o <= ar_requested_beat_count_o +
                    {56'd0, s_axi_arlen} + 1'b1;
                if (!current_ar_valid) begin
                    invalid_access_count_o <=
                        invalid_access_count_o + 1'b1;
                    if (!ar_protocol_valid || !ar_alignment_valid)
                        protocol_error_count_o <=
                            protocol_error_count_o + 1'b1;
                    if (!ar_page_valid)
                        four_kib_error_count_o <=
                            four_kib_error_count_o + 1'b1;
                end
            end

            if (ar_pop) begin
                read_active <= 1'b1;
                read_id <= ar_id_fifo[ar_read_pointer];
                read_address <= ar_addr_fifo[ar_read_pointer];
                read_length <= ar_len_fifo[ar_read_pointer];
                read_size <= ar_size_fifo[ar_read_pointer];
                read_region <= ar_region_fifo[ar_read_pointer];
                read_contract_valid <= ar_valid_fifo[ar_read_pointer];
                read_rresp_fault <= ar_rresp_fault_fifo[ar_read_pointer];
                read_rresp_fault_beat <=
                    ar_rresp_beat_fifo[ar_read_pointer];
                read_rresp_fault_value <=
                    ar_rresp_value_fifo[ar_read_pointer];
                read_rid_fault <= ar_rid_fault_fifo[ar_read_pointer];
                read_rid_fault_value <=
                    ar_rid_value_fifo[ar_read_pointer];
                read_rlast_mode <= ar_rlast_mode_fifo[ar_read_pointer];
                read_beat_index <= 9'd0;
                ar_read_pointer <= ar_pointer_next(ar_read_pointer);
            end

            case ({ar_push, ar_pop})
                2'b10: ar_fifo_count <= ar_fifo_count + 1;
                2'b01: ar_fifo_count <= ar_fifo_count - 1;
                default: ar_fifo_count <= ar_fifo_count;
            endcase

            if (!s_axi_rvalid && read_active &&
                (!STALL_ENABLE || (cycle_count[2:0] != 3'd4))) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rid <= read_rid_fault ?
                    read_rid_fault_value : read_id;
                s_axi_rdata <= build_read_data(
                    current_read_beat_address,
                    read_size,
                    read_region,
                    read_contract_valid
                );
                if (!read_contract_valid)
                    s_axi_rresp <= AXI_RESP_SLVERR;
                else if (read_rresp_fault &&
                         (read_beat_index ==
                          {1'b0, read_rresp_fault_beat}))
                    s_axi_rresp <= read_rresp_fault_value;
                else
                    s_axi_rresp <= AXI_RESP_OKAY;

                case (read_rlast_mode)
                    2'd1:
                        s_axi_rlast <= (read_beat_index == 9'd0);
                    2'd2:
                        s_axi_rlast <= 1'b0;
                    default:
                        s_axi_rlast <=
                            (read_beat_index == {1'b0, read_length});
                endcase
            end

            if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
                r_beat_count_o <= r_beat_count_o + 1'b1;
                if (read_contract_valid) begin
                    read_count_o <= read_count_o + {32'd0, beat_words};
                    case (read_region)
                        REGION_MODEL: begin
                            model_read_count_o <=
                                model_read_count_o + {32'd0, beat_words};
                            sequential_word_index = address_word_index(
                                current_read_beat_address, REGION_MODEL
                            );
                            if (sequential_word_index < model_min_word)
                                model_min_word <= sequential_word_index;
                            if ((sequential_word_index + beat_words - 1'b1) >
                                model_max_word)
                                model_max_word <=
                                    sequential_word_index +
                                    beat_words - 1'b1;
                        end
                        REGION_INPUT: begin
                            input_read_count_o <=
                                input_read_count_o + {32'd0, beat_words};
                            sequential_word_index = address_word_index(
                                current_read_beat_address, REGION_INPUT
                            );
                            if (sequential_word_index < input_min_word)
                                input_min_word <= sequential_word_index;
                            if ((sequential_word_index + beat_words - 1'b1) >
                                input_max_word)
                                input_max_word <=
                                    sequential_word_index +
                                    beat_words - 1'b1;
                        end
                        REGION_SCRATCH: begin
                            scratch_read_count_o <=
                                scratch_read_count_o + {32'd0, beat_words};
                            sequential_word_index = address_word_index(
                                current_read_beat_address, REGION_SCRATCH
                            );
                            if (sequential_word_index < scratch_min_word)
                                scratch_min_word <= sequential_word_index;
                            if ((sequential_word_index + beat_words - 1'b1) >
                                scratch_max_word)
                                scratch_max_word <=
                                    sequential_word_index +
                                    beat_words - 1'b1;
                        end
                        default: begin
                        end
                    endcase
                end

                if (read_beat_index == {1'b0, read_length}) begin
                    read_active <= 1'b0;
                    read_beat_index <= 9'd0;
                end else begin
                    read_beat_index <= read_beat_index + 1'b1;
                end
            end

            if (aw_push) begin
                aw_id_fifo[aw_write_pointer] <= s_axi_awid;
                aw_addr_fifo[aw_write_pointer] <= s_axi_awaddr;
                aw_len_fifo[aw_write_pointer] <= s_axi_awlen;
                aw_size_fifo[aw_write_pointer] <= s_axi_awsize;
                aw_region_fifo[aw_write_pointer] <= aw_decoded_region;
                aw_valid_fifo[aw_write_pointer] <= current_aw_valid;
                aw_bresp_fault_fifo[aw_write_pointer] <=
                    fault_bresp_enable_i &&
                    (fault_bresp_id_i == s_axi_awid);
                aw_bresp_value_fifo[aw_write_pointer] <=
                    fault_bresp_value_i;
                aw_bid_fault_fifo[aw_write_pointer] <= fault_bid_enable_i;
                aw_bid_value_fifo[aw_write_pointer] <= fault_bid_value_i;
                aw_write_pointer <= aw_pointer_next(aw_write_pointer);

                aw_transaction_count_o <= aw_transaction_count_o + 1'b1;
                aw_requested_beat_count_o <= aw_requested_beat_count_o +
                    {56'd0, s_axi_awlen} + 1'b1;
                if (!current_aw_valid) begin
                    invalid_access_count_o <=
                        invalid_access_count_o + 1'b1;
                    if (!aw_protocol_valid || !aw_alignment_valid)
                        protocol_error_count_o <=
                            protocol_error_count_o + 1'b1;
                    if (!aw_page_valid)
                        four_kib_error_count_o <=
                            four_kib_error_count_o + 1'b1;
                end
            end

            if (aw_pop) begin
                write_active <= 1'b1;
                write_id <= aw_id_fifo[aw_read_pointer];
                write_address <= aw_addr_fifo[aw_read_pointer];
                write_length <= aw_len_fifo[aw_read_pointer];
                write_size <= aw_size_fifo[aw_read_pointer];
                write_region <= aw_region_fifo[aw_read_pointer];
                write_contract_valid <= aw_valid_fifo[aw_read_pointer];
                write_error_accumulated <= 1'b0;
                write_bresp_fault <=
                    aw_bresp_fault_fifo[aw_read_pointer];
                write_bresp_fault_value <=
                    aw_bresp_value_fifo[aw_read_pointer];
                write_bid_fault <= aw_bid_fault_fifo[aw_read_pointer];
                write_bid_fault_value <=
                    aw_bid_value_fifo[aw_read_pointer];
                write_beat_index <= 9'd0;
                aw_read_pointer <= aw_pointer_next(aw_read_pointer);
            end

            case ({aw_push, aw_pop})
                2'b10: aw_fifo_count <= aw_fifo_count + 1;
                2'b01: aw_fifo_count <= aw_fifo_count - 1;
                default: aw_fifo_count <= aw_fifo_count;
            endcase

            if (w_push) begin
                w_data_fifo[w_write_pointer] <= s_axi_wdata;
                w_strb_fifo[w_write_pointer] <= s_axi_wstrb;
                w_last_fifo[w_write_pointer] <= s_axi_wlast;
                w_write_pointer <= w_pointer_next(w_write_pointer);
                w_beat_count_o <= w_beat_count_o + 1'b1;
            end

            if (w_pop) begin
                if (!current_write_last_matches ||
                    !current_write_strobe_valid) begin
                    write_error_accumulated <= 1'b1;
                    protocol_error_count_o <=
                        protocol_error_count_o + 1'b1;
                end

                if (write_contract_valid && current_write_strobe_valid) begin
                    for (sequential_byte_index = 0;
                         sequential_byte_index < 16;
                         sequential_byte_index =
                             sequential_byte_index + 1) begin
                        if (w_strb_fifo[w_read_pointer]
                            [sequential_byte_index]) begin
                            sequential_byte_address =
                                current_write_bus_base +
                                64'(sequential_byte_index);
                            sequential_byte_region =
                                decode_region_64(sequential_byte_address);
                            sequential_word_index = address_word_index(
                                sequential_byte_address,
                                sequential_byte_region
                            );
                            if (sequential_byte_region == REGION_SCRATCH)
                                scratch_memory[sequential_word_index]
                                    [sequential_byte_address[1:0]*8 +: 8] <=
                                    w_data_fifo[w_read_pointer]
                                        [sequential_byte_index*8 +: 8];
                        end
                    end
                    if (w_strb_fifo[w_read_pointer] != 16'b0) begin
                        write_count_o <= write_count_o + 1'b1;
                        scratch_write_count_o <=
                            scratch_write_count_o + 1'b1;
                        sequential_word_index = address_word_index(
                            current_write_beat_address, REGION_SCRATCH
                        );
                        if (sequential_word_index < scratch_min_word)
                            scratch_min_word <= sequential_word_index;
                        if (sequential_word_index > scratch_max_word)
                            scratch_max_word <= sequential_word_index;
                    end
                end

                if (current_write_finishes) begin
                    write_active <= 1'b0;
                    write_beat_index <= 9'd0;
                end else begin
                    write_beat_index <= write_beat_index + 1'b1;
                end
                w_read_pointer <= w_pointer_next(w_read_pointer);
            end

            case ({w_push, w_pop})
                2'b10: w_fifo_count <= w_fifo_count + 1;
                2'b01: w_fifo_count <= w_fifo_count - 1;
                default: w_fifo_count <= w_fifo_count;
            endcase

            if (b_push) begin
                b_id_fifo[b_write_pointer] <= new_bid;
                b_resp_fifo[b_write_pointer] <= new_bresp;
                b_write_pointer <= aw_pointer_next(b_write_pointer);
            end

            if (b_pop_to_channel) begin
                s_axi_bid <= b_id_fifo[b_read_pointer];
                s_axi_bresp <= b_resp_fifo[b_read_pointer];
                s_axi_bvalid <= 1'b1;
                b_read_pointer <= aw_pointer_next(b_read_pointer);
            end

            if (write_response_handshake) begin
                s_axi_bvalid <= 1'b0;
                b_response_count_o <= b_response_count_o + 1'b1;
            end

            case ({b_push, b_pop_to_channel})
                2'b10: b_fifo_count <= b_fifo_count + 1;
                2'b01: b_fifo_count <= b_fifo_count - 1;
                default: b_fifo_count <= b_fifo_count;
            endcase

            case ({ar_push, read_terminal_handshake})
                2'b10: begin
                    read_outstanding_count_o <=
                        read_outstanding_count_o + 1'b1;
                    if ((read_outstanding_count_o + 1'b1) >
                        read_outstanding_high_water_o)
                        read_outstanding_high_water_o <=
                            read_outstanding_count_o + 1'b1;
                end
                2'b01:
                    read_outstanding_count_o <=
                        read_outstanding_count_o - 1'b1;
                default:
                    read_outstanding_count_o <=
                        read_outstanding_count_o;
            endcase

            case ({aw_push, write_response_handshake})
                2'b10: begin
                    write_outstanding_count_o <=
                        write_outstanding_count_o + 1'b1;
                    if ((write_outstanding_count_o + 1'b1) >
                        write_outstanding_high_water_o)
                        write_outstanding_high_water_o <=
                            write_outstanding_count_o + 1'b1;
                end
                2'b01:
                    write_outstanding_count_o <=
                        write_outstanding_count_o - 1'b1;
                default:
                    write_outstanding_count_o <=
                        write_outstanding_count_o;
            endcase
        end
    end

    initial begin
        if ((AXI_ADDR_WIDTH <= 0) || (AXI_ADDR_WIDTH > 64))
            $fatal(1, "AXI_ADDR_WIDTH must be in 1..64");
        if (AXI_ID_WIDTH <= 0)
            $fatal(1, "AXI_ID_WIDTH must be positive");
        if ((MAX_BURST_BEATS <= 0) || (MAX_BURST_BEATS > 256))
            $fatal(1, "MAX_BURST_BEATS must be in 1..256");
        if ((READ_QUEUE_DEPTH < 2) || (WRITE_QUEUE_DEPTH < 1) ||
            (W_QUEUE_DEPTH < MAX_BURST_BEATS))
            $fatal(1, "invalid AXI queue depth configuration");
    end

endmodule
