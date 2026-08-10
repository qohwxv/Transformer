`timescale 1ns/1ps

module tb_vit_layernorm_engine_fp32_real;

    localparam integer HIDDEN_SIZE = 768;

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
    logic [31:0] gamma_data;
    logic [31:0] beta_data;
    logic result_valid;
    logic result_ready;
    logic [31:0] result_index;
    logic [31:0] result_data;
    logic [31:0] debug_mean;
    logic [31:0] debug_variance;
    logic [31:0] debug_inv_std;

    logic [31:0] input_words [0:HIDDEN_SIZE-1];
    logic [31:0] gamma_words [0:HIDDEN_SIZE-1];
    logic [31:0] beta_words [0:HIDDEN_SIZE-1];
    logic [31:0] observed [0:HIDDEN_SIZE-1];

    string input_hex;
    string gamma_hex;
    string beta_hex;
    string output_hex;
    integer result_count;
    integer cycle_count;

    always #5 clk = ~clk;

    always_comb begin
        input_valid = data_request;
        input_data = input_words[data_index];
        gamma_data = gamma_words[data_index];
        beta_data = beta_words[data_index];
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

    vit_layernorm_engine_fp32 dut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .cfg_token_count(32'd1),
        .cfg_hidden_size(HIDDEN_SIZE),
        .cfg_epsilon(32'h2b8c_bccc),
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

    initial begin
        if (!$value$plusargs("INPUT_HEX=%s", input_hex))
            $fatal(1, "Missing +INPUT_HEX");
        if (!$value$plusargs("GAMMA_HEX=%s", gamma_hex))
            $fatal(1, "Missing +GAMMA_HEX");
        if (!$value$plusargs("BETA_HEX=%s", beta_hex))
            $fatal(1, "Missing +BETA_HEX");
        if (!$value$plusargs("OUTPUT_HEX=%s", output_hex))
            $fatal(1, "Missing +OUTPUT_HEX");

        $readmemh(input_hex, input_words);
        $readmemh(gamma_hex, gamma_words);
        $readmemh(beta_hex, beta_words);

        clk = 1'b0;
        rst = 1'b1;
        start = 1'b0;
        result_ready = 1'b1;

        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        cycle_count = 0;
        while (!done_seen && (cycle_count < 5000)) begin
            @(posedge clk);
            cycle_count = cycle_count + 1;
        end
        @(negedge clk);

        if (!done_seen)
            $fatal(1, "Real-data LayerNorm timeout");
        if (config_error)
            $fatal(1, "Unexpected config_error");
        if (result_count != HIDDEN_SIZE)
            $fatal(1, "Expected %0d results, got %0d", HIDDEN_SIZE, result_count);

        $writememh(output_hex, observed);
        $display(
            "PASS real-data LayerNorm mean=%08x variance=%08x inv_std=%08x outputs=%0d cycles=%0d",
            debug_mean,
            debug_variance,
            debug_inv_std,
            result_count,
            cycle_count
        );
        $finish;
    end

endmodule
