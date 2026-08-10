`timescale 1ns/1ps

// Exact binary32 encoding of 1/value using a restoring integer divider.
//
// This is the sequential counterpart of vit_fp32_recip_u32_comb.  It keeps
// the same round-to-nearest-even result while replacing the inferred 64-bit
// combinational / and % operators with one compare/subtract step per cycle.
(* use_dsp = "no" *)
module vit_fp32_recip_u32_serial (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic [31:0] value,
    output logic        busy,
    output logic        done,
    output logic [31:0] result
);

    localparam logic [31:0] FP32_POS_ZERO = 32'h0000_0000;
    localparam logic [31:0] FP32_POS_INF  = 32'h7f80_0000;

    typedef enum logic [1:0] {
        STATE_IDLE,
        STATE_DIVIDE,
        STATE_ROUND,
        STATE_DONE
    } state_t;

    state_t state;
    logic [63:0] denominator;
    logic [63:0] dividend;
    logic [63:0] quotient;
    logic [63:0] remainder;
    logic [5:0] division_index;
    logic signed [7:0] unbiased_exponent;

    logic [4:0] start_msb_index;
    logic start_power_of_two;
    logic [5:0] start_numerator_shift;
    logic [63:0] shifted_remainder;
    logic [63:0] rounded_quotient;
    logic [63:0] normalized_quotient;
    logic signed [8:0] biased_exponent;
    integer scan_index;

    assign busy = (state != STATE_IDLE);
    assign done = (state == STATE_DONE);
    assign start_power_of_two =
        (value != 0) && ((value & (value - 1'b1)) == 0);
    assign start_numerator_shift =
        start_power_of_two
            ? (6'd23 + {1'b0, start_msb_index})
            : (6'd24 + {1'b0, start_msb_index});
    assign shifted_remainder = {
        remainder[62:0],
        dividend[division_index]
    };

    always_comb begin
        start_msb_index = 5'd0;
        for (scan_index = 0; scan_index < 32;
             scan_index = scan_index + 1)
            if (value[scan_index])
                start_msb_index = 5'(scan_index);
    end

    always_comb begin
        rounded_quotient = quotient;
        if (((remainder << 1) > denominator) ||
            (((remainder << 1) == denominator) && quotient[0]))
            rounded_quotient = quotient + 1'b1;

        normalized_quotient = rounded_quotient;
        biased_exponent =
            $signed(unbiased_exponent) + 9'sd127;
        if (rounded_quotient[24]) begin
            normalized_quotient = rounded_quotient >> 1;
            biased_exponent =
                $signed(unbiased_exponent) + 9'sd128;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state             <= STATE_IDLE;
            denominator       <= 64'd0;
            dividend          <= 64'd0;
            quotient          <= 64'd0;
            remainder         <= 64'd0;
            division_index    <= 6'd0;
            unbiased_exponent <= 8'sd0;
            result            <= FP32_POS_ZERO;
        end else begin
            case (state)
                STATE_IDLE: begin
                    if (start) begin
                        if (value == 0) begin
                            result <= FP32_POS_INF;
                            state  <= STATE_DONE;
                        end else begin
                            denominator <= {32'd0, value};
                            dividend <=
                                64'd1 << start_numerator_shift;
                            quotient       <= 64'd0;
                            remainder      <= 64'd0;
                            division_index <= start_numerator_shift;
                            if (start_power_of_two)
                                unbiased_exponent <=
                                    -$signed({3'd0, start_msb_index});
                            else
                                unbiased_exponent <=
                                    -$signed({
                                        3'd0,
                                        start_msb_index
                                    }) - 1'b1;
                            state <= STATE_DIVIDE;
                        end
                    end
                end

                STATE_DIVIDE: begin
                    if (shifted_remainder >= denominator) begin
                        remainder <= shifted_remainder - denominator;
                        quotient[division_index] <= 1'b1;
                    end else begin
                        remainder <= shifted_remainder;
                        quotient[division_index] <= 1'b0;
                    end

                    if (division_index == 0) begin
                        state <= STATE_ROUND;
                    end else begin
                        division_index <= division_index - 1'b1;
                    end
                end

                STATE_ROUND: begin
                    if (biased_exponent >= 9'sd255)
                        result <= FP32_POS_INF;
                    else if (biased_exponent <= 0)
                        result <= FP32_POS_ZERO;
                    else
                        result <= {
                            1'b0,
                            biased_exponent[7:0],
                            normalized_quotient[22:0]
                        };
                    state <= STATE_DONE;
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
