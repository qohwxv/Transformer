`timescale 1ns/1ps

// Pure-SystemVerilog, simulation-only arithmetic backend for the Phase-E
// synthesizable descriptor/controller contract.
//
// Raw INPUT/PARAM/SCRATCH memories remain IEEE-754 binary32 word arrays.  A
// real-valued shadow is synchronized after the testbench uses $readmemh, then
// each complete descriptor is evaluated by blocking SystemVerilog tasks.  The
// result of every descriptor is explicitly rounded back through binary32.
//
// This backend intentionally has no C/C++/DPI/VPI dependency.  Its real math,
// dynamic shadow arrays, and blocking whole-tensor tasks are NOT synthesizable.
// The sequencer, descriptor addressing, raw memory contract, and handshakes
// around it remain the replaceable/synthesizable portion of the design.
module vit_phase_e_behavioral_engine_top #(
    parameter integer ARRAY_ROWS      = 2,
    parameter integer ARRAY_COLS      = 2,
    parameter integer PE_LANES        = 16,
    parameter integer VECTOR_LANES    = 16,
    parameter integer SCRATCH_WORDS   = 32'h001e_6000,
    parameter integer INPUT_WORDS     = 150_528,
    parameter integer PARAM_WORDS     = 32'h0024_1000
)(
    input  logic                          clk,
    input  logic                          rst,

    input  logic                          cmd_valid,
    output logic                          cmd_ready,
    input  vit_phase_e_pkg::phase_e_cmd_t cmd,
    output logic                          cmd_done,
    output logic                          cmd_error,
    output logic                          busy,

    output logic                          parameter_request,
    input  logic                          parameter_ready,
    output vit_phase_e_pkg::phase_e_cmd_t parameter_command,

    input  logic                          input_write_enable,
    input  logic [31:0]                   input_write_address,
    input  logic [31:0]                   input_write_data,
    input  logic                          parameter_write_enable,
    input  logic [31:0]                   parameter_write_address,
    input  logic [31:0]                   parameter_write_data,
    input  logic                          scratch_write_enable,
    input  logic [31:0]                   scratch_write_address,
    input  logic [31:0]                   scratch_write_data,
    input  logic [31:0]                   scratch_read_address,
    output logic [31:0]                   scratch_read_data,

    output logic                          class_result_valid,
    output logic [31:0]                   class_index,
    output logic [31:0]                   class_logit
);

    import vit_phase_e_pkg::*;
    import vit_fp32_math_ref_pkg::*;

    localparam logic [31:0] FP32_QNAN = 32'h7fc0_0000;

    // The raw memories retain the synthesizable engine's names/addressing
    // contract, but are dynamic in this explicitly simulation-only backend.
    // The testbench owns one reusable static $readmemh staging buffer and then
    // copies the requested region here.
    logic [31:0] scratch_memory[];
    logic [31:0] input_memory[];
    logic [31:0] parameter_memory[];

    // Simulation-only cached values.  Caching avoids decoding an FP32 word on
    // every one of the model's roughly 17.5 billion multiply-accumulates.
    real scratch_value[];
    real input_value[];
    real parameter_value[];
    logic shadow_ready;

    typedef enum logic [2:0] {
        ENGINE_IDLE,
        ENGINE_WAIT_PARAMETER,
        ENGINE_EXECUTE,
        ENGINE_REPORT
    } engine_state_t;

    engine_state_t state;
    phase_e_cmd_t active_cmd;
    logic report_error;
    logic execution_error;
    logic argmax_produced;

    initial begin
        shadow_ready = 1'b0;
        scratch_memory = new[SCRATCH_WORDS];
        input_memory = new[INPUT_WORDS];
        parameter_memory = new[PARAM_WORDS];
        scratch_value = new[SCRATCH_WORDS];
        input_value = new[INPUT_WORDS];
        parameter_value = new[PARAM_WORDS];
        shadow_ready = 1'b1;
    end

    // These synchronization tasks are called by the SystemVerilog testbench
    // immediately after its $readmemh operation.  File I/O therefore remains
    // outside the execution backend.
    task automatic sync_input_region(
        input integer start_address,
        input integer word_count
    );
        integer index;
        begin
            wait (shadow_ready === 1'b1);
            for (index = 0; index < word_count; index = index + 1)
                input_value[start_address + index] =
                    fp32_ref_to_real(input_memory[start_address + index]);
        end
    endtask

    task automatic sync_parameter_region(
        input integer start_address,
        input integer word_count
    );
        integer index;
        begin
            wait (shadow_ready === 1'b1);
            for (index = 0; index < word_count; index = index + 1)
                parameter_value[start_address + index] =
                    fp32_ref_to_real(parameter_memory[start_address + index]);
        end
    endtask

    task automatic sync_scratch_region(
        input integer start_address,
        input integer word_count
    );
        integer index;
        begin
            wait (shadow_ready === 1'b1);
            for (index = 0; index < word_count; index = index + 1)
                scratch_value[start_address + index] =
                    fp32_ref_to_real(scratch_memory[start_address + index]);
        end
    endtask

    function automatic logic command_needs_parameters(input phase_e_cmd_t value);
        begin
            command_needs_parameters =
                (value.route.src0_space == PHASE_E_MEM_PARAM) ||
                (value.route.src1_space == PHASE_E_MEM_PARAM) ||
                (value.route.src2_space == PHASE_E_MEM_PARAM);
        end
    endfunction

    function automatic real read_value(
        input phase_e_mem_space_t space,
        input integer address
    );
        begin
            case (space)
                PHASE_E_MEM_SCRATCH: begin
                    if ((address >= 0) && (address < SCRATCH_WORDS))
                        read_value = scratch_value[address];
                    else begin
                        read_value = 0.0;
                        $error("Scratch read out of range: %0d", address);
                    end
                end
                PHASE_E_MEM_PARAM: begin
                    if ((address >= 0) && (address < PARAM_WORDS))
                        read_value = parameter_value[address];
                    else begin
                        read_value = 0.0;
                        $error("Parameter read out of range: %0d", address);
                    end
                end
                PHASE_E_MEM_INPUT: begin
                    if ((address >= 0) && (address < INPUT_WORDS))
                        read_value = input_value[address];
                    else begin
                        read_value = 0.0;
                        $error("Input read out of range: %0d", address);
                    end
                end
                default: read_value = 0.0;
            endcase
        end
    endfunction

    task automatic write_scratch_real(
        input integer address,
        input real value
    );
        logic [31:0] rounded_word;
        begin
            if ((address < 0) || (address >= SCRATCH_WORDS)) begin
                execution_error = 1'b1;
                $error("Scratch write out of range: %0d", address);
            end else begin
                // Explicit conversion is the binary32 operation boundary.
                rounded_word = fp32_ref_from_real(value);
                scratch_memory[address] = rounded_word;
                scratch_value[address] = fp32_ref_to_real(rounded_word);
            end
        end
    endtask

    // Process sixteen adjacent output columns with local scalar accumulators.
    // This keeps B accesses contiguous without the interpreter overhead of a
    // dynamically indexed accumulator array. Each scalar still reduces K in
    // increasing order.
`define VIT_REAL_GEMM_BLOCKED(A_MEMORY, B_MEMORY) \
        for (column_block = 0; column_block < full_columns; column_block = column_block + 16) begin \
            sum0 = 0.0;  sum1 = 0.0;  sum2 = 0.0;  sum3 = 0.0; \
            sum4 = 0.0;  sum5 = 0.0;  sum6 = 0.0;  sum7 = 0.0; \
            sum8 = 0.0;  sum9 = 0.0;  sum10 = 0.0; sum11 = 0.0; \
            sum12 = 0.0; sum13 = 0.0; sum14 = 0.0; sum15 = 0.0; \
            for (reduction_index = 0; reduction_index < value.dim2; reduction_index = reduction_index + 1) begin \
                activation = A_MEMORY[a_row_base + reduction_index]; \
                weight_row_base = b_batch_base + reduction_index * b_row_stride + column_block; \
                sum0  = sum0  + activation * B_MEMORY[weight_row_base + 0]; \
                sum1  = sum1  + activation * B_MEMORY[weight_row_base + 1]; \
                sum2  = sum2  + activation * B_MEMORY[weight_row_base + 2]; \
                sum3  = sum3  + activation * B_MEMORY[weight_row_base + 3]; \
                sum4  = sum4  + activation * B_MEMORY[weight_row_base + 4]; \
                sum5  = sum5  + activation * B_MEMORY[weight_row_base + 5]; \
                sum6  = sum6  + activation * B_MEMORY[weight_row_base + 6]; \
                sum7  = sum7  + activation * B_MEMORY[weight_row_base + 7]; \
                sum8  = sum8  + activation * B_MEMORY[weight_row_base + 8]; \
                sum9  = sum9  + activation * B_MEMORY[weight_row_base + 9]; \
                sum10 = sum10 + activation * B_MEMORY[weight_row_base + 10]; \
                sum11 = sum11 + activation * B_MEMORY[weight_row_base + 11]; \
                sum12 = sum12 + activation * B_MEMORY[weight_row_base + 12]; \
                sum13 = sum13 + activation * B_MEMORY[weight_row_base + 13]; \
                sum14 = sum14 + activation * B_MEMORY[weight_row_base + 14]; \
                sum15 = sum15 + activation * B_MEMORY[weight_row_base + 15]; \
            end \
            if ((value.header.flags & PHASE_E_FLAG_BIAS_ENABLE) != 0) begin \
                sum0  = sum0  + read_value(value.route.src2_space, value.src2_base + column_block + 0); \
                sum1  = sum1  + read_value(value.route.src2_space, value.src2_base + column_block + 1); \
                sum2  = sum2  + read_value(value.route.src2_space, value.src2_base + column_block + 2); \
                sum3  = sum3  + read_value(value.route.src2_space, value.src2_base + column_block + 3); \
                sum4  = sum4  + read_value(value.route.src2_space, value.src2_base + column_block + 4); \
                sum5  = sum5  + read_value(value.route.src2_space, value.src2_base + column_block + 5); \
                sum6  = sum6  + read_value(value.route.src2_space, value.src2_base + column_block + 6); \
                sum7  = sum7  + read_value(value.route.src2_space, value.src2_base + column_block + 7); \
                sum8  = sum8  + read_value(value.route.src2_space, value.src2_base + column_block + 8); \
                sum9  = sum9  + read_value(value.route.src2_space, value.src2_base + column_block + 9); \
                sum10 = sum10 + read_value(value.route.src2_space, value.src2_base + column_block + 10); \
                sum11 = sum11 + read_value(value.route.src2_space, value.src2_base + column_block + 11); \
                sum12 = sum12 + read_value(value.route.src2_space, value.src2_base + column_block + 12); \
                sum13 = sum13 + read_value(value.route.src2_space, value.src2_base + column_block + 13); \
                sum14 = sum14 + read_value(value.route.src2_space, value.src2_base + column_block + 14); \
                sum15 = sum15 + read_value(value.route.src2_space, value.src2_base + column_block + 15); \
            end \
            output_address = value.dst_base + batch * value.stride4 + row * value.immediate + column_block; \
            write_scratch_real(output_address + 0,  sum0);  write_scratch_real(output_address + 1,  sum1); \
            write_scratch_real(output_address + 2,  sum2);  write_scratch_real(output_address + 3,  sum3); \
            write_scratch_real(output_address + 4,  sum4);  write_scratch_real(output_address + 5,  sum5); \
            write_scratch_real(output_address + 6,  sum6);  write_scratch_real(output_address + 7,  sum7); \
            write_scratch_real(output_address + 8,  sum8);  write_scratch_real(output_address + 9,  sum9); \
            write_scratch_real(output_address + 10, sum10); write_scratch_real(output_address + 11, sum11); \
            write_scratch_real(output_address + 12, sum12); write_scratch_real(output_address + 13, sum13); \
            write_scratch_real(output_address + 14, sum14); write_scratch_real(output_address + 15, sum15); \
        end \
        for (column = full_columns; column < value.dim3; column = column + 1) begin \
            sum = 0.0; \
            for (reduction_index = 0; reduction_index < value.dim2; reduction_index = reduction_index + 1) \
                sum = sum + A_MEMORY[a_row_base + reduction_index] * \
                      B_MEMORY[b_batch_base + reduction_index * b_row_stride + column]; \
            if ((value.header.flags & PHASE_E_FLAG_BIAS_ENABLE) != 0) \
                sum = sum + read_value(value.route.src2_space, value.src2_base + column); \
            output_address = value.dst_base + batch * value.stride4 + row * value.immediate + column; \
            write_scratch_real(output_address, sum); \
        end

    task automatic execute_gemm(input phase_e_cmd_t value);
        integer batch;
        integer row;
        integer column;
        integer column_block;
        integer reduction_index;
        integer a_row_base;
        integer b_batch_base;
        integer b_row_stride;
        integer weight_row_base;
        integer output_address;
        integer full_columns;
        real activation;
        real sum;
        real sum0;
        real sum1;
        real sum2;
        real sum3;
        real sum4;
        real sum5;
        real sum6;
        real sum7;
        real sum8;
        real sum9;
        real sum10;
        real sum11;
        real sum12;
        real sum13;
        real sum14;
        real sum15;
        begin
            b_row_stride = value.stride3;
            full_columns = (value.dim3 / 16) * 16;
            $display(
                "[SV-DATAPATH] GEMM batch=%0d M=%0d K=%0d N=%0d",
                value.dim0, value.dim1, value.dim2, value.dim3
            );

            for (batch = 0; batch < value.dim0; batch = batch + 1) begin
                b_batch_base = value.src1_base + batch * value.stride2;
                for (row = 0; row < value.dim1; row = row + 1) begin
                    if ((row % 32) == 0) begin
                        $display(
                            "[SV-DATAPATH]   GEMM progress batch=%0d row=%0d/%0d",
                            batch, row, value.dim1
                        );
                        $fflush();
                    end
                    a_row_base = value.src0_base + batch * value.stride0 +
                                 row * value.stride1;
                    if ((value.route.src0_space == PHASE_E_MEM_INPUT) &&
                        (value.route.src1_space == PHASE_E_MEM_PARAM)) begin
                        `VIT_REAL_GEMM_BLOCKED(input_value, parameter_value)
                    end else if ((value.route.src0_space == PHASE_E_MEM_SCRATCH) &&
                                 (value.route.src1_space == PHASE_E_MEM_PARAM)) begin
                        `VIT_REAL_GEMM_BLOCKED(scratch_value, parameter_value)
                    end else if ((value.route.src0_space == PHASE_E_MEM_SCRATCH) &&
                                 (value.route.src1_space == PHASE_E_MEM_SCRATCH)) begin
                        `VIT_REAL_GEMM_BLOCKED(scratch_value, scratch_value)
                    end else begin
                        execution_error = 1'b1;
                        $error(
                            "Unsupported GEMM memory spaces A=%0d B=%0d",
                            value.route.src0_space,
                            value.route.src1_space
                        );
                    end

                end
            end
        end
    endtask

    task automatic execute_vector(input phase_e_cmd_t value);
        integer index;
        real operand_a;
        real operand_b;
        real scalar;
        real result;
        begin
            scalar = fp32_ref_to_real(value.immediate);
            $display(
                "[SV-DATAPATH] VECTOR subop=%0d length=%0d",
                value.header.subop,
                value.dim0
            );
            for (index = 0; index < value.dim0; index = index + 1) begin
                operand_a = read_value(value.route.src0_space, value.src0_base + index);
                case (value.header.subop)
                    PHASE_E_SUBOP_VECTOR_ADD: begin
                        operand_b = read_value(
                            value.route.src1_space,
                            value.src1_base + index
                        );
                        result = operand_a + operand_b;
                    end
                    PHASE_E_SUBOP_VECTOR_SCALE_MASK: begin
                        result = operand_a * scalar;
                        if ((value.header.flags & PHASE_E_FLAG_MASK_ENABLE) != 0) begin
                            operand_b = read_value(
                                value.route.src1_space,
                                value.src1_base + index
                            );
                            result = result + operand_b;
                        end
                    end
                    default: begin
                        result = 0.0;
                        execution_error = 1'b1;
                        $error("Unsupported VECTOR subop %0d", value.header.subop);
                    end
                endcase
                write_scratch_real(value.dst_base + index, result);
            end
        end
    endtask

    task automatic execute_layout(input phase_e_cmd_t value);
        integer index0;
        integer index1;
        integer index2;
        integer source_address;
        integer destination_address;
        real element;
        begin
            $display(
                "[SV-DATAPATH] LAYOUT dims=%0d x %0d x %0d",
                value.dim0, value.dim1, value.dim2
            );
            for (index0 = 0; index0 < value.dim0; index0 = index0 + 1) begin
                for (index1 = 0; index1 < value.dim1; index1 = index1 + 1) begin
                    for (index2 = 0; index2 < value.dim2; index2 = index2 + 1) begin
                        source_address = value.src0_base + index0 * value.stride0 +
                                         index1 * value.stride1 + index2 * value.stride2;
                        destination_address = value.dst_base +
                            (index0 * value.dim1 + index1) * value.dim2 + index2;
                        element = read_value(value.route.src0_space, source_address);
                        write_scratch_real(destination_address, element);
                    end
                end
            end
        end
    endtask

    task automatic execute_layernorm(input phase_e_cmd_t value);
        integer token;
        integer channel;
        real sum;
        real mean;
        real centered;
        real variance_sum;
        real variance;
        real inverse_std;
        real epsilon;
        real normalized;
        real gamma;
        real beta;
        begin
            epsilon = fp32_ref_to_real(value.immediate);
            $display(
                "[SV-DATAPATH] LAYERNORM tokens=%0d hidden=%0d",
                value.dim0,
                value.dim1
            );
            for (token = 0; token < value.dim0; token = token + 1) begin
                sum = 0.0;
                for (channel = 0; channel < value.dim1; channel = channel + 1)
                    sum = sum + read_value(
                        value.route.src0_space,
                        value.src0_base + token * value.dim1 + channel
                    );
                mean = sum / value.dim1;

                variance_sum = 0.0;
                for (channel = 0; channel < value.dim1; channel = channel + 1) begin
                    centered = read_value(
                        value.route.src0_space,
                        value.src0_base + token * value.dim1 + channel
                    ) - mean;
                    variance_sum = variance_sum + centered * centered;
                end
                variance = variance_sum / value.dim1;
                inverse_std = 1.0 / $sqrt(variance + epsilon);

                for (channel = 0; channel < value.dim1; channel = channel + 1) begin
                    normalized = (
                        read_value(
                            value.route.src0_space,
                            value.src0_base + token * value.dim1 + channel
                        ) - mean
                    ) * inverse_std;
                    gamma = parameter_value[value.src1_base + channel];
                    beta = parameter_value[value.src2_base + channel];
                    write_scratch_real(
                        value.dst_base + token * value.dim1 + channel,
                        normalized * gamma + beta
                    );
                end
            end
        end
    endtask

    task automatic execute_softmax(input phase_e_cmd_t value);
        integer row;
        integer column;
        integer source_address;
        real maximum;
        real element;
        real exponential_sum;
        real probability;
        begin
            $display(
                "[SV-DATAPATH] SOFTMAX rows=%0d columns=%0d",
                value.dim0,
                value.dim1
            );
            for (row = 0; row < value.dim0; row = row + 1) begin
                source_address = value.src0_base + row * value.dim1;
                maximum = read_value(value.route.src0_space, source_address);
                for (column = 1; column < value.dim1; column = column + 1) begin
                    element = read_value(
                        value.route.src0_space,
                        source_address + column
                    );
                    if (element > maximum)
                        maximum = element;
                end

                exponential_sum = 0.0;
                for (column = 0; column < value.dim1; column = column + 1)
                    exponential_sum = exponential_sum + $exp(
                        read_value(value.route.src0_space, source_address + column) -
                        maximum
                    );

                for (column = 0; column < value.dim1; column = column + 1) begin
                    probability = $exp(
                        read_value(value.route.src0_space, source_address + column) -
                        maximum
                    ) / exponential_sum;
                    write_scratch_real(
                        value.dst_base + row * value.dim1 + column,
                        probability
                    );
                end
            end
        end
    endtask

    task automatic execute_gelu(input phase_e_cmd_t value);
        integer index;
        real input_real;
        real result_real;
        begin
            $display("[SV-DATAPATH] GELU length=%0d", value.dim0);
            for (index = 0; index < value.dim0; index = index + 1) begin
                input_real = read_value(
                    value.route.src0_space,
                    value.src0_base + index
                );
                result_real = 0.5 * input_real * (
                    1.0 + erf_as_ref_real(input_real * 0.70710678118654752440)
                );
                write_scratch_real(value.dst_base + index, result_real);
            end
        end
    endtask

    task automatic execute_argmax(input phase_e_cmd_t value);
        integer index;
        integer best_index;
        real best_value;
        real candidate;
        begin
            $display("[SV-DATAPATH] ARGMAX length=%0d", value.dim0);
            best_index = 0;
            best_value = read_value(value.route.src0_space, value.src0_base);
            for (index = 1; index < value.dim0; index = index + 1) begin
                candidate = read_value(
                    value.route.src0_space,
                    value.src0_base + index
                );
                if (candidate > best_value) begin
                    best_value = candidate;
                    best_index = index;
                end
            end
            class_index = best_index;
            class_logit = scratch_memory[value.src0_base + best_index];
            argmax_produced = 1'b1;
        end
    endtask

    task automatic execute_command(input phase_e_cmd_t value);
        begin
            execution_error = 1'b0;
            argmax_produced = 1'b0;
            case (value.header.opcode)
                PHASE_E_OP_GEMM:      execute_gemm(value);
                PHASE_E_OP_VECTOR:    execute_vector(value);
                PHASE_E_OP_LAYOUT:    execute_layout(value);
                PHASE_E_OP_LAYERNORM: execute_layernorm(value);
                PHASE_E_OP_SOFTMAX:   execute_softmax(value);
                PHASE_E_OP_GELU:      execute_gelu(value);
                PHASE_E_OP_ARGMAX:    execute_argmax(value);
                default: begin
                    execution_error = 1'b1;
                    $error("Unsupported Phase-E opcode %0d", value.header.opcode);
                end
            endcase
        end
    endtask

`undef VIT_REAL_GEMM_BLOCKED

    assign cmd_ready = (state == ENGINE_IDLE);
    assign busy = (state != ENGINE_IDLE);
    assign parameter_request = (state == ENGINE_WAIT_PARAMETER);
    assign parameter_command = active_cmd;

    always_comb begin
        if (scratch_read_address < SCRATCH_WORDS)
            scratch_read_data = scratch_memory[scratch_read_address];
        else
            scratch_read_data = FP32_QNAN;
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= ENGINE_IDLE;
            active_cmd <= '0;
            cmd_done <= 1'b0;
            cmd_error <= 1'b0;
            report_error <= 1'b0;
            class_result_valid <= 1'b0;
            class_index <= 32'd0;
            class_logit <= 32'd0;
        end else begin
            cmd_done <= 1'b0;
            cmd_error <= 1'b0;
            class_result_valid <= 1'b0;

            if (input_write_enable && (input_write_address < INPUT_WORDS)) begin
                input_memory[input_write_address] = input_write_data;
                input_value[input_write_address] = fp32_ref_to_real(input_write_data);
            end
            if (parameter_write_enable && (parameter_write_address < PARAM_WORDS)) begin
                parameter_memory[parameter_write_address] = parameter_write_data;
                parameter_value[parameter_write_address] = fp32_ref_to_real(parameter_write_data);
            end
            if (scratch_write_enable && (scratch_write_address < SCRATCH_WORDS)) begin
                scratch_memory[scratch_write_address] = scratch_write_data;
                scratch_value[scratch_write_address] = fp32_ref_to_real(scratch_write_data);
            end

            case (state)
                ENGINE_IDLE: begin
                    if (cmd_valid) begin
                        active_cmd <= cmd;
                        if (command_needs_parameters(cmd))
                            state <= ENGINE_WAIT_PARAMETER;
                        else
                            state <= ENGINE_EXECUTE;
                    end
                end

                ENGINE_WAIT_PARAMETER: begin
                    if (parameter_ready)
                        state <= ENGINE_EXECUTE;
                end

                ENGINE_EXECUTE: begin
                    execute_command(active_cmd);
                    if (argmax_produced)
                        class_result_valid <= 1'b1;
                    report_error <= execution_error;
                    state <= ENGINE_REPORT;
                end

                ENGINE_REPORT: begin
                    if (report_error)
                        cmd_error <= 1'b1;
                    else
                        cmd_done <= 1'b1;
                    state <= ENGINE_IDLE;
                end

                default: begin
                    cmd_error <= 1'b1;
                    state <= ENGINE_IDLE;
                end
            endcase
        end
    end

endmodule
