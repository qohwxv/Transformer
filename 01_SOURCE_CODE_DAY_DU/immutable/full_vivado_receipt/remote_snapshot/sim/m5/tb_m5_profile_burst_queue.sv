`timescale 1ns/1ps

module tb_m5_profile_burst_queue;
    import vit_phase_e_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic start_accept;
    logic done;
    phase_e_profile_core_events_t core_events;
    logic ar_accept;
    logic aw_accept;
    logic legacy_stall;
    logic logical_request_backpressure;
    logic logical_response_backpressure;
    logic logical_read_wait;
    logic logical_write_wait;
    logic logical_response_error;
    logic job_error;
    logic r_beat;
    logic r_last;
    logic w_beat;
    logic b_response;
    logic ar_backpressure;
    logic aw_backpressure;
    logic w_backpressure;
    logic r_wait;
    logic b_wait;
    logic r_backpressure;
    logic b_backpressure;
    logic r_error;
    logic b_error;
    logic trace_select_strobe;
    logic [7:0] trace_select;

    logic profile_running;
    logic snapshot_valid;
    logic [44*64-1:0] global_counters;
    logic [16*64-1:0] opcode_counts;
    logic [16*64-1:0] opcode_cycles;
    logic [63:0] global_overflow;
    logic [15:0] opcode_count_overflow;
    logic [15:0] opcode_cycle_overflow;
    logic [31:0] error_status;
    logic [8:0] trace_count;
    logic trace_truncated;
    logic trace_selected_valid;
    logic trace_read_pending;
    logic [31:0] trace_meta;
    logic [63:0] trace_cycles;
    logic [18*64-1:0] histograms;
    logic [17:0] histogram_overflow;

    integer checks = 0;
    integer failures = 0;

    always #5 clk = ~clk;

    vit_phase_e_profile_counters dut (
        .clk(clk),
        .rst(rst),
        .start_accept_i(start_accept),
        .done_i(done),
        .core_events_i(core_events),
        .m7_a_vector_hit_word_delta_i(4'd0),
        .legacy_axi_read_accept_i(ar_accept),
        .legacy_axi_write_accept_i(aw_accept),
        .legacy_axi_request_stall_i(legacy_stall),
        .logical_request_backpressure_i(logical_request_backpressure),
        .logical_response_backpressure_i(logical_response_backpressure),
        .logical_read_response_wait_i(logical_read_wait),
        .logical_write_response_wait_i(logical_write_wait),
        .logical_response_error_i(logical_response_error),
        .job_error_i(job_error),
        .axi_r_beat_i(r_beat),
        .axi_w_beat_i(w_beat),
        .axi_b_response_i(b_response),
        .axi_ar_backpressure_i(ar_backpressure),
        .axi_aw_backpressure_i(aw_backpressure),
        .axi_w_backpressure_i(w_backpressure),
        .axi_r_response_wait_i(r_wait),
        .axi_b_response_wait_i(b_wait),
        .axi_r_response_backpressure_i(r_backpressure),
        .axi_b_response_backpressure_i(b_backpressure),
        .axi_r_last_i(r_last),
        .axi_r_error_i(r_error),
        .axi_b_error_i(b_error),
        .trace_select_strobe_i(trace_select_strobe),
        .trace_select_i(trace_select),
        .profile_running_o(profile_running),
        .profile_snapshot_valid_o(snapshot_valid),
        .global_counters_flat_o(global_counters),
        .opcode_counts_flat_o(opcode_counts),
        .opcode_cycles_flat_o(opcode_cycles),
        .global_overflow_o(global_overflow),
        .opcode_count_overflow_o(opcode_count_overflow),
        .opcode_cycle_overflow_o(opcode_cycle_overflow),
        .error_status_o(error_status),
        .trace_count_o(trace_count),
        .trace_truncated_o(trace_truncated),
        .trace_selected_valid_o(trace_selected_valid),
        .trace_read_pending_o(trace_read_pending),
        .trace_selected_meta_o(trace_meta),
        .trace_selected_cycles_o(trace_cycles),
        .histogram_counters_flat_o(histograms),
        .histogram_overflow_o(histogram_overflow)
    );

    function automatic logic [63:0] global_counter(input integer index);
        global_counter = global_counters[index*64 +: 64];
    endfunction

    function automatic logic [63:0] histogram(input integer index);
        histogram = histograms[index*64 +: 64];
    endfunction

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (!condition) begin
                failures = failures + 1;
                $error("M5 BURST PROFILE CHECK FAILED: %s", message);
            end
        end
    endtask

    task automatic clear_events;
        begin
            start_accept = 1'b0;
            done = 1'b0;
            core_events = '0;
            ar_accept = 1'b0;
            aw_accept = 1'b0;
            legacy_stall = 1'b0;
            logical_request_backpressure = 1'b0;
            logical_response_backpressure = 1'b0;
            logical_read_wait = 1'b0;
            logical_write_wait = 1'b0;
            logical_response_error = 1'b0;
            job_error = 1'b0;
            r_beat = 1'b0;
            r_last = 1'b0;
            w_beat = 1'b0;
            b_response = 1'b0;
            ar_backpressure = 1'b0;
            aw_backpressure = 1'b0;
            w_backpressure = 1'b0;
            r_wait = 1'b0;
            b_wait = 1'b0;
            r_backpressure = 1'b0;
            b_backpressure = 1'b0;
            r_error = 1'b0;
            b_error = 1'b0;
            trace_select_strobe = 1'b0;
            trace_select = 8'd0;
        end
    endtask

    task automatic sample_edge;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic pulse_ar;
        begin
            @(negedge clk);
            clear_events();
            ar_accept = 1'b1;
            sample_edge();
        end
    endtask

    task automatic pulse_r(input logic last_value);
        begin
            @(negedge clk);
            clear_events();
            r_beat = 1'b1;
            r_last = last_value;
            sample_edge();
        end
    endtask

    initial begin
        clear_events();
        repeat (3) sample_edge();
        @(negedge clk);
        rst = 1'b0;
        start_accept = 1'b1;
        sample_edge();
        clear_events();

        // Two legal same-ID ARs overlap.  Each response is a four-beat burst.
        pulse_ar();
        pulse_ar();
        repeat (2) begin
            @(negedge clk);
            clear_events();
            sample_edge();
        end
        pulse_r(1'b0);
        pulse_r(1'b0);
        pulse_r(1'b0);
        pulse_r(1'b1);
        pulse_r(1'b0);
        pulse_r(1'b0);
        pulse_r(1'b0);
        pulse_r(1'b1);

        @(negedge clk);
        clear_events();
        done = 1'b1;
        sample_edge();
        clear_events();

        check(snapshot_valid && !profile_running,
              "DONE publishes the burst-safe snapshot");
        check(error_status == 32'd0,
              "two legal overlapping bursts raise no integrity error");
        check(global_counter(PHASE_E_PROFILE_GLOBAL_R_BEATS) == 64'd8,
              "all eight physical R beats counted");
        check(histogram(2) == 64'd1,
              "first AR-to-first-R latency lands in 2..3 bucket");
        check(histogram(3) == 64'd1,
              "second AR-to-first-R latency lands in 4..7 bucket");
        check(histogram(0) + histogram(1) + histogram(2) + histogram(3) +
              histogram(4) + histogram(5) + histogram(6) + histogram(7)
              == 64'd2,
              "only the first beat of each burst updates the histogram");
        check(histogram(16) == 64'd6,
              "published maximum is AR-to-first-R for queued burst two");

        // At full depth an RLAST and new AR may handshake together.  The
        // ordered queue must pop the old head and push the new tail without a
        // transient overflow or lost descriptor.
        @(negedge clk);
        start_accept = 1'b1;
        sample_edge();
        clear_events();
        pulse_ar();
        pulse_ar();
        @(negedge clk);
        clear_events();
        ar_accept = 1'b1;
        r_beat = 1'b1;
        r_last = 1'b1;
        sample_edge();
        pulse_r(1'b1);
        pulse_r(1'b1);
        @(negedge clk);
        clear_events();
        done = 1'b1;
        sample_edge();
        clear_events();
        check(error_status == 32'd0,
              "full-queue simultaneous pop/push is legal");
        check(global_counter(PHASE_E_PROFILE_GLOBAL_R_BEATS) == 64'd3,
              "pop/push epoch retains all three responses");
        check(histogram(0) + histogram(1) + histogram(2) + histogram(3) +
              histogram(4) + histogram(5) + histogram(6) + histogram(7)
              == 64'd3,
              "pop/push epoch accounts for all three first responses");

        // A third AR without a retiring RLAST exceeds the supported depth.
        @(negedge clk);
        start_accept = 1'b1;
        sample_edge();
        clear_events();
        pulse_ar();
        pulse_ar();
        pulse_ar();
        @(negedge clk);
        clear_events();
        done = 1'b1;
        sample_edge();
        check(error_status[12], "third AR reports queue overflow in bit 12");
        check(error_status[18], "DONE detects outstanding read transactions");

        if (failures == 0)
            $display("M5_PROFILE_BURST_QUEUE_PASS checks=%0d", checks);
        else
            $fatal(1, "M5 profile burst queue failures=%0d checks=%0d",
                   failures, checks);
        $finish;
    end
endmodule
