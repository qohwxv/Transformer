`timescale 1ns/1ps

module tb_vit_gemm_tree_array;

    localparam integer ARRAY_ROWS = 2;
    localparam integer ARRAY_COLS = 2;
    localparam integer PE_LANES   = 16;

    logic clk;
    logic rst;
    logic start;
    logic [31:0] cfg_m;
    logic [31:0] cfg_k;
    logic [31:0] cfg_n;
    logic [31:0] cfg_batch_count;
    logic cfg_bias_enable;
    logic busy;
    logic done;
    logic config_error;
    logic data_request;
    logic data_valid;
    logic [31:0] token_base;
    logic [31:0] output_base;
    logic [31:0] k_base;
    logic [31:0] batch_index;
    logic [ARRAY_ROWS*PE_LANES*32-1:0] activation_data;
    logic [ARRAY_COLS*PE_LANES*32-1:0] weight_data;
    logic [ARRAY_COLS*32-1:0] bias_data;
    logic result_valid;
    logic result_ready;
    logic [31:0] result_token_base;
    logic [31:0] result_output_base;
    logic [31:0] result_batch_index;
    logic [ARRAY_ROWS-1:0] result_token_mask;
    logic [ARRAY_COLS-1:0] result_output_mask;
    logic [ARRAY_ROWS*ARRAY_COLS*32-1:0] result_data;

    integer drive_row_index;
    integer drive_col_index;
    integer drive_lane_index;
    integer result_count;
    integer error_count;
    integer check_row_index;
    integer check_col_index;
    integer check_token_index;
    integer check_output_index;
    integer check_pe_index;
    integer hold_pe_index;
    integer timeout_cycles;

    logic [31:0] held_result_data [0:ARRAY_ROWS*ARRAY_COLS-1];
    logic [31:0] held_token_base;
    logic [31:0] held_output_base;

    vit_gemm_tree_array #(
        .ARRAY_ROWS (ARRAY_ROWS),
        .ARRAY_COLS (ARRAY_COLS),
        .PE_LANES   (PE_LANES)
    ) dut (
        .clk                      (clk),
        .rst                      (rst),
        .start                    (start),
        .cfg_m                    (cfg_m),
        .cfg_k                    (cfg_k),
        .cfg_n                    (cfg_n),
        .cfg_batch_count          (cfg_batch_count),
        .cfg_bias_enable          (cfg_bias_enable),
        .busy                     (busy),
        .done                     (done),
        .config_error             (config_error),
        .data_request             (data_request),
        .data_valid               (data_valid),
        .token_base               (token_base),
        .output_base              (output_base),
        .k_base                   (k_base),
        .batch_index              (batch_index),
        .activation_data          (activation_data),
        .weight_data              (weight_data),
        .bias_data                (bias_data),
        .result_valid             (result_valid),
        .result_ready             (result_ready),
        .result_token_base        (result_token_base),
        .result_output_base       (result_output_base),
        .result_batch_index       (result_batch_index),
        .result_token_mask        (result_token_mask),
        .result_output_mask       (result_output_mask),
        .result_data              (result_data)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    function automatic logic [31:0] activation_value(input integer token);
        begin
            case (token)
                0: activation_value = 32'h3f80_0000; // 1.0
                1: activation_value = 32'h4000_0000; // 2.0
                2: activation_value = 32'h4040_0000; // 3.0
                default: activation_value = 32'h7fc0_0000;
            endcase
        end
    endfunction

    function automatic logic [31:0] weight_value(input integer output_id);
        begin
            case (output_id)
                0: weight_value = 32'h3f80_0000; // 1.0
                1: weight_value = 32'h4000_0000; // 2.0
                2: weight_value = 32'h4040_0000; // 3.0
                default: weight_value = 32'h7fc0_0000;
            endcase
        end
    endfunction

    // With K=17 and bias[n]=n:
    // C[token,n] = 17*(token+1)*(n+1)+n.
    function automatic logic [31:0] expected_value(
        input integer token,
        input integer output_id
    );
        begin
            case (token*3 + output_id)
                0: expected_value = 32'h4188_0000; // 17
                1: expected_value = 32'h420c_0000; // 35
                2: expected_value = 32'h4254_0000; // 53
                3: expected_value = 32'h4208_0000; // 34
                4: expected_value = 32'h428a_0000; // 69
                5: expected_value = 32'h42d0_0000; // 104
                6: expected_value = 32'h424c_0000; // 51
                7: expected_value = 32'h42ce_0000; // 103
                8: expected_value = 32'h431b_0000; // 155
                default: expected_value = 32'hxxxx_xxxx;
            endcase
        end
    endfunction

    // Respond combinationally to each requested chunk.  The second K chunk
    // contains only one valid lane.  Every tail lane is deliberately poisoned
    // with Inf/NaN to prove that lane_valid suppresses it.
    always_comb begin
        data_valid      = data_request;
        activation_data = '0;
        weight_data     = '0;
        bias_data       = '0;

        for (drive_row_index = 0; drive_row_index < ARRAY_ROWS;
             drive_row_index = drive_row_index + 1) begin
            for (drive_lane_index = 0; drive_lane_index < PE_LANES;
                 drive_lane_index = drive_lane_index + 1) begin
                if ((k_base + drive_lane_index) < cfg_k) begin
                    activation_data[
                        (drive_row_index*PE_LANES+drive_lane_index)*32 +: 32
                    ] = activation_value(token_base + drive_row_index);
                end else begin
                    activation_data[
                        (drive_row_index*PE_LANES+drive_lane_index)*32 +: 32
                    ] = 32'h7f80_0000;
                end
            end
        end

        for (drive_col_index = 0; drive_col_index < ARRAY_COLS;
             drive_col_index = drive_col_index + 1) begin
            case (output_base + drive_col_index)
                0: bias_data[drive_col_index*32 +: 32] = 32'h0000_0000;
                1: bias_data[drive_col_index*32 +: 32] = 32'h3f80_0000;
                2: bias_data[drive_col_index*32 +: 32] = 32'h4000_0000;
                default:
                    bias_data[drive_col_index*32 +: 32] = 32'h7fc0_0000;
            endcase

            for (drive_lane_index = 0; drive_lane_index < PE_LANES;
                 drive_lane_index = drive_lane_index + 1) begin
                if ((k_base + drive_lane_index) < cfg_k) begin
                    weight_data[
                        (drive_col_index*PE_LANES+drive_lane_index)*32 +: 32
                    ] = weight_value(output_base + drive_col_index);
                end else begin
                    weight_data[
                        (drive_col_index*PE_LANES+drive_lane_index)*32 +: 32
                    ] = 32'h7fc0_0000;
                end
            end
        end

        // The shared PE array must own the accepted tile while it visits the
        // four output coordinates. Poison every external operand as soon as
        // data_request drops to catch accidental dependence on live buses.
        if (!data_request) begin
            for (drive_row_index = 0;
                 drive_row_index < ARRAY_ROWS;
                 drive_row_index = drive_row_index + 1) begin
                for (drive_lane_index = 0;
                     drive_lane_index < PE_LANES;
                     drive_lane_index = drive_lane_index + 1) begin
                    activation_data[
                        (drive_row_index*PE_LANES+
                         drive_lane_index)*32 +: 32
                    ] = 32'h7fc0_0000;
                end
            end

            for (drive_col_index = 0;
                 drive_col_index < ARRAY_COLS;
                 drive_col_index = drive_col_index + 1) begin
                bias_data[drive_col_index*32 +: 32] = 32'h7f80_0000;
                for (drive_lane_index = 0;
                     drive_lane_index < PE_LANES;
                     drive_lane_index = drive_lane_index + 1) begin
                    weight_data[
                        (drive_col_index*PE_LANES+
                         drive_lane_index)*32 +: 32
                    ] = 32'h7f80_0000;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (result_valid && result_ready) begin
            if (result_batch_index != 0) begin
                $error("unexpected batch index %0d", result_batch_index);
                error_count = error_count + 1;
            end

            for (check_row_index = 0; check_row_index < ARRAY_ROWS;
                 check_row_index = check_row_index + 1) begin
                for (check_col_index = 0; check_col_index < ARRAY_COLS;
                     check_col_index = check_col_index + 1) begin
                    check_pe_index =
                        check_row_index*ARRAY_COLS + check_col_index;
                    check_token_index =
                        result_token_base + check_row_index;
                    check_output_index =
                        result_output_base + check_col_index;

                    if (result_token_mask[check_row_index] &&
                        result_output_mask[check_col_index]) begin
                        if (result_data[check_pe_index*32 +: 32] !==
                            expected_value(
                                check_token_index,
                                check_output_index
                            )) begin
                            $error(
                                "C[%0d,%0d] expected=%h observed=%h",
                                check_token_index,
                                check_output_index,
                                expected_value(
                                    check_token_index,
                                    check_output_index
                                ),
                                result_data[check_pe_index*32 +: 32]
                            );
                            error_count = error_count + 1;
                        end
                    end
                end
            end
            result_count = result_count + 1;
        end
    end

    initial begin
        rst               = 1'b1;
        start             = 1'b0;
        cfg_m             = 32'd3;
        cfg_k             = 32'd17;
        cfg_n             = 32'd3;
        cfg_batch_count   = 32'd1;
        cfg_bias_enable   = 1'b1;
        result_ready      = 1'b0;
        result_count      = 0;
        error_count       = 0;
        held_token_base   = 32'd0;
        held_output_base  = 32'd0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        if (!busy || (batch_index != 0)) begin
            $error("controller did not enter a valid busy state");
            error_count = error_count + 1;
        end

        // Hold the first result for two clocks and verify every externally
        // visible result field remains stable while ready is low.
        wait (result_valid);
        #1;
        held_token_base  = result_token_base;
        held_output_base = result_output_base;
        for (hold_pe_index = 0;
             hold_pe_index < ARRAY_ROWS*ARRAY_COLS;
             hold_pe_index = hold_pe_index + 1) begin
            held_result_data[hold_pe_index] =
                result_data[hold_pe_index*32 +: 32];
        end

        repeat (2) begin
            @(posedge clk);
            #1;
            if (!result_valid ||
                (result_token_base != held_token_base) ||
                (result_output_base != held_output_base)) begin
                $error("result metadata changed while result_ready=0");
                error_count = error_count + 1;
            end
            for (hold_pe_index = 0;
                 hold_pe_index < ARRAY_ROWS*ARRAY_COLS;
                 hold_pe_index = hold_pe_index + 1) begin
                if (result_data[hold_pe_index*32 +: 32] !==
                    held_result_data[hold_pe_index]) begin
                    $error("result data changed while result_ready=0");
                    error_count = error_count + 1;
                end
            end
        end

        @(negedge clk);
        result_ready = 1'b1;

        timeout_cycles = 0;
        // The production PE array intentionally reuses one multiplier and
        // one adder, so this timeout covers the serial dot-product schedule.
        while (!done && (timeout_cycles < 3000)) begin
            @(posedge clk);
            #1;
            timeout_cycles = timeout_cycles + 1;
        end
        if (!done)
            $fatal(1, "timeout waiting for GEMM done");

        @(posedge clk);
        #1;
        if (config_error) begin
            $error("valid GEMM raised config_error");
            error_count = error_count + 1;
        end
        if (result_count != 4) begin
            $error("expected 4 tiles, observed %0d", result_count);
            error_count = error_count + 1;
        end

        if (error_count == 0)
            $display("GEMM_TREE_ARRAY_PASS tiles=%0d", result_count);
        else
            $fatal(1, "GEMM_TREE_ARRAY_FAIL errors=%0d", error_count);

        $finish;
    end

endmodule
