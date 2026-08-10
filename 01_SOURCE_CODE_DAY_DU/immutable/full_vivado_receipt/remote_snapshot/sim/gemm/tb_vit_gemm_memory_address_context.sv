`timescale 1ns/1ps

// Direct self-check for the incremental GEMM address context.
//
// The normal tests only use the public interface and walk coordinates in the
// controller order:
//
//   batch -> token tile -> output tile -> K chunk
//
// A final backdoor-seeded test reconstructs a valid context close to the
// 32-bit coordinate limits.  This fast-forwards billions of legal increments
// so the 66-bit carry path can be checked in a short simulation.
module tb_vit_gemm_memory_address_context;

    import vit_phase_e_pkg::*;

    localparam integer ARRAY_ROWS = 2;
    localparam integer ARRAY_COLS = 2;
    localparam integer PE_LANES   = 16;
    localparam logic [31:0] BLOCKED_B_WORDS =
        ARRAY_COLS * PE_LANES;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic clear = 1'b0;
    logic request_start = 1'b0;

    phase_e_cmd_t active_cmd = '0;
    logic [31:0] token_base = 32'd0;
    logic [31:0] output_base = 32'd0;
    logic [31:0] k_base = 32'd0;
    logic [31:0] batch_index = 32'd0;

    logic [65:0] activation_address_base;
    logic [65:0] weight_address_base;
    logic [65:0] bias_address_base;
    logic [65:0] result_address_base;

    integer checks = 0;
    integer failures = 0;
    integer requests = 0;
    integer descriptors = 0;
    integer extended_32bit_hits = 0;
    integer bit64_hits = 0;
    logic [31:0] random_state = 32'h91c7_4a2d;

    logic [65:0] held_activation;
    logic [65:0] held_weight;
    logic [65:0] held_bias;
    logic [65:0] held_result;

    always #5 clk = ~clk;

    vit_gemm_memory_address_context #(
        .ARRAY_ROWS (ARRAY_ROWS),
        .ARRAY_COLS (ARRAY_COLS),
        .PE_LANES   (PE_LANES)
    ) dut (
        .clk                     (clk),
        .rst                     (rst),
        .clear                   (clear),
        .request_start           (request_start),
        .active_cmd              (active_cmd),
        .token_base              (token_base),
        .output_base             (output_base),
        .k_base                  (k_base),
        .batch_index             (batch_index),
        .activation_address_base (activation_address_base),
        .weight_address_base     (weight_address_base),
        .bias_address_base       (bias_address_base),
        .result_address_base     (result_address_base)
    );

    function automatic logic [65:0] widen32(
        input logic [31:0] value
    );
        begin
            widen32 = {34'd0, value};
        end
    endfunction

    // Shift/add is used instead of '*' so the reference width is explicit
    // and independent of expression-sizing rules in the simulator.
    function automatic logic [65:0] multiply_u32(
        input logic [31:0] left,
        input logic [31:0] right
    );
        integer bit_index;
        logic [65:0] result;
        begin
            result = 66'd0;
            for (bit_index = 0; bit_index < 32;
                 bit_index = bit_index + 1)
                if (right[bit_index])
                    result = result + (widen32(left) << bit_index);
            multiply_u32 = result;
        end
    endfunction

    function automatic logic [65:0] expected_activation(
        input logic [31:0] batch_value,
        input logic [31:0] token_value,
        input logic [31:0] k_value
    );
        begin
            expected_activation =
                widen32(active_cmd.src0_base) +
                multiply_u32(batch_value, active_cmd.stride0) +
                multiply_u32(token_value, active_cmd.stride1) +
                widen32(k_value);
        end
    endfunction

    function automatic logic [65:0] expected_weight(
        input logic [31:0] batch_value,
        input logic [31:0] output_value,
        input logic [31:0] k_value
    );
        logic [31:0] output_tile;
        logic [31:0] k_chunk;
        begin
            if ((active_cmd.header.flags &
                 PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2) != 0) begin
                output_tile = output_value / ARRAY_COLS;
                k_chunk = k_value / PE_LANES;
                expected_weight =
                    widen32(active_cmd.src1_base) +
                    multiply_u32(batch_value, active_cmd.stride2) +
                    multiply_u32(output_tile, active_cmd.stride3) +
                    multiply_u32(k_chunk, BLOCKED_B_WORDS);
            end else begin
                expected_weight =
                    widen32(active_cmd.src1_base) +
                    multiply_u32(batch_value, active_cmd.stride2) +
                    widen32(output_value) +
                    multiply_u32(k_value, active_cmd.stride3);
            end
        end
    endfunction

    function automatic logic [65:0] expected_bias(
        input logic [31:0] output_value
    );
        begin
            expected_bias =
                widen32(active_cmd.src2_base) +
                widen32(output_value);
        end
    endfunction

    function automatic logic [65:0] expected_result(
        input logic [31:0] batch_value,
        input logic [31:0] token_value,
        input logic [31:0] output_value
    );
        begin
            expected_result =
                widen32(active_cmd.dst_base) +
                multiply_u32(batch_value, active_cmd.stride4) +
                multiply_u32(token_value, active_cmd.immediate) +
                widen32(output_value);
        end
    endfunction

    function automatic logic [31:0] xorshift32(
        input logic [31:0] value
    );
        logic [31:0] next_value;
        begin
            next_value = value;
            next_value = next_value ^ (next_value << 13);
            next_value = next_value ^ (next_value >> 17);
            next_value = next_value ^ (next_value << 5);
            xorshift32 = next_value;
        end
    endfunction

    task automatic check66(
        input logic [65:0] actual,
        input logic [65:0] expected,
        input string name
    );
        begin
            checks = checks + 1;
            if (actual !== expected) begin
                failures = failures + 1;
                $error(
                    {
                        "%s mismatch request=%0d batch=%08x token=%08x ",
                        "output=%08x k=%08x actual=%017x expected=%017x"
                    },
                    name,
                    requests,
                    batch_index,
                    token_base,
                    output_base,
                    k_base,
                    actual,
                    expected
                );
            end
        end
    endtask

    task automatic check_true(
        input logic condition,
        input string name
    );
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $error("%s", name);
            end
        end
    endtask

    task automatic check_current_bases;
        logic [65:0] expected_a;
        logic [65:0] expected_b;
        logic [65:0] expected_bias_value;
        logic [65:0] expected_c;
        begin
            expected_a =
                expected_activation(batch_index, token_base, k_base);
            expected_b =
                expected_weight(batch_index, output_base, k_base);
            expected_bias_value = expected_bias(output_base);
            expected_c =
                expected_result(batch_index, token_base, output_base);

            check66(
                activation_address_base,
                expected_a,
                "activation_address_base"
            );
            check66(weight_address_base, expected_b, "weight_address_base");
            check66(
                bias_address_base,
                expected_bias_value,
                "bias_address_base"
            );
            check66(result_address_base, expected_c, "result_address_base");

            if ((expected_a[65:32] != 0) ||
                (expected_b[65:32] != 0) ||
                (expected_bias_value[65:32] != 0) ||
                (expected_c[65:32] != 0))
                extended_32bit_hits = extended_32bit_hits + 1;

            if (expected_a[64] || expected_b[64] || expected_c[64])
                bit64_hits = bit64_hits + 1;
        end
    endtask

    task automatic pulse_request(
        input logic [31:0] batch_value,
        input logic [31:0] token_value,
        input logic [31:0] output_value,
        input logic [31:0] k_value
    );
        begin
            @(negedge clk);
            batch_index = batch_value;
            token_base = token_value;
            output_base = output_value;
            k_base = k_value;
            request_start = 1'b1;

            @(posedge clk);
            #1;
            request_start = 1'b0;
            requests = requests + 1;
            check_current_bases();
        end
    endtask

    task automatic pulse_clear;
        begin
            @(negedge clk);
            request_start = 1'b0;
            clear = 1'b1;
            @(posedge clk);
            #1;
            clear = 1'b0;
            check66(activation_address_base, 66'd0, "clear activation");
            check66(weight_address_base, 66'd0, "clear weight");
            check66(bias_address_base, 66'd0, "clear bias");
            check66(result_address_base, 66'd0, "clear result");
        end
    endtask

    task automatic apply_reset;
        begin
            @(negedge clk);
            request_start = 1'b0;
            clear = 1'b0;
            rst = 1'b1;
            repeat (2) @(posedge clk);
            #1;
            check66(activation_address_base, 66'd0, "reset activation");
            check66(weight_address_base, 66'd0, "reset weight");
            check66(bias_address_base, 66'd0, "reset bias");
            check66(result_address_base, 66'd0, "reset result");
            @(negedge clk);
            rst = 1'b0;
        end
    endtask

    task automatic check_hold_without_request;
        begin
            held_activation = activation_address_base;
            held_weight = weight_address_base;
            held_bias = bias_address_base;
            held_result = result_address_base;
            request_start = 1'b0;
            repeat (3) @(posedge clk);
            #1;
            check66(
                activation_address_base,
                held_activation,
                "idle hold activation"
            );
            check66(weight_address_base, held_weight, "idle hold weight");
            check66(bias_address_base, held_bias, "idle hold bias");
            check66(result_address_base, held_result, "idle hold result");
        end
    endtask

    task automatic run_current_descriptor;
        integer batch_value;
        integer token_value;
        integer output_value;
        integer reduction_value;
        begin
            descriptors = descriptors + 1;
            for (batch_value = 0;
                 batch_value < active_cmd.dim0;
                 batch_value = batch_value + 1)
                for (token_value = 0;
                     token_value < active_cmd.dim1;
                     token_value = token_value + ARRAY_ROWS)
                    for (output_value = 0;
                         output_value < active_cmd.dim3;
                         output_value = output_value + ARRAY_COLS)
                        for (reduction_value = 0;
                             reduction_value < active_cmd.dim2;
                             reduction_value =
                                 reduction_value + PE_LANES) begin
                            pulse_request(
                                batch_value[31:0],
                                token_value[31:0],
                                output_value[31:0],
                                reduction_value[31:0]
                            );

                            // Repeating the same coordinate must be a no-op.
                            if ((requests % 19) == 0)
                                pulse_request(
                                    batch_value[31:0],
                                    token_value[31:0],
                                    output_value[31:0],
                                    reduction_value[31:0]
                                );
                        end
            check_hold_without_request();
        end
    endtask

    task automatic make_random_valid_descriptor(
        input logic blocked_mode
    );
        integer batch_count;
        integer token_count;
        integer reduction_count;
        integer output_count;
        integer padding;
        begin
            active_cmd = '0;
            active_cmd.header.opcode = PHASE_E_OP_GEMM;
            if (blocked_mode)
                active_cmd.header.flags =
                    PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2;

            random_state = xorshift32(random_state);
            batch_count = 1 + (random_state % 4);
            random_state = xorshift32(random_state);
            token_count = 1 + (random_state % 9);
            random_state = xorshift32(random_state);
            reduction_count = 1 + (random_state % 65);
            random_state = xorshift32(random_state);
            output_count = 1 + (random_state % 9);

            active_cmd.dim0 = batch_count;
            active_cmd.dim1 = token_count;
            active_cmd.dim2 = reduction_count;
            active_cmd.dim3 = output_count;

            random_state = xorshift32(random_state);
            active_cmd.src0_base = random_state & 32'h000f_ffff;
            random_state = xorshift32(random_state);
            active_cmd.src1_base = random_state & 32'h000f_ffff;
            random_state = xorshift32(random_state);
            active_cmd.src2_base = random_state & 32'h000f_ffff;
            random_state = xorshift32(random_state);
            active_cmd.dst_base = random_state & 32'h000f_ffff;

            // Each stride includes random legal padding and is large enough
            // for the immediately nested matrix dimension.
            random_state = xorshift32(random_state);
            padding = random_state % 8;
            active_cmd.stride1 = reduction_count + padding;
            random_state = xorshift32(random_state);
            padding = random_state % 8;
            active_cmd.stride0 =
                token_count * active_cmd.stride1 + padding;

            if (blocked_mode) begin
                // The production package has no inter-tile padding, but the
                // address context deliberately accepts a padded N-tile
                // stride.  Keep all padding block-aligned.
                random_state = xorshift32(random_state);
                padding = random_state % 4;
                active_cmd.stride3 =
                    (((reduction_count + PE_LANES - 1) / PE_LANES) +
                     padding) * BLOCKED_B_WORDS;
                random_state = xorshift32(random_state);
                padding = random_state % 8;
                active_cmd.stride2 =
                    ((output_count + ARRAY_COLS - 1) / ARRAY_COLS) *
                    active_cmd.stride3 + padding;
            end else begin
                random_state = xorshift32(random_state);
                padding = random_state % 8;
                active_cmd.stride3 = output_count + padding;
                random_state = xorshift32(random_state);
                padding = random_state % 8;
                active_cmd.stride2 =
                    reduction_count * active_cmd.stride3 + padding;
            end

            random_state = xorshift32(random_state);
            padding = random_state % 8;
            active_cmd.immediate = output_count + padding;
            random_state = xorshift32(random_state);
            padding = random_state % 8;
            active_cmd.stride4 =
                token_count * active_cmd.immediate + padding;
        end
    endtask

    // Recreate the state that would exist after all prior legal coordinate
    // increments.  Hierarchical assignment is confined to this verification
    // task and lets the test reach the 65th address bit quickly.
    task automatic seed_valid_context(
        input logic [31:0] batch_value,
        input logic [31:0] token_value,
        input logic [31:0] output_value,
        input logic [31:0] k_value
    );
        begin
            @(negedge clk);
            request_start = 1'b0;

            batch_index = batch_value;
            token_base = token_value;
            output_base = output_value;
            k_base = k_value;

            dut.context_valid = 1'b1;
            dut.previous_batch_index = batch_value;
            dut.previous_token_base = token_value;
            dut.previous_output_base = output_value;
            dut.previous_k_base = k_value;

            dut.activation_batch_base =
                widen32(active_cmd.src0_base) +
                multiply_u32(batch_value, active_cmd.stride0);
            dut.activation_token_base =
                widen32(active_cmd.src0_base) +
                multiply_u32(batch_value, active_cmd.stride0) +
                multiply_u32(token_value, active_cmd.stride1);
            dut.activation_address_base =
                expected_activation(batch_value, token_value, k_value);

            dut.weight_batch_base =
                widen32(active_cmd.src1_base) +
                multiply_u32(batch_value, active_cmd.stride2);
            if ((active_cmd.header.flags &
                 PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2) != 0)
                dut.weight_output_base =
                    widen32(active_cmd.src1_base) +
                    multiply_u32(batch_value, active_cmd.stride2) +
                    multiply_u32(
                        output_value / ARRAY_COLS,
                        active_cmd.stride3
                    );
            else
                dut.weight_output_base =
                    widen32(active_cmd.src1_base) +
                    multiply_u32(batch_value, active_cmd.stride2) +
                    widen32(output_value);
            dut.weight_address_base =
                expected_weight(batch_value, output_value, k_value);

            dut.bias_address_base = expected_bias(output_value);

            dut.result_batch_base =
                widen32(active_cmd.dst_base) +
                multiply_u32(batch_value, active_cmd.stride4);
            dut.result_token_base =
                widen32(active_cmd.dst_base) +
                multiply_u32(batch_value, active_cmd.stride4) +
                multiply_u32(token_value, active_cmd.immediate);
            dut.result_address_base =
                expected_result(batch_value, token_value, output_value);

            #1;
            check_current_bases();
        end
    endtask

    task automatic run_near_limit_fast_forward(
        input logic blocked_mode
    );
        begin
            active_cmd = '0;
            active_cmd.header.opcode = PHASE_E_OP_GEMM;
            if (blocked_mode)
                active_cmd.header.flags =
                    PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2;
            active_cmd.src0_base = 32'hffff_ffff;
            active_cmd.src1_base = 32'hffff_fff7;
            active_cmd.src2_base = 32'hffff_ffe1;
            active_cmd.dst_base = 32'hffff_ffc3;
            active_cmd.stride0 = 32'hffff_fffb;
            active_cmd.stride1 = 32'hffff_fff1;
            active_cmd.stride2 = 32'hffff_ffef;
            active_cmd.stride3 = 32'hffff_ffe7;
            active_cmd.stride4 = 32'hffff_ffdf;
            active_cmd.immediate = 32'hffff_ffd3;

            // K is the innermost loop.
            seed_valid_context(
                32'hffff_ffff,
                32'hffff_fffc,
                32'hffff_fffc,
                32'hffff_ffe0
            );
            pulse_request(
                32'hffff_ffff,
                32'hffff_fffc,
                32'hffff_fffc,
                32'hffff_fff0
            );

            // Output advances by ARRAY_COLS and resets K to zero.
            seed_valid_context(
                32'hffff_ffff,
                32'hffff_fffc,
                32'hffff_fffc,
                32'hffff_fff0
            );
            pulse_request(
                32'hffff_ffff,
                32'hffff_fffc,
                32'hffff_fffe,
                32'd0
            );

            // Token advances by ARRAY_ROWS and resets output/K.
            seed_valid_context(
                32'hffff_ffff,
                32'hffff_fffa,
                32'hffff_fffe,
                32'hffff_fff0
            );
            pulse_request(
                32'hffff_ffff,
                32'hffff_fffc,
                32'd0,
                32'd0
            );

            // Batch advances by one and resets all inner coordinates.
            seed_valid_context(
                32'hffff_fffe,
                32'hffff_fffc,
                32'hffff_fffe,
                32'hffff_fff0
            );
            pulse_request(
                32'hffff_ffff,
                32'd0,
                32'd0,
                32'd0
            );
        end
    endtask

    integer descriptor_index;
    integer tail_index;

    initial begin
        repeat (3) @(posedge clk);
        #1;
        check66(activation_address_base, 66'd0, "initial reset activation");
        check66(weight_address_base, 66'd0, "initial reset weight");
        check66(bias_address_base, 66'd0, "initial reset bias");
        check66(result_address_base, 66'd0, "initial reset result");
        @(negedge clk);
        rst = 1'b0;

        // Directed nested-order sequence with partial edge tiles.
        active_cmd = '0;
        active_cmd.header.opcode = PHASE_E_OP_GEMM;
        active_cmd.src0_base = 32'd17;
        active_cmd.src1_base = 32'd1009;
        active_cmd.src2_base = 32'd4003;
        active_cmd.dst_base = 32'd8009;
        active_cmd.dim0 = 32'd2;
        active_cmd.dim1 = 32'd5;
        active_cmd.dim2 = 32'd35;
        active_cmd.dim3 = 32'd5;
        active_cmd.stride1 = 32'd41;
        active_cmd.stride0 = 32'd223;
        active_cmd.stride3 = 32'd11;
        active_cmd.stride2 = 32'd397;
        active_cmd.immediate = 32'd13;
        active_cmd.stride4 = 32'd79;
        pulse_clear();
        run_current_descriptor();

        // Reset in the middle of a sequence must invalidate all history.
        pulse_clear();
        pulse_request(32'd0, 32'd0, 32'd0, 32'd0);
        pulse_request(32'd0, 32'd0, 32'd0, 32'd16);
        apply_reset();
        pulse_request(32'd0, 32'd0, 32'd0, 32'd0);
        pulse_request(32'd0, 32'd0, 32'd0, 32'd16);

        // Deterministic random row-major descriptors exercise partial tiles,
        // padded strides, arbitrary bases, clear, and repeated coordinates.
        for (descriptor_index = 0; descriptor_index < 40;
             descriptor_index = descriptor_index + 1) begin
            make_random_valid_descriptor(1'b0);
            if ((descriptor_index % 9) == 4)
                apply_reset();
            else
                pulse_clear();
            run_current_descriptor();
        end

        // Directed blocked-B tails cover both exact and partial K16/N2
        // tiles.  The padded lanes/column are represented by the package but
        // must not perturb the base of any following logical tile.
        for (tail_index = 0; tail_index < 4;
             tail_index = tail_index + 1) begin
            active_cmd = '0;
            active_cmd.header.opcode = PHASE_E_OP_GEMM;
            active_cmd.header.flags =
                PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2;
            active_cmd.src0_base = 32'd31 + tail_index;
            active_cmd.src1_base = 32'd2048 + tail_index * 1024;
            active_cmd.src2_base = 32'd8192 + tail_index * 32;
            active_cmd.dst_base = 32'd12288 + tail_index * 64;
            active_cmd.dim0 = 32'd2;
            active_cmd.dim1 = 32'd3;
            case (tail_index)
                0: begin
                    active_cmd.dim2 = 32'd1;
                    active_cmd.dim3 = 32'd1;
                end
                1: begin
                    active_cmd.dim2 = 32'd16;
                    active_cmd.dim3 = 32'd2;
                end
                2: begin
                    active_cmd.dim2 = 32'd17;
                    active_cmd.dim3 = 32'd3;
                end
                default: begin
                    active_cmd.dim2 = 32'd31;
                    active_cmd.dim3 = 32'd3;
                end
            endcase
            active_cmd.stride1 = active_cmd.dim2 + 32'd3;
            active_cmd.stride0 =
                active_cmd.dim1 * active_cmd.stride1 + 32'd5;
            active_cmd.stride3 =
                ((active_cmd.dim2 + PE_LANES - 1) / PE_LANES) *
                BLOCKED_B_WORDS;
            active_cmd.stride2 =
                ((active_cmd.dim3 + ARRAY_COLS - 1) / ARRAY_COLS) *
                active_cmd.stride3 + 32'd7;
            active_cmd.immediate = active_cmd.dim3 + 32'd2;
            active_cmd.stride4 =
                active_cmd.dim1 * active_cmd.immediate + 32'd3;
            pulse_clear();
            run_current_descriptor();
        end

        // Random blocked descriptors additionally cover non-zero batch
        // strides and block-aligned padding between N tiles.
        for (descriptor_index = 0; descriptor_index < 40;
             descriptor_index = descriptor_index + 1) begin
            make_random_valid_descriptor(1'b1);
            if ((descriptor_index % 11) == 6)
                apply_reset();
            else
                pulse_clear();
            run_current_descriptor();
        end

        // A 32-word/128-byte block beginning at word offset 992 occupies the
        // final 128 bytes of a 4 KiB page.  The next K chunk must begin at
        // word offset 0 of the next page, never crossing the boundary.
        active_cmd = '0;
        active_cmd.header.opcode = PHASE_E_OP_GEMM;
        active_cmd.header.flags =
            PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2;
        active_cmd.src1_base = 32'd992;
        active_cmd.dim0 = 32'd1;
        active_cmd.dim1 = 32'd1;
        active_cmd.dim2 = 32'd32;
        active_cmd.dim3 = 32'd4;
        active_cmd.stride3 = 32'd64;
        pulse_clear();
        pulse_request(32'd0, 32'd0, 32'd0, 32'd0);
        check_true(
            weight_address_base[9:0] == 10'd992,
            "blocked block starts at final 128 bytes of 4 KiB page"
        );
        pulse_request(32'd0, 32'd0, 32'd0, 32'd16);
        check_true(
            weight_address_base[9:0] == 10'd0,
            "next blocked K chunk starts at next 4 KiB page"
        );
        pulse_request(32'd0, 32'd0, 32'd2, 32'd0);
        check_true(
            weight_address_base == 66'd1056,
            "next blocked N tile uses exact tile stride"
        );

        // Public-interface overflow test: all bases and strides are near the
        // 32-bit maximum, while the output must retain every carry.
        active_cmd = '0;
        active_cmd.header.opcode = PHASE_E_OP_GEMM;
        active_cmd.src0_base = 32'hffff_fff0;
        active_cmd.src1_base = 32'hffff_ffe0;
        active_cmd.src2_base = 32'hffff_ffd0;
        active_cmd.dst_base = 32'hffff_ffc0;
        active_cmd.dim0 = 32'd6;
        active_cmd.dim1 = 32'd7;
        active_cmd.dim2 = 32'd49;
        active_cmd.dim3 = 32'd7;
        active_cmd.stride0 = 32'hffff_fff1;
        active_cmd.stride1 = 32'hffff_ffe3;
        active_cmd.stride2 = 32'hffff_ffd7;
        active_cmd.stride3 = 32'hffff_ffc9;
        active_cmd.stride4 = 32'hffff_ffbb;
        active_cmd.immediate = 32'hffff_ffad;
        pulse_clear();
        run_current_descriptor();

        // Fast-forwarded legal context checks transition arithmetic around
        // the largest possible 32-bit coordinates.
        pulse_clear();
        run_near_limit_fast_forward(1'b0);

        // The same 66-bit carry checks apply when output tiles advance by
        // stride3 and K chunks advance by exactly 32 words.
        pulse_clear();
        run_near_limit_fast_forward(1'b1);

        checks = checks + 1;
        if (extended_32bit_hits == 0) begin
            failures = failures + 1;
            $error("overflow suite never exercised an address above 32 bits");
        end

        checks = checks + 1;
        if (bit64_hits == 0) begin
            failures = failures + 1;
            $error("fast-forward suite never exercised address bit 64");
        end

        if (failures == 0) begin
            $display(
                "PASS vit_gemm_memory_address_context: %0d checks, %0d requests, %0d descriptors, %0d >32-bit hits, %0d bit64 hits",
                checks,
                requests,
                descriptors,
                extended_32bit_hits,
                bit64_hits
            );
            $finish;
        end

        $fatal(
            1,
            "FAIL vit_gemm_memory_address_context: %0d/%0d checks failed",
            failures,
            checks
        );
    end

    initial begin
        #5_000_000;
        $fatal(1, "timeout in vit_gemm_memory_address_context test");
    end

endmodule
