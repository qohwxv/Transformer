`timescale 1ns/1ps

// Production-path M8 Vector/GELU read-ahead regression.
//
// This test instantiates the real engine frontend, unchanged M5 AXI adapter
// and the native-128 DDR model.  A registered pseudo-random proxy stalls all
// five AXI channels while preserving each ready/valid handshake.  The same
// test is compiled against the exact M7 parent router and the M8 candidate;
// REQ_TRACE and RESULT_TRACE are compared by the runner.
module tb_m8_vector_gelu_linefill_integration;

    import vit_phase_e_pkg::*;
    import vit_fp32_pkg::*;

    localparam integer AXI_ADDR_WIDTH = 40;
    localparam integer AXI_ID_WIDTH = 1;
    localparam integer MEMORY_WORDS = 8192;
    localparam logic [63:0] MODEL_BASE = 64'h0000_0000_0100_0000;
    localparam logic [63:0] INPUT_BASE = 64'h0000_0000_0200_0000;
    localparam logic [63:0] SCRATCH_BASE = 64'h0000_0000_0300_0000;

    logic clk = 1'b0;
    logic rst = 1'b1;
    wire aresetn = !rst;

    logic cmd_valid = 1'b0;
    logic cmd_ready;
    phase_e_cmd_t cmd;
    logic cmd_done;
    logic cmd_error;
    logic busy;
    logic parameter_request;
    phase_e_cmd_t parameter_command;

    logic mem_req_valid;
    logic mem_req_ready;
    logic mem_req_write;
    phase_e_mem_space_t mem_req_space;
    logic [31:0] mem_req_word_address;
    logic [31:0] mem_req_write_data;
    logic [3:0] mem_req_write_strobe;
    logic mem_req_read_ahead_safe;
    logic [5:0] mem_req_contiguous_words;
    logic mem_rsp_valid;
    logic mem_rsp_ready;
    logic [31:0] mem_rsp_read_data;
    logic mem_rsp_error;
    phase_e_profile_core_events_t profile_events;
    phase_e_m7_profile_events_t m7_profile_events;

    logic [AXI_ID_WIDTH-1:0] a_awid;
    logic [AXI_ADDR_WIDTH-1:0] a_awaddr;
    logic [7:0] a_awlen;
    logic [2:0] a_awsize;
    logic [1:0] a_awburst;
    logic a_awlock;
    logic [3:0] a_awcache;
    logic [2:0] a_awprot;
    logic [3:0] a_awqos;
    logic a_awvalid;
    logic a_awready;
    logic d_awready;

    logic [127:0] a_wdata;
    logic [15:0] a_wstrb;
    logic a_wlast;
    logic a_wvalid;
    logic a_wready;
    logic d_wready;

    logic [AXI_ID_WIDTH-1:0] d_bid;
    logic [1:0] d_bresp;
    logic d_bvalid;
    logic a_bvalid;
    logic a_bready;

    logic [AXI_ID_WIDTH-1:0] a_arid;
    logic [AXI_ADDR_WIDTH-1:0] a_araddr;
    logic [7:0] a_arlen;
    logic [2:0] a_arsize;
    logic [1:0] a_arburst;
    logic a_arlock;
    logic [3:0] a_arcache;
    logic [2:0] a_arprot;
    logic [3:0] a_arqos;
    logic a_arvalid;
    logic a_arready;
    logic d_arready;

    logic [AXI_ID_WIDTH-1:0] d_rid;
    logic [127:0] d_rdata;
    logic [1:0] d_rresp;
    logic d_rlast;
    logic d_rvalid;
    logic a_rvalid;
    logic a_rready;

    logic cache_invalidate;
    logic adapter_r_protocol_error;
    logic adapter_b_protocol_error;
    logic linefill_start;
    logic linefill_hit;
    logic full_r_beat;
    logic narrow_r_beat;
    logic four_k_split;
    logic [5:0] prefetched_words_discarded;
    logic [1:0] adapter_read_outstanding;

    logic fault_rresp_enable;
    logic [7:0] fault_rresp_beat;
    logic [1:0] fault_rresp_value;
    logic [1:0] fault_rlast_mode;

    logic [63:0] ram_read_count;
    logic [63:0] ram_write_count;
    logic [63:0] ram_model_read_count;
    logic [63:0] ram_input_read_count;
    logic [63:0] ram_scratch_read_count;
    logic [63:0] ram_scratch_write_count;
    logic [63:0] ram_ar_count;
    logic [63:0] ram_aw_count;
    logic [63:0] ram_r_beat_count;
    logic [63:0] ram_w_beat_count;
    logic [63:0] ram_b_count;
    logic [63:0] ram_ar_requested_beats;
    logic [31:0] ram_invalid_access_count;
    logic [31:0] ram_protocol_error_count;
    logic [31:0] ram_four_kib_error_count;
    logic [31:0] ram_read_outstanding;
    logic [31:0] ram_write_outstanding;
    logic [31:0] ram_read_outstanding_high_water;

    logic [31:0] stall_lfsr;
    logic [31:0] cycle_count;
    logic allow_aw;
    logic allow_w;
    logic allow_b;
    logic allow_ar;
    logic allow_r;
    integer seed;
    integer negative_mode;

    integer checks = 0;
    integer failures = 0;
    integer done_count = 0;
    integer error_count = 0;
    integer request_trace_count = 0;
    integer result_trace_count = 0;
    integer logical_read_count = 0;
    integer logical_write_count = 0;
    integer linefill_start_count = 0;
    integer linefill_hit_count = 0;
    integer full_r_beat_count = 0;
    integer narrow_r_beat_count = 0;
    integer discard_word_count = 0;
    integer r_protocol_error_count = 0;
    integer b_protocol_error_count = 0;
    integer command_tag = 0;
    integer tail;
    integer lane;
    integer src0_word;
    integer src1_word;
    integer dst_word;
    integer before_done;
    integer before_error;
    integer command_watchdog;
    logic [31:0] expected_word;
    logic [63:0] model_reads_before;

    always #5 clk = ~clk;

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $error("CHECK FAILED: %s", message);
            end
        end
    endtask

    // Registered pseudo-random channel gating.  A periodic escape condition
    // guarantees forward progress for every seed.
    assign allow_aw = stall_lfsr[0] || (cycle_count[4:0] == 5'd0);
    assign allow_w  = stall_lfsr[5] || (cycle_count[4:0] == 5'd3);
    assign allow_b  = stall_lfsr[11] || (cycle_count[4:0] == 5'd7);
    assign allow_ar = stall_lfsr[17] || (cycle_count[4:0] == 5'd13);
    assign allow_r  = stall_lfsr[23] || (cycle_count[4:0] == 5'd19);

    assign a_awready = d_awready && allow_aw;
    assign a_wready = d_wready && allow_w;
    assign a_bvalid = d_bvalid && allow_b;
    assign a_arready = d_arready && allow_ar;
    assign a_rvalid = d_rvalid && allow_r;

    always_ff @(posedge clk) begin
        if (rst) begin
            stall_lfsr <= (seed == 0) ? 32'h0000_0001 : seed;
            cycle_count <= 32'd0;
            done_count <= 0;
            error_count <= 0;
            request_trace_count <= 0;
            result_trace_count <= 0;
            logical_read_count <= 0;
            logical_write_count <= 0;
            linefill_start_count <= 0;
            linefill_hit_count <= 0;
            full_r_beat_count <= 0;
            narrow_r_beat_count <= 0;
            discard_word_count <= 0;
            r_protocol_error_count <= 0;
            b_protocol_error_count <= 0;
            cache_invalidate <= 1'b0;
        end else begin
            stall_lfsr <= {stall_lfsr[30:0],
                stall_lfsr[31] ^ stall_lfsr[21] ^
                stall_lfsr[1] ^ stall_lfsr[0]};
            cycle_count <= cycle_count + 1'b1;
            cache_invalidate <= 1'b0;

            if (cmd_done)
                done_count <= done_count + 1;
            if (cmd_error)
                error_count <= error_count + 1;

            if (profile_events.logical_read_word)
                logical_read_count <= logical_read_count + 1;
            if (profile_events.logical_write_word)
                logical_write_count <= logical_write_count + 1;

            if (linefill_start) begin
                linefill_start_count <= linefill_start_count + 1;
                if (negative_mode == 3)
                    cache_invalidate <= 1'b1;
            end
            if (linefill_hit)
                linefill_hit_count <= linefill_hit_count + 1;
            if (full_r_beat)
                full_r_beat_count <= full_r_beat_count + 1;
            if (narrow_r_beat)
                narrow_r_beat_count <= narrow_r_beat_count + 1;
            if (prefetched_words_discarded != 0)
                discard_word_count <= discard_word_count +
                    prefetched_words_discarded;
            if (adapter_r_protocol_error)
                r_protocol_error_count <= r_protocol_error_count + 1;
            if (adapter_b_protocol_error)
                b_protocol_error_count <= b_protocol_error_count + 1;

            if (mem_req_valid && mem_req_ready) begin
                $display(
                    "REQ_TRACE %0d %0d %0d %08x %08x %x",
                    request_trace_count,
                    mem_req_write,
                    mem_req_space,
                    mem_req_word_address,
                    mem_req_write_data,
                    mem_req_write_strobe
                );
                request_trace_count <= request_trace_count + 1;
            end
        end
    end

    vit_phase_e_engine_top #(
        .ARRAY_ROWS(8),
        .ARRAY_COLS(2),
        .PE_LANES(16),
        .FP16_STREAMS(8),
        .VECTOR_LANES(16),
        .GEMM_A_CACHE_DEPTH_WORDS(3072),
        .GEMM_BIAS_CACHE_DEPTH_WORDS(3072),
        .SCRATCH_WORDS(MEMORY_WORDS),
        .INPUT_WORDS(MEMORY_WORDS),
        .PARAM_WORDS(MEMORY_WORDS)
    ) u_engine (
        .clk(clk),
        .rst(rst),
        .cmd_valid(cmd_valid),
        .cmd_ready(cmd_ready),
        .cmd(cmd),
        .cmd_done(cmd_done),
        .cmd_error(cmd_error),
        .busy(busy),
        .parameter_request(parameter_request),
        .parameter_ready(1'b1),
        .parameter_command(parameter_command),
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_req_write(mem_req_write),
        .mem_req_space(mem_req_space),
        .mem_req_word_address(mem_req_word_address),
        .mem_req_write_data(mem_req_write_data),
        .mem_req_write_strobe(mem_req_write_strobe),
        .mem_req_read_ahead_safe(mem_req_read_ahead_safe),
        .mem_req_contiguous_words(mem_req_contiguous_words),
        .mem_rsp_valid(mem_rsp_valid),
        .mem_rsp_ready(mem_rsp_ready),
        .mem_rsp_read_data(mem_rsp_read_data),
        .mem_rsp_error(mem_rsp_error),
        .input_write_enable(1'b0),
        .input_write_address(32'd0),
        .input_write_data(32'd0),
        .parameter_write_enable(1'b0),
        .parameter_write_address(32'd0),
        .parameter_write_data(32'd0),
        .scratch_write_enable(1'b0),
        .scratch_write_address(32'd0),
        .scratch_write_data(32'd0),
        .scratch_read_address(32'd0),
        .scratch_read_data(),
        .class_result_valid(),
        .class_index(),
        .class_logit(),
        .profile_events(profile_events),
        .m7_profile_events(m7_profile_events)
    );

    vit_phase_e_axi_mem_adapter #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MAX_BURST_BEATS(4),
        .MAX_READ_OUTSTANDING(2),
        .MAX_LINE_WORDS(32)
    ) u_adapter (
        .aclk(clk),
        .aresetn(aresetn),
        .scratch_base_i(SCRATCH_BASE),
        .model_base_i(MODEL_BASE),
        .input_base_i(INPUT_BASE),
        .scratch_words_i(MEMORY_WORDS),
        .model_words_i(MEMORY_WORDS),
        .input_words_i(MEMORY_WORDS),
        .cache_invalidate_i(cache_invalidate),
        .req_valid(mem_req_valid),
        .req_ready(mem_req_ready),
        .req_write(mem_req_write),
        .req_space(mem_req_space),
        .req_word_address(mem_req_word_address),
        .req_write_data(mem_req_write_data),
        .req_write_strobe(mem_req_write_strobe),
        .req_read_ahead_safe(mem_req_read_ahead_safe),
        .req_contiguous_words(mem_req_contiguous_words),
        .rsp_valid(mem_rsp_valid),
        .rsp_ready(mem_rsp_ready),
        .rsp_read_data(mem_rsp_read_data),
        .rsp_error(mem_rsp_error),
        .axi_r_protocol_error_o(adapter_r_protocol_error),
        .axi_b_protocol_error_o(adapter_b_protocol_error),
        .linefill_start_o(linefill_start),
        .linefill_hit_o(linefill_hit),
        .full_r_beat_o(full_r_beat),
        .narrow_r_beat_o(narrow_r_beat),
        .four_k_split_o(four_k_split),
        .prefetched_words_discarded_o(prefetched_words_discarded),
        .read_outstanding_o(adapter_read_outstanding),
        .m_axi_awid(a_awid),
        .m_axi_awaddr(a_awaddr),
        .m_axi_awlen(a_awlen),
        .m_axi_awsize(a_awsize),
        .m_axi_awburst(a_awburst),
        .m_axi_awlock(a_awlock),
        .m_axi_awcache(a_awcache),
        .m_axi_awprot(a_awprot),
        .m_axi_awqos(a_awqos),
        .m_axi_awvalid(a_awvalid),
        .m_axi_awready(a_awready),
        .m_axi_wdata(a_wdata),
        .m_axi_wstrb(a_wstrb),
        .m_axi_wlast(a_wlast),
        .m_axi_wvalid(a_wvalid),
        .m_axi_wready(a_wready),
        .m_axi_bid(d_bid),
        .m_axi_bresp(d_bresp),
        .m_axi_bvalid(a_bvalid),
        .m_axi_bready(a_bready),
        .m_axi_arid(a_arid),
        .m_axi_araddr(a_araddr),
        .m_axi_arlen(a_arlen),
        .m_axi_arsize(a_arsize),
        .m_axi_arburst(a_arburst),
        .m_axi_arlock(a_arlock),
        .m_axi_arcache(a_arcache),
        .m_axi_arprot(a_arprot),
        .m_axi_arqos(a_arqos),
        .m_axi_arvalid(a_arvalid),
        .m_axi_arready(a_arready),
        .m_axi_rid(d_rid),
        .m_axi_rdata(d_rdata),
        .m_axi_rresp(d_rresp),
        .m_axi_rlast(d_rlast),
        .m_axi_rvalid(a_rvalid),
        .m_axi_rready(a_rready)
    );

    vit_axi_ddr_model_128 #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MODEL_WORDS(MEMORY_WORDS),
        .INPUT_WORDS(MEMORY_WORDS),
        .SCRATCH_WORDS(MEMORY_WORDS),
        .MODEL_BASE(MODEL_BASE),
        .INPUT_BASE(INPUT_BASE),
        .SCRATCH_BASE(SCRATCH_BASE),
        .MAX_BURST_BEATS(4),
        .READ_QUEUE_DEPTH(4),
        .WRITE_QUEUE_DEPTH(4),
        .W_QUEUE_DEPTH(8),
        .STALL_ENABLE(1'b0)
    ) u_ram (
        .aclk(clk),
        .aresetn(aresetn),
        .s_axi_awid(a_awid),
        .s_axi_awaddr(a_awaddr),
        .s_axi_awlen(a_awlen),
        .s_axi_awsize(a_awsize),
        .s_axi_awburst(a_awburst),
        .s_axi_awlock(a_awlock),
        .s_axi_awcache(a_awcache),
        .s_axi_awprot(a_awprot),
        .s_axi_awqos(a_awqos),
        .s_axi_awvalid(a_awvalid && allow_aw),
        .s_axi_awready(d_awready),
        .s_axi_wdata(a_wdata),
        .s_axi_wstrb(a_wstrb),
        .s_axi_wlast(a_wlast),
        .s_axi_wvalid(a_wvalid && allow_w),
        .s_axi_wready(d_wready),
        .s_axi_bid(d_bid),
        .s_axi_bresp(d_bresp),
        .s_axi_bvalid(d_bvalid),
        .s_axi_bready(a_bready && allow_b),
        .s_axi_arid(a_arid),
        .s_axi_araddr(a_araddr),
        .s_axi_arlen(a_arlen),
        .s_axi_arsize(a_arsize),
        .s_axi_arburst(a_arburst),
        .s_axi_arlock(a_arlock),
        .s_axi_arcache(a_arcache),
        .s_axi_arprot(a_arprot),
        .s_axi_arqos(a_arqos),
        .s_axi_arvalid(a_arvalid && allow_ar),
        .s_axi_arready(d_arready),
        .s_axi_rid(d_rid),
        .s_axi_rdata(d_rdata),
        .s_axi_rresp(d_rresp),
        .s_axi_rlast(d_rlast),
        .s_axi_rvalid(d_rvalid),
        .s_axi_rready(a_rready && allow_r),
        .fault_rresp_enable_i(fault_rresp_enable),
        .fault_rresp_id_i('0),
        .fault_rresp_beat_i(fault_rresp_beat),
        .fault_rresp_value_i(fault_rresp_value),
        .fault_rid_enable_i(1'b0),
        .fault_rid_value_i('0),
        .fault_rlast_mode_i(fault_rlast_mode),
        .fault_bresp_enable_i(1'b0),
        .fault_bresp_id_i('0),
        .fault_bresp_value_i('0),
        .fault_bid_enable_i(1'b0),
        .fault_bid_value_i('0),
        .read_count_o(ram_read_count),
        .write_count_o(ram_write_count),
        .model_read_count_o(ram_model_read_count),
        .input_read_count_o(ram_input_read_count),
        .scratch_read_count_o(ram_scratch_read_count),
        .scratch_write_count_o(ram_scratch_write_count),
        .ar_transaction_count_o(ram_ar_count),
        .aw_transaction_count_o(ram_aw_count),
        .r_beat_count_o(ram_r_beat_count),
        .w_beat_count_o(ram_w_beat_count),
        .b_response_count_o(ram_b_count),
        .ar_requested_beat_count_o(ram_ar_requested_beats),
        .aw_requested_beat_count_o(),
        .ar_backpressure_cycle_count_o(),
        .aw_backpressure_cycle_count_o(),
        .w_backpressure_cycle_count_o(),
        .r_backpressure_cycle_count_o(),
        .b_backpressure_cycle_count_o(),
        .invalid_access_count_o(ram_invalid_access_count),
        .protocol_error_count_o(ram_protocol_error_count),
        .four_kib_error_count_o(ram_four_kib_error_count),
        .read_outstanding_count_o(ram_read_outstanding),
        .write_outstanding_count_o(ram_write_outstanding),
        .read_outstanding_high_water_o(ram_read_outstanding_high_water),
        .write_outstanding_high_water_o()
    );

    task automatic issue_command(input logic expect_success);
        begin
            before_done = done_count;
            before_error = error_count;
            command_tag = command_tag + 1;
            cmd.header.tag = 8'(command_tag);
            @(negedge clk);
            cmd_valid = 1'b1;
            do begin
                @(posedge clk);
            end while (!(cmd_valid && cmd_ready));
            @(negedge clk);
            cmd_valid = 1'b0;

            command_watchdog = 0;
            while ((done_count == before_done) &&
                   (error_count == before_error) &&
                   (command_watchdog < 1_000_000)) begin
                @(posedge clk);
                command_watchdog = command_watchdog + 1;
            end
            #1;
            check(command_watchdog < 1_000_000,
                  "command watchdog");
            if (expect_success) begin
                check(done_count == (before_done + 1),
                      "successful command done pulse");
                check(error_count == before_error,
                      "successful command error count");
            end else begin
                check(error_count == (before_error + 1),
                      "negative command error pulse");
                check(done_count == before_done,
                      "negative command must not complete");
            end
            repeat (3)
                @(posedge clk);
        end
    endtask

    task automatic emit_result(
        input integer case_id,
        input integer word_id,
        input logic [31:0] value
    );
        begin
            $display("RESULT_TRACE %0d %0d %08x",
                     case_id, word_id, value);
            result_trace_count = result_trace_count + 1;
        end
    endtask

    task automatic run_positive_suite;
        integer case_id;
        begin
            case_id = 0;

            // Vector ADD: all tails, all alignment residues across the sweep,
            // and distinct INPUT/PARAM source spaces.
            for (tail = 1; tail <= 16; tail = tail + 1) begin
                src0_word = 64 + tail*24 + (tail % 4);
                src1_word = 1024 + tail*24 + ((tail + 1) % 4);
                dst_word = 2048 + tail*20;
                for (lane = 0; lane < tail; lane = lane + 1) begin
                    u_ram.input_memory[src0_word + lane] =
                        fp32_from_u32_synth(lane + 1);
                    u_ram.model_memory[src1_word + lane] =
                        fp32_from_u32_synth(lane + 100);
                    u_ram.scratch_memory[dst_word + lane] = 32'hdead_beef;
                end
                u_ram.scratch_memory[dst_word + tail] = 32'hc001_cafe;

                cmd = '0;
                cmd.header.opcode = PHASE_E_OP_VECTOR;
                cmd.header.subop = PHASE_E_SUBOP_VECTOR_ADD;
                cmd.route.src0_space = PHASE_E_MEM_INPUT;
                cmd.route.src1_space = PHASE_E_MEM_PARAM;
                cmd.route.dst_space = PHASE_E_MEM_SCRATCH;
                cmd.src0_base = src0_word;
                cmd.src1_base = src1_word;
                cmd.dst_base = dst_word;
                cmd.dim0 = tail;
                issue_command(1'b1);

                for (lane = 0; lane < tail; lane = lane + 1) begin
                    expected_word = fp32_from_u32_synth(101 + 2*lane);
                    check(u_ram.scratch_memory[dst_word + lane] ==
                          expected_word, "Vector ADD result");
                    emit_result(case_id, lane,
                                u_ram.scratch_memory[dst_word + lane]);
                end
                check(u_ram.scratch_memory[dst_word + tail] == 32'hc001_cafe,
                      "Vector ADD tail sentinel");
                case_id = case_id + 1;
            end

            // SCALE_MASK with mask disabled must never access src1.  Poisoned
            // B data remains unobservable and multiplying by 1.0 is exact.
            src0_word = 4608;
            src1_word = 5632;
            dst_word = 4864;
            for (lane = 0; lane < 16; lane = lane + 1) begin
                u_ram.scratch_memory[src0_word + lane] =
                    fp32_from_u32_synth(lane + 3);
                u_ram.model_memory[src1_word + lane] = 32'h7fc0_1234;
                u_ram.scratch_memory[dst_word + lane] = 32'hdead_beef;
            end
            model_reads_before = ram_model_read_count;
            cmd = '0;
            cmd.header.opcode = PHASE_E_OP_VECTOR;
            cmd.header.subop = PHASE_E_SUBOP_VECTOR_SCALE_MASK;
            cmd.header.flags = 8'd0;
            cmd.route.src0_space = PHASE_E_MEM_SCRATCH;
            cmd.route.src1_space = PHASE_E_MEM_PARAM;
            cmd.route.dst_space = PHASE_E_MEM_SCRATCH;
            cmd.src0_base = src0_word;
            cmd.src1_base = src1_word;
            cmd.dst_base = dst_word;
            cmd.dim0 = 32'd16;
            cmd.immediate = 32'h3f80_0000;
            issue_command(1'b1);
            check(ram_model_read_count == model_reads_before,
                  "mask-disabled Vector B physical skip");
            for (lane = 0; lane < 16; lane = lane + 1) begin
                expected_word = fp32_from_u32_synth(lane + 3);
                check(u_ram.scratch_memory[dst_word + lane] == expected_word,
                      "mask-disabled SCALE result");
                emit_result(case_id, lane,
                            u_ram.scratch_memory[dst_word + lane]);
            end
            case_id = case_id + 1;

            // Exact same-source and in-place destination alias.  Both A and B
            // must be gathered before the first write; M8 may serve B as hits.
            src0_word = 5120;
            for (lane = 0; lane < 16; lane = lane + 1)
                u_ram.scratch_memory[src0_word + lane] =
                    fp32_from_u32_synth(lane + 1);
            cmd = '0;
            cmd.header.opcode = PHASE_E_OP_VECTOR;
            cmd.header.subop = PHASE_E_SUBOP_VECTOR_ADD;
            cmd.header.flags = PHASE_E_FLAG_IN_PLACE;
            cmd.route.src0_space = PHASE_E_MEM_SCRATCH;
            cmd.route.src1_space = PHASE_E_MEM_SCRATCH;
            cmd.route.dst_space = PHASE_E_MEM_SCRATCH;
            cmd.src0_base = src0_word;
            cmd.src1_base = src0_word;
            cmd.dst_base = src0_word;
            cmd.dim0 = 32'd16;
            issue_command(1'b1);
            for (lane = 0; lane < 16; lane = lane + 1) begin
                expected_word = fp32_from_u32_synth(2*(lane + 1));
                check(u_ram.scratch_memory[src0_word + lane] == expected_word,
                      "Vector in-place alias result");
                emit_result(case_id, lane,
                            u_ram.scratch_memory[src0_word + lane]);
            end
            case_id = case_id + 1;

            // GELU all tails and alignment residues.  Zero is an exact fixed
            // point of the current GELU datapath, avoiding a software-model
            // dependency while still exercising every active lane.
            for (tail = 1; tail <= 16; tail = tail + 1) begin
                src0_word = 2560 + tail*24 + ((tail + 2) % 4);
                dst_word = 3072 + tail*20;
                for (lane = 0; lane < tail; lane = lane + 1) begin
                    u_ram.scratch_memory[src0_word + lane] = 32'd0;
                    u_ram.scratch_memory[dst_word + lane] = 32'hdead_beef;
                end
                u_ram.scratch_memory[dst_word + tail] = 32'hface_feed;
                cmd = '0;
                cmd.header.opcode = PHASE_E_OP_GELU;
                cmd.route.src0_space = PHASE_E_MEM_SCRATCH;
                cmd.route.dst_space = PHASE_E_MEM_SCRATCH;
                cmd.src0_base = src0_word;
                cmd.dst_base = dst_word;
                cmd.dim0 = tail;
                issue_command(1'b1);
                for (lane = 0; lane < tail; lane = lane + 1) begin
                    check(u_ram.scratch_memory[dst_word + lane] == 32'd0,
                          "GELU zero result");
                    emit_result(case_id, lane,
                                u_ram.scratch_memory[dst_word + lane]);
                end
                check(u_ram.scratch_memory[dst_word + tail] == 32'hface_feed,
                      "GELU tail sentinel");
                case_id = case_id + 1;
            end

            // GELU exact in-place alias at a full aligned vector.
            src0_word = 6144;
            for (lane = 0; lane < 16; lane = lane + 1)
                u_ram.scratch_memory[src0_word + lane] = 32'd0;
            cmd = '0;
            cmd.header.opcode = PHASE_E_OP_GELU;
            cmd.header.flags = PHASE_E_FLAG_IN_PLACE;
            cmd.route.src0_space = PHASE_E_MEM_SCRATCH;
            cmd.route.dst_space = PHASE_E_MEM_SCRATCH;
            cmd.src0_base = src0_word;
            cmd.dst_base = src0_word;
            cmd.dim0 = 32'd16;
            issue_command(1'b1);
            for (lane = 0; lane < 16; lane = lane + 1) begin
                check(u_ram.scratch_memory[src0_word + lane] == 32'd0,
                      "GELU in-place alias result");
                emit_result(case_id, lane,
                            u_ram.scratch_memory[src0_word + lane]);
            end

            check(logical_read_count == 472,
                  "exact positive logical read count");
            check(logical_write_count == 320,
                  "exact positive logical write count");
            check(ram_aw_count == 320, "all writes remain scalar AW");
            check(ram_w_beat_count == 320, "all writes remain scalar W");
            check(ram_b_count == 320, "all writes receive B");
            check(ram_scratch_write_count == 320,
                  "scratch write payload count");
            check(ram_invalid_access_count == 0,
                  "no DDR invalid access");
            check(ram_protocol_error_count == 0,
                  "no DDR protocol error");
            check(ram_four_kib_error_count == 0,
                  "no DDR 4 KiB error");
            check(ram_read_outstanding == 0,
                  "DDR read outstanding drains");
            check(ram_write_outstanding == 0,
                  "DDR write outstanding drains");
            check(adapter_read_outstanding == 0,
                  "adapter read outstanding drains");
            check(discard_word_count == 0,
                  "safe gathers consume every prefetched word");
            check(b_protocol_error_count == 0,
                  "adapter B protocol remains clean");
            check(r_protocol_error_count == 0,
                  "adapter R protocol remains clean");
            check(!four_k_split, "no unexpected terminal 4 KiB pulse");

`ifdef M8_CANDIDATE_ROUTER
            check(linefill_start_count > 0,
                  "candidate starts Vector/GELU linefills");
            check(linefill_hit_count > 0,
                  "candidate consumes linefill hits");
            check(full_r_beat_count > 0,
                  "candidate receives full-width beats");
            check(ram_ar_count < logical_read_count,
                  "candidate reduces physical AR transactions");
            check(ram_r_beat_count < logical_read_count,
                  "candidate reduces physical R beats");
            check(ram_read_count <= logical_read_count,
                  "candidate never overfetches semantic words");
`else
            check(linefill_start_count == 0,
                  "parent has no Vector/GELU linefills");
            check(linefill_hit_count == 0,
                  "parent has no Vector/GELU line hits");
            check(full_r_beat_count == 0,
                  "parent has no full-width Vector/GELU beats");
            check(ram_ar_count == logical_read_count,
                  "parent issues one scalar AR per read");
            check(ram_r_beat_count == logical_read_count,
                  "parent issues one scalar R beat per read");
            check(ram_read_count == logical_read_count,
                  "parent reads each logical word physically");
`endif

            $display(
                "TRAFFIC_SUMMARY logical_reads=%0d logical_writes=%0d physical_words=%0d ar=%0d r_beats=%0d linefills=%0d hits=%0d full=%0d narrow=%0d discarded=%0d",
                logical_read_count,
                logical_write_count,
                ram_read_count,
                ram_ar_count,
                ram_r_beat_count,
                linefill_start_count,
                linefill_hit_count,
                full_r_beat_count,
                narrow_r_beat_count,
                discard_word_count
            );
        end
    endtask

    task automatic run_negative_suite;
        begin
            src0_word = 256;
            src1_word = 512;
            dst_word = 768;
            for (lane = 0; lane < 16; lane = lane + 1) begin
                u_ram.input_memory[src0_word + lane] =
                    fp32_from_u32_synth(lane + 1);
                u_ram.model_memory[src1_word + lane] =
                    fp32_from_u32_synth(lane + 100);
                u_ram.scratch_memory[dst_word + lane] = 32'hdead_beef;
            end
            fault_rresp_enable = (negative_mode == 1);
            fault_rresp_beat = 8'd0;
            fault_rresp_value = 2'b10;
            fault_rlast_mode = (negative_mode == 2) ? 2'd2 : 2'd0;

            cmd = '0;
            cmd.header.opcode = PHASE_E_OP_VECTOR;
            cmd.header.subop = PHASE_E_SUBOP_VECTOR_ADD;
            cmd.route.src0_space = PHASE_E_MEM_INPUT;
            cmd.route.src1_space = PHASE_E_MEM_PARAM;
            cmd.route.dst_space = PHASE_E_MEM_SCRATCH;
            cmd.src0_base = src0_word;
            cmd.src1_base = src1_word;
            cmd.dst_base = dst_word;
            cmd.dim0 = 32'd16;
            issue_command(1'b0);

            check(ram_aw_count == 0,
                  "negative read failure prevents destination AW");
            check(ram_w_beat_count == 0,
                  "negative read failure prevents destination W");
            for (lane = 0; lane < 16; lane = lane + 1)
                check(u_ram.scratch_memory[dst_word + lane] == 32'hdead_beef,
                      "negative read failure preserves destination");

            if (negative_mode == 1)
                check(r_protocol_error_count > 0,
                      "RRESP fault raises adapter read-error event");
            if (negative_mode == 2)
                check(r_protocol_error_count > 0,
                      "suppressed RLAST raises framing error");
            if (negative_mode == 3) begin
                check(linefill_start_count > 0,
                      "invalidation case reached active linefill");
                check(discard_word_count == 16,
                      "in-flight invalidation reports the discarded line");
            end
        end
    endtask

    initial begin
        if (!$value$plusargs("SEED=%d", seed))
            seed = 32'h0000_0001;
        if (!$value$plusargs("NEGATIVE=%d", negative_mode))
            negative_mode = 0;
        cmd = '0;
        fault_rresp_enable = 1'b0;
        fault_rresp_beat = 8'd0;
        fault_rresp_value = 2'b00;
        fault_rlast_mode = 2'd0;
        cache_invalidate = 1'b0;

        repeat (7)
            @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        repeat (3)
            @(posedge clk);

        if (negative_mode == 0)
            run_positive_suite();
        else
            run_negative_suite();

        repeat (5)
            @(posedge clk);
        #1;
        if (failures == 0) begin
`ifdef M8_CANDIDATE_ROUTER
            $display(
                "M8_LINEFILL_INTEGRATION_PASS implementation=M8 seed=%0d negative=%0d checks=%0d req_traces=%0d result_traces=%0d",
                seed, negative_mode, checks, request_trace_count,
                result_trace_count
            );
`else
            $display(
                "M8_LINEFILL_INTEGRATION_PASS implementation=M7_PARENT seed=%0d negative=%0d checks=%0d req_traces=%0d result_traces=%0d",
                seed, negative_mode, checks, request_trace_count,
                result_trace_count
            );
`endif
            $finish;
        end
        $fatal(1,
               "M8_LINEFILL_INTEGRATION_FAIL failures=%0d checks=%0d seed=%0d negative=%0d",
               failures, checks, seed, negative_mode);
    end

endmodule
