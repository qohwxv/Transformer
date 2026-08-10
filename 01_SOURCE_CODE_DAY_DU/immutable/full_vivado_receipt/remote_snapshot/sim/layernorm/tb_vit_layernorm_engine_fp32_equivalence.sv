`timescale 1ns/1ps

module tb_vit_layernorm_engine_fp32_equivalence;

    localparam integer MAX_WORDS = 128;
    localparam integer TIMEOUT_CYCLES = 500000;
    localparam logic [31:0] FP32_QNAN = 32'h7fc0_0000;

    logic clk;
    logic rst;
    logic start;
    logic [31:0] cfg_token_count;
    logic [31:0] cfg_hidden_size;
    logic [31:0] cfg_epsilon;
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
    logic [31:0] ref_gamma_data;
    logic [31:0] ref_beta_data;
    logic ref_result_valid;
    logic ref_result_ready;
    logic [31:0] ref_result_index;
    logic [31:0] ref_result_data;
    logic [31:0] ref_debug_mean;
    logic [31:0] ref_debug_variance;
    logic [31:0] ref_debug_inv_std;

    logic dut_busy;
    logic dut_done;
    logic dut_done_seen;
    logic dut_config_error;
    logic dut_data_request;
    logic dut_input_valid;
    logic [1:0] dut_data_pass;
    logic [31:0] dut_data_index;
    logic [31:0] dut_input_data;
    logic [31:0] dut_gamma_data;
    logic [31:0] dut_beta_data;
    logic dut_result_valid;
    logic dut_result_ready;
    logic [31:0] dut_result_index;
    logic [31:0] dut_result_data;
    logic [31:0] dut_debug_mean;
    logic [31:0] dut_debug_variance;
    logic [31:0] dut_debug_inv_std;

    logic [31:0] input_words [0:MAX_WORDS-1];
    logic [31:0] gamma_words [0:MAX_WORDS-1];
    logic [31:0] beta_words [0:MAX_WORDS-1];
    logic [31:0] ref_outputs [0:MAX_WORDS-1];
    logic [31:0] dut_outputs [0:MAX_WORDS-1];
    logic [31:0] ref_mean_by_output [0:MAX_WORDS-1];
    logic [31:0] dut_mean_by_output [0:MAX_WORDS-1];
    logic [31:0] ref_variance_by_output [0:MAX_WORDS-1];
    logic [31:0] dut_variance_by_output [0:MAX_WORDS-1];
    logic [31:0] ref_inv_std_by_output [0:MAX_WORDS-1];
    logic [31:0] dut_inv_std_by_output [0:MAX_WORDS-1];
    logic ref_seen [0:MAX_WORDS-1];
    logic dut_seen [0:MAX_WORDS-1];

    integer ref_result_count;
    integer dut_result_count;
    integer ref_read_mean_count;
    integer ref_read_variance_count;
    integer ref_read_affine_count;
    integer dut_read_mean_count;
    integer dut_read_variance_count;
    integer dut_read_affine_count;

    logic ref_stall_active;
    logic [31:0] ref_stall_index;
    logic [31:0] ref_stall_data;
    logic [31:0] ref_stall_mean;
    logic [31:0] ref_stall_variance;
    logic [31:0] ref_stall_inv_std;
    logic dut_stall_active;
    logic [31:0] dut_stall_index;
    logic [31:0] dut_stall_data;
    logic [31:0] dut_stall_mean;
    logic [31:0] dut_stall_variance;
    logic [31:0] dut_stall_inv_std;

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
                 (cycle_counter[2:0] != 3'd2));
            dut_input_valid =
                dut_data_request &&
                (!backpressure_enable ||
                 (cycle_counter[2:0] != 3'd6));

            ref_result_ready =
                !backpressure_enable ||
                (cycle_counter[1:0] != 2'd1);
            dut_result_ready =
                !backpressure_enable ||
                ((cycle_counter[2:0] != 3'd0) &&
                 (cycle_counter[2:0] != 3'd5));
        end

        ref_input_data = FP32_QNAN;
        ref_gamma_data = FP32_QNAN;
        ref_beta_data = FP32_QNAN;
        if (ref_data_index < active_total_words) begin
            ref_input_data = input_words[ref_data_index];
            ref_gamma_data =
                gamma_words[ref_data_index % cfg_hidden_size];
            ref_beta_data =
                beta_words[ref_data_index % cfg_hidden_size];
        end

        dut_input_data = FP32_QNAN;
        dut_gamma_data = FP32_QNAN;
        dut_beta_data = FP32_QNAN;
        if (dut_data_index < active_total_words) begin
            dut_input_data = input_words[dut_data_index];
            dut_gamma_data =
                gamma_words[dut_data_index % cfg_hidden_size];
            dut_beta_data =
                beta_words[dut_data_index % cfg_hidden_size];
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            cycle_counter              <= 32'd0;
            ref_done_seen              <= 1'b0;
            dut_done_seen              <= 1'b0;
            ref_result_count           <= 0;
            dut_result_count           <= 0;
            ref_read_mean_count        <= 0;
            ref_read_variance_count    <= 0;
            ref_read_affine_count      <= 0;
            dut_read_mean_count        <= 0;
            dut_read_variance_count    <= 0;
            dut_read_affine_count      <= 0;
            ref_stall_active           <= 1'b0;
            ref_stall_index            <= 32'd0;
            ref_stall_data             <= 32'd0;
            ref_stall_mean             <= 32'd0;
            ref_stall_variance         <= 32'd0;
            ref_stall_inv_std          <= 32'd0;
            dut_stall_active           <= 1'b0;
            dut_stall_index            <= 32'd0;
            dut_stall_data             <= 32'd0;
            dut_stall_mean             <= 32'd0;
            dut_stall_variance         <= 32'd0;
            dut_stall_inv_std          <= 32'd0;

            for (reset_index = 0; reset_index < MAX_WORDS;
                 reset_index = reset_index + 1) begin
                ref_outputs[reset_index]          = 32'd0;
                dut_outputs[reset_index]          = 32'd0;
                ref_mean_by_output[reset_index]   = 32'd0;
                dut_mean_by_output[reset_index]   = 32'd0;
                ref_variance_by_output[reset_index] = 32'd0;
                dut_variance_by_output[reset_index] = 32'd0;
                ref_inv_std_by_output[reset_index] = 32'd0;
                dut_inv_std_by_output[reset_index] = 32'd0;
                ref_seen[reset_index]             = 1'b0;
                dut_seen[reset_index]             = 1'b0;
            end
        end else begin
            cycle_counter <= cycle_counter + 1'b1;

            if (ref_done)
                ref_done_seen <= 1'b1;
            if (dut_done)
                dut_done_seen <= 1'b1;

            if (ref_input_valid) begin
                if (ref_data_index >= active_total_words)
                    $fatal(
                        1,
                        "Reference read index out of range: %0d",
                        ref_data_index
                    );
                case (ref_data_pass)
                    2'd0:
                        ref_read_mean_count <= ref_read_mean_count + 1;
                    2'd1:
                        ref_read_variance_count <=
                            ref_read_variance_count + 1;
                    2'd2:
                        ref_read_affine_count <=
                            ref_read_affine_count + 1;
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
                        dut_read_mean_count <= dut_read_mean_count + 1;
                    2'd1:
                        dut_read_variance_count <=
                            dut_read_variance_count + 1;
                    2'd2:
                        dut_read_affine_count <=
                            dut_read_affine_count + 1;
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
                    (ref_debug_mean !== ref_stall_mean) ||
                    (ref_debug_variance !== ref_stall_variance) ||
                    (ref_debug_inv_std !== ref_stall_inv_std))
                    $fatal(1, "Reference result changed under backpressure");
            end

            if (dut_stall_active) begin
                if (!dut_result_valid ||
                    (dut_result_index !== dut_stall_index) ||
                    (dut_result_data !== dut_stall_data) ||
                    (dut_debug_mean !== dut_stall_mean) ||
                    (dut_debug_variance !== dut_stall_variance) ||
                    (dut_debug_inv_std !== dut_stall_inv_std))
                    $fatal(1, "Production result changed under backpressure");
            end

            if (ref_result_valid && !ref_result_ready) begin
                ref_stall_active   <= 1'b1;
                ref_stall_index    <= ref_result_index;
                ref_stall_data     <= ref_result_data;
                ref_stall_mean     <= ref_debug_mean;
                ref_stall_variance <= ref_debug_variance;
                ref_stall_inv_std  <= ref_debug_inv_std;
            end else begin
                ref_stall_active <= 1'b0;
            end

            if (dut_result_valid && !dut_result_ready) begin
                dut_stall_active   <= 1'b1;
                dut_stall_index    <= dut_result_index;
                dut_stall_data     <= dut_result_data;
                dut_stall_mean     <= dut_debug_mean;
                dut_stall_variance <= dut_debug_variance;
                dut_stall_inv_std  <= dut_debug_inv_std;
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
                ref_mean_by_output[ref_result_index] <=
                    ref_debug_mean;
                ref_variance_by_output[ref_result_index] <=
                    ref_debug_variance;
                ref_inv_std_by_output[ref_result_index] <=
                    ref_debug_inv_std;
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
                dut_mean_by_output[dut_result_index] <=
                    dut_debug_mean;
                dut_variance_by_output[dut_result_index] <=
                    dut_debug_variance;
                dut_inv_std_by_output[dut_result_index] <=
                    dut_debug_inv_std;
                dut_seen[dut_result_index] <= 1'b1;
                dut_result_count <= dut_result_count + 1;
            end
        end
    end

    vit_layernorm_engine_fp32_reference u_reference (
        .clk             (clk),
        .rst             (rst),
        .start           (start),
        .cfg_token_count (cfg_token_count),
        .cfg_hidden_size (cfg_hidden_size),
        .cfg_epsilon     (cfg_epsilon),
        .busy            (ref_busy),
        .done            (ref_done),
        .config_error    (ref_config_error),
        .data_request    (ref_data_request),
        .input_valid     (ref_input_valid),
        .data_pass       (ref_data_pass),
        .data_index      (ref_data_index),
        .input_data      (ref_input_data),
        .gamma_data      (ref_gamma_data),
        .beta_data       (ref_beta_data),
        .result_valid    (ref_result_valid),
        .result_ready    (ref_result_ready),
        .result_index    (ref_result_index),
        .result_data     (ref_result_data),
        .debug_mean      (ref_debug_mean),
        .debug_variance  (ref_debug_variance),
        .debug_inv_std   (ref_debug_inv_std)
    );

    vit_layernorm_engine_fp32 u_production (
        .clk             (clk),
        .rst             (rst),
        .start           (start),
        .cfg_token_count (cfg_token_count),
        .cfg_hidden_size (cfg_hidden_size),
        .cfg_epsilon     (cfg_epsilon),
        .busy            (dut_busy),
        .done            (dut_done),
        .config_error    (dut_config_error),
        .data_request    (dut_data_request),
        .input_valid     (dut_input_valid),
        .data_pass       (dut_data_pass),
        .data_index      (dut_data_index),
        .input_data      (dut_input_data),
        .gamma_data      (dut_gamma_data),
        .beta_data       (dut_beta_data),
        .result_valid    (dut_result_valid),
        .result_ready    (dut_result_ready),
        .result_index    (dut_result_index),
        .result_data     (dut_result_data),
        .debug_mean      (dut_debug_mean),
        .debug_variance  (dut_debug_variance),
        .debug_inv_std   (dut_debug_inv_std)
    );

    function automatic logic [31:0] finite_pattern(
        input integer pattern_index
    );
        begin
            case (pattern_index % 16)
                0:  finite_pattern = 32'hc040_0000;
                1:  finite_pattern = 32'hc000_0000;
                2:  finite_pattern = 32'hbf80_0000;
                3:  finite_pattern = 32'hbf00_0000;
                4:  finite_pattern = 32'h8000_0000;
                5:  finite_pattern = 32'h0000_0000;
                6:  finite_pattern = 32'h3e80_0000;
                7:  finite_pattern = 32'h3f00_0000;
                8:  finite_pattern = 32'h3f80_0000;
                9:  finite_pattern = 32'h4000_0000;
                10: finite_pattern = 32'h4040_0000;
                11: finite_pattern = 32'h4080_0000;
                12: finite_pattern = 32'h3f40_0000;
                13: finite_pattern = 32'hbfc0_0000;
                14: finite_pattern = 32'h40a0_0000;
                default:
                    finite_pattern = 32'hc080_0000;
            endcase
        end
    endfunction

    function automatic logic [31:0] gamma_pattern(
        input integer pattern_index
    );
        begin
            case (pattern_index % 8)
                0: gamma_pattern = 32'h3f80_0000;
                1: gamma_pattern = 32'h3f00_0000;
                2: gamma_pattern = 32'h4000_0000;
                3: gamma_pattern = 32'hbf80_0000;
                4: gamma_pattern = 32'h0000_0000;
                5: gamma_pattern = 32'h3fc0_0000;
                6: gamma_pattern = 32'hbe80_0000;
                default:
                    gamma_pattern = 32'h4080_0000;
            endcase
        end
    endfunction

    function automatic logic [31:0] beta_pattern(
        input integer pattern_index
    );
        begin
            case (pattern_index % 8)
                0: beta_pattern = 32'h0000_0000;
                1: beta_pattern = 32'h3e80_0000;
                2: beta_pattern = 32'hbe80_0000;
                3: beta_pattern = 32'h3f80_0000;
                4: beta_pattern = 32'hbf80_0000;
                5: beta_pattern = 32'h8000_0000;
                6: beta_pattern = 32'h4000_0000;
                default:
                    beta_pattern = 32'hc000_0000;
            endcase
        end
    endfunction

    task automatic clear_inputs;
        begin
            for (load_index = 0; load_index < MAX_WORDS;
                 load_index = load_index + 1) begin
                input_words[load_index] = 32'd0;
                gamma_words[load_index] = 32'h3f80_0000;
                beta_words[load_index] = 32'd0;
            end
        end
    endtask

    task automatic load_single_case;
        begin
            clear_inputs();
            input_words[0] = 32'h4000_0000;
            gamma_words[0] = 32'h3f80_0000;
            beta_words[0] = 32'h0000_0000;
        end
    endtask

    task automatic load_normal_multi_token_case;
        integer token;
        integer channel;
        integer flat_index;
        begin
            clear_inputs();
            for (token = 0; token < 3; token = token + 1)
                for (channel = 0; channel < 4; channel = channel + 1) begin
                    flat_index = token * 4 + channel;
                    input_words[flat_index] =
                        finite_pattern(flat_index + token);
                    gamma_words[flat_index] = gamma_pattern(channel);
                    beta_words[flat_index] = beta_pattern(channel);
                end
        end
    endtask

    task automatic load_special_case;
        integer token;
        integer channel;
        integer flat_index;
        begin
            clear_inputs();

            input_words[0]  = 32'h0000_0000;
            input_words[1]  = 32'h8000_0000;
            input_words[2]  = 32'h0000_0001;
            input_words[3]  = 32'h8000_0001;
            input_words[4]  = 32'h0080_0000;
            input_words[5]  = 32'h8080_0000;

            input_words[6]  = 32'h7f7f_ffff;
            input_words[7]  = 32'hff7f_ffff;
            input_words[8]  = 32'h3f80_0000;
            input_words[9]  = 32'hbf80_0000;
            input_words[10] = 32'h4120_0000;
            input_words[11] = 32'hc120_0000;

            input_words[12] = 32'h7fc1_2345;
            input_words[13] = 32'hffc1_2345;
            input_words[14] = 32'h7f80_0001;
            input_words[15] = 32'h3f00_0000;
            input_words[16] = 32'hbf00_0000;
            input_words[17] = 32'h0000_0000;

            input_words[18] = 32'h7f80_0000;
            input_words[19] = 32'hff80_0000;
            input_words[20] = 32'h3f80_0000;
            input_words[21] = 32'hbf80_0000;
            input_words[22] = 32'h0000_0000;
            input_words[23] = 32'h8000_0000;

            input_words[24] = 32'h4040_0000;
            input_words[25] = 32'h4040_0000;
            input_words[26] = 32'h4040_0000;
            input_words[27] = 32'h4040_0000;
            input_words[28] = 32'h4040_0000;
            input_words[29] = 32'h4040_0000;

            for (token = 0; token < 5; token = token + 1)
                for (channel = 0; channel < 6; channel = channel + 1) begin
                    flat_index = token * 6 + channel;
                    case (channel)
                        0: gamma_words[flat_index] = 32'h3f80_0000;
                        1: gamma_words[flat_index] = 32'h0000_0000;
                        2: gamma_words[flat_index] = 32'hbf80_0000;
                        3: gamma_words[flat_index] = 32'h7f80_0000;
                        4: gamma_words[flat_index] = 32'h7fc1_2345;
                        default:
                            gamma_words[flat_index] = 32'h0000_0001;
                    endcase
                    case (channel)
                        0: beta_words[flat_index] = 32'h0000_0000;
                        1: beta_words[flat_index] = 32'h8000_0000;
                        2: beta_words[flat_index] = 32'h3f80_0000;
                        3: beta_words[flat_index] = 32'hbf80_0000;
                        4: beta_words[flat_index] = 32'h7f80_0000;
                        default:
                            beta_words[flat_index] = 32'h7fc1_2345;
                    endcase
                end
        end
    endtask

    task automatic load_negative_zero_epsilon_case;
        begin
            clear_inputs();
            for (load_index = 0; load_index < 6;
                 load_index = load_index + 1) begin
                input_words[load_index] =
                    finite_pattern(load_index + 7);
                gamma_words[load_index] =
                    gamma_pattern(load_index % 3);
                beta_words[load_index] =
                    beta_pattern(load_index % 3);
            end
        end
    endtask

    task automatic load_many_tokens_case;
        integer token;
        integer channel;
        integer flat_index;
        begin
            clear_inputs();
            for (token = 0; token < 9; token = token + 1)
                for (channel = 0; channel < 7; channel = channel + 1) begin
                    flat_index = token * 7 + channel;
                    input_words[flat_index] =
                        finite_pattern(flat_index + token * 3);
                    gamma_words[flat_index] =
                        gamma_pattern(channel);
                    beta_words[flat_index] =
                        beta_pattern(channel);
                end
        end
    endtask

    task automatic run_case(
        input string case_name,
        input integer token_count,
        input integer hidden_size,
        input logic [31:0] epsilon,
        input logic use_backpressure
    );
        integer case_cycle_count;
        begin
            if ((token_count * hidden_size) > MAX_WORDS)
                $fatal(1, "%s exceeds MAX_WORDS", case_name);

            active_total_words = token_count * hidden_size;
            cfg_token_count = token_count;
            cfg_hidden_size = hidden_size;
            cfg_epsilon = epsilon;
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

            if ((ref_read_mean_count != active_total_words) ||
                (ref_read_variance_count != active_total_words) ||
                (ref_read_affine_count != active_total_words) ||
                (dut_read_mean_count != active_total_words) ||
                (dut_read_variance_count != 0) ||
                (dut_read_affine_count != hidden_size))
                $fatal(
                    1,
                    "%s pass counts ref=%0d/%0d/%0d dut=%0d/%0d/%0d",
                    case_name,
                    ref_read_mean_count,
                    ref_read_variance_count,
                    ref_read_affine_count,
                    dut_read_mean_count,
                    dut_read_variance_count,
                    dut_read_affine_count
                );

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
                if (dut_mean_by_output[check_index] !==
                    ref_mean_by_output[check_index])
                    $fatal(
                        1,
                        "%s mean[%0d] ref=%08x dut=%08x",
                        case_name,
                        check_index,
                        ref_mean_by_output[check_index],
                        dut_mean_by_output[check_index]
                    );
                if (dut_variance_by_output[check_index] !==
                    ref_variance_by_output[check_index])
                    $fatal(
                        1,
                        "%s variance[%0d] ref=%08x dut=%08x",
                        case_name,
                        check_index,
                        ref_variance_by_output[check_index],
                        dut_variance_by_output[check_index]
                    );
                if (dut_inv_std_by_output[check_index] !==
                    ref_inv_std_by_output[check_index])
                    $fatal(
                        1,
                        "%s inv_std[%0d] ref=%08x dut=%08x",
                        case_name,
                        check_index,
                        ref_inv_std_by_output[check_index],
                        dut_inv_std_by_output[check_index]
                    );
            end

            $display(
                "LAYERNORM_EQUIVALENCE_CASE_PASS name=%s tokens=%0d hidden=%0d epsilon=%08x cycles=%0d backpressure=%0b",
                case_name,
                token_count,
                hidden_size,
                epsilon,
                case_cycle_count,
                use_backpressure
            );
        end
    endtask

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        start = 1'b0;
        cfg_token_count = 32'd0;
        cfg_hidden_size = 32'd0;
        cfg_epsilon = 32'd0;
        backpressure_enable = 1'b0;
        active_total_words = 0;

        load_single_case();
        run_case("single_element", 1, 1, 32'h3727_c5ac, 1'b0);

        load_normal_multi_token_case();
        run_case("normal_multi_token", 3, 4, 32'h3727_c5ac, 1'b1);

        load_special_case();
        run_case("special_fp", 5, 6, 32'h0000_0001, 1'b1);

        load_negative_zero_epsilon_case();
        run_case("negative_zero_epsilon", 2, 3, 32'h8000_0000, 1'b1);

        load_many_tokens_case();
        run_case("many_tokens", 9, 7, 32'h3727_c5ac, 1'b1);

        $display("LAYERNORM_ENGINE_BIT_EXACT_EQUIVALENCE_PASS");
        $finish;
    end

endmodule
