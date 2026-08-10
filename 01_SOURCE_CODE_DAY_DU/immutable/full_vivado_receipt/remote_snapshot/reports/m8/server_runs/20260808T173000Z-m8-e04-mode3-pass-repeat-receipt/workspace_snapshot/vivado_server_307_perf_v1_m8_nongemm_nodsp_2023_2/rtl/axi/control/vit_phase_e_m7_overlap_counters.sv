`timescale 1ns/1ps

// Append-only M7 exact-stage/ownership profile bank.
//
// The frozen v1.2 global counters and the M5 native-AXI bank are left intact.
// This independent bank starts at AXI-Lite 0x810 and publishes one atomic,
// terminal-cycle-inclusive snapshot per accepted job.
(* use_dsp = "no" *)
module vit_phase_e_m7_overlap_counters #(
    parameter integer ARRAY_ROWS = 8,
    parameter integer ARRAY_COLS = 2,
    parameter integer PE_LANES = 16,
    parameter integer STREAMS = 16,
    parameter integer OPERAND_BANKS = 2,
    parameter integer RESULT_FIFO_DEPTH = 0,
    parameter integer GENERATION_BITS = 0
) (
    input  logic clk,
    input  logic rst,
    input  logic start_accept_i,
    input  logic done_i,
    input  vit_phase_e_pkg::phase_e_m7_profile_events_t events_i,

    output logic running_o,
    output logic snapshot_valid_o,
    output logic [31:0] capability_o,
    output logic [31:0] status_o,
    output logic [63:0] overflow_o,
    output logic [31:0] error_status_o,
    output logic [31:0] geometry_o,
    output logic [31:0] buffer_config_o,
    output logic [31:0] numeric_config_o,
    output logic [vit_phase_e_pkg::PHASE_E_M7_COUNTER_COUNT*64-1:0]
                 counters_flat_o
);

    import vit_phase_e_pkg::*;

    localparam integer COUNTER_COUNT = PHASE_E_M7_COUNTER_COUNT;

    localparam integer CTR_TERM_ACCEPTS       = 0;
    localparam integer CTR_DISABLED_ACCEPTS   = 1;
    localparam integer CTR_DOT_STARTS         = 2;
    localparam integer CTR_RESULT_VECTORS     = 3;
    localparam integer CTR_FEEDER_STALL       = 4;
    localparam integer CTR_RESULT_BP          = 5;
    localparam integer CTR_LOAD_ACTIVE        = 6;
    localparam integer CTR_COMPUTE_ACTIVE     = 7;
    localparam integer CTR_STORE_ACTIVE       = 8;
    localparam integer CTR_STAGE_UNION        = 9;
    localparam integer CTR_LOAD_COMPUTE       = 10;
    localparam integer CTR_COMPUTE_STORE      = 11;
    localparam integer CTR_LOAD_STORE         = 12;
    localparam integer CTR_THREE_WAY          = 13;
    localparam integer CTR_BANK_COMMITS       = 14;
    localparam integer CTR_BANK_CLAIMS        = 15;
    localparam integer CTR_BANK_RELEASES      = 16;
    localparam integer CTR_BANK_EMPTY_WAIT    = 17;
    localparam integer CTR_BANK_FULL_WAIT     = 18;
    localparam integer CTR_BANK_MAX_OCC       = 19;
    localparam integer CTR_FIFO_ENQUEUE       = 20;
    localparam integer CTR_FIFO_DEQUEUE       = 21;
    localparam integer CTR_FIFO_MAX_OCC       = 22;

    logic [63:0] live [0:COUNTER_COUNT-1];
    logic [63:0] published [0:COUNTER_COUNT-1];
    logic [63:0] delta [0:COUNTER_COUNT-1];
    logic [64:0] sum [0:COUNTER_COUNT-1];
    logic [63:0] next_value [0:COUNTER_COUNT-1];
    logic [COUNTER_COUNT-1:0] overflow_live;
    logic [COUNTER_COUNT-1:0] overflow_next;
    logic [COUNTER_COUNT-1:0] overflow_published;
    logic [19:0] error_live;
    logic [19:0] error_next;
    logic [19:0] error_published;
    logic [1:0] claim_seen_live;
    logic [1:0] claim_seen_next;
    logic [1:0] claim_seen_published;
    logic stage_union;
    logic load_compute_overlap;
    logic compute_store_overlap;
    logic load_store_overlap;
    logic three_way_overlap;
    integer comb_index;
    integer sequential_index;
    integer output_index;

    initial begin
        if (COUNTER_COUNT != 23)
            $fatal(1, "M7 ABI requires exactly 23 counters");
        if ((ARRAY_ROWS <= 0) || (ARRAY_ROWS > 255) ||
            (ARRAY_COLS <= 0) || (ARRAY_COLS > 255) ||
            (PE_LANES <= 0) || (PE_LANES > 255) ||
            (STREAMS <= 0) || (STREAMS > 255))
            $fatal(1, "M7 geometry fields must fit one byte");
        if ((OPERAND_BANKS <= 0) || (OPERAND_BANKS > 255) ||
            (RESULT_FIFO_DEPTH < 0) || (RESULT_FIFO_DEPTH > 255) ||
            (GENERATION_BITS < 0) || (GENERATION_BITS > 255))
            $fatal(1, "M7 buffer configuration fields must fit one byte");
    end

    // Schema 1, 23 x 64-bit counters, atomic snapshot, sticky overflow,
    // typed errors, exact stages, term deltas and two-bank operand ownership.
    // Bits 22/23 advertise reachable result-FIFO/generation hardware only
    // when their configured widths are non-zero.
    assign capability_o =
        32'h013f_0817 |
        ((RESULT_FIFO_DEPTH > 0) ? 32'h0040_0000 : 32'd0) |
        ((GENERATION_BITS > 0) ? 32'h0080_0000 : 32'd0);
    assign geometry_o = {
        8'(STREAMS), 8'(PE_LANES), 8'(ARRAY_COLS), 8'(ARRAY_ROWS)
    };
    assign buffer_config_o = {
        8'd0, 8'(GENERATION_BITS), 8'(RESULT_FIFO_DEPTH), 8'(OPERAND_BANKS)
    };
    // [7:0] accumulator width=93, [15:8] signed LSB=-48, [23:16]
    // Kmax/16=192, bits 24..26 gradual-subnormal/FP32-output/final-RNE.
    assign numeric_config_o = 32'h07c0_d05d;

    assign stage_union =
        events_i.m7_panel_load_active ||
        events_i.m7_panel_compute_active ||
        events_i.m7_panel_store_active;
    assign load_compute_overlap =
        events_i.m7_panel_load_active &&
        events_i.m7_panel_compute_active;
    assign compute_store_overlap =
        events_i.m7_panel_compute_active &&
        events_i.m7_panel_store_active;
    assign load_store_overlap =
        events_i.m7_panel_load_active &&
        events_i.m7_panel_store_active;
    assign three_way_overlap =
        events_i.m7_panel_load_active &&
        events_i.m7_panel_compute_active &&
        events_i.m7_panel_store_active;

    always_comb begin
        for (comb_index = 0; comb_index < COUNTER_COUNT;
             comb_index = comb_index + 1)
            delta[comb_index] = 64'd0;

        delta[CTR_TERM_ACCEPTS] =
            {59'd0, events_i.m7_fp16_term_accept_delta};
        delta[CTR_DISABLED_ACCEPTS] =
            {59'd0, events_i.m7_fp16_disabled_term_delta};
        delta[CTR_DOT_STARTS] =
            events_i.m7_fp16_dot_start ? 64'd1 : 64'd0;
        delta[CTR_RESULT_VECTORS] =
            events_i.m7_fp16_result_vector ? 64'd1 : 64'd0;
        delta[CTR_FEEDER_STALL] =
            (events_i.m7_fp16_input_wait ||
             events_i.m7_fp16_term_stall) ? 64'd1 : 64'd0;
        delta[CTR_RESULT_BP] =
            events_i.m7_fp16_result_backpressure ? 64'd1 : 64'd0;
        delta[CTR_LOAD_ACTIVE] =
            events_i.m7_panel_load_active ? 64'd1 : 64'd0;
        delta[CTR_COMPUTE_ACTIVE] =
            events_i.m7_panel_compute_active ? 64'd1 : 64'd0;
        delta[CTR_STORE_ACTIVE] =
            events_i.m7_panel_store_active ? 64'd1 : 64'd0;
        delta[CTR_STAGE_UNION] = stage_union ? 64'd1 : 64'd0;
        delta[CTR_LOAD_COMPUTE] =
            load_compute_overlap ? 64'd1 : 64'd0;
        delta[CTR_COMPUTE_STORE] =
            compute_store_overlap ? 64'd1 : 64'd0;
        delta[CTR_LOAD_STORE] = load_store_overlap ? 64'd1 : 64'd0;
        delta[CTR_THREE_WAY] = three_way_overlap ? 64'd1 : 64'd0;
        delta[CTR_BANK_COMMITS] =
            events_i.m7_panel_commit ? 64'd1 : 64'd0;
        delta[CTR_BANK_CLAIMS] =
            events_i.m7_panel_claim ? 64'd1 : 64'd0;
        delta[CTR_BANK_RELEASES] =
            events_i.m7_panel_release ? 64'd1 : 64'd0;
        delta[CTR_BANK_EMPTY_WAIT] =
            events_i.m7_panel_empty_stall ? 64'd1 : 64'd0;
        delta[CTR_BANK_FULL_WAIT] =
            events_i.m7_panel_full_stall ? 64'd1 : 64'd0;
        delta[CTR_FIFO_ENQUEUE] =
            events_i.m7_result_fifo_enqueue ? 64'd1 : 64'd0;
        delta[CTR_FIFO_DEQUEUE] =
            events_i.m7_result_fifo_dequeue ? 64'd1 : 64'd0;

        overflow_next = overflow_live;
        for (comb_index = 0; comb_index < COUNTER_COUNT;
             comb_index = comb_index + 1) begin
            sum[comb_index] =
                {1'b0, live[comb_index]} + {1'b0, delta[comb_index]};
            next_value[comb_index] = sum[comb_index][63:0];
            if (sum[comb_index][64])
                overflow_next[comb_index] = 1'b1;
        end

        // Occupancy counters are maximum gauges, not additive events.
        next_value[CTR_BANK_MAX_OCC] =
            (live[CTR_BANK_MAX_OCC] < {62'd0, events_i.m7_panel_occupancy})
                ? {62'd0, events_i.m7_panel_occupancy}
                : live[CTR_BANK_MAX_OCC];
        next_value[CTR_FIFO_MAX_OCC] =
            (live[CTR_FIFO_MAX_OCC] <
             {62'd0, events_i.m7_result_fifo_occupancy})
                ? {62'd0, events_i.m7_result_fifo_occupancy}
                : live[CTR_FIFO_MAX_OCC];

        error_next = error_live | events_i.m7_error_events;
        if (events_i.m7_fp16_disabled_term_delta >
            events_i.m7_fp16_term_accept_delta)
            error_next[18] = 1'b1;
        if (done_i && (events_i.m7_panel_occupancy != 0))
            error_next[14] = 1'b1;
        if (done_i && (events_i.m7_result_fifo_occupancy != 0))
            error_next[15] = 1'b1;
        if (done_i &&
            (events_i.m7_panel_load_active ||
             events_i.m7_panel_compute_active ||
             events_i.m7_panel_store_active))
            error_next[16] = 1'b1;
        claim_seen_next = claim_seen_live | events_i.m7_panel_claim_mask;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            running_o <= 1'b0;
            snapshot_valid_o <= 1'b0;
            overflow_live <= '0;
            overflow_published <= '0;
            error_live <= '0;
            error_published <= '0;
            claim_seen_live <= '0;
            claim_seen_published <= '0;
            for (sequential_index = 0; sequential_index < COUNTER_COUNT;
                 sequential_index = sequential_index + 1) begin
                live[sequential_index] <= 64'd0;
                published[sequential_index] <= 64'd0;
            end
        end else if (start_accept_i) begin
            running_o <= 1'b1;
            snapshot_valid_o <= 1'b0;
            overflow_live <= '0;
            overflow_published <= '0;
            error_live <= '0;
            error_published <= '0;
            claim_seen_live <= '0;
            claim_seen_published <= '0;
            for (sequential_index = 0; sequential_index < COUNTER_COUNT;
                 sequential_index = sequential_index + 1) begin
                live[sequential_index] <= 64'd0;
                published[sequential_index] <= 64'd0;
            end
        end else if (running_o) begin
            overflow_live <= overflow_next;
            error_live <= error_next;
            claim_seen_live <= claim_seen_next;
            for (sequential_index = 0; sequential_index < COUNTER_COUNT;
                 sequential_index = sequential_index + 1)
                live[sequential_index] <= next_value[sequential_index];

            if (done_i) begin
                running_o <= 1'b0;
                snapshot_valid_o <= 1'b1;
                overflow_published <= overflow_next;
                error_published <= error_next;
                claim_seen_published <= claim_seen_next;
                for (sequential_index = 0;
                     sequential_index < COUNTER_COUNT;
                     sequential_index = sequential_index + 1)
                    published[sequential_index] <=
                        next_value[sequential_index];
            end
        end
    end

    always_comb begin
        status_o = 32'd0;
        status_o[0] = running_o;
        status_o[1] = snapshot_valid_o;
        status_o[2] = |overflow_published;
        status_o[3] = |error_published;
        status_o[4] = published[CTR_LOAD_COMPUTE] != 0;
        status_o[5] = published[CTR_COMPUTE_STORE] != 0;
        status_o[6] = published[CTR_THREE_WAY] != 0;
        status_o[7] = &claim_seen_published;
        status_o[9:8] = claim_seen_published;
        status_o[11:10] = published[CTR_BANK_MAX_OCC][1:0];
        status_o[15:12] = published[CTR_FIFO_MAX_OCC][3:0];
        status_o[16] = published[CTR_FEEDER_STALL] != 0;
        status_o[17] = published[CTR_RESULT_BP] != 0;
        status_o[18] = published[CTR_BANK_EMPTY_WAIT] != 0;
        status_o[19] = published[CTR_BANK_FULL_WAIT] != 0;
        status_o[20] = |error_published[13:10] || error_published[19];
        status_o[21] = |error_published[9:0] || |error_published[18:14];

        overflow_o = 64'd0;
        overflow_o[COUNTER_COUNT-1:0] = overflow_published;
        error_status_o = {12'd0, error_published};
        counters_flat_o = '0;
        for (output_index = 0; output_index < COUNTER_COUNT;
             output_index = output_index + 1)
            counters_flat_o[output_index*64 +: 64] =
                published[output_index];
    end

endmodule
