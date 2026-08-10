`timescale 1ns/1ps

// Converts one sequencer layer request into 16 ordered synchronous RAM reads.
//
// request_i/index_i may remain asserted for the complete transaction, as they
// do in vit_phase_e_sequencer.  response_valid_o is exactly one clock wide;
// WAIT_RELEASE prevents a held request from being accepted twice.  The RAM
// request side supports backpressure even though the production table is
// always ready.
module vit_layer_param_loader (
    input  logic                                    clk,
    input  logic                                    rst,

    input  logic                                    request_i,
    input  logic [3:0]                              index_i,
    output logic                                    response_valid_o,
    // Packed exactly as phase_e_layer_params_t: software word 0 occupies
    // bits [511:480], and software word 15 occupies bits [31:0].
    output logic [16*32-1:0]                        response_data_o,

    output logic                                    ram_req_valid_o,
    input  logic                                    ram_req_ready_i,
    output logic [7:0]                              ram_req_addr_o,
    input  logic                                    ram_rsp_valid_i,
    input  logic [31:0]                             ram_rsp_data_i
);

    typedef enum logic [1:0] {
        LOAD_IDLE,
        LOAD_RUN,
        LOAD_RESPONSE,
        LOAD_WAIT_RELEASE
    } load_state_t;

    load_state_t state;
    logic [3:0] active_index;
    logic [4:0] issue_count;
    logic [4:0] receive_count;
    logic [16*32-1:0] loaded_words;

    assign ram_req_valid_o =
        (state == LOAD_RUN) && (issue_count < 5'd16);
    assign ram_req_addr_o =
        {active_index, 4'b0000} + {4'd0, issue_count[3:0]};
    assign response_valid_o = (state == LOAD_RESPONSE);
    assign response_data_o = loaded_words;

    always_ff @(posedge clk) begin
        if (rst) begin
            state         <= LOAD_IDLE;
            active_index  <= 4'd0;
            issue_count   <= 5'd0;
            receive_count <= 5'd0;
            loaded_words  <= '0;
        end else begin
            case (state)
                LOAD_IDLE: begin
                    if (request_i) begin
                        active_index  <= index_i;
                        issue_count   <= 5'd0;
                        receive_count <= 5'd0;
                        loaded_words  <= '0;
                        // Invalid indices still receive one deterministic
                        // zero response, so no requester can deadlock.
                        if (index_i < 4'd12)
                            state <= LOAD_RUN;
                        else
                            state <= LOAD_RESPONSE;
                    end
                end

                LOAD_RUN: begin
                    if (ram_req_valid_o && ram_req_ready_i)
                        issue_count <= issue_count + 1'b1;

                    if (ram_rsp_valid_i) begin
                        // Shift order makes the first software word land in
                        // the most-significant packed-struct field.
                        loaded_words <= {
                            loaded_words[15*32-1:0],
                            ram_rsp_data_i
                        };
                        if (receive_count == 5'd15)
                            state <= LOAD_RESPONSE;
                        else
                            receive_count <= receive_count + 1'b1;
                    end
                end

                LOAD_RESPONSE:
                    state <= LOAD_WAIT_RELEASE;

                LOAD_WAIT_RELEASE: begin
                    if (!request_i)
                        state <= LOAD_IDLE;
                end

                default:
                    state <= LOAD_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    logic [5:0] outstanding_reads;
    always @(posedge clk) begin
        if (rst || state == LOAD_IDLE) begin
            outstanding_reads <= 6'd0;
        end else begin
            case ({
                ram_req_valid_o && ram_req_ready_i,
                ram_rsp_valid_i
            })
                2'b10: outstanding_reads <= outstanding_reads + 1'b1;
                2'b01: begin
                    assert (outstanding_reads != 0)
                        else $fatal(
                            1,
                            "layer loader received an unsolicited RAM response"
                        );
                    outstanding_reads <= outstanding_reads - 1'b1;
                end
                default: begin
                end
            endcase

            assert (receive_count <= issue_count)
                else $fatal(1, "layer loader response count exceeded requests");
        end
    end
`endif

endmodule
