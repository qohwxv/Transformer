`timescale 1ns/1ps

// Self-checking testbench for vit_gemm_local_1x1.
//
// The testbench intentionally accesses the DUT only through its top-level
// ports.  The same test can therefore be used for RTL, post-synthesis
// functional, and post-implementation timing simulation.
module tb_vit_gemm_local_1x1;
    localparam time CLOCK_PERIOD = 5ns; // 200 MHz

    localparam logic [1:0] LOAD_A = 2'd0;
    localparam logic [1:0] LOAD_B = 2'd1;

    localparam logic [3:0] OPCODE_GEMM    = 4'h1;
    localparam logic [3:0] OPCODE_INVALID = 4'hf;

    localparam integer A_WORDS = 3 * 5;
    localparam integer B_WORDS = 5 * 7;
    localparam integer C_WORDS = 3 * 7;

    logic         aclk;
    logic         aresetn;
    logic         cmd_valid;
    logic [511:0] cmd_data;
    logic         cmd_ready;
    logic         busy;
    logic         done;
    logic         error;
    logic [7:0]   error_code;
    logic         load_we;
    logic [1:0]   load_select;
    logic [31:0]  load_addr;
    logic [31:0]  load_wdata;
    logic         c_read_en;
    logic [31:0]  c_read_addr;
    logic [31:0]  c_read_data;

    integer cycle_count;
    integer mismatch_count;

    vit_gemm_local_1x1 dut (
        .aclk        (aclk),
        .aresetn     (aresetn),
        .cmd_valid   (cmd_valid),
        .cmd_data    (cmd_data),
        .cmd_ready   (cmd_ready),
        .busy        (busy),
        .done        (done),
        .error       (error),
        .error_code  (error_code),
        .load_we     (load_we),
        .load_select (load_select),
        .load_addr   (load_addr),
        .load_wdata  (load_wdata),
        .c_read_en   (c_read_en),
        .c_read_addr (c_read_addr),
        .c_read_data (c_read_data)
    );

    initial begin
        aclk = 1'b0;
        forever #(CLOCK_PERIOD / 2) aclk = ~aclk;
    end

    always @(posedge aclk) begin
        cycle_count <= cycle_count + 1;
    end

    // A is row-major, shape 3x5:
    //
    //   1 2 3 4 5
    //   2 3 4 5 6
    //   3 4 5 6 7
    //
    // Integer-valued binary32 operands make every expected result exactly
    // representable, so raw 32-bit comparison is deterministic.
    function automatic logic [31:0] a_word(input integer index);
        begin
            case (index)
                0:  a_word = 32'h3f80_0000; // 1
                1:  a_word = 32'h4000_0000; // 2
                2:  a_word = 32'h4040_0000; // 3
                3:  a_word = 32'h4080_0000; // 4
                4:  a_word = 32'h40a0_0000; // 5
                5:  a_word = 32'h4000_0000; // 2
                6:  a_word = 32'h4040_0000; // 3
                7:  a_word = 32'h4080_0000; // 4
                8:  a_word = 32'h40a0_0000; // 5
                9:  a_word = 32'h40c0_0000; // 6
                10: a_word = 32'h4040_0000; // 3
                11: a_word = 32'h4080_0000; // 4
                12: a_word = 32'h40a0_0000; // 5
                13: a_word = 32'h40c0_0000; // 6
                14: a_word = 32'h40e0_0000; // 7
                default: a_word = 32'hxxxx_xxxx;
            endcase
        end
    endfunction

    // B is row-major, shape 5x7:
    //
    //  -6 -4  6 -4  3 -4  3
    //  10  6 -7  7 -1  5 -1
    //   1  1  1  1  1  1  1
    //  -1 -1 -1 -1 -1 -1 -1
    //   1  1  1  1  1  1  1
    function automatic logic [31:0] b_word(input integer index);
        begin
            case (index)
                0:  b_word = 32'hc0c0_0000; // -6
                1:  b_word = 32'hc080_0000; // -4
                2:  b_word = 32'h40c0_0000; //  6
                3:  b_word = 32'hc080_0000; // -4
                4:  b_word = 32'h4040_0000; //  3
                5:  b_word = 32'hc080_0000; // -4
                6:  b_word = 32'h4040_0000; //  3
                7:  b_word = 32'h4120_0000; // 10
                8:  b_word = 32'h40c0_0000; //  6
                9:  b_word = 32'hc0e0_0000; // -7
                10: b_word = 32'h40e0_0000; //  7
                11: b_word = 32'hbf80_0000; // -1
                12: b_word = 32'h40a0_0000; //  5
                13: b_word = 32'hbf80_0000; // -1
                14, 15, 16, 17, 18, 19, 20:
                    b_word = 32'h3f80_0000; //  1
                21, 22, 23, 24, 25, 26, 27:
                    b_word = 32'hbf80_0000; // -1
                28, 29, 30, 31, 32, 33, 34:
                    b_word = 32'h3f80_0000; //  1
                default: b_word = 32'hxxxx_xxxx;
            endcase
        end
    endfunction

    // Expected row-major C, shape 3x7.
    function automatic logic [31:0] expected_c_word(input integer index);
        begin
            case (index)
                0:  expected_c_word = 32'h4190_0000; // 18
                1:  expected_c_word = 32'h4140_0000; // 12
                2:  expected_c_word = 32'hc080_0000; // -4
                3:  expected_c_word = 32'h4160_0000; // 14
                4:  expected_c_word = 32'h40a0_0000; //  5
                5:  expected_c_word = 32'h4120_0000; // 10
                6:  expected_c_word = 32'h40a0_0000; //  5
                7:  expected_c_word = 32'h41b8_0000; // 23
                8:  expected_c_word = 32'h4170_0000; // 15
                9:  expected_c_word = 32'hc080_0000; // -4
                10: expected_c_word = 32'h4190_0000; // 18
                11: expected_c_word = 32'h4100_0000; //  8
                12: expected_c_word = 32'h4140_0000; // 12
                13: expected_c_word = 32'h4100_0000; //  8
                14: expected_c_word = 32'h41e0_0000; // 28
                15: expected_c_word = 32'h4190_0000; // 18
                16: expected_c_word = 32'hc080_0000; // -4
                17: expected_c_word = 32'h41b0_0000; // 22
                18: expected_c_word = 32'h4130_0000; // 11
                19: expected_c_word = 32'h4160_0000; // 14
                20: expected_c_word = 32'h4130_0000; // 11
                default: expected_c_word = 32'hxxxx_xxxx;
            endcase
        end
    endfunction

    function automatic logic [511:0] make_gemm_descriptor;
        logic [511:0] descriptor;
        begin
            descriptor = 512'b0;
            descriptor[(0 * 32) +: 32] = {16'b0, 8'b0, 4'b0, OPCODE_GEMM};
            descriptor[(2 * 32) +: 32] = 32'd0; // A base
            descriptor[(3 * 32) +: 32] = 32'd0; // B base
            descriptor[(5 * 32) +: 32] = 32'd0; // C base
            descriptor[(6 * 32) +: 32] = 32'd1; // batch
            descriptor[(7 * 32) +: 32] = 32'd3; // M
            descriptor[(8 * 32) +: 32] = 32'd5; // K
            descriptor[(9 * 32) +: 32] = 32'd7; // N
            descriptor[(11 * 32) +: 32] = 32'd5; // A row stride
            descriptor[(13 * 32) +: 32] = 32'd7; // B row stride
            descriptor[(15 * 32) +: 32] = 32'd7; // C row stride
            make_gemm_descriptor = descriptor;
        end
    endfunction

    task automatic record_mismatch(input string message);
        begin
            mismatch_count = mismatch_count + 1;
            $error("GEMM_CHECK_FAIL cycle=%0d %s", cycle_count, message);
        end
    endtask

    task automatic apply_reset(input integer clocks);
        begin
            @(negedge aclk);
            aresetn = 1'b0;
            cmd_valid = 1'b0;
            cmd_data = 512'b0;
            load_we = 1'b0;
            load_select = 2'b0;
            load_addr = 32'b0;
            load_wdata = 32'b0;
            c_read_en = 1'b0;
            c_read_addr = 32'b0;
            repeat (clocks) @(posedge aclk);
            @(negedge aclk);
            aresetn = 1'b1;
            repeat (2) @(posedge aclk);
        end
    endtask

    task automatic load_word(
        input logic [1:0]  memory_select,
        input logic [31:0] address,
        input logic [31:0] value
    );
        begin
            @(negedge aclk);
            load_select = memory_select;
            load_addr = address;
            load_wdata = value;
            load_we = 1'b1;
            @(posedge aclk);
            @(negedge aclk);
            load_we = 1'b0;
        end
    endtask

    task automatic send_command(input logic [511:0] descriptor);
        integer ready_timeout;
        begin
            ready_timeout = 0;
            @(negedge aclk);
            cmd_data = descriptor;
            cmd_valid = 1'b1;
            while ((cmd_ready !== 1'b1) && (ready_timeout < 1000)) begin
                @(negedge aclk);
                ready_timeout = ready_timeout + 1;
            end
            if (cmd_ready !== 1'b1) begin
                record_mismatch("cmd_ready timeout");
                $fatal(1, "GEMM_LOCAL_1X1_FAIL");
            end
            // cmd_ready was observed at a negedge; the handshake occurs at
            // the following posedge. Hold descriptor stable through it.
            @(posedge aclk);
            @(negedge aclk);
            cmd_valid = 1'b0;
            cmd_data = 512'b0;
        end
    endtask

    task automatic wait_for_done;
        integer done_timeout;
        begin
            done_timeout = 0;
            while ((done !== 1'b1) && (done_timeout < 20000)) begin
                @(negedge aclk);
                done_timeout = done_timeout + 1;
            end
            if (done !== 1'b1) begin
                record_mismatch("done timeout");
                $fatal(1, "GEMM_LOCAL_1X1_FAIL");
            end
        end
    endtask

    task automatic wait_for_error(input string test_name);
        integer error_timeout;
        begin
            error_timeout = 0;
            while ((error !== 1'b1) && (error_timeout < 1000)) begin
                @(negedge aclk);
                error_timeout = error_timeout + 1;
            end
            if (error !== 1'b1) begin
                record_mismatch({test_name, ": error timeout"});
            end else if ((error_code === 8'h00) || (^error_code === 1'bx)) begin
                record_mismatch(
                    $sformatf(
                        "%s: invalid error_code=%02x",
                        test_name,
                        error_code
                    )
                );
            end
        end
    endtask

    task automatic read_c_word(
        input  logic [31:0] address,
        output logic [31:0] value
    );
        begin
            @(negedge aclk);
            c_read_addr = address;
            c_read_en = 1'b1;
            @(posedge aclk);
            // Sample at the following falling edge. This leaves half a clock
            // for clock-to-out delay in post-implementation timing tests.
            @(negedge aclk);
            value = c_read_data;
            c_read_en = 1'b0;
        end
    endtask

    integer index;
    logic [31:0] observed_word;
    logic [511:0] test_descriptor;

    initial begin
        cycle_count = 0;
        mismatch_count = 0;
        aresetn = 1'b0;
        cmd_valid = 1'b0;
        cmd_data = 512'b0;
        load_we = 1'b0;
        load_select = 2'b0;
        load_addr = 32'b0;
        load_wdata = 32'b0;
        c_read_en = 1'b0;
        c_read_addr = 32'b0;

        // 50 clocks = 250 ns. This exceeds both the requested 200 ns reset
        // interval and the typical 100 ns global-set/reset interval used by
        // Xilinx post-implementation simulation.
        apply_reset(50);

        for (index = 0; index < A_WORDS; index = index + 1) begin
            load_word(LOAD_A, index, a_word(index));
        end
        for (index = 0; index < B_WORDS; index = index + 1) begin
            load_word(LOAD_B, index, b_word(index));
        end

        test_descriptor = make_gemm_descriptor();
        send_command(test_descriptor);
        wait_for_done();

        if (error !== 1'b0) begin
            record_mismatch(
                $sformatf(
                    "valid GEMM raised error=%0b error_code=%02x",
                    error,
                    error_code
                )
            );
        end
        if (busy !== 1'b0) begin
            record_mismatch("busy remained asserted when done was observed");
        end

        for (index = 0; index < C_WORDS; index = index + 1) begin
            read_c_word(index, observed_word);
            if (observed_word !== expected_c_word(index)) begin
                record_mismatch(
                    $sformatf(
                        "C[%0d]=%08x expected=%08x",
                        index,
                        observed_word,
                        expected_c_word(index)
                    )
                );
            end
        end

        // Decoder validation: unsupported opcode must be rejected with a
        // nonzero error code.
        apply_reset(12);
        test_descriptor = make_gemm_descriptor();
        test_descriptor[3:0] = OPCODE_INVALID;
        send_command(test_descriptor);
        wait_for_error("invalid opcode");

        // Dimension validation: K=0 must also be rejected.
        apply_reset(12);
        test_descriptor = make_gemm_descriptor();
        test_descriptor[(8 * 32) +: 32] = 32'd0;
        send_command(test_descriptor);
        wait_for_error("zero K");

        if (mismatch_count == 0) begin
            $display(
                "GEMM_LOCAL_1X1_PASS cycles=%0d C_words=%0d",
                cycle_count,
                C_WORDS
            );
            $finish;
        end

        $fatal(
            1,
            "GEMM_LOCAL_1X1_FAIL mismatches=%0d",
            mismatch_count
        );
    end

    // Independent absolute watchdog for deadlocks and missing handshakes.
    initial begin
        #5ms;
        $fatal(1, "GEMM_LOCAL_1X1_FAIL absolute watchdog expired");
    end
endmodule
