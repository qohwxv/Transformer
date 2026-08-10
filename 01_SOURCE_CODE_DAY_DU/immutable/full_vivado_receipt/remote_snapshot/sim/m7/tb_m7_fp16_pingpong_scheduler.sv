`timescale 1ns/1ps

// M7.4 Gate-2 black-box specification test for the production FP16 scheduler.
// It covers two-bank panel ownership plus the depth-two result FIFO, early
// non-final tile advance, compute/store overlap, full simultaneous pop/push,
// metadata/order integrity, reset recovery, error drain and final drain.
module tb_m7_fp16_pingpong_scheduler;
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

    logic profile_gemm_tile_step;
    logic [15:0] profile_valid_mac_delta;
    logic [15:0] profile_tail_mac_delta;
    logic [4:0] profile_term_accept_delta;
    logic [4:0] profile_disabled_term_delta;
    logic profile_input_wait;
    logic profile_term_stall;
    logic profile_result_backpressure;
    logic profile_compute_active;
    logic profile_dot_start;
    logic profile_result_vector;
    logic [4:0] profile_invalid_delta;
    logic [4:0] profile_overflow_delta;
    logic [4:0] profile_length_error_delta;
    logic [4:0] profile_subnormal_flushed_delta;
    logic profile_panel_load_active;
    logic profile_panel_compute_active;
    logic profile_panel_commit;
    logic profile_panel_claim;
    logic [1:0] profile_panel_claim_mask;
    logic profile_panel_release;
    logic profile_panel_empty_stall;
    logic profile_panel_full_stall;
    logic [1:0] profile_panel_occupancy;
    logic profile_result_fifo_enqueue;
    logic profile_result_fifo_dequeue;
    logic profile_result_fifo_full_stall;
    logic [1:0] profile_result_fifo_occupancy;

    // Deterministic pseudo-random frontend and result-backpressure models.
    localparam logic [31:0] DATA_SEED = 32'h4d37_5047;
    localparam logic [31:0] READY_SEED = 32'h4d37_4250;
    logic [31:0] data_lfsr;
    logic [31:0] ready_lfsr;
    logic responder_enable;
    logic stats_clear;
    logic distinct_payload_enable;
    logic inject_invalid_payload;
    integer inject_invalid_output_base;
    logic allow_numerical_error;
    integer forced_data_delay;
    logic request_pending;
    integer response_delay;
    logic [31:0] request_token_hold;
    logic [31:0] request_output_hold;
    logic [31:0] request_k_hold;
    logic [31:0] request_batch_hold;

    logic result_wait_active;
    integer result_wait_remaining;
    logic result_force_block;
    logic result_manual_mode;
    logic result_manual_ready;

    localparam integer MAX_CAPTURED_RESULTS = 16;

    integer checks = 0;
    integer request_count;
    integer commit_count;
    integer consume_count;
    integer committed_depth;
    integer max_committed_depth;
    integer request_compute_overlap_cycles;
    integer commit_compute_overlap_count;
    integer compute_active_cycles;
    integer result_count;
    integer result_backpressure_cycles;
    integer profile_panel_commit_count;
    integer profile_panel_claim_count;
    integer profile_panel_release_count;
    integer profile_bank0_claim_count;
    integer profile_bank1_claim_count;
    integer profile_panel_max_occupancy;
    integer profile_panel_empty_stall_cycles;
    integer profile_panel_full_stall_cycles;
    integer profile_result_fifo_enqueue_count;
    integer profile_result_fifo_dequeue_count;
    integer profile_result_fifo_full_stall_cycles;
    integer profile_result_fifo_max_occupancy;
    integer simultaneous_commit_claim_count;
    integer simultaneous_commit_release_count;
    integer last_chunk_release_count;
    integer numerical_error_event_count;
    integer compute_fifo_overlap_cycles;
    integer full_simultaneous_push_pop_count;
    integer final_drain_depth_two_cycles;
    integer live_address_divergence_cycles;
    integer dequeue_compute_overlap_count;
    logic [511:0] captured_result_data;
    logic [7:0] captured_token_mask;
    logic [1:0] captured_output_mask;
    logic [31:0] captured_result_token;
    logic [31:0] captured_result_output;
    logic [31:0] captured_result_batch;
    logic [65:0] captured_result_address;
    logic [7:0] captured_result_generation;
    logic result_hold_valid;
    logic [511:0] result_hold_data;
    logic [65:0] result_hold_address;
    logic [7:0] result_hold_generation;
    logic [31:0] result_hold_token;
    logic [31:0] result_hold_output;
    logic [31:0] result_hold_batch;
    logic [7:0] result_hold_token_mask;
    logic [1:0] result_hold_output_mask;
    logic [65:0] fifo_expected_address_log [0:MAX_CAPTURED_RESULTS-1];
    logic [7:0] fifo_expected_generation_log [0:MAX_CAPTURED_RESULTS-1];
    logic [31:0] fifo_expected_token_log [0:MAX_CAPTURED_RESULTS-1];
    logic [31:0] fifo_expected_output_log [0:MAX_CAPTURED_RESULTS-1];
    logic [31:0] fifo_expected_batch_log [0:MAX_CAPTURED_RESULTS-1];
    logic [7:0] fifo_expected_token_mask_log [0:MAX_CAPTURED_RESULTS-1];
    logic [1:0] fifo_expected_output_mask_log [0:MAX_CAPTURED_RESULTS-1];
    logic [511:0] fifo_expected_data_log [0:MAX_CAPTURED_RESULTS-1];
    logic metadata_poison_enable;
    logic [65:0] result_address_seed;
    logic [7:0] result_generation_seed;

    logic [511:0] result_data_log [0:MAX_CAPTURED_RESULTS-1];
    logic [7:0] result_token_mask_log [0:MAX_CAPTURED_RESULTS-1];
    logic [1:0] result_output_mask_log [0:MAX_CAPTURED_RESULTS-1];
    logic [31:0] result_token_log [0:MAX_CAPTURED_RESULTS-1];
    logic [31:0] result_output_log [0:MAX_CAPTURED_RESULTS-1];
    logic [31:0] result_batch_log [0:MAX_CAPTURED_RESULTS-1];
    logic [65:0] result_address_log [0:MAX_CAPTURED_RESULTS-1];
    logic [7:0] result_generation_log [0:MAX_CAPTURED_RESULTS-1];

    integer row;
    integer lane;
    integer score_row;
    integer score_col;
    integer score_lane;
    integer result_row;
    integer result_col;
    integer capture_index;
    integer depth_next;
    integer expected_request_k;
    integer expected_chunks_per_tile;
    integer expected_tile_index;
    integer expected_chunk_index;
    integer expected_token_tile;
    integer expected_output_tile;
    integer expected_batch;
    integer expected_token_coord;
    integer expected_output_coord;
    integer expected_output_column;
    integer claimed_bank_index;
    integer claimed_k_coord;
    integer released_k_coord;
    integer expected_valid_lanes;
    integer observed_valid_lanes;
    integer expected_results;
    integer expected_requests;
    integer weighted_k_sum;
    integer activation_scalar;
    integer weight_scalar;
    integer expected_integer_result;
    integer alignment_delay;
    integer alignment_hit;

    function automatic logic [31:0] lfsr_next(input logic [31:0] value);
        begin
            lfsr_next = {value[30:0],
                         value[31] ^ value[21] ^ value[1] ^ value[0]};
        end
    endfunction

    // Exact positive-integer encoders keep the scoreboard independent of
    // simulator-specific shortreal support.  All directed values are small
    // enough to be represented exactly in FP16 and FP32.
    function automatic logic [31:0] uint_to_fp32(input integer value);
        integer msb;
        integer shifted_fraction;
        begin
            if (value <= 0) begin
                uint_to_fp32 = 32'd0;
            end else begin
                msb = 0;
                while ((1 << (msb + 1)) <= value)
                    msb = msb + 1;
                shifted_fraction =
                    (value - (1 << msb)) << (23 - msb);
                uint_to_fp32 = {1'b0, 8'(127 + msb),
                                23'(shifted_fraction)};
            end
        end
    endfunction

    function automatic logic [15:0] uint_to_fp16(input integer value);
        integer msb;
        integer shifted_fraction;
        begin
            if (value <= 0) begin
                uint_to_fp16 = 16'd0;
            end else begin
                msb = 0;
                while ((1 << (msb + 1)) <= value)
                    msb = msb + 1;
                shifted_fraction =
                    (value - (1 << msb)) << (10 - msb);
                uint_to_fp16 = {1'b0, 5'(15 + msb),
                                10'(shifted_fraction)};
            end
        end
    endfunction

    function automatic integer k_weighted_lane_sum(input integer reduction);
        integer base;
        integer lanes_left;
        integer chunk_scale;
        begin
            k_weighted_lane_sum = 0;
            base = 0;
            chunk_scale = 1;
            while (base < reduction) begin
                lanes_left = reduction - base;
                if (lanes_left > PE_LANES)
                    lanes_left = PE_LANES;
                k_weighted_lane_sum = k_weighted_lane_sum +
                                      lanes_left * chunk_scale;
                base = base + PE_LANES;
                chunk_scale = chunk_scale << 1;
            end
        end
    endfunction

    task automatic require(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (!condition)
                $fatal(1, "M7.4_GATE1_INVARIANT_FAIL: %s", message);
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

    task automatic pulse_stats_clear;
        begin
            @(negedge clk);
            stats_clear = 1'b1;
            @(negedge clk);
            stats_clear = 1'b0;
        end
    endtask

    task automatic pulse_reset;
        begin
            @(negedge clk);
            rst = 1'b1;
            repeat (2) @(posedge clk);
            @(negedge clk);
            rst = 1'b0;
            @(posedge clk);
            #1;
            require(!busy, "reset must clear busy");
            require(!done, "reset must clear done");
            require(!result_valid, "reset must clear result_valid");
            require(!config_error, "reset must clear config_error");
            require(!request_pending, "reset must flush pending response owner");
            require(committed_depth == 0,
                    "reset must flush externally observed panel ownership");
            require(profile_result_fifo_occupancy == 0,
                    "reset must flush the result FIFO");
        end
    endtask

    task automatic wait_for_done(input integer timeout_cycles);
        integer waited;
        begin
            waited = 0;
            while (!done && (waited < timeout_cycles)) begin
                @(posedge clk);
                waited = waited + 1;
            end
            require(done, "timeout waiting for scheduler done");
            #1;
        end
    endtask

    task automatic check_exact_result(
        input logic [31:0] expected_col0,
        input logic [31:0] expected_col1
    );
        begin
            require(result_count == 2,
                    "S8 full C2 tile requires two result vectors");
            require((result_token_log[0] == 0) &&
                    (result_token_log[1] == 0),
                    "result token coordinates must remain zero");
            require((result_output_log[0] == 0) &&
                    (result_output_log[1] == 0),
                    "result output coordinates must remain zero");
            require((result_batch_log[0] == 0) &&
                    (result_batch_log[1] == 0),
                    "result batch coordinates must remain zero");
            require((result_address_log[0] == result_address_seed) &&
                    (result_address_log[1] == result_address_seed),
                    "result absolute addresses must share tile context");
            require((result_generation_log[0] == result_generation_seed) &&
                    (result_generation_log[1] == result_generation_seed),
                    "result generations must match command generation");
            require((result_token_mask_log[0] == 8'hff) &&
                    (result_token_mask_log[1] == 8'hff),
                    "full R8 token masks expected");
            require((result_output_mask_log[0] == 2'b01) &&
                    (result_output_mask_log[1] == 2'b10),
                    "S8 result masks must be ordered column zero then one");
            for (result_row = 0; result_row < ARRAY_ROWS;
                 result_row = result_row + 1) begin
                require(
                    result_data_log[0][(result_row*2)*32 +: 32] ==
                        expected_col0,
                    "packed column-0 numerical result mismatch"
                );
                require(
                    result_data_log[1][(result_row*2+1)*32 +: 32] ==
                        expected_col1,
                    "packed column-1 numerical result mismatch"
                );
            end
        end
    endtask

    task automatic run_packed_case(
        input integer reduction,
        input logic [31:0] expected_col0,
        input logic [31:0] expected_col1,
        input logic require_basic_overlap,
        input logic require_two_bank_depth
    );
        integer expected_chunks;
        begin
            forced_data_delay = -1;
            distinct_payload_enable = 1'b0;
            inject_invalid_payload = 1'b0;
            allow_numerical_error = 1'b0;
            cfg_k = reduction;
            pulse_stats_clear();
            pulse_start();
            wait_for_done(200000);

            expected_chunks = (reduction + PE_LANES - 1) / PE_LANES;
            require(!config_error, "packed scheduler command must be clean");
            require(request_count == expected_chunks * 2,
                    "one frontend request per K16 chunk and S8 column expected");
            require(commit_count == expected_chunks * 2,
                    "one panel commit per frontend response expected");
            require(consume_count == expected_chunks * 2,
                    "one bridge consume per committed panel expected");
            require(committed_depth == 0,
                    "all committed panels must be released at done");
            require(profile_panel_occupancy == 0,
                    "reported panel occupancy must be zero at done");
            require(max_committed_depth <= 2,
                    "two-bank ownership depth must never overflow");
            require(profile_panel_commit_count == expected_chunks * 2,
                    "profile commit count must equal delivered chunks");
            require(profile_panel_claim_count == expected_chunks * 2,
                    "profile claim count must equal consumed chunks");
            require(profile_panel_release_count == expected_chunks * 2,
                    "profile release count must equal consumed chunks");
            require(result_backpressure_cycles > 0,
                    "randomized result backpressure must be exercised");
            require(profile_result_fifo_enqueue_count == 2,
                    "packed tile must enqueue both S8 column results");
            require(profile_result_fifo_dequeue_count == 2,
                    "packed tile must dequeue both S8 column results");
            require((profile_result_fifo_max_occupancy >= 1) &&
                    (profile_result_fifo_max_occupancy <= 2),
                    "S8 result FIFO occupancy must remain bounded");
            check_exact_result(expected_col0, expected_col1);

            if (require_basic_overlap) begin
                require(request_compute_overlap_cycles > 0,
                        "K>=32 must request data while arithmetic is active");
                require(commit_compute_overlap_count > 0,
                        "K>=32 must commit a panel while arithmetic is active");
            end
            if (require_two_bank_depth) begin
                require(profile_panel_max_occupancy == 2,
                        "reported occupancy must visit both panel banks");
                require((profile_bank0_claim_count > 0) &&
                        (profile_bank1_claim_count > 0),
                        "both tagged banks must be claimed");
            end

            $display(
                {"M7.4_GATE1_CASE K=%0d req=%0d commit=%0d consume=%0d ",
                 "max_ready_depth=%0d req_compute_overlap=%0d ",
                 "commit_compute_overlap=%0d result_bp=%0d"},
                reduction, request_count, commit_count, consume_count,
                max_committed_depth, request_compute_overlap_cycles,
                commit_compute_overlap_count, result_backpressure_cycles
            );

            // This is the intentional RED specification assertion.  It comes
            // last so tail, reset, coordinate-hold, numerical and one-slot
            // overlap evidence survive in the log produced by current RTL.
            if (require_two_bank_depth && (max_committed_depth < 2))
                $fatal(
                    1,
                    {"M7.4_GATE1_RED_NO_TWO_BANK_LOOKAHEAD: ",
                     "K=%0d max_ready_depth=%0d expected>=2"},
                    reduction, max_committed_depth
                );
        end
    endtask

    task automatic check_distinct_result_log;
        integer log_index;
        integer output_tiles;
        integer token_tiles;
        integer tile_in_batch;
        integer token_tile_index;
        integer output_tile_index;
        integer expected_token;
        integer expected_output;
        integer expected_batch_index;
        integer expected_token_mask_integer;
        integer expected_output_mask_integer;
        integer local_activation_scalar;
        integer local_weight_scalar;
        integer local_expected_integer_result;
        integer local_weighted_k_sum;
        begin
            output_tiles = (cfg_n + ARRAY_COLS - 1) / ARRAY_COLS;
            token_tiles = (cfg_m + ARRAY_ROWS - 1) / ARRAY_ROWS;
            // S8 emits one partial result for each real output column.
            expected_results = cfg_batch_count * cfg_n * token_tiles;
            local_weighted_k_sum = k_weighted_lane_sum(cfg_k);

            require(result_count == expected_results,
                    "multi-tile result-vector count mismatch");
            for (log_index = 0; log_index < expected_results;
                 log_index = log_index + 1) begin
                expected_batch_index = log_index / (cfg_n * token_tiles);
                tile_in_batch = log_index % (cfg_n * token_tiles);
                token_tile_index = tile_in_batch / cfg_n;
                expected_output_column = tile_in_batch % cfg_n;
                output_tile_index = expected_output_column / ARRAY_COLS;
                expected_token = token_tile_index * ARRAY_ROWS;
                expected_output = output_tile_index * ARRAY_COLS;

                require(result_batch_log[log_index] ==
                            expected_batch_index,
                        "result batch order mismatch");
                require(result_token_log[log_index] == expected_token,
                        "result token-tile order mismatch");
                require(result_output_log[log_index] == expected_output,
                        "result output-tile order mismatch");
                require(
                    result_address_log[log_index] ==
                        result_address_seed +
                        {18'd0, expected_batch_index[31:0], 16'd0} +
                        {26'd0, expected_token[31:0], 8'd0} +
                        {34'd0, expected_output[31:0]},
                    "result absolute-address order mismatch"
                );
                require(result_generation_log[log_index] ==
                            result_generation_seed,
                        "result generation order mismatch");

                expected_token_mask_integer = 0;
                for (result_row = 0; result_row < ARRAY_ROWS;
                     result_row = result_row + 1)
                    if ((expected_token + result_row) < cfg_m)
                        expected_token_mask_integer =
                            expected_token_mask_integer | (1 << result_row);
                expected_output_mask_integer =
                    1 << (expected_output_column % ARRAY_COLS);
                require(result_token_mask_log[log_index] ==
                            expected_token_mask_integer[7:0],
                        "result token-tail mask mismatch");
                require(result_output_mask_log[log_index] ==
                            expected_output_mask_integer[1:0],
                        "result output-tail mask mismatch");

                for (result_row = 0; result_row < ARRAY_ROWS;
                     result_row = result_row + 1) begin
                    for (result_col = 0; result_col < ARRAY_COLS;
                         result_col = result_col + 1) begin
                        if (((expected_token + result_row) < cfg_m) &&
                            (result_col ==
                             (expected_output_column % ARRAY_COLS))) begin
                            local_activation_scalar = 1 + expected_token +
                                result_row + (expected_batch_index * 16);
                            local_weight_scalar = 1 + expected_output +
                                result_col + (expected_batch_index * 4);
                            local_expected_integer_result =
                                local_weighted_k_sum *
                                local_activation_scalar *
                                local_weight_scalar;
                            require(
                                result_data_log[log_index]
                                    [(result_row*ARRAY_COLS+result_col)*32
                                     +: 32] ==
                                    uint_to_fp32(
                                        local_expected_integer_result
                                    ),
                                "distinct payload numerical mismatch"
                            );
                        end
                    end
                end
            end
        end
    endtask

    task automatic run_distinct_multitile_case;
        integer local_expected_chunks;
        begin
            forced_data_delay = -1;
            distinct_payload_enable = 1'b1;
            inject_invalid_payload = 1'b0;
            allow_numerical_error = 1'b0;
            cfg_m = 32'd10;
            cfg_k = 32'd33;
            cfg_n = 32'd3;
            cfg_batch_count = 32'd2;
            pulse_stats_clear();
            pulse_start();
            wait_for_done(800000);

            local_expected_chunks = (cfg_k + PE_LANES - 1) / PE_LANES;
            expected_results = cfg_batch_count *
                ((cfg_m + ARRAY_ROWS - 1) / ARRAY_ROWS) * cfg_n;
            expected_requests = expected_results * local_expected_chunks;
            require(!config_error,
                    "distinct multi-tile command must be clean");
            require(request_count == expected_requests,
                    "distinct multi-tile request count mismatch");
            require(commit_count == expected_requests,
                    "distinct multi-tile commit count mismatch");
            require(consume_count == expected_requests,
                    "distinct multi-tile consume count mismatch");
            require(profile_panel_claim_count == expected_requests,
                    "distinct multi-tile claim count mismatch");
            require(profile_panel_release_count == expected_requests,
                    "distinct multi-tile release count mismatch");
            require(last_chunk_release_count == expected_results,
                    "exactly one TLAST release per output tile expected");
            require(committed_depth == 0,
                    "multi-tile command leaked committed ownership");
            require(profile_panel_occupancy == 0,
                    "multi-tile command leaked reported ownership");
            require(profile_panel_max_occupancy == 2,
                    "multi-tile command never filled both banks");
            require((profile_bank0_claim_count > 0) &&
                    (profile_bank1_claim_count > 0),
                    "multi-tile command must alternate both banks");
            require(request_compute_overlap_cycles > 0,
                    "multi-tile command did not overlap requests/compute");
            require(commit_compute_overlap_count > 0,
                    "multi-tile command did not overlap commits/compute");
            require(simultaneous_commit_claim_count == 0,
                    "two-bank/one-outstanding contract forbids commit+claim");
            require(result_backpressure_cycles > 0,
                    "multi-tile command did not exercise result backpressure");
            require(profile_result_fifo_enqueue_count == expected_results,
                    "one FIFO enqueue per multi-tile result expected");
            require(profile_result_fifo_dequeue_count == expected_results,
                    "one FIFO dequeue per multi-tile result expected");
            require((profile_result_fifo_max_occupancy >= 1) &&
                    (profile_result_fifo_max_occupancy <= 2),
                    "multi-tile S8 FIFO occupancy must remain bounded");
            check_distinct_result_log();

            $display(
                "M7.4_INTEGRITY_MULTI results=%0d chunks=%0d req=%0d max_depth=%0d commit_claim=%0d commit_release=%0d last=%0d",
                result_count, local_expected_chunks, request_count,
                max_committed_depth, simultaneous_commit_claim_count,
                simultaneous_commit_release_count,
                last_chunk_release_count
            );
        end
    endtask

    task automatic run_gate2_fifo_depth_case;
        integer waited;
        integer local_expected_chunks;
        begin
            // Four output tiles let one accepted dequeue overlap tile-3
            // compute, after which tile 3 refills the FIFO and tile 4 reaches
            // the full replacement path.  The final replacement leaves two
            // entries for the terminal drain.
            forced_data_delay = 0;
            distinct_payload_enable = 1'b1;
            inject_invalid_payload = 1'b0;
            allow_numerical_error = 1'b0;
            result_force_block = 1'b0;
            result_manual_mode = 1'b1;
            result_manual_ready = 1'b0;
            cfg_m = 32'd8;
            cfg_k = 32'd17;
            cfg_n = 32'd7;
            cfg_batch_count = 32'd1;
            pulse_stats_clear();
            pulse_start();

            // The first two tiles fill the FIFO; tile 3 is already computing.
            waited = 0;
            while (!((profile_result_fifo_occupancy == 2) &&
                     profile_compute_active) &&
                   (waited < 400000)) begin
                @(posedge clk);
                waited = waited + 1;
            end
            require(profile_result_fifo_occupancy == 2,
                    "Gate2 directed case never filled result FIFO");
            require(profile_compute_active,
                    "Gate2 directed case did not compute with FIFO full");

            // Register ready for exactly one handshake edge, then re-block.
            // This models one completed external store while compute remains
            // active, rather than merely having queued store work.
            @(negedge clk);
            result_manual_ready = 1'b1;
            @(posedge clk);
            #1;
            @(negedge clk);
            result_manual_ready = 1'b0;
            @(posedge clk);
            #1;
            require(profile_result_fifo_dequeue_count == 1,
                    "Gate2 directed store pulse did not dequeue exactly once");
            require(dequeue_compute_overlap_count > 0,
                    "Gate2 accepted dequeue did not overlap compute");

            // Tile 3 refills the freed slot.  Tile 4 then waits with a valid
            // result while the FIFO is full, so release exercises atomic
            // old-head pop plus final-result push.
            waited = 0;
            while (!((profile_result_fifo_occupancy == 2) &&
                     profile_result_fifo_full_stall) &&
                   (waited < 400000)) begin
                @(posedge clk);
                waited = waited + 1;
            end
            require(profile_result_fifo_full_stall,
                    "Gate2 directed final result never stalled on full FIFO");
            require(result_valid && !result_ready,
                    "full FIFO head must remain visible under backpressure");
            // Keep the FIFO at depth two with one atomic pop+push per remaining
            // physical column pass.  Re-block after every exchange so the
            // final S8 column is enqueued into a depth-two terminal drain.
            while (u_dut.state != u_dut.STATE_PACK_DRAIN_RESULT) begin
                require(profile_result_fifo_full_stall,
                        "Gate2 S8 exchange requires a blocked full FIFO");
                @(negedge clk);
                result_manual_ready = 1'b1;
                @(posedge clk);
                #1;
                @(negedge clk);
                result_manual_ready = 1'b0;
                @(posedge clk);
                #1;
                if (u_dut.state != u_dut.STATE_PACK_DRAIN_RESULT) begin
                    waited = 0;
                    while (!profile_result_fifo_full_stall &&
                           (waited < 400000)) begin
                        @(posedge clk);
                        waited = waited + 1;
                    end
                    require(profile_result_fifo_full_stall,
                            "next S8 result never reached full FIFO exchange");
                end
            end
            require(profile_result_fifo_occupancy == 2,
                    "S8 final drain must begin at FIFO depth two");
            @(posedge clk);
            #1;
            @(negedge clk);
            result_manual_ready = 1'b1;
            wait_for_done(400000);

            local_expected_chunks = (cfg_k + PE_LANES - 1) / PE_LANES;
            expected_results = cfg_n;
            expected_requests = expected_results * local_expected_chunks;
            require(!config_error,
                    "Gate2 depth/full-pop-push command must be clean");
            require(request_count == expected_requests,
                    "Gate2 directed request count mismatch");
            require(result_count == expected_results,
                    "Gate2 directed result count mismatch");
            require(profile_result_fifo_enqueue_count == expected_results,
                    "Gate2 directed enqueue count mismatch");
            require(profile_result_fifo_dequeue_count == expected_results,
                    "Gate2 directed dequeue count mismatch");
            require(profile_result_fifo_max_occupancy == 2,
                    "Gate2 result FIFO did not reach depth two");
            require(profile_result_fifo_full_stall_cycles > 0,
                    "Gate2 full-FIFO backpressure was not counted");
            require(full_simultaneous_push_pop_count > 0,
                    "Gate2 full FIFO did not pop and push atomically");
            require(compute_fifo_overlap_cycles > 0,
                    "Gate2 saw no compute while queued store work existed");
            require(dequeue_compute_overlap_count > 0,
                    "Gate2 saw no accepted store while compute was active");
            require(final_drain_depth_two_cycles > 0,
                    "Gate2 S8 final drain never held two queued results");
            require(profile_result_fifo_occupancy == 0,
                    "Gate2 DONE left result FIFO occupied");
            require(live_address_divergence_cycles > 0,
                    "Gate2 never retained a head across live address advance");
            require(!result_valid && !data_request &&
                    (profile_panel_occupancy == 0) &&
                    !profile_compute_active,
                    "Gate2 terminal stage did not fully quiesce");
            check_distinct_result_log();

            $display(
                {"M7.4_GATE2_FIFO results=%0d enq=%0d deq=%0d max=%0d ",
                 "full_stall=%0d full_pop_push=%0d compute_fifo=%0d ",
                 "dequeue_compute=%0d final_drain2=%0d"},
                result_count, profile_result_fifo_enqueue_count,
                profile_result_fifo_dequeue_count,
                profile_result_fifo_max_occupancy,
                profile_result_fifo_full_stall_cycles,
                full_simultaneous_push_pop_count,
                compute_fifo_overlap_cycles,
                dequeue_compute_overlap_count,
                final_drain_depth_two_cycles
            );
            result_manual_mode = 1'b0;
            result_manual_ready = 1'b0;
            result_force_block = 1'b0;
        end
    endtask

    task automatic run_gate2_fifo_reset_case;
        integer waited;
        begin
            forced_data_delay = 0;
            distinct_payload_enable = 1'b1;
            inject_invalid_payload = 1'b0;
            allow_numerical_error = 1'b0;
            result_force_block = 1'b0;
            result_manual_mode = 1'b1;
            result_manual_ready = 1'b0;
            cfg_m = 32'd8;
            cfg_k = 32'd17;
            cfg_n = 32'd5;
            cfg_batch_count = 32'd1;
            pulse_stats_clear();
            pulse_start();

            waited = 0;
            while (!((profile_result_fifo_occupancy == 2) &&
                     profile_compute_active) &&
                   (waited < 300000)) begin
                @(posedge clk);
                waited = waited + 1;
            end
            require(profile_result_fifo_occupancy == 2,
                    "Gate2 reset case never reached FIFO depth two");
            require(profile_compute_active,
                    "Gate2 reset case missed active next-tile compute");
            pulse_reset();
            require(profile_result_fifo_occupancy == 0 && !result_valid,
                    "Gate2 reset did not flush queued result ownership");
            require(!data_request && (profile_panel_occupancy == 0) &&
                    !profile_compute_active,
                    "Gate2 reset left an active pipeline stage");
            result_manual_mode = 1'b0;
            result_manual_ready = 1'b0;

            // A fresh tail command must not observe a stale dequeue or entry.
            cfg_m = 32'd8;
            cfg_n = 32'd2;
            cfg_batch_count = 32'd1;
            run_packed_case(17, 32'h4188_0000, 32'h4208_0000,
                            1'b0, 1'b0);
            require(profile_result_fifo_enqueue_count == 2 &&
                    profile_result_fifo_dequeue_count == 2,
                    "fresh post-reset command observed stale FIFO activity");
            $display(
                "M7.4_GATE2_RESET_DEPTH2 fresh_enq=%0d fresh_deq=%0d",
                profile_result_fifo_enqueue_count,
                profile_result_fifo_dequeue_count
            );
        end
    endtask

    task automatic run_gate2_error_drain_case;
        integer waited;
        begin
            // Tile zero is valid and remains queued.  Tile one is poisoned
            // while the external store path is blocked.  Gate-2 must consume
            // no poisoned result, retain the older FIFO head, drain it after
            // ready returns, and only then assert error/DONE.
            forced_data_delay = 0;
            distinct_payload_enable = 1'b0;
            inject_invalid_payload = 1'b1;
            inject_invalid_output_base = 2;
            allow_numerical_error = 1'b1;
            result_force_block = 1'b1;
            cfg_m = 32'd8;
            cfg_k = 32'd16;
            cfg_n = 32'd3;
            cfg_batch_count = 32'd1;
            pulse_stats_clear();
            pulse_start();

            waited = 0;
            while (!(config_error &&
                     (profile_result_fifo_occupancy == 2)) &&
                   (waited < 300000)) begin
                @(posedge clk);
                waited = waited + 1;
            end
            require(config_error,
                    "Gate2 queued-head numerical error was not reported");
            require(profile_result_fifo_occupancy == 2,
                    "Gate2 numerical error flushed older valid FIFO heads");
            require(profile_result_fifo_enqueue_count == 2,
                    "poisoned S8 result entered the FIFO");
            require(result_valid && !result_ready,
                    "older valid result disappeared on later numerical error");

            @(negedge clk);
            result_force_block = 1'b0;
            wait_for_done(300000);
            require(config_error,
                    "Gate2 error indication did not survive final drain");
            require(profile_result_fifo_enqueue_count == 2 &&
                    profile_result_fifo_dequeue_count == 2,
                    "Gate2 error drain did not retire both valid S8 heads");
            require(result_count == 2,
                    "Gate2 error drain exposed wrong result count");
            require(numerical_error_event_count > 0,
                    "Gate2 queued-head error lacked numerical event");
            require(profile_result_fifo_occupancy == 0,
                    "Gate2 error DONE preceded FIFO drain");
            check_exact_result(32'h4180_0000, 32'h4200_0000);
            $display(
                "M7.4_GATE2_ERROR_DRAIN enq=%0d deq=%0d results=%0d events=%0d",
                profile_result_fifo_enqueue_count,
                profile_result_fifo_dequeue_count,
                result_count,
                numerical_error_event_count
            );
            result_force_block = 1'b0;
            inject_invalid_payload = 1'b0;
            inject_invalid_output_base = -1;
            allow_numerical_error = 1'b0;
        end
    endtask

    task automatic run_expected_numerical_error_case;
        begin
            forced_data_delay = 0;
            distinct_payload_enable = 1'b0;
            inject_invalid_payload = 1'b1;
            inject_invalid_output_base = -1;
            allow_numerical_error = 1'b1;
            cfg_m = 32'd8;
            cfg_k = 32'd16;
            cfg_n = 32'd2;
            cfg_batch_count = 32'd1;
            pulse_stats_clear();
            pulse_start();
            wait_for_done(200000);
            require(config_error,
                    "invalid FP16 payload must fail the command closed");
            require(result_count == 0,
                    "invalid FP16 payload must not escape as a result");
            require(numerical_error_event_count > 0,
                    "invalid FP16 payload must raise a typed numerical event");
            require(committed_depth == 0,
                    "numerical-error exit must flush panel ownership");
            require(profile_panel_occupancy == 0,
                    "numerical-error exit must report zero occupancy");
            require(profile_result_fifo_enqueue_count == 0,
                    "poisoned result must not enter the FIFO");
            require(profile_result_fifo_dequeue_count == 0,
                    "poisoned result must not leave the FIFO");
            require(profile_result_fifo_occupancy == 0,
                    "poisoned result must leave FIFO empty");
            $display(
                "M7.4_INTEGRITY_ERROR config_error=%0b events=%0d results=%0d",
                config_error, numerical_error_event_count, result_count
            );
            inject_invalid_payload = 1'b0;
            allow_numerical_error = 1'b0;
        end
    endtask

    task automatic run_commit_release_alignment_probe(
        input integer probe_delay,
        output integer probe_hit
    );
        begin
            forced_data_delay = probe_delay;
            distinct_payload_enable = 1'b0;
            inject_invalid_payload = 1'b0;
            allow_numerical_error = 1'b0;
            cfg_m = 32'd8;
            cfg_k = 32'd48;
            cfg_n = 32'd2;
            cfg_batch_count = 32'd1;
            pulse_stats_clear();
            pulse_start();
            wait_for_done(300000);
            require(!config_error,
                    "alignment probe command must remain clean");
            require(request_count == 6,
                    "alignment probe request count mismatch");
            require(commit_count == 6,
                    "alignment probe commit count mismatch");
            require(consume_count == 6,
                    "alignment probe consume count mismatch");
            require(profile_result_fifo_enqueue_count == 2,
                    "alignment probe must enqueue two S8 results");
            require(profile_result_fifo_dequeue_count == 2,
                    "alignment probe must dequeue two S8 results");
            check_exact_result(32'h4240_0000, 32'h42c0_0000);
            probe_hit = (simultaneous_commit_release_count > 0);
            if (probe_hit)
                $display(
                    "M7.4_INTEGRITY_ATOMIC commit_release_delay=%0d count=%0d",
                    probe_delay,
                    simultaneous_commit_release_count
                );
        end
    endtask

    // Model the absolute write context that a later engine/frontend seam will
    // provide.  Immediately after enqueue, deliberately poison the live
    // inputs: the externally visible FIFO head must retain the pre-poison
    // address and the generation captured at command start.
    always_comb begin
        // Address follows the live tile context.  Once the scheduler advances,
        // an older FIFO head must retain the prior value while this input moves
        // naturally to the next tile.  Only generation is deliberately
        // poisoned after the first enqueue; the command-start snapshot must be
        // used by all entries from that command.
        result_address_base_i = result_address_seed +
            {18'd0, batch_index, 16'd0} +
            {26'd0, token_base, 8'd0} +
            {34'd0, output_base};
        result_generation_i = metadata_poison_enable ?
            ~result_generation_seed : result_generation_seed;
    end

    // The original Gate-1 cases retain their constant 1.0 activation and
    // 1.0/2.0 packed weights.  The integrity extension selects payloads that
    // differ by K chunk, output tile, token row and batch.  A dropped,
    // duplicated, stale or cross-bank panel therefore changes the numerical
    // result even though accumulation itself is commutative.  Poisoned upper
    // words continue to prove that only the packed-v3 lower B payload is used.
    always_comb begin
        activation_data = '0;
        weight_data = '0;
        bias_data = '0;
        for (row = 0; row < ARRAY_ROWS; row = row + 1) begin
            if (distinct_payload_enable)
                activation_scalar = 1 + token_base + row +
                                    (batch_index * 16);
            else
                activation_scalar = 1;
            for (lane = 0; lane < PE_LANES; lane = lane + 1)
                activation_data[(row*PE_LANES+lane)*32 +: 32] =
                    uint_to_fp32(activation_scalar);
        end
        for (lane = 0; lane < PE_LANES; lane = lane + 1) begin
            if (distinct_payload_enable) begin
                weight_scalar = (1 + output_base + (batch_index * 4)) <<
                                (k_base / PE_LANES);
                weight_data[lane*32 +: 16] =
                    uint_to_fp16(weight_scalar);
                weight_scalar = (2 + output_base + (batch_index * 4)) <<
                                (k_base / PE_LANES);
                weight_data[lane*32+16 +: 16] =
                    uint_to_fp16(weight_scalar);
            end else begin
                weight_data[lane*32 +: 16] = 16'h3c00;
                weight_data[lane*32+16 +: 16] = 16'h4000;
            end
            weight_data[(PE_LANES+lane)*32 +: 32] = 32'h7fc0_0000;
        end
        if (inject_invalid_payload &&
            ((inject_invalid_output_base < 0) ||
             (output_base == inject_invalid_output_base)))
            weight_data[15:0] = 16'h7e00;
    end

    vit_gemm_fp16_parallel_scheduler #(
        .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .PE_LANES(PE_LANES),
        .FP16_STREAMS(FP16_STREAMS)
    ) u_dut (
        .clk(clk),
        .rst(rst),
        .start(start),
        .cfg_m(cfg_m),
        .cfg_k(cfg_k),
        .cfg_n(cfg_n),
        .cfg_batch_count(cfg_batch_count),
        .cfg_bias_enable(cfg_bias_enable),
        .cfg_weight_fp16_packed2(cfg_weight_fp16_packed2),
        .busy(busy),
        .done(done),
        .config_error(config_error),
        .data_request(data_request),
        .data_valid(data_valid),
        .token_base(token_base),
        .output_base(output_base),
        .k_base(k_base),
        .batch_index(batch_index),
        .activation_data(activation_data),
        .weight_data(weight_data),
        .bias_data(bias_data),
        .result_address_base_i(result_address_base_i),
        .result_generation_i(result_generation_i),
        .result_valid(result_valid),
        .result_ready(result_ready),
        .result_address_base_o(result_address_base_o),
        .result_generation_o(result_generation_o),
        .result_token_base(result_token_base),
        .result_output_base(result_output_base),
        .result_batch_index(result_batch_index),
        .result_token_mask(result_token_mask),
        .result_output_mask(result_output_mask),
        .result_data(result_data),
        .profile_gemm_tile_step_o(profile_gemm_tile_step),
        .profile_valid_mac_delta_o(profile_valid_mac_delta),
        .profile_tail_mac_delta_o(profile_tail_mac_delta),
        .profile_term_accept_delta_o(profile_term_accept_delta),
        .profile_disabled_term_delta_o(profile_disabled_term_delta),
        .profile_input_wait_o(profile_input_wait),
        .profile_term_stall_o(profile_term_stall),
        .profile_result_backpressure_o(profile_result_backpressure),
        .profile_compute_active_o(profile_compute_active),
        .profile_dot_start_o(profile_dot_start),
        .profile_result_vector_o(profile_result_vector),
        .profile_invalid_delta_o(profile_invalid_delta),
        .profile_overflow_delta_o(profile_overflow_delta),
        .profile_length_error_delta_o(profile_length_error_delta),
        .profile_subnormal_flushed_delta_o(
            profile_subnormal_flushed_delta
        ),
        .profile_panel_load_active_o(profile_panel_load_active),
        .profile_panel_compute_active_o(profile_panel_compute_active),
        .profile_panel_commit_o(profile_panel_commit),
        .profile_panel_claim_o(profile_panel_claim),
        .profile_panel_claim_mask_o(profile_panel_claim_mask),
        .profile_panel_release_o(profile_panel_release),
        .profile_panel_empty_stall_o(profile_panel_empty_stall),
        .profile_panel_full_stall_o(profile_panel_full_stall),
        .profile_panel_occupancy_o(profile_panel_occupancy),
        .profile_result_fifo_enqueue_o(profile_result_fifo_enqueue),
        .profile_result_fifo_dequeue_o(profile_result_fifo_dequeue),
        .profile_result_fifo_full_stall_o(
            profile_result_fifo_full_stall
        ),
        .profile_result_fifo_occupancy_o(
            profile_result_fifo_occupancy
        )
    );

    // One response at a time, matching the existing frontend contract.  Delay
    // is deterministic-random (0..3 cycles) unless a reset test overrides it.
    always_ff @(posedge clk) begin
        if (rst || !responder_enable) begin
            data_valid <= 1'b0;
            request_pending <= 1'b0;
            response_delay <= 0;
            request_token_hold <= 32'd0;
            request_output_hold <= 32'd0;
            request_k_hold <= 32'd0;
            request_batch_hold <= 32'd0;
            data_lfsr <= DATA_SEED;
        end else begin
            data_lfsr <= lfsr_next(data_lfsr);

            if (data_valid) begin
                // The response is accepted on this edge.  Do not interpret the
                // still-high request level as a second request on the same edge.
                data_valid <= 1'b0;
                request_pending <= 1'b0;
            end else if (request_pending) begin
                require(data_request,
                        "data_request dropped before matching data_valid");
                require(token_base == request_token_hold,
                        "token coordinate changed while request outstanding");
                require(output_base == request_output_hold,
                        "output coordinate changed while request outstanding");
                require(k_base == request_k_hold,
                        "K coordinate changed while request outstanding");
                require(batch_index == request_batch_hold,
                        "batch coordinate changed while request outstanding");
                if (response_delay == 0)
                    data_valid <= 1'b1;
                else
                    response_delay <= response_delay - 1;
            end else if (data_request) begin
                request_pending <= 1'b1;
                request_token_hold <= token_base;
                request_output_hold <= output_base;
                request_k_hold <= k_base;
                request_batch_hold <= batch_index;
                if (forced_data_delay >= 0)
                    response_delay <= forced_data_delay;
                else
                    response_delay <= data_lfsr[1:0];
            end
        end
    end

    // Result backpressure always stalls at least one cycle, then uses a
    // deterministic-random 1..4-cycle hold interval for every result vector.
    always_ff @(posedge clk) begin
        if (rst || stats_clear || !responder_enable) begin
            result_ready <= 1'b0;
            result_wait_active <= 1'b0;
            result_wait_remaining <= 0;
            ready_lfsr <= READY_SEED;
        end else if (result_force_block) begin
            result_ready <= 1'b0;
            result_wait_active <= 1'b0;
            result_wait_remaining <= 0;
            ready_lfsr <= lfsr_next(ready_lfsr);
        end else if (result_manual_mode) begin
            result_ready <= result_manual_ready;
            result_wait_active <= 1'b0;
            result_wait_remaining <= 0;
            ready_lfsr <= lfsr_next(ready_lfsr);
        end else begin
            ready_lfsr <= lfsr_next(ready_lfsr);
            if (!result_valid) begin
                result_ready <= 1'b0;
                result_wait_active <= 1'b0;
            end else if (!result_wait_active) begin
                result_ready <= 1'b0;
                result_wait_active <= 1'b1;
                result_wait_remaining <= 1 + ready_lfsr[1:0];
            end else if (result_wait_remaining != 0) begin
                result_ready <= 1'b0;
                result_wait_remaining <= result_wait_remaining - 1;
            end else begin
                result_ready <= 1'b1;
            end
        end
    end

    // External ownership scoreboard.  A commit is a delivered frontend panel;
    // a consume is the bridge chunk handshake exposed by tile_step.  This
    // remains valid without reaching into implementation-specific bank names.
    always_ff @(posedge clk) begin
        if (rst || stats_clear) begin
            request_count <= 0;
            commit_count <= 0;
            consume_count <= 0;
            committed_depth <= 0;
            max_committed_depth <= 0;
            request_compute_overlap_cycles <= 0;
            commit_compute_overlap_count <= 0;
            compute_active_cycles <= 0;
            result_count <= 0;
            result_backpressure_cycles <= 0;
            profile_panel_commit_count <= 0;
            profile_panel_claim_count <= 0;
            profile_panel_release_count <= 0;
            profile_bank0_claim_count <= 0;
            profile_bank1_claim_count <= 0;
            profile_panel_max_occupancy <= 0;
            profile_panel_empty_stall_cycles <= 0;
            profile_panel_full_stall_cycles <= 0;
            profile_result_fifo_enqueue_count <= 0;
            profile_result_fifo_dequeue_count <= 0;
            profile_result_fifo_full_stall_cycles <= 0;
            profile_result_fifo_max_occupancy <= 0;
            simultaneous_commit_claim_count <= 0;
            simultaneous_commit_release_count <= 0;
            last_chunk_release_count <= 0;
            numerical_error_event_count <= 0;
            compute_fifo_overlap_cycles <= 0;
            full_simultaneous_push_pop_count <= 0;
            final_drain_depth_two_cycles <= 0;
            live_address_divergence_cycles <= 0;
            dequeue_compute_overlap_count <= 0;
            captured_result_data <= '0;
            captured_token_mask <= '0;
            captured_output_mask <= '0;
            captured_result_token <= 32'd0;
            captured_result_output <= 32'd0;
            captured_result_batch <= 32'd0;
            captured_result_address <= 66'd0;
            captured_result_generation <= 8'd0;
            result_hold_valid <= 1'b0;
            result_hold_data <= '0;
            result_hold_address <= 66'd0;
            result_hold_generation <= 8'd0;
            result_hold_token <= 32'd0;
            result_hold_output <= 32'd0;
            result_hold_batch <= 32'd0;
            result_hold_token_mask <= '0;
            result_hold_output_mask <= '0;
            metadata_poison_enable <= 1'b0;
            for (capture_index = 0;
                 capture_index < MAX_CAPTURED_RESULTS;
                 capture_index = capture_index + 1) begin
                result_data_log[capture_index] <= '0;
                result_token_mask_log[capture_index] <= '0;
                result_output_mask_log[capture_index] <= '0;
                result_token_log[capture_index] <= 32'd0;
                result_output_log[capture_index] <= 32'd0;
                result_batch_log[capture_index] <= 32'd0;
                result_address_log[capture_index] <= 66'd0;
                result_generation_log[capture_index] <= 8'd0;
                fifo_expected_address_log[capture_index] <= 66'd0;
                fifo_expected_generation_log[capture_index] <= 8'd0;
                fifo_expected_token_log[capture_index] <= 32'd0;
                fifo_expected_output_log[capture_index] <= 32'd0;
                fifo_expected_batch_log[capture_index] <= 32'd0;
                fifo_expected_token_mask_log[capture_index] <= '0;
                fifo_expected_output_mask_log[capture_index] <= '0;
                fifo_expected_data_log[capture_index] <= '0;
            end
        end else begin
            if (!request_pending && !data_valid && data_request) begin
                expected_chunks_per_tile =
                    (cfg_k + PE_LANES - 1) / PE_LANES;
                expected_tile_index = request_count /
                                      expected_chunks_per_tile;
                expected_chunk_index = request_count %
                                       expected_chunks_per_tile;
                expected_output_column = expected_tile_index % cfg_n;
                expected_output_tile = expected_output_column / ARRAY_COLS;
                expected_token_tile =
                    (expected_tile_index / cfg_n) %
                    ((cfg_m + ARRAY_ROWS - 1) / ARRAY_ROWS);
                expected_batch = expected_tile_index /
                    (cfg_n *
                     ((cfg_m + ARRAY_ROWS - 1) / ARRAY_ROWS));
                expected_request_k = expected_chunk_index * PE_LANES;
                expected_token_coord = expected_token_tile * ARRAY_ROWS;
                expected_output_coord = expected_output_tile * ARRAY_COLS;
                require(k_base == expected_request_k,
                        "K request order must be contiguous and unrepeated");
                require(token_base == expected_token_coord,
                        "request token coordinate/order mismatch");
                require(output_base == expected_output_coord,
                        "request output coordinate/order mismatch");
                require(batch_index == expected_batch,
                        "request batch coordinate/order mismatch");
                require(u_dut.fallback_column_q ==
                            (expected_output_column % ARRAY_COLS),
                        "request S8 column-pass order mismatch");
                request_count <= request_count + 1;
            end

            depth_next = committed_depth;
            if (data_valid) begin
                commit_count <= commit_count + 1;
                depth_next = depth_next + 1;
            end
            if (profile_gemm_tile_step) begin
                consume_count <= consume_count + 1;
                depth_next = depth_next - 1;
            end
            require(depth_next >= 0,
                    "panel consumed without a preceding frontend commit");
            require(depth_next <= 2,
                    "more than two committed panels violates ping-pong depth");
            committed_depth <= depth_next;
            if (depth_next > max_committed_depth)
                max_committed_depth <= depth_next;

            if (profile_compute_active)
                compute_active_cycles <= compute_active_cycles + 1;
            if (profile_compute_active &&
                (profile_result_fifo_occupancy != 0))
                compute_fifo_overlap_cycles <=
                    compute_fifo_overlap_cycles + 1;
            if (data_request && profile_compute_active)
                request_compute_overlap_cycles <=
                    request_compute_overlap_cycles + 1;
            if (data_valid && profile_compute_active)
                commit_compute_overlap_count <=
                    commit_compute_overlap_count + 1;

            if (result_valid && !result_ready)
                result_backpressure_cycles <=
                    result_backpressure_cycles + 1;

            require(profile_panel_occupancy <= 2,
                    "reported panel occupancy exceeds two banks");
            if (profile_panel_occupancy > profile_panel_max_occupancy)
                profile_panel_max_occupancy <= profile_panel_occupancy;
            if (busy)
                require(profile_panel_load_active === data_request,
                        "packed profile load-active must match request owner");
            require(profile_panel_compute_active ===
                        profile_compute_active,
                    "packed panel compute-active must use exact bridge stage");
            if (profile_panel_commit)
                profile_panel_commit_count <=
                    profile_panel_commit_count + 1;
            if (profile_panel_claim) begin
                profile_panel_claim_count <= profile_panel_claim_count + 1;
                require((profile_panel_claim_mask == 2'b01) ||
                        (profile_panel_claim_mask == 2'b10),
                        "panel claim mask must be one-hot");
                if (profile_panel_claim_mask[0])
                    profile_bank0_claim_count <=
                        profile_bank0_claim_count + 1;
                if (profile_panel_claim_mask[1])
                    profile_bank1_claim_count <=
                        profile_bank1_claim_count + 1;

                claimed_bank_index = profile_panel_claim_mask[1] ? 1 : 0;
                expected_chunks_per_tile =
                    (cfg_k + PE_LANES - 1) / PE_LANES;
                expected_tile_index = profile_panel_claim_count /
                                      expected_chunks_per_tile;
                expected_chunk_index = profile_panel_claim_count %
                                       expected_chunks_per_tile;
                expected_output_column = expected_tile_index % cfg_n;
                expected_output_tile = expected_output_column / ARRAY_COLS;
                expected_token_tile =
                    (expected_tile_index / cfg_n) %
                    ((cfg_m + ARRAY_ROWS - 1) / ARRAY_ROWS);
                expected_batch = expected_tile_index /
                    (cfg_n *
                     ((cfg_m + ARRAY_ROWS - 1) / ARRAY_ROWS));
                claimed_k_coord = expected_chunk_index * PE_LANES;
                require(u_dut.panel_state_q[claimed_bank_index] ==
                            u_dut.PANEL_READY,
                        "claim must select a READY panel bank");
                require(u_dut.panel_k_q[claimed_bank_index] ==
                            claimed_k_coord,
                        "claimed K panel reordered, replayed or dropped");
                require(u_dut.panel_token_q[claimed_bank_index] ==
                            expected_token_tile * ARRAY_ROWS,
                        "claimed panel token owner mismatch");
                require(u_dut.panel_output_q[claimed_bank_index] ==
                            expected_output_tile * ARRAY_COLS,
                        "claimed panel output owner mismatch");
                require(u_dut.panel_batch_q[claimed_bank_index] ==
                            expected_batch,
                        "claimed panel batch owner mismatch");
                require(u_dut.fallback_column_q ==
                            (expected_output_column % ARRAY_COLS),
                        "claimed panel S8 column-pass mismatch");
                require(u_dut.panel_last_q[claimed_bank_index] ===
                            ((claimed_k_coord + PE_LANES) >= cfg_k),
                        "claimed panel TLAST metadata mismatch");
            end else begin
                require(profile_panel_claim_mask == 2'b00,
                        "claim mask must be zero without a claim event");
            end
            if (profile_panel_release) begin
                profile_panel_release_count <=
                    profile_panel_release_count + 1;
                expected_chunks_per_tile =
                    (cfg_k + PE_LANES - 1) / PE_LANES;
                expected_tile_index = profile_panel_release_count /
                                      expected_chunks_per_tile;
                expected_chunk_index = profile_panel_release_count %
                                       expected_chunks_per_tile;
                expected_output_column = expected_tile_index % cfg_n;
                expected_output_tile = expected_output_column / ARRAY_COLS;
                expected_token_tile =
                    (expected_tile_index / cfg_n) %
                    ((cfg_m + ARRAY_ROWS - 1) / ARRAY_ROWS);
                expected_batch = expected_tile_index /
                    (cfg_n *
                     ((cfg_m + ARRAY_ROWS - 1) / ARRAY_ROWS));
                released_k_coord = expected_chunk_index * PE_LANES;
                require(u_dut.panel_state_q[u_dut.compute_bank_q] ==
                            u_dut.PANEL_COMPUTE,
                        "release must select the COMPUTE panel bank");
                require(u_dut.panel_k_q[u_dut.compute_bank_q] ==
                            released_k_coord,
                        "released K panel reordered, replayed or dropped");
                require(u_dut.panel_token_q[u_dut.compute_bank_q] ==
                            expected_token_tile * ARRAY_ROWS,
                        "released panel token owner mismatch");
                require(u_dut.panel_output_q[u_dut.compute_bank_q] ==
                            expected_output_tile * ARRAY_COLS,
                        "released panel output owner mismatch");
                require(u_dut.panel_batch_q[u_dut.compute_bank_q] ==
                            expected_batch,
                        "released panel batch owner mismatch");
                require(u_dut.fallback_column_q ==
                            (expected_output_column % ARRAY_COLS),
                        "released panel S8 column-pass mismatch");
                require(u_dut.last_k_chunk ===
                            ((released_k_coord + PE_LANES) >= cfg_k),
                        "released panel TLAST mismatch");

                observed_valid_lanes = 0;
                for (score_lane = 0; score_lane < PE_LANES;
                     score_lane = score_lane + 1) begin
                    require(u_dut.lane_valid[score_lane] ===
                                ((released_k_coord + score_lane) < cfg_k),
                            "released panel lane-tail mask mismatch");
                    if (u_dut.lane_valid[score_lane])
                        observed_valid_lanes = observed_valid_lanes + 1;
                end
                expected_valid_lanes = cfg_k - released_k_coord;
                if (expected_valid_lanes > PE_LANES)
                    expected_valid_lanes = PE_LANES;
                require(observed_valid_lanes == expected_valid_lanes,
                        "released panel valid-lane population mismatch");
                for (score_row = 0; score_row < ARRAY_ROWS;
                     score_row = score_row + 1)
                    require(u_dut.token_valid[score_row] ===
                                ((expected_token_tile * ARRAY_ROWS +
                                  score_row) <
                                 cfg_m),
                            "released panel token-tail mask mismatch");
                for (score_col = 0; score_col < ARRAY_COLS;
                     score_col = score_col + 1)
                    require(u_dut.output_valid[score_col] ===
                                ((expected_output_tile * ARRAY_COLS +
                                  score_col) < cfg_n),
                            "released panel output-tail mask mismatch");
                if ((released_k_coord + PE_LANES) >= cfg_k)
                    last_chunk_release_count <=
                        last_chunk_release_count + 1;
            end
            require(profile_panel_commit === data_valid,
                    "profile commit must match frontend data_valid");
            require(profile_panel_release === profile_gemm_tile_step,
                    "profile release must match bridge chunk consume");
            if (profile_panel_empty_stall)
                profile_panel_empty_stall_cycles <=
                    profile_panel_empty_stall_cycles + 1;
            if (profile_panel_full_stall)
                profile_panel_full_stall_cycles <=
                    profile_panel_full_stall_cycles + 1;
            require(profile_result_fifo_occupancy <= 2,
                    "result FIFO occupancy exceeds physical depth");
            if (profile_result_fifo_occupancy >
                profile_result_fifo_max_occupancy)
                profile_result_fifo_max_occupancy <=
                    profile_result_fifo_occupancy;
            if (profile_result_fifo_full_stall)
                profile_result_fifo_full_stall_cycles <=
                    profile_result_fifo_full_stall_cycles + 1;
            if (profile_result_fifo_enqueue &&
                profile_result_fifo_dequeue &&
                (profile_result_fifo_occupancy == 2))
                full_simultaneous_push_pop_count <=
                    full_simultaneous_push_pop_count + 1;
            if ((u_dut.state == u_dut.STATE_PACK_DRAIN_RESULT) &&
                (profile_result_fifo_occupancy == 2))
                final_drain_depth_two_cycles <=
                    final_drain_depth_two_cycles + 1;
            if (profile_result_fifo_dequeue && profile_compute_active)
                dequeue_compute_overlap_count <=
                    dequeue_compute_overlap_count + 1;
            if (profile_result_fifo_enqueue) begin
                require(cfg_weight_fp16_packed2,
                        "result FIFO enqueue escaped packed mode");
                require(profile_result_fifo_enqueue_count <
                            MAX_CAPTURED_RESULTS,
                        "expected FIFO enqueue log overflow");
                if (profile_result_fifo_enqueue_count <
                    MAX_CAPTURED_RESULTS) begin
                    fifo_expected_address_log[
                        profile_result_fifo_enqueue_count
                    ] <= result_address_base_i;
                    fifo_expected_generation_log[
                        profile_result_fifo_enqueue_count
                    ] <= u_dut.active_result_generation;
                    fifo_expected_token_log[
                        profile_result_fifo_enqueue_count
                    ] <= u_dut.panel_token_q[u_dut.compute_bank_q];
                    fifo_expected_output_log[
                        profile_result_fifo_enqueue_count
                    ] <= u_dut.panel_output_q[u_dut.compute_bank_q];
                    fifo_expected_batch_log[
                        profile_result_fifo_enqueue_count
                    ] <= u_dut.panel_batch_q[u_dut.compute_bank_q];
                    fifo_expected_token_mask_log[
                        profile_result_fifo_enqueue_count
                    ] <= u_dut.bridge_result_token_mask;
                    fifo_expected_output_mask_log[
                        profile_result_fifo_enqueue_count
                    ] <= u_dut.bridge_result_output_mask;
                    fifo_expected_data_log[
                        profile_result_fifo_enqueue_count
                    ] <= u_dut.bridge_result_data;
                end
                profile_result_fifo_enqueue_count <=
                    profile_result_fifo_enqueue_count + 1;
                metadata_poison_enable <= 1'b1;
            end
            if (profile_result_fifo_dequeue) begin
                require(profile_result_fifo_dequeue_count <
                            profile_result_fifo_enqueue_count,
                        "result FIFO dequeued without captured identity");
                profile_result_fifo_dequeue_count <=
                    profile_result_fifo_dequeue_count + 1;
            end
            require(profile_result_fifo_occupancy ==
                        (profile_result_fifo_enqueue_count -
                         profile_result_fifo_dequeue_count),
                    "DUT FIFO occupancy disagrees with expected queue depth");
            if (result_valid) begin
                require(profile_result_fifo_dequeue_count <
                            profile_result_fifo_enqueue_count,
                        "packed visible result lacks FIFO ownership");
                require(result_address_base_o ===
                            fifo_expected_address_log[
                                profile_result_fifo_dequeue_count],
                        "FIFO absolute address was not retained");
                require(result_generation_o ===
                            fifo_expected_generation_log[
                                profile_result_fifo_dequeue_count],
                        "FIFO generation was not retained");
                require(result_token_base ===
                            fifo_expected_token_log[
                                profile_result_fifo_dequeue_count],
                        "FIFO token coordinate was not retained");
                require(result_output_base ===
                            fifo_expected_output_log[
                                profile_result_fifo_dequeue_count],
                        "FIFO output coordinate was not retained");
                require(result_batch_index ===
                            fifo_expected_batch_log[
                                profile_result_fifo_dequeue_count],
                        "FIFO batch coordinate was not retained");
                require(result_token_mask ===
                            fifo_expected_token_mask_log[
                                profile_result_fifo_dequeue_count],
                        "FIFO token mask was not retained");
                require(result_output_mask ===
                            fifo_expected_output_mask_log[
                                profile_result_fifo_dequeue_count],
                        "FIFO output mask was not retained");
                require(result_data ===
                            fifo_expected_data_log[
                                profile_result_fifo_dequeue_count],
                        "FIFO result data was not retained");
                if (result_address_base_i !== result_address_base_o)
                    live_address_divergence_cycles <=
                        live_address_divergence_cycles + 1;
            end
            if (done) begin
                require(profile_result_fifo_occupancy == 0,
                        "DONE asserted before result FIFO drained");
                require(profile_result_fifo_enqueue_count ==
                            profile_result_fifo_dequeue_count,
                        "DONE asserted before every FIFO enqueue was popped");
                require(!result_valid && !data_request,
                        "DONE asserted with visible result or data request");
                require((profile_panel_occupancy == 0) &&
                        !profile_compute_active,
                        "DONE asserted with active packed stage");
            end
            if (profile_panel_commit && profile_panel_claim)
                simultaneous_commit_claim_count <=
                    simultaneous_commit_claim_count + 1;
            if (profile_panel_commit && profile_panel_release)
                simultaneous_commit_release_count <=
                    simultaneous_commit_release_count + 1;

            if (result_valid && !result_ready) begin
                if (!result_hold_valid) begin
                    result_hold_valid <= 1'b1;
                    result_hold_data <= result_data;
                    result_hold_address <= result_address_base_o;
                    result_hold_generation <= result_generation_o;
                    result_hold_token <= result_token_base;
                    result_hold_output <= result_output_base;
                    result_hold_batch <= result_batch_index;
                    result_hold_token_mask <= result_token_mask;
                    result_hold_output_mask <= result_output_mask;
                end else begin
                    require(result_data === result_hold_data,
                            "result data changed under backpressure");
                    require(result_address_base_o === result_hold_address,
                            "result address changed under backpressure");
                    require(result_generation_o === result_hold_generation,
                            "result generation changed under backpressure");
                    require(result_token_base === result_hold_token,
                            "result token changed under backpressure");
                    require(result_output_base === result_hold_output,
                            "result output changed under backpressure");
                    require(result_batch_index === result_hold_batch,
                            "result batch changed under backpressure");
                    require(result_token_mask === result_hold_token_mask,
                            "result token mask changed under backpressure");
                    require(result_output_mask === result_hold_output_mask,
                            "result output mask changed under backpressure");
                end
            end

            if (result_valid && result_ready) begin
                if (result_hold_valid) begin
                    require(result_data === result_hold_data,
                            "held result changed on release cycle");
                    require(result_address_base_o === result_hold_address,
                            "held address changed on release cycle");
                    require(result_generation_o === result_hold_generation,
                            "held generation changed on release cycle");
                    require(result_token_base === result_hold_token,
                            "held token changed on release cycle");
                    require(result_output_base === result_hold_output,
                            "held output changed on release cycle");
                    require(result_batch_index === result_hold_batch,
                            "held batch changed on release cycle");
                    require(result_token_mask === result_hold_token_mask,
                            "held token mask changed on release cycle");
                    require(result_output_mask === result_hold_output_mask,
                            "held output mask changed on release cycle");
                end
                result_hold_valid <= 1'b0;
                result_count <= result_count + 1;
                captured_result_data <= result_data;
                captured_token_mask <= result_token_mask;
                captured_output_mask <= result_output_mask;
                captured_result_token <= result_token_base;
                captured_result_output <= result_output_base;
                captured_result_batch <= result_batch_index;
                captured_result_address <= result_address_base_o;
                captured_result_generation <= result_generation_o;
                require(result_count < MAX_CAPTURED_RESULTS,
                        "result capture log overflow");
                if (result_count < MAX_CAPTURED_RESULTS) begin
                    result_data_log[result_count] <= result_data;
                    result_token_mask_log[result_count] <= result_token_mask;
                    result_output_mask_log[result_count] <= result_output_mask;
                    result_token_log[result_count] <= result_token_base;
                    result_output_log[result_count] <= result_output_base;
                    result_batch_log[result_count] <= result_batch_index;
                    result_address_log[result_count] <=
                        result_address_base_o;
                    result_generation_log[result_count] <=
                        result_generation_o;
                end
            end

            numerical_error_event_count <= numerical_error_event_count +
                profile_invalid_delta + profile_overflow_delta +
                profile_length_error_delta;
            if (!allow_numerical_error) begin
                require(!(profile_invalid_delta != 0),
                        "finite packed test produced invalid result");
                require(!(profile_overflow_delta != 0),
                        "finite packed test produced overflow result");
                require(!(profile_length_error_delta != 0),
                        "finite packed test produced length error");
            end
        end
    end

    initial begin
        start = 1'b0;
        stats_clear = 1'b0;
        responder_enable = 1'b0;
        distinct_payload_enable = 1'b0;
        inject_invalid_payload = 1'b0;
        inject_invalid_output_base = -1;
        allow_numerical_error = 1'b0;
        result_force_block = 1'b0;
        result_manual_mode = 1'b0;
        result_manual_ready = 1'b0;
        forced_data_delay = -1;
        cfg_m = 32'd8;
        cfg_k = 32'd48;
        cfg_n = 32'd2;
        cfg_batch_count = 32'd1;
        cfg_bias_enable = 1'b0;
        cfg_weight_fp16_packed2 = 1'b1;
        result_address_seed = 66'h1_2345_6789;
        result_generation_seed = 8'hfe;

        $display(
            "M7.4_GATE1 seeds data=0x%08x ready=0x%08x",
            DATA_SEED, READY_SEED
        );

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;
        responder_enable = 1'b1;

        // Reset with an outstanding request/response owner.
        forced_data_delay = 8;
        pulse_stats_clear();
        pulse_start();
        wait (request_pending && (response_delay > 0));
        repeat (2) @(posedge clk);
        require(request_pending && !data_valid,
                "reset-request test must have one outstanding request");
        pulse_reset();

        // Reset after a next panel has committed while the previous chunk is
        // still computing.  This is the one-slot overlap current RTL already
        // provides; a fresh tail run below proves stale data is not consumed.
        forced_data_delay = 0;
        cfg_k = 32'd48;
        pulse_stats_clear();
        pulse_start();
        while (!((committed_depth > 0) && profile_compute_active))
            @(posedge clk);
        require(commit_count >= 2,
                "reset-prefetch test must reach a committed look-ahead panel");
        pulse_reset();

        // Packed K tails with randomized response latency and result stalls.
        run_packed_case(17, 32'h4188_0000, 32'h4208_0000, 1'b0, 1'b0);
        run_packed_case(31, 32'h41f8_0000, 32'h4278_0000, 1'b0, 1'b0);
        run_packed_case(33, 32'h4204_0000, 32'h4284_0000, 1'b1, 1'b0);

        // Fast enough randomized frontend responses let a true two-bank
        // scheduler commit chunks K16 and K32 while chunk K0 computes.  The
        // current one-slot scheduler reaches only depth 1 and must fail here.
        run_packed_case(48, 32'h4240_0000, 32'h42c0_0000, 1'b1, 1'b1);

        // With two banks and one frontend request outstanding, commit+claim
        // is structurally excluded: a READY bank is claimed before the newly
        // RESERVED bank can return.  Commit+release is reachable when the
        // frontend response lands on the current chunk-consume edge.  Sweep a
        // bounded deterministic latency to exercise that atomic ownership
        // transition instead of relying on a lucky pseudo-random phase.
        alignment_hit = 0;
        for (alignment_delay = 0;
             (alignment_delay <= 256) && !alignment_hit;
             alignment_delay = alignment_delay + 1)
            run_commit_release_alignment_probe(
                alignment_delay,
                alignment_hit
            );
        require(alignment_hit,
                "no reachable simultaneous panel commit+release observed");

        // K-distinct payloads plus partial M/N tails, two output tiles and two
        // batches catch panel replay/cross-owner corruption that constant
        // operands cannot expose numerically.
        run_distinct_multitile_case();

        // Gate-2 result overlap: fill both FIFO entries, hold a third result,
        // then release into a simultaneous full pop+push and depth-2 drain.
        run_gate2_fifo_depth_case();
        run_gate2_fifo_reset_case();
        run_gate2_error_drain_case();

        // The scheduler interface has no frontend transport-error input, so
        // error injection here targets the arithmetic fail-closed path.
        run_expected_numerical_error_case();
        pulse_reset();
        run_packed_case(17, 32'h4188_0000, 32'h4208_0000, 1'b0, 1'b0);

        $display(
            "PASS M7.4 scheduler ping-pong Gate-2 checks=%0d integrity=1",
            checks
        );
        $finish;
    end

    initial begin
        #20_000_000;
        $fatal(1, "M7.4_GATE1_INVARIANT_FAIL: global timeout");
    end

endmodule
