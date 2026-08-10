`timescale 1ns/1ps

module tb_vit_gemm_activation_panel_cache;

    localparam integer ARRAY_ROWS = 2;
    localparam integer DEPTH = 19;

    logic clk;
    logic rst;
    logic clear;
    logic write_enable;
    logic write_row;
    logic [31:0] write_k_index;
    logic [31:0] write_data;
    logic read_enable;
    logic read_row;
    logic [31:0] read_k_index;
    logic read_data_valid;
    logic [31:0] read_data;
    logic vector_read_enable;
    logic [31:0] vector_read_k_index;
    logic vector_read_data_valid;
    logic [ARRAY_ROWS*32-1:0] vector_read_data;

    logic [31:0] reference_memory [0:ARRAY_ROWS-1][0:DEPTH-1];
    integer checks;
    integer row_index;
    integer k_index;
    integer random_index;

    always #5 clk = ~clk;

    vit_gemm_activation_panel_cache #(
        .ARRAY_ROWS         (ARRAY_ROWS),
        .DEPTH_WORDS_PER_ROW(DEPTH)
    ) dut (
        .clk            (clk),
        .rst            (rst),
        .clear          (clear),
        .write_enable   (write_enable),
        .write_row      (write_row),
        .write_k_index  (write_k_index),
        .write_data     (write_data),
        .read_enable    (read_enable),
        .read_row       (read_row),
        .read_k_index   (read_k_index),
        .read_data_valid(read_data_valid),
        .read_data      (read_data),
        .vector_read_enable   (vector_read_enable),
        .vector_read_k_index  (vector_read_k_index),
        .vector_read_data_valid(vector_read_data_valid),
        .vector_read_data     (vector_read_data)
    );

    function automatic logic [31:0] pattern(
        input integer row_value,
        input integer k_value
    );
        pattern =
            32'h5100_0000 ^
            (32'(row_value) << 20) ^
            (32'(k_value) * 32'h0001_0201);
    endfunction

    task automatic write_word(
        input integer row_value,
        input integer k_value,
        input logic [31:0] value
    );
        begin
            @(negedge clk);
            write_enable = 1'b1;
            write_row = row_value[0];
            write_k_index = k_value;
            write_data = value;
            @(negedge clk);
            write_enable = 1'b0;
            reference_memory[row_value][k_value] = value;
        end
    endtask

    task automatic vector_read_and_check(input integer k_value);
        integer vector_row;
        begin
            @(negedge clk);
            vector_read_enable = 1'b1;
            vector_read_k_index = k_value;

            @(negedge clk);
            vector_read_enable = 1'b0;
            if (!vector_read_data_valid)
                $fatal(1, "cache vector_read_data_valid missing");
            if (read_data_valid)
                $fatal(1, "scalar valid asserted for vector request");
            checks = checks + 2;
            for (vector_row = 0; vector_row < ARRAY_ROWS;
                 vector_row = vector_row + 1) begin
                if (vector_read_data[vector_row*32 +: 32] !==
                    reference_memory[vector_row][k_value])
                    $fatal(
                        1,
                        "cache vector mismatch row=%0d k=%0d got=%08x expected=%08x",
                        vector_row,
                        k_value,
                        vector_read_data[vector_row*32 +: 32],
                        reference_memory[vector_row][k_value]
                    );
                checks = checks + 1;
            end

            @(negedge clk);
            if (vector_read_data_valid)
                $fatal(1, "cache vector_read_data_valid was not a pulse");
            checks = checks + 1;
        end
    endtask

    task automatic read_and_check(
        input integer row_value,
        input integer k_value
    );
        begin
            @(negedge clk);
            read_enable = 1'b1;
            read_row = row_value[0];
            read_k_index = k_value;

            @(negedge clk);
            read_enable = 1'b0;
            if (!read_data_valid)
                $fatal(1, "cache read_data_valid missing");
            if (read_data !== reference_memory[row_value][k_value])
                $fatal(
                    1,
                    "cache mismatch row=%0d k=%0d got=%08x expected=%08x",
                    row_value,
                    k_value,
                    read_data,
                    reference_memory[row_value][k_value]
                );
            checks = checks + 2;

            @(negedge clk);
            if (read_data_valid)
                $fatal(1, "cache read_data_valid was not a pulse");
            checks = checks + 1;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        clear = 1'b0;
        write_enable = 1'b0;
        write_row = 1'b0;
        write_k_index = 32'd0;
        write_data = 32'd0;
        read_enable = 1'b0;
        read_row = 1'b0;
        read_k_index = 32'd0;
        vector_read_enable = 1'b0;
        vector_read_k_index = 32'd0;
        checks = 0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        for (row_index = 0; row_index < ARRAY_ROWS;
             row_index = row_index + 1)
            for (k_index = 0; k_index < DEPTH;
                 k_index = k_index + 1)
                write_word(
                    row_index,
                    k_index,
                    pattern(row_index, k_index)
                );

        for (row_index = 0; row_index < ARRAY_ROWS;
             row_index = row_index + 1)
            for (k_index = 0; k_index < DEPTH;
                 k_index = k_index + 1)
                read_and_check(row_index, k_index);

        for (random_index = 0; random_index < 100;
             random_index = random_index + 1) begin
            row_index = $urandom_range(0, ARRAY_ROWS - 1);
            k_index = $urandom_range(0, DEPTH - 1);
            read_and_check(row_index, k_index);
        end

        for (k_index = 0; k_index < DEPTH; k_index = k_index + 1)
            vector_read_and_check(k_index);

        // clear cancels an in-flight valid pulse but does not require clearing
        // the RAM contents. Tags in the frontend decide whether data is usable.
        @(negedge clk);
        read_enable = 1'b1;
        read_row = 1'b1;
        read_k_index = DEPTH - 1;
        clear = 1'b1;
        @(negedge clk);
        read_enable = 1'b0;
        vector_read_enable = 1'b0;
        clear = 1'b0;
        if (read_data_valid)
            $fatal(1, "clear did not cancel read_data_valid");
        if (vector_read_data_valid)
            $fatal(1, "clear did not cancel vector_read_data_valid");
        checks = checks + 2;

        read_and_check(1, DEPTH - 1);

        $display(
            "PASS GEMM activation panel cache: checks=%0d words=%0d",
            checks,
            ARRAY_ROWS * DEPTH
        );
        $finish;
    end

    initial begin
        repeat (5000) @(posedge clk);
        $fatal(1, "Timeout in tb_vit_gemm_activation_panel_cache");
    end

endmodule
