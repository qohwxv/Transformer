`timescale 1ns/1ps

// Thin simulation probe around the production memory frontend.  The probe
// exposes only the existing internal cache eligibility/write signals; it does
// not replace any production logic.
module m4_frontend_boundary_probe #(
    parameter integer ARRAY_ROWS = 4
) (
    input  logic clk,
    input  logic rst,
    input  logic command_accept,
    input  logic execute,
    input  vit_phase_e_pkg::phase_e_cmd_t active_cmd,
    input  logic selected_data_request,
    input  logic mem_rsp_valid,
    input  logic [31:0] mem_rsp_read_data,

    output logic mem_req_valid,
    output logic mem_req_ready,
    output logic mem_rsp_ready,
    output logic gemm_data_valid,
    output logic profile_a_lookup,
    output logic profile_a_miss,
    output logic a_cache_allowed,
    output logic bias_cache_allowed,
    output logic a_cache_write_enable,
    output logic [31:0] a_cache_k_index
);

    import vit_phase_e_pkg::*;

    localparam integer ARRAY_COLS = 2;
    localparam integer PE_LANES = 16;
    localparam integer READ_WORD_COUNT =
        ARRAY_ROWS * PE_LANES + ARRAY_COLS * PE_LANES + ARRAY_COLS;

    logic mem_req_write;
    phase_e_mem_space_t mem_req_space;
    logic [31:0] mem_req_word_address;

    assign mem_req_ready = 1'b1;
    assign a_cache_allowed = u_frontend.gemm_a_cache_allowed;
    assign bias_cache_allowed = u_frontend.gemm_bias_cache_allowed;
    assign a_cache_write_enable = u_frontend.gemm_a_cache_write_enable;
    assign a_cache_k_index = u_frontend.gemm_a_cache_k_index;

    vit_phase_e_memory_frontend #(
        .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .PE_LANES(PE_LANES),
        .VECTOR_LANES(16),
        .GEMM_A_CACHE_DEPTH_WORDS(3072),
        .GEMM_BIAS_CACHE_DEPTH_WORDS(3072)
    ) u_frontend (
        .clk(clk),
        .rst(rst),
        .command_accept(command_accept),
        .execute(execute),
        .active_cmd(active_cmd),
        .selected_data_request(selected_data_request),
        .selected_result_valid(1'b0),
        .read_word_count(16'(READ_WORD_COUNT)),
        .write_word_count(16'(ARRAY_ROWS * ARRAY_COLS)),
        .memory_error_latched(),
        .debug_mem_state(),
        .profile_logical_read_word_o(),
        .profile_logical_write_word_o(),
        .profile_load_active_o(),
        .profile_store_active_o(),
        .profile_a_cache_lookup_o(profile_a_lookup),
        .profile_a_cache_hit_o(),
        .profile_a_cache_miss_o(profile_a_miss),
        .profile_bias_cache_lookup_o(),
        .profile_bias_cache_hit_o(),
        .profile_bias_cache_miss_o(),
        .profile_b_bypass_o(),
        .profile_frontend_error_o(),
        .profile_result_generation_error_o(),
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_req_write(mem_req_write),
        .mem_req_space(mem_req_space),
        .mem_req_word_address(mem_req_word_address),
        .mem_req_write_data(),
        .mem_req_write_strobe(),
        .mem_rsp_valid(mem_rsp_valid),
        .mem_rsp_ready(mem_rsp_ready),
        .mem_rsp_read_data(mem_rsp_read_data),
        .mem_rsp_error(1'b0),
        .gemm_token_base(32'd0),
        .gemm_output_base(32'd0),
        .gemm_k_base(32'd3056),
        .gemm_batch_index(32'd0),
        .gemm_activation_data(),
        .gemm_weight_data(),
        .gemm_bias_data(),
        .gemm_data_valid(gemm_data_valid),
        .gemm_result_address_base_current_o(),
        .gemm_result_address_base_store_i(66'd0),
        .gemm_result_generation_store_i(8'd0),
        .gemm_result_generation_expected_i(8'd0),
        .gemm_result_token_base_store_i(32'd0),
        .gemm_result_output_base_store_i(32'd0),
        .gemm_result_batch_index_store_i(32'd0),
        .gemm_result_token_mask('0),
        .gemm_result_output_mask('0),
        .gemm_result_data('0),
        .gemm_result_ready(),
        .vector_element_base(32'd0),
        .vector_input_a(),
        .vector_input_b(),
        .vector_data_valid(),
        .vector_result_base(32'd0),
        .vector_result_lane_mask('0),
        .vector_result_data('0),
        .vector_result_ready(),
        .layout_source_address(32'd0),
        .layout_source_data(),
        .layout_data_valid(),
        .layout_result_address(32'd0),
        .layout_result_data(32'd0),
        .layout_result_ready(),
        .ln_data_pass(2'd0),
        .ln_data_index(32'd0),
        .ln_data_channel_index(32'd0),
        .ln_input_data(),
        .ln_gamma_data(),
        .ln_beta_data(),
        .ln_input_valid(),
        .ln_result_index(32'd0),
        .ln_result_data(32'd0),
        .ln_result_ready(),
        .softmax_data_index(32'd0),
        .softmax_input_data(),
        .softmax_input_valid(),
        .softmax_result_index(32'd0),
        .softmax_result_data(32'd0),
        .softmax_result_ready(),
        .gelu_data_base_index(32'd0),
        .gelu_data_lane_mask('0),
        .gelu_input_data(),
        .gelu_input_valid(),
        .gelu_result_base_index(32'd0),
        .gelu_result_lane_mask('0),
        .gelu_result_data('0),
        .gelu_result_ready(),
        .argmax_element_index(32'd0),
        .argmax_input_data(),
        .argmax_data_valid(),
        .argmax_result_ready()
    );

endmodule

// Exact 3072/3073 cache-policy boundary test.  Each compile selects R4 or R8.
module tb_m4_frontend_cache_boundary #(
    parameter integer ARRAY_ROWS = 4
);

    import vit_phase_e_pkg::*;

    localparam integer ARRAY_COLS = 2;
    localparam integer PE_LANES = 16;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic command_accept = 1'b0;
    logic execute = 1'b1;
    phase_e_cmd_t cmd = '0;
    logic selected_data_request = 1'b0;
    logic mem_rsp_valid = 1'b1;
    logic [31:0] mem_rsp_read_data = 32'h3f80_0000;

    logic mem_req_valid;
    logic mem_req_ready;
    logic mem_rsp_ready;
    logic gemm_data_valid;
    logic profile_a_lookup;
    logic profile_a_miss;
    logic a_cache_allowed;
    logic bias_cache_allowed;
    logic a_cache_write_enable;
    logic [31:0] a_cache_k_index;

    integer checks = 0;
    integer physical_reads = 0;
    integer a_lookups = 0;
    integer a_misses = 0;
    integer a_writes = 0;
    integer max_written_k = -1;
    integer monitor_enable = 0;
    integer wait_cycles;

    always #5 clk = ~clk;

    m4_frontend_boundary_probe #(
        .ARRAY_ROWS(ARRAY_ROWS)
    ) u_probe (
        .clk(clk),
        .rst(rst),
        .command_accept(command_accept),
        .execute(execute),
        .active_cmd(cmd),
        .selected_data_request(selected_data_request),
        .mem_rsp_valid(mem_rsp_valid),
        .mem_rsp_read_data(mem_rsp_read_data),
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_rsp_ready(mem_rsp_ready),
        .gemm_data_valid(gemm_data_valid),
        .profile_a_lookup(profile_a_lookup),
        .profile_a_miss(profile_a_miss),
        .a_cache_allowed(a_cache_allowed),
        .bias_cache_allowed(bias_cache_allowed),
        .a_cache_write_enable(a_cache_write_enable),
        .a_cache_k_index(a_cache_k_index)
    );

    task automatic check_true(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1)
                $fatal(1, "M4 frontend boundary check failed: %s", message);
        end
    endtask

    task automatic set_dimensions(
        input logic [31:0] k_dimension,
        input logic [31:0] n_dimension,
        input logic [7:0] flags
    );
        begin
            cmd = '0;
            cmd.header.opcode = PHASE_E_OP_GEMM;
            cmd.header.flags = flags;
            cmd.route.src0_space = PHASE_E_MEM_INPUT;
            cmd.route.src1_space = PHASE_E_MEM_PARAM;
            cmd.route.src2_space = PHASE_E_MEM_PARAM;
            cmd.route.dst_space = PHASE_E_MEM_SCRATCH;
            cmd.dim0 = 32'd1;
            cmd.dim1 = 32'(ARRAY_ROWS);
            cmd.dim2 = k_dimension;
            cmd.dim3 = n_dimension;
            cmd.stride1 = k_dimension;
            cmd.stride3 = n_dimension;
            cmd.immediate = n_dimension;
            #1;
        end
    endtask

    task automatic pulse_command_clear;
        begin
            @(negedge clk);
            command_accept = 1'b1;
            @(posedge clk);
            #1;
            command_accept = 1'b0;
        end
    endtask

    task automatic run_last_k_chunk(
        input logic [31:0] k_dimension,
        input logic expected_cache_safe
    );
        integer expected_reads;
        begin
            set_dimensions(
                k_dimension,
                32'd3072,
                PHASE_E_FLAG_GEMM_CACHE_SAFE |
                PHASE_E_FLAG_BIAS_ENABLE
            );
            pulse_command_clear();

            physical_reads = 0;
            a_lookups = 0;
            a_misses = 0;
            a_writes = 0;
            max_written_k = -1;
            monitor_enable = 1;

            @(negedge clk);
            selected_data_request = 1'b1;
            @(posedge clk);
            #1;
            selected_data_request = 1'b0;

            wait_cycles = 0;
            while (!gemm_data_valid && (wait_cycles < 3000)) begin
                @(posedge clk);
                #1;
                wait_cycles = wait_cycles + 1;
            end
            check_true(gemm_data_valid, "gather did not reach data_valid");
            monitor_enable = 0;

            expected_reads = ARRAY_ROWS * PE_LANES + ARRAY_COLS * PE_LANES;
            if (k_dimension == 32'd3072)
                expected_reads = expected_reads + ARRAY_COLS;

            check_true(
                physical_reads == expected_reads,
                $sformatf(
                    "physical read count K=%0d got=%0d expected=%0d",
                    k_dimension,
                    physical_reads,
                    expected_reads
                )
            );
            check_true(
                a_lookups ==
                    (expected_cache_safe ? ARRAY_ROWS * PE_LANES : 0),
                $sformatf("A lookup count K=%0d got=%0d", k_dimension, a_lookups)
            );
            check_true(a_misses == a_lookups, "first-fill misses != lookups");
            check_true(
                a_writes ==
                    (expected_cache_safe ? ARRAY_ROWS * PE_LANES : 0),
                $sformatf("A write count K=%0d got=%0d", k_dimension, a_writes)
            );
            if (expected_cache_safe)
                check_true(
                    max_written_k == 3071,
                    $sformatf("last safe K index got=%0d", max_written_k)
                );
            else
                check_true(max_written_k == -1, "fallback wrote activation cache");

            // Let READ_DELIVER return to IDLE before the next command clear.
            @(posedge clk);
            #1;
        end
    endtask

    always @(posedge clk) begin
        if (monitor_enable != 0) begin
            if (mem_req_valid && mem_req_ready)
                physical_reads = physical_reads + 1;
            if (profile_a_lookup)
                a_lookups = a_lookups + 1;
            if (profile_a_miss)
                a_misses = a_misses + 1;
            if (a_cache_write_enable) begin
                a_writes = a_writes + 1;
                if ((max_written_k < 0) ||
                    (a_cache_k_index > 32'(max_written_k)))
                    max_written_k = a_cache_k_index;
            end
        end
    end

    initial begin
        if ((ARRAY_ROWS != 4) && (ARRAY_ROWS != 8))
            $fatal(1, "M4 boundary test supports only ARRAY_ROWS=4 or 8");

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // Both production cache dimensions accept exactly 3072 words.
        set_dimensions(
            32'd3072,
            32'd3072,
            PHASE_E_FLAG_GEMM_CACHE_SAFE | PHASE_E_FLAG_BIAS_ENABLE
        );
        check_true(a_cache_allowed, "K=3072 should allow activation cache");
        check_true(bias_cache_allowed, "N=3072 should allow bias cache");

        // 3073 must bypass rather than truncate a 32-bit index into the RAM.
        set_dimensions(
            32'd3073,
            32'd3072,
            PHASE_E_FLAG_GEMM_CACHE_SAFE | PHASE_E_FLAG_BIAS_ENABLE
        );
        check_true(!a_cache_allowed, "K=3073 must bypass activation cache");
        check_true(bias_cache_allowed, "K overflow must not disable safe bias");

        set_dimensions(
            32'd3072,
            32'd3073,
            PHASE_E_FLAG_GEMM_CACHE_SAFE | PHASE_E_FLAG_BIAS_ENABLE
        );
        check_true(a_cache_allowed, "N overflow must not disable safe A cache");
        check_true(!bias_cache_allowed, "N=3073 must bypass bias cache");

        set_dimensions(
            32'd3072,
            32'd3072,
            PHASE_E_FLAG_BIAS_ENABLE
        );
        check_true(!a_cache_allowed, "cache-safe flag is mandatory for A");
        check_true(!bias_cache_allowed, "cache-safe flag is mandatory for bias");

        set_dimensions(
            32'd3072,
            32'd3072,
            PHASE_E_FLAG_GEMM_CACHE_SAFE
        );
        check_true(a_cache_allowed, "A cache should not require bias enable");
        check_true(!bias_cache_allowed, "bias-enable flag is mandatory");

        // Dynamic gather checks prove that the safe final K16 chunk writes
        // through K=3071, while K=3073 takes the physical-read fallback and
        // never writes an aliased activation-cache entry.
        run_last_k_chunk(32'd3072, 1'b1);
        run_last_k_chunk(32'd3073, 1'b0);

        $display(
            {
                "PASS M4 frontend cache boundary: R=%0d checks=%0d ",
                "K/N=3072 safe K/N=3073 fallback max_k=3071"
            },
            ARRAY_ROWS,
            checks
        );
        $finish;
    end

    initial begin
        repeat (10000) @(posedge clk);
        $fatal(1, "Timeout in tb_m4_frontend_cache_boundary R=%0d", ARRAY_ROWS);
    end

endmodule
