`timescale 1ns/1ps

module tb_vit_layernorm_engine_fp32_m8_ab;

    localparam integer MAX_HIDDEN = 3072;
    localparam integer MAX_WORDS = 197 * 768;
    localparam integer TIMEOUT_CYCLES = 20_000_000;
    localparam logic [31:0] FP32_QNAN = 32'h7fc0_0000;

`ifdef M8_PARENT_BASELINE
    localparam string IMPLEMENTATION = "M7_PARENT_V1_12";
    localparam bit EXPECT_BUFFERED = 1'b0;
`else
    localparam string IMPLEMENTATION = "M8_LN_BUFFERED";
    localparam bit EXPECT_BUFFERED = 1'b1;
`endif

    logic clk;
    logic rst;
    logic start;
    logic [31:0] cfg_token_count;
    logic [31:0] cfg_hidden_size;
    logic [31:0] cfg_epsilon;
    logic busy;
    logic done;
    logic config_error;

    logic data_request;
    logic input_valid;
    logic [1:0] data_pass;
    logic [31:0] data_index;
    logic [31:0] data_channel_index;
    logic [31:0] input_data;
    logic [31:0] gamma_data;
    logic [31:0] beta_data;

    logic result_valid;
    logic result_ready;
    logic [31:0] result_index;
    logic [31:0] result_data;
    logic [31:0] debug_mean;
    logic [31:0] debug_variance;
    logic [31:0] debug_inv_std;

    logic [31:0] input_words [0:MAX_WORDS-1];
    logic [31:0] gamma_words [0:MAX_HIDDEN-1];
    logic [31:0] beta_words [0:MAX_HIDDEN-1];

    logic request_inflight;
    logic [3:0] response_delay;
    logic [1:0] request_pass_q;
    logic [31:0] request_index_q;
    logic [31:0] request_channel_q;
    logic done_seen;
    logic stall_active;
    logic [31:0] stall_index_q;
    logic [31:0] stall_data_q;
    logic [31:0] stall_mean_q;
    logic [31:0] stall_variance_q;
    logic [31:0] stall_inv_std_q;

    integer cycle_count;
    integer result_count;
    integer mean_packet_count;
    integer variance_packet_count;
    integer affine_packet_count;
    integer active_token_count_int;
    integer active_hidden_size_int;
    integer active_total_words;
    integer case_id;
    integer trace_fd;
    integer load_index;
    integer expected_mean_packets;
    integer expected_variance_packets;
    integer expected_affine_packets;
    integer observed_word_reads;
    integer expected_word_reads;
    logic backpressure_enable;
    logic in_place_enable;
    logic trace_enable;
    string trace_path;

    always #5 clk = ~clk;

    assign result_ready =
        !backpressure_enable ||
        ((cycle_count % 11) != 3 &&
         (cycle_count % 11) != 7 &&
         (cycle_count % 11) != 8);

    vit_layernorm_engine_fp32 dut (
        .clk                (clk),
        .rst                (rst),
        .start              (start),
        .cfg_token_count    (cfg_token_count),
        .cfg_hidden_size    (cfg_hidden_size),
        .cfg_epsilon        (cfg_epsilon),
        .busy               (busy),
        .done               (done),
        .config_error       (config_error),
        .data_request       (data_request),
        .input_valid        (input_valid),
        .data_pass          (data_pass),
        .data_index         (data_index),
        .data_channel_index (data_channel_index),
        .input_data         (input_data),
        .gamma_data         (gamma_data),
        .beta_data          (beta_data),
        .result_valid       (result_valid),
        .result_ready       (result_ready),
        .result_index       (result_index),
        .result_data        (result_data),
        .debug_mean         (debug_mean),
        .debug_variance     (debug_variance),
        .debug_inv_std      (debug_inv_std),
        .mul_operand_a      (),
        .mul_operand_b      (),
        .external_mul_result(32'd0),
        .add_operand_a      (),
        .add_operand_b      (),
        .external_add_result(32'd0)
    );

    function automatic logic [31:0] sample_pattern(input integer index);
        begin
            case (index % 16)
                0: sample_pattern = 32'hc040_0000;
                1: sample_pattern = 32'hc000_0000;
                2: sample_pattern = 32'hbf80_0000;
                3: sample_pattern = 32'hbf00_0000;
                4: sample_pattern = 32'h8000_0000;
                5: sample_pattern = 32'h0000_0000;
                6: sample_pattern = 32'h3e80_0000;
                7: sample_pattern = 32'h3f00_0000;
                8: sample_pattern = 32'h3f80_0000;
                9: sample_pattern = 32'h4000_0000;
                10: sample_pattern = 32'h4040_0000;
                11: sample_pattern = 32'h4080_0000;
                12: sample_pattern = 32'h3f40_0000;
                13: sample_pattern = 32'hbfc0_0000;
                14: sample_pattern = 32'h40a0_0000;
                default: sample_pattern = 32'hc080_0000;
            endcase
        end
    endfunction

    function automatic logic [31:0] gamma_pattern(input integer index);
        begin
            case (index % 8)
                0: gamma_pattern = 32'h3f80_0000;
                1: gamma_pattern = 32'h3f00_0000;
                2: gamma_pattern = 32'h4000_0000;
                3: gamma_pattern = 32'hbf80_0000;
                4: gamma_pattern = 32'h0000_0000;
                5: gamma_pattern = 32'h3fc0_0000;
                6: gamma_pattern = 32'hbe80_0000;
                default: gamma_pattern = 32'h4080_0000;
            endcase
        end
    endfunction

    function automatic logic [31:0] beta_pattern(input integer index);
        begin
            case (index % 8)
                0: beta_pattern = 32'h0000_0000;
                1: beta_pattern = 32'h3e80_0000;
                2: beta_pattern = 32'hbe80_0000;
                3: beta_pattern = 32'h3f80_0000;
                4: beta_pattern = 32'hbf80_0000;
                5: beta_pattern = 32'h8000_0000;
                6: beta_pattern = 32'h4000_0000;
                default: beta_pattern = 32'hc000_0000;
            endcase
        end
    endfunction

    task automatic initialize_case_data(
        input integer token_count,
        input integer hidden_size,
        input logic special_values
    );
        integer token;
        integer channel;
        integer flat_index;
        begin
            active_token_count_int = token_count;
            active_hidden_size_int = hidden_size;
            active_total_words = token_count * hidden_size;

            if (active_total_words > MAX_WORDS)
                $fatal(1, "test requires %0d words, MAX_WORDS=%0d",
                       active_total_words, MAX_WORDS);
            if (hidden_size > MAX_HIDDEN)
                $fatal(1, "test hidden=%0d exceeds MAX_HIDDEN=%0d",
                       hidden_size, MAX_HIDDEN);

            for (channel = 0; channel < hidden_size;
                 channel = channel + 1) begin
                gamma_words[channel] = gamma_pattern(channel);
                beta_words[channel] = beta_pattern(channel);
            end

            for (token = 0; token < token_count; token = token + 1)
                for (channel = 0; channel < hidden_size;
                     channel = channel + 1) begin
                    flat_index = token * hidden_size + channel;
                    input_words[flat_index] =
                        sample_pattern(flat_index + token * 3);
                end

            if (special_values) begin
                input_words[0]  = 32'h0000_0000;
                input_words[1]  = 32'h8000_0000;
                input_words[2]  = 32'h0000_0001;
                input_words[3]  = 32'h8000_0001;
                input_words[4]  = 32'h0080_0000;
                input_words[5]  = 32'h8080_0000;
                input_words[6]  = 32'h7f7f_ffff;
                input_words[7]  = 32'hff7f_ffff;
                input_words[8]  = 32'h7f80_0000;
                input_words[9]  = 32'hff80_0000;
                input_words[10] = 32'h7fc1_2345;
                input_words[11] = 32'hffc1_2345;
                input_words[12] = 32'h7f80_0001;
                input_words[13] = 32'h3f80_0000;
                input_words[14] = 32'hbf80_0000;
                input_words[15] = 32'h0000_0000;

                gamma_words[0] = 32'h7f80_0000;
                gamma_words[1] = 32'hff80_0000;
                gamma_words[2] = 32'h7fc1_2345;
                gamma_words[3] = 32'h0000_0001;
                beta_words[0] = 32'h8000_0000;
                beta_words[1] = 32'h7f80_0000;
                beta_words[2] = 32'hff80_0000;
                beta_words[3] = 32'h7fc1_2345;
            end
        end
    endtask

    task automatic reset_and_start(
        input integer token_count,
        input integer hidden_size,
        input logic [31:0] epsilon
    );
        begin
            cfg_token_count = token_count;
            cfg_hidden_size = hidden_size;
            cfg_epsilon = epsilon;
            start = 1'b0;
            rst = 1'b1;
            repeat (4) @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    task automatic run_case(
        input integer next_case_id,
        input string case_name,
        input integer token_count,
        input integer hidden_size,
        input logic [31:0] epsilon,
        input logic use_backpressure,
        input logic use_in_place,
        input logic special_values
    );
        begin
            case_id = next_case_id;
            backpressure_enable = use_backpressure;
            in_place_enable = use_in_place;
            trace_enable = 1'b1;
            initialize_case_data(token_count, hidden_size, special_values);
            reset_and_start(token_count, hidden_size, epsilon);

            while (!done_seen && (cycle_count < TIMEOUT_CYCLES))
                @(posedge clk);
            @(negedge clk);

            if (!done_seen)
                $fatal(1, "%s timeout cycles=%0d results=%0d",
                       case_name, cycle_count, result_count);
            if (config_error)
                $fatal(1, "%s unexpected config_error", case_name);
            if (request_inflight || input_valid)
                $fatal(1, "%s ended with memory response pending", case_name);
            if (result_count != active_total_words)
                $fatal(1, "%s result count got=%0d expected=%0d",
                       case_name, result_count, active_total_words);

            expected_mean_packets = active_total_words;
            if (EXPECT_BUFFERED && (hidden_size <= 1024)) begin
                expected_variance_packets = 0;
                expected_affine_packets = hidden_size;
                expected_word_reads = hidden_size * (token_count + 3);
            end else begin
                expected_variance_packets = active_total_words;
                expected_affine_packets = active_total_words;
                expected_word_reads = 5 * active_total_words;
            end

            if ((mean_packet_count != expected_mean_packets) ||
                (variance_packet_count != expected_variance_packets) ||
                (affine_packet_count != expected_affine_packets))
                $fatal(1,
                       "%s packet counts mean/var/affine=%0d/%0d/%0d expected=%0d/%0d/%0d",
                       case_name,
                       mean_packet_count, variance_packet_count,
                       affine_packet_count, expected_mean_packets,
                       expected_variance_packets, expected_affine_packets);

            observed_word_reads = mean_packet_count +
                                  variance_packet_count +
                                  (3 * affine_packet_count);
            if (observed_word_reads != expected_word_reads)
                $fatal(1, "%s word reads got=%0d expected=%0d",
                       case_name, observed_word_reads, expected_word_reads);

            $display(
                "M8_LN_CASE_PASS implementation=%s name=%s tokens=%0d hidden=%0d cycles=%0d packets=%0d/%0d/%0d word_reads=%0d in_place=%0b backpressure=%0b",
                IMPLEMENTATION, case_name, token_count, hidden_size,
                cycle_count, mean_packet_count, variance_packet_count,
                affine_packet_count, observed_word_reads, use_in_place,
                use_backpressure
            );
            trace_enable = 1'b0;
        end
    endtask

    task automatic exercise_midcommand_reset;
        integer wait_cycles;
        begin
            case_id = 90;
            trace_enable = 1'b0;
            backpressure_enable = 1'b1;
            in_place_enable = 1'b0;
            initialize_case_data(2, 16, 1'b0);
            reset_and_start(2, 16, 32'h3727_c5ac);

            wait_cycles = 0;
            while ((mean_packet_count < 9) && (wait_cycles < 1000)) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
            end
            if (mean_packet_count < 9)
                $fatal(1, "mid-command reset failed to dirty sample buffer");

            @(negedge clk);
            rst = 1'b1;
            repeat (3) @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
            @(posedge clk);
            if (busy || done || data_request || result_valid || config_error)
                $fatal(1,
                       "reset did not return clean idle busy=%0b done=%0b request=%0b valid=%0b error=%0b",
                       busy, done, data_request, result_valid, config_error);

            $display("M8_LN_RESET_ABORT_PASS implementation=%s", IMPLEMENTATION);
        end
    endtask

    always_ff @(posedge clk) begin
        if (rst) begin
            input_valid <= 1'b0;
            input_data <= FP32_QNAN;
            gamma_data <= FP32_QNAN;
            beta_data <= FP32_QNAN;
            request_inflight <= 1'b0;
            response_delay <= 4'd0;
            request_pass_q <= 2'd0;
            request_index_q <= 32'd0;
            request_channel_q <= 32'd0;
            done_seen <= 1'b0;
            stall_active <= 1'b0;
            stall_index_q <= 32'd0;
            stall_data_q <= 32'd0;
            stall_mean_q <= 32'd0;
            stall_variance_q <= 32'd0;
            stall_inv_std_q <= 32'd0;
            cycle_count <= 0;
            result_count <= 0;
            mean_packet_count <= 0;
            variance_packet_count <= 0;
            affine_packet_count <= 0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (done)
                done_seen <= 1'b1;

            if (input_valid) begin
                input_valid <= 1'b0;
                input_data <= FP32_QNAN;
                gamma_data <= FP32_QNAN;
                beta_data <= FP32_QNAN;
            end else if (!request_inflight && data_request) begin
                if ((data_index >= active_total_words) ||
                    (data_channel_index >= active_hidden_size_int))
                    $fatal(1,
                           "request out of bounds pass=%0d index=%0d channel=%0d total=%0d hidden=%0d",
                           data_pass, data_index, data_channel_index,
                           active_total_words, active_hidden_size_int);
                request_inflight <= 1'b1;
                request_pass_q <= data_pass;
                request_index_q <= data_index;
                request_channel_q <= data_channel_index;
                // Approximate the serialized production frontend: affine
                // fetches sample/gamma/beta, while statistics fetch one word.
                if (data_pass == 2'd2)
                    response_delay <= 4'd7 + cycle_count[0];
                else
                    response_delay <= 4'd3 + cycle_count[0];
            end else if (request_inflight) begin
                if (response_delay != 0) begin
                    response_delay <= response_delay - 1'b1;
                end else begin
                    request_inflight <= 1'b0;
                    input_valid <= 1'b1;
                    input_data <= input_words[request_index_q];
                    gamma_data <= gamma_words[request_channel_q];
                    beta_data <= beta_words[request_channel_q];
                end
            end

            if (input_valid && data_request) begin
                case (request_pass_q)
                    2'd0: mean_packet_count <= mean_packet_count + 1;
                    2'd1: variance_packet_count <=
                        variance_packet_count + 1;
                    2'd2: affine_packet_count <= affine_packet_count + 1;
                    default: $fatal(1, "invalid LayerNorm pass %0d",
                                    request_pass_q);
                endcase
            end

            if (stall_active) begin
                if (!result_valid ||
                    (result_index !== stall_index_q) ||
                    (result_data !== stall_data_q) ||
                    (debug_mean !== stall_mean_q) ||
                    (debug_variance !== stall_variance_q) ||
                    (debug_inv_std !== stall_inv_std_q))
                    $fatal(1, "result/debug changed under backpressure");
            end

            if (result_valid && !result_ready) begin
                stall_active <= 1'b1;
                stall_index_q <= result_index;
                stall_data_q <= result_data;
                stall_mean_q <= debug_mean;
                stall_variance_q <= debug_variance;
                stall_inv_std_q <= debug_inv_std;
            end else begin
                stall_active <= 1'b0;
            end

            if (result_valid && result_ready) begin
                if (result_index != result_count)
                    $fatal(1, "non-sequential/duplicate result got=%0d expected=%0d",
                           result_index, result_count);
                if (trace_enable)
                    $fwrite(trace_fd, "%0d %0d %08x %08x %08x %08x\n",
                            case_id, result_index, result_data, debug_mean,
                            debug_variance, debug_inv_std);
                if (in_place_enable)
                    input_words[result_index] <= result_data;
                result_count <= result_count + 1;
            end
        end
    end

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        start = 1'b0;
        cfg_token_count = 32'd0;
        cfg_hidden_size = 32'd0;
        cfg_epsilon = 32'd0;
        backpressure_enable = 1'b0;
        in_place_enable = 1'b0;
        trace_enable = 1'b0;
        active_token_count_int = 0;
        active_hidden_size_int = 0;
        active_total_words = 0;
        case_id = 0;

        if (!$value$plusargs("TRACE_FILE=%s", trace_path))
            trace_path = "/tmp/m8_layernorm_trace.txt";
        trace_fd = $fopen(trace_path, "w");
        if (trace_fd == 0)
            $fatal(1, "cannot open trace file %s", trace_path);

        exercise_midcommand_reset();
        run_case(1, "h1_t2", 2, 1, 32'h3727_c5ac,
                 1'b0, 1'b0, 1'b0);
        run_case(2, "h16_t2_special", 2, 16, 32'h0000_0001,
                 1'b1, 1'b0, 1'b1);
        run_case(3, "h16_t2_in_place_alias", 2, 16, 32'h3727_c5ac,
                 1'b1, 1'b1, 1'b0);
        run_case(4, "h768_t2", 2, 768, 32'h3727_c5ac,
                 1'b1, 1'b0, 1'b0);
        run_case(5, "h1024_t2_boundary", 2, 1024, 32'h3727_c5ac,
                 1'b1, 1'b0, 1'b0);
        run_case(6, "h1025_t2_fallback", 2, 1025, 32'h3727_c5ac,
                 1'b1, 1'b0, 1'b0);
        run_case(7, "h3072_t1_fallback", 1, 3072, 32'h3727_c5ac,
                 1'b1, 1'b0, 1'b0);
        run_case(8, "production_h768_t197", 197, 768, 32'h3727_c5ac,
                 1'b1, 1'b0, 1'b0);

        $fclose(trace_fd);
        $display("M8_LAYERNORM_AB_SIM_PASS implementation=%s", IMPLEMENTATION);
        $finish;
    end

endmodule
