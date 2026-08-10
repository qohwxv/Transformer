`timescale 1ns/1ps

module tb_m5_axi_counter_bank;
    logic clk = 1'b0;
    logic rst = 1'b1;
    logic aresetn = 1'b0;
    logic start_accept;
    logic done;
    logic full_r_beat;
    logic narrow_r_beat;
    logic linefill_start;
    logic linefill_hit;
    logic four_k_split;
    logic [1:0] read_outstanding;
    logic [7:0] protocol_error;
    logic [5:0] prefetched_words_discarded;
    logic running;
    logic snapshot_valid;
    logic [31:0] capability;
    logic [31:0] m5_status;
    logic [15:0] overflow;
    logic [7:0] protocol_status;
    logic [8*64-1:0] counters;

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
    logic trace_select_strobe;
    logic [7:0] trace_select;

    integer checks = 0;
    integer failures = 0;

    always #5 clk = ~clk;

    vit_phase_e_m5_axi_counters u_m5 (
        .clk(clk),
        .rst(rst),
        .start_accept_i(start_accept),
        .done_i(done),
        .full_r_beat_i(full_r_beat),
        .narrow_r_beat_i(narrow_r_beat),
        .linefill_start_i(linefill_start),
        .linefill_hit_i(linefill_hit),
        .four_k_split_i(four_k_split),
        .read_outstanding_i(read_outstanding),
        .protocol_error_i(protocol_error),
        .prefetched_words_discarded_i(prefetched_words_discarded),
        .running_o(running),
        .snapshot_valid_o(snapshot_valid),
        .capability_o(capability),
        .status_o(m5_status),
        .overflow_o(overflow),
        .protocol_error_status_o(protocol_status),
        .counters_flat_o(counters)
    );

    vit_axi_lite_control_regs u_regs (
        .aclk(clk),
        .aresetn(aresetn),
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
        .config_busy_i(1'b0),
        .status_idle_i(1'b1),
        .status_busy_i(1'b0),
        .status_done_i(1'b0),
        .status_error_i(1'b0),
        .status_fallback_wait_i(1'b0),
        .error_code_i(32'd0),
        .error_info_i(32'd0),
        .irq_events_i(32'd0),
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
        .m5_axi_capability_i(capability),
        .m5_axi_status_i(m5_status),
        .m5_axi_overflow_i(overflow),
        .m5_axi_protocol_status_i(protocol_status),
        .m5_axi_counters_i(counters),
        .m7_capability_i(32'd0),
        .m7_status_i(32'd0),
        .m7_overflow_i(64'd0),
        .m7_error_i(32'd0),
        .m7_geometry_i(32'd0),
        .m7_buffer_config_i(32'd0),
        .m7_numeric_config_i(32'd0),
        .m7_counters_i({23*64{1'b0}}),
        .profile_trace_select_strobe_o(trace_select_strobe),
        .profile_trace_select_o(trace_select)
    );

    function automatic logic [63:0] counter(input integer index);
        counter = counters[index*64 +: 64];
    endfunction

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (!condition) begin
                failures = failures + 1;
                $error("M5 AXI COUNTER CHECK FAILED: %s", message);
            end
        end
    endtask

    task automatic clear_events;
        begin
            start_accept = 1'b0;
            done = 1'b0;
            full_r_beat = 1'b0;
            narrow_r_beat = 1'b0;
            linefill_start = 1'b0;
            linefill_hit = 1'b0;
            four_k_split = 1'b0;
            read_outstanding = 2'd0;
            protocol_error = 8'd0;
            prefetched_words_discarded = 6'd0;
        end
    endtask

    task automatic sample_edge;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task automatic axil_read(
        input logic [11:0] address,
        input logic [31:0] expected,
        input logic [1:0] expected_resp,
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
            check(s_axi_rresp == expected_resp, {message, " response"});
            check(s_axi_rdata == expected, {message, " data"});
            sample_edge();
        end
    endtask

    task automatic axil_write_expect(
        input logic [11:0] address,
        input logic [31:0] value,
        input logic [1:0] expected_resp,
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
            check(s_axi_bresp == expected_resp, {message, " response"});
            sample_edge();
        end
    endtask

    initial begin
        clear_events();
        repeat (3) sample_edge();
        @(negedge clk);
        rst = 1'b0;
        aresetn = 1'b1;
        start_accept = 1'b1;
        sample_edge();
        clear_events();
        check(running && !snapshot_valid, "START opens a fresh live epoch");
        check(counters == '0, "published counters clear at START");

        @(negedge clk);
        full_r_beat = 1'b1;
        linefill_start = 1'b1;
        read_outstanding = 2'd1;
        sample_edge();
        clear_events();

        @(negedge clk);
        full_r_beat = 1'b1;
        linefill_hit = 1'b1;
        read_outstanding = 2'd2;
        sample_edge();
        clear_events();

        @(negedge clk);
        narrow_r_beat = 1'b1;
        four_k_split = 1'b1;
        read_outstanding = 2'd1;
        protocol_error = 8'h09;
        prefetched_words_discarded = 6'd5;
        done = 1'b1;
        sample_edge();
        clear_events();

        check(!running && snapshot_valid, "DONE atomically publishes M5 bank");
        check(counter(0) == 64'd2, "full-width R beats");
        check(counter(1) == 64'd1, "narrow R beats");
        check(counter(2) == 64'd1, "linefill starts");
        check(counter(3) == 64'd1, "linefill hits");
        check(counter(4) == 64'd1, "4-KiB split events");
        check(counter(5) == 64'd2, "maximum outstanding read depth");
        check(counter(6) == 64'd2, "typed protocol pulse popcount");
        check(counter(7) == 64'd5, "discarded prefetch word delta");
        check(protocol_status == 8'h09, "typed protocol status is sticky");
        check(overflow == 16'd0, "ordinary epoch has no overflow");
        check(capability == 32'h01f2_1008, "capability encoding");
        check(m5_status[7:0] == 8'hda, "published status summary");

        // Verify every append-only AXI-Lite address, including the high word
        // of the final counter and the intentionally unsupported gap.
        axil_read(12'h004, 32'h0001_000d, 2'b00, "IP version v1.13");
        axil_read(12'h7c0, 32'h01f2_1008, 2'b00, "M5 capability");
        axil_read(12'h7c4, 32'h0000_00da, 2'b00, "M5 status");
        axil_read(12'h7c8, 32'h0000_0000, 2'b00, "M5 overflow");
        axil_read(12'h7cc, 32'h0000_0009, 2'b00, "M5 protocol status");
        axil_read(12'h7d0, 32'd2, 2'b00, "counter 0 low");
        axil_read(12'h7d4, 32'd0, 2'b00, "counter 0 high");
        axil_read(12'h7f8, 32'd2, 2'b00, "counter 5 low");
        axil_read(12'h800, 32'd2, 2'b00, "counter 6 low");
        axil_read(12'h808, 32'd5, 2'b00, "counter 7 low");
        axil_read(12'h80c, 32'd0, 2'b00, "counter 7 high");
        axil_read(12'h7b8, 32'd0, 2'b10, "reserved pre-M5 gap");
        axil_write_expect(12'h7c0, 32'hdead_beef, 2'b10,
                          "M5 snapshot bank is read-only");
        axil_read(12'h7c0, 32'h01f2_1008, 2'b00,
                  "rejected write leaves capability unchanged");

        // Direct saturation injection covers the 64-bit carry path.
        @(negedge clk);
        start_accept = 1'b1;
        sample_edge();
        clear_events();
        @(negedge clk);
        u_m5.live[0] = 64'hffff_ffff_ffff_ffff;
        full_r_beat = 1'b1;
        done = 1'b1;
        sample_edge();
        clear_events();
        check(counter(0) == 64'd0, "counter overflow remains modulo 2^64");
        check(overflow[0], "counter overflow bit publishes atomically");
        check(m5_status[2], "status reports published overflow");

        if (failures == 0)
            $display("M5_AXI_COUNTER_BANK_PASS checks=%0d", checks);
        else
            $fatal(1, "M5 counter bank failures=%0d checks=%0d",
                   failures, checks);
        $finish;
    end
endmodule
