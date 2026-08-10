`timescale 1ns/1ps

module tb_vit_axi_lite_control_regs;

    localparam integer ADDR_WIDTH = 12;
    localparam logic [1:0] RESP_OKAY   = 2'b00;
    localparam logic [1:0] RESP_SLVERR = 2'b10;

    localparam logic [ADDR_WIDTH-1:0] REG_IP_ID          = 'h000;
    localparam logic [ADDR_WIDTH-1:0] REG_IP_VERSION     = 'h004;
    localparam logic [ADDR_WIDTH-1:0] REG_CONTROL        = 'h008;
    localparam logic [ADDR_WIDTH-1:0] REG_STATUS         = 'h00c;
    localparam logic [ADDR_WIDTH-1:0] REG_IRQ_ENABLE     = 'h010;
    localparam logic [ADDR_WIDTH-1:0] REG_IRQ_STATUS     = 'h014;
    localparam logic [ADDR_WIDTH-1:0] REG_ERROR_CODE     = 'h018;
    localparam logic [ADDR_WIDTH-1:0] REG_ERROR_INFO     = 'h01c;
    localparam logic [ADDR_WIDTH-1:0] REG_MODEL_BASE_LO  = 'h020;
    localparam logic [ADDR_WIDTH-1:0] REG_MODEL_BASE_HI  = 'h024;
    localparam logic [ADDR_WIDTH-1:0] REG_INPUT_BASE_LO  = 'h028;
    localparam logic [ADDR_WIDTH-1:0] REG_INPUT_BASE_HI  = 'h02c;
    localparam logic [ADDR_WIDTH-1:0] REG_SCRATCH_BASE_LO = 'h030;
    localparam logic [ADDR_WIDTH-1:0] REG_SCRATCH_BASE_HI = 'h034;
    localparam logic [ADDR_WIDTH-1:0] REG_MODEL_WORDS    = 'h038;
    localparam logic [ADDR_WIDTH-1:0] REG_INPUT_WORDS    = 'h03c;
    localparam logic [ADDR_WIDTH-1:0] REG_SCRATCH_WORDS  = 'h040;
    localparam logic [ADDR_WIDTH-1:0] REG_EXECUTION_MODE = 'h044;
    localparam logic [ADDR_WIDTH-1:0] REG_PERF_CAPABILITY = 'h048;
    localparam logic [ADDR_WIDTH-1:0] REG_PERF_STATUS     = 'h04c;
    localparam logic [ADDR_WIDTH-1:0] REG_JOB_CYCLES_LO   = 'h050;
    localparam logic [ADDR_WIDTH-1:0] REG_JOB_CYCLES_HI   = 'h054;
    localparam logic [ADDR_WIDTH-1:0] REG_COMMANDS_LO     = 'h058;
    localparam logic [ADDR_WIDTH-1:0] REG_COMMANDS_HI     = 'h05c;
    localparam logic [ADDR_WIDTH-1:0] REG_AXI_READS_LO    = 'h060;
    localparam logic [ADDR_WIDTH-1:0] REG_AXI_READS_HI    = 'h064;
    localparam logic [ADDR_WIDTH-1:0] REG_AXI_WRITES_LO   = 'h068;
    localparam logic [ADDR_WIDTH-1:0] REG_AXI_WRITES_HI   = 'h06c;
    localparam logic [ADDR_WIDTH-1:0] REG_AXI_STALL_LO    = 'h070;
    localparam logic [ADDR_WIDTH-1:0] REG_AXI_STALL_HI    = 'h074;
    localparam logic [ADDR_WIDTH-1:0] REG_PROFILE_CAP2     = 'h188;
    localparam logic [ADDR_WIDTH-1:0] REG_PROFILE_STATUS2  = 'h18c;
    localparam logic [ADDR_WIDTH-1:0] REG_PROFILE_OVF_LO   = 'h190;
    localparam logic [ADDR_WIDTH-1:0] REG_PROFILE_OVF_HI   = 'h194;
    localparam logic [ADDR_WIDTH-1:0] REG_OPCODE_COUNT_OVF = 'h198;
    localparam logic [ADDR_WIDTH-1:0] REG_OPCODE_CYCLE_OVF = 'h19c;
    localparam logic [ADDR_WIDTH-1:0] REG_PROFILE_GLOBAL_BASE = 'h1a0;
    localparam logic [ADDR_WIDTH-1:0] REG_PROFILE_GLOBAL_LAST = 'h2fc;
    localparam logic [ADDR_WIDTH-1:0] REG_PROFILE_OPCODE_BASE = 'h300;
    localparam logic [ADDR_WIDTH-1:0] REG_PROFILE_OPCODE_LAST = 'h3fc;
    localparam logic [ADDR_WIDTH-1:0] REG_LAYER_BASE      = 'h400;
    localparam logic [ADDR_WIDTH-1:0] REG_LAYER_LAST      = 'h6fc;
    localparam logic [ADDR_WIDTH-1:0] REG_TRACE_CAPABILITY = 'h700;
    localparam logic [ADDR_WIDTH-1:0] REG_TRACE_SELECT     = 'h704;
    localparam logic [ADDR_WIDTH-1:0] REG_TRACE_STATUS     = 'h708;
    localparam logic [ADDR_WIDTH-1:0] REG_TRACE_META       = 'h70c;
    localparam logic [ADDR_WIDTH-1:0] REG_TRACE_CYCLES_LO  = 'h710;
    localparam logic [ADDR_WIDTH-1:0] REG_TRACE_CYCLES_HI  = 'h714;
    localparam logic [ADDR_WIDTH-1:0] REG_TRACE_COUNT      = 'h718;
    localparam logic [ADDR_WIDTH-1:0] REG_PROFILE_ERROR    = 'h71c;
    localparam logic [ADDR_WIDTH-1:0] REG_HIST_CAPABILITY  = 'h720;
    localparam logic [ADDR_WIDTH-1:0] REG_HIST_OVERFLOW    = 'h724;
    localparam logic [ADDR_WIDTH-1:0] REG_HIST_BASE        = 'h728;
    localparam logic [ADDR_WIDTH-1:0] REG_HIST_LAST        = 'h7b4;
    localparam logic [ADDR_WIDTH-1:0] REG_M7_CAPABILITY    = 'h810;
    localparam logic [ADDR_WIDTH-1:0] REG_M7_STATUS        = 'h814;
    localparam logic [ADDR_WIDTH-1:0] REG_M7_OVF_LO        = 'h818;
    localparam logic [ADDR_WIDTH-1:0] REG_M7_OVF_HI        = 'h81c;
    localparam logic [ADDR_WIDTH-1:0] REG_M7_ERROR         = 'h820;
    localparam logic [ADDR_WIDTH-1:0] REG_M7_GEOMETRY      = 'h824;
    localparam logic [ADDR_WIDTH-1:0] REG_M7_BUFFER_CONFIG = 'h828;
    localparam logic [ADDR_WIDTH-1:0] REG_M7_NUMERIC_CONFIG = 'h82c;
    localparam logic [ADDR_WIDTH-1:0] REG_M7_COUNTER_BASE  = 'h830;
    localparam logic [ADDR_WIDTH-1:0] REG_M7_COUNTER_LAST  = 'h8e4;

    logic aclk = 1'b0;
    logic aresetn = 1'b0;

    logic [ADDR_WIDTH-1:0] s_axi_awaddr = '0;
    logic [2:0] s_axi_awprot = 3'b0;
    logic s_axi_awvalid = 1'b0;
    logic s_axi_awready;
    logic [31:0] s_axi_wdata = 32'b0;
    logic [3:0] s_axi_wstrb = 4'b0;
    logic s_axi_wvalid = 1'b0;
    logic s_axi_wready;
    logic [1:0] s_axi_bresp;
    logic s_axi_bvalid;
    logic s_axi_bready = 1'b0;
    logic [ADDR_WIDTH-1:0] s_axi_araddr = '0;
    logic [2:0] s_axi_arprot = 3'b0;
    logic s_axi_arvalid = 1'b0;
    logic s_axi_arready;
    logic [31:0] s_axi_rdata;
    logic [1:0] s_axi_rresp;
    logic s_axi_rvalid;
    logic s_axi_rready = 1'b0;

    logic start_pulse;
    logic soft_reset_pulse;
    logic abort_pulse;
    logic clear_error_pulse;
    logic config_busy = 1'b0;
    logic status_idle = 1'b1;
    logic status_busy = 1'b0;
    logic status_done = 1'b0;
    logic status_error = 1'b0;
    logic status_fallback_wait = 1'b0;
    logic [31:0] error_code = 32'b0;
    logic [31:0] error_info = 32'b0;
    logic [31:0] irq_events = 32'b0;
    logic [31:0] irq_enable;
    logic [31:0] irq_status;
    logic irq;
    logic [63:0] model_base;
    logic [63:0] input_base;
    logic [63:0] scratch_base;
    logic [31:0] model_words;
    logic [31:0] input_words;
    logic [31:0] scratch_words;
    logic [31:0] execution_mode;
    logic layer_table_en;
    logic [7:0] layer_table_addr;
    logic [3:0] layer_table_we;
    logic [31:0] layer_table_wdata;
    logic layer_table_rvalid;
    logic [31:0] layer_table_rdata;
    logic perf_running = 1'b1;
    logic perf_snapshot_valid = 1'b1;
    logic profile_running = 1'b1;
    logic profile_snapshot_valid = 1'b1;
    logic [63:0] perf_job_cycles = 64'h0123_4567_89ab_cdef;
    logic [63:0] perf_command_count = 64'h1111_2222_3333_4444;
    logic [63:0] perf_axi_read_count = 64'h5555_6666_7777_8888;
    logic [63:0] perf_axi_write_count = 64'h9999_aaaa_bbbb_cccc;
    logic [63:0] perf_axi_stall_cycles = 64'hdddd_eeee_ffff_0001;
    logic [44*64-1:0] profile_global_counters = '0;
    logic [16*64-1:0] profile_opcode_counts = '0;
    logic [16*64-1:0] profile_opcode_cycles = '0;
    logic [63:0] profile_global_overflow = 64'h0123_4567_89ab_cdef;
    logic [15:0] profile_opcode_count_overflow = 16'h8001;
    logic [15:0] profile_opcode_cycle_overflow = 16'h4002;
    logic [31:0] profile_error_status = 32'hdead_7001;
    logic [8:0] profile_trace_count = 9'd249;
    logic profile_trace_truncated = 1'b1;
    logic profile_trace_selected_valid = 1'b1;
    logic profile_trace_read_pending = 1'b1;
    logic [31:0] profile_trace_meta = 32'h0000_1a57;
    logic [63:0] profile_trace_cycles = 64'h7654_3210_fedc_ba98;
    logic [18*64-1:0] profile_hist_counters = '0;
    logic [17:0] profile_hist_overflow = 18'h2_0001;
    logic [31:0] m7_capability = 32'h01ff_0817;
    logic [31:0] m7_status = 32'h003f_0fda;
    logic [63:0] m7_overflow = 64'h0123_4567_89ab_cdef;
    logic [31:0] m7_error = 32'h000a_55a5;
    logic [31:0] m7_geometry = 32'h0810_0208;
    logic [31:0] m7_buffer_config = 32'h0008_0202;
    logic [31:0] m7_numeric_config = 32'h07c0_d05d;
    logic [23*64-1:0] m7_counters = '0;
    logic profile_trace_select_strobe;
    logic [7:0] profile_trace_select;

    integer checks = 0;
    integer failures = 0;
    integer start_count = 0;
    integer soft_reset_count = 0;
    integer abort_count = 0;
    integer clear_error_count = 0;
    integer trace_select_strobe_count = 0;

    always #5 aclk = ~aclk;

    always @(posedge aclk) begin
        if (!aresetn) begin
            start_count       <= 0;
            soft_reset_count  <= 0;
            abort_count       <= 0;
            clear_error_count <= 0;
            trace_select_strobe_count <= 0;
        end else begin
            if (start_pulse)
                start_count <= start_count + 1;
            if (soft_reset_pulse)
                soft_reset_count <= soft_reset_count + 1;
            if (abort_pulse)
                abort_count <= abort_count + 1;
            if (clear_error_pulse)
                clear_error_count <= clear_error_count + 1;
            if (profile_trace_select_strobe)
                trace_select_strobe_count <= trace_select_strobe_count + 1;
        end
    end

    vit_axi_lite_control_regs #(
        .AXI_ADDR_WIDTH(ADDR_WIDTH)
    ) dut (
        .aclk(aclk),
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
        .start_pulse_o(start_pulse),
        .soft_reset_pulse_o(soft_reset_pulse),
        .abort_pulse_o(abort_pulse),
        .clear_error_pulse_o(clear_error_pulse),
        .config_busy_i(config_busy),
        .status_idle_i(status_idle),
        .status_busy_i(status_busy),
        .status_done_i(status_done),
        .status_error_i(status_error),
        .status_fallback_wait_i(status_fallback_wait),
        .error_code_i(error_code),
        .error_info_i(error_info),
        .irq_events_i(irq_events),
        .irq_enable_o(irq_enable),
        .irq_status_o(irq_status),
        .irq_o(irq),
        .model_base_o(model_base),
        .input_base_o(input_base),
        .scratch_base_o(scratch_base),
        .model_words_o(model_words),
        .input_words_o(input_words),
        .scratch_words_o(scratch_words),
        .execution_mode_o(execution_mode),
        .global_params_flat_o(),
        .job_config_o(),
        .job_patch_a_base_o(),
        .layer_table_en_o(layer_table_en),
        .layer_table_addr_o(layer_table_addr),
        .layer_table_we_o(layer_table_we),
        .layer_table_wdata_o(layer_table_wdata),
        .layer_table_rvalid_i(layer_table_rvalid),
        .layer_table_rdata_i(layer_table_rdata),
        .class_index_i(32'b0),
        .class_logit_i(32'b0),
        .perf_running_i(perf_running),
        .perf_snapshot_valid_i(perf_snapshot_valid),
        .perf_job_cycles_i(perf_job_cycles),
        .perf_command_count_i(perf_command_count),
        .perf_axi_read_count_i(perf_axi_read_count),
        .perf_axi_write_count_i(perf_axi_write_count),
        .perf_axi_stall_cycles_i(perf_axi_stall_cycles),
        .profile_running_i(profile_running),
        .profile_snapshot_valid_i(profile_snapshot_valid),
        .profile_global_counters_i(profile_global_counters),
        .profile_opcode_counts_i(profile_opcode_counts),
        .profile_opcode_cycles_i(profile_opcode_cycles),
        .profile_global_overflow_i(profile_global_overflow),
        .profile_opcode_count_overflow_i(
            profile_opcode_count_overflow
        ),
        .profile_opcode_cycle_overflow_i(
            profile_opcode_cycle_overflow
        ),
        .profile_error_status_i(profile_error_status),
        .profile_trace_count_i(profile_trace_count),
        .profile_trace_truncated_i(profile_trace_truncated),
        .profile_trace_selected_valid_i(profile_trace_selected_valid),
        .profile_trace_read_pending_i(profile_trace_read_pending),
        .profile_trace_meta_i(profile_trace_meta),
        .profile_trace_cycles_i(profile_trace_cycles),
        .profile_hist_counters_i(profile_hist_counters),
        .profile_hist_overflow_i(profile_hist_overflow),
        .m5_axi_capability_i(32'd0),
        .m5_axi_status_i(32'd0),
        .m5_axi_overflow_i(16'd0),
        .m5_axi_protocol_status_i(8'd0),
        .m5_axi_counters_i({8*64{1'b0}}),
        .m7_capability_i(m7_capability),
        .m7_status_i(m7_status),
        .m7_overflow_i(m7_overflow),
        .m7_error_i(m7_error),
        .m7_geometry_i(m7_geometry),
        .m7_buffer_config_i(m7_buffer_config),
        .m7_numeric_config_i(m7_numeric_config),
        .m7_counters_i(m7_counters),
        .profile_trace_select_strobe_o(profile_trace_select_strobe),
        .profile_trace_select_o(profile_trace_select)
    );

    vit_layer_param_table layer_table_i (
        .clk(aclk),
        .rst(!aresetn),
        .a_en_i(layer_table_en),
        .a_addr_i(layer_table_addr),
        .a_we_i(layer_table_we),
        .a_wdata_i(layer_table_wdata),
        .a_rvalid_o(layer_table_rvalid),
        .a_rdata_o(layer_table_rdata),
        .b_en_i(1'b0),
        .b_addr_i(8'd0),
        .b_rvalid_o(),
        .b_rdata_o()
    );

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $error("CHECK FAILED: %s", message);
            end
        end
    endtask

    task automatic drive_aw(
        input logic [ADDR_WIDTH-1:0] address,
        input integer delay_cycles
    );
        begin
            repeat (delay_cycles)
                @(posedge aclk);
            @(negedge aclk);
            s_axi_awaddr  = address;
            s_axi_awvalid = 1'b1;
            do begin
                @(posedge aclk);
            end while (!(s_axi_awvalid && s_axi_awready));
            @(negedge aclk);
            s_axi_awvalid = 1'b0;
        end
    endtask

    task automatic drive_w(
        input logic [31:0] data,
        input logic [3:0] strobe,
        input integer delay_cycles
    );
        begin
            repeat (delay_cycles)
                @(posedge aclk);
            @(negedge aclk);
            s_axi_wdata  = data;
            s_axi_wstrb  = strobe;
            s_axi_wvalid = 1'b1;
            do begin
                @(posedge aclk);
            end while (!(s_axi_wvalid && s_axi_wready));
            @(negedge aclk);
            s_axi_wvalid = 1'b0;
        end
    endtask

    task automatic axi_write(
        input logic [ADDR_WIDTH-1:0] address,
        input logic [31:0] data,
        input logic [3:0] strobe,
        input integer aw_delay,
        input integer w_delay,
        input integer response_stall,
        output logic [1:0] response
    );
        logic [1:0] held_response;
        integer stall_index;
        begin
            fork
                drive_aw(address, aw_delay);
                drive_w(data, strobe, w_delay);
            join

            while (!s_axi_bvalid) begin
                @(posedge aclk);
                #1;
            end
            held_response = s_axi_bresp;
            for (
                stall_index = 0;
                stall_index < response_stall;
                stall_index = stall_index + 1
            ) begin
                check(s_axi_bvalid, "BVALID dropped under backpressure");
                check(
                    s_axi_bresp == held_response,
                    "BRESP changed under backpressure"
                );
                check(
                    !s_axi_awready && !s_axi_wready,
                    "write request accepted while B response outstanding"
                );
                @(posedge aclk);
                #1;
            end

            @(negedge aclk);
            s_axi_bready = 1'b1;
            @(posedge aclk);
            response = s_axi_bresp;
            @(negedge aclk);
            s_axi_bready = 1'b0;
        end
    endtask

    task automatic axi_read(
        input logic [ADDR_WIDTH-1:0] address,
        input integer response_stall,
        output logic [31:0] data,
        output logic [1:0] response
    );
        logic [31:0] held_data;
        logic [1:0] held_response;
        integer stall_index;
        begin
            @(negedge aclk);
            s_axi_araddr  = address;
            s_axi_arvalid = 1'b1;
            do begin
                @(posedge aclk);
            end while (!(s_axi_arvalid && s_axi_arready));
            @(negedge aclk);
            s_axi_arvalid = 1'b0;

            while (!s_axi_rvalid) begin
                @(posedge aclk);
                #1;
            end
            held_data = s_axi_rdata;
            held_response = s_axi_rresp;
            for (
                stall_index = 0;
                stall_index < response_stall;
                stall_index = stall_index + 1
            ) begin
                check(s_axi_rvalid, "RVALID dropped under backpressure");
                check(
                    s_axi_rdata == held_data,
                    "RDATA changed under backpressure"
                );
                check(
                    s_axi_rresp == held_response,
                    "RRESP changed under backpressure"
                );
                check(
                    !s_axi_arready,
                    "read request accepted while R response outstanding"
                );
                @(posedge aclk);
                #1;
            end

            @(negedge aclk);
            s_axi_rready = 1'b1;
            @(posedge aclk);
            data = s_axi_rdata;
            response = s_axi_rresp;
            @(negedge aclk);
            s_axi_rready = 1'b0;
        end
    endtask

    task automatic pulse_irq_events(input logic [31:0] event_mask);
        begin
            @(negedge aclk);
            irq_events = event_mask;
            @(posedge aclk);
            @(negedge aclk);
            irq_events = 32'b0;
            @(posedge aclk);
            #1;
        end
    endtask

    // Drive a one-clock IRQ event on the exact edge that commits an RW1C
    // write.  Keeping the event high beyond the commit edge would not prove
    // event-over-clear priority because a later clock could simply set the
    // sticky bit again.
    task automatic axi_irq_clear_with_commit_event(
        input logic [31:0] clear_mask,
        input logic [31:0] event_mask,
        output logic [1:0] response
    );
        begin
            fork
                drive_aw(REG_IRQ_STATUS, 0);
                drive_w(clear_mask, 4'hf, 0);
            join

            check(
                dut.write_commit,
                "IRQ priority test did not align event with write commit"
            );
            irq_events = event_mask;
            @(posedge aclk);
            #1;
            check(
                (irq_status & event_mask) == event_mask,
                "one-cycle IRQ event did not win simultaneous RW1C clear"
            );
            @(negedge aclk);
            irq_events = 32'b0;

            while (!s_axi_bvalid) begin
                @(posedge aclk);
                #1;
            end
            response = s_axi_bresp;
            s_axi_bready = 1'b1;
            @(posedge aclk);
            @(negedge aclk);
            s_axi_bready = 1'b0;
        end
    endtask

    logic [31:0] read_data;
    logic [1:0] response;
    integer profile_index;
    integer opcode_index;
    integer hist_index;
    integer m7_index;
    integer strobe_count_before;

    initial begin
        for (profile_index = 0; profile_index < 44;
             profile_index = profile_index + 1)
            profile_global_counters[profile_index*64 +: 64] = {
                32'h9000_0000 + profile_index,
                32'h1000_0000 + profile_index
            };
        for (opcode_index = 0; opcode_index < 16;
             opcode_index = opcode_index + 1) begin
            profile_opcode_counts[opcode_index*64 +: 64] = {
                32'ha000_0000 + opcode_index,
                32'h2000_0000 + opcode_index
            };
            profile_opcode_cycles[opcode_index*64 +: 64] = {
                32'hb000_0000 + opcode_index,
                32'h3000_0000 + opcode_index
            };
        end
        for (hist_index = 0; hist_index < 18;
             hist_index = hist_index + 1)
            profile_hist_counters[hist_index*64 +: 64] = {
                32'hc000_0000 + hist_index,
                32'h4000_0000 + hist_index
            };
        for (m7_index = 0; m7_index < 23; m7_index = m7_index + 1)
            m7_counters[m7_index*64 +: 64] = {
                32'he000_0000 + m7_index,
                32'h6000_0000 + m7_index
            };

        fork
            begin
                #2_000_000;
                $fatal(1, "testbench watchdog timeout");
            end
        join_none

        repeat (4)
            @(posedge aclk);
        @(negedge aclk);
        aresetn = 1'b1;
        repeat (2)
            @(posedge aclk);
        #1;

        check(!s_axi_bvalid && !s_axi_rvalid, "responses not reset");
        check(irq_enable == 0 && irq_status == 0 && !irq, "IRQ reset");
        check(
            model_base == 0 && input_base == 0 && scratch_base == 0,
            "base registers reset"
        );

        axi_read(REG_IP_ID, 0, read_data, response);
        check(response == RESP_OKAY, "IP_ID read response");
        check(read_data == 32'h5649_544e, "IP_ID value");
        axi_read(REG_IP_VERSION, 2, read_data, response);
        check(response == RESP_OKAY, "IP_VERSION read response");
        check(read_data == 32'h0001_000d, "IP_VERSION value (M8 profile v1.13)");

        // Append-only, read-only performance ABI.  Published 64-bit pairs are
        // already stable at this boundary, including under R backpressure.
        axi_read(REG_PERF_CAPABILITY, 0, read_data, response);
        check(
            (response == RESP_OKAY) && (read_data == 32'h0001_001f),
            "performance capability schema"
        );
        axi_read(REG_PERF_STATUS, 0, read_data, response);
        check(read_data == 32'h0000_0003, "performance status bits");
        axi_read(REG_JOB_CYCLES_LO, 0, read_data, response);
        check(read_data == 32'h89ab_cdef, "job cycles low word");
        axi_read(REG_JOB_CYCLES_HI, 2, read_data, response);
        check(read_data == 32'h0123_4567, "job cycles high word");
        axi_read(REG_COMMANDS_LO, 0, read_data, response);
        check(read_data == 32'h3333_4444, "command count low word");
        axi_read(REG_COMMANDS_HI, 0, read_data, response);
        check(read_data == 32'h1111_2222, "command count high word");
        axi_read(REG_AXI_READS_LO, 0, read_data, response);
        check(read_data == 32'h7777_8888, "AXI read count low word");
        axi_read(REG_AXI_READS_HI, 0, read_data, response);
        check(read_data == 32'h5555_6666, "AXI read count high word");
        axi_read(REG_AXI_WRITES_LO, 0, read_data, response);
        check(read_data == 32'hbbbb_cccc, "AXI write count low word");
        axi_read(REG_AXI_WRITES_HI, 0, read_data, response);
        check(read_data == 32'h9999_aaaa, "AXI write count high word");
        axi_read(REG_AXI_STALL_LO, 0, read_data, response);
        check(read_data == 32'hffff_0001, "AXI stall count low word");
        axi_read(REG_AXI_STALL_HI, 0, read_data, response);
        check(read_data == 32'hdddd_eeee, "AXI stall count high word");
        axi_write(
            REG_JOB_CYCLES_LO,
            32'hffff_ffff,
            4'hf,
            0,
            0,
            0,
            response
        );
        check(response == RESP_SLVERR, "performance registers are read-only");

        // Profile ABI v1.2: exact fixed metadata and all three address
        // formulas, including their final valid words.
        check(
            REG_PROFILE_GLOBAL_LAST ==
                (REG_PROFILE_GLOBAL_BASE + 12'(43*8 + 4)),
            "global counter window bound formula"
        );
        check(
            REG_PROFILE_OPCODE_LAST ==
                (REG_PROFILE_OPCODE_BASE + 12'(15*16 + 12)),
            "opcode table bound formula"
        );
        check(
            REG_HIST_LAST == (REG_HIST_BASE + 12'(17*8 + 4)),
            "histogram window bound formula"
        );
        axi_read(REG_PROFILE_CAP2, 0, read_data, response);
        check(
            (response == RESP_OKAY) && (read_data == 32'h0002_7fff),
            "profile2 capability"
        );
        axi_read(REG_PROFILE_STATUS2, 0, read_data, response);
        check(read_data == 32'h0000_003f, "profile2 status bit layout");
        axi_read(REG_PROFILE_OVF_LO, 0, read_data, response);
        check(read_data == 32'h89ab_cdef, "global overflow low");
        axi_read(REG_PROFILE_OVF_HI, 0, read_data, response);
        check(read_data == 32'h0123_4567, "global overflow high");
        axi_read(REG_OPCODE_COUNT_OVF, 0, read_data, response);
        check(read_data == 32'h0000_8001, "opcode-count overflow mask");
        axi_read(REG_OPCODE_CYCLE_OVF, 0, read_data, response);
        check(read_data == 32'h0000_4002, "opcode-cycle overflow mask");

        for (profile_index = 0; profile_index < 44;
             profile_index = profile_index + 1) begin
            axi_read(
                REG_PROFILE_GLOBAL_BASE + profile_index*8,
                (profile_index == 17) ? 3 : 0,
                read_data,
                response
            );
            check(
                (response == RESP_OKAY) &&
                (read_data == (32'h1000_0000 + profile_index)),
                $sformatf("global counter %0d low", profile_index)
            );
            axi_read(
                REG_PROFILE_GLOBAL_BASE + profile_index*8 + 4,
                0,
                read_data,
                response
            );
            check(
                (response == RESP_OKAY) &&
                (read_data == (32'h9000_0000 + profile_index)),
                $sformatf("global counter %0d high", profile_index)
            );
        end

        for (opcode_index = 0; opcode_index < 16;
             opcode_index = opcode_index + 1) begin
            axi_read(
                REG_PROFILE_OPCODE_BASE + opcode_index*16,
                0,
                read_data,
                response
            );
            check(
                read_data == (32'h2000_0000 + opcode_index),
                $sformatf("opcode %0d count low", opcode_index)
            );
            axi_read(
                REG_PROFILE_OPCODE_BASE + opcode_index*16 + 4,
                0,
                read_data,
                response
            );
            check(
                read_data == (32'ha000_0000 + opcode_index),
                $sformatf("opcode %0d count high", opcode_index)
            );
            axi_read(
                REG_PROFILE_OPCODE_BASE + opcode_index*16 + 8,
                0,
                read_data,
                response
            );
            check(
                read_data == (32'h3000_0000 + opcode_index),
                $sformatf("opcode %0d cycles low", opcode_index)
            );
            axi_read(
                REG_PROFILE_OPCODE_BASE + opcode_index*16 + 12,
                (opcode_index == 15) ? 2 : 0,
                read_data,
                response
            );
            check(
                (response == RESP_OKAY) &&
                (read_data == (32'hb000_0000 + opcode_index)),
                $sformatf("opcode %0d cycles high", opcode_index)
            );
        end

        axi_read(REG_TRACE_CAPABILITY, 0, read_data, response);
        check(read_data == 32'h0103_0100, "trace capability");
        axi_read(REG_TRACE_SELECT, 0, read_data, response);
        check(read_data == 0, "trace selector reset readback");
        axi_read(REG_TRACE_STATUS, 0, read_data, response);
        check(read_data == 32'h0000_000f, "trace status bit layout");
        axi_read(REG_TRACE_META, 0, read_data, response);
        check(read_data == profile_trace_meta, "trace metadata");
        axi_read(REG_TRACE_CYCLES_LO, 0, read_data, response);
        check(read_data == 32'hfedc_ba98, "trace cycles low");
        axi_read(REG_TRACE_CYCLES_HI, 3, read_data, response);
        check(read_data == 32'h7654_3210, "trace cycles high");
        axi_read(REG_TRACE_COUNT, 0, read_data, response);
        check(read_data == 32'd249, "trace count");
        axi_read(REG_PROFILE_ERROR, 0, read_data, response);
        check(read_data == profile_error_status, "profile error status");

        axi_read(REG_HIST_CAPABILITY, 0, read_data, response);
        check(read_data == 32'h0108_0802, "histogram capability");
        axi_read(REG_HIST_OVERFLOW, 0, read_data, response);
        check(read_data == {14'b0, profile_hist_overflow}, "hist overflow");
        for (hist_index = 0; hist_index < 18;
             hist_index = hist_index + 1) begin
            axi_read(
                REG_HIST_BASE + hist_index*8,
                0,
                read_data,
                response
            );
            check(
                read_data == (32'h4000_0000 + hist_index),
                $sformatf("hist counter %0d low", hist_index)
            );
            axi_read(
                REG_HIST_BASE + hist_index*8 + 4,
                (hist_index == 17) ? 3 : 0,
                read_data,
                response
            );
            check(
                (response == RESP_OKAY) &&
                (read_data == (32'hc000_0000 + hist_index)),
                $sformatf("hist counter %0d high", hist_index)
            );
        end

        // M8 v1.13 preserves the append-only bank. Exercise every header and both halves of
        // all 23 counters, including the exact final address 0x8e4.
        axi_read(REG_M7_CAPABILITY, 0, read_data, response);
        check((response == RESP_OKAY) && (read_data == m7_capability),
              "M7 capability");
        axi_read(REG_M7_STATUS, 0, read_data, response);
        check(read_data == m7_status, "M7 status");
        axi_read(REG_M7_OVF_LO, 0, read_data, response);
        check(read_data == m7_overflow[31:0], "M7 overflow low");
        axi_read(REG_M7_OVF_HI, 0, read_data, response);
        check(read_data == m7_overflow[63:32], "M7 overflow high");
        axi_read(REG_M7_ERROR, 0, read_data, response);
        check(read_data == m7_error, "M7 error");
        axi_read(REG_M7_GEOMETRY, 0, read_data, response);
        check(read_data == m7_geometry, "M7 geometry");
        axi_read(REG_M7_BUFFER_CONFIG, 0, read_data, response);
        check(read_data == m7_buffer_config, "M7 buffer config");
        axi_read(REG_M7_NUMERIC_CONFIG, 0, read_data, response);
        check(read_data == m7_numeric_config, "M7 numeric config");
        check(REG_M7_COUNTER_LAST ==
              (REG_M7_COUNTER_BASE + 12'(22*8 + 4)),
              "M7 counter window bound formula");
        for (m7_index = 0; m7_index < 23; m7_index = m7_index + 1) begin
            axi_read(REG_M7_COUNTER_BASE + m7_index*8,
                     0, read_data, response);
            check((response == RESP_OKAY) &&
                  (read_data == (32'h6000_0000 + m7_index)),
                  $sformatf("M7 counter %0d low", m7_index));
            axi_read(REG_M7_COUNTER_BASE + m7_index*8 + 4,
                     (m7_index == 22) ? 3 : 0, read_data, response);
            check((response == RESP_OKAY) &&
                  (read_data == (32'he000_0000 + m7_index)),
                  $sformatf("M7 counter %0d high", m7_index));
        end
        axi_write(REG_M7_COUNTER_BASE, 32'hffff_ffff, 4'hf,
                  0, 0, 0, response);
        check(response == RESP_SLVERR, "M7 counters are read-only");
        axi_read(12'h8e8, 0, read_data, response);
        check((response == RESP_SLVERR) && (read_data == 0),
              "first address after M7 bank is unsupported");

        // TRACE_SELECT is the only writable profile register.  A running job
        // rejects the write at commit time and must neither update nor pulse.
        strobe_count_before = trace_select_strobe_count;
        axi_write(
            REG_TRACE_SELECT,
            32'h0000_005a,
            4'hf,
            0,
            0,
            2,
            response
        );
        #1;
        check(response == RESP_SLVERR, "running trace select is rejected");
        check(profile_trace_select == 0, "rejected selector unchanged");
        check(
            trace_select_strobe_count == strobe_count_before,
            "rejected selector did not pulse"
        );

        perf_running = 1'b0;
        profile_running = 1'b0;
        strobe_count_before = trace_select_strobe_count;
        axi_write(
            REG_TRACE_SELECT,
            32'h0000_ab00,
            4'b0010,
            0,
            0,
            0,
            response
        );
        #1;
        check(response == RESP_OKAY, "upper-byte-only selector no-op");
        check(profile_trace_select == 0, "selector respects WSTRB");
        check(
            trace_select_strobe_count == strobe_count_before,
            "selector no-op did not prefetch"
        );

        axi_write(
            REG_TRACE_SELECT,
            32'hffff_ffa5,
            4'b0001,
            0,
            0,
            4,
            response
        );
        #1;
        check(response == RESP_OKAY, "partial selector write response");
        check(profile_trace_select == 8'ha5, "partial selector value");
        check(
            trace_select_strobe_count == (strobe_count_before + 1),
            "selector generated exactly one prefetch pulse"
        );
        axi_read(REG_TRACE_SELECT, 3, read_data, response);
        check(
            (response == RESP_OKAY) && (read_data == 32'h0000_00a5),
            "selector readback stable under backpressure"
        );

        // Like the layer lock, the running policy is sampled at the complete
        // split-channel write commit, not when AW is buffered.
        strobe_count_before = trace_select_strobe_count;
        perf_running = 1'b0;
        profile_running = 1'b0;
        drive_aw(REG_TRACE_SELECT, 0);
        perf_running = 1'b1;
        profile_running = 1'b1;
        drive_w(32'h0000_003c, 4'hf, 0);
        while (!s_axi_bvalid) begin
            @(posedge aclk);
            #1;
        end
        response = s_axi_bresp;
        @(negedge aclk);
        s_axi_bready = 1'b1;
        @(posedge aclk);
        @(negedge aclk);
        s_axi_bready = 1'b0;
        #1;
        check(
            response == RESP_SLVERR,
            "running transition before selector commit is rejected"
        );
        check(profile_trace_select == 8'ha5, "split reject keeps selector");
        check(
            trace_select_strobe_count == strobe_count_before,
            "split reject did not pulse"
        );
        perf_running = 1'b0;
        profile_running = 1'b0;

        axi_write(
            REG_PROFILE_GLOBAL_BASE,
            32'hffff_ffff,
            4'hf,
            0,
            0,
            0,
            response
        );
        check(response == RESP_SLVERR, "extended globals are read-only");
        axi_write(
            REG_PROFILE_OPCODE_LAST,
            32'hffff_ffff,
            4'hf,
            0,
            0,
            0,
            response
        );
        check(response == RESP_SLVERR, "opcode table is read-only");
        axi_write(
            REG_HIST_LAST,
            32'hffff_ffff,
            4'hf,
            0,
            0,
            0,
            response
        );
        check(response == RESP_SLVERR, "histogram table is read-only");
        axi_read(12'h7b8, 0, read_data, response);
        check(
            (response == RESP_SLVERR) && (read_data == 0),
            "first address after histogram is unsupported"
        );

        // Simultaneous AW/W, then W-before-A, then AW-before-W.
        axi_write(
            REG_MODEL_WORDS,
            32'h1234_5678,
            4'hf,
            0,
            0,
            0,
            response
        );
        check(response == RESP_OKAY, "simultaneous AW/W response");
        axi_write(
            REG_INPUT_WORDS,
            32'h89ab_cdef,
            4'hf,
            3,
            0,
            0,
            response
        );
        check(response == RESP_OKAY, "W-before-A response");
        axi_write(
            REG_SCRATCH_WORDS,
            32'h0bad_f00d,
            4'hf,
            0,
            4,
            0,
            response
        );
        check(response == RESP_OKAY, "AW-before-W response");
        check(model_words == 32'h1234_5678, "MODEL_WORDS write");
        check(input_words == 32'h89ab_cdef, "INPUT_WORDS write");
        check(scratch_words == 32'h0bad_f00d, "SCRATCH_WORDS write");

        // WSTRB and readback.
        axi_write(
            REG_IRQ_ENABLE,
            32'ha5a5_5a5a,
            4'hf,
            0,
            0,
            0,
            response
        );
        axi_write(
            REG_IRQ_ENABLE,
            32'h00cc_0000,
            4'b0100,
            0,
            0,
            0,
            response
        );
        axi_read(REG_IRQ_ENABLE, 0, read_data, response);
        check(read_data == 32'ha5cc_5a5a, "IRQ_ENABLE byte WSTRB");

        axi_write(
            REG_MODEL_BASE_LO,
            32'h89ab_cdef,
            4'hf,
            0,
            0,
            0,
            response
        );
        axi_write(
            REG_MODEL_BASE_HI,
            32'h0123_4567,
            4'hf,
            0,
            0,
            0,
            response
        );
        axi_write(
            REG_MODEL_BASE_LO,
            32'h0000_5500,
            4'b0010,
            0,
            0,
            0,
            response
        );
        check(
            model_base == 64'h0123_4567_89ab_55ef,
            "64-bit base and WSTRB readback"
        );

        axi_write(
            REG_INPUT_BASE_LO,
            32'h1111_2222,
            4'hf,
            0,
            0,
            0,
            response
        );
        axi_write(
            REG_INPUT_BASE_HI,
            32'h3333_4444,
            4'hf,
            0,
            0,
            0,
            response
        );
        axi_write(
            REG_SCRATCH_BASE_LO,
            32'h5555_6666,
            4'hf,
            0,
            0,
            0,
            response
        );
        axi_write(
            REG_SCRATCH_BASE_HI,
            32'h7777_8888,
            4'hf,
            0,
            0,
            0,
            response
        );
        axi_write(
            REG_EXECUTION_MODE,
            32'h0000_0001,
            4'hf,
            0,
            0,
            0,
            response
        );
        check(
            input_base == 64'h3333_4444_1111_2222,
            "INPUT_BASE register pair"
        );
        check(
            scratch_base == 64'h7777_8888_5555_6666,
            "SCRATCH_BASE register pair"
        );
        check(execution_mode == 1, "EXECUTION_MODE write");

        // The register bank stores the complete software mode word.  Mode
        // legality is deliberately enforced by the production wrapper at
        // START, so the append-only control bank must preserve bit 2.
        axi_write(
            REG_EXECUTION_MODE,
            32'h0000_0005,
            4'hf,
            0,
            0,
            0,
            response
        );
        check(response == RESP_OKAY, "M7 EXECUTION_MODE write response");
        check(execution_mode == 5, "M7 EXECUTION_MODE bit 2 preserved");
        axi_read(REG_EXECUTION_MODE, 0, read_data, response);
        check(
            response == RESP_OKAY && read_data == 32'h0000_0005,
            "M7 EXECUTION_MODE readback"
        );

        // The wrapper consumes the layer table live.  Idle writes work as
        // before, but an asserted configuration lock must return SLVERR and
        // leave both ends of the table unchanged.  Non-layer control/IRQ
        // registers remain writable while this narrow lock is active.
        axi_write(
            REG_LAYER_BASE,
            32'h1122_3344,
            4'hf,
            0,
            0,
            0,
            response
        );
        check(response == RESP_OKAY, "idle layer-table write response");
        axi_write(
            REG_LAYER_LAST,
            32'h5566_7788,
            4'hf,
            0,
            0,
            0,
            response
        );
        check(response == RESP_OKAY, "idle last layer-table write response");
        axi_read(REG_LAYER_BASE, 0, read_data, response);
        check(
            (response == RESP_OKAY) && (read_data == 32'h1122_3344),
            "idle layer-table write/readback"
        );
        axi_read(REG_LAYER_LAST, 0, read_data, response);
        check(
            (response == RESP_OKAY) && (read_data == 32'h5566_7788),
            "idle last layer-table write/readback"
        );
        axi_write(
            REG_LAYER_BASE + 12'h004,
            32'haabb_ccdd,
            4'b0101,
            0,
            0,
            0,
            response
        );
        check(
            response == RESP_OKAY,
            "layer-table partial byte write response"
        );
        axi_read(REG_LAYER_BASE + 12'h004, 0, read_data, response);
        check(
            (response == RESP_OKAY) && (read_data == 32'h00bb_00dd),
            "layer-table byte strobes and zero-invalid bytes"
        );

        config_busy = 1'b1;
        axi_write(
            REG_LAYER_BASE,
            32'haaaa_5555,
            4'hf,
            0,
            0,
            0,
            response
        );
        check(response == RESP_SLVERR, "busy layer write returns SLVERR");
        axi_write(
            REG_LAYER_LAST,
            32'hbbbb_6666,
            4'hf,
            0,
            0,
            0,
            response
        );
        check(response == RESP_SLVERR, "busy last layer write returns SLVERR");
        axi_read(REG_LAYER_BASE, 0, read_data, response);
        check(
            (response == RESP_OKAY) && (read_data == 32'h1122_3344),
            "busy write did not alter first layer word"
        );
        axi_read(REG_LAYER_LAST, 0, read_data, response);
        check(
            (response == RESP_OKAY) && (read_data == 32'h5566_7788),
            "busy write did not alter last layer word"
        );
        axi_write(
            REG_IRQ_ENABLE,
            32'h0000_0005,
            4'hf,
            0,
            0,
            0,
            response
        );
        check(
            (response == RESP_OKAY) && (irq_enable == 32'h0000_0005),
            "layer lock does not block IRQ control"
        );
        axi_write(
            REG_CONTROL,
            32'h0000_0008,
            4'b0001,
            0,
            0,
            0,
            response
        );
        repeat (2)
            @(posedge aclk);
        #1;
        check(
            (response == RESP_OKAY)
            && (clear_error_count == 1)
            && (start_count == 0)
            && (soft_reset_count == 0)
            && (abort_count == 0),
            "layer lock does not block CONTROL pulses"
        );

        // Lock policy is evaluated when the complete write commits, not when
        // AW is first buffered.  This closes the split-channel race where AW
        // arrives idle but W arrives only after the wrapper becomes busy.
        config_busy = 1'b0;
        drive_aw(REG_LAYER_BASE, 0);
        config_busy = 1'b1;
        drive_w(32'hdead_beef, 4'hf, 0);
        while (!s_axi_bvalid) begin
            @(posedge aclk);
            #1;
        end
        response = s_axi_bresp;
        @(negedge aclk);
        s_axi_bready = 1'b1;
        @(posedge aclk);
        @(negedge aclk);
        s_axi_bready = 1'b0;
        check(
            response == RESP_SLVERR,
            "busy transition before split write commit returns SLVERR"
        );
        axi_read(REG_LAYER_BASE, 0, read_data, response);
        check(
            (response == RESP_OKAY) && (read_data == 32'h1122_3344),
            "split-channel busy transition left layer word unchanged"
        );
        config_busy = 1'b0;

        // CONTROL pulses occur once even while B is backpressured.
        axi_write(
            REG_CONTROL,
            32'h0000_000f,
            4'b0001,
            0,
            0,
            4,
            response
        );
        check(response == RESP_OKAY, "CONTROL response");
        repeat (2)
            @(posedge aclk);
        #1;
        check(start_count == 1, "START pulse count");
        check(soft_reset_count == 1, "SOFT_RESET pulse count");
        check(abort_count == 1, "ABORT pulse count");
        check(clear_error_count == 2, "CLEAR_ERROR pulse count");
        check(
            !start_pulse && !soft_reset_pulse
            && !abort_pulse && !clear_error_pulse,
            "CONTROL pulses self-clear"
        );
        axi_write(
            REG_CONTROL,
            32'h0000_000f,
            4'b0010,
            0,
            0,
            0,
            response
        );
        repeat (2)
            @(posedge aclk);
        #1;
        check(start_count == 1, "CONTROL respects WSTRB");
        axi_read(REG_CONTROL, 0, read_data, response);
        check(read_data == 0, "CONTROL reads as self-cleared zero");

        // Live STATUS and ERROR inputs.
        status_idle = 1'b0;
        status_busy = 1'b1;
        status_done = 1'b1;
        status_error = 1'b1;
        status_fallback_wait = 1'b1;
        error_code = 32'hdead_0007;
        error_info = 32'h1234_abcd;
        axi_write(
            REG_IRQ_ENABLE,
            32'h0000_0005,
            4'hf,
            0,
            0,
            0,
            response
        );
        axi_read(REG_STATUS, 0, read_data, response);
        check(read_data == 32'h0000_002e, "STATUS live bits without IRQ");
        axi_read(REG_ERROR_CODE, 0, read_data, response);
        check(read_data == error_code, "ERROR_CODE live input");
        axi_read(REG_ERROR_INFO, 0, read_data, response);
        check(read_data == error_info, "ERROR_INFO live input");

        // Sticky interrupt, mask, RW1C, byte strobes, and event-wins-clear.
        pulse_irq_events(32'h0000_0001);
        check(irq_status == 32'h1 && irq, "IRQ event and mask");
        axi_read(REG_STATUS, 0, read_data, response);
        check(read_data == 32'h0000_003e, "STATUS IRQ bit");
        axi_write(
            REG_IRQ_STATUS,
            32'h0000_0002,
            4'hf,
            0,
            0,
            0,
            response
        );
        check(irq_status == 32'h1, "RW1C does not clear zero bit");
        axi_write(
            REG_IRQ_STATUS,
            32'h0000_0001,
            4'hf,
            0,
            0,
            0,
            response
        );
        check(irq_status == 0 && !irq, "RW1C clear and IRQ deassert");

        pulse_irq_events(32'h0000_0101);
        axi_write(
            REG_IRQ_STATUS,
            32'h0000_0101,
            4'b0001,
            0,
            0,
            0,
            response
        );
        check(
            irq_status == 32'h0000_0100,
            "IRQ_STATUS RW1C respects WSTRB"
        );
        axi_write(
            REG_IRQ_STATUS,
            32'h0000_0100,
            4'b0010,
            0,
            0,
            0,
            response
        );
        check(irq_status == 0, "IRQ_STATUS second-byte clear");

        pulse_irq_events(32'h0000_0004);
        @(negedge aclk);
        irq_events = 32'h0000_0004;
        axi_write(
            REG_IRQ_STATUS,
            32'h0000_0004,
            4'hf,
            0,
            0,
            2,
            response
        );
        @(negedge aclk);
        irq_events = 32'b0;
        @(posedge aclk);
        #1;
        check(
            irq_status == 32'h0000_0004,
            "simultaneous IRQ event wins RW1C clear"
        );
        axi_irq_clear_with_commit_event(
            32'h0000_0004,
            32'h0000_0004,
            response
        );
        check(response == RESP_OKAY, "event-at-commit write response");
        check(
            irq_status == 32'h0000_0004,
            "one-cycle event-at-commit remains sticky"
        );
        axi_write(
            REG_IRQ_STATUS,
            32'h0000_0004,
            4'hf,
            0,
            0,
            0,
            response
        );
        check(irq_status == 0, "final IRQ clear");

        // Writes to RO, invalid addresses, and unaligned accesses are SLVERR.
        axi_write(
            REG_IP_ID,
            32'hffff_ffff,
            4'hf,
            0,
            0,
            0,
            response
        );
        check(response == RESP_SLVERR, "RO write returns SLVERR");
        axi_read(REG_IP_ID, 0, read_data, response);
        check(read_data == 32'h5649_544e, "RO write did not alter IP_ID");
        axi_write(
            12'h048,
            32'h1,
            4'hf,
            0,
            0,
            0,
            response
        );
        check(response == RESP_SLVERR, "invalid write returns SLVERR");
        axi_read(12'h078, 0, read_data, response);
        check(
            response == RESP_SLVERR && read_data == 0,
            "invalid read returns zero/SLVERR"
        );
        axi_write(
            12'h011,
            32'h1,
            4'hf,
            0,
            0,
            0,
            response
        );
        check(response == RESP_SLVERR, "unaligned write returns SLVERR");
        axi_read(12'h003, 0, read_data, response);
        check(response == RESP_SLVERR, "unaligned read returns SLVERR");

        // Reset clears a partially captured write rather than committing it
        // after reset release.
        pulse_irq_events(32'h0000_0001);
        drive_aw(REG_MODEL_WORDS, 0);
        #1;
        check(
            !s_axi_awready && s_axi_wready,
            "AW-only transaction was not held independently"
        );
        @(negedge aclk);
        aresetn = 1'b0;
        repeat (2)
            @(posedge aclk);
        #1;
        check(
            irq_enable == 0 && irq_status == 0 && !irq,
            "reset clears IRQ state"
        );
        check(
            model_base == 0 && input_base == 0 && scratch_base == 0,
            "reset clears base registers"
        );
        check(
            model_words == 0 && input_words == 0 && scratch_words == 0,
            "reset clears word limits"
        );
        check(execution_mode == 0, "reset clears execution mode");
        check(
            (profile_trace_select == 0) &&
            !profile_trace_select_strobe,
            "reset clears trace selector state"
        );
        check(
            !s_axi_bvalid && !s_axi_rvalid,
            "reset did not clear response channels"
        );
        check(
            s_axi_awready && s_axi_wready && s_axi_arready,
            "reset did not clear held AXI request state"
        );
        @(negedge aclk);
        aresetn = 1'b1;
        repeat (2)
            @(posedge aclk);

        // Reset also aborts completed-but-unaccepted B and R responses.
        fork
            drive_aw(REG_MODEL_WORDS, 0);
            drive_w(32'hfeed_beef, 4'hf, 0);
        join
        while (!s_axi_bvalid) begin
            @(posedge aclk);
            #1;
        end
        check(
            model_words == 32'hfeed_beef,
            "pre-reset outstanding write did not commit"
        );

        @(negedge aclk);
        s_axi_araddr = REG_IP_ID;
        s_axi_arvalid = 1'b1;
        do begin
            @(posedge aclk);
        end while (!(s_axi_arvalid && s_axi_arready));
        @(negedge aclk);
        s_axi_arvalid = 1'b0;
        while (!s_axi_rvalid) begin
            @(posedge aclk);
            #1;
        end
        check(
            s_axi_bvalid && s_axi_rvalid,
            "test setup did not create outstanding B and R responses"
        );

        @(negedge aclk);
        aresetn = 1'b0;
        @(posedge aclk);
        #1;
        check(
            !s_axi_bvalid && !s_axi_rvalid,
            "reset did not abort outstanding B/R responses"
        );
        check(
            model_words == 0,
            "reset did not clear register written before B acceptance"
        );
        @(negedge aclk);
        aresetn = 1'b1;
        repeat (2)
            @(posedge aclk);

        if (failures == 0) begin
            $display(
                "P4_AXI_LITE_CONTROL_TEST_PASS checks=%0d",
                checks
            );
            $finish;
        end

        $fatal(
            1,
            "P4_AXI_LITE_CONTROL_TEST_FAIL failures=%0d checks=%0d",
            failures,
            checks
        );
    end

endmodule
