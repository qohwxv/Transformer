`timescale 1ns/1ps

// Standalone integration test for the synthesizable GEMM path:
//
//   command controller -> GEMM controller/PE array
//     -> memory frontend -> read/write address routers
//
// The logical memory model deliberately applies request backpressure and
// delayed responses.  A transaction scoreboard checks the complete read/write
// sequence independently from the DUT address routers.
module tb_vit_phase_e_engine_gemm_memory #(
    parameter integer ARRAY_ROWS = 2,
    parameter integer ARRAY_COLS = 2
);

    import vit_phase_e_pkg::*;
    import vit_fp32_pkg::*;

    localparam integer PE_LANES         = 16;
    localparam integer VECTOR_LANES     = 16;
    localparam integer GEMM_A_CACHE_DEPTH_WORDS = 17;
    localparam integer GEMM_BIAS_CACHE_DEPTH_WORDS = 17;
    localparam integer MEMORY_WORDS     = 2048;
    localparam integer MAX_TRANSACTIONS = 1024;

    localparam integer TEST_NONE     = 0;
    localparam integer TEST_BIAS_ON  = 1;
    localparam integer TEST_BIAS_OFF = 2;

    localparam logic [31:0] FP32_SENTINEL = 32'hdead_beef;
    localparam logic [31:0] FP32_POISON   = 32'h7fc0_0000;

    logic clk = 1'b0;
    logic rst = 1'b1;

    logic cmd_valid = 1'b0;
    logic cmd_ready;
    phase_e_cmd_t cmd = '0;
    logic cmd_done;
    logic cmd_error;
    logic busy;

    logic parameter_request;
    logic parameter_ready = 1'b1;
    phase_e_cmd_t parameter_command;

    logic mem_req_valid;
    logic mem_req_ready;
    logic mem_req_write;
    phase_e_mem_space_t mem_req_space;
    logic [31:0] mem_req_word_address;
    logic [31:0] mem_req_write_data;
    logic [3:0] mem_req_write_strobe;
    logic mem_rsp_valid = 1'b0;
    logic mem_rsp_ready;
    logic [31:0] mem_rsp_read_data = 32'd0;
    logic mem_rsp_error = 1'b0;

    logic [31:0] scratch_read_data;
    logic class_result_valid;
    logic [31:0] class_index;
    logic [31:0] class_logit;

    logic [31:0] scratch_memory [0:MEMORY_WORDS-1];
    logic [31:0] input_memory   [0:MEMORY_WORDS-1];
    logic [31:0] param_memory   [0:MEMORY_WORDS-1];

    logic        expected_write      [0:MAX_TRANSACTIONS-1];
    logic [1:0]  expected_space      [0:MAX_TRANSACTIONS-1];
    logic [31:0] expected_address    [0:MAX_TRANSACTIONS-1];
    logic [31:0] expected_write_data [0:MAX_TRANSACTIONS-1];

    integer expected_count = 0;
    integer expected_read_count = 0;
    integer expected_write_count = 0;
    integer combined_expected_transactions = 0;
    integer transaction_index = 0;
    integer accepted_transactions = 0;
    integer checks = 0;
    integer failures = 0;
    integer current_test = TEST_NONE;
    integer cycle_count = 0;
    integer parameter_request_pulses = 0;

    logic memory_pending = 1'b0;
    logic pending_write = 1'b0;
    logic [1:0] pending_space = PHASE_E_MEM_NONE;
    logic [31:0] pending_address = 32'd0;
    logic [31:0] pending_write_data = 32'd0;
    logic [3:0] pending_write_strobe = 4'd0;
    logic [31:0] pending_read_data = 32'd0;
    integer pending_delay = 0;

    logic stalled_request = 1'b0;
    logic stalled_write = 1'b0;
    logic [1:0] stalled_space = PHASE_E_MEM_NONE;
    logic [31:0] stalled_address = 32'd0;
    logic [31:0] stalled_data = 32'd0;
    logic [3:0] stalled_strobe = 4'd0;

    phase_e_cmd_t test_command;
    integer initialize_index;

    always #5 clk = ~clk;

    // Deterministic request backpressure. The memory still supports exactly
    // one outstanding logical transaction, matching the engine contract.
    assign mem_req_ready =
        !memory_pending && !mem_rsp_valid && ((cycle_count % 5) != 2);

    vit_phase_e_engine_top #(
        .ARRAY_ROWS   (ARRAY_ROWS),
        .ARRAY_COLS   (ARRAY_COLS),
        .PE_LANES     (PE_LANES),
        .VECTOR_LANES (VECTOR_LANES),
        .GEMM_A_CACHE_DEPTH_WORDS(GEMM_A_CACHE_DEPTH_WORDS),
        .GEMM_BIAS_CACHE_DEPTH_WORDS(GEMM_BIAS_CACHE_DEPTH_WORDS),
        .SCRATCH_WORDS(MEMORY_WORDS),
        .INPUT_WORDS  (MEMORY_WORDS),
        .PARAM_WORDS  (MEMORY_WORDS)
    ) dut (
        .clk                    (clk),
        .rst                    (rst),
        .cmd_valid              (cmd_valid),
        .cmd_ready              (cmd_ready),
        .cmd                    (cmd),
        .cmd_done               (cmd_done),
        .cmd_error              (cmd_error),
        .busy                   (busy),
        .parameter_request      (parameter_request),
        .parameter_ready        (parameter_ready),
        .parameter_command      (parameter_command),
        .mem_req_valid          (mem_req_valid),
        .mem_req_ready          (mem_req_ready),
        .mem_req_write          (mem_req_write),
        .mem_req_space          (mem_req_space),
        .mem_req_word_address   (mem_req_word_address),
        .mem_req_write_data     (mem_req_write_data),
        .mem_req_write_strobe   (mem_req_write_strobe),
        .mem_rsp_valid          (mem_rsp_valid),
        .mem_rsp_ready          (mem_rsp_ready),
        .mem_rsp_read_data      (mem_rsp_read_data),
        .mem_rsp_error          (mem_rsp_error),
        .input_write_enable     (1'b0),
        .input_write_address    (32'd0),
        .input_write_data       (32'd0),
        .parameter_write_enable (1'b0),
        .parameter_write_address(32'd0),
        .parameter_write_data   (32'd0),
        .scratch_write_enable   (1'b0),
        .scratch_write_address  (32'd0),
        .scratch_write_data     (32'd0),
        .scratch_read_address   (32'd0),
        .scratch_read_data      (scratch_read_data),
        .class_result_valid     (class_result_valid),
        .class_index            (class_index),
        .class_logit            (class_logit)
    );

    task automatic check(
        input logic condition,
        input string message
    );
        begin
            checks = checks + 1;
            if (!condition) begin
                failures = failures + 1;
                $error(
                    "CHECK FAILED test=%0d transaction=%0d: %s",
                    current_test,
                    transaction_index,
                    message
                );
            end
        end
    endtask

    function automatic logic [31:0] activation_word(
        input integer test_id,
        input integer batch_id,
        input integer row_id,
        input integer reduction_id
    );
        integer value;
        begin
            value = 0;
            case (test_id)
                TEST_BIAS_ON:
                    value = batch_id + row_id + 1;
                TEST_BIAS_OFF:
                    value = batch_id + row_id + 2;
                default:
                    value = 0;
            endcase
            // reduction_id is intentionally present in the address pattern,
            // while the exact integer value keeps the FP32 golden model simple.
            if (reduction_id < 0)
                value = 0;
            activation_word = fp32_from_u32_synth(value);
        end
    endfunction

    function automatic logic [31:0] weight_word(
        input integer test_id,
        input integer batch_id,
        input integer reduction_id,
        input integer column_id
    );
        integer value;
        begin
            value = 0;
            case (test_id)
                TEST_BIAS_ON,
                TEST_BIAS_OFF:
                    value = batch_id + column_id + 1;
                default:
                    value = 0;
            endcase
            if (reduction_id < 0)
                value = 0;
            weight_word = fp32_from_u32_synth(value);
        end
    endfunction

    function automatic logic [31:0] bias_word(
        input integer test_id,
        input integer column_id
    );
        integer value;
        begin
            value = (test_id == TEST_BIAS_ON) ? (column_id + 1) : 0;
            bias_word = fp32_from_u32_synth(value);
        end
    endfunction

    function automatic logic [31:0] expected_result_word(
        input integer test_id,
        input integer batch_id,
        input integer row_id,
        input integer column_id
    );
        integer integer_result;
        begin
            integer_result = 0;
            case (test_id)
                TEST_BIAS_ON: begin
                    integer_result =
                        test_command.dim2 *
                        (batch_id + row_id + 1) *
                        (batch_id + column_id + 1) +
                        column_id + 1;
                end

                TEST_BIAS_OFF: begin
                    integer_result =
                        test_command.dim2 *
                        (batch_id + row_id + 2) *
                        (batch_id + column_id + 1);
                end

                default:
                    integer_result = 0;
            endcase
            expected_result_word =
                fp32_from_u32_synth(integer_result);
        end
    endfunction

    function automatic logic [31:0] read_logical_memory(
        input logic [1:0] space,
        input logic [31:0] address
    );
        begin
            if (address >= MEMORY_WORDS) begin
                read_logical_memory = FP32_POISON;
            end else begin
                case (space)
                    PHASE_E_MEM_SCRATCH:
                        read_logical_memory = scratch_memory[address];
                    PHASE_E_MEM_INPUT:
                        read_logical_memory = input_memory[address];
                    PHASE_E_MEM_PARAM:
                        read_logical_memory = param_memory[address];
                    default:
                        read_logical_memory = FP32_POISON;
                endcase
            end
        end
    endfunction

    task automatic write_logical_memory(
        input logic [1:0] space,
        input logic [31:0] address,
        input logic [31:0] value,
        input logic [3:0] strobe
    );
        begin
            if (address >= MEMORY_WORDS) begin
                $fatal(1, "test memory write address out of range: %0d", address);
            end else begin
                case (space)
                    PHASE_E_MEM_SCRATCH: begin
                        if (strobe[0])
                            scratch_memory[address][7:0] = value[7:0];
                        if (strobe[1])
                            scratch_memory[address][15:8] = value[15:8];
                        if (strobe[2])
                            scratch_memory[address][23:16] = value[23:16];
                        if (strobe[3])
                            scratch_memory[address][31:24] = value[31:24];
                    end

                    PHASE_E_MEM_INPUT: begin
                        if (strobe[0])
                            input_memory[address][7:0] = value[7:0];
                        if (strobe[1])
                            input_memory[address][15:8] = value[15:8];
                        if (strobe[2])
                            input_memory[address][23:16] = value[23:16];
                        if (strobe[3])
                            input_memory[address][31:24] = value[31:24];
                    end

                    PHASE_E_MEM_PARAM: begin
                        if (strobe[0])
                            param_memory[address][7:0] = value[7:0];
                        if (strobe[1])
                            param_memory[address][15:8] = value[15:8];
                        if (strobe[2])
                            param_memory[address][23:16] = value[23:16];
                        if (strobe[3])
                            param_memory[address][31:24] = value[31:24];
                    end

                    default:
                        $fatal(1, "write targeted PHASE_E_MEM_NONE");
                endcase
            end
        end
    endtask

    task automatic set_logical_word(
        input logic [1:0] space,
        input logic [31:0] address,
        input logic [31:0] value
    );
        begin
            write_logical_memory(space, address, value, 4'hf);
        end
    endtask

    task automatic append_expected(
        input logic is_write,
        input logic [1:0] space,
        input logic [31:0] address,
        input logic [31:0] write_data
    );
        begin
            if (expected_count >= MAX_TRANSACTIONS)
                $fatal(1, "expected transaction array overflow");

            expected_write[expected_count] = is_write;
            expected_space[expected_count] = space;
            expected_address[expected_count] = address;
            expected_write_data[expected_count] = write_data;
            expected_count = expected_count + 1;

            if (is_write)
                expected_write_count = expected_write_count + 1;
            else
                expected_read_count = expected_read_count + 1;
        end
    endtask

    task automatic build_expected_transactions(
        input integer test_id,
        input phase_e_cmd_t command_value
    );
        integer batch_id;
        integer token_base;
        integer output_base;
        integer reduction_base;
        integer row_id;
        integer column_id;
        integer lane_id;
        integer row_absolute;
        integer column_absolute;
        integer reduction_absolute;
        logic [31:0] address;
        begin
            expected_count = 0;
            expected_read_count = 0;
            expected_write_count = 0;
            transaction_index = 0;

            for (batch_id = 0;
                 batch_id < command_value.dim0;
                 batch_id = batch_id + 1) begin
                for (token_base = 0;
                     token_base < command_value.dim1;
                     token_base = token_base + ARRAY_ROWS) begin
                    for (output_base = 0;
                         output_base < command_value.dim3;
                         output_base = output_base + ARRAY_COLS) begin
                        for (reduction_base = 0;
                             reduction_base < command_value.dim2;
                             reduction_base =
                                 reduction_base + PE_LANES) begin
                            // A slots: row-major, then reduction lane.
                            for (row_id = 0;
                                 row_id < ARRAY_ROWS;
                                 row_id = row_id + 1) begin
                                for (lane_id = 0;
                                     lane_id < PE_LANES;
                                     lane_id = lane_id + 1) begin
                                    row_absolute = token_base + row_id;
                                    reduction_absolute =
                                        reduction_base + lane_id;
                                    if ((row_absolute < command_value.dim1) &&
                                        (reduction_absolute <
                                         command_value.dim2) &&
                                        ((((command_value.header.flags &
                                            PHASE_E_FLAG_GEMM_CACHE_SAFE) ==
                                           0)) ||
                                         (command_value.dim2 >
                                          GEMM_A_CACHE_DEPTH_WORDS) ||
                                         (output_base == 0))) begin
                                        address =
                                            command_value.src0_base +
                                            batch_id *
                                                command_value.stride0 +
                                            row_absolute *
                                                command_value.stride1 +
                                            reduction_absolute;
                                        append_expected(
                                            1'b0,
                                            command_value.route.src0_space,
                                            address,
                                            32'd0
                                        );
                                    end
                                end
                            end

                            // B slots: column-major, then reduction lane.
                            for (column_id = 0;
                                 column_id < ARRAY_COLS;
                                 column_id = column_id + 1) begin
                                for (lane_id = 0;
                                     lane_id < PE_LANES;
                                     lane_id = lane_id + 1) begin
                                    column_absolute =
                                        output_base + column_id;
                                    reduction_absolute =
                                        reduction_base + lane_id;
                                    if ((column_absolute <
                                         command_value.dim3) &&
                                        (reduction_absolute <
                                         command_value.dim2)) begin
                                        address =
                                            command_value.src1_base +
                                            batch_id *
                                                command_value.stride2 +
                                            reduction_absolute *
                                                command_value.stride3 +
                                            column_absolute;
                                        append_expected(
                                            1'b0,
                                            command_value.route.src1_space,
                                            address,
                                            32'd0
                                        );
                                    end
                                end
                            end

                            // Bias slots are real transactions only on the
                            // final K chunk when the descriptor enables bias.
                            if (command_value.header.flags[0] &&
                                ((reduction_base + PE_LANES) >=
                                 command_value.dim2) &&
                                !(
                                    ((command_value.header.flags &
                                      PHASE_E_FLAG_GEMM_CACHE_SAFE) != 0) &&
                                    (command_value.dim3 <=
                                     GEMM_BIAS_CACHE_DEPTH_WORDS) &&
                                    ((batch_id != 0) || (token_base != 0))
                                )) begin
                                for (column_id = 0;
                                     column_id < ARRAY_COLS;
                                     column_id = column_id + 1) begin
                                    column_absolute =
                                        output_base + column_id;
                                    if (column_absolute <
                                        command_value.dim3) begin
                                        address =
                                            command_value.src2_base +
                                            column_absolute;
                                        append_expected(
                                            1'b0,
                                            command_value.route.src2_space,
                                            address,
                                            32'd0
                                        );
                                    end
                                end
                            end
                        end

                        // C slots: row-major output tile.
                        for (row_id = 0;
                             row_id < ARRAY_ROWS;
                             row_id = row_id + 1) begin
                            for (column_id = 0;
                                 column_id < ARRAY_COLS;
                                 column_id = column_id + 1) begin
                                row_absolute = token_base + row_id;
                                column_absolute =
                                    output_base + column_id;
                                if ((row_absolute <
                                     command_value.dim1) &&
                                    (column_absolute <
                                     command_value.dim3)) begin
                                    address =
                                        command_value.dst_base +
                                        batch_id *
                                            command_value.stride4 +
                                        row_absolute *
                                            command_value.immediate +
                                        column_absolute;
                                    append_expected(
                                        1'b1,
                                        command_value.route.dst_space,
                                        address,
                                        expected_result_word(
                                            test_id,
                                            batch_id,
                                            row_absolute,
                                            column_absolute
                                        )
                                    );
                                end
                            end
                        end
                    end
                end
            end
        end
    endtask

    task automatic prepare_case_memory(
        input integer test_id,
        input phase_e_cmd_t command_value
    );
        integer batch_id;
        integer row_id;
        integer column_id;
        integer reduction_id;
        integer clear_offset;
        logic [31:0] address;
        begin
            // Initialize the whole destination allocation, including every
            // row/batch padding word, to a recognizable untouched sentinel.
            for (batch_id = 0;
                 batch_id < command_value.dim0;
                 batch_id = batch_id + 1) begin
                for (clear_offset = 0;
                     clear_offset < command_value.stride4;
                     clear_offset = clear_offset + 1) begin
                    address =
                        command_value.dst_base +
                        batch_id * command_value.stride4 +
                        clear_offset;
                    set_logical_word(
                        command_value.route.dst_space,
                        address,
                        FP32_SENTINEL
                    );
                end
            end

            for (batch_id = 0;
                 batch_id < command_value.dim0;
                 batch_id = batch_id + 1) begin
                for (row_id = 0;
                     row_id < command_value.dim1;
                     row_id = row_id + 1) begin
                    for (reduction_id = 0;
                         reduction_id < command_value.dim2;
                         reduction_id = reduction_id + 1) begin
                        address =
                            command_value.src0_base +
                            batch_id * command_value.stride0 +
                            row_id * command_value.stride1 +
                            reduction_id;
                        set_logical_word(
                            command_value.route.src0_space,
                            address,
                            activation_word(
                                test_id,
                                batch_id,
                                row_id,
                                reduction_id
                            )
                        );
                    end
                end

                for (reduction_id = 0;
                     reduction_id < command_value.dim2;
                     reduction_id = reduction_id + 1) begin
                    for (column_id = 0;
                         column_id < command_value.dim3;
                         column_id = column_id + 1) begin
                        address =
                            command_value.src1_base +
                            batch_id * command_value.stride2 +
                            reduction_id * command_value.stride3 +
                            column_id;
                        set_logical_word(
                            command_value.route.src1_space,
                            address,
                            weight_word(
                                test_id,
                                batch_id,
                                reduction_id,
                                column_id
                            )
                        );
                    end
                end
            end

            if (command_value.header.flags[0]) begin
                for (column_id = 0;
                     column_id < command_value.dim3;
                     column_id = column_id + 1) begin
                    address =
                        command_value.src2_base + column_id;
                    set_logical_word(
                        command_value.route.src2_space,
                        address,
                        bias_word(test_id, column_id)
                    );
                end
            end else begin
                // A disabled/none bias route must never be accessed.
                scratch_memory[command_value.src2_base] = FP32_POISON;
                input_memory[command_value.src2_base] = FP32_POISON;
                param_memory[command_value.src2_base] = FP32_POISON;
            end
        end
    endtask

    task automatic check_accepted_request;
        integer expected_index;
        begin
            expected_index = transaction_index;
            check(
                current_test != TEST_NONE,
                "memory transaction occurred outside an active test"
            );
            check(
                expected_index < expected_count,
                "DUT emitted more transactions than expected"
            );

            if (expected_index < expected_count) begin
                check(
                    mem_req_write === expected_write[expected_index],
                    "request direction/order"
                );
                check(
                    mem_req_space === expected_space[expected_index],
                    "request memory space"
                );
                check(
                    mem_req_word_address ===
                        expected_address[expected_index],
                    "request logical word address"
                );
                if (expected_write[expected_index]) begin
                    check(
                        mem_req_write_strobe === 4'hf,
                        "GEMM uses full-word writes"
                    );
                    check(
                        mem_req_write_data ===
                            expected_write_data[expected_index],
                        "GEMM write data"
                    );
                end
            end

            transaction_index = transaction_index + 1;
        end
    endtask

    task automatic issue_command(
        input phase_e_cmd_t command_value
    );
        begin
            @(negedge clk);
            cmd = command_value;
            cmd_valid = 1'b1;
            while (!cmd_ready)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            cmd_valid = 1'b0;
        end
    endtask

    task automatic wait_for_success(
        input integer timeout_cycles,
        output integer profiled_total_cycles,
        output integer profiled_external_cycles,
        output integer profiled_cache_cycles,
        output integer profiled_frontend_cycles,
        output integer profiled_compute_cycles,
        output integer profiled_control_cycles
    );
        integer wait_cycles;
        logic completion_seen;
        begin
            wait_cycles = 0;
            completion_seen = 1'b0;
            profiled_total_cycles = 0;
            profiled_external_cycles = 0;
            profiled_cache_cycles = 0;
            profiled_frontend_cycles = 0;
            profiled_compute_cycles = 0;
            profiled_control_cycles = 0;
            while (!completion_seen &&
                   (wait_cycles < timeout_cycles)) begin
                @(posedge clk);
                #1;

                profiled_total_cycles =
                    profiled_total_cycles + 1;
                if (mem_req_valid || memory_pending || mem_rsp_valid)
                    profiled_external_cycles =
                        profiled_external_cycles + 1;
                else if (dut.mem_state == 4)
                    // MEM_CACHE_RESPONSE in the production frontend.
                    profiled_cache_cycles =
                        profiled_cache_cycles + 1;
                else if (dut.mem_state != 0)
                    profiled_frontend_cycles =
                        profiled_frontend_cycles + 1;
                else if (dut.gemm_busy)
                    profiled_compute_cycles =
                        profiled_compute_cycles + 1;
                else
                    profiled_control_cycles =
                        profiled_control_cycles + 1;

                if (cmd_done || cmd_error)
                    completion_seen = 1'b1;
                wait_cycles = wait_cycles + 1;
            end

            check(completion_seen, "command completed before timeout");
            check(cmd_done, "valid GEMM reports cmd_done");
            check(!cmd_error, "valid GEMM does not report cmd_error");
            check(
                transaction_index == expected_count,
                "observed exactly the expected transaction count"
            );
            check(!memory_pending, "no logical transaction pending at done");
            check(!mem_rsp_valid, "no logical response pending at done");

            @(posedge clk);
            #1;
            check(
                !cmd_done && !cmd_error,
                "completion indication is a one-cycle pulse"
            );
        end
    endtask

    task automatic verify_case_memory(
        input integer test_id,
        input phase_e_cmd_t command_value
    );
        integer batch_id;
        integer row_id;
        integer column_id;
        integer padding_id;
        logic [31:0] address;
        logic [31:0] observed;
        logic [31:0] expected;
        begin
            for (batch_id = 0;
                 batch_id < command_value.dim0;
                 batch_id = batch_id + 1) begin
                for (row_id = 0;
                     row_id < command_value.dim1;
                     row_id = row_id + 1) begin
                    for (column_id = 0;
                         column_id < command_value.dim3;
                         column_id = column_id + 1) begin
                        address =
                            command_value.dst_base +
                            batch_id * command_value.stride4 +
                            row_id * command_value.immediate +
                            column_id;
                        observed = read_logical_memory(
                            command_value.route.dst_space,
                            address
                        );
                        expected = expected_result_word(
                            test_id,
                            batch_id,
                            row_id,
                            column_id
                        );
                        check(
                            observed === expected,
                            "destination matrix value"
                        );
                    end

                    for (padding_id = command_value.dim3;
                         padding_id < command_value.immediate;
                         padding_id = padding_id + 1) begin
                        address =
                            command_value.dst_base +
                            batch_id * command_value.stride4 +
                            row_id * command_value.immediate +
                            padding_id;
                        check(
                            read_logical_memory(
                                command_value.route.dst_space,
                                address
                            ) === FP32_SENTINEL,
                            "destination row padding remains untouched"
                        );
                    end
                end

                for (
                    padding_id =
                        command_value.dim1 * command_value.immediate;
                    padding_id < command_value.stride4;
                    padding_id = padding_id + 1
                ) begin
                    address =
                        command_value.dst_base +
                        batch_id * command_value.stride4 +
                        padding_id;
                    check(
                        read_logical_memory(
                            command_value.route.dst_space,
                            address
                        ) === FP32_SENTINEL,
                        "destination batch padding remains untouched"
                    );
                end
            end
        end
    endtask

    task automatic run_case(
        input integer test_id,
        input phase_e_cmd_t command_value,
        input integer exact_read_count,
        input integer exact_write_count
    );
        integer parameter_pulses_before;
        integer profile_total_cycles;
        integer profile_external_cycles;
        integer profile_cache_cycles;
        integer profile_frontend_cycles;
        integer profile_compute_cycles;
        integer profile_control_cycles;
        begin
            current_test = test_id;
            parameter_pulses_before = parameter_request_pulses;
            build_expected_transactions(test_id, command_value);
            combined_expected_transactions =
                combined_expected_transactions + expected_count;
            prepare_case_memory(test_id, command_value);

            if ((ARRAY_ROWS == 2) && (ARRAY_COLS == 2)) begin
                check(
                    expected_read_count == exact_read_count,
                    "golden read transaction count"
                );
                check(
                    expected_write_count == exact_write_count,
                    "golden write transaction count"
                );
            end
            check(
                !memory_pending && !mem_rsp_valid,
                "memory model idle before command"
            );

            issue_command(command_value);
            wait_for_success(
                100000,
                profile_total_cycles,
                profile_external_cycles,
                profile_cache_cycles,
                profile_frontend_cycles,
                profile_compute_cycles,
                profile_control_cycles
            );
            verify_case_memory(test_id, command_value);

            if (
                (command_value.route.src0_space == PHASE_E_MEM_PARAM) ||
                (command_value.route.src1_space == PHASE_E_MEM_PARAM) ||
                (command_value.route.src2_space == PHASE_E_MEM_PARAM)
            ) begin
                check(
                    parameter_request_pulses >
                        parameter_pulses_before,
                    "parameter-backed GEMM requests parameter staging"
                );
            end else begin
                check(
                    parameter_request_pulses ==
                        parameter_pulses_before,
                    "non-parameter GEMM skips parameter staging"
                );
            end

            $display(
                "GEMM_ENGINE_MEMORY_CASE_PASS id=%0d reads=%0d writes=%0d total=%0d cycles=%0d external=%0d cache=%0d frontend=%0d compute=%0d control=%0d",
                test_id,
                expected_read_count,
                expected_write_count,
                expected_count,
                profile_total_cycles,
                profile_external_cycles,
                profile_cache_cycles,
                profile_frontend_cycles,
                profile_compute_cycles,
                profile_control_cycles
            );
            current_test = TEST_NONE;
        end
    endtask

    // One-outstanding logical memory with delayed responses.
    always @(posedge clk) begin
        if (rst) begin
            cycle_count <= 0;
            accepted_transactions <= 0;
            memory_pending <= 1'b0;
            pending_write <= 1'b0;
            pending_space <= PHASE_E_MEM_NONE;
            pending_address <= 32'd0;
            pending_write_data <= 32'd0;
            pending_write_strobe <= 4'd0;
            pending_read_data <= 32'd0;
            pending_delay <= 0;
            mem_rsp_valid <= 1'b0;
            mem_rsp_read_data <= 32'd0;
            mem_rsp_error <= 1'b0;
            parameter_request_pulses <= 0;
        end else begin
            cycle_count <= cycle_count + 1;

            if (parameter_request)
                parameter_request_pulses <=
                    parameter_request_pulses + 1;

            if (mem_req_valid && mem_req_ready) begin
                check_accepted_request();
                memory_pending <= 1'b1;
                pending_write <= mem_req_write;
                pending_space <= mem_req_space;
                pending_address <= mem_req_word_address;
                pending_write_data <= mem_req_write_data;
                pending_write_strobe <= mem_req_write_strobe;
                pending_read_data <= read_logical_memory(
                    mem_req_space,
                    mem_req_word_address
                );
                pending_delay <= (accepted_transactions % 3) + 1;
                accepted_transactions <= accepted_transactions + 1;
            end

            if (memory_pending && !mem_rsp_valid) begin
                if (pending_delay == 0) begin
                    mem_rsp_valid <= 1'b1;
                    mem_rsp_read_data <=
                        pending_write ? 32'd0 : pending_read_data;
                    mem_rsp_error <= 1'b0;
                end else begin
                    pending_delay <= pending_delay - 1;
                end
            end

            if (mem_rsp_valid && mem_rsp_ready) begin
                if (pending_write)
                    write_logical_memory(
                        pending_space,
                        pending_address,
                        pending_write_data,
                        pending_write_strobe
                    );
                memory_pending <= 1'b0;
                mem_rsp_valid <= 1'b0;
                mem_rsp_read_data <= 32'd0;
                mem_rsp_error <= 1'b0;
            end
        end
    end

    // Request payload must remain stable while the memory model withholds
    // READY.
    always @(posedge clk) begin
        if (rst) begin
            stalled_request <= 1'b0;
            stalled_write <= 1'b0;
            stalled_space <= PHASE_E_MEM_NONE;
            stalled_address <= 32'd0;
            stalled_data <= 32'd0;
            stalled_strobe <= 4'd0;
        end else if (mem_req_valid && !mem_req_ready) begin
            if (!stalled_request) begin
                stalled_request <= 1'b1;
                stalled_write <= mem_req_write;
                stalled_space <= mem_req_space;
                stalled_address <= mem_req_word_address;
                stalled_data <= mem_req_write_data;
                stalled_strobe <= mem_req_write_strobe;
            end else begin
                check(
                    mem_req_write === stalled_write,
                    "REQ_WRITE stable under backpressure"
                );
                check(
                    mem_req_space === stalled_space,
                    "REQ_SPACE stable under backpressure"
                );
                check(
                    mem_req_word_address === stalled_address,
                    "REQ address stable under backpressure"
                );
                check(
                    mem_req_write_data === stalled_data,
                    "REQ data stable under backpressure"
                );
                check(
                    mem_req_write_strobe === stalled_strobe,
                    "REQ strobe stable under backpressure"
                );
            end
        end else begin
            stalled_request <= 1'b0;
        end
    end

    initial begin
        for (initialize_index = 0;
             initialize_index < MEMORY_WORDS;
             initialize_index = initialize_index + 1) begin
            scratch_memory[initialize_index] = FP32_SENTINEL;
            input_memory[initialize_index] = FP32_SENTINEL;
            param_memory[initialize_index] = FP32_SENTINEL;
        end
        combined_expected_transactions = 0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // Case 1: two batches, every matrix uses a non-zero base and padded
        // row/batch stride, K/M/N all have tails, and bias is enabled.
        test_command = '0;
        test_command.header.opcode = PHASE_E_OP_GEMM;
        test_command.header.flags =
            PHASE_E_FLAG_BIAS_ENABLE |
            PHASE_E_FLAG_GEMM_CACHE_SAFE;
        test_command.route.src0_space = PHASE_E_MEM_INPUT;
        test_command.route.src1_space = PHASE_E_MEM_PARAM;
        test_command.route.src2_space = PHASE_E_MEM_PARAM;
        test_command.route.dst_space = PHASE_E_MEM_SCRATCH;
        test_command.src0_base = 32'd37;
        test_command.src1_base = 32'd113;
        test_command.src2_base = 32'd487;
        test_command.dst_base = 32'd701;
        test_command.dim0 = 32'd2;
        test_command.dim1 = 32'd3;
        test_command.dim2 = 32'd17;
        test_command.dim3 = 32'd3;
        test_command.stride0 = 32'd96;
        test_command.stride1 = 32'd24;
        test_command.stride2 = 32'd160;
        test_command.stride3 = 32'd8;
        test_command.stride4 = 32'd40;
        test_command.immediate = 32'd9;
        run_case(TEST_BIAS_ON, test_command, 309, 18);

        // Case 2: independent non-zero/padded regions, two batches, K and N
        // tails, and a disabled PHASE_E_MEM_NONE bias route.
        test_command = '0;
        test_command.header.opcode = PHASE_E_OP_GEMM;
        test_command.header.flags =
            PHASE_E_FLAG_GEMM_CACHE_SAFE;
        test_command.route.src0_space = PHASE_E_MEM_SCRATCH;
        test_command.route.src1_space = PHASE_E_MEM_INPUT;
        test_command.route.src2_space = PHASE_E_MEM_NONE;
        test_command.route.dst_space = PHASE_E_MEM_SCRATCH;
        test_command.src0_base = 32'd251;
        test_command.src1_base = 32'd631;
        test_command.src2_base = 32'd1300;
        test_command.dst_base = 32'd991;
        test_command.dim0 = 32'd2;
        test_command.dim1 = 32'd2;
        test_command.dim2 = 32'd4;
        test_command.dim3 = 32'd3;
        test_command.stride0 = 32'd32;
        test_command.stride1 = 32'd11;
        test_command.stride2 = 32'd48;
        test_command.stride3 = 32'd9;
        test_command.stride4 = 32'd24;
        test_command.immediate = 32'd8;
        run_case(TEST_BIAS_OFF, test_command, 40, 12);

        // Case 3: the descriptor opts in, but K exceeds this test instance's
        // panel-cache depth. All activation reads must fall back to memory.
        test_command = '0;
        test_command.header.opcode = PHASE_E_OP_GEMM;
        test_command.header.flags =
            PHASE_E_FLAG_GEMM_CACHE_SAFE;
        test_command.route.src0_space = PHASE_E_MEM_INPUT;
        test_command.route.src1_space = PHASE_E_MEM_PARAM;
        test_command.route.src2_space = PHASE_E_MEM_NONE;
        test_command.route.dst_space = PHASE_E_MEM_SCRATCH;
        test_command.src0_base = 32'd50;
        test_command.src1_base = 32'd900;
        test_command.src2_base = 32'd1400;
        test_command.dst_base = 32'd1500;
        test_command.dim0 = 32'd1;
        test_command.dim1 = 32'd1;
        test_command.dim2 = 32'd18;
        test_command.dim3 = 32'd3;
        test_command.stride0 = 32'd64;
        test_command.stride1 = 32'd23;
        test_command.stride2 = 32'd160;
        test_command.stride3 = 32'd7;
        test_command.stride4 = 32'd16;
        test_command.immediate = 32'd5;
        run_case(TEST_BIAS_OFF, test_command, 90, 3);

        // Case 4: K fits, but software did not assert CACHE_SAFE. Preserve the
        // original memory-visible behavior for potentially aliasing commands.
        test_command = '0;
        test_command.header.opcode = PHASE_E_OP_GEMM;
        test_command.header.flags = 8'd0;
        test_command.route.src0_space = PHASE_E_MEM_INPUT;
        test_command.route.src1_space = PHASE_E_MEM_PARAM;
        test_command.route.src2_space = PHASE_E_MEM_NONE;
        test_command.route.dst_space = PHASE_E_MEM_SCRATCH;
        test_command.src0_base = 32'd100;
        test_command.src1_base = 32'd1100;
        test_command.src2_base = 32'd1450;
        test_command.dst_base = 32'd1600;
        test_command.dim0 = 32'd1;
        test_command.dim1 = 32'd1;
        test_command.dim2 = 32'd4;
        test_command.dim3 = 32'd3;
        test_command.stride0 = 32'd16;
        test_command.stride1 = 32'd8;
        test_command.stride2 = 32'd32;
        test_command.stride3 = 32'd5;
        test_command.stride4 = 32'd8;
        test_command.immediate = 32'd4;
        run_case(TEST_BIAS_OFF, test_command, 20, 3);

        // Case 5: repeat case 4 with CACHE_SAFE asserted. This is a direct
        // A/B profile: dimensions, addresses and memory latency are identical;
        // only the four repeated activation reads move to the A-panel cache.
        test_command.header.flags =
            PHASE_E_FLAG_GEMM_CACHE_SAFE;
        run_case(TEST_BIAS_OFF, test_command, 16, 3);

        check(
            accepted_transactions == combined_expected_transactions,
            "combined accepted transaction count"
        );

        if (failures == 0) begin
            $display(
                "GEMM_ENGINE_MEMORY_PASS rows=%0d cols=%0d checks=%0d transactions=%0d",
                ARRAY_ROWS,
                ARRAY_COLS,
                checks,
                accepted_transactions
            );
        end else begin
            $fatal(
                1,
                "GEMM_ENGINE_MEMORY_FAIL checks=%0d failures=%0d",
                checks,
                failures
            );
        end

        $finish;
    end

    initial begin
        repeat (250000) @(posedge clk);
        $fatal(1, "Timeout in tb_vit_phase_e_engine_gemm_memory");
    end

endmodule
