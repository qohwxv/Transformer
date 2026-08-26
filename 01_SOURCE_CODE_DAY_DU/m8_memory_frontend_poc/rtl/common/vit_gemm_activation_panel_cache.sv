`timescale 1ns/1ps

// Banked on-chip cache for one GEMM activation panel.
//
// Each array row owns one synchronous-read memory bank indexed by K. Keeping
// the row banks separate removes a runtime row*K address multiplier and gives
// the synthesis tool a simple one-read/one-write RAM template.
//
// Tags and fill/valid policy deliberately stay in the memory frontend. This
// leaf only stores words and returns one word one cycle after read_enable.
(* use_dsp = "no" *)
module vit_gemm_activation_panel_cache #(
    parameter integer ARRAY_ROWS = 2,
    parameter integer DEPTH_WORDS_PER_ROW = 3072
) (
    input  logic clk,
    input  logic rst,
    input  logic clear,

    input  logic write_enable,
    input  logic [((ARRAY_ROWS <= 1) ? 1 : $clog2(ARRAY_ROWS))-1:0]
                 write_row,
    input  logic [31:0] write_k_index,
    input  logic [31:0] write_data,

    input  logic read_enable,
    input  logic [((ARRAY_ROWS <= 1) ? 1 : $clog2(ARRAY_ROWS))-1:0]
                 read_row,
    input  logic [31:0] read_k_index,
    output logic read_data_valid,
    output logic [31:0] read_data,

    // M7 packed-mode vector port.  All row banks share one K index and return
    // one word per row in the same cycle.  It reuses each bank's existing
    // read port, so scalar and vector requests are deliberately exclusive.
    input  logic vector_read_enable,
    input  logic [31:0] vector_read_k_index,
    output logic vector_read_data_valid,
    output logic [ARRAY_ROWS*32-1:0] vector_read_data
);

    localparam integer ROW_INDEX_WIDTH =
        (ARRAY_ROWS <= 1) ? 1 : $clog2(ARRAY_ROWS);
    localparam integer ADDRESS_WIDTH =
        (DEPTH_WORDS_PER_ROW <= 1)
            ? 1
            : $clog2(DEPTH_WORDS_PER_ROW);

    logic [ROW_INDEX_WIDTH-1:0] read_row_hold;
    logic [31:0] bank_read_data [0:ARRAY_ROWS-1];

    initial begin
        if (ARRAY_ROWS <= 0)
            $fatal(
                1,
                "vit_gemm_activation_panel_cache requires ARRAY_ROWS > 0"
            );
        if (DEPTH_WORDS_PER_ROW <= 0)
            $fatal(
                1,
                "vit_gemm_activation_panel_cache requires DEPTH > 0"
            );
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst && read_enable && vector_read_enable)
            $fatal(1, "activation cache scalar/vector read collision");
    end
`endif

    always_ff @(posedge clk) begin
        if (rst || clear) begin
            read_data_valid <= 1'b0;
            vector_read_data_valid <= 1'b0;
            read_row_hold <= '0;
        end else begin
            read_data_valid <= read_enable && !vector_read_enable;
            vector_read_data_valid <= vector_read_enable;
            if (read_enable && !vector_read_enable)
                read_row_hold <= read_row;
        end
    end

    integer read_mux_row;
    always_comb begin
        read_data = 32'd0;
        vector_read_data = '0;
        for (
            read_mux_row = 0;
            read_mux_row < ARRAY_ROWS;
            read_mux_row = read_mux_row + 1
        ) begin
            if (read_row_hold == ROW_INDEX_WIDTH'(read_mux_row))
                read_data = bank_read_data[read_mux_row];
            vector_read_data[read_mux_row*32 +: 32] =
                bank_read_data[read_mux_row];
        end
    end

    genvar bank_index;
    generate
        for (
            bank_index = 0;
            bank_index < ARRAY_ROWS;
            bank_index = bank_index + 1
        ) begin : gen_row_bank
            (* ram_style = "block" *)
            logic [31:0] row_memory [0:DEPTH_WORDS_PER_ROW-1];
            logic bank_read_enable;
            logic [ADDRESS_WIDTH-1:0] bank_read_address;

            // Present exactly one synchronous read port to RAM inference.
            // Keeping two conditional array reads with different address
            // expressions makes Vivado treat the mutually-exclusive scalar
            // and vector paths as two read ports, which cannot map together
            // with the write port to RAMB36.  Muxing before the single array
            // access preserves the old scalar behavior and the M7 vector
            // behavior while retaining a one-read/one-write SDP template.
            assign bank_read_enable = vector_read_enable ||
                (read_enable &&
                 (read_row == ROW_INDEX_WIDTH'(bank_index)));
            assign bank_read_address = vector_read_enable ?
                vector_read_k_index[ADDRESS_WIDTH-1:0] :
                read_k_index[ADDRESS_WIDTH-1:0];

            always_ff @(posedge clk) begin
                if (
                    write_enable &&
                    (write_row == ROW_INDEX_WIDTH'(bank_index))
                )
                    row_memory[
                        write_k_index[ADDRESS_WIDTH-1:0]
                    ] <= write_data;

                if (bank_read_enable)
                    bank_read_data[bank_index] <=
                        row_memory[bank_read_address];
            end
        end
    endgenerate

endmodule
