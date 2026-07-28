`timescale 1ns/1ps

// Single-outstanding Phase-E logical-memory to AXI4 adapter.
//
// Descriptor and engine addresses are FP32 word offsets.  This module is the
// only point that converts them to AXI byte addresses:
//
//   physical_byte_address = space_base + (word_address << 2)
//
// The datapath is intentionally 32 bits and each request becomes one AXI4
// beat.  Wider bursts and caches can be added later without changing the
// logical req/rsp contract used by the Phase-E engine.
module vit_phase_e_axi_mem_adapter #(
    parameter integer AXI_ADDR_WIDTH = 40,
    parameter integer AXI_ID_WIDTH   = 1
) (
    input  logic                          aclk,
    input  logic                          aresetn,

    input  logic [63:0]                   scratch_base_i,
    input  logic [63:0]                   model_base_i,
    input  logic [63:0]                   input_base_i,
    input  logic [31:0]                   scratch_words_i,
    input  logic [31:0]                   model_words_i,
    input  logic [31:0]                   input_words_i,

    input  logic                          req_valid,
    output logic                          req_ready,
    input  logic                          req_write,
    input  logic [1:0]                    req_space,
    input  logic [31:0]                   req_word_address,
    input  logic [31:0]                   req_write_data,
    input  logic [3:0]                    req_write_strobe,

    output logic                          rsp_valid,
    input  logic                          rsp_ready,
    output logic [31:0]                   rsp_read_data,
    output logic                          rsp_error,

    output logic [AXI_ID_WIDTH-1:0]       m_axi_awid,
    output logic [AXI_ADDR_WIDTH-1:0]     m_axi_awaddr,
    output logic [7:0]                    m_axi_awlen,
    output logic [2:0]                    m_axi_awsize,
    output logic [1:0]                    m_axi_awburst,
    output logic                          m_axi_awlock,
    output logic [3:0]                    m_axi_awcache,
    output logic [2:0]                    m_axi_awprot,
    output logic [3:0]                    m_axi_awqos,
    output logic                          m_axi_awvalid,
    input  logic                          m_axi_awready,

    output logic [31:0]                   m_axi_wdata,
    output logic [3:0]                    m_axi_wstrb,
    output logic                          m_axi_wlast,
    output logic                          m_axi_wvalid,
    input  logic                          m_axi_wready,

    input  logic [AXI_ID_WIDTH-1:0]       m_axi_bid,
    input  logic [1:0]                    m_axi_bresp,
    input  logic                          m_axi_bvalid,
    output logic                          m_axi_bready,

    output logic [AXI_ID_WIDTH-1:0]       m_axi_arid,
    output logic [AXI_ADDR_WIDTH-1:0]     m_axi_araddr,
    output logic [7:0]                    m_axi_arlen,
    output logic [2:0]                    m_axi_arsize,
    output logic [1:0]                    m_axi_arburst,
    output logic                          m_axi_arlock,
    output logic [3:0]                    m_axi_arcache,
    output logic [2:0]                    m_axi_arprot,
    output logic [3:0]                    m_axi_arqos,
    output logic                          m_axi_arvalid,
    input  logic                          m_axi_arready,

    input  logic [AXI_ID_WIDTH-1:0]       m_axi_rid,
    input  logic [31:0]                   m_axi_rdata,
    input  logic [1:0]                    m_axi_rresp,
    input  logic                          m_axi_rlast,
    input  logic                          m_axi_rvalid,
    output logic                          m_axi_rready
);

    localparam logic [1:0] MEM_NONE    = 2'd0;
    localparam logic [1:0] MEM_SCRATCH = 2'd1;
    localparam logic [1:0] MEM_MODEL   = 2'd2;
    localparam logic [1:0] MEM_INPUT   = 2'd3;

    localparam logic [1:0] AXI_RESP_OKAY = 2'b00;
    localparam logic [1:0] AXI_BURST_INCR = 2'b01;

    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_READ_ADDRESS,
        STATE_READ_DATA,
        STATE_WRITE_ISSUE,
        STATE_WRITE_RESPONSE,
        STATE_LOCAL_RESPONSE
    } state_t;

    state_t state;

    logic [63:0] selected_base;
    logic [31:0] selected_words;
    logic [64:0] byte_offset_wide;
    logic [64:0] physical_address_wide;
    logic        request_space_valid;
    logic        request_in_bounds;
    logic        request_base_aligned;
    logic        request_address_aligned;
    logic        request_address_fits_axi;
    logic        request_write_allowed;
    logic        request_is_valid;

    logic [AXI_ADDR_WIDTH-1:0] address_hold;
    logic [31:0]               write_data_hold;
    logic [3:0]                write_strobe_hold;
    logic                      aw_complete;
    logic                      w_complete;

    integer address_bit;

    initial begin
        if ((AXI_ADDR_WIDTH < 3) || (AXI_ADDR_WIDTH > 64))
            $error("AXI_ADDR_WIDTH must be in the range 3..64");
        if (AXI_ID_WIDTH < 1)
            $error("AXI_ID_WIDTH must be at least one");
    end

    always_comb begin
        selected_base = 64'b0;
        selected_words = 32'b0;
        request_space_valid = 1'b1;

        case (req_space)
            MEM_SCRATCH: begin
                selected_base = scratch_base_i;
                selected_words = scratch_words_i;
            end
            MEM_MODEL: begin
                selected_base = model_base_i;
                selected_words = model_words_i;
            end
            MEM_INPUT: begin
                selected_base = input_base_i;
                selected_words = input_words_i;
            end
            MEM_NONE: begin
                request_space_valid = 1'b0;
            end
            default: begin
                request_space_valid = 1'b0;
            end
        endcase

        // Widen before shifting so word addresses at or above 2^30 are not
        // truncated by a 32-bit intermediate.
        byte_offset_wide = {33'b0, req_word_address} << 2;
        physical_address_wide = {1'b0, selected_base} +
                                byte_offset_wide;

        request_in_bounds = (req_word_address < selected_words);
        request_base_aligned = (selected_base[1:0] == 2'b00);
        request_address_aligned =
            (physical_address_wide[1:0] == 2'b00);

        request_address_fits_axi = !physical_address_wide[64];
        for (
            address_bit = AXI_ADDR_WIDTH;
            address_bit < 64;
            address_bit = address_bit + 1
        )
            if (physical_address_wide[address_bit])
                request_address_fits_axi = 1'b0;

        // Compute descriptors may only modify scratch. Model parameters and
        // prepared input are loaded by the PS and remain read-only to the NPU.
        request_write_allowed =
            !req_write || (req_space == MEM_SCRATCH);

        request_is_valid =
            request_space_valid &&
            request_in_bounds &&
            request_base_aligned &&
            request_address_aligned &&
            request_address_fits_axi &&
            request_write_allowed;
    end

    assign req_ready = (state == STATE_IDLE);

    assign m_axi_awid    = '0;
    assign m_axi_awaddr  = address_hold;
    assign m_axi_awlen   = 8'd0;
    assign m_axi_awsize  = 3'b010;
    assign m_axi_awburst = AXI_BURST_INCR;
    assign m_axi_awlock  = 1'b0;
    assign m_axi_awcache = 4'b0011;
    assign m_axi_awprot  = 3'b000;
    assign m_axi_awqos   = 4'b0000;
    assign m_axi_awvalid =
        (state == STATE_WRITE_ISSUE) && !aw_complete;

    assign m_axi_wdata  = write_data_hold;
    assign m_axi_wstrb  = write_strobe_hold;
    assign m_axi_wlast  = 1'b1;
    assign m_axi_wvalid =
        (state == STATE_WRITE_ISSUE) && !w_complete;

    assign m_axi_bready = (state == STATE_WRITE_RESPONSE);

    assign m_axi_arid    = '0;
    assign m_axi_araddr  = address_hold;
    assign m_axi_arlen   = 8'd0;
    assign m_axi_arsize  = 3'b010;
    assign m_axi_arburst = AXI_BURST_INCR;
    assign m_axi_arlock  = 1'b0;
    assign m_axi_arcache = 4'b0011;
    assign m_axi_arprot  = 3'b000;
    assign m_axi_arqos   = 4'b0000;
    assign m_axi_arvalid = (state == STATE_READ_ADDRESS);

    assign m_axi_rready = (state == STATE_READ_DATA);

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            state              <= STATE_IDLE;
            address_hold       <= '0;
            write_data_hold    <= 32'b0;
            write_strobe_hold  <= 4'b0;
            aw_complete        <= 1'b0;
            w_complete         <= 1'b0;
            rsp_valid          <= 1'b0;
            rsp_read_data      <= 32'b0;
            rsp_error          <= 1'b0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    rsp_valid <= 1'b0;
                    if (req_valid) begin
                        rsp_read_data <= 32'b0;
                        rsp_error <= 1'b0;

                        if (!request_is_valid) begin
                            rsp_valid <= 1'b1;
                            rsp_error <= 1'b1;
                            state <= STATE_LOCAL_RESPONSE;
                        end else begin
                            address_hold <= physical_address_wide[
                                AXI_ADDR_WIDTH-1:0
                            ];
                            if (req_write) begin
                                write_data_hold   <= req_write_data;
                                write_strobe_hold <= req_write_strobe;
                                aw_complete       <= 1'b0;
                                w_complete        <= 1'b0;
                                state             <= STATE_WRITE_ISSUE;
                            end else begin
                                state <= STATE_READ_ADDRESS;
                            end
                        end
                    end
                end

                STATE_READ_ADDRESS: begin
                    if (m_axi_arvalid && m_axi_arready)
                        state <= STATE_READ_DATA;
                end

                STATE_READ_DATA: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        rsp_valid <= 1'b1;
                        rsp_read_data <= m_axi_rdata;
                        rsp_error <=
                            (m_axi_rresp != AXI_RESP_OKAY) ||
                            !m_axi_rlast ||
                            (m_axi_rid != {AXI_ID_WIDTH{1'b0}});
                        state <= STATE_LOCAL_RESPONSE;
                    end
                end

                STATE_WRITE_ISSUE: begin
                    if (m_axi_awvalid && m_axi_awready)
                        aw_complete <= 1'b1;
                    if (m_axi_wvalid && m_axi_wready)
                        w_complete <= 1'b1;

                    if (
                        (aw_complete ||
                         (m_axi_awvalid && m_axi_awready)) &&
                        (w_complete ||
                         (m_axi_wvalid && m_axi_wready))
                    )
                        state <= STATE_WRITE_RESPONSE;
                end

                STATE_WRITE_RESPONSE: begin
                    if (m_axi_bvalid && m_axi_bready) begin
                        rsp_valid <= 1'b1;
                        rsp_read_data <= 32'b0;
                        rsp_error <=
                            (m_axi_bresp != AXI_RESP_OKAY) ||
                            (m_axi_bid != {AXI_ID_WIDTH{1'b0}});
                        state <= STATE_LOCAL_RESPONSE;
                    end
                end

                STATE_LOCAL_RESPONSE: begin
                    if (rsp_valid && rsp_ready) begin
                        rsp_valid <= 1'b0;
                        rsp_read_data <= 32'b0;
                        rsp_error <= 1'b0;
                        state <= STATE_IDLE;
                    end
                end

                default: begin
                    state <= STATE_IDLE;
                    aw_complete <= 1'b0;
                    w_complete <= 1'b0;
                    rsp_valid <= 1'b0;
                    rsp_read_data <= 32'b0;
                    rsp_error <= 1'b1;
                end
            endcase
        end
    end

endmodule
