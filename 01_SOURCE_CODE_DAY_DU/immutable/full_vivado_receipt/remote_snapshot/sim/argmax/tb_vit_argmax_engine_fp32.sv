`timescale 1ns/1ps

module tb_vit_argmax_engine_fp32;

    logic clk;
    logic rst;
    logic start;
    logic [31:0] cfg_length;
    logic busy;
    logic done;
    logic config_error;
    logic input_nonfinite_error;
    logic data_request;
    logic data_valid;
    logic [31:0] element_index;
    logic [31:0] input_data;
    logic result_valid;
    logic result_ready;
    logic [31:0] result_index;
    logic [31:0] result_value;

    logic [31:0] samples [0:7];

    vit_argmax_engine_fp32 u_dut (
        .clk                  (clk),
        .rst                  (rst),
        .start                (start),
        .cfg_length           (cfg_length),
        .busy                 (busy),
        .done                 (done),
        .config_error         (config_error),
        .input_nonfinite_error(input_nonfinite_error),
        .data_request         (data_request),
        .data_valid           (data_valid),
        .element_index        (element_index),
        .input_data           (input_data),
        .result_valid         (result_valid),
        .result_ready         (result_ready),
        .result_index         (result_index),
        .result_value         (result_value)
    );

    assign data_valid = data_request;
    assign input_data = samples[element_index[2:0]];

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    task automatic pulse_start(input logic [31:0] length);
        begin
            @(negedge clk);
            cfg_length = length;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    task automatic wait_for_result;
        integer timeout;
        begin
            timeout = 0;
            while (!result_valid && (timeout < 100)) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (!result_valid)
                $fatal(1, "argmax result timeout");
        end
    endtask

    initial begin
        rst = 1'b1;
        start = 1'b0;
        cfg_length = 32'd0;
        result_ready = 1'b0;

        // -2, +3, +3 (tie), NaN, -0, +0, +2, -Inf.
        samples[0] = 32'hc000_0000;
        samples[1] = 32'h4040_0000;
        samples[2] = 32'h4040_0000;
        samples[3] = 32'h7fc0_0001;
        samples[4] = 32'h8000_0000;
        samples[5] = 32'h0000_0000;
        samples[6] = 32'h4000_0000;
        samples[7] = 32'hff80_0000;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        pulse_start(32'd8);
        wait_for_result();
        repeat (3) @(posedge clk);
        if (!result_valid)
            $fatal(1, "result did not hold under backpressure");
        if ((result_index !== 32'd1) ||
            (result_value !== 32'h4040_0000))
            $fatal(
                1,
                "argmax mismatch index=%0d value=%08x",
                result_index,
                result_value
            );
        if (!input_nonfinite_error)
            $fatal(1, "non-finite input error was not sticky");

        @(negedge clk);
        result_ready = 1'b1;
        while (!done)
            @(posedge clk);
        @(negedge clk);
        result_ready = 1'b0;

        pulse_start(32'd0);
        while (!done)
            @(posedge clk);
        if (!config_error)
            $fatal(1, "zero-length configuration was accepted");

        $display("ARGMAX_ENGINE_PASS");
        $finish;
    end

endmodule
