`timescale 1ns/1ps

// Serialized gather/scatter frontend shared by all Phase-E compute blocks.
//
// One native request is gathered completely before data_valid is pulsed.  One
// native result is scattered completely before result_ready is pulsed.  This
// ordering preserves in-place command semantics and prevents cmd_done from
// preceding the final memory response.
(* use_dsp = "no" *)
module vit_phase_e_memory_frontend_optimized #(
    parameter integer ARRAY_ROWS   = 2,
    parameter integer ARRAY_COLS   = 2,
    parameter integer PE_LANES     = 16,
    parameter integer VECTOR_LANES = 16,
    parameter integer GEMM_A_CACHE_DEPTH_WORDS = 3072,
    parameter integer GEMM_BIAS_CACHE_DEPTH_WORDS = 3072
)(
    input  logic                           clk,
    input  logic                           rst,
    input  logic                           command_accept,
    input  logic                           execute,
    input  vit_phase_e_pkg::phase_e_cmd_t  active_cmd,

    input  logic        selected_data_request,
    input  logic        selected_result_valid,
    input  logic [15:0] read_word_count,
    input  logic [15:0] write_word_count,
    output logic        memory_error_latched,
    output logic [3:0]  debug_mem_state,

    // One-cycle/profile-level events.  Logical word events are generated in
    // the SELECT states before an eligible read is served by a local cache.
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

    output logic                              mem_req_valid,
    input  logic                              mem_req_ready,
    output logic                              mem_req_write,
    output vit_phase_e_pkg::phase_e_mem_space_t mem_req_space,
    output logic [31:0]                       mem_req_word_address,
    output logic [31:0]                       mem_req_write_data,
    output logic [3:0]                        mem_req_write_strobe,
    output logic                              mem_req_read_ahead_safe,
    output logic [5:0]                        mem_req_contiguous_words,
    input  logic                              mem_rsp_valid,
    output logic                              mem_rsp_ready,
    input  logic [31:0]                       mem_rsp_read_data,
    input  logic                              mem_rsp_error,

    input  logic [31:0] gemm_token_base,
    input  logic [31:0] gemm_output_base,
    input  logic [31:0] gemm_k_base,
    input  logic [31:0] gemm_batch_index,
    output logic [ARRAY_ROWS*PE_LANES*32-1:0] gemm_activation_data,
    output logic [ARRAY_COLS*PE_LANES*32-1:0] gemm_weight_data,
    output logic [ARRAY_COLS*32-1:0] gemm_bias_data,
    output logic gemm_data_valid,
    output logic [65:0] gemm_result_address_base_current_o,
    input  logic [65:0] gemm_result_address_base_store_i,
    input  logic [7:0] gemm_result_generation_store_i,
    input  logic [7:0] gemm_result_generation_expected_i,
    input  logic [31:0] gemm_result_token_base_store_i,
    input  logic [31:0] gemm_result_output_base_store_i,
    input  logic [31:0] gemm_result_batch_index_store_i,
    input  logic [ARRAY_ROWS-1:0] gemm_result_token_mask,
    input  logic [ARRAY_COLS-1:0] gemm_result_output_mask,
    input  logic [ARRAY_ROWS*ARRAY_COLS*32-1:0] gemm_result_data,
    output logic gemm_result_ready,

    input  logic [31:0] vector_element_base,
    output logic [VECTOR_LANES*32-1:0] vector_input_a,
    output logic [VECTOR_LANES*32-1:0] vector_input_b,
    output logic vector_data_valid,
    input  logic [31:0] vector_result_base,
    input  logic [VECTOR_LANES-1:0] vector_result_lane_mask,
    input  logic [VECTOR_LANES*32-1:0] vector_result_data,
    output logic vector_result_ready,

    input  logic [31:0] layout_source_address,
    output logic [31:0] layout_source_data,
    output logic layout_data_valid,
    input  logic [31:0] layout_result_address,
    input  logic [31:0] layout_result_data,
    output logic layout_result_ready,

    input  logic [1:0] ln_data_pass,
    input  logic [31:0] ln_data_index,
    input  logic [31:0] ln_data_channel_index,
    output logic [31:0] ln_input_data,
    output logic [31:0] ln_gamma_data,
    output logic [31:0] ln_beta_data,
    output logic ln_input_valid,
    input  logic [31:0] ln_result_index,
    input  logic [31:0] ln_result_data,
    output logic ln_result_ready,

    input  logic [31:0] softmax_data_index,
    output logic [31:0] softmax_input_data,
    output logic softmax_input_valid,
    input  logic [31:0] softmax_result_index,
    input  logic [31:0] softmax_result_data,
    output logic softmax_result_ready,

    input  logic [31:0] gelu_data_base_index,
    input  logic [VECTOR_LANES-1:0] gelu_data_lane_mask,
    output logic [VECTOR_LANES*32-1:0] gelu_input_data,
    output logic gelu_input_valid,
    input  logic [31:0] gelu_result_base_index,
    input  logic [VECTOR_LANES-1:0] gelu_result_lane_mask,
    input  logic [VECTOR_LANES*32-1:0] gelu_result_data,
    output logic gelu_result_ready,

    input  logic [31:0] argmax_element_index,
    output logic [31:0] argmax_input_data,
    output logic argmax_data_valid,
    output logic argmax_result_ready
);

    import vit_phase_e_pkg::*;

    localparam integer GEMM_A_WORDS =
        ARRAY_ROWS * PE_LANES;
    localparam integer GEMM_B_WORDS =
        ARRAY_COLS * PE_LANES;
    localparam integer GEMM_PACKED_B_WORDS =
        ((ARRAY_COLS + 1) / 2) * PE_LANES;
    localparam logic [31:0] GEMM_A_WORDS_U32 = 32'(GEMM_A_WORDS);
    localparam logic [31:0] GEMM_B_WORDS_U32 = 32'(GEMM_B_WORDS);
    localparam logic [31:0] GEMM_PACKED_B_WORDS_U32 =
        32'(GEMM_PACKED_B_WORDS);
    localparam logic [31:0] ARRAY_COLS_U32 = 32'(ARRAY_COLS);
    localparam logic [31:0] PE_LANES_U32 = 32'(PE_LANES);
    localparam logic [31:0] VECTOR_LANES_U32 = 32'(VECTOR_LANES);
    localparam integer GEMM_A_CACHE_ROW_WIDTH =
        (ARRAY_ROWS <= 1) ? 1 : $clog2(ARRAY_ROWS);
    localparam logic [32:0] GEMM_A_CACHE_DEPTH_WIDE =
        33'(GEMM_A_CACHE_DEPTH_WORDS);
    localparam logic [32:0] GEMM_BIAS_CACHE_DEPTH_WIDE =
        33'(GEMM_BIAS_CACHE_DEPTH_WORDS);
    localparam logic [32:0] GEMM_PE_LANES_WIDE = 33'(PE_LANES);

    typedef enum logic [3:0] {
        MEM_IDLE,
        MEM_READ_SELECT,
        MEM_READ_REQUEST,
        MEM_READ_RESPONSE,
        MEM_CACHE_RESPONSE,
        MEM_READ_DELIVER,
        MEM_WRITE_SELECT,
        MEM_WRITE_REQUEST,
        MEM_WRITE_RESPONSE,
        MEM_WRITE_DELIVER,
        // Appended states preserve the frozen debug encodings 0..9.
        MEM_GEMM_A_VECTOR_PRIME,
        MEM_GEMM_A_VECTOR_RUN,
        MEM_GEMM_A_VECTOR_DRAIN,
        // M2: scalar read issue/retire pipeline.
        // Appended to preserve existing debug state encodings.
        MEM_READ_PIPE
    } mem_state_t;

    mem_state_t mem_state;
    logic [15:0] mem_word_index;
    logic [31:0] mem_word_index_u32;
    logic gemm_b_packed2;
    logic [31:0] gemm_b_storage_words_u32;
    logic [31:0] gemm_bias_word_base_u32;

    assign debug_mem_state = mem_state;
    assign mem_word_index_u32 = {16'd0, mem_word_index};
    assign gemm_b_packed2 =
        (active_cmd.header.flags &
         PHASE_E_FLAG_GEMM_B_FP16_PACKED2) != 0;
    assign gemm_b_storage_words_u32 = gemm_b_packed2 ?
        GEMM_PACKED_B_WORDS_U32 : GEMM_B_WORDS_U32;
    assign gemm_bias_word_base_u32 =
        GEMM_A_WORDS_U32 + gemm_b_storage_words_u32;

    initial begin
        if (ARRAY_ROWS <= 0)
            $fatal(1,
                   "vit_phase_e_memory_frontend requires ARRAY_ROWS > 0");
        if (ARRAY_COLS <= 0)
            $fatal(1,
                   "vit_phase_e_memory_frontend requires ARRAY_COLS > 0");
        if (PE_LANES <= 0)
            $fatal(1,
                   "vit_phase_e_memory_frontend requires PE_LANES > 0");
        if (VECTOR_LANES <= 0)
            $fatal(1,
                   "vit_phase_e_memory_frontend requires VECTOR_LANES > 0");
        if ((GEMM_A_WORDS + GEMM_B_WORDS + ARRAY_COLS) > 16'hffff)
            $fatal(1,
                   "GEMM read word count must fit the 16-bit word index");
        if ((ARRAY_ROWS * ARRAY_COLS) > 16'hffff)
            $fatal(1,
                   "GEMM write word count must fit the 16-bit word index");
        if ((VECTOR_LANES + VECTOR_LANES) > 16'hffff)
            $fatal(1,
                   "Vector read word count must fit the 16-bit word index");
        if (GEMM_A_CACHE_DEPTH_WORDS <= 0)
            $fatal(1,
                   "GEMM_A_CACHE_DEPTH_WORDS must be greater than zero");
        if (GEMM_BIAS_CACHE_DEPTH_WORDS <= 0)
            $fatal(1,
                   "GEMM_BIAS_CACHE_DEPTH_WORDS must be greater than zero");
    end

    logic read_candidate_needed;
    phase_e_mem_space_t read_candidate_space;
    logic [31:0] read_candidate_address;
    logic read_candidate_address_overflow;
    logic read_candidate_read_ahead_safe;
    logic [5:0] read_candidate_contiguous_words;
    logic write_candidate_needed;
    phase_e_mem_space_t write_candidate_space;
    logic [31:0] write_candidate_address;
    logic write_candidate_address_overflow;
    logic [31:0] write_candidate_data;
    logic gemm_address_context_start;
    logic [65:0] gemm_activation_address_base;
    logic [65:0] gemm_weight_address_base;
    logic [65:0] gemm_bias_address_base;
    logic [65:0] gemm_result_address_base;
    logic [65:0] gemm_result_address_base_store_q;
    logic [7:0] gemm_result_generation_store_q;
    logic [31:0] gemm_result_token_base_store_q;
    logic [31:0] gemm_result_output_base_store_q;
    logic [31:0] gemm_result_batch_index_store_q;
    logic gemm_result_generation_error;
    logic gemm_packed_store_turn_q;
    logic gemm_packed_result_defer_q;
    logic gemm_a_cache_valid;
    logic [31:0] gemm_a_cache_batch_tag;
    logic [31:0] gemm_a_cache_token_tag;
    logic gemm_a_cache_allowed;
    logic gemm_a_cache_tag_match;
    logic gemm_a_cache_hit;
    logic [GEMM_A_CACHE_ROW_WIDTH-1:0] gemm_a_cache_word_row;
    logic [31:0] gemm_a_cache_word_lane;
    logic [31:0] gemm_a_cache_k_index;
    logic gemm_a_cache_write_enable;
    logic gemm_a_cache_read_enable;
    logic gemm_a_cache_read_data_valid;
    logic [31:0] gemm_a_cache_read_data;
    logic gemm_a_cache_vector_read_enable;
    logic [31:0] gemm_a_cache_vector_read_k_index;
    logic gemm_a_cache_vector_read_data_valid;
    logic [ARRAY_ROWS*32-1:0] gemm_a_cache_vector_read_data;
    logic gemm_a_vector_path_hit;
    logic [4:0] gemm_a_vector_issue_lane_q;
    logic [4:0] gemm_a_vector_response_lane_q;
    logic [31:0] gemm_a_vector_token_q;
    logic [31:0] gemm_a_vector_output_q;
    logic [31:0] gemm_a_vector_k_q;
    logic [31:0] gemm_a_vector_batch_q;
    logic gemm_a_vector_lane_valid;
    logic gemm_a_vector_coordinate_error;
    logic gemm_a_vector_response_error;
    logic gemm_a_vector_request_active_q;
    logic [ARRAY_ROWS-1:0] gemm_a_vector_row_valid_q;
    integer gemm_a_vector_count_row;
    integer gemm_a_vector_capture_row;
    integer gemm_a_vector_valid_row_count;
    logic gemm_bias_cache_valid;
    logic gemm_bias_cache_allowed;
    logic gemm_bias_cache_hit;
    logic gemm_bias_cache_word;
    logic [31:0] gemm_bias_cache_column;
    logic [31:0] gemm_bias_cache_index;
    logic gemm_bias_cache_write_enable;
    logic gemm_bias_cache_read_enable;
    logic gemm_bias_cache_read_data_valid;
    logic [31:0] gemm_bias_cache_read_data;

    // M2 scalar-read metadata queue, depth = 2.
    // Stores logical word index until its response retires.
    logic [15:0] read_meta_word_index [0:1];
    logic        read_meta_read_pointer;
    logic        read_meta_write_pointer;
    logic [1:0]  read_meta_count;

    // M2 pipeline control.
    logic        read_pipe_issue_done_q;
    logic        read_pipe_error_q;

    // M2 derived issue/retire control.
    logic        read_pipe_candidate;
    logic        read_pipe_can_issue;
    logic        read_pipe_req_fire;
    logic        read_pipe_rsp_fire;
    logic [1:0]  read_meta_count_next;
    logic [15:0] read_retire_word_index;
    logic [31:0] read_retire_word_index_u32;

    // M2 response-retire/cache-fill coordinates.
    logic        read_response_fire;
    logic [GEMM_A_CACHE_ROW_WIDTH-1:0] gemm_a_cache_write_row;
    logic [31:0] gemm_a_cache_write_lane;
    logic [31:0] gemm_a_cache_write_k_index;
    logic        gemm_bias_cache_write_word;
    logic [31:0] gemm_bias_cache_write_column;
    logic [31:0] gemm_bias_cache_write_index;

    // ============================================================
    // M2 scalar-read issue/retire derived control
    // ============================================================

    // Only exact external scalar reads are candidates for M2.
    // Cache hits and read-ahead/line-fill stay on historical paths.
    assign read_pipe_candidate =
        read_candidate_needed &&
        (read_candidate_space != PHASE_E_MEM_NONE) &&
        !read_candidate_address_overflow &&
        !((active_cmd.header.opcode == PHASE_E_OP_GEMM) &&
          gemm_a_cache_hit) &&
        !((active_cmd.header.opcode == PHASE_E_OP_GEMM) &&
          gemm_bias_cache_hit) &&
        !read_candidate_read_ahead_safe;

    assign read_pipe_can_issue =
        (mem_state == MEM_READ_PIPE) &&
        !read_pipe_issue_done_q &&
        !read_pipe_error_q &&
        (read_meta_count < 2) &&
        read_pipe_candidate;

    // These fire signals become active only after M2.6E connects
    // MEM_READ_PIPE to the logical request/response channels.
    assign read_pipe_req_fire =
        read_pipe_can_issue &&
        mem_req_valid &&
        mem_req_ready;

    assign read_pipe_rsp_fire =
        (mem_state == MEM_READ_PIPE) &&
        (read_meta_count != 0) &&
        mem_rsp_valid &&
        mem_rsp_ready;

    // Issue cursor may later advance ahead of response retirement.
    // Retire destination therefore comes from FIFO head.
    assign read_retire_word_index =
        ((mem_state == MEM_READ_PIPE) &&
         (read_meta_count != 0)) ?
        read_meta_word_index[read_meta_read_pointer] :
        mem_word_index;

    assign read_retire_word_index_u32 =
        32'(read_retire_word_index);

    // Occupancy supports push, pop, and simultaneous push+pop.
    always_comb begin
        read_meta_count_next = read_meta_count;

        if (read_pipe_req_fire && !read_pipe_rsp_fire)
            read_meta_count_next = read_meta_count + 2'd1;
        else if (!read_pipe_req_fire && read_pipe_rsp_fire)
            read_meta_count_next = read_meta_count - 2'd1;
    end

    // Historical/cache/linefill reads are counted in SELECT.
    // Scalar pipeline reads are counted when actually accepted.
    assign profile_logical_read_word_o =
        ((mem_state == MEM_READ_SELECT) &&
         read_candidate_needed &&
         (read_candidate_space != PHASE_E_MEM_NONE) &&
         !read_candidate_address_overflow &&
         !read_pipe_candidate) ||
        read_pipe_req_fire;
    assign profile_logical_write_word_o =
        (mem_state == MEM_WRITE_SELECT) &&
        write_candidate_needed &&
        (write_candidate_space != PHASE_E_MEM_NONE) &&
        !write_candidate_address_overflow;

    assign profile_load_active_o =
        (mem_state == MEM_READ_SELECT) ||
        (mem_state == MEM_READ_REQUEST) ||
        (mem_state == MEM_READ_RESPONSE) ||
        (mem_state == MEM_CACHE_RESPONSE) ||
        (mem_state == MEM_READ_DELIVER) ||
        (mem_state == MEM_READ_PIPE) ||
        (mem_state == MEM_GEMM_A_VECTOR_PRIME) ||
        (mem_state == MEM_GEMM_A_VECTOR_RUN) ||
        (mem_state == MEM_GEMM_A_VECTOR_DRAIN);
    assign profile_store_active_o =
        (mem_state == MEM_WRITE_SELECT) ||
        (mem_state == MEM_WRITE_REQUEST) ||
        (mem_state == MEM_WRITE_RESPONSE) ||
        (mem_state == MEM_WRITE_DELIVER);

    assign profile_a_cache_lookup_o =
        profile_logical_read_word_o &&
        (active_cmd.header.opcode == PHASE_E_OP_GEMM) &&
        gemm_a_cache_allowed &&
        (mem_word_index_u32 < GEMM_A_WORDS_U32);
    assign profile_a_cache_hit_o =
        profile_a_cache_lookup_o && gemm_a_cache_hit;
    assign profile_a_cache_miss_o =
        profile_a_cache_lookup_o && !gemm_a_cache_hit;

    assign profile_bias_cache_lookup_o =
        profile_logical_read_word_o &&
        (active_cmd.header.opcode == PHASE_E_OP_GEMM) &&
        gemm_bias_cache_allowed &&
        gemm_bias_cache_word;
    assign profile_bias_cache_hit_o =
        profile_bias_cache_lookup_o && gemm_bias_cache_hit;
    assign profile_bias_cache_miss_o =
        profile_bias_cache_lookup_o && !gemm_bias_cache_hit;

    // There is deliberately no B cache in this revision.  Count valid B-word
    // demand as bypass traffic instead of mislabelling it as a cache miss.
    assign profile_b_bypass_o =
        profile_logical_read_word_o &&
        (active_cmd.header.opcode == PHASE_E_OP_GEMM) &&
        (mem_word_index_u32 >= GEMM_A_WORDS_U32) &&
        (mem_word_index_u32 <
         (GEMM_A_WORDS_U32 + gemm_b_storage_words_u32));

    assign profile_frontend_error_o =
        ((mem_state == MEM_READ_SELECT) &&
         read_candidate_needed &&
         (read_candidate_space != PHASE_E_MEM_NONE) &&
         read_candidate_address_overflow) ||
        ((mem_state == MEM_WRITE_SELECT) &&
         write_candidate_needed &&
         (write_candidate_space != PHASE_E_MEM_NONE) &&
         write_candidate_address_overflow) ||
        (((mem_state == MEM_READ_RESPONSE) ||
          (mem_state == MEM_WRITE_RESPONSE)) &&
         mem_rsp_valid && mem_rsp_ready && mem_rsp_error) ||
        (read_pipe_rsp_fire && mem_rsp_error) ||
        gemm_a_vector_coordinate_error ||
        gemm_a_vector_response_error ||
        gemm_result_generation_error;
    assign profile_a_vector_protocol_error_o =
        gemm_a_vector_coordinate_error ||
        gemm_a_vector_response_error;
    assign profile_result_generation_error_o =
        gemm_result_generation_error;

    // The address context describes the result corresponding to the current
    // operand request.  Packed mode captures this value into its FIFO before
    // advancing any tile coordinate.
    assign gemm_result_address_base_current_o =
        gemm_result_address_base;
    assign gemm_result_generation_error =
        (((mem_state == MEM_IDLE) && execute && selected_result_valid) &&
         (active_cmd.header.opcode == PHASE_E_OP_GEMM) &&
         (gemm_result_generation_store_i !=
          gemm_result_generation_expected_i)) ||
        ((((mem_state == MEM_WRITE_SELECT) ||
           (mem_state == MEM_WRITE_REQUEST) ||
           (mem_state == MEM_WRITE_RESPONSE) ||
           (mem_state == MEM_WRITE_DELIVER)) &&
          (active_cmd.header.opcode == PHASE_E_OP_GEMM)) &&
         ((gemm_result_generation_store_i !=
           gemm_result_generation_store_q) ||
          (gemm_result_address_base_store_i !=
           gemm_result_address_base_store_q) ||
          (gemm_result_token_base_store_i !=
           gemm_result_token_base_store_q) ||
          (gemm_result_output_base_store_i !=
           gemm_result_output_base_store_q) ||
          (gemm_result_batch_index_store_i !=
           gemm_result_batch_index_store_q)));

    assign gemm_address_context_start =
        (mem_state == MEM_IDLE) &&
        execute &&
        selected_data_request &&
        (active_cmd.header.opcode == PHASE_E_OP_GEMM);

    always_comb begin
        gemm_a_cache_word_row = '0;
        gemm_a_cache_word_lane = 32'd0;
        if (mem_word_index_u32 < GEMM_A_WORDS_U32) begin
            gemm_a_cache_word_row =
                GEMM_A_CACHE_ROW_WIDTH'(
                    mem_word_index_u32 / PE_LANES_U32
                );
            gemm_a_cache_word_lane =
                mem_word_index_u32 % PE_LANES_U32;
        end
    end

    assign gemm_a_cache_k_index =
        gemm_k_base + gemm_a_cache_word_lane;
    assign gemm_a_cache_allowed =
        ((active_cmd.header.flags &
          PHASE_E_FLAG_GEMM_CACHE_SAFE) != 0) &&
        ({1'b0, active_cmd.dim2} <= GEMM_A_CACHE_DEPTH_WIDE);
    assign gemm_a_cache_tag_match =
        (gemm_a_cache_batch_tag == gemm_batch_index) &&
        (gemm_a_cache_token_tag == gemm_token_base);
    assign gemm_a_cache_hit =
        gemm_a_cache_allowed &&
        gemm_a_cache_valid &&
        gemm_a_cache_tag_match &&
        (mem_word_index_u32 < GEMM_A_WORDS_U32);

    // The vector cache path is intentionally limited to packed persistent-B
    // GEMMs with the same CACHE_SAFE/tag/capacity contract as the scalar hit
    // path.  Mode 5/non-packed scratch and every cache miss stay unchanged.
    assign gemm_a_vector_path_hit =
        (active_cmd.header.opcode == PHASE_E_OP_GEMM) &&
        gemm_b_packed2 &&
        ((active_cmd.header.flags & PHASE_E_FLAG_GEMM_FP16) != 0) &&
        ((active_cmd.header.flags &
          PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2) != 0) &&
        (active_cmd.route.src1_space == PHASE_E_MEM_PARAM) &&
        gemm_a_cache_allowed &&
        gemm_a_cache_valid &&
        gemm_a_cache_tag_match;
    assign gemm_a_vector_lane_valid =
        ({1'b0, gemm_a_vector_k_q} +
         {28'd0, gemm_a_vector_issue_lane_q}) <
        {1'b0, active_cmd.dim2};
    assign gemm_a_cache_vector_read_enable =
        ((mem_state == MEM_GEMM_A_VECTOR_PRIME) ||
         (mem_state == MEM_GEMM_A_VECTOR_RUN)) &&
        gemm_a_vector_lane_valid;
    assign gemm_a_cache_vector_read_k_index =
        gemm_a_vector_k_q + gemm_a_vector_issue_lane_q;
    assign gemm_a_vector_coordinate_error =
        gemm_a_vector_request_active_q &&
        ((gemm_token_base != gemm_a_vector_token_q) ||
         (gemm_output_base != gemm_a_vector_output_q) ||
         (gemm_k_base != gemm_a_vector_k_q) ||
         (gemm_batch_index != gemm_a_vector_batch_q));
    assign gemm_a_vector_response_error =
        ((mem_state == MEM_GEMM_A_VECTOR_RUN) ||
         (mem_state == MEM_GEMM_A_VECTOR_DRAIN)) &&
        !gemm_a_cache_vector_read_data_valid;

    always_comb begin
        gemm_a_vector_valid_row_count = 0;
        if (gemm_a_cache_vector_read_enable)
            for (gemm_a_vector_count_row = 0;
                 gemm_a_vector_count_row < ARRAY_ROWS;
                 gemm_a_vector_count_row = gemm_a_vector_count_row + 1)
                if (gemm_a_vector_row_valid_q[gemm_a_vector_count_row])
                    gemm_a_vector_valid_row_count =
                        gemm_a_vector_valid_row_count + 1;
        profile_a_vector_hit_word_delta_o =
            4'(gemm_a_vector_valid_row_count);
    end

    // Response corresponding to the current retire metadata entry.
    // In the historical path this is exactly MEM_READ_RESPONSE fire.
    assign read_response_fire =
        (((mem_state == MEM_READ_RESPONSE) &&
          mem_rsp_valid && mem_rsp_ready) ||
         read_pipe_rsp_fire);

    // A-cache fill location follows the retired request, not the
    // potentially advanced issue cursor.
    always_comb begin
        gemm_a_cache_write_row = '0;
        gemm_a_cache_write_lane = 32'd0;

        if (read_retire_word_index_u32 < GEMM_A_WORDS_U32) begin
            gemm_a_cache_write_row =
                GEMM_A_CACHE_ROW_WIDTH'(
                    read_retire_word_index_u32 / PE_LANES_U32
                );

            gemm_a_cache_write_lane =
                read_retire_word_index_u32 % PE_LANES_U32;
        end
    end

    assign gemm_a_cache_write_k_index =
        gemm_k_base + gemm_a_cache_write_lane;

    assign gemm_bias_cache_write_word =
        (read_retire_word_index_u32 >= gemm_bias_word_base_u32) &&
        (read_retire_word_index_u32 <
         (gemm_bias_word_base_u32 + ARRAY_COLS_U32));

    assign gemm_bias_cache_write_column =
        read_retire_word_index_u32 - gemm_bias_word_base_u32;

    assign gemm_bias_cache_write_index =
        gemm_output_base + gemm_bias_cache_write_column;

    assign gemm_a_cache_write_enable =
        read_response_fire &&
        !mem_rsp_error &&
        (active_cmd.header.opcode == PHASE_E_OP_GEMM) &&
        gemm_a_cache_allowed &&
        (gemm_output_base == 0) &&
        (read_retire_word_index_u32 < GEMM_A_WORDS_U32);

    assign gemm_a_cache_read_enable =
        (mem_state == MEM_READ_SELECT) &&
        gemm_a_cache_hit &&
        read_candidate_needed &&
        (read_candidate_space != PHASE_E_MEM_NONE) &&
        !read_candidate_address_overflow;

    assign gemm_bias_cache_word =
        (mem_word_index_u32 >= gemm_bias_word_base_u32) &&
        (mem_word_index_u32 <
         (gemm_bias_word_base_u32 + ARRAY_COLS_U32));
    assign gemm_bias_cache_column =
        mem_word_index_u32 - gemm_bias_word_base_u32;
    assign gemm_bias_cache_index =
        gemm_output_base + gemm_bias_cache_column;
    assign gemm_bias_cache_allowed =
        ((active_cmd.header.flags &
          PHASE_E_FLAG_GEMM_CACHE_SAFE) != 0) &&
        ((active_cmd.header.flags &
          PHASE_E_FLAG_BIAS_ENABLE) != 0) &&
        ({1'b0, active_cmd.dim3} <= GEMM_BIAS_CACHE_DEPTH_WIDE);
    assign gemm_bias_cache_hit =
        gemm_bias_cache_allowed &&
        gemm_bias_cache_valid &&
        gemm_bias_cache_word;

    assign gemm_bias_cache_write_enable =
        read_response_fire &&
        !mem_rsp_error &&
        (active_cmd.header.opcode == PHASE_E_OP_GEMM) &&
        gemm_bias_cache_allowed &&
        (gemm_batch_index == 0) &&
        (gemm_token_base == 0) &&
        gemm_bias_cache_write_word;

    assign gemm_bias_cache_read_enable =
        (mem_state == MEM_READ_SELECT) &&
        gemm_bias_cache_hit &&
        read_candidate_needed &&
        (read_candidate_space != PHASE_E_MEM_NONE) &&
        !read_candidate_address_overflow;

    vit_gemm_activation_panel_cache #(
        .ARRAY_ROWS         (ARRAY_ROWS),
        .DEPTH_WORDS_PER_ROW(GEMM_A_CACHE_DEPTH_WORDS)
    ) u_gemm_activation_panel_cache (
        .clk            (clk),
        .rst            (rst),
        .clear          (command_accept),
        .write_enable   (gemm_a_cache_write_enable),
        .write_row      (gemm_a_cache_write_row),
        .write_k_index  (gemm_a_cache_write_k_index),
        .write_data     (mem_rsp_read_data),
        .read_enable    (gemm_a_cache_read_enable),
        .read_row       (gemm_a_cache_word_row),
        .read_k_index   (gemm_a_cache_k_index),
        .read_data_valid(gemm_a_cache_read_data_valid),
        .read_data      (gemm_a_cache_read_data),
        .vector_read_enable   (gemm_a_cache_vector_read_enable),
        .vector_read_k_index  (gemm_a_cache_vector_read_k_index),
        .vector_read_data_valid(gemm_a_cache_vector_read_data_valid),
        .vector_read_data     (gemm_a_cache_vector_read_data)
    );

    vit_gemm_bias_cache #(
        .DEPTH_WORDS(GEMM_BIAS_CACHE_DEPTH_WORDS)
    ) u_gemm_bias_cache (
        .clk            (clk),
        .rst            (rst),
        .clear          (command_accept),
        .write_enable   (gemm_bias_cache_write_enable),
        .write_index    (gemm_bias_cache_write_index),
        .write_data     (mem_rsp_read_data),
        .read_enable    (gemm_bias_cache_read_enable),
        .read_index     (gemm_bias_cache_index),
        .read_data_valid(gemm_bias_cache_read_data_valid),
        .read_data      (gemm_bias_cache_read_data)
    );

    vit_gemm_memory_address_context #(
        .ARRAY_ROWS (ARRAY_ROWS),
        .ARRAY_COLS (ARRAY_COLS),
        .PE_LANES   (PE_LANES)
    ) u_gemm_address_context (
        .clk                     (clk),
        .rst                     (rst),
        .clear                   (command_accept),
        .request_start           (gemm_address_context_start),
        .active_cmd              (active_cmd),
        .token_base              (gemm_token_base),
        .output_base             (gemm_output_base),
        .k_base                  (gemm_k_base),
        .batch_index             (gemm_batch_index),
        .activation_address_base (gemm_activation_address_base),
        .weight_address_base     (gemm_weight_address_base),
        .bias_address_base       (gemm_bias_address_base),
        .result_address_base     (gemm_result_address_base)
    );

    vit_phase_e_read_address_router #(
        .ARRAY_ROWS   (ARRAY_ROWS),
        .ARRAY_COLS   (ARRAY_COLS),
        .PE_LANES     (PE_LANES),
        .VECTOR_LANES (VECTOR_LANES)
    ) u_read_address_router (
        .active_cmd                 (active_cmd),
        .word_index                 (mem_word_index),
        .gemm_token_base            (gemm_token_base),
        .gemm_output_base           (gemm_output_base),
        .gemm_k_base                (gemm_k_base),
        .gemm_activation_address_base (
            gemm_activation_address_base
        ),
        .gemm_weight_address_base   (gemm_weight_address_base),
        .gemm_bias_address_base     (gemm_bias_address_base),
        .vector_element_base        (vector_element_base),
        .layout_source_address      (layout_source_address),
        .ln_data_pass               (ln_data_pass),
        .ln_data_index              (ln_data_index),
        .ln_data_channel_index      (ln_data_channel_index),
        .softmax_data_index         (softmax_data_index),
        .gelu_data_base_index       (gelu_data_base_index),
        .gelu_data_lane_mask        (gelu_data_lane_mask),
        .argmax_element_index       (argmax_element_index),
        .candidate_needed           (read_candidate_needed),
        .candidate_space            (read_candidate_space),
        .candidate_address          (read_candidate_address),
        .candidate_address_overflow (read_candidate_address_overflow),
        .candidate_read_ahead_safe  (read_candidate_read_ahead_safe),
        .candidate_contiguous_words (read_candidate_contiguous_words)
    );

    vit_phase_e_write_address_router #(
        .ARRAY_ROWS   (ARRAY_ROWS),
        .ARRAY_COLS   (ARRAY_COLS),
        .VECTOR_LANES (VECTOR_LANES)
    ) u_write_address_router (
        .active_cmd                 (active_cmd),
        .word_index                 (mem_word_index),
        .gemm_result_address_base   (gemm_result_address_base_store_q),
        .gemm_result_token_mask     (gemm_result_token_mask),
        .gemm_result_output_mask    (gemm_result_output_mask),
        .gemm_result_data           (gemm_result_data),
        .vector_result_base         (vector_result_base),
        .vector_result_lane_mask    (vector_result_lane_mask),
        .vector_result_data         (vector_result_data),
        .layout_result_address      (layout_result_address),
        .layout_result_data         (layout_result_data),
        .ln_result_index            (ln_result_index),
        .ln_result_data             (ln_result_data),
        .softmax_result_index       (softmax_result_index),
        .softmax_result_data        (softmax_result_data),
        .gelu_result_base_index     (gelu_result_base_index),
        .gelu_result_lane_mask      (gelu_result_lane_mask),
        .gelu_result_data           (gelu_result_data),
        .candidate_needed           (write_candidate_needed),
        .candidate_space            (write_candidate_space),
        .candidate_address          (write_candidate_address),
        .candidate_address_overflow (write_candidate_address_overflow),
        .candidate_data             (write_candidate_data)
    );

    assign mem_req_valid =
        (mem_state == MEM_READ_REQUEST) ||
        (mem_state == MEM_WRITE_REQUEST) ||
        read_pipe_can_issue;
    assign mem_req_write = (mem_state == MEM_WRITE_REQUEST);
    always_comb begin
        if (mem_req_write)
            mem_req_space = write_candidate_space;
        else
            mem_req_space = read_candidate_space;
    end
    assign mem_req_word_address =
        mem_req_write ? write_candidate_address : read_candidate_address;
    assign mem_req_write_data = write_candidate_data;
    assign mem_req_write_strobe = 4'hf;
    assign mem_req_read_ahead_safe =
        (mem_state == MEM_READ_REQUEST) &&
        read_candidate_read_ahead_safe;
    assign mem_req_contiguous_words = mem_req_read_ahead_safe ?
        read_candidate_contiguous_words : 6'd1;
    assign mem_rsp_ready =
        (mem_state == MEM_READ_RESPONSE) ||
        (mem_state == MEM_WRITE_RESPONSE) ||
        ((mem_state == MEM_READ_PIPE) &&
         (read_meta_count != 0));

    assign gemm_data_valid =
        (mem_state == MEM_READ_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_GEMM) &&
        !gemm_a_vector_coordinate_error;
    assign vector_data_valid =
        (mem_state == MEM_READ_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_VECTOR);
    assign layout_data_valid =
        (mem_state == MEM_READ_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_LAYOUT);
    assign ln_input_valid =
        (mem_state == MEM_READ_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_LAYERNORM);
    assign softmax_input_valid =
        (mem_state == MEM_READ_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_SOFTMAX);
    assign gelu_input_valid =
        (mem_state == MEM_READ_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_GELU);
    assign argmax_data_valid =
        (mem_state == MEM_READ_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_ARGMAX);

    assign gemm_result_ready =
        (mem_state == MEM_WRITE_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_GEMM);
    assign vector_result_ready =
        (mem_state == MEM_WRITE_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_VECTOR);
    assign layout_result_ready =
        (mem_state == MEM_WRITE_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_LAYOUT);
    assign ln_result_ready =
        (mem_state == MEM_WRITE_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_LAYERNORM);
    assign softmax_result_ready =
        (mem_state == MEM_WRITE_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_SOFTMAX);
    assign gelu_result_ready =
        (mem_state == MEM_WRITE_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_GELU);
    assign argmax_result_ready =
        (mem_state == MEM_WRITE_DELIVER) &&
        (active_cmd.header.opcode == PHASE_E_OP_ARGMAX);

    always_ff @(posedge clk) begin
        if (rst) begin
            mem_state <= MEM_IDLE;
            mem_word_index <= 16'd0;

            read_meta_word_index[0] <= 16'd0;
            read_meta_word_index[1] <= 16'd0;
            read_meta_read_pointer <= 1'b0;
            read_meta_write_pointer <= 1'b0;
            read_meta_count <= 2'd0;
            read_pipe_issue_done_q <= 1'b0;
            read_pipe_error_q <= 1'b0;
            memory_error_latched <= 1'b0;
            gemm_a_cache_valid <= 1'b0;
            gemm_a_cache_batch_tag <= 32'd0;
            gemm_a_cache_token_tag <= 32'd0;
            gemm_bias_cache_valid <= 1'b0;
            gemm_activation_data <= '0;
            gemm_weight_data <= '0;
            gemm_bias_data <= '0;
            vector_input_a <= '0;
            vector_input_b <= '0;
            layout_source_data <= 32'd0;
            ln_input_data <= 32'd0;
            ln_gamma_data <= 32'd0;
            ln_beta_data <= 32'd0;
            softmax_input_data <= 32'd0;
            gelu_input_data <= '0;
            argmax_input_data <= 32'd0;
            gemm_a_vector_issue_lane_q <= 5'd0;
            gemm_a_vector_response_lane_q <= 5'd0;
            gemm_a_vector_token_q <= 32'd0;
            gemm_a_vector_output_q <= 32'd0;
            gemm_a_vector_k_q <= 32'd0;
            gemm_a_vector_batch_q <= 32'd0;
            gemm_a_vector_request_active_q <= 1'b0;
            gemm_a_vector_row_valid_q <= '0;
            gemm_result_address_base_store_q <= 66'd0;
            gemm_result_generation_store_q <= 8'd0;
            gemm_result_token_base_store_q <= 32'd0;
            gemm_result_output_base_store_q <= 32'd0;
            gemm_result_batch_index_store_q <= 32'd0;
            gemm_packed_store_turn_q <= 1'b0;
            gemm_packed_result_defer_q <= 1'b0;
        end else begin
            if (command_accept) begin
                memory_error_latched <= 1'b0;
                gemm_a_cache_valid <= 1'b0;
                gemm_bias_cache_valid <= 1'b0;
                gemm_a_vector_request_active_q <= 1'b0;
                gemm_packed_store_turn_q <= 1'b0;
                gemm_packed_result_defer_q <= 1'b0;
            end

            // Once a transaction fails, do not allow a still-high native
            // request/result signal to restart the frontend while engine_rst
            // and command REPORT take effect.
            if (memory_error_latched) begin
                mem_state <= MEM_IDLE;
                mem_word_index <= 16'd0;
                gemm_a_cache_valid <= 1'b0;
                gemm_bias_cache_valid <= 1'b0;
                gemm_a_vector_request_active_q <= 1'b0;
                gemm_packed_store_turn_q <= 1'b0;
                gemm_packed_result_defer_q <= 1'b0;
            end else if (gemm_result_generation_error) begin
                // Never let a stale queued result inherit a newer command's
                // destination.  The wrapper requires SOFT_RESET after this
                // terminal error before another job can start.
                memory_error_latched <= 1'b1;
                mem_state <= MEM_IDLE;
                mem_word_index <= 16'd0;
                gemm_a_cache_valid <= 1'b0;
                gemm_bias_cache_valid <= 1'b0;
                gemm_a_vector_request_active_q <= 1'b0;
                gemm_packed_store_turn_q <= 1'b0;
                gemm_packed_result_defer_q <= 1'b0;
            end else if (gemm_a_vector_coordinate_error) begin
                // The scheduler must hold the panel coordinates until the
                // complete A/B/bias bundle is delivered.  Fail closed before
                // exposing data_valid if that request contract is violated.
                memory_error_latched <= 1'b1;
                mem_state <= MEM_IDLE;
                mem_word_index <= 16'd0;
                gemm_a_cache_valid <= 1'b0;
                gemm_bias_cache_valid <= 1'b0;
                gemm_a_vector_request_active_q <= 1'b0;
                gemm_packed_store_turn_q <= 1'b0;
                gemm_packed_result_defer_q <= 1'b0;
            end else begin
                case (mem_state)
                    MEM_IDLE: begin
                        mem_word_index <= 16'd0;

                        // M2 pipeline transaction boundary.
                        read_meta_read_pointer <= 1'b0;
                        read_meta_write_pointer <= 1'b0;
                        read_meta_count <= 2'd0;
                        read_pipe_issue_done_q <= 1'b0;
                        read_pipe_error_q <= 1'b0;
                        // Packed mode uses deterministic one-load/one-store
                        // round-robin arbitration when both FIFO output and a
                        // held operand request are present.  The first tie
                        // admits one look-ahead panel; the next tie drains the
                        // immutable result while that panel computes.  Other
                        // modes retain the historical load-first arbitration.
                        if (
                            execute && selected_data_request &&
                            !(
                                selected_result_valid &&
                                (active_cmd.header.opcode == PHASE_E_OP_GEMM) &&
                                ((active_cmd.header.flags &
                                  PHASE_E_FLAG_GEMM_B_FP16_PACKED2) != 0) &&
                                gemm_packed_store_turn_q
                            )
                        ) begin
                            if (
                                selected_result_valid &&
                                (active_cmd.header.opcode == PHASE_E_OP_GEMM) &&
                                ((active_cmd.header.flags &
                                  PHASE_E_FLAG_GEMM_B_FP16_PACKED2) != 0)
                            )
                                gemm_packed_store_turn_q <= 1'b1;
                            if (
                                selected_result_valid &&
                                (active_cmd.header.opcode == PHASE_E_OP_GEMM) &&
                                ((active_cmd.header.flags &
                                  PHASE_E_FLAG_GEMM_B_FP16_PACKED2) != 0)
                            )
                                gemm_packed_result_defer_q <= 1'b0;
                            case (active_cmd.header.opcode)
                                PHASE_E_OP_GEMM: begin
                                    gemm_activation_data <= '0;
                                    gemm_weight_data <= '0;
                                    gemm_bias_data <= '0;
                                    if (
                                        gemm_a_cache_allowed &&
                                        (gemm_output_base == 0) &&
                                        (gemm_k_base == 0) &&
                                        (!gemm_a_cache_valid ||
                                         !gemm_a_cache_tag_match)
                                    ) begin
                                        gemm_a_cache_valid <= 1'b0;
                                        gemm_a_cache_batch_tag <=
                                            gemm_batch_index;
                                        gemm_a_cache_token_tag <=
                                            gemm_token_base;
                                    end
                                end
                                PHASE_E_OP_VECTOR: begin
                                    vector_input_a <= '0;
                                    vector_input_b <= '0;
                                end
                                PHASE_E_OP_LAYOUT:
                                    layout_source_data <= 32'd0;
                                PHASE_E_OP_LAYERNORM: begin
                                    ln_input_data <= 32'd0;
                                    ln_gamma_data <= 32'd0;
                                    ln_beta_data <= 32'd0;
                                end
                                PHASE_E_OP_SOFTMAX:
                                    softmax_input_data <= 32'd0;
                                PHASE_E_OP_GELU:
                                    gelu_input_data <= '0;
                                PHASE_E_OP_ARGMAX:
                                    argmax_input_data <= 32'd0;
                                default: begin
                                end
                            endcase
                            if ((active_cmd.header.opcode == PHASE_E_OP_GEMM) &&
                                gemm_a_vector_path_hit) begin
                                gemm_a_vector_issue_lane_q <= 5'd0;
                                gemm_a_vector_response_lane_q <= 5'd0;
                                gemm_a_vector_token_q <= gemm_token_base;
                                gemm_a_vector_output_q <= gemm_output_base;
                                gemm_a_vector_k_q <= gemm_k_base;
                                gemm_a_vector_batch_q <= gemm_batch_index;
                                gemm_a_vector_request_active_q <= 1'b1;
                                for (gemm_a_vector_capture_row = 0;
                                     gemm_a_vector_capture_row < ARRAY_ROWS;
                                     gemm_a_vector_capture_row =
                                         gemm_a_vector_capture_row + 1)
                                    gemm_a_vector_row_valid_q[
                                        gemm_a_vector_capture_row
                                    ] <=
                                        ({1'b0, gemm_token_base} +
                                         33'(gemm_a_vector_capture_row)) <
                                        {1'b0, active_cmd.dim1};
                                mem_state <= MEM_GEMM_A_VECTOR_PRIME;
                            end else begin
                                mem_state <= MEM_READ_SELECT;
                            end
                        end else if (execute && selected_result_valid) begin
                            if (active_cmd.header.opcode == PHASE_E_OP_GEMM) begin
                                if (
                                    ((active_cmd.header.flags &
                                      PHASE_E_FLAG_GEMM_B_FP16_PACKED2) != 0) &&
                                    !gemm_packed_store_turn_q &&
                                    !gemm_packed_result_defer_q
                                ) begin
                                    // The FIFO head becomes visible one cycle
                                    // before the scheduler's next operand
                                    // request.  Defer exactly once so that the
                                    // round-robin tie can admit that panel.
                                    gemm_packed_result_defer_q <= 1'b1;
                                end else begin
                                    gemm_packed_store_turn_q <= 1'b0;
                                    gemm_packed_result_defer_q <= 1'b0;
                                    gemm_result_address_base_store_q <=
                                        gemm_result_address_base_store_i;
                                    gemm_result_generation_store_q <=
                                        gemm_result_generation_store_i;
                                    gemm_result_token_base_store_q <=
                                        gemm_result_token_base_store_i;
                                    gemm_result_output_base_store_q <=
                                        gemm_result_output_base_store_i;
                                    gemm_result_batch_index_store_q <=
                                        gemm_result_batch_index_store_i;
                                    mem_state <= MEM_WRITE_SELECT;
                                end
                            end else if (active_cmd.header.opcode ==
                                         PHASE_E_OP_ARGMAX)
                                mem_state <= MEM_WRITE_DELIVER;
                            else
                                mem_state <= MEM_WRITE_SELECT;
                        end
                    end

                    MEM_READ_SELECT: begin
                        if (read_candidate_needed &&
                            (read_candidate_space != PHASE_E_MEM_NONE) &&
                            read_candidate_address_overflow) begin
                            memory_error_latched <= 1'b1;
                            mem_state <= MEM_IDLE;
                        end else if (
                            gemm_a_cache_read_enable ||
                            gemm_bias_cache_read_enable
                        ) begin
                            mem_state <= MEM_CACHE_RESPONSE;
                        end else if (!read_candidate_needed ||
                            (read_candidate_space == PHASE_E_MEM_NONE)) begin
                            if ((mem_word_index + 1) >= read_word_count)
                                mem_state <= MEM_READ_DELIVER;
                            else
                                mem_word_index <= mem_word_index + 1'b1;
                        end else begin
                            if (read_pipe_candidate)
                                mem_state <= MEM_READ_PIPE;
                            else
                                mem_state <= MEM_READ_REQUEST;
                        end
                    end

                    MEM_READ_PIPE: begin
                        // ----------------------------------------
                        // ISSUE SIDE
                        // ----------------------------------------
                        if (read_pipe_req_fire) begin
                            read_meta_word_index[
                                read_meta_write_pointer
                            ] <= mem_word_index;

                            read_meta_write_pointer <=
                                ~read_meta_write_pointer;

                            if ((mem_word_index + 1'b1) >=
                                read_word_count) begin

                                // Last logical word accepted.
                                // Keep index parked on the last word
                                // until its response retires.
                                read_pipe_issue_done_q <= 1'b1;

                            end else begin
                                // Advance ISSUE cursor immediately.
                                mem_word_index <=
                                    mem_word_index + 1'b1;
                            end
                        end

                        // ----------------------------------------
                        // RETIRE SIDE
                        // Responses are ordered by the adapter, so
                        // FIFO head identifies destination.
                        // ----------------------------------------
                        if (read_pipe_rsp_fire) begin
                            read_meta_read_pointer <=
                                ~read_meta_read_pointer;

                            if (mem_rsp_error) begin
                                // Stop issuing new reads, but drain
                                // every request already accepted.
                                read_pipe_error_q <= 1'b1;

                            end else begin
                                case (active_cmd.header.opcode)

                                    PHASE_E_OP_GEMM: begin
                                        if (read_retire_word_index_u32 <
                                            GEMM_A_WORDS_U32)
                                            gemm_activation_data[
                                                read_retire_word_index*32
                                                +: 32
                                            ] <= mem_rsp_read_data;
                                        else if (
                                            read_retire_word_index_u32 <
                                            (GEMM_A_WORDS_U32 +
                                             gemm_b_storage_words_u32)
                                        )
                                            gemm_weight_data[
                                                (read_retire_word_index_u32 -
                                                 GEMM_A_WORDS_U32)*32
                                                +: 32
                                            ] <= mem_rsp_read_data;
                                        else
                                            gemm_bias_data[
                                                (read_retire_word_index_u32 -
                                                 gemm_bias_word_base_u32)*32
                                                +: 32
                                            ] <= mem_rsp_read_data;
                                    end

                                    PHASE_E_OP_VECTOR: begin
                                        if (read_retire_word_index_u32 <
                                            VECTOR_LANES_U32)
                                            vector_input_a[
                                                read_retire_word_index*32
                                                +: 32
                                            ] <= mem_rsp_read_data;
                                        else
                                            vector_input_b[
                                                (read_retire_word_index_u32 -
                                                 VECTOR_LANES_U32)*32
                                                +: 32
                                            ] <= mem_rsp_read_data;
                                    end

                                    PHASE_E_OP_LAYOUT:
                                        layout_source_data <=
                                            mem_rsp_read_data;

                                    PHASE_E_OP_LAYERNORM: begin
                                        if (read_retire_word_index == 0)
                                            ln_input_data <=
                                                mem_rsp_read_data;
                                        else if (
                                            read_retire_word_index == 1
                                        )
                                            ln_gamma_data <=
                                                mem_rsp_read_data;
                                        else
                                            ln_beta_data <=
                                                mem_rsp_read_data;
                                    end

                                    PHASE_E_OP_SOFTMAX:
                                        softmax_input_data <=
                                            mem_rsp_read_data;

                                    PHASE_E_OP_GELU:
                                        gelu_input_data[
                                            read_retire_word_index*32
                                            +: 32
                                        ] <= mem_rsp_read_data;

                                    PHASE_E_OP_ARGMAX:
                                        argmax_input_data <=
                                            mem_rsp_read_data;

                                    default: begin
                                    end
                                endcase
                            end
                        end

                        // Push/pop occupancy.
                        read_meta_count <=
                            read_meta_count_next;

                        // ----------------------------------------
                        // ERROR COMPLETION
                        // ----------------------------------------
                        if ((read_pipe_error_q ||
                             (read_pipe_rsp_fire && mem_rsp_error)) &&
                            (read_meta_count_next == 0)) begin

                            memory_error_latched <= 1'b1;
                            read_pipe_issue_done_q <= 1'b0;
                            read_pipe_error_q <= 1'b0;
                            mem_state <= MEM_IDLE;

                        // ----------------------------------------
                        // NORMAL COMPLETION
                        // ----------------------------------------
                        end else if (
                            (read_pipe_issue_done_q ||
                             (read_pipe_req_fire &&
                              ((mem_word_index + 1'b1) >=
                               read_word_count))) &&
                            (read_meta_count_next == 0)
                        ) begin

                            read_pipe_issue_done_q <= 1'b0;
                            read_pipe_error_q <= 1'b0;
                            mem_state <= MEM_READ_DELIVER;

                        // ----------------------------------------
                        // ORDERING BARRIER
                        // Cache hit / linefill / empty candidate.
                        // Only leave after older scalar reads drain.
                        // ----------------------------------------
                        end else if (
                            !read_pipe_candidate &&
                            (read_meta_count_next == 0) &&
                            !read_pipe_issue_done_q &&
                            !read_pipe_error_q
                        ) begin

                            mem_state <= MEM_READ_SELECT;
                        end
                    end

                    MEM_READ_REQUEST: begin
                        if (mem_req_valid && mem_req_ready)
                            mem_state <= MEM_READ_RESPONSE;
                    end

                    MEM_READ_RESPONSE: begin
                        if (mem_rsp_valid && mem_rsp_ready) begin
                            if (mem_rsp_error) begin
                                memory_error_latched <= 1'b1;
                                mem_state <= MEM_IDLE;
                            end else begin
                                case (active_cmd.header.opcode)
                                    PHASE_E_OP_GEMM: begin
                                        if (mem_word_index_u32 <
                                            GEMM_A_WORDS_U32)
                                            gemm_activation_data[
                                                mem_word_index*32 +: 32
                                            ] <= mem_rsp_read_data;
                                        else if (
                                            mem_word_index_u32 <
                                            (GEMM_A_WORDS_U32 +
                                             gemm_b_storage_words_u32)
                                        )
                                            gemm_weight_data[
                                                (mem_word_index_u32 -
                                                 GEMM_A_WORDS_U32)
                                                *32 +: 32
                                            ] <= mem_rsp_read_data;
                                        else
                                            gemm_bias_data[
                                                (mem_word_index_u32 -
                                                 gemm_bias_word_base_u32)*32 +: 32
                                            ] <= mem_rsp_read_data;
                                    end
                                    PHASE_E_OP_VECTOR: begin
                                        if (mem_word_index_u32 <
                                            VECTOR_LANES_U32)
                                            vector_input_a[
                                                mem_word_index*32 +: 32
                                            ] <= mem_rsp_read_data;
                                        else
                                            vector_input_b[
                                                (mem_word_index_u32 -
                                                 VECTOR_LANES_U32)
                                                *32 +: 32
                                            ] <= mem_rsp_read_data;
                                    end
                                    PHASE_E_OP_LAYOUT:
                                        layout_source_data <=
                                            mem_rsp_read_data;
                                    PHASE_E_OP_LAYERNORM: begin
                                        if (mem_word_index == 0)
                                            ln_input_data <=
                                                mem_rsp_read_data;
                                        else if (mem_word_index == 1)
                                            ln_gamma_data <=
                                                mem_rsp_read_data;
                                        else
                                            ln_beta_data <=
                                                mem_rsp_read_data;
                                    end
                                    PHASE_E_OP_SOFTMAX:
                                        softmax_input_data <=
                                            mem_rsp_read_data;
                                    PHASE_E_OP_GELU:
                                        gelu_input_data[
                                            mem_word_index*32 +: 32
                                        ] <= mem_rsp_read_data;
                                    PHASE_E_OP_ARGMAX:
                                        argmax_input_data <=
                                            mem_rsp_read_data;
                                    default: begin
                                    end
                                endcase

                                if ((mem_word_index + 1) >= read_word_count)
                                    mem_state <= MEM_READ_DELIVER;
                                else begin
                                    mem_word_index <= mem_word_index + 1'b1;
                                    mem_state <= MEM_READ_SELECT;
                                end
                            end
                        end
                    end

                    MEM_CACHE_RESPONSE: begin
                        if (gemm_a_cache_read_data_valid) begin
                            gemm_activation_data[
                                mem_word_index*32 +: 32
                            ] <= gemm_a_cache_read_data;

                            if ((mem_word_index + 1) >= read_word_count)
                                mem_state <= MEM_READ_DELIVER;
                            else begin
                                mem_word_index <= mem_word_index + 1'b1;
                                mem_state <= MEM_READ_SELECT;
                            end
                        end else if (gemm_bias_cache_read_data_valid) begin
                            gemm_bias_data[
                                (mem_word_index_u32 -
                                 gemm_bias_word_base_u32)*32 +: 32
                            ] <= gemm_bias_cache_read_data;

                            if ((mem_word_index + 1) >= read_word_count)
                                mem_state <= MEM_READ_DELIVER;
                            else begin
                                mem_word_index <= mem_word_index + 1'b1;
                                mem_state <= MEM_READ_SELECT;
                            end
                        end
                    end

                    MEM_READ_DELIVER: begin
                        if (
                            (active_cmd.header.opcode == PHASE_E_OP_GEMM) &&
                            gemm_a_cache_allowed &&
                            (gemm_output_base == 0) &&
                            gemm_a_cache_tag_match &&
                            (({1'b0, gemm_k_base} +
                              GEMM_PE_LANES_WIDE) >=
                             {1'b0, active_cmd.dim2})
                        )
                            gemm_a_cache_valid <= 1'b1;
                        gemm_a_vector_request_active_q <= 1'b0;
                        mem_state <= MEM_IDLE;
                    end

                    MEM_GEMM_A_VECTOR_PRIME: begin
                        if (!gemm_a_vector_lane_valid) begin
                            // K-tail lanes were zeroed on entry; continue at
                            // the first packed-B logical word.
                            mem_word_index <= 16'(GEMM_A_WORDS);
                            mem_state <= MEM_READ_SELECT;
                        end else begin
                            gemm_a_vector_response_lane_q <=
                                gemm_a_vector_issue_lane_q;
                            if ((gemm_a_vector_issue_lane_q + 1'b1 >=
                                 PE_LANES) ||
                                (({1'b0, gemm_a_vector_k_q} +
                                  {28'd0,
                                   gemm_a_vector_issue_lane_q} + 1'b1) >=
                                 {1'b0, active_cmd.dim2})) begin
                                mem_state <= MEM_GEMM_A_VECTOR_DRAIN;
                            end else begin
                                gemm_a_vector_issue_lane_q <=
                                    gemm_a_vector_issue_lane_q + 1'b1;
                                mem_state <= MEM_GEMM_A_VECTOR_RUN;
                            end
                        end
                    end

                    MEM_GEMM_A_VECTOR_RUN: begin
                        if (gemm_a_vector_response_error) begin
                            memory_error_latched <= 1'b1;
                            gemm_a_cache_valid <= 1'b0;
                            gemm_a_vector_request_active_q <= 1'b0;
                            mem_state <= MEM_IDLE;
                        end else begin
                            for (gemm_a_vector_capture_row = 0;
                                 gemm_a_vector_capture_row < ARRAY_ROWS;
                                 gemm_a_vector_capture_row =
                                     gemm_a_vector_capture_row + 1)
                                if (gemm_a_vector_row_valid_q[
                                    gemm_a_vector_capture_row
                                ])
                                    gemm_activation_data[
                                        (gemm_a_vector_capture_row*PE_LANES +
                                         gemm_a_vector_response_lane_q)*32
                                        +: 32
                                    ] <= gemm_a_cache_vector_read_data[
                                        gemm_a_vector_capture_row*32 +: 32
                                    ];
                            gemm_a_vector_response_lane_q <=
                                gemm_a_vector_issue_lane_q;
                            if ((gemm_a_vector_issue_lane_q + 1'b1 >=
                                 PE_LANES) ||
                                (({1'b0, gemm_a_vector_k_q} +
                                  {28'd0,
                                   gemm_a_vector_issue_lane_q} + 1'b1) >=
                                 {1'b0, active_cmd.dim2})) begin
                                mem_state <= MEM_GEMM_A_VECTOR_DRAIN;
                            end else begin
                                gemm_a_vector_issue_lane_q <=
                                    gemm_a_vector_issue_lane_q + 1'b1;
                            end
                        end
                    end

                    MEM_GEMM_A_VECTOR_DRAIN: begin
                        if (gemm_a_vector_response_error) begin
                            memory_error_latched <= 1'b1;
                            gemm_a_cache_valid <= 1'b0;
                            gemm_a_vector_request_active_q <= 1'b0;
                            mem_state <= MEM_IDLE;
                        end else begin
                            for (gemm_a_vector_capture_row = 0;
                                 gemm_a_vector_capture_row < ARRAY_ROWS;
                                 gemm_a_vector_capture_row =
                                     gemm_a_vector_capture_row + 1)
                                if (gemm_a_vector_row_valid_q[
                                    gemm_a_vector_capture_row
                                ])
                                    gemm_activation_data[
                                        (gemm_a_vector_capture_row*PE_LANES +
                                         gemm_a_vector_response_lane_q)*32
                                        +: 32
                                    ] <= gemm_a_cache_vector_read_data[
                                        gemm_a_vector_capture_row*32 +: 32
                                    ];
                            mem_word_index <= 16'(GEMM_A_WORDS);
                            mem_state <= MEM_READ_SELECT;
                        end
                    end

                    MEM_WRITE_SELECT: begin
                        if (write_candidate_needed &&
                            write_candidate_address_overflow) begin
                            memory_error_latched <= 1'b1;
                            mem_state <= MEM_IDLE;
                        end else if (!write_candidate_needed) begin
                            if ((mem_word_index + 1) >= write_word_count)
                                mem_state <= MEM_WRITE_DELIVER;
                            else
                                mem_word_index <= mem_word_index + 1'b1;
                        end else begin
                            mem_state <= MEM_WRITE_REQUEST;
                        end
                    end

                    MEM_WRITE_REQUEST: begin
                        if (mem_req_valid && mem_req_ready)
                            mem_state <= MEM_WRITE_RESPONSE;
                    end

                    MEM_WRITE_RESPONSE: begin
                        if (mem_rsp_valid && mem_rsp_ready) begin
                            if (mem_rsp_error) begin
                                memory_error_latched <= 1'b1;
                                mem_state <= MEM_IDLE;
                            end else begin
                                if ((mem_word_index + 1) >= write_word_count)
                                    mem_state <= MEM_WRITE_DELIVER;
                                else begin
                                    mem_word_index <= mem_word_index + 1'b1;
                                    mem_state <= MEM_WRITE_SELECT;
                                end
                            end
                        end
                    end

                    MEM_WRITE_DELIVER: begin
                        if (
                            (active_cmd.header.opcode == PHASE_E_OP_GEMM) &&
                            gemm_bias_cache_allowed &&
                            !gemm_bias_cache_valid &&
                            (gemm_result_batch_index_store_q == 0) &&
                            (gemm_result_token_base_store_q == 0) &&
                            (({1'b0, gemm_result_output_base_store_q} +
                              33'(ARRAY_COLS)) >=
                             {1'b0, active_cmd.dim3})
                        )
                            gemm_bias_cache_valid <= 1'b1;
                        mem_state <= MEM_IDLE;
                    end

                    default:
                        mem_state <= MEM_IDLE;
                endcase
            end
        end
    end

endmodule
