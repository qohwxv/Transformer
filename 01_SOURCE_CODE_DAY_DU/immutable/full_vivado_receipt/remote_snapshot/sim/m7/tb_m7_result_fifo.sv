`timescale 1ns/1ps

// Isolated depth-2 FIFO scoreboard.  Directed cases cover full simultaneous
// pop+push, a held head under backpressure, and flush/reset.  The randomized
// phase then checks every accepted 692-bit entry in FIFO order.
module tb_m7_result_fifo;

    localparam integer ARRAY_ROWS = 8;
    localparam integer ARRAY_COLS = 2;
    localparam integer GENERATION_BITS = 8;
    localparam integer DATA_BITS = ARRAY_ROWS * ARRAY_COLS * 32;
    localparam integer ENTRY_BITS =
        DATA_BITS + 66 + 32 + 32 + 32 +
        ARRAY_ROWS + ARRAY_COLS + GENERATION_BITS;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic flush_i = 1'b0;

    logic input_valid_i = 1'b0;
    logic input_ready_o;
    logic [65:0] input_address_base_i = '0;
    logic [31:0] input_token_base_i = '0;
    logic [31:0] input_output_base_i = '0;
    logic [31:0] input_batch_index_i = '0;
    logic [ARRAY_ROWS-1:0] input_token_mask_i = '0;
    logic [ARRAY_COLS-1:0] input_output_mask_i = '0;
    logic [GENERATION_BITS-1:0] input_generation_i = '0;
    logic [DATA_BITS-1:0] input_data_i = '0;

    logic output_valid_o;
    logic output_ready_i = 1'b0;
    logic [65:0] output_address_base_o;
    logic [31:0] output_token_base_o;
    logic [31:0] output_output_base_o;
    logic [31:0] output_batch_index_o;
    logic [ARRAY_ROWS-1:0] output_token_mask_o;
    logic [ARRAY_COLS-1:0] output_output_mask_o;
    logic [GENERATION_BITS-1:0] output_generation_o;
    logic [DATA_BITS-1:0] output_data_o;
    logic push_fire_o;
    logic pop_fire_o;
    logic [1:0] occupancy_o;

    logic [ENTRY_BITS-1:0] expected_memory [0:1];
    logic expected_read_pointer = 1'b0;
    logic expected_write_pointer = 1'b0;
    integer expected_count = 0;
    logic [ENTRY_BITS-1:0] held_head = '0;
    logic previous_stalled = 1'b0;

    integer checks = 0;
    integer failures = 0;
    integer accepted_pushes = 0;
    integer accepted_pops = 0;
    integer full_exchanges = 0;
    integer flushes = 0;
    integer stalled_head_cycles = 0;
    integer sequence_number = 0;
    integer random_cycle;
    logic [31:0] random_state = 32'h3ad5_7c91;

    logic sampled_push;
    logic sampled_pop;
    logic [ENTRY_BITS-1:0] sampled_input_entry;
    logic [ENTRY_BITS-1:0] observed_output_entry;

    always #5 clk = ~clk;

    function automatic logic [31:0] lfsr_next(input logic [31:0] value);
        begin
            lfsr_next = {value[30:0],
                         value[31] ^ value[21] ^ value[1] ^ value[0]};
        end
    endfunction

    function automatic logic [31:0] data_word(
        input integer sequence_value,
        input integer word_value
    );
        begin
            data_word = 32'hc700_0000 ^
                        (32'(sequence_value) * 32'h0001_0101) ^
                        (32'(word_value) * 32'h0100_0011);
        end
    endfunction

    function automatic logic [ENTRY_BITS-1:0] pack_input;
        begin
            pack_input = {
                input_generation_i,
                input_batch_index_i,
                input_output_base_i,
                input_token_base_i,
                input_address_base_i,
                input_output_mask_i,
                input_token_mask_i,
                input_data_i
            };
        end
    endfunction

    function automatic logic [ENTRY_BITS-1:0] pack_output;
        begin
            pack_output = {
                output_generation_o,
                output_batch_index_o,
                output_output_base_o,
                output_token_base_o,
                output_address_base_o,
                output_output_mask_o,
                output_token_mask_o,
                output_data_o
            };
        end
    endfunction

    task automatic check_true(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $error("%s", message);
            end
        end
    endtask

    task automatic drive_entry(input integer sequence_value);
        integer word_index;
        begin
            input_address_base_i =
                {34'(sequence_value),
                 32'h2000_0000 + 32'(sequence_value)};
            input_token_base_i = 32'(sequence_value * 8);
            input_output_base_i = 32'(sequence_value * 2);
            input_batch_index_i = 32'(sequence_value >> 3);
            input_token_mask_i = 8'hff ^ 8'(sequence_value);
            input_output_mask_i = (sequence_value[0]) ? 2'b01 : 2'b11;
            input_generation_i = 8'(sequence_value);
            for (word_index = 0; word_index < 16;
                 word_index = word_index + 1)
                input_data_i[word_index*32 +: 32] =
                    data_word(sequence_value, word_index);
        end
    endtask

    vit_gemm_result_fifo #(
        .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .GENERATION_BITS(GENERATION_BITS),
        .DEPTH(2)
    ) u_fifo (
        .clk(clk),
        .rst(rst),
        .flush_i(flush_i),
        .input_valid_i(input_valid_i),
        .input_ready_o(input_ready_o),
        .input_address_base_i(input_address_base_i),
        .input_token_base_i(input_token_base_i),
        .input_output_base_i(input_output_base_i),
        .input_batch_index_i(input_batch_index_i),
        .input_token_mask_i(input_token_mask_i),
        .input_output_mask_i(input_output_mask_i),
        .input_generation_i(input_generation_i),
        .input_data_i(input_data_i),
        .output_valid_o(output_valid_o),
        .output_ready_i(output_ready_i),
        .output_address_base_o(output_address_base_o),
        .output_token_base_o(output_token_base_o),
        .output_output_base_o(output_output_base_o),
        .output_batch_index_o(output_batch_index_o),
        .output_token_mask_o(output_token_mask_o),
        .output_output_mask_o(output_output_mask_o),
        .output_generation_o(output_generation_o),
        .output_data_o(output_data_o),
        .push_fire_o(push_fire_o),
        .pop_fire_o(pop_fire_o),
        .occupancy_o(occupancy_o)
    );

    // Sample and update the reference FIFO at the same edge as the DUT.
    always @(posedge clk) begin
        if (rst || flush_i) begin
            expected_read_pointer = 1'b0;
            expected_write_pointer = 1'b0;
            expected_count = 0;
            previous_stalled = 1'b0;
            if (flush_i && !rst)
                flushes = flushes + 1;
            #1;
            check_true(occupancy_o == 2'd0,
                       "reset/flush clears occupancy");
            check_true(!output_valid_o,
                       "reset/flush clears output valid");
            check_true(!push_fire_o && !pop_fire_o,
                       "reset/flush suppresses event hooks");
        end else begin
            sampled_input_entry = pack_input();
            observed_output_entry = pack_output();
            sampled_push = push_fire_o;
            sampled_pop = pop_fire_o;

            check_true(output_valid_o == (expected_count != 0),
                       "pre-edge output-valid matches reference occupancy");
            check_true(occupancy_o == expected_count[1:0],
                       "pre-edge occupancy matches reference FIFO");
            check_true(sampled_push == (input_valid_i && input_ready_o),
                       "push hook is exact ready/valid handshake");
            check_true(sampled_pop == (output_valid_o && output_ready_i),
                       "pop hook is exact ready/valid handshake");

            if (expected_count != 0)
                check_true(
                    observed_output_entry ==
                        expected_memory[expected_read_pointer],
                    "head metadata and payload match FIFO order"
                );
            else
                check_true(observed_output_entry == '0,
                           "empty FIFO drives a deterministic zero entry");

            if (previous_stalled) begin
                check_true(output_valid_o,
                           "stalled head remains valid");
                check_true(observed_output_entry == held_head,
                           "stalled head remains bit-stable");
                stalled_head_cycles = stalled_head_cycles + 1;
            end

            previous_stalled = output_valid_o && !output_ready_i;
            if (previous_stalled)
                held_head = observed_output_entry;

            if ((expected_count == 2) && sampled_push && sampled_pop)
                full_exchanges = full_exchanges + 1;

            if (sampled_pop) begin
                expected_read_pointer = ~expected_read_pointer;
                accepted_pops = accepted_pops + 1;
            end
            if (sampled_push) begin
                expected_memory[expected_write_pointer] =
                    sampled_input_entry;
                expected_write_pointer = ~expected_write_pointer;
                accepted_pushes = accepted_pushes + 1;
            end
            case ({sampled_push, sampled_pop})
                2'b10: expected_count = expected_count + 1;
                2'b01: expected_count = expected_count - 1;
                default: expected_count = expected_count;
            endcase

            check_true((expected_count >= 0) && (expected_count <= 2),
                       "reference occupancy stays within depth two");
            #1;
            check_true(occupancy_o == expected_count[1:0],
                       "post-edge occupancy matches accepted handshakes");
            check_true(output_valid_o == (expected_count != 0),
                       "post-edge output-valid matches updated occupancy");
            if (expected_count != 0)
                check_true(pack_output() ==
                               expected_memory[expected_read_pointer],
                           "post-edge head matches updated FIFO order");
            else
                check_true(pack_output() == '0,
                           "post-edge empty output remains zero");
        end
    end

    task automatic push_one(input integer sequence_value);
        begin
            @(negedge clk);
            drive_entry(sequence_value);
            input_valid_i = 1'b1;
            while (!input_ready_o)
                @(negedge clk);
            @(posedge clk);
            @(negedge clk);
            input_valid_i = 1'b0;
        end
    endtask

    initial begin
        // Synchronous reset.
        repeat (3) @(negedge clk);
        rst = 1'b0;

        // Fill both slots, then hold a third result while the full FIFO and
        // store backpressure keep the original head stable.
        push_one(1);
        push_one(2);
        @(negedge clk);
        drive_entry(3);
        input_valid_i = 1'b1;
        output_ready_i = 1'b0;
        repeat (4) @(negedge clk);
        check_true(!input_ready_o,
                   "full FIFO rejects push without a simultaneous pop");

        // Full pop+push: result 1 leaves while result 3 enters.  The FIFO
        // remains full and the next visible head must be result 2.
        output_ready_i = 1'b1;
        @(negedge clk);
        input_valid_i = 1'b0;
        output_ready_i = 1'b0;
        check_true(occupancy_o == 2'd2,
                   "full simultaneous pop+push keeps occupancy at two");

        // Drain the two retained results in order.
        output_ready_i = 1'b1;
        repeat (2) @(negedge clk);
        output_ready_i = 1'b0;
        check_true(occupancy_o == 2'd0,
                   "directed drain empties FIFO");

        // Flush must discard a backpressured entry and allow a clean refill.
        push_one(4);
        @(negedge clk);
        output_ready_i = 1'b0;
        flush_i = 1'b1;
        @(negedge clk);
        flush_i = 1'b0;
        check_true(occupancy_o == 2'd0 && !output_valid_o,
                   "flush discards pending result");
        push_one(5);
        @(negedge clk);
        output_ready_i = 1'b1;
        @(negedge clk);
        output_ready_i = 1'b0;

        // Randomized legal producer/consumer behavior.  A producer keeps its
        // entry stable whenever valid is backpressured.
        for (random_cycle = 0; random_cycle < 3000;
             random_cycle = random_cycle + 1) begin
            @(negedge clk);
            random_state = lfsr_next(random_state);

            if ((random_cycle != 0) &&
                ((random_cycle % 347) == 0)) begin
                flush_i = 1'b1;
                input_valid_i = 1'b0;
                output_ready_i = random_state[4];
            end else begin
                flush_i = 1'b0;
                output_ready_i = random_state[3] | random_state[7];

                if (!(input_valid_i && !input_ready_o)) begin
                    input_valid_i = random_state[0] | random_state[5];
                    if (input_valid_i) begin
                        sequence_number = sequence_number + 1;
                        drive_entry(100 + sequence_number);
                    end
                end
            end
        end

        // Stop producing and drain the final reference contents.
        @(negedge clk);
        flush_i = 1'b0;
        input_valid_i = 1'b0;
        output_ready_i = 1'b1;
        while (occupancy_o != 0)
            @(negedge clk);
        @(negedge clk);
        output_ready_i = 1'b0;

        check_true(full_exchanges > 20,
                   "random test exercised many full pop+push exchanges");
        check_true(stalled_head_cycles > 100,
                   "random test exercised sustained output backpressure");
        check_true(flushes >= 8,
                   "random test exercised repeated synchronous flushes");
        check_true(accepted_pushes > 500,
                   "random test accepted a substantial input sample");
        check_true(expected_count == 0,
                   "reference FIFO is empty after final drain");

        if (failures == 0) begin
            $display(
                "M7_RESULT_FIFO_PASS checks=%0d pushes=%0d pops=%0d full_exchanges=%0d stalled_head_cycles=%0d flushes=%0d entry_bits=%0d depth=2",
                checks, accepted_pushes, accepted_pops, full_exchanges,
                stalled_head_cycles, flushes, ENTRY_BITS
            );
            $finish;
        end
        $fatal(1,
               "M7_RESULT_FIFO_FAIL failures=%0d checks=%0d",
               failures, checks);
    end

    initial begin
        repeat (20000) @(posedge clk);
        $fatal(1, "Timeout in tb_m7_result_fifo");
    end

endmodule
