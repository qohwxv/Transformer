`timescale 1ns/1ps

module tb_vit_gemm_dual_mode_array;
    localparam integer ARRAY_ROWS = 8;
    localparam integer ARRAY_COLS = 2;
    localparam integer PE_LANES = 16;
    localparam integer FP16_STREAMS = 8;

    logic clk = 1'b0;
    logic rst = 1'b1;
    always #5 clk = ~clk;

    logic start;
    logic [31:0] cfg_m;
    logic [31:0] cfg_k;
    logic [31:0] cfg_n;
    logic [31:0] cfg_batch_count;
    logic cfg_bias_enable;
    logic cfg_fp16_enable;
    logic cfg_weight_fp16_packed2;
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
    logic [65:0] result_address_base_i;
    logic [7:0] result_generation_i;
    logic [65:0] result_address_seed;
    logic [7:0] result_generation_seed;
    logic gate2_metadata_mode;
    logic gate2_generation_poison;
    logic result_valid;
    logic result_ready;
    logic [65:0] result_address_base_o;
    logic [7:0] result_generation_o;
    logic [31:0] result_token_base;
    logic [31:0] result_output_base;
    logic [31:0] result_batch_index;
    logic [ARRAY_ROWS-1:0] result_token_mask;
    logic [ARRAY_COLS-1:0] result_output_mask;
    logic [ARRAY_ROWS*ARRAY_COLS*32-1:0] result_data;
    logic [31:0] mul_operand_a;
    logic [31:0] mul_operand_b;
    logic [31:0] mul_result;
    logic [31:0] add_operand_a;
    logic [31:0] add_operand_b;
    logic [31:0] add_result;
    logic profile_tile_step;
    logic [15:0] profile_valid_mac;
    logic [15:0] profile_tail_mac;
    logic profile_result_fifo_enqueue;
    logic profile_result_fifo_dequeue;
    logic profile_result_fifo_full_stall;
    logic [1:0] profile_result_fifo_occupancy;
    logic profile_compute_active;

    logic ref_start;
    logic ref_busy;
    logic ref_done;
    logic ref_config_error;
    logic ref_data_request;
    logic ref_data_valid;
    logic [31:0] ref_token_base;
    logic [31:0] ref_output_base;
    logic [31:0] ref_k_base;
    logic [31:0] ref_batch_index;
    logic ref_result_valid;
    logic [31:0] ref_result_token_base;
    logic [31:0] ref_result_output_base;
    logic [31:0] ref_result_batch_index;
    logic [ARRAY_ROWS-1:0] ref_result_token_mask;
    logic [ARRAY_COLS-1:0] ref_result_output_mask;
    logic [ARRAY_ROWS*ARRAY_COLS*32-1:0] ref_result_data;
    logic [31:0] ref_mul_operand_a;
    logic [31:0] ref_mul_operand_b;
    logic [31:0] ref_mul_result;
    logic [31:0] ref_add_operand_a;
    logic [31:0] ref_add_operand_b;
    logic [31:0] ref_add_result;
    logic ref_profile_tile_step;
    logic [15:0] ref_profile_valid_mac;
    logic [15:0] ref_profile_tail_mac;

    integer checks = 0;
    integer errors = 0;
    integer row;
    integer col;
    integer lane;
    integer tile_step_count;
    integer valid_mac_sum;
    integer tail_mac_sum;
    integer bridge_start_count;
    integer bridge_last_count;
    integer fifo_enqueue_count;
    integer fifo_dequeue_count;
    integer fifo_max_occupancy;
    integer fifo_full_stall_count;
    integer fifo_full_pop_push_count;
    integer compute_fifo_overlap_count;
    integer gate2_wait_cycles;
    integer gate2_result_count;
    integer gate2_log_index;
    integer gate2_log_row;
    logic [31:0] gate2_result_output_log [0:7];
    logic [65:0] gate2_result_address_log [0:7];
    logic [7:0] gate2_result_generation_log [0:7];
    logic [7:0] gate2_result_token_mask_log [0:7];
    logic [1:0] gate2_result_output_mask_log [0:7];
    logic [511:0] gate2_result_data_log [0:7];
    integer fifo_enqueue_before_poison;
    integer fifo_dequeue_before_poison;
    logic legacy_compare_active;
    logic poison_bias;
    logic packed_lane_probe;
    logic final_only_bias;

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (!condition) begin
                errors = errors + 1;
                $display("FAIL: %s", message);
            end
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

    function automatic logic [31:0] weight_for_column(
        input logic [31:0] column
    );
        begin
            case (column)
                32'd0: weight_for_column = 32'h3f80_0000; // 1.0
                32'd1: weight_for_column = 32'h4000_0000; // 2.0
                default: weight_for_column = 32'h4040_0000; // 3.0
            endcase
        end
    endfunction

    function automatic logic [15:0] fp16_weight_for_column(
        input logic [31:0] column
    );
        begin
            case (column)
                32'd0: fp16_weight_for_column = 16'h3c00; // 1.0
                32'd1: fp16_weight_for_column = 16'h4000; // 2.0
                default: fp16_weight_for_column = 16'h4200; // 3.0
            endcase
        end
    endfunction

    always_comb begin
        activation_data = '0;
        weight_data = '0;
        bias_data = '0;
        for (row = 0; row < ARRAY_ROWS; row = row + 1)
            for (lane = 0; lane < PE_LANES; lane = lane + 1)
                if (packed_lane_probe && (lane != 7))
                    activation_data[(row*PE_LANES+lane)*32 +: 32] =
                        32'd0;
                else
                    activation_data[(row*PE_LANES+lane)*32 +: 32] =
                        32'h3f80_0000;
        if (cfg_weight_fp16_packed2) begin
            for (lane = 0; lane < PE_LANES; lane = lane + 1) begin
                if (packed_lane_probe && (lane != 7)) begin
                    weight_data[lane*32 +: 16] = 16'h4400; // 4.0
                    weight_data[lane*32+16 +: 16] = 16'h4800; // 8.0
                end else begin
                    weight_data[lane*32 +: 16] =
                        fp16_weight_for_column(output_base);
                    weight_data[lane*32+16 +: 16] =
                        fp16_weight_for_column(output_base + 1'b1);
                end
                // The direct packed seam must ignore the upper 512 bits.
                weight_data[(PE_LANES+lane)*32 +: 32] = 32'h7fc0_0000;
            end
        end else begin
            for (col = 0; col < ARRAY_COLS; col = col + 1)
                for (lane = 0; lane < PE_LANES; lane = lane + 1)
                    weight_data[(col*PE_LANES+lane)*32 +: 32] =
                        weight_for_column(output_base + col);
        end
        if (final_only_bias && (({1'b0, k_base} + 33'd16) >=
                                {1'b0, cfg_k})) begin
            bias_data[31:0] = 32'h3f80_0000;  // +1.0, column 0
            bias_data[63:32] = 32'h4000_0000; // +2.0, column 1
        end
        if (poison_bias)
            bias_data[31:0] = 32'h7f80_0000;
    end

    always_comb begin
        if (gate2_metadata_mode)
            result_address_base_i = result_address_seed +
                {18'd0, batch_index, 16'd0} +
                {26'd0, token_base, 8'd0} +
                {34'd0, output_base};
        else
            result_address_base_i = result_address_seed;
        result_generation_i = gate2_generation_poison ?
            ~result_generation_seed : result_generation_seed;
    end

    assign data_valid = data_request;
    assign ref_data_valid = ref_data_request;

    vit_fp32_mul_comb_nodsp u_dut_mul (
        .a(mul_operand_a), .b(mul_operand_b), .result(mul_result)
    );
    vit_fp32_add_comb u_dut_add (
        .a(add_operand_a), .b(add_operand_b), .result(add_result)
    );
    vit_fp32_mul_comb_nodsp u_ref_mul (
        .a(ref_mul_operand_a), .b(ref_mul_operand_b), .result(ref_mul_result)
    );
    vit_fp32_add_comb u_ref_add (
        .a(ref_add_operand_a), .b(ref_add_operand_b), .result(ref_add_result)
    );

    vit_gemm_dual_mode_array #(
        .ARRAY_ROWS(ARRAY_ROWS), .ARRAY_COLS(ARRAY_COLS),
        .PE_LANES(PE_LANES), .FP16_STREAMS(FP16_STREAMS),
        .USE_EXTERNAL_MUL(1),
        .USE_EXTERNAL_ADD(1)
    ) u_dut (
        .clk(clk), .rst(rst), .start(start), .cfg_m(cfg_m), .cfg_k(cfg_k),
        .cfg_n(cfg_n), .cfg_batch_count(cfg_batch_count),
        .cfg_bias_enable(cfg_bias_enable), .cfg_fp16_enable(cfg_fp16_enable),
        .cfg_weight_fp16_packed2(cfg_weight_fp16_packed2),
        .busy(busy), .done(done), .config_error(config_error),
        .data_request(data_request), .data_valid(data_valid),
        .token_base(token_base), .output_base(output_base), .k_base(k_base),
        .batch_index(batch_index), .activation_data(activation_data),
        .weight_data(weight_data), .bias_data(bias_data),
        .result_address_base_i(result_address_base_i),
        .result_generation_i(result_generation_i),
        .result_valid(result_valid), .result_ready(result_ready),
        .result_address_base_o(result_address_base_o),
        .result_generation_o(result_generation_o),
        .result_token_base(result_token_base),
        .result_output_base(result_output_base),
        .result_batch_index(result_batch_index),
        .result_token_mask(result_token_mask),
        .result_output_mask(result_output_mask), .result_data(result_data),
        .mul_operand_a(mul_operand_a), .mul_operand_b(mul_operand_b),
        .external_mul_result(mul_result), .add_operand_a(add_operand_a),
        .add_operand_b(add_operand_b), .external_add_result(add_result),
        .profile_gemm_tile_step_o(profile_tile_step),
        .profile_valid_mac_delta_o(profile_valid_mac),
        .profile_tail_mac_delta_o(profile_tail_mac),
        .profile_m7_compute_active_o(profile_compute_active),
        .profile_m7_result_fifo_enqueue_o(
            profile_result_fifo_enqueue
        ),
        .profile_m7_result_fifo_dequeue_o(
            profile_result_fifo_dequeue
        ),
        .profile_m7_result_fifo_full_stall_o(
            profile_result_fifo_full_stall
        ),
        .profile_m7_result_fifo_occupancy_o(
            profile_result_fifo_occupancy
        )
    );

    vit_gemm_tree_array #(
        .ARRAY_ROWS(ARRAY_ROWS), .ARRAY_COLS(ARRAY_COLS),
        .PE_LANES(PE_LANES), .USE_EXTERNAL_MUL(1),
        .USE_EXTERNAL_ADD(1)
    ) u_reference (
        .clk(clk), .rst(rst), .start(ref_start), .cfg_m(cfg_m), .cfg_k(cfg_k),
        .cfg_n(cfg_n), .cfg_batch_count(cfg_batch_count),
        .cfg_bias_enable(cfg_bias_enable), .busy(ref_busy), .done(ref_done),
        .config_error(ref_config_error), .data_request(ref_data_request),
        .data_valid(ref_data_valid), .token_base(ref_token_base),
        .output_base(ref_output_base), .k_base(ref_k_base),
        .batch_index(ref_batch_index), .activation_data(activation_data),
        .weight_data(weight_data), .bias_data(bias_data),
        .result_valid(ref_result_valid), .result_ready(result_ready),
        .result_token_base(ref_result_token_base),
        .result_output_base(ref_result_output_base),
        .result_batch_index(ref_result_batch_index),
        .result_token_mask(ref_result_token_mask),
        .result_output_mask(ref_result_output_mask),
        .result_data(ref_result_data), .mul_operand_a(ref_mul_operand_a),
        .mul_operand_b(ref_mul_operand_b),
        .external_mul_result(ref_mul_result),
        .add_operand_a(ref_add_operand_a), .add_operand_b(ref_add_operand_b),
        .external_add_result(ref_add_result),
        .profile_gemm_tile_step_o(ref_profile_tile_step),
        .profile_valid_mac_delta_o(ref_profile_valid_mac),
        .profile_tail_mac_delta_o(ref_profile_tail_mac)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            tile_step_count <= 0;
            valid_mac_sum <= 0;
            tail_mac_sum <= 0;
            bridge_start_count <= 0;
            bridge_last_count <= 0;
            fifo_enqueue_count <= 0;
            fifo_dequeue_count <= 0;
            fifo_max_occupancy <= 0;
            fifo_full_stall_count <= 0;
            fifo_full_pop_push_count <= 0;
            compute_fifo_overlap_count <= 0;
            gate2_result_count <= 0;
            gate2_result_output_log[0] <= 32'd0;
            gate2_result_output_log[1] <= 32'd0;
            gate2_result_output_log[2] <= 32'd0;
            gate2_result_output_log[3] <= 32'd0;
            gate2_result_address_log[0] <= 66'd0;
            gate2_result_address_log[1] <= 66'd0;
            gate2_result_address_log[2] <= 66'd0;
            gate2_result_address_log[3] <= 66'd0;
            gate2_result_generation_log[0] <= 8'd0;
            gate2_result_generation_log[1] <= 8'd0;
            gate2_result_generation_log[2] <= 8'd0;
            gate2_result_generation_log[3] <= 8'd0;
            gate2_result_token_mask_log[0] <= '0;
            gate2_result_token_mask_log[1] <= '0;
            gate2_result_token_mask_log[2] <= '0;
            gate2_result_token_mask_log[3] <= '0;
            gate2_result_output_mask_log[0] <= '0;
            gate2_result_output_mask_log[1] <= '0;
            gate2_result_output_mask_log[2] <= '0;
            gate2_result_output_mask_log[3] <= '0;
            gate2_result_data_log[0] <= '0;
            gate2_result_data_log[1] <= '0;
            gate2_result_data_log[2] <= '0;
            gate2_result_data_log[3] <= '0;
        end else begin
            if (profile_tile_step) begin
                tile_step_count <= tile_step_count + 1;
                valid_mac_sum <= valid_mac_sum + profile_valid_mac;
                tail_mac_sum <= tail_mac_sum + profile_tail_mac;
            end
            if (u_dut.gen_fp16.u_fp16.u_stream_array.start_valid_i &&
                u_dut.gen_fp16.u_fp16.u_stream_array.start_ready_o)
                bridge_start_count <= bridge_start_count + 1;
            if (u_dut.gen_fp16.u_fp16.u_stream_array.chunk_valid_i &&
                u_dut.gen_fp16.u_fp16.u_stream_array.chunk_ready_o &&
                u_dut.gen_fp16.u_fp16.u_stream_array.chunk_last_i)
                bridge_last_count <= bridge_last_count + 1;
            if (profile_result_fifo_enqueue)
                fifo_enqueue_count <= fifo_enqueue_count + 1;
            if (profile_result_fifo_dequeue)
                fifo_dequeue_count <= fifo_dequeue_count + 1;
            if (profile_result_fifo_occupancy > fifo_max_occupancy)
                fifo_max_occupancy <= profile_result_fifo_occupancy;
            if (profile_result_fifo_full_stall)
                fifo_full_stall_count <= fifo_full_stall_count + 1;
            if (profile_result_fifo_enqueue &&
                profile_result_fifo_dequeue &&
                (profile_result_fifo_occupancy == 2))
                fifo_full_pop_push_count <= fifo_full_pop_push_count + 1;
            if (profile_compute_active &&
                (profile_result_fifo_occupancy != 0))
                compute_fifo_overlap_count <= compute_fifo_overlap_count + 1;
            if (gate2_metadata_mode && result_valid && result_ready) begin
                check(gate2_result_count < 8,
                      "dual-mode Gate2 result log capacity");
                if (gate2_result_count < 8) begin
                    gate2_result_output_log[gate2_result_count] <=
                        result_output_base;
                    gate2_result_address_log[gate2_result_count] <=
                        result_address_base_o;
                    gate2_result_generation_log[gate2_result_count] <=
                        result_generation_o;
                    gate2_result_token_mask_log[gate2_result_count] <=
                        result_token_mask;
                    gate2_result_output_mask_log[gate2_result_count] <=
                        result_output_mask;
                    gate2_result_data_log[gate2_result_count] <= result_data;
                end
                gate2_result_count <= gate2_result_count + 1;
            end
            check(profile_result_fifo_occupancy <= 2,
                  "dual-mode result FIFO occupancy bound");
            if (profile_result_fifo_enqueue ||
                profile_result_fifo_dequeue ||
                (profile_result_fifo_occupancy != 0))
                check(u_dut.mode_fp16_q && cfg_weight_fp16_packed2,
                      "FIFO activity remains packed-FP16 only");

            if (legacy_compare_active) begin
                check(busy === ref_busy, "legacy busy cycle equivalence");
                check(done === ref_done, "legacy done cycle equivalence");
                check(config_error === ref_config_error,
                      "legacy config-error equivalence");
                check(data_request === ref_data_request,
                      "legacy request cycle equivalence");
                check(token_base === ref_token_base,
                      "legacy token coordinate equivalence");
                check(output_base === ref_output_base,
                      "legacy output coordinate equivalence");
                check(k_base === ref_k_base, "legacy K coordinate equivalence");
                check(!profile_result_fifo_enqueue &&
                      !profile_result_fifo_dequeue &&
                      !profile_result_fifo_full_stall &&
                      (profile_result_fifo_occupancy == 0),
                      "legacy path bypasses result FIFO exactly");
                check(result_valid === ref_result_valid,
                      "legacy result-valid equivalence");
                if (result_valid) begin
                    check(result_address_base_o === result_address_base_i,
                          "legacy result address pass-through");
                    check(result_generation_o === result_generation_i,
                          "legacy result generation pass-through");
                    check(result_token_mask === ref_result_token_mask,
                          "legacy token mask equivalence");
                    check(result_output_mask === ref_result_output_mask,
                          "legacy output mask equivalence");
                    check(result_data === ref_result_data,
                          "legacy result data equivalence");
                end
            end
        end
    end

    task automatic expect_fp16_tile(
        input logic [31:0] expected_output_base,
        input logic [7:0] expected_token_mask,
        input logic [1:0] expected_output_mask,
        input logic [31:0] expected_col0,
        input logic [31:0] expected_col1,
        input integer stall_cycles
    );
        integer stall;
        integer pass;
        integer pass_count;
        integer rr;
        logic [511:0] held_data;
        logic [65:0] held_address;
        logic [7:0] held_generation;
        logic [31:0] held_token;
        logic [31:0] held_output;
        logic [31:0] held_batch;
        begin
            pass_count = expected_output_mask[1] ? 2 : 1;
            for (pass = 0; pass < pass_count; pass = pass + 1) begin
                wait (result_valid === 1'b1);
                #1;
                check(result_output_base == expected_output_base,
                      "FP16 output-base metadata");
                check(result_address_base_o == result_address_base_i,
                      "FP16 result absolute-address metadata");
                check(result_generation_o == result_generation_i,
                      "FP16 result generation metadata");
                check(result_token_mask == expected_token_mask,
                      "FP16 token tail mask");
                check(result_output_mask == (pass ? 2'b10 : 2'b01),
                      "FP16 S8 partial output mask/order");
                held_data = result_data;
                held_address = result_address_base_o;
                held_generation = result_generation_o;
                held_token = result_token_base;
                held_output = result_output_base;
                held_batch = result_batch_index;
                for (rr = 0; rr < ARRAY_ROWS; rr = rr + 1) begin
                    if (expected_token_mask[rr] && !pass)
                        check(result_data[(rr*2)*32 +: 32] == expected_col0,
                              "FP16 S8 column-0 result");
                    if (expected_token_mask[rr] && pass)
                        check(result_data[(rr*2+1)*32 +: 32] == expected_col1,
                              "FP16 S8 column-1 result");
                end
                for (stall = 0; stall < stall_cycles; stall = stall + 1) begin
                    @(posedge clk);
                    #1;
                    check(result_valid, "FP16 result held under backpressure");
                    check(result_data === held_data,
                          "FP16 result data stable under backpressure");
                    check(result_address_base_o === held_address,
                          "FP16 result address stable under backpressure");
                    check(result_generation_o === held_generation,
                          "FP16 result generation stable under backpressure");
                    check(result_token_base === held_token,
                          "FP16 result token stable under backpressure");
                    check(result_output_base === held_output,
                          "FP16 result output stable under backpressure");
                    check(result_batch_index === held_batch,
                          "FP16 result batch stable under backpressure");
                end
                result_ready = 1'b1;
                @(posedge clk);
                #1;
                result_ready = 1'b0;
            end
        end
    endtask

    task automatic run_final_panel_bias_case(
        input logic packed2,
        input logic [31:0] reduction_k,
        input logic [31:0] expected_col0,
        input logic [31:0] expected_col1
    );
        begin
            wait (!busy && !done);
            cfg_m = 32'd8;
            cfg_k = reduction_k;
            cfg_n = 32'd2;
            cfg_batch_count = 32'd1;
            cfg_bias_enable = 1'b1;
            cfg_fp16_enable = 1'b1;
            cfg_weight_fp16_packed2 = packed2;
            final_only_bias = 1'b1;
            result_ready = 1'b0;
            pulse_start();
            expect_fp16_tile(32'd0, 8'hff, 2'b11,
                             expected_col0, expected_col1, 3);
            wait (done);
            #1;
            check(!config_error,
                  "final-panel FP16 bias command completes cleanly");
            final_only_bias = 1'b0;
            // Leave the one-cycle DONE state before the next directed case.
            @(posedge clk);
            #1;
            check(!busy && !done,
                  "final-panel bias case returns to idle");
        end
    endtask

    initial begin
        start = 1'b0;
        ref_start = 1'b0;
        cfg_m = 32'd0;
        cfg_k = 32'd0;
        cfg_n = 32'd0;
        cfg_batch_count = 32'd0;
        cfg_bias_enable = 1'b0;
        cfg_fp16_enable = 1'b0;
        cfg_weight_fp16_packed2 = 1'b0;
        result_address_seed = 66'h2_3456_789a;
        result_generation_seed = 8'hff;
        gate2_metadata_mode = 1'b0;
        gate2_generation_poison = 1'b0;
        result_ready = 1'b0;
        legacy_compare_active = 1'b0;
        poison_bias = 1'b0;
        packed_lane_probe = 1'b0;
        final_only_bias = 1'b0;

        repeat (4) @(posedge clk);
        rst = 1'b0;

        // Exact cycle/data equivalence of selector mode 0 with the original
        // promoted M5 FP32 tree.
        cfg_m = 32'd8;
        cfg_k = 32'd16;
        cfg_n = 32'd2;
        cfg_batch_count = 32'd1;
        cfg_bias_enable = 1'b0;
        cfg_fp16_enable = 1'b0;
        result_ready = 1'b1;
        legacy_compare_active = 1'b1;
        @(negedge clk);
        start = 1'b1;
        ref_start = 1'b1;
        @(negedge clk);
        start = 1'b0;
        ref_start = 1'b0;
        wait (done && ref_done);
        @(posedge clk);
        legacy_compare_active = 1'b0;
        check(!config_error && !ref_config_error,
              "legacy compatibility command completes cleanly");
        check((fifo_enqueue_count == 0) && (fifo_dequeue_count == 0) &&
              (fifo_max_occupancy == 0),
              "legacy command has no result-FIFO activity");

        // Packed storage is only legal when the FP16 compute path is selected.
        // The selector must reject it without launching either datapath.
        legacy_compare_active = 1'b0;
        cfg_weight_fp16_packed2 = 1'b1;
        pulse_start();
        wait (done);
        #1;
        check(config_error, "packed B without FP16 fails closed");
        check(!data_request, "illegal packed mode launches no data request");
        check(!result_valid, "illegal packed mode produces no result");
        @(posedge clk);
        #1;
        check(!done && !busy,
              "illegal packed-mode rejection is a bounded one-cycle pulse");
        check((fifo_enqueue_count == 0) && (fifo_dequeue_count == 0),
              "illegal packed mode has no result-FIFO activity");

        // Clear only test-local/DUT state so the following profile assertions
        // describe the FP16 case rather than the preceding equivalence run.
        @(negedge clk);
        rst = 1'b1;
        @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // K16 primary geometry and explicit output backpressure.
        result_ready = 1'b0;
        cfg_fp16_enable = 1'b1;
        cfg_weight_fp16_packed2 = 1'b0;
        cfg_m = 32'd8;
        cfg_k = 32'd16;
        cfg_n = 32'd2;
        pulse_start();
        expect_fp16_tile(32'd0, 8'hff, 2'b11,
                         32'h4180_0000, 32'h4200_0000, 3);
        wait (done);
        #1;
        check(!config_error, "K16 FP16 command clean");
        check(tile_step_count == 2, "K16 has two S8 column chunks");
        check(valid_mac_sum == 256, "K16 valid MAC accounting");
        check(tail_mac_sum == 0, "K16 zero tail MACs");
        check(bridge_start_count == 2, "K16 has two S8 bridge starts");
        check(bridge_last_count == 2, "K16 has one TLAST per S8 pass");
        check((fifo_enqueue_count == 0) && (fifo_dequeue_count == 0) &&
              (fifo_max_occupancy == 0),
              "non-packed FP16 path bypasses result FIFO exactly");

        // Reset clears all in-flight ownership/state, then a new command can
        // start.  Assert reset after one of two K chunks was accepted.
        @(posedge clk);
        cfg_k = 32'd32;
        pulse_start();
        wait (profile_tile_step);
        @(negedge clk);
        rst = 1'b1;
        @(posedge clk);
        #1;
        check(!busy && !done && !result_valid && !config_error,
              "reset clears FP16 in-flight command");
        @(negedge clk);
        rst = 1'b0;

        // A single active activation lane distinguishes lane 7 from every
        // other packed word and checks low/high-half column ordering directly.
        cfg_m = 32'd8;
        cfg_k = 32'd16;
        cfg_n = 32'd2;
        cfg_batch_count = 32'd1;
        cfg_bias_enable = 1'b0;
        cfg_weight_fp16_packed2 = 1'b1;
        packed_lane_probe = 1'b1;
        result_ready = 1'b0;
        pulse_start();
        expect_fp16_tile(32'd0, 8'hff, 2'b11,
                         32'h3f80_0000, 32'h4000_0000, 1);
        wait (done);
        #1;
        check(!config_error, "packed lane/column probe completes cleanly");
        check((fifo_enqueue_count == 2) && (fifo_dequeue_count == 2) &&
              (fifo_max_occupancy <= 2),
              "packed lane probe drains both S8 column entries before DONE");

        // Reset test-local profile totals before the larger packed tail case.
        @(negedge clk);
        rst = 1'b1;
        @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        packed_lane_probe = 1'b0;

        // Direct packed-v3 B: multi-chunk K tail plus M/N tails.  Two output
        // tiles, two chunks each.  All-one A and packed FP16 column weights
        // 1/2/3 give exact 18/36/54 while poisoned upper-half words prove that
        // only the defined lower 512-bit packed payload is consumed.
        cfg_m = 32'd5;
        cfg_k = 32'd18;
        cfg_n = 32'd3;
        cfg_batch_count = 32'd1;
        cfg_bias_enable = 1'b0;
        cfg_weight_fp16_packed2 = 1'b1;
        result_ready = 1'b0;
        pulse_start();
        expect_fp16_tile(32'd0, 8'h1f, 2'b11,
                         32'h4190_0000, 32'h4210_0000, 1);
        expect_fp16_tile(32'd2, 8'h1f, 2'b01,
                         32'h4258_0000, 32'd0, 2);
        wait (done);
        #1;
        check(!config_error, "K18/tail packed-FP16 command clean");
        check(tile_step_count == 6, "K18 chunks cover three S8 column passes");
        check(valid_mac_sum == 270, "K18/M5/N3 valid MAC accounting");
        check(tail_mac_sum == 498, "K18/M5/N3 S8 tail MAC accounting");
        check(bridge_start_count == 3,
              "one bridge start spans K chunks per physical column pass");
        check(bridge_last_count == 3,
              "TLAST occurs once per physical S8 column pass");
        check((fifo_enqueue_count == 3) && (fifo_dequeue_count == 3) &&
              (fifo_max_occupancy <= 2) &&
              (profile_result_fifo_occupancy == 0),
              "packed tail command drains every serialized FIFO entry");

        // Gate-2 production-selector proof.  Four packed result tiles fill
        // both FIFO slots and hold a later bridge result.  Address metadata
        // follows the live tile while generation is poisoned after the first
        // enqueue; every dequeued result must nevertheless preserve the
        // address/generation captured for its own command/tile.  Releasing
        // ready from the full condition must exercise atomic pop+push and
        // drain every entry in order before DONE.
        @(negedge clk);
        rst = 1'b1;
        @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        cfg_m = 32'd8;
        cfg_k = 32'd17;
        cfg_n = 32'd7;
        cfg_batch_count = 32'd1;
        cfg_bias_enable = 1'b0;
        cfg_fp16_enable = 1'b1;
        cfg_weight_fp16_packed2 = 1'b1;
        gate2_metadata_mode = 1'b1;
        gate2_generation_poison = 1'b0;
        result_ready = 1'b0;
        pulse_start();
        wait (fifo_enqueue_count == 1);
        @(negedge clk);
        gate2_generation_poison = 1'b1;
        gate2_wait_cycles = 0;
        while (!((profile_result_fifo_occupancy == 2) &&
                 profile_result_fifo_full_stall) &&
               (gate2_wait_cycles < 500000)) begin
            @(posedge clk);
            gate2_wait_cycles = gate2_wait_cycles + 1;
        end
        check(profile_result_fifo_occupancy == 2,
              "dual-mode Gate2 FIFO reaches depth two");
        check(profile_result_fifo_full_stall,
              "dual-mode Gate2 third result stalls on full FIFO");
        check(result_valid && !result_ready,
              "dual-mode Gate2 FIFO head visible under backpressure");
        check(result_address_base_o == result_address_seed,
              "dual-mode Gate2 FIFO head retains tile-zero address");
        check(result_address_base_o != result_address_base_i,
              "dual-mode Gate2 queued address differs from live tile");
        check(result_generation_o == result_generation_seed,
              "dual-mode Gate2 FIFO head retains command generation");
        check(result_generation_o != result_generation_i,
              "dual-mode Gate2 queued generation ignores live poison");
        @(negedge clk);
        result_ready = 1'b1;
        wait (done);
        #1;
        check(!config_error, "dual-mode Gate2 command completes cleanly");
        check((fifo_enqueue_count == 7) && (fifo_dequeue_count == 7),
              "dual-mode Gate2 enqueues/dequeues all seven S8 results");
        check(fifo_max_occupancy == 2,
              "dual-mode Gate2 max FIFO occupancy is two");
        check(fifo_full_stall_count > 0,
              "dual-mode Gate2 counts full-FIFO backpressure");
        check(fifo_full_pop_push_count > 0,
              "dual-mode Gate2 exercises full simultaneous pop/push");
        check(compute_fifo_overlap_count > 0,
              "dual-mode Gate2 computes with queued store work");
        check((profile_result_fifo_occupancy == 0) && !result_valid &&
              !data_request && !profile_compute_active,
              "dual-mode Gate2 DONE follows final FIFO drain");
        check(gate2_result_count == 7,
              "dual-mode Gate2 logs every dequeued result exactly once");
        for (gate2_log_index = 0; gate2_log_index < 7;
             gate2_log_index = gate2_log_index + 1) begin
            check(gate2_result_output_log[gate2_log_index] ==
                  ((gate2_log_index / 2) * 2),
                  "dual-mode Gate2 dequeue output order");
            check(gate2_result_address_log[gate2_log_index] ==
                  (result_address_seed + ((gate2_log_index / 2) * 2)),
                  "dual-mode Gate2 per-tile captured address order");
            check(gate2_result_generation_log[gate2_log_index] ==
                  result_generation_seed,
                  "dual-mode Gate2 captured command generation");
            check(gate2_result_token_mask_log[gate2_log_index] == 8'hff,
                  "dual-mode Gate2 token mask order");
            if ((gate2_log_index & 1) == 0)
                check(gate2_result_output_mask_log[gate2_log_index] ==
                      2'b01,
                      "dual-mode Gate2 S8 column-zero mask");
            else
                check(gate2_result_output_mask_log[gate2_log_index] ==
                      2'b10,
                      "dual-mode Gate2 S8 column-one mask");
            for (gate2_log_row = 0; gate2_log_row < ARRAY_ROWS;
                 gate2_log_row = gate2_log_row + 1) begin
                if (gate2_log_index < 2) begin
                    if ((gate2_log_index & 1) == 0)
                    check(gate2_result_data_log[gate2_log_index]
                              [(gate2_log_row*2)*32 +: 32] ==
                          32'h4188_0000,
                          "dual-mode Gate2 tile-zero column-zero data");
                    else
                    check(gate2_result_data_log[gate2_log_index]
                              [(gate2_log_row*2+1)*32 +: 32] ==
                          32'h4208_0000,
                          "dual-mode Gate2 tile-zero column-one data");
                end else begin
                    if ((gate2_log_index & 1) == 0)
                    check(gate2_result_data_log[gate2_log_index]
                              [(gate2_log_row*2)*32 +: 32] ==
                          32'h424c_0000,
                          "dual-mode Gate2 later-tile column-zero data");
                    else
                        check(gate2_result_data_log[gate2_log_index]
                                  [(gate2_log_row*2+1)*32 +: 32] ==
                              32'h424c_0000,
                              "dual-mode Gate2 later-tile column-one data");
                end
            end
        end
        $display(
            "M7_S8_DUAL_GATE2 results=%0d enq=%0d deq=%0d max=%0d full_stall=%0d full_pop_push=%0d compute_fifo=%0d metadata_order=PASS",
            gate2_result_count, fifo_enqueue_count, fifo_dequeue_count,
            fifo_max_occupancy, fifo_full_stall_count,
            fifo_full_pop_push_count, compute_fifo_overlap_count
        );
        gate2_metadata_mode = 1'b0;
        gate2_generation_poison = 1'b0;
        result_ready = 1'b0;

        // Production supplies bias only with the final K16 panel.  Exercise
        // both the packed mode-3 seam and the non-packed mode-5 compatibility
        // seam across exact/tail/maximum supported reductions.  These cases
        // permanently guard the K>16 bias-refresh fix in the stream array.
        run_final_panel_bias_case(1'b1, 32'd17,
                                  32'h4190_0000, 32'h4210_0000);
        run_final_panel_bias_case(1'b1, 32'd32,
                                  32'h4204_0000, 32'h4284_0000);
        run_final_panel_bias_case(1'b1, 32'd33,
                                  32'h4208_0000, 32'h4288_0000);
        run_final_panel_bias_case(1'b1, 32'd3072,
                                  32'h4540_1000, 32'h45c0_1000);
        run_final_panel_bias_case(1'b0, 32'd17,
                                  32'h4190_0000, 32'h4210_0000);
        run_final_panel_bias_case(1'b0, 32'd32,
                                  32'h4204_0000, 32'h4284_0000);
        run_final_panel_bias_case(1'b0, 32'd33,
                                  32'h4208_0000, 32'h4288_0000);
        run_final_panel_bias_case(1'b0, 32'd3072,
                                  32'h4540_1000, 32'h45c0_1000);

        // Bias-created infinity is consumed internally and reported as an
        // error.  It must never reach the memory frontend as result_valid.
        @(posedge clk);
        fifo_enqueue_before_poison = fifo_enqueue_count;
        fifo_dequeue_before_poison = fifo_dequeue_count;
        cfg_m = 32'd8;
        cfg_k = 32'd16;
        cfg_n = 32'd2;
        cfg_bias_enable = 1'b1;
        poison_bias = 1'b1;
        result_ready = 1'b1;
        pulse_start();
        wait (done);
        #1;
        check(config_error, "bias overflow fails command closed");
        check(!result_valid, "poisoned result is never externally valid");
        check((fifo_enqueue_count == fifo_enqueue_before_poison) &&
              (fifo_dequeue_count == fifo_dequeue_before_poison) &&
              (profile_result_fifo_occupancy == 0),
              "poisoned result does not enter the result FIFO");
        poison_bias = 1'b0;

        if (errors == 0)
            $display("PASS M7 dual-mode production GEMM checks=%0d", checks);
        else
            $fatal(1, "FAIL M7 dual-mode production GEMM errors=%0d checks=%0d",
                   errors, checks);
        $finish;
    end

    initial begin
        #5_000_000;
        $fatal(1, "timeout in M7 dual-mode production GEMM test");
    end
endmodule
