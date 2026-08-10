`timescale 1ns/1ps

module tb_vit_phase_e_m7_overlap_counters;
    import vit_phase_e_pkg::*;

    localparam logic [1:0] RESP_OKAY = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;
    localparam logic [11:0] REG_IP_VERSION = 12'h004;
    localparam logic [11:0] REG_M5_LAST = 12'h80c;
    localparam logic [11:0] REG_M7_CAPABILITY = 12'h810;
    localparam logic [11:0] REG_M7_STATUS = 12'h814;
    localparam logic [11:0] REG_M7_OVF_LO = 12'h818;
    localparam logic [11:0] REG_M7_OVF_HI = 12'h81c;
    localparam logic [11:0] REG_M7_ERROR = 12'h820;
    localparam logic [11:0] REG_M7_GEOMETRY = 12'h824;
    localparam logic [11:0] REG_M7_BUFFER_CONFIG = 12'h828;
    localparam logic [11:0] REG_M7_NUMERIC_CONFIG = 12'h82c;
    localparam logic [11:0] REG_M7_COUNTER_BASE = 12'h830;
    localparam logic [11:0] REG_M7_COUNTER_LAST = 12'h8e4;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic start_accept = 1'b0;
    logic done = 1'b0;
    phase_e_m7_profile_events_t events = '0;

    logic running;
    logic snapshot_valid;
    logic [31:0] capability;
    logic [31:0] status;
    logic [63:0] overflow;
    logic [31:0] error_status;
    logic [31:0] geometry;
    logic [31:0] buffer_config;
    logic [31:0] numeric_config;
    logic [PHASE_E_M7_COUNTER_COUNT*64-1:0] counters;

    logic [11:0] s_axi_awaddr = 12'd0;
    logic [2:0] s_axi_awprot = 3'd0;
    logic s_axi_awvalid = 1'b0;
    logic s_axi_awready;
    logic [31:0] s_axi_wdata = 32'd0;
    logic [3:0] s_axi_wstrb = 4'd0;
    logic s_axi_wvalid = 1'b0;
    logic s_axi_wready;
    logic [1:0] s_axi_bresp;
    logic s_axi_bvalid;
    logic s_axi_bready = 1'b1;
    logic [11:0] s_axi_araddr = 12'd0;
    logic [2:0] s_axi_arprot = 3'd0;
    logic s_axi_arvalid = 1'b0;
    logic s_axi_arready;
    logic [31:0] s_axi_rdata;
    logic [1:0] s_axi_rresp;
    logic s_axi_rvalid;
    logic s_axi_rready = 1'b1;

    logic [63:0] expected [0:PHASE_E_M7_COUNTER_COUNT-1];
    integer checks = 0;
    integer failures = 0;
    integer counter_index;
    integer stage_pattern;

    always #5 clk = ~clk;

    vit_phase_e_m7_overlap_counters #(
        .STREAMS(8),
        .RESULT_FIFO_DEPTH(2),
        .GENERATION_BITS(8)
    ) u_counter (
        .clk(clk),
        .rst(rst),
        .start_accept_i(start_accept),
        .done_i(done),
        .events_i(events),
        .running_o(running),
        .snapshot_valid_o(snapshot_valid),
        .capability_o(capability),
        .status_o(status),
        .overflow_o(overflow),
        .error_status_o(error_status),
        .geometry_o(geometry),
        .buffer_config_o(buffer_config),
        .numeric_config_o(numeric_config),
        .counters_flat_o(counters)
    );

    vit_axi_lite_control_regs u_regs (
        .aclk(clk),
        .aresetn(!rst),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awprot(s_axi_awprot),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arprot(s_axi_arprot),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .start_pulse_o(),
        .soft_reset_pulse_o(),
        .abort_pulse_o(),
        .clear_error_pulse_o(),
        .config_busy_i(1'b0),
        .status_idle_i(1'b1),
        .status_busy_i(1'b0),
        .status_done_i(1'b0),
        .status_error_i(1'b0),
        .status_fallback_wait_i(1'b0),
        .error_code_i(32'd0),
        .error_info_i(32'd0),
        .irq_events_i(32'd0),
        .irq_enable_o(),
        .irq_status_o(),
        .irq_o(),
        .model_base_o(),
        .input_base_o(),
        .scratch_base_o(),
        .model_words_o(),
        .input_words_o(),
        .scratch_words_o(),
        .execution_mode_o(),
        .global_params_flat_o(),
        .job_config_o(),
        .job_patch_a_base_o(),
        .layer_table_en_o(),
        .layer_table_addr_o(),
        .layer_table_we_o(),
        .layer_table_wdata_o(),
        .layer_table_rvalid_i(1'b0),
        .layer_table_rdata_i(32'd0),
        .class_index_i(32'd0),
        .class_logit_i(32'd0),
        .perf_running_i(1'b0),
        .perf_snapshot_valid_i(1'b0),
        .perf_job_cycles_i(64'd0),
        .perf_command_count_i(64'd0),
        .perf_axi_read_count_i(64'd0),
        .perf_axi_write_count_i(64'd0),
        .perf_axi_stall_cycles_i(64'd0),
        .profile_running_i(1'b0),
        .profile_snapshot_valid_i(1'b0),
        .profile_global_counters_i({44*64{1'b0}}),
        .profile_opcode_counts_i({16*64{1'b0}}),
        .profile_opcode_cycles_i({16*64{1'b0}}),
        .profile_global_overflow_i(64'd0),
        .profile_opcode_count_overflow_i(16'd0),
        .profile_opcode_cycle_overflow_i(16'd0),
        .profile_error_status_i(32'd0),
        .profile_trace_count_i(9'd0),
        .profile_trace_truncated_i(1'b0),
        .profile_trace_selected_valid_i(1'b0),
        .profile_trace_read_pending_i(1'b0),
        .profile_trace_meta_i(32'd0),
        .profile_trace_cycles_i(64'd0),
        .profile_hist_counters_i({18*64{1'b0}}),
        .profile_hist_overflow_i(18'd0),
        .m5_axi_capability_i(32'h01f2_1008),
        .m5_axi_status_i(32'd0),
        .m5_axi_overflow_i(16'd0),
        .m5_axi_protocol_status_i(8'd0),
        .m5_axi_counters_i({8*64{1'b0}}),
        .m7_capability_i(capability),
        .m7_status_i(status),
        .m7_overflow_i(overflow),
        .m7_error_i(error_status),
        .m7_geometry_i(geometry),
        .m7_buffer_config_i(buffer_config),
        .m7_numeric_config_i(numeric_config),
        .m7_counters_i(counters),
        .profile_trace_select_strobe_o(),
        .profile_trace_select_o()
    );

    function automatic logic [63:0] counter(input integer index);
        counter = counters[index*64 +: 64];
    endfunction

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (!condition) begin
                failures = failures + 1;
                $error("M7 COUNTER CHECK FAILED: %s", message);
            end
        end
    endtask

    task automatic clear_events;
        begin
            start_accept = 1'b0;
            done = 1'b0;
            events = '0;
        end
    endtask

    task automatic sample_edge;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic start_job;
        begin
            @(negedge clk);
            clear_events();
            start_accept = 1'b1;
            sample_edge();
            clear_events();
        end
    endtask

    task automatic axil_read(
        input logic [11:0] address,
        input logic [31:0] expected_value,
        input logic [1:0] expected_response,
        input string message
    );
        begin
            @(negedge clk);
            s_axi_araddr = address;
            s_axi_arvalid = 1'b1;
            while (!s_axi_arready)
                @(negedge clk);
            @(posedge clk);
            #1;
            s_axi_arvalid = 1'b0;
            check(s_axi_rvalid, {message, " valid"});
            check(s_axi_rresp === expected_response, {message, " response"});
            check(s_axi_rdata === expected_value, {message, " data"});
            sample_edge();
        end
    endtask

    task automatic axil_write_expect(
        input logic [11:0] address,
        input logic [31:0] value,
        input logic [1:0] expected_response,
        input string message
    );
        begin
            @(negedge clk);
            s_axi_awaddr = address;
            s_axi_awvalid = 1'b1;
            s_axi_wdata = value;
            s_axi_wstrb = 4'hf;
            s_axi_wvalid = 1'b1;
            @(posedge clk);
            #1;
            s_axi_awvalid = 1'b0;
            s_axi_wvalid = 1'b0;
            while (!s_axi_bvalid)
                sample_edge();
            check(s_axi_bresp === expected_response, {message, " response"});
            sample_edge();
        end
    endtask

    initial begin
        clear_events();
        repeat (3) sample_edge();
        @(negedge clk);
        rst = 1'b0;

        check(PHASE_E_M7_COUNTER_COUNT == 23, "ABI has exactly 23 counters");
        check(!running && !snapshot_valid, "reset leaves bank idle/invalid");
        check(counters === '0, "reset clears published counters");
        check(overflow === 64'd0, "reset clears published overflow");
        check(error_status === 32'd0, "reset clears published error");
        check(capability === 32'h01ff_0817, "FIFO/generation capability constant");
        check(geometry === 32'h0810_0208, "R8/C2/L16/S8 geometry");
        check(buffer_config === 32'h0008_0202,
              "two operand banks, depth-2 result FIFO, 8-bit generation tag");
        check(numeric_config === 32'h07c0_d05d, "M7 numerical contract");

        start_job();
        check(running && !snapshot_valid, "START opens fresh live epoch");
        check(counters === '0, "START clears published snapshot");
        axil_read(REG_M7_STATUS, 32'h0000_0001, RESP_OKAY,
                  "live M7 status exposes running only");

        // Exhaustively visit every L/C/S combination once. Each stage is high
        // four times, union seven, every pair twice, and all three once.
        for (stage_pattern = 0; stage_pattern < 8;
             stage_pattern = stage_pattern + 1) begin
            @(negedge clk);
            clear_events();
            events.m7_panel_load_active = stage_pattern[2];
            events.m7_panel_compute_active = stage_pattern[1];
            events.m7_panel_store_active = stage_pattern[0];
            sample_edge();
        end
        clear_events();

        // Exercise all append-only counter datapaths, including the reachable
        // production result-FIFO fields advertised by the v1.10 capability.
        @(negedge clk);
        events = '0;
        events.m7_fp16_term_accept_delta = 5'd16;
        events.m7_fp16_disabled_term_delta = 5'd3;
        events.m7_fp16_input_wait = 1'b1;
        events.m7_fp16_term_stall = 1'b1;
        events.m7_fp16_result_backpressure = 1'b1;
        events.m7_fp16_dot_start = 1'b1;
        events.m7_fp16_result_vector = 1'b1;
        events.m7_panel_commit = 1'b1;
        events.m7_panel_claim = 1'b1;
        events.m7_panel_claim_mask = 2'b01;
        events.m7_panel_release = 1'b1;
        events.m7_panel_empty_stall = 1'b1;
        events.m7_panel_full_stall = 1'b1;
        events.m7_panel_occupancy = 2'd1;
        events.m7_result_fifo_enqueue = 1'b1;
        events.m7_result_fifo_dequeue = 1'b1;
        events.m7_result_fifo_occupancy = 2'd1;
        sample_edge();

        // Exercise the second bank, maximum gauges, and prove the two feeder
        // stall causes are ORed into one cycle counter rather than double-counted.
        @(negedge clk);
        events = '0;
        events.m7_fp16_term_stall = 1'b1;
        events.m7_panel_commit = 1'b1;
        events.m7_panel_claim = 1'b1;
        events.m7_panel_claim_mask = 2'b10;
        events.m7_panel_release = 1'b1;
        events.m7_panel_occupancy = 2'd2;
        events.m7_result_fifo_enqueue = 1'b1;
        events.m7_result_fifo_dequeue = 1'b1;
        events.m7_result_fifo_occupancy = 2'd2;
        sample_edge();

        // Published values remain atomic and invisible until DONE.
        clear_events();
        check(counters === '0, "live updates do not tear published snapshot");
        axil_read(REG_M7_COUNTER_BASE, 32'd0, RESP_OKAY,
                  "counter remains unpublished while running");

        // Terminal-cycle deltas must be included in the atomic snapshot.
        @(negedge clk);
        events = '0;
        events.m7_fp16_term_accept_delta = 5'd4;
        events.m7_fp16_disabled_term_delta = 5'd1;
        events.m7_result_fifo_enqueue = 1'b1;
        events.m7_result_fifo_dequeue = 1'b1;
        done = 1'b1;
        sample_edge();
        clear_events();

        expected[0] = 64'd20;
        expected[1] = 64'd4;
        expected[2] = 64'd1;
        expected[3] = 64'd1;
        expected[4] = 64'd2;
        expected[5] = 64'd1;
        expected[6] = 64'd4;
        expected[7] = 64'd4;
        expected[8] = 64'd4;
        expected[9] = 64'd7;
        expected[10] = 64'd2;
        expected[11] = 64'd2;
        expected[12] = 64'd2;
        expected[13] = 64'd1;
        expected[14] = 64'd2;
        expected[15] = 64'd2;
        expected[16] = 64'd2;
        expected[17] = 64'd1;
        expected[18] = 64'd1;
        expected[19] = 64'd2;
        expected[20] = 64'd3;
        expected[21] = 64'd3;
        expected[22] = 64'd2;

        check(!running && snapshot_valid, "DONE atomically publishes M7 bank");
        check(overflow == 0, "clean epoch has no counter overflow");
        check(error_status == 0, "clean epoch has no typed error");
        for (counter_index = 0;
             counter_index < PHASE_E_M7_COUNTER_COUNT;
             counter_index = counter_index + 1)
            check(counter(counter_index) === expected[counter_index],
                  $sformatf("counter %0d exact value", counter_index));

        check(counter(0) - counter(1) == 64'd16,
              "accepted minus disabled terms gives useful terms");
        check(counter(9) == counter(6) + counter(7) + counter(8) -
              counter(10) - counter(11) - counter(12) + counter(13),
              "stage inclusion-exclusion identity");
        check(status[1] && !status[0], "status snapshot valid and idle");
        check(status[7] && (status[9:8] == 2'b11),
              "status proves both operand banks were claimed");
        check(status[11:10] == 2'd2, "status bank maximum occupancy");
        check(status[15:12] == 4'd2, "status FIFO maximum occupancy");
        check(status[19:16] == 4'hf,
              "status records feeder/result/empty/full waits");

        // Exercise all eight headers and every LO/HI counter address.
        axil_read(REG_IP_VERSION, 32'h0001_000d, RESP_OKAY,
                  "IP version v1.13");
        axil_read(REG_M5_LAST, 32'd0, RESP_OKAY,
                  "M5 final high word remains mapped");
        axil_read(REG_M7_CAPABILITY, 32'h01ff_0817, RESP_OKAY,
                  "M7 capability address");
        axil_read(REG_M7_STATUS, status, RESP_OKAY, "M7 status address");
        axil_read(REG_M7_OVF_LO, 32'd0, RESP_OKAY, "M7 overflow low");
        axil_read(REG_M7_OVF_HI, 32'd0, RESP_OKAY, "M7 overflow high");
        axil_read(REG_M7_ERROR, 32'd0, RESP_OKAY, "M7 error address");
        axil_read(REG_M7_GEOMETRY, 32'h0810_0208, RESP_OKAY,
                  "M7 geometry address");
        axil_read(REG_M7_BUFFER_CONFIG, 32'h0008_0202, RESP_OKAY,
                  "M7 buffer configuration address");
        axil_read(REG_M7_NUMERIC_CONFIG, 32'h07c0_d05d, RESP_OKAY,
                  "M7 numerical configuration address");
        for (counter_index = 0;
             counter_index < PHASE_E_M7_COUNTER_COUNT;
             counter_index = counter_index + 1) begin
            axil_read(
                REG_M7_COUNTER_BASE + counter_index*8,
                expected[counter_index][31:0],
                RESP_OKAY,
                $sformatf("M7 counter %0d low mapping", counter_index)
            );
            axil_read(
                REG_M7_COUNTER_BASE + counter_index*8 + 4,
                expected[counter_index][63:32],
                RESP_OKAY,
                $sformatf("M7 counter %0d high mapping", counter_index)
            );
        end
        axil_read(REG_M7_COUNTER_LAST, expected[22][63:32], RESP_OKAY,
                  "last mapped M7 high word");
        axil_read(12'h8e8, 32'd0, RESP_SLVERR,
                  "first post-M7 word remains unsupported");

        axil_write_expect(REG_M7_CAPABILITY, 32'hdead_beef, RESP_SLVERR,
                          "M7 header is read-only");
        axil_write_expect(REG_M7_COUNTER_BASE, 32'hdead_beef, RESP_SLVERR,
                          "M7 counter bank is read-only");
        axil_read(REG_M7_CAPABILITY, 32'h01ff_0817, RESP_OKAY,
                  "rejected header write has no effect");
        axil_read(REG_M7_COUNTER_BASE, expected[0][31:0], RESP_OKAY,
                  "rejected counter write has no effect");

        // Near-maximum injection proves modulo overflow, sticky typed errors,
        // automatic disabled>accepted checking, and dirty-DONE checking.
        start_job();
        check(counters === '0 && overflow === 0 && error_status === 0,
              "new START clears prior published snapshot/status");
        @(negedge clk);
        u_counter.live[0] = 64'hffff_ffff_ffff_ffff;
        events = '0;
        events.m7_fp16_term_accept_delta = 5'd1;
        events.m7_fp16_disabled_term_delta = 5'd2;
        events.m7_panel_load_active = 1'b1;
        events.m7_panel_occupancy = 2'd2;
        events.m7_result_fifo_occupancy = 2'd1;
        events.m7_error_events[0] = 1'b1;
        events.m7_error_events[10] = 1'b1;
        done = 1'b1;
        sample_edge();
        clear_events();

        check(counter(0) == 64'd0, "counter wraps modulo 2^64");
        check(overflow[0] && (overflow[63:1] == 0),
              "matching sticky overflow bit publishes");
        check(error_status[0] && error_status[10] && error_status[14] &&
              error_status[15] && error_status[16] && error_status[18],
              "explicit, malformed-delta, and dirty-DONE errors publish");
        check(status[2] && status[3] && status[20] && status[21],
              "status summarizes overflow, numerical, and ownership errors");
        axil_read(REG_M7_OVF_LO, 32'h0000_0001, RESP_OKAY,
                  "overflow is visible through AXI-Lite");
        axil_read(REG_M7_ERROR, error_status, RESP_OKAY,
                  "typed errors are visible through AXI-Lite");

        // A subsequent empty job proves START clears every published field and
        // a clean DONE can publish a new all-zero snapshot.
        start_job();
        check(!snapshot_valid && counters === '0 && overflow === 0 &&
              error_status === 0, "START clears overflow/error publication");
        @(negedge clk);
        done = 1'b1;
        sample_edge();
        clear_events();
        check(snapshot_valid && counters === '0 && overflow === 0 &&
              error_status === 0, "empty clean epoch publishes zero snapshot");

        if (failures == 0)
            $display("M7_OVERLAP_COUNTER_BANK_PASS checks=%0d", checks);
        else
            $fatal(1, "M7 overlap counter failures=%0d checks=%0d",
                   failures, checks);
        $finish;
    end
endmodule
