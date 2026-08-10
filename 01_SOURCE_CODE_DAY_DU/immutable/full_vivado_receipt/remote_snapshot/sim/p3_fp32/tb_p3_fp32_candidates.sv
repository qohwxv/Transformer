`timescale 1ns/1ps

// Self-checking behavioral test for the three P3 FP32 PE candidates.
//
// All arithmetic vectors are exactly representable in binary32. This keeps
// the protocol/architecture test deterministic and separates it from the
// wider numeric-contract tests that use the Xilinx bit-accurate C model.
module tb_p3_fp32_candidates;
    localparam logic [31:0] FP32_HALF    = 32'h3f00_0000;
    localparam logic [31:0] FP32_ONE     = 32'h3f80_0000;
    localparam logic [31:0] FP32_TWO     = 32'h4000_0000;
    localparam logic [31:0] FP32_THREE   = 32'h4040_0000;
    localparam logic [31:0] FP32_FOUR    = 32'h4080_0000;
    localparam logic [31:0] FP32_FIVE    = 32'h40a0_0000;
    localparam logic [31:0] FP32_EIGHT   = 32'h4100_0000;
    localparam logic [31:0] FP32_FOURTEEN = 32'h4160_0000;
    localparam logic [31:0] FP32_16P5    = 32'h4184_0000;

    logic aclk;
    logic aresetn;
    integer cycle_count;
    integer error_count;

    logic        c1_in_valid;
    logic        c1_in_ready;
    logic [63:0] c1_in_data;
    logic        c1_in_last;
    logic        c1_out_valid;
    logic        c1_out_ready;
    logic [31:0] c1_out_data;
    logic        c1_out_last;

    logic        c2_in_valid;
    logic        c2_in_ready;
    logic [63:0] c2_in_data;
    logic        c2_in_last;
    logic        c2_out_valid;
    logic        c2_out_ready;
    logic [31:0] c2_out_data;
    logic        c2_out_last;
    logic [31:0] c2_a_vector [0:2];
    logic [31:0] c2_b_vector [0:2];

    logic        c3_in_valid;
    logic        c3_in_ready;
    logic [63:0] c3_in_data;
    logic [4:0]  c3_in_user;
    logic        c3_in_last;
    logic        c3_out_valid;
    logic        c3_out_ready;
    logic [31:0] c3_out_data;
    logic [4:0]  c3_out_user;
    logic        c3_out_last;

    logic        c3_accept_monitor_enable;
    integer      c3_accept_count;
    integer      c3_previous_accept_cycle;
    integer      c3_score_count;
    logic        c3_score_enable;

    fp32_fma_feedback_candidate u_candidate_1 (
        .aclk                 (aclk),
        .aresetn              (aresetn),
        .s_axis_term_tvalid   (c1_in_valid),
        .s_axis_term_tready   (c1_in_ready),
        .s_axis_term_tdata    (c1_in_data),
        .s_axis_term_tlast    (c1_in_last),
        .m_axis_result_tvalid (c1_out_valid),
        .m_axis_result_tready (c1_out_ready),
        .m_axis_result_tdata  (c1_out_data),
        .m_axis_result_tlast  (c1_out_last)
    );

    fp32_mul_accum_candidate u_candidate_2 (
        .aclk                 (aclk),
        .aresetn              (aresetn),
        .s_axis_term_tvalid   (c2_in_valid),
        .s_axis_term_tready   (c2_in_ready),
        .s_axis_term_tdata    (c2_in_data),
        .s_axis_term_tlast    (c2_in_last),
        .m_axis_result_tvalid (c2_out_valid),
        .m_axis_result_tready (c2_out_ready),
        .m_axis_result_tdata  (c2_out_data),
        .m_axis_result_tlast  (c2_out_last)
    );

    fp32_fma_interleaved_candidate u_candidate_3 (
        .aclk                 (aclk),
        .aresetn              (aresetn),
        .s_axis_term_tvalid   (c3_in_valid),
        .s_axis_term_tready   (c3_in_ready),
        .s_axis_term_tdata    (c3_in_data),
        .s_axis_term_tuser    (c3_in_user),
        .s_axis_term_tlast    (c3_in_last),
        .m_axis_result_tvalid (c3_out_valid),
        .m_axis_result_tready (c3_out_ready),
        .m_axis_result_tdata  (c3_out_data),
        .m_axis_result_tuser  (c3_out_user),
        .m_axis_result_tlast  (c3_out_last)
    );

    initial begin
        aclk = 1'b0;
        forever #2.5 aclk = ~aclk;
    end

    always @(posedge aclk) begin
        cycle_count <= cycle_count + 1;
    end

    task automatic record_error(input string message);
        begin
            error_count = error_count + 1;
            $error("P3_CHECK_FAIL cycle=%0d %s", cycle_count, message);
        end
    endtask

    // Candidate 3 acceptance monitor. The interleaved architecture is useful
    // only if independent contexts can be issued on consecutive clocks.
    always @(posedge aclk) begin
        if (aresetn &&
            c3_accept_monitor_enable &&
            c3_in_valid &&
            c3_in_ready) begin
            if ((c3_previous_accept_cycle >= 0) &&
                (cycle_count != (c3_previous_accept_cycle + 1))) begin
                record_error(
                    $sformatf(
                        "candidate3 acceptance gap=%0d, expected 1",
                        cycle_count - c3_previous_accept_cycle
                    )
                );
            end
            c3_previous_accept_cycle = cycle_count;
            c3_accept_count = c3_accept_count + 1;
        end
    end

    // Candidate 3 final-result scoreboard for contexts 0..23.
    always @(posedge aclk) begin
        if (aresetn &&
            c3_score_enable &&
            c3_out_valid &&
            c3_out_ready) begin
            if (c3_out_user !== c3_score_count[4:0]) begin
                record_error(
                    $sformatf(
                        "candidate3 result context=%0d, expected %0d",
                        c3_out_user,
                        c3_score_count
                    )
                );
            end
            if (c3_out_data !== FP32_THREE) begin
                record_error(
                    $sformatf(
                        "candidate3 context=%0d data=%08x, expected 40400000",
                        c3_out_user,
                        c3_out_data
                    )
                );
            end
            if (c3_out_last !== 1'b1) begin
                record_error("candidate3 final result missing TLAST");
            end
            c3_score_count = c3_score_count + 1;
        end
    end

    task automatic send_candidate1_term(
        input  logic [31:0] operand_a,
        input  logic [31:0] operand_b,
        input  logic        is_last,
        output integer      accepted_cycle
    );
        integer accepted;
        begin
            @(negedge aclk);
            c1_in_valid = 1'b1;
            c1_in_data  = {operand_b, operand_a};
            c1_in_last  = is_last;
            accepted = 0;
            while (accepted == 0) begin
                @(posedge aclk);
                if (c1_in_ready === 1'b1) begin
                    accepted_cycle = cycle_count;
                    accepted = 1;
                end
            end
            @(negedge aclk);
            c1_in_valid = 1'b0;
            c1_in_last  = 1'b0;
        end
    endtask

    task automatic stream_candidate3_round(
        input logic [31:0] operand_a,
        input logic [31:0] operand_b,
        input logic        is_last
    );
        integer context_id;
        integer accepted;
        begin
            c3_accept_count = 0;
            c3_previous_accept_cycle = -1;
            c3_accept_monitor_enable = 1'b1;
            for (context_id = 0; context_id < 24;
                 context_id = context_id + 1) begin
                @(negedge aclk);
                c3_in_valid = 1'b1;
                c3_in_data  = {operand_b, operand_a};
                c3_in_user  = context_id[4:0];
                c3_in_last  = is_last;
                accepted = 0;
                while (accepted == 0) begin
                    @(posedge aclk);
                    if (c3_in_ready === 1'b1) begin
                        accepted = 1;
                    end
                end
            end
            @(negedge aclk);
            c3_in_valid = 1'b0;
            c3_in_last  = 1'b0;
            c3_accept_monitor_enable = 1'b0;
            if (c3_accept_count != 24) begin
                record_error(
                    $sformatf(
                        "candidate3 accepted %0d terms, expected 24",
                        c3_accept_count
                    )
                );
            end
        end
    endtask

    task automatic send_candidate3_term(
        input logic [31:0] operand_a,
        input logic [31:0] operand_b,
        input logic [4:0]  context_id,
        input logic        is_last
    );
        integer accepted;
        begin
            @(negedge aclk);
            c3_in_valid = 1'b1;
            c3_in_data  = {operand_b, operand_a};
            c3_in_user  = context_id;
            c3_in_last  = is_last;
            accepted = 0;
            while (accepted == 0) begin
                @(posedge aclk);
                if (c3_in_ready === 1'b1) begin
                    accepted = 1;
                end
            end
            @(negedge aclk);
            c3_in_valid = 1'b0;
            c3_in_last  = 1'b0;
        end
    endtask

    task automatic wait_candidate1_valid;
        integer timeout_cycles;
        begin
            timeout_cycles = 0;
            while ((c1_out_valid !== 1'b1) && (timeout_cycles < 200)) begin
                @(posedge aclk);
                timeout_cycles = timeout_cycles + 1;
            end
            if (c1_out_valid !== 1'b1) begin
                $fatal(1, "P3_TIMEOUT candidate1 result");
            end
        end
    endtask

    task automatic wait_candidate2_valid;
        integer timeout_cycles;
        begin
            timeout_cycles = 0;
            while ((c2_out_valid !== 1'b1) && (timeout_cycles < 200)) begin
                @(posedge aclk);
                timeout_cycles = timeout_cycles + 1;
            end
            if (c2_out_valid !== 1'b1) begin
                $fatal(1, "P3_TIMEOUT candidate2 result");
            end
        end
    endtask

    task automatic wait_candidate3_valid;
        integer timeout_cycles;
        begin
            timeout_cycles = 0;
            while ((c3_out_valid !== 1'b1) && (timeout_cycles < 200)) begin
                @(posedge aclk);
                timeout_cycles = timeout_cycles + 1;
            end
            if (c3_out_valid !== 1'b1) begin
                $fatal(1, "P3_TIMEOUT candidate3 result");
            end
        end
    endtask

    integer c1_first_cycle;
    integer c1_second_cycle;
    integer c2_index;
    integer c2_accepted;
    integer c2_current_cycle;
    integer c2_previous_cycle;
    integer wait_cycles;
    logic [31:0] held_result;
    logic [4:0] held_context;

    initial begin
        cycle_count = 0;
        error_count = 0;
        aresetn = 1'b0;

        c1_in_valid = 1'b0;
        c1_in_data = 64'h0;
        c1_in_last = 1'b0;
        c1_out_ready = 1'b0;

        c2_in_valid = 1'b0;
        c2_in_data = 64'h0;
        c2_in_last = 1'b0;
        c2_out_ready = 1'b0;

        c3_in_valid = 1'b0;
        c3_in_data = 64'h0;
        c3_in_user = 5'h0;
        c3_in_last = 1'b0;
        c3_out_ready = 1'b0;
        c3_accept_monitor_enable = 1'b0;
        c3_accept_count = 0;
        c3_previous_accept_cycle = -1;
        c3_score_count = 0;
        c3_score_enable = 1'b0;

        c2_a_vector[0] = FP32_ONE;
        c2_b_vector[0] = FP32_TWO;
        c2_a_vector[1] = FP32_THREE;
        c2_b_vector[1] = FP32_FOUR;
        c2_a_vector[2] = FP32_FIVE;
        c2_b_vector[2] = FP32_HALF;

        // The Floating-Point Operator uses synchronous active-low reset.
        repeat (8) @(posedge aclk);
        if (c1_out_valid !== 1'b0 ||
            c2_out_valid !== 1'b0 ||
            c3_out_valid !== 1'b0) begin
            record_error("an output was valid while reset was asserted");
        end
        @(negedge aclk);
        aresetn = 1'b1;
        repeat (3) @(posedge aclk);
        if (c1_in_ready !== 1'b1 ||
            c2_in_ready !== 1'b1 ||
            c3_in_ready !== 1'b1) begin
            record_error("one or more candidates did not become ready after reset");
        end
        $display("P3_RESET_PASS cycle=%0d", cycle_count);

        // Candidate 1: 1*2 + 3*4 = 14. The feedback dependence must keep the
        // second term from being accepted at pipeline rate.
        send_candidate1_term(
            FP32_ONE, FP32_TWO, 1'b0, c1_first_cycle
        );
        send_candidate1_term(
            FP32_THREE, FP32_FOUR, 1'b1, c1_second_cycle
        );
        if ((c1_second_cycle - c1_first_cycle) < 22) begin
            record_error(
                $sformatf(
                    "candidate1 recurrence gap=%0d, expected at least 22",
                    c1_second_cycle - c1_first_cycle
                )
            );
        end
        wait_candidate1_valid();
        held_result = c1_out_data;
        repeat (4) begin
            @(posedge aclk);
            if (c1_out_valid !== 1'b1 ||
                c1_out_data !== held_result) begin
                record_error("candidate1 did not hold result during backpressure");
            end
        end
        if (held_result !== FP32_FOURTEEN || c1_out_last !== 1'b1) begin
            record_error(
                $sformatf(
                    "candidate1 result=%08x last=%0b, expected 41600000/1",
                    held_result,
                    c1_out_last
                )
            );
        end
        @(negedge aclk);
        c1_out_ready = 1'b1;
        @(posedge aclk);
        @(negedge aclk);
        c1_out_ready = 1'b0;
        $display(
            "P3_CANDIDATE1_PASS recurrence_accept_gap=%0d result=%08x",
            c1_second_cycle - c1_first_cycle,
            held_result
        );

        // Candidate 2: three consecutive products:
        // 1*2 + 3*4 + 5*0.5 = 16.5.
        c2_previous_cycle = -1;
        for (c2_index = 0; c2_index < 3; c2_index = c2_index + 1) begin
            @(negedge aclk);
            c2_in_valid = 1'b1;
            c2_in_data = {
                c2_b_vector[c2_index],
                c2_a_vector[c2_index]
            };
            c2_in_last = (c2_index == 2);
            c2_accepted = 0;
            while (c2_accepted == 0) begin
                @(posedge aclk);
                if (c2_in_ready === 1'b1) begin
                    c2_current_cycle = cycle_count;
                    c2_accepted = 1;
                end
            end
            if ((c2_previous_cycle >= 0) &&
                (c2_current_cycle != (c2_previous_cycle + 1))) begin
                record_error(
                    $sformatf(
                        "candidate2 acceptance gap=%0d, expected 1",
                        c2_current_cycle - c2_previous_cycle
                    )
                );
            end
            c2_previous_cycle = c2_current_cycle;
        end
        @(negedge aclk);
        c2_in_valid = 1'b0;
        c2_in_last = 1'b0;

        wait_candidate2_valid();
        held_result = c2_out_data;
        repeat (4) begin
            @(posedge aclk);
            if (c2_out_valid !== 1'b1 ||
                c2_out_data !== held_result) begin
                record_error("candidate2 did not hold result during backpressure");
            end
        end
        if (held_result !== FP32_16P5 || c2_out_last !== 1'b1) begin
            record_error(
                $sformatf(
                    "candidate2 result=%08x last=%0b, expected 41840000/1",
                    held_result,
                    c2_out_last
                )
            );
        end
        @(negedge aclk);
        c2_out_ready = 1'b1;
        @(posedge aclk);
        @(negedge aclk);
        c2_out_ready = 1'b0;
        $display(
            "P3_CANDIDATE2_PASS input_II=1 result=%08x",
            held_result
        );

        // Candidate 3: 24 independent contexts keep the 22-cycle FMA pipe
        // occupied. Each context computes 1*1 followed by 2*1 = 3.
        c3_out_ready = 1'b1;
        stream_candidate3_round(FP32_ONE, FP32_ONE, 1'b0);
        $display(
            "P3_CANDIDATE3_FIRST_ROUND_PASS contexts=24 input_II=1"
        );

        c3_score_count = 0;
        c3_score_enable = 1'b1;
        stream_candidate3_round(FP32_TWO, FP32_ONE, 1'b1);
        wait_cycles = 0;
        while ((c3_score_count < 24) && (wait_cycles < 300)) begin
            @(posedge aclk);
            wait_cycles = wait_cycles + 1;
        end
        if (c3_score_count != 24) begin
            $fatal(
                1,
                "P3_TIMEOUT candidate3 received %0d/24 results",
                c3_score_count
            );
        end
        @(negedge aclk);
        c3_score_enable = 1'b0;
        $display(
            "P3_CANDIDATE3_INTERLEAVED_PASS contexts=24 input_II=1 results=24"
        );

        // A final one-term context checks result backpressure and metadata
        // stability independently of the throughput measurement.
        repeat (2) @(posedge aclk);
        @(negedge aclk);
        c3_out_ready = 1'b0;
        send_candidate3_term(
            FP32_FOUR, FP32_TWO, 5'd31, 1'b1
        );
        wait_candidate3_valid();
        held_result = c3_out_data;
        held_context = c3_out_user;
        repeat (4) begin
            @(posedge aclk);
            if (c3_out_valid !== 1'b1 ||
                c3_out_data !== held_result ||
                c3_out_user !== held_context) begin
                record_error("candidate3 did not hold result during backpressure");
            end
        end
        if (held_result !== FP32_EIGHT ||
            held_context !== 5'd31 ||
            c3_out_last !== 1'b1) begin
            record_error(
                $sformatf(
                    "candidate3 result=%08x context=%0d last=%0b",
                    held_result,
                    held_context,
                    c3_out_last
                )
            );
        end
        @(negedge aclk);
        c3_out_ready = 1'b1;
        @(posedge aclk);
        @(negedge aclk);
        c3_out_ready = 1'b0;
        $display(
            "P3_CANDIDATE3_BACKPRESSURE_PASS context=%0d result=%08x",
            held_context,
            held_result
        );

        repeat (5) @(posedge aclk);
        if (error_count == 0) begin
            $display(
                "P3_SIM_PASS candidates=3 reset=PASS handshake=PASS arithmetic=PASS"
            );
            $finish;
        end
        $fatal(1, "P3_SIM_FAIL error_count=%0d", error_count);
    end

    initial begin
        repeat (5000) @(posedge aclk);
        $fatal(1, "P3_GLOBAL_TIMEOUT");
    end
endmodule
