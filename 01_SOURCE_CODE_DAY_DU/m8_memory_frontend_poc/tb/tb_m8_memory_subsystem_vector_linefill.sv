
`timescale 1ns/1ps

module tb_m8_memory_subsystem_vector_linefill;

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
    // VECTOR LINE-FILL TEST
    // ============================================================

    localparam logic [31:0] VECTOR_SRC_BASE = 32'd16;
    localparam logic [31:0] VECTOR_LENGTH   = 32'd16;

    integer linefill_start_count;
    integer linefill_hit_count;
    integer full_r_beat_count;
    integer max_read_outstanding_seen;
    integer i;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            linefill_start_count       <= 0;
            linefill_hit_count         <= 0;
            full_r_beat_count          <= 0;
            max_read_outstanding_seen  <= 0;
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

            if (read_outstanding_o >
                max_read_outstanding_seen)
                max_read_outstanding_seen <=
                    read_outstanding_o;
        end
    end

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

        // Production Vector dispatch uses:
        // 16 src0 slots + 16 optional src1 slots.
        read_word_count  = 16'd32;
        write_word_count = 16'd16;

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

        // --------------------------------------------------------
        // Vector configuration
        // --------------------------------------------------------
        vector_element_base = 32'd0;
        vector_result_base = '0;
        vector_result_lane_mask = '0;
        vector_result_data = '0;

        // Layout
        layout_source_address = '0;
        layout_result_address = '0;
        layout_result_data = '0;

        // LayerNorm
        ln_data_pass = '0;
        ln_data_index = '0;
        ln_data_channel_index = '0;
        ln_result_index = '0;
        ln_result_data = '0;

        // Softmax
        softmax_data_index = '0;
        softmax_result_index = '0;
        softmax_result_data = '0;

        // GELU
        gelu_data_base_index = '0;
        gelu_data_lane_mask = '0;
        gelu_result_base_index = '0;
        gelu_result_lane_mask = '0;
        gelu_result_data = '0;

        argmax_element_index = '0;

        // --------------------------------------------------------
        // Vector descriptor
        //
        // SCALE_MASK with mask flag disabled:
        // only src0 is required.
        // --------------------------------------------------------
        active_cmd.header.opcode =
            PHASE_E_OP_VECTOR;

        active_cmd.header.subop =
            PHASE_E_SUBOP_VECTOR_SCALE_MASK;

        active_cmd.header.flags = '0;

        active_cmd.route.src0_space =
            PHASE_E_MEM_SCRATCH;

        active_cmd.route.src1_space =
            PHASE_E_MEM_NONE;

        active_cmd.src0_base =
            VECTOR_SRC_BASE;

        active_cmd.dim0 =
            VECTOR_LENGTH;

        // --------------------------------------------------------
        // Reset period
        // --------------------------------------------------------
        repeat (8) @(posedge aclk);

        // Seed 16 contiguous logical words.
        //
        // SCRATCH physical range:
        // 0x40040 ... 0x4007C
        //
        for (i = 0; i < 16; i = i + 1) begin
            u_ddr.poke_u32(
                SCRATCH_BASE +
                ((VECTOR_SRC_BASE + i) << 2),
                32'hA500_0000 + i
            );
        end

        $display("");
        $display("==============================================");
        $display("TEST: VECTOR 16-WORD LINEFILL READ");
        $display("first logical = %0d", VECTOR_SRC_BASE);
        $display("first physical = 0x%0h",
            SCRATCH_BASE + (VECTOR_SRC_BASE << 2));
        $display("==============================================");

        // Release reset
        @(negedge aclk);
        aresetn = 1'b1;

        repeat (3) @(posedge aclk);

        // Command accept pulse
        @(negedge aclk);
        command_accept = 1'b1;

        @(negedge aclk);
        command_accept = 1'b0;

        execute = 1'b1;
        selected_data_request = 1'b1;

        fork
            begin : WAIT_VECTOR
                wait (vector_data_valid === 1'b1);

                // ----------------------------------------------
                // Verify all sixteen words.
                // ----------------------------------------------
                for (i = 0; i < 16; i = i + 1) begin
                    if (
                        vector_input_a[i*32 +: 32] !==
                        (32'hA500_0000 + i)
                    ) begin
                        $display(
                            "FAIL lane %0d expected=%08h actual=%08h",
                            i,
                            (32'hA500_0000 + i),
                            vector_input_a[i*32 +: 32]
                        );
                        $fatal(1);
                    end
                end

                $display(
                    "PASS: all 16 vector words match"
                );

                @(negedge aclk);
                selected_data_request = 1'b0;
                execute = 1'b0;

                repeat (5) @(posedge aclk);

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

                $display("");
                $display(
                    "------------ LINEFILL COUNTERS ------------"
                );
                $display(
                    "logical reads        = %0d",
                    logical_read_count
                );
                $display(
                    "AR handshakes        = %0d",
                    ar_count
                );
                $display(
                    "R beat handshakes    = %0d",
                    r_beat_count
                );
                $display(
                    "linefill starts      = %0d",
                    linefill_start_count
                );
                $display(
                    "linefill hits        = %0d",
                    linefill_hit_count
                );
                $display(
                    "full R beats         = %0d",
                    full_r_beat_count
                );
                $display(
                    "narrow R beats       = %0d",
                    narrow_read_count
                );
                $display(
                    "max outstanding seen = %0d",
                    max_read_outstanding_seen
                );
                $display(
                    "-------------------------------------------"
                );

                // Exact expectations for this aligned 16-word run.
                if (logical_read_count != 16) begin
                    $display(
                        "FAIL: logical reads != 16"
                    );
                    $fatal(1);
                end

                if (ar_count != 1) begin
                    $display(
                        "FAIL: expected one burst AR"
                    );
                    $fatal(1);
                end

                if (r_beat_count != 4) begin
                    $display(
                        "FAIL: expected four R beats"
                    );
                    $fatal(1);
                end

                if (linefill_start_count != 1) begin
                    $display(
                        "FAIL: expected one linefill"
                    );
                    $fatal(1);
                end

                if (narrow_read_count != 0) begin
                    $display(
                        "FAIL: unexpected narrow read"
                    );
                    $fatal(1);
                end

                $display("");
                $display("==============================================");
                $display("VECTOR LINEFILL TEST PASS");
                $display("==============================================");

                $finish;
            end

            begin : TIMEOUT
                repeat (600) @(posedge aclk);

                $display("");
                $display("FAIL: VECTOR LINEFILL TIMEOUT");
                $display(
                    "debug_mem_state = %0d",
                    debug_mem_state
                );
                $display(
                    "AR count = %0d",
                    ar_count
                );
                $display(
                    "R beats = %0d",
                    r_beat_count
                );

                $fatal(1);
            end
        join_any

        disable fork;
    end

endmodule

