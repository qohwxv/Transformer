`timescale 1ns/1ps

// Incremental rank-3 strided address generator.  It replaces three address
// multipliers with adders and three small index counters.
module vit_layout_address_generator (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic        advance,
    input  logic [31:0] cfg_src_base,
    input  logic [31:0] cfg_dim1,
    input  logic [31:0] cfg_dim2,
    input  logic [31:0] cfg_src_stride0,
    input  logic [31:0] cfg_src_stride1,
    input  logic [31:0] cfg_src_stride2,
    output logic [31:0] source_address
);

    logic [31:0] active_dim1;
    logic [31:0] active_dim2;
    logic [31:0] active_stride0;
    logic [31:0] active_stride1;
    logic [31:0] active_stride2;
    logic [31:0] index1;
    logic [31:0] index2;
    logic [31:0] plane_base_address;
    logic [31:0] row_base_address;

    always_ff @(posedge clk) begin
        if (rst) begin
            active_dim1       <= 32'd0;
            active_dim2       <= 32'd0;
            active_stride0    <= 32'd0;
            active_stride1    <= 32'd0;
            active_stride2    <= 32'd0;
            index1            <= 32'd0;
            index2            <= 32'd0;
            plane_base_address <= 32'd0;
            row_base_address   <= 32'd0;
            source_address     <= 32'd0;
        end else if (start) begin
            active_dim1        <= cfg_dim1;
            active_dim2        <= cfg_dim2;
            active_stride0     <= cfg_src_stride0;
            active_stride1     <= cfg_src_stride1;
            active_stride2     <= cfg_src_stride2;
            index1             <= 32'd0;
            index2             <= 32'd0;
            plane_base_address <= cfg_src_base;
            row_base_address   <= cfg_src_base;
            source_address     <= cfg_src_base;
        end else if (advance) begin
            if ((index2 + 1'b1) < active_dim2) begin
                index2        <= index2 + 1'b1;
                source_address <= source_address + active_stride2;
            end else if ((index1 + 1'b1) < active_dim1) begin
                index1          <= index1 + 1'b1;
                index2          <= 32'd0;
                row_base_address <= row_base_address + active_stride1;
                source_address   <= row_base_address + active_stride1;
            end else begin
                index1             <= 32'd0;
                index2             <= 32'd0;
                plane_base_address <= plane_base_address + active_stride0;
                row_base_address   <= plane_base_address + active_stride0;
                source_address     <= plane_base_address + active_stride0;
            end
        end
    end

endmodule
