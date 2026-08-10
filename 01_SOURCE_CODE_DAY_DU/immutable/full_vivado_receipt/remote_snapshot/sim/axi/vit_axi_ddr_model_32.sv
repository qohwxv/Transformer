`timescale 1ns/1ps

// Simulation-only, three-region AXI4 DDR model for the Phase-E wrapper.
//
// The model deliberately implements the same narrow contract as the current
// production adapter: one 32-bit beat per transaction and one outstanding
// read/write response.  MODEL and INPUT are read-only from the PL master;
// SCRATCH is read/write.  Public memories allow a testbench to preload a
// compact model without adding a second path into the DUT.
module vit_axi_ddr_model_32 #(
    parameter integer AXI_ADDR_WIDTH = 40,
    parameter integer AXI_ID_WIDTH = 1,
    parameter integer MODEL_WORDS = 32768,
    parameter integer INPUT_WORDS = 32,
    parameter integer SCRATCH_WORDS = 32'h001e_6000,
    parameter logic [63:0] MODEL_BASE = 64'h0000_0010_0000_0000,
    parameter logic [63:0] INPUT_BASE = 64'h0000_0020_0000_0000,
    parameter logic [63:0] SCRATCH_BASE = 64'h0000_0030_0000_0000,
    parameter logic STALL_ENABLE = 1'b1
) (
    input  logic                          aclk,
    input  logic                          aresetn,

    input  logic [AXI_ID_WIDTH-1:0]       s_axi_awid,
    input  logic [AXI_ADDR_WIDTH-1:0]     s_axi_awaddr,
    input  logic [7:0]                    s_axi_awlen,
    input  logic [2:0]                    s_axi_awsize,
    input  logic [1:0]                    s_axi_awburst,
    input  logic                          s_axi_awlock,
    input  logic [3:0]                    s_axi_awcache,
    input  logic [2:0]                    s_axi_awprot,
    input  logic [3:0]                    s_axi_awqos,
    input  logic                          s_axi_awvalid,
    output logic                          s_axi_awready,

    input  logic [31:0]                   s_axi_wdata,
    input  logic [3:0]                    s_axi_wstrb,
    input  logic                          s_axi_wlast,
    input  logic                          s_axi_wvalid,
    output logic                          s_axi_wready,

    output logic [AXI_ID_WIDTH-1:0]       s_axi_bid,
    output logic [1:0]                    s_axi_bresp,
    output logic                          s_axi_bvalid,
    input  logic                          s_axi_bready,

    input  logic [AXI_ID_WIDTH-1:0]       s_axi_arid,
    input  logic [AXI_ADDR_WIDTH-1:0]     s_axi_araddr,
    input  logic [7:0]                    s_axi_arlen,
    input  logic [2:0]                    s_axi_arsize,
    input  logic [1:0]                    s_axi_arburst,
    input  logic                          s_axi_arlock,
    input  logic [3:0]                    s_axi_arcache,
    input  logic [2:0]                    s_axi_arprot,
    input  logic [3:0]                    s_axi_arqos,
    input  logic                          s_axi_arvalid,
    output logic                          s_axi_arready,

    output logic [AXI_ID_WIDTH-1:0]       s_axi_rid,
    output logic [31:0]                   s_axi_rdata,
    output logic [1:0]                    s_axi_rresp,
    output logic                          s_axi_rlast,
    output logic                          s_axi_rvalid,
    input  logic                          s_axi_rready,

    output logic [63:0]                   read_count_o,
    output logic [63:0]                   write_count_o,
    output logic [63:0]                   model_read_count_o,
    output logic [63:0]                   input_read_count_o,
    output logic [63:0]                   scratch_read_count_o,
    output logic [63:0]                   scratch_write_count_o,
    output logic [31:0]                   invalid_access_count_o
);

    localparam logic [1:0] AXI_RESP_OKAY = 2'b00;
    localparam logic [1:0] AXI_RESP_SLVERR = 2'b10;
    localparam logic [1:0] AXI_BURST_INCR = 2'b01;

    localparam logic [1:0] REGION_NONE = 2'd0;
    localparam logic [1:0] REGION_MODEL = 2'd1;
    localparam logic [1:0] REGION_INPUT = 2'd2;
    localparam logic [1:0] REGION_SCRATCH = 2'd3;

    logic [31:0] model_memory [0:MODEL_WORDS-1];
    logic [31:0] input_memory [0:INPUT_WORDS-1];
    logic [31:0] scratch_memory [0:SCRATCH_WORDS-1];

    logic [63:0] cycle_count;

    logic aw_pending;
    logic [AXI_ID_WIDTH-1:0] awid_hold;
    logic [AXI_ADDR_WIDTH-1:0] awaddr_hold;
    logic [7:0] awlen_hold;
    logic [2:0] awsize_hold;
    logic [1:0] awburst_hold;
    logic awlock_hold;

    logic w_pending;
    logic [31:0] wdata_hold;
    logic [3:0] wstrb_hold;
    logic wlast_hold;

    logic [1:0] write_region;
    logic [31:0] write_word_index;
    logic write_address_valid;
    logic write_protocol_valid;
    logic [31:0] write_merged_data;

    logic [1:0] read_region;
    logic [31:0] read_word_index;
    logic read_address_valid;
    logic read_protocol_valid;
    logic [31:0] read_data_value;

    // Public range monitors are intentionally not ports: end-to-end tests may
    // inspect them hierarchically without widening the production interface.
    logic [31:0] model_min_word;
    logic [31:0] model_max_word;
    logic [31:0] input_min_word;
    logic [31:0] input_max_word;
    logic [31:0] scratch_min_word;
    logic [31:0] scratch_max_word;

    function automatic logic [63:0] extend_address(
        input logic [AXI_ADDR_WIDTH-1:0] address
    );
        begin
            extend_address = 64'b0;
            extend_address[AXI_ADDR_WIDTH-1:0] = address;
        end
    endfunction

    function automatic logic address_in_region(
        input logic [AXI_ADDR_WIDTH-1:0] address,
        input logic [63:0] base_address,
        input logic [63:0] word_count
    );
        logic [63:0] address_64;
        logic [64:0] end_exclusive;
        begin
            address_64 = extend_address(address);
            end_exclusive =
                {1'b0, base_address} + ({1'b0, word_count} << 2);
            address_in_region =
                (address_64 >= base_address) &&
                ({1'b0, address_64} < end_exclusive);
        end
    endfunction

    function automatic logic [1:0] decode_region(
        input logic [AXI_ADDR_WIDTH-1:0] address
    );
        begin
            if (address_in_region(address, MODEL_BASE, MODEL_WORDS))
                decode_region = REGION_MODEL;
            else if (address_in_region(address, INPUT_BASE, INPUT_WORDS))
                decode_region = REGION_INPUT;
            else if (address_in_region(address, SCRATCH_BASE, SCRATCH_WORDS))
                decode_region = REGION_SCRATCH;
            else
                decode_region = REGION_NONE;
        end
    endfunction

    function automatic logic [31:0] decode_word_index(
        input logic [AXI_ADDR_WIDTH-1:0] address,
        input logic [1:0] region
    );
        logic [63:0] address_64;
        logic [63:0] region_base;
        begin
            address_64 = extend_address(address);
            case (region)
                REGION_MODEL:   region_base = MODEL_BASE;
                REGION_INPUT:   region_base = INPUT_BASE;
                REGION_SCRATCH: region_base = SCRATCH_BASE;
                default:        region_base = 64'b0;
            endcase
            decode_word_index = (address_64 - region_base) >> 2;
        end
    endfunction

    function automatic logic [31:0] apply_wstrb(
        input logic [31:0] prior_value,
        input logic [31:0] new_value,
        input logic [3:0] strobe
    );
        integer byte_index;
        begin
            apply_wstrb = prior_value;
            for (byte_index = 0; byte_index < 4;
                 byte_index = byte_index + 1)
                if (strobe[byte_index])
                    apply_wstrb[byte_index*8 +: 8] =
                        new_value[byte_index*8 +: 8];
        end
    endfunction

    always_comb begin
        write_region = decode_region(awaddr_hold);
        write_word_index = decode_word_index(awaddr_hold, write_region);
        write_address_valid =
            (write_region == REGION_SCRATCH) &&
            (awaddr_hold[1:0] == 2'b00);
        write_protocol_valid =
            (awlen_hold == 8'd0) &&
            (awsize_hold == 3'b010) &&
            (awburst_hold == AXI_BURST_INCR) &&
            !awlock_hold &&
            wlast_hold;
        write_merged_data = 32'b0;
        if (write_address_valid)
            write_merged_data = apply_wstrb(
                scratch_memory[write_word_index],
                wdata_hold,
                wstrb_hold
            );

        read_region = decode_region(s_axi_araddr);
        read_word_index = decode_word_index(s_axi_araddr, read_region);
        read_address_valid =
            (read_region != REGION_NONE) &&
            (s_axi_araddr[1:0] == 2'b00);
        read_protocol_valid =
            (s_axi_arlen == 8'd0) &&
            (s_axi_arsize == 3'b010) &&
            (s_axi_arburst == AXI_BURST_INCR) &&
            !s_axi_arlock;

        read_data_value = 32'b0;
        if (read_address_valid) begin
            case (read_region)
                REGION_MODEL:
                    read_data_value = model_memory[read_word_index];
                REGION_INPUT:
                    read_data_value = input_memory[read_word_index];
                REGION_SCRATCH:
                    read_data_value = scratch_memory[read_word_index];
                default:
                    read_data_value = 32'b0;
            endcase
        end
    end

    assign s_axi_awready =
        !aw_pending && !s_axi_bvalid &&
        (!STALL_ENABLE || (cycle_count[2:0] != 3'd1));
    assign s_axi_wready =
        !w_pending && !s_axi_bvalid &&
        (!STALL_ENABLE || (cycle_count[2:0] != 3'd2));
    assign s_axi_arready =
        !s_axi_rvalid &&
        (!STALL_ENABLE || (cycle_count[2:0] != 3'd3));

    // Cache/protection/QoS are legal sideband values but do not affect this
    // functional memory model.
    logic unused_sideband;
    assign unused_sideband =
        s_axi_awcache[0] ^ s_axi_awprot[0] ^ s_axi_awqos[0] ^
        s_axi_arcache[0] ^ s_axi_arprot[0] ^ s_axi_arqos[0];

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            cycle_count <= 64'd0;
            aw_pending <= 1'b0;
            awid_hold <= '0;
            awaddr_hold <= '0;
            awlen_hold <= 8'd0;
            awsize_hold <= 3'd0;
            awburst_hold <= 2'd0;
            awlock_hold <= 1'b0;
            w_pending <= 1'b0;
            wdata_hold <= 32'd0;
            wstrb_hold <= 4'd0;
            wlast_hold <= 1'b0;
            s_axi_bid <= '0;
            s_axi_bresp <= AXI_RESP_OKAY;
            s_axi_bvalid <= 1'b0;
            s_axi_rid <= '0;
            s_axi_rdata <= 32'd0;
            s_axi_rresp <= AXI_RESP_OKAY;
            s_axi_rlast <= 1'b1;
            s_axi_rvalid <= 1'b0;
            read_count_o <= 64'd0;
            write_count_o <= 64'd0;
            model_read_count_o <= 64'd0;
            input_read_count_o <= 64'd0;
            scratch_read_count_o <= 64'd0;
            scratch_write_count_o <= 64'd0;
            invalid_access_count_o <= 32'd0;
            model_min_word <= 32'hffff_ffff;
            model_max_word <= 32'd0;
            input_min_word <= 32'hffff_ffff;
            input_max_word <= 32'd0;
            scratch_min_word <= 32'hffff_ffff;
            scratch_max_word <= 32'd0;
        end else begin
            cycle_count <= cycle_count + 1'b1;

            if (s_axi_awvalid && s_axi_awready) begin
                aw_pending <= 1'b1;
                awid_hold <= s_axi_awid;
                awaddr_hold <= s_axi_awaddr;
                awlen_hold <= s_axi_awlen;
                awsize_hold <= s_axi_awsize;
                awburst_hold <= s_axi_awburst;
                awlock_hold <= s_axi_awlock;
            end

            if (s_axi_wvalid && s_axi_wready) begin
                w_pending <= 1'b1;
                wdata_hold <= s_axi_wdata;
                wstrb_hold <= s_axi_wstrb;
                wlast_hold <= s_axi_wlast;
            end

            if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
                s_axi_bresp <= AXI_RESP_OKAY;
            end

            if (aw_pending && w_pending && !s_axi_bvalid) begin
                aw_pending <= 1'b0;
                w_pending <= 1'b0;
                s_axi_bid <= awid_hold;
                s_axi_bvalid <= 1'b1;

                if (write_address_valid && write_protocol_valid) begin
                    scratch_memory[write_word_index] <= write_merged_data;
                    s_axi_bresp <= AXI_RESP_OKAY;
                    write_count_o <= write_count_o + 1'b1;
                    scratch_write_count_o <=
                        scratch_write_count_o + 1'b1;
                    if (write_word_index < scratch_min_word)
                        scratch_min_word <= write_word_index;
                    if (write_word_index > scratch_max_word)
                        scratch_max_word <= write_word_index;
                end else begin
                    s_axi_bresp <= AXI_RESP_SLVERR;
                    invalid_access_count_o <=
                        invalid_access_count_o + 1'b1;
                end
            end

            if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
                s_axi_rresp <= AXI_RESP_OKAY;
                s_axi_rdata <= 32'd0;
            end

            if (s_axi_arvalid && s_axi_arready) begin
                s_axi_rid <= s_axi_arid;
                s_axi_rlast <= 1'b1;
                s_axi_rvalid <= 1'b1;

                if (read_address_valid && read_protocol_valid) begin
                    s_axi_rdata <= read_data_value;
                    s_axi_rresp <= AXI_RESP_OKAY;
                    read_count_o <= read_count_o + 1'b1;
                    case (read_region)
                        REGION_MODEL: begin
                            model_read_count_o <=
                                model_read_count_o + 1'b1;
                            if (read_word_index < model_min_word)
                                model_min_word <= read_word_index;
                            if (read_word_index > model_max_word)
                                model_max_word <= read_word_index;
                        end
                        REGION_INPUT: begin
                            input_read_count_o <=
                                input_read_count_o + 1'b1;
                            if (read_word_index < input_min_word)
                                input_min_word <= read_word_index;
                            if (read_word_index > input_max_word)
                                input_max_word <= read_word_index;
                        end
                        REGION_SCRATCH: begin
                            scratch_read_count_o <=
                                scratch_read_count_o + 1'b1;
                            if (read_word_index < scratch_min_word)
                                scratch_min_word <= read_word_index;
                            if (read_word_index > scratch_max_word)
                                scratch_max_word <= read_word_index;
                        end
                        default: begin
                        end
                    endcase
                end else begin
                    s_axi_rdata <= 32'd0;
                    s_axi_rresp <= AXI_RESP_SLVERR;
                    invalid_access_count_o <=
                        invalid_access_count_o + 1'b1;
                end
            end
        end
    end

endmodule
