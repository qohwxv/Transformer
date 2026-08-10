`timescale 1ns/1ps

module tb_vit_phase_e_profile_counters;

    import vit_phase_e_pkg::*;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic start_accept;
    logic done;
    phase_e_profile_core_events_t core_events;
    logic [3:0] m7_a_vector_hit_word_delta;
    logic legacy_axi_read_accept;
    logic legacy_axi_write_accept;
    logic legacy_axi_request_stall;
    logic logical_request_backpressure;
    logic logical_response_backpressure;
    logic logical_read_response_wait;
    logic logical_write_response_wait;
    logic logical_response_error;
    logic job_error;
    logic axi_r_beat;
    logic axi_w_beat;
    logic axi_b_response;
    logic axi_ar_backpressure;
    logic axi_aw_backpressure;
    logic axi_w_backpressure;
    logic axi_r_response_wait;
    logic axi_b_response_wait;
    logic axi_r_response_backpressure;
    logic axi_b_response_backpressure;
    logic axi_r_error;
    logic axi_b_error;
    logic trace_select_strobe;
    logic [7:0] trace_select;

    logic profile_running;
    logic profile_snapshot_valid;
    logic [PHASE_E_PROFILE_GLOBAL_COUNT*64-1:0] global_counters_flat;
    logic [PHASE_E_PROFILE_OPCODE_SLOTS*64-1:0] opcode_counts_flat;
    logic [PHASE_E_PROFILE_OPCODE_SLOTS*64-1:0] opcode_cycles_flat;
    logic [63:0] global_overflow;
    logic [15:0] opcode_count_overflow;
    logic [15:0] opcode_cycle_overflow;
    logic [31:0] error_status;
    logic [8:0] trace_count;
    logic trace_truncated;
    logic trace_selected_valid;
    logic trace_read_pending;
    logic [31:0] trace_selected_meta;
    logic [63:0] trace_selected_cycles;
    logic [PHASE_E_PROFILE_HIST_COUNT*64-1:0]
        histogram_counters_flat;
    logic [17:0] histogram_overflow;
    logic [63:0] expected_global [0:PHASE_E_PROFILE_GLOBAL_COUNT-1];

    integer checks = 0;
    integer failures = 0;
    integer command_index;

    always #5 clk = ~clk;

    vit_phase_e_profile_counters dut (
        .clk(clk),
        .rst(rst),
        .start_accept_i(start_accept),
        .done_i(done),
        .core_events_i(core_events),
        .m7_a_vector_hit_word_delta_i(m7_a_vector_hit_word_delta),
        .legacy_axi_read_accept_i(legacy_axi_read_accept),
        .legacy_axi_write_accept_i(legacy_axi_write_accept),
        .legacy_axi_request_stall_i(legacy_axi_request_stall),
        .logical_request_backpressure_i(logical_request_backpressure),
        .logical_response_backpressure_i(logical_response_backpressure),
        .logical_read_response_wait_i(logical_read_response_wait),
        .logical_write_response_wait_i(logical_write_response_wait),
        .logical_response_error_i(logical_response_error),
        .job_error_i(job_error),
        .axi_r_beat_i(axi_r_beat),
        .axi_w_beat_i(axi_w_beat),
        .axi_b_response_i(axi_b_response),
        .axi_ar_backpressure_i(axi_ar_backpressure),
        .axi_aw_backpressure_i(axi_aw_backpressure),
        .axi_w_backpressure_i(axi_w_backpressure),
        .axi_r_response_wait_i(axi_r_response_wait),
        .axi_b_response_wait_i(axi_b_response_wait),
        .axi_r_response_backpressure_i(axi_r_response_backpressure),
        .axi_b_response_backpressure_i(axi_b_response_backpressure),
        .axi_r_last_i(axi_r_beat),
        .axi_r_error_i(axi_r_error),
        .axi_b_error_i(axi_b_error),
        .trace_select_strobe_i(trace_select_strobe),
        .trace_select_i(trace_select),
        .profile_running_o(profile_running),
        .profile_snapshot_valid_o(profile_snapshot_valid),
        .global_counters_flat_o(global_counters_flat),
        .opcode_counts_flat_o(opcode_counts_flat),
        .opcode_cycles_flat_o(opcode_cycles_flat),
        .global_overflow_o(global_overflow),
        .opcode_count_overflow_o(opcode_count_overflow),
        .opcode_cycle_overflow_o(opcode_cycle_overflow),
        .error_status_o(error_status),
        .trace_count_o(trace_count),
        .trace_truncated_o(trace_truncated),
        .trace_selected_valid_o(trace_selected_valid),
        .trace_read_pending_o(trace_read_pending),
        .trace_selected_meta_o(trace_selected_meta),
        .trace_selected_cycles_o(trace_selected_cycles),
        .histogram_counters_flat_o(histogram_counters_flat),
        .histogram_overflow_o(histogram_overflow)
    );

    function automatic logic [63:0] global_counter(input integer index);
        global_counter = global_counters_flat[index*64 +: 64];
    endfunction

    function automatic logic [63:0] opcode_count(input integer index);
        opcode_count = opcode_counts_flat[index*64 +: 64];
    endfunction

    function automatic logic [63:0] opcode_cycles(input integer index);
        opcode_cycles = opcode_cycles_flat[index*64 +: 64];
    endfunction

    function automatic logic [63:0] histogram_counter(input integer index);
        histogram_counter = histogram_counters_flat[index*64 +: 64];
    endfunction

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $error("PROFILE COUNTER CHECK FAILED: %s", message);
            end
        end
    endtask

    task automatic clear_events;
        begin
            start_accept = 1'b0;
            done = 1'b0;
            core_events = '0;
            m7_a_vector_hit_word_delta = 4'd0;
            legacy_axi_read_accept = 1'b0;
            legacy_axi_write_accept = 1'b0;
            legacy_axi_request_stall = 1'b0;
            logical_request_backpressure = 1'b0;
            logical_response_backpressure = 1'b0;
            logical_read_response_wait = 1'b0;
            logical_write_response_wait = 1'b0;
            logical_response_error = 1'b0;
            job_error = 1'b0;
            axi_r_beat = 1'b0;
            axi_w_beat = 1'b0;
            axi_b_response = 1'b0;
            axi_ar_backpressure = 1'b0;
            axi_aw_backpressure = 1'b0;
            axi_w_backpressure = 1'b0;
            axi_r_response_wait = 1'b0;
            axi_b_response_wait = 1'b0;
            axi_r_response_backpressure = 1'b0;
            axi_b_response_backpressure = 1'b0;
            axi_r_error = 1'b0;
            axi_b_error = 1'b0;
            trace_select_strobe = 1'b0;
            trace_select = 8'd0;
        end
    endtask

    task automatic sample_edge;
        begin
            @(posedge clk);
            #1;
            clear_events();
        end
    endtask

    task automatic start_job;
        begin
            @(negedge clk);
            clear_events();
            start_accept = 1'b1;
            sample_edge();
            check(profile_running, "START enters profile-running state");
            check(!profile_snapshot_valid, "START invalidates snapshot");
        end
    endtask

    task automatic accept_command(
        input logic [3:0] opcode,
        input logic [7:0] tag,
        input logic [1:0] section,
        input logic [3:0] layer,
        input logic [4:0] step
    );
        begin
            @(negedge clk);
            clear_events();
            core_events.command_accept = 1'b1;
            core_events.command_opcode = phase_e_opcode_t'(opcode);
            core_events.command_tag = tag;
            core_events.command_section = phase_e_section_t'(section);
            core_events.command_layer = layer;
            core_events.command_step = step;
            sample_edge();
        end
    endtask

    task automatic complete_command(input logic with_error);
        begin
            @(negedge clk);
            clear_events();
            core_events.command_complete = 1'b1;
            core_events.command_error = with_error;
            sample_edge();
        end
    endtask

    task automatic idle_active_cycle;
        begin
            @(negedge clk);
            clear_events();
            sample_edge();
        end
    endtask

    task automatic finish_job(input logic with_error);
        begin
            @(negedge clk);
            clear_events();
            done = 1'b1;
            job_error = with_error;
            sample_edge();
            check(!profile_running, "DONE leaves profile-running state");
            check(profile_snapshot_valid, "DONE publishes snapshot");
        end
    endtask

    task automatic select_trace(input logic [7:0] index);
        begin
            @(negedge clk);
            clear_events();
            trace_select = index;
            trace_select_strobe = 1'b1;
            @(posedge clk);
            #1;
            clear_events();
            check(trace_read_pending, "trace selector starts prefetch");
            @(posedge clk);
            #1;
            check(!trace_read_pending, "trace prefetch completes next cycle");
        end
    endtask

    initial begin
        clear_events();
        repeat (3)
            @(posedge clk);
        #1;
        check(!profile_running && !profile_snapshot_valid, "reset status");
        check(global_overflow == 0, "reset global overflow");
        check(error_status == 0, "reset error status");
        check(trace_count == 0 && !trace_truncated, "reset trace status");

        @(negedge clk);
        rst = 1'b0;

        // Successful two-command job with independently constructed events.
        start_job();
        accept_command(
            PHASE_E_OP_GEMM,
            8'h21,
            PHASE_E_SECTION_ENCODER,
            4'd3,
            5'd8
        );

        // GEMM active interval 1: physical A-cache miss and one AXI read.
        @(negedge clk);
        clear_events();
        core_events.logical_read_word = 1'b1;
        core_events.load_active = 1'b1;
        core_events.a_cache_lookup = 1'b1;
        core_events.a_cache_miss = 1'b1;
        legacy_axi_read_accept = 1'b1;
        sample_edge();

        // Interval 2: cached logical read overlaps load and compute.
        @(negedge clk);
        clear_events();
        core_events.logical_read_word = 1'b1;
        core_events.load_active = 1'b1;
        core_events.compute_active = 1'b1;
        core_events.a_cache_lookup = 1'b1;
        core_events.a_cache_hit = 1'b1;
        axi_r_response_wait = 1'b1;
        logical_read_response_wait = 1'b1;
        sample_edge();

        // Interval 3: first 2x2x16 tile step and explicit request BP.
        @(negedge clk);
        clear_events();
        core_events.compute_active = 1'b1;
        core_events.gemm_tile_step = 1'b1;
        core_events.gemm_valid_mac_delta = 16'd10;
        core_events.gemm_tail_mac_delta = 16'd54;
        logical_request_backpressure = 1'b1;
        legacy_axi_request_stall = 1'b1;
        axi_ar_backpressure = 1'b1;
        axi_r_response_wait = 1'b1;
        logical_read_response_wait = 1'b1;
        sample_edge();

        // Interval 4: full tile plus the single read response beat.
        @(negedge clk);
        clear_events();
        core_events.compute_active = 1'b1;
        core_events.gemm_tile_step = 1'b1;
        core_events.gemm_valid_mac_delta = 16'd64;
        core_events.gemm_tail_mac_delta = 16'd0;
        axi_r_beat = 1'b1;
        sample_edge();

        // Interval 5 is the GEMM terminal edge and one logical/AXI write.
        @(negedge clk);
        clear_events();
        core_events.command_complete = 1'b1;
        core_events.logical_write_word = 1'b1;
        core_events.store_active = 1'b1;
        legacy_axi_write_accept = 1'b1;
        axi_w_beat = 1'b1;
        sample_edge();

        // One write-response wait cycle and the response itself.
        @(negedge clk);
        clear_events();
        axi_b_response_wait = 1'b1;
        logical_write_response_wait = 1'b1;
        sample_edge();
        @(negedge clk);
        clear_events();
        axi_b_response = 1'b1;
        sample_edge();

        accept_command(
            PHASE_E_OP_VECTOR,
            8'h22,
            PHASE_E_SECTION_FINAL,
            4'd0,
            5'd1
        );
        @(negedge clk);
        clear_events();
        core_events.compute_active = 1'b1;
        sample_edge();
        complete_command(1'b0);
        finish_job(1'b0);

        check(trace_count == 9'd2, "two completed commands traced");
        check(!trace_truncated, "successful trace is not truncated");
        check(global_overflow == 0, "successful job has no overflow");
        check(opcode_count_overflow == 0, "opcode counts do not overflow");
        check(opcode_cycle_overflow == 0, "opcode cycles do not overflow");
        check(histogram_overflow == 0, "histogram does not overflow");
        check(error_status == 0, "successful job has no typed error");

        // Assert every event-to-counter mapping, including expected-zero
        // paths. Case-inequality in check() makes any X/Z value fail.
        for (command_index = 0;
             command_index < PHASE_E_PROFILE_GLOBAL_COUNT;
             command_index = command_index + 1)
            expected_global[command_index] = 64'd0;
        expected_global[PHASE_E_PROFILE_GLOBAL_LOGICAL_READ] = 64'd2;
        expected_global[PHASE_E_PROFILE_GLOBAL_LOGICAL_WRITE] = 64'd1;
        expected_global[PHASE_E_PROFILE_GLOBAL_R_BEATS] = 64'd1;
        expected_global[PHASE_E_PROFILE_GLOBAL_W_BEATS] = 64'd1;
        expected_global[PHASE_E_PROFILE_GLOBAL_COMMAND_ACTIVE] = 64'd7;
        expected_global[PHASE_E_PROFILE_GLOBAL_LOGICAL_REQ_BP] = 64'd1;
        expected_global[PHASE_E_PROFILE_GLOBAL_AR_BP] = 64'd1;
        expected_global[PHASE_E_PROFILE_GLOBAL_R_WAIT] = 64'd2;
        expected_global[PHASE_E_PROFILE_GLOBAL_B_WAIT] = 64'd1;
        expected_global[PHASE_E_PROFILE_GLOBAL_LOAD] = 64'd2;
        expected_global[PHASE_E_PROFILE_GLOBAL_COMPUTE] = 64'd4;
        expected_global[PHASE_E_PROFILE_GLOBAL_STORE] = 64'd1;
        expected_global[PHASE_E_PROFILE_GLOBAL_UNION] = 64'd6;
        expected_global[PHASE_E_PROFILE_GLOBAL_OVERLAP] = 64'd1;
        expected_global[PHASE_E_PROFILE_GLOBAL_CACHE_LOOKUP] = 64'd2;
        expected_global[PHASE_E_PROFILE_GLOBAL_CACHE_HIT] = 64'd1;
        expected_global[PHASE_E_PROFILE_GLOBAL_CACHE_MISS] = 64'd1;
        expected_global[PHASE_E_PROFILE_GLOBAL_GEMM_TILE_STEPS] = 64'd2;
        expected_global[PHASE_E_PROFILE_GLOBAL_VALID_MAC] = 64'd74;
        expected_global[PHASE_E_PROFILE_GLOBAL_TAIL_MAC] = 64'd54;
        expected_global[PHASE_E_PROFILE_GLOBAL_B_RESPONSES] = 64'd1;
        expected_global[PHASE_E_PROFILE_GLOBAL_A_LOOKUP] = 64'd2;
        expected_global[PHASE_E_PROFILE_GLOBAL_A_HIT] = 64'd1;
        expected_global[PHASE_E_PROFILE_GLOBAL_A_MISS] = 64'd1;
        expected_global[
            PHASE_E_PROFILE_GLOBAL_LOAD_COMPUTE_OVERLAP
        ] = 64'd1;
        expected_global[
            PHASE_E_PROFILE_GLOBAL_LOGICAL_READ_RSP_WAIT
        ] = 64'd2;
        expected_global[
            PHASE_E_PROFILE_GLOBAL_LOGICAL_WRITE_RSP_WAIT
        ] = 64'd1;
        for (command_index = 0;
             command_index < PHASE_E_PROFILE_GLOBAL_COUNT;
             command_index = command_index + 1)
            check(
                global_counter(command_index) ===
                    expected_global[command_index],
                $sformatf(
                    "global counter %0d matches its event stream",
                    command_index
                )
            );

        check(
            global_counter(PHASE_E_PROFILE_GLOBAL_LOGICAL_READ) == 2,
            "logical reads include one cache miss and one hit"
        );
        check(
            global_counter(PHASE_E_PROFILE_GLOBAL_LOGICAL_WRITE) == 1,
            "logical write count"
        );
        check(
            global_counter(PHASE_E_PROFILE_GLOBAL_R_BEATS) == 1,
            "AXI R beat count"
        );
        check(
            global_counter(PHASE_E_PROFILE_GLOBAL_W_BEATS) == 1,
            "AXI W beat count"
        );
        check(
            global_counter(PHASE_E_PROFILE_GLOBAL_B_RESPONSES) == 1,
            "AXI B response count"
        );
        check(
            global_counter(PHASE_E_PROFILE_GLOBAL_COMMAND_ACTIVE) == 7,
            "accepted-to-terminal command intervals"
        );
        check(
            global_counter(PHASE_E_PROFILE_GLOBAL_LOAD) == 2,
            "load-active cycles"
        );
        check(
            global_counter(PHASE_E_PROFILE_GLOBAL_COMPUTE) == 4,
            "compute-active cycles"
        );
        check(
            global_counter(PHASE_E_PROFILE_GLOBAL_STORE) == 1,
            "store-active cycles"
        );
        check(
            global_counter(PHASE_E_PROFILE_GLOBAL_UNION) == 6,
            "stage union cycles"
        );
        check(
            global_counter(PHASE_E_PROFILE_GLOBAL_OVERLAP) == 1,
            "stage overlap cycles"
        );
        check(
            global_counter(PHASE_E_PROFILE_GLOBAL_LOAD_COMPUTE_OVERLAP) == 1,
            "load/compute overlap"
        );
        check(
            global_counter(PHASE_E_PROFILE_GLOBAL_CACHE_LOOKUP) == 2 &&
            global_counter(PHASE_E_PROFILE_GLOBAL_CACHE_HIT) == 1 &&
            global_counter(PHASE_E_PROFILE_GLOBAL_CACHE_MISS) == 1,
            "cache lookup equals hit plus miss"
        );
        check(
            global_counter(PHASE_E_PROFILE_GLOBAL_GEMM_TILE_STEPS) == 2,
            "GEMM tile-step count"
        );
        check(
            global_counter(PHASE_E_PROFILE_GLOBAL_VALID_MAC) == 74 &&
            global_counter(PHASE_E_PROFILE_GLOBAL_TAIL_MAC) == 54,
            "valid plus tail MAC slots equal two 2x2x16 steps"
        );
        check(
            global_counter(PHASE_E_PROFILE_GLOBAL_R_WAIT) == 2 &&
            global_counter(PHASE_E_PROFILE_GLOBAL_B_WAIT) == 1,
            "AXI response-wait cycles"
        );
        check(
            global_counter(PHASE_E_PROFILE_GLOBAL_LOGICAL_READ_RSP_WAIT) == 2 &&
            global_counter(PHASE_E_PROFILE_GLOBAL_LOGICAL_WRITE_RSP_WAIT) == 1,
            "logical response-wait cycles"
        );
        check(
            opcode_count(PHASE_E_OP_GEMM) == 1 &&
            opcode_count(PHASE_E_OP_VECTOR) == 1,
            "per-opcode command counts"
        );
        check(
            opcode_cycles(PHASE_E_OP_GEMM) == 5 &&
            opcode_cycles(PHASE_E_OP_VECTOR) == 2,
            "per-opcode active cycles"
        );
        check(
            histogram_counter(2) == 1 && histogram_counter(16) == 2,
            "read response wait bucket 2-3 and max"
        );
        check(
            histogram_counter(9) == 1 && histogram_counter(17) == 1,
            "write response wait bucket 1 and max"
        );

        select_trace(8'd0);
        check(trace_selected_valid, "trace entry zero valid");
        check(trace_selected_cycles == 5, "GEMM command duration is five");
        check(trace_selected_meta[3:0] == PHASE_E_OP_GEMM, "trace opcode");
        check(trace_selected_meta[11:4] == 8'h21, "trace tag");
        check(trace_selected_meta[12] == 0, "trace success bit");
        check(trace_selected_meta[16:14] == {1'b0, PHASE_E_SECTION_ENCODER},
              "trace section");
        check(trace_selected_meta[20:17] == 4'd3, "trace layer");
        check(trace_selected_meta[25:21] == 5'd8, "trace step");
        select_trace(8'd1);
        check(trace_selected_valid && trace_selected_cycles == 2,
              "second trace duration");
        select_trace(8'd2);
        check(!trace_selected_valid, "index equal to trace count is invalid");

        // Events after DONE must not alter a published snapshot.
        @(negedge clk);
        clear_events();
        core_events.logical_read_word = 1'b1;
        core_events.command_accept = 1'b1;
        sample_edge();
        check(
            global_counter(PHASE_E_PROFILE_GLOBAL_LOGICAL_READ) == 2,
            "published snapshot freezes after DONE"
        );

        // M7 vector-cache service credits exact logical words without
        // changing the frozen profile-v1.2 register map or event struct.
        start_job();
        @(negedge clk);
        clear_events();
        m7_a_vector_hit_word_delta = 4'd8;
        sample_edge();
        finish_job(1'b0);
        check(
            global_counter(PHASE_E_PROFILE_GLOBAL_LOGICAL_READ) == 8,
            "vector cache delta credits eight logical reads"
        );
        check(
            global_counter(PHASE_E_PROFILE_GLOBAL_CACHE_LOOKUP) == 8 &&
            global_counter(PHASE_E_PROFILE_GLOBAL_CACHE_HIT) == 8 &&
            global_counter(PHASE_E_PROFILE_GLOBAL_CACHE_MISS) == 0,
            "vector cache delta preserves aggregate lookup=hit+miss"
        );
        check(
            global_counter(PHASE_E_PROFILE_GLOBAL_A_LOOKUP) == 8 &&
            global_counter(PHASE_E_PROFILE_GLOBAL_A_HIT) == 8 &&
            global_counter(PHASE_E_PROFILE_GLOBAL_A_MISS) == 0,
            "vector cache delta preserves exact A-cache word counters"
        );

        // Trace boundary: entry 257 is dropped and must not overwrite entry 0.
        start_job();
        for (command_index = 0; command_index < 257;
             command_index = command_index + 1) begin
            accept_command(
                PHASE_E_OP_LAYOUT,
                command_index[7:0],
                PHASE_E_SECTION_ENCODER,
                command_index % 12,
                command_index % 20
            );
            if (command_index == 256)
                idle_active_cycle();
            complete_command(1'b0);
        end
        finish_job(1'b0);
        check(trace_count == 9'd256, "trace count saturates at 256");
        check(trace_truncated, "257th terminal marks trace truncated");
        check(
            global_counter(PHASE_E_PROFILE_GLOBAL_TRACE_DROPPED) == 1,
            "exactly one trace entry dropped"
        );
        check(opcode_count(PHASE_E_OP_LAYOUT) == 257,
              "opcode count includes dropped trace command");
        check(opcode_cycles(PHASE_E_OP_LAYOUT) == 258,
              "opcode cycles include longer dropped command");
        check(error_status[9], "trace truncation is a typed profiler error");
        select_trace(8'd0);
        check(trace_selected_valid && trace_selected_cycles == 1,
              "entry zero was not overwritten by command 257");
        select_trace(8'd255);
        check(trace_selected_valid && trace_selected_cycles == 1,
              "entry 255 is retained");

        // Direct near-maximum injection proves all overflow classes without a
        // 2^64-cycle simulation.
        start_job();
        @(negedge clk);
        dut.legacy_live[0] = 64'hffff_ffff_ffff_ffff;
        dut.global_live[PHASE_E_PROFILE_GLOBAL_LOGICAL_READ] =
            64'hffff_ffff_ffff_ffff;
        dut.opcode_count_live[PHASE_E_OP_GEMM] =
            64'hffff_ffff_ffff_ffff;
        dut.histogram_live[0] = 64'hffff_ffff_ffff_ffff;
        clear_events();
        core_events.command_accept = 1'b1;
        core_events.command_opcode = PHASE_E_OP_GEMM;
        core_events.command_tag = 8'h5a;
        core_events.command_section = PHASE_E_SECTION_FINAL;
        core_events.logical_read_word = 1'b1;
        m7_a_vector_hit_word_delta = 4'd8;
        legacy_axi_read_accept = 1'b1;
        legacy_axi_write_accept = 1'b1;
        axi_r_beat = 1'b1;
        axi_b_response = 1'b1;
        sample_edge();

        @(negedge clk);
        dut.read_latency_active = 1'b1;
        dut.write_latency_active = 1'b1;
        dut.read_wait_live = 64'hffff_ffff_ffff_ffff;
        dut.write_wait_live = 64'hffff_ffff_ffff_ffff;
        dut.opcode_cycle_live[PHASE_E_OP_GEMM] =
            64'hffff_ffff_ffff_ffff;
        clear_events();
        axi_r_response_wait = 1'b1;
        axi_b_response_wait = 1'b1;
        sample_edge();

        @(negedge clk);
        dut.command_duration_live = 64'hffff_ffff_ffff_ffff;
        clear_events();
        core_events.command_complete = 1'b1;
        axi_r_beat = 1'b1;
        axi_b_response = 1'b1;
        sample_edge();
        finish_job(1'b0);

        check(global_overflow[0], "legacy job-cycle overflow bit");
        check(
            global_overflow[5 + PHASE_E_PROFILE_GLOBAL_LOGICAL_READ],
            "extended global overflow bit"
        );
        check(
            global_counter(PHASE_E_PROFILE_GLOBAL_LOGICAL_READ) == 8,
            "scalar plus vector delta wraps modulo 2^64 after overflow"
        );
        check(opcode_count_overflow[PHASE_E_OP_GEMM],
              "opcode-count overflow bit");
        check(opcode_cycle_overflow[PHASE_E_OP_GEMM],
              "opcode-cycle overflow bit");
        check(histogram_overflow[0], "histogram overflow bit");
        check(histogram_overflow[16] && histogram_overflow[17],
              "read/write maximum latency overflow bits");
        check(error_status[14] && error_status[15],
              "read/write latency-overflow typed errors");
        check(histogram_counter(16) == 64'hffff_ffff_ffff_ffff,
              "read maximum latency saturates");
        check(histogram_counter(17) == 64'hffff_ffff_ffff_ffff,
              "write maximum latency saturates");
        check(error_status[16], "command-duration overflow error bit");
        select_trace(8'd0);
        check(trace_selected_valid, "overflow trace entry remains readable");
        check(trace_selected_meta[13], "trace duration-overflow metadata bit");
        check(trace_selected_cycles == 0,
              "command duration retains modulo-2^64 value");

        // Positive activation of the remaining typed event/protocol errors.
        start_job();
        accept_command(
            PHASE_E_OP_GEMM,
            8'h60,
            PHASE_E_SECTION_ENCODER,
            4'd1,
            5'd2
        );
        @(negedge clk);
        clear_events();
        core_events.command_accept = 1'b1;
        core_events.command_opcode = phase_e_opcode_t'(4'hf);
        core_events.command_error = 1'b1;
        core_events.frontend_error = 1'b1;
        logical_response_error = 1'b1;
        job_error = 1'b1;
        axi_r_error = 1'b1;
        axi_b_error = 1'b1;
        axi_r_beat = 1'b1;
        axi_b_response = 1'b1;
        trace_select_strobe = 1'b1;
        sample_edge();
        complete_command(1'b0);
        complete_command(1'b0);
        finish_job(1'b0);

        for (command_index = 0; command_index <= 8;
             command_index = command_index + 1)
            check(
                error_status[command_index],
                $sformatf("typed error bit %0d activates", command_index)
            );
        check(error_status[10], "R-without-AR error activates");
        check(error_status[11], "B-without-AW error activates");
        check(error_status[17], "trace-select-while-running activates");
        check(
            global_counter(PHASE_E_PROFILE_GLOBAL_COMMAND_ERRORS) == 1,
            "command-error counter activates"
        );
        check(
            global_counter(
                PHASE_E_PROFILE_GLOBAL_AXI_RESPONSE_ERRORS
            ) == 2,
            "AXI response-error counter activates"
        );
        check(
            global_counter(
                PHASE_E_PROFILE_GLOBAL_LOGICAL_RSP_ERRORS
            ) == 1,
            "logical response-error counter activates"
        );
        check(
            global_counter(PHASE_E_PROFILE_GLOBAL_JOB_ERRORS) == 1,
            "job-error counter activates"
        );

        // Outstanding/reissued address faults are separate from response
        // faults and must be sticky through the terminal publication.  M5
        // permits two ordered read ARs, so the third read AR is the overflow;
        // writes intentionally retain their one-outstanding contract.
        start_job();
        @(negedge clk);
        clear_events();
        legacy_axi_read_accept = 1'b1;
        legacy_axi_write_accept = 1'b1;
        sample_edge();
        @(negedge clk);
        clear_events();
        legacy_axi_read_accept = 1'b1;
        legacy_axi_write_accept = 1'b1;
        sample_edge();
        @(negedge clk);
        clear_events();
        legacy_axi_read_accept = 1'b1;
        sample_edge();
        finish_job(1'b0);
        check(error_status[12], "AR queue-overflow error activates");
        check(error_status[13], "AW-while-active error activates");
        check(error_status[18], "DONE-with-read-active error activates");
        check(error_status[19], "DONE-with-write-active error activates");

        @(negedge clk);
        rst = 1'b1;
        @(posedge clk);
        #1;
        check(!profile_running && !profile_snapshot_valid,
              "final reset clears status");
        check(global_overflow == 0 && error_status == 0,
              "final reset clears sticky publication");

        if (failures == 0)
            $display(
                "VIT_PHASE_E_PROFILE_COUNTERS_TEST_PASS checks=%0d",
                checks
            );
        else
            $fatal(
                1,
                "profile counter failures=%0d checks=%0d",
                failures,
                checks
            );
        $finish;
    end

endmodule
