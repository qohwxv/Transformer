`timescale 1ns/1ps

module tb_vit_gelu_engine_fp32_real;

    localparam integer LANES = 16;
    localparam integer LENGTH = 4096;

    logic clk;
    logic rst;
    logic start;
    logic done;
    logic done_seen;
    logic config_error;
    logic data_request;
    logic input_valid;
    logic [31:0] data_base_index;
    logic [LANES-1:0] data_lane_mask;
    logic [LANES*32-1:0] input_data;
    logic result_valid;
    logic result_ready;
    logic [31:0] result_base_index;
    logic [LANES-1:0] result_lane_mask;
    logic [LANES*32-1:0] result_data;

    logic [31:0] input_words [0:LENGTH-1];
    logic [31:0] observed [0:LENGTH-1];
    string input_hex;
    string output_hex;
    integer result_count;
    integer cycle_count;
    integer drive_lane;
    integer capture_lane;
    integer accepted_lane_count;

    always #5 clk = ~clk;

    always_comb begin
        input_valid = data_request;
        input_data = '0;
        accepted_lane_count = 0;
        for (drive_lane = 0; drive_lane < LANES;
             drive_lane = drive_lane + 1) begin
            if ((data_base_index + drive_lane) < LENGTH)
                input_data[drive_lane*32 +: 32] =
                    input_words[data_base_index + drive_lane];
            if (result_lane_mask[drive_lane])
                accepted_lane_count = accepted_lane_count + 1;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            done_seen <= 1'b0;
            result_count <= 0;
        end else begin
            if (done)
                done_seen <= 1'b1;
            if (result_valid && result_ready) begin
                for (capture_lane = 0; capture_lane < LANES;
                     capture_lane = capture_lane + 1) begin
                    if (result_lane_mask[capture_lane])
                        observed[result_base_index + capture_lane] <=
                            result_data[capture_lane*32 +: 32];
                end
                result_count <= result_count + accepted_lane_count;
            end
        end
    end

    vit_gelu_engine_fp32 #(
        .LANES(LANES)
    ) dut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .cfg_length(LENGTH),
        .busy(),
        .done(done),
        .config_error(config_error),
        .data_request(data_request),
        .input_valid(input_valid),
        .data_base_index(data_base_index),
        .data_lane_mask(data_lane_mask),
        .input_data(input_data),
        .result_valid(result_valid),
        .result_ready(result_ready),
        .result_base_index(result_base_index),
        .result_lane_mask(result_lane_mask),
        .result_data(result_data)
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
        while (!done_seen && (cycle_count < 10000)) begin
            @(posedge clk);
            cycle_count = cycle_count + 1;
        end
        @(negedge clk);

        if (!done_seen)
            $fatal(1, "Real-data GELU timeout");
        if (config_error)
            $fatal(1, "Unexpected config_error");
        if (result_count != LENGTH)
            $fatal(1, "Expected %0d results, got %0d", LENGTH, result_count);

        $writememh(output_hex, observed);
        $display(
            "PASS real-data GELU outputs=%0d cycles=%0d",
            result_count,
            cycle_count
        );
        $finish;
    end

endmodule
