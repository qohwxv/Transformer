`timescale 1ns/1ps

// M4 capacity/banking gate for the production activation and bias RAM leaves.
//
// The test is compiled twice (ARRAY_ROWS=4 and ARRAY_ROWS=8).  It targets the
// exact production depth, checks that every row bank has independent words at
// K=0 and K=3071, and verifies the documented clear/read-valid contract.
module tb_m4_cache_capacity #(
    parameter integer ARRAY_ROWS = 4
);

    localparam integer DEPTH = 3072;
    localparam integer ROW_WIDTH =
        (ARRAY_ROWS <= 1) ? 1 : $clog2(ARRAY_ROWS);

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic clear = 1'b0;

    logic a_write_enable = 1'b0;
    logic [ROW_WIDTH-1:0] a_write_row = '0;
    logic [31:0] a_write_k_index = 32'd0;
    logic [31:0] a_write_data = 32'd0;
    logic a_read_enable = 1'b0;
    logic [ROW_WIDTH-1:0] a_read_row = '0;
    logic [31:0] a_read_k_index = 32'd0;
    logic a_read_data_valid;
    logic [31:0] a_read_data;

    logic bias_write_enable = 1'b0;
    logic [31:0] bias_write_index = 32'd0;
    logic [31:0] bias_write_data = 32'd0;
    logic bias_read_enable = 1'b0;
    logic [31:0] bias_read_index = 32'd0;
    logic bias_read_data_valid;
    logic [31:0] bias_read_data;

    integer checks = 0;
    integer row_index;

    always #5 clk = ~clk;

    vit_gemm_activation_panel_cache #(
        .ARRAY_ROWS(ARRAY_ROWS),
        .DEPTH_WORDS_PER_ROW(DEPTH)
    ) u_activation_cache (
        .clk(clk),
        .rst(rst),
        .clear(clear),
        .write_enable(a_write_enable),
        .write_row(a_write_row),
        .write_k_index(a_write_k_index),
        .write_data(a_write_data),
        .read_enable(a_read_enable),
        .read_row(a_read_row),
        .read_k_index(a_read_k_index),
        .read_data_valid(a_read_data_valid),
        .read_data(a_read_data),
        .vector_read_enable(1'b0),
        .vector_read_k_index(32'd0),
        .vector_read_data_valid(),
        .vector_read_data()
    );

    vit_gemm_bias_cache #(
        .DEPTH_WORDS(DEPTH)
    ) u_bias_cache (
        .clk(clk),
        .rst(rst),
        .clear(clear),
        .write_enable(bias_write_enable),
        .write_index(bias_write_index),
        .write_data(bias_write_data),
        .read_enable(bias_read_enable),
        .read_index(bias_read_index),
        .read_data_valid(bias_read_data_valid),
        .read_data(bias_read_data)
    );

    function automatic logic [31:0] activation_pattern(
        input integer row_value,
        input integer k_value
    );
        begin
            activation_pattern =
                32'ha400_0000 ^
                (32'(row_value) << 20) ^
                (32'(k_value) * 32'h0001_0101);
        end
    endfunction

    function automatic logic [31:0] bias_pattern(input integer k_value);
        begin
            bias_pattern =
                32'hb150_0000 ^ (32'(k_value) * 32'h0001_0201);
        end
    endfunction

    task automatic check_true(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1)
                $fatal(1, "M4 cache capacity check failed: %s", message);
        end
    endtask

    task automatic write_activation(
        input integer row_value,
        input integer k_value,
        input logic [31:0] value
    );
        begin
            @(negedge clk);
            a_write_enable = 1'b1;
            a_write_row = ROW_WIDTH'(row_value);
            a_write_k_index = 32'(k_value);
            a_write_data = value;
            @(negedge clk);
            a_write_enable = 1'b0;
        end
    endtask

    task automatic read_activation_and_check(
        input integer row_value,
        input integer k_value,
        input logic [31:0] expected
    );
        begin
            @(negedge clk);
            a_read_enable = 1'b1;
            a_read_row = ROW_WIDTH'(row_value);
            a_read_k_index = 32'(k_value);
            @(posedge clk);
            #1;
            check_true(a_read_data_valid, "activation read valid missing");
            check_true(
                a_read_data === expected,
                $sformatf(
                    "activation row=%0d k=%0d got=%08x expected=%08x",
                    row_value,
                    k_value,
                    a_read_data,
                    expected
                )
            );
            @(negedge clk);
            a_read_enable = 1'b0;
            @(posedge clk);
            #1;
            check_true(!a_read_data_valid, "activation valid was not a pulse");
        end
    endtask

    task automatic write_bias(
        input integer k_value,
        input logic [31:0] value
    );
        begin
            @(negedge clk);
            bias_write_enable = 1'b1;
            bias_write_index = 32'(k_value);
            bias_write_data = value;
            @(negedge clk);
            bias_write_enable = 1'b0;
        end
    endtask

    task automatic read_bias_and_check(
        input integer k_value,
        input logic [31:0] expected
    );
        begin
            @(negedge clk);
            bias_read_enable = 1'b1;
            bias_read_index = 32'(k_value);
            @(posedge clk);
            #1;
            check_true(bias_read_data_valid, "bias read valid missing");
            check_true(
                bias_read_data === expected,
                $sformatf(
                    "bias k=%0d got=%08x expected=%08x",
                    k_value,
                    bias_read_data,
                    expected
                )
            );
            @(negedge clk);
            bias_read_enable = 1'b0;
            @(posedge clk);
            #1;
            check_true(!bias_read_data_valid, "bias valid was not a pulse");
        end
    endtask

    initial begin
        if ((ARRAY_ROWS != 4) && (ARRAY_ROWS != 8))
            $fatal(1, "M4 cache test supports only ARRAY_ROWS=4 or 8");

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // Two far-apart locations per bank expose row-bank or address aliases.
        for (row_index = 0; row_index < ARRAY_ROWS;
             row_index = row_index + 1) begin
            write_activation(
                row_index,
                0,
                activation_pattern(row_index, 0)
            );
            write_activation(
                row_index,
                DEPTH - 1,
                activation_pattern(row_index, DEPTH - 1)
            );
        end

        // Reverse-order reads make accidental sharing between adjacent banks
        // visible, including the maximum R4/R8 bank.
        for (row_index = ARRAY_ROWS - 1; row_index >= 0;
             row_index = row_index - 1) begin
            read_activation_and_check(
                row_index,
                DEPTH - 1,
                activation_pattern(row_index, DEPTH - 1)
            );
            read_activation_and_check(
                row_index,
                0,
                activation_pattern(row_index, 0)
            );
        end

        write_bias(0, bias_pattern(0));
        write_bias(DEPTH - 1, bias_pattern(DEPTH - 1));
        read_bias_and_check(DEPTH - 1, bias_pattern(DEPTH - 1));
        read_bias_and_check(0, bias_pattern(0));

        // Clear cancels both in-flight valid pulses.  RAM contents are not
        // required to clear; the frontend owns cache tags/validity.
        @(negedge clk);
        a_read_enable = 1'b1;
        a_read_row = ROW_WIDTH'(ARRAY_ROWS - 1);
        a_read_k_index = DEPTH - 1;
        bias_read_enable = 1'b1;
        bias_read_index = DEPTH - 1;
        clear = 1'b1;
        @(posedge clk);
        #1;
        check_true(!a_read_data_valid, "clear did not cancel activation valid");
        check_true(!bias_read_data_valid, "clear did not cancel bias valid");
        @(negedge clk);
        clear = 1'b0;
        a_read_enable = 1'b0;
        bias_read_enable = 1'b0;

        read_activation_and_check(
            ARRAY_ROWS - 1,
            DEPTH - 1,
            activation_pattern(ARRAY_ROWS - 1, DEPTH - 1)
        );
        read_bias_and_check(DEPTH - 1, bias_pattern(DEPTH - 1));

        $display(
            {
                "PASS M4 cache capacity: R=%0d checks=%0d ",
                "activation_words=%0d bias_words=%0d max_k=3071"
            },
            ARRAY_ROWS,
            checks,
            ARRAY_ROWS * DEPTH,
            DEPTH
        );
        $finish;
    end

    initial begin
        repeat (2000) @(posedge clk);
        $fatal(1, "Timeout in tb_m4_cache_capacity R=%0d", ARRAY_ROWS);
    end

endmodule
