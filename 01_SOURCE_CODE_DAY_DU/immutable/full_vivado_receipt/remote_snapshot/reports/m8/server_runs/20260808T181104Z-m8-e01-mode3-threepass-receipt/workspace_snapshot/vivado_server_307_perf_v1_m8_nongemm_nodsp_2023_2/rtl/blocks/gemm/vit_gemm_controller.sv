`timescale 1ns/1ps

// GEMM tile scheduler.
//
// This module owns only command/configuration state and tile progression.  It
// deliberately contains no floating-point datapath so that the control path
// can be synthesized and verified independently from the PE array.
module vit_gemm_controller #(
    parameter integer ARRAY_ROWS = 2,
    parameter integer ARRAY_COLS = 2,
    parameter integer PE_LANES   = 16
) (
    input  logic        clk,
    input  logic        rst,

    input  logic        start,
    input  logic [31:0] cfg_m,
    input  logic [31:0] cfg_k,
    input  logic [31:0] cfg_n,
    input  logic [31:0] cfg_batch_count,
    input  logic        cfg_bias_enable,

    input  logic        data_valid,
    input  logic        pe_step_done,
    input  logic        pe_finish_done,
    input  logic        result_ready,

    output logic        busy,
    output logic        done,
    output logic        config_error,
    output logic        data_request,
    output logic        result_valid,

    output logic        pe_clear,
    output logic        pe_step,
    output logic        pe_finish,

    output logic [31:0] active_m,
    output logic [31:0] active_k,
    output logic [31:0] active_n,
    output logic        active_bias_enable,

    output logic [31:0] token_base,
    output logic [31:0] output_base,
    output logic [31:0] k_base,
    output logic [31:0] batch_index
);

    localparam logic [32:0] ARRAY_ROWS_WIDE = 33'(ARRAY_ROWS);
    localparam logic [32:0] ARRAY_COLS_WIDE = 33'(ARRAY_COLS);
    localparam logic [32:0] PE_LANES_WIDE   = 33'(PE_LANES);

    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_CLEAR,
        STATE_COMPUTE,
        STATE_WAIT_PE,
        STATE_BIAS,
        STATE_WRITE,
        STATE_DONE
    } state_t;

    state_t state;
    logic [31:0] active_batch_count;
    logic        last_k_chunk;

    // STATE_DONE does not accept a new command.  busy therefore stays high
    // until IDLE, matching the original back-to-back command contract.
    assign busy         = (state != STATE_IDLE);
    assign done         = (state == STATE_DONE);
    assign data_request = (state == STATE_COMPUTE);
    assign result_valid = (state == STATE_WRITE);

    assign pe_clear  = (state == STATE_CLEAR);
    assign pe_step   = (state == STATE_COMPUTE) && data_valid;
    assign pe_finish = (state == STATE_BIAS);

    initial begin
        if (ARRAY_ROWS <= 0)
            $fatal(1, "vit_gemm_controller requires ARRAY_ROWS > 0");
        if (ARRAY_COLS <= 0)
            $fatal(1, "vit_gemm_controller requires ARRAY_COLS > 0");
        if (PE_LANES <= 0)
            $fatal(1, "vit_gemm_controller requires PE_LANES > 0");
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state              <= STATE_IDLE;
            config_error       <= 1'b0;
            active_m           <= 32'd0;
            active_k           <= 32'd0;
            active_n           <= 32'd0;
            active_batch_count <= 32'd0;
            active_bias_enable <= 1'b0;
            token_base         <= 32'd0;
            output_base        <= 32'd0;
            k_base             <= 32'd0;
            batch_index        <= 32'd0;
            last_k_chunk       <= 1'b0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (start) begin
                        token_base  <= 32'd0;
                        output_base <= 32'd0;
                        k_base      <= 32'd0;
                        batch_index <= 32'd0;

                        if ((cfg_batch_count == 0) || (cfg_m == 0) ||
                            (cfg_k == 0) || (cfg_n == 0)) begin
                            config_error <= 1'b1;
                            state        <= STATE_DONE;
                        end else begin
                            config_error       <= 1'b0;
                            active_m           <= cfg_m;
                            active_k           <= cfg_k;
                            active_n           <= cfg_n;
                            active_batch_count <= cfg_batch_count;
                            active_bias_enable <= cfg_bias_enable;
                            state              <= STATE_CLEAR;
                        end
                    end
                end

                STATE_CLEAR: begin
                    k_base       <= 32'd0;
                    last_k_chunk <= 1'b0;
                    state        <= STATE_COMPUTE;
                end

                STATE_COMPUTE: begin
                    if (data_valid) begin
                        last_k_chunk <=
                            (({1'b0, k_base} + PE_LANES_WIDE) >=
                             {1'b0, active_k});
                        state <= STATE_WAIT_PE;
                    end
                end

                STATE_WAIT_PE: begin
                    if (pe_step_done) begin
                        if (last_k_chunk) begin
                            state <= STATE_BIAS;
                        end else begin
                            k_base <= k_base + PE_LANES;
                            state  <= STATE_COMPUTE;
                        end
                    end
                end

                STATE_BIAS: begin
                    if (pe_finish_done)
                        state <= STATE_WRITE;
                end

                STATE_WRITE: begin
                    if (result_ready) begin
                        if (({1'b0, output_base} + ARRAY_COLS_WIDE) <
                            {1'b0, active_n}) begin
                            output_base <= output_base + ARRAY_COLS;
                            state       <= STATE_CLEAR;
                        end else begin
                            output_base <= 32'd0;
                            if (({1'b0, token_base} + ARRAY_ROWS_WIDE) <
                                {1'b0, active_m}) begin
                                token_base <= token_base + ARRAY_ROWS;
                                state      <= STATE_CLEAR;
                            end else if ((batch_index + 1) <
                                         active_batch_count) begin
                                token_base  <= 32'd0;
                                batch_index <= batch_index + 1;
                                state       <= STATE_CLEAR;
                            end else begin
                                state <= STATE_DONE;
                            end
                        end
                    end
                end

                STATE_DONE: begin
                    state <= STATE_IDLE;
                end

                default: begin
                    config_error <= 1'b1;
                    state        <= STATE_IDLE;
                end
            endcase
        end
    end

endmodule
