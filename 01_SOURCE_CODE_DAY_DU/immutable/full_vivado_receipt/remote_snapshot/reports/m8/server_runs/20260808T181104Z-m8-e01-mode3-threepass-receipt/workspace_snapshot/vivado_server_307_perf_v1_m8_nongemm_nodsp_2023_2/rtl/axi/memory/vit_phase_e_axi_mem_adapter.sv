`timescale 1ns/1ps

// Phase-E logical-memory to native 128-bit AXI4 adapter.
//
// The logical interface remains one 32-bit request/response at a time.  A
// proven-contiguous read miss may fill as many as 32 words through two
// same-ID, four-beat AXI bursts.  Later scalar requests hit the completed
// line.  Requests without an explicit safety hint use one narrow AXI beat.
// Writes also remain narrow, one-beat transactions so a logical write is not
// acknowledged before its BRESP has committed.
//
// Using one AXI ID is deliberate: AXI preserves response ordering between
// transactions with the same ID, so two outstanding bursts need descriptor
// accounting but no data reorder RAM.
module vit_phase_e_axi_mem_adapter #(
    parameter integer AXI_ADDR_WIDTH = 40,
    parameter integer AXI_ID_WIDTH = 1,
    parameter integer MAX_BURST_BEATS = 4,
    parameter integer MAX_LINE_WORDS = 32,
    parameter integer MAX_READ_OUTSTANDING = 2
) (
    input  logic                          aclk,
    input  logic                          aresetn,

    input  logic [63:0]                   scratch_base_i,
    input  logic [63:0]                   model_base_i,
    input  logic [63:0]                   input_base_i,
    input  logic [31:0]                   scratch_words_i,
    input  logic [31:0]                   model_words_i,
    input  logic [31:0]                   input_words_i,

    input  logic                          cache_invalidate_i,

    input  logic                          req_valid,
    output logic                          req_ready,
    input  logic                          req_write,
    input  logic [1:0]                    req_space,
    input  logic [31:0]                   req_word_address,
    input  logic [31:0]                   req_write_data,
    input  logic [3:0]                    req_write_strobe,
    input  logic                          req_read_ahead_safe,
    input  logic [5:0]                    req_contiguous_words,

    output logic                          rsp_valid,
    input  logic                          rsp_ready,
    output logic [31:0]                   rsp_read_data,
    output logic                          rsp_error,

    // Protocol and payload-profile events.  Every event is a one-cycle pulse;
    // prefetched_words_discarded_o is zero when no discard event occurs.
    output logic                          axi_r_protocol_error_o,
    output logic                          axi_b_protocol_error_o,
    output logic                          linefill_start_o,
    output logic                          linefill_hit_o,
    output logic                          full_r_beat_o,
    output logic                          narrow_r_beat_o,
    output logic                          four_k_split_o,
    output logic [5:0]                    prefetched_words_discarded_o,
    output logic [1:0]                    read_outstanding_o,

    output logic [AXI_ID_WIDTH-1:0]       m_axi_awid,
    output logic [AXI_ADDR_WIDTH-1:0]     m_axi_awaddr,
    output logic [7:0]                    m_axi_awlen,
    output logic [2:0]                    m_axi_awsize,
    output logic [1:0]                    m_axi_awburst,
    output logic                          m_axi_awlock,
    output logic [3:0]                    m_axi_awcache,
    output logic [2:0]                    m_axi_awprot,
    output logic [3:0]                    m_axi_awqos,
    output logic                          m_axi_awvalid,
    input  logic                          m_axi_awready,

    output logic [127:0]                  m_axi_wdata,
    output logic [15:0]                   m_axi_wstrb,
    output logic                          m_axi_wlast,
    output logic                          m_axi_wvalid,
    input  logic                          m_axi_wready,

    input  logic [AXI_ID_WIDTH-1:0]       m_axi_bid,
    input  logic [1:0]                    m_axi_bresp,
    input  logic                          m_axi_bvalid,
    output logic                          m_axi_bready,

    output logic [AXI_ID_WIDTH-1:0]       m_axi_arid,
    output logic [AXI_ADDR_WIDTH-1:0]     m_axi_araddr,
    output logic [7:0]                    m_axi_arlen,
    output logic [2:0]                    m_axi_arsize,
    output logic [1:0]                    m_axi_arburst,
    output logic                          m_axi_arlock,
    output logic [3:0]                    m_axi_arcache,
    output logic [2:0]                    m_axi_arprot,
    output logic [3:0]                    m_axi_arqos,
    output logic                          m_axi_arvalid,
    input  logic                          m_axi_arready,

    input  logic [AXI_ID_WIDTH-1:0]       m_axi_rid,
    input  logic [127:0]                  m_axi_rdata,
    input  logic [1:0]                    m_axi_rresp,
    input  logic                          m_axi_rlast,
    input  logic                          m_axi_rvalid,
    output logic                          m_axi_rready
);

    localparam logic [1:0] MEM_NONE    = 2'd0;
    localparam logic [1:0] MEM_SCRATCH = 2'd1;
    localparam logic [1:0] MEM_MODEL   = 2'd2;
    localparam logic [1:0] MEM_INPUT   = 2'd3;

    localparam logic [1:0] AXI_RESP_OKAY = 2'b00;
    localparam logic [1:0] AXI_BURST_INCR = 2'b01;
    localparam integer LINE_INDEX_WIDTH =
        (MAX_LINE_WORDS <= 1) ? 1 : $clog2(MAX_LINE_WORDS);

    typedef enum logic [3:0] {
        STATE_IDLE,
        STATE_SCALAR_READ_ADDRESS,
        STATE_SCALAR_READ_DATA,
        STATE_LINE_FILL,
        STATE_WRITE_ISSUE,
        STATE_WRITE_RESPONSE,
        STATE_LOCAL_RESPONSE,
        STATE_POISON_RESPONSE,
        STATE_POISON_FLUSH,
        STATE_POISON
    } state_t;

    state_t state;

    // The logical request and response channels are independently buffered.
    // The core still executes one logical request at a time, but upstream may
    // enqueue two requests while AXI or the response consumer is stalled.
    logic        req_fifo_write [0:1];
    logic [1:0]  req_fifo_space [0:1];
    logic [31:0] req_fifo_word_address [0:1];
    logic [31:0] req_fifo_write_data [0:1];
    logic [3:0]  req_fifo_write_strobe [0:1];
    logic        req_fifo_read_ahead_safe [0:1];
    logic [5:0]  req_fifo_contiguous_words [0:1];
    logic [63:0] req_fifo_selected_base [0:1];
    logic [31:0] req_fifo_selected_words [0:1];
    logic        req_fifo_space_valid [0:1];
    logic        req_fifo_read_pointer;
    logic        req_fifo_write_pointer;
    logic [1:0]  req_fifo_count;

    logic        core_req_write;
    logic [1:0]  core_req_space;
    logic [31:0] core_req_word_address;
    logic [31:0] core_req_write_data;
    logic [3:0]  core_req_write_strobe;
    logic        core_req_read_ahead_safe;
    logic [5:0]  core_req_contiguous_words;
    logic [63:0] core_req_selected_base;
    logic [31:0] core_req_selected_words;
    logic        core_req_space_valid;

    logic [31:0] rsp_fifo_data [0:1];
    logic        rsp_fifo_error [0:1];
    logic        rsp_fifo_read_pointer;
    logic        rsp_fifo_write_pointer;
    logic [1:0]  rsp_fifo_count;
    logic [31:0] core_rsp_data;
    logic        core_rsp_error;

    logic req_fifo_push;
    logic req_fifo_pop;
    logic req_core_start;
    logic req_queued_start;
    logic req_bypass_start;
    logic req_input_fire;
    logic req_poison_flush;
    logic rsp_fifo_pop;
    logic rsp_fifo_push;
    logic rsp_fifo_space_available;
    logic rsp_direct_valid;
    logic rsp_direct_consume;
    logic request_accept_enabled;
    logic [31:0] rsp_fifo_push_data;
    logic rsp_fifo_push_error;

    logic [63:0] live_selected_base;
    logic [31:0] live_selected_words;
    logic        live_space_valid;

    logic [63:0] selected_base;
    logic [31:0] selected_words;
    logic [64:0] byte_offset_wide;
    logic [64:0] physical_address_wide;
    logic        request_space_valid;
    logic        request_in_bounds;
    logic        request_base_aligned;
    logic        request_address_aligned;
    logic        request_address_fits_axi;
    logic        request_write_allowed;
    logic        request_is_valid;

    logic [32:0] request_words_remaining;
    logic [6:0] requested_contiguous_words;
    logic [6:0] clamped_contiguous_words;
    logic [4:0] planned_wide_beats;
    logic [8:0] first_page_beats;
    logic [8:0] second_page_beats;
    logic [2:0] planned_first_beats;
    logic [2:0] planned_second_beats;
    logic [4:0] planned_total_beats;
    logic [6:0] planned_total_words;
    logic [64:0] planned_second_address_wide;
    logic [64:0] planned_end_address_wide;
    logic        planned_address_fits_axi;
    logic        planned_four_k_split;
    logic        request_can_linefill;

    logic [31:0] line_data [0:MAX_LINE_WORDS-1];
    logic        line_valid;
    logic [1:0]  line_space;
    logic [63:0] line_base;
    logic [31:0] line_start_word;
    logic [6:0]  line_valid_words;
    logic [MAX_LINE_WORDS-1:0] line_consumed_bitmap;
    logic [6:0]  line_consumed_unique_words;
    logic [32:0] line_end_word;
    logic [31:0] line_hit_delta;
    logic [LINE_INDEX_WIDTH-1:0] line_hit_index;
    logic        request_hits_line;

    logic [AXI_ADDR_WIDTH-1:0] scalar_address_hold;
    logic [1:0] scalar_lane_hold;
    logic scalar_read_outstanding;

    logic [127:0] write_data_hold;
    logic [15:0] write_strobe_hold;
    logic aw_complete;
    logic w_complete;

    // Fixed two-entry burst-descriptor FIFO.  Entry zero is always consumed
    // before entry one because both transactions use the same AXI ID.
    logic [AXI_ADDR_WIDTH-1:0] fill_desc_addr [0:1];
    logic [2:0] fill_desc_beats [0:1];
    logic [1:0] fill_burst_count;
    logic [1:0] fill_ar_issue_index;
    logic [1:0] fill_ar_accepted_count;
    logic [1:0] fill_ar_accepted_effective;
    logic fill_ar_fire;
    logic [1:0] fill_r_burst_index;
    logic [1:0] fill_r_completed_count;
    logic [2:0] fill_r_beat_index;
    logic fill_error;
    logic fill_discard;
    logic [1:0] fill_space;
    logic [63:0] fill_base;
    logic [31:0] fill_start_word;
    logic [6:0] fill_valid_words;
    logic [31:0] fill_first_word;

    logic [2:0] current_fill_beats;
    logic fill_expected_last;
    logic fill_current_framing_error;
    logic [6:0] fill_current_word_base;
    logic [6:0] discarded_words;

    integer address_bit;
    integer consumed_bit;

    initial begin
        if ((AXI_ADDR_WIDTH < 12) || (AXI_ADDR_WIDTH > 64))
            $error("AXI_ADDR_WIDTH must be in the range 12..64");
        if (AXI_ID_WIDTH < 1)
            $error("AXI_ID_WIDTH must be at least one");
        if ((MAX_BURST_BEATS < 1) || (MAX_BURST_BEATS > 4))
            $error("MAX_BURST_BEATS must be in the range 1..4");
        if ((MAX_LINE_WORDS < 4) || (MAX_LINE_WORDS > 32) ||
            ((MAX_LINE_WORDS % 4) != 0))
            $error("MAX_LINE_WORDS must be a multiple of four in 4..32");
        if (MAX_READ_OUTSTANDING != 2)
            $error("This M5 slice requires MAX_READ_OUTSTANDING=2");
    end

    // The empty request FIFO is fall-through: an IDLE adapter may consume a
    // live handshake immediately.  Busy/full cases still use the physical
    // depth-2 FIFO and therefore retain captured base/size configuration.
    always_comb begin
        live_selected_base = 64'd0;
        live_selected_words = 32'd0;
        live_space_valid = 1'b1;
        case (req_space)
            MEM_SCRATCH: begin
                live_selected_base = scratch_base_i;
                live_selected_words = scratch_words_i;
            end
            MEM_MODEL: begin
                live_selected_base = model_base_i;
                live_selected_words = model_words_i;
            end
            MEM_INPUT: begin
                live_selected_base = input_base_i;
                live_selected_words = input_words_i;
            end
            default: begin
                live_space_valid = 1'b0;
            end
        endcase
    end

    assign core_req_write = req_bypass_start ?
        req_write : req_fifo_write[req_fifo_read_pointer];
    assign core_req_space = req_bypass_start ?
        req_space : req_fifo_space[req_fifo_read_pointer];
    assign core_req_word_address =
        req_bypass_start ? req_word_address :
        req_fifo_word_address[req_fifo_read_pointer];
    assign core_req_write_data =
        req_bypass_start ? req_write_data :
        req_fifo_write_data[req_fifo_read_pointer];
    assign core_req_write_strobe =
        req_bypass_start ? req_write_strobe :
        req_fifo_write_strobe[req_fifo_read_pointer];
    assign core_req_read_ahead_safe =
        req_bypass_start ? req_read_ahead_safe :
        req_fifo_read_ahead_safe[req_fifo_read_pointer];
    assign core_req_contiguous_words =
        req_bypass_start ? req_contiguous_words :
        req_fifo_contiguous_words[req_fifo_read_pointer];
    assign core_req_selected_base =
        req_bypass_start ? live_selected_base :
        req_fifo_selected_base[req_fifo_read_pointer];
    assign core_req_selected_words =
        req_bypass_start ? live_selected_words :
        req_fifo_selected_words[req_fifo_read_pointer];
    assign core_req_space_valid =
        req_bypass_start ? live_space_valid :
        req_fifo_space_valid[req_fifo_read_pointer];

    always_comb begin
        selected_base = core_req_selected_base;
        selected_words = core_req_selected_words;
        request_space_valid = core_req_space_valid;

        // Widen before shifting so offsets at or above 2^30 cannot wrap.
        byte_offset_wide = {33'b0, core_req_word_address} << 2;
        physical_address_wide = {1'b0, selected_base} + byte_offset_wide;
        request_in_bounds = (core_req_word_address < selected_words);
        request_base_aligned = (selected_base[1:0] == 2'b00);
        request_address_aligned = (physical_address_wide[1:0] == 2'b00);
        request_address_fits_axi = !physical_address_wide[64];
        for (address_bit = AXI_ADDR_WIDTH; address_bit < 64;
             address_bit = address_bit + 1)
            if (physical_address_wide[address_bit])
                request_address_fits_axi = 1'b0;
        request_write_allowed =
            !core_req_write || (core_req_space == MEM_SCRATCH);
        request_is_valid =
            request_space_valid && request_in_bounds &&
            request_base_aligned && request_address_aligned &&
            request_address_fits_axi && request_write_allowed;

        request_words_remaining =
            {1'b0, selected_words} - {1'b0, core_req_word_address};
        requested_contiguous_words =
            (core_req_contiguous_words == 0) ?
            7'd1 : {1'b0, core_req_contiguous_words};
        clamped_contiguous_words = requested_contiguous_words;
        if (clamped_contiguous_words > 7'(MAX_LINE_WORDS))
            clamped_contiguous_words = 7'(MAX_LINE_WORDS);
        if (request_words_remaining < {26'd0, clamped_contiguous_words})
            clamped_contiguous_words = request_words_remaining[6:0];

        // Full-width line fills use only complete 128-bit beats.  A head or
        // tail that is not naturally aligned falls back to an exact narrow
        // transfer rather than reading outside the configured logical region.
        planned_wide_beats = clamped_contiguous_words[6:2];
        first_page_beats = 9'(
            (13'd4096 - {1'b0, physical_address_wide[11:0]}) >> 4);

        planned_first_beats = 3'd0;
        if (planned_wide_beats != 0) begin
            if (planned_wide_beats > 5'(MAX_BURST_BEATS))
                planned_first_beats = 3'(MAX_BURST_BEATS);
            else
                planned_first_beats = planned_wide_beats[2:0];
            if (first_page_beats < {6'd0, planned_first_beats})
                planned_first_beats = first_page_beats[2:0];
        end

        planned_second_address_wide =
            physical_address_wide + ({62'd0, planned_first_beats} << 4);
        second_page_beats = 9'(
            (13'd4096 -
             {1'b0, planned_second_address_wide[11:0]}) >> 4);
        planned_second_beats = 3'd0;
        if (planned_wide_beats > {2'd0, planned_first_beats}) begin
            if ((planned_wide_beats - {2'd0, planned_first_beats}) >
                5'(MAX_BURST_BEATS))
                planned_second_beats = 3'(MAX_BURST_BEATS);
            else
                planned_second_beats =
                    planned_wide_beats[2:0] - planned_first_beats;
            // Descriptor one starts either within the same page or exactly at
            // the following page after descriptor zero was boundary-clamped.
            if (second_page_beats < {6'd0, planned_second_beats})
                planned_second_beats = second_page_beats[2:0];
        end

        planned_total_beats =
            {2'd0, planned_first_beats} + {2'd0, planned_second_beats};
        planned_total_words = {planned_total_beats, 2'b00};
        planned_end_address_wide = physical_address_wide;
        if (planned_total_beats != 0)
            planned_end_address_wide =
                physical_address_wide +
                ({60'd0, planned_total_beats} << 4) - 65'd1;
        planned_address_fits_axi = !planned_end_address_wide[64];
        for (address_bit = AXI_ADDR_WIDTH; address_bit < 64;
             address_bit = address_bit + 1)
            if (planned_end_address_wide[address_bit])
                planned_address_fits_axi = 1'b0;

        planned_four_k_split =
            (planned_wide_beats != 0) &&
            (first_page_beats < {4'd0,
             ((planned_wide_beats > 5'(MAX_BURST_BEATS)) ?
              5'(MAX_BURST_BEATS) : planned_wide_beats)});
        request_can_linefill =
            request_is_valid && !core_req_write &&
            core_req_read_ahead_safe &&
            (physical_address_wide[3:0] == 4'b0000) &&
            (planned_total_beats != 0) && planned_address_fits_axi;

        line_end_word =
            {1'b0, line_start_word} + {26'd0, line_valid_words};
        line_hit_delta = core_req_word_address - line_start_word;
        line_hit_index = line_hit_delta[LINE_INDEX_WIDTH-1:0];
        request_hits_line =
            request_is_valid && !core_req_write && line_valid &&
            !cache_invalidate_i && (core_req_space == line_space) &&
            (selected_base == line_base) &&
            ({1'b0, core_req_word_address} >=
             {1'b0, line_start_word}) &&
            ({1'b0, core_req_word_address} < line_end_word);

        current_fill_beats =
            (fill_r_burst_index == 0) ?
            fill_desc_beats[0] : fill_desc_beats[1];
        fill_expected_last =
            ((fill_r_beat_index + 3'd1) == current_fill_beats);
        fill_current_framing_error =
            (m_axi_rid != {AXI_ID_WIDTH{1'b0}}) ||
            (m_axi_rlast != fill_expected_last);
        fill_current_word_base =
            ((fill_r_burst_index == 0) ? 7'd0 :
             ({4'd0, fill_desc_beats[0]} << 2)) +
            ({4'd0, fill_r_beat_index} << 2);

        line_consumed_unique_words = 7'd0;
        for (consumed_bit = 0; consumed_bit < MAX_LINE_WORDS;
             consumed_bit = consumed_bit + 1)
            if ((consumed_bit < line_valid_words) &&
                line_consumed_bitmap[consumed_bit])
                line_consumed_unique_words =
                    line_consumed_unique_words + 7'd1;

        if (line_consumed_unique_words >= line_valid_words)
            discarded_words = 7'd0;
        else
            discarded_words =
                line_valid_words - line_consumed_unique_words;
    end

    // A completed core response falls through when the stored FIFO is empty.
    // Stored responses always win, so a new completion can never pass an
    // older token.  Under backpressure the completion stays in its response
    // state, or is enqueued exactly once behind an older stored response.
    assign rsp_direct_valid =
        (state == STATE_LOCAL_RESPONSE) ||
        (state == STATE_POISON_RESPONSE);
    assign rsp_valid = (rsp_fifo_count != 0) || rsp_direct_valid;
    assign rsp_read_data = (rsp_fifo_count != 0) ?
        rsp_fifo_data[rsp_fifo_read_pointer] :
        (rsp_direct_valid ? core_rsp_data : 32'd0);
    assign rsp_error = (rsp_fifo_count != 0) ?
        rsp_fifo_error[rsp_fifo_read_pointer] :
        (rsp_direct_valid ? core_rsp_error : 1'b0);
    assign rsp_fifo_pop = (rsp_fifo_count != 0) && rsp_ready;
    assign rsp_direct_consume =
        rsp_direct_valid && (rsp_fifo_count == 0) && rsp_ready;
    assign rsp_fifo_space_available =
        (rsp_fifo_count < 2) || rsp_fifo_pop;

    // Reserve one response slot before starting work.  An empty request FIFO
    // is fall-through; queued work retains strict head-before-live ordering.
    assign req_queued_start =
        (state == STATE_IDLE) && (req_fifo_count != 0) &&
        rsp_fifo_space_available;
    assign req_poison_flush =
        (state == STATE_POISON_FLUSH) && (req_fifo_count != 0) &&
        rsp_fifo_space_available;
    assign req_fifo_pop = req_queued_start || req_poison_flush;

    assign request_accept_enabled =
        (state != STATE_POISON_RESPONSE) &&
        (state != STATE_POISON_FLUSH) &&
        (state != STATE_POISON);
    assign req_ready = aresetn && request_accept_enabled &&
        ((req_fifo_count < 2) || req_fifo_pop);
    assign req_input_fire = req_valid && req_ready;
    assign req_bypass_start =
        (state == STATE_IDLE) && (req_fifo_count == 0) &&
        rsp_fifo_space_available && req_input_fire;
    assign req_core_start = req_queued_start || req_bypass_start;
    assign req_fifo_push = req_input_fire && !req_bypass_start;

    // Poison-flush tokens are always materialized in the FIFO.  A normal or
    // active-poison direct response is stored when backpressured or when an
    // older FIFO entry has priority.  An empty, ready channel consumes it
    // directly without adding a bubble.
    assign rsp_fifo_push = rsp_fifo_space_available &&
        (req_poison_flush ||
         (rsp_direct_valid &&
          ((rsp_fifo_count != 0) || !rsp_ready)));
    assign rsp_fifo_push_data =
        req_poison_flush ? 32'd0 : core_rsp_data;
    assign rsp_fifo_push_error =
        req_poison_flush ? 1'b1 : core_rsp_error;

    assign m_axi_awid = '0;
    assign m_axi_awaddr = scalar_address_hold;
    assign m_axi_awlen = 8'd0;
    assign m_axi_awsize = 3'b010;
    assign m_axi_awburst = AXI_BURST_INCR;
    assign m_axi_awlock = 1'b0;
    assign m_axi_awcache = 4'b0011;
    assign m_axi_awprot = 3'b000;
    assign m_axi_awqos = 4'b0000;
    assign m_axi_awvalid =
        (state == STATE_WRITE_ISSUE) && !aw_complete;

    assign m_axi_wdata = write_data_hold;
    assign m_axi_wstrb = write_strobe_hold;
    assign m_axi_wlast = 1'b1;
    assign m_axi_wvalid =
        (state == STATE_WRITE_ISSUE) && !w_complete;
    assign m_axi_bready = (state == STATE_WRITE_RESPONSE);

    assign m_axi_arid = '0;
    always_comb begin
        m_axi_araddr = scalar_address_hold;
        m_axi_arlen = 8'd0;
        m_axi_arsize = 3'b010;
        if (state == STATE_LINE_FILL) begin
            m_axi_araddr =
                (fill_ar_issue_index == 0) ?
                fill_desc_addr[0] : fill_desc_addr[1];
            m_axi_arlen =
                {5'd0, ((fill_ar_issue_index == 0) ?
                 fill_desc_beats[0] : fill_desc_beats[1])} - 8'd1;
            m_axi_arsize = 3'b100;
        end
    end
    assign m_axi_arburst = AXI_BURST_INCR;
    assign m_axi_arlock = 1'b0;
    assign m_axi_arcache = 4'b0011;
    assign m_axi_arprot = 3'b000;
    assign m_axi_arqos = 4'b0000;
    assign m_axi_arvalid =
        (state == STATE_SCALAR_READ_ADDRESS) ||
        ((state == STATE_LINE_FILL) &&
         (fill_ar_issue_index < fill_burst_count));
    assign fill_ar_fire =
        (state == STATE_LINE_FILL) && m_axi_arvalid && m_axi_arready;
    assign fill_ar_accepted_effective =
        fill_ar_accepted_count + {1'b0, fill_ar_fire};

    assign m_axi_rready =
        (state == STATE_SCALAR_READ_DATA) ||
        (state == STATE_LINE_FILL);

    always_comb begin
        if (state == STATE_LINE_FILL)
            read_outstanding_o =
                fill_ar_accepted_count - fill_r_completed_count;
        else
            read_outstanding_o = {1'b0, scalar_read_outstanding};
    end

    always_ff @(posedge aclk) begin : adapter_sequential
        integer line_word;
        logic [1:0] request_lane;
        logic final_fill_error;
        if (!aresetn) begin
            state <= STATE_IDLE;
            req_fifo_read_pointer <= 1'b0;
            req_fifo_write_pointer <= 1'b0;
            req_fifo_count <= 2'd0;
            req_fifo_write[0] <= 1'b0;
            req_fifo_write[1] <= 1'b0;
            req_fifo_space[0] <= MEM_NONE;
            req_fifo_space[1] <= MEM_NONE;
            req_fifo_word_address[0] <= 32'd0;
            req_fifo_word_address[1] <= 32'd0;
            req_fifo_write_data[0] <= 32'd0;
            req_fifo_write_data[1] <= 32'd0;
            req_fifo_write_strobe[0] <= 4'd0;
            req_fifo_write_strobe[1] <= 4'd0;
            req_fifo_read_ahead_safe[0] <= 1'b0;
            req_fifo_read_ahead_safe[1] <= 1'b0;
            req_fifo_contiguous_words[0] <= 6'd0;
            req_fifo_contiguous_words[1] <= 6'd0;
            req_fifo_selected_base[0] <= 64'd0;
            req_fifo_selected_base[1] <= 64'd0;
            req_fifo_selected_words[0] <= 32'd0;
            req_fifo_selected_words[1] <= 32'd0;
            req_fifo_space_valid[0] <= 1'b0;
            req_fifo_space_valid[1] <= 1'b0;
            rsp_fifo_read_pointer <= 1'b0;
            rsp_fifo_write_pointer <= 1'b0;
            rsp_fifo_count <= 2'd0;
            rsp_fifo_data[0] <= 32'd0;
            rsp_fifo_data[1] <= 32'd0;
            rsp_fifo_error[0] <= 1'b0;
            rsp_fifo_error[1] <= 1'b0;
            core_rsp_data <= 32'd0;
            core_rsp_error <= 1'b0;
            scalar_address_hold <= '0;
            scalar_lane_hold <= 2'd0;
            scalar_read_outstanding <= 1'b0;
            write_data_hold <= 128'd0;
            write_strobe_hold <= 16'd0;
            aw_complete <= 1'b0;
            w_complete <= 1'b0;
            line_valid <= 1'b0;
            line_space <= MEM_NONE;
            line_base <= 64'd0;
            line_start_word <= 32'd0;
            line_valid_words <= 7'd0;
            line_consumed_bitmap <= '0;
            fill_desc_addr[0] <= '0;
            fill_desc_addr[1] <= '0;
            fill_desc_beats[0] <= 3'd1;
            fill_desc_beats[1] <= 3'd1;
            fill_burst_count <= 2'd0;
            fill_ar_issue_index <= 2'd0;
            fill_ar_accepted_count <= 2'd0;
            fill_r_burst_index <= 2'd0;
            fill_r_completed_count <= 2'd0;
            fill_r_beat_index <= 3'd0;
            fill_error <= 1'b0;
            fill_discard <= 1'b0;
            fill_space <= MEM_NONE;
            fill_base <= 64'd0;
            fill_start_word <= 32'd0;
            fill_valid_words <= 7'd0;
            fill_first_word <= 32'd0;
            axi_r_protocol_error_o <= 1'b0;
            axi_b_protocol_error_o <= 1'b0;
            linefill_start_o <= 1'b0;
            linefill_hit_o <= 1'b0;
            full_r_beat_o <= 1'b0;
            narrow_r_beat_o <= 1'b0;
            four_k_split_o <= 1'b0;
            prefetched_words_discarded_o <= 6'd0;
            for (line_word = 0; line_word < MAX_LINE_WORDS;
                 line_word = line_word + 1)
                line_data[line_word] <= 32'd0;
        end else begin
            axi_r_protocol_error_o <= 1'b0;
            axi_b_protocol_error_o <= 1'b0;
            linefill_start_o <= 1'b0;
            linefill_hit_o <= 1'b0;
            full_r_beat_o <= 1'b0;
            narrow_r_beat_o <= 1'b0;
            four_k_split_o <= 1'b0;
            prefetched_words_discarded_o <= 6'd0;

            if (req_fifo_push) begin
                req_fifo_write[req_fifo_write_pointer] <= req_write;
                req_fifo_space[req_fifo_write_pointer] <= req_space;
                req_fifo_word_address[req_fifo_write_pointer] <=
                    req_word_address;
                req_fifo_write_data[req_fifo_write_pointer] <=
                    req_write_data;
                req_fifo_write_strobe[req_fifo_write_pointer] <=
                    req_write_strobe;
                req_fifo_read_ahead_safe[req_fifo_write_pointer] <=
                    req_read_ahead_safe;
                req_fifo_contiguous_words[req_fifo_write_pointer] <=
                    req_contiguous_words;
                req_fifo_selected_base[req_fifo_write_pointer] <= 64'd0;
                req_fifo_selected_words[req_fifo_write_pointer] <= 32'd0;
                req_fifo_space_valid[req_fifo_write_pointer] <= 1'b1;
                case (req_space)
                    MEM_SCRATCH: begin
                        req_fifo_selected_base[req_fifo_write_pointer] <=
                            scratch_base_i;
                        req_fifo_selected_words[req_fifo_write_pointer] <=
                            scratch_words_i;
                    end
                    MEM_MODEL: begin
                        req_fifo_selected_base[req_fifo_write_pointer] <=
                            model_base_i;
                        req_fifo_selected_words[req_fifo_write_pointer] <=
                            model_words_i;
                    end
                    MEM_INPUT: begin
                        req_fifo_selected_base[req_fifo_write_pointer] <=
                            input_base_i;
                        req_fifo_selected_words[req_fifo_write_pointer] <=
                            input_words_i;
                    end
                    default: begin
                        req_fifo_space_valid[req_fifo_write_pointer] <=
                            1'b0;
                    end
                endcase
                req_fifo_write_pointer <= ~req_fifo_write_pointer;
            end
            if (req_fifo_pop)
                req_fifo_read_pointer <= ~req_fifo_read_pointer;
            case ({req_fifo_push, req_fifo_pop})
                2'b10: req_fifo_count <= req_fifo_count + 2'd1;
                2'b01: req_fifo_count <= req_fifo_count - 2'd1;
                default: req_fifo_count <= req_fifo_count;
            endcase

            if (rsp_fifo_push) begin
                rsp_fifo_data[rsp_fifo_write_pointer] <=
                    rsp_fifo_push_data;
                rsp_fifo_error[rsp_fifo_write_pointer] <=
                    rsp_fifo_push_error;
                rsp_fifo_write_pointer <= ~rsp_fifo_write_pointer;
            end
            if (rsp_fifo_pop)
                rsp_fifo_read_pointer <= ~rsp_fifo_read_pointer;
            case ({rsp_fifo_push, rsp_fifo_pop})
                2'b10: rsp_fifo_count <= rsp_fifo_count + 2'd1;
                2'b01: rsp_fifo_count <= rsp_fifo_count - 2'd1;
                default: rsp_fifo_count <= rsp_fifo_count;
            endcase

            if (cache_invalidate_i && line_valid) begin
                line_valid <= 1'b0;
                line_consumed_bitmap <= '0;
                prefetched_words_discarded_o <=
                    (discarded_words > 7'd63) ?
                    6'h3f : discarded_words[5:0];
            end
            if (cache_invalidate_i && (state == STATE_LINE_FILL)) begin
                fill_discard <= 1'b1;
                fill_error <= 1'b1;
            end

            case (state)
                STATE_IDLE: begin
                    scalar_read_outstanding <= 1'b0;
                    if (req_core_start) begin
                        core_rsp_data <= 32'd0;
                        core_rsp_error <= 1'b0;
                        request_lane = physical_address_wide[3:2];
                        scalar_address_hold <=
                            physical_address_wide[AXI_ADDR_WIDTH-1:0];
                        scalar_lane_hold <= request_lane;

                        if (!request_is_valid) begin
                            core_rsp_error <= 1'b1;
                            state <= STATE_LOCAL_RESPONSE;
                        end else if (request_hits_line) begin
                            core_rsp_data <= line_data[line_hit_index];
                            linefill_hit_o <= 1'b1;
                            line_consumed_bitmap[line_hit_index] <= 1'b1;
                            state <= STATE_LOCAL_RESPONSE;
                        end else if (!core_req_write &&
                                     request_can_linefill) begin
                            if (line_valid) begin
                                prefetched_words_discarded_o <=
                                    (discarded_words > 7'd63) ?
                                    6'h3f : discarded_words[5:0];
                            end
                            line_valid <= 1'b0;
                            line_consumed_bitmap <= '0;
                            linefill_start_o <= 1'b1;
                            four_k_split_o <= planned_four_k_split;
                            fill_desc_addr[0] <=
                                physical_address_wide[
                                    AXI_ADDR_WIDTH-1:0
                                ];
                            fill_desc_beats[0] <= planned_first_beats;
                            fill_desc_addr[1] <=
                                planned_second_address_wide[
                                    AXI_ADDR_WIDTH-1:0
                                ];
                            fill_desc_beats[1] <= planned_second_beats;
                            fill_burst_count <=
                                (planned_second_beats != 0) ? 2'd2 : 2'd1;
                            fill_ar_issue_index <= 2'd0;
                            fill_ar_accepted_count <= 2'd0;
                            fill_r_burst_index <= 2'd0;
                            fill_r_completed_count <= 2'd0;
                            fill_r_beat_index <= 3'd0;
                            fill_error <= 1'b0;
                            fill_discard <= 1'b0;
                            fill_space <= core_req_space;
                            fill_base <= selected_base;
                            fill_start_word <= core_req_word_address;
                            fill_valid_words <= planned_total_words;
                            fill_first_word <= 32'd0;
                            state <= STATE_LINE_FILL;
                        end else if (core_req_write) begin
                            // Narrow transfer: AXI address selects the active
                            // 32-bit lane on the native 128-bit bus.
                            write_data_hold <=
                                {96'd0, core_req_write_data} <<
                                (request_lane * 32);
                            write_strobe_hold <=
                                {12'd0, core_req_write_strobe} <<
                                (request_lane * 4);
                            aw_complete <= 1'b0;
                            w_complete <= 1'b0;
                            if (line_valid) begin
                                line_valid <= 1'b0;
                                line_consumed_bitmap <= '0;
                                prefetched_words_discarded_o <=
                                    (discarded_words > 7'd63) ?
                                    6'h3f : discarded_words[5:0];
                            end
                            state <= STATE_WRITE_ISSUE;
                        end else begin
                            state <= STATE_SCALAR_READ_ADDRESS;
                        end
                    end
                end

                STATE_SCALAR_READ_ADDRESS: begin
                    if (m_axi_arvalid && m_axi_arready) begin
                        scalar_read_outstanding <= 1'b1;
                        state <= STATE_SCALAR_READ_DATA;
                    end
                end

                STATE_SCALAR_READ_DATA: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        narrow_r_beat_o <= 1'b1;
                        scalar_read_outstanding <= !m_axi_rlast;
                        core_rsp_data <=
                            m_axi_rdata[scalar_lane_hold*32 +: 32];
                        if ((m_axi_rid != {AXI_ID_WIDTH{1'b0}}) ||
                            !m_axi_rlast) begin
                            axi_r_protocol_error_o <= 1'b1;
                            scalar_read_outstanding <= 1'b1;
                            core_rsp_data <= 32'd0;
                            core_rsp_error <= 1'b1;
                            state <= STATE_POISON_RESPONSE;
                        end else begin
                            core_rsp_error <=
                                (m_axi_rresp != AXI_RESP_OKAY);
                            if (m_axi_rresp != AXI_RESP_OKAY)
                                axi_r_protocol_error_o <= 1'b1;
                            state <= STATE_LOCAL_RESPONSE;
                        end
                    end
                end

                STATE_LINE_FILL: begin
                    if (m_axi_arvalid && m_axi_arready) begin
                        fill_ar_issue_index <= fill_ar_issue_index + 2'd1;
                        fill_ar_accepted_count <=
                            fill_ar_accepted_count + 2'd1;
                    end

                    if (m_axi_rvalid && m_axi_rready) begin
                        full_r_beat_o <= 1'b1;
                        final_fill_error =
                            fill_error ||
                            (m_axi_rresp != AXI_RESP_OKAY) ||
                            fill_discard || cache_invalidate_i;
                        if (fill_current_framing_error) begin
                            fill_error <= 1'b1;
                            axi_r_protocol_error_o <= 1'b1;
                            line_valid <= 1'b0;
                            line_consumed_bitmap <= '0;
                            core_rsp_data <= 32'd0;
                            core_rsp_error <= 1'b1;
                            prefetched_words_discarded_o <=
                                (fill_valid_words > 7'd63) ?
                                6'h3f : fill_valid_words[5:0];
                            state <= STATE_POISON_RESPONSE;
                        end else begin
                            if (m_axi_rresp != AXI_RESP_OKAY) begin
                                fill_error <= 1'b1;
                                axi_r_protocol_error_o <= 1'b1;
                            end
                            line_word = {25'd0, fill_current_word_base};
                            if ((line_word + 0) < MAX_LINE_WORDS)
                                line_data[line_word + 0] <=
                                    m_axi_rdata[31:0];
                            if ((line_word + 1) < MAX_LINE_WORDS)
                                line_data[line_word + 1] <=
                                    m_axi_rdata[63:32];
                            if ((line_word + 2) < MAX_LINE_WORDS)
                                line_data[line_word + 2] <=
                                    m_axi_rdata[95:64];
                            if ((line_word + 3) < MAX_LINE_WORDS)
                                line_data[line_word + 3] <=
                                    m_axi_rdata[127:96];
                            if ((fill_r_burst_index == 0) &&
                                (fill_r_beat_index == 0))
                                fill_first_word <= m_axi_rdata[31:0];

                            if (m_axi_rlast) begin
                                fill_r_completed_count <=
                                    fill_r_completed_count + 2'd1;
                                fill_r_beat_index <= 3'd0;
                                if ((fill_r_burst_index + 2'd1) >=
                                    fill_burst_count) begin
                                    // Do not expose the logical response
                                    // until every planned AR was accepted and
                                    // every planned burst was retired.
                                    if ((fill_ar_accepted_effective !=
                                         fill_burst_count) ||
                                        ((fill_r_completed_count + 2'd1) !=
                                         fill_burst_count)) begin
                                        axi_r_protocol_error_o <= 1'b1;
                                        core_rsp_data <= 32'd0;
                                        core_rsp_error <= 1'b1;
                                        line_valid <= 1'b0;
                                        line_consumed_bitmap <= '0;
                                        prefetched_words_discarded_o <=
                                            (fill_valid_words > 7'd63) ?
                                            6'h3f : fill_valid_words[5:0];
                                        state <= STATE_POISON_RESPONSE;
                                    end else begin
                                        core_rsp_error <= final_fill_error;
                                        core_rsp_data <=
                                            ((fill_r_burst_index == 0) &&
                                             (fill_r_beat_index == 0)) ?
                                            m_axi_rdata[31:0] :
                                            fill_first_word;
                                        if (!final_fill_error) begin
                                            line_valid <= 1'b1;
                                            line_space <= fill_space;
                                            line_base <= fill_base;
                                            line_start_word <= fill_start_word;
                                            line_valid_words <=
                                                fill_valid_words;
                                            line_consumed_bitmap <=
                                                {{(MAX_LINE_WORDS-1){1'b0}},
                                                 1'b1};
                                        end else begin
                                            line_valid <= 1'b0;
                                            line_consumed_bitmap <= '0;
                                            prefetched_words_discarded_o <=
                                                (fill_valid_words > 7'd63) ?
                                                6'h3f :
                                                fill_valid_words[5:0];
                                        end
                                        state <= STATE_LOCAL_RESPONSE;
                                    end
                                end else begin
                                    fill_r_burst_index <=
                                        fill_r_burst_index + 2'd1;
                                end
                            end else begin
                                fill_r_beat_index <=
                                    fill_r_beat_index + 3'd1;
                            end
                        end
                    end
                end

                STATE_WRITE_ISSUE: begin
                    if (m_axi_awvalid && m_axi_awready)
                        aw_complete <= 1'b1;
                    if (m_axi_wvalid && m_axi_wready)
                        w_complete <= 1'b1;
                    if ((aw_complete ||
                         (m_axi_awvalid && m_axi_awready)) &&
                        (w_complete ||
                         (m_axi_wvalid && m_axi_wready)))
                        state <= STATE_WRITE_RESPONSE;
                end

                STATE_WRITE_RESPONSE: begin
                    if (m_axi_bvalid && m_axi_bready) begin
                        core_rsp_data <= 32'd0;
                        core_rsp_error <=
                            (m_axi_bresp != AXI_RESP_OKAY) ||
                            (m_axi_bid != {AXI_ID_WIDTH{1'b0}});
                        if ((m_axi_bresp != AXI_RESP_OKAY) ||
                            (m_axi_bid != {AXI_ID_WIDTH{1'b0}}))
                            axi_b_protocol_error_o <= 1'b1;
                        state <= STATE_LOCAL_RESPONSE;
                    end
                end

                STATE_LOCAL_RESPONSE: begin
                    if (rsp_fifo_push || rsp_direct_consume)
                        state <= STATE_IDLE;
                end

                // A framing violation destroys transaction-boundary
                // certainty.  Return one bounded error response, then reject
                // all new requests until reset rather than risking silent
                // beat re-attribution or waiting forever for a missing RLAST.
                STATE_POISON_RESPONSE: begin
                    if (rsp_fifo_push || rsp_direct_consume)
                        state <= STATE_POISON_FLUSH;
                end

                // Every logical request accepted before the framing fault is
                // still owed one ordered response.  Convert queued requests
                // to error tokens, respecting response-FIFO backpressure.
                STATE_POISON_FLUSH: begin
                    line_valid <= 1'b0;
                    line_consumed_bitmap <= '0;
                    if (req_fifo_count == 0)
                        state <= STATE_POISON;
                end

                STATE_POISON: begin
                    line_valid <= 1'b0;
                    line_consumed_bitmap <= '0;
                end

                default: begin
                    core_rsp_data <= 32'd0;
                    core_rsp_error <= 1'b1;
                    state <= STATE_POISON_RESPONSE;
                    line_valid <= 1'b0;
                    line_consumed_bitmap <= '0;
                    scalar_read_outstanding <= 1'b0;
                    aw_complete <= 1'b0;
                    w_complete <= 1'b0;
                end
            endcase
        end
    end

endmodule
