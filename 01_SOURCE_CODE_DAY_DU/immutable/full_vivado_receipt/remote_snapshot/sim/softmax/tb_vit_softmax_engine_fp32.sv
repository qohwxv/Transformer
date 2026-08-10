`timescale 1ns/1ps

module tb_vit_softmax_engine_fp32;

    import vit_fp32_pkg::*;

    logic clk;
    logic rst;
    logic start;
    logic busy;
    logic done;
    logic done_seen;
    logic config_error;
    logic data_request;
    logic input_valid;
    logic [1:0] data_pass;
    logic [31:0] data_index;
    logic [31:0] input_data;
    logic result_valid;
    logic result_ready;
    logic [31:0] result_index;
    logic [31:0] result_data;
    logic [31:0] debug_row_max;
    logic [31:0] debug_exp_sum;

    logic [31:0] input_words [0:7];
    logic [31:0] observed [0:7];
    logic [31:0] expected [0:7];
    logic [31:0] row_sum;
    integer result_count;
    integer cycle_count;
    integer check_index;
    integer difference;

    always #5 clk = ~clk;

    always_comb begin
        input_valid = data_request;
        input_data = input_words[data_index];
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            done_seen <= 1'b0;
            result_count <= 0;
        end else begin
            if (done)
                done_seen <= 1'b1;
            if (result_valid && result_ready) begin
                observed[result_index] <= result_data;
                result_count <= result_count + 1;
            end
        end
    end

    vit_softmax_engine_fp32 dut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .cfg_row_count(32'd2),
        .cfg_row_length(32'd4),
        .busy(busy),
        .done(done),
        .config_error(config_error),
        .data_request(data_request),
        .input_valid(input_valid),
        .data_pass(data_pass),
        .data_index(data_index),
        .input_data(input_data),
        .result_valid(result_valid),
        .result_ready(result_ready),
        .result_index(result_index),
        .result_data(result_data),
        .debug_row_max(debug_row_max),
        .debug_exp_sum(debug_exp_sum)
    );

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        start = 1'b0;
        result_ready = 1'b1;

        input_words[0] = 32'h3f80_0000;
        input_words[1] = 32'h4000_0000;
        input_words[2] = 32'h4040_0000;
        input_words[3] = 32'h4080_0000;
        input_words[4] = 32'h0000_0000;
        input_words[5] = 32'h0000_0000;
        input_words[6] = 32'h0000_0000;
        input_words[7] = 32'h0000_0000;

        expected[0] = 32'h3d03_4fe2;
        expected[1] = 32'h3db2_78b8;
        expected[2] = 32'h3e72_9169;
        expected[3] = 32'h3f24_d791;
        expected[4] = 32'h3e80_0000;
        expected[5] = 32'h3e80_0000;
        expected[6] = 32'h3e80_0000;
        expected[7] = 32'h3e80_0000;

        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        cycle_count = 0;
        while (!done_seen && (cycle_count < 1000)) begin
            @(posedge clk);
            cycle_count = cycle_count + 1;
        end
        @(negedge clk);

        if (!done_seen)
            $fatal(1, "Softmax timeout");
        if (config_error)
            $fatal(1, "Unexpected config_error");
        if (result_count != 8)
            $fatal(1, "Expected 8 results, got %0d", result_count);

        for (check_index = 0; check_index < 8; check_index = check_index + 1) begin
            difference = (observed[check_index] >= expected[check_index]) ?
                         (observed[check_index] - expected[check_index]) :
                         (expected[check_index] - observed[check_index]);
            if (difference > 32)
                $fatal(
                    1,
                    "Softmax output[%0d] mismatch got=%08x expected=%08x ulp=%0d",
                    check_index,
                    observed[check_index],
                    expected[check_index],
                    difference
                );
        end

        row_sum = FP32_SYNTH_POS_ZERO;
        for (check_index = 0; check_index < 4; check_index = check_index + 1)
            row_sum = fp32_add(row_sum, observed[check_index]);
        difference = (row_sum >= FP32_SYNTH_ONE) ?
                     (row_sum - FP32_SYNTH_ONE) :
                     (FP32_SYNTH_ONE - row_sum);
        if (difference > 16)
            $fatal(1, "Softmax row sum mismatch: %08x", row_sum);

        $display(
            "PASS Softmax outputs=%08x,%08x,%08x,%08x row_sum=%08x cycles=%0d",
            observed[0],
            observed[1],
            observed[2],
            observed[3],
            row_sum,
            cycle_count
        );
        $finish;
    end

endmodule
