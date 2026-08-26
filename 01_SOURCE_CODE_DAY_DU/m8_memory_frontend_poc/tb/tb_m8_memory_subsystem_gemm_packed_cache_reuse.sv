
`timescale 1ns/1ps

module tb_m8_memory_subsystem_gemm_packed_cache_reuse;

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
    // TEST 5A — GEMM PACKED COLD PANEL
    // R8 / C2 / K16
    //
    // A        = 128 x u32
    // Packed B =  16 x u32
    // Bias     =   2 x u32
    // Total    = 146 logical words
    // ============================================================

    localparam logic [31:0] A_BASE    = 32'd256;
    localparam logic [31:0] B_BASE    = 32'd128;
    localparam logic [31:0] BIAS_BASE = 32'd512;

    integer linefill_start_count;
    integer linefill_hit_count;
    integer full_r_beat_count;

    integer a_cache_lookup_count;
    integer a_cache_hit_count;
    integer a_cache_miss_count;

    integer bias_cache_lookup_count;
    integer bias_cache_hit_count;
    integer bias_cache_miss_count;

    integer max_read_outstanding_seen;

    integer request_cycle;
    integer data_cycle;
    integer request_to_data_cycles;

    integer i;

    // ------------------------------------------------------------
    // Additional profiling
    // ------------------------------------------------------------
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            linefill_start_count       <= 0;
            linefill_hit_count         <= 0;
            full_r_beat_count          <= 0;

            a_cache_lookup_count       <= 0;
            a_cache_hit_count          <= 0;
            a_cache_miss_count         <= 0;

            bias_cache_lookup_count    <= 0;
            bias_cache_hit_count       <= 0;
            bias_cache_miss_count      <= 0;

            max_read_outstanding_seen  <= 0;

            request_cycle              <= -1;
            data_cycle                 <= -1;
            request_to_data_cycles     <= -1;
        end else begin

            if (linefill_start_o)
                linefill_start_count <=
                    linefill_start_count + 1;

            if (linefill_hit_o)
                linefill_hit_count <=
                    linefill_hit_count + 1;

            if (full_r_beat_o)
                full_r_beat_count <=
                    full_r_beat_count + 1;

            if (profile_a_cache_lookup_o)
                a_cache_lookup_count <=
                    a_cache_lookup_count + 1;

            if (profile_a_cache_hit_o)
                a_cache_hit_count <=
                    a_cache_hit_count + 1;

            if (profile_a_cache_miss_o)
                a_cache_miss_count <=
                    a_cache_miss_count + 1;

            if (profile_bias_cache_lookup_o)
                bias_cache_lookup_count <=
                    bias_cache_lookup_count + 1;

            if (profile_bias_cache_hit_o)
                bias_cache_hit_count <=
                    bias_cache_hit_count + 1;

            if (profile_bias_cache_miss_o)
                bias_cache_miss_count <=
                    bias_cache_miss_count + 1;

            if (read_outstanding_o >
                max_read_outstanding_seen)
                max_read_outstanding_seen <=
                    read_outstanding_o;

            if (
                execute &&
                selected_data_request &&
                (request_cycle < 0)
            )
                request_cycle <= cycle_count;

            if (
                gemm_data_valid &&
                (data_cycle < 0)
            ) begin
                data_cycle <= cycle_count;

                if (request_cycle >= 0)
                    request_to_data_cycles <=
                        cycle_count - request_cycle;
            end
        end
    end



    // ============================================================
    // TEST 5B-1 — PACKED GEMM A-CACHE VECTOR REUSE
    //
    // Panel #1:
    //   cold fill A-cache
    //
    // Panel #2:
    //   same batch/token/K tile
    //   A must come from vector-cache replay path
    //
    // IMPORTANT:
    //   command_accept occurs ONCE only.
    // ============================================================

    integer a_vector_hit_words_total;

    integer first_logical_snapshot;
    integer first_ar_snapshot;
    integer first_r_snapshot;
    integer first_linefill_snapshot;
    integer first_linehit_snapshot;
    integer first_narrow_snapshot;
    integer first_full_r_snapshot;
    integer first_avector_snapshot;

    integer first_delivery_cycle;
    integer second_delivery_cycles;

    integer panel_count;

    // ------------------------------------------------------------
    // Count exact A words serviced by vector-cache path.
    //
    // With R8/K16:
    // 16 vector accesses × 8 valid rows = 128 words.
    // ------------------------------------------------------------
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            a_vector_hit_words_total <= 0;
        end else begin
            a_vector_hit_words_total <=
                a_vector_hit_words_total +
                profile_a_vector_hit_word_delta_o;
        end
    end


    // ============================================================
    // MAIN TEST
    // ============================================================
    initial begin

        // --------------------------------------------------------
        // Defaults
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

        // Same packed geometry as Test 5A.
        read_word_count  = 16'd146;
        write_word_count = 16'd16;

        // --------------------------------------------------------
        // GEMM coordinates
        //
        // DO NOT CHANGE these between panel 1 and panel 2.
        // Vector path checks coordinate stability.
        // --------------------------------------------------------
        gemm_token_base  = 32'd0;
        gemm_output_base = 32'd0;
        gemm_k_base      = 32'd0;
        gemm_batch_index = 32'd0;

        // No result path in this isolated cache test.
        gemm_result_address_base_store_i = '0;
        gemm_result_generation_store_i = '0;
        gemm_result_generation_expected_i = '0;
        gemm_result_token_base_store_i = '0;
        gemm_result_output_base_store_i = '0;
        gemm_result_batch_index_store_i = '0;
        gemm_result_token_mask = '0;
        gemm_result_output_mask = '0;
        gemm_result_data = '0;

        // Other engines unused.
        vector_element_base = '0;
        vector_result_base = '0;
        vector_result_lane_mask = '0;
        vector_result_data = '0;

        layout_source_address = '0;
        layout_result_address = '0;
        layout_result_data = '0;

        ln_data_pass = '0;
        ln_data_index = '0;
        ln_data_channel_index = '0;
        ln_result_index = '0;
        ln_result_data = '0;

        softmax_data_index = '0;
        softmax_result_index = '0;
        softmax_result_data = '0;

        gelu_data_base_index = '0;
        gelu_data_lane_mask = '0;
        gelu_result_base_index = '0;
        gelu_result_lane_mask = '0;
        gelu_result_data = '0;

        argmax_element_index = '0;


        // ========================================================
        // GEMM DESCRIPTOR
        // ========================================================

        active_cmd.header.opcode =
            PHASE_E_OP_GEMM;

        active_cmd.header.flags =
            PHASE_E_FLAG_BIAS_ENABLE |
            PHASE_E_FLAG_GEMM_CACHE_SAFE |
            PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2 |
            PHASE_E_FLAG_GEMM_FP16 |
            PHASE_E_FLAG_GEMM_B_FP16_PACKED2;

        active_cmd.route.src0_space =
            PHASE_E_MEM_SCRATCH;

        active_cmd.route.src1_space =
            PHASE_E_MEM_PARAM;

        active_cmd.route.src2_space =
            PHASE_E_MEM_PARAM;

        active_cmd.route.dst_space =
            PHASE_E_MEM_NONE;

        active_cmd.src0_base = A_BASE;
        active_cmd.src1_base = B_BASE;
        active_cmd.src2_base = BIAS_BASE;
        active_cmd.dst_base  = 32'd0;

        active_cmd.dim0 = 32'd1;
        active_cmd.dim1 = 32'd8;
        active_cmd.dim2 = 32'd16;
        active_cmd.dim3 = 32'd2;

        // A[row][k] = base + row*16 + k
        active_cmd.stride0 = 32'd0;
        active_cmd.stride1 = 32'd16;

        active_cmd.stride2 = 32'd0;
        active_cmd.stride3 = 32'd0;
        active_cmd.stride4 = 32'd0;

        active_cmd.immediate = 32'd0;


        // ========================================================
        // Initial bookkeeping
        // ========================================================
        panel_count = 0;

        first_logical_snapshot  = 0;
        first_ar_snapshot       = 0;
        first_r_snapshot        = 0;
        first_linefill_snapshot = 0;
        first_linehit_snapshot  = 0;
        first_narrow_snapshot   = 0;
        first_full_r_snapshot   = 0;
        first_avector_snapshot  = 0;

        first_delivery_cycle  = -1;
        second_delivery_cycles = -1;


        // ========================================================
        // Hold reset
        // ========================================================
        repeat (8) @(posedge aclk);


        // ========================================================
        // Seed A — same data as Test 5A
        // ========================================================
        for (i = 0; i < 128; i = i + 1) begin
            u_ddr.poke_u32(
                SCRATCH_BASE +
                ((A_BASE + i) << 2),
                32'h3F00_0000 + i
            );
        end


        // ========================================================
        // Seed packed B
        // ========================================================
        for (i = 0; i < 16; i = i + 1) begin
            u_ddr.poke_u32(
                MODEL_BASE +
                ((B_BASE + i) << 2),
                32'hB100_A100 +
                (i << 16) +
                i
            );
        end


        // ========================================================
        // Seed bias
        // ========================================================
        u_ddr.poke_u32(
            MODEL_BASE +
            (BIAS_BASE << 2),
            32'h3F80_0000
        );

        u_ddr.poke_u32(
            MODEL_BASE +
            ((BIAS_BASE + 1) << 2),
            32'h4000_0000
        );


        $display("");
        $display("================================================");
        $display("TEST 5B-1: GEMM PACKED A-CACHE VECTOR REUSE");
        $display("Panel 1 = cold fill");
        $display("Panel 2 = same A tile, vector-cache replay");
        $display("command_accept = ONE pulse only");
        $display("================================================");


        // ========================================================
        // Release reset
        // ========================================================
        @(negedge aclk);
        aresetn = 1'b1;

        repeat (3) @(posedge aclk);


        // ========================================================
        // COMMAND ACCEPT — ONCE ONLY
        // ========================================================
        @(negedge aclk);
        command_accept = 1'b1;

        @(negedge aclk);
        command_accept = 1'b0;


        // Execute same command continuously.
        execute = 1'b1;

        // Keep request asserted across BOTH panels.
        selected_data_request = 1'b1;


        fork

            // ====================================================
            // PANEL MONITOR
            // ====================================================
            begin : TWO_PANEL_SEQUENCE

                // ------------------------------------------------
                // PANEL #1 — cold
                // ------------------------------------------------
                wait (gemm_data_valid === 1'b1);

                panel_count = 1;

                $display("");
                $display("PANEL #1 gemm_data_valid");


                // Verify cold panel A.
                for (i = 0; i < 128; i = i + 1) begin
                    if (
                        gemm_activation_data[
                            i*32 +: 32
                        ] !==
                        (32'h3F00_0000 + i)
                    ) begin
                        $display(
                            "FAIL P1 A[%0d] exp=%08h got=%08h",
                            i,
                            32'h3F00_0000 + i,
                            gemm_activation_data[i*32 +: 32]
                        );
                        $fatal(1);
                    end
                end

                $display("PASS P1: A correct");


                // Packed B
                for (i = 0; i < 16; i = i + 1) begin
                    if (
                        gemm_weight_data[
                            i*32 +: 32
                        ] !==
                        (
                            32'hB100_A100 +
                            (i << 16) +
                            i
                        )
                    ) begin
                        $display(
                            "FAIL P1 B[%0d] got=%08h",
                            i,
                            gemm_weight_data[i*32 +: 32]
                        );
                        $fatal(1);
                    end
                end

                $display("PASS P1: packed B correct");


                if (
                    (gemm_bias_data[31:0] !== 32'h3F80_0000) ||
                    (gemm_bias_data[63:32] !== 32'h4000_0000)
                ) begin
                    $display("FAIL P1 bias");
                    $fatal(1);
                end

                $display("PASS P1: bias correct");


                // ------------------------------------------------
                // Snapshot cumulative counters immediately after
                // first completed panel.
                // ------------------------------------------------
                first_logical_snapshot  = logical_read_count;
                first_ar_snapshot       = ar_count;
                first_r_snapshot        = r_beat_count;
                first_linefill_snapshot = linefill_start_count;
                first_linehit_snapshot  = linefill_hit_count;
                first_narrow_snapshot   = narrow_read_count;
                first_full_r_snapshot   = full_r_beat_count;
                first_avector_snapshot  = a_vector_hit_words_total;

                first_delivery_cycle = cycle_count;


                $display("");
                $display("---------- PANEL #1 SNAPSHOT ----------");
                $display(
                    "logical reads   = %0d",
                    first_logical_snapshot
                );
                $display(
                    "AR              = %0d",
                    first_ar_snapshot
                );
                $display(
                    "R beats         = %0d",
                    first_r_snapshot
                );
                $display(
                    "A vector words  = %0d",
                    first_avector_snapshot
                );
                $display("---------------------------------------");


                // Wait until first data-valid pulse has gone away.
                wait (gemm_data_valid === 1'b0);


                // ------------------------------------------------
                // PANEL #2 — cache reuse
                // ------------------------------------------------
                wait (gemm_data_valid === 1'b1);

                panel_count = 2;

                second_delivery_cycles =
                    cycle_count - first_delivery_cycle;

                $display("");
                $display("PANEL #2 gemm_data_valid");


                // ================================================
                // Verify A again.
                //
                // Same numerical data, but source must now have
                // been local A-cache vector replay.
                // ================================================
                for (i = 0; i < 128; i = i + 1) begin
                    if (
                        gemm_activation_data[
                            i*32 +: 32
                        ] !==
                        (32'h3F00_0000 + i)
                    ) begin
                        $display(
                            "FAIL P2 A[%0d] exp=%08h got=%08h",
                            i,
                            32'h3F00_0000 + i,
                            gemm_activation_data[i*32 +: 32]
                        );
                        $fatal(1);
                    end
                end

                $display("PASS P2: A correct");


                // Verify B again.
                for (i = 0; i < 16; i = i + 1) begin
                    if (
                        gemm_weight_data[
                            i*32 +: 32
                        ] !==
                        (
                            32'hB100_A100 +
                            (i << 16) +
                            i
                        )
                    ) begin
                        $display(
                            "FAIL P2 B[%0d] got=%08h",
                            i,
                            gemm_weight_data[i*32 +: 32]
                        );
                        $fatal(1);
                    end
                end

                $display("PASS P2: packed B correct");


                if (
                    (gemm_bias_data[31:0] !== 32'h3F80_0000) ||
                    (gemm_bias_data[63:32] !== 32'h4000_0000)
                ) begin
                    $display("FAIL P2 bias");
                    $fatal(1);
                end

                $display("PASS P2: bias correct");


                // Stop before a third panel starts.
                @(negedge aclk);
                selected_data_request = 1'b0;
                execute = 1'b0;

                repeat (5) @(posedge aclk);


                // ================================================
                // Errors
                // ================================================
                if (memory_error_latched) begin
                    $display(
                        "FAIL: memory_error_latched"
                    );
                    $fatal(1);
                end

                if (axi_r_protocol_error_o) begin
                    $display(
                        "FAIL: AXI R protocol error"
                    );
                    $fatal(1);
                end

                if (profile_a_vector_protocol_error_o) begin
                    $display(
                        "FAIL: A-vector protocol error"
                    );
                    $fatal(1);
                end


                // ================================================
                // Panel #2 deltas
                // ================================================
                $display("");
                $display(
                    "========== PANEL #2 REUSE DELTAS =========="
                );

                $display(
                    "logical read delta     = %0d",
                    logical_read_count -
                    first_logical_snapshot
                );

                $display(
                    "AR delta               = %0d",
                    ar_count -
                    first_ar_snapshot
                );

                $display(
                    "R beat delta           = %0d",
                    r_beat_count -
                    first_r_snapshot
                );

                $display(
                    "linefill start delta   = %0d",
                    linefill_start_count -
                    first_linefill_snapshot
                );

                $display(
                    "linefill hit delta     = %0d",
                    linefill_hit_count -
                    first_linehit_snapshot
                );

                $display(
                    "narrow R delta         = %0d",
                    narrow_read_count -
                    first_narrow_snapshot
                );

                $display(
                    "full R delta           = %0d",
                    full_r_beat_count -
                    first_full_r_snapshot
                );

                $display(
                    "A vector hit words     = %0d",
                    a_vector_hit_words_total -
                    first_avector_snapshot
                );

                $display(
                    "P1 -> P2 cycles        = %0d",
                    second_delivery_cycles
                );

                $display(
                    "============================================"
                );


                // ================================================
                // HARD EXPECTATION #1
                //
                // Exact vector replay:
                // 16 K lanes × 8 rows = 128 A words.
                // ================================================
                if (
                    (a_vector_hit_words_total -
                     first_avector_snapshot) != 128
                ) begin

                    $display(
                        "FAIL: expected 128 A vector-cache words"
                    );

                    $fatal(1);
                end


                // ================================================
                // HARD EXPECTATION #2
                //
                // Scalar logical-read pulse no longer visits
                // A[0..127].
                //
                // It resumes at:
                //   16 packed B + 2 bias = 18 candidates.
                // ================================================
                if (
                    (logical_read_count -
                     first_logical_snapshot) != 18
                ) begin

                    $display(
                        "FAIL: expected only 18 scalar logical reads on reuse"
                    );

                    $fatal(1);
                end


                // Cache replay should not produce A scalar misses
                // during panel #2.
                if (a_cache_miss_count != 128) begin

                    $display(
                        "FAIL: unexpected additional A cache miss"
                    );

                    $display(
                        "A miss cumulative = %0d",
                        a_cache_miss_count
                    );

                    $fatal(1);
                end


                $display("");
                $display("================================================");
                $display("GEMM PACKED A-CACHE REUSE TEST PASS");
                $display("================================================");

                $finish;
            end


            // ====================================================
            // TIMEOUT
            // ====================================================
            begin : TIMEOUT

                repeat (8000) @(posedge aclk);

                $display("");
                $display("FAIL: PACKED CACHE REUSE TIMEOUT");

                $display(
                    "panel_count = %0d",
                    panel_count
                );

                $display(
                    "debug_mem_state = %0d",
                    debug_mem_state
                );

                $display(
                    "logical reads = %0d",
                    logical_read_count
                );

                $display(
                    "A vector words = %0d",
                    a_vector_hit_words_total
                );

                $fatal(1);
            end

        join_any

        disable fork;
    end

endmodule

