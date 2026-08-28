
`timescale 1ns/1ps

module vit_m8_memory_subsystem_optimized #(
    parameter integer ARRAY_ROWS   = 8,
    parameter integer ARRAY_COLS   = 2,
    parameter integer PE_LANES     = 16,
    parameter integer VECTOR_LANES = 16,

    parameter integer GEMM_A_CACHE_DEPTH_WORDS    = 3072,
    parameter integer GEMM_BIAS_CACHE_DEPTH_WORDS = 3072,

    parameter integer AXI_ADDR_WIDTH          = 40,
    parameter integer AXI_ID_WIDTH            = 1,
    parameter integer MAX_BURST_BEATS         = 4,
    parameter integer MAX_LINE_WORDS          = 32,
    parameter integer MAX_READ_OUTSTANDING    = 2
)(
    // ============================================================
    // CLOCK / RESET
    // ============================================================
    input  logic aclk,
    input  logic aresetn,

    // ============================================================
    // MEMORY MAP CONFIGURATION
    // ============================================================
    input  logic [63:0] scratch_base_i,
    input  logic [63:0] model_base_i,
    input  logic [63:0] input_base_i,

    input  logic [31:0] scratch_words_i,
    input  logic [31:0] model_words_i,
    input  logic [31:0] input_words_i,

    input  logic cache_invalidate_i,

    // ============================================================
    // COMMAND / ENGINE CONTROL
    // ============================================================
    input  logic                          command_accept,
    input  logic                          execute,
    input  vit_phase_e_pkg::phase_e_cmd_t active_cmd,

    input  logic        selected_data_request,
    input  logic        selected_result_valid,
    input  logic [15:0] read_word_count,
    input  logic [15:0] write_word_count,

    output logic        memory_error_latched,
    output logic [3:0]  debug_mem_state,

    // ============================================================
    // MEMORY FRONTEND PROFILE EVENTS
    // ============================================================
    output logic        profile_logical_read_word_o,
    output logic        profile_logical_write_word_o,
    output logic        profile_load_active_o,
    output logic        profile_store_active_o,

    output logic        profile_a_cache_lookup_o,
    output logic        profile_a_cache_hit_o,
    output logic        profile_a_cache_miss_o,

    output logic        profile_bias_cache_lookup_o,
    output logic        profile_bias_cache_hit_o,
    output logic        profile_bias_cache_miss_o,

    output logic        profile_b_bypass_o,
    output logic        profile_frontend_error_o,

    output logic [3:0]  profile_a_vector_hit_word_delta_o,
    output logic        profile_a_vector_protocol_error_o,
    output logic        profile_result_generation_error_o,

    // ============================================================
    // GEMM INTERFACE
    // ============================================================
    input  logic [31:0] gemm_token_base,
    input  logic [31:0] gemm_output_base,
    input  logic [31:0] gemm_k_base,
    input  logic [31:0] gemm_batch_index,

    output logic [ARRAY_ROWS*PE_LANES*32-1:0]
        gemm_activation_data,

    output logic [ARRAY_COLS*PE_LANES*32-1:0]
        gemm_weight_data,

    output logic [ARRAY_COLS*32-1:0]
        gemm_bias_data,

    output logic gemm_data_valid,

    output logic [65:0]
        gemm_result_address_base_current_o,

    input logic [65:0]
        gemm_result_address_base_store_i,

    input logic [7:0]
        gemm_result_generation_store_i,

    input logic [7:0]
        gemm_result_generation_expected_i,

    input logic [31:0]
        gemm_result_token_base_store_i,

    input logic [31:0]
        gemm_result_output_base_store_i,

    input logic [31:0]
        gemm_result_batch_index_store_i,

    input logic [ARRAY_ROWS-1:0]
        gemm_result_token_mask,

    input logic [ARRAY_COLS-1:0]
        gemm_result_output_mask,

    input logic [ARRAY_ROWS*ARRAY_COLS*32-1:0]
        gemm_result_data,

    output logic gemm_result_ready,

    // ============================================================
    // VECTOR INTERFACE
    // ============================================================
    input  logic [31:0] vector_element_base,

    output logic [VECTOR_LANES*32-1:0]
        vector_input_a,

    output logic [VECTOR_LANES*32-1:0]
        vector_input_b,

    output logic vector_data_valid,

    input  logic [31:0] vector_result_base,

    input  logic [VECTOR_LANES-1:0]
        vector_result_lane_mask,

    input  logic [VECTOR_LANES*32-1:0]
        vector_result_data,

    output logic vector_result_ready,

    // ============================================================
    // LAYOUT INTERFACE
    // ============================================================
    input  logic [31:0] layout_source_address,
    output logic [31:0] layout_source_data,
    output logic        layout_data_valid,

    input  logic [31:0] layout_result_address,
    input  logic [31:0] layout_result_data,
    output logic        layout_result_ready,

    // ============================================================
    // LAYERNORM INTERFACE
    // ============================================================
    input  logic [1:0]  ln_data_pass,
    input  logic [31:0] ln_data_index,
    input  logic [31:0] ln_data_channel_index,

    output logic [31:0] ln_input_data,
    output logic [31:0] ln_gamma_data,
    output logic [31:0] ln_beta_data,
    output logic        ln_input_valid,

    input  logic [31:0] ln_result_index,
    input  logic [31:0] ln_result_data,
    output logic        ln_result_ready,

    // ============================================================
    // SOFTMAX INTERFACE
    // ============================================================
    input  logic [31:0] softmax_data_index,
    output logic [31:0] softmax_input_data,
    output logic        softmax_input_valid,

    input  logic [31:0] softmax_result_index,
    input  logic [31:0] softmax_result_data,
    output logic        softmax_result_ready,

    // ============================================================
    // GELU INTERFACE
    // ============================================================
    input logic [31:0] gelu_data_base_index,

    input logic [VECTOR_LANES-1:0]
        gelu_data_lane_mask,

    output logic [VECTOR_LANES*32-1:0]
        gelu_input_data,

    output logic gelu_input_valid,

    input logic [31:0]
        gelu_result_base_index,

    input logic [VECTOR_LANES-1:0]
        gelu_result_lane_mask,

    input logic [VECTOR_LANES*32-1:0]
        gelu_result_data,

    output logic gelu_result_ready,

    // ============================================================
    // ARGMAX INTERFACE
    // ============================================================
    input  logic [31:0] argmax_element_index,
    output logic [31:0] argmax_input_data,
    output logic        argmax_data_valid,
    output logic        argmax_result_ready,

    // ============================================================
    // AXI ADAPTER PROFILE / OBSERVABILITY
    // ============================================================
    output logic       axi_r_protocol_error_o,
    output logic       axi_b_protocol_error_o,
    output logic       linefill_start_o,
    output logic       linefill_hit_o,
    output logic       full_r_beat_o,
    output logic       narrow_r_beat_o,
    output logic       four_k_split_o,

    output logic [5:0] prefetched_words_discarded_o,
    output logic [1:0] read_outstanding_o,

    // ============================================================
    // AXI4 MASTER WRITE ADDRESS
    // ============================================================
    output logic [AXI_ID_WIDTH-1:0]   m_axi_awid,
    output logic [AXI_ADDR_WIDTH-1:0] m_axi_awaddr,
    output logic [7:0]                m_axi_awlen,
    output logic [2:0]                m_axi_awsize,
    output logic [1:0]                m_axi_awburst,
    output logic                      m_axi_awlock,
    output logic [3:0]                m_axi_awcache,
    output logic [2:0]                m_axi_awprot,
    output logic [3:0]                m_axi_awqos,
    output logic                      m_axi_awvalid,
    input  logic                      m_axi_awready,

    // ============================================================
    // AXI4 MASTER WRITE DATA
    // ============================================================
    output logic [127:0] m_axi_wdata,
    output logic [15:0]  m_axi_wstrb,
    output logic         m_axi_wlast,
    output logic         m_axi_wvalid,
    input  logic         m_axi_wready,

    // ============================================================
    // AXI4 MASTER WRITE RESPONSE
    // ============================================================
    input  logic [AXI_ID_WIDTH-1:0] m_axi_bid,
    input  logic [1:0]              m_axi_bresp,
    input  logic                    m_axi_bvalid,
    output logic                    m_axi_bready,

    // ============================================================
    // AXI4 MASTER READ ADDRESS
    // ============================================================
    output logic [AXI_ID_WIDTH-1:0]   m_axi_arid,
    output logic [AXI_ADDR_WIDTH-1:0] m_axi_araddr,
    output logic [7:0]                m_axi_arlen,
    output logic [2:0]                m_axi_arsize,
    output logic [1:0]                m_axi_arburst,
    output logic                      m_axi_arlock,
    output logic [3:0]                m_axi_arcache,
    output logic [2:0]                m_axi_arprot,
    output logic [3:0]                m_axi_arqos,
    output logic                      m_axi_arvalid,
    input  logic                      m_axi_arready,

    // ============================================================
    // AXI4 MASTER READ DATA
    // ============================================================
    input  logic [AXI_ID_WIDTH-1:0] m_axi_rid,
    input  logic [127:0]            m_axi_rdata,
    input  logic [1:0]              m_axi_rresp,
    input  logic                    m_axi_rlast,
    input  logic                    m_axi_rvalid,
    output logic                    m_axi_rready
);

    // ============================================================
    // COMMON CLOCK / RESET
    // ============================================================

    logic clk;
    logic rst;

    assign clk = aclk;
    assign rst = ~aresetn;

    // ============================================================
    // INTERNAL LOGICAL MEMORY CHANNEL
    // Memory Frontend <-> AXI Memory Adapter
    // ============================================================

    logic                               mem_req_valid;
    logic                               mem_req_ready;
    logic                               mem_req_write;
    vit_phase_e_pkg::phase_e_mem_space_t mem_req_space;
    logic [31:0]                        mem_req_word_address;
    logic [31:0]                        mem_req_write_data;
    logic [3:0]                         mem_req_write_strobe;
    logic                               mem_req_read_ahead_safe;
    logic [5:0]                         mem_req_contiguous_words;

    logic        mem_rsp_valid;
    logic        mem_rsp_ready;
    logic [31:0] mem_rsp_read_data;
    logic        mem_rsp_error;

    // ============================================================
    // ORIGINAL MEMORY FRONTEND
    //
    // Wildcard is intentional here:
    // all engine/profile signals retain exactly the original names.
    // ============================================================

    vit_phase_e_memory_frontend_optimized #(
        .ARRAY_ROWS                  (ARRAY_ROWS),
        .ARRAY_COLS                  (ARRAY_COLS),
        .PE_LANES                    (PE_LANES),
        .VECTOR_LANES                (VECTOR_LANES),
        .GEMM_A_CACHE_DEPTH_WORDS    (GEMM_A_CACHE_DEPTH_WORDS),
        .GEMM_BIAS_CACHE_DEPTH_WORDS (GEMM_BIAS_CACHE_DEPTH_WORDS)
    ) u_memory_frontend (
        .*
    );

    // ============================================================
    // ORIGINAL AXI MEMORY ADAPTER
    // ============================================================

    vit_phase_e_axi_mem_adapter_optimized #(
        .AXI_ADDR_WIDTH       (AXI_ADDR_WIDTH),
        .AXI_ID_WIDTH         (AXI_ID_WIDTH),
        .MAX_BURST_BEATS      (MAX_BURST_BEATS),
        .MAX_LINE_WORDS       (MAX_LINE_WORDS),
        .MAX_READ_OUTSTANDING (MAX_READ_OUTSTANDING)
    ) u_mem_adapter (
        .aclk                       (aclk),
        .aresetn                    (aresetn),

        .req_valid                  (mem_req_valid),
        .req_ready                  (mem_req_ready),
        .req_write                  (mem_req_write),
        .req_space                  (mem_req_space),
        .req_word_address           (mem_req_word_address),
        .req_write_data             (mem_req_write_data),
        .req_write_strobe           (mem_req_write_strobe),
        .req_read_ahead_safe        (mem_req_read_ahead_safe),
        .req_contiguous_words       (mem_req_contiguous_words),

        .rsp_valid                  (mem_rsp_valid),
        .rsp_ready                  (mem_rsp_ready),
        .rsp_read_data              (mem_rsp_read_data),
        .rsp_error                  (mem_rsp_error),

        .*
    );

endmodule

