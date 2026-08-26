
`timescale 1ns/1ps

module tb_m8_memory_subsystem_layout_write;

    import vit_phase_e_pkg::*;

    localparam integer ARRAY_ROWS   = 8;
    localparam integer ARRAY_COLS   = 2;
    localparam integer PE_LANES     = 16;
    localparam integer VECTOR_LANES = 16;

    localparam integer AXI_ADDR_WIDTH = 40;
    localparam integer AXI_ID_WIDTH   = 1;

    localparam logic [63:0] MODEL_BASE   = 64'h0000_0000;
    localparam logic [63:0] INPUT_BASE   = 64'h0002_0000;
    localparam logic [63:0] SCRATCH_BASE = 64'h0004_0000;

    localparam logic [31:0] TEST_WORD_ADDR = 32'd5;
    localparam logic [31:0] TEST_VALUE     = 32'h3F80_0000;

    logic aclk;
    logic aresetn;

    // ------------------------------------------------------------
    // Memory map
    // ------------------------------------------------------------
    logic [63:0] scratch_base_i;
    logic [63:0] model_base_i;
    logic [63:0] input_base_i;

    logic [31:0] scratch_words_i;
    logic [31:0] model_words_i;
    logic [31:0] input_words_i;

    logic cache_invalidate_i;

    // ------------------------------------------------------------
    // Command/frontend control
    // ------------------------------------------------------------
    logic command_accept;
    logic execute;

    phase_e_cmd_t active_cmd;

    logic selected_data_request;
    logic selected_result_valid;

    logic [15:0] read_word_count;
    logic [15:0] write_word_count;

    logic memory_error_latched;
    logic [3:0] debug_mem_state;

    // ------------------------------------------------------------
    // Profile outputs
    // ------------------------------------------------------------
    logic profile_logical_read_word_o;
    logic profile_logical_write_word_o;
    logic profile_load_active_o;
    logic profile_store_active_o;

    logic profile_a_cache_lookup_o;
    logic profile_a_cache_hit_o;
    logic profile_a_cache_miss_o;

    logic profile_bias_cache_lookup_o;
    logic profile_bias_cache_hit_o;
    logic profile_bias_cache_miss_o;

    logic profile_b_bypass_o;
    logic profile_frontend_error_o;

    logic [3:0] profile_a_vector_hit_word_delta_o;
    logic profile_a_vector_protocol_error_o;
    logic profile_result_generation_error_o;

    // ------------------------------------------------------------
    // GEMM inputs/outputs
    // ------------------------------------------------------------
    logic [31:0] gemm_token_base;
    logic [31:0] gemm_output_base;
    logic [31:0] gemm_k_base;
    logic [31:0] gemm_batch_index;

    logic [ARRAY_ROWS*PE_LANES*32-1:0] gemm_activation_data;
    logic [ARRAY_COLS*PE_LANES*32-1:0] gemm_weight_data;
    logic [ARRAY_COLS*32-1:0] gemm_bias_data;

    logic gemm_data_valid;

    logic [65:0] gemm_result_address_base_current_o;
    logic [65:0] gemm_result_address_base_store_i;

    logic [7:0] gemm_result_generation_store_i;
    logic [7:0] gemm_result_generation_expected_i;

    logic [31:0] gemm_result_token_base_store_i;
    logic [31:0] gemm_result_output_base_store_i;
    logic [31:0] gemm_result_batch_index_store_i;

    logic [ARRAY_ROWS-1:0] gemm_result_token_mask;
    logic [ARRAY_COLS-1:0] gemm_result_output_mask;

    logic [ARRAY_ROWS*ARRAY_COLS*32-1:0] gemm_result_data;

    logic gemm_result_ready;

    // ------------------------------------------------------------
    // Vector
    // ------------------------------------------------------------
    logic [31:0] vector_element_base;

    logic [VECTOR_LANES*32-1:0] vector_input_a;
    logic [VECTOR_LANES*32-1:0] vector_input_b;

    logic vector_data_valid;

    logic [31:0] vector_result_base;
    logic [VECTOR_LANES-1:0] vector_result_lane_mask;
    logic [VECTOR_LANES*32-1:0] vector_result_data;

    logic vector_result_ready;

    // ------------------------------------------------------------
    // Layout
    // ------------------------------------------------------------
    logic [31:0] layout_source_address;
    logic [31:0] layout_source_data;
    logic layout_data_valid;

    logic [31:0] layout_result_address;
    logic [31:0] layout_result_data;
    logic layout_result_ready;

    // ------------------------------------------------------------
    // LayerNorm
    // ------------------------------------------------------------
    logic [1:0] ln_data_pass;
    logic [31:0] ln_data_index;
    logic [31:0] ln_data_channel_index;

    logic [31:0] ln_input_data;
    logic [31:0] ln_gamma_data;
    logic [31:0] ln_beta_data;
    logic ln_input_valid;

    logic [31:0] ln_result_index;
    logic [31:0] ln_result_data;
    logic ln_result_ready;

    // ------------------------------------------------------------
    // Softmax
    // ------------------------------------------------------------
    logic [31:0] softmax_data_index;
    logic [31:0] softmax_input_data;
    logic softmax_input_valid;

    logic [31:0] softmax_result_index;
    logic [31:0] softmax_result_data;
    logic softmax_result_ready;

    // ------------------------------------------------------------
    // GELU
    // ------------------------------------------------------------
    logic [31:0] gelu_data_base_index;
    logic [VECTOR_LANES-1:0] gelu_data_lane_mask;

    logic [VECTOR_LANES*32-1:0] gelu_input_data;
    logic gelu_input_valid;

    logic [31:0] gelu_result_base_index;
    logic [VECTOR_LANES-1:0] gelu_result_lane_mask;
    logic [VECTOR_LANES*32-1:0] gelu_result_data;

    logic gelu_result_ready;

    // ------------------------------------------------------------
    // Argmax
    // ------------------------------------------------------------
    logic [31:0] argmax_element_index;
    logic [31:0] argmax_input_data;
    logic argmax_data_valid;
    logic argmax_result_ready;

    // ------------------------------------------------------------
    // Adapter profiling
    // ------------------------------------------------------------
    logic axi_r_protocol_error_o;
    logic axi_b_protocol_error_o;

    logic linefill_start_o;
    logic linefill_hit_o;

    logic full_r_beat_o;
    logic narrow_r_beat_o;
    logic four_k_split_o;

    logic [5:0] prefetched_words_discarded_o;
    logic [1:0] read_outstanding_o;

    // ------------------------------------------------------------
    // AXI write address
    // ------------------------------------------------------------
    logic [AXI_ID_WIDTH-1:0] m_axi_awid;
    logic [AXI_ADDR_WIDTH-1:0] m_axi_awaddr;
    logic [7:0] m_axi_awlen;
    logic [2:0] m_axi_awsize;
    logic [1:0] m_axi_awburst;
    logic m_axi_awlock;
    logic [3:0] m_axi_awcache;
    logic [2:0] m_axi_awprot;
    logic [3:0] m_axi_awqos;
    logic m_axi_awvalid;
    logic m_axi_awready;

    // AXI W
    logic [127:0] m_axi_wdata;
    logic [15:0] m_axi_wstrb;
    logic m_axi_wlast;
    logic m_axi_wvalid;
    logic m_axi_wready;

    // AXI B
    logic [AXI_ID_WIDTH-1:0] m_axi_bid;
    logic [1:0] m_axi_bresp;
    logic m_axi_bvalid;
    logic m_axi_bready;

    // AXI AR
    logic [AXI_ID_WIDTH-1:0] m_axi_arid;
    logic [AXI_ADDR_WIDTH-1:0] m_axi_araddr;
    logic [7:0] m_axi_arlen;
    logic [2:0] m_axi_arsize;
    logic [1:0] m_axi_arburst;
    logic m_axi_arlock;
    logic [3:0] m_axi_arcache;
    logic [2:0] m_axi_arprot;
    logic [3:0] m_axi_arqos;
    logic m_axi_arvalid;
    logic m_axi_arready;

    // AXI R
    logic [AXI_ID_WIDTH-1:0] m_axi_rid;
    logic [127:0] m_axi_rdata;
    logic [1:0] m_axi_rresp;
    logic m_axi_rlast;
    logic m_axi_rvalid;
    logic m_axi_rready;

    // ------------------------------------------------------------
    // Simple counters
    // ------------------------------------------------------------
    integer cycle_count;
    integer ar_count;
    integer r_beat_count;
    integer logical_read_count;
    integer narrow_read_count;

    // ------------------------------------------------------------
    // DUT
    // ------------------------------------------------------------
    vit_m8_memory_subsystem_baseline #(
        .ARRAY_ROWS   (ARRAY_ROWS),
        .ARRAY_COLS   (ARRAY_COLS),
        .PE_LANES     (PE_LANES),
        .VECTOR_LANES (VECTOR_LANES)
    ) dut (
        .*
    );

    // ------------------------------------------------------------
    // AXI DDR MODEL
    // ------------------------------------------------------------
    axi_ddr_model #(
        .AXI_ADDR_WIDTH       (AXI_ADDR_WIDTH),
        .AXI_ID_WIDTH         (AXI_ID_WIDTH),
        .MEM_BYTES            (1048576),
        .READ_LATENCY         (12),
        .WRITE_RESP_LATENCY   (4),
        .READ_QUEUE_DEPTH     (4)
    ) u_ddr (
        .aclk          (aclk),
        .aresetn       (aresetn),

        .s_axi_awid    (m_axi_awid),
        .s_axi_awaddr  (m_axi_awaddr),
        .s_axi_awlen   (m_axi_awlen),
        .s_axi_awsize  (m_axi_awsize),
        .s_axi_awburst (m_axi_awburst),
        .s_axi_awlock  (m_axi_awlock),
        .s_axi_awcache (m_axi_awcache),
        .s_axi_awprot  (m_axi_awprot),
        .s_axi_awqos   (m_axi_awqos),
        .s_axi_awvalid (m_axi_awvalid),
        .s_axi_awready (m_axi_awready),

        .s_axi_wdata   (m_axi_wdata),
        .s_axi_wstrb   (m_axi_wstrb),
        .s_axi_wlast   (m_axi_wlast),
        .s_axi_wvalid  (m_axi_wvalid),
        .s_axi_wready  (m_axi_wready),

        .s_axi_bid     (m_axi_bid),
        .s_axi_bresp   (m_axi_bresp),
        .s_axi_bvalid  (m_axi_bvalid),
        .s_axi_bready  (m_axi_bready),

        .s_axi_arid    (m_axi_arid),
        .s_axi_araddr  (m_axi_araddr),
        .s_axi_arlen   (m_axi_arlen),
        .s_axi_arsize  (m_axi_arsize),
        .s_axi_arburst (m_axi_arburst),
        .s_axi_arlock  (m_axi_arlock),
        .s_axi_arcache (m_axi_arcache),
        .s_axi_arprot  (m_axi_arprot),
        .s_axi_arqos   (m_axi_arqos),
        .s_axi_arvalid (m_axi_arvalid),
        .s_axi_arready (m_axi_arready),

        .s_axi_rid     (m_axi_rid),
        .s_axi_rdata   (m_axi_rdata),
        .s_axi_rresp   (m_axi_rresp),
        .s_axi_rlast   (m_axi_rlast),
        .s_axi_rvalid  (m_axi_rvalid),
        .s_axi_rready  (m_axi_rready)
    );

    // ------------------------------------------------------------
    // Clock
    // 50 MHz production clock => 20 ns period
    // ------------------------------------------------------------
    initial begin
        aclk = 1'b0;
        forever #10 aclk = ~aclk;
    end

    // ------------------------------------------------------------
    // Counters
    // ------------------------------------------------------------
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            cycle_count        <= 0;
            ar_count           <= 0;
            r_beat_count       <= 0;
            logical_read_count <= 0;
            narrow_read_count  <= 0;
        end else begin
            cycle_count <= cycle_count + 1;

            if (m_axi_arvalid && m_axi_arready)
                ar_count <= ar_count + 1;

            if (m_axi_rvalid && m_axi_rready)
                r_beat_count <= r_beat_count + 1;

            if (profile_logical_read_word_o)
                logical_read_count <= logical_read_count + 1;

            if (narrow_r_beat_o)
                narrow_read_count <= narrow_read_count + 1;
        end
    end


    // ============================================================
    // WRITE TEST COUNTERS
    // ============================================================

    integer aw_count;
    integer w_count;
    integer b_count;
    integer logical_write_count;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            aw_count            <= 0;
            w_count             <= 0;
            b_count             <= 0;
            logical_write_count <= 0;
        end else begin
            if (m_axi_awvalid && m_axi_awready)
                aw_count <= aw_count + 1;

            if (m_axi_wvalid && m_axi_wready)
                w_count <= w_count + 1;

            if (m_axi_bvalid && m_axi_bready)
                b_count <= b_count + 1;

            if (profile_logical_write_word_o)
                logical_write_count <= logical_write_count + 1;
        end
    end

    // ============================================================
    // MAIN TEST — LAYOUT SINGLE-WORD WRITE
    // ============================================================

    localparam logic [31:0] WRITE_WORD_ADDR = 32'd6;
    localparam logic [31:0] WRITE_VALUE     = 32'hDEAD_BEEF;

    initial begin
        // --------------------------------------------------------
        // Known defaults
        // --------------------------------------------------------
        aresetn = 1'b0;

        scratch_base_i = SCRATCH_BASE;
        model_base_i   = MODEL_BASE;
        input_base_i   = INPUT_BASE;

        scratch_words_i = 32'h0001_8000;
        model_words_i   = 32'h0000_8000;
        input_words_i   = 32'h0000_8000;

        cache_invalidate_i = 1'b0;

        command_accept = 1'b0;
        execute = 1'b0;

        active_cmd = '0;

        selected_data_request = 1'b0;
        selected_result_valid = 1'b0;

        read_word_count  = 16'd1;
        write_word_count = 16'd1;

        // GEMM defaults
        gemm_token_base = '0;
        gemm_output_base = '0;
        gemm_k_base = '0;
        gemm_batch_index = '0;

        gemm_result_address_base_store_i = '0;
        gemm_result_generation_store_i = '0;
        gemm_result_generation_expected_i = '0;
        gemm_result_token_base_store_i = '0;
        gemm_result_output_base_store_i = '0;
        gemm_result_batch_index_store_i = '0;
        gemm_result_token_mask = '0;
        gemm_result_output_mask = '0;
        gemm_result_data = '0;

        // Vector defaults
        vector_element_base = '0;
        vector_result_base = '0;
        vector_result_lane_mask = '0;
        vector_result_data = '0;

        // --------------------------------------------------------
        // Layout WRITE stimulus
        // --------------------------------------------------------
        layout_source_address = '0;

        layout_result_address = WRITE_WORD_ADDR;
        layout_result_data    = WRITE_VALUE;

        // LayerNorm defaults
        ln_data_pass = '0;
        ln_data_index = '0;
        ln_data_channel_index = '0;
        ln_result_index = '0;
        ln_result_data = '0;

        // Softmax defaults
        softmax_data_index = '0;
        softmax_result_index = '0;
        softmax_result_data = '0;

        // GELU defaults
        gelu_data_base_index = '0;
        gelu_data_lane_mask = '0;
        gelu_result_base_index = '0;
        gelu_result_lane_mask = '0;
        gelu_result_data = '0;

        argmax_element_index = '0;

        // --------------------------------------------------------
        // Minimal Layout command
        // --------------------------------------------------------
        active_cmd.header.opcode = PHASE_E_OP_LAYOUT;
        active_cmd.header.subop  = PHASE_E_SUBOP_LAYOUT_COPY;

        active_cmd.route.dst_space = PHASE_E_MEM_SCRATCH;

        repeat (8) @(posedge aclk);

        // Initialize destination to zero before testing.
        u_ddr.poke_u32(
            SCRATCH_BASE + (WRITE_WORD_ADDR << 2),
            32'h0000_0000
        );

        $display("");
        $display("==============================================");
        $display("M8 MEMORY SUBSYSTEM BASELINE TEST");
        $display("TEST: LAYOUT SINGLE-WORD WRITE");
        $display("logical addr  = %0d", WRITE_WORD_ADDR);
        $display("physical addr = 0x%0h",
                 SCRATCH_BASE + (WRITE_WORD_ADDR << 2));
        $display("write value   = 0x%08h", WRITE_VALUE);
        $display("==============================================");

        // Release reset
        @(negedge aclk);
        aresetn = 1'b1;

        repeat (3) @(posedge aclk);

        // Command accept
        @(negedge aclk);
        command_accept = 1'b1;

        @(negedge aclk);
        command_accept = 1'b0;

        // Controller in EXECUTE.
        execute = 1'b1;

        // Emulate Layout engine holding result_valid until ready.
        selected_result_valid = 1'b1;

        fork
            begin : WAIT_FOR_WRITE
                wait (layout_result_ready === 1'b1);

                $display("layout_result_ready asserted");

                // Drop engine request before frontend can restart.
                @(negedge aclk);
                selected_result_valid = 1'b0;
                execute = 1'b0;

                repeat (5) @(posedge aclk);

                // ------------------------------------------------
                // Check committed DDR contents
                // ------------------------------------------------
                if (
                    u_ddr.peek_u32(
                        SCRATCH_BASE + (WRITE_WORD_ADDR << 2)
                    ) !== WRITE_VALUE
                ) begin
                    $display("FAIL: DDR DATA MISMATCH");
                    $display(
                        "expected = 0x%08h",
                        WRITE_VALUE
                    );
                    $display(
                        "actual   = 0x%08h",
                        u_ddr.peek_u32(
                            SCRATCH_BASE +
                            (WRITE_WORD_ADDR << 2)
                        )
                    );
                    $fatal(1);
                end

                $display(
                    "PASS: DDR data = 0x%08h",
                    u_ddr.peek_u32(
                        SCRATCH_BASE +
                        (WRITE_WORD_ADDR << 2)
                    )
                );

                if (memory_error_latched) begin
                    $display(
                        "FAIL: memory_error_latched = 1"
                    );
                    $fatal(1);
                end

                if (axi_b_protocol_error_o) begin
                    $display(
                        "FAIL: AXI B protocol error"
                    );
                    $fatal(1);
                end

                $display("");
                $display(
                    "------------ WRITE COUNTERS -------------"
                );
                $display(
                    "logical writes = %0d",
                    logical_write_count
                );
                $display(
                    "AW handshakes  = %0d",
                    aw_count
                );
                $display(
                    "W handshakes   = %0d",
                    w_count
                );
                $display(
                    "B handshakes   = %0d",
                    b_count
                );
                $display(
                    "-----------------------------------------"
                );

                if (logical_write_count != 1) begin
                    $display(
                        "FAIL: expected 1 logical write"
                    );
                    $fatal(1);
                end

                if (aw_count != 1) begin
                    $display(
                        "FAIL: expected 1 AW handshake"
                    );
                    $fatal(1);
                end

                if (w_count != 1) begin
                    $display(
                        "FAIL: expected 1 W handshake"
                    );
                    $fatal(1);
                end

                if (b_count != 1) begin
                    $display(
                        "FAIL: expected 1 B handshake"
                    );
                    $fatal(1);
                end

                $display("");
                $display("==============================================");
                $display("BASELINE WRITE TEST PASS");
                $display("==============================================");

                $finish;
            end

            begin : TIMEOUT
                repeat (300) @(posedge aclk);

                $display("");
                $display("FAIL: WRITE TIMEOUT");
                $display(
                    "debug_mem_state = %0d",
                    debug_mem_state
                );
                $display(
                    "AW count = %0d",
                    aw_count
                );
                $display(
                    "W count  = %0d",
                    w_count
                );
                $display(
                    "B count  = %0d",
                    b_count
                );

                $fatal(1);
            end
        join_any

        disable fork;
    end

endmodule

