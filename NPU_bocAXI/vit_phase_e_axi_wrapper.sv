`timescale 1ns/1ps

// ViT Phase-E hardware integration top.
//
// S_AXI is the 32-bit software control plane. M_AXI is a correctness-first,
// 32-bit, single-beat AXI4 DDR master. All interfaces and the compute core use
// one clock domain in this first hardware milestone.
//
// AXI-Lite launch configuration:
//   0x000..0x044  identity, control, status, IRQ, DDR bases/word limits
//   0x080..0x09c  global parameter word addresses (8 words)
//   0x0a0         job: [2:0] phase, [6:3] first layer,
//                 [10:7] last layer, [11] class softmax,
//                 [12] checkpoints, [20:13] job tag
//   0x0a4         prepared patch-A input word address
//   0x180/0x184   class index / class logit (read-only)
//   0x400..0x6fc  12 layers * 16 parameter word addresses
//
// Parameter/global/table entries are logical MODEL word offsets. Software must
// use the packed-model offsets, not the old reusable MAIN/AUX staging offsets.
module vit_phase_e_axi_wrapper #(
    parameter integer AXI_ADDR_WIDTH = 40,
    parameter integer AXI_ID_WIDTH   = 1,
    parameter integer ARRAY_ROWS     = 2,
    parameter integer ARRAY_COLS     = 2,
    parameter integer PE_LANES       = 16,
    parameter integer VECTOR_LANES   = 16
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER =
        "XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF S_AXI:M_AXI, ASSOCIATED_RESET aresetn, FREQ_HZ 100000000"
    *)
    input  logic                         aclk,

    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER =
        "XIL_INTERFACENAME aresetn, POLARITY ACTIVE_LOW"
    *)
    input  logic                         aresetn,

    // AXI4-Lite slave control interface.
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
    (* X_INTERFACE_PARAMETER =
        "XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 12, ID_WIDTH 0, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 1, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 0, MAX_BURST_LENGTH 1, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1"
    *)
    input  logic [11:0]                  s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWPROT" *)
    input  logic [2:0]                   s_axi_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
    input  logic                         s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
    output logic                         s_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
    input  logic [31:0]                  s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
    input  logic [3:0]                   s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
    input  logic                         s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
    output logic                         s_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
    output logic [1:0]                   s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
    output logic                         s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
    input  logic                         s_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
    input  logic [11:0]                  s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARPROT" *)
    input  logic [2:0]                   s_axi_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
    input  logic                         s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
    output logic                         s_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
    output logic [31:0]                  s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
    output logic [1:0]                   s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
    output logic                         s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
    input  logic                         s_axi_rready,

    // AXI4 master DDR interface.
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWID" *)
    output logic [AXI_ID_WIDTH-1:0]       m_axi_awid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWADDR" *)
    (* X_INTERFACE_PARAMETER =
        "XIL_INTERFACENAME M_AXI, PROTOCOL AXI4, DATA_WIDTH 32, ADDR_WIDTH 40, ID_WIDTH 1, HAS_BURST 1, HAS_LOCK 1, HAS_PROT 1, HAS_CACHE 1, HAS_QOS 1, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 1, MAX_BURST_LENGTH 1, NUM_READ_OUTSTANDING 1, NUM_WRITE_OUTSTANDING 1"
    *)
    output logic [AXI_ADDR_WIDTH-1:0]     m_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWLEN" *)
    output logic [7:0]                    m_axi_awlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWSIZE" *)
    output logic [2:0]                    m_axi_awsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWBURST" *)
    output logic [1:0]                    m_axi_awburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWLOCK" *)
    output logic                          m_axi_awlock,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWCACHE" *)
    output logic [3:0]                    m_axi_awcache,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWPROT" *)
    output logic [2:0]                    m_axi_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWQOS" *)
    output logic [3:0]                    m_axi_awqos,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWVALID" *)
    output logic                          m_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWREADY" *)
    input  logic                          m_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WDATA" *)
    output logic [31:0]                   m_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WSTRB" *)
    output logic [3:0]                    m_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WLAST" *)
    output logic                          m_axi_wlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WVALID" *)
    output logic                          m_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WREADY" *)
    input  logic                          m_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BID" *)
    input  logic [AXI_ID_WIDTH-1:0]       m_axi_bid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BRESP" *)
    input  logic [1:0]                    m_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BVALID" *)
    input  logic                          m_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BREADY" *)
    output logic                          m_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARID" *)
    output logic [AXI_ID_WIDTH-1:0]       m_axi_arid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARADDR" *)
    output logic [AXI_ADDR_WIDTH-1:0]     m_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARLEN" *)
    output logic [7:0]                    m_axi_arlen,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARSIZE" *)
    output logic [2:0]                    m_axi_arsize,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARBURST" *)
    output logic [1:0]                    m_axi_arburst,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARLOCK" *)
    output logic                          m_axi_arlock,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARCACHE" *)
    output logic [3:0]                    m_axi_arcache,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARPROT" *)
    output logic [2:0]                    m_axi_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARQOS" *)
    output logic [3:0]                    m_axi_arqos,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARVALID" *)
    output logic                          m_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARREADY" *)
    input  logic                          m_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RID" *)
    input  logic [AXI_ID_WIDTH-1:0]       m_axi_rid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RDATA" *)
    input  logic [31:0]                   m_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RRESP" *)
    input  logic [1:0]                    m_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RLAST" *)
    input  logic                          m_axi_rlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RVALID" *)
    input  logic                          m_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RREADY" *)
    output logic                          m_axi_rready,

    (* X_INTERFACE_INFO = "xilinx.com:signal:interrupt:1.0 irq_o INTERRUPT" *)
    (* X_INTERFACE_PARAMETER =
        "XIL_INTERFACENAME irq_o, SENSITIVITY LEVEL_HIGH"
    *)
    output logic                          irq_o
);

    import vit_phase_e_pkg::*;

    localparam logic [31:0] WRAPPER_ERROR_BUSY = 32'h8000_0001;
    localparam logic [31:0] WRAPPER_ERROR_ABORT_UNSUPPORTED =
        32'h8000_0002;

    logic start_pulse;
    logic soft_reset_pulse;
    logic abort_pulse;
    logic clear_error_pulse;
    logic [31:0] irq_enable;
    logic [31:0] irq_status;

    logic [63:0] model_base_cfg;
    logic [63:0] input_base_cfg;
    logic [63:0] scratch_base_cfg;
    logic [31:0] model_words_cfg;
    logic [31:0] input_words_cfg;
    logic [31:0] scratch_words_cfg;
    logic [31:0] execution_mode;
    logic [8*32-1:0] global_params_flat;
    logic [31:0] job_config;
    logic [31:0] job_patch_a_base;
    logic [12*16*32-1:0] layer_params_flat;

    logic [63:0] model_base_active;
    logic [63:0] input_base_active;
    logic [63:0] scratch_base_active;
    logic [31:0] model_words_active;
    logic [31:0] input_words_active;
    logic [31:0] scratch_words_active;
    logic [8*32-1:0] global_params_active_flat;
    logic [12*16*32-1:0] layer_params_active_flat;
    phase_e_job_t job_cfg_value;
    phase_e_job_t job_active;
    phase_e_global_params_t global_params_active;
    phase_e_layer_params_t layer_param_data;

    logic job_pending;
    logic job_ready;
    logic npu_busy;
    logic npu_done;
    logic npu_error;
    phase_e_error_t npu_error_code;
    phase_e_section_t npu_error_section;
    logic [3:0] npu_error_layer;
    logic [4:0] npu_error_step;

    logic done_sticky;
    logic error_sticky;
    logic [31:0] error_code_sticky;
    logic [31:0] error_info_sticky;
    logic launch_reject_pulse;
    logic local_reset_pulse;
    logic compute_rst;
    logic adapter_aresetn;
    logic wrapper_busy;

    logic layer_param_request;
    logic [3:0] layer_param_index;
    logic checkpoint_valid;
    phase_e_phase_t checkpoint_phase;
    phase_e_section_t checkpoint_section;
    logic [3:0] checkpoint_layer;
    logic [4:0] checkpoint_step;
    logic [7:0] checkpoint_tag;
    phase_e_opcode_t checkpoint_opcode;
    phase_e_tensor_id_t checkpoint_dst_tensor;
    logic operand_load_request;
    phase_e_cmd_t operand_load_command;

    logic class_result_valid;
    logic [31:0] class_index;
    logic [31:0] class_logit;

    logic mem_req_valid;
    logic mem_req_ready;
    logic mem_req_write;
    phase_e_mem_space_t mem_req_space;
    logic [31:0] mem_req_word_address;
    logic [31:0] mem_req_write_data;
    logic [3:0] mem_req_write_strobe;
    logic mem_rsp_valid;
    logic mem_rsp_ready;
    logic [31:0] mem_rsp_read_data;
    logic mem_rsp_error;

    logic [31:0] irq_events;
    integer layer_word_base;

    assign wrapper_busy = job_pending || npu_busy;
    assign compute_rst = !aresetn || local_reset_pulse;
    assign adapter_aresetn = aresetn && !local_reset_pulse;
    // npu_error is sticky inside the sequencer until the next job is
    // accepted. Qualify it with the one-cycle SEQ_DONE indication so IRQ
    // RW1C and CONTROL.CLEAR_ERROR remain effective while idle.
    assign irq_events = {
        30'b0,
        (npu_done && npu_error) || launch_reject_pulse,
        npu_done && !npu_error
    };

    // Job configuration is deliberately explicit so the software-visible
    // bitfield is independent of packed-struct declaration ordering.
    always_comb begin
        job_cfg_value = '0;
        job_cfg_value.phase =
            phase_e_phase_t'(job_config[2:0]);
        job_cfg_value.first_layer = job_config[6:3];
        job_cfg_value.last_layer = job_config[10:7];
        job_cfg_value.class_softmax_enable = job_config[11];
        job_cfg_value.checkpoint_enable = job_config[12];
        job_cfg_value.job_tag = job_config[20:13];
        job_cfg_value.patch_a_base = job_patch_a_base;
    end

    always_comb begin
        global_params_active = '0;
        global_params_active.patch_weight_base =
            global_params_active_flat[0*32 +: 32];
        global_params_active.patch_bias_base =
            global_params_active_flat[1*32 +: 32];
        global_params_active.cls_base =
            global_params_active_flat[2*32 +: 32];
        global_params_active.position_base =
            global_params_active_flat[3*32 +: 32];
        global_params_active.final_ln_gamma_base =
            global_params_active_flat[4*32 +: 32];
        global_params_active.final_ln_beta_base =
            global_params_active_flat[5*32 +: 32];
        global_params_active.classifier_weight_base =
            global_params_active_flat[6*32 +: 32];
        global_params_active.classifier_bias_base =
            global_params_active_flat[7*32 +: 32];
    end

    // The register bank stores word zero in the least-significant slice.
    // Explicit field mapping avoids relying on packed-struct bit ordering.
    always_comb begin
        layer_param_data = '0;
        layer_word_base = layer_param_index * 16;
        if (layer_param_index < 12) begin
            layer_param_data.ln1_gamma_base =
                layer_params_active_flat[(layer_word_base+0)*32 +: 32];
            layer_param_data.ln1_beta_base =
                layer_params_active_flat[(layer_word_base+1)*32 +: 32];
            layer_param_data.q_weight_base =
                layer_params_active_flat[(layer_word_base+2)*32 +: 32];
            layer_param_data.q_bias_base =
                layer_params_active_flat[(layer_word_base+3)*32 +: 32];
            layer_param_data.k_weight_base =
                layer_params_active_flat[(layer_word_base+4)*32 +: 32];
            layer_param_data.k_bias_base =
                layer_params_active_flat[(layer_word_base+5)*32 +: 32];
            layer_param_data.v_weight_base =
                layer_params_active_flat[(layer_word_base+6)*32 +: 32];
            layer_param_data.v_bias_base =
                layer_params_active_flat[(layer_word_base+7)*32 +: 32];
            layer_param_data.o_weight_base =
                layer_params_active_flat[(layer_word_base+8)*32 +: 32];
            layer_param_data.o_bias_base =
                layer_params_active_flat[(layer_word_base+9)*32 +: 32];
            layer_param_data.ln2_gamma_base =
                layer_params_active_flat[(layer_word_base+10)*32 +: 32];
            layer_param_data.ln2_beta_base =
                layer_params_active_flat[(layer_word_base+11)*32 +: 32];
            layer_param_data.fc1_weight_base =
                layer_params_active_flat[(layer_word_base+12)*32 +: 32];
            layer_param_data.fc1_bias_base =
                layer_params_active_flat[(layer_word_base+13)*32 +: 32];
            layer_param_data.fc2_weight_base =
                layer_params_active_flat[(layer_word_base+14)*32 +: 32];
            layer_param_data.fc2_bias_base =
                layer_params_active_flat[(layer_word_base+15)*32 +: 32];
        end
    end

    // START snapshots every configuration bus used during the run. Software
    // may prepare the next job only after STATUS.IDLE returns high.
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            job_pending <= 1'b0;
            job_active <= '0;
            global_params_active_flat <= '0;
            layer_params_active_flat <= '0;
            model_base_active <= 64'd0;
            input_base_active <= 64'd0;
            scratch_base_active <= 64'd0;
            model_words_active <= 32'd0;
            input_words_active <= 32'd0;
            scratch_words_active <= 32'd0;
            done_sticky <= 1'b0;
            error_sticky <= 1'b0;
            error_code_sticky <= 32'd0;
            error_info_sticky <= 32'd0;
            launch_reject_pulse <= 1'b0;
            local_reset_pulse <= 1'b0;
        end else begin
            launch_reject_pulse <= 1'b0;
            local_reset_pulse <= 1'b0;

            if (clear_error_pulse) begin
                error_sticky <= 1'b0;
                error_code_sticky <= 32'd0;
                error_info_sticky <= 32'd0;
            end

            if (start_pulse) begin
                if (!wrapper_busy) begin
                    job_active <= job_cfg_value;
                    global_params_active_flat <= global_params_flat;
                    layer_params_active_flat <= layer_params_flat;
                    model_base_active <= model_base_cfg;
                    input_base_active <= input_base_cfg;
                    scratch_base_active <= scratch_base_cfg;
                    model_words_active <= model_words_cfg;
                    input_words_active <= input_words_cfg;
                    scratch_words_active <= scratch_words_cfg;
                    job_pending <= 1'b1;
                    done_sticky <= 1'b0;
                    error_sticky <= 1'b0;
                    error_code_sticky <= 32'd0;
                    error_info_sticky <= 32'd0;
                end else begin
                    launch_reject_pulse <= 1'b1;
                    error_sticky <= 1'b1;
                    error_code_sticky <= WRAPPER_ERROR_BUSY;
                    error_info_sticky <= 32'd0;
                end
            end

            if (job_pending && job_ready)
                job_pending <= 1'b0;

            if (npu_done) begin
                if (npu_error) begin
                    error_sticky <= 1'b1;
                    error_code_sticky <= {29'd0, npu_error_code};
                    error_info_sticky <= {
                        19'd0,
                        npu_error_section,
                        npu_error_layer,
                        npu_error_step,
                        2'd0
                    };
                end else begin
                    done_sticky <= 1'b1;
                end
            end

            // Dropping reset during an accepted AXI transaction is unsafe.
            // Therefore software reset is accepted only while fully idle.
            if (soft_reset_pulse) begin
                if (!wrapper_busy) begin
                    local_reset_pulse <= 1'b1;
                    job_pending <= 1'b0;
                    done_sticky <= 1'b0;
                    error_sticky <= 1'b0;
                    error_code_sticky <= 32'd0;
                    error_info_sticky <= 32'd0;
                end else begin
                    launch_reject_pulse <= 1'b1;
                    error_sticky <= 1'b1;
                    error_code_sticky <= WRAPPER_ERROR_BUSY;
                end
            end

            // The scalar adapter cannot safely cancel a transaction already
            // accepted by DDR. Abort reports an explicit error instead.
            if (abort_pulse) begin
                launch_reject_pulse <= 1'b1;
                error_sticky <= 1'b1;
                error_code_sticky <= WRAPPER_ERROR_ABORT_UNSUPPORTED;
            end
        end
    end

    vit_axi_lite_control_regs #(
        .AXI_ADDR_WIDTH(12)
    ) u_control (
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
        .start_pulse_o(start_pulse),
        .soft_reset_pulse_o(soft_reset_pulse),
        .abort_pulse_o(abort_pulse),
        .clear_error_pulse_o(clear_error_pulse),
        .status_idle_i(!wrapper_busy),
        .status_busy_i(wrapper_busy),
        .status_done_i(done_sticky),
        .status_error_i(error_sticky),
        .status_fallback_wait_i(operand_load_request),
        .error_code_i(error_code_sticky),
        .error_info_i(error_info_sticky),
        .irq_events_i(irq_events),
        .irq_enable_o(irq_enable),
        .irq_status_o(irq_status),
        .irq_o(irq_o),
        .model_base_o(model_base_cfg),
        .input_base_o(input_base_cfg),
        .scratch_base_o(scratch_base_cfg),
        .model_words_o(model_words_cfg),
        .input_words_o(input_words_cfg),
        .scratch_words_o(scratch_words_cfg),
        .execution_mode_o(execution_mode),
        .global_params_flat_o(global_params_flat),
        .job_config_o(job_config),
        .job_patch_a_base_o(job_patch_a_base),
        .layer_params_flat_o(layer_params_flat),
        .class_index_i(class_index),
        .class_logit_i(class_logit)
    );

    vit_phase_e_npu #(
        .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .PE_LANES(PE_LANES),
        .VECTOR_LANES(VECTOR_LANES)
    ) u_npu (
        .clk(aclk),
        .rst(compute_rst),
        .job_valid(job_pending),
        .job_ready(job_ready),
        .job(job_active),
        .global_params(global_params_active),
        .layer_param_request(layer_param_request),
        .layer_param_index(layer_param_index),
        .layer_param_valid(layer_param_request &&
                           (layer_param_index < 12)),
        .layer_param_data(layer_param_data),
        .operand_load_request(operand_load_request),
        .operand_load_ready(1'b1),
        .operand_load_command(operand_load_command),
        .checkpoint_valid(checkpoint_valid),
        .checkpoint_ready(1'b1),
        .checkpoint_phase(checkpoint_phase),
        .checkpoint_section(checkpoint_section),
        .checkpoint_layer(checkpoint_layer),
        .checkpoint_step(checkpoint_step),
        .checkpoint_tag(checkpoint_tag),
        .checkpoint_opcode(checkpoint_opcode),
        .checkpoint_dst_tensor(checkpoint_dst_tensor),
        .busy(npu_busy),
        .done(npu_done),
        .error(npu_error),
        .error_code(npu_error_code),
        .error_section(npu_error_section),
        .error_layer(npu_error_layer),
        .error_step(npu_error_step),
        .input_write_enable(1'b0),
        .input_write_address(32'd0),
        .input_write_data(32'd0),
        .parameter_write_enable(1'b0),
        .parameter_write_address(32'd0),
        .parameter_write_data(32'd0),
        .scratch_write_enable(1'b0),
        .scratch_write_address(32'd0),
        .scratch_write_data(32'd0),
        .scratch_read_address(32'd0),
        .scratch_read_data(),
        .mem_req_valid(mem_req_valid),
        .mem_req_ready(mem_req_ready),
        .mem_req_write(mem_req_write),
        .mem_req_space(mem_req_space),
        .mem_req_word_address(mem_req_word_address),
        .mem_req_write_data(mem_req_write_data),
        .mem_req_write_strobe(mem_req_write_strobe),
        .mem_rsp_valid(mem_rsp_valid),
        .mem_rsp_ready(mem_rsp_ready),
        .mem_rsp_read_data(mem_rsp_read_data),
        .mem_rsp_error(mem_rsp_error),
        .class_result_valid(class_result_valid),
        .class_index(class_index),
        .class_logit(class_logit)
    );

    vit_phase_e_axi_mem_adapter #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH)
    ) u_mem_adapter (
        .aclk(aclk),
        .aresetn(adapter_aresetn),
        .scratch_base_i(scratch_base_active),
        .model_base_i(model_base_active),
        .input_base_i(input_base_active),
        .scratch_words_i(scratch_words_active),
        .model_words_i(model_words_active),
        .input_words_i(input_words_active),
        .req_valid(mem_req_valid),
        .req_ready(mem_req_ready),
        .req_write(mem_req_write),
        .req_space(mem_req_space),
        .req_word_address(mem_req_word_address),
        .req_write_data(mem_req_write_data),
        .req_write_strobe(mem_req_write_strobe),
        .rsp_valid(mem_rsp_valid),
        .rsp_ready(mem_rsp_ready),
        .rsp_read_data(mem_rsp_read_data),
        .rsp_error(mem_rsp_error),
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
        .m_axi_rready(m_axi_rready)
    );

    // These are visible in hierarchy for debug and intentionally otherwise
    // unused in the first wrapper.
    logic unused_status;
    assign unused_status = irq_enable[0] ^ irq_status[0] ^
                           execution_mode[0] ^ class_result_valid ^
                           checkpoint_valid ^ checkpoint_phase[0] ^
                           checkpoint_section[0] ^ checkpoint_layer[0] ^
                           checkpoint_step[0] ^ checkpoint_tag[0] ^
                           checkpoint_opcode[0] ^
                           checkpoint_dst_tensor[0] ^
                           operand_load_command.header.opcode[0];

endmodule
