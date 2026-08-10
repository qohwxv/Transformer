`timescale 1ns/1ps

module tb_vit_softmax_engine_fp32_equivalence;

    localparam integer MAX_WORDS = 128;
    localparam integer TIMEOUT_CYCLES = 500000;
    localparam integer DUT_BUFFER_DEPTH = 8;
    localparam logic [31:0] FP32_QNAN = 32'h7fc0_0000;

    logic clk;
    logic rst;
    logic start;
    logic [31:0] cfg_row_count;
    logic [31:0] cfg_row_length;
    logic backpressure_enable;
    logic [31:0] cycle_counter;
    integer active_total_words;

    logic ref_busy;
    logic ref_done;
    logic ref_done_seen;
    logic ref_config_error;
    logic ref_data_request;
    logic ref_input_valid;
    logic [1:0] ref_data_pass;
    logic [31:0] ref_data_index;
    logic [31:0] ref_input_data;
    logic ref_result_valid;
    logic ref_result_ready;
    logic [31:0] ref_result_index;
    logic [31:0] ref_result_data;
    logic [31:0] ref_debug_row_max;
    logic [31:0] ref_debug_exp_sum;

    logic dut_busy;
    logic dut_done;
    logic dut_done_seen;
    logic dut_config_error;
    logic dut_data_request;
    logic dut_input_valid;
    logic [1:0] dut_data_pass;
    logic [31:0] dut_data_index;
    logic [31:0] dut_input_data;
    logic dut_result_valid;
    logic dut_result_ready;
    logic [31:0] dut_result_index;
    logic [31:0] dut_result_data;
    logic [31:0] dut_debug_row_max;
    logic [31:0] dut_debug_exp_sum;

    logic [31:0] input_words [0:MAX_WORDS-1];
    logic [31:0] ref_outputs [0:MAX_WORDS-1];
    logic [31:0] dut_outputs [0:MAX_WORDS-1];
    logic [31:0] ref_max_by_output [0:MAX_WORDS-1];
    logic [31:0] dut_max_by_output [0:MAX_WORDS-1];
    logic [31:0] ref_sum_by_output [0:MAX_WORDS-1];
    logic [31:0] dut_sum_by_output [0:MAX_WORDS-1];
    logic ref_seen [0:MAX_WORDS-1];
    logic dut_seen [0:MAX_WORDS-1];

    integer ref_result_count;
    integer dut_result_count;
    integer ref_read_max_count;
    integer ref_read_sum_count;
    integer ref_read_output_count;
    integer dut_read_max_count;
    integer dut_read_sum_count;
    integer dut_read_output_count;
    integer ref_done_cycle;
    integer dut_done_cycle;

    logic ref_stall_active;
    logic [31:0] ref_stall_index;
    logic [31:0] ref_stall_data;
    logic [31:0] ref_stall_max;
    logic [31:0] ref_stall_sum;
    logic dut_stall_active;
    logic [31:0] dut_stall_index;
    logic [31:0] dut_stall_data;
    logic [31:0] dut_stall_max;
    logic [31:0] dut_stall_sum;

    integer reset_index;
    integer load_index;
    integer check_index;

    always #5 clk = ~clk;

    always_comb begin
        ref_input_valid = 1'b0;
        dut_input_valid = 1'b0;
        ref_result_ready = 1'b0;
        dut_result_ready = 1'b0;

        if (!rst) begin
            ref_input_valid =
                ref_data_request &&
                (!backpressure_enable ||
                 (cycle_counter[2:0] != 3'd1));
            dut_input_valid =
                dut_data_request &&
                (!backpressure_enable ||
                 (cycle_counter[2:0] != 3'd5));

            ref_result_ready =
                !backpressure_enable ||
                (cycle_counter[1:0] != 2'd0);
            dut_result_ready =
                !backpressure_enable ||
                ((cycle_counter[2:0] != 3'd2) &&
                 (cycle_counter[2:0] != 3'd6));
        end

        ref_input_data = FP32_QNAN;
        if (ref_data_index < active_total_words)
            ref_input_data = input_words[ref_data_index];

        dut_input_data = FP32_QNAN;
        if (dut_data_index < active_total_words)
            dut_input_data = input_words[dut_data_index];
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            cycle_counter          <= 32'd0;
            ref_done_seen          <= 1'b0;
            dut_done_seen          <= 1'b0;
            ref_result_count       <= 0;
            dut_result_count       <= 0;
            ref_read_max_count     <= 0;
            ref_read_sum_count     <= 0;
            ref_read_output_count  <= 0;
            dut_read_max_count     <= 0;
            dut_read_sum_count     <= 0;
            dut_read_output_count  <= 0;
            ref_done_cycle         <= -1;
            dut_done_cycle         <= -1;
            ref_stall_active       <= 1'b0;
            ref_stall_index        <= 32'd0;
            ref_stall_data         <= 32'd0;
            ref_stall_max          <= 32'd0;
            ref_stall_sum          <= 32'd0;
            dut_stall_active       <= 1'b0;
            dut_stall_index        <= 32'd0;
            dut_stall_data         <= 32'd0;
            dut_stall_max          <= 32'd0;
            dut_stall_sum          <= 32'd0;

            for (reset_index = 0; reset_index < MAX_WORDS;
                 reset_index = reset_index + 1) begin
                ref_outputs[reset_index]       = 32'd0;
                dut_outputs[reset_index]       = 32'd0;
                ref_max_by_output[reset_index] = 32'd0;
                dut_max_by_output[reset_index] = 32'd0;
                ref_sum_by_output[reset_index] = 32'd0;
                dut_sum_by_output[reset_index] = 32'd0;
                ref_seen[reset_index]          = 1'b0;
                dut_seen[reset_index]          = 1'b0;
            end
        end else begin
            cycle_counter <= cycle_counter + 1'b1;

            if (ref_done) begin
                ref_done_seen <= 1'b1;
                if (!ref_done_seen)
                    ref_done_cycle <= cycle_counter;
            end
            if (dut_done) begin
                dut_done_seen <= 1'b1;
                if (!dut_done_seen)
                    dut_done_cycle <= cycle_counter;
            end

            if (ref_input_valid) begin
                if (ref_data_index >= active_total_words)
                    $fatal(
                        1,
                        "Reference read index out of range: %0d",
                        ref_data_index
                    );
                case (ref_data_pass)
                    2'd0:
                        ref_read_max_count <= ref_read_max_count + 1;
                    2'd1:
                        ref_read_sum_count <= ref_read_sum_count + 1;
                    2'd2:
                        ref_read_output_count <=
                            ref_read_output_count + 1;
                    default:
                        $fatal(
                            1,
                            "Reference emitted invalid pass %0d",
                            ref_data_pass
                        );
                endcase
            end

            if (dut_input_valid) begin
                if (dut_data_index >= active_total_words)
                    $fatal(
                        1,
                        "Production read index out of range: %0d",
                        dut_data_index
                    );
                case (dut_data_pass)
                    2'd0:
                        dut_read_max_count <= dut_read_max_count + 1;
                    2'd1:
                        dut_read_sum_count <= dut_read_sum_count + 1;
                    2'd2:
                        dut_read_output_count <=
                            dut_read_output_count + 1;
                    default:
                        $fatal(
                            1,
                            "Production emitted invalid pass %0d",
                            dut_data_pass
                        );
                endcase
            end

            if (ref_stall_active) begin
                if (!ref_result_valid ||
                    (ref_result_index !== ref_stall_index) ||
                    (ref_result_data !== ref_stall_data) ||
                    (ref_debug_row_max !== ref_stall_max) ||
                    (ref_debug_exp_sum !== ref_stall_sum))
                    $fatal(1, "Reference result changed under backpressure");
            end

            if (dut_stall_active) begin
                if (!dut_result_valid ||
                    (dut_result_index !== dut_stall_index) ||
                    (dut_result_data !== dut_stall_data) ||
                    (dut_debug_row_max !== dut_stall_max) ||
                    (dut_debug_exp_sum !== dut_stall_sum))
                    $fatal(1, "Production result changed under backpressure");
            end

            if (ref_result_valid && !ref_result_ready) begin
                ref_stall_active <= 1'b1;
                ref_stall_index  <= ref_result_index;
                ref_stall_data   <= ref_result_data;
                ref_stall_max    <= ref_debug_row_max;
                ref_stall_sum    <= ref_debug_exp_sum;
            end else begin
                ref_stall_active <= 1'b0;
            end

            if (dut_result_valid && !dut_result_ready) begin
                dut_stall_active <= 1'b1;
                dut_stall_index  <= dut_result_index;
                dut_stall_data   <= dut_result_data;
                dut_stall_max    <= dut_debug_row_max;
                dut_stall_sum    <= dut_debug_exp_sum;
            end else begin
                dut_stall_active <= 1'b0;
            end

            if (ref_result_valid && ref_result_ready) begin
                if (ref_result_index >= active_total_words)
                    $fatal(
                        1,
                        "Reference result index out of range: %0d",
                        ref_result_index
                    );
                if (ref_seen[ref_result_index])
                    $fatal(
                        1,
                        "Reference duplicated result index %0d",
                        ref_result_index
                    );
                ref_outputs[ref_result_index] <= ref_result_data;
                ref_max_by_output[ref_result_index] <=
                    ref_debug_row_max;
                ref_sum_by_output[ref_result_index] <=
                    ref_debug_exp_sum;
                ref_seen[ref_result_index] <= 1'b1;
                ref_result_count <= ref_result_count + 1;
            end

            if (dut_result_valid && dut_result_ready) begin
                if (dut_result_index >= active_total_words)
                    $fatal(
                        1,
                        "Production result index out of range: %0d",
                        dut_result_index
                    );
                if (dut_seen[dut_result_index])
                    $fatal(
                        1,
                        "Production duplicated result index %0d",
                        dut_result_index
                    );
                dut_outputs[dut_result_index] <= dut_result_data;
                dut_max_by_output[dut_result_index] <=
                    dut_debug_row_max;
                dut_sum_by_output[dut_result_index] <=
                    dut_debug_exp_sum;
                dut_seen[dut_result_index] <= 1'b1;
                dut_result_count <= dut_result_count + 1;
            end
        end
    end

    vit_softmax_engine_fp32_reference u_reference (
        .clk             (clk),
        .rst             (rst),
        .start           (start),
        .cfg_row_count   (cfg_row_count),
        .cfg_row_length  (cfg_row_length),
        .busy            (ref_busy),
        .done            (ref_done),
        .config_error    (ref_config_error),
        .data_request    (ref_data_request),
        .input_valid     (ref_input_valid),
        .data_pass       (ref_data_pass),
        .data_index      (ref_data_index),
        .input_data      (ref_input_data),
        .result_valid    (ref_result_valid),
        .result_ready    (ref_result_ready),
        .result_index    (ref_result_index),
        .result_data     (ref_result_data),
        .debug_row_max   (ref_debug_row_max),
        .debug_exp_sum   (ref_debug_exp_sum)
    );

    vit_softmax_engine_fp32 #(
        .ENABLE_ROW_EXP_BUFFER (1),
        .ROW_EXP_BUFFER_DEPTH  (DUT_BUFFER_DEPTH)
    ) u_production (
        .clk             (clk),
        .rst             (rst),
        .start           (start),
        .cfg_row_count   (cfg_row_count),
        .cfg_row_length  (cfg_row_length),
        .busy            (dut_busy),
        .done            (dut_done),
        .config_error    (dut_config_error),
        .data_request    (dut_data_request),
        .input_valid     (dut_input_valid),
        .data_pass       (dut_data_pass),
        .data_index      (dut_data_index),
        .input_data      (dut_input_data),
        .result_valid    (dut_result_valid),
        .result_ready    (dut_result_ready),
        .result_index    (dut_result_index),
        .result_data     (dut_result_data),
        .debug_row_max   (dut_debug_row_max),
        .debug_exp_sum   (dut_debug_exp_sum)
    );

    function automatic logic [31:0] finite_pattern(
        input integer pattern_index
    );
        begin
            case (pattern_index % 16)
                0:  finite_pattern = 32'hc040_0000; // -3.0
                1:  finite_pattern = 32'hc000_0000; // -2.0
                2:  finite_pattern = 32'hbf80_0000; // -1.0
                3:  finite_pattern = 32'hbf00_0000; // -0.5
                4:  finite_pattern = 32'h8000_0000; // -0.0
                5:  finite_pattern = 32'h0000_0000; // +0.0
                6:  finite_pattern = 32'h3e80_0000; // +0.25
                7:  finite_pattern = 32'h3f00_0000; // +0.5
                8:  finite_pattern = 32'h3f80_0000; // +1.0
                9:  finite_pattern = 32'h4000_0000; // +2.0
                10: finite_pattern = 32'h4040_0000; // +3.0
                11: finite_pattern = 32'h4080_0000; // +4.0
                12: finite_pattern = 32'h3f40_0000; // +0.75
                13: finite_pattern = 32'hbfc0_0000; // -1.5
                14: finite_pattern = 32'h40a0_0000; // +5.0
                default:
                    finite_pattern = 32'hc080_0000; // -4.0
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

    task automatic load_small_case;
        begin
            clear_inputs();
            input_words[0] = 32'h3f80_0000;
        end
    endtask

    task automatic load_special_case;
        begin
            clear_inputs();

            input_words[0]  = 32'h0000_0000;
            input_words[1]  = 32'h8000_0000;
            input_words[2]  = 32'h3f80_0000;
            input_words[3]  = 32'hbf80_0000;
            input_words[4]  = 32'h0000_0001;
            input_words[5]  = 32'h8000_0001;

            input_words[6]  = 32'h7f80_0000;
            input_words[7]  = 32'h4040_0000;
            input_words[8]  = 32'hff80_0000;
            input_words[9]  = 32'hc040_0000;
            input_words[10] = 32'h7f7f_ffff;
            input_words[11] = 32'hff7f_ffff;

            input_words[12] = 32'h7fc1_2345;
            input_words[13] = 32'hffc1_2345;
            input_words[14] = 32'h7f80_0001;
            input_words[15] = 32'h0080_0000;
            input_words[16] = 32'h8080_0000;
            input_words[17] = 32'h3f00_0000;

            input_words[18] = 32'hff80_0000;
            input_words[19] = 32'hff80_0000;
            input_words[20] = 32'hff80_0000;
            input_words[21] = 32'hff80_0000;
            input_words[22] = 32'hff80_0000;
            input_words[23] = 32'hff80_0000;

            input_words[24] = 32'h4120_0000;
            input_words[25] = 32'h4120_0000;
            input_words[26] = 32'hc120_0000;
            input_words[27] = 32'hc120_0000;
            input_words[28] = 32'h3f80_0000;
            input_words[29] = 32'h3f80_0000;
        end
    endtask

    task automatic load_many_rows_case;
        begin
            clear_inputs();
            for (load_index = 0; load_index < 99;
                 load_index = load_index + 1)
                input_words[load_index] =
                    finite_pattern(load_index + (load_index / 11));
        end
    endtask

    task automatic run_case(
        input string case_name,
        input integer row_count,
        input integer row_length,
        input logic use_backpressure
    );
        integer case_cycle_count;
        begin
            if ((row_count * row_length) > MAX_WORDS)
                $fatal(1, "%s exceeds MAX_WORDS", case_name);

            active_total_words = row_count * row_length;
            cfg_row_count = row_count;
            cfg_row_length = row_length;
            backpressure_enable = use_backpressure;
            start = 1'b0;
            rst = 1'b1;

            repeat (4) @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;

            case_cycle_count = 0;
            while (!(ref_done_seen && dut_done_seen) &&
                   (case_cycle_count < TIMEOUT_CYCLES)) begin
                @(posedge clk);
                case_cycle_count = case_cycle_count + 1;
            end
            @(negedge clk);

            if (!(ref_done_seen && dut_done_seen))
                $fatal(
                    1,
                    "%s timeout reference_done=%0b production_done=%0b",
                    case_name,
                    ref_done_seen,
                    dut_done_seen
                );
            if (ref_config_error || dut_config_error)
                $fatal(
                    1,
                    "%s unexpected config error ref=%0b dut=%0b",
                    case_name,
                    ref_config_error,
                    dut_config_error
                );
            if ((ref_result_count != active_total_words) ||
                (dut_result_count != active_total_words))
                $fatal(
                    1,
                    "%s result count mismatch ref=%0d dut=%0d expected=%0d",
                    case_name,
                    ref_result_count,
                    dut_result_count,
                    active_total_words
                );

            if ((ref_read_max_count != active_total_words) ||
                (ref_read_sum_count != active_total_words) ||
                (ref_read_output_count != active_total_words))
                $fatal(
                    1,
                    "%s reference pass counts=%0d/%0d/%0d",
                    case_name,
                    ref_read_max_count,
                    ref_read_sum_count,
                    ref_read_output_count
                );

            if (row_length <= DUT_BUFFER_DEPTH) begin
                if ((dut_read_max_count != active_total_words) ||
                    (dut_read_sum_count != 0) ||
                    (dut_read_output_count != 0))
                    $fatal(
                        1,
                        "%s buffered pass counts=%0d/%0d/%0d expected=%0d/0/0",
                        case_name,
                        dut_read_max_count,
                        dut_read_sum_count,
                        dut_read_output_count,
                        active_total_words
                    );

            end else begin
                if ((dut_read_max_count != active_total_words) ||
                    (dut_read_sum_count != active_total_words) ||
                    (dut_read_output_count != active_total_words))
                    $fatal(
                        1,
                        "%s fallback pass counts=%0d/%0d/%0d expected=%0d/%0d/%0d",
                        case_name,
                        dut_read_max_count,
                        dut_read_sum_count,
                        dut_read_output_count,
                        active_total_words,
                        active_total_words,
                        active_total_words
                    );

            end

            for (check_index = 0;
                 check_index < active_total_words;
                 check_index = check_index + 1) begin
                if (!ref_seen[check_index] || !dut_seen[check_index])
                    $fatal(
                        1,
                        "%s missing output index %0d ref=%0b dut=%0b",
                        case_name,
                        check_index,
                        ref_seen[check_index],
                        dut_seen[check_index]
                    );
                if (dut_outputs[check_index] !==
                    ref_outputs[check_index])
                    $fatal(
                        1,
                        "%s data[%0d] ref=%08x dut=%08x",
                        case_name,
                        check_index,
                        ref_outputs[check_index],
                        dut_outputs[check_index]
                    );
                if (dut_max_by_output[check_index] !==
                    ref_max_by_output[check_index])
                    $fatal(
                        1,
                        "%s row_max[%0d] ref=%08x dut=%08x",
                        case_name,
                        check_index,
                        ref_max_by_output[check_index],
                        dut_max_by_output[check_index]
                    );
                if (dut_sum_by_output[check_index] !==
                    ref_sum_by_output[check_index])
                    $fatal(
                        1,
                        "%s exp_sum[%0d] ref=%08x dut=%08x",
                        case_name,
                        check_index,
                        ref_sum_by_output[check_index],
                        dut_sum_by_output[check_index]
                    );
            end

            $display(
                "SOFTMAX_EQUIVALENCE_CASE_PASS name=%s rows=%0d length=%0d oracle_cycles=%0d production_cycles=%0d reads_oracle=%0d reads_production=%0d backpressure=%0b",
                case_name,
                row_count,
                row_length,
                ref_done_cycle,
                dut_done_cycle,
                ref_read_max_count + ref_read_sum_count +
                    ref_read_output_count,
                dut_read_max_count + dut_read_sum_count +
                    dut_read_output_count,
                use_backpressure
            );
        end
    endtask

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        start = 1'b0;
        cfg_row_count = 32'd0;
        cfg_row_length = 32'd0;
        backpressure_enable = 1'b0;
        active_total_words = 0;

        load_small_case();
        run_case("single_element", 1, 1, 1'b0);

        load_special_case();
        run_case("special_fp", 5, 6, 1'b1);

        load_many_rows_case();
        run_case("fallback_many_rows", 9, 11, 1'b0);

        $display("SOFTMAX_ENGINE_BIT_EXACT_EQUIVALENCE_PASS");
        $finish;
    end

endmodule
