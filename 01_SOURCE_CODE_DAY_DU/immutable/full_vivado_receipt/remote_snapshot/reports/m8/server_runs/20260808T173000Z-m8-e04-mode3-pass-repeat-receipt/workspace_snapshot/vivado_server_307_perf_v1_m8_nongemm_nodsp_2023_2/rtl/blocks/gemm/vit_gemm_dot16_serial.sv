`timescale 1ns/1ps

// Bit-exact, time-multiplexed 16-lane FP32 dot product.
//
// A single fabric multiplier produces the 16 rounded products. A single FP32
// adder then replays the same balanced reduction order as vit_fp32_reduce16:
// 8 pair sums, 4 quarter sums, 2 half sums, and one root sum. The sequential
// schedule changes latency only; every arithmetic edge and rounding point is
// identical to the parallel tree.
(* use_dsp = "no" *)
module vit_gemm_dot16_serial #(
    parameter integer USE_EXTERNAL_MUL = 0,
    parameter integer USE_EXTERNAL_ADD = 0
) (
    input  logic         clk,
    input  logic         rst,
    input  logic         start,
    input  logic [15:0]  lane_valid,
    input  logic [511:0] activation_lanes,
    input  logic [511:0] weight_lanes,
    output logic         busy,
    output logic         done,
    output logic [31:0]  partial_sum,

    // Optional hierarchy-level FP32 multiplier service.  Standalone GEMM
    // tests retain the local multiplier by leaving USE_EXTERNAL_MUL at zero.
    output logic [31:0]  mul_operand_a,
    output logic [31:0]  mul_operand_b,
    input  logic [31:0]  external_mul_result,

    output logic         add_request,
    output logic [31:0]  add_operand_a,
    output logic [31:0]  add_operand_b,
    input  logic [31:0]  external_add_result
);

    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_MULTIPLY,
        STATE_REDUCE_1,
        STATE_REDUCE_2,
        STATE_REDUCE_3,
        STATE_REDUCE_ROOT,
        STATE_DONE
    } state_t;

    state_t state;
    logic [3:0] operation_index;
    logic [511:0] activation_shift;
    logic [511:0] weight_shift;
    logic [15:0] lane_valid_shift;
    logic [31:0] reduction_buffer [0:15];
    logic [31:0] raw_product;
    logic [31:0] valid_product;
    logic [31:0] add_result;
    integer reset_index;

    assign busy = (state != STATE_IDLE);
    assign done = (state == STATE_DONE);
    assign valid_product =
        lane_valid_shift[0] ? raw_product : 32'd0;
    assign mul_operand_a = activation_shift[31:0];
    assign mul_operand_b = weight_shift[31:0];
    assign add_request =
        (state == STATE_REDUCE_1) ||
        (state == STATE_REDUCE_2) ||
        (state == STATE_REDUCE_3) ||
        (state == STATE_REDUCE_ROOT);

    generate
        if (USE_EXTERNAL_MUL != 0) begin : gen_external_multiplier
            assign raw_product = external_mul_result;
        end else begin : gen_local_multiplier
            vit_fp32_mul_comb_nodsp u_shared_multiplier (
                .a      (mul_operand_a),
                .b      (mul_operand_b),
                .result (raw_product)
            );
        end
    endgenerate

    always_comb begin
        add_operand_a = 32'd0;
        add_operand_b = 32'd0;

        case (state)
            STATE_REDUCE_1,
            STATE_REDUCE_2,
            STATE_REDUCE_3: begin
                add_operand_a =
                    reduction_buffer[operation_index << 1];
                add_operand_b =
                    reduction_buffer[(operation_index << 1) + 1'b1];
            end

            STATE_REDUCE_ROOT: begin
                add_operand_a = reduction_buffer[0];
                add_operand_b = reduction_buffer[1];
            end

            default: begin
            end
        endcase
    end

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

    always_ff @(posedge clk) begin
        if (rst) begin
            state             <= STATE_IDLE;
            operation_index   <= 4'd0;
            activation_shift  <= '0;
            weight_shift      <= '0;
            lane_valid_shift  <= '0;
            partial_sum       <= 32'd0;
            for (reset_index = 0; reset_index < 16;
                 reset_index = reset_index + 1)
                reduction_buffer[reset_index] <= 32'd0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (start) begin
                        operation_index  <= 4'd0;
                        activation_shift <= activation_lanes;
                        weight_shift     <= weight_lanes;
                        lane_valid_shift <= lane_valid;
                        state            <= STATE_MULTIPLY;
                    end
                end

                STATE_MULTIPLY: begin
                    reduction_buffer[operation_index] <= valid_product;
                    activation_shift <= activation_shift >> 32;
                    weight_shift     <= weight_shift >> 32;
                    lane_valid_shift <= lane_valid_shift >> 1;

                    if (operation_index == 4'd15) begin
                        operation_index <= 4'd0;
                        state           <= STATE_REDUCE_1;
                    end else begin
                        operation_index <= operation_index + 1'b1;
                    end
                end

                STATE_REDUCE_1: begin
                    reduction_buffer[operation_index] <= add_result;
                    if (operation_index == 4'd7) begin
                        operation_index <= 4'd0;
                        state           <= STATE_REDUCE_2;
                    end else begin
                        operation_index <= operation_index + 1'b1;
                    end
                end

                STATE_REDUCE_2: begin
                    reduction_buffer[operation_index] <= add_result;
                    if (operation_index == 4'd3) begin
                        operation_index <= 4'd0;
                        state           <= STATE_REDUCE_3;
                    end else begin
                        operation_index <= operation_index + 1'b1;
                    end
                end

                STATE_REDUCE_3: begin
                    reduction_buffer[operation_index] <= add_result;
                    if (operation_index == 4'd1) begin
                        operation_index <= 4'd0;
                        state           <= STATE_REDUCE_ROOT;
                    end else begin
                        operation_index <= operation_index + 1'b1;
                    end
                end

                STATE_REDUCE_ROOT: begin
                    partial_sum <= add_result;
                    state       <= STATE_DONE;
                end

                STATE_DONE: begin
                    state <= STATE_IDLE;
                end

                default: begin
                    state <= STATE_IDLE;
                end
            endcase
        end
    end

endmodule
