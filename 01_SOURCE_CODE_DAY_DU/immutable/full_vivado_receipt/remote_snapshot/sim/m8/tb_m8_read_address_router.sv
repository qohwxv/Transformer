`timescale 1ns/1ps

// Focused M8 read-ahead contract regression.
//
// The same testbench is compiled once against the exact M7-S8 parent router
// and once against the M8 candidate.  BASE_TRACE deliberately omits the two
// hint outputs, so the runner can prove that candidate_needed, space, address
// and overflow are bit-for-bit identical.  LEGACY_TRACE includes every
// output for opcodes whose M8 behavior must remain completely unchanged.
module tb_m8_read_address_router;

    import vit_phase_e_pkg::*;

    localparam integer ARRAY_ROWS = 8;
    localparam integer ARRAY_COLS = 2;
    localparam integer PE_LANES = 16;
    localparam integer VECTOR_LANES = 16;

    phase_e_cmd_t active_cmd;
    logic [15:0] word_index;
    logic [31:0] gemm_token_base;
    logic [31:0] gemm_output_base;
    logic [31:0] gemm_k_base;
    logic [65:0] gemm_activation_address_base;
    logic [65:0] gemm_weight_address_base;
    logic [65:0] gemm_bias_address_base;
    logic [31:0] vector_element_base;
    logic [31:0] layout_source_address;
    logic [1:0] ln_data_pass;
    logic [31:0] ln_data_index;
    logic [31:0] ln_data_channel_index;
    logic [31:0] softmax_data_index;
    logic [31:0] gelu_data_base_index;
    logic [VECTOR_LANES-1:0] gelu_data_lane_mask;
    logic [31:0] argmax_element_index;

    logic candidate_needed;
    phase_e_mem_space_t candidate_space;
    logic [31:0] candidate_address;
    logic candidate_address_overflow;
    logic candidate_read_ahead_safe;
    logic [5:0] candidate_contiguous_words;

    integer checks = 0;
    integer failures = 0;
    integer trace_index = 0;
    integer tail;
    integer lane;
    integer base_mod;
    integer run_count;
    integer expected_count;
    integer random_case;
    logic [31:0] lfsr;
    logic [15:0] mask_value;

    vit_phase_e_read_address_router #(
        .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .PE_LANES(PE_LANES),
        .VECTOR_LANES(VECTOR_LANES)
    ) u_dut (
        .active_cmd(active_cmd),
        .word_index(word_index),
        .gemm_token_base(gemm_token_base),
        .gemm_output_base(gemm_output_base),
        .gemm_k_base(gemm_k_base),
        .gemm_activation_address_base(gemm_activation_address_base),
        .gemm_weight_address_base(gemm_weight_address_base),
        .gemm_bias_address_base(gemm_bias_address_base),
        .vector_element_base(vector_element_base),
        .layout_source_address(layout_source_address),
        .ln_data_pass(ln_data_pass),
        .ln_data_index(ln_data_index),
        .ln_data_channel_index(ln_data_channel_index),
        .softmax_data_index(softmax_data_index),
        .gelu_data_base_index(gelu_data_base_index),
        .gelu_data_lane_mask(gelu_data_lane_mask),
        .argmax_element_index(argmax_element_index),
        .candidate_needed(candidate_needed),
        .candidate_space(candidate_space),
        .candidate_address(candidate_address),
        .candidate_address_overflow(candidate_address_overflow),
        .candidate_read_ahead_safe(candidate_read_ahead_safe),
        .candidate_contiguous_words(candidate_contiguous_words)
    );

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $error("CHECK FAILED: %s", message);
            end
        end
    endtask

    task automatic clear_inputs;
        begin
            active_cmd = '0;
            word_index = 16'd0;
            gemm_token_base = 32'd0;
            gemm_output_base = 32'd0;
            gemm_k_base = 32'd0;
            gemm_activation_address_base = 66'd0;
            gemm_weight_address_base = 66'd0;
            gemm_bias_address_base = 66'd0;
            vector_element_base = 32'd0;
            layout_source_address = 32'd0;
            ln_data_pass = 2'd0;
            ln_data_index = 32'd0;
            ln_data_channel_index = 32'd0;
            softmax_data_index = 32'd0;
            gelu_data_base_index = 32'd0;
            gelu_data_lane_mask = '0;
            argmax_element_index = 32'd0;
        end
    endtask

    task automatic emit_base_trace(input integer kind);
        begin
            #1;
            $display(
                "BASE_TRACE %0d %0d %0d %0d %08x %0d",
                trace_index,
                kind,
                candidate_needed,
                candidate_space,
                candidate_address,
                candidate_address_overflow
            );
            trace_index = trace_index + 1;
        end
    endtask

    task automatic emit_legacy_trace(input integer kind);
        begin
            #1;
            $display(
                "LEGACY_TRACE %0d %0d %0d %0d %08x %0d %0d %0d",
                trace_index,
                kind,
                candidate_needed,
                candidate_space,
                candidate_address,
                candidate_address_overflow,
                candidate_read_ahead_safe,
                candidate_contiguous_words
            );
            trace_index = trace_index + 1;
        end
    endtask

    task automatic check_hint(
        input logic expected_needed,
        input integer expected_words,
        input string message
    );
        begin
            check(candidate_needed == expected_needed,
                  {message, " needed"});
`ifdef M8_CANDIDATE_ROUTER
            check(candidate_read_ahead_safe == expected_needed,
                  {message, " candidate safe"});
            check(candidate_contiguous_words ==
                  (expected_needed ? 6'(expected_words) : 6'd1),
                  {message, " candidate count"});
`else
            check(!candidate_read_ahead_safe,
                  {message, " parent safe remains zero"});
            check(candidate_contiguous_words == 6'd1,
                  {message, " parent count remains one"});
`endif
        end
    endtask

    task automatic vector_case(
        input integer length,
        input integer address_mod,
        input phase_e_subop_t subop,
        input logic mask_enable
    );
        integer local_lane;
        integer local_expected;
        begin
            clear_inputs();
            active_cmd.header.opcode = PHASE_E_OP_VECTOR;
            active_cmd.header.subop = subop;
            active_cmd.header.flags = mask_enable ?
                PHASE_E_FLAG_MASK_ENABLE : 8'd0;
            active_cmd.route.src0_space = PHASE_E_MEM_INPUT;
            active_cmd.route.src1_space = PHASE_E_MEM_PARAM;
            active_cmd.src0_base = 32'h0000_0100 + address_mod;
            active_cmd.src1_base = 32'h0000_2000 + address_mod;
            vector_element_base = 32'd37;
            active_cmd.dim0 = vector_element_base + length;

            for (local_lane = 0; local_lane < VECTOR_LANES;
                 local_lane = local_lane + 1) begin
                word_index = 16'(local_lane);
                #1;
                local_expected = length - local_lane;
                if (local_expected > (VECTOR_LANES - local_lane))
                    local_expected = VECTOR_LANES - local_lane;
                if (local_expected < 0)
                    local_expected = 0;
                check_hint(local_lane < length, local_expected,
                           "Vector A tail/read-ahead");
                check(candidate_space == PHASE_E_MEM_INPUT,
                      "Vector A space");
                check(candidate_address ==
                      (32'h0000_0100 + address_mod + 37 + local_lane),
                      "Vector A address");
                check(!candidate_address_overflow,
                      "Vector A address overflow");
                emit_base_trace(1);

                word_index = 16'(VECTOR_LANES + local_lane);
                #1;
                if ((subop == PHASE_E_SUBOP_VECTOR_ADD) || mask_enable) begin
                    check_hint(local_lane < length, local_expected,
                               "Vector B tail/read-ahead");
                end else begin
                    check(!candidate_needed,
                          "mask-disabled Vector B is skipped");
                    check(!candidate_read_ahead_safe,
                          "mask-disabled Vector B cannot prefetch");
                    check(candidate_contiguous_words == 6'd1,
                          "mask-disabled Vector B count is one");
                end
                check(candidate_space == PHASE_E_MEM_PARAM,
                      "Vector B space metadata");
                check(candidate_address ==
                      (32'h0000_2000 + address_mod + 37 + local_lane),
                      "Vector B address");
                check(!candidate_address_overflow,
                      "Vector B address overflow");
                emit_base_trace(2);
            end
        end
    endtask

    task automatic gelu_mask_case(input logic [15:0] test_mask);
        integer local_lane;
        integer scan_lane;
        integer local_count;
        logic still_contiguous;
        begin
            clear_inputs();
            active_cmd.header.opcode = PHASE_E_OP_GELU;
            active_cmd.route.src0_space = PHASE_E_MEM_SCRATCH;
            active_cmd.src0_base = 32'h0000_3003;
            gelu_data_base_index = 32'd91;
            gelu_data_lane_mask = test_mask;
            for (local_lane = 0; local_lane < VECTOR_LANES;
                 local_lane = local_lane + 1) begin
                word_index = 16'(local_lane);
                #1;
                local_count = 0;
                still_contiguous = 1'b1;
                for (scan_lane = local_lane; scan_lane < VECTOR_LANES;
                     scan_lane = scan_lane + 1) begin
                    if (still_contiguous && test_mask[scan_lane])
                        local_count = local_count + 1;
                    else
                        still_contiguous = 1'b0;
                end
                check_hint(test_mask[local_lane], local_count,
                           "GELU mask/read-ahead");
                check(candidate_space == PHASE_E_MEM_SCRATCH,
                      "GELU space");
                check(candidate_address ==
                      (32'h0000_3003 + 91 + local_lane),
                      "GELU address");
                check(!candidate_address_overflow,
                      "GELU address overflow");
                emit_base_trace(3);
            end
        end
    endtask

    initial begin
        clear_inputs();

        // Every tail and every word-alignment residue.  ADD covers independent
        // A/B spaces; SCALE_MASK covers enabled B and the disabled-B skip.
        for (tail = 1; tail <= VECTOR_LANES; tail = tail + 1)
            for (base_mod = 0; base_mod < 4; base_mod = base_mod + 1) begin
                vector_case(tail, base_mod,
                            PHASE_E_SUBOP_VECTOR_ADD, 1'b0);
                vector_case(tail, base_mod,
                            PHASE_E_SUBOP_VECTOR_SCALE_MASK, 1'b1);
                vector_case(tail, base_mod,
                            PHASE_E_SUBOP_VECTOR_SCALE_MASK, 1'b0);
            end

        // GELU production low-prefix tails plus malformed sparse masks.  The
        // candidate may advertise only the consecutive asserted run starting
        // at the current lane.
        for (tail = 1; tail <= VECTOR_LANES; tail = tail + 1) begin
            if (tail == VECTOR_LANES)
                mask_value = 16'hffff;
            else
                mask_value = (16'h0001 << tail) - 1'b1;
            gelu_mask_case(mask_value);
        end
        gelu_mask_case(16'b1111_0000_1111_0111);
        gelu_mask_case(16'b0101_0101_1010_1010);
        gelu_mask_case(16'b1000_0000_0000_0001);
        gelu_mask_case(16'b0000_0000_0000_0000);

        // Address overflow must suppress read-ahead exactly as it did for M7.
        clear_inputs();
        active_cmd.header.opcode = PHASE_E_OP_VECTOR;
        active_cmd.header.subop = PHASE_E_SUBOP_VECTOR_ADD;
        active_cmd.route.src0_space = PHASE_E_MEM_SCRATCH;
        active_cmd.src0_base = 32'hffff_ffff;
        active_cmd.dim0 = 32'hffff_ffff;
        vector_element_base = 32'hffff_fffe;
        word_index = 16'd0;
        #1;
        check(candidate_address_overflow,
              "Vector overflow is detected before truncation");
        check(!candidate_read_ahead_safe,
              "overflow suppresses Vector read-ahead");
        check(candidate_contiguous_words == 6'd1,
              "overflow restores conservative count");
        emit_base_trace(4);

        clear_inputs();
        active_cmd.header.opcode = PHASE_E_OP_GELU;
        active_cmd.route.src0_space = PHASE_E_MEM_SCRATCH;
        active_cmd.src0_base = 32'hffff_ffff;
        gelu_data_base_index = 32'd1;
        gelu_data_lane_mask = 16'hffff;
        word_index = 16'd0;
        #1;
        check(candidate_address_overflow,
              "GELU overflow is detected before truncation");
        check(!candidate_read_ahead_safe,
              "overflow suppresses GELU read-ahead");
        check(candidate_contiguous_words == 6'd1,
              "GELU overflow restores conservative count");
        emit_base_trace(5);

        // Randomized legacy-opcode stimulus.  The runner compares complete
        // LEGACY_TRACE lines against the exact parent source, including the
        // original blocked/packed GEMM hints.
        lfsr = 32'h8f31_7a5d;
        for (random_case = 0; random_case < 512;
             random_case = random_case + 1) begin
            clear_inputs();
            lfsr = {lfsr[30:0],
                    lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            case (random_case % 7)
                0: active_cmd.header.opcode = PHASE_E_OP_GEMM;
                1: active_cmd.header.opcode = PHASE_E_OP_LAYOUT;
                2: active_cmd.header.opcode = PHASE_E_OP_LAYERNORM;
                3: active_cmd.header.opcode = PHASE_E_OP_SOFTMAX;
                4: active_cmd.header.opcode = PHASE_E_OP_ARGMAX;
                5: active_cmd.header.opcode = PHASE_E_OP_NOP;
                default: active_cmd.header.opcode = PHASE_E_OP_END;
            endcase
            active_cmd.header.flags = lfsr[7:0];
            active_cmd.route.src0_space = phase_e_mem_space_t'(lfsr[1:0]);
            active_cmd.route.src1_space = phase_e_mem_space_t'(lfsr[3:2]);
            active_cmd.route.src2_space = phase_e_mem_space_t'(lfsr[5:4]);
            active_cmd.src0_base = lfsr;
            active_cmd.src1_base = {lfsr[15:0], lfsr[31:16]};
            active_cmd.src2_base = ~lfsr;
            active_cmd.dim0 = {1'b0, lfsr[30:0]};
            active_cmd.dim1 = {16'd0, lfsr[15:0]};
            active_cmd.dim2 = {16'd0, lfsr[31:16]};
            active_cmd.dim3 = {16'd0, lfsr[23:8]};
            active_cmd.stride1 = {24'd0, lfsr[7:0]};
            active_cmd.stride3 = {24'd0, lfsr[15:8]};
            word_index = lfsr[15:0] % 16'd160;
            gemm_token_base = {24'd0, lfsr[7:0]};
            gemm_output_base = {24'd0, lfsr[15:8]};
            gemm_k_base = {24'd0, lfsr[23:16]};
            gemm_activation_address_base = {34'd0, lfsr};
            gemm_weight_address_base = {34'd0, ~lfsr};
            gemm_bias_address_base = {34'd0,
                {lfsr[15:0], lfsr[31:16]}};
            layout_source_address = lfsr;
            ln_data_pass = lfsr[1:0];
            ln_data_index = lfsr;
            ln_data_channel_index = {lfsr[7:0], lfsr[31:8]};
            softmax_data_index = ~lfsr;
            argmax_element_index = {lfsr[15:0], lfsr[31:16]};
            emit_legacy_trace(6 + (random_case % 7));
        end

        if (failures == 0) begin
`ifdef M8_CANDIDATE_ROUTER
            $display("M8_ROUTER_PASS implementation=M8 checks=%0d traces=%0d",
                     checks, trace_index);
`else
            $display("M8_ROUTER_PASS implementation=M7_PARENT checks=%0d traces=%0d",
                     checks, trace_index);
`endif
            $finish;
        end

        $fatal(1, "M8_ROUTER_FAIL failures=%0d checks=%0d",
               failures, checks);
    end

endmodule
