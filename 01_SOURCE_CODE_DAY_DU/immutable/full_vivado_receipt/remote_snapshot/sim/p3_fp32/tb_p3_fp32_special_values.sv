`timescale 1ns/1ps

// T029 numeric-contract test. This test drives the generated Xilinx
// Floating-Point Operator IPs directly and compares raw binary32 result bits
// with the checked-in T030 Xilinx bit-accurate C-model vectors.
module tb_p3_fp32_special_values;
    localparam integer MUL_VECTOR_COUNT = 8;
    localparam integer FMA_VECTOR_COUNT = 8;

    logic aclk;
    logic aresetn;
    integer cycle_count;
    integer error_count;

    logic        mul_a_valid;
    logic        mul_a_ready;
    logic [31:0] mul_a_data;
    logic        mul_a_last;
    logic        mul_b_valid;
    logic        mul_b_ready;
    logic [31:0] mul_b_data;
    logic        mul_out_valid;
    logic        mul_out_ready;
    logic [31:0] mul_out_data;
    logic        mul_out_last;

    logic        fma_a_valid;
    logic        fma_a_ready;
    logic [31:0] fma_a_data;
    logic        fma_b_valid;
    logic        fma_b_ready;
    logic [31:0] fma_b_data;
    logic        fma_c_valid;
    logic        fma_c_ready;
    logic [31:0] fma_c_data;
    logic        fma_out_valid;
    logic        fma_out_ready;
    logic [31:0] fma_out_data;

    logic        accum_in_valid;
    logic        accum_in_ready;
    logic [31:0] accum_in_data;
    logic        accum_in_last;
    logic        accum_out_valid;
    logic        accum_out_ready;
    logic [31:0] accum_out_data;
    logic        accum_out_last;

    logic [31:0] mul_a_vector [0:MUL_VECTOR_COUNT-1];
    logic [31:0] mul_b_vector [0:MUL_VECTOR_COUNT-1];
    logic [31:0] mul_expected [0:MUL_VECTOR_COUNT-1];
    logic [31:0] fma_a_vector [0:FMA_VECTOR_COUNT-1];
    logic [31:0] fma_b_vector [0:FMA_VECTOR_COUNT-1];
    logic [31:0] fma_c_vector [0:FMA_VECTOR_COUNT-1];
    logic [31:0] fma_expected [0:FMA_VECTOR_COUNT-1];
    logic [31:0] accum_vector [0:4];

    fp_mul_single u_multiplier (
        .aclk                 (aclk),
        .aresetn              (aresetn),
        .s_axis_a_tvalid      (mul_a_valid),
        .s_axis_a_tready      (mul_a_ready),
        .s_axis_a_tdata       (mul_a_data),
        .s_axis_a_tlast       (mul_a_last),
        .s_axis_b_tvalid      (mul_b_valid),
        .s_axis_b_tready      (mul_b_ready),
        .s_axis_b_tdata       (mul_b_data),
        .m_axis_result_tvalid (mul_out_valid),
        .m_axis_result_tready (mul_out_ready),
        .m_axis_result_tdata  (mul_out_data),
        .m_axis_result_tlast  (mul_out_last)
    );

    fp_fma_single u_fma (
        .aclk                 (aclk),
        .aresetn              (aresetn),
        .s_axis_a_tvalid      (fma_a_valid),
        .s_axis_a_tready      (fma_a_ready),
        .s_axis_a_tdata       (fma_a_data),
        .s_axis_b_tvalid      (fma_b_valid),
        .s_axis_b_tready      (fma_b_ready),
        .s_axis_b_tdata       (fma_b_data),
        .s_axis_c_tvalid      (fma_c_valid),
        .s_axis_c_tready      (fma_c_ready),
        .s_axis_c_tdata       (fma_c_data),
        .m_axis_result_tvalid (fma_out_valid),
        .m_axis_result_tready (fma_out_ready),
        .m_axis_result_tdata  (fma_out_data)
    );

    fp_accum_single u_accumulator (
        .aclk                 (aclk),
        .aresetn              (aresetn),
        .s_axis_a_tvalid      (accum_in_valid),
        .s_axis_a_tready      (accum_in_ready),
        .s_axis_a_tdata       (accum_in_data),
        .s_axis_a_tlast       (accum_in_last),
        .m_axis_result_tvalid (accum_out_valid),
        .m_axis_result_tready (accum_out_ready),
        .m_axis_result_tdata  (accum_out_data),
        .m_axis_result_tlast  (accum_out_last)
    );

    initial begin
        aclk = 1'b0;
        forever #2.5 aclk = ~aclk;
    end

    always @(posedge aclk) begin
        cycle_count <= cycle_count + 1;
    end

    task automatic record_error(input string message);
        begin
            error_count = error_count + 1;
            $error("T029_CHECK_FAIL cycle=%0d %s", cycle_count, message);
        end
    endtask

    task automatic run_mul_vector(
        input  integer      vector_index,
        input  logic [31:0] operand_a,
        input  logic [31:0] operand_b,
        input  logic [31:0] expected,
        output integer      observed_latency
    );
        integer a_pending;
        integer b_pending;
        integer accepted_cycle;
        integer timeout_cycles;
        begin
            a_pending = 1;
            b_pending = 1;
            accepted_cycle = -1;
            while ((a_pending != 0) || (b_pending != 0)) begin
                @(negedge aclk);
                mul_a_valid = a_pending[0];
                mul_b_valid = b_pending[0];
                mul_a_data = operand_a;
                mul_b_data = operand_b;
                mul_a_last = 1'b1;
                @(posedge aclk);
                if ((a_pending != 0) && (mul_a_ready === 1'b1)) begin
                    a_pending = 0;
                end
                if ((b_pending != 0) && (mul_b_ready === 1'b1)) begin
                    b_pending = 0;
                end
                if ((a_pending == 0) && (b_pending == 0)) begin
                    accepted_cycle = cycle_count;
                end
            end
            @(negedge aclk);
            mul_a_valid = 1'b0;
            mul_b_valid = 1'b0;
            mul_a_last = 1'b0;

            timeout_cycles = 0;
            while ((mul_out_valid !== 1'b1) && (timeout_cycles < 100)) begin
                @(posedge aclk);
                timeout_cycles = timeout_cycles + 1;
            end
            if (mul_out_valid !== 1'b1) begin
                $fatal(1, "T029_TIMEOUT multiplier vector=%0d", vector_index);
            end
            observed_latency = cycle_count - accepted_cycle;
            if (mul_out_data !== expected || mul_out_last !== 1'b1) begin
                record_error(
                    $sformatf(
                        "MUL index=%0d a=%08x b=%08x actual=%08x/%0b expected=%08x/1",
                        vector_index,
                        operand_a,
                        operand_b,
                        mul_out_data,
                        mul_out_last,
                        expected
                    )
                );
            end else begin
                $display(
                    "T029_MUL_PASS index=%0d a=%08x b=%08x result=%08x latency=%0d",
                    vector_index,
                    operand_a,
                    operand_b,
                    mul_out_data,
                    observed_latency
                );
            end
            @(posedge aclk);
        end
    endtask

    task automatic run_fma_vector(
        input  integer      vector_index,
        input  logic [31:0] operand_a,
        input  logic [31:0] operand_b,
        input  logic [31:0] operand_c,
        input  logic [31:0] expected,
        output integer      observed_latency
    );
        integer a_pending;
        integer b_pending;
        integer c_pending;
        integer accepted_cycle;
        integer timeout_cycles;
        begin
            a_pending = 1;
            b_pending = 1;
            c_pending = 1;
            accepted_cycle = -1;
            while ((a_pending != 0) ||
                   (b_pending != 0) ||
                   (c_pending != 0)) begin
                @(negedge aclk);
                fma_a_valid = a_pending[0];
                fma_b_valid = b_pending[0];
                fma_c_valid = c_pending[0];
                fma_a_data = operand_a;
                fma_b_data = operand_b;
                fma_c_data = operand_c;
                @(posedge aclk);
                if ((a_pending != 0) && (fma_a_ready === 1'b1)) begin
                    a_pending = 0;
                end
                if ((b_pending != 0) && (fma_b_ready === 1'b1)) begin
                    b_pending = 0;
                end
                if ((c_pending != 0) && (fma_c_ready === 1'b1)) begin
                    c_pending = 0;
                end
                if ((a_pending == 0) &&
                    (b_pending == 0) &&
                    (c_pending == 0)) begin
                    accepted_cycle = cycle_count;
                end
            end
            @(negedge aclk);
            fma_a_valid = 1'b0;
            fma_b_valid = 1'b0;
            fma_c_valid = 1'b0;

            timeout_cycles = 0;
            while ((fma_out_valid !== 1'b1) && (timeout_cycles < 120)) begin
                @(posedge aclk);
                timeout_cycles = timeout_cycles + 1;
            end
            if (fma_out_valid !== 1'b1) begin
                $fatal(1, "T029_TIMEOUT FMA vector=%0d", vector_index);
            end
            observed_latency = cycle_count - accepted_cycle;
            if (fma_out_data !== expected) begin
                record_error(
                    $sformatf(
                        "FMA index=%0d a=%08x b=%08x c=%08x actual=%08x expected=%08x",
                        vector_index,
                        operand_a,
                        operand_b,
                        operand_c,
                        fma_out_data,
                        expected
                    )
                );
            end else begin
                $display(
                    "T029_FMA_PASS index=%0d a=%08x b=%08x c=%08x result=%08x latency=%0d",
                    vector_index,
                    operand_a,
                    operand_b,
                    operand_c,
                    fma_out_data,
                    observed_latency
                );
            end
            @(posedge aclk);
        end
    endtask

    task automatic run_accumulator_vector(output integer observed_latency);
        integer sample_index;
        integer accepted;
        integer last_accepted_cycle;
        integer timeout_cycles;
        begin
            last_accepted_cycle = -1;
            for (sample_index = 0; sample_index < 5;
                 sample_index = sample_index + 1) begin
                @(negedge aclk);
                accum_in_valid = 1'b1;
                accum_in_data = accum_vector[sample_index];
                accum_in_last = (sample_index == 4);
                accepted = 0;
                while (accepted == 0) begin
                    @(posedge aclk);
                    if (accum_in_ready === 1'b1) begin
                        accepted = 1;
                        if (sample_index == 4) begin
                            last_accepted_cycle = cycle_count;
                        end
                    end
                end
            end
            @(negedge aclk);
            accum_in_valid = 1'b0;
            accum_in_last = 1'b0;

            timeout_cycles = 0;
            while (((accum_out_valid !== 1'b1) ||
                    (accum_out_last !== 1'b1)) &&
                   (timeout_cycles < 150)) begin
                @(posedge aclk);
                timeout_cycles = timeout_cycles + 1;
            end
            if (accum_out_valid !== 1'b1 ||
                accum_out_last !== 1'b1) begin
                $fatal(1, "T029_TIMEOUT accumulator final result");
            end
            observed_latency = cycle_count - last_accepted_cycle;
            if (accum_out_data !== 32'hc20e_0000) begin
                record_error(
                    $sformatf(
                        "ACCUM actual=%08x expected=c20e0000",
                        accum_out_data
                    )
                );
            end else begin
                $display(
                    "T029_ACCUM_PASS samples=5 result=%08x final_latency=%0d",
                    accum_out_data,
                    observed_latency
                );
            end
            @(posedge aclk);
        end
    endtask

    integer vector_index;
    integer latency;
    integer first_mul_latency;
    integer first_fma_latency;

    initial begin
        cycle_count = 0;
        error_count = 0;
        aresetn = 1'b0;

        mul_a_valid = 1'b0;
        mul_a_data = 32'h0;
        mul_a_last = 1'b0;
        mul_b_valid = 1'b0;
        mul_b_data = 32'h0;
        mul_out_ready = 1'b1;

        fma_a_valid = 1'b0;
        fma_a_data = 32'h0;
        fma_b_valid = 1'b0;
        fma_b_data = 32'h0;
        fma_c_valid = 1'b0;
        fma_c_data = 32'h0;
        fma_out_ready = 1'b1;

        accum_in_valid = 1'b0;
        accum_in_data = 32'h0;
        accum_in_last = 1'b0;
        accum_out_ready = 1'b1;

        // MUL vectors 0..7 from T030.
        mul_a_vector[0] = 32'h3fc0_0000;
        mul_b_vector[0] = 32'h4000_0000;
        mul_expected[0] = 32'h4040_0000;
        mul_a_vector[1] = 32'hbfc0_0000;
        mul_b_vector[1] = 32'h4000_0000;
        mul_expected[1] = 32'hc040_0000;
        mul_a_vector[2] = 32'h8000_0000;
        mul_b_vector[2] = 32'h4000_0000;
        mul_expected[2] = 32'h8000_0000;
        mul_a_vector[3] = 32'h7f7f_ffff;
        mul_b_vector[3] = 32'h4000_0000;
        mul_expected[3] = 32'h7f80_0000;
        mul_a_vector[4] = 32'h0080_0000;
        mul_b_vector[4] = 32'h3f00_0000;
        mul_expected[4] = 32'h0000_0000;
        mul_a_vector[5] = 32'h0000_0001;
        mul_b_vector[5] = 32'h3f80_0000;
        mul_expected[5] = 32'h0000_0000;
        mul_a_vector[6] = 32'h7f80_0000;
        mul_b_vector[6] = 32'h0000_0000;
        mul_expected[6] = 32'h7fc0_0000;
        mul_a_vector[7] = 32'h7fc1_2345;
        mul_b_vector[7] = 32'h3f80_0000;
        mul_expected[7] = 32'h7fc0_0000;

        // FMA vectors 8..15 from T030.
        fma_a_vector[0] = 32'h3fc0_0000;
        fma_b_vector[0] = 32'h4000_0000;
        fma_c_vector[0] = 32'h3e80_0000;
        fma_expected[0] = 32'h4050_0000;
        fma_a_vector[1] = 32'h3f80_0001;
        fma_b_vector[1] = 32'h3f7f_ffff;
        fma_c_vector[1] = 32'hbf80_0000;
        fma_expected[1] = 32'h337f_fffe;
        fma_a_vector[2] = 32'h3f80_0000;
        fma_b_vector[2] = 32'h3f80_0000;
        fma_c_vector[2] = 32'hbf80_0000;
        fma_expected[2] = 32'h0000_0000;
        fma_a_vector[3] = 32'h7f7f_ffff;
        fma_b_vector[3] = 32'h4000_0000;
        fma_c_vector[3] = 32'h0000_0000;
        fma_expected[3] = 32'h7f80_0000;
        fma_a_vector[4] = 32'h0080_0000;
        fma_b_vector[4] = 32'h3f00_0000;
        fma_c_vector[4] = 32'h0000_0000;
        fma_expected[4] = 32'h0000_0000;
        fma_a_vector[5] = 32'h7f80_0000;
        fma_b_vector[5] = 32'h0000_0000;
        fma_c_vector[5] = 32'h3f80_0000;
        fma_expected[5] = 32'h7fc0_0000;
        fma_a_vector[6] = 32'h7f80_0000;
        fma_b_vector[6] = 32'h0000_0000;
        fma_c_vector[6] = 32'h7fc0_0000;
        fma_expected[6] = 32'h7fc0_0000;
        fma_a_vector[7] = 32'h7fc1_2345;
        fma_b_vector[7] = 32'h3f80_0000;
        fma_c_vector[7] = 32'h4000_0000;
        fma_expected[7] = 32'h7fc0_0000;

        accum_vector[0] = 32'h3fc0_0000;
        accum_vector[1] = 32'h4010_0000;
        accum_vector[2] = 32'h4120_0000;
        accum_vector[3] = 32'hc2c8_0000;
        accum_vector[4] = 32'h424b_0000;

        repeat (8) @(posedge aclk);
        @(negedge aclk);
        aresetn = 1'b1;
        repeat (3) @(posedge aclk);
        $display("T029_RESET_PASS cycle=%0d", cycle_count);

        first_mul_latency = -1;
        for (vector_index = 0;
             vector_index < MUL_VECTOR_COUNT;
             vector_index = vector_index + 1) begin
            run_mul_vector(
                vector_index,
                mul_a_vector[vector_index],
                mul_b_vector[vector_index],
                mul_expected[vector_index],
                latency
            );
            if (first_mul_latency < 0) begin
                first_mul_latency = latency;
            end else if (latency != first_mul_latency) begin
                record_error(
                    $sformatf(
                        "MUL latency changed from %0d to %0d",
                        first_mul_latency,
                        latency
                    )
                );
            end
        end

        first_fma_latency = -1;
        for (vector_index = 0;
             vector_index < FMA_VECTOR_COUNT;
             vector_index = vector_index + 1) begin
            run_fma_vector(
                vector_index + 8,
                fma_a_vector[vector_index],
                fma_b_vector[vector_index],
                fma_c_vector[vector_index],
                fma_expected[vector_index],
                latency
            );
            if (first_fma_latency < 0) begin
                first_fma_latency = latency;
            end else if (latency != first_fma_latency) begin
                record_error(
                    $sformatf(
                        "FMA latency changed from %0d to %0d",
                        first_fma_latency,
                        latency
                    )
                );
            end
        end

        run_accumulator_vector(latency);

        repeat (5) @(posedge aclk);
        if (error_count == 0) begin
            $display(
                "T029_SPECIAL_VALUES_PASS mul_vectors=8 fma_vectors=8 accum_vectors=5 mul_latency=%0d fma_latency=%0d",
                first_mul_latency,
                first_fma_latency
            );
            $finish;
        end
        $fatal(1, "T029_SPECIAL_VALUES_FAIL error_count=%0d", error_count);
    end

    initial begin
        repeat (5000) @(posedge aclk);
        $fatal(1, "T029_GLOBAL_TIMEOUT");
    end
endmodule
