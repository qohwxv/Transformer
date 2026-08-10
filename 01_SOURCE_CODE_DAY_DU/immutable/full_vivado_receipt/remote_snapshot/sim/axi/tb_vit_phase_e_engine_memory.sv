`timescale 1ns/1ps

// Self-checking test for the logical word request/response interface exposed by
// vit_phase_e_engine_top.  The memory model deliberately stalls both request
// acceptance and response production.  It supports one outstanding word,
// matching the engine/adapter contract.
module tb_vit_phase_e_engine_memory;

    import vit_phase_e_pkg::*;

    localparam integer MEMORY_WORDS = 512;

    localparam integer TEST_NONE    = 0;
    localparam integer TEST_VECTOR  = 1;
    localparam integer TEST_ARGMAX  = 2;
    localparam integer TEST_ERROR   = 3;
    localparam integer TEST_READ_ERROR = 4;
    localparam integer TEST_WRAP    = 5;
    localparam integer TEST_WRITE_WRAP = 6;

    localparam logic [31:0] VECTOR_A_BASE   = 32'd16;
    localparam logic [31:0] VECTOR_B_BASE   = 32'd64;
    localparam logic [31:0] VECTOR_DST_BASE = 32'd112;
    localparam logic [31:0] ARGMAX_BASE     = 32'd180;
    localparam logic [31:0] ERROR_A_BASE    = 32'd220;
    localparam logic [31:0] ERROR_B_BASE    = 32'd221;
    localparam logic [31:0] ERROR_DST_BASE  = 32'd222;
    localparam logic [31:0] READ_ERROR_A_BASE   = 32'd240;
    localparam logic [31:0] READ_ERROR_B_BASE   = 32'd241;
    localparam logic [31:0] READ_ERROR_DST_BASE = 32'd242;
    localparam logic [31:0] WRAP_A_BASE         = 32'hffff_ffff;
    localparam logic [31:0] WRAP_DST_BASE       = 32'd260;
    localparam logic [31:0] WRITE_WRAP_A_BASE   = 32'd270;
    localparam logic [31:0] WRITE_WRAP_B_BASE   = 32'd272;
    localparam logic [31:0] WRITE_WRAP_DST_BASE = 32'hffff_ffff;

    localparam logic [31:0] FP32_ONE        = 32'h3f80_0000;
    localparam logic [31:0] FP32_TWO        = 32'h4000_0000;
    localparam logic [31:0] FP32_THREE      = 32'h4040_0000;
    localparam logic [31:0] FP32_NEG_ONE    = 32'hbf80_0000;
    localparam logic [31:0] FP32_ONE_HALF   = 32'h3fc0_0000;
    localparam logic [31:0] FP32_SIX        = 32'h40c0_0000;
    localparam logic [31:0] FP32_SEVEN      = 32'h40e0_0000;
    localparam logic [31:0] FP32_SENTINEL   = 32'hdead_beef;

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

    logic [31:0] logical_memory [0:MEMORY_WORDS-1];

    integer checks = 0;
    integer failures = 0;
    integer current_test = TEST_NONE;
    integer cycle_count = 0;
    integer accepted_transactions = 0;
    integer read_requests = 0;
    integer write_requests = 0;
    integer class_result_pulses = 0;
    logic [31:0] captured_class_index = 32'd0;
    logic [31:0] captured_class_logit = 32'd0;
    logic last_write_response_seen = 1'b0;
    logic injected_error_response_seen = 1'b0;

    logic memory_pending = 1'b0;
    logic pending_write = 1'b0;
    logic [31:0] pending_address = 32'd0;
    logic [31:0] pending_write_data = 32'd0;
    logic [3:0] pending_write_strobe = 4'd0;
    logic [31:0] pending_read_data = 32'd0;
    logic pending_error = 1'b0;
    logic pending_final_write = 1'b0;
    integer pending_delay = 0;

    logic stalled_request = 1'b0;
    logic stalled_write = 1'b0;
    phase_e_mem_space_t stalled_space = PHASE_E_MEM_NONE;
    logic [31:0] stalled_address = 32'd0;
    logic [31:0] stalled_data = 32'd0;
    logic [3:0] stalled_strobe = 4'd0;

    integer initialize_index;
    integer verify_index;

    always #5 clk = ~clk;

    // Deterministic request backpressure.  Keeping this combinational makes
    // the source prove that request fields stay stable while READY is low.
    assign mem_req_ready =
        !memory_pending && !mem_rsp_valid && ((cycle_count % 4) != 1);

    vit_phase_e_engine_top #(
        .ARRAY_ROWS(2),
        .ARRAY_COLS(2),
        .PE_LANES(16),
        .VECTOR_LANES(16),
        .SCRATCH_WORDS(MEMORY_WORDS),
        .INPUT_WORDS(MEMORY_WORDS),
        .PARAM_WORDS(MEMORY_WORDS)
    ) dut (
        .clk(clk),
        .rst(rst),
        .cmd_valid(cmd_valid),
        .cmd_ready(cmd_ready),
        .cmd(cmd),
        .cmd_done(cmd_done),
        .cmd_error(cmd_error),
        .busy(busy),
        .parameter_request(parameter_request),
        .parameter_ready(parameter_ready),
        .parameter_command(parameter_command),
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_req_write(mem_req_write),
        .mem_req_space(mem_req_space),
        .mem_req_word_address(mem_req_word_address),
        .mem_req_write_data(mem_req_write_data),
        .mem_req_write_strobe(mem_req_write_strobe),
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
        .scratch_read_data(scratch_read_data),
        .class_result_valid(class_result_valid),
        .class_index(class_index),
        .class_logit(class_logit)
    );

    task automatic check(
        input logic condition,
        input string message
    );
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $error("CHECK FAILED: %s", message);
            end
        end
    endtask

    task automatic check_logical_request;
        integer expected_address;
        begin
            expected_address = -1;
            check(
                mem_req_space == PHASE_E_MEM_SCRATCH,
                "every test transaction uses scratch space"
            );

            case (current_test)
                TEST_VECTOR: begin
                    if (mem_req_write) begin
                        expected_address = VECTOR_DST_BASE + write_requests;
                        check(
                            write_requests < 17,
                            "VECTOR emitted no extra write request"
                        );
                        check(
                            mem_req_write_data == FP32_THREE,
                            "VECTOR write data is 1.0 + 2.0"
                        );
                        check(
                            mem_req_write_strobe == 4'hf,
                            "VECTOR uses a full-word write strobe"
                        );
                        write_requests = write_requests + 1;
                    end else begin
                        if (read_requests < 16)
                            expected_address =
                                VECTOR_A_BASE + read_requests;
                        else if (read_requests < 32)
                            expected_address =
                                VECTOR_B_BASE + read_requests - 16;
                        else if (read_requests == 32)
                            expected_address = VECTOR_A_BASE + 16;
                        else if (read_requests == 33)
                            expected_address = VECTOR_B_BASE + 16;

                        check(
                            read_requests < 34,
                            "VECTOR emitted no extra read request"
                        );
                        read_requests = read_requests + 1;
                    end
                end

                TEST_ARGMAX: begin
                    check(!mem_req_write, "ARGMAX never writes logical memory");
                    expected_address = ARGMAX_BASE + read_requests;
                    check(
                        read_requests < 5,
                        "ARGMAX emitted no extra read request"
                    );
                    read_requests = read_requests + 1;
                end

                TEST_ERROR: begin
                    if (mem_req_write) begin
                        expected_address = ERROR_DST_BASE;
                        check(
                            write_requests == 0,
                            "error test emitted exactly one write"
                        );
                        check(
                            mem_req_write_data == FP32_THREE,
                            "error-test result reaches the write request"
                        );
                        check(
                            mem_req_write_strobe == 4'hf,
                            "error test uses a full-word write strobe"
                        );
                        write_requests = write_requests + 1;
                    end else begin
                        if (read_requests == 0)
                            expected_address = ERROR_A_BASE;
                        else if (read_requests == 1)
                            expected_address = ERROR_B_BASE;
                        check(
                            read_requests < 2,
                            "error test emitted exactly two reads"
                        );
                        read_requests = read_requests + 1;
                    end
                end

                TEST_READ_ERROR: begin
                    check(
                        !mem_req_write,
                        "read-error command never emits a write"
                    );
                    expected_address = READ_ERROR_A_BASE;
                    check(
                        read_requests == 0,
                        "read-error command stops after its first read"
                    );
                    read_requests = read_requests + 1;
                end

                TEST_WRAP: begin
                    check(
                        !mem_req_write,
                        "overflow command never emits a write"
                    );
                    expected_address = WRAP_A_BASE;
                    check(
                        read_requests == 0,
                        "overflow command issues only its first valid address"
                    );
                    read_requests = read_requests + 1;
                end

                TEST_WRITE_WRAP: begin
                    if (mem_req_write) begin
                        expected_address = WRITE_WRAP_DST_BASE;
                        check(
                            write_requests == 0,
                            "write-overflow command emits one valid write"
                        );
                        check(
                            mem_req_write_data == FP32_THREE,
                            "write-overflow valid lane contains FP32 sum"
                        );
                        write_requests = write_requests + 1;
                    end else begin
                        case (read_requests)
                            0: expected_address = WRITE_WRAP_A_BASE;
                            1: expected_address = WRITE_WRAP_A_BASE + 1;
                            2: expected_address = WRITE_WRAP_B_BASE;
                            3: expected_address = WRITE_WRAP_B_BASE + 1;
                            default: expected_address = -1;
                        endcase
                        check(
                            read_requests < 4,
                            "write-overflow command emits four operand reads"
                        );
                        read_requests = read_requests + 1;
                    end
                end

                default: begin
                    check(1'b0, "transaction occurred outside an active test");
                end
            endcase

            check(
                mem_req_word_address == expected_address[31:0],
                "logical transaction word address and ordering"
            );
        end
    endtask

    task automatic start_test(input integer test_number);
        begin
            @(negedge clk);
            current_test = test_number;
            read_requests = 0;
            write_requests = 0;
            last_write_response_seen = 1'b0;
            injected_error_response_seen = 1'b0;
            check(
                !memory_pending && !mem_rsp_valid,
                "memory model is idle at command boundary"
            );
        end
    endtask

    task automatic issue_command(input phase_e_cmd_t command_value);
        begin
            @(negedge clk);
            cmd = command_value;
            cmd_valid = 1'b1;
            while (!cmd_ready)
                @(negedge clk);
            // READY is high before this edge; this edge accepts the command.
            @(posedge clk);
            @(negedge clk);
            cmd_valid = 1'b0;
        end
    endtask

    task automatic wait_for_completion(
        input logic expect_error,
        input integer timeout_cycles
    );
        integer wait_cycles;
        logic completion_seen;
        begin
            wait_cycles = 0;
            completion_seen = 1'b0;
            while (!completion_seen && (wait_cycles < timeout_cycles)) begin
                @(posedge clk);
                #1;
                if (cmd_done || cmd_error)
                    completion_seen = 1'b1;
                wait_cycles = wait_cycles + 1;
            end

            if (!completion_seen)
                $display(
                    "TIMEOUT DEBUG test=%0d reads=%0d writes=%0d busy=%b engine_state=%0d mem_state=%0d vector_state=%0d argmax_state=%0d pending=%b rsp_valid=%b",
                    current_test,
                    read_requests,
                    write_requests,
                    busy,
                    dut.state,
                    dut.mem_state,
                    dut.u_vector.state,
                    dut.u_argmax.state,
                    memory_pending,
                    mem_rsp_valid
                );
            check(completion_seen, "command completed before timeout");
            check(
                !(cmd_done && cmd_error),
                "command done and error are mutually exclusive"
            );
            if (expect_error) begin
                check(cmd_error, "command reports the injected memory error");
                check(!cmd_done, "errored command does not report done");
            end else begin
                check(cmd_done, "successful command reports done");
                check(!cmd_error, "successful command does not report error");
            end

            check(!memory_pending, "no transaction pending at completion");
            check(!mem_rsp_valid, "no response pending at completion");

            @(posedge clk);
            #1;
            check(
                !cmd_done && !cmd_error,
                "completion indication is a one-cycle pulse"
            );
        end
    endtask

    // One-outstanding logical memory with deterministic response latency.
    always_ff @(posedge clk) begin
        if (rst) begin
            cycle_count <= 0;
            accepted_transactions <= 0;
            memory_pending <= 1'b0;
            pending_write <= 1'b0;
            pending_address <= 32'd0;
            pending_write_data <= 32'd0;
            pending_write_strobe <= 4'd0;
            pending_read_data <= 32'd0;
            pending_error <= 1'b0;
            pending_final_write <= 1'b0;
            pending_delay <= 0;
            mem_rsp_valid <= 1'b0;
            mem_rsp_read_data <= 32'd0;
            mem_rsp_error <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1;

            if (mem_req_valid && mem_req_ready) begin
                check_logical_request();
                memory_pending <= 1'b1;
                pending_write <= mem_req_write;
                pending_address <= mem_req_word_address;
                pending_write_data <= mem_req_write_data;
                pending_write_strobe <= mem_req_write_strobe;
                if (mem_req_word_address < MEMORY_WORDS)
                    pending_read_data <=
                        logical_memory[mem_req_word_address];
                else
                    pending_read_data <= 32'h7fc0_0000;

                pending_error <=
                    ((current_test == TEST_ERROR) &&
                     mem_req_write &&
                     (mem_req_word_address == ERROR_DST_BASE)) ||
                    ((current_test == TEST_READ_ERROR) &&
                     !mem_req_write &&
                     (mem_req_word_address == READ_ERROR_A_BASE));
                pending_final_write <=
                    ((current_test == TEST_VECTOR) &&
                     mem_req_write && (write_requests == 17)) ||
                    ((current_test == TEST_ERROR) &&
                     mem_req_write && (write_requests == 1));

                // Make the final 17-word VECTOR write visibly expensive so
                // an early cmd_done is very likely to be caught.
                if ((current_test == TEST_VECTOR) &&
                    mem_req_write && (write_requests == 17))
                    pending_delay <= 8;
                else
                    pending_delay <= (accepted_transactions % 3) + 1;
                accepted_transactions <= accepted_transactions + 1;
            end

            if (memory_pending && !mem_rsp_valid) begin
                if (pending_delay == 0) begin
                    mem_rsp_valid <= 1'b1;
                    mem_rsp_read_data <=
                        pending_write ? 32'd0 : pending_read_data;
                    mem_rsp_error <= pending_error;
                end else begin
                    pending_delay <= pending_delay - 1;
                end
            end

            if (mem_rsp_valid && mem_rsp_ready) begin
                if (pending_write && !pending_error &&
                    (pending_address < MEMORY_WORDS)) begin
                    if (pending_write_strobe[0])
                        logical_memory[pending_address][7:0] <=
                            pending_write_data[7:0];
                    if (pending_write_strobe[1])
                        logical_memory[pending_address][15:8] <=
                            pending_write_data[15:8];
                    if (pending_write_strobe[2])
                        logical_memory[pending_address][23:16] <=
                            pending_write_data[23:16];
                    if (pending_write_strobe[3])
                        logical_memory[pending_address][31:24] <=
                            pending_write_data[31:24];
                end

                if (pending_final_write)
                    last_write_response_seen <= 1'b1;
                if (pending_error)
                    injected_error_response_seen <= 1'b1;

                memory_pending <= 1'b0;
                mem_rsp_valid <= 1'b0;
                mem_rsp_read_data <= 32'd0;
                mem_rsp_error <= 1'b0;
            end
        end
    end

    // Check stability whenever the test memory withholds request READY.
    always_ff @(posedge clk) begin
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
                    mem_req_write == stalled_write,
                    "REQ_WRITE stable under request backpressure"
                );
                check(
                    mem_req_space == stalled_space,
                    "REQ_SPACE stable under request backpressure"
                );
                check(
                    mem_req_word_address == stalled_address,
                    "REQ word address stable under request backpressure"
                );
                check(
                    mem_req_write_data == stalled_data,
                    "REQ write data stable under request backpressure"
                );
                check(
                    mem_req_write_strobe == stalled_strobe,
                    "REQ strobe stable under request backpressure"
                );
            end
        end else begin
            stalled_request <= 1'b0;
        end
    end

    // Sideband and command-order assertions.
    always @(posedge clk) begin
        #1;
        if (!rst) begin
            check(
                !(mem_req_valid && mem_rsp_valid),
                "one-outstanding interface never requests with a response pending"
            );
            check(
                !parameter_request,
                "scratch-only commands do not request parameter staging"
            );

            if (class_result_valid) begin
                class_result_pulses = class_result_pulses + 1;
                captured_class_index = class_index;
                captured_class_logit = class_logit;
            end

            if ((cmd_done || cmd_error) &&
                (current_test == TEST_VECTOR)) begin
                check(
                    last_write_response_seen,
                    "cmd_done follows the final VECTOR write response"
                );
            end

            if (cmd_done || cmd_error) begin
                check(
                    !memory_pending && !mem_rsp_valid,
                    "completion never precedes an outstanding response"
                );
            end
        end
    end

    initial begin
        for (
            initialize_index = 0;
            initialize_index < MEMORY_WORDS;
            initialize_index = initialize_index + 1
        )
            logical_memory[initialize_index] = FP32_SENTINEL;

        for (
            initialize_index = 0;
            initialize_index < 17;
            initialize_index = initialize_index + 1
        ) begin
            logical_memory[VECTOR_A_BASE + initialize_index] = FP32_ONE;
            logical_memory[VECTOR_B_BASE + initialize_index] = FP32_TWO;
        end

        logical_memory[ARGMAX_BASE + 0] = FP32_NEG_ONE;
        logical_memory[ARGMAX_BASE + 1] = FP32_ONE_HALF;
        logical_memory[ARGMAX_BASE + 2] = FP32_SEVEN;
        logical_memory[ARGMAX_BASE + 3] = FP32_TWO;
        logical_memory[ARGMAX_BASE + 4] = FP32_SIX;

        logical_memory[ERROR_A_BASE] = FP32_ONE;
        logical_memory[ERROR_B_BASE] = FP32_TWO;
        logical_memory[ERROR_DST_BASE] = FP32_SENTINEL;
        logical_memory[READ_ERROR_A_BASE] = FP32_ONE;
        logical_memory[READ_ERROR_B_BASE] = FP32_TWO;
        logical_memory[READ_ERROR_DST_BASE] = FP32_SENTINEL;
        logical_memory[WRITE_WRAP_A_BASE] = FP32_ONE;
        logical_memory[WRITE_WRAP_A_BASE + 1] = FP32_ONE;
        logical_memory[WRITE_WRAP_B_BASE] = FP32_TWO;
        logical_memory[WRITE_WRAP_B_BASE + 1] = FP32_TWO;

        repeat (5)
            @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // VECTOR_ADD length 17 exercises one full 16-lane gather/scatter and
        // one tail gather/scatter.
        start_test(TEST_VECTOR);
        cmd = '0;
        cmd.header.opcode = PHASE_E_OP_VECTOR;
        cmd.header.subop = PHASE_E_SUBOP_VECTOR_ADD;
        cmd.route.src0_space = PHASE_E_MEM_SCRATCH;
        cmd.route.src1_space = PHASE_E_MEM_SCRATCH;
        cmd.route.dst_space = PHASE_E_MEM_SCRATCH;
        cmd.src0_base = VECTOR_A_BASE;
        cmd.src1_base = VECTOR_B_BASE;
        cmd.dst_base = VECTOR_DST_BASE;
        cmd.dim0 = 32'd17;
        issue_command(cmd);
        wait_for_completion(1'b0, 5000);
        check(read_requests == 34, "VECTOR issued 34 valid reads");
        check(write_requests == 17, "VECTOR issued 17 writes");
        check(
            last_write_response_seen,
            "VECTOR final write response was observed"
        );
        for (
            verify_index = 0;
            verify_index < 17;
            verify_index = verify_index + 1
        )
            check(
                logical_memory[VECTOR_DST_BASE + verify_index] ==
                    FP32_THREE,
                "VECTOR destination contains the expected FP32 sum"
            );

        // ARGMAX has reads only and reports the winning index/value on its
        // class sideband.
        start_test(TEST_ARGMAX);
        cmd = '0;
        cmd.header.opcode = PHASE_E_OP_ARGMAX;
        cmd.route.src0_space = PHASE_E_MEM_SCRATCH;
        cmd.src0_base = ARGMAX_BASE;
        cmd.dim0 = 32'd5;
        issue_command(cmd);
        wait_for_completion(1'b0, 1000);
        check(read_requests == 5, "ARGMAX issued five reads");
        check(write_requests == 0, "ARGMAX issued no writes");
        check(class_result_pulses == 1, "ARGMAX emitted one class result");
        check(captured_class_index == 32'd2, "ARGMAX class index is two");
        check(captured_class_logit == FP32_SEVEN, "ARGMAX logit is 7.0");

        // Inject an error only on the write response.  Arithmetic succeeds,
        // but the sticky logical-memory error must turn completion into
        // cmd_error and the failed write must not modify memory.
        start_test(TEST_ERROR);
        cmd = '0;
        cmd.header.opcode = PHASE_E_OP_VECTOR;
        cmd.header.subop = PHASE_E_SUBOP_VECTOR_ADD;
        cmd.route.src0_space = PHASE_E_MEM_SCRATCH;
        cmd.route.src1_space = PHASE_E_MEM_SCRATCH;
        cmd.route.dst_space = PHASE_E_MEM_SCRATCH;
        cmd.src0_base = ERROR_A_BASE;
        cmd.src1_base = ERROR_B_BASE;
        cmd.dst_base = ERROR_DST_BASE;
        cmd.dim0 = 32'd1;
        issue_command(cmd);
        wait_for_completion(1'b1, 1000);
        check(read_requests == 2, "error test issued two reads");
        check(write_requests == 1, "error test issued one write");
        check(
            injected_error_response_seen,
            "memory model delivered the injected error response"
        );
        check(
            last_write_response_seen,
            "error command waited for its write response"
        );
        check(
            logical_memory[ERROR_DST_BASE] == FP32_SENTINEL,
            "failed write did not modify logical memory"
        );

        // A failed operand read must fail fast: do not fetch later operands,
        // do not feed QNaN into compute, and do not scatter any result.
        start_test(TEST_READ_ERROR);
        cmd = '0;
        cmd.header.opcode = PHASE_E_OP_VECTOR;
        cmd.header.subop = PHASE_E_SUBOP_VECTOR_ADD;
        cmd.route.src0_space = PHASE_E_MEM_SCRATCH;
        cmd.route.src1_space = PHASE_E_MEM_SCRATCH;
        cmd.route.dst_space = PHASE_E_MEM_SCRATCH;
        cmd.src0_base = READ_ERROR_A_BASE;
        cmd.src1_base = READ_ERROR_B_BASE;
        cmd.dst_base = READ_ERROR_DST_BASE;
        cmd.dim0 = 32'd1;
        issue_command(cmd);
        wait_for_completion(1'b1, 1000);
        check(read_requests == 1, "read error stopped further gathers");
        check(write_requests == 0, "read error suppressed all scatter writes");
        check(
            injected_error_response_seen,
            "memory model delivered the injected read error"
        );
        check(
            logical_memory[READ_ERROR_DST_BASE] == FP32_SENTINEL,
            "read error left destination unchanged"
        );

        // The first operand address is representable, but the second would be
        // 0x1_0000_0000.  The engine must report an error locally rather than
        // truncate it to word address zero and corrupt an unrelated buffer.
        start_test(TEST_WRAP);
        cmd = '0;
        cmd.header.opcode = PHASE_E_OP_VECTOR;
        cmd.header.subop = PHASE_E_SUBOP_VECTOR_SCALE_MASK;
        cmd.route.src0_space = PHASE_E_MEM_SCRATCH;
        cmd.route.src1_space = PHASE_E_MEM_NONE;
        cmd.route.dst_space = PHASE_E_MEM_SCRATCH;
        cmd.src0_base = WRAP_A_BASE;
        cmd.dst_base = WRAP_DST_BASE;
        cmd.dim0 = 32'd2;
        cmd.immediate = FP32_ONE;
        issue_command(cmd);
        wait_for_completion(1'b1, 1000);
        check(read_requests == 1, "overflow stopped before wrapped read");
        check(write_requests == 0, "overflow suppressed all writes");
        check(
            logical_memory[WRAP_DST_BASE] == FP32_SENTINEL,
            "overflow left destination unchanged"
        );

        // The first output word at 0xffffffff is legal in the logical
        // interface; lane one would wrap to zero.  Commit the first response,
        // then fail locally before issuing the wrapped second write.
        start_test(TEST_WRITE_WRAP);
        cmd = '0;
        cmd.header.opcode = PHASE_E_OP_VECTOR;
        cmd.header.subop = PHASE_E_SUBOP_VECTOR_ADD;
        cmd.route.src0_space = PHASE_E_MEM_SCRATCH;
        cmd.route.src1_space = PHASE_E_MEM_SCRATCH;
        cmd.route.dst_space = PHASE_E_MEM_SCRATCH;
        cmd.src0_base = WRITE_WRAP_A_BASE;
        cmd.src1_base = WRITE_WRAP_B_BASE;
        cmd.dst_base = WRITE_WRAP_DST_BASE;
        cmd.dim0 = 32'd2;
        issue_command(cmd);
        wait_for_completion(1'b1, 1000);
        check(read_requests == 4, "write overflow followed four valid reads");
        check(write_requests == 1, "write overflow stopped before wrapped lane");
        check(
            logical_memory[0] == FP32_SENTINEL,
            "write overflow did not corrupt logical address zero"
        );

        current_test = TEST_NONE;
        if (failures == 0) begin
            $display(
                "PASS engine logical-memory test: checks=%0d transactions=%0d",
                checks,
                accepted_transactions
            );
            $finish;
        end else begin
            $fatal(
                1,
                "FAIL engine logical-memory test: failures=%0d checks=%0d",
                failures,
                checks
            );
        end
    end

    initial begin
        #2_000_000;
        $fatal(1, "Timeout in tb_vit_phase_e_engine_memory");
    end

endmodule
