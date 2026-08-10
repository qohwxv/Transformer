`timescale 1ns/1ps

// Validates a rank-3 layout descriptor with one shared iterative LUT
// multiplier.  This avoids synthesizing the eight wide combinational
// multipliers that were previously embedded in vit_layout_engine.
module vit_layout_descriptor_validator (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic [31:0] cfg_src_base,
    input  logic [31:0] cfg_dst_base,
    input  logic [31:0] cfg_dim0,
    input  logic [31:0] cfg_dim1,
    input  logic [31:0] cfg_dim2,
    input  logic [31:0] cfg_src_stride0,
    input  logic [31:0] cfg_src_stride1,
    input  logic [31:0] cfg_src_stride2,
    output logic        busy,
    output logic        done,
    output logic        descriptor_valid,
    output logic [31:0] total_words
);

    typedef enum logic [3:0] {
        STATE_IDLE,
        STATE_TOTAL01_START,
        STATE_TOTAL01_WAIT,
        STATE_TOTAL2_START,
        STATE_TOTAL2_WAIT,
        STATE_STRIDE0_START,
        STATE_STRIDE0_WAIT,
        STATE_STRIDE1_START,
        STATE_STRIDE1_WAIT,
        STATE_STRIDE2_START,
        STATE_STRIDE2_WAIT,
        STATE_FINAL_CHECK,
        STATE_DONE
    } state_t;

    state_t state;

    logic [31:0] active_dst_base;
    logic [31:0] active_dim0;
    logic [31:0] active_dim1;
    logic [31:0] active_dim2;
    logic [31:0] active_stride0;
    logic [31:0] active_stride1;
    logic [31:0] active_stride2;
    logic [31:0] dim01_product;
    logic [65:0] maximum_source_address;

    logic        multiply_start;
    logic [31:0] multiply_operand_a;
    logic [31:0] multiply_operand_b;
    logic        multiply_done;
    logic [63:0] multiply_product;
    logic [63:0] last_destination_address;

    assign busy = (state != STATE_IDLE);
    assign done = (state == STATE_DONE);

    always_comb begin
        multiply_start = 1'b0;
        multiply_operand_a = 32'd0;
        multiply_operand_b = 32'd0;

        case (state)
            STATE_TOTAL01_START: begin
                multiply_start = 1'b1;
                multiply_operand_a = active_dim0;
                multiply_operand_b = active_dim1;
            end

            STATE_TOTAL2_START: begin
                multiply_start = 1'b1;
                multiply_operand_a = dim01_product;
                multiply_operand_b = active_dim2;
            end

            STATE_STRIDE0_START: begin
                multiply_start = 1'b1;
                multiply_operand_a = active_dim0 - 1'b1;
                multiply_operand_b = active_stride0;
            end

            STATE_STRIDE1_START: begin
                multiply_start = 1'b1;
                multiply_operand_a = active_dim1 - 1'b1;
                multiply_operand_b = active_stride1;
            end

            STATE_STRIDE2_START: begin
                multiply_start = 1'b1;
                multiply_operand_a = active_dim2 - 1'b1;
                multiply_operand_b = active_stride2;
            end

            default: begin
                multiply_start = 1'b0;
            end
        endcase
    end

    assign last_destination_address =
        {32'd0, active_dst_base} + {32'd0, total_words} - 1'b1;

    vit_u32_mul_iterative_nodsp u_shared_multiplier (
        .clk      (clk),
        .rst      (rst),
        .start    (multiply_start),
        .operand_a(multiply_operand_a),
        .operand_b(multiply_operand_b),
        .busy     (),
        .done     (multiply_done),
        .product  (multiply_product)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            state                  <= STATE_IDLE;
            active_dst_base        <= 32'd0;
            active_dim0            <= 32'd0;
            active_dim1            <= 32'd0;
            active_dim2            <= 32'd0;
            active_stride0         <= 32'd0;
            active_stride1         <= 32'd0;
            active_stride2         <= 32'd0;
            dim01_product          <= 32'd0;
            maximum_source_address <= 66'd0;
            descriptor_valid       <= 1'b0;
            total_words            <= 32'd0;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (start) begin
                        active_dst_base        <= cfg_dst_base;
                        active_dim0            <= cfg_dim0;
                        active_dim1            <= cfg_dim1;
                        active_dim2            <= cfg_dim2;
                        active_stride0         <= cfg_src_stride0;
                        active_stride1         <= cfg_src_stride1;
                        active_stride2         <= cfg_src_stride2;
                        dim01_product          <= 32'd0;
                        maximum_source_address <= {34'd0, cfg_src_base};
                        descriptor_valid       <= 1'b0;
                        total_words            <= 32'd0;

                        if ((cfg_dim0 == 0) ||
                            (cfg_dim1 == 0) ||
                            (cfg_dim2 == 0))
                            state <= STATE_DONE;
                        else
                            state <= STATE_TOTAL01_START;
                    end
                end

                STATE_TOTAL01_START:
                    state <= STATE_TOTAL01_WAIT;

                STATE_TOTAL01_WAIT: begin
                    if (multiply_done) begin
                        if (multiply_product[63:32] != 0)
                            state <= STATE_DONE;
                        else begin
                            dim01_product <= multiply_product[31:0];
                            state <= STATE_TOTAL2_START;
                        end
                    end
                end

                STATE_TOTAL2_START:
                    state <= STATE_TOTAL2_WAIT;

                STATE_TOTAL2_WAIT: begin
                    if (multiply_done) begin
                        if (multiply_product[63:32] != 0)
                            state <= STATE_DONE;
                        else begin
                            total_words <= multiply_product[31:0];
                            state <= STATE_STRIDE0_START;
                        end
                    end
                end

                STATE_STRIDE0_START:
                    state <= STATE_STRIDE0_WAIT;

                STATE_STRIDE0_WAIT: begin
                    if (multiply_done) begin
                        maximum_source_address <=
                            maximum_source_address +
                            {2'd0, multiply_product};
                        state <= STATE_STRIDE1_START;
                    end
                end

                STATE_STRIDE1_START:
                    state <= STATE_STRIDE1_WAIT;

                STATE_STRIDE1_WAIT: begin
                    if (multiply_done) begin
                        maximum_source_address <=
                            maximum_source_address +
                            {2'd0, multiply_product};
                        state <= STATE_STRIDE2_START;
                    end
                end

                STATE_STRIDE2_START:
                    state <= STATE_STRIDE2_WAIT;

                STATE_STRIDE2_WAIT: begin
                    if (multiply_done) begin
                        maximum_source_address <=
                            maximum_source_address +
                            {2'd0, multiply_product};
                        state <= STATE_FINAL_CHECK;
                    end
                end

                STATE_FINAL_CHECK: begin
                    descriptor_valid <=
                        (maximum_source_address[65:32] == 0) &&
                        (last_destination_address[63:32] == 0);
                    state <= STATE_DONE;
                end

                STATE_DONE:
                    state <= STATE_IDLE;

                default: begin
                    descriptor_valid <= 1'b0;
                    state <= STATE_IDLE;
                end
            endcase
        end
    end

endmodule
