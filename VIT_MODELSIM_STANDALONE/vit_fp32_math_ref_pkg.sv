`timescale 1ns/1ps

// Floating-point special-function helpers for functional simulation only.
//
// This package intentionally uses SystemVerilog shortreal/real values and
// simulator math functions. It is useful for bringing up the ViT control and
// memory sequencing before synthesizable rsqrt/reciprocal/exp/erf units are
// available. It is NOT synthesis-ready and must not be used to estimate area,
// timing, or FPGA/ASIC numerical behavior.
//
// Questa/ModelSim supports $bitstoshortreal and $shortrealtobits. Some lint
// tools, including several Verilator versions, treat shortreal as unsupported
// or promote it to real. Keep this package in the functional-simulation
// filelist and out of the synthesizable GEMM filelist.
package vit_fp32_math_ref_pkg;

    localparam logic [31:0] FP32_REF_POS_ZERO = 32'h00000000;
    localparam logic [31:0] FP32_REF_NEG_ZERO = 32'h80000000;
    localparam logic [31:0] FP32_REF_POS_INF  = 32'h7F800000;
    localparam logic [31:0] FP32_REF_NEG_INF  = 32'hFF800000;
    localparam logic [31:0] FP32_REF_QNAN     = 32'h7FC00000;

    function automatic logic fp32_ref_is_nan(input logic [31:0] value);
        begin
            fp32_ref_is_nan = (value[30:23] == 8'hFF) &&
                              (value[22:0] != 23'd0);
        end
    endfunction

    function automatic logic fp32_ref_is_inf(input logic [31:0] value);
        begin
            fp32_ref_is_inf = (value[30:23] == 8'hFF) &&
                              (value[22:0] == 23'd0);
        end
    endfunction

    function automatic logic fp32_ref_is_zero(input logic [31:0] value);
        begin
            fp32_ref_is_zero = (value[30:0] == 31'd0);
        end
    endfunction

    function automatic real fp32_ref_to_real(input logic [31:0] value);
        shortreal converted;
        begin
            converted = $bitstoshortreal(value);
            fp32_ref_to_real = converted;
        end
    endfunction

    // Assignment to shortreal performs the final binary32 rounding before the
    // bit pattern is returned to the rest of the RTL model.
    function automatic logic [31:0] fp32_ref_from_real(input real value);
        shortreal rounded;
        begin
            rounded = value;
            fp32_ref_from_real = $shortrealtobits(rounded);
        end
    endfunction

    function automatic logic [31:0] fp32_sqrt_ref(input logic [31:0] value);
        real input_real;
        real result_real;
        begin
            if (fp32_ref_is_nan(value)) begin
                fp32_sqrt_ref = FP32_REF_QNAN;
            end else if (value == FP32_REF_NEG_INF) begin
                fp32_sqrt_ref = FP32_REF_QNAN;
            end else if (value[31] && !fp32_ref_is_zero(value)) begin
                fp32_sqrt_ref = FP32_REF_QNAN;
            end else if (fp32_ref_is_zero(value) ||
                         (value == FP32_REF_POS_INF)) begin
                // Preserve the sign of zero and pass positive infinity.
                fp32_sqrt_ref = value;
            end else begin
                input_real = fp32_ref_to_real(value);
                result_real = $sqrt(input_real);
                fp32_sqrt_ref = fp32_ref_from_real(result_real);
            end
        end
    endfunction

    function automatic logic [31:0] fp32_rsqrt_ref(input logic [31:0] value);
        real input_real;
        real result_real;
        begin
            if (fp32_ref_is_nan(value) ||
                (value[31] && !fp32_ref_is_zero(value))) begin
                fp32_rsqrt_ref = FP32_REF_QNAN;
            end else if (value == FP32_REF_POS_INF) begin
                fp32_rsqrt_ref = FP32_REF_POS_ZERO;
            end else if (value == FP32_REF_POS_ZERO) begin
                fp32_rsqrt_ref = FP32_REF_POS_INF;
            end else if (value == FP32_REF_NEG_ZERO) begin
                fp32_rsqrt_ref = FP32_REF_NEG_INF;
            end else begin
                input_real = fp32_ref_to_real(value);
                result_real = 1.0 / $sqrt(input_real);
                fp32_rsqrt_ref = fp32_ref_from_real(result_real);
            end
        end
    endfunction

    function automatic logic [31:0] fp32_recip_ref(input logic [31:0] value);
        real input_real;
        real result_real;
        begin
            if (fp32_ref_is_nan(value)) begin
                fp32_recip_ref = FP32_REF_QNAN;
            end else if (value == FP32_REF_POS_INF) begin
                fp32_recip_ref = FP32_REF_POS_ZERO;
            end else if (value == FP32_REF_NEG_INF) begin
                fp32_recip_ref = FP32_REF_NEG_ZERO;
            end else if (value == FP32_REF_POS_ZERO) begin
                fp32_recip_ref = FP32_REF_POS_INF;
            end else if (value == FP32_REF_NEG_ZERO) begin
                fp32_recip_ref = FP32_REF_NEG_INF;
            end else begin
                input_real = fp32_ref_to_real(value);
                result_real = 1.0 / input_real;
                fp32_recip_ref = fp32_ref_from_real(result_real);
            end
        end
    endfunction

    // Convenience helper for runtime reduction widths such as LayerNorm's
    // hidden size. It is intentionally a reference conversion through real;
    // production RTL should receive a programmed FP32 reciprocal or use a
    // synthesizable integer-to-float/divide path.
    function automatic logic [31:0] fp32_recip_u32_ref(input logic [31:0] value);
        longint unsigned integer_value;
        real denominator;
        begin
            if (value == 0) begin
                fp32_recip_u32_ref = FP32_REF_POS_INF;
            end else begin
                integer_value = value;
                denominator = integer_value;
                fp32_recip_u32_ref = fp32_ref_from_real(1.0 / denominator);
            end
        end
    endfunction

    function automatic logic [31:0] fp32_exp_ref(input logic [31:0] value);
        real input_real;
        real result_real;
        begin
            if (fp32_ref_is_nan(value)) begin
                fp32_exp_ref = FP32_REF_QNAN;
            end else if (value == FP32_REF_POS_INF) begin
                fp32_exp_ref = FP32_REF_POS_INF;
            end else if (value == FP32_REF_NEG_INF) begin
                fp32_exp_ref = FP32_REF_POS_ZERO;
            end else begin
                input_real = fp32_ref_to_real(value);
                result_real = $exp(input_real);
                fp32_exp_ref = fp32_ref_from_real(result_real);
            end
        end
    endfunction

    // Propagating maximum for the Softmax reference engine. A row containing
    // a NaN remains a NaN row. For equal signed zeros, +0 is selected.
    function automatic logic [31:0] fp32_max_ref(
        input logic [31:0] a,
        input logic [31:0] b
    );
        real a_real;
        real b_real;
        begin
            if (fp32_ref_is_nan(a) || fp32_ref_is_nan(b)) begin
                fp32_max_ref = FP32_REF_QNAN;
            end else if (fp32_ref_is_zero(a) && fp32_ref_is_zero(b)) begin
                fp32_max_ref = FP32_REF_POS_ZERO;
            end else begin
                a_real = fp32_ref_to_real(a);
                b_real = fp32_ref_to_real(b);
                fp32_max_ref = (a_real >= b_real) ? a : b;
            end
        end
    endfunction

    // Abramowitz and Stegun 7.1.26. The maximum absolute erf error of this
    // approximation is about 1.5e-7. Keeping the polynomial in real arithmetic
    // makes this a simulator reference, not a proposed hardware datapath.
    function automatic real erf_as_ref_real(input real value);
        real absolute_value;
        real t;
        real polynomial;
        real magnitude;
        begin
            absolute_value = (value < 0.0) ? -value : value;
            t = 1.0 / (1.0 + 0.3275911 * absolute_value);
            polynomial = (((((1.061405429 * t - 1.453152027) * t +
                              1.421413741) * t - 0.284496736) * t +
                              0.254829592) * t);
            magnitude = 1.0 - polynomial * $exp(-absolute_value * absolute_value);
            erf_as_ref_real = (value < 0.0) ? -magnitude : magnitude;
        end
    endfunction

    function automatic logic [31:0] fp32_erf_ref(input logic [31:0] value);
        real input_real;
        real result_real;
        begin
            if (fp32_ref_is_nan(value)) begin
                fp32_erf_ref = FP32_REF_QNAN;
            end else if (value == FP32_REF_POS_INF) begin
                fp32_erf_ref = 32'h3F800000;
            end else if (value == FP32_REF_NEG_INF) begin
                fp32_erf_ref = 32'hBF800000;
            end else if (fp32_ref_is_zero(value)) begin
                fp32_erf_ref = value;
            end else begin
                input_real = fp32_ref_to_real(value);
                result_real = erf_as_ref_real(input_real);
                fp32_erf_ref = fp32_ref_from_real(result_real);
            end
        end
    endfunction

    // Exact-erf-style GELU target used by google/vit-base-patch16-224:
    //     GELU(x) = 0.5*x*(1 + erf(x/sqrt(2)))
    // erf is evaluated with the A&S approximation above. On the saved layer-0
    // FC1 tensor this differs from PyTorch exact GELU by less than 1e-6.
    function automatic logic [31:0] fp32_gelu_ref(input logic [31:0] value);
        real input_real;
        real erf_real;
        real result_real;
        begin
            if (fp32_ref_is_nan(value) || (value == FP32_REF_NEG_INF)) begin
                // PyTorch exact GELU also returns NaN for negative infinity.
                fp32_gelu_ref = FP32_REF_QNAN;
            end else if (value == FP32_REF_POS_INF) begin
                fp32_gelu_ref = FP32_REF_POS_INF;
            end else if (fp32_ref_is_zero(value)) begin
                // PyTorch's exact-erf implementation canonicalizes -0 to +0.
                fp32_gelu_ref = FP32_REF_POS_ZERO;
            end else begin
                input_real = fp32_ref_to_real(value);
                erf_real = erf_as_ref_real(input_real * 0.70710678118654752440);
                result_real = 0.5 * input_real * (1.0 + erf_real);
                fp32_gelu_ref = fp32_ref_from_real(result_real);
            end
        end
    endfunction

endpackage
