`timescale 1ns/1ps

// One shared GELU lane.  The streaming engine selects a lane from the latched
// vector and reuses this datapath once per cycle.
(* use_dsp = "no" *)
module vit_gelu_lane_datapath (
    input  logic [31:0] input_value,
    output logic [31:0] output_value
);

    vit_fp32_gelu_comb u_gelu (
        .value  (input_value),
        .result (output_value)
    );

endmodule
