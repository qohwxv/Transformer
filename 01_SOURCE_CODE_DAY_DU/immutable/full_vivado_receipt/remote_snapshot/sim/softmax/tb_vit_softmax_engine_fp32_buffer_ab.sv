`timescale 1ns/1ps

module tb_vit_softmax_engine_fp32_buffer_ab;

    localparam integer MAX_WORDS = 1025;
    localparam integer BUFFER_DEPTH = 1024;
    localparam integer TIMEOUT_CYCLES = 200000;

    logic clk;
    logic rst;
    logic start;
    logic [31:0] cfg_row_count;
    logic [31:0] cfg_row_length;
    logic [31:0] cycle_counter;
    integer active_total_words;

    logic base_done;
    logic base_done_seen;
    logic base_config_error;
    logic base_data_request;
    logic base_input_valid;
    logic [1:0] base_data_pass;
    logic [31:0] base_data_index;
    logic [31:0] base_input_data;
    logic base_result_valid;
    logic [31:0] base_result_index;
    logic [31:0] base_result_data;

    logic opt_done;
    logic opt_done_seen;
    logic opt_config_error;
    logic opt_data_request;
    logic opt_input_valid;
    logic [1:0] opt_data_pass;
    logic [31:0] opt_data_index;
    logic [31:0] opt_input_data;
    logic opt_result_valid;
    logic [31:0] opt_result_index;
    logic [31:0] opt_result_data;

    logic [31:0] input_words [0:MAX_WORDS-1];
    logic [31:0] base_outputs [0:MAX_WORDS-1];
    logic [31:0] opt_outputs [0:MAX_WORDS-1];
    logic base_seen [0:MAX_WORDS-1];
    logic opt_seen [0:MAX_WORDS-1];

    integer base_done_cycle;
    integer opt_done_cycle;
    integer base_result_count;
    integer opt_result_count;
    integer base_read_max_count;
    integer base_read_sum_count;
    integer base_read_output_count;
    integer opt_read_max_count;
    integer opt_read_sum_count;
    integer opt_read_output_count;
    integer reset_index;
    integer load_index;
    integer check_index;

    always #5 clk = ~clk;

    always_comb begin
        base_input_valid = base_data_request;
        opt_input_valid = opt_data_request;

        base_input_data = 32'h7fc0_0000;
        if (base_data_index < active_total_words)
            base_input_data = input_words[base_data_index];

        opt_input_data = 32'h7fc0_0000;
        if (opt_data_index < active_total_words)
            opt_input_data = input_words[opt_data_index];
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            cycle_counter <= 32'd0;
            base_done_seen <= 1'b0;
            opt_done_seen <= 1'b0;
            base_done_cycle <= -1;
            opt_done_cycle <= -1;
            base_result_count <= 0;
            opt_result_count <= 0;
            base_read_max_count <= 0;
            base_read_sum_count <= 0;
            base_read_output_count <= 0;
            opt_read_max_count <= 0;
            opt_read_sum_count <= 0;
            opt_read_output_count <= 0;

            for (reset_index = 0; reset_index < MAX_WORDS;
                 reset_index = reset_index + 1) begin
                base_outputs[reset_index] = 32'd0;
                opt_outputs[reset_index] = 32'd0;
                base_seen[reset_index] = 1'b0;
                opt_seen[reset_index] = 1'b0;
            end
        end else begin
            cycle_counter <= cycle_counter + 1'b1;

            if (base_done) begin
                base_done_seen <= 1'b1;
                if (!base_done_seen)
                    base_done_cycle <= cycle_counter;
            end
            if (opt_done) begin
                opt_done_seen <= 1'b1;
                if (!opt_done_seen)
                    opt_done_cycle <= cycle_counter;
            end

            if (base_input_valid) begin
                if (base_data_index >= active_total_words)
                    $fatal(1, "Baseline read index out of range: %0d",
                           base_data_index);
                case (base_data_pass)
                    2'd0: base_read_max_count <= base_read_max_count + 1;
                    2'd1: base_read_sum_count <= base_read_sum_count + 1;
                    2'd2: base_read_output_count <=
                        base_read_output_count + 1;
                    default: $fatal(1, "Baseline invalid data_pass=%0d",
                                    base_data_pass);
                endcase
            end

            if (opt_input_valid) begin
                if (opt_data_index >= active_total_words)
                    $fatal(1, "Buffered read index out of range: %0d",
                           opt_data_index);
                case (opt_data_pass)
                    2'd0: opt_read_max_count <= opt_read_max_count + 1;
                    2'd1: opt_read_sum_count <= opt_read_sum_count + 1;
                    2'd2: opt_read_output_count <=
                        opt_read_output_count + 1;
                    default: $fatal(1, "Buffered invalid data_pass=%0d",
                                    opt_data_pass);
                endcase
            end

            if (base_result_valid) begin
                if (base_result_index >= active_total_words)
                    $fatal(1, "Baseline result index out of range: %0d",
                           base_result_index);
                if (base_seen[base_result_index])
                    $fatal(1, "Baseline duplicate result index: %0d",
                           base_result_index);
                base_outputs[base_result_index] <= base_result_data;
                base_seen[base_result_index] <= 1'b1;
                base_result_count <= base_result_count + 1;
            end

            if (opt_result_valid) begin
                if (opt_result_index >= active_total_words)
                    $fatal(1, "Buffered result index out of range: %0d",
                           opt_result_index);
                if (opt_seen[opt_result_index])
                    $fatal(1, "Buffered duplicate result index: %0d",
                           opt_result_index);
                opt_outputs[opt_result_index] <= opt_result_data;
                opt_seen[opt_result_index] <= 1'b1;
                opt_result_count <= opt_result_count + 1;
            end
        end
    end

    vit_softmax_engine_fp32 #(
        .ENABLE_ROW_EXP_BUFFER (0),
        .ROW_EXP_BUFFER_DEPTH  (BUFFER_DEPTH)
    ) u_serial_baseline (
        .clk(clk),
        .rst(rst),
        .start(start),
        .cfg_row_count(cfg_row_count),
        .cfg_row_length(cfg_row_length),
        .busy(),
        .done(base_done),
        .config_error(base_config_error),
        .data_request(base_data_request),
        .input_valid(base_input_valid),
        .data_pass(base_data_pass),
        .data_index(base_data_index),
        .input_data(base_input_data),
        .result_valid(base_result_valid),
        .result_ready(1'b1),
        .result_index(base_result_index),
        .result_data(base_result_data),
        .debug_row_max(),
        .debug_exp_sum(),
        .mul_operand_a(),
        .mul_operand_b(),
        .external_mul_result(32'd0),
        .add_operand_a(),
        .add_operand_b(),
        .external_add_result(32'd0)
    );

    vit_softmax_engine_fp32 #(
        .ENABLE_ROW_EXP_BUFFER (1),
        .ROW_EXP_BUFFER_DEPTH  (BUFFER_DEPTH)
    ) u_buffered (
        .clk(clk),
        .rst(rst),
        .start(start),
        .cfg_row_count(cfg_row_count),
        .cfg_row_length(cfg_row_length),
        .busy(),
        .done(opt_done),
        .config_error(opt_config_error),
        .data_request(opt_data_request),
        .input_valid(opt_input_valid),
        .data_pass(opt_data_pass),
        .data_index(opt_data_index),
        .input_data(opt_input_data),
        .result_valid(opt_result_valid),
        .result_ready(1'b1),
        .result_index(opt_result_index),
        .result_data(opt_result_data),
        .debug_row_max(),
        .debug_exp_sum(),
        .mul_operand_a(),
        .mul_operand_b(),
        .external_mul_result(32'd0),
        .add_operand_a(),
        .add_operand_b(),
        .external_add_result(32'd0)
    );

    function automatic logic [31:0] finite_pattern(
        input integer pattern_index
    );
        begin
            case (pattern_index % 16)
                0: finite_pattern = 32'hc040_0000;
                1: finite_pattern = 32'hc000_0000;
                2: finite_pattern = 32'hbf80_0000;
                3: finite_pattern = 32'hbf00_0000;
                4: finite_pattern = 32'h0000_0000;
                5: finite_pattern = 32'h3e80_0000;
                6: finite_pattern = 32'h3f00_0000;
                7: finite_pattern = 32'h3f40_0000;
                8: finite_pattern = 32'h3f80_0000;
                9: finite_pattern = 32'h3fc0_0000;
                10: finite_pattern = 32'h4000_0000;
                11: finite_pattern = 32'h4020_0000;
                12: finite_pattern = 32'h4040_0000;
                13: finite_pattern = 32'h4080_0000;
                14: finite_pattern = 32'h40a0_0000;
                default: finite_pattern = 32'hc080_0000;
            endcase
        end
    endfunction

    task automatic load_case(input integer words, input integer salt);
        begin
            for (load_index = 0; load_index < MAX_WORDS;
                 load_index = load_index + 1)
                input_words[load_index] = 32'd0;
            for (load_index = 0; load_index < words;
                 load_index = load_index + 1)
                input_words[load_index] =
                    finite_pattern(load_index * 5 + salt);
        end
    endtask

    task automatic run_case(
        input string case_name,
        input integer row_count,
        input integer row_length,
        input logic expect_buffer
    );
        integer wait_cycles;
        integer saved_cycles;
        begin
            active_total_words = row_count * row_length;
            if (active_total_words > MAX_WORDS)
                $fatal(1, "%s exceeds MAX_WORDS", case_name);

            cfg_row_count = row_count;
            cfg_row_length = row_length;
            start = 1'b0;
            rst = 1'b1;
            repeat (4) @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;

            wait_cycles = 0;
            while (!(base_done_seen && opt_done_seen) &&
                   (wait_cycles < TIMEOUT_CYCLES)) begin
                @(posedge clk);
                wait_cycles = wait_cycles + 1;
            end
            @(negedge clk);

            if (!(base_done_seen && opt_done_seen))
                $fatal(1, "%s timeout base=%0b opt=%0b",
                       case_name, base_done_seen, opt_done_seen);
            if (base_config_error || opt_config_error)
                $fatal(1, "%s unexpected config_error base=%0b opt=%0b",
                       case_name, base_config_error, opt_config_error);
            if ((base_result_count != active_total_words) ||
                (opt_result_count != active_total_words))
                $fatal(1, "%s result count base=%0d opt=%0d expected=%0d",
                       case_name, base_result_count, opt_result_count,
                       active_total_words);

            for (check_index = 0; check_index < active_total_words;
                 check_index = check_index + 1) begin
                if (!base_seen[check_index] || !opt_seen[check_index])
                    $fatal(1, "%s missing output[%0d] base=%0b opt=%0b",
                           case_name, check_index, base_seen[check_index],
                           opt_seen[check_index]);
                if (base_outputs[check_index] !== opt_outputs[check_index])
                    $fatal(1, "%s output[%0d] base=%08x opt=%08x",
                           case_name, check_index,
                           base_outputs[check_index], opt_outputs[check_index]);
            end

            if ((base_read_max_count != active_total_words) ||
                (base_read_sum_count != active_total_words) ||
                (base_read_output_count != active_total_words))
                $fatal(1, "%s baseline reads=%0d/%0d/%0d",
                       case_name, base_read_max_count, base_read_sum_count,
                       base_read_output_count);

            if (expect_buffer) begin
                if ((opt_read_max_count != active_total_words) ||
                    (opt_read_sum_count != 0) ||
                    (opt_read_output_count != 0))
                    $fatal(1, "%s buffered reads=%0d/%0d/%0d",
                           case_name, opt_read_max_count, opt_read_sum_count,
                           opt_read_output_count);
                if (opt_done_cycle >= base_done_cycle)
                    $fatal(1, "%s did not improve cycles base=%0d opt=%0d",
                           case_name, base_done_cycle, opt_done_cycle);
            end else begin
                if ((opt_read_max_count != active_total_words) ||
                    (opt_read_sum_count != active_total_words) ||
                    (opt_read_output_count != active_total_words))
                    $fatal(1, "%s fallback reads=%0d/%0d/%0d",
                           case_name, opt_read_max_count, opt_read_sum_count,
                           opt_read_output_count);
                if (opt_done_cycle != base_done_cycle)
                    $fatal(1, "%s fallback cycles changed base=%0d opt=%0d",
                           case_name, base_done_cycle, opt_done_cycle);
            end

            saved_cycles = base_done_cycle - opt_done_cycle;
            $display(
                "SOFTMAX_BUFFER_AB_CASE_PASS name=%s rows=%0d length=%0d base_cycles=%0d opt_cycles=%0d saved_cycles=%0d base_reads=%0d opt_reads=%0d fallback=%0b",
                case_name,
                row_count,
                row_length,
                base_done_cycle,
                opt_done_cycle,
                saved_cycles,
                base_read_max_count + base_read_sum_count +
                    base_read_output_count,
                opt_read_max_count + opt_read_sum_count +
                    opt_read_output_count,
                !expect_buffer
            );
        end
    endtask

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        start = 1'b0;
        cfg_row_count = 32'd0;
        cfg_row_length = 32'd0;
        active_total_words = 0;

        load_case(394, 3);
        run_case("attention_two_rows_197", 2, 197, 1'b1);

        load_case(1000, 9);
        run_case("classifier_row_1000", 1, 1000, 1'b1);

        load_case(1024, 5);
        run_case("buffer_boundary_1024", 1, 1024, 1'b1);

        load_case(1025, 11);
        run_case("oversize_fallback_1025", 1, 1025, 1'b0);

        $display("SOFTMAX_ROW_EXP_BUFFER_AB_PASS");
        $finish;
    end

endmodule
