`timescale 1ns/1ps

module tb_vit_gelu_engine_fp32;

    localparam integer LANES = 4;
    localparam integer LENGTH = 12;

    logic clk;
    logic rst;
    logic start;
    logic busy;
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
                    if (result_lane_mask[capture_lane]) begin
                        observed[result_base_index + capture_lane] <=
                            result_data[capture_lane*32 +: 32];
                    end
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
        .busy(busy),
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
        clk = 1'b0;
        rst = 1'b1;
        start = 1'b0;
        result_ready = 1'b1;

        input_words[0]  = 32'hff80_0000;
        input_words[1]  = 32'hc040_0000;
        input_words[2]  = 32'hbf80_0000;
        input_words[3]  = 32'h8000_0000;
        input_words[4]  = 32'h0000_0000;
        input_words[5]  = 32'h3f00_0000;
        input_words[6]  = 32'h3f80_0000;
        input_words[7]  = 32'h4040_0000;
        input_words[8]  = 32'h7f80_0000;
        input_words[9]  = 32'h7fc1_2345;
        input_words[10] = 32'hc0c0_0000;
        input_words[11] = 32'h40c0_0000;

        repeat (4) @(posedge clk);
        rst <= 1'b0;
        @(posedge clk);
        start <= 1'b1;
        @(posedge clk);
        start <= 1'b0;

        cycle_count = 0;
        while (!done_seen && (cycle_count < 2000)) begin
            @(posedge clk);
            cycle_count = cycle_count + 1;
        end
        @(negedge clk);

        if (!done_seen)
            $fatal(1, "GELU timeout");
        if (config_error)
            $fatal(1, "Unexpected config_error");
        if (result_count != LENGTH)
            $fatal(1, "Expected %0d results, got %0d", LENGTH, result_count);
        if (observed[0] != 32'h7fc0_0000)
            $fatal(1, "GELU(-Inf) mismatch: %08x", observed[0]);
        if (observed[3] != 32'h0000_0000)
            $fatal(1, "GELU(-0) mismatch: %08x", observed[3]);
        if (observed[4] != 32'h0000_0000)
            $fatal(1, "GELU(+0) mismatch: %08x", observed[4]);
        if (observed[8] != 32'h7f80_0000)
            $fatal(1, "GELU(+Inf) mismatch: %08x", observed[8]);
        if (observed[9] != 32'h7fc0_0000)
            $fatal(1, "GELU(NaN) mismatch: %08x", observed[9]);

        $display(
            "PASS GELU outputs[-3,-1,0.5,1,3]=%08x,%08x,%08x,%08x,%08x cycles=%0d",
            observed[1],
            observed[2],
            observed[5],
            observed[6],
            observed[7],
            cycle_count
        );
        $finish;
    end

endmodule
