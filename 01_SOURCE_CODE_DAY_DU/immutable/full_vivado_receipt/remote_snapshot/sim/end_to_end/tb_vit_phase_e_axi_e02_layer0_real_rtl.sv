`timescale 1ns/1ps

// Production E02 test for one complete, full-dimension encoder layer using
// real activations and all sixteen real layer-0 tensors.
//
//   AXI4-Lite BFM -> vit_phase_e_axi_bd_wrapper
//                 -> production vit_phase_e_npu / engine
//                 -> production 32-bit AXI memory adapter
//                 -> three-region AXI DDR model
//
// The test does not define VIT_PURE_SV_BEHAVIORAL and does not override any
// ViT-Base dimensions.  E02 is intentionally used because the sequencer
// contract fixes it to encoder layer 0 and exactly twenty commands.
module tb_vit_phase_e_axi_e02_layer0_real_rtl;

    import vit_phase_e_pkg::*;

    localparam integer AXI_ADDR_WIDTH = 40;
    localparam integer AXI_ID_WIDTH = 1;

    localparam integer TOKEN_COUNT = 197;
    localparam integer HIDDEN_SIZE = 768;
    localparam integer HEAD_COUNT = 12;
    localparam integer INTERMEDIATE_SIZE = 3072;
    localparam integer HIDDEN_WORDS = TOKEN_COUNT * HIDDEN_SIZE;
    localparam integer SCORE_WORDS =
        HEAD_COUNT * TOKEN_COUNT * TOKEN_COUNT;
    localparam integer FC1_WORDS = TOKEN_COUNT * INTERMEDIATE_SIZE;

    // Canonical model-package-v1 word offsets generated from
    // build/model_package/v1/vit_runtime_config.json.
    localparam logic [31:0] LN1_GAMMA_BASE = 32'h0017_16f0;
    localparam logic [31:0] LN1_BETA_BASE = 32'h0017_19f0;
    localparam logic [31:0] Q_WEIGHT_BASE = 32'h0017_1cf0;
    localparam logic [31:0] Q_BIAS_BASE = 32'h0020_1cf0;
    localparam logic [31:0] K_WEIGHT_BASE = 32'h0020_1ff0;
    localparam logic [31:0] K_BIAS_BASE = 32'h0029_1ff0;
    localparam logic [31:0] V_WEIGHT_BASE = 32'h0029_22f0;
    localparam logic [31:0] V_BIAS_BASE = 32'h0032_22f0;
    localparam logic [31:0] O_WEIGHT_BASE = 32'h0032_25f0;
    localparam logic [31:0] O_BIAS_BASE = 32'h003b_25f0;
    localparam logic [31:0] LN2_GAMMA_BASE = 32'h003b_28f0;
    localparam logic [31:0] LN2_BETA_BASE = 32'h003b_2bf0;
    localparam logic [31:0] FC1_WEIGHT_BASE = 32'h003b_2ef0;
    localparam logic [31:0] FC1_BIAS_BASE = 32'h005f_2ef0;
    localparam logic [31:0] FC2_WEIGHT_BASE = 32'h005f_3af0;
    localparam logic [31:0] FC2_BIAS_BASE = 32'h0083_3af0;

    localparam integer QKV_WEIGHT_WORDS = HIDDEN_SIZE * HIDDEN_SIZE;
    localparam integer FC_WEIGHT_WORDS =
        HIDDEN_SIZE * INTERMEDIATE_SIZE;
    localparam integer LAYER0_PARAMETER_WORDS =
        (4 * QKV_WEIGHT_WORDS) +
        (2 * FC_WEIGHT_WORDS) +
        (9 * HIDDEN_SIZE) +
        INTERMEDIATE_SIZE;
    localparam integer MODEL_BACKING_WORDS =
        FC2_BIAS_BASE + HIDDEN_SIZE;
    localparam logic [31:0] MODEL_PACKAGE_V1_WORDS = 32'h0528_eaf0;
    localparam integer INPUT_BACKING_WORDS = 1;
    localparam integer SCRATCH_WORDS = PHASE_E_SCRATCH_WORDS;

    localparam logic [63:0] MODEL_BASE =
        64'h0000_0010_0000_0000;
    localparam logic [63:0] INPUT_BASE =
        64'h0000_0020_0000_0000;
    localparam logic [63:0] SCRATCH_BASE =
        64'h0000_0030_0000_0000;

    localparam logic [7:0] JOB_TAG = 8'h20;
    localparam integer EXPECTED_COMMANDS = 20;
    localparam integer EXPECTED_PARAMETER_REQUESTS = 8;
    localparam integer EXPECTED_WRITES =
        (15 * HIDDEN_WORDS) + (3 * SCORE_WORDS) + (2 * FC1_WORDS);
    localparam logic [31:0] EXPECTED_MODEL_MIN = LN1_GAMMA_BASE;
    localparam logic [31:0] EXPECTED_MODEL_MAX =
        FC2_BIAS_BASE + HIDDEN_SIZE - 1;
    localparam logic [31:0] EXPECTED_SCRATCH_MIN =
        PHASE_E_ADDR_HIDDEN_A;
    localparam logic [31:0] EXPECTED_SCRATCH_MAX =
        PHASE_E_ADDR_FC1 + FC1_WORDS - 1;

    // Encoder arithmetic is a much longer chain than E04.  This combined
    // absolute/relative threshold is strict enough to expose a functional
    // drift while allowing the production finite-state FP32 round points to
    // differ from the behavioral oracle.
    localparam real OUTPUT_ABS_TOLERANCE = 2.0e-3;
    localparam real OUTPUT_REL_TOLERANCE = 2.0e-3;
    localparam logic [31:0] FP32_SENTINEL = 32'hdead_beef;
    localparam logic [63:0] WATCHDOG_CYCLES = 64'd20_000_000_000;
    localparam logic [1:0] AXI_RESP_OKAY = 2'b00;

    localparam logic [11:0] REG_IP_ID = 12'h000;
    localparam logic [11:0] REG_CONTROL = 12'h008;
    localparam logic [11:0] REG_STATUS = 12'h00c;
    localparam logic [11:0] REG_IRQ_ENABLE = 12'h010;
    localparam logic [11:0] REG_IRQ_STATUS = 12'h014;
    localparam logic [11:0] REG_ERROR_CODE = 12'h018;
    localparam logic [11:0] REG_MODEL_BASE_LO = 12'h020;
    localparam logic [11:0] REG_MODEL_BASE_HI = 12'h024;
    localparam logic [11:0] REG_INPUT_BASE_LO = 12'h028;
    localparam logic [11:0] REG_INPUT_BASE_HI = 12'h02c;
    localparam logic [11:0] REG_SCRATCH_BASE_LO = 12'h030;
    localparam logic [11:0] REG_SCRATCH_BASE_HI = 12'h034;
    localparam logic [11:0] REG_MODEL_WORDS = 12'h038;
    localparam logic [11:0] REG_INPUT_WORDS = 12'h03c;
    localparam logic [11:0] REG_SCRATCH_WORDS = 12'h040;
    localparam logic [11:0] REG_JOB_CONFIG = 12'h0a0;
    localparam logic [11:0] REG_JOB_PATCH_BASE = 12'h0a4;
    localparam logic [11:0] REG_LAYER0_BASE = 12'h400;

    logic aclk = 1'b0;
    logic aresetn = 1'b0;

    logic [11:0] s_axi_awaddr = 12'd0;
    logic [2:0] s_axi_awprot = 3'd0;
    logic s_axi_awvalid = 1'b0;
    logic s_axi_awready;
    logic [31:0] s_axi_wdata = 32'd0;
    logic [3:0] s_axi_wstrb = 4'd0;
    logic s_axi_wvalid = 1'b0;
    logic s_axi_wready;
    logic [1:0] s_axi_bresp;
    logic s_axi_bvalid;
    logic s_axi_bready = 1'b0;
    logic [11:0] s_axi_araddr = 12'd0;
    logic [2:0] s_axi_arprot = 3'd0;
    logic s_axi_arvalid = 1'b0;
    logic s_axi_arready;
    logic [31:0] s_axi_rdata;
    logic [1:0] s_axi_rresp;
    logic s_axi_rvalid;
    logic s_axi_rready = 1'b0;

    logic [AXI_ID_WIDTH-1:0] m_axi_awid;
    logic [AXI_ADDR_WIDTH-1:0] m_axi_awaddr;
    logic [7:0] m_axi_awlen;
    logic [2:0] m_axi_awsize;
    logic [1:0] m_axi_awburst;
    logic m_axi_awlock;
    logic [3:0] m_axi_awcache;
    logic [2:0] m_axi_awprot;
    logic [3:0] m_axi_awqos;
    logic m_axi_awvalid;
    logic m_axi_awready;
    logic [31:0] m_axi_wdata;
    logic [3:0] m_axi_wstrb;
    logic m_axi_wlast;
    logic m_axi_wvalid;
    logic m_axi_wready;
    logic [AXI_ID_WIDTH-1:0] m_axi_bid;
    logic [1:0] m_axi_bresp;
    logic m_axi_bvalid;
    logic m_axi_bready;
    logic [AXI_ID_WIDTH-1:0] m_axi_arid;
    logic [AXI_ADDR_WIDTH-1:0] m_axi_araddr;
    logic [7:0] m_axi_arlen;
    logic [2:0] m_axi_arsize;
    logic [1:0] m_axi_arburst;
    logic m_axi_arlock;
    logic [3:0] m_axi_arcache;
    logic [2:0] m_axi_arprot;
    logic [3:0] m_axi_arqos;
    logic m_axi_arvalid;
    logic m_axi_arready;
    logic [AXI_ID_WIDTH-1:0] m_axi_rid;
    logic [31:0] m_axi_rdata;
    logic [1:0] m_axi_rresp;
    logic m_axi_rlast;
    logic m_axi_rvalid;
    logic m_axi_rready;
    logic irq_o;

    logic [63:0] ddr_read_count;
    logic [63:0] ddr_write_count;
    logic [63:0] model_read_count;
    logic [63:0] input_read_count;
    logic [63:0] scratch_read_count;
    logic [63:0] scratch_write_count;
    logic [31:0] invalid_access_count;

    logic [63:0] cycle_count = 64'd0;
    integer checks = 0;
    integer failures = 0;
    integer command_count = 0;
    integer checkpoint_count = 0;
    integer parameter_request_count = 0;
    integer layer_request_count = 0;
    integer class_result_count = 0;
    integer initialize_index;
    integer exact_mismatches;
    integer tolerance_failures;
    integer max_error_index;
    logic [1:0] response;
    logic [31:0] read_data;
    logic [31:0] job_config_value;
    logic [31:0] golden_output [0:HIDDEN_WORDS-1];
    real rtl_value;
    real golden_value;
    real absolute_error;
    real allowed_error;
    real max_abs_error;

    always #1 aclk = ~aclk;

    function automatic logic fp32_is_finite(
        input logic [31:0] word
    );
        begin
            fp32_is_finite = (word[30:23] != 8'hff);
        end
    endfunction

    function automatic real fp32_to_real(
        input logic [31:0] word
    );
        integer exponent;
        integer scale_index;
        real significand;
        real scale;
        begin
            exponent = word[30:23];
            scale = 1.0;
            significand = 0.0;
            if (exponent == 0) begin
                significand = real'(word[22:0]) / 8388608.0;
                for (scale_index = 0; scale_index < 126;
                     scale_index = scale_index + 1)
                    scale = scale * 0.5;
            end else if (exponent != 255) begin
                significand =
                    1.0 + (real'(word[22:0]) / 8388608.0);
                if (exponent >= 127)
                    for (scale_index = 127; scale_index < exponent;
                         scale_index = scale_index + 1)
                        scale = scale * 2.0;
                else
                    for (scale_index = exponent; scale_index < 127;
                         scale_index = scale_index + 1)
                        scale = scale * 0.5;
            end
            if (exponent == 255)
                fp32_to_real = 0.0;
            else begin
                fp32_to_real = significand * scale;
                if (word[31])
                    fp32_to_real = -fp32_to_real;
            end
        end
    endfunction

    function automatic phase_e_opcode_t expected_opcode(
        input integer ordinal
    );
        begin
            case (ordinal)
                0, 15:
                    expected_opcode = PHASE_E_OP_LAYERNORM;
                1, 3, 5, 8, 11, 13, 16, 18:
                    expected_opcode = PHASE_E_OP_GEMM;
                2, 4, 6, 7, 12:
                    expected_opcode = PHASE_E_OP_LAYOUT;
                9, 14, 19:
                    expected_opcode = PHASE_E_OP_VECTOR;
                10:
                    expected_opcode = PHASE_E_OP_SOFTMAX;
                17:
                    expected_opcode = PHASE_E_OP_GELU;
                default:
                    expected_opcode = PHASE_E_OP_NOP;
            endcase
        end
    endfunction

    task automatic check(
        input logic condition,
        input string message
    );
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $error(
                    "E02 LAYER0 REAL AXI CHECK FAILED cycle=%0d: %s",
                    cycle_count,
                    message
                );
            end
        end
    endtask

    task automatic axi_lite_write(
        input logic [11:0] address,
        input logic [31:0] data
    );
        logic aw_done;
        logic w_done;
        begin
            aw_done = 1'b0;
            w_done = 1'b0;
            @(negedge aclk);
            s_axi_awaddr = address;
            s_axi_awvalid = 1'b1;
            s_axi_wdata = data;
            s_axi_wstrb = 4'hf;
            s_axi_wvalid = 1'b1;

            while (!aw_done || !w_done) begin
                @(posedge aclk);
                if (s_axi_awvalid && s_axi_awready)
                    aw_done = 1'b1;
                if (s_axi_wvalid && s_axi_wready)
                    w_done = 1'b1;
                @(negedge aclk);
                if (aw_done)
                    s_axi_awvalid = 1'b0;
                if (w_done)
                    s_axi_wvalid = 1'b0;
            end

            while (!s_axi_bvalid)
                @(posedge aclk);
            response = s_axi_bresp;
            @(negedge aclk);
            s_axi_bready = 1'b1;
            @(posedge aclk);
            @(negedge aclk);
            s_axi_bready = 1'b0;
            check(response == AXI_RESP_OKAY, "AXI-Lite write response");
        end
    endtask

    task automatic axi_lite_read(
        input logic [11:0] address,
        output logic [31:0] data
    );
        begin
            @(negedge aclk);
            s_axi_araddr = address;
            s_axi_arvalid = 1'b1;
            do begin
                @(posedge aclk);
            end while (!(s_axi_arvalid && s_axi_arready));
            @(negedge aclk);
            s_axi_arvalid = 1'b0;

            while (!s_axi_rvalid)
                @(posedge aclk);
            data = s_axi_rdata;
            response = s_axi_rresp;
            @(negedge aclk);
            s_axi_rready = 1'b1;
            @(posedge aclk);
            @(negedge aclk);
            s_axi_rready = 1'b0;
            check(response == AXI_RESP_OKAY, "AXI-Lite read response");
        end
    endtask

    task automatic program_layer0_table;
        begin
            axi_lite_write(REG_LAYER0_BASE + 12'h000, LN1_GAMMA_BASE);
            axi_lite_write(REG_LAYER0_BASE + 12'h004, LN1_BETA_BASE);
            axi_lite_write(REG_LAYER0_BASE + 12'h008, Q_WEIGHT_BASE);
            axi_lite_write(REG_LAYER0_BASE + 12'h00c, Q_BIAS_BASE);
            axi_lite_write(REG_LAYER0_BASE + 12'h010, K_WEIGHT_BASE);
            axi_lite_write(REG_LAYER0_BASE + 12'h014, K_BIAS_BASE);
            axi_lite_write(REG_LAYER0_BASE + 12'h018, V_WEIGHT_BASE);
            axi_lite_write(REG_LAYER0_BASE + 12'h01c, V_BIAS_BASE);
            axi_lite_write(REG_LAYER0_BASE + 12'h020, O_WEIGHT_BASE);
            axi_lite_write(REG_LAYER0_BASE + 12'h024, O_BIAS_BASE);
            axi_lite_write(REG_LAYER0_BASE + 12'h028, LN2_GAMMA_BASE);
            axi_lite_write(REG_LAYER0_BASE + 12'h02c, LN2_BETA_BASE);
            axi_lite_write(REG_LAYER0_BASE + 12'h030, FC1_WEIGHT_BASE);
            axi_lite_write(REG_LAYER0_BASE + 12'h034, FC1_BIAS_BASE);
            axi_lite_write(REG_LAYER0_BASE + 12'h038, FC2_WEIGHT_BASE);
            axi_lite_write(REG_LAYER0_BASE + 12'h03c, FC2_BIAS_BASE);
        end
    endtask

    // No E05 shape override: E02 always uses the production ViT-Base shape.
    vit_phase_e_axi_bd_wrapper #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH)
    ) dut (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awprot(s_axi_awprot),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arprot(s_axi_arprot),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .m_axi_awid(m_axi_awid),
        .m_axi_awaddr(m_axi_awaddr),
        .m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),
        .m_axi_awburst(m_axi_awburst),
        .m_axi_awlock(m_axi_awlock),
        .m_axi_awcache(m_axi_awcache),
        .m_axi_awprot(m_axi_awprot),
        .m_axi_awqos(m_axi_awqos),
        .m_axi_awvalid(m_axi_awvalid),
        .m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),
        .m_axi_wstrb(m_axi_wstrb),
        .m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),
        .m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid),
        .m_axi_bresp(m_axi_bresp),
        .m_axi_bvalid(m_axi_bvalid),
        .m_axi_bready(m_axi_bready),
        .m_axi_arid(m_axi_arid),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache),
        .m_axi_arprot(m_axi_arprot),
        .m_axi_arqos(m_axi_arqos),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready),
        .irq_o(irq_o)
    );

    // Backpressure is already covered by compact AXI E05.  Disabling optional
    // DDR stalls here preserves the exact AXI protocol while keeping this
    // billion-operation real-data test as short as the scalar adapter allows.
    vit_axi_ddr_model_32 #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH),
        .MODEL_WORDS(MODEL_BACKING_WORDS),
        .INPUT_WORDS(INPUT_BACKING_WORDS),
        .SCRATCH_WORDS(SCRATCH_WORDS),
        .MODEL_BASE(MODEL_BASE),
        .INPUT_BASE(INPUT_BASE),
        .SCRATCH_BASE(SCRATCH_BASE),
        .STALL_ENABLE(1'b0)
    ) u_ddr (
        .aclk(aclk),
        .aresetn(aresetn),
        .s_axi_awid(m_axi_awid),
        .s_axi_awaddr(m_axi_awaddr),
        .s_axi_awlen(m_axi_awlen),
        .s_axi_awsize(m_axi_awsize),
        .s_axi_awburst(m_axi_awburst),
        .s_axi_awlock(m_axi_awlock),
        .s_axi_awcache(m_axi_awcache),
        .s_axi_awprot(m_axi_awprot),
        .s_axi_awqos(m_axi_awqos),
        .s_axi_awvalid(m_axi_awvalid),
        .s_axi_awready(m_axi_awready),
        .s_axi_wdata(m_axi_wdata),
        .s_axi_wstrb(m_axi_wstrb),
        .s_axi_wlast(m_axi_wlast),
        .s_axi_wvalid(m_axi_wvalid),
        .s_axi_wready(m_axi_wready),
        .s_axi_bid(m_axi_bid),
        .s_axi_bresp(m_axi_bresp),
        .s_axi_bvalid(m_axi_bvalid),
        .s_axi_bready(m_axi_bready),
        .s_axi_arid(m_axi_arid),
        .s_axi_araddr(m_axi_araddr),
        .s_axi_arlen(m_axi_arlen),
        .s_axi_arsize(m_axi_arsize),
        .s_axi_arburst(m_axi_arburst),
        .s_axi_arlock(m_axi_arlock),
        .s_axi_arcache(m_axi_arcache),
        .s_axi_arprot(m_axi_arprot),
        .s_axi_arqos(m_axi_arqos),
        .s_axi_arvalid(m_axi_arvalid),
        .s_axi_arready(m_axi_arready),
        .s_axi_rid(m_axi_rid),
        .s_axi_rdata(m_axi_rdata),
        .s_axi_rresp(m_axi_rresp),
        .s_axi_rlast(m_axi_rlast),
        .s_axi_rvalid(m_axi_rvalid),
        .s_axi_rready(m_axi_rready),
        .read_count_o(ddr_read_count),
        .write_count_o(ddr_write_count),
        .model_read_count_o(model_read_count),
        .input_read_count_o(input_read_count),
        .scratch_read_count_o(scratch_read_count),
        .scratch_write_count_o(scratch_write_count),
        .invalid_access_count_o(invalid_access_count)
    );

    always @(posedge aclk) begin
        cycle_count <= cycle_count + 1'b1;
        if (!aresetn) begin
            command_count <= 0;
            checkpoint_count <= 0;
            parameter_request_count <= 0;
            layer_request_count <= 0;
            class_result_count <= 0;
        end else begin
            if (
                dut.u_core.u_npu.command_valid &&
                dut.u_core.u_npu.command_ready
            ) begin
                check(
                    command_count < EXPECTED_COMMANDS,
                    "no command beyond the twenty-step layer"
                );
                if (command_count < EXPECTED_COMMANDS) begin
                    check(
                        dut.u_core.u_npu.command.header.opcode ==
                            expected_opcode(command_count),
                        "command opcode follows encoder step order"
                    );
                    check(
                        dut.u_core.u_npu.command.header.tag ==
                            JOB_TAG + command_count[7:0],
                        "command tag follows ordinal"
                    );
                    check(
                        dut.u_core.u_npu.command.header.reserved[7:6] ==
                            PHASE_E_SECTION_ENCODER,
                        "command section is ENCODER"
                    );
                    check(
                        dut.u_core.u_npu.command.header.reserved[5:2] == 4'd0,
                        "command layer is zero"
                    );
                end
                command_count <= command_count + 1;
            end

            if (dut.u_core.checkpoint_valid) begin
                check(
                    dut.u_core.checkpoint_phase == PHASE_E_E02,
                    "checkpoint phase is E02"
                );
                check(
                    dut.u_core.checkpoint_section ==
                        PHASE_E_SECTION_ENCODER,
                    "checkpoint section is ENCODER"
                );
                check(
                    dut.u_core.checkpoint_layer == 4'd0,
                    "checkpoint layer is zero"
                );
                check(
                    dut.u_core.checkpoint_step ==
                        checkpoint_count[4:0],
                    "checkpoint step is ordered"
                );
                checkpoint_count <= checkpoint_count + 1;
            end

            if (dut.u_core.operand_load_request)
                parameter_request_count <= parameter_request_count + 1;
            if (dut.u_core.layer_param_request) begin
                check(
                    dut.u_core.layer_param_index == 4'd0,
                    "layer-table request selects layer zero"
                );
                layer_request_count <= layer_request_count + 1;
            end
            if (dut.u_core.class_result_valid)
                class_result_count <= class_result_count + 1;

            if (
                dut.u_core.npu_busy &&
                (cycle_count != 0) &&
                (
                    (
                        (cycle_count < 64'd10_000_000) &&
                        ((cycle_count % 64'd1_000_000) == 0)
                    ) ||
                    (
                        (cycle_count >= 64'd10_000_000) &&
                        ((cycle_count % 64'd50_000_000) == 0)
                    )
                )
            )
                begin
                    $display(
                        "E02_LAYER0_REAL_AXI_PROGRESS cycles=%0d commands=%0d checkpoints=%0d reads=%0d writes=%0d model_reads=%0d scratch_reads=%0d",
                        cycle_count,
                        command_count,
                        checkpoint_count,
                        ddr_read_count,
                        ddr_write_count,
                        model_read_count,
                        scratch_read_count
                    );
                    $fflush();
                end

            if (cycle_count >= WATCHDOG_CYCLES)
                $fatal(
                    1,
                    "E02 layer0 real-data AXI watchdog after %0d cycles",
                    WATCHDOG_CYCLES
                );
        end
    end

    initial begin
        $display(
            "E02_LAYER0_REAL_AXI_PRELOAD_BEGIN tensors=18 parameter_words=%0d",
            LAYER0_PARAMETER_WORDS
        );
        $fflush();
        $readmemh(
            "results/embedding_step_06_hidden_states_f32.hex",
            u_ddr.scratch_memory,
            PHASE_E_ADDR_HIDDEN_A,
            PHASE_E_ADDR_HIDDEN_A + HIDDEN_WORDS - 1
        );
        $readmemh(
            "results/encoder_layer_00_step_20_layer_output_f32.hex",
            golden_output
        );

        $readmemh(
            "parameters/encoder_layer_00_ln_before_gamma_f32.hex",
            u_ddr.model_memory,
            LN1_GAMMA_BASE,
            LN1_GAMMA_BASE + HIDDEN_SIZE - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_ln_before_beta_f32.hex",
            u_ddr.model_memory,
            LN1_BETA_BASE,
            LN1_BETA_BASE + HIDDEN_SIZE - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_q_weight_B_f32.hex",
            u_ddr.model_memory,
            Q_WEIGHT_BASE,
            Q_WEIGHT_BASE + QKV_WEIGHT_WORDS - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_q_bias_f32.hex",
            u_ddr.model_memory,
            Q_BIAS_BASE,
            Q_BIAS_BASE + HIDDEN_SIZE - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_k_weight_B_f32.hex",
            u_ddr.model_memory,
            K_WEIGHT_BASE,
            K_WEIGHT_BASE + QKV_WEIGHT_WORDS - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_k_bias_f32.hex",
            u_ddr.model_memory,
            K_BIAS_BASE,
            K_BIAS_BASE + HIDDEN_SIZE - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_v_weight_B_f32.hex",
            u_ddr.model_memory,
            V_WEIGHT_BASE,
            V_WEIGHT_BASE + QKV_WEIGHT_WORDS - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_v_bias_f32.hex",
            u_ddr.model_memory,
            V_BIAS_BASE,
            V_BIAS_BASE + HIDDEN_SIZE - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_o_weight_B_f32.hex",
            u_ddr.model_memory,
            O_WEIGHT_BASE,
            O_WEIGHT_BASE + QKV_WEIGHT_WORDS - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_o_bias_f32.hex",
            u_ddr.model_memory,
            O_BIAS_BASE,
            O_BIAS_BASE + HIDDEN_SIZE - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_ln_after_gamma_f32.hex",
            u_ddr.model_memory,
            LN2_GAMMA_BASE,
            LN2_GAMMA_BASE + HIDDEN_SIZE - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_ln_after_beta_f32.hex",
            u_ddr.model_memory,
            LN2_BETA_BASE,
            LN2_BETA_BASE + HIDDEN_SIZE - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_fc1_weight_B_f32.hex",
            u_ddr.model_memory,
            FC1_WEIGHT_BASE,
            FC1_WEIGHT_BASE + FC_WEIGHT_WORDS - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_fc1_bias_f32.hex",
            u_ddr.model_memory,
            FC1_BIAS_BASE,
            FC1_BIAS_BASE + INTERMEDIATE_SIZE - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_fc2_weight_B_f32.hex",
            u_ddr.model_memory,
            FC2_WEIGHT_BASE,
            FC2_WEIGHT_BASE + FC_WEIGHT_WORDS - 1
        );
        $readmemh(
            "parameters/encoder_layer_00_fc2_bias_f32.hex",
            u_ddr.model_memory,
            FC2_BIAS_BASE,
            FC2_BIAS_BASE + HIDDEN_SIZE - 1
        );
        $display(
            "E02_LAYER0_REAL_AXI_PRELOAD_DONE input_words=%0d model_words=%0d golden_words=%0d",
            HIDDEN_WORDS,
            MODEL_BACKING_WORDS,
            HIDDEN_WORDS
        );
        $fflush();

        // Initialize the alternate/intermediate hidden buffer so an early or
        // skipped command cannot silently consume stale-looking values.
        for (initialize_index = 0;
             initialize_index < HIDDEN_WORDS;
             initialize_index = initialize_index + 1)
            u_ddr.scratch_memory[
                PHASE_E_ADDR_HIDDEN_B + initialize_index
            ] = FP32_SENTINEL;

        repeat (8)
            @(posedge aclk);
        @(negedge aclk);
        aresetn = 1'b1;

        axi_lite_read(REG_IP_ID, read_data);
        check(read_data == 32'h5649_544e, "IP identity register");

        axi_lite_write(REG_MODEL_BASE_LO, MODEL_BASE[31:0]);
        axi_lite_write(REG_MODEL_BASE_HI, MODEL_BASE[63:32]);
        axi_lite_write(REG_INPUT_BASE_LO, INPUT_BASE[31:0]);
        axi_lite_write(REG_INPUT_BASE_HI, INPUT_BASE[63:32]);
        axi_lite_write(REG_SCRATCH_BASE_LO, SCRATCH_BASE[31:0]);
        axi_lite_write(REG_SCRATCH_BASE_HI, SCRATCH_BASE[63:32]);
        axi_lite_write(REG_MODEL_WORDS, MODEL_PACKAGE_V1_WORDS);
        axi_lite_write(REG_INPUT_WORDS, INPUT_BACKING_WORDS);
        axi_lite_write(REG_SCRATCH_WORDS, SCRATCH_WORDS);
        program_layer0_table();

        job_config_value = 32'd0;
        job_config_value[2:0] = PHASE_E_E02;
        job_config_value[12] = 1'b1;
        job_config_value[20:13] = JOB_TAG;
        axi_lite_write(REG_JOB_CONFIG, job_config_value);
        axi_lite_write(REG_JOB_PATCH_BASE, 32'd0);
        axi_lite_write(REG_IRQ_ENABLE, 32'h0000_0001);

        axi_lite_read(REG_STATUS, read_data);
        check(read_data[0] && !read_data[1], "idle before START");
        check(!read_data[2] && !read_data[3], "flags clear before START");

        axi_lite_write(REG_CONTROL, 32'h0000_0001);
        axi_lite_read(REG_STATUS, read_data);
        check(read_data[1] && !read_data[0], "BUSY after START");
        $display(
            "E02_LAYER0_REAL_AXI_STARTED cycle=%0d expected_commands=%0d expected_writes=%0d",
            cycle_count,
            EXPECTED_COMMANDS,
            EXPECTED_WRITES
        );
        $fflush();

        wait (irq_o);

        axi_lite_read(REG_STATUS, read_data);
        check(read_data[0] && !read_data[1], "idle after completion");
        check(read_data[2] && !read_data[3], "DONE without ERROR");
        check(read_data[4], "STATUS reflects IRQ");
        axi_lite_read(REG_IRQ_STATUS, read_data);
        check(read_data[0] && !read_data[1], "done IRQ is sticky");
        axi_lite_read(REG_ERROR_CODE, read_data);
        check(read_data == 32'd0, "error code is zero");

        exact_mismatches = 0;
        tolerance_failures = 0;
        max_error_index = 0;
        max_abs_error = 0.0;
        for (initialize_index = 0;
             initialize_index < HIDDEN_WORDS;
             initialize_index = initialize_index + 1) begin
            if (
                u_ddr.scratch_memory[
                    PHASE_E_ADDR_HIDDEN_A + initialize_index
                ] !== golden_output[initialize_index]
            )
                exact_mismatches = exact_mismatches + 1;

            if (
                !fp32_is_finite(
                    u_ddr.scratch_memory[
                        PHASE_E_ADDR_HIDDEN_A + initialize_index
                    ]
                ) ||
                !fp32_is_finite(golden_output[initialize_index])
            ) begin
                tolerance_failures = tolerance_failures + 1;
            end else begin
                rtl_value = fp32_to_real(
                    u_ddr.scratch_memory[
                        PHASE_E_ADDR_HIDDEN_A + initialize_index
                    ]
                );
                golden_value = fp32_to_real(golden_output[initialize_index]);
                absolute_error = rtl_value - golden_value;
                if (absolute_error < 0.0)
                    absolute_error = -absolute_error;
                allowed_error = golden_value;
                if (allowed_error < 0.0)
                    allowed_error = -allowed_error;
                allowed_error =
                    OUTPUT_ABS_TOLERANCE +
                    (OUTPUT_REL_TOLERANCE * allowed_error);
                if (absolute_error > max_abs_error) begin
                    max_abs_error = absolute_error;
                    max_error_index = initialize_index;
                end
                if (absolute_error > allowed_error)
                    tolerance_failures = tolerance_failures + 1;
            end
        end

        $display(
            "E02_LAYER0_REAL_AXI_NUMERIC exact_mismatch=%0d tolerance_failures=%0d max_abs=%0.9e max_index=%0d",
            exact_mismatches,
            tolerance_failures,
            max_abs_error,
            max_error_index
        );
        check(
            tolerance_failures == 0,
            "all 151296 layer-0 outputs match absolute/relative tolerance"
        );

        check(command_count == EXPECTED_COMMANDS, "twenty commands issued");
        check(
            checkpoint_count == EXPECTED_COMMANDS,
            "twenty command checkpoints observed"
        );
        check(
            parameter_request_count == EXPECTED_PARAMETER_REQUESTS,
            "eight parameter-bearing commands observed"
        );
        check(layer_request_count == 1, "one layer-table request observed");
        check(class_result_count == 0, "encoder emits no class result");

        check(
            ddr_write_count == EXPECTED_WRITES,
            "exact encoder-layer scratch write count"
        );
        check(
            scratch_write_count == ddr_write_count,
            "all writes target SCRATCH"
        );
        check(model_read_count > 0, "MODEL was read");
        check(input_read_count == 0, "E02 did not read INPUT");
        check(scratch_read_count > 0, "SCRATCH was read");
        check(
            ddr_read_count == model_read_count + scratch_read_count,
            "every read maps to MODEL or SCRATCH"
        );
        check(invalid_access_count == 0, "no invalid AXI access");
        check(
            u_ddr.model_min_word == EXPECTED_MODEL_MIN,
            "MODEL minimum is layer-0 LN1 gamma"
        );
        check(
            u_ddr.model_max_word == EXPECTED_MODEL_MAX,
            "MODEL maximum is layer-0 FC2 bias end"
        );
        check(
            u_ddr.scratch_min_word == EXPECTED_SCRATCH_MIN,
            "SCRATCH minimum is HIDDEN_A"
        );
        check(
            u_ddr.scratch_max_word == EXPECTED_SCRATCH_MAX,
            "SCRATCH maximum is FC1 end"
        );

        axi_lite_write(REG_IRQ_STATUS, 32'h0000_0001);
        @(posedge aclk);
        check(!irq_o, "RW1C clears done IRQ");
        axi_lite_read(REG_IRQ_STATUS, read_data);
        check(read_data == 32'd0, "IRQ status reads clear");

        if (failures == 0) begin
            $display(
                "VIT_PHASE_E_AXI_E02_LAYER0_REAL_RTL_E2E_PASS checks=%0d cycles=%0d commands=%0d reads=%0d writes=%0d model_reads=%0d scratch_reads=%0d exact_mismatch=%0d max_abs=%0.9e",
                checks,
                cycle_count,
                command_count,
                ddr_read_count,
                ddr_write_count,
                model_read_count,
                scratch_read_count,
                exact_mismatches,
                max_abs_error
            );
            $finish;
        end else begin
            $fatal(
                1,
                "VIT_PHASE_E_AXI_E02_LAYER0_REAL_RTL_E2E_FAIL checks=%0d failures=%0d commands=%0d",
                checks,
                failures,
                command_count
            );
        end
    end

endmodule
