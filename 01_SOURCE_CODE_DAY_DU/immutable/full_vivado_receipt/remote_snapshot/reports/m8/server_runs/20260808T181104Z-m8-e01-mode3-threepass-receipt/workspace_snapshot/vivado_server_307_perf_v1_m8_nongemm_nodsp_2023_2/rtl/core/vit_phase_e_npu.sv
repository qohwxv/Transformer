`timescale 1ns/1ps

// Phase-E functional NPU top: model sequencer plus one-at-a-time execution
// adapter.  The external testbench/host supplies job metadata, layer parameter
// table entries, staged parameter contents, and checkpoint consumption.
(* use_dsp = "no" *)
module vit_phase_e_npu #(
    parameter integer ARRAY_ROWS    = 2,
    parameter integer ARRAY_COLS    = 2,
    parameter integer PE_LANES      = 16,
    parameter integer FP16_STREAMS  = 8,
    parameter integer VECTOR_LANES  = 16,
    parameter integer SCRATCH_WORDS = 32'h001e_6000,
    parameter integer INPUT_WORDS   = 150_528,
    parameter integer PARAM_WORDS   = 32'h0024_1000,
    // Simulation can override only the E04 final-phase dimensions.  Keeping
    // these defaults preserves the production ViT-base synthesis hierarchy.
    parameter logic [31:0] E04_TOKEN_COUNT =
        vit_phase_e_pkg::VIT_TOKEN_COUNT,
    parameter logic [31:0] E04_HIDDEN_SIZE =
        vit_phase_e_pkg::VIT_HIDDEN_SIZE,
    parameter logic [31:0] E04_CLASS_COUNT =
        vit_phase_e_pkg::VIT_CLASS_COUNT,
    // E05-only compact simulation shape.  Production synthesis sees the
    // unchanged ViT-base defaults.
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
        vit_phase_e_pkg::VIT_ENCODER_LAYERS,
    parameter logic [31:0] E05_ATTN_SCALE_FP32 =
        vit_phase_e_pkg::VIT_ATTN_SCALE_FP32
)(
    input  logic                                       clk,
    input  logic                                       rst,

    input  logic                                       job_valid,
    output logic                                       job_ready,
    input  vit_phase_e_pkg::phase_e_job_t              job,
    input  vit_phase_e_pkg::phase_e_global_params_t    global_params,

    output logic                                       layer_param_request,
    output logic [3:0]                                 layer_param_index,
    input  logic                                       layer_param_valid,
    input  vit_phase_e_pkg::phase_e_layer_params_t     layer_param_data,

    // Staged operand loader.  The request contains the complete command so
    // software/testbench can select the exact layer/op files before execution.
    output logic                                       operand_load_request,
    input  logic                                       operand_load_ready,
    output vit_phase_e_pkg::phase_e_cmd_t              operand_load_command,

    output logic                                       checkpoint_valid,
    input  logic                                       checkpoint_ready,
    output vit_phase_e_pkg::phase_e_phase_t            checkpoint_phase,
    output vit_phase_e_pkg::phase_e_section_t          checkpoint_section,
    output logic [3:0]                                 checkpoint_layer,
    output logic [4:0]                                 checkpoint_step,
    output logic [7:0]                                 checkpoint_tag,
    output vit_phase_e_pkg::phase_e_opcode_t           checkpoint_opcode,
    output vit_phase_e_pkg::phase_e_tensor_id_t        checkpoint_dst_tensor,

    output logic                                       busy,
    output logic                                       done,
    output logic                                       error,
    output vit_phase_e_pkg::phase_e_error_t            error_code,
    output vit_phase_e_pkg::phase_e_section_t          error_section,
    output logic [3:0]                                 error_layer,
    output logic [4:0]                                 error_step,

    // Optional slow host/debug memory ports.  File testbenches can directly
    // use u_engine.{input,parameter,scratch}_memory for zero-time bulk loads.
    input  logic                                       input_write_enable,
    input  logic [31:0]                                input_write_address,
    input  logic [31:0]                                input_write_data,
    input  logic                                       parameter_write_enable,
    input  logic [31:0]                                parameter_write_address,
    input  logic [31:0]                                parameter_write_data,
    input  logic                                       scratch_write_enable,
    input  logic [31:0]                                scratch_write_address,
    input  logic [31:0]                                scratch_write_data,
    input  logic [31:0]                                scratch_read_address,
    output logic [31:0]                                scratch_read_data,

    // Logical DDR word interface used by the synthesizable engine.  The pure
    // behavioral engine keeps its private file-backed memories and ties this
    // interface idle.
    output logic                                       mem_req_valid,
    input  logic                                       mem_req_ready,
    output logic                                       mem_req_write,
    output vit_phase_e_pkg::phase_e_mem_space_t        mem_req_space,
    output logic [31:0]                                mem_req_word_address,
    output logic [31:0]                                mem_req_write_data,
    output logic [3:0]                                 mem_req_write_strobe,
    output logic                                       mem_req_read_ahead_safe,
    output logic [5:0]                                 mem_req_contiguous_words,
    input  logic                                       mem_rsp_valid,
    output logic                                       mem_rsp_ready,
    input  logic [31:0]                                mem_rsp_read_data,
    input  logic                                       mem_rsp_error,

    output logic                                       class_result_valid,
    output logic [31:0]                                class_index,
    output logic [31:0]                                class_logit,

    // One-cycle event for the wrapper-level performance counter.  This is the
    // exact sequencer-to-engine descriptor handshake and is independent of the
    // optional checkpoint stream.
    output logic                                       command_accept_o,

    output vit_phase_e_pkg::phase_e_profile_core_events_t
                                                       profile_events_o,
    output vit_phase_e_pkg::phase_e_m7_profile_events_t
                                                       m7_profile_events_o
);

    import vit_phase_e_pkg::*;

    phase_e_cmd_t command;
    logic command_valid;
    logic command_ready;
    logic command_done;
    logic command_error;
    logic sequencer_busy;
    logic engine_busy;
    phase_e_profile_core_events_t engine_profile_events;
    phase_e_m7_profile_events_t engine_m7_profile_events;

    assign busy = sequencer_busy || engine_busy;
    assign command_accept_o = command_valid && command_ready;

`ifdef VIT_PURE_SV_BEHAVIORAL
    // The behavioral reference has no production memory/cache/GEMM seams.
    // Preserve command-level profiling while explicitly keeping every
    // hardware-only event at zero.
    always_comb begin
        profile_events_o = '0;
        profile_events_o.command_accept = command_accept_o;
        profile_events_o.command_complete = command_done || command_error;
        profile_events_o.command_error = command_error;
        profile_events_o.command_opcode = command.header.opcode;
        profile_events_o.command_tag = command.header.tag;
        profile_events_o.command_section =
            phase_e_section_t'(command.header.reserved[7:6]);
        profile_events_o.command_layer = command.header.reserved[5:2];
        profile_events_o.command_step = command.route.reserved[4:0];
        m7_profile_events_o = '0;
    end
`else
    assign profile_events_o = engine_profile_events;
    assign m7_profile_events_o = engine_m7_profile_events;
`endif

    vit_phase_e_sequencer #(
        .E04_TOKEN_COUNT(E04_TOKEN_COUNT),
        .E04_HIDDEN_SIZE(E04_HIDDEN_SIZE),
        .E04_CLASS_COUNT(E04_CLASS_COUNT),
        .E05_PATCH_COUNT(E05_PATCH_COUNT),
        .E05_TOKEN_COUNT(E05_TOKEN_COUNT),
        .E05_HIDDEN_SIZE(E05_HIDDEN_SIZE),
        .E05_HEAD_COUNT(E05_HEAD_COUNT),
        .E05_HEAD_SIZE(E05_HEAD_SIZE),
        .E05_INTERMEDIATE_SIZE(E05_INTERMEDIATE_SIZE),
        .E05_CLASS_COUNT(E05_CLASS_COUNT),
        .E05_ENCODER_LAYERS(E05_ENCODER_LAYERS),
        .E05_ATTN_SCALE_FP32(E05_ATTN_SCALE_FP32)
    ) u_sequencer (
        .clk(clk),
        .rst(rst),
        .job_valid(job_valid),
        .job_ready(job_ready),
        .job(job),
        .global_params(global_params),
        .layer_param_request(layer_param_request),
        .layer_param_index(layer_param_index),
        .layer_param_valid(layer_param_valid),
        .layer_param_data(layer_param_data),
        .cmd_valid(command_valid),
        .cmd_ready(command_ready),
        .cmd(command),
        .cmd_done(command_done),
        .cmd_error(command_error),
        .checkpoint_valid(checkpoint_valid),
        .checkpoint_ready(checkpoint_ready),
        .checkpoint_phase(checkpoint_phase),
        .checkpoint_section(checkpoint_section),
        .checkpoint_layer(checkpoint_layer),
        .checkpoint_step(checkpoint_step),
        .checkpoint_tag(checkpoint_tag),
        .checkpoint_opcode(checkpoint_opcode),
        .checkpoint_dst_tensor(checkpoint_dst_tensor),
        .busy(sequencer_busy),
        .done(done),
        .error(error),
        .error_code(error_code),
        .error_section(error_section),
        .error_layer(error_layer),
        .error_step(error_step)
    );

`ifdef VIT_PURE_SV_BEHAVIORAL
    assign mem_req_valid = 1'b0;
    assign mem_req_write = 1'b0;
    assign mem_req_space = PHASE_E_MEM_NONE;
    assign mem_req_word_address = 32'd0;
    assign mem_req_write_data = 32'd0;
    assign mem_req_write_strobe = 4'd0;
    assign mem_req_read_ahead_safe = 1'b0;
    assign mem_req_contiguous_words = 6'd1;
    assign mem_rsp_ready = 1'b0;

    vit_phase_e_behavioral_engine_top #(
`else
    vit_phase_e_engine_top #(
`endif
        .ARRAY_ROWS(ARRAY_ROWS),
        .ARRAY_COLS(ARRAY_COLS),
        .PE_LANES(PE_LANES),
`ifndef VIT_PURE_SV_BEHAVIORAL
        .FP16_STREAMS(FP16_STREAMS),
`endif
        .VECTOR_LANES(VECTOR_LANES),
        .SCRATCH_WORDS(SCRATCH_WORDS),
        .INPUT_WORDS(INPUT_WORDS),
        .PARAM_WORDS(PARAM_WORDS)
    ) u_engine (
        .clk(clk),
        .rst(rst),
        .cmd_valid(command_valid),
        .cmd_ready(command_ready),
        .cmd(command),
        .cmd_done(command_done),
        .cmd_error(command_error),
        .busy(engine_busy),
        .parameter_request(operand_load_request),
        .parameter_ready(operand_load_ready),
        .parameter_command(operand_load_command),
        .input_write_enable(input_write_enable),
        .input_write_address(input_write_address),
        .input_write_data(input_write_data),
        .parameter_write_enable(parameter_write_enable),
        .parameter_write_address(parameter_write_address),
        .parameter_write_data(parameter_write_data),
        .scratch_write_enable(scratch_write_enable),
        .scratch_write_address(scratch_write_address),
        .scratch_write_data(scratch_write_data),
        .scratch_read_address(scratch_read_address),
        .scratch_read_data(scratch_read_data),
`ifndef VIT_PURE_SV_BEHAVIORAL
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
`endif
`ifndef VIT_PURE_SV_BEHAVIORAL
        .profile_events(engine_profile_events),
        .m7_profile_events(engine_m7_profile_events),
`endif
        .class_result_valid(class_result_valid),
        .class_index(class_index),
        .class_logit(class_logit)
    );

endmodule
