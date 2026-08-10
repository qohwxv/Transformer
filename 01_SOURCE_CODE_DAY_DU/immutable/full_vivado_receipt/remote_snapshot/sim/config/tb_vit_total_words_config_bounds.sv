`timescale 1ns/1ps

// Direct configuration-boundary checks for the iterative total-word
// multipliers in LayerNorm and Softmax.
//
// The maximum valid product is exercised with:
//     65535 * 65537 = 0xffff_ffff
//
// The first overflowing product is exercised with:
//     65536 * 65536 = 0x1_0000_0000
//
// No tensor data is supplied.  A valid configuration must therefore stop at
// its first data request, while rejected configurations must finish without
// issuing either a data request or a result.
module tb_vit_total_words_config_bounds;

    localparam logic [31:0] MAX_FACTOR_A = 32'd65535;
    localparam logic [31:0] MAX_FACTOR_B = 32'd65537;
    localparam logic [31:0] OVERFLOW_FACTOR = 32'd65536;

    logic clk;
    logic rst;

    logic ln_start;
    logic [31:0] ln_token_count;
    logic [31:0] ln_hidden_size;
    logic ln_busy;
    logic ln_done;
    logic ln_config_error;
    logic ln_data_request;
    logic [1:0] ln_data_pass;
    logic [31:0] ln_data_index;
    logic [31:0] ln_data_channel_index;
    logic ln_result_valid;
    logic [31:0] ln_result_index;
    logic [31:0] ln_result_data;
    logic [31:0] ln_debug_mean;
    logic [31:0] ln_debug_variance;
    logic [31:0] ln_debug_inv_std;

    logic sm_start;
    logic [31:0] sm_row_count;
    logic [31:0] sm_row_length;
    logic sm_busy;
    logic sm_done;
    logic sm_config_error;
    logic sm_data_request;
    logic [1:0] sm_data_pass;
    logic [31:0] sm_data_index;
    logic sm_result_valid;
    logic [31:0] sm_result_index;
    logic [31:0] sm_result_data;
    logic [31:0] sm_debug_row_max;
    logic [31:0] sm_debug_exp_sum;

    integer checks;

    always #5 clk = ~clk;

    vit_layernorm_engine_fp32 u_layernorm (
        .clk                (clk),
        .rst                (rst),
        .start              (ln_start),
        .cfg_token_count    (ln_token_count),
        .cfg_hidden_size    (ln_hidden_size),
        .cfg_epsilon        (32'h3727_c5ac),
        .busy               (ln_busy),
        .done               (ln_done),
        .config_error       (ln_config_error),
        .data_request       (ln_data_request),
        .input_valid        (1'b0),
        .data_pass          (ln_data_pass),
        .data_index         (ln_data_index),
        .data_channel_index (ln_data_channel_index),
        .input_data         (32'd0),
        .gamma_data         (32'h3f80_0000),
        .beta_data          (32'd0),
        .result_valid       (ln_result_valid),
        .result_ready       (1'b1),
        .result_index       (ln_result_index),
        .result_data        (ln_result_data),
        .debug_mean         (ln_debug_mean),
        .debug_variance     (ln_debug_variance),
        .debug_inv_std      (ln_debug_inv_std)
    );

    vit_softmax_engine_fp32 u_softmax (
        .clk           (clk),
        .rst           (rst),
        .start         (sm_start),
        .cfg_row_count (sm_row_count),
        .cfg_row_length(sm_row_length),
        .busy          (sm_busy),
        .done          (sm_done),
        .config_error  (sm_config_error),
        .data_request  (sm_data_request),
        .input_valid   (1'b0),
        .data_pass     (sm_data_pass),
        .data_index    (sm_data_index),
        .input_data    (32'd0),
        .result_valid  (sm_result_valid),
        .result_ready  (1'b1),
        .result_index  (sm_result_index),
        .result_data   (sm_result_data),
        .debug_row_max (sm_debug_row_max),
        .debug_exp_sum (sm_debug_exp_sum)
    );

    task automatic apply_reset;
        begin
            ln_start = 1'b0;
            sm_start = 1'b0;
            rst = 1'b1;
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
            @(negedge clk);

            if (ln_busy || ln_done || ln_config_error ||
                ln_data_request || ln_result_valid)
                $fatal(1, "LayerNorm reset did not clear the interface");
            if (sm_busy || sm_done || sm_config_error ||
                sm_data_request || sm_result_valid)
                $fatal(1, "Softmax reset did not clear the interface");
            checks = checks + 2;
        end
    endtask

    task automatic launch_layernorm(
        input logic [31:0] token_count,
        input logic [31:0] hidden_size
    );
        begin
            ln_token_count = token_count;
            ln_hidden_size = hidden_size;
            @(negedge clk);
            ln_start = 1'b1;
            @(negedge clk);
            ln_start = 1'b0;
        end
    endtask

    task automatic launch_softmax(
        input logic [31:0] row_count,
        input logic [31:0] row_length
    );
        begin
            sm_row_count = row_count;
            sm_row_length = row_length;
            @(negedge clk);
            sm_start = 1'b1;
            @(negedge clk);
            sm_start = 1'b0;
        end
    endtask

    task automatic reset_layernorm_during_total;
        begin
            launch_layernorm(32'd1234567, 32'd3456);

            // TOTAL_START launches the multiplier on the next rising edge.
            @(negedge clk);
            if (!u_layernorm.u_total_words_multiplier.busy)
                $fatal(1, "LayerNorm total_words multiplier did not start");
            if (ln_data_request || ln_result_valid || ln_done ||
                ln_config_error)
                $fatal(1, "LayerNorm exposed activity before total_words completed");

            rst = 1'b1;
            repeat (2) @(posedge clk);
            @(negedge clk);
            if (ln_busy || ln_done || ln_config_error ||
                ln_data_request || ln_result_valid ||
                u_layernorm.u_total_words_multiplier.busy ||
                (u_layernorm.total_words_product != 64'd0))
                $fatal(1, "LayerNorm reset did not cancel total_words");

            rst = 1'b0;
            @(negedge clk);
            if (ln_busy || ln_done || ln_config_error ||
                ln_data_request || ln_result_valid)
                $fatal(1, "LayerNorm did not remain idle after reset cancellation");
            checks = checks + 11;
        end
    endtask

    task automatic reset_softmax_during_total;
        begin
            launch_softmax(32'd7654321, 32'd2345);

            // Exercise reset while the independent Softmax multiplier is busy.
            @(negedge clk);
            if (!u_softmax.u_total_words_multiplier.busy)
                $fatal(1, "Softmax total_words multiplier did not start");
            if (sm_data_request || sm_result_valid || sm_done ||
                sm_config_error)
                $fatal(1, "Softmax exposed activity before total_words completed");

            rst = 1'b1;
            repeat (2) @(posedge clk);
            @(negedge clk);
            if (sm_busy || sm_done || sm_config_error ||
                sm_data_request || sm_result_valid ||
                u_softmax.u_total_words_multiplier.busy ||
                (u_softmax.total_words_product != 64'd0))
                $fatal(1, "Softmax reset did not cancel total_words");

            rst = 1'b0;
            @(negedge clk);
            if (sm_busy || sm_done || sm_config_error ||
                sm_data_request || sm_result_valid)
                $fatal(1, "Softmax did not remain idle after reset cancellation");
            checks = checks + 11;
        end
    endtask

    task automatic expect_layernorm_reject(
        input integer max_cycles
    );
        integer cycle;
        logic seen_done;
        begin
            seen_done = 1'b0;
            cycle = 0;
            while (!seen_done && (cycle < max_cycles)) begin
                if (ln_data_request)
                    $fatal(1, "Rejected LayerNorm config requested data");
                if (ln_result_valid)
                    $fatal(1, "Rejected LayerNorm config produced a result");
                if (ln_done) begin
                    if (!ln_config_error)
                        $fatal(1, "LayerNorm reject omitted config_error");
                    seen_done = 1'b1;
                end else begin
                    @(negedge clk);
                    cycle = cycle + 1;
                end
            end
            if (!seen_done)
                $fatal(1, "LayerNorm reject timed out");

            @(negedge clk);
            if (ln_done || ln_busy || ln_data_request || ln_result_valid)
                $fatal(1, "LayerNorm reject did not return to idle");
            if (!ln_config_error)
                $fatal(1, "LayerNorm config_error did not remain diagnostic");
            checks = checks + 5;
        end
    endtask

    task automatic expect_softmax_reject(
        input integer max_cycles
    );
        integer cycle;
        logic seen_done;
        begin
            seen_done = 1'b0;
            cycle = 0;
            while (!seen_done && (cycle < max_cycles)) begin
                if (sm_data_request)
                    $fatal(1, "Rejected Softmax config requested data");
                if (sm_result_valid)
                    $fatal(1, "Rejected Softmax config produced a result");
                if (sm_done) begin
                    if (!sm_config_error)
                        $fatal(1, "Softmax reject omitted config_error");
                    seen_done = 1'b1;
                end else begin
                    @(negedge clk);
                    cycle = cycle + 1;
                end
            end
            if (!seen_done)
                $fatal(1, "Softmax reject timed out");

            @(negedge clk);
            if (sm_done || sm_busy || sm_data_request || sm_result_valid)
                $fatal(1, "Softmax reject did not return to idle");
            if (!sm_config_error)
                $fatal(1, "Softmax config_error did not remain diagnostic");
            checks = checks + 5;
        end
    endtask

    task automatic expect_layernorm_first_request(
        input integer max_cycles
    );
        integer cycle;
        logic seen_request;
        begin
            seen_request = 1'b0;
            cycle = 0;
            while (!seen_request && (cycle < max_cycles)) begin
                if (ln_config_error)
                    $fatal(1, "Valid LayerNorm boundary was rejected");
                if (ln_done)
                    $fatal(1, "Valid LayerNorm boundary finished before input");
                if (ln_result_valid)
                    $fatal(1, "LayerNorm produced a result without input");
                if (ln_data_request) begin
                    if ((ln_data_pass != 2'd0) ||
                        (ln_data_index != 32'd0) ||
                        (ln_data_channel_index != 32'd0))
                        $fatal(1, "LayerNorm first request metadata mismatch");
                    seen_request = 1'b1;
                end else begin
                    @(negedge clk);
                    cycle = cycle + 1;
                end
            end
            if (!seen_request)
                $fatal(1, "Valid LayerNorm boundary did not request data");
            checks = checks + 6;
        end
    endtask

    task automatic expect_softmax_first_request(
        input integer max_cycles
    );
        integer cycle;
        logic seen_request;
        begin
            seen_request = 1'b0;
            cycle = 0;
            while (!seen_request && (cycle < max_cycles)) begin
                if (sm_config_error)
                    $fatal(1, "Valid Softmax boundary was rejected");
                if (sm_done)
                    $fatal(1, "Valid Softmax boundary finished before input");
                if (sm_result_valid)
                    $fatal(1, "Softmax produced a result without input");
                if (sm_data_request) begin
                    if ((sm_data_pass != 2'd0) ||
                        (sm_data_index != 32'd0))
                        $fatal(1, "Softmax first request metadata mismatch");
                    seen_request = 1'b1;
                end else begin
                    @(negedge clk);
                    cycle = cycle + 1;
                end
            end
            if (!seen_request)
                $fatal(1, "Valid Softmax boundary did not request data");
            checks = checks + 5;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        ln_start = 1'b0;
        ln_token_count = 32'd1;
        ln_hidden_size = 32'd1;
        sm_start = 1'b0;
        sm_row_count = 32'd1;
        sm_row_length = 32'd1;
        checks = 0;

        // LayerNorm: both zero dimensions are invalid immediately.
        apply_reset();
        launch_layernorm(32'd0, 32'd1);
        expect_layernorm_reject(4);
        launch_layernorm(32'd1, 32'd0);
        expect_layernorm_reject(4);

        // Reset must abort the 32-cycle configuration multiplication itself.
        reset_layernorm_during_total();

        // Recovery from the sticky error is checked without another reset.
        // The exact 32-bit maximum product must pass configuration checking.
        launch_layernorm(MAX_FACTOR_A, MAX_FACTOR_B);
        expect_layernorm_first_request(160);

        // Reset while stalled on a valid request must cancel the command.
        apply_reset();

        // The smallest product above 32 bits must be rejected after the
        // iterative multiplier completes, without any memory-side activity.
        launch_layernorm(OVERFLOW_FACTOR, OVERFLOW_FACTOR);
        expect_layernorm_reject(80);
        apply_reset();

        // Softmax performs the same zero, boundary, recovery, and overflow
        // checks through its independent configuration controller.
        launch_softmax(32'd0, 32'd1);
        expect_softmax_reject(4);
        launch_softmax(32'd1, 32'd0);
        expect_softmax_reject(4);

        reset_softmax_during_total();

        launch_softmax(MAX_FACTOR_A, MAX_FACTOR_B);
        expect_softmax_first_request(80);
        apply_reset();

        launch_softmax(OVERFLOW_FACTOR, OVERFLOW_FACTOR);
        expect_softmax_reject(80);
        apply_reset();

        $display(
            "PASS total_words config bounds: checks=%0d max=ffffffff overflow=0000000100000000",
            checks
        );
        $finish;
    end

endmodule
