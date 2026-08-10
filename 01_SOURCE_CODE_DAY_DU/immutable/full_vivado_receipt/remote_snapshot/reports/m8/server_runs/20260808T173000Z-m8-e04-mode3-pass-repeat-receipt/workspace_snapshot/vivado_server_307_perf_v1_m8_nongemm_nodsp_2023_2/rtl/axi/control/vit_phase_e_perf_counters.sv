`timescale 1ns/1ps

// Per-job performance counters for the production AXI wrapper.
//
// START clears both the live and published values.  DONE atomically publishes
// all five counters, including events sampled on the DONE edge.  Software only
// reads the published bank, so a 64-bit LO/HI pair cannot tear while a job is
// running.  All counters wrap modulo 2^64.
(* use_dsp = "no" *)
module vit_phase_e_perf_counters (
    input  logic        clk,
    input  logic        rst,

    input  logic        start_accept_i,
    input  logic        done_i,
    input  logic        command_accept_i,
    input  logic        axi_read_accept_i,
    input  logic        axi_write_accept_i,
    input  logic        axi_request_stall_i,

    output logic        running_o,
    output logic        snapshot_valid_o,
    output logic [63:0] job_cycles_o,
    output logic [63:0] command_count_o,
    output logic [63:0] axi_read_count_o,
    output logic [63:0] axi_write_count_o,
    output logic [63:0] axi_request_stall_cycles_o
);

    logic [63:0] live_job_cycles;
    logic [63:0] live_command_count;
    logic [63:0] live_axi_read_count;
    logic [63:0] live_axi_write_count;
    logic [63:0] live_axi_request_stall_cycles;

    always_ff @(posedge clk) begin
        if (rst) begin
            running_o                       <= 1'b0;
            snapshot_valid_o                <= 1'b0;
            live_job_cycles                 <= 64'd0;
            live_command_count               <= 64'd0;
            live_axi_read_count               <= 64'd0;
            live_axi_write_count              <= 64'd0;
            live_axi_request_stall_cycles     <= 64'd0;
            job_cycles_o                      <= 64'd0;
            command_count_o                   <= 64'd0;
            axi_read_count_o                   <= 64'd0;
            axi_write_count_o                  <= 64'd0;
            axi_request_stall_cycles_o         <= 64'd0;
        end else if (start_accept_i) begin
            running_o                       <= 1'b1;
            snapshot_valid_o                <= 1'b0;
            live_job_cycles                 <= 64'd0;
            live_command_count               <= 64'd0;
            live_axi_read_count               <= 64'd0;
            live_axi_write_count              <= 64'd0;
            live_axi_request_stall_cycles     <= 64'd0;
            job_cycles_o                      <= 64'd0;
            command_count_o                   <= 64'd0;
            axi_read_count_o                   <= 64'd0;
            axi_write_count_o                  <= 64'd0;
            axi_request_stall_cycles_o         <= 64'd0;
        end else if (running_o) begin
            live_job_cycles <= live_job_cycles + 64'd1;
            if (command_accept_i)
                live_command_count <= live_command_count + 64'd1;
            if (axi_read_accept_i)
                live_axi_read_count <= live_axi_read_count + 64'd1;
            if (axi_write_accept_i)
                live_axi_write_count <= live_axi_write_count + 64'd1;
            if (axi_request_stall_i)
                live_axi_request_stall_cycles <=
                    live_axi_request_stall_cycles + 64'd1;

            if (done_i) begin
                running_o        <= 1'b0;
                snapshot_valid_o <= 1'b1;
                job_cycles_o     <= live_job_cycles + 64'd1;
                command_count_o  <= live_command_count +
                    (command_accept_i ? 64'd1 : 64'd0);
                axi_read_count_o <= live_axi_read_count +
                    (axi_read_accept_i ? 64'd1 : 64'd0);
                axi_write_count_o <= live_axi_write_count +
                    (axi_write_accept_i ? 64'd1 : 64'd0);
                axi_request_stall_cycles_o <=
                    live_axi_request_stall_cycles +
                    (axi_request_stall_i ? 64'd1 : 64'd0);
            end
        end
    end

endmodule
