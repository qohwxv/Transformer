`timescale 1ns/1ps

// Bit-exact equivalence checks between the explicit activation/normalization
// datapaths and the original package arithmetic contracts.
module tb_vit_activation_norm_leaf_equivalence;

    import vit_fp32_pkg::*;

    logic [31:0] gelu_input;
    logic [31:0] gelu_output;

    logic [31:0] reciprocal_u32_input;
    logic [31:0] reciprocal_u32_output;

    logic [31:0] softmax_input;
    logic [31:0] softmax_maximum;
    logic [31:0] softmax_sum;
    logic [31:0] softmax_reciprocal;
    logic [31:0] softmax_exponential;
    logic [31:0] softmax_next_sum;
    logic [31:0] softmax_normalized;
    logic [31:0] reciprocal_operand;
    logic [31:0] reciprocal_estimate;
    logic [31:0] reciprocal_next;

    logic        statistics_variance_mode;
    logic [31:0] statistics_sample;
    logic [31:0] statistics_mean;
    logic [31:0] statistics_accumulator;
    logic [31:0] statistics_scale_operand;
    logic [31:0] statistics_reciprocal_size;
    logic [31:0] statistics_variance;
    logic [31:0] statistics_epsilon;
    logic [31:0] statistics_accumulation_next;
    logic [31:0] statistics_scaled;
    logic [31:0] statistics_variance_epsilon;

    logic [31:0] affine_sample;
    logic [31:0] affine_mean;
    logic [31:0] affine_inv_std;
    logic [31:0] affine_gamma;
    logic [31:0] affine_beta;
    logic [31:0] affine_result;

    integer check_count;
    integer random_index;

    vit_fp32_gelu_comb u_gelu (
        .value(gelu_input), .result(gelu_output)
    );
    vit_fp32_recip_u32_comb u_reciprocal_u32 (
        .value(reciprocal_u32_input), .result(reciprocal_u32_output)
    );
    vit_softmax_exp_datapath u_softmax_exp (
        .input_value(softmax_input),
        .row_maximum(softmax_maximum),
        .exponential_sum(softmax_sum),
        .reciprocal_sum(softmax_reciprocal),
        .exponential_value(softmax_exponential),
        .next_exponential_sum(softmax_next_sum),
        .normalized_value(softmax_normalized)
    );
    vit_softmax_reciprocal_step u_softmax_reciprocal (
        .operand(reciprocal_operand),
        .estimate(reciprocal_estimate),
        .next_estimate(reciprocal_next)
    );
    vit_layernorm_statistics_datapath u_layernorm_statistics (
        .variance_mode(statistics_variance_mode),
        .sample(statistics_sample),
        .mean(statistics_mean),
        .accumulator(statistics_accumulator),
        .scale_operand(statistics_scale_operand),
        .reciprocal_hidden_size(statistics_reciprocal_size),
        .variance(statistics_variance),
        .epsilon(statistics_epsilon),
        .accumulation_next(statistics_accumulation_next),
        .scaled_statistic(statistics_scaled),
        .variance_plus_epsilon(statistics_variance_epsilon)
    );
    vit_layernorm_affine_datapath u_layernorm_affine (
        .sample(affine_sample),
        .mean(affine_mean),
        .inverse_standard_deviation(affine_inv_std),
        .gamma(affine_gamma),
        .beta(affine_beta),
        .result(affine_result)
    );

    task automatic check_gelu(input logic [31:0] value);
        logic [31:0] expected;
        begin
            gelu_input = value;
            #1;
            expected = fp32_gelu_synth(value);
            if (gelu_output !== expected)
                $fatal(
                    1,
                    "GELU leaf mismatch value=%08x got=%08x expected=%08x",
                    value,
                    gelu_output,
                    expected
                );
            check_count = check_count + 1;
        end
    endtask

    task automatic check_reciprocal_u32(
        input logic [31:0] value,
        input logic [31:0] expected
    );
        begin
            reciprocal_u32_input = value;
            #1;
            if (reciprocal_u32_output !== expected)
                $fatal(
                    1,
                    "U32 reciprocal mismatch value=%0d got=%08x expected=%08x",
                    value,
                    reciprocal_u32_output,
                    expected
                );
            check_count = check_count + 1;
        end
    endtask

    task automatic check_softmax_exp(
        input logic [31:0] input_value,
        input logic [31:0] maximum_value,
        input logic [31:0] sum_value,
        input logic [31:0] reciprocal_value
    );
        logic [31:0] expected_exponential;
        logic [31:0] expected_sum;
        logic [31:0] expected_normalized;
        begin
            softmax_input = input_value;
            softmax_maximum = maximum_value;
            softmax_sum = sum_value;
            softmax_reciprocal = reciprocal_value;
            #1;
            expected_exponential = fp32_exp_neg_synth(
                fp32_sub_synth(input_value, maximum_value)
            );
            expected_sum = fp32_add(sum_value, expected_exponential);
            expected_normalized = fp32_mul(
                expected_exponential,
                reciprocal_value
            );
            if ((softmax_exponential !== expected_exponential) ||
                (softmax_next_sum !== expected_sum) ||
                (softmax_normalized !== expected_normalized))
                $fatal(
                    1,
                    "Softmax datapath mismatch exp=%08x/%08x sum=%08x/%08x norm=%08x/%08x",
                    softmax_exponential,
                    expected_exponential,
                    softmax_next_sum,
                    expected_sum,
                    softmax_normalized,
                    expected_normalized
                );
            check_count = check_count + 3;
        end
    endtask

    task automatic check_reciprocal_step(
        input logic [31:0] operand,
        input logic [31:0] estimate
    );
        logic [31:0] expected;
        begin
            reciprocal_operand = operand;
            reciprocal_estimate = estimate;
            #1;
            expected = fp32_mul(
                estimate,
                fp32_sub_synth(
                    32'h4000_0000,
                    fp32_mul(operand, estimate)
                )
            );
            if (reciprocal_next !== expected)
                $fatal(
                    1,
                    "Reciprocal step mismatch got=%08x expected=%08x",
                    reciprocal_next,
                    expected
                );
            check_count = check_count + 1;
        end
    endtask

    task automatic check_statistics(
        input logic        variance_mode,
        input logic [31:0] sample,
        input logic [31:0] mean,
        input logic [31:0] accumulator,
        input logic [31:0] scale_operand,
        input logic [31:0] reciprocal_size,
        input logic [31:0] variance,
        input logic [31:0] epsilon
    );
        logic [31:0] centered;
        logic [31:0] addend;
        logic [31:0] expected_accumulation;
        logic [31:0] expected_scaled;
        logic [31:0] expected_variance_epsilon;
        begin
            statistics_variance_mode = variance_mode;
            statistics_sample = sample;
            statistics_mean = mean;
            statistics_accumulator = accumulator;
            statistics_scale_operand = scale_operand;
            statistics_reciprocal_size = reciprocal_size;
            statistics_variance = variance;
            statistics_epsilon = epsilon;
            #1;
            centered = fp32_sub_synth(sample, mean);
            addend = variance_mode ?
                     fp32_mul(centered, centered) :
                     sample;
            expected_accumulation = fp32_add(accumulator, addend);
            expected_scaled = fp32_mul(scale_operand, reciprocal_size);
            expected_variance_epsilon = fp32_add(variance, epsilon);
            if ((statistics_accumulation_next !== expected_accumulation) ||
                (statistics_scaled !== expected_scaled) ||
                (statistics_variance_epsilon !== expected_variance_epsilon))
                $fatal(
                    1,
                    "LayerNorm statistics mismatch acc=%08x/%08x scale=%08x/%08x eps=%08x/%08x",
                    statistics_accumulation_next,
                    expected_accumulation,
                    statistics_scaled,
                    expected_scaled,
                    statistics_variance_epsilon,
                    expected_variance_epsilon
                );
            check_count = check_count + 3;
        end
    endtask

    task automatic check_affine(
        input logic [31:0] sample,
        input logic [31:0] mean,
        input logic [31:0] inverse_standard_deviation,
        input logic [31:0] gamma,
        input logic [31:0] beta
    );
        logic [31:0] expected;
        begin
            affine_sample = sample;
            affine_mean = mean;
            affine_inv_std = inverse_standard_deviation;
            affine_gamma = gamma;
            affine_beta = beta;
            #1;
            expected = fp32_add(
                fp32_mul(
                    fp32_mul(
                        fp32_sub_synth(sample, mean),
                        inverse_standard_deviation
                    ),
                    gamma
                ),
                beta
            );
            if (affine_result !== expected)
                $fatal(
                    1,
                    "LayerNorm affine mismatch got=%08x expected=%08x",
                    affine_result,
                    expected
                );
            check_count = check_count + 1;
        end
    endtask

    initial begin
        check_count = 0;
        gelu_input = 32'd0;
        reciprocal_u32_input = 32'd0;
        softmax_input = 32'd0;
        softmax_maximum = 32'd0;
        softmax_sum = 32'd0;
        softmax_reciprocal = 32'd0;
        reciprocal_operand = 32'd0;
        reciprocal_estimate = 32'd0;
        statistics_variance_mode = 1'b0;
        statistics_sample = 32'd0;
        statistics_mean = 32'd0;
        statistics_accumulator = 32'd0;
        statistics_scale_operand = 32'd0;
        statistics_reciprocal_size = 32'd0;
        statistics_variance = 32'd0;
        statistics_epsilon = 32'd0;
        affine_sample = 32'd0;
        affine_mean = 32'd0;
        affine_inv_std = 32'd0;
        affine_gamma = 32'd0;
        affine_beta = 32'd0;

        check_gelu(32'hff80_0000);
        check_gelu(32'hc0c0_0000);
        check_gelu(32'hc040_0000);
        check_gelu(32'hbf80_0000);
        check_gelu(32'h8000_0000);
        check_gelu(32'h0000_0000);
        check_gelu(32'h3f00_0000);
        check_gelu(32'h3f80_0000);
        check_gelu(32'h4040_0000);
        check_gelu(32'h40c0_0000);
        check_gelu(32'h7f80_0000);
        check_gelu(32'h7fc1_2345);

        for (random_index = 0; random_index < 64;
             random_index = random_index + 1)
            check_gelu($urandom);

        check_reciprocal_u32(32'd0,    32'h7f80_0000);
        check_reciprocal_u32(32'd1,    32'h3f80_0000);
        check_reciprocal_u32(32'd2,    32'h3f00_0000);
        check_reciprocal_u32(32'd3,    32'h3eaa_aaab);
        check_reciprocal_u32(32'd768,  32'h3aaa_aaab);
        check_reciprocal_u32(32'd3072, 32'h39aa_aaab);

        check_softmax_exp(
            32'h3f80_0000,
            32'h4080_0000,
            32'h3f80_0000,
            32'h3e80_0000
        );
        check_softmax_exp(
            32'h4080_0000,
            32'h4080_0000,
            32'h4040_0000,
            32'h3d80_0000
        );
        check_reciprocal_step(32'h4080_0000, 32'h3e70_0000);

        check_statistics(
            1'b0,
            32'h4000_0000,
            32'h3f80_0000,
            32'h4040_0000,
            32'h4120_0000,
            32'h3e80_0000,
            32'h3fa0_0000,
            32'h3727_c5ac
        );
        check_statistics(
            1'b1,
            32'h4080_0000,
            32'h4020_0000,
            32'h3f80_0000,
            32'h40a0_0000,
            32'h3e80_0000,
            32'h3fa0_0000,
            32'h3727_c5ac
        );
        check_affine(
            32'h4080_0000,
            32'h4020_0000,
            32'h3f64_f8f3,
            32'h3f80_0000,
            32'h0000_0000
        );

        for (random_index = 0; random_index < 64;
             random_index = random_index + 1) begin
            check_softmax_exp(
                $urandom,
                $urandom,
                $urandom,
                $urandom
            );
            check_reciprocal_step($urandom, $urandom);
            check_statistics(
                random_index[0],
                $urandom,
                $urandom,
                $urandom,
                $urandom,
                $urandom,
                $urandom,
                $urandom
            );
            check_affine(
                $urandom,
                $urandom,
                $urandom,
                $urandom,
                $urandom
            );
        end

        $display(
            "PASS activation/normalization leaf equivalence checks=%0d",
            check_count
        );
        $finish;
    end

endmodule
