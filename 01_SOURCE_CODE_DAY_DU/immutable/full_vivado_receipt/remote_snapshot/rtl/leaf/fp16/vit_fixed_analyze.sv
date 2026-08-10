`timescale 1ns/1ps

// First half of the pipelined fixed-to-FP32 conversion: absolute value and
// leading-one detection.  Registering its outputs separates the wide carry
// propagation from the later normalization barrel shift.
module vit_fixed_analyze #(
    parameter integer ACC_WIDTH = 93,
    parameter integer INDEX_WIDTH = $clog2(ACC_WIDTH)
) (
    input  logic signed [ACC_WIDTH-1:0] value,
    output logic                         value_sign,
    output logic [ACC_WIDTH-1:0]         magnitude,
    output logic                         is_zero,
    output logic [INDEX_WIDTH-1:0]       leading_index
);

    logic found_leading_one;
    integer scan_index;

    always_comb begin
        value_sign = value[ACC_WIDTH-1];
        if (value_sign)
            magnitude = (~value) + {{(ACC_WIDTH-1){1'b0}}, 1'b1};
        else
            magnitude = value;

        is_zero = (magnitude == {ACC_WIDTH{1'b0}});
        leading_index = '0;
        found_leading_one = 1'b0;
        for (scan_index = ACC_WIDTH - 1;
             scan_index >= 0;
             scan_index = scan_index - 1)
            if (!found_leading_one && magnitude[scan_index]) begin
                found_leading_one = 1'b1;
                leading_index = scan_index[INDEX_WIDTH-1:0];
            end
    end

endmodule
