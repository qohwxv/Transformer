`timescale 1ns/1ps

// M4 tail/padding gate.  The production operand router generates M/K/N masks;
// the production write router must then leave every padded output sentinel
// untouched.  The test is compiled independently for R4 and R8.
module tb_m4_tail_output_sentinel #(
    parameter integer ARRAY_ROWS = 4
);

    import vit_phase_e_pkg::*;

    localparam integer ARRAY_COLS = 2;
    localparam integer PE_LANES = 16;
    localparam integer RESULT_WORDS = ARRAY_ROWS * ARRAY_COLS;
    localparam integer MEMORY_WORDS = 256;
    localparam integer VALID_ROWS = ARRAY_ROWS - 1;
    localparam logic [31:0] SENTINEL = 32'hdead_beef;
    localparam logic [31:0] RESULT_BASE = 32'd32;
    localparam logic [31:0] RESULT_STRIDE = 32'd8;

    logic [31:0] active_m;
    logic [31:0] active_k;
    logic [31:0] active_n;
    logic [31:0] token_base;
    logic [31:0] output_base;
    logic [31:0] k_base;

    logic [ARRAY_ROWS*PE_LANES*32-1:0] activation_data;
    logic [ARRAY_COLS*PE_LANES*32-1:0] weight_data;
    logic [ARRAY_COLS*32-1:0] bias_data;
    logic [ARRAY_ROWS*PE_LANES*32-1:0] routed_activation_data;
    logic [ARRAY_COLS*PE_LANES*32-1:0] routed_weight_data;
    logic [ARRAY_COLS*32-1:0] routed_bias_data;
    logic [PE_LANES-1:0] lane_valid;
    logic [ARRAY_ROWS-1:0] token_valid;
    logic [ARRAY_COLS-1:0] output_valid;

    phase_e_cmd_t cmd;
    logic [15:0] word_index;
    logic [65:0] gemm_result_address_base;
    logic [RESULT_WORDS*32-1:0] gemm_result_data;
    logic candidate_needed;
    phase_e_mem_space_t candidate_space;
    logic [31:0] candidate_address;
    logic candidate_address_overflow;
    logic [31:0] candidate_data;

    logic [31:0] output_memory [0:MEMORY_WORDS-1];
    integer checks = 0;
    integer write_count = 0;
    integer row_index;
    integer col_index;
    integer lane_index;
    integer flat_index;
    integer address_index;

    vit_gemm_operand_router #(
        .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .PE_LANES(PE_LANES)
    ) u_operand_router (
        .active_m(active_m),
        .active_k(active_k),
        .active_n(active_n),
        .token_base(token_base),
        .output_base(output_base),
        .k_base(k_base),
        .activation_data(activation_data),
        .weight_data(weight_data),
        .bias_data(bias_data),
        .routed_activation_data(routed_activation_data),
        .routed_weight_data(routed_weight_data),
        .routed_bias_data(routed_bias_data),
        .lane_valid(lane_valid),
        .token_valid(token_valid),
        .output_valid(output_valid)
    );

    vit_phase_e_write_address_router #(
        .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .VECTOR_LANES(16)
    ) u_write_router (
        .active_cmd(cmd),
        .word_index(word_index),
        .gemm_result_address_base(gemm_result_address_base),
        .gemm_result_token_mask(token_valid),
        .gemm_result_output_mask(output_valid),
        .gemm_result_data(gemm_result_data),
        .vector_result_base(32'd0),
        .vector_result_lane_mask('0),
        .vector_result_data('0),
        .layout_result_address(32'd0),
        .layout_result_data(32'd0),
        .ln_result_index(32'd0),
        .ln_result_data(32'd0),
        .softmax_result_index(32'd0),
        .softmax_result_data(32'd0),
        .gelu_result_base_index(32'd0),
        .gelu_result_lane_mask('0),
        .gelu_result_data('0),
        .candidate_needed(candidate_needed),
        .candidate_space(candidate_space),
        .candidate_address(candidate_address),
        .candidate_address_overflow(candidate_address_overflow),
        .candidate_data(candidate_data)
    );

    function automatic logic [31:0] activation_pattern(
        input integer row_value,
        input integer lane_value
    );
        activation_pattern =
            32'ha000_0000 ^
            (32'(row_value) << 12) ^
            32'(lane_value);
    endfunction

    function automatic logic [31:0] weight_pattern(
        input integer col_value,
        input integer lane_value
    );
        weight_pattern =
            32'hb000_0000 ^
            (32'(col_value) << 12) ^
            32'(lane_value);
    endfunction

    function automatic logic [31:0] result_pattern(
        input integer row_value,
        input integer col_value
    );
        result_pattern =
            32'hc000_0000 ^
            (32'(row_value) << 8) ^
            32'(col_value);
    endfunction

    task automatic check_true(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1)
                $fatal(1, "M4 tail/sentinel check failed: %s", message);
        end
    endtask

    initial begin
        if ((ARRAY_ROWS != 4) && (ARRAY_ROWS != 8))
            $fatal(1, "M4 tail test supports only ARRAY_ROWS=4 or 8");

        active_m = 32'd100 + 32'(VALID_ROWS);
        active_k = 32'd3073;
        active_n = 32'd1001;
        token_base = 32'd100;
        k_base = 32'd3072;
        output_base = 32'd1000;

        activation_data = '0;
        weight_data = '0;
        bias_data = '0;
        gemm_result_data = '0;
        cmd = '0;
        cmd.header.opcode = PHASE_E_OP_GEMM;
        cmd.route.dst_space = PHASE_E_MEM_SCRATCH;
        cmd.immediate = RESULT_STRIDE;
        gemm_result_address_base = {34'd0, RESULT_BASE};
        word_index = 16'd0;

        for (address_index = 0; address_index < MEMORY_WORDS;
             address_index = address_index + 1)
            output_memory[address_index] = SENTINEL;

        for (row_index = 0; row_index < ARRAY_ROWS;
             row_index = row_index + 1) begin
            for (lane_index = 0; lane_index < PE_LANES;
                 lane_index = lane_index + 1)
                activation_data[
                    (row_index*PE_LANES+lane_index)*32 +: 32
                ] = activation_pattern(row_index, lane_index);

            for (col_index = 0; col_index < ARRAY_COLS;
                 col_index = col_index + 1) begin
                flat_index = row_index * ARRAY_COLS + col_index;
                gemm_result_data[flat_index*32 +: 32] =
                    result_pattern(row_index, col_index);
            end
        end

        for (col_index = 0; col_index < ARRAY_COLS;
             col_index = col_index + 1) begin
            bias_data[col_index*32 +: 32] =
                32'hd000_0000 ^ 32'(col_index);
            for (lane_index = 0; lane_index < PE_LANES;
                 lane_index = lane_index + 1)
                weight_data[(col_index*PE_LANES+lane_index)*32 +: 32] =
                    weight_pattern(col_index, lane_index);
        end

        #1;

        // M tail: all but the last row are valid. K tail: only lane zero is
        // valid. N tail: only column zero is valid.
        for (row_index = 0; row_index < ARRAY_ROWS;
             row_index = row_index + 1)
            check_true(
                token_valid[row_index] === (row_index < VALID_ROWS),
                $sformatf("token mask row=%0d", row_index)
            );
        for (lane_index = 0; lane_index < PE_LANES;
             lane_index = lane_index + 1)
            check_true(
                lane_valid[lane_index] === (lane_index == 0),
                $sformatf("K-tail lane mask lane=%0d", lane_index)
            );
        check_true(output_valid[0], "first output column should be valid");
        check_true(!output_valid[1], "padded output column should be invalid");

        // Invalid M rows and N columns are explicitly zeroed at the operand
        // boundary. K lanes use lane_valid (the PE suppresses invalid lanes).
        for (row_index = 0; row_index < ARRAY_ROWS;
             row_index = row_index + 1)
            for (lane_index = 0; lane_index < PE_LANES;
                 lane_index = lane_index + 1)
                if (row_index < VALID_ROWS)
                    check_true(
                        routed_activation_data[
                            (row_index*PE_LANES+lane_index)*32 +: 32
                        ] === activation_pattern(row_index, lane_index),
                        $sformatf(
                            "valid activation row=%0d lane=%0d",
                            row_index,
                            lane_index
                        )
                    );
                else
                    check_true(
                        routed_activation_data[
                            (row_index*PE_LANES+lane_index)*32 +: 32
                        ] === 32'd0,
                        $sformatf(
                            "padded activation row=%0d lane=%0d",
                            row_index,
                            lane_index
                        )
                    );

        for (lane_index = 0; lane_index < PE_LANES;
             lane_index = lane_index + 1) begin
            check_true(
                routed_weight_data[lane_index*32 +: 32] ===
                    weight_pattern(0, lane_index),
                $sformatf("valid weight lane=%0d", lane_index)
            );
            check_true(
                routed_weight_data[(PE_LANES+lane_index)*32 +: 32] === 32'd0,
                $sformatf("padded weight lane=%0d", lane_index)
            );
        end
        check_true(
            routed_bias_data[31:0] === bias_data[31:0],
            "valid bias column changed"
        );
        check_true(
            routed_bias_data[63:32] === 32'd0,
            "padded bias column was not zero"
        );

        // Scatter only valid row/column intersections into the sentinel RAM.
        for (flat_index = 0; flat_index < RESULT_WORDS;
             flat_index = flat_index + 1) begin
            word_index = 16'(flat_index);
            #1;
            row_index = flat_index / ARRAY_COLS;
            col_index = flat_index % ARRAY_COLS;
            check_true(
                candidate_needed ===
                    ((row_index < VALID_ROWS) && (col_index == 0)),
                $sformatf(
                    "write mask row=%0d col=%0d",
                    row_index,
                    col_index
                )
            );
            check_true(!candidate_address_overflow, "unexpected write overflow");
            check_true(
                candidate_space == PHASE_E_MEM_SCRATCH,
                "write space changed"
            );
            check_true(
                candidate_address ==
                    (RESULT_BASE + 32'(row_index) * RESULT_STRIDE +
                     32'(col_index)),
                $sformatf(
                    "write address row=%0d col=%0d got=%0d",
                    row_index,
                    col_index,
                    candidate_address
                )
            );
            check_true(
                candidate_data === result_pattern(row_index, col_index),
                $sformatf("write data row=%0d col=%0d", row_index, col_index)
            );

            if (candidate_needed) begin
                output_memory[candidate_address] = candidate_data;
                write_count = write_count + 1;
            end
        end

        check_true(
            write_count == VALID_ROWS,
            $sformatf("valid write count got=%0d expected=%0d", write_count, VALID_ROWS)
        );

        for (row_index = 0; row_index < ARRAY_ROWS;
             row_index = row_index + 1)
            for (col_index = 0; col_index < ARRAY_COLS;
                 col_index = col_index + 1) begin
                address_index =
                    RESULT_BASE + row_index * RESULT_STRIDE + col_index;
                if ((row_index < VALID_ROWS) && (col_index == 0))
                    check_true(
                        output_memory[address_index] ===
                            result_pattern(row_index, col_index),
                        $sformatf(
                            "valid output row=%0d col=%0d",
                            row_index,
                            col_index
                        )
                    );
                else
                    check_true(
                        output_memory[address_index] === SENTINEL,
                        $sformatf(
                            "padding sentinel row=%0d col=%0d",
                            row_index,
                            col_index
                        )
                    );
            end

        $display(
            {
                "PASS M4 tail/output sentinel: R=%0d checks=%0d ",
                "valid_rows=%0d valid_writes=%0d"
            },
            ARRAY_ROWS,
            checks,
            VALID_ROWS,
            write_count
        );
        $finish;
    end

endmodule
