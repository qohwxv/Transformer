`timescale 1ns/1ps

// Compact four-state protocol test for the production vit_phase_e_npu.
//
// The test deliberately:
//   1. stalls the first native-memory request and checks VALID/payload hold;
//   2. accepts that request, then asserts reset while its response is pending;
//   3. restarts the NPU and completes a compact E04 job while every read and
//      write request sees deterministic backpressure;
//   4. checks one-outstanding request/response accounting and rejects X/Z on
//      every meaningful NPU protocol/control output.
//
// No behavioral-engine define is used.  E04 dimensions and lane counts are
// reduced only to make this production-hierarchy protocol test short.
module tb_vit_phase_e_npu_memory_protocol_4state;

    import vit_phase_e_pkg::*;

    localparam logic [31:0] TEST_TOKEN_COUNT  = 32'd1;
    localparam logic [31:0] TEST_HIDDEN_SIZE = 32'd1;
    localparam logic [31:0] TEST_CLASS_COUNT = 32'd1;
    localparam logic [31:0] LN_GAMMA_BASE    = 32'd0;
    localparam logic [31:0] LN_BETA_BASE     = 32'd16;
    localparam logic [31:0] CLASS_W_BASE     = 32'd32;
    localparam logic [31:0] CLASS_B_BASE     = 32'd48;
    localparam integer WATCHDOG_CYCLES       = 50_000;
    localparam integer REQUEST_STALL_CYCLES  = 3;
    localparam integer RESPONSE_DELAY_CYCLES = 2;

    logic clk = 1'b0;
    logic rst = 1'b1;

    logic job_valid = 1'b0;
    logic job_ready;
    phase_e_job_t job = '0;
    phase_e_global_params_t global_params = '0;

    logic layer_param_request;
    logic [3:0] layer_param_index;
    logic layer_param_valid = 1'b0;
    phase_e_layer_params_t layer_param_data = '0;

    logic operand_load_request;
    logic operand_load_ready = 1'b1;
    phase_e_cmd_t operand_load_command;

    logic checkpoint_valid;
    logic checkpoint_ready = 1'b1;
    phase_e_phase_t checkpoint_phase;
    phase_e_section_t checkpoint_section;
    logic [3:0] checkpoint_layer;
    logic [4:0] checkpoint_step;
    logic [7:0] checkpoint_tag;
    phase_e_opcode_t checkpoint_opcode;
    phase_e_tensor_id_t checkpoint_dst_tensor;

    logic busy;
    logic done;
    logic error;
    phase_e_error_t error_code;
    phase_e_section_t error_section;
    logic [3:0] error_layer;
    logic [4:0] error_step;

    logic mem_req_valid;
    logic mem_req_ready = 1'b0;
    logic mem_req_write;
    phase_e_mem_space_t mem_req_space;
    logic [31:0] mem_req_word_address;
    logic [31:0] mem_req_write_data;
    logic [3:0] mem_req_write_strobe;
    logic mem_rsp_valid = 1'b0;
    logic mem_rsp_ready;
    logic [31:0] mem_rsp_read_data = 32'd0;
    logic mem_rsp_error = 1'b0;

    logic class_result_valid;
    logic [31:0] class_index;
    logic [31:0] class_logit;

    integer checks = 0;
    integer failures = 0;
    longint cycle_count = 0;
    logic monitor_enabled = 1'b0;

    // Epoch zero is intentionally aborted.  Epoch one must drain normally.
    integer current_epoch = 0;
    integer request_count [0:1];
    integer response_count [0:1];
    integer read_request_count [0:1];
    integer read_response_count [0:1];
    integer write_request_count [0:1];
    integer write_response_count [0:1];
    integer aborted_request_count = 0;
    integer unexpected_response_count = 0;
    integer maximum_outstanding = 0;
    integer outstanding = 0;

    integer request_stall_age = 0;
    integer request_stall_events = 0;
    integer read_stall_events = 0;
    integer write_stall_events = 0;
    integer response_stall_events = 0;
    integer response_delay = 0;
    logic clean_response_mode = 1'b0;
    logic pending_write = 1'b0;
    logic [31:0] pending_address = 32'd0;

    logic stalled_request_active = 1'b0;
    logic stalled_request_write = 1'b0;
    phase_e_mem_space_t stalled_request_space = PHASE_E_MEM_NONE;
    logic [31:0] stalled_request_address = 32'd0;
    logic [31:0] stalled_request_data = 32'd0;
    logic [3:0] stalled_request_strobe = 4'd0;

    logic stalled_response_active = 1'b0;
    logic [31:0] stalled_response_data = 32'd0;
    logic stalled_response_error = 1'b0;

    always #5 clk = ~clk;

    task automatic fail_check(
        input logic condition,
        input string message
    );
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $error(
                    "PROTOCOL_4STATE_CHECK_FAILED cycle=%0d epoch=%0d: %s",
                    cycle_count,
                    current_epoch,
                    message
                );
            end
        end
    endtask

    task automatic check_known_bit(
        input logic value,
        input string name
    );
        begin
            fail_check(
                (value === 1'b0) || (value === 1'b1),
                {name, " contains X/Z"}
            );
        end
    endtask

    task automatic check_known_reduction(
        input logic reduction_value,
        input string name
    );
        begin
            fail_check(
                (reduction_value === 1'b0) ||
                (reduction_value === 1'b1),
                {name, " contains X/Z"}
            );
        end
    endtask

    task automatic launch_e04_job(input logic [7:0] tag);
        begin
            @(negedge clk);
            job = '0;
            job.phase = PHASE_E_E04;
            job.class_softmax_enable = 1'b0;
            job.checkpoint_enable = 1'b1;
            job.job_tag = tag;
            job_valid = 1'b1;

            while (job_ready !== 1'b1)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            job_valid = 1'b0;
        end
    endtask

    vit_phase_e_npu #(
        .ARRAY_ROWS       (1),
        .ARRAY_COLS       (1),
        // The production GEMM/vector leaf contracts are fixed at 16 lanes.
        .PE_LANES         (16),
        .VECTOR_LANES     (16),
        .SCRATCH_WORDS    (PHASE_E_SCRATCH_WORDS),
        .INPUT_WORDS      (1),
        .PARAM_WORDS      (64),
        .E04_TOKEN_COUNT  (TEST_TOKEN_COUNT),
        .E04_HIDDEN_SIZE  (TEST_HIDDEN_SIZE),
        .E04_CLASS_COUNT  (TEST_CLASS_COUNT)
    ) dut (
        .clk                     (clk),
        .rst                     (rst),
        .job_valid               (job_valid),
        .job_ready               (job_ready),
        .job                     (job),
        .global_params           (global_params),
        .layer_param_request     (layer_param_request),
        .layer_param_index       (layer_param_index),
        .layer_param_valid       (layer_param_valid),
        .layer_param_data        (layer_param_data),
        .operand_load_request    (operand_load_request),
        .operand_load_ready      (operand_load_ready),
        .operand_load_command    (operand_load_command),
        .checkpoint_valid        (checkpoint_valid),
        .checkpoint_ready        (checkpoint_ready),
        .checkpoint_phase        (checkpoint_phase),
        .checkpoint_section      (checkpoint_section),
        .checkpoint_layer        (checkpoint_layer),
        .checkpoint_step         (checkpoint_step),
        .checkpoint_tag          (checkpoint_tag),
        .checkpoint_opcode       (checkpoint_opcode),
        .checkpoint_dst_tensor   (checkpoint_dst_tensor),
        .busy                    (busy),
        .done                    (done),
        .error                   (error),
        .error_code              (error_code),
        .error_section           (error_section),
        .error_layer             (error_layer),
        .error_step              (error_step),
        .input_write_enable      (1'b0),
        .input_write_address     (32'd0),
        .input_write_data        (32'd0),
        .parameter_write_enable  (1'b0),
        .parameter_write_address (32'd0),
        .parameter_write_data    (32'd0),
        .scratch_write_enable    (1'b0),
        .scratch_write_address   (32'd0),
        .scratch_write_data      (32'd0),
        .scratch_read_address    (32'd0),
        .scratch_read_data       (),
        .mem_req_valid           (mem_req_valid),
        .mem_req_ready           (mem_req_ready),
        .mem_req_write           (mem_req_write),
        .mem_req_space           (mem_req_space),
        .mem_req_word_address    (mem_req_word_address),
        .mem_req_write_data      (mem_req_write_data),
        .mem_req_write_strobe    (mem_req_write_strobe),
        .mem_rsp_valid           (mem_rsp_valid),
        .mem_rsp_ready           (mem_rsp_ready),
        .mem_rsp_read_data       (mem_rsp_read_data),
        .mem_rsp_error           (mem_rsp_error),
        .class_result_valid      (class_result_valid),
        .class_index             (class_index),
        .class_logit             (class_logit)
    );

    // Four-state checks for all meaningful top-level control and protocol
    // outputs.  Payload checks are qualified by their corresponding VALID.
    always @(posedge clk) begin
        if (rst) begin
            cycle_count = 0;
            monitor_enabled = 1'b1;
            stalled_request_active = 1'b0;
            stalled_response_active = 1'b0;
        end else if (monitor_enabled) begin
            cycle_count = cycle_count + 1;

            check_known_bit(job_ready, "job_ready");
            check_known_bit(layer_param_request, "layer_param_request");
            check_known_bit(
                operand_load_request,
                "operand_load_request"
            );
            check_known_bit(checkpoint_valid, "checkpoint_valid");
            check_known_bit(busy, "busy");
            check_known_bit(done, "done");
            check_known_bit(error, "error");
            check_known_bit(mem_req_valid, "mem_req_valid");
            check_known_bit(mem_rsp_ready, "mem_rsp_ready");
            check_known_bit(
                class_result_valid,
                "class_result_valid"
            );

            if (layer_param_request === 1'b1)
                check_known_reduction(
                    ^layer_param_index,
                    "layer_param_index"
                );
            if (operand_load_request === 1'b1)
                check_known_reduction(
                    ^operand_load_command,
                    "operand_load_command"
                );
            if (checkpoint_valid === 1'b1)
                check_known_reduction(
                    ^{
                        checkpoint_phase,
                        checkpoint_section,
                        checkpoint_layer,
                        checkpoint_step,
                        checkpoint_tag,
                        checkpoint_opcode,
                        checkpoint_dst_tensor
                    },
                    "checkpoint payload"
                );
            if (error === 1'b1)
                check_known_reduction(
                    ^{
                        error_code,
                        error_section,
                        error_layer,
                        error_step
                    },
                    "error payload"
                );
            if (class_result_valid === 1'b1)
                check_known_reduction(
                    ^{class_index, class_logit},
                    "class result payload"
                );

            if (mem_req_valid === 1'b1) begin
                check_known_reduction(
                    ^{
                        mem_req_write,
                        mem_req_space,
                        mem_req_word_address,
                        mem_req_write_strobe
                    },
                    "memory request control/address"
                );
                if (mem_req_write === 1'b1)
                    check_known_reduction(
                        ^mem_req_write_data,
                        "memory write data"
                    );
            end

            if (mem_rsp_valid === 1'b1)
                check_known_reduction(
                    ^{mem_rsp_read_data, mem_rsp_error},
                    "memory response payload"
                );

            // Once request VALID has been observed while READY is low, both
            // VALID and every semantically meaningful payload field must stay
            // stable through the eventual handshake.
            if (stalled_request_active) begin
                fail_check(
                    mem_req_valid === 1'b1,
                    "request VALID dropped under backpressure"
                );
                fail_check(
                    (mem_req_write === stalled_request_write) &&
                    (mem_req_space === stalled_request_space) &&
                    (mem_req_word_address ===
                        stalled_request_address) &&
                    (mem_req_write_strobe ===
                        stalled_request_strobe),
                    "request control/address changed under backpressure"
                );
                if (stalled_request_write)
                    fail_check(
                        mem_req_write_data === stalled_request_data,
                        "request write data changed under backpressure"
                    );
                if (
                    (mem_req_valid === 1'b1) &&
                    (mem_req_ready === 1'b1)
                )
                    stalled_request_active = 1'b0;
            end else if (
                (mem_req_valid === 1'b1) &&
                (mem_req_ready === 1'b0)
            ) begin
                stalled_request_active = 1'b1;
                stalled_request_write = mem_req_write;
                stalled_request_space = mem_req_space;
                stalled_request_address = mem_req_word_address;
                stalled_request_data = mem_req_write_data;
                stalled_request_strobe = mem_req_write_strobe;
                request_stall_events = request_stall_events + 1;
                if (mem_req_write === 1'b1)
                    write_stall_events = write_stall_events + 1;
                else if (mem_req_write === 1'b0)
                    read_stall_events = read_stall_events + 1;
            end

            // The NPU is the response consumer, but the test memory still
            // obeys and checks the same VALID/payload hold contract.
            if (stalled_response_active) begin
                fail_check(
                    mem_rsp_valid === 1'b1,
                    "response VALID dropped under backpressure"
                );
                fail_check(
                    (mem_rsp_read_data === stalled_response_data) &&
                    (mem_rsp_error === stalled_response_error),
                    "response payload changed under backpressure"
                );
                if (
                    (mem_rsp_valid === 1'b1) &&
                    (mem_rsp_ready === 1'b1)
                )
                    stalled_response_active = 1'b0;
            end else if (
                (mem_rsp_valid === 1'b1) &&
                (mem_rsp_ready === 1'b0)
            ) begin
                stalled_response_active = 1'b1;
                stalled_response_data = mem_rsp_read_data;
                stalled_response_error = mem_rsp_error;
                response_stall_events = response_stall_events + 1;
            end
        end
    end

    // Single-outstanding memory responder.  Request READY is asserted only
    // after a fixed stall.  Epoch zero withholds its response so reset aborts
    // a real accepted transaction; epoch one returns every response exactly
    // once after a small fixed delay.
    always @(posedge clk) begin
        if (rst) begin
            if (outstanding != 0) begin
                aborted_request_count = aborted_request_count + outstanding;
                outstanding = 0;
            end
            mem_req_ready <= 1'b0;
            mem_rsp_valid <= 1'b0;
            mem_rsp_read_data <= 32'd0;
            mem_rsp_error <= 1'b0;
            request_stall_age = 0;
            response_delay = 0;
            pending_write = 1'b0;
            pending_address = 32'd0;
        end else begin
            // Consume a response before considering a new request.  The DUT
            // itself serializes these phases, so both cannot be accepted on
            // the same edge in a legal trace.
            if (
                (mem_rsp_valid === 1'b1) &&
                (mem_rsp_ready === 1'b1)
            ) begin
                if (outstanding != 1) begin
                    unexpected_response_count =
                        unexpected_response_count + 1;
                    failures = failures + 1;
                    $error(
                        "PROTOCOL_4STATE_CHECK_FAILED: response without exactly one outstanding request"
                    );
                end else begin
                    response_count[current_epoch] =
                        response_count[current_epoch] + 1;
                    if (pending_write)
                        write_response_count[current_epoch] =
                            write_response_count[current_epoch] + 1;
                    else
                        read_response_count[current_epoch] =
                            read_response_count[current_epoch] + 1;
                    outstanding = 0;
                end
                mem_rsp_valid <= 1'b0;
                mem_rsp_read_data <= 32'd0;
                mem_rsp_error <= 1'b0;
            end

            if (
                (mem_req_valid === 1'b1) &&
                (mem_req_ready === 1'b1)
            ) begin
                if (outstanding != 0) begin
                    failures = failures + 1;
                    $error(
                        "PROTOCOL_4STATE_CHECK_FAILED: accepted request while another request is outstanding"
                    );
                end
                outstanding = outstanding + 1;
                if (outstanding > maximum_outstanding)
                    maximum_outstanding = outstanding;

                request_count[current_epoch] =
                    request_count[current_epoch] + 1;
                pending_write = mem_req_write;
                pending_address = mem_req_word_address;
                if (mem_req_write)
                    write_request_count[current_epoch] =
                        write_request_count[current_epoch] + 1;
                else
                    read_request_count[current_epoch] =
                        read_request_count[current_epoch] + 1;

                response_delay = RESPONSE_DELAY_CYCLES;
                request_stall_age = 0;
                mem_req_ready <= 1'b0;
            end else if (mem_req_valid === 1'b1) begin
                if (request_stall_age >= (REQUEST_STALL_CYCLES - 1))
                    mem_req_ready <= 1'b1;
                else begin
                    request_stall_age = request_stall_age + 1;
                    mem_req_ready <= 1'b0;
                end
            end else begin
                request_stall_age = 0;
                mem_req_ready <= 1'b0;
            end

            if (
                clean_response_mode &&
                (outstanding == 1) &&
                (mem_rsp_valid !== 1'b1)
            ) begin
                if (response_delay == 0) begin
`ifdef VIT_PROTOCOL_INJECT_X
                    mem_rsp_read_data <= 32'hxxxx_xxxx;
`elsif VIT_PROTOCOL_INJECT_Z
                    mem_rsp_read_data <= 32'hzzzz_zzzz;
`else
                    mem_rsp_read_data <= 32'd0;
`endif
                    mem_rsp_error <= 1'b0;
                    mem_rsp_valid <= 1'b1;
                end else
                    response_delay = response_delay - 1;
            end
        end
    end

    initial begin
        request_count[0] = 0;
        request_count[1] = 0;
        response_count[0] = 0;
        response_count[1] = 0;
        read_request_count[0] = 0;
        read_request_count[1] = 0;
        read_response_count[0] = 0;
        read_response_count[1] = 0;
        write_request_count[0] = 0;
        write_request_count[1] = 0;
        write_response_count[0] = 0;
        write_response_count[1] = 0;

        global_params = '0;
        global_params.final_ln_gamma_base = LN_GAMMA_BASE;
        global_params.final_ln_beta_base = LN_BETA_BASE;
        global_params.classifier_weight_base = CLASS_W_BASE;
        global_params.classifier_bias_base = CLASS_B_BASE;

        repeat (5)
            @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // Epoch zero: accept exactly one request, then reset before response.
        launch_e04_job(8'ha0);
        wait (outstanding == 1);
        fail_check(
            request_count[0] == 1,
            "epoch zero accepted exactly one request before reset"
        );
        fail_check(
            response_count[0] == 0,
            "epoch zero has no response before reset"
        );

        @(negedge clk);
        rst = 1'b1;
        repeat (2)
            @(posedge clk);
        #1;
        fail_check(
            aborted_request_count == 1,
            "reset aborted exactly one outstanding transaction"
        );
        fail_check(
            outstanding == 0,
            "reset cleared external outstanding accounting"
        );
        fail_check(
            mem_req_valid === 1'b0,
            "request VALID is low during reset"
        );
        fail_check(
            mem_rsp_ready === 1'b0,
            "response READY is low during reset"
        );
        fail_check(busy === 1'b0, "busy is low during reset");
        fail_check(done === 1'b0, "done is low during reset");
        fail_check(error === 1'b0, "error is low during reset");
        fail_check(job_ready === 1'b1, "job_ready is high after reset");

        // Epoch one: restart from a clean protocol state and complete.
        @(negedge clk);
        current_epoch = 1;
        clean_response_mode = 1'b1;
        rst = 1'b0;
        launch_e04_job(8'hb0);

        wait ((done === 1'b1) || (error === 1'b1));
        #1;
        fail_check(error === 1'b0, "restarted E04 job has no error");
        fail_check(done === 1'b1, "restarted E04 job reaches done");
        fail_check(
            request_count[1] > 0,
            "restarted job issued memory requests"
        );
        fail_check(
            read_request_count[1] > 0,
            "restarted job issued read requests"
        );
        fail_check(
            write_request_count[1] > 0,
            "restarted job issued write requests"
        );
        fail_check(
            request_count[1] == response_count[1],
            "restart request/response totals match"
        );
        fail_check(
            read_request_count[1] == read_response_count[1],
            "restart read request/response totals match"
        );
        fail_check(
            write_request_count[1] == write_response_count[1],
            "restart write request/response totals match"
        );
        fail_check(
            outstanding == 0,
            "no transaction remains outstanding at done"
        );
        fail_check(
            mem_rsp_valid === 1'b0,
            "memory response VALID is drained at done"
        );
        fail_check(
            unexpected_response_count == 0,
            "no response occurred without a request"
        );
        fail_check(
            maximum_outstanding == 1,
            "protocol never exceeded one outstanding transaction"
        );
        fail_check(
            request_stall_events ==
                (request_count[0] + request_count[1]),
            "exactly one backpressure episode covered every request"
        );
        fail_check(
            request_count[0] == 1 && response_count[0] == 0,
            "aborted epoch retained exact request/response accounting"
        );
        fail_check(
            read_stall_events > 0,
            "read request stability was exercised"
        );
        fail_check(
            write_stall_events > 0,
            "write request stability was exercised"
        );
        fail_check(
            class_result_valid === 1'b0,
            "class-result VALID is a pulse and is low at final done"
        );

        if (failures == 0) begin
            $display(
                "VIT_PHASE_E_NPU_MEMORY_PROTOCOL_4STATE_PASS checks=%0d failures=%0d cycles=%0d aborted=%0d restart_requests=%0d restart_responses=%0d reads=%0d writes=%0d request_stalls=%0d response_stalls=%0d max_outstanding=%0d",
                checks,
                failures,
                cycle_count,
                aborted_request_count,
                request_count[1],
                response_count[1],
                read_request_count[1],
                write_request_count[1],
                request_stall_events,
                response_stall_events,
                maximum_outstanding
            );
            $finish;
        end else begin
            $fatal(
                1,
                "VIT_PHASE_E_NPU_MEMORY_PROTOCOL_4STATE_FAIL checks=%0d failures=%0d",
                checks,
                failures
            );
        end
    end

    initial begin
        repeat (WATCHDOG_CYCLES)
            @(posedge clk);
        $fatal(
            1,
            "VIT_PHASE_E_NPU_MEMORY_PROTOCOL_4STATE_TIMEOUT cycles=%0d outstanding=%0d requests=%0d responses=%0d",
            WATCHDOG_CYCLES,
            outstanding,
            request_count[1],
            response_count[1]
        );
    end

endmodule
