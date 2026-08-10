`timescale 1ns/1ps

// Production-RTL end-to-end integration smoke test for the complete E04 final
// phase:
//
//   job -> sequencer -> command controller -> compute blocks
//       -> logical-memory model -> class result / done
//
// No VIT_PURE_SV_BEHAVIORAL define is used. The test therefore exercises
// vit_phase_e_engine_top, including the production LayerNorm, Layout, GEMM,
// Argmax, Softmax, memory frontend, address routers, and GEMM caches.
//
// To keep the golden result exact and file-independent:
//   - HIDDEN_A is all +0;
//   - final LayerNorm gamma=1 and beta=0, so HIDDEN_B remains +0;
//   - classifier weights are +0;
//   - classifier bias is +7 only at TARGET_CLASS, otherwise +0.
//
// The expected class is consequently TARGET_CLASS with logit +7.0.
module tb_vit_phase_e_npu_e04_rtl;

    import vit_phase_e_pkg::*;

    localparam integer ARRAY_ROWS = 2;
    localparam integer ARRAY_COLS = 2;
    localparam integer PE_LANES = 16;
    localparam integer VECTOR_LANES = 16;

    // Compact E04 dimensions keep this production-hierarchy smoke test fast.
    // The DUT defaults remain the full ViT-base 197 x 768 x 1000 dimensions.
    localparam logic [31:0] E04_TOKEN_COUNT = 32'd3;
    localparam logic [31:0] E04_HIDDEN_SIZE = 32'd16;
    localparam logic [31:0] E04_CLASS_COUNT = 32'd7;
    localparam integer E04_HIDDEN_WORDS =
        E04_TOKEN_COUNT * E04_HIDDEN_SIZE;

    localparam logic [31:0] FINAL_LN_GAMMA_BASE = 32'd0;
    localparam logic [31:0] FINAL_LN_BETA_BASE = 32'd1024;
    localparam logic [31:0] CLASSIFIER_WEIGHT_BASE = 32'd2048;
    localparam logic [31:0] CLASSIFIER_WEIGHT_WORDS =
        E04_HIDDEN_SIZE * E04_CLASS_COUNT;
    localparam logic [31:0] CLASSIFIER_BIAS_BASE =
        CLASSIFIER_WEIGHT_BASE + CLASSIFIER_WEIGHT_WORDS;
    localparam integer PARAM_WORDS =
        CLASSIFIER_BIAS_BASE + E04_CLASS_COUNT + 32;

    localparam integer TARGET_CLASS = 3;
    localparam logic [31:0] FP32_POS_ZERO = 32'h0000_0000;
    localparam logic [31:0] FP32_ONE = 32'h3f80_0000;
    localparam logic [31:0] FP32_SEVEN = 32'h40e0_0000;
    localparam logic [31:0] FP32_QNAN = 32'h7fc0_0000;
    localparam logic [31:0] FP32_SENTINEL = 32'hdead_beef;

    localparam integer EXPECTED_COMMANDS = 5;
    localparam integer EXPECTED_HIDDEN_WRITES = E04_HIDDEN_WORDS;
    localparam integer EXPECTED_LINEAR_WRITES = E04_HIDDEN_SIZE;
    localparam integer EXPECTED_LOGIT_WRITES = E04_CLASS_COUNT;
    localparam integer EXPECTED_PROB_WRITES = E04_CLASS_COUNT;
    localparam integer EXPECTED_WRITES =
        EXPECTED_HIDDEN_WRITES +
        EXPECTED_LINEAR_WRITES +
        EXPECTED_LOGIT_WRITES +
        EXPECTED_PROB_WRITES;
    localparam integer WATCHDOG_CYCLES = 1_000_000;

    logic clk = 1'b0;
    logic rst = 1'b1;

    logic job_valid = 1'b0;
    logic job_ready;
    phase_e_job_t job = '0;
    phase_e_global_params_t global_params = '0;

    logic layer_param_request;
    logic [3:0] layer_param_index;
    logic layer_param_valid = 1'b0;
    phase_e_layer_params_t layer_param_data = '0;

    logic operand_load_request;
    logic operand_load_ready = 1'b1;
    phase_e_cmd_t operand_load_command;

    logic checkpoint_valid;
    logic checkpoint_ready = 1'b1;
    phase_e_phase_t checkpoint_phase;
    phase_e_section_t checkpoint_section;
    logic [3:0] checkpoint_layer;
    logic [4:0] checkpoint_step;
    logic [7:0] checkpoint_tag;
    phase_e_opcode_t checkpoint_opcode;
    phase_e_tensor_id_t checkpoint_dst_tensor;

    logic busy;
    logic done;
    logic error;
    phase_e_error_t error_code;
    phase_e_section_t error_section;
    logic [3:0] error_layer;
    logic [4:0] error_step;

    logic mem_req_valid;
    logic mem_req_ready;
    logic mem_req_write;
    phase_e_mem_space_t mem_req_space;
    logic [31:0] mem_req_word_address;
    logic [31:0] mem_req_write_data;
    logic [3:0] mem_req_write_strobe;
    logic mem_rsp_valid = 1'b0;
    logic mem_rsp_ready;
    logic [31:0] mem_rsp_read_data = FP32_POS_ZERO;
    logic mem_rsp_error = 1'b0;

    logic class_result_valid;
    logic [31:0] class_index;
    logic [31:0] class_logit;

    // Compact storage for only the E04 scratch regions that are touched.
    // HIDDEN_A is modeled algorithmically as an all-zero, read-only region.
    logic [31:0] hidden_b_memory [0:E04_HIDDEN_WORDS-1];
    logic [31:0] linear_memory [0:E04_HIDDEN_SIZE-1];
    logic [31:0] logits_memory [0:E04_CLASS_COUNT-1];
    logic [31:0] probability_memory [0:E04_CLASS_COUNT-1];
    integer hidden_write_hits [0:E04_HIDDEN_WORDS-1];
    integer linear_write_hits [0:E04_HIDDEN_SIZE-1];
    integer logit_write_hits [0:E04_CLASS_COUNT-1];
    integer probability_write_hits [0:E04_CLASS_COUNT-1];

    logic pending_write = 1'b0;
    phase_e_mem_space_t pending_space = PHASE_E_MEM_NONE;
    logic [31:0] pending_address = 32'd0;
    logic [31:0] pending_write_data = 32'd0;
    logic [3:0] pending_write_strobe = 4'd0;

    longint cycle_count = 0;
    integer checks = 0;
    integer failures = 0;
    integer command_count = 0;
    integer checkpoint_count = 0;
    integer parameter_request_count = 0;
    integer layer_request_count = 0;
    integer class_result_count = 0;
    integer read_transaction_count = 0;
    integer write_transaction_count = 0;
    integer invalid_transaction_count = 0;
    integer hidden_write_count = 0;
    integer linear_write_count = 0;
    integer logit_write_count = 0;
    integer probability_write_count = 0;
    logic [31:0] captured_class_index = 32'd0;
    logic [31:0] captured_class_logit = FP32_QNAN;

    integer initialize_index;
    integer verify_index;

    always #5 clk = ~clk;

    function automatic logic address_in_range(
        input logic [31:0] address,
        input logic [31:0] base,
        input logic [31:0] word_count
    );
        logic [32:0] limit;
        begin
            limit = {1'b0, base} + {1'b0, word_count};
            address_in_range =
                ({1'b0, address} >= {1'b0, base}) &&
                ({1'b0, address} < limit);
        end
    endfunction

    function automatic logic [31:0] merge_strobe(
        input logic [31:0] original,
        input logic [31:0] replacement,
        input logic [3:0] strobe
    );
        logic [31:0] merged;
        begin
            merged = original;
            if (strobe[0])
                merged[7:0] = replacement[7:0];
            if (strobe[1])
                merged[15:8] = replacement[15:8];
            if (strobe[2])
                merged[23:16] = replacement[23:16];
            if (strobe[3])
                merged[31:24] = replacement[31:24];
            merge_strobe = merged;
        end
    endfunction

    function automatic logic logical_address_valid(
        input logic write_request,
        input phase_e_mem_space_t space,
        input logic [31:0] address
    );
        logic scratch_valid;
        logic parameter_valid;
        begin
            scratch_valid =
                address_in_range(
                    address,
                    PHASE_E_ADDR_HIDDEN_A,
                    E04_HIDDEN_WORDS
                ) ||
                address_in_range(
                    address,
                    PHASE_E_ADDR_HIDDEN_B,
                    E04_HIDDEN_WORDS
                ) ||
                address_in_range(
                    address,
                    PHASE_E_ADDR_LINEAR_TMP,
                    E04_HIDDEN_SIZE
                ) ||
                address_in_range(
                    address,
                    PHASE_E_ADDR_LOGITS,
                    E04_CLASS_COUNT
                ) ||
                address_in_range(
                    address,
                    PHASE_E_ADDR_CLASS_PROB,
                    E04_CLASS_COUNT
                );

            parameter_valid =
                address_in_range(
                    address,
                    FINAL_LN_GAMMA_BASE,
                    E04_HIDDEN_SIZE
                ) ||
                address_in_range(
                    address,
                    FINAL_LN_BETA_BASE,
                    E04_HIDDEN_SIZE
                ) ||
                address_in_range(
                    address,
                    CLASSIFIER_WEIGHT_BASE,
                    CLASSIFIER_WEIGHT_WORDS
                ) ||
                address_in_range(
                    address,
                    CLASSIFIER_BIAS_BASE,
                    E04_CLASS_COUNT
                );

            if (write_request)
                logical_address_valid =
                    (space == PHASE_E_MEM_SCRATCH) &&
                    scratch_valid;
            else begin
                case (space)
                    PHASE_E_MEM_SCRATCH:
                        logical_address_valid = scratch_valid;
                    PHASE_E_MEM_PARAM:
                        logical_address_valid = parameter_valid;
                    default:
                        logical_address_valid = 1'b0;
                endcase
            end
        end
    endfunction

    function automatic logic [31:0] read_logical_word(
        input phase_e_mem_space_t space,
        input logic [31:0] address
    );
        integer word_index;
        begin
            read_logical_word = FP32_QNAN;
            case (space)
                PHASE_E_MEM_SCRATCH: begin
                    if (address_in_range(
                        address,
                        PHASE_E_ADDR_HIDDEN_A,
                        E04_HIDDEN_WORDS
                    )) begin
                        read_logical_word = FP32_POS_ZERO;
                    end else if (address_in_range(
                        address,
                        PHASE_E_ADDR_HIDDEN_B,
                        E04_HIDDEN_WORDS
                    )) begin
                        word_index = address - PHASE_E_ADDR_HIDDEN_B;
                        read_logical_word = hidden_b_memory[word_index];
                    end else if (address_in_range(
                        address,
                        PHASE_E_ADDR_LINEAR_TMP,
                        E04_HIDDEN_SIZE
                    )) begin
                        word_index = address - PHASE_E_ADDR_LINEAR_TMP;
                        read_logical_word = linear_memory[word_index];
                    end else if (address_in_range(
                        address,
                        PHASE_E_ADDR_LOGITS,
                        E04_CLASS_COUNT
                    )) begin
                        word_index = address - PHASE_E_ADDR_LOGITS;
                        read_logical_word = logits_memory[word_index];
                    end else if (address_in_range(
                        address,
                        PHASE_E_ADDR_CLASS_PROB,
                        E04_CLASS_COUNT
                    )) begin
                        word_index = address - PHASE_E_ADDR_CLASS_PROB;
                        read_logical_word =
                            probability_memory[word_index];
                    end
                end

                PHASE_E_MEM_PARAM: begin
                    if (address_in_range(
                        address,
                        FINAL_LN_GAMMA_BASE,
                        E04_HIDDEN_SIZE
                    )) begin
                        read_logical_word = FP32_ONE;
                    end else if (address_in_range(
                        address,
                        FINAL_LN_BETA_BASE,
                        E04_HIDDEN_SIZE
                    )) begin
                        read_logical_word = FP32_POS_ZERO;
                    end else if (address_in_range(
                        address,
                        CLASSIFIER_WEIGHT_BASE,
                        CLASSIFIER_WEIGHT_WORDS
                    )) begin
                        read_logical_word = FP32_POS_ZERO;
                    end else if (address_in_range(
                        address,
                        CLASSIFIER_BIAS_BASE,
                        E04_CLASS_COUNT
                    )) begin
                        word_index = address - CLASSIFIER_BIAS_BASE;
                        read_logical_word =
                            (word_index == TARGET_CLASS)
                                ? FP32_SEVEN
                                : FP32_POS_ZERO;
                    end
                end

                default:
                    read_logical_word = FP32_QNAN;
            endcase
        end
    endfunction

    task automatic write_scratch_word(
        input logic [31:0] address,
        input logic [31:0] data,
        input logic [3:0] strobe
    );
        integer word_index;
        begin
            if (address_in_range(
                address,
                PHASE_E_ADDR_HIDDEN_B,
                E04_HIDDEN_WORDS
            )) begin
                word_index = address - PHASE_E_ADDR_HIDDEN_B;
                hidden_b_memory[word_index] = merge_strobe(
                    hidden_b_memory[word_index],
                    data,
                    strobe
                );
                hidden_write_count = hidden_write_count + 1;
                hidden_write_hits[word_index] =
                    hidden_write_hits[word_index] + 1;
            end else if (address_in_range(
                address,
                PHASE_E_ADDR_LINEAR_TMP,
                E04_HIDDEN_SIZE
            )) begin
                word_index = address - PHASE_E_ADDR_LINEAR_TMP;
                linear_memory[word_index] = merge_strobe(
                    linear_memory[word_index],
                    data,
                    strobe
                );
                linear_write_count = linear_write_count + 1;
                linear_write_hits[word_index] =
                    linear_write_hits[word_index] + 1;
            end else if (address_in_range(
                address,
                PHASE_E_ADDR_LOGITS,
                E04_CLASS_COUNT
            )) begin
                word_index = address - PHASE_E_ADDR_LOGITS;
                logits_memory[word_index] = merge_strobe(
                    logits_memory[word_index],
                    data,
                    strobe
                );
                logit_write_count = logit_write_count + 1;
                logit_write_hits[word_index] =
                    logit_write_hits[word_index] + 1;
            end else if (address_in_range(
                address,
                PHASE_E_ADDR_CLASS_PROB,
                E04_CLASS_COUNT
            )) begin
                word_index = address - PHASE_E_ADDR_CLASS_PROB;
                probability_memory[word_index] = merge_strobe(
                    probability_memory[word_index],
                    data,
                    strobe
                );
                probability_write_count =
                    probability_write_count + 1;
                probability_write_hits[word_index] =
                    probability_write_hits[word_index] + 1;
            end else begin
                invalid_transaction_count <=
                    invalid_transaction_count + 1;
                $error(
                    "Unexpected scratch write address %08x",
                    address
                );
            end
        end
    endtask

    task automatic check(
        input logic condition,
        input string message
    );
        begin
            checks = checks + 1;
            // Case inequality makes an X/Z result fail instead of silently
            // passing through Verilog's procedural-if semantics.
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $error(
                    "E04 RTL E2E CHECK FAILED cycle=%0d: %s",
                    cycle_count,
                    message
                );
            end
        end
    endtask

    assign mem_req_ready = !mem_rsp_valid;

    vit_phase_e_npu #(
        .ARRAY_ROWS   (ARRAY_ROWS),
        .ARRAY_COLS   (ARRAY_COLS),
        .PE_LANES     (PE_LANES),
        .VECTOR_LANES (VECTOR_LANES),
        .SCRATCH_WORDS(PHASE_E_SCRATCH_WORDS),
        .INPUT_WORDS  (1),
        .PARAM_WORDS  (PARAM_WORDS),
        .E04_TOKEN_COUNT(E04_TOKEN_COUNT),
        .E04_HIDDEN_SIZE(E04_HIDDEN_SIZE),
        .E04_CLASS_COUNT(E04_CLASS_COUNT)
    ) dut (
        .clk                    (clk),
        .rst                    (rst),
        .job_valid              (job_valid),
        .job_ready              (job_ready),
        .job                    (job),
        .global_params          (global_params),
        .layer_param_request    (layer_param_request),
        .layer_param_index      (layer_param_index),
        .layer_param_valid      (layer_param_valid),
        .layer_param_data       (layer_param_data),
        .operand_load_request   (operand_load_request),
        .operand_load_ready     (operand_load_ready),
        .operand_load_command   (operand_load_command),
        .checkpoint_valid       (checkpoint_valid),
        .checkpoint_ready       (checkpoint_ready),
        .checkpoint_phase       (checkpoint_phase),
        .checkpoint_section     (checkpoint_section),
        .checkpoint_layer       (checkpoint_layer),
        .checkpoint_step        (checkpoint_step),
        .checkpoint_tag         (checkpoint_tag),
        .checkpoint_opcode      (checkpoint_opcode),
        .checkpoint_dst_tensor  (checkpoint_dst_tensor),
        .busy                   (busy),
        .done                   (done),
        .error                  (error),
        .error_code             (error_code),
        .error_section          (error_section),
        .error_layer            (error_layer),
        .error_step             (error_step),
        .input_write_enable     (1'b0),
        .input_write_address    (32'd0),
        .input_write_data       (32'd0),
        .parameter_write_enable (1'b0),
        .parameter_write_address(32'd0),
        .parameter_write_data   (32'd0),
        .scratch_write_enable   (1'b0),
        .scratch_write_address  (32'd0),
        .scratch_write_data     (32'd0),
        .scratch_read_address   (32'd0),
        .scratch_read_data      (),
        .mem_req_valid          (mem_req_valid),
        .mem_req_ready          (mem_req_ready),
        .mem_req_write          (mem_req_write),
        .mem_req_space          (mem_req_space),
        .mem_req_word_address   (mem_req_word_address),
        .mem_req_write_data     (mem_req_write_data),
        .mem_req_write_strobe   (mem_req_write_strobe),
        .mem_rsp_valid          (mem_rsp_valid),
        .mem_rsp_ready          (mem_rsp_ready),
        .mem_rsp_read_data      (mem_rsp_read_data),
        .mem_rsp_error          (mem_rsp_error),
        .class_result_valid     (class_result_valid),
        .class_index            (class_index),
        .class_logit            (class_logit)
    );

    // One-outstanding, one-cycle logical-memory response model.
    always @(posedge clk) begin
        if (rst) begin
            mem_rsp_valid <= 1'b0;
            mem_rsp_read_data <= FP32_POS_ZERO;
            mem_rsp_error <= 1'b0;
            pending_write <= 1'b0;
            pending_space <= PHASE_E_MEM_NONE;
            pending_address <= 32'd0;
            pending_write_data <= 32'd0;
            pending_write_strobe <= 4'd0;
            read_transaction_count <= 0;
            write_transaction_count <= 0;
            invalid_transaction_count <= 0;
        end else begin
            if (mem_rsp_valid && mem_rsp_ready) begin
                if (pending_write && !mem_rsp_error)
                    write_scratch_word(
                        pending_address,
                        pending_write_data,
                        pending_write_strobe
                    );
                mem_rsp_valid <= 1'b0;
                mem_rsp_read_data <= FP32_POS_ZERO;
                mem_rsp_error <= 1'b0;
            end

            if (mem_req_valid && mem_req_ready) begin
                pending_write <= mem_req_write;
                pending_space <= mem_req_space;
                pending_address <= mem_req_word_address;
                pending_write_data <= mem_req_write_data;
                pending_write_strobe <= mem_req_write_strobe;
                mem_rsp_read_data <= read_logical_word(
                    mem_req_space,
                    mem_req_word_address
                );
                mem_rsp_error <=
                    (logical_address_valid(
                        mem_req_write,
                        mem_req_space,
                        mem_req_word_address
                    ) !== 1'b1);
                mem_rsp_valid <= 1'b1;

                if (logical_address_valid(
                    mem_req_write,
                    mem_req_space,
                    mem_req_word_address
                ) !== 1'b1) begin
                    invalid_transaction_count <=
                        invalid_transaction_count + 1;
                    $error(
                        "Invalid logical request write=%0b space=%0d address=%08x",
                        mem_req_write,
                        mem_req_space,
                        mem_req_word_address
                    );
                end

                if (mem_req_write) begin
                    check(
                        mem_req_write_strobe == 4'hf,
                        "production engine emits full-word write strobes"
                    );
                    write_transaction_count <=
                        write_transaction_count + 1;
                end else
                    read_transaction_count <=
                        read_transaction_count + 1;
            end
        end
    end

    // Top-level sequencing and sideband monitors.
    always @(posedge clk) begin
        if (rst) begin
            cycle_count <= 0;
            command_count <= 0;
            checkpoint_count <= 0;
            parameter_request_count <= 0;
            layer_request_count <= 0;
            class_result_count <= 0;
            captured_class_index <= 32'd0;
            captured_class_logit <= FP32_QNAN;
        end else begin
            cycle_count <= cycle_count + 1;

            if (
                busy &&
                (cycle_count != 0) &&
                ((cycle_count % 1_000_000) == 0)
            )
                $display(
                    "E04_RTL_E2E_PROGRESS cycles=%0d commands=%0d reads=%0d writes=%0d",
                    cycle_count,
                    command_count,
                    read_transaction_count,
                    write_transaction_count
                );

            if (dut.command_valid && dut.command_ready) begin
                case (command_count)
                    0: begin
                        check(
                            dut.command.header.opcode ==
                                PHASE_E_OP_LAYERNORM,
                            "command 0 is final LayerNorm"
                        );
                        check(
                            dut.command.dim0 == E04_TOKEN_COUNT &&
                            dut.command.dim1 == E04_HIDDEN_SIZE,
                            "final LayerNorm dimensions"
                        );
                    end
                    1: begin
                        check(
                            dut.command.header.opcode ==
                                PHASE_E_OP_LAYOUT,
                            "command 1 is CLS layout"
                        );
                        check(
                            dut.command.dim2 == E04_HIDDEN_SIZE,
                            "CLS layout copies one hidden vector"
                        );
                    end
                    2: begin
                        check(
                            dut.command.header.opcode == PHASE_E_OP_GEMM,
                            "command 2 is classifier GEMM"
                        );
                        check(
                            dut.command.dim2 == E04_HIDDEN_SIZE &&
                            dut.command.dim3 == E04_CLASS_COUNT,
                            "classifier GEMM dimensions"
                        );
                        check(
                            (dut.command.header.flags &
                             PHASE_E_FLAG_GEMM_CACHE_SAFE) != 0,
                            "classifier GEMM enables safe cache reuse"
                        );
                    end
                    3: begin
                        check(
                            dut.command.header.opcode == PHASE_E_OP_ARGMAX,
                            "command 3 is Argmax"
                        );
                        check(
                            dut.command.dim0 == E04_CLASS_COUNT,
                            "Argmax scans every compact class"
                        );
                    end
                    4: begin
                        check(
                            dut.command.header.opcode == PHASE_E_OP_SOFTMAX,
                            "command 4 is optional class Softmax"
                        );
                        check(
                            dut.command.dim0 == 32'd1 &&
                            dut.command.dim1 == E04_CLASS_COUNT,
                            "class Softmax dimensions"
                        );
                    end
                    default: check(
                        1'b0,
                        "sequencer emitted an unexpected extra command"
                    );
                endcase

                check(
                    dut.command.header.tag ==
                        (8'h40 + command_count[7:0]),
                    "command tag increments from job tag"
                );
                command_count <= command_count + 1;
            end

            if (checkpoint_valid && checkpoint_ready) begin
                check(
                    checkpoint_phase == PHASE_E_E04,
                    "checkpoint phase is E04"
                );
                check(
                    checkpoint_section == PHASE_E_SECTION_FINAL,
                    "checkpoint section is FINAL"
                );
                check(
                    checkpoint_step == checkpoint_count[4:0],
                    "checkpoint step order"
                );
                check(
                    checkpoint_tag ==
                        (8'h40 + checkpoint_count[7:0]),
                    "checkpoint tag follows command tag"
                );
                case (checkpoint_count)
                    0: begin
                        check(
                            checkpoint_opcode == PHASE_E_OP_LAYERNORM,
                            "checkpoint 0 opcode"
                        );
                        check(
                            checkpoint_dst_tensor ==
                                PHASE_E_TENSOR_HIDDEN_B,
                            "checkpoint 0 destination"
                        );
                    end
                    1: begin
                        check(
                            checkpoint_opcode == PHASE_E_OP_LAYOUT,
                            "checkpoint 1 opcode"
                        );
                        check(
                            checkpoint_dst_tensor ==
                                PHASE_E_TENSOR_LINEAR_TMP,
                            "checkpoint 1 destination"
                        );
                    end
                    2: begin
                        check(
                            checkpoint_opcode == PHASE_E_OP_GEMM,
                            "checkpoint 2 opcode"
                        );
                        check(
                            checkpoint_dst_tensor ==
                                PHASE_E_TENSOR_LOGITS,
                            "checkpoint 2 destination"
                        );
                    end
                    3: begin
                        check(
                            checkpoint_opcode == PHASE_E_OP_ARGMAX,
                            "checkpoint 3 opcode"
                        );
                        check(
                            checkpoint_dst_tensor ==
                                PHASE_E_TENSOR_NONE,
                            "checkpoint 3 has no destination tensor"
                        );
                    end
                    4: begin
                        check(
                            checkpoint_opcode == PHASE_E_OP_SOFTMAX,
                            "checkpoint 4 opcode"
                        );
                        check(
                            checkpoint_dst_tensor ==
                                PHASE_E_TENSOR_CLASS_PROB,
                            "checkpoint 4 destination"
                        );
                    end
                    default:
                        check(1'b0, "unexpected extra checkpoint");
                endcase
                checkpoint_count <= checkpoint_count + 1;
            end

            if (operand_load_request && operand_load_ready) begin
                if (parameter_request_count == 0)
                    check(
                        operand_load_command.header.opcode ==
                            PHASE_E_OP_LAYERNORM,
                        "first parameter stage belongs to LayerNorm"
                    );
                else if (parameter_request_count == 1)
                    check(
                        operand_load_command.header.opcode ==
                            PHASE_E_OP_GEMM,
                        "second parameter stage belongs to classifier GEMM"
                    );
                else
                    check(1'b0, "unexpected extra parameter-stage request");
                parameter_request_count <=
                    parameter_request_count + 1;
            end

            if (layer_param_request)
                layer_request_count <= layer_request_count + 1;

            if (class_result_valid) begin
                class_result_count <= class_result_count + 1;
                captured_class_index <= class_index;
                captured_class_logit <= class_logit;
            end
        end
    end

    initial begin
        for (
            initialize_index = 0;
            initialize_index < E04_HIDDEN_WORDS;
            initialize_index = initialize_index + 1
        ) begin
            hidden_b_memory[initialize_index] = FP32_SENTINEL;
            hidden_write_hits[initialize_index] = 0;
        end

        for (
            initialize_index = 0;
            initialize_index < E04_HIDDEN_SIZE;
            initialize_index = initialize_index + 1
        ) begin
            linear_memory[initialize_index] = FP32_SENTINEL;
            linear_write_hits[initialize_index] = 0;
        end

        for (
            initialize_index = 0;
            initialize_index < E04_CLASS_COUNT;
            initialize_index = initialize_index + 1
        ) begin
            logits_memory[initialize_index] = FP32_SENTINEL;
            probability_memory[initialize_index] = FP32_SENTINEL;
            logit_write_hits[initialize_index] = 0;
            probability_write_hits[initialize_index] = 0;
        end

        repeat (5)
            @(posedge clk);
        @(negedge clk);
        rst = 1'b0;

        job = '0;
        job.phase = PHASE_E_E04;
        job.class_softmax_enable = 1'b1;
        job.checkpoint_enable = 1'b1;
        job.job_tag = 8'h40;

        global_params = '0;
        global_params.final_ln_gamma_base =
            FINAL_LN_GAMMA_BASE;
        global_params.final_ln_beta_base =
            FINAL_LN_BETA_BASE;
        global_params.classifier_weight_base =
            CLASSIFIER_WEIGHT_BASE;
        global_params.classifier_bias_base =
            CLASSIFIER_BIAS_BASE;

        @(negedge clk);
        job_valid = 1'b1;
        while (!job_ready)
            @(negedge clk);
        @(posedge clk);
        @(negedge clk);
        job_valid = 1'b0;

        wait (done || error);
        #1;

        check(!error, "E04 job completed without sequencer error");
        check(error_code == PHASE_E_ERROR_NONE, "error code is NONE");
        check(command_count == EXPECTED_COMMANDS, "five commands completed");
        check(
            checkpoint_count == EXPECTED_COMMANDS,
            "checkpoint observed after every command"
        );
        check(
            parameter_request_count == 2,
            "LayerNorm and classifier requested parameter staging"
        );
        check(
            layer_request_count == 0,
            "E04 did not request encoder-layer parameters"
        );
        check(
            class_result_count == 1,
            "Argmax produced exactly one class result"
        );
        check(
            captured_class_index == TARGET_CLASS,
            "class index matches the unique maximum bias"
        );
        check(
            captured_class_logit == FP32_SEVEN,
            "class logit is exactly +7.0"
        );
        check(
            invalid_transaction_count == 0,
            "all logical-memory transactions were in range"
        );
        check(
            write_transaction_count == EXPECTED_WRITES,
            "total scratch write transaction count"
        );
        check(
            hidden_write_count == EXPECTED_HIDDEN_WRITES,
            "LayerNorm wrote every HIDDEN_B word"
        );
        check(
            linear_write_count == EXPECTED_LINEAR_WRITES,
            "CLS layout wrote one hidden vector"
        );
        check(
            logit_write_count == EXPECTED_LOGIT_WRITES,
            "classifier wrote every logit"
        );
        check(
            probability_write_count == EXPECTED_PROB_WRITES,
            "Softmax wrote every class probability"
        );

        for (
            verify_index = 0;
            verify_index < E04_HIDDEN_WORDS;
            verify_index = verify_index + 1
        ) begin
            check(
                hidden_write_hits[verify_index] == 1,
                "each HIDDEN_B word is written exactly once"
            );
            check(
                hidden_b_memory[verify_index] == FP32_POS_ZERO,
                "constant-zero LayerNorm output remains +0"
            );
        end

        for (
            verify_index = 0;
            verify_index < E04_HIDDEN_SIZE;
            verify_index = verify_index + 1
        ) begin
            check(
                linear_write_hits[verify_index] == 1,
                "each CLS-vector word is written exactly once"
            );
            check(
                linear_memory[verify_index] == FP32_POS_ZERO,
                "CLS vector is zero after final LayerNorm"
            );
        end

        for (
            verify_index = 0;
            verify_index < E04_CLASS_COUNT;
            verify_index = verify_index + 1
        ) begin
            check(
                logit_write_hits[verify_index] == 1,
                "each classifier logit is written exactly once"
            );
            check(
                logits_memory[verify_index] ==
                    ((verify_index == TARGET_CLASS)
                        ? FP32_SEVEN
                        : FP32_POS_ZERO),
                "classifier logits equal the programmed bias"
            );
            check(
                probability_write_hits[verify_index] == 1,
                "each class probability is written exactly once"
            );
            check(
                (^probability_memory[verify_index]) !== 1'bx,
                "every Softmax probability is known"
            );
            check(
                probability_memory[verify_index][31] == 1'b0 &&
                probability_memory[verify_index][30:23] != 8'hff &&
                probability_memory[verify_index] > FP32_POS_ZERO &&
                probability_memory[verify_index] <= FP32_ONE,
                "every Softmax probability is finite and in (0, 1]"
            );
            if (verify_index != TARGET_CLASS)
                check(
                    probability_memory[verify_index] ==
                        probability_memory[0],
                    "equal non-target logits produce equal probabilities"
                );
        end

        check(
            probability_memory[TARGET_CLASS] >
                probability_memory[0],
            "target Softmax probability is positive and maximal"
        );

        if (failures == 0) begin
            $display(
                "VIT_PHASE_E_NPU_E04_RTL_E2E_PASS checks=%0d cycles=%0d commands=%0d reads=%0d writes=%0d class=%0d logit=%08x",
                checks,
                cycle_count,
                command_count,
                read_transaction_count,
                write_transaction_count,
                captured_class_index,
                captured_class_logit
            );
            $finish;
        end else begin
            $fatal(
                1,
                "VIT_PHASE_E_NPU_E04_RTL_E2E_FAIL checks=%0d failures=%0d",
                checks,
                failures
            );
        end
    end

    initial begin
        repeat (WATCHDOG_CYCLES)
            @(posedge clk);
        $fatal(
            1,
            "Timeout in E04 RTL end-to-end test after %0d cycles",
            WATCHDOG_CYCLES
        );
    end

endmodule
