`timescale 1ns/1ps

// Two-entry M7 GEMM result FIFO.
//
// Each entry captures the complete store identity at enqueue time.  In
// particular, result_address_base is an absolute 66-bit word-address context;
// it must not be reconstructed from a later GEMM load context while this
// result is waiting for the store path.  With the locked R8/C2 geometry and
// an eight-bit generation tag, one entry is exactly 692 bits:
//
//   512 data + 66 absolute base + 3*32 coordinates
//       + 8 token mask + 2 output mask + 8 generation = 692 bits.
//
// The FIFO accepts a replacement entry on the same cycle that a full FIFO
// pops its head.  A stalled head is never overwritten and remains stable
// until output_ready_i or an explicit reset/flush.
(* keep_hierarchy = "yes", use_dsp = "no" *)
module vit_gemm_result_fifo #(
    parameter integer ARRAY_ROWS = 8,
    parameter integer ARRAY_COLS = 2,
    parameter integer GENERATION_BITS = 8,
    parameter integer DEPTH = 2
) (
    input  logic                                    clk,
    input  logic                                    rst,
    input  logic                                    flush_i,

    input  logic                                    input_valid_i,
    output logic                                    input_ready_o,
    input  logic [65:0]                             input_address_base_i,
    input  logic [31:0]                             input_token_base_i,
    input  logic [31:0]                             input_output_base_i,
    input  logic [31:0]                             input_batch_index_i,
    input  logic [ARRAY_ROWS-1:0]                   input_token_mask_i,
    input  logic [ARRAY_COLS-1:0]                   input_output_mask_i,
    input  logic [GENERATION_BITS-1:0]              input_generation_i,
    input  logic [ARRAY_ROWS*ARRAY_COLS*32-1:0]     input_data_i,

    output logic                                    output_valid_o,
    input  logic                                    output_ready_i,
    output logic [65:0]                             output_address_base_o,
    output logic [31:0]                             output_token_base_o,
    output logic [31:0]                             output_output_base_o,
    output logic [31:0]                             output_batch_index_o,
    output logic [ARRAY_ROWS-1:0]                   output_token_mask_o,
    output logic [ARRAY_COLS-1:0]                   output_output_mask_o,
    output logic [GENERATION_BITS-1:0]              output_generation_o,
    output logic [ARRAY_ROWS*ARRAY_COLS*32-1:0]     output_data_o,

    // Exact one-cycle event hooks for the append-only M7 profile bank.
    output logic                                    push_fire_o,
    output logic                                    pop_fire_o,
    output logic [1:0]                              occupancy_o
);

    localparam integer DATA_BITS = ARRAY_ROWS * ARRAY_COLS * 32;
    localparam integer ENTRY_BITS =
        DATA_BITS + 66 + 32 + 32 + 32 +
        ARRAY_ROWS + ARRAY_COLS + GENERATION_BITS;

    logic [ENTRY_BITS-1:0] entry_memory [0:1];
    logic                  read_pointer_q;
    logic                  write_pointer_q;
    logic [1:0]            count_q;
    logic [ENTRY_BITS-1:0] input_entry;
    logic [ENTRY_BITS-1:0] output_entry;

    initial begin
        if (ARRAY_ROWS <= 0)
            $fatal(1, "vit_gemm_result_fifo requires ARRAY_ROWS > 0");
        if (ARRAY_COLS <= 0)
            $fatal(1, "vit_gemm_result_fifo requires ARRAY_COLS > 0");
        if (GENERATION_BITS <= 0)
            $fatal(1, "vit_gemm_result_fifo requires GENERATION_BITS > 0");
        if (DEPTH != 2)
            $fatal(1, "vit_gemm_result_fifo is intentionally fixed at depth 2");
    end

    // Packing order is part of this leaf's local contract.  Keeping the
    // complete entry in one array makes simultaneous full pop+push atomic.
    assign input_entry = {
        input_generation_i,
        input_batch_index_i,
        input_output_base_i,
        input_token_base_i,
        input_address_base_i,
        input_output_mask_i,
        input_token_mask_i,
        input_data_i
    };

    assign output_valid_o = !rst && !flush_i && (count_q != 2'd0);
    assign pop_fire_o = output_valid_o && output_ready_i;

    // Look through a same-cycle pop when full.  This is the no-bubble case:
    // the old head is consumed and the new tail is accepted on one edge.
    assign input_ready_o =
        !rst && !flush_i && ((count_q != 2'd2) || pop_fire_o);
    assign push_fire_o = input_valid_i && input_ready_o;
    assign occupancy_o = (rst || flush_i) ? 2'd0 : count_q;

    always_comb begin
        output_entry = '0;
        if (output_valid_o)
            output_entry = entry_memory[read_pointer_q];
    end

    assign {
        output_generation_o,
        output_batch_index_o,
        output_output_base_o,
        output_token_base_o,
        output_address_base_o,
        output_output_mask_o,
        output_token_mask_o,
        output_data_o
    } = output_entry;

    always_ff @(posedge clk) begin
        if (rst || flush_i) begin
            read_pointer_q  <= 1'b0;
            write_pointer_q <= 1'b0;
            count_q         <= 2'd0;
        end else begin
            if (push_fire_o) begin
                entry_memory[write_pointer_q] <= input_entry;
                write_pointer_q <= ~write_pointer_q;
            end

            if (pop_fire_o)
                read_pointer_q <= ~read_pointer_q;

            case ({push_fire_o, pop_fire_o})
                2'b10: count_q <= count_q + 2'd1;
                2'b01: count_q <= count_q - 2'd1;
                default: count_q <= count_q;
            endcase
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (!rst && !flush_i && (count_q > 2'd2))
            $fatal(1, "vit_gemm_result_fifo occupancy exceeded depth 2");
    end
`endif

endmodule
