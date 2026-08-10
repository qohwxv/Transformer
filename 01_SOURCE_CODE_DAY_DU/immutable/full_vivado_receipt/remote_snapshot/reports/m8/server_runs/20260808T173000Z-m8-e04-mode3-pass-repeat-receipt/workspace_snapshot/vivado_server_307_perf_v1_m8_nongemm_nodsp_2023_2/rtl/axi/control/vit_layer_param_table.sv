`timescale 1ns/1ps

// 192 x 32 software-visible layer-parameter table.
//
// Port A is used by AXI4-Lite for read/write access.  Port B is an
// independent synchronous read port used by the layer loader.  The data
// array is deliberately not reset: only the word-valid sideband is cleared,
// which keeps the data array compatible with block-RAM inference while still
// making every word read as zero after reset.  A partial first write exposes
// zero for all untouched bytes.
//
// Both ports are read-first for an A-port write/B-port read collision.  The
// production wrapper prevents writes while the loader can be active, so the
// collision rule is primarily useful for deterministic verification.
module vit_layer_param_table #(
    parameter integer WORD_COUNT = 192,
    parameter integer ADDR_WIDTH = 8
) (
    input  logic                  clk,
    input  logic                  rst,

    input  logic                  a_en_i,
    input  logic [ADDR_WIDTH-1:0] a_addr_i,
    input  logic [3:0]            a_we_i,
    input  logic [31:0]           a_wdata_i,
    output logic                  a_rvalid_o,
    output logic [31:0]           a_rdata_o,

    input  logic                  b_en_i,
    input  logic [ADDR_WIDTH-1:0] b_addr_i,
    output logic                  b_rvalid_o,
    output logic [31:0]           b_rdata_o
);

    // Vivado 2022.2 recognizes ram_style="block" for UltraScale+ RAMB18E2/
    // RAMB36E2 inference.  Keeping one unpacked data array and synchronous
    // registered reads also lets Yosys retain one $mem_v2 before mapping.
    (* ram_style = "block" *)
    logic [31:0] data_memory [0:WORD_COUNT-1];

    // Word validity is separate from the RAM data.  It is resettable control
    // state, not part of the inferred data memory.  On the first partial
    // write, all four RAM bytes are written and unselected bytes are forced
    // to zero; later partial writes use the native byte enables.
    logic [WORD_COUNT-1:0] word_valid;

    logic [31:0] a_raw_data;
    logic        a_word_valid;
    logic [31:0] b_raw_data;
    logic        b_word_valid;
    logic [3:0]  a_effective_we;
    logic [31:0] a_effective_wdata;

    assign a_rdata_o = a_word_valid ? a_raw_data : 32'd0;
    assign b_rdata_o = b_word_valid ? b_raw_data : 32'd0;
    assign a_effective_we =
        (|a_we_i && !word_valid[a_addr_i]) ? 4'hf : a_we_i;
    assign a_effective_wdata = word_valid[a_addr_i] ?
        a_wdata_i :
        {
            a_we_i[3] ? a_wdata_i[31:24] : 8'd0,
            a_we_i[2] ? a_wdata_i[23:16] : 8'd0,
            a_we_i[1] ? a_wdata_i[15:8]  : 8'd0,
            a_we_i[0] ? a_wdata_i[7:0]   : 8'd0
        };

    always_ff @(posedge clk) begin
        if (rst) begin
            word_valid  <= '0;
            a_raw_data  <= 32'd0;
            a_word_valid <= 1'b0;
            a_rvalid_o  <= 1'b0;
            b_raw_data  <= 32'd0;
            b_word_valid <= 1'b0;
            b_rvalid_o  <= 1'b0;
        end else begin
            a_rvalid_o <= a_en_i;
            b_rvalid_o <= b_en_i;

            if (a_en_i) begin
                a_raw_data <= data_memory[a_addr_i];
                a_word_valid <= word_valid[a_addr_i];

                if (a_effective_we[0])
                    data_memory[a_addr_i][7:0] <=
                        a_effective_wdata[7:0];
                if (a_effective_we[1])
                    data_memory[a_addr_i][15:8] <=
                        a_effective_wdata[15:8];
                if (a_effective_we[2])
                    data_memory[a_addr_i][23:16] <=
                        a_effective_wdata[23:16];
                if (a_effective_we[3])
                    data_memory[a_addr_i][31:24] <=
                        a_effective_wdata[31:24];
                if (|a_we_i)
                    word_valid[a_addr_i] <= 1'b1;
            end

            if (b_en_i) begin
                b_raw_data <= data_memory[b_addr_i];
                b_word_valid <= word_valid[b_addr_i];
            end
        end
    end

`ifndef SYNTHESIS
    initial begin
        if (WORD_COUNT != 192)
            $fatal(1, "vit_layer_param_table requires WORD_COUNT=192");
        if (ADDR_WIDTH < 8)
            $fatal(1, "vit_layer_param_table requires ADDR_WIDTH>=8");
    end
`endif

endmodule
