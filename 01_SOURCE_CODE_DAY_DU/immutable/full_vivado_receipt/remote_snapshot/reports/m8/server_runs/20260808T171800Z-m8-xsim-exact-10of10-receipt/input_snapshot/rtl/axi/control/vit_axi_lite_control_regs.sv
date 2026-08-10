`timescale 1ns/1ps

// P4 control-plane register bank for the ViT accelerator.
//
// This block intentionally stops before the 512-bit descriptor registers and
// command FIFO planned for P6. It implements one outstanding AXI4-Lite read
// and one outstanding AXI4-Lite write. AW and W are buffered independently,
// so either channel may arrive first.
module vit_axi_lite_control_regs #(
    parameter integer AXI_ADDR_WIDTH = 12,
    parameter logic [31:0] IP_ID_VALUE = 32'h5649_544e,       // "VITN"
    parameter logic [31:0] IP_VERSION_VALUE = 32'h0001_000d, // v1.13/M8 no-DSP non-GEMM acceleration ABI
    parameter logic [31:0] PERF_CAPABILITY_VALUE =
        32'h0001_001f // schema v1, five counters present
) (
    input  logic                          aclk,
    input  logic                          aresetn,

    input  logic [AXI_ADDR_WIDTH-1:0]     s_axi_awaddr,
    input  logic [2:0]                    s_axi_awprot,
    input  logic                          s_axi_awvalid,
    output logic                          s_axi_awready,

    input  logic [31:0]                   s_axi_wdata,
    input  logic [3:0]                    s_axi_wstrb,
    input  logic                          s_axi_wvalid,
    output logic                          s_axi_wready,

    output logic [1:0]                    s_axi_bresp,
    output logic                          s_axi_bvalid,
    input  logic                          s_axi_bready,

    input  logic [AXI_ADDR_WIDTH-1:0]     s_axi_araddr,
    input  logic [2:0]                    s_axi_arprot,
    input  logic                          s_axi_arvalid,
    output logic                          s_axi_arready,

    output logic [31:0]                   s_axi_rdata,
    output logic [1:0]                    s_axi_rresp,
    output logic                          s_axi_rvalid,
    input  logic                          s_axi_rready,

    // CONTROL register: write-one, one-clock pulses; read value is zero.
    output logic                          start_pulse_o,
    output logic                          soft_reset_pulse_o,
    output logic                          abort_pulse_o,
    output logic                          clear_error_pulse_o,

    // The layer table is consumed live by the compute wrapper.  Lock only
    // that table while a job is pending/running so software cannot change a
    // layer descriptor underneath the sequencer.  Reads remain available.
    input  logic                          config_busy_i,

    // Live engine state exposed through STATUS and ERROR registers.
    input  logic                          status_idle_i,
    input  logic                          status_busy_i,
    input  logic                          status_done_i,
    input  logic                          status_error_i,
    input  logic                          status_fallback_wait_i,
    input  logic [31:0]                   error_code_i,
    input  logic [31:0]                   error_info_i,

    // Sticky interrupt sources. Event wins over a simultaneous RW1C clear.
    input  logic [31:0]                   irq_events_i,
    output logic [31:0]                   irq_enable_o,
    output logic [31:0]                   irq_status_o,
    output logic                          irq_o,

    // Early configuration/readback registers from checklist sheet 04.
    output logic [63:0]                   model_base_o,
    output logic [63:0]                   input_base_o,
    output logic [63:0]                   scratch_base_o,
    output logic [31:0]                   model_words_o,
    output logic [31:0]                   input_words_o,
    output logic [31:0]                   scratch_words_o,
    output logic [31:0]                   execution_mode_o,

    // Full-model launch configuration. Word zero occupies bits [31:0].
    output logic [8*32-1:0]               global_params_flat_o,
    output logic [31:0]                   job_config_o,
    output logic [31:0]                   job_patch_a_base_o,

    // Synchronous port-A command/response for vit_layer_param_table.  The
    // table address is a word index in the fixed 192-word window.
    output logic                          layer_table_en_o,
    output logic [7:0]                    layer_table_addr_o,
    output logic [3:0]                    layer_table_we_o,
    output logic [31:0]                   layer_table_wdata_o,
    input  logic                          layer_table_rvalid_i,
    input  logic [31:0]                   layer_table_rdata_i,

    input  logic [31:0]                   class_index_i,
    input  logic [31:0]                   class_logit_i,

    // Atomically published per-job performance snapshot.  The live counters
    // are intentionally not exposed, so LO/HI reads cannot tear.
    input  logic                          perf_running_i,
    input  logic                          perf_snapshot_valid_i,
    input  logic [63:0]                   perf_job_cycles_i,
    input  logic [63:0]                   perf_command_count_i,
    input  logic [63:0]                   perf_axi_read_count_i,
    input  logic [63:0]                   perf_axi_write_count_i,
    input  logic [63:0]                   perf_axi_stall_cycles_i,

    // Profile ABI v1.2.  These are published/snapshot values supplied by the
    // profiling block; this register bank only maps them into AXI-Lite.
    input  logic                          profile_running_i,
    input  logic                          profile_snapshot_valid_i,
    input  logic [44*64-1:0]              profile_global_counters_i,
    input  logic [16*64-1:0]              profile_opcode_counts_i,
    input  logic [16*64-1:0]              profile_opcode_cycles_i,
    input  logic [63:0]                   profile_global_overflow_i,
    input  logic [15:0]                   profile_opcode_count_overflow_i,
    input  logic [15:0]                   profile_opcode_cycle_overflow_i,
    input  logic [31:0]                   profile_error_status_i,
    input  logic [8:0]                    profile_trace_count_i,
    input  logic                          profile_trace_truncated_i,
    input  logic                          profile_trace_selected_valid_i,
    input  logic                          profile_trace_read_pending_i,
    input  logic [31:0]                   profile_trace_meta_i,
    input  logic [63:0]                   profile_trace_cycles_i,
    input  logic [18*64-1:0]              profile_hist_counters_i,
    input  logic [17:0]                   profile_hist_overflow_i,

    // Append-only M5 native-AXI snapshot bank.  No pre-M5 address changes.
    input  logic [31:0]                   m5_axi_capability_i,
    input  logic [31:0]                   m5_axi_status_i,
    input  logic [15:0]                   m5_axi_overflow_i,
    input  logic [7:0]                    m5_axi_protocol_status_i,
    input  logic [8*64-1:0]               m5_axi_counters_i,

    // Append-only M7 exact-stage/ownership bank at 0x810..0x8E4.
    input  logic [31:0]                   m7_capability_i,
    input  logic [31:0]                   m7_status_i,
    input  logic [63:0]                   m7_overflow_i,
    input  logic [31:0]                   m7_error_i,
    input  logic [31:0]                   m7_geometry_i,
    input  logic [31:0]                   m7_buffer_config_i,
    input  logic [31:0]                   m7_numeric_config_i,
    // Fixed ABI width: 23 append-only 64-bit counters.  Keep this literal so
    // the AXI-Lite bank remains independently lintable without importing the
    // full execution package.
    input  logic [23*64-1:0]              m7_counters_i,

    output logic                          profile_trace_select_strobe_o,
    output logic [7:0]                    profile_trace_select_o
);

    localparam logic [1:0] AXI_RESP_OKAY   = 2'b00;
    localparam logic [1:0] AXI_RESP_SLVERR = 2'b10;

    localparam logic [AXI_ADDR_WIDTH-1:0] REG_IP_ID          = 'h000;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_IP_VERSION     = 'h004;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_CONTROL        = 'h008;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_STATUS         = 'h00c;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_IRQ_ENABLE     = 'h010;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_IRQ_STATUS     = 'h014;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_ERROR_CODE     = 'h018;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_ERROR_INFO     = 'h01c;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_MODEL_BASE_LO  = 'h020;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_MODEL_BASE_HI  = 'h024;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_INPUT_BASE_LO  = 'h028;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_INPUT_BASE_HI  = 'h02c;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_SCRATCH_BASE_LO = 'h030;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_SCRATCH_BASE_HI = 'h034;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_MODEL_WORDS    = 'h038;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_INPUT_WORDS    = 'h03c;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_SCRATCH_WORDS  = 'h040;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_EXECUTION_MODE = 'h044;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_PERF_CAPABILITY = 'h048;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_PERF_STATUS     = 'h04c;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_JOB_CYCLES_LO   = 'h050;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_JOB_CYCLES_HI   = 'h054;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_COMMANDS_LO     = 'h058;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_COMMANDS_HI     = 'h05c;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_AXI_READS_LO    = 'h060;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_AXI_READS_HI    = 'h064;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_AXI_WRITES_LO   = 'h068;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_AXI_WRITES_HI   = 'h06c;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_AXI_STALL_LO    = 'h070;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_AXI_STALL_HI    = 'h074;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_GLOBAL_BASE     = 'h080;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_GLOBAL_LAST     = 'h09c;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_JOB_CONFIG      = 'h0a0;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_JOB_PATCH_BASE  = 'h0a4;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_CLASS_INDEX     = 'h180;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_CLASS_LOGIT     = 'h184;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_PROFILE_CAP2     = 'h188;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_PROFILE_STATUS2  = 'h18c;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_PROFILE_OVF_LO   = 'h190;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_PROFILE_OVF_HI   = 'h194;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_OPCODE_COUNT_OVF = 'h198;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_OPCODE_CYCLE_OVF = 'h19c;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_PROFILE_GLOBAL_BASE = 'h1a0;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_PROFILE_GLOBAL_LAST = 'h2fc;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_PROFILE_OPCODE_BASE = 'h300;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_PROFILE_OPCODE_LAST = 'h3fc;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_LAYER_BASE      = 'h400;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_LAYER_LAST      = 'h6fc;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_TRACE_CAPABILITY = 'h700;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_TRACE_SELECT     = 'h704;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_TRACE_STATUS     = 'h708;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_TRACE_META       = 'h70c;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_TRACE_CYCLES_LO  = 'h710;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_TRACE_CYCLES_HI  = 'h714;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_TRACE_COUNT      = 'h718;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_PROFILE_ERROR    = 'h71c;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_HIST_CAPABILITY  = 'h720;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_HIST_OVERFLOW    = 'h724;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_HIST_BASE        = 'h728;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_HIST_LAST        = 'h7b4;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_M5_CAPABILITY    = 'h7c0;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_M5_STATUS        = 'h7c4;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_M5_OVERFLOW      = 'h7c8;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_M5_PROTOCOL      = 'h7cc;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_M5_COUNTER_BASE  = 'h7d0;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_M5_COUNTER_LAST  = 'h80c;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_M7_CAPABILITY    = 'h810;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_M7_STATUS        = 'h814;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_M7_OVF_LO        = 'h818;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_M7_OVF_HI        = 'h81c;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_M7_ERROR         = 'h820;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_M7_GEOMETRY      = 'h824;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_M7_BUFFER_CONFIG = 'h828;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_M7_NUMERIC_CONFIG = 'h82c;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_M7_COUNTER_BASE  = 'h830;
    localparam logic [AXI_ADDR_WIDTH-1:0] REG_M7_COUNTER_LAST  = 'h8e4;

    localparam logic [31:0] PROFILE_CAPABILITY2_VALUE = 32'h0002_7fff;
    localparam logic [31:0] TRACE_CAPABILITY_VALUE    = 32'h0103_0100;
    localparam logic [31:0] HIST_CAPABILITY_VALUE     = 32'h0108_0802;

    localparam integer CONTROL_START_BIT       = 0;
    localparam integer CONTROL_SOFT_RESET_BIT  = 1;
    localparam integer CONTROL_ABORT_BIT       = 2;
    localparam integer CONTROL_CLEAR_ERROR_BIT = 3;

    logic [AXI_ADDR_WIDTH-1:0] awaddr_hold;
    logic                      awaddr_hold_valid;
    logic [31:0]               wdata_hold;
    logic [3:0]                wstrb_hold;
    logic                      wdata_hold_valid;
    logic                      write_commit;
    logic                      awaddr_hold_aligned;
    logic [31:0]               irq_clear_mask;
    logic [31:0]               status_value;
    logic [31:0]               perf_status_value;
    logic [31:0]               profile_status2_value;
    logic [31:0]               trace_status_value;
    logic                      layer_read_pending;
    logic                      layer_read_accept;
    logic                      layer_write_commit;
    logic [7:0]                aw_layer_word_address;
    logic [7:0]                ar_layer_word_address;

    // The protection attributes are accepted but do not alter this local
    // register bank's access policy.
    logic [5:0] unused_prot;
    assign unused_prot = {s_axi_awprot, s_axi_arprot};

    function automatic logic [31:0] apply_wstrb(
        input logic [31:0] old_value,
        input logic [31:0] new_value,
        input logic [3:0]  byte_strobe
    );
        integer byte_index;
        begin
            apply_wstrb = old_value;
            for (byte_index = 0; byte_index < 4; byte_index = byte_index + 1)
                if (byte_strobe[byte_index])
                    apply_wstrb[byte_index*8 +: 8] =
                        new_value[byte_index*8 +: 8];
        end
    endfunction

    function automatic logic write_address_supported(
        input logic [AXI_ADDR_WIDTH-1:0] address
    );
        begin
            case (address)
                REG_CONTROL,
                REG_IRQ_ENABLE,
                REG_IRQ_STATUS,
                REG_MODEL_BASE_LO,
                REG_MODEL_BASE_HI,
                REG_INPUT_BASE_LO,
                REG_INPUT_BASE_HI,
                REG_SCRATCH_BASE_LO,
                REG_SCRATCH_BASE_HI,
                REG_MODEL_WORDS,
                REG_INPUT_WORDS,
                REG_SCRATCH_WORDS,
                REG_EXECUTION_MODE,
                REG_JOB_CONFIG,
                REG_JOB_PATCH_BASE,
                REG_TRACE_SELECT: write_address_supported = 1'b1;
                default: write_address_supported =
                    (((address >= REG_GLOBAL_BASE) &&
                      (address <= REG_GLOBAL_LAST)) ||
                     ((address >= REG_LAYER_BASE) &&
                      (address <= REG_LAYER_LAST))) &&
                    (address[1:0] == 2'b00);
            endcase
        end
    endfunction

    function automatic logic read_address_supported(
        input logic [AXI_ADDR_WIDTH-1:0] address
    );
        begin
            case (address)
                REG_IP_ID,
                REG_IP_VERSION,
                REG_CONTROL,
                REG_STATUS,
                REG_IRQ_ENABLE,
                REG_IRQ_STATUS,
                REG_ERROR_CODE,
                REG_ERROR_INFO,
                REG_MODEL_BASE_LO,
                REG_MODEL_BASE_HI,
                REG_INPUT_BASE_LO,
                REG_INPUT_BASE_HI,
                REG_SCRATCH_BASE_LO,
                REG_SCRATCH_BASE_HI,
                REG_MODEL_WORDS,
                REG_INPUT_WORDS,
                REG_SCRATCH_WORDS,
                REG_EXECUTION_MODE,
                REG_PERF_CAPABILITY,
                REG_PERF_STATUS,
                REG_JOB_CYCLES_LO,
                REG_JOB_CYCLES_HI,
                REG_COMMANDS_LO,
                REG_COMMANDS_HI,
                REG_AXI_READS_LO,
                REG_AXI_READS_HI,
                REG_AXI_WRITES_LO,
                REG_AXI_WRITES_HI,
                REG_AXI_STALL_LO,
                REG_AXI_STALL_HI,
                REG_JOB_CONFIG,
                REG_JOB_PATCH_BASE,
                REG_CLASS_INDEX,
                REG_CLASS_LOGIT,
                REG_PROFILE_CAP2,
                REG_PROFILE_STATUS2,
                REG_PROFILE_OVF_LO,
                REG_PROFILE_OVF_HI,
                REG_OPCODE_COUNT_OVF,
                REG_OPCODE_CYCLE_OVF,
                REG_TRACE_CAPABILITY,
                REG_TRACE_SELECT,
                REG_TRACE_STATUS,
                REG_TRACE_META,
                REG_TRACE_CYCLES_LO,
                REG_TRACE_CYCLES_HI,
                REG_TRACE_COUNT,
                REG_PROFILE_ERROR,
                REG_HIST_CAPABILITY,
                REG_HIST_OVERFLOW,
                REG_M5_CAPABILITY,
                REG_M5_STATUS,
                REG_M5_OVERFLOW,
                REG_M5_PROTOCOL,
                REG_M7_CAPABILITY,
                REG_M7_STATUS,
                REG_M7_OVF_LO,
                REG_M7_OVF_HI,
                REG_M7_ERROR,
                REG_M7_GEOMETRY,
                REG_M7_BUFFER_CONFIG,
                REG_M7_NUMERIC_CONFIG: read_address_supported = 1'b1;
                default: read_address_supported =
                    (((address >= REG_GLOBAL_BASE) &&
                      (address <= REG_GLOBAL_LAST)) ||
                     ((address >= REG_PROFILE_GLOBAL_BASE) &&
                      (address <= REG_PROFILE_GLOBAL_LAST)) ||
                     ((address >= REG_PROFILE_OPCODE_BASE) &&
                      (address <= REG_PROFILE_OPCODE_LAST)) ||
                     ((address >= REG_LAYER_BASE) &&
                      (address <= REG_LAYER_LAST)) ||
                     ((address >= REG_HIST_BASE) &&
                      (address <= REG_HIST_LAST)) ||
                     ((address >= REG_M5_COUNTER_BASE) &&
                      (address <= REG_M5_COUNTER_LAST)) ||
                     ((address >= REG_M7_COUNTER_BASE) &&
                      (address <= REG_M7_COUNTER_LAST))) &&
                    (address[1:0] == 2'b00);
            endcase
        end
    endfunction

    function automatic logic is_layer_address(
        input logic [AXI_ADDR_WIDTH-1:0] address
    );
        begin
            is_layer_address =
                (address >= REG_LAYER_BASE)
                && (address <= REG_LAYER_LAST)
                && (address[1:0] == 2'b00);
        end
    endfunction

    function automatic logic [31:0] read_register(
        input logic [AXI_ADDR_WIDTH-1:0] address
    );
        begin
            case (address)
                REG_IP_ID:           read_register = IP_ID_VALUE;
                REG_IP_VERSION:      read_register = IP_VERSION_VALUE;
                REG_CONTROL:         read_register = 32'b0;
                REG_STATUS:          read_register = status_value;
                REG_IRQ_ENABLE:      read_register = irq_enable_o;
                REG_IRQ_STATUS:      read_register = irq_status_o;
                REG_ERROR_CODE:      read_register = error_code_i;
                REG_ERROR_INFO:      read_register = error_info_i;
                REG_MODEL_BASE_LO:   read_register = model_base_o[31:0];
                REG_MODEL_BASE_HI:   read_register = model_base_o[63:32];
                REG_INPUT_BASE_LO:   read_register = input_base_o[31:0];
                REG_INPUT_BASE_HI:   read_register = input_base_o[63:32];
                REG_SCRATCH_BASE_LO: read_register = scratch_base_o[31:0];
                REG_SCRATCH_BASE_HI: read_register = scratch_base_o[63:32];
                REG_MODEL_WORDS:     read_register = model_words_o;
                REG_INPUT_WORDS:     read_register = input_words_o;
                REG_SCRATCH_WORDS:   read_register = scratch_words_o;
                REG_EXECUTION_MODE:  read_register = execution_mode_o;
                REG_PERF_CAPABILITY: read_register = PERF_CAPABILITY_VALUE;
                REG_PERF_STATUS:     read_register = perf_status_value;
                REG_JOB_CYCLES_LO:   read_register = perf_job_cycles_i[31:0];
                REG_JOB_CYCLES_HI:   read_register = perf_job_cycles_i[63:32];
                REG_COMMANDS_LO:     read_register = perf_command_count_i[31:0];
                REG_COMMANDS_HI:     read_register = perf_command_count_i[63:32];
                REG_AXI_READS_LO:    read_register = perf_axi_read_count_i[31:0];
                REG_AXI_READS_HI:    read_register = perf_axi_read_count_i[63:32];
                REG_AXI_WRITES_LO:   read_register = perf_axi_write_count_i[31:0];
                REG_AXI_WRITES_HI:   read_register = perf_axi_write_count_i[63:32];
                REG_AXI_STALL_LO:    read_register = perf_axi_stall_cycles_i[31:0];
                REG_AXI_STALL_HI:    read_register = perf_axi_stall_cycles_i[63:32];
                REG_JOB_CONFIG:      read_register = job_config_o;
                REG_JOB_PATCH_BASE:  read_register = job_patch_a_base_o;
                REG_CLASS_INDEX:     read_register = class_index_i;
                REG_CLASS_LOGIT:     read_register = class_logit_i;
                REG_PROFILE_CAP2:    read_register =
                    PROFILE_CAPABILITY2_VALUE;
                REG_PROFILE_STATUS2: read_register = profile_status2_value;
                REG_PROFILE_OVF_LO:  read_register =
                    profile_global_overflow_i[31:0];
                REG_PROFILE_OVF_HI:  read_register =
                    profile_global_overflow_i[63:32];
                REG_OPCODE_COUNT_OVF: read_register =
                    {16'b0, profile_opcode_count_overflow_i};
                REG_OPCODE_CYCLE_OVF: read_register =
                    {16'b0, profile_opcode_cycle_overflow_i};
                REG_TRACE_CAPABILITY: read_register = TRACE_CAPABILITY_VALUE;
                REG_TRACE_SELECT:     read_register =
                    {24'b0, profile_trace_select_o};
                REG_TRACE_STATUS:     read_register = trace_status_value;
                REG_TRACE_META:       read_register = profile_trace_meta_i;
                REG_TRACE_CYCLES_LO:  read_register =
                    profile_trace_cycles_i[31:0];
                REG_TRACE_CYCLES_HI:  read_register =
                    profile_trace_cycles_i[63:32];
                REG_TRACE_COUNT:      read_register =
                    {23'b0, profile_trace_count_i};
                REG_PROFILE_ERROR:    read_register = profile_error_status_i;
                REG_HIST_CAPABILITY:  read_register = HIST_CAPABILITY_VALUE;
                REG_HIST_OVERFLOW:    read_register =
                    {14'b0, profile_hist_overflow_i};
                REG_M5_CAPABILITY:    read_register = m5_axi_capability_i;
                REG_M5_STATUS:        read_register = m5_axi_status_i;
                REG_M5_OVERFLOW:      read_register =
                    {16'b0, m5_axi_overflow_i};
                REG_M5_PROTOCOL:      read_register =
                    {24'b0, m5_axi_protocol_status_i};
                REG_M7_CAPABILITY:    read_register = m7_capability_i;
                REG_M7_STATUS:        read_register = m7_status_i;
                REG_M7_OVF_LO:        read_register = m7_overflow_i[31:0];
                REG_M7_OVF_HI:        read_register = m7_overflow_i[63:32];
                REG_M7_ERROR:         read_register = m7_error_i;
                REG_M7_GEOMETRY:      read_register = m7_geometry_i;
                REG_M7_BUFFER_CONFIG: read_register = m7_buffer_config_i;
                REG_M7_NUMERIC_CONFIG: read_register = m7_numeric_config_i;
                default: begin
                    if ((address >= REG_GLOBAL_BASE) &&
                        (address <= REG_GLOBAL_LAST))
                        read_register = global_params_flat_o[
                            ((address - REG_GLOBAL_BASE) >> 2)*32 +: 32
                        ];
                    else if ((address >= REG_PROFILE_GLOBAL_BASE) &&
                        (address <= REG_PROFILE_GLOBAL_LAST))
                        read_register = profile_global_counters_i[
                            (((address - REG_PROFILE_GLOBAL_BASE) >> 3)*64) +
                            (address[2] ? 32 : 0) +: 32
                        ];
                    else if ((address >= REG_PROFILE_OPCODE_BASE) &&
                        (address <= REG_PROFILE_OPCODE_LAST)) begin
                        if (address[3])
                            read_register = profile_opcode_cycles_i[
                                (((address - REG_PROFILE_OPCODE_BASE) >> 4)
                                 *64) +
                                (address[2] ? 32 : 0) +: 32
                            ];
                        else
                            read_register = profile_opcode_counts_i[
                                (((address - REG_PROFILE_OPCODE_BASE) >> 4)
                                 *64) +
                                (address[2] ? 32 : 0) +: 32
                            ];
                    end else if ((address >= REG_HIST_BASE) &&
                        (address <= REG_HIST_LAST))
                        read_register = profile_hist_counters_i[
                            (((address - REG_HIST_BASE) >> 3)*64) +
                            (address[2] ? 32 : 0) +: 32
                        ];
                    else if ((address >= REG_M5_COUNTER_BASE) &&
                        (address <= REG_M5_COUNTER_LAST))
                        read_register = m5_axi_counters_i[
                            (((address - REG_M5_COUNTER_BASE) >> 3)*64) +
                            (address[2] ? 32 : 0) +: 32
                        ];
                    else if ((address >= REG_M7_COUNTER_BASE) &&
                        (address <= REG_M7_COUNTER_LAST))
                        read_register = m7_counters_i[
                            (((address - REG_M7_COUNTER_BASE) >> 3)*64) +
                            (address[2] ? 32 : 0) +: 32
                        ];
                    else
                        read_register = 32'b0;
                end
            endcase
        end
    endfunction

    assign irq_o = |(irq_status_o & irq_enable_o);

    always_comb begin
        status_value = 32'b0;
        status_value[0] = status_idle_i;
        status_value[1] = status_busy_i;
        status_value[2] = status_done_i;
        status_value[3] = status_error_i;
        status_value[4] = irq_o;
        status_value[5] = status_fallback_wait_i;

        perf_status_value = 32'b0;
        perf_status_value[0] = perf_running_i;
        perf_status_value[1] = perf_snapshot_valid_i;

        profile_status2_value = 32'b0;
        profile_status2_value[0] = |profile_global_overflow_i;
        profile_status2_value[1] = |profile_opcode_count_overflow_i;
        profile_status2_value[2] = |profile_opcode_cycle_overflow_i;
        profile_status2_value[3] = profile_trace_truncated_i;
        profile_status2_value[4] = profile_trace_selected_valid_i;
        profile_status2_value[5] = profile_trace_read_pending_i;

        trace_status_value = 32'b0;
        trace_status_value[0] = profile_snapshot_valid_i;
        trace_status_value[1] = profile_trace_selected_valid_i;
        trace_status_value[2] = profile_trace_read_pending_i;
        trace_status_value[3] = profile_trace_truncated_i;
    end

    assign s_axi_awready = !awaddr_hold_valid && !s_axi_bvalid;
    assign s_axi_wready  = !wdata_hold_valid && !s_axi_bvalid;
    assign write_commit =
        !s_axi_bvalid && awaddr_hold_valid && wdata_hold_valid;
    assign awaddr_hold_aligned = (awaddr_hold[1:0] == 2'b00);
    assign layer_write_commit =
        write_commit
        && awaddr_hold_aligned
        && is_layer_address(awaddr_hold)
        && !config_busy_i;

    // A table read cannot share port A with an accepted table write.  Reads
    // of ordinary registers can still proceed concurrently with writes.
    assign s_axi_arready =
        !s_axi_rvalid
        && !layer_read_pending
        && (!is_layer_address(s_axi_araddr) || !layer_write_commit);
    assign layer_read_accept =
        s_axi_arready
        && s_axi_arvalid
        && is_layer_address(s_axi_araddr);
    // REG_LAYER_BASE is 0x400, so bits [9:2] are exactly the
    // zero-based word index throughout 0x400..0x6fc.
    assign aw_layer_word_address = awaddr_hold[9:2];
    assign ar_layer_word_address = s_axi_araddr[9:2];

    always_comb begin
        layer_table_en_o = 1'b0;
        layer_table_addr_o = 8'd0;
        layer_table_we_o = 4'd0;
        layer_table_wdata_o = 32'd0;

        // Writes have priority.  s_axi_arready prevents a same-cycle layer
        // read from being accepted when this branch is active.
        if (layer_write_commit) begin
            layer_table_en_o = 1'b1;
            layer_table_addr_o = aw_layer_word_address;
            layer_table_we_o = wstrb_hold;
            layer_table_wdata_o = wdata_hold;
        end else if (layer_read_accept) begin
            layer_table_en_o = 1'b1;
            layer_table_addr_o = ar_layer_word_address;
        end
    end

    always_comb begin
        irq_clear_mask = 32'b0;
        if (
            write_commit
            && awaddr_hold_aligned
            && (awaddr_hold == REG_IRQ_STATUS)
        )
            irq_clear_mask = apply_wstrb(32'b0, wdata_hold, wstrb_hold);
    end

    // Write address/data capture, register writes, and B response.
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            awaddr_hold          <= '0;
            awaddr_hold_valid    <= 1'b0;
            wdata_hold           <= 32'b0;
            wstrb_hold           <= 4'b0;
            wdata_hold_valid     <= 1'b0;
            s_axi_bresp          <= AXI_RESP_OKAY;
            s_axi_bvalid         <= 1'b0;
            start_pulse_o        <= 1'b0;
            soft_reset_pulse_o   <= 1'b0;
            abort_pulse_o        <= 1'b0;
            clear_error_pulse_o  <= 1'b0;
            irq_enable_o         <= 32'b0;
            model_base_o         <= 64'b0;
            input_base_o         <= 64'b0;
            scratch_base_o       <= 64'b0;
            model_words_o        <= 32'b0;
            input_words_o        <= 32'b0;
            scratch_words_o      <= 32'b0;
            execution_mode_o     <= 32'b0;
            global_params_flat_o <= '0;
            job_config_o         <= 32'b0;
            job_patch_a_base_o   <= 32'b0;
            profile_trace_select_strobe_o <= 1'b0;
            profile_trace_select_o <= 8'b0;
        end else begin
            start_pulse_o       <= 1'b0;
            soft_reset_pulse_o  <= 1'b0;
            abort_pulse_o       <= 1'b0;
            clear_error_pulse_o <= 1'b0;
            profile_trace_select_strobe_o <= 1'b0;

            if (s_axi_awready && s_axi_awvalid) begin
                awaddr_hold       <= s_axi_awaddr;
                awaddr_hold_valid <= 1'b1;
            end
            if (s_axi_wready && s_axi_wvalid) begin
                wdata_hold       <= s_axi_wdata;
                wstrb_hold       <= s_axi_wstrb;
                wdata_hold_valid <= 1'b1;
            end

            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;

            if (write_commit) begin
                awaddr_hold_valid <= 1'b0;
                wdata_hold_valid  <= 1'b0;
                s_axi_bvalid      <= 1'b1;

                if (
                    !awaddr_hold_aligned
                    || !write_address_supported(awaddr_hold)
                    || (
                        config_busy_i
                        && (awaddr_hold >= REG_LAYER_BASE)
                        && (awaddr_hold <= REG_LAYER_LAST)
                    ) || (
                        profile_running_i
                        && (awaddr_hold == REG_TRACE_SELECT)
                    )
                ) begin
                    s_axi_bresp <= AXI_RESP_SLVERR;
                end else begin
                    s_axi_bresp <= AXI_RESP_OKAY;
                    case (awaddr_hold)
                        REG_CONTROL: begin
                            if (wstrb_hold[0]) begin
                                start_pulse_o <=
                                    wdata_hold[CONTROL_START_BIT];
                                soft_reset_pulse_o <=
                                    wdata_hold[CONTROL_SOFT_RESET_BIT];
                                abort_pulse_o <=
                                    wdata_hold[CONTROL_ABORT_BIT];
                                clear_error_pulse_o <=
                                    wdata_hold[CONTROL_CLEAR_ERROR_BIT];
                            end
                        end
                        REG_IRQ_ENABLE:
                            irq_enable_o <= apply_wstrb(
                                irq_enable_o, wdata_hold, wstrb_hold
                            );
                        // REG_IRQ_STATUS is updated in the sticky IRQ block.
                        REG_MODEL_BASE_LO:
                            model_base_o[31:0] <= apply_wstrb(
                                model_base_o[31:0], wdata_hold, wstrb_hold
                            );
                        REG_MODEL_BASE_HI:
                            model_base_o[63:32] <= apply_wstrb(
                                model_base_o[63:32], wdata_hold, wstrb_hold
                            );
                        REG_INPUT_BASE_LO:
                            input_base_o[31:0] <= apply_wstrb(
                                input_base_o[31:0], wdata_hold, wstrb_hold
                            );
                        REG_INPUT_BASE_HI:
                            input_base_o[63:32] <= apply_wstrb(
                                input_base_o[63:32], wdata_hold, wstrb_hold
                            );
                        REG_SCRATCH_BASE_LO:
                            scratch_base_o[31:0] <= apply_wstrb(
                                scratch_base_o[31:0],
                                wdata_hold,
                                wstrb_hold
                            );
                        REG_SCRATCH_BASE_HI:
                            scratch_base_o[63:32] <= apply_wstrb(
                                scratch_base_o[63:32],
                                wdata_hold,
                                wstrb_hold
                            );
                        REG_MODEL_WORDS:
                            model_words_o <= apply_wstrb(
                                model_words_o, wdata_hold, wstrb_hold
                            );
                        REG_INPUT_WORDS:
                            input_words_o <= apply_wstrb(
                                input_words_o, wdata_hold, wstrb_hold
                            );
                        REG_SCRATCH_WORDS:
                            scratch_words_o <= apply_wstrb(
                                scratch_words_o, wdata_hold, wstrb_hold
                            );
                        REG_EXECUTION_MODE:
                            execution_mode_o <= apply_wstrb(
                                execution_mode_o, wdata_hold, wstrb_hold
                            );
                        REG_JOB_CONFIG:
                            job_config_o <= apply_wstrb(
                                job_config_o, wdata_hold, wstrb_hold
                            );
                        REG_JOB_PATCH_BASE:
                            job_patch_a_base_o <= apply_wstrb(
                                job_patch_a_base_o, wdata_hold, wstrb_hold
                            );
                        REG_TRACE_SELECT: begin
                            if (wstrb_hold[0]) begin
                                profile_trace_select_o <= wdata_hold[7:0];
                                profile_trace_select_strobe_o <= 1'b1;
                            end
                        end
                        default: begin
                            if ((awaddr_hold >= REG_GLOBAL_BASE) &&
                                (awaddr_hold <= REG_GLOBAL_LAST))
                                global_params_flat_o[
                                    ((awaddr_hold - REG_GLOBAL_BASE) >> 2)*32
                                    +: 32
                                ] <= apply_wstrb(
                                    global_params_flat_o[
                                        ((awaddr_hold - REG_GLOBAL_BASE) >> 2)
                                        *32 +: 32
                                    ],
                                    wdata_hold,
                                    wstrb_hold
                                );
                            // Layer-table writes are emitted through the
                            // synchronous memory port above.
                        end
                    endcase
                end
            end
        end
    end

    // RW1C sticky interrupt status. An event has priority over clearing the
    // same bit so an interrupt cannot be lost at the software-clear boundary.
    always_ff @(posedge aclk) begin
        if (!aresetn)
            irq_status_o <= 32'b0;
        else
            irq_status_o <=
                (irq_status_o & ~irq_clear_mask) | irq_events_i;
    end

    // One-outstanding read channel.  Ordinary registers respond immediately;
    // layer-table reads wait for the synchronous port-A response.  RDATA and
    // RRESP remain stable under AXI backpressure.
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            s_axi_rdata  <= 32'b0;
            s_axi_rresp  <= AXI_RESP_OKAY;
            s_axi_rvalid <= 1'b0;
            layer_read_pending <= 1'b0;
        end else begin
            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;

            if (s_axi_arready && s_axi_arvalid) begin
                if (
                    (s_axi_araddr[1:0] != 2'b00)
                    || !read_address_supported(s_axi_araddr)
                ) begin
                    s_axi_rvalid <= 1'b1;
                    s_axi_rdata <= 32'b0;
                    s_axi_rresp <= AXI_RESP_SLVERR;
                end else if (is_layer_address(s_axi_araddr)) begin
                    layer_read_pending <= 1'b1;
                end else begin
                    s_axi_rvalid <= 1'b1;
                    s_axi_rdata <= read_register(s_axi_araddr);
                    s_axi_rresp <= AXI_RESP_OKAY;
                end
            end

            if (layer_read_pending && layer_table_rvalid_i) begin
                layer_read_pending <= 1'b0;
                s_axi_rvalid <= 1'b1;
                s_axi_rdata <= layer_table_rdata_i;
                s_axi_rresp <= AXI_RESP_OKAY;
            end
        end
    end

endmodule
