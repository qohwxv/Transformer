`timescale 1ns/1ps

// One-source-at-a-time harness used by run_exact_parent_ab.sh.  The exact
// M7/IP-v1.12 source and the M8 candidate are compiled in separate builds so
// the frozen parent file remains byte-for-byte identical to its checkpoint.
module tb_vit_softmax_engine_fp32_exact_parent;

    localparam integer MAX_WORDS = 2048;
    localparam integer BUFFER_DEPTH = 1024;
    localparam integer TIMEOUT_CYCLES = 400000;
    localparam integer RESET_AFTER_CYCLES = 5200;
    logic clk;
    logic rst;
    logic start;
    logic [31:0] cfg_row_count;
    logic [31:0] cfg_row_length;
    logic busy;
    logic done;
    logic done_seen;
    logic config_error;
    logic data_request;
    logic input_valid;
    logic [1:0] data_pass;
    logic [31:0] data_index;
    logic [31:0] input_data;
    logic result_valid;
    logic result_ready;
    logic [31:0] result_index;
    logic [31:0] result_data;
    logic [31:0] debug_row_max;
    logic [31:0] debug_exp_sum;

    logic input_stalls_enabled;
    logic output_stalls_enabled;
    logic [31:0] cycle_counter;
    integer active_total_words;

    logic [31:0] input_words [0:MAX_WORDS-1];
    logic [31:0] outputs [0:MAX_WORDS-1];
    logic [31:0] max_by_output [0:MAX_WORDS-1];
    logic [31:0] sum_by_output [0:MAX_WORDS-1];
    logic seen [0:MAX_WORDS-1];

    integer result_count;
    integer read_max_count;
    integer read_sum_count;
    integer read_output_count;
    integer done_cycle;
    integer reset_index;
    integer load_index;
    integer check_index;
    integer signature_file;
    string signature_path;

    logic stalled_result;
    logic [31:0] stalled_result_index;
    logic [31:0] stalled_result_data;
    logic [31:0] stalled_debug_max;
    logic [31:0] stalled_debug_sum;

    always #5 clk = ~clk;

    always_comb begin
        input_valid = 1'b0;
        result_ready = 1'b0;
        input_data = 32'hdeaf_0000 ^ cycle_counter;

        if (!rst) begin
            input_valid = data_request &&
                (!input_stalls_enabled ||
                 ((cycle_counter[3:0] != 4'd1) &&
                  (cycle_counter[3:0] != 4'd6) &&
                  (cycle_counter[3:0] != 4'd11)));
            result_ready = !output_stalls_enabled ||
                ((cycle_counter[2:0] != 3'd0) &&
                 (cycle_counter[2:0] != 3'd3) &&
                 (cycle_counter[2:0] != 3'd6));
        end

        // Deliberately poison input_data whenever input_valid is low.  This
        // catches accidental sampling during a request stall.
        if (input_valid && (data_index < active_total_words))
            input_data = input_words[data_index];
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            cycle_counter <= 32'd0;
            done_seen <= 1'b0;
            result_count <= 0;
            read_max_count <= 0;
            read_sum_count <= 0;
            read_output_count <= 0;
            done_cycle <= -1;
            stalled_result <= 1'b0;
            stalled_result_index <= 32'd0;
            stalled_result_data <= 32'd0;
            stalled_debug_max <= 32'd0;
            stalled_debug_sum <= 32'd0;
            for (reset_index = 0; reset_index < MAX_WORDS;
                 reset_index = reset_index + 1) begin
                outputs[reset_index] = 32'd0;
                max_by_output[reset_index] = 32'd0;
                sum_by_output[reset_index] = 32'd0;
                seen[reset_index] = 1'b0;
            end
        end else begin
            cycle_counter <= cycle_counter + 1'b1;

            if (done) begin
                done_seen <= 1'b1;
                if (!done_seen)
                    done_cycle <= cycle_counter;
            end

            if (input_valid) begin
                if (!data_request)
                    $fatal(1, "input_valid without data_request");
                if (data_index >= active_total_words)
                    $fatal(1, "read index out of range: %0d >= %0d",
                           data_index, active_total_words);
                case (data_pass)
                    2'd0: read_max_count <= read_max_count + 1;
                    2'd1: read_sum_count <= read_sum_count + 1;
                    2'd2: read_output_count <= read_output_count + 1;
                    default: $fatal(1, "invalid data_pass=%0d", data_pass);
                endcase
            end

            if (stalled_result) begin
                if (!result_valid ||
                    (result_index !== stalled_result_index) ||
                    (result_data !== stalled_result_data) ||
                    (debug_row_max !== stalled_debug_max) ||
                    (debug_exp_sum !== stalled_debug_sum))
                    $fatal(1, "result/debug changed under backpressure");
            end

            if (result_valid && !result_ready) begin
                stalled_result <= 1'b1;
                stalled_result_index <= result_index;
                stalled_result_data <= result_data;
                stalled_debug_max <= debug_row_max;
                stalled_debug_sum <= debug_exp_sum;
            end else begin
                stalled_result <= 1'b0;
            end

            if (result_valid && result_ready) begin
                if (result_index >= active_total_words)
                    $fatal(1, "result index out of range: %0d >= %0d",
                           result_index, active_total_words);
                if (seen[result_index])
                    $fatal(1, "duplicate result index=%0d", result_index);
                outputs[result_index] <= result_data;
                max_by_output[result_index] <= debug_row_max;
                sum_by_output[result_index] <= debug_exp_sum;
                seen[result_index] <= 1'b1;
                result_count <= result_count + 1;
            end
        end
    end

`ifdef M8_CANDIDATE
    vit_softmax_engine_fp32 #(
        .ENABLE_ROW_EXP_BUFFER (1),
        .ROW_EXP_BUFFER_DEPTH  (BUFFER_DEPTH)
    ) dut (
`else
    vit_softmax_engine_fp32 dut (
`endif
        .clk(clk),
        .rst(rst),
        .start(start),
        .cfg_row_count(cfg_row_count),
        .cfg_row_length(cfg_row_length),
        .busy(busy),
        .done(done),
        .config_error(config_error),
        .data_request(data_request),
        .input_valid(input_valid),
        .data_pass(data_pass),
        .data_index(data_index),
        .input_data(input_data),
        .result_valid(result_valid),
        .result_ready(result_ready),
        .result_index(result_index),
        .result_data(result_data),
        .debug_row_max(debug_row_max),
        .debug_exp_sum(debug_exp_sum),
        .mul_operand_a(),
        .mul_operand_b(),
        .external_mul_result(32'd0),
        .add_operand_a(),
        .add_operand_b(),
        .external_add_result(32'd0)
    );

    function automatic logic [31:0] finite_pattern(input integer index);
        begin
            case (index % 20)
                0: finite_pattern = 32'hc120_0000;
                1: finite_pattern = 32'hc080_0000;
                2: finite_pattern = 32'hc040_0000;
                3: finite_pattern = 32'hc000_0000;
                4: finite_pattern = 32'hbf80_0000;
                5: finite_pattern = 32'hbf00_0000;
                6: finite_pattern = 32'h8000_0000;
                7: finite_pattern = 32'h0000_0000;
                8: finite_pattern = 32'h3d80_0000;
                9: finite_pattern = 32'h3e80_0000;
                10: finite_pattern = 32'h3f00_0000;
                11: finite_pattern = 32'h3f40_0000;
                12: finite_pattern = 32'h3f80_0000;
                13: finite_pattern = 32'h3fc0_0000;
                14: finite_pattern = 32'h4000_0000;
                15: finite_pattern = 32'h4020_0000;
                16: finite_pattern = 32'h4040_0000;
                17: finite_pattern = 32'h4080_0000;
                18: finite_pattern = 32'h40a0_0000;
                default: finite_pattern = 32'h4120_0000;
            endcase
        end
    endfunction

    task automatic clear_inputs;
        begin
            for (load_index = 0; load_index < MAX_WORDS;
                 load_index = load_index + 1)
                input_words[load_index] = 32'd0;
        end
    endtask

    task automatic load_finite(input integer words, input integer salt);
        begin
            clear_inputs();
            for (load_index = 0; load_index < words;
                 load_index = load_index + 1)
                input_words[load_index] =
                    finite_pattern((load_index * 13) + salt +
                                   (load_index / 17));
        end
    endtask

    task automatic load_special;
        begin
            clear_inputs();
            input_words[0]  = 32'h0000_0000;
            input_words[1]  = 32'h8000_0000;
            input_words[2]  = 32'h0000_0001;
            input_words[3]  = 32'h8000_0001;
            input_words[4]  = 32'h0080_0000;
            input_words[5]  = 32'h8080_0000;
            input_words[6]  = 32'h3f80_0000;
            input_words[7]  = 32'hbf80_0000;
            input_words[8]  = 32'h7f80_0000;
            input_words[9]  = 32'hff80_0000;
            input_words[10] = 32'h7f7f_ffff;
            input_words[11] = 32'hff7f_ffff;
            input_words[12] = 32'h7fc1_2345;
            input_words[13] = 32'hffc1_2345;
            input_words[14] = 32'h7f80_0001;
            input_words[15] = 32'hff80_0001;
            input_words[16] = 32'hff80_0000;
            input_words[17] = 32'hff80_0000;
            input_words[18] = 32'hff80_0000;
            input_words[19] = 32'hff80_0000;
            input_words[20] = 32'h4120_0000;
            input_words[21] = 32'h4120_0000;
            input_words[22] = 32'hc120_0000;
            input_words[23] = 32'hc120_0000;
            input_words[24] = 32'h3f00_0000;
            input_words[25] = 32'hbf00_0000;
            input_words[26] = 32'h4000_0000;
            input_words[27] = 32'hc000_0000;
            input_words[28] = 32'h4040_0000;
            input_words[29] = 32'hc040_0000;
            input_words[30] = 32'h0000_0001;
            input_words[31] = 32'h8000_0001;
        end
    endtask

    task automatic pulse_start;
        begin
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    task automatic reset_then_start;
        begin
            start = 1'b0;
            rst = 1'b1;
            repeat (4) @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
            pulse_start();
        end
    endtask

    task automatic run_case(
        input string case_name,
        input integer row_count,
        input integer row_length,
        input logic use_input_stalls,
        input logic use_output_stalls,
        input logic inject_reset,
        input logic expect_buffer
    );
        integer wait_cycles;
        integer expected_reads;
        begin
            active_total_words = row_count * row_length;
            if ((active_total_words < 1) ||
                (active_total_words > MAX_WORDS))
                $fatal(1, "%s invalid total words=%0d",
                       case_name, active_total_words);

            cfg_row_count = row_count;
            cfg_row_length = row_length;
            input_stalls_enabled = use_input_stalls;
            output_stalls_enabled = use_output_stalls;
            reset_then_start();

            if (inject_reset) begin
                repeat (RESET_AFTER_CYCLES) @(posedge clk);
                if (!busy || done_seen)
                    $fatal(1, "%s reset injection missed active job busy=%0b done=%0b",
                           case_name, busy, done_seen);
                @(negedge clk);
                rst = 1'b1;
                repeat (3) @(posedge clk);
                if (busy || done)
                    $fatal(1, "%s reset did not clear busy/done", case_name);
                @(negedge clk);
                rst = 1'b0;
                pulse_start();
            end

            wait_cycles = 0;
            while (!done_seen && (wait_cycles < TIMEOUT_CYCLES)) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
            end
            @(negedge clk);

            if (!done_seen)
                $fatal(1, "%s timeout", case_name);
            if (config_error)
                $fatal(1, "%s unexpected config_error", case_name);
            if (result_count != active_total_words)
                $fatal(1, "%s results=%0d expected=%0d",
                       case_name, result_count, active_total_words);

`ifdef M8_CANDIDATE
            if (expect_buffer) begin
                if ((read_max_count != active_total_words) ||
                    (read_sum_count != 0) ||
                    (read_output_count != 0))
                    $fatal(1, "%s candidate reads=%0d/%0d/%0d expected=%0d/0/0",
                           case_name, read_max_count, read_sum_count,
                           read_output_count, active_total_words);
                expected_reads = active_total_words;
            end else begin
                if ((read_max_count != active_total_words) ||
                    (read_sum_count != active_total_words) ||
                    (read_output_count != active_total_words))
                    $fatal(1, "%s candidate fallback reads=%0d/%0d/%0d",
                           case_name, read_max_count, read_sum_count,
                           read_output_count);
                expected_reads = 3 * active_total_words;
            end
`else
            if ((read_max_count != active_total_words) ||
                (read_sum_count != active_total_words) ||
                (read_output_count != active_total_words))
                $fatal(1, "%s parent reads=%0d/%0d/%0d",
                       case_name, read_max_count, read_sum_count,
                       read_output_count);
            expected_reads = 3 * active_total_words;
`endif

            for (check_index = 0; check_index < active_total_words;
                 check_index = check_index + 1) begin
                if (!seen[check_index])
                    $fatal(1, "%s missing output=%0d", case_name,
                           check_index);
                $fwrite(signature_file, "%s\t%0d\t%08x\t%08x\t%08x\n",
                        case_name, check_index, outputs[check_index],
                        max_by_output[check_index],
                        sum_by_output[check_index]);
            end

`ifdef M8_CANDIDATE
            $display("SOFTMAX_EXACT_AB_CASE_PASS implementation=M8_CANDIDATE name=%s rows=%0d length=%0d cycles=%0d reads=%0d reset=%0b input_stalls=%0b output_stalls=%0b",
                     case_name, row_count, row_length, done_cycle,
                     expected_reads, inject_reset, use_input_stalls,
                     use_output_stalls);
`else
            $display("SOFTMAX_EXACT_AB_CASE_PASS implementation=M7_PARENT_V1_12 name=%s rows=%0d length=%0d cycles=%0d reads=%0d reset=%0b input_stalls=%0b output_stalls=%0b",
                     case_name, row_count, row_length, done_cycle,
                     expected_reads, inject_reset, use_input_stalls,
                     use_output_stalls);
`endif
        end
    endtask

    task automatic run_invalid_config;
        integer wait_cycles;
        begin
            active_total_words = 0;
            cfg_row_count = 0;
            cfg_row_length = 197;
            input_stalls_enabled = 1'b0;
            output_stalls_enabled = 1'b0;
            reset_then_start();
            wait_cycles = 0;
            while (!done_seen && (wait_cycles < 100)) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
            end
            @(negedge clk);
            if (!done_seen || !config_error || result_count != 0 ||
                read_max_count != 0 || read_sum_count != 0 ||
                read_output_count != 0)
                $fatal(1, "invalid config contract failed");
            $display("SOFTMAX_EXACT_AB_INVALID_CONFIG_PASS");
        end
    endtask

    initial begin
        if (!$value$plusargs("SIGNATURE_FILE=%s", signature_path))
            $fatal(1, "missing +SIGNATURE_FILE");
        signature_file = $fopen(signature_path, "w");
        if (signature_file == 0)
            $fatal(1, "cannot open signature file: %s", signature_path);

        clk = 1'b0;
        rst = 1'b1;
        start = 1'b0;
        cfg_row_count = 32'd0;
        cfg_row_length = 32'd0;
        input_stalls_enabled = 1'b0;
        output_stalls_enabled = 1'b0;
        active_total_words = 0;

        load_finite(3, 1);
        run_case("length_1", 3, 1, 1'b1, 1'b1, 1'b0, 1'b1);

        load_finite(394, 7);
        run_case("attention_197", 2, 197, 1'b1, 1'b1, 1'b0, 1'b1);

        load_finite(1000, 11);
        run_case("classifier_1000", 1, 1000, 1'b1, 1'b0, 1'b0, 1'b1);

        load_finite(1024, 13);
        run_case("boundary_1024", 1, 1024, 1'b0, 1'b1, 1'b0, 1'b1);

        load_finite(1025, 17);
        run_case("fallback_1025", 1, 1025, 1'b1, 1'b1, 1'b0, 1'b0);

        load_finite(1537, 19);
        run_case("fallback_1537", 1, 1537, 1'b1, 1'b0, 1'b0, 1'b0);

        load_special();
        run_case("special_fp", 4, 8, 1'b1, 1'b1, 1'b0, 1'b1);

        load_finite(197, 23);
        run_case("reset_restart_197", 1, 197, 1'b1, 1'b1, 1'b1, 1'b1);

        run_invalid_config();
        $fclose(signature_file);
`ifdef M8_CANDIDATE
        $display("SOFTMAX_EXACT_PARENT_HARNESS_PASS implementation=M8_CANDIDATE");
`else
        $display("SOFTMAX_EXACT_PARENT_HARNESS_PASS implementation=M7_PARENT_V1_12");
`endif
        $finish;
    end

endmodule
