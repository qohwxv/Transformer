`timescale 1ns/1ps

module tb_vit_phase_e_perf_counters;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic start_accept = 1'b0;
    logic done = 1'b0;
    logic command_accept = 1'b0;
    logic axi_read_accept = 1'b0;
    logic axi_write_accept = 1'b0;
    logic axi_request_stall = 1'b0;

    logic running;
    logic snapshot_valid;
    logic [63:0] job_cycles;
    logic [63:0] command_count;
    logic [63:0] axi_read_count;
    logic [63:0] axi_write_count;
    logic [63:0] axi_request_stall_cycles;

    integer checks = 0;
    integer failures = 0;

    always #5 clk = ~clk;

    vit_phase_e_perf_counters dut (
        .clk                        (clk),
        .rst                        (rst),
        .start_accept_i             (start_accept),
        .done_i                     (done),
        .command_accept_i           (command_accept),
        .axi_read_accept_i          (axi_read_accept),
        .axi_write_accept_i         (axi_write_accept),
        .axi_request_stall_i        (axi_request_stall),
        .running_o                  (running),
        .snapshot_valid_o           (snapshot_valid),
        .job_cycles_o               (job_cycles),
        .command_count_o            (command_count),
        .axi_read_count_o           (axi_read_count),
        .axi_write_count_o          (axi_write_count),
        .axi_request_stall_cycles_o (axi_request_stall_cycles)
    );

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $error("PERF COUNTER CHECK FAILED: %s", message);
            end
        end
    endtask

    task automatic sample_cycle(
        input logic command_event,
        input logic read_event,
        input logic write_event,
        input logic stall_event,
        input logic done_event
    );
        begin
            @(negedge clk);
            command_accept = command_event;
            axi_read_accept = read_event;
            axi_write_accept = write_event;
            axi_request_stall = stall_event;
            done = done_event;
            @(posedge clk);
            #1;
            command_accept = 1'b0;
            axi_read_accept = 1'b0;
            axi_write_accept = 1'b0;
            axi_request_stall = 1'b0;
            done = 1'b0;
        end
    endtask

    initial begin
        repeat (3)
            @(posedge clk);
        #1;
        check(!running && !snapshot_valid, "reset status");
        check(
            (job_cycles == 0) &&
            (command_count == 0) &&
            (axi_read_count == 0) &&
            (axi_write_count == 0) &&
            (axi_request_stall_cycles == 0),
            "reset values"
        );

        @(negedge clk);
        rst = 1'b0;
        start_accept = 1'b1;
        @(posedge clk);
        #1;
        check(running && !snapshot_valid, "START enters running state");
        check(job_cycles == 0, "published snapshot clears at START");
        @(negedge clk);
        start_accept = 1'b0;

        sample_cycle(1'b1, 1'b1, 1'b0, 1'b1, 1'b0);
        sample_cycle(1'b0, 1'b0, 1'b1, 1'b1, 1'b0);
        sample_cycle(1'b1, 1'b1, 1'b1, 1'b0, 1'b0);
        sample_cycle(1'b1, 1'b1, 1'b1, 1'b1, 1'b1);

        check(!running && snapshot_valid, "DONE publishes and freezes snapshot");
        check(
            job_cycles == 64'd5,
            "launch handoff and terminal cycles are included"
        );
        check(command_count == 64'd3, "command events including DONE edge");
        check(axi_read_count == 64'd3, "read events including DONE edge");
        check(axi_write_count == 64'd3, "write events including DONE edge");
        check(
            axi_request_stall_cycles == 64'd3,
            "stall events including DONE edge"
        );

        sample_cycle(1'b1, 1'b1, 1'b1, 1'b1, 1'b0);
        sample_cycle(1'b1, 1'b1, 1'b1, 1'b1, 1'b0);
        check(job_cycles == 64'd5, "snapshot remains stable after DONE");
        check(command_count == 64'd3, "events after DONE are ignored");

        @(negedge clk);
        start_accept = 1'b1;
        @(posedge clk);
        #1;
        check(running && !snapshot_valid, "second START invalidates old snapshot");
        check(
            (job_cycles == 0) &&
            (command_count == 0) &&
            (axi_read_count == 0) &&
            (axi_write_count == 0) &&
            (axi_request_stall_cycles == 0),
            "second START clears all published counters"
        );
        @(negedge clk);
        start_accept = 1'b0;

        sample_cycle(1'b0, 1'b0, 1'b0, 1'b0, 1'b0);
        @(negedge clk);
        rst = 1'b1;
        @(posedge clk);
        #1;
        check(!running && !snapshot_valid, "reset aborts active measurement");
        check(job_cycles == 0, "reset clears active measurement");

        if (failures == 0)
            $display(
                "VIT_PHASE_E_PERF_COUNTERS_TEST_PASS checks=%0d",
                checks
            );
        else
            $fatal(1, "perf counter failures=%0d checks=%0d", failures, checks);
        $finish;
    end

endmodule
