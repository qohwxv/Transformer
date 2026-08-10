`timescale 1ns/1ps

// FP32 vector engine with one time-shared arithmetic lane.
//
// MODE_ADD:
//     result[i] = input_a[i] + input_b[i]
//
// MODE_SCALE_MASK:
//     scaled = input_a[i] * cfg_scalar
//     result[i] = cfg_mask_enable ? scaled + input_b[i] : scaled
//
// input_b is therefore the second residual/vector operand in MODE_ADD and the
// additive attention mask in MODE_SCALE_MASK.  Bypassing the mask is explicit:
// a disabled mask bus may contain arbitrary data without affecting the result.
//
// The external interface remains one packed LANES-word transaction.  Accepted
// operands are held in shift registers and evaluated one lane at a time.  A
// register separates multiply and add so SCALE_MASK does not create a
// multiplier-to-adder combinational path.  This keeps the exact per-lane FP32
// operation while replacing LANES parallel multiplier/adder pairs with one
// shared pair.
module vit_vector_engine_fp32 #(
    parameter integer LANES = 16,
    parameter integer USE_EXTERNAL_MUL = 0,
    parameter integer USE_EXTERNAL_ADD = 0
)(
    input  logic                    clk,
    input  logic                    rst,

    input  logic                    start,
    input  logic [1:0]              cfg_mode,
    input  logic [31:0]             cfg_length,
    input  logic [31:0]             cfg_scalar,
    input  logic                    cfg_mask_enable,
    output logic                    busy,
    output logic                    done,
    output logic                    config_error,

    // One packed vector is accepted only when data_request and data_valid are
    // both high. element_base is the first flat element represented by it.
    output logic                    data_request,
    input  logic                    data_valid,
    output logic [31:0]             element_base,
    input  logic [LANES*32-1:0]     input_a,
    input  logic [LANES*32-1:0]     input_b,

    // A result vector and its metadata remain stable until result_ready.
    output logic                    result_valid,
    input  logic                    result_ready,
    output logic [31:0]             result_base,
    output logic [LANES-1:0]        result_lane_mask,
    output logic [LANES*32-1:0]     result_data,

    output logic [31:0]             mul_operand_a,
    output logic [31:0]             mul_operand_b,
    input  logic [31:0]             external_mul_result,

    output logic [31:0]             add_operand_a,
    output logic [31:0]             add_operand_b,
    input  logic [31:0]             external_add_result
);

    localparam logic [1:0] MODE_ADD        = 2'd0;
    localparam logic [1:0] MODE_SCALE_MASK = 2'd1;
    localparam logic [32:0] LANES_WIDE = 33'(LANES);

    localparam integer LANE_INDEX_WIDTH =
        (LANES <= 1) ? 1 : $clog2(LANES);
    localparam logic [LANE_INDEX_WIDTH-1:0] LAST_LANE_INDEX =
        LANE_INDEX_WIDTH'(LANES - 1);

    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_LOAD,
        STATE_MULTIPLY,
        STATE_ADD,
        STATE_WRITE,
        STATE_DONE
    } state_t;

    state_t state;

    logic [1:0] active_mode;
    logic [31:0] active_length;
    logic [31:0] active_scalar;
    logic active_mask_enable;
    logic [LANES-1:0] current_lane_mask;
    logic [LANES*32-1:0] input_a_shift;
    logic [LANES*32-1:0] input_b_shift;
    logic [LANES-1:0] lane_mask_shift;
    logic [LANE_INDEX_WIDTH-1:0] compute_lane_index;
    logic [31:0] shared_scaled_data;
    logic [31:0] scaled_data_reg;
    logic [31:0] shared_added_data;
    logic [31:0] shared_result_data;
    logic [LANES*32-1:0] result_data_reg;
    logic [31:0] result_base_reg;
    logic [LANES-1:0] result_lane_mask_reg;

    assign busy = (state != STATE_IDLE);
    assign done = (state == STATE_DONE);
    assign data_request = (state == STATE_LOAD);
    assign result_valid = (state == STATE_WRITE);
    assign result_base = result_base_reg;
    assign result_lane_mask = result_lane_mask_reg;
    assign result_data = result_data_reg;
    assign mul_operand_a = input_a_shift[31:0];
    assign mul_operand_b = active_scalar;

    vit_lane_mask #(
        .LANES(LANES)
    ) u_lane_mask (
        .base_index (element_base),
        .length     (active_length),
        .lane_mask  (current_lane_mask)
    );

    generate
        if (USE_EXTERNAL_MUL != 0) begin : gen_external_multiplier
            assign shared_scaled_data = external_mul_result;
        end else begin : gen_local_multiplier
            vit_fp32_mul_comb_nodsp u_shared_multiplier (
                .a      (mul_operand_a),
                .b      (mul_operand_b),
                .result (shared_scaled_data)
            );
        end
    endgenerate

    assign add_operand_a =
        (active_mode == MODE_ADD) ? input_a_shift[31:0] : scaled_data_reg;
    assign add_operand_b = input_b_shift[31:0];

    generate
        if (USE_EXTERNAL_ADD != 0) begin : gen_external_adder
            assign shared_added_data = external_add_result;
        end else begin : gen_local_adder
            vit_fp32_add_comb u_shared_adder (
                .a      (add_operand_a),
                .b      (add_operand_b),
                .result (shared_added_data)
            );
        end
    endgenerate

    always_comb begin
        if (!lane_mask_shift[0])
            shared_result_data = 32'd0;
        else if ((active_mode == MODE_SCALE_MASK) &&
                 !active_mask_enable)
            shared_result_data = scaled_data_reg;
        else
            shared_result_data = shared_added_data;
    end

    initial begin
        if (LANES != 16)
            $fatal(1, "vit_vector_engine_fp32 requires LANES=16");
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state                    <= STATE_IDLE;
            config_error             <= 1'b0;
            active_mode              <= MODE_ADD;
            active_length            <= 32'd0;
            active_scalar            <= 32'd0;
            active_mask_enable       <= 1'b0;
            element_base             <= 32'd0;
            input_a_shift            <= '0;
            input_b_shift            <= '0;
            lane_mask_shift          <= '0;
            compute_lane_index       <= '0;
            scaled_data_reg          <= 32'd0;
            result_data_reg          <= '0;
            result_base_reg          <= 32'd0;
            result_lane_mask_reg     <= '0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (start) begin
                        element_base <= 32'd0;
                        if ((cfg_length == 0) ||
                            ((cfg_mode != MODE_ADD) &&
                             (cfg_mode != MODE_SCALE_MASK))) begin
                            config_error <= 1'b1;
                            state <= STATE_DONE;
                        end else begin
                            config_error       <= 1'b0;
                            active_mode        <= cfg_mode;
                            active_length      <= cfg_length;
                            active_scalar      <= cfg_scalar;
                            active_mask_enable <= cfg_mask_enable;
                            state              <= STATE_LOAD;
                        end
                    end
                end

                STATE_LOAD: begin
                    if (data_valid) begin
                        input_a_shift        <= input_a;
                        input_b_shift        <= input_b;
                        lane_mask_shift      <= current_lane_mask;
                        compute_lane_index   <= '0;
                        result_data_reg      <= '0;
                        result_base_reg      <= element_base;
                        result_lane_mask_reg <= current_lane_mask;
                        state                <= STATE_MULTIPLY;
                    end
                end

                STATE_MULTIPLY: begin
                    scaled_data_reg <= shared_scaled_data;
                    state <= STATE_ADD;
                end

                STATE_ADD: begin
                    result_data_reg[
                        compute_lane_index*32 +: 32
                    ] <= shared_result_data;
                    input_a_shift   <= input_a_shift >> 32;
                    input_b_shift   <= input_b_shift >> 32;
                    lane_mask_shift <= lane_mask_shift >> 1;

                    if (compute_lane_index == LAST_LANE_INDEX) begin
                        state                <= STATE_WRITE;
                    end else begin
                        compute_lane_index <= compute_lane_index + 1'b1;
                        state <= STATE_MULTIPLY;
                    end
                end

                STATE_WRITE: begin
                    if (result_ready) begin
                        if (({1'b0, element_base} + LANES_WIDE) >=
                            {1'b0, active_length}) begin
                            state <= STATE_DONE;
                        end else begin
                            element_base <= element_base + LANES;
                            state <= STATE_LOAD;
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
