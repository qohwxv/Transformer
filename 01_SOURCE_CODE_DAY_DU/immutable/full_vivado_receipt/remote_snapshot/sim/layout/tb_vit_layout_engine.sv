`timescale 1ns/1ps

module tb_vit_layout_engine;

    logic clk;
    logic rst;
    logic start;
    logic cfg_src_bank;
    logic [31:0] cfg_src_base;
    logic [31:0] cfg_dst_base;
    logic [31:0] cfg_dim0;
    logic [31:0] cfg_dim1;
    logic [31:0] cfg_dim2;
    logic [31:0] cfg_src_stride0;
    logic [31:0] cfg_src_stride1;
    logic [31:0] cfg_src_stride2;
    logic busy;
    logic done;
    logic config_error;
    logic data_request;
    logic data_valid;
    logic src_bank;
    logic [31:0] source_address;
    logic [31:0] source_data;
    logic result_valid;
    logic result_ready;
    logic [31:0] result_address;
    logic [31:0] result_data;

    integer request_count;
    integer result_count;
    integer cycle_count;
    integer expected_i0;
    integer expected_i1;
    integer expected_i2;
    logic [31:0] expected_source_address;

    assign data_valid = 1'b1;
    assign source_data = source_address ^ 32'ha5a5_5a5a;
    assign result_ready = (cycle_count[1:0] != 2'b10);

    vit_layout_engine u_dut (
        .clk             (clk),
        .rst             (rst),
        .start           (start),
        .cfg_src_bank    (cfg_src_bank),
        .cfg_src_base    (cfg_src_base),
        .cfg_dst_base    (cfg_dst_base),
        .cfg_dim0        (cfg_dim0),
        .cfg_dim1        (cfg_dim1),
        .cfg_dim2        (cfg_dim2),
        .cfg_src_stride0 (cfg_src_stride0),
        .cfg_src_stride1 (cfg_src_stride1),
        .cfg_src_stride2 (cfg_src_stride2),
        .busy            (busy),
        .done            (done),
        .config_error    (config_error),
        .data_request    (data_request),
        .data_valid      (data_valid),
        .src_bank        (src_bank),
        .source_address  (source_address),
        .source_data     (source_data),
        .result_valid    (result_valid),
        .result_ready    (result_ready),
        .result_address  (result_address),
        .result_data     (result_data)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always_ff @(posedge clk) begin
        if (rst)
            cycle_count <= 0;
        else
            cycle_count <= cycle_count + 1;
    end

    always @(posedge clk) begin
        if (!rst && data_request && data_valid) begin
            expected_i0 = request_count / 12;
            expected_i1 = (request_count % 12) / 4;
            expected_i2 = request_count % 4;
            expected_source_address =
                32'd7 +
                (expected_i0 * 32'd100) +
                (expected_i1 * 32'd10) +
                (expected_i2 * 32'd2);

            if (source_address !== expected_source_address)
                $fatal(
                    1,
                    "source address mismatch request=%0d expected=%0d actual=%0d",
                    request_count,
                    expected_source_address,
                    source_address
                );
            if (src_bank !== 1'b1)
                $fatal(1, "source bank was not retained");
            request_count = request_count + 1;
        end

        if (!rst && result_valid && result_ready) begin
            expected_i0 = result_count / 12;
            expected_i1 = (result_count % 12) / 4;
            expected_i2 = result_count % 4;
            expected_source_address =
                32'd7 +
                (expected_i0 * 32'd100) +
                (expected_i1 * 32'd10) +
                (expected_i2 * 32'd2);

            if (result_address !== (32'd1000 + result_count))
                $fatal(
                    1,
                    "destination mismatch result=%0d expected=%0d actual=%0d",
                    result_count,
                    1000 + result_count,
                    result_address
                );
            if (result_data !==
                (expected_source_address ^ 32'ha5a5_5a5a))
                $fatal(1, "data mismatch result=%0d", result_count);
            result_count = result_count + 1;
        end
    end

    task automatic pulse_start;
        begin
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    task automatic wait_for_done;
        integer timeout;
        begin
            timeout = 0;
            while (!done && (timeout < 2000)) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (!done)
                $fatal(1, "layout timeout");
            @(posedge clk);
        end
    endtask

    initial begin
        rst = 1'b1;
        start = 1'b0;
        cfg_src_bank = 1'b0;
        cfg_src_base = 32'd0;
        cfg_dst_base = 32'd0;
        cfg_dim0 = 32'd0;
        cfg_dim1 = 32'd0;
        cfg_dim2 = 32'd0;
        cfg_src_stride0 = 32'd0;
        cfg_src_stride1 = 32'd0;
        cfg_src_stride2 = 32'd0;
        request_count = 0;
        result_count = 0;
        cycle_count = 0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        cfg_src_bank = 1'b1;
        cfg_src_base = 32'd7;
        cfg_dst_base = 32'd1000;
        cfg_dim0 = 32'd2;
        cfg_dim1 = 32'd3;
        cfg_dim2 = 32'd4;
        cfg_src_stride0 = 32'd100;
        cfg_src_stride1 = 32'd10;
        cfg_src_stride2 = 32'd2;
        pulse_start();
        wait_for_done();

        if (config_error)
            $fatal(1, "valid descriptor raised config_error");
        if ((request_count != 24) || (result_count != 24))
            $fatal(
                1,
                "word count mismatch requests=%0d results=%0d",
                request_count,
                result_count
            );

        cfg_dim0 = 32'd0;
        pulse_start();
        wait_for_done();
        if (!config_error)
            $fatal(1, "zero dimension was accepted");

        cfg_dim0 = 32'hffff_ffff;
        cfg_dim1 = 32'hffff_ffff;
        cfg_dim2 = 32'd2;
        pulse_start();
        wait_for_done();
        if (!config_error)
            $fatal(1, "overflowing descriptor was accepted");

        $display(
            "LAYOUT_ENGINE_PASS requests=%0d results=%0d",
            request_count,
            result_count
        );
        $finish;
    end

endmodule
