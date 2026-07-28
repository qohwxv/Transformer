`timescale 1ns/1ps

// Bit-preserving scalar data mover driven by one rank-3 strided descriptor.
// Destination words are emitted contiguously while source addresses follow:
//
//   src = cfg_src_base
//       + index0 * cfg_src_stride0
//       + index1 * cfg_src_stride1
//       + index2 * cfg_src_stride2
//
//   dst = cfg_dst_base + linear_output_index
//
// A rank-1 transfer uses dim0=1, dim1=1, and dim2=length. A rank-2 transfer
// uses dim0=1. Keeping the mover generic lets the controller express every
// D06 operation without embedding ViT dimensions in this datapath:
//
//   patch transpose: dims [1,196,768], strides [0,1,196]
//   split heads:     dims [12,197,64], strides [64,768,1]
//   K transpose:     dims [12,64,197], strides [12608,1,64]
//   merge heads:     dims [197,12,64], strides [64,12608,1]
//   select CLS:      dims [1,1,768], strides [0,0,1]
//
// Prepending CLS uses two descriptors with different cfg_src_bank and
// cfg_dst_base values: copy 768 CLS words to destination zero, then copy the
// patch tensor to destination 768.
module vit_layout_engine (
    input  logic            clk,
    input  logic            rst,

    input  logic            start,
    input  logic            cfg_src_bank,
    input  logic [31:0]     cfg_src_base,
    input  logic [31:0]     cfg_dst_base,
    input  logic [31:0]     cfg_dim0,
    input  logic [31:0]     cfg_dim1,
    input  logic [31:0]     cfg_dim2,
    input  logic [31:0]     cfg_src_stride0,
    input  logic [31:0]     cfg_src_stride1,
    input  logic [31:0]     cfg_src_stride2,
    output logic            busy,
    output logic            done,
    output logic            config_error,

    // The source request and address remain stable until data_valid accepts
    // the word. src_bank selects one of the testbench/scratchpad source banks.
    output logic            data_request,
    input  logic            data_valid,
    output logic            src_bank,
    output logic [31:0]     source_address,
    input  logic [31:0]     source_data,

    // Result data and destination address remain stable until result_ready.
    output logic            result_valid,
    input  logic            result_ready,
    output logic [31:0]     result_address,
    output logic [31:0]     result_data
);

    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_REQUEST,
        STATE_WRITE,
        STATE_DONE
    } state_t;

    state_t state;

    logic active_src_bank;
    logic [31:0] active_src_base;
    logic [31:0] active_dst_base;
    logic [31:0] active_dim1;
    logic [31:0] active_dim2;
    logic [31:0] active_src_stride0;
    logic [31:0] active_src_stride1;
    logic [31:0] active_src_stride2;
    logic [31:0] active_total_words;

    logic [31:0] index0;
    logic [31:0] index1;
    logic [31:0] index2;
    logic [31:0] linear_output_index;
    logic [31:0] result_address_reg;
    logic [31:0] result_data_reg;

    logic [95:0] cfg_total_words;
    logic [95:0] cfg_max_source_address;
    logic [95:0] cfg_last_destination_address;
    logic [63:0] mapped_source_address;

    assign busy = (state != STATE_IDLE);
    assign done = (state == STATE_DONE);
    assign data_request = (state == STATE_REQUEST);
    assign src_bank = active_src_bank;
    assign source_address = mapped_source_address[31:0];
    assign result_valid = (state == STATE_WRITE);
    assign result_address = result_address_reg;
    assign result_data = result_data_reg;

    // Use wide intermediates so invalid descriptors that overflow the 32-bit
    // word-address interface can be rejected when start is accepted.
    always_comb begin
        cfg_total_words = {64'd0, cfg_dim0} * cfg_dim1;
        cfg_total_words = cfg_total_words * cfg_dim2;

        cfg_max_source_address = {64'd0, cfg_src_base};
        cfg_max_source_address = cfg_max_source_address +
            ({64'd0, cfg_dim0 - 32'd1} * cfg_src_stride0);
        cfg_max_source_address = cfg_max_source_address +
            ({64'd0, cfg_dim1 - 32'd1} * cfg_src_stride1);
        cfg_max_source_address = cfg_max_source_address +
            ({64'd0, cfg_dim2 - 32'd1} * cfg_src_stride2);

        cfg_last_destination_address = {64'd0, cfg_dst_base};
        if (cfg_total_words != 0)
            cfg_last_destination_address =
                cfg_last_destination_address + cfg_total_words - 1;
    end

    always_comb begin
        mapped_source_address = {32'd0, active_src_base};
        mapped_source_address = mapped_source_address +
            ({32'd0, index0} * active_src_stride0);
        mapped_source_address = mapped_source_address +
            ({32'd0, index1} * active_src_stride1);
        mapped_source_address = mapped_source_address +
            ({32'd0, index2} * active_src_stride2);
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state                      <= STATE_IDLE;
            config_error               <= 1'b0;
            active_src_bank            <= 1'b0;
            active_src_base            <= 32'd0;
            active_dst_base            <= 32'd0;
            active_dim1                <= 32'd0;
            active_dim2                <= 32'd0;
            active_src_stride0         <= 32'd0;
            active_src_stride1         <= 32'd0;
            active_src_stride2         <= 32'd0;
            active_total_words         <= 32'd0;
            index0                     <= 32'd0;
            index1                     <= 32'd0;
            index2                     <= 32'd0;
            linear_output_index        <= 32'd0;
            result_address_reg         <= 32'd0;
            result_data_reg            <= 32'd0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (start) begin
                        index0              <= 32'd0;
                        index1              <= 32'd0;
                        index2              <= 32'd0;
                        linear_output_index <= 32'd0;

                        if ((cfg_dim0 == 0) || (cfg_dim1 == 0) ||
                            (cfg_dim2 == 0) || (cfg_total_words[95:32] != 0) ||
                            (cfg_max_source_address[95:32] != 0) ||
                            (cfg_last_destination_address[95:32] != 0)) begin
                            config_error <= 1'b1;
                            state <= STATE_DONE;
                        end else begin
                            config_error       <= 1'b0;
                            active_src_bank    <= cfg_src_bank;
                            active_src_base    <= cfg_src_base;
                            active_dst_base    <= cfg_dst_base;
                            active_dim1        <= cfg_dim1;
                            active_dim2        <= cfg_dim2;
                            active_src_stride0 <= cfg_src_stride0;
                            active_src_stride1 <= cfg_src_stride1;
                            active_src_stride2 <= cfg_src_stride2;
                            active_total_words <= cfg_total_words[31:0];
                            state              <= STATE_REQUEST;
                        end
                    end
                end

                STATE_REQUEST: begin
                    if (data_valid) begin
                        result_address_reg <= active_dst_base + linear_output_index;
                        result_data_reg <= source_data;
                        state <= STATE_WRITE;
                    end
                end

                STATE_WRITE: begin
                    if (result_ready) begin
                        if ((linear_output_index + 1) >= active_total_words) begin
                            state <= STATE_DONE;
                        end else begin
                            linear_output_index <= linear_output_index + 1;

                            if ((index2 + 1) < active_dim2) begin
                                index2 <= index2 + 1;
                            end else begin
                                index2 <= 32'd0;
                                if ((index1 + 1) < active_dim1) begin
                                    index1 <= index1 + 1;
                                end else begin
                                    index1 <= 32'd0;
                                    index0 <= index0 + 1;
                                end
                            end
                            state <= STATE_REQUEST;
                        end
                    end
                end

                STATE_DONE: begin
                    state <= STATE_IDLE;
                end

                default: begin
                    config_error <= 1'b1;
                    state <= STATE_IDLE;
                end
            endcase
        end
    end

endmodule
