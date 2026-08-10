`timescale 1ns/1ps

module tb_vit_gemm_dot16_serial;

    localparam integer RANDOM_CASES = 1000;

    logic clk;
    logic rst;
    logic start;
    logic [15:0] lane_valid;
    logic [511:0] activation_lanes;
    logic [511:0] weight_lanes;
    logic serial_busy;
    logic serial_done;
    logic [31:0] serial_result;
    logic [31:0] parallel_result;

    integer case_index;
    integer lane_index;
    integer timeout_cycles;
    integer check_count;
    logic [31:0] expected_result;

    vit_gemm_dot16 u_parallel_reference (
        .lane_valid       (lane_valid),
        .activation_lanes (activation_lanes),
        .weight_lanes     (weight_lanes),
        .partial_sum      (parallel_result)
    );

    vit_gemm_dot16_serial u_serial_dut (
        .clk              (clk),
        .rst              (rst),
        .start            (start),
        .lane_valid       (lane_valid),
        .activation_lanes (activation_lanes),
        .weight_lanes     (weight_lanes),
        .busy             (serial_busy),
        .done             (serial_done),
        .partial_sum      (serial_result)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic run_current_case;
        begin
            #1;
            expected_result = parallel_result;

            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;

            // Accepted operands must be held internally throughout the
            // 16-product and 15-add schedule.
            lane_valid      = 16'hffff;
            activation_lanes = {16{32'h7fc0_0000}};
            weight_lanes     = {16{32'h7f80_0000}};

            timeout_cycles = 0;
            while (!serial_done && (timeout_cycles < 80)) begin
                @(negedge clk);
                timeout_cycles = timeout_cycles + 1;
            end
            #1;
            if (timeout_cycles >= 80)
                $fatal(1, "serial dot-product timeout");
            if (serial_result !== expected_result)
                $fatal(
                    1,
                    "dot mismatch case=%0d expected=%08x actual=%08x",
                    case_index,
                    expected_result,
                    serial_result
                );

            check_count = check_count + 1;
            @(posedge clk);
        end
    endtask

    initial begin
        rst              = 1'b1;
        start            = 1'b0;
        lane_valid       = 16'd0;
        activation_lanes = '0;
        weight_lanes     = '0;
        check_count      = 0;
        case_index       = 0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // Empty K-tail.
        lane_valid = 16'd0;
        activation_lanes = {16{32'h7fc0_0000}};
        weight_lanes = {16{32'h7f80_0000}};
        run_current_case();

        // One valid lane with poisoned tail.
        case_index = 1;
        lane_valid = 16'h0001;
        activation_lanes = {16{32'h7fc0_0000}};
        weight_lanes = {16{32'h7f80_0000}};
        activation_lanes[31:0] = 32'h3fc0_0000;
        weight_lanes[31:0] = 32'h4000_0000;
        run_current_case();

        // Random raw FP32 words cover normals, zeros, infinities, NaNs, signs,
        // cancellation, and arbitrary tail masks. Equivalence is bit exact.
        for (case_index = 2; case_index < (RANDOM_CASES + 2);
             case_index = case_index + 1) begin
            lane_valid = $urandom;
            for (lane_index = 0; lane_index < 16;
                 lane_index = lane_index + 1) begin
                activation_lanes[lane_index*32 +: 32] = $urandom;
                weight_lanes[lane_index*32 +: 32] = $urandom;
            end
            run_current_case();
        end

        $display(
            "GEMM_DOT16_SERIAL_EQUIVALENCE_PASS checks=%0d",
            check_count
        );
        $finish;
    end

endmodule
