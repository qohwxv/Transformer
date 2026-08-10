`timescale 1ns/1ps

module tb_vit_fp32_gelu_serial;

    localparam integer RANDOM_CASES = 2000;
    localparam integer TIMEOUT_CYCLES = 100;

    logic clk;
    logic rst;
    logic start;
    logic [31:0] input_value;
    logic busy;
    logic done;
    logic [31:0] serial_result;
    logic [31:0] reference_result;
    logic [31:0] expected_result;
    integer check_count;
    integer cycle_count;
    integer random_index;

    always #5 clk = ~clk;

    vit_fp32_gelu_comb u_reference (
        .value  (input_value),
        .result (reference_result)
    );

    vit_fp32_gelu_serial dut (
        .clk    (clk),
        .rst    (rst),
        .start  (start),
        .value  (input_value),
        .busy   (busy),
        .done   (done),
        .result (serial_result)
    );

    task automatic check_value(input logic [31:0] test_value);
        begin
            while (busy)
                @(posedge clk);

            @(negedge clk);
            input_value = test_value;
            #1;
            expected_result = reference_result;
            start = 1'b1;

            @(posedge clk);
            #1;
            start = 1'b0;
            input_value = 32'h7fc0_bad0;

            cycle_count = 0;
            while (!done && (cycle_count < TIMEOUT_CYCLES)) begin
                @(posedge clk);
                #1;
                cycle_count = cycle_count + 1;
            end

            if (!done)
                $fatal(
                    1,
                    "Serial GELU timeout for input %08x",
                    test_value
                );
            if (serial_result !== expected_result)
                $fatal(
                    1,
                    "Serial GELU mismatch input=%08x got=%08x expected=%08x",
                    test_value,
                    serial_result,
                    expected_result
                );

            check_count = check_count + 1;
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        start = 1'b0;
        input_value = 32'd0;
        check_count = 0;

        repeat (4) @(posedge clk);
        rst = 1'b0;

        check_value(32'h0000_0000);
        check_value(32'h8000_0000);
        check_value(32'h7f80_0000);
        check_value(32'hff80_0000);
        check_value(32'h7fc1_2345);
        check_value(32'hffc1_2345);
        check_value(32'h0000_0001);
        check_value(32'h8000_0001);
        check_value(32'h0080_0000);
        check_value(32'h8080_0000);
        check_value(32'h3f00_0000);
        check_value(32'hbf00_0000);
        check_value(32'h3f80_0000);
        check_value(32'hbf80_0000);
        check_value(32'h4040_0000);
        check_value(32'hc040_0000);
        check_value(32'h7f7f_ffff);
        check_value(32'hff7f_ffff);

        for (random_index = 0;
             random_index < RANDOM_CASES;
             random_index = random_index + 1)
            check_value($urandom);

        $display(
            "GELU_SERIAL_EQUIVALENCE_PASS checks=%0d",
            check_count
        );
        $finish;
    end

endmodule
