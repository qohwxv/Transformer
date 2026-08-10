`timescale 1ns/1ps

// Extended per-job profile bank for ABI v1.2.
//
// The legacy five-counter module remains a separate, unchanged instance.  This
// block shadows those five event streams only to publish their overflow bits,
// then adds the global/opcode/trace/histogram data required by profile 7.1.
// Aggregate values are modulo 2^64 and overflow is sticky.  Software sees only
// the atomically published bank after DONE.
(* use_dsp = "no" *)
module vit_phase_e_profile_counters (
    input  logic clk,
    input  logic rst,

    input  logic start_accept_i,
    input  logic done_i,
    input  vit_phase_e_pkg::phase_e_profile_core_events_t core_events_i,
    input  logic [3:0] m7_a_vector_hit_word_delta_i,

    input  logic legacy_axi_read_accept_i,
    input  logic legacy_axi_write_accept_i,
    input  logic legacy_axi_request_stall_i,

    input  logic logical_request_backpressure_i,
    input  logic logical_response_backpressure_i,
    input  logic logical_read_response_wait_i,
    input  logic logical_write_response_wait_i,
    input  logic logical_response_error_i,
    input  logic job_error_i,

    input  logic axi_r_beat_i,
    input  logic axi_w_beat_i,
    input  logic axi_b_response_i,
    input  logic axi_ar_backpressure_i,
    input  logic axi_aw_backpressure_i,
    input  logic axi_w_backpressure_i,
    input  logic axi_r_response_wait_i,
    input  logic axi_b_response_wait_i,
    input  logic axi_r_response_backpressure_i,
    input  logic axi_b_response_backpressure_i,
    // End-of-burst qualifier for axi_r_beat_i.  M5 may have two ordered,
    // same-ID read bursts outstanding, so an intermediate R beat must not
    // retire the AR transaction or be treated as a protocol error.
    input  logic axi_r_last_i,
    input  logic axi_r_error_i,
    input  logic axi_b_error_i,

    input  logic       trace_select_strobe_i,
    input  logic [7:0] trace_select_i,

    output logic profile_running_o,
    output logic profile_snapshot_valid_o,
    output logic [
        vit_phase_e_pkg::PHASE_E_PROFILE_GLOBAL_COUNT*64-1:0
    ] global_counters_flat_o,
    output logic [
        vit_phase_e_pkg::PHASE_E_PROFILE_OPCODE_SLOTS*64-1:0
    ] opcode_counts_flat_o,
    output logic [
        vit_phase_e_pkg::PHASE_E_PROFILE_OPCODE_SLOTS*64-1:0
    ] opcode_cycles_flat_o,
    output logic [63:0] global_overflow_o,
    output logic [15:0] opcode_count_overflow_o,
    output logic [15:0] opcode_cycle_overflow_o,
    output logic [31:0] error_status_o,

    output logic [8:0]  trace_count_o,
    output logic        trace_truncated_o,
    output logic        trace_selected_valid_o,
    output logic        trace_read_pending_o,
    output logic [31:0] trace_selected_meta_o,
    output logic [63:0] trace_selected_cycles_o,

    output logic [
        vit_phase_e_pkg::PHASE_E_PROFILE_HIST_COUNT*64-1:0
    ] histogram_counters_flat_o,
    output logic [17:0] histogram_overflow_o
);

    import vit_phase_e_pkg::*;

    localparam integer LEGACY_COUNTER_COUNT = 5;
    localparam logic [63:0] COUNTER_MAX = 64'hffff_ffff_ffff_ffff;
    localparam logic [8:0] TRACE_DEPTH_U9 =
        9'(PHASE_E_PROFILE_TRACE_DEPTH);

    // Typed sticky error bits published at 0x71c.
    localparam integer ERROR_JOB                    = 0;
    localparam integer ERROR_COMMAND                = 1;
    localparam integer ERROR_LOGICAL_RESPONSE       = 2;
    localparam integer ERROR_AXI_R_RESPONSE         = 3;
    localparam integer ERROR_AXI_B_RESPONSE         = 4;
    localparam integer ERROR_FRONTEND               = 5;
    localparam integer ERROR_ACCEPT_WHILE_ACTIVE    = 6;
    localparam integer ERROR_COMPLETE_WITHOUT_ACTIVE = 7;
    localparam integer ERROR_INVALID_OPCODE         = 8;
    localparam integer ERROR_TRACE_TRUNCATED         = 9;
    localparam integer ERROR_R_WITHOUT_AR            = 10;
    localparam integer ERROR_B_WITHOUT_AW            = 11;
    localparam integer ERROR_AR_WHILE_ACTIVE         = 12;
    localparam integer ERROR_AW_WHILE_ACTIVE         = 13;
    localparam integer ERROR_R_LATENCY_OVERFLOW      = 14;
    localparam integer ERROR_B_LATENCY_OVERFLOW      = 15;
    localparam integer ERROR_COMMAND_DURATION_OVERFLOW = 16;
    localparam integer ERROR_TRACE_SELECT_WHILE_RUNNING = 17;
    localparam integer ERROR_DONE_WITH_READ_ACTIVE   = 18;
    localparam integer ERROR_DONE_WITH_WRITE_ACTIVE  = 19;

    logic [63:0] legacy_live [0:LEGACY_COUNTER_COUNT-1];
    logic [63:0] legacy_delta [0:LEGACY_COUNTER_COUNT-1];
    logic [64:0] legacy_sum [0:LEGACY_COUNTER_COUNT-1];
    logic [63:0] legacy_next [0:LEGACY_COUNTER_COUNT-1];
    logic [LEGACY_COUNTER_COUNT-1:0] legacy_overflow_live;
    logic [LEGACY_COUNTER_COUNT-1:0] legacy_overflow_next;
    logic [LEGACY_COUNTER_COUNT-1:0] legacy_overflow_published;

    logic [63:0] global_live [0:PHASE_E_PROFILE_GLOBAL_COUNT-1];
    logic [63:0] global_published [0:PHASE_E_PROFILE_GLOBAL_COUNT-1];
    logic [63:0] global_delta [0:PHASE_E_PROFILE_GLOBAL_COUNT-1];
    logic [64:0] global_sum [0:PHASE_E_PROFILE_GLOBAL_COUNT-1];
    logic [63:0] global_next [0:PHASE_E_PROFILE_GLOBAL_COUNT-1];
    logic [PHASE_E_PROFILE_GLOBAL_COUNT-1:0] global_overflow_live;
    logic [PHASE_E_PROFILE_GLOBAL_COUNT-1:0] global_overflow_next;
    logic [PHASE_E_PROFILE_GLOBAL_COUNT-1:0]
        global_overflow_published;

    logic [63:0] opcode_count_live [0:PHASE_E_PROFILE_OPCODE_SLOTS-1];
    logic [63:0] opcode_count_published [0:PHASE_E_PROFILE_OPCODE_SLOTS-1];
    logic [63:0] opcode_count_delta [0:PHASE_E_PROFILE_OPCODE_SLOTS-1];
    logic [64:0] opcode_count_sum [0:PHASE_E_PROFILE_OPCODE_SLOTS-1];
    logic [63:0] opcode_count_next [0:PHASE_E_PROFILE_OPCODE_SLOTS-1];
    logic [PHASE_E_PROFILE_OPCODE_SLOTS-1:0]
        opcode_count_overflow_live;
    logic [PHASE_E_PROFILE_OPCODE_SLOTS-1:0]
        opcode_count_overflow_next;
    logic [PHASE_E_PROFILE_OPCODE_SLOTS-1:0]
        opcode_count_overflow_published;

    logic [63:0] opcode_cycle_live [0:PHASE_E_PROFILE_OPCODE_SLOTS-1];
    logic [63:0] opcode_cycle_published [0:PHASE_E_PROFILE_OPCODE_SLOTS-1];
    logic [63:0] opcode_cycle_delta [0:PHASE_E_PROFILE_OPCODE_SLOTS-1];
    logic [64:0] opcode_cycle_sum [0:PHASE_E_PROFILE_OPCODE_SLOTS-1];
    logic [63:0] opcode_cycle_next [0:PHASE_E_PROFILE_OPCODE_SLOTS-1];
    logic [PHASE_E_PROFILE_OPCODE_SLOTS-1:0]
        opcode_cycle_overflow_live;
    logic [PHASE_E_PROFILE_OPCODE_SLOTS-1:0]
        opcode_cycle_overflow_next;
    logic [PHASE_E_PROFILE_OPCODE_SLOTS-1:0]
        opcode_cycle_overflow_published;

    logic [63:0] histogram_live [0:PHASE_E_PROFILE_HIST_COUNT-1];
    logic [63:0] histogram_published [0:PHASE_E_PROFILE_HIST_COUNT-1];
    logic [63:0] histogram_delta [0:PHASE_E_PROFILE_HIST_COUNT-1];
    logic [64:0] histogram_sum [0:PHASE_E_PROFILE_HIST_COUNT-1];
    logic [63:0] histogram_next [0:PHASE_E_PROFILE_HIST_COUNT-1];
    logic [PHASE_E_PROFILE_HIST_COUNT-1:0] histogram_overflow_live;
    logic [PHASE_E_PROFILE_HIST_COUNT-1:0] histogram_overflow_next;
    logic [PHASE_E_PROFILE_HIST_COUNT-1:0]
        histogram_overflow_published;

    logic command_trace_active;
    phase_e_opcode_t command_opcode_live;
    logic [7:0] command_tag_live;
    phase_e_section_t command_section_live;
    logic [3:0] command_layer_live;
    logic [4:0] command_step_live;
    logic [63:0] command_duration_live;
    logic command_duration_overflow_live;
    logic command_duration_overflow_event;
    logic [63:0] command_terminal_duration;
    logic [31:0] command_terminal_meta;
    logic trace_completion_valid;
    logic trace_will_store;
    logic trace_will_drop;
    logic [8:0] trace_count_live;
    logic [8:0] trace_count_next;
    logic trace_truncated_live;
    logic trace_truncated_next;

    (* ram_style = "block" *)
    logic [95:0] trace_memory [0:PHASE_E_PROFILE_TRACE_DEPTH-1];
    logic [7:0] trace_read_address;

    logic [31:0] error_status_live;
    logic [31:0] error_status_next;
    logic [31:0] error_status_published;

    // Ordered two-entry AR latency queue.  The histogram records the number
    // of complete cycles from each AR handshake to that transaction's first
    // R handshake.  RLAST, not the first R beat, retires the queue entry.
    logic [1:0] read_latency_count;
    // Keep these two legacy internal names as the first queue slot.  The
    // established counter unit test uses near-maximum hierarchical injection
    // to cover 64-bit saturation without simulating 2^64 cycles.
    logic       read_latency_active;
    logic       read_first_seen [0:1];
    logic [63:0] read_wait_live;
    logic [63:0] read_wait_second;
    logic       read_last_clean;
    logic       read_pop_valid;
    logic       read_push_overflow;
    logic [1:0] read_latency_count_after;
    logic       read_latency_overflow_event;
    logic write_latency_active;
    logic [63:0] write_wait_live;
    logic read_response_matches;
    logic write_response_matches;
    logic [63:0] observed_read_wait;
    logic [63:0] observed_write_wait;

    logic stage_union_event;
    logic stage_overlap_event;
    logic load_compute_overlap_event;
    logic compute_store_overlap_event;
    logic load_store_overlap_event;
    logic three_way_overlap_event;
    logic [3:0] cache_lookup_delta;
    logic [3:0] cache_hit_delta;
    logic [1:0] cache_miss_delta;
    logic [1:0] axi_response_error_delta;

    integer legacy_index;
    integer global_index;
    integer opcode_index;
    integer histogram_index;
    integer sequential_index;

    function automatic integer wait_bucket(input logic [63:0] wait_cycles);
        begin
            if (wait_cycles == 0)
                wait_bucket = 0;
            else if (wait_cycles == 1)
                wait_bucket = 1;
            else if (wait_cycles <= 3)
                wait_bucket = 2;
            else if (wait_cycles <= 7)
                wait_bucket = 3;
            else if (wait_cycles <= 15)
                wait_bucket = 4;
            else if (wait_cycles <= 31)
                wait_bucket = 5;
            else if (wait_cycles <= 63)
                wait_bucket = 6;
            else
                wait_bucket = 7;
        end
    endfunction

    assign stage_union_event =
        core_events_i.load_active ||
        core_events_i.compute_active ||
        core_events_i.store_active;
    assign load_compute_overlap_event =
        core_events_i.load_active && core_events_i.compute_active;
    assign compute_store_overlap_event =
        core_events_i.compute_active && core_events_i.store_active;
    assign load_store_overlap_event =
        core_events_i.load_active && core_events_i.store_active;
    assign three_way_overlap_event =
        core_events_i.load_active &&
        core_events_i.compute_active &&
        core_events_i.store_active;
    assign stage_overlap_event =
        load_compute_overlap_event ||
        compute_store_overlap_event ||
        load_store_overlap_event;

    assign cache_lookup_delta =
        {3'b0, core_events_i.a_cache_lookup} +
        {3'b0, core_events_i.bias_cache_lookup} +
        m7_a_vector_hit_word_delta_i;
    assign cache_hit_delta =
        {3'b0, core_events_i.a_cache_hit} +
        {3'b0, core_events_i.bias_cache_hit} +
        m7_a_vector_hit_word_delta_i;
    assign cache_miss_delta =
        {1'b0, core_events_i.a_cache_miss} +
        {1'b0, core_events_i.bias_cache_miss};
    assign axi_response_error_delta =
        {1'b0, axi_r_error_i} + {1'b0, axi_b_error_i};

    assign trace_completion_valid =
        core_events_i.command_complete && command_trace_active;
    assign trace_will_store =
        trace_completion_valid && (trace_count_live < TRACE_DEPTH_U9);
    assign trace_will_drop =
        trace_completion_valid && (trace_count_live >= TRACE_DEPTH_U9);
    assign trace_count_next =
        trace_will_store ? (trace_count_live + 1'b1) : trace_count_live;
    assign trace_truncated_next = trace_truncated_live || trace_will_drop;
    assign command_duration_overflow_event =
        command_trace_active && (command_duration_live == COUNTER_MAX);
    assign command_terminal_duration = command_duration_live + 64'd1;

    always_comb begin
        command_terminal_meta = 32'd0;
        command_terminal_meta[3:0] = command_opcode_live;
        command_terminal_meta[11:4] = command_tag_live;
        command_terminal_meta[12] = core_events_i.command_error;
        command_terminal_meta[13] =
            command_duration_overflow_live ||
            command_duration_overflow_event;
        command_terminal_meta[16:14] = {1'b0, command_section_live};
        command_terminal_meta[20:17] = command_layer_live;
        command_terminal_meta[25:21] = command_step_live;
    end

    assign read_last_clean = axi_r_last_i;
    assign read_response_matches =
        axi_r_beat_i &&
        ((((read_latency_count != 0) || read_latency_active) &&
          !read_first_seen[0]) ||
         ((read_latency_count == 0) && legacy_axi_read_accept_i));
    assign write_response_matches =
        axi_b_response_i &&
        (write_latency_active || legacy_axi_write_accept_i);
    assign observed_read_wait =
        ((read_latency_count != 0) || read_latency_active) ?
            read_wait_live : 64'd0;
    assign observed_write_wait =
        write_latency_active ? write_wait_live : 64'd0;

    assign read_pop_valid =
        axi_r_beat_i && read_last_clean &&
        ((read_latency_count != 0) || legacy_axi_read_accept_i);
    assign read_push_overflow =
        legacy_axi_read_accept_i && (read_latency_count == 2) &&
        !read_pop_valid;

    always_comb begin
        read_latency_count_after = read_latency_count;
        case ({legacy_axi_read_accept_i && !read_push_overflow,
               read_pop_valid})
            2'b10: read_latency_count_after = read_latency_count + 1'b1;
            2'b01: read_latency_count_after = read_latency_count - 1'b1;
            default: read_latency_count_after = read_latency_count;
        endcase
    end

    assign read_latency_overflow_event =
        ((((read_latency_count > 0) || read_latency_active) &&
          !read_first_seen[0]) &&
         (read_wait_live == COUNTER_MAX)) ||
        (((read_latency_count > 1) && !read_first_seen[1]) &&
         (read_wait_second == COUNTER_MAX));

    always_comb begin
        for (legacy_index = 0;
             legacy_index < LEGACY_COUNTER_COUNT;
             legacy_index = legacy_index + 1)
            legacy_delta[legacy_index] = 64'd0;
        legacy_delta[0] = profile_running_o ? 64'd1 : 64'd0;
        legacy_delta[1] =
            core_events_i.command_accept ? 64'd1 : 64'd0;
        legacy_delta[2] =
            legacy_axi_read_accept_i ? 64'd1 : 64'd0;
        legacy_delta[3] =
            legacy_axi_write_accept_i ? 64'd1 : 64'd0;
        legacy_delta[4] =
            legacy_axi_request_stall_i ? 64'd1 : 64'd0;

        legacy_overflow_next = legacy_overflow_live;
        for (legacy_index = 0;
             legacy_index < LEGACY_COUNTER_COUNT;
             legacy_index = legacy_index + 1) begin
            legacy_sum[legacy_index] =
                {1'b0, legacy_live[legacy_index]} +
                {1'b0, legacy_delta[legacy_index]};
            legacy_next[legacy_index] = legacy_sum[legacy_index][63:0];
            if (legacy_sum[legacy_index][64])
                legacy_overflow_next[legacy_index] = 1'b1;
        end
    end

    always_comb begin
        for (global_index = 0;
             global_index < PHASE_E_PROFILE_GLOBAL_COUNT;
             global_index = global_index + 1)
            global_delta[global_index] = 64'd0;

        global_delta[PHASE_E_PROFILE_GLOBAL_LOGICAL_READ] =
            (core_events_i.logical_read_word ? 64'd1 : 64'd0) +
            {60'd0, m7_a_vector_hit_word_delta_i};
        global_delta[PHASE_E_PROFILE_GLOBAL_LOGICAL_WRITE] =
            core_events_i.logical_write_word ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_R_BEATS] =
            axi_r_beat_i ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_W_BEATS] =
            axi_w_beat_i ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_COMMAND_ACTIVE] =
            command_trace_active ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_LOGICAL_REQ_BP] =
            logical_request_backpressure_i ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_AR_BP] =
            axi_ar_backpressure_i ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_AW_BP] =
            axi_aw_backpressure_i ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_W_BP] =
            axi_w_backpressure_i ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_R_WAIT] =
            axi_r_response_wait_i ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_B_WAIT] =
            axi_b_response_wait_i ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_R_BP] =
            axi_r_response_backpressure_i ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_B_BP] =
            axi_b_response_backpressure_i ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_LOAD] =
            core_events_i.load_active ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_COMPUTE] =
            core_events_i.compute_active ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_STORE] =
            core_events_i.store_active ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_UNION] =
            stage_union_event ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_OVERLAP] =
            stage_overlap_event ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_CACHE_LOOKUP] =
            {{60{1'b0}}, cache_lookup_delta};
        global_delta[PHASE_E_PROFILE_GLOBAL_CACHE_HIT] =
            {{60{1'b0}}, cache_hit_delta};
        global_delta[PHASE_E_PROFILE_GLOBAL_CACHE_MISS] =
            {{62{1'b0}}, cache_miss_delta};
        global_delta[PHASE_E_PROFILE_GLOBAL_GEMM_TILE_STEPS] =
            core_events_i.gemm_tile_step ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_VALID_MAC] =
            core_events_i.gemm_tile_step ?
                {48'd0, core_events_i.gemm_valid_mac_delta} : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_TAIL_MAC] =
            core_events_i.gemm_tile_step ?
                {48'd0, core_events_i.gemm_tail_mac_delta} : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_COMMAND_ERRORS] =
            core_events_i.command_error ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_AXI_RESPONSE_ERRORS] =
            {{62{1'b0}}, axi_response_error_delta};
        global_delta[PHASE_E_PROFILE_GLOBAL_TRACE_DROPPED] =
            trace_will_drop ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_LOGICAL_RSP_BP] =
            logical_response_backpressure_i ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_B_RESPONSES] =
            axi_b_response_i ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_LOGICAL_RSP_ERRORS] =
            logical_response_error_i ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_JOB_ERRORS] =
            job_error_i ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_A_LOOKUP] =
            (core_events_i.a_cache_lookup ? 64'd1 : 64'd0) +
            {60'd0, m7_a_vector_hit_word_delta_i};
        global_delta[PHASE_E_PROFILE_GLOBAL_A_HIT] =
            (core_events_i.a_cache_hit ? 64'd1 : 64'd0) +
            {60'd0, m7_a_vector_hit_word_delta_i};
        global_delta[PHASE_E_PROFILE_GLOBAL_A_MISS] =
            core_events_i.a_cache_miss ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_BIAS_LOOKUP] =
            core_events_i.bias_cache_lookup ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_BIAS_HIT] =
            core_events_i.bias_cache_hit ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_BIAS_MISS] =
            core_events_i.bias_cache_miss ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_B_BYPASS] =
            core_events_i.b_bypass ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_LOAD_COMPUTE_OVERLAP] =
            load_compute_overlap_event ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_COMPUTE_STORE_OVERLAP] =
            compute_store_overlap_event ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_LOAD_STORE_OVERLAP] =
            load_store_overlap_event ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_THREE_WAY] =
            three_way_overlap_event ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_LOGICAL_READ_RSP_WAIT] =
            logical_read_response_wait_i ? 64'd1 : 64'd0;
        global_delta[PHASE_E_PROFILE_GLOBAL_LOGICAL_WRITE_RSP_WAIT] =
            logical_write_response_wait_i ? 64'd1 : 64'd0;

        global_overflow_next = global_overflow_live;
        for (global_index = 0;
             global_index < PHASE_E_PROFILE_GLOBAL_COUNT;
             global_index = global_index + 1) begin
            global_sum[global_index] =
                {1'b0, global_live[global_index]} +
                {1'b0, global_delta[global_index]};
            global_next[global_index] = global_sum[global_index][63:0];
            if (global_sum[global_index][64])
                global_overflow_next[global_index] = 1'b1;
        end
    end

    always_comb begin
        for (opcode_index = 0;
             opcode_index < PHASE_E_PROFILE_OPCODE_SLOTS;
             opcode_index = opcode_index + 1) begin
            opcode_count_delta[opcode_index] = 64'd0;
            opcode_cycle_delta[opcode_index] = 64'd0;
            if (core_events_i.command_accept &&
                (core_events_i.command_opcode == opcode_index[3:0]))
                opcode_count_delta[opcode_index] = 64'd1;
            if (command_trace_active &&
                (command_opcode_live == opcode_index[3:0]))
                opcode_cycle_delta[opcode_index] = 64'd1;
        end

        opcode_count_overflow_next = opcode_count_overflow_live;
        opcode_cycle_overflow_next = opcode_cycle_overflow_live;
        for (opcode_index = 0;
             opcode_index < PHASE_E_PROFILE_OPCODE_SLOTS;
             opcode_index = opcode_index + 1) begin
            opcode_count_sum[opcode_index] =
                {1'b0, opcode_count_live[opcode_index]} +
                {1'b0, opcode_count_delta[opcode_index]};
            opcode_count_next[opcode_index] =
                opcode_count_sum[opcode_index][63:0];
            if (opcode_count_sum[opcode_index][64])
                opcode_count_overflow_next[opcode_index] = 1'b1;

            opcode_cycle_sum[opcode_index] =
                {1'b0, opcode_cycle_live[opcode_index]} +
                {1'b0, opcode_cycle_delta[opcode_index]};
            opcode_cycle_next[opcode_index] =
                opcode_cycle_sum[opcode_index][63:0];
            if (opcode_cycle_sum[opcode_index][64])
                opcode_cycle_overflow_next[opcode_index] = 1'b1;
        end
    end

    always_comb begin
        for (histogram_index = 0;
             histogram_index < PHASE_E_PROFILE_HIST_COUNT;
             histogram_index = histogram_index + 1)
            histogram_delta[histogram_index] = 64'd0;

        if (read_response_matches)
            histogram_delta[wait_bucket(observed_read_wait)] = 64'd1;
        if (write_response_matches)
            histogram_delta[8 + wait_bucket(observed_write_wait)] = 64'd1;

        histogram_overflow_next = histogram_overflow_live;
        for (histogram_index = 0;
             histogram_index < PHASE_E_PROFILE_HIST_COUNT;
             histogram_index = histogram_index + 1) begin
            histogram_sum[histogram_index] =
                {1'b0, histogram_live[histogram_index]} +
                {1'b0, histogram_delta[histogram_index]};
            histogram_next[histogram_index] =
                histogram_sum[histogram_index][63:0];
            if (histogram_sum[histogram_index][64])
                histogram_overflow_next[histogram_index] = 1'b1;
        end

        if (read_response_matches &&
            (observed_read_wait > histogram_next[16]))
            histogram_next[16] = observed_read_wait;
        if (write_response_matches &&
            (observed_write_wait > histogram_next[17]))
            histogram_next[17] = observed_write_wait;

        // Histogram entries 16/17 are maxima rather than additive buckets.
        // Their overflow bits therefore describe a saturated latency counter,
        // not an adder carry from histogram_delta.
        if (read_latency_overflow_event)
            histogram_overflow_next[16] = 1'b1;
        if (write_latency_active && axi_b_response_wait_i &&
            (write_wait_live == COUNTER_MAX))
            histogram_overflow_next[17] = 1'b1;
    end

    always_comb begin
        error_status_next = error_status_live;
        if (job_error_i)
            error_status_next[ERROR_JOB] = 1'b1;
        if (core_events_i.command_error)
            error_status_next[ERROR_COMMAND] = 1'b1;
        if (logical_response_error_i)
            error_status_next[ERROR_LOGICAL_RESPONSE] = 1'b1;
        if (axi_r_error_i)
            error_status_next[ERROR_AXI_R_RESPONSE] = 1'b1;
        if (axi_b_error_i)
            error_status_next[ERROR_AXI_B_RESPONSE] = 1'b1;
        if (core_events_i.frontend_error)
            error_status_next[ERROR_FRONTEND] = 1'b1;
        if (core_events_i.command_accept && command_trace_active)
            error_status_next[ERROR_ACCEPT_WHILE_ACTIVE] = 1'b1;
        if (core_events_i.command_complete && !command_trace_active)
            error_status_next[ERROR_COMPLETE_WITHOUT_ACTIVE] = 1'b1;
        if (core_events_i.command_accept &&
            ((core_events_i.command_opcode < PHASE_E_OP_GEMM) ||
             (core_events_i.command_opcode > PHASE_E_OP_ARGMAX)))
            error_status_next[ERROR_INVALID_OPCODE] = 1'b1;
        if (trace_will_drop)
            error_status_next[ERROR_TRACE_TRUNCATED] = 1'b1;
        if (axi_r_beat_i && (read_latency_count == 0) &&
            !read_latency_active &&
            !legacy_axi_read_accept_i)
            error_status_next[ERROR_R_WITHOUT_AR] = 1'b1;
        if (axi_b_response_i && !write_latency_active &&
            !legacy_axi_write_accept_i)
            error_status_next[ERROR_B_WITHOUT_AW] = 1'b1;
        if (read_push_overflow)
            error_status_next[ERROR_AR_WHILE_ACTIVE] = 1'b1;
        if (legacy_axi_write_accept_i && write_latency_active)
            error_status_next[ERROR_AW_WHILE_ACTIVE] = 1'b1;
        if (read_latency_overflow_event)
            error_status_next[ERROR_R_LATENCY_OVERFLOW] = 1'b1;
        if (write_latency_active && axi_b_response_wait_i &&
            (write_wait_live == COUNTER_MAX))
            error_status_next[ERROR_B_LATENCY_OVERFLOW] = 1'b1;
        if (command_duration_overflow_event)
            error_status_next[ERROR_COMMAND_DURATION_OVERFLOW] = 1'b1;
        if (trace_select_strobe_i && profile_running_o)
            error_status_next[ERROR_TRACE_SELECT_WHILE_RUNNING] = 1'b1;
        if (done_i && (read_latency_count_after != 0))
            error_status_next[ERROR_DONE_WITH_READ_ACTIVE] = 1'b1;
        if (done_i && write_latency_active && !axi_b_response_i)
            error_status_next[ERROR_DONE_WITH_WRITE_ACTIVE] = 1'b1;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            profile_running_o <= 1'b0;
            profile_snapshot_valid_o <= 1'b0;
            legacy_overflow_live <= '0;
            legacy_overflow_published <= '0;
            global_overflow_live <= '0;
            global_overflow_published <= '0;
            opcode_count_overflow_live <= '0;
            opcode_count_overflow_published <= '0;
            opcode_cycle_overflow_live <= '0;
            opcode_cycle_overflow_published <= '0;
            histogram_overflow_live <= '0;
            histogram_overflow_published <= '0;
            error_status_live <= 32'd0;
            error_status_published <= 32'd0;
            command_trace_active <= 1'b0;
            command_opcode_live <= phase_e_opcode_t'(4'd0);
            command_tag_live <= 8'd0;
            command_section_live <= PHASE_E_SECTION_NONE;
            command_layer_live <= 4'd0;
            command_step_live <= 5'd0;
            command_duration_live <= 64'd0;
            command_duration_overflow_live <= 1'b0;
            trace_count_live <= 9'd0;
            trace_count_o <= 9'd0;
            trace_truncated_live <= 1'b0;
            trace_truncated_o <= 1'b0;
            read_latency_count <= 2'd0;
            read_latency_active <= 1'b0;
            read_first_seen[0] <= 1'b0;
            read_first_seen[1] <= 1'b0;
            write_latency_active <= 1'b0;
            read_wait_live <= 64'd0;
            read_wait_second <= 64'd0;
            write_wait_live <= 64'd0;

            for (sequential_index = 0;
                 sequential_index < LEGACY_COUNTER_COUNT;
                 sequential_index = sequential_index + 1)
                legacy_live[sequential_index] <= 64'd0;
            for (sequential_index = 0;
                 sequential_index < PHASE_E_PROFILE_GLOBAL_COUNT;
                 sequential_index = sequential_index + 1) begin
                global_live[sequential_index] <= 64'd0;
                global_published[sequential_index] <= 64'd0;
            end
            for (sequential_index = 0;
                 sequential_index < PHASE_E_PROFILE_OPCODE_SLOTS;
                 sequential_index = sequential_index + 1) begin
                opcode_count_live[sequential_index] <= 64'd0;
                opcode_count_published[sequential_index] <= 64'd0;
                opcode_cycle_live[sequential_index] <= 64'd0;
                opcode_cycle_published[sequential_index] <= 64'd0;
            end
            for (sequential_index = 0;
                 sequential_index < PHASE_E_PROFILE_HIST_COUNT;
                 sequential_index = sequential_index + 1) begin
                histogram_live[sequential_index] <= 64'd0;
                histogram_published[sequential_index] <= 64'd0;
            end
        end else if (start_accept_i) begin
            profile_running_o <= 1'b1;
            profile_snapshot_valid_o <= 1'b0;
            legacy_overflow_live <= '0;
            legacy_overflow_published <= '0;
            global_overflow_live <= '0;
            global_overflow_published <= '0;
            opcode_count_overflow_live <= '0;
            opcode_count_overflow_published <= '0;
            opcode_cycle_overflow_live <= '0;
            opcode_cycle_overflow_published <= '0;
            histogram_overflow_live <= '0;
            histogram_overflow_published <= '0;
            error_status_live <= 32'd0;
            error_status_published <= 32'd0;
            command_trace_active <= 1'b0;
            command_opcode_live <= phase_e_opcode_t'(4'd0);
            command_tag_live <= 8'd0;
            command_section_live <= PHASE_E_SECTION_NONE;
            command_layer_live <= 4'd0;
            command_step_live <= 5'd0;
            command_duration_live <= 64'd0;
            command_duration_overflow_live <= 1'b0;
            trace_count_live <= 9'd0;
            trace_count_o <= 9'd0;
            trace_truncated_live <= 1'b0;
            trace_truncated_o <= 1'b0;
            read_latency_count <= 2'd0;
            read_latency_active <= 1'b0;
            read_first_seen[0] <= 1'b0;
            read_first_seen[1] <= 1'b0;
            write_latency_active <= 1'b0;
            read_wait_live <= 64'd0;
            read_wait_second <= 64'd0;
            write_wait_live <= 64'd0;

            for (sequential_index = 0;
                 sequential_index < LEGACY_COUNTER_COUNT;
                 sequential_index = sequential_index + 1)
                legacy_live[sequential_index] <= 64'd0;
            for (sequential_index = 0;
                 sequential_index < PHASE_E_PROFILE_GLOBAL_COUNT;
                 sequential_index = sequential_index + 1) begin
                global_live[sequential_index] <= 64'd0;
                global_published[sequential_index] <= 64'd0;
            end
            for (sequential_index = 0;
                 sequential_index < PHASE_E_PROFILE_OPCODE_SLOTS;
                 sequential_index = sequential_index + 1) begin
                opcode_count_live[sequential_index] <= 64'd0;
                opcode_count_published[sequential_index] <= 64'd0;
                opcode_cycle_live[sequential_index] <= 64'd0;
                opcode_cycle_published[sequential_index] <= 64'd0;
            end
            for (sequential_index = 0;
                 sequential_index < PHASE_E_PROFILE_HIST_COUNT;
                 sequential_index = sequential_index + 1) begin
                histogram_live[sequential_index] <= 64'd0;
                histogram_published[sequential_index] <= 64'd0;
            end
        end else if (profile_running_o) begin
            legacy_overflow_live <= legacy_overflow_next;
            global_overflow_live <= global_overflow_next;
            opcode_count_overflow_live <= opcode_count_overflow_next;
            opcode_cycle_overflow_live <= opcode_cycle_overflow_next;
            histogram_overflow_live <= histogram_overflow_next;
            error_status_live <= error_status_next;
            trace_count_live <= trace_count_next;
            trace_truncated_live <= trace_truncated_next;

            for (sequential_index = 0;
                 sequential_index < LEGACY_COUNTER_COUNT;
                 sequential_index = sequential_index + 1)
                legacy_live[sequential_index] <= legacy_next[sequential_index];
            for (sequential_index = 0;
                 sequential_index < PHASE_E_PROFILE_GLOBAL_COUNT;
                 sequential_index = sequential_index + 1)
                global_live[sequential_index] <= global_next[sequential_index];
            for (sequential_index = 0;
                 sequential_index < PHASE_E_PROFILE_OPCODE_SLOTS;
                 sequential_index = sequential_index + 1) begin
                opcode_count_live[sequential_index] <=
                    opcode_count_next[sequential_index];
                opcode_cycle_live[sequential_index] <=
                    opcode_cycle_next[sequential_index];
            end
            for (sequential_index = 0;
                 sequential_index < PHASE_E_PROFILE_HIST_COUNT;
                 sequential_index = sequential_index + 1)
                histogram_live[sequential_index] <=
                    histogram_next[sequential_index];

            if (core_events_i.command_accept && !command_trace_active) begin
                command_trace_active <= 1'b1;
                command_opcode_live <= core_events_i.command_opcode;
                command_tag_live <= core_events_i.command_tag;
                command_section_live <= core_events_i.command_section;
                command_layer_live <= core_events_i.command_layer;
                command_step_live <= core_events_i.command_step;
                command_duration_live <= 64'd0;
                command_duration_overflow_live <= 1'b0;
            end else if (command_trace_active) begin
                command_duration_live <= command_terminal_duration;
                if (command_duration_overflow_event)
                    command_duration_overflow_live <= 1'b1;
            end

            if (trace_completion_valid) begin
                if (trace_will_store)
                    trace_memory[trace_count_live[7:0]] <= {
                        command_terminal_meta,
                        command_terminal_duration
                    };
                command_trace_active <= 1'b0;
                command_duration_live <= 64'd0;
                command_duration_overflow_live <= 1'b0;
            end

            // Age every accepted transaction until its first R handshake.
            // Same-ID responses are ordered, so only slot zero can consume a
            // beat; slot one is shifted forward when slot zero sees RLAST.
            if ((read_latency_count > 0) && !read_first_seen[0] &&
                (read_wait_live != COUNTER_MAX))
                read_wait_live <= read_wait_live + 64'd1;
            if ((read_latency_count > 1) && !read_first_seen[1] &&
                (read_wait_second != COUNTER_MAX))
                read_wait_second <= read_wait_second + 64'd1;

            case (read_latency_count)
                2'd0: begin
                    if (legacy_axi_read_accept_i) begin
                        if (axi_r_beat_i) begin
                            if (!read_last_clean) begin
                                read_latency_count <= 2'd1;
                                read_latency_active <= 1'b1;
                                read_first_seen[0] <= 1'b1;
                                read_wait_live <= 64'd0;
                            end
                        end else begin
                            read_latency_count <= 2'd1;
                            read_latency_active <= 1'b1;
                            read_first_seen[0] <= 1'b0;
                            read_wait_live <= 64'd0;
                        end
                    end else if (axi_r_beat_i && read_latency_active) begin
                        // Compatibility with the established saturation
                        // injection test; normal hardware never reaches this
                        // alias-only state.
                        read_latency_active <= 1'b0;
                        read_wait_live <= 64'd0;
                    end
                end

                2'd1: begin
                    if (axi_r_beat_i && !read_first_seen[0])
                        read_first_seen[0] <= 1'b1;

                    if (axi_r_beat_i && read_last_clean) begin
                        if (legacy_axi_read_accept_i) begin
                            // The response belongs to the old head.  The new
                            // same-cycle AR becomes the sole pending entry.
                            read_latency_count <= 2'd1;
                            read_latency_active <= 1'b1;
                            read_first_seen[0] <= 1'b0;
                            read_wait_live <= 64'd0;
                        end else begin
                            read_latency_count <= 2'd0;
                            read_latency_active <= 1'b0;
                            read_first_seen[0] <= 1'b0;
                            read_wait_live <= 64'd0;
                        end
                    end else if (legacy_axi_read_accept_i) begin
                        read_latency_count <= 2'd2;
                        read_latency_active <= 1'b1;
                        read_first_seen[1] <= 1'b0;
                        read_wait_second <= 64'd0;
                    end
                end

                default: begin // two queued transactions
                    if (axi_r_beat_i && !read_first_seen[0])
                        read_first_seen[0] <= 1'b1;

                    if (axi_r_beat_i && read_last_clean) begin
                        read_first_seen[0] <= read_first_seen[1];
                        read_wait_live <=
                            (!read_first_seen[1] &&
                             (read_wait_second != COUNTER_MAX)) ?
                                (read_wait_second + 64'd1) :
                                read_wait_second;
                        if (legacy_axi_read_accept_i) begin
                            read_latency_count <= 2'd2;
                            read_latency_active <= 1'b1;
                            read_first_seen[1] <= 1'b0;
                            read_wait_second <= 64'd0;
                        end else begin
                            read_latency_count <= 2'd1;
                            read_latency_active <= 1'b1;
                            read_first_seen[1] <= 1'b0;
                            read_wait_second <= 64'd0;
                        end
                    end
                    // An AR without a simultaneous retiring RLAST is a queue
                    // overflow.  It is flagged above and deliberately not
                    // stored, preserving fail-closed integrity accounting.
                end
            endcase

            if (legacy_axi_write_accept_i) begin
                write_latency_active <= 1'b1;
                write_wait_live <= 64'd0;
            end else if (write_latency_active && axi_b_response_wait_i &&
                         (write_wait_live != COUNTER_MAX)) begin
                write_wait_live <= write_wait_live + 64'd1;
            end
            if (axi_b_response_i) begin
                write_latency_active <= 1'b0;
                write_wait_live <= 64'd0;
            end

            if (done_i) begin
                profile_running_o <= 1'b0;
                profile_snapshot_valid_o <= 1'b1;
                legacy_overflow_published <= legacy_overflow_next;
                global_overflow_published <= global_overflow_next;
                opcode_count_overflow_published <=
                    opcode_count_overflow_next;
                opcode_cycle_overflow_published <=
                    opcode_cycle_overflow_next;
                histogram_overflow_published <= histogram_overflow_next;
                error_status_published <= error_status_next;
                trace_count_o <= trace_count_next;
                trace_truncated_o <= trace_truncated_next;

                for (sequential_index = 0;
                     sequential_index < PHASE_E_PROFILE_GLOBAL_COUNT;
                     sequential_index = sequential_index + 1)
                    global_published[sequential_index] <=
                        global_next[sequential_index];
                for (sequential_index = 0;
                     sequential_index < PHASE_E_PROFILE_OPCODE_SLOTS;
                     sequential_index = sequential_index + 1) begin
                    opcode_count_published[sequential_index] <=
                        opcode_count_next[sequential_index];
                    opcode_cycle_published[sequential_index] <=
                        opcode_cycle_next[sequential_index];
                end
                for (sequential_index = 0;
                     sequential_index < PHASE_E_PROFILE_HIST_COUNT;
                     sequential_index = sequential_index + 1)
                    histogram_published[sequential_index] <=
                        histogram_next[sequential_index];
            end
        end
    end

    // The trace RAM is not cleared on START.  A selector launches one
    // synchronous prefetch; valid is qualified by the published trace count.
    always_ff @(posedge clk) begin
        if (rst || start_accept_i) begin
            trace_read_address <= 8'd0;
            trace_read_pending_o <= 1'b0;
            trace_selected_valid_o <= 1'b0;
            trace_selected_meta_o <= 32'd0;
            trace_selected_cycles_o <= 64'd0;
        end else begin
            if (trace_select_strobe_i) begin
                trace_read_address <= trace_select_i;
                trace_read_pending_o <= 1'b1;
                trace_selected_valid_o <= 1'b0;
            end else if (trace_read_pending_o) begin
                trace_read_pending_o <= 1'b0;
                if (profile_snapshot_valid_o &&
                    ({1'b0, trace_read_address} < trace_count_o)) begin
                    trace_selected_meta_o <=
                        trace_memory[trace_read_address][95:64];
                    trace_selected_cycles_o <=
                        trace_memory[trace_read_address][63:0];
                    trace_selected_valid_o <= 1'b1;
                end else begin
                    trace_selected_meta_o <= 32'd0;
                    trace_selected_cycles_o <= 64'd0;
                    trace_selected_valid_o <= 1'b0;
                end
            end
        end
    end

    always_comb begin
        global_overflow_o = 64'd0;
        global_overflow_o[4:0] = legacy_overflow_published;
        global_overflow_o[
            5 +: PHASE_E_PROFILE_GLOBAL_COUNT
        ] = global_overflow_published;
    end

    assign opcode_count_overflow_o = opcode_count_overflow_published;
    assign opcode_cycle_overflow_o = opcode_cycle_overflow_published;
    assign histogram_overflow_o = histogram_overflow_published;
    assign error_status_o = error_status_published;

    genvar output_index;
    generate
        for (output_index = 0;
             output_index < PHASE_E_PROFILE_GLOBAL_COUNT;
             output_index = output_index + 1) begin : gen_global_output
            assign global_counters_flat_o[output_index*64 +: 64] =
                global_published[output_index];
        end
        for (output_index = 0;
             output_index < PHASE_E_PROFILE_OPCODE_SLOTS;
             output_index = output_index + 1) begin : gen_opcode_output
            assign opcode_counts_flat_o[output_index*64 +: 64] =
                opcode_count_published[output_index];
            assign opcode_cycles_flat_o[output_index*64 +: 64] =
                opcode_cycle_published[output_index];
        end
        for (output_index = 0;
             output_index < PHASE_E_PROFILE_HIST_COUNT;
             output_index = output_index + 1) begin : gen_histogram_output
            assign histogram_counters_flat_o[output_index*64 +: 64] =
                histogram_published[output_index];
        end
    endgenerate

endmodule
