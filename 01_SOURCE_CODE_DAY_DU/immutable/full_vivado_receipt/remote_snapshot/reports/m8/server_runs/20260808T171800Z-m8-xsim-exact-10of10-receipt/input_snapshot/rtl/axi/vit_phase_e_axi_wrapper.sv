`timescale 1ns/1ps

// ViT Phase-E hardware integration top.
//
// S_AXI remains the frozen 32-bit software control plane.  M5 changes only
// the DDR data plane to a native 128-bit AXI4 master with bounded INCR bursts
// and two same-ID outstanding blocked-B reads.  Narrow single-beat accesses
// preserve the scalar fallback and write commit semantics.
//
// AXI-Lite launch configuration:
//   0x000..0x044  identity, control, status, IRQ, DDR bases/word limits
//   0x048..0x074  atomic per-job 64-bit performance snapshot
//   0x080..0x09c  global parameter word addresses (8 words)
//   0x0a0         job: [2:0] phase, [6:3] first layer,
//                 [10:7] last layer, [11] class softmax,
//                 [12] checkpoints, [20:13] job tag
//   0x0a4         prepared patch-A input word address
//   0x180/0x184   class index / class logit (read-only)
//   0x188..0x3fc  append-only profile ABI v1.2 counters
//   0x400..0x6fc  12 layers * 16 parameter word addresses
//   0x700..0x7b4  command trace and response-wait histograms
//
// Parameter/global/table entries are logical MODEL word offsets. Software must
// use the packed-model offsets, not the old reusable MAIN/AUX staging offsets.
module vit_phase_e_axi_wrapper #(
    parameter integer AXI_ADDR_WIDTH = 40,
    parameter integer AXI_ID_WIDTH   = 1,
    parameter integer ARRAY_ROWS     = 2,
    parameter integer ARRAY_COLS     = 2,
    parameter integer PE_LANES       = 16,
    parameter integer FP16_STREAMS   = 8,
    parameter integer VECTOR_LANES   = 16,
    // Simulation may override the E05 tensor shape while the defaults remain
    // the production ViT-Base/16-224 configuration.
    parameter logic [31:0] E05_PATCH_COUNT =
        vit_phase_e_pkg::VIT_PATCH_COUNT,
    parameter logic [31:0] E05_TOKEN_COUNT =
        vit_phase_e_pkg::VIT_TOKEN_COUNT,
    parameter logic [31:0] E05_HIDDEN_SIZE =
        vit_phase_e_pkg::VIT_HIDDEN_SIZE,
    parameter logic [31:0] E05_HEAD_COUNT =
        vit_phase_e_pkg::VIT_HEAD_COUNT,
    parameter logic [31:0] E05_HEAD_SIZE =
        vit_phase_e_pkg::VIT_HEAD_SIZE,
    parameter logic [31:0] E05_INTERMEDIATE_SIZE =
        vit_phase_e_pkg::VIT_INTERMEDIATE_SIZE,
    parameter logic [31:0] E05_CLASS_COUNT =
        vit_phase_e_pkg::VIT_CLASS_COUNT,
    parameter logic [3:0] E05_ENCODER_LAYERS =
        vit_phase_e_pkg::VIT_ENCODER_LAYERS[3:0],
    parameter logic [31:0] E05_ATTN_SCALE_FP32 =
        vit_phase_e_pkg::VIT_ATTN_SCALE_FP32
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER =
        "XIL_INTERFACENAME aclk, ASSOCIATED_BUSIF S_AXI:M_AXI, ASSOCIATED_RESET aresetn, FREQ_HZ 50000000"
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
        "XIL_INTERFACENAME M_AXI, PROTOCOL AXI4, DATA_WIDTH 128, ADDR_WIDTH 40, ID_WIDTH 1, HAS_BURST 1, HAS_LOCK 1, HAS_PROT 1, HAS_CACHE 1, HAS_QOS 1, HAS_REGION 0, HAS_WSTRB 1, HAS_BRESP 1, HAS_RRESP 1, SUPPORTS_NARROW_BURST 1, MAX_BURST_LENGTH 4, NUM_READ_OUTSTANDING 2, NUM_WRITE_OUTSTANDING 1"
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
    output logic [127:0]                  m_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WSTRB" *)
    output logic [15:0]                   m_axi_wstrb,
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
    input  logic [127:0]                  m_axi_rdata,
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
    localparam logic [31:0] WRAPPER_ERROR_EXECUTION_MODE =
        32'h8000_0003;
    localparam logic [31:0] WRAPPER_ERROR_MODEL_ALIGNMENT =
        32'h8000_0004;
    localparam logic [31:0] WRAPPER_ERROR_RESET_REQUIRED =
        32'h8000_0005;

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
    logic execution_mode_legal;
    logic packed_model_alignment_legal;
    logic [8*32-1:0] global_params_flat;
    logic [31:0] job_config;
    logic [31:0] job_patch_a_base;

    logic layer_table_a_en;
    logic [7:0] layer_table_a_addr;
    logic [3:0] layer_table_a_we;
    logic [31:0] layer_table_a_wdata;
    logic layer_table_a_rvalid;
    logic [31:0] layer_table_a_rdata;
    logic layer_table_b_en;
    logic [7:0] layer_table_b_addr;
    logic layer_table_b_rvalid;
    logic [31:0] layer_table_b_rdata;
    logic layer_loader_ram_valid;
    logic layer_param_valid;
    logic [16*32-1:0] layer_param_packed;

    logic [63:0] model_base_active;
    logic [63:0] input_base_active;
    logic [63:0] scratch_base_active;
    logic [31:0] model_words_active;
    logic [31:0] input_words_active;
    logic [31:0] scratch_words_active;
    logic [8*32-1:0] global_params_active_flat;
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
    logic recovery_required_q;
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
    logic mem_req_read_ahead_safe;
    logic [5:0] mem_req_contiguous_words;
    logic mem_rsp_valid;
    logic mem_rsp_ready;
    logic [31:0] mem_rsp_read_data;
    logic mem_rsp_error;

    logic adapter_axi_r_protocol_error;
    logic adapter_axi_b_protocol_error;
    logic adapter_linefill_start;
    logic adapter_linefill_hit;
    logic adapter_full_r_beat;
    logic adapter_narrow_r_beat;
    logic adapter_four_k_split;
    logic [5:0] adapter_prefetched_words_discarded;
    logic [1:0] adapter_read_outstanding;

    logic m5_axi_running;
    logic m5_axi_snapshot_valid;
    logic [31:0] m5_axi_capability;
    logic [31:0] m5_axi_status;
    logic [15:0] m5_axi_overflow;
    logic [7:0] m5_axi_protocol_status;
    logic [8*64-1:0] m5_axi_counters_flat;
    logic [7:0] m5_axi_protocol_events;
    logic m7_profile_running;
    logic m7_profile_snapshot_valid;
    logic [31:0] m7_profile_capability;
    logic [31:0] m7_profile_status;
    logic [63:0] m7_profile_overflow;
    logic [31:0] m7_profile_error;
    logic [31:0] m7_profile_geometry;
    logic [31:0] m7_profile_buffer_config;
    logic [31:0] m7_profile_numeric_config;
    logic [PHASE_E_M7_COUNTER_COUNT*64-1:0]
        m7_profile_counters_flat;

    logic [31:0] irq_events;

    logic npu_command_accept;
    phase_e_profile_core_events_t npu_profile_events;
    phase_e_m7_profile_events_t npu_m7_profile_events;
    logic perf_start_accept;
    logic perf_axi_read_accept;
    logic perf_axi_write_accept;
    logic perf_axi_request_stall;
    logic perf_running;
    logic perf_snapshot_valid;
    logic [63:0] perf_job_cycles;
    logic [63:0] perf_command_count;
    logic [63:0] perf_axi_read_count;
    logic [63:0] perf_axi_write_count;
    logic [63:0] perf_axi_stall_cycles;

    logic profile_running;
    logic profile_snapshot_valid;
    logic [PHASE_E_PROFILE_GLOBAL_COUNT*64-1:0]
        profile_global_counters_flat;
    logic [PHASE_E_PROFILE_OPCODE_SLOTS*64-1:0]
        profile_opcode_counts_flat;
    logic [PHASE_E_PROFILE_OPCODE_SLOTS*64-1:0]
        profile_opcode_cycles_flat;
    logic [63:0] profile_global_overflow;
    logic [15:0] profile_opcode_count_overflow;
    logic [15:0] profile_opcode_cycle_overflow;
    logic [31:0] profile_error_status;
    logic [8:0] profile_trace_count;
    logic profile_trace_truncated;
    logic profile_trace_selected_valid;
    logic profile_trace_read_pending;
    logic [31:0] profile_trace_selected_meta;
    logic [63:0] profile_trace_selected_cycles;
    logic [PHASE_E_PROFILE_HIST_COUNT*64-1:0]
        profile_histogram_counters_flat;
    logic [17:0] profile_histogram_overflow;
    logic profile_trace_select_strobe;
    logic [7:0] profile_trace_select;

    assign wrapper_busy = job_pending || npu_busy;
    assign compute_rst = !aresetn || local_reset_pulse;
    assign adapter_aresetn = aresetn && !local_reset_pulse;
    // This board specialization deliberately instantiates only the FP16 GEMM
    // datapath.  START therefore admits exactly the two encodings whose job
    // snapshots enable FP16 compute:
    //   3: blocked-v3 packed-FP16 persistent B + FP16 GEMM compute
    //   5: blocked-v2 FP32 storage + FP16 compute compatibility A/B
    // The register remains a full-width read/write field for ABI continuity,
    // but modes 0/1 (the removed FP32 compute paths), mode 2, and every other
    // encoding fail closed at START with WRAPPER_ERROR_EXECUTION_MODE.
    assign execution_mode_legal =
        (execution_mode == 32'd3) ||
        (execution_mode == 32'd5);
    // Package-v3 tensor starts are 128-byte aligned.  The table/hash identity
    // remains a host-side preflight responsibility, but hardware rejects a
    // mode-3 launch whose configured physical model base cannot preserve that
    // contract.
    assign packed_model_alignment_legal =
        (execution_mode != 32'd3) || (model_base_cfg[6:0] == 7'd0);
    assign perf_start_accept =
        start_pulse && !wrapper_busy && !recovery_required_q &&
        execution_mode_legal && packed_model_alignment_legal;
    assign perf_axi_read_accept = m_axi_arvalid && m_axi_arready;
    assign perf_axi_write_accept = m_axi_awvalid && m_axi_awready;
    assign perf_axi_request_stall =
        (m_axi_arvalid && !m_axi_arready) ||
        (m_axi_awvalid && !m_axi_awready) ||
        (m_axi_wvalid && !m_axi_wready);
    assign m5_axi_protocol_events = {
        6'd0,
        adapter_axi_b_protocol_error,
        adapter_axi_r_protocol_error
    };
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
        job_cfg_value.model_b_blocked_k16_n2 = execution_mode[0];
        job_cfg_value.model_b_fp16_packed2 = execution_mode[1];
        job_cfg_value.fp16_gemm_compat_enable =
            execution_mode[1] || execution_mode[2];
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

    // START snapshots the launch, global and memory configuration buses used
    // during the run.  The block-RAM layer table remains live and is
    // write-locked by u_control until STATUS.IDLE returns high.
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            job_pending <= 1'b0;
            job_active <= '0;
            global_params_active_flat <= '0;
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
            recovery_required_q <= 1'b0;
        end else begin
            launch_reject_pulse <= 1'b0;
            local_reset_pulse <= 1'b0;

            if (clear_error_pulse) begin
                error_sticky <= 1'b0;
                error_code_sticky <= 32'd0;
                error_info_sticky <= 32'd0;
            end

            if (start_pulse) begin
                if (!wrapper_busy && !recovery_required_q &&
                    execution_mode_legal &&
                    packed_model_alignment_legal) begin
                    job_active <= job_cfg_value;
                    global_params_active_flat <= global_params_flat;
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
                end else if (wrapper_busy) begin
                    launch_reject_pulse <= 1'b1;
                    error_sticky <= 1'b1;
                    error_code_sticky <= WRAPPER_ERROR_BUSY;
                    error_info_sticky <= 32'd0;
                end else if (recovery_required_q) begin
                    // A terminal NPU error can leave an accepted AXI response
                    // behind the logical-memory consumer.  Keep new jobs from
                    // observing that response until SOFT_RESET has reset both
                    // the compute hierarchy and the AXI adapter queues.
                    launch_reject_pulse <= 1'b1;
                    error_sticky <= 1'b1;
                    error_code_sticky <= WRAPPER_ERROR_RESET_REQUIRED;
                    error_info_sticky <= 32'd0;
                end else if (!execution_mode_legal) begin
                    launch_reject_pulse <= 1'b1;
                    error_sticky <= 1'b1;
                    error_code_sticky <= WRAPPER_ERROR_EXECUTION_MODE;
                    error_info_sticky <= execution_mode;
                end else begin
                    launch_reject_pulse <= 1'b1;
                    error_sticky <= 1'b1;
                    error_code_sticky <= WRAPPER_ERROR_MODEL_ALIGNMENT;
                    error_info_sticky <= model_base_cfg[31:0];
                end
            end

            if (job_pending && job_ready)
                job_pending <= 1'b0;

            if (npu_done) begin
                if (npu_error) begin
                    recovery_required_q <= 1'b1;
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
                    recovery_required_q <= 1'b0;
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

    vit_phase_e_perf_counters u_perf_counters (
        .clk                        (aclk),
        .rst                        (compute_rst),
        .start_accept_i             (perf_start_accept),
        .done_i                     (npu_done),
        .command_accept_i           (npu_command_accept),
        .axi_read_accept_i          (perf_axi_read_accept),
        .axi_write_accept_i         (perf_axi_write_accept),
        .axi_request_stall_i        (perf_axi_request_stall),
        .running_o                  (perf_running),
        .snapshot_valid_o           (perf_snapshot_valid),
        .job_cycles_o               (perf_job_cycles),
        .command_count_o            (perf_command_count),
        .axi_read_count_o           (perf_axi_read_count),
        .axi_write_count_o          (perf_axi_write_count),
        .axi_request_stall_cycles_o (perf_axi_stall_cycles)
    );

    // ABI v1.2 profiling is intentionally a second block.  The original
    // five-counter instance and its addresses remain bit-for-bit compatible
    // with v1.1, while this append-only bank observes the same job boundary
    // plus the finer-grained core, logical-memory and AXI handshakes.
    vit_phase_e_profile_counters u_profile_counters (
        .clk                             (aclk),
        .rst                             (compute_rst),
        .start_accept_i                  (perf_start_accept),
        .done_i                          (npu_done),
        .core_events_i                   (npu_profile_events),
        .m7_a_vector_hit_word_delta_i    (
            npu_m7_profile_events.m7_a_vector_hit_word_delta
        ),
        .legacy_axi_read_accept_i        (perf_axi_read_accept),
        .legacy_axi_write_accept_i       (perf_axi_write_accept),
        .legacy_axi_request_stall_i      (perf_axi_request_stall),
        .logical_request_backpressure_i  (mem_req_valid && !mem_req_ready),
        .logical_response_backpressure_i (mem_rsp_valid && !mem_rsp_ready),
        .logical_read_response_wait_i    (
            npu_profile_events.load_active &&
            mem_rsp_ready && !mem_rsp_valid
        ),
        .logical_write_response_wait_i   (
            npu_profile_events.store_active &&
            mem_rsp_ready && !mem_rsp_valid
        ),
        .logical_response_error_i        (
            mem_rsp_valid && mem_rsp_ready && mem_rsp_error
        ),
        .job_error_i                     (npu_done && npu_error),
        .axi_r_beat_i                    (m_axi_rvalid && m_axi_rready),
        .axi_r_last_i                    (m_axi_rlast),
        .axi_w_beat_i                    (m_axi_wvalid && m_axi_wready),
        .axi_b_response_i                (m_axi_bvalid && m_axi_bready),
        .axi_ar_backpressure_i           (m_axi_arvalid && !m_axi_arready),
        .axi_aw_backpressure_i           (m_axi_awvalid && !m_axi_awready),
        .axi_w_backpressure_i            (m_axi_wvalid && !m_axi_wready),
        .axi_r_response_wait_i           (m_axi_rready && !m_axi_rvalid),
        .axi_b_response_wait_i           (m_axi_bready && !m_axi_bvalid),
        .axi_r_response_backpressure_i   (m_axi_rvalid && !m_axi_rready),
        .axi_b_response_backpressure_i   (m_axi_bvalid && !m_axi_bready),
        .axi_r_error_i                   (adapter_axi_r_protocol_error),
        .axi_b_error_i                   (adapter_axi_b_protocol_error),
        .trace_select_strobe_i           (profile_trace_select_strobe),
        .trace_select_i                  (profile_trace_select),
        .profile_running_o               (profile_running),
        .profile_snapshot_valid_o        (profile_snapshot_valid),
        .global_counters_flat_o          (profile_global_counters_flat),
        .opcode_counts_flat_o            (profile_opcode_counts_flat),
        .opcode_cycles_flat_o            (profile_opcode_cycles_flat),
        .global_overflow_o               (profile_global_overflow),
        .opcode_count_overflow_o         (profile_opcode_count_overflow),
        .opcode_cycle_overflow_o         (profile_opcode_cycle_overflow),
        .error_status_o                  (profile_error_status),
        .trace_count_o                   (profile_trace_count),
        .trace_truncated_o               (profile_trace_truncated),
        .trace_selected_valid_o          (profile_trace_selected_valid),
        .trace_read_pending_o            (profile_trace_read_pending),
        .trace_selected_meta_o           (profile_trace_selected_meta),
        .trace_selected_cycles_o         (profile_trace_selected_cycles),
        .histogram_counters_flat_o       (
            profile_histogram_counters_flat
        ),
        .histogram_overflow_o            (profile_histogram_overflow)
    );

    vit_phase_e_m5_axi_counters u_m5_axi_counters (
        .clk                          (aclk),
        .rst                          (compute_rst),
        .start_accept_i               (perf_start_accept),
        .done_i                       (npu_done),
        .full_r_beat_i                (adapter_full_r_beat),
        .narrow_r_beat_i              (adapter_narrow_r_beat),
        .linefill_start_i             (adapter_linefill_start),
        .linefill_hit_i               (adapter_linefill_hit),
        .four_k_split_i               (adapter_four_k_split),
        .read_outstanding_i           (adapter_read_outstanding),
        .protocol_error_i             (m5_axi_protocol_events),
        .prefetched_words_discarded_i (
            adapter_prefetched_words_discarded
        ),
        .running_o                    (m5_axi_running),
        .snapshot_valid_o             (m5_axi_snapshot_valid),
        .capability_o                 (m5_axi_capability),
        .status_o                     (m5_axi_status),
        .overflow_o                   (m5_axi_overflow),
        .protocol_error_status_o      (m5_axi_protocol_status),
        .counters_flat_o              (m5_axi_counters_flat)
    );

    vit_phase_e_m7_overlap_counters #(
        .ARRAY_ROWS       (ARRAY_ROWS),
        .ARRAY_COLS       (ARRAY_COLS),
        .PE_LANES         (PE_LANES),
        .STREAMS          (FP16_STREAMS),
        .OPERAND_BANKS    (2),
        .RESULT_FIFO_DEPTH(2),
        .GENERATION_BITS  (8)
    ) u_m7_overlap_counters (
        .clk               (aclk),
        .rst               (compute_rst),
        .start_accept_i    (perf_start_accept),
        .done_i            (npu_done),
        .events_i          (npu_m7_profile_events),
        .running_o         (m7_profile_running),
        .snapshot_valid_o  (m7_profile_snapshot_valid),
        .capability_o      (m7_profile_capability),
        .status_o          (m7_profile_status),
        .overflow_o        (m7_profile_overflow),
        .error_status_o    (m7_profile_error),
        .geometry_o        (m7_profile_geometry),
        .buffer_config_o   (m7_profile_buffer_config),
        .numeric_config_o  (m7_profile_numeric_config),
        .counters_flat_o   (m7_profile_counters_flat)
    );

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
        .config_busy_i(wrapper_busy),
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
        .layer_table_en_o(layer_table_a_en),
        .layer_table_addr_o(layer_table_a_addr),
        .layer_table_we_o(layer_table_a_we),
        .layer_table_wdata_o(layer_table_a_wdata),
        .layer_table_rvalid_i(layer_table_a_rvalid),
        .layer_table_rdata_i(layer_table_a_rdata),
        .class_index_i(class_index),
        .class_logit_i(class_logit),
        .perf_running_i(perf_running),
        .perf_snapshot_valid_i(perf_snapshot_valid),
        .perf_job_cycles_i(perf_job_cycles),
        .perf_command_count_i(perf_command_count),
        .perf_axi_read_count_i(perf_axi_read_count),
        .perf_axi_write_count_i(perf_axi_write_count),
        .perf_axi_stall_cycles_i(perf_axi_stall_cycles),
        .profile_running_i(profile_running),
        .profile_snapshot_valid_i(profile_snapshot_valid),
        .profile_global_counters_i(profile_global_counters_flat),
        .profile_opcode_counts_i(profile_opcode_counts_flat),
        .profile_opcode_cycles_i(profile_opcode_cycles_flat),
        .profile_global_overflow_i(profile_global_overflow),
        .profile_opcode_count_overflow_i(
            profile_opcode_count_overflow
        ),
        .profile_opcode_cycle_overflow_i(
            profile_opcode_cycle_overflow
        ),
        .profile_error_status_i(profile_error_status),
        .profile_trace_count_i(profile_trace_count),
        .profile_trace_truncated_i(profile_trace_truncated),
        .profile_trace_selected_valid_i(
            profile_trace_selected_valid
        ),
        .profile_trace_read_pending_i(profile_trace_read_pending),
        .profile_trace_meta_i(profile_trace_selected_meta),
        .profile_trace_cycles_i(profile_trace_selected_cycles),
        .profile_hist_counters_i(profile_histogram_counters_flat),
        .profile_hist_overflow_i(profile_histogram_overflow),
        .m5_axi_capability_i(m5_axi_capability),
        .m5_axi_status_i(m5_axi_status),
        .m5_axi_overflow_i(m5_axi_overflow),
        .m5_axi_protocol_status_i(m5_axi_protocol_status),
        .m5_axi_counters_i(m5_axi_counters_flat),
        .m7_capability_i(m7_profile_capability),
        .m7_status_i(m7_profile_status),
        .m7_overflow_i(m7_profile_overflow),
        .m7_error_i(m7_profile_error),
        .m7_geometry_i(m7_profile_geometry),
        .m7_buffer_config_i(m7_profile_buffer_config),
        .m7_numeric_config_i(m7_profile_numeric_config),
        .m7_counters_i(m7_profile_counters_flat),
        .profile_trace_select_strobe_o(profile_trace_select_strobe),
        .profile_trace_select_o(profile_trace_select)
    );

    // AXI-Lite uses port A.  The loader streams one 16-word descriptor from
    // port B only when the sequencer enters SEQ_LOAD_LAYER.  The busy write
    // lock makes the table stable throughout every accepted job.
    vit_layer_param_table u_layer_param_table (
        .clk(aclk),
        .rst(!aresetn),
        .a_en_i(layer_table_a_en),
        .a_addr_i(layer_table_a_addr),
        .a_we_i(layer_table_a_we),
        .a_wdata_i(layer_table_a_wdata),
        .a_rvalid_o(layer_table_a_rvalid),
        .a_rdata_o(layer_table_a_rdata),
        .b_en_i(layer_table_b_en),
        .b_addr_i(layer_table_b_addr),
        .b_rvalid_o(layer_table_b_rvalid),
        .b_rdata_o(layer_table_b_rdata)
    );

    assign layer_table_b_en = layer_loader_ram_valid;
    assign layer_param_data =
        phase_e_layer_params_t'(layer_param_packed);

    vit_layer_param_loader u_layer_param_loader (
        .clk(aclk),
        .rst(compute_rst),
        .request_i(layer_param_request),
        .index_i(layer_param_index),
        .response_valid_o(layer_param_valid),
        .response_data_o(layer_param_packed),
        .ram_req_valid_o(layer_loader_ram_valid),
        .ram_req_ready_i(1'b1),
        .ram_req_addr_o(layer_table_b_addr),
        .ram_rsp_valid_i(layer_table_b_rvalid),
        .ram_rsp_data_i(layer_table_b_rdata)
    );

    vit_phase_e_npu #(
        .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .PE_LANES(PE_LANES),
        .FP16_STREAMS(FP16_STREAMS),
        .VECTOR_LANES(VECTOR_LANES),
        .E05_PATCH_COUNT(E05_PATCH_COUNT),
        .E05_TOKEN_COUNT(E05_TOKEN_COUNT),
        .E05_HIDDEN_SIZE(E05_HIDDEN_SIZE),
        .E05_HEAD_COUNT(E05_HEAD_COUNT),
        .E05_HEAD_SIZE(E05_HEAD_SIZE),
        .E05_INTERMEDIATE_SIZE(E05_INTERMEDIATE_SIZE),
        .E05_CLASS_COUNT(E05_CLASS_COUNT),
        .E05_ENCODER_LAYERS(E05_ENCODER_LAYERS),
        .E05_ATTN_SCALE_FP32(E05_ATTN_SCALE_FP32)
    ) u_npu (
        .clk(aclk),
        .rst(compute_rst),
        .job_valid(job_pending),
        .job_ready(job_ready),
        .job(job_active),
        .global_params(global_params_active),
        .layer_param_request(layer_param_request),
        .layer_param_index(layer_param_index),
        .layer_param_valid(layer_param_valid),
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
        .mem_req_read_ahead_safe(mem_req_read_ahead_safe),
        .mem_req_contiguous_words(mem_req_contiguous_words),
        .mem_rsp_valid(mem_rsp_valid),
        .mem_rsp_ready(mem_rsp_ready),
        .mem_rsp_read_data(mem_rsp_read_data),
        .mem_rsp_error(mem_rsp_error),
        .class_result_valid(class_result_valid),
        .class_index(class_index),
        .class_logit(class_logit),
        .command_accept_o(npu_command_accept),
        .profile_events_o(npu_profile_events),
        .m7_profile_events_o(npu_m7_profile_events)
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
        .req_read_ahead_safe(mem_req_read_ahead_safe),
        .req_contiguous_words(mem_req_contiguous_words),
        .cache_invalidate_i(perf_start_accept),
        .rsp_valid(mem_rsp_valid),
        .rsp_ready(mem_rsp_ready),
        .rsp_read_data(mem_rsp_read_data),
        .rsp_error(mem_rsp_error),
        .axi_r_protocol_error_o(adapter_axi_r_protocol_error),
        .axi_b_protocol_error_o(adapter_axi_b_protocol_error),
        .linefill_start_o(adapter_linefill_start),
        .linefill_hit_o(adapter_linefill_hit),
        .full_r_beat_o(adapter_full_r_beat),
        .narrow_r_beat_o(adapter_narrow_r_beat),
        .four_k_split_o(adapter_four_k_split),
        .prefetched_words_discarded_o(
            adapter_prefetched_words_discarded
        ),
        .read_outstanding_o(adapter_read_outstanding),
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
                           execution_mode[0] ^ execution_mode[1] ^
                           execution_mode[2] ^ class_result_valid ^
                           checkpoint_valid ^ checkpoint_phase[0] ^
                           checkpoint_section[0] ^ checkpoint_layer[0] ^
                           checkpoint_step[0] ^ checkpoint_tag[0] ^
                           checkpoint_opcode[0] ^
                           checkpoint_dst_tensor[0] ^
                           operand_load_command.header.opcode[0] ^
                           profile_running ^ profile_snapshot_valid ^
                           m7_profile_running ^ m7_profile_snapshot_valid;

endmodule
