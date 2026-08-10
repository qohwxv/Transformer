`timescale 1ns/1ps

module tb_vit_gemm_bias_cache;

    localparam integer DEPTH = 23;

    logic clk;
    logic rst;
    logic clear;
    logic write_enable;
    logic [31:0] write_index;
    logic [31:0] write_data;
    logic read_enable;
    logic [31:0] read_index;
    logic read_data_valid;
    logic [31:0] read_data;
    logic [31:0] reference_memory [0:DEPTH-1];
    integer checks;
    integer index;

    always #5 clk = ~clk;

    vit_gemm_bias_cache #(
        .DEPTH_WORDS(DEPTH)
    ) dut (
        .clk            (clk),
        .rst            (rst),
        .clear          (clear),
        .write_enable   (write_enable),
        .write_index    (write_index),
        .write_data     (write_data),
        .read_enable    (read_enable),
        .read_index     (read_index),
        .read_data_valid(read_data_valid),
        .read_data      (read_data)
    );

    task automatic write_word(
        input integer word_index,
        input logic [31:0] value
    );
        begin
            @(negedge clk);
            write_enable = 1'b1;
            write_index = word_index;
            write_data = value;
            @(negedge clk);
            write_enable = 1'b0;
            reference_memory[word_index] = value;
        end
    endtask

    task automatic read_and_check(input integer word_index);
        begin
            @(negedge clk);
            read_enable = 1'b1;
            read_index = word_index;
            @(negedge clk);
            read_enable = 1'b0;

            if (!read_data_valid)
                $fatal(1, "bias cache read_data_valid missing");
            if (read_data !== reference_memory[word_index])
                $fatal(
                    1,
                    "bias cache mismatch index=%0d got=%08x expected=%08x",
                    word_index,
                    read_data,
                    reference_memory[word_index]
                );
            checks = checks + 2;

            @(negedge clk);
            if (read_data_valid)
                $fatal(1, "bias cache read_data_valid was not a pulse");
            checks = checks + 1;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        clear = 1'b0;
        write_enable = 1'b0;
        write_index = 32'd0;
        write_data = 32'd0;
        read_enable = 1'b0;
        read_index = 32'd0;
        checks = 0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        for (index = 0; index < DEPTH; index = index + 1)
            write_word(
                index,
                32'h6200_0000 ^ (32'(index) * 32'h0001_0101)
            );

        for (index = DEPTH - 1; index >= 0; index = index - 1)
            read_and_check(index);

        @(negedge clk);
        read_enable = 1'b1;
        read_index = 32'd7;
        clear = 1'b1;
        @(negedge clk);
        read_enable = 1'b0;
        clear = 1'b0;
        if (read_data_valid)
            $fatal(1, "bias cache clear did not cancel read pulse");
        checks = checks + 1;

        read_and_check(7);

        $display(
            "PASS GEMM bias cache: checks=%0d words=%0d",
            checks,
            DEPTH
        );
        $finish;
    end

    initial begin
        repeat (3000) @(posedge clk);
        $fatal(1, "Timeout in tb_vit_gemm_bias_cache");
    end

endmodule
