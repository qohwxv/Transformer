`timescale 1ns/1ps

module tb_vit_fp32_to_fp16_rne;

    logic [31:0] fp32_i;
    logic [15:0] fp16_o;

    string vector_file;
    integer vector_fd;
    integer scan_count;
    integer vector_count;
    logic [31:0] vector_input;
    logic [15:0] vector_expected;

    vit_fp32_to_fp16_rne_gradual dut (
        .fp32_i (fp32_i),
        .fp16_o (fp16_o)
    );

    initial begin
        fp32_i = 32'd0;
        vector_count = 0;

        if (!$value$plusargs("VECTOR_FILE=%s", vector_file))
            $fatal(1, "VECTOR_FILE plusarg is required");

        vector_fd = $fopen(vector_file, "r");
        if (vector_fd == 0)
            $fatal(1, "cannot open converter vector file: %s", vector_file);

        while (!$feof(vector_fd)) begin
            scan_count = $fscanf(
                vector_fd,
                "%h %h\n",
                vector_input,
                vector_expected
            );
            if (scan_count == 2) begin
                fp32_i = vector_input;
                #1;
                if (fp16_o !== vector_expected)
                    $fatal(
                        1,
                        "FP32_TO_FP16_MISMATCH index=%0d input=%08h expected=%04h actual=%04h",
                        vector_count,
                        vector_input,
                        vector_expected,
                        fp16_o
                    );
                vector_count = vector_count + 1;
            end else if (!$feof(vector_fd)) begin
                $fatal(1, "malformed converter vector at index %0d", vector_count);
            end
        end

        $fclose(vector_fd);
        if (vector_count == 0)
            $fatal(1, "converter vector file was empty");

        $display(
            "PASS M7_FP32_TO_FP16_RNE vectors=%0d",
            vector_count
        );
        $finish;
    end

endmodule
