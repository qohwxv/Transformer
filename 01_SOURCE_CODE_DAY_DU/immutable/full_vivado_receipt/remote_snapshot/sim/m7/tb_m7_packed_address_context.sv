`timescale 1ns/1ps

// Focused incremental-address test for package-v3 packed FP16 B.
module tb_m7_packed_address_context;

    import vit_phase_e_pkg::*;

    localparam integer ARRAY_ROWS = 8;
    localparam integer ARRAY_COLS = 2;
    localparam integer PE_LANES = 16;

    logic clk = 1'b0;
    logic rst = 1'b1;
    logic clear = 1'b0;
    logic request_start = 1'b0;
    phase_e_cmd_t active_cmd = '0;
    logic [31:0] token_base = '0;
    logic [31:0] output_base = '0;
    logic [31:0] k_base = '0;
    logic [31:0] batch_index = '0;
    logic [65:0] activation_address_base;
    logic [65:0] weight_address_base;
    logic [65:0] bias_address_base;
    logic [65:0] result_address_base;

    integer checks = 0;
    integer failures = 0;

    always #5 clk = ~clk;

    vit_gemm_memory_address_context #(
        .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .PE_LANES(PE_LANES)
    ) dut (
        .clk(clk),
        .rst(rst),
        .clear(clear),
        .request_start(request_start),
        .active_cmd(active_cmd),
        .token_base(token_base),
        .output_base(output_base),
        .k_base(k_base),
        .batch_index(batch_index),
        .activation_address_base(activation_address_base),
        .weight_address_base(weight_address_base),
        .bias_address_base(bias_address_base),
        .result_address_base(result_address_base)
    );

    task automatic check66(
        input logic [65:0] actual,
        input logic [65:0] expected,
        input string message
    );
        begin
            checks = checks + 1;
            if (actual !== expected) begin
                failures = failures + 1;
                $error("%s actual=%017x expected=%017x", message,
                       actual, expected);
            end
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
        end
    endtask

    task automatic request(
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
        end
    endtask

    task automatic configure_common(input logic packed_mode);
        begin
            active_cmd = '0;
            active_cmd.header.opcode = PHASE_E_OP_GEMM;
            active_cmd.header.flags =
                PHASE_E_FLAG_GEMM_B_BLOCKED_K16_N2;
            if (packed_mode)
                active_cmd.header.flags =
                    active_cmd.header.flags |
                    PHASE_E_FLAG_GEMM_B_FP16_PACKED2;
            active_cmd.src0_base = 32'd100;
            active_cmd.src1_base = 32'd1008;
            active_cmd.src2_base = 32'd7000;
            active_cmd.dst_base = 32'd9000;
            active_cmd.stride0 = 32'd4096;
            active_cmd.stride1 = 32'd64;
            active_cmd.stride2 = 32'd128;
            active_cmd.stride3 = packed_mode ? 32'd48 : 32'd96;
            active_cmd.stride4 = 32'd256;
            active_cmd.immediate = 32'd16;
        end
    endtask

    task automatic check_rewind(
        input logic packed_mode,
        input logic [31:0] last_k,
        input logic [65:0] expected_b_step
    );
        logic [31:0] walk_k;
        begin
            configure_common(packed_mode);
            pulse_clear();
            request(32'd0, 32'd0, 32'd0, 32'd0);
            walk_k = 32'd16;
            while (walk_k <= last_k) begin
                request(32'd0, 32'd0, 32'd0, walk_k);
                walk_k = walk_k + 32'd16;
            end
            request(32'd0, 32'd0, 32'd0, 32'd0);
            check66(activation_address_base, 66'd100,
                    "S8 K rewind restores activation tile base");
            check66(weight_address_base, 66'd1008,
                    "S8 K rewind restores weight output base");
            request(32'd0, 32'd0, 32'd0, 32'd16);
            check66(weight_address_base, 66'd1008 + expected_b_step,
                    "post-rewind forward K16 step is exact");
        end
    endtask

    task automatic check_row_major_rewind(input logic [31:0] last_k);
        logic [31:0] walk_k;
        begin
            configure_common(1'b0);
            active_cmd.header.flags = 8'd0;
            active_cmd.stride3 = 32'd197;
            pulse_clear();
            request(32'd0, 32'd0, 32'd0, 32'd0);
            walk_k = 32'd16;
            while (walk_k <= last_k) begin
                request(32'd0, 32'd0, 32'd0, walk_k);
                walk_k = walk_k + 32'd16;
            end
            request(32'd0, 32'd0, 32'd0, 32'd0);
            check66(activation_address_base, 66'd100,
                    "row-major S8 rewind restores activation tile base");
            check66(weight_address_base, 66'd1008,
                    "row-major S8 rewind restores weight output base");
            request(32'd0, 32'd0, 32'd0, 32'd16);
            check66(weight_address_base, 66'(1008 + 16*197),
                    "row-major post-rewind K16 uses 16*stride3");
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        // Packed v3: K advances by 16 physical words.  Output-tile advance
        // uses descriptor stride3 exactly (including legal tile padding).
        configure_common(1'b1);
        pulse_clear();
        request(32'd0, 32'd0, 32'd0, 32'd0);
        check66(weight_address_base, 66'd1008,
                "packed initial B base");
        check66(activation_address_base, 66'd100,
                "packed initial A base");
        request(32'd0, 32'd0, 32'd0, 32'd16);
        check66(weight_address_base, 66'd1024,
                "packed K16 step is 16 words");
        check66(activation_address_base, 66'd116,
                "A K16 step remains 16 words");
        request(32'd0, 32'd0, 32'd0, 32'd0);
        check66(weight_address_base, 66'd1008,
                "packed S8 column pass rewinds B to tile base");
        check66(activation_address_base, 66'd100,
                "packed S8 column pass rewinds A to token base");
        request(32'd0, 32'd0, 32'd0, 32'd16);
        request(32'd0, 32'd0, 32'd2, 32'd0);
        check66(weight_address_base, 66'd1056,
                "packed output tile uses stride3=48");
        check66(bias_address_base, 66'd7002,
                "bias advances by ARRAY_COLS");
        check66(result_address_base, 66'd9002,
                "result advances by ARRAY_COLS");
        request(32'd0, 32'd0, 32'd2, 32'd16);
        check66(weight_address_base, 66'd1072,
                "packed second-tile K16 step remains 16 words");

        // Advancing one R8 token tile resets B to the batch base and advances
        // A/result by eight rows; packed storage has no hidden token stride.
        request(32'd0, 32'd8, 32'd0, 32'd0);
        check66(weight_address_base, 66'd1008,
                "packed token advance resets B to batch base");
        check66(activation_address_base, 66'(100 + 8*64),
                "R8 token step advances A by 8*stride1");
        check66(result_address_base, 66'(9000 + 8*16),
                "R8 token step advances result by 8*immediate");

        // A batch step uses the descriptor's full matrix strides.
        request(32'd1, 32'd0, 32'd0, 32'd0);
        check66(weight_address_base, 66'(1008 + 128),
                "packed batch step uses stride2");
        check66(activation_address_base, 66'(100 + 4096),
                "batch step uses stride0");
        check66(result_address_base, 66'(9000 + 256),
                "batch step uses stride4");

        // Legacy blocked-v2 is unchanged: its K16 step remains 32 words and
        // output still uses the supplied v2 tile stride.
        configure_common(1'b0);
        pulse_clear();
        request(32'd0, 32'd0, 32'd0, 32'd0);
        check66(weight_address_base, 66'd1008,
                "legacy initial B base");
        request(32'd0, 32'd0, 32'd0, 32'd16);
        check66(weight_address_base, 66'd1040,
                "legacy blocked K16 step remains 32 words");
        request(32'd0, 32'd0, 32'd2, 32'd0);
        check66(weight_address_base, 66'd1104,
                "legacy output tile uses stride3=96");
        request(32'd0, 32'd0, 32'd2, 32'd16);
        check66(weight_address_base, 66'd1136,
                "legacy second-tile K16 step remains 32 words");

        // Tail/exact/max reductions all rewind at the same coordinate seam.
        // K=17/32 end at K16, K=33 ends at K32 and K=3072 ends at K3056.
        check_rewind(1'b1, 32'd16, 66'd16);
        check_rewind(1'b1, 32'd16, 66'd16);
        check_rewind(1'b1, 32'd32, 66'd16);
        check_rewind(1'b1, 32'd3056, 66'd16);
        // Blocked-v2/mode-1 monotonic addressing remains 32 words per K16;
        // exercising rewind here proves the new branch does not alter it.
        check_rewind(1'b0, 32'd32, 66'd32);
        // Mode 5 can retain the row-major scratch-B seam (blocked flag clear).
        // Its K rewind must restore weight_output_base before resuming the
        // historical 16*stride3 progression.  Cover an exact K64 end at K48
        // and the ViT token-tail-like K197 end at K192.
        check_row_major_rewind(32'd48);
        check_row_major_rewind(32'd192);

        // Exact 4 KiB placement: packed starts at word 1008 and its next K
        // chunk begins at word 1024; legacy starts at 992 and also lands 1024.
        configure_common(1'b1);
        active_cmd.src1_base = 32'd1008;
        active_cmd.stride3 = 32'd32;
        pulse_clear();
        request(32'd0, 32'd0, 32'd0, 32'd0);
        check66(weight_address_base, 66'd1008,
                "packed last-64-byte page placement");
        request(32'd0, 32'd0, 32'd0, 32'd16);
        check66(weight_address_base, 66'd1024,
                "packed next chunk starts at new page");

        configure_common(1'b0);
        active_cmd.src1_base = 32'd992;
        active_cmd.stride3 = 32'd64;
        pulse_clear();
        request(32'd0, 32'd0, 32'd0, 32'd0);
        check66(weight_address_base, 66'd992,
                "legacy last-128-byte page placement");
        request(32'd0, 32'd0, 32'd0, 32'd16);
        check66(weight_address_base, 66'd1024,
                "legacy next chunk starts at new page");

        if (failures == 0) begin
            $display("PASS M7 packed address context: checks=%0d", checks);
            $finish;
        end
        $fatal(1, "FAIL M7 packed address context: %0d/%0d failed",
               failures, checks);
    end

    initial begin
        repeat (500) @(posedge clk);
        $fatal(1, "Timeout in tb_m7_packed_address_context");
    end

endmodule
