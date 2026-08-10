`timescale 1ns/1ps

// Leaf-level throughput proof for the banked activation cache.  Consecutive
// vector requests must produce consecutive complete-row responses while an
// independent row write is accepted on every cycle at a different address.
module tb_m7_activation_cache_leaf_pipeline;

    localparam integer ARRAY_ROWS = 8;
    localparam integer DEPTH_WORDS_PER_ROW = 32;
    localparam integer ROW_WIDTH = $clog2(ARRAY_ROWS);

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic clear = 1'b0;
    logic write_enable = 1'b0;
    logic [ROW_WIDTH-1:0] write_row = '0;
    logic [31:0] write_k_index = 32'd0;
    logic [31:0] write_data = 32'd0;
    logic read_enable = 1'b0;
    logic [ROW_WIDTH-1:0] read_row = '0;
    logic [31:0] read_k_index = 32'd0;
    logic read_data_valid;
    logic [31:0] read_data;
    logic vector_read_enable = 1'b0;
    logic [31:0] vector_read_k_index = 32'd0;
    logic vector_read_data_valid;
    logic [ARRAY_ROWS*32-1:0] vector_read_data;

    integer checks = 0;
    integer failures = 0;
    integer row_index;
    integer k_index;

    always #5 clk = ~clk;

    function automatic logic [31:0] cache_word(
        input integer row_value,
        input integer k_value
    );
        begin
            cache_word = 32'h7100_0000 |
                ((row_value & 8'hff) << 12) |
                (k_value & 12'hfff);
        end
    endfunction

    vit_gemm_activation_panel_cache #(
        .ARRAY_ROWS(ARRAY_ROWS),
        .DEPTH_WORDS_PER_ROW(DEPTH_WORDS_PER_ROW)
    ) u_cache (
        .clk(clk),
        .rst(rst),
        .clear(clear),
        .write_enable(write_enable),
        .write_row(write_row),
        .write_k_index(write_k_index),
        .write_data(write_data),
        .read_enable(read_enable),
        .read_row(read_row),
        .read_k_index(read_k_index),
        .read_data_valid(read_data_valid),
        .read_data(read_data),
        .vector_read_enable(vector_read_enable),
        .vector_read_k_index(vector_read_k_index),
        .vector_read_data_valid(vector_read_data_valid),
        .vector_read_data(vector_read_data)
    );

    task automatic check_true(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $error("%s", message);
            end
        end
    endtask

    task automatic write_one(
        input integer row_value,
        input integer k_value
    );
        begin
            @(negedge clk);
            write_enable = 1'b1;
            write_row = ROW_WIDTH'(row_value);
            write_k_index = 32'(k_value);
            write_data = cache_word(row_value, k_value);
            @(posedge clk);
            #1;
        end
    endtask

    task automatic check_vector_response(input integer k_value);
        begin
            check_true(vector_read_data_valid,
                       $sformatf("vector K%0d response is valid", k_value));
            check_true(!read_data_valid,
                       $sformatf("vector K%0d suppresses scalar valid", k_value));
            for (row_index = 0; row_index < ARRAY_ROWS;
                 row_index = row_index + 1)
                check_true(
                    vector_read_data[row_index*32 +: 32] ==
                        cache_word(row_index, k_value),
                    $sformatf("vector K%0d row%0d data", k_value, row_index)
                );
        end
    endtask

    task automatic read_scalar_and_check(
        input integer row_value,
        input integer k_value
    );
        begin
            @(negedge clk);
            write_enable = 1'b0;
            vector_read_enable = 1'b0;
            read_enable = 1'b1;
            read_row = ROW_WIDTH'(row_value);
            read_k_index = 32'(k_value);
            @(posedge clk);
            #1;
            check_true(read_data_valid,
                       $sformatf("scalar row%0d K%0d valid",
                                 row_value, k_value));
            check_true(!vector_read_data_valid,
                       "scalar request suppresses vector valid");
            check_true(read_data == cache_word(row_value, k_value),
                       $sformatf("scalar row%0d K%0d data",
                                 row_value, k_value));
            @(negedge clk);
            read_enable = 1'b0;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // Seed four complete K columns with row-unique values.
        for (k_index = 0; k_index < 4; k_index = k_index + 1)
            for (row_index = 0; row_index < ARRAY_ROWS;
                 row_index = row_index + 1)
                write_one(row_index, k_index);
        @(negedge clk);
        write_enable = 1'b0;

        // Four back-to-back vector requests have no response bubble.  In the
        // same cycles, write a different K address in four independent banks.
        for (k_index = 0; k_index < 4; k_index = k_index + 1) begin
            @(negedge clk);
            read_enable = 1'b0;
            vector_read_enable = 1'b1;
            vector_read_k_index = 32'(k_index);
            write_enable = 1'b1;
            write_row = ROW_WIDTH'(k_index);
            write_k_index = 32'(8 + k_index);
            write_data = cache_word(k_index, 8 + k_index);
            @(posedge clk);
            #1;
            check_vector_response(k_index);
        end

        @(negedge clk);
        vector_read_enable = 1'b0;
        write_enable = 1'b0;
        @(posedge clk);
        #1;
        check_true(!vector_read_data_valid,
                   "vector valid deasserts immediately after request stream");

        // Concurrent writes were not dropped by the vector-read stream.
        for (row_index = 0; row_index < 4; row_index = row_index + 1)
            read_scalar_and_check(row_index, 8 + row_index);

        // Clear flushes both response-valid pipelines but does not pretend to
        // erase RAM payload; tags/ownership are maintained by the frontend.
        @(negedge clk);
        read_enable = 1'b0;
        vector_read_enable = 1'b1;
        vector_read_k_index = 32'd2;
        clear = 1'b1;
        @(posedge clk);
        #1;
        check_true(!read_data_valid && !vector_read_data_valid,
                   "clear flushes scalar and vector response valids");
        @(negedge clk);
        clear = 1'b0;
        vector_read_enable = 1'b1;
        vector_read_k_index = 32'd2;
        @(posedge clk);
        #1;
        check_vector_response(2);

        @(negedge clk);
        vector_read_enable = 1'b0;
        if (failures == 0) begin
            $display(
                "PASS M7 activation cache leaf pipeline: checks=%0d vector_ii=1 responses=5 concurrent_writes=4 clear_flush=1",
                checks
            );
            $finish;
        end
        $fatal(1,
               "FAIL M7 activation cache leaf pipeline: %0d/%0d failed",
               failures, checks);
    end

    initial begin
        repeat (2000) @(posedge clk);
        $fatal(1, "Timeout in tb_m7_activation_cache_leaf_pipeline");
    end

endmodule
