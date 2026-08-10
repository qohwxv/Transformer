`timescale 1ns/1ps

module tb_vit_softmax_engine_fp32_real #(
    parameter integer ENABLE_ROW_EXP_BUFFER = 1
);

    localparam integer LENGTH = 1000;

    logic clk;
    logic rst;
    logic start;
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

    logic [31:0] input_words [0:LENGTH-1];
    logic [31:0] observed [0:LENGTH-1];
    string input_hex;
    string output_hex;
    integer result_count;
    integer cycle_count;
    integer read_max_count;
    integer read_sum_count;
    integer read_output_count;

    always #5 clk = ~clk;

    always_comb begin
        input_valid = data_request;
        input_data = input_words[data_index];
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            done_seen <= 1'b0;
            result_count <= 0;
            read_max_count <= 0;
            read_sum_count <= 0;
            read_output_count <= 0;
        end else begin
            if (done)
                done_seen <= 1'b1;
            if (input_valid) begin
                case (data_pass)
                    2'd0: read_max_count <= read_max_count + 1;
                    2'd1: read_sum_count <= read_sum_count + 1;
                    2'd2: read_output_count <= read_output_count + 1;
                    default: $fatal(1, "Invalid data_pass=%0d", data_pass);
                endcase
            end
            if (result_valid && result_ready) begin
                observed[result_index] <= result_data;
                result_count <= result_count + 1;
            end
        end
    end

    vit_softmax_engine_fp32 #(
        .ENABLE_ROW_EXP_BUFFER(ENABLE_ROW_EXP_BUFFER)
    ) dut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .cfg_row_count(32'd1),
        .cfg_row_length(LENGTH),
        .busy(),
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
        if (!$value$plusargs("INPUT_HEX=%s", input_hex))
            $fatal(1, "Missing +INPUT_HEX");
        if (!$value$plusargs("OUTPUT_HEX=%s", output_hex))
            $fatal(1, "Missing +OUTPUT_HEX");
        $readmemh(input_hex, input_words);

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
        while (!done_seen && (cycle_count < 100000)) begin
            @(posedge clk);
            cycle_count = cycle_count + 1;
        end
        @(negedge clk);

        if (!done_seen)
            $fatal(1, "Real-data Softmax timeout");
        if (config_error)
            $fatal(1, "Unexpected config_error");
        if (result_count != LENGTH)
            $fatal(1, "Expected %0d results, got %0d", LENGTH, result_count);
        if (ENABLE_ROW_EXP_BUFFER != 0) begin
            if ((read_max_count != LENGTH) ||
                (read_sum_count != 0) ||
                (read_output_count != 0))
                $fatal(
                    1,
                    "Buffered real-data read counts=%0d/%0d/%0d expected=%0d/0/0",
                    read_max_count,
                    read_sum_count,
                    read_output_count,
                    LENGTH
                );
        end else begin
            if ((read_max_count != LENGTH) ||
                (read_sum_count != LENGTH) ||
                (read_output_count != LENGTH))
                $fatal(
                    1,
                    "Legacy real-data read counts=%0d/%0d/%0d expected=%0d/%0d/%0d",
                    read_max_count,
                    read_sum_count,
                    read_output_count,
                    LENGTH,
                    LENGTH,
                    LENGTH
                );
        end

        $writememh(output_hex, observed);
        $display(
            "PASS real-data Softmax buffer=%0d max=%08x exp_sum=%08x outputs=%0d cycles=%0d reads=%0d/%0d/%0d",
            ENABLE_ROW_EXP_BUFFER,
            debug_row_max,
            debug_exp_sum,
            result_count,
            cycle_count,
            read_max_count,
            read_sum_count,
            read_output_count
        );
        $finish;
    end

endmodule
