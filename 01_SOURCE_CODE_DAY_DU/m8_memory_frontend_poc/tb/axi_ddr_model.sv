
`timescale 1ns/1ps

module axi_ddr_model #(
    parameter integer AXI_ADDR_WIDTH = 40,
    parameter integer AXI_ID_WIDTH   = 1,

    // Standalone POC memory size.
    // Testbench will use small remapped base addresses.
    parameter integer MEM_BYTES = 1048576,

    // Delay from accepting/starting a read request
    // until the first R beat is produced.
    parameter integer READ_LATENCY = 12,

    // Delay before BRESP.
    parameter integer WRITE_RESP_LATENCY = 4,

    // Must be >= 2 to exercise M8's current two-AR
    // outstanding line-fill behavior.
    parameter integer READ_QUEUE_DEPTH = 4
)(
    input logic aclk,
    input logic aresetn,

    // ------------------------------------------------------------
    // AXI WRITE ADDRESS
    // ------------------------------------------------------------
    input  logic [AXI_ID_WIDTH-1:0]   s_axi_awid,
    input  logic [AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    input  logic [7:0]                s_axi_awlen,
    input  logic [2:0]                s_axi_awsize,
    input  logic [1:0]                s_axi_awburst,
    input  logic                      s_axi_awlock,
    input  logic [3:0]                s_axi_awcache,
    input  logic [2:0]                s_axi_awprot,
    input  logic [3:0]                s_axi_awqos,
    input  logic                      s_axi_awvalid,
    output logic                      s_axi_awready,

    // ------------------------------------------------------------
    // AXI WRITE DATA
    // ------------------------------------------------------------
    input  logic [127:0] s_axi_wdata,
    input  logic [15:0]  s_axi_wstrb,
    input  logic         s_axi_wlast,
    input  logic         s_axi_wvalid,
    output logic         s_axi_wready,

    // ------------------------------------------------------------
    // AXI WRITE RESPONSE
    // ------------------------------------------------------------
    output logic [AXI_ID_WIDTH-1:0] s_axi_bid,
    output logic [1:0]              s_axi_bresp,
    output logic                    s_axi_bvalid,
    input  logic                    s_axi_bready,

    // ------------------------------------------------------------
    // AXI READ ADDRESS
    // ------------------------------------------------------------
    input  logic [AXI_ID_WIDTH-1:0]   s_axi_arid,
    input  logic [AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    input  logic [7:0]                s_axi_arlen,
    input  logic [2:0]                s_axi_arsize,
    input  logic [1:0]                s_axi_arburst,
    input  logic                      s_axi_arlock,
    input  logic [3:0]                s_axi_arcache,
    input  logic [2:0]                s_axi_arprot,
    input  logic [3:0]                s_axi_arqos,
    input  logic                      s_axi_arvalid,
    output logic                      s_axi_arready,

    // ------------------------------------------------------------
    // AXI READ DATA
    // ------------------------------------------------------------
    output logic [AXI_ID_WIDTH-1:0] s_axi_rid,
    output logic [127:0]            s_axi_rdata,
    output logic [1:0]              s_axi_rresp,
    output logic                    s_axi_rlast,
    output logic                    s_axi_rvalid,
    input  logic                    s_axi_rready
);

    localparam logic [1:0] AXI_RESP_OKAY  = 2'b00;
    localparam logic [1:0] AXI_BURST_INCR = 2'b01;

    // ============================================================
    // BYTE-ADDRESSABLE SIMULATION MEMORY
    // ============================================================

    logic [7:0] mem [0:MEM_BYTES-1];

    integer init_i;

    initial begin
        for (init_i = 0; init_i < MEM_BYTES; init_i = init_i + 1)
            mem[init_i] = 8'h00;
    end

    // Read one 128-bit bus line. For narrow AXI reads the adapter
    // selects the correct 32-bit lane from this returned bus line.
    function automatic logic [127:0] read_bus_line(
        input logic [AXI_ADDR_WIDTH-1:0] addr
    );
        logic [AXI_ADDR_WIDTH-1:0] line_base;
        integer i;
        begin
            line_base = {addr[AXI_ADDR_WIDTH-1:4], 4'b0000};
            read_bus_line = '0;

            for (i = 0; i < 16; i = i + 1) begin
                if ((line_base + i) < MEM_BYTES)
                    read_bus_line[i*8 +: 8] = mem[line_base + i];
            end
        end
    endfunction

    task automatic write_bus_line(
        input logic [AXI_ADDR_WIDTH-1:0] addr,
        input logic [127:0] data,
        input logic [15:0] strobe
    );
        logic [AXI_ADDR_WIDTH-1:0] line_base;
        integer i;
        begin
            line_base = {addr[AXI_ADDR_WIDTH-1:4], 4'b0000};

            for (i = 0; i < 16; i = i + 1) begin
                if (strobe[i] && ((line_base + i) < MEM_BYTES))
                    mem[line_base + i] = data[i*8 +: 8];
            end
        end
    endtask

    // Convenient TB-side helpers.
    task automatic poke_u32(
        input logic [AXI_ADDR_WIDTH-1:0] addr,
        input logic [31:0] data
    );
        begin
            if ((addr + 3) < MEM_BYTES) begin
                mem[addr+0] = data[7:0];
                mem[addr+1] = data[15:8];
                mem[addr+2] = data[23:16];
                mem[addr+3] = data[31:24];
            end
        end
    endtask

    function automatic logic [31:0] peek_u32(
        input logic [AXI_ADDR_WIDTH-1:0] addr
    );
        begin
            if ((addr + 3) < MEM_BYTES)
                peek_u32 = {
                    mem[addr+3],
                    mem[addr+2],
                    mem[addr+1],
                    mem[addr+0]
                };
            else
                peek_u32 = 32'hxxxx_xxxx;
        end
    endfunction

    // ============================================================
    // READ ADDRESS QUEUE
    //
    // Allows multiple AR transactions to be accepted before
    // earlier bursts have completed.
    // Responses are intentionally retired in-order.
    // ============================================================

    logic [AXI_ID_WIDTH-1:0]
        rdq_id [0:READ_QUEUE_DEPTH-1];

    logic [AXI_ADDR_WIDTH-1:0]
        rdq_addr [0:READ_QUEUE_DEPTH-1];

    logic [7:0]
        rdq_len [0:READ_QUEUE_DEPTH-1];

    logic [2:0]
        rdq_size [0:READ_QUEUE_DEPTH-1];

    logic [1:0]
        rdq_burst [0:READ_QUEUE_DEPTH-1];

    integer rdq_wr_ptr;
    integer rdq_rd_ptr;
    integer rdq_count;

    logic rd_active;

    logic [AXI_ID_WIDTH-1:0]
        current_rid;

    logic [7:0]
        current_rlen;

    logic [2:0]
        current_rsize;

    logic [1:0]
        current_rburst;

    logic [7:0]
        current_beat_index;

    logic [AXI_ADDR_WIDTH-1:0]
        current_beat_addr;

    integer read_latency_count;

    wire ar_fire =
        s_axi_arvalid && s_axi_arready;

    wire start_read =
        (!rd_active) && (rdq_count != 0);

    assign s_axi_arready =
        (rdq_count < READ_QUEUE_DEPTH);

    logic [AXI_ADDR_WIDTH-1:0] read_step_bytes;
    logic [AXI_ADDR_WIDTH-1:0] next_beat_addr;

    always_comb begin
        read_step_bytes = '0;
        read_step_bytes[0] = 1'b1;
        read_step_bytes = read_step_bytes << current_rsize;

        if (current_rburst == AXI_BURST_INCR)
            next_beat_addr = current_beat_addr + read_step_bytes;
        else
            next_beat_addr = current_beat_addr;
    end

    // ============================================================
    // WRITE CAPTURE
    // Current M8 adapter issues narrow, one-beat writes.
    // ============================================================

    logic aw_hold_valid;
    logic [AXI_ID_WIDTH-1:0] aw_hold_id;
    logic [AXI_ADDR_WIDTH-1:0] aw_hold_addr;

    logic w_hold_valid;
    logic [127:0] w_hold_data;
    logic [15:0]  w_hold_strb;

    logic write_response_pending;
    integer write_response_count;

    assign s_axi_awready =
        !aw_hold_valid &&
        !write_response_pending &&
        !s_axi_bvalid;

    assign s_axi_wready =
        !w_hold_valid &&
        !write_response_pending &&
        !s_axi_bvalid;

    // ============================================================
    // MAIN SEQUENTIAL MODEL
    // ============================================================

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            rdq_wr_ptr <= 0;
            rdq_rd_ptr <= 0;
            rdq_count  <= 0;

            rd_active <= 1'b0;
            current_rid <= '0;
            current_rlen <= '0;
            current_rsize <= '0;
            current_rburst <= '0;
            current_beat_index <= '0;
            current_beat_addr <= '0;
            read_latency_count <= 0;

            s_axi_rid <= '0;
            s_axi_rdata <= '0;
            s_axi_rresp <= AXI_RESP_OKAY;
            s_axi_rlast <= 1'b0;
            s_axi_rvalid <= 1'b0;

            aw_hold_valid <= 1'b0;
            aw_hold_id <= '0;
            aw_hold_addr <= '0;

            w_hold_valid <= 1'b0;
            w_hold_data <= '0;
            w_hold_strb <= '0;

            write_response_pending <= 1'b0;
            write_response_count <= 0;

            s_axi_bid <= '0;
            s_axi_bresp <= AXI_RESP_OKAY;
            s_axi_bvalid <= 1'b0;
        end else begin

            // ----------------------------------------------------
            // READ ADDRESS ENQUEUE
            // ----------------------------------------------------
            if (ar_fire) begin
                rdq_id[rdq_wr_ptr]    <= s_axi_arid;
                rdq_addr[rdq_wr_ptr]  <= s_axi_araddr;
                rdq_len[rdq_wr_ptr]   <= s_axi_arlen;
                rdq_size[rdq_wr_ptr]  <= s_axi_arsize;
                rdq_burst[rdq_wr_ptr] <= s_axi_arburst;

                if (rdq_wr_ptr == READ_QUEUE_DEPTH-1)
                    rdq_wr_ptr <= 0;
                else
                    rdq_wr_ptr <= rdq_wr_ptr + 1;
            end

            // ----------------------------------------------------
            // BEGIN NEXT READ BURST
            // ----------------------------------------------------
            if (start_read) begin
                current_rid   <= rdq_id[rdq_rd_ptr];
                current_rlen  <= rdq_len[rdq_rd_ptr];
                current_rsize <= rdq_size[rdq_rd_ptr];
                current_rburst<= rdq_burst[rdq_rd_ptr];

                current_beat_index <= 0;
                current_beat_addr  <= rdq_addr[rdq_rd_ptr];

                read_latency_count <= READ_LATENCY;
                rd_active <= 1'b1;

                if (rdq_rd_ptr == READ_QUEUE_DEPTH-1)
                    rdq_rd_ptr <= 0;
                else
                    rdq_rd_ptr <= rdq_rd_ptr + 1;
            end

            // Queue-count update handles simultaneous enqueue/pop.
            case ({ar_fire, start_read})
                2'b10: rdq_count <= rdq_count + 1;
                2'b01: rdq_count <= rdq_count - 1;
                default: rdq_count <= rdq_count;
            endcase

            // ----------------------------------------------------
            // READ RESPONSE GENERATION
            // ----------------------------------------------------
            if (rd_active) begin
                if (read_latency_count > 0) begin
                    read_latency_count <= read_latency_count - 1;
                end
                else if (!s_axi_rvalid) begin
                    s_axi_rid   <= current_rid;
                    s_axi_rdata <= read_bus_line(current_beat_addr);
                    s_axi_rresp <= AXI_RESP_OKAY;

                    s_axi_rlast <=
                        (current_beat_index == current_rlen);

                    s_axi_rvalid <= 1'b1;
                end
                else if (s_axi_rvalid && s_axi_rready) begin
                    if (s_axi_rlast) begin
                        s_axi_rvalid <= 1'b0;
                        s_axi_rlast  <= 1'b0;
                        rd_active    <= 1'b0;
                    end
                    else begin
                        current_beat_index <=
                            current_beat_index + 1'b1;

                        current_beat_addr <=
                            next_beat_addr;

                        s_axi_rdata <=
                            read_bus_line(next_beat_addr);

                        s_axi_rlast <=
                            ((current_beat_index + 1'b1)
                                == current_rlen);

                        // Keep RVALID asserted to support
                        // one accepted beat per clock.
                        s_axi_rvalid <= 1'b1;
                    end
                end
            end

            // ----------------------------------------------------
            // WRITE ADDRESS / DATA CAPTURE
            // ----------------------------------------------------
            if (s_axi_awvalid && s_axi_awready) begin
                aw_hold_valid <= 1'b1;
                aw_hold_id    <= s_axi_awid;
                aw_hold_addr  <= s_axi_awaddr;
            end

            if (s_axi_wvalid && s_axi_wready) begin
                w_hold_valid <= 1'b1;
                w_hold_data  <= s_axi_wdata;
                w_hold_strb  <= s_axi_wstrb;
            end

            // ----------------------------------------------------
            // COMMIT WRITE
            // ----------------------------------------------------
            if (aw_hold_valid &&
                w_hold_valid &&
                !write_response_pending &&
                !s_axi_bvalid) begin

                write_bus_line(
                    aw_hold_addr,
                    w_hold_data,
                    w_hold_strb
                );

                s_axi_bid <= aw_hold_id;
                s_axi_bresp <= AXI_RESP_OKAY;

                aw_hold_valid <= 1'b0;
                w_hold_valid  <= 1'b0;

                write_response_pending <= 1'b1;
                write_response_count <= WRITE_RESP_LATENCY;
            end

            // ----------------------------------------------------
            // BRESP LATENCY
            // ----------------------------------------------------
            if (write_response_pending) begin
                if (write_response_count > 0) begin
                    write_response_count <=
                        write_response_count - 1;
                end
                else if (!s_axi_bvalid) begin
                    s_axi_bvalid <= 1'b1;
                end
            end

            if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
                write_response_pending <= 1'b0;
            end
        end
    end

endmodule

