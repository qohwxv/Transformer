`timescale 1ns/1ps

module tb_vit_gemm_fp16_stream_array #(
    parameter integer STREAMS = 16
);

    logic clk;
    logic rst;

    logic start_valid_i;
    logic start_ready_o;
    logic bias_enable_i;
    logic [7:0] token_valid_i;
    logic [1:0] output_valid_i;
    logic fallback_column_i;
    logic [63:0] bias_data_i;

    logic chunk_valid_i;
    logic chunk_ready_o;
    logic chunk_last_i;
    logic [15:0] lane_valid_i;
    logic [4095:0] activation_data_i;
    logic [1023:0] weight_data_i;

    logic busy_o;
    logic result_valid_o;
    logic result_ready_i;
    logic [7:0] result_token_mask_o;
    logic [1:0] result_output_mask_o;
    logic [511:0] result_data_o;
    logic [15:0] result_invalid_o;
    logic [15:0] result_overflow_o;
    logic [15:0] result_subnormal_flushed_o;
    logic [15:0] result_length_error_o;
    logic numerical_error_o;
    logic done_o;

    logic [4:0] profile_term_accept_count_o;
    logic [4:0] profile_disabled_term_accept_count_o;
    logic profile_feeder_stall_o;
    logic profile_result_backpressure_o;

    integer total_term_accepts;
    integer total_disabled_accepts;
    integer total_feeder_stalls;
    integer total_result_backpressure;
    integer row_index;
    integer col_index;
    integer lane_index;
    integer chunk_index;
    integer timeout_count;

    logic [511:0] held_result_data;
    logic [15:0] held_result_invalid;
    logic [15:0] held_result_overflow;
    logic [15:0] held_result_subnormal;
    logic [15:0] held_result_length;
    logic [7:0] held_token_mask;
    logic [1:0] held_output_mask;

    vit_gemm_fp16_stream_array #(
        .STREAMS (STREAMS),
        .FLUSH_SUBNORMALS (0)
    ) dut (
        .clk (clk),
        .rst (rst),
        .start_valid_i (start_valid_i),
        .start_ready_o (start_ready_o),
        .bias_enable_i (bias_enable_i),
        .token_valid_i (token_valid_i),
        .output_valid_i (output_valid_i),
        .fallback_column_i (fallback_column_i),
        .weight_fp16_packed2_i (1'b0),
        .bias_data_i (bias_data_i),
        .chunk_valid_i (chunk_valid_i),
        .chunk_ready_o (chunk_ready_o),
        .chunk_last_i (chunk_last_i),
        .lane_valid_i (lane_valid_i),
        .activation_data_i (activation_data_i),
        .weight_data_i (weight_data_i),
        .busy_o (busy_o),
        .result_valid_o (result_valid_o),
        .result_ready_i (result_ready_i),
        .result_token_mask_o (result_token_mask_o),
        .result_output_mask_o (result_output_mask_o),
        .result_data_o (result_data_o),
        .result_invalid_o (result_invalid_o),
        .result_overflow_o (result_overflow_o),
        .result_subnormal_flushed_o (result_subnormal_flushed_o),
        .result_length_error_o (result_length_error_o),
        .numerical_error_o (numerical_error_o),
        .done_o (done_o),
        .profile_term_accept_count_o (profile_term_accept_count_o),
        .profile_disabled_term_accept_count_o (
            profile_disabled_term_accept_count_o
        ),
        .profile_feeder_stall_o (profile_feeder_stall_o),
        .profile_result_backpressure_o (profile_result_backpressure_o)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (!rst) begin
            total_term_accepts =
                total_term_accepts + profile_term_accept_count_o;
            total_disabled_accepts =
                total_disabled_accepts +
                profile_disabled_term_accept_count_o;
            if (profile_feeder_stall_o)
                total_feeder_stalls = total_feeder_stalls + 1;
            if (profile_result_backpressure_o)
                total_result_backpressure =
                    total_result_backpressure + 1;
        end
    end

    function automatic logic [31:0] row_fp32(input integer row_number);
        begin
            case (row_number)
                0: row_fp32 = 32'h3f800000;
                1: row_fp32 = 32'h40000000;
                2: row_fp32 = 32'h40400000;
                3: row_fp32 = 32'h40800000;
                4: row_fp32 = 32'h40a00000;
                5: row_fp32 = 32'h40c00000;
                6: row_fp32 = 32'h40e00000;
                7: row_fp32 = 32'h41000000;
                default: row_fp32 = 32'd0;
            endcase
        end
    endfunction

    function automatic logic [31:0] main_expected(
        input integer logical_index
    );
        begin
            case (logical_index)
                0:  main_expected = 32'h42020000;
                1:  main_expected = 32'h427c0000;
                2:  main_expected = 32'h42810000;
                3:  main_expected = 32'h42fe0000;
                4:  main_expected = 32'h42c10000;
                5:  main_expected = 32'h433f0000;
                6:  main_expected = 32'h43008000;
                7:  main_expected = 32'h437f0000;
                8:  main_expected = 32'h43208000;
                9:  main_expected = 32'h439f8000;
                10: main_expected = 32'h43408000;
                11: main_expected = 32'h43bf8000;
                12: main_expected = 32'h43608000;
                13: main_expected = 32'h43df8000;
                14: main_expected = 32'h43804000;
                15: main_expected = 32'h43ff8000;
                default: main_expected = 32'd0;
            endcase
        end
    endfunction

    function automatic logic [31:0] fallback_expected(
        input integer row_number
    );
        begin
            case (row_number)
                0: fallback_expected = 32'h40c00000;
                1: fallback_expected = 32'h41400000;
                2: fallback_expected = 32'h41900000;
                3: fallback_expected = 32'h41c00000;
                4: fallback_expected = 32'h41f00000;
                5: fallback_expected = 32'h42100000;
                6: fallback_expected = 32'h42280000;
                7: fallback_expected = 32'h42400000;
                default: fallback_expected = 32'd0;
            endcase
        end
    endfunction

    task automatic clear_profile;
        begin
            @(negedge clk);
            total_term_accepts = 0;
            total_disabled_accepts = 0;
            total_feeder_stalls = 0;
            total_result_backpressure = 0;
        end
    endtask

    task automatic launch(
        input logic bias_enable,
        input logic [7:0] token_mask,
        input logic [1:0] output_mask,
        input logic fallback_column,
        input logic [63:0] bias_words
    );
        begin
            @(negedge clk);
            bias_enable_i = bias_enable;
            token_valid_i = token_mask;
            output_valid_i = output_mask;
            fallback_column_i = fallback_column;
            bias_data_i = bias_words;
            start_valid_i = 1'b1;
            while (!start_ready_o)
                @(negedge clk);
            @(negedge clk);
            start_valid_i = 1'b0;
        end
    endtask

    task automatic send_chunk(
        input logic is_last,
        input logic [15:0] valid_lanes
    );
        begin
            @(negedge clk);
            chunk_last_i = is_last;
            lane_valid_i = valid_lanes;
            chunk_valid_i = 1'b1;
            while (!chunk_ready_o)
                @(negedge clk);
            @(negedge clk);
            chunk_valid_i = 1'b0;
        end
    endtask

    task automatic wait_for_result;
        begin
            timeout_count = 0;
            while (!result_valid_o) begin
                @(posedge clk);
                #1;
                timeout_count = timeout_count + 1;
                if (timeout_count > 100000)
                    $fatal(1, "timeout waiting for M7 bridge result");
            end
        end
    endtask

    task automatic consume_result;
        begin
            @(negedge clk);
            result_ready_i = 1'b1;
            @(posedge clk);
            #1;
            if (!done_o)
                $fatal(1, "done_o did not pulse on result handshake");
            @(negedge clk);
            result_ready_i = 1'b0;
        end
    endtask

    task automatic fill_regular_payload;
        begin
            activation_data_i = '0;
            weight_data_i = '0;
            for (row_index = 0; row_index < 8; row_index = row_index + 1)
                for (lane_index = 0; lane_index < 16;
                     lane_index = lane_index + 1)
                    activation_data_i[
                        (row_index*16+lane_index)*32 +: 32
                    ] = row_fp32(row_index);
            for (lane_index = 0; lane_index < 16;
                 lane_index = lane_index + 1) begin
                weight_data_i[lane_index*32 +: 32] = 32'h3f800000;
                weight_data_i[(16+lane_index)*32 +: 32] =
                    32'h40000000;
            end
        end
    endtask

    task automatic check_clean_flags;
        begin
            if (result_invalid_o !== 16'd0)
                $fatal(1, "unexpected invalid flags=%04h", result_invalid_o);
            if (result_overflow_o !== 16'd0)
                $fatal(1, "unexpected overflow flags=%04h", result_overflow_o);
            if (result_subnormal_flushed_o !== 16'd0)
                $fatal(
                    1,
                    "unexpected subnormal flags=%04h",
                    result_subnormal_flushed_o
                );
            if (result_length_error_o !== 16'd0)
                $fatal(
                    1,
                    "unexpected length flags=%04h",
                    result_length_error_o
                );
            if (numerical_error_o !== 1'b0)
                $fatal(1, "unexpected numerical_error_o");
        end
    endtask

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        start_valid_i = 1'b0;
        bias_enable_i = 1'b0;
        token_valid_i = 8'd0;
        output_valid_i = 2'd0;
        fallback_column_i = 1'b0;
        bias_data_i = 64'd0;
        chunk_valid_i = 1'b0;
        chunk_last_i = 1'b0;
        lane_valid_i = 16'd0;
        activation_data_i = '0;
        weight_data_i = '0;
        result_ready_i = 1'b0;
        total_term_accepts = 0;
        total_disabled_accepts = 0;
        total_feeder_stalls = 0;
        total_result_backpressure = 0;

        repeat (5) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        if (!start_ready_o || busy_o)
            $fatal(1, "bridge did not enter idle after reset");

        // Reset recovery while a non-final dot is in progress.
        clear_profile();
        fill_regular_payload();
        launch(1'b0, 8'hff, 2'b11, 1'b0, 64'd0);
        send_chunk(1'b0, 16'hffff);
        repeat (5) @(posedge clk);
        @(negedge clk);
        rst = 1'b1;
        repeat (2) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        repeat (2) @(posedge clk);
        #1;
        if (!start_ready_o || busy_o || result_valid_o)
            $fatal(1, "mid-dot reset did not restore clean idle state");

        if (STREAMS == 16) begin
            // Primary R8/C2/L16 result with two chunks and sequential bias.
            clear_profile();
            fill_regular_payload();
            launch(
                1'b1,
                8'hff,
                2'b11,
                1'b0,
                {32'hbf800000, 32'h3f000000}
            );
            send_chunk(1'b0, 16'hffff);
            send_chunk(1'b1, 16'hffff);
            wait_for_result();

            if (result_token_mask_o !== 8'hff)
                $fatal(1, "primary token mask mismatch");
            if (result_output_mask_o !== 2'b11)
                $fatal(1, "primary output mask mismatch");
            for (row_index = 0; row_index < 16;
                 row_index = row_index + 1)
                if (result_data_o[row_index*32 +: 32] !==
                    main_expected(row_index))
                    $fatal(
                        1,
                        "primary result mismatch slot=%0d expected=%08h actual=%08h",
                        row_index,
                        main_expected(row_index),
                        result_data_o[row_index*32 +: 32]
                    );
            check_clean_flags();
            if (total_term_accepts != 512 || total_disabled_accepts != 0)
                $fatal(
                    1,
                    "primary profile mismatch terms=%0d disabled=%0d",
                    total_term_accepts,
                    total_disabled_accepts
                );
            if (total_feeder_stalls != 0)
                $fatal(
                    1,
                    "unexpected internal feeder stall count=%0d",
                    total_feeder_stalls
                );

            // Hold output backpressured and require every externally visible
            // result bit to remain stable until the handshake.
            held_result_data = result_data_o;
            held_result_invalid = result_invalid_o;
            held_result_overflow = result_overflow_o;
            held_result_subnormal = result_subnormal_flushed_o;
            held_result_length = result_length_error_o;
            held_token_mask = result_token_mask_o;
            held_output_mask = result_output_mask_o;
            repeat (5) begin
                @(posedge clk);
                #1;
                if (!result_valid_o ||
                    result_data_o !== held_result_data ||
                    result_invalid_o !== held_result_invalid ||
                    result_overflow_o !== held_result_overflow ||
                    result_subnormal_flushed_o !== held_result_subnormal ||
                    result_length_error_o !== held_result_length ||
                    result_token_mask_o !== held_token_mask ||
                    result_output_mask_o !== held_output_mask)
                    $fatal(1, "result changed while backpressured");
            end
            if (total_result_backpressure < 5)
                $fatal(1, "result backpressure counter hook did not pulse");
            consume_result();

            // Three-lane tail, sparse token mask and both columns.
            clear_profile();
            fill_regular_payload();
            launch(1'b0, 8'h05, 2'b11, 1'b0, 64'd0);
            send_chunk(1'b1, 16'h0007);
            wait_for_result();
            if (result_token_mask_o !== 8'h05 ||
                result_output_mask_o !== 2'b11)
                $fatal(1, "tail mask mismatch");
            if (result_data_o[0*32 +: 32] !== 32'h40400000 ||
                result_data_o[1*32 +: 32] !== 32'h40c00000 ||
                result_data_o[4*32 +: 32] !== 32'h41100000 ||
                result_data_o[5*32 +: 32] !== 32'h41900000)
                $fatal(1, "primary tail result mismatch");
            for (row_index = 0; row_index < 16;
                 row_index = row_index + 1)
                if ((row_index != 0) && (row_index != 1) &&
                    (row_index != 4) && (row_index != 5) &&
                    (result_data_o[row_index*32 +: 32] !== 32'd0))
                    $fatal(1, "inactive primary tail slot was nonzero");
            check_clean_flags();
            if (total_term_accepts != 256 ||
                total_disabled_accepts != 244)
                $fatal(
                    1,
                    "tail profile mismatch terms=%0d disabled=%0d",
                    total_term_accepts,
                    total_disabled_accepts
                );
            consume_result();
        end else begin
            // Controlled eight-stream fallback evaluates one selected column.
            clear_profile();
            fill_regular_payload();
            launch(1'b0, 8'hff, 2'b11, 1'b1, 64'd0);
            send_chunk(1'b1, 16'h0007);
            wait_for_result();
            if (result_token_mask_o !== 8'hff ||
                result_output_mask_o !== 2'b10)
                $fatal(1, "fallback result mask mismatch");
            for (row_index = 0; row_index < 8;
                 row_index = row_index + 1) begin
                if (result_data_o[(row_index*2+1)*32 +: 32] !==
                    fallback_expected(row_index))
                    $fatal(
                        1,
                        "fallback result mismatch row=%0d expected=%08h actual=%08h",
                        row_index,
                        fallback_expected(row_index),
                        result_data_o[(row_index*2+1)*32 +: 32]
                    );
                if (result_data_o[(row_index*2)*32 +: 32] !== 32'd0)
                    $fatal(1, "unselected fallback column was nonzero");
            end
            check_clean_flags();
            if (total_term_accepts != 128 ||
                total_disabled_accepts != 104)
                $fatal(
                    1,
                    "fallback profile mismatch terms=%0d disabled=%0d",
                    total_term_accepts,
                    total_disabled_accepts
                );
            consume_result();
        end

        // Canonical NaN conversion and propagation, with all disabled lanes
        // proven not to contaminate the one logical output.
        clear_profile();
        fill_regular_payload();
        activation_data_i[0 +: 32] = 32'h7fc12345;
        launch(1'b0, 8'h01, 2'b01, 1'b0, 64'd0);
        send_chunk(1'b1, 16'h0001);
        wait_for_result();
        if (result_token_mask_o !== 8'h01 ||
            result_output_mask_o !== 2'b01)
            $fatal(
                1,
                "NaN result mask mismatch token=%02h output=%02b",
                result_token_mask_o,
                result_output_mask_o
            );
        if (result_data_o[0 +: 32] !== 32'h7fc00000)
            $fatal(1, "NaN result was not canonicalized");
        if (!result_invalid_o[0] || !numerical_error_o)
            $fatal(
                1,
                "NaN invalid/numerical flag missing invalid=%04h numerical=%0b result=%08h",
                result_invalid_o,
                numerical_error_o,
                result_data_o[0 +: 32]
            );
        consume_result();

        // The raw M6 dot is +Inf (valid under its special-value contract),
        // while the sequential bias is -Inf.  The bias adder alone creates
        // qNaN, which the bridge must classify as invalid/fail-closed.
        clear_profile();
        fill_regular_payload();
        activation_data_i[0 +: 32] = 32'h7f800000;
        launch(
            1'b1,
            8'h01,
            2'b01,
            1'b0,
            {32'd0, 32'hff800000}
        );
        send_chunk(1'b1, 16'h0001);
        wait_for_result();
        if (result_token_mask_o !== 8'h01 ||
            result_output_mask_o !== 2'b01)
            $fatal(1, "bias-special result mask mismatch");
        if (result_data_o[0 +: 32] !== 32'h7fc00000 ||
            !result_invalid_o[0] ||
            result_overflow_o[0] ||
            !numerical_error_o)
            $fatal(
                1,
                "bias-created NaN classification mismatch data=%08h invalid=%0b overflow=%0b numerical=%0b",
                result_data_o[0 +: 32],
                result_invalid_o[0],
                result_overflow_o[0],
                numerical_error_o
            );
        consume_result();

        // A non-finite enabled bias is fail-closed even when the raw dot is
        // finite: the final +Inf is reported through the overflow channel.
        clear_profile();
        fill_regular_payload();
        launch(
            1'b1,
            8'h01,
            2'b01,
            1'b0,
            {32'd0, 32'h7f800000}
        );
        send_chunk(1'b1, 16'h0001);
        wait_for_result();
        if (result_data_o[0 +: 32] !== 32'h7f800000 ||
            result_invalid_o[0] ||
            !result_overflow_o[0] ||
            !numerical_error_o)
            $fatal(
                1,
                "infinite bias classification mismatch data=%08h invalid=%0b overflow=%0b numerical=%0b",
                result_data_o[0 +: 32],
                result_invalid_o[0],
                result_overflow_o[0],
                numerical_error_o
            );
        consume_result();

        // K=3088 (193 K16 chunks) exceeds the M6 K<=3072 contract.  The
        // active logical result must surface both length and invalid flags.
        clear_profile();
        fill_regular_payload();
        launch(1'b0, 8'h01, 2'b01, 1'b0, 64'd0);
        for (chunk_index = 0; chunk_index < 193;
             chunk_index = chunk_index + 1)
            send_chunk(chunk_index == 192, 16'hffff);
        wait_for_result();
        if (!result_length_error_o[0] ||
            !result_invalid_o[0] ||
            !numerical_error_o)
            $fatal(1, "K overflow did not surface length/invalid flags");
        consume_result();

        $display(
            "PASS M7_GEMM_FP16_STREAM_ARRAY streams=%0d",
            STREAMS
        );
        $finish;
    end

endmodule
