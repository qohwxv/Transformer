`timescale 1ns/1ps

// Append-only M5 native-AXI profile bank.
//
// The M1/M4 global counters retain their original addresses and meanings.
// This independent bank publishes burst-specific facts atomically at DONE so
// software can distinguish logical words from 128-bit physical beats and can
// prove that read-ahead/outstanding operation actually occurred.
(* use_dsp = "no" *)
module vit_phase_e_m5_axi_counters (
    input  logic       clk,
    input  logic       rst,
    input  logic       start_accept_i,
    input  logic       done_i,

    input  logic       full_r_beat_i,
    input  logic       narrow_r_beat_i,
    input  logic       linefill_start_i,
    input  logic       linefill_hit_i,
    input  logic       four_k_split_i,
    input  logic [1:0] read_outstanding_i,
    input  logic [7:0] protocol_error_i,
    input  logic [5:0] prefetched_words_discarded_i,

    output logic       running_o,
    output logic       snapshot_valid_o,
    output logic [31:0] capability_o,
    output logic [31:0] status_o,
    output logic [15:0] overflow_o,
    output logic [7:0] protocol_error_status_o,
    output logic [8*64-1:0] counters_flat_o
);

    localparam integer COUNTER_COUNT = 8;

    localparam integer CTR_FULL_R_BEATS       = 0;
    localparam integer CTR_NARROW_R_BEATS     = 1;
    localparam integer CTR_LINEFILL_STARTS    = 2;
    localparam integer CTR_LINEFILL_HITS      = 3;
    localparam integer CTR_FOUR_K_SPLITS      = 4;
    localparam integer CTR_MAX_READ_OUTSTANDING = 5;
    localparam integer CTR_PROTOCOL_ERRORS    = 6;
    localparam integer CTR_PREFETCH_DISCARDED = 7;

    logic [63:0] live [0:COUNTER_COUNT-1];
    logic [63:0] published [0:COUNTER_COUNT-1];
    logic [63:0] delta [0:COUNTER_COUNT-1];
    logic [64:0] sum [0:COUNTER_COUNT-1];
    logic [63:0] next_value [0:COUNTER_COUNT-1];
    logic [COUNTER_COUNT-1:0] overflow_live;
    logic [COUNTER_COUNT-1:0] overflow_next;
    logic [COUNTER_COUNT-1:0] overflow_published;
    logic [7:0] protocol_error_live;
    logic [7:0] protocol_error_next;
    logic [7:0] protocol_error_published;
    logic [3:0] protocol_error_delta;
    integer comb_index;
    integer sequential_index;
    integer output_index;

    function automatic logic [3:0] popcount8(input logic [7:0] value);
        integer bit_index;
        begin
            popcount8 = 4'd0;
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1)
                popcount8 = popcount8 + {3'd0, value[bit_index]};
        end
    endfunction

    // Encoding:
    // [7:0] counter count, [15:8] native bytes/beat,
    // [19:16] supported read outstanding depth, [20] burst, [21] INCR,
    // [22] 4-KiB clamp, [23] typed protocol status, [24] atomic snapshot.
    assign capability_o = 32'h01f2_1008;
    assign protocol_error_delta = popcount8(protocol_error_i);
    assign protocol_error_next = protocol_error_live | protocol_error_i;

    always_comb begin
        for (comb_index = 0;
             comb_index < COUNTER_COUNT;
             comb_index = comb_index + 1)
            delta[comb_index] = 64'd0;

        delta[CTR_FULL_R_BEATS] = full_r_beat_i ? 64'd1 : 64'd0;
        delta[CTR_NARROW_R_BEATS] = narrow_r_beat_i ? 64'd1 : 64'd0;
        delta[CTR_LINEFILL_STARTS] = linefill_start_i ? 64'd1 : 64'd0;
        delta[CTR_LINEFILL_HITS] = linefill_hit_i ? 64'd1 : 64'd0;
        delta[CTR_FOUR_K_SPLITS] = four_k_split_i ? 64'd1 : 64'd0;
        delta[CTR_MAX_READ_OUTSTANDING] = 64'd0;
        delta[CTR_PROTOCOL_ERRORS] = {60'd0, protocol_error_delta};
        delta[CTR_PREFETCH_DISCARDED] =
            {58'd0, prefetched_words_discarded_i};

        overflow_next = overflow_live;
        for (comb_index = 0;
             comb_index < COUNTER_COUNT;
             comb_index = comb_index + 1) begin
            sum[comb_index] =
                {1'b0, live[comb_index]} + {1'b0, delta[comb_index]};
            next_value[comb_index] = sum[comb_index][63:0];
            if (sum[comb_index][64])
                overflow_next[comb_index] = 1'b1;
        end

        // Counter five is a maximum gauge, not an additive event counter.
        next_value[CTR_MAX_READ_OUTSTANDING] =
            (live[CTR_MAX_READ_OUTSTANDING] <
             {62'd0, read_outstanding_i}) ?
                {62'd0, read_outstanding_i} :
                live[CTR_MAX_READ_OUTSTANDING];
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            running_o <= 1'b0;
            snapshot_valid_o <= 1'b0;
            overflow_live <= '0;
            overflow_published <= '0;
            protocol_error_live <= 8'd0;
            protocol_error_published <= 8'd0;
            for (sequential_index = 0;
                 sequential_index < COUNTER_COUNT;
                 sequential_index = sequential_index + 1) begin
                live[sequential_index] <= 64'd0;
                published[sequential_index] <= 64'd0;
            end
        end else if (start_accept_i) begin
            running_o <= 1'b1;
            snapshot_valid_o <= 1'b0;
            overflow_live <= '0;
            overflow_published <= '0;
            protocol_error_live <= 8'd0;
            protocol_error_published <= 8'd0;
            for (sequential_index = 0;
                 sequential_index < COUNTER_COUNT;
                 sequential_index = sequential_index + 1) begin
                live[sequential_index] <= 64'd0;
                published[sequential_index] <= 64'd0;
            end
        end else if (running_o) begin
            overflow_live <= overflow_next;
            protocol_error_live <= protocol_error_next;
            for (sequential_index = 0;
                 sequential_index < COUNTER_COUNT;
                 sequential_index = sequential_index + 1)
                live[sequential_index] <= next_value[sequential_index];

            if (done_i) begin
                running_o <= 1'b0;
                snapshot_valid_o <= 1'b1;
                overflow_published <= overflow_next;
                protocol_error_published <= protocol_error_next;
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
        status_o[3] = |protocol_error_published;
        status_o[4] = (published[CTR_MAX_READ_OUTSTANDING] >= 64'd2);
        status_o[5] = (published[CTR_MAX_READ_OUTSTANDING] > 64'd2);
        status_o[6] = (published[CTR_FOUR_K_SPLITS] != 64'd0);
        status_o[7] = (published[CTR_PREFETCH_DISCARDED] != 64'd0);
    end

    always_comb begin
        overflow_o = 16'd0;
        overflow_o[COUNTER_COUNT-1:0] = overflow_published;
        protocol_error_status_o = protocol_error_published;
        counters_flat_o = '0;
        for (output_index = 0;
             output_index < COUNTER_COUNT;
             output_index = output_index + 1)
            counters_flat_o[output_index*64 +: 64] =
                published[output_index];
    end

endmodule
