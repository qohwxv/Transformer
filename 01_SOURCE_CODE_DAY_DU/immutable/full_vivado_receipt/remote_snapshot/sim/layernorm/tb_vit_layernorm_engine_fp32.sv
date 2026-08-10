`timescale 1ns/1ps

module tb_vit_layernorm_engine_fp32;

    logic clk;
    logic rst;
    logic start;
    logic [31:0] cfg_token_count;
    logic [31:0] cfg_hidden_size;
    logic [31:0] cfg_epsilon;
    logic busy;
    logic done;
    logic config_error;
    logic data_request;
    logic input_valid;
    logic [1:0] data_pass;
    logic [31:0] data_index;
    logic [31:0] input_data;
    logic [31:0] gamma_data;
    logic [31:0] beta_data;
    logic result_valid;
    logic result_ready;
    logic [31:0] result_index;
    logic [31:0] result_data;
    logic [31:0] debug_mean;
    logic [31:0] debug_variance;
    logic [31:0] debug_inv_std;
    logic [31:0] reciprocal_test_input;
    logic [31:0] reciprocal_test_output;

    logic [31:0] input_words [0:3];
    logic [31:0] observed [0:3];
    logic done_seen;
    integer result_count;
    integer cycle_count;

    always #5 clk = ~clk;

    always_comb begin
        input_valid = data_request;
        input_data = input_words[data_index[1:0]];
        gamma_data = 32'h3f80_0000;
        beta_data = 32'h0000_0000;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            result_count <= 0;
            done_seen <= 1'b0;
        end else if (result_valid && result_ready) begin
            observed[result_index[1:0]] <= result_data;
            result_count <= result_count + 1;
        end
        if (!rst && done)
            done_seen <= 1'b1;
    end

    vit_layernorm_engine_fp32 dut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .cfg_token_count(cfg_token_count),
        .cfg_hidden_size(cfg_hidden_size),
        .cfg_epsilon(cfg_epsilon),
        .busy(busy),
        .done(done),
        .config_error(config_error),
        .data_request(data_request),
        .input_valid(input_valid),
        .data_pass(data_pass),
        .data_index(data_index),
        .input_data(input_data),
        .gamma_data(gamma_data),
        .beta_data(beta_data),
        .result_valid(result_valid),
        .result_ready(result_ready),
        .result_index(result_index),
        .result_data(result_data),
        .debug_mean(debug_mean),
        .debug_variance(debug_variance),
        .debug_inv_std(debug_inv_std)
    );

    vit_fp32_recip_u32_comb reciprocal_leaf_under_test (
        .value  (reciprocal_test_input),
        .result (reciprocal_test_output)
    );

    task automatic check_reciprocal(
        input logic [31:0] value,
        input logic [31:0] expected
    );
        begin
            reciprocal_test_input = value;
            #1;
            if (reciprocal_test_output != expected)
                $fatal(
                    1,
                    "reciprocal conversion failed value=%0d got=%08x expected=%08x",
                    value,
                    reciprocal_test_output,
                    expected
                );
        end
    endtask

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        start = 1'b0;
        result_ready = 1'b1;
        cfg_token_count = 32'd1;
        cfg_hidden_size = 32'd4;
        cfg_epsilon = 32'h3727_c5ac;
        reciprocal_test_input = 32'd0;
        input_words[0] = 32'h3f80_0000;
        input_words[1] = 32'h4000_0000;
        input_words[2] = 32'h4040_0000;
        input_words[3] = 32'h4080_0000;

        check_reciprocal(32'd1,    32'h3f80_0000);
        check_reciprocal(32'd3,    32'h3eaa_aaab);
        check_reciprocal(32'd768,  32'h3aaa_aaab);
        check_reciprocal(32'd3072, 32'h39aa_aaab);

        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        cycle_count = 0;
        while (!done_seen && (cycle_count < 200)) begin
            @(posedge clk);
            cycle_count = cycle_count + 1;
        end
        @(negedge clk);

        if (!done_seen)
            $fatal(
                1,
                "LayerNorm timeout state=%0d token=%0d channel=%0d data_request=%b input_valid=%b",
                dut.state,
                dut.token_index,
                dut.channel_index,
                data_request,
                input_valid
            );
        if (config_error)
            $fatal(1, "Unexpected config_error");
        if (result_count != 4)
            $fatal(1, "Expected 4 results, got %0d", result_count);
        if (debug_mean != 32'h4020_0000)
            $fatal(1, "Mean mismatch: %08x", debug_mean);
        if (debug_variance != 32'h3fa0_0000)
            $fatal(1, "Variance mismatch: %08x", debug_variance);
        if (debug_inv_std != 32'h3f64_f8f3)
            $fatal(1, "Inverse standard deviation mismatch: %08x", debug_inv_std);
        if ((observed[0] != 32'hbfab_bab6) ||
            (observed[1] != 32'hbee4_f8f3) ||
            (observed[2] != 32'h3ee4_f8f3) ||
            (observed[3] != 32'h3fab_bab6))
            $fatal(
                1,
                "Output mismatch: %08x,%08x,%08x,%08x",
                observed[0],
                observed[1],
                observed[2],
                observed[3]
            );

        $display(
            "PASS LayerNorm mean=%08x variance=%08x inv_std=%08x outputs=%08x,%08x,%08x,%08x cycles=%0d",
            debug_mean,
            debug_variance,
            debug_inv_std,
            observed[0],
            observed[1],
            observed[2],
            observed[3],
            cycle_count
        );
        $finish;
    end

endmodule
