`timescale 1ns/1ps

// Time-multiplexed two-dimensional output-stationary PE array.
//
// One serial, bit-exact 16-lane dot-product datapath is shared across every
// row/column accumulator. Accepted A/B tiles are buffered once, then the local
// scheduler visits PE coordinates in row-major order. This retains A-row and
// B-column reuse and exact FP32 reduction order while reducing the production
// array to one fabric multiplier and one reduction adder.
(* use_dsp = "no" *)
module vit_gemm_pe_array #(
    parameter integer ARRAY_ROWS = 2,
    parameter integer ARRAY_COLS = 2,
    parameter integer PE_LANES   = 16,
    parameter integer USE_EXTERNAL_MUL = 0,
    parameter integer USE_EXTERNAL_ADD = 0
) (
    input  logic                                    clk,
    input  logic                                    rst,
    input  logic                                    clear_accumulators,
    input  logic                                    step_valid,
    output logic                                    step_done,
    input  logic                                    finish,
    output logic                                    finish_done,
    input  logic                                    bias_enable,
    input  logic [PE_LANES-1:0]                    lane_valid,
    input  logic [ARRAY_ROWS-1:0]                   token_valid,
    input  logic [ARRAY_COLS-1:0]                   output_valid,
    input  logic [ARRAY_ROWS*PE_LANES*32-1:0]       activation_data,
    input  logic [ARRAY_COLS*PE_LANES*32-1:0]       weight_data,
    input  logic [ARRAY_COLS*32-1:0]                bias_data,
    output logic [ARRAY_ROWS*ARRAY_COLS*32-1:0]     result_data,

    output logic [31:0]                             mul_operand_a,
    output logic [31:0]                             mul_operand_b,
    input  logic [31:0]                             external_mul_result,

    output logic [31:0]                             add_operand_a,
    output logic [31:0]                             add_operand_b,
    input  logic [31:0]                             external_add_result
);

    localparam integer ROW_INDEX_WIDTH =
        (ARRAY_ROWS <= 1) ? 1 : $clog2(ARRAY_ROWS);
    localparam integer COL_INDEX_WIDTH =
        (ARRAY_COLS <= 1) ? 1 : $clog2(ARRAY_COLS);
    localparam integer PE_COUNT = ARRAY_ROWS * ARRAY_COLS;
    localparam integer PE_INDEX_WIDTH =
        (PE_COUNT <= 1) ? 1 : $clog2(PE_COUNT);
    localparam logic [ROW_INDEX_WIDTH-1:0] LAST_ROW_INDEX =
        ROW_INDEX_WIDTH'(ARRAY_ROWS - 1);
    localparam logic [COL_INDEX_WIDTH-1:0] LAST_COL_INDEX =
        COL_INDEX_WIDTH'(ARRAY_COLS - 1);

    typedef enum logic [1:0] {
        STATE_IDLE,
        STATE_START_DOT,
        STATE_WAIT_DOT
    } state_t;

    state_t state;
    logic [ROW_INDEX_WIDTH-1:0] active_row_index;
    logic [COL_INDEX_WIDTH-1:0] active_col_index;
    logic [PE_LANES-1:0] latched_lane_valid;
    logic [ARRAY_ROWS-1:0] latched_token_valid;
    logic [ARRAY_COLS-1:0] latched_output_valid;
    logic [ARRAY_ROWS*PE_LANES*32-1:0]
        latched_activation_data;
    logic [ARRAY_COLS*PE_LANES*32-1:0]
        latched_weight_data;
    logic [ARRAY_COLS*32-1:0] latched_bias_data;
    logic [PE_LANES*32-1:0] selected_activation_lanes;
    logic [PE_LANES*32-1:0] selected_weight_lanes;
    logic [31:0] shared_partial_sum;
    logic shared_dot_busy;
    logic shared_dot_done;
    logic [PE_INDEX_WIDTH-1:0] active_pe_index;
    logic accumulate_valid;
    logic [PE_COUNT*32-1:0] expanded_bias_data;
    logic dot_add_request;
    logic [31:0] dot_add_operand_a;
    logic [31:0] dot_add_operand_b;
    logic accumulator_add_request;
    logic [31:0] accumulator_add_operand_a;
    logic [31:0] accumulator_add_operand_b;

    assign selected_activation_lanes =
        latched_activation_data[
            active_row_index*PE_LANES*32 +: PE_LANES*32
        ];
    assign selected_weight_lanes =
        latched_weight_data[
            active_col_index*PE_LANES*32 +: PE_LANES*32
        ];
    assign active_pe_index =
        (PE_INDEX_WIDTH'(active_row_index) *
         PE_INDEX_WIDTH'(ARRAY_COLS)) +
        PE_INDEX_WIDTH'(active_col_index);
    assign accumulate_valid =
        (state == STATE_WAIT_DOT) &&
        shared_dot_done &&
        latched_token_valid[active_row_index] &&
        latched_output_valid[active_col_index];

    // Dot reduction uses the adder only before STATE_DONE.  Accumulation starts
    // when shared_dot_done is visible, and the bias epilogue runs only after
    // the PE scheduler has returned to IDLE.  Therefore the requests are
    // mutually exclusive by construction.  Dot reduction has deterministic
    // priority if control corruption ever violates that invariant.
    always_comb begin
        add_operand_a = 32'd0;
        add_operand_b = 32'd0;

        if (dot_add_request) begin
            add_operand_a = dot_add_operand_a;
            add_operand_b = dot_add_operand_b;
        end else if (accumulator_add_request) begin
            add_operand_a = accumulator_add_operand_a;
            add_operand_b = accumulator_add_operand_b;
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (!rst && dot_add_request && accumulator_add_request)
            $fatal(
                1,
                "GEMM shared-adder collision: dot and accumulator both active"
            );
    end
`endif

    initial begin
        if (ARRAY_ROWS <= 0)
            $fatal(1, "vit_gemm_pe_array requires ARRAY_ROWS > 0");
        if (ARRAY_COLS <= 0)
            $fatal(1, "vit_gemm_pe_array requires ARRAY_COLS > 0");
        if (PE_LANES != 16)
            $fatal(1, "vit_gemm_pe_array requires PE_LANES=16");
    end

    vit_gemm_dot16_serial #(
        .USE_EXTERNAL_MUL (USE_EXTERNAL_MUL),
        .USE_EXTERNAL_ADD (USE_EXTERNAL_ADD)
    ) u_shared_dot_product (
        .clk              (clk),
        .rst              (rst),
        .start            (state == STATE_START_DOT),
        .lane_valid       (latched_lane_valid),
        .activation_lanes (selected_activation_lanes),
        .weight_lanes     (selected_weight_lanes),
        .busy             (shared_dot_busy),
        .done             (shared_dot_done),
        .partial_sum      (shared_partial_sum),
        .mul_operand_a    (mul_operand_a),
        .mul_operand_b    (mul_operand_b),
        .external_mul_result(external_mul_result),
        .add_request      (dot_add_request),
        .add_operand_a    (dot_add_operand_a),
        .add_operand_b    (dot_add_operand_b),
        .external_add_result(external_add_result)
    );

    vit_gemm_accumulator_bank #(
        .PE_COUNT       (PE_COUNT),
        .PE_INDEX_WIDTH (PE_INDEX_WIDTH),
        .USE_EXTERNAL_ADD(USE_EXTERNAL_ADD)
    ) u_accumulator_bank (
        .clk              (clk),
        .rst              (rst),
        .clear            (clear_accumulators),
        .accumulate_valid (accumulate_valid),
        .accumulate_index (active_pe_index),
        .partial_sum      (shared_partial_sum),
        .finish           (finish),
        .bias_enable      (bias_enable),
        .bias_data        (expanded_bias_data),
        .finish_done      (finish_done),
        .result_data      (result_data),
        .add_request      (accumulator_add_request),
        .add_operand_a    (accumulator_add_operand_a),
        .add_operand_b    (accumulator_add_operand_b),
        .external_add_result(external_add_result)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            state                   <= STATE_IDLE;
            step_done               <= 1'b0;
            active_row_index        <= '0;
            active_col_index        <= '0;
            latched_lane_valid      <= '0;
            latched_token_valid     <= '0;
            latched_output_valid    <= '0;
            latched_activation_data <= '0;
            latched_weight_data     <= '0;
            latched_bias_data       <= '0;
        end else begin
            step_done <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    if (step_valid) begin
                        active_row_index        <= '0;
                        active_col_index        <= '0;
                        latched_lane_valid      <= lane_valid;
                        latched_token_valid     <= token_valid;
                        latched_output_valid    <= output_valid;
                        latched_activation_data <= activation_data;
                        latched_weight_data     <= weight_data;
                        latched_bias_data       <= bias_data;
                        state                   <= STATE_START_DOT;
                    end
                end

                STATE_START_DOT: begin
                    if (!shared_dot_busy)
                        state <= STATE_WAIT_DOT;
                end

                STATE_WAIT_DOT: begin
                    if (shared_dot_done) begin
                        if ((active_row_index == LAST_ROW_INDEX) &&
                            (active_col_index == LAST_COL_INDEX)) begin
                            step_done <= 1'b1;
                            state     <= STATE_IDLE;
                        end else if (active_col_index ==
                                     LAST_COL_INDEX) begin
                            active_col_index <= '0;
                            active_row_index <= active_row_index + 1'b1;
                            state            <= STATE_START_DOT;
                        end else begin
                            active_col_index <=
                                active_col_index + 1'b1;
                            state <= STATE_START_DOT;
                        end
                    end
                end

                default: begin
                    state <= STATE_IDLE;
                end
            endcase
        end
    end

    genvar row_index;
    genvar col_index;
    generate
        for (row_index = 0; row_index < ARRAY_ROWS;
             row_index = row_index + 1) begin : gen_bias_rows
            for (col_index = 0; col_index < ARRAY_COLS;
                 col_index = col_index + 1) begin : gen_bias_cols
                localparam integer PE_INDEX =
                    row_index * ARRAY_COLS + col_index;

                assign expanded_bias_data[PE_INDEX*32 +: 32] =
                    latched_bias_data[col_index*32 +: 32];
            end
        end
    endgenerate

endmodule
