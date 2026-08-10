`timescale 1ns/1ps

module tb_vit_vector_engine_fp32;

    import vit_fp32_pkg::*;

    localparam integer LANES = 16;
    localparam logic [1:0] MODE_ADD = 2'd0;
    localparam logic [1:0] MODE_SCALE_MASK = 2'd1;
`ifdef M8_PARENT_BASELINE
    localparam integer EXPECTED_ADD_CYCLES = 72;
    localparam integer EXPECTED_SCALE_MASK_CYCLES = 37;
    localparam integer EXPECTED_SCALE_NOMASK_CYCLES = 37;
    localparam string IMPLEMENTATION_LABEL = "M7_PARENT";
`else
    localparam integer EXPECTED_ADD_CYCLES = 40;
    localparam integer EXPECTED_SCALE_MASK_CYCLES = 37;
    localparam integer EXPECTED_SCALE_NOMASK_CYCLES = 21;
    localparam string IMPLEMENTATION_LABEL = "M8_FASTPATH";
`endif

    logic clk;
    logic rst;
    logic start;
    logic [1:0] cfg_mode;
    logic [31:0] cfg_length;
    logic [31:0] cfg_scalar;
    logic cfg_mask_enable;
    logic busy;
    logic done;
    logic config_error;
    logic data_request;
    logic data_valid;
    logic [31:0] element_base;
    logic [LANES*32-1:0] input_a;
    logic [LANES*32-1:0] input_b;
    logic result_valid;
    logic result_ready;
    logic [31:0] result_base;
    logic [LANES-1:0] result_lane_mask;
    logic [LANES*32-1:0] result_data;

    integer lane;
    integer accepted_vectors;
    integer cycle_count;
    integer run_start_cycle;
    integer add_cycles;
    integer scale_mask_cycles;
    integer scale_nomask_cycles;
    logic [31:0] expected_lane;
    logic [31:0] payload_a_word;
    logic [31:0] payload_b_word;

    assign data_valid = data_request;
    assign result_ready = (cycle_count[1:0] != 2'b01);

    always_comb begin
        input_a = '0;
        input_b = '0;
        for (lane = 0; lane < LANES; lane = lane + 1) begin
            // Present the real payload only during the request handshake.
            // Poisoning the buses while the shared datapath is computing
            // proves that the engine owns an internal operand buffer.
            if (data_request) begin
                input_a[lane*32 +: 32] = payload_a_word;
                input_b[lane*32 +: 32] = payload_b_word;
            end else begin
                input_a[lane*32 +: 32] = 32'h7fc0_0000;
                input_b[lane*32 +: 32] = 32'h7f80_0000;
            end
        end
    end

    vit_vector_engine_fp32 #(
        .LANES(LANES)
    ) u_dut (
        .clk             (clk),
        .rst             (rst),
        .start           (start),
        .cfg_mode        (cfg_mode),
        .cfg_length      (cfg_length),
        .cfg_scalar      (cfg_scalar),
        .cfg_mask_enable (cfg_mask_enable),
        .busy            (busy),
        .done            (done),
        .config_error    (config_error),
        .data_request    (data_request),
        .data_valid      (data_valid),
        .element_base    (element_base),
        .input_a         (input_a),
        .input_b         (input_b),
        .result_valid    (result_valid),
        .result_ready    (result_ready),
        .result_base     (result_base),
        .result_lane_mask(result_lane_mask),
        .result_data     (result_data)
    );

    initial begin
        clk = 1'b0;
        forever #5 clk = ~clk;
    end

    always_ff @(posedge clk) begin
        if (rst)
            cycle_count <= 0;
        else
            cycle_count <= cycle_count + 1;
    end

    task automatic pulse_start(
        input logic [1:0]  mode,
        input logic [31:0] length,
        input logic [31:0] scalar,
        input logic        mask_enable
    );
        begin
            @(negedge clk);
            cfg_mode = mode;
            cfg_length = length;
            cfg_scalar = scalar;
            cfg_mask_enable = mask_enable;
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    task automatic wait_for_done;
        integer timeout;
        begin
            timeout = 0;
            while (!done && (timeout < 100)) begin
                @(posedge clk);
                timeout = timeout + 1;
            end
            if (!done)
                $fatal(1, "vector engine timeout");
            @(posedge clk);
        end
    endtask

    always @(posedge clk) begin
        if (!rst && result_valid && result_ready) begin
            if (result_base !== (accepted_vectors * LANES))
                $fatal(
                    1,
                    "result base mismatch expected=%0d actual=%0d",
                    accepted_vectors * LANES,
                    result_base
                );

            if ((cfg_length == 20) && (accepted_vectors == 1)) begin
                if (result_lane_mask !== 16'h000f)
                    $fatal(1, "tail lane mask mismatch: %04x", result_lane_mask);
            end else if (result_lane_mask !== 16'hffff) begin
                $fatal(1, "full lane mask mismatch: %04x", result_lane_mask);
            end

            for (lane = 0; lane < LANES; lane = lane + 1) begin
                if (result_lane_mask[lane]) begin
                    if (cfg_mode == MODE_ADD)
                        expected_lane = fp32_add(
                            payload_a_word,
                            payload_b_word
                        );
                    else if (cfg_mask_enable)
                        expected_lane = fp32_add(
                            fp32_mul(payload_a_word, cfg_scalar),
                            payload_b_word
                        );
                    else
                        expected_lane = fp32_mul(
                            payload_a_word,
                            cfg_scalar
                        );

                    if (result_data[lane*32 +: 32] !== expected_lane)
                        $fatal(
                            1,
                            "lane %0d mismatch expected=%08x actual=%08x",
                            lane,
                            expected_lane,
                            result_data[lane*32 +: 32]
                        );
                end else if (result_data[lane*32 +: 32] !== 32'd0) begin
                    $fatal(1, "inactive lane %0d was not zero", lane);
                end
            end
            accepted_vectors = accepted_vectors + 1;
        end
    end

    task automatic run_value_case(
        input logic [1:0]  mode,
        input logic [31:0] scalar,
        input logic        mask_enable,
        input logic [31:0] a_word,
        input logic [31:0] b_word
    );
        begin
            accepted_vectors = 0;
            payload_a_word = a_word;
            payload_b_word = b_word;
            pulse_start(mode, 32'd16, scalar, mask_enable);
            wait_for_done();
            if (config_error || (accepted_vectors != 1))
                $fatal(
                    1,
                    "directed value case failed mode=%0d mask=%0d a=%08x b=%08x scalar=%08x",
                    mode,
                    mask_enable,
                    a_word,
                    b_word,
                    scalar
                );
        end
    endtask

    initial begin
        rst = 1'b1;
        start = 1'b0;
        cfg_mode = MODE_ADD;
        cfg_length = 32'd0;
        cfg_scalar = 32'h4000_0000;
        cfg_mask_enable = 1'b0;
        accepted_vectors = 0;
        cycle_count = 0;
        run_start_cycle = 0;
        add_cycles = 0;
        scale_mask_cycles = 0;
        scale_nomask_cycles = 0;
        payload_a_word = 32'h3f80_0000;
        payload_b_word = 32'h4000_0000;

        repeat (4) @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        run_start_cycle = cycle_count;
        pulse_start(MODE_ADD, 32'd20, 32'h4000_0000, 1'b0);
        wait_for_done();
        add_cycles = cycle_count - run_start_cycle;
        if (config_error || (accepted_vectors != 2))
            $fatal(1, "MODE_ADD failed vectors=%0d", accepted_vectors);

        accepted_vectors = 0;
        payload_a_word = 32'h3f80_0000;
        payload_b_word = 32'hbf80_0000;
        run_start_cycle = cycle_count;
        pulse_start(MODE_SCALE_MASK, 32'd16, 32'h4000_0000, 1'b1);
        wait_for_done();
        scale_mask_cycles = cycle_count - run_start_cycle;
        if (config_error || (accepted_vectors != 1))
            $fatal(1, "MODE_SCALE_MASK failed");

        accepted_vectors = 0;
        payload_a_word = 32'h3f80_0000;
        payload_b_word = 32'hbf80_0000;
        run_start_cycle = cycle_count;
        pulse_start(MODE_SCALE_MASK, 32'd16, 32'h4000_0000, 1'b0);
        wait_for_done();
        scale_nomask_cycles = cycle_count - run_start_cycle;
        if (config_error || (accepted_vectors != 1))
            $fatal(1, "MODE_SCALE_MASK no-mask failed");

        if (add_cycles != EXPECTED_ADD_CYCLES)
            $fatal(
                1,
                "MODE_ADD cycle regression expected=%0d actual=%0d",
                EXPECTED_ADD_CYCLES,
                add_cycles
            );
        if (scale_mask_cycles != EXPECTED_SCALE_MASK_CYCLES)
            $fatal(
                1,
                "MODE_SCALE_MASK masked cycle regression expected=%0d actual=%0d",
                EXPECTED_SCALE_MASK_CYCLES,
                scale_mask_cycles
            );
        if (scale_nomask_cycles != EXPECTED_SCALE_NOMASK_CYCLES)
            $fatal(
                1,
                "MODE_SCALE_MASK no-mask cycle regression expected=%0d actual=%0d",
                EXPECTED_SCALE_NOMASK_CYCLES,
                scale_nomask_cycles
            );

        // Exercise the M8 bypasses with values that stress the unchanged
        // FP32 leaf behavior.  The expected path uses the repository's
        // synthesis-compatible FP32 package, while the payload buses are
        // poisoned immediately after each request handshake.
        run_value_case(
            MODE_ADD, 32'h3f80_0000, 1'b0,
            32'h0000_0000, 32'h8000_0000
        );
        run_value_case(
            MODE_ADD, 32'h3f80_0000, 1'b0,
            32'h7f80_0000, 32'hff80_0000
        );
        run_value_case(
            MODE_ADD, 32'h3f80_0000, 1'b0,
            32'h7fc1_2345, 32'h3f80_0000
        );
        run_value_case(
            MODE_ADD, 32'h3f80_0000, 1'b0,
            32'h7f7f_ffff, 32'h7f7f_ffff
        );
        run_value_case(
            MODE_SCALE_MASK, 32'h0000_0000, 1'b0,
            32'h7f80_0000, 32'h7fc0_0000
        );
        run_value_case(
            MODE_SCALE_MASK, 32'h4000_0000, 1'b0,
            32'h0000_0001, 32'h7fc0_0000
        );
        run_value_case(
            MODE_SCALE_MASK, 32'hbf80_0000, 1'b1,
            32'h3f00_0000, 32'h3f80_0000
        );

        pulse_start(2'd3, 32'd16, 32'h3f80_0000, 1'b0);
        wait_for_done();
        if (!config_error)
            $fatal(1, "invalid vector mode was accepted");

        $display(
            "VECTOR_ENGINE_PASS implementation=%s add_cycles=%0d scale_mask_cycles=%0d scale_nomask_cycles=%0d",
            IMPLEMENTATION_LABEL,
            add_cycles,
            scale_mask_cycles,
            scale_nomask_cycles
        );
        $finish;
    end

endmodule
