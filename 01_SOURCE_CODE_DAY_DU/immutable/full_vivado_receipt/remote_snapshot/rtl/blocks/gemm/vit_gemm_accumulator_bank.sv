`timescale 1ns/1ps

// Output-stationary register bank with one shared FP32 adder.
//
// Dot products arrive sequentially with a linear PE index, so one adder is
// sufficient for every partial-sum update. The same adder is reused during a
// short row-major epilogue that applies bias and freezes the result tile.
(* use_dsp = "no" *)
module vit_gemm_accumulator_bank #(
    parameter integer PE_COUNT = 4,
    parameter integer PE_INDEX_WIDTH =
        (PE_COUNT <= 1) ? 1 : $clog2(PE_COUNT),
    parameter integer USE_EXTERNAL_ADD = 0
) (
    input  logic                        clk,
    input  logic                        rst,
    input  logic                        clear,

    input  logic                        accumulate_valid,
    input  logic [PE_INDEX_WIDTH-1:0]   accumulate_index,
    input  logic [31:0]                 partial_sum,

    input  logic                        finish,
    input  logic                        bias_enable,
    input  logic [PE_COUNT*32-1:0]      bias_data,
    output logic                        finish_done,
    output logic [PE_COUNT*32-1:0]      result_data,

    output logic                        add_request,
    output logic [31:0]                 add_operand_a,
    output logic [31:0]                 add_operand_b,
    input  logic [31:0]                 external_add_result
);

    typedef enum logic [1:0] {
        STATE_IDLE,
        STATE_BIAS,
        STATE_HOLD
    } state_t;

    state_t state;
    logic [PE_INDEX_WIDTH-1:0] finish_index;
    logic [PE_COUNT*32-1:0] accumulator_data;
    logic latched_bias_enable;
    logic [PE_COUNT*32-1:0] latched_bias_data;
    logic [31:0] selected_accumulator;
    logic [31:0] selected_bias;
    logic [31:0] add_result;

    localparam logic [PE_INDEX_WIDTH-1:0] LAST_PE_INDEX =
        PE_INDEX_WIDTH'(PE_COUNT - 1);

    assign finish_done = (state == STATE_HOLD);
    assign selected_accumulator =
        (state == STATE_BIAS)
            ? accumulator_data[finish_index*32 +: 32]
            : accumulator_data[accumulate_index*32 +: 32];
    assign selected_bias =
        latched_bias_data[finish_index*32 +: 32];
    assign add_operand_a = selected_accumulator;
    assign add_operand_b =
        (state == STATE_BIAS) ? selected_bias : partial_sum;
    assign add_request =
        accumulate_valid || (state == STATE_BIAS);

    generate
        if (USE_EXTERNAL_ADD != 0) begin : gen_external_adder
            assign add_result = external_add_result;
        end else begin : gen_local_adder
            vit_fp32_add_comb u_shared_adder (
                .a      (add_operand_a),
                .b      (add_operand_b),
                .result (add_result)
            );
        end
    endgenerate

    initial begin
        if (PE_COUNT <= 0)
            $fatal(1, "vit_gemm_accumulator_bank requires PE_COUNT > 0");
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state               <= STATE_IDLE;
            finish_index        <= '0;
            accumulator_data    <= '0;
            latched_bias_enable <= 1'b0;
            latched_bias_data   <= '0;
            result_data         <= '0;
        end else if (clear) begin
            state               <= STATE_IDLE;
            finish_index        <= '0;
            accumulator_data    <= '0;
            latched_bias_enable <= 1'b0;
            latched_bias_data   <= '0;
            result_data         <= '0;
        end else begin
            if (accumulate_valid)
                accumulator_data[
                    accumulate_index*32 +: 32
                ] <= add_result;

            case (state)
                STATE_IDLE: begin
                    if (finish) begin
                        finish_index        <= '0;
                        latched_bias_enable <= bias_enable;
                        latched_bias_data   <= bias_data;
                        state               <= STATE_BIAS;
                    end
                end

                STATE_BIAS: begin
                    result_data[finish_index*32 +: 32] <=
                        latched_bias_enable
                            ? add_result
                            : selected_accumulator;
                    if (finish_index == LAST_PE_INDEX) begin
                        state <= STATE_HOLD;
                    end else begin
                        finish_index <= finish_index + 1'b1;
                    end
                end

                STATE_HOLD: begin
                    if (!finish)
                        state <= STATE_IDLE;
                end

                default: begin
                    state <= STATE_IDLE;
                end
            endcase
        end
    end

endmodule
