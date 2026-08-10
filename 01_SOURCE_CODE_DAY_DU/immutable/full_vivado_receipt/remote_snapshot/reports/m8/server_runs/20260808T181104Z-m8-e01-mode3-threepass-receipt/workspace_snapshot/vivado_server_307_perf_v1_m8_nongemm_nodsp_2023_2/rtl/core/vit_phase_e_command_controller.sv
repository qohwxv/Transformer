`timescale 1ns/1ps

// Command-level control for the Phase-E core.
//
// This module owns the accepted descriptor and the lifecycle visible at the
// core command port.  Operand/result transport is deliberately delegated to
// vit_phase_e_memory_frontend, while opcode-specific execution is delegated to
// the compute blocks instantiated by vit_phase_e_engine_top.
(* use_dsp = "no" *)
module vit_phase_e_command_controller (
    input  logic                           clk,
    input  logic                           rst,

    input  logic                           cmd_valid,
    output logic                           cmd_ready,
    input  vit_phase_e_pkg::phase_e_cmd_t  cmd,
    output logic                           cmd_done,
    output logic                           cmd_error,
    output logic                           busy,

    output logic                           parameter_request,
    input  logic                           parameter_ready,
    output vit_phase_e_pkg::phase_e_cmd_t  parameter_command,

    input  logic                           memory_error_latched,
    input  logic                           selected_done,
    input  logic                           selected_error,

    input  logic                           argmax_result_valid,
    input  logic                           argmax_result_ready,
    input  logic [31:0]                    argmax_result_index,
    input  logic [31:0]                    argmax_result_value,

    output vit_phase_e_pkg::phase_e_cmd_t  active_cmd,
    output logic                           command_accept,
    output logic                           launch,
    output logic                           execute,
    output logic                           engine_rst,
    output logic [2:0]                     debug_state,

    output logic                           class_result_valid,
    output logic [31:0]                    class_index,
    output logic [31:0]                    class_logit
);

    import vit_phase_e_pkg::*;

    localparam logic [31:0] FP32_QNAN = 32'h7fc0_0000;

    typedef enum logic [2:0] {
        STATE_IDLE,
        STATE_WAIT_PARAMETER,
        STATE_LAUNCH,
        STATE_EXECUTE,
        STATE_REPORT
    } state_t;

    state_t state;
    logic report_error;
    logic incoming_needs_parameters;

    function automatic logic command_needs_parameters(
        input phase_e_cmd_t value
    );
        begin
            command_needs_parameters =
                (value.route.src0_space == PHASE_E_MEM_PARAM) ||
                (value.route.src1_space == PHASE_E_MEM_PARAM) ||
                (value.route.src2_space == PHASE_E_MEM_PARAM);
        end
    endfunction

    assign cmd_ready = (state == STATE_IDLE);
    assign command_accept = cmd_valid && cmd_ready;
    assign busy = (state != STATE_IDLE);
    assign launch = (state == STATE_LAUNCH);
    assign execute = (state == STATE_EXECUTE);
    assign engine_rst = rst || memory_error_latched;
    assign debug_state = state;
    assign parameter_request = (state == STATE_WAIT_PARAMETER);
    assign parameter_command = active_cmd;
    assign incoming_needs_parameters = command_needs_parameters(cmd);

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= STATE_IDLE;
            active_cmd <= '0;
            cmd_done <= 1'b0;
            cmd_error <= 1'b0;
            report_error <= 1'b0;
            class_result_valid <= 1'b0;
            class_index <= 32'd0;
            class_logit <= FP32_QNAN;
        end else begin
            cmd_done <= 1'b0;
            cmd_error <= 1'b0;
            class_result_valid <= 1'b0;

            if (argmax_result_valid && argmax_result_ready) begin
                class_index <= argmax_result_index;
                class_logit <= argmax_result_value;
                class_result_valid <= 1'b1;
            end

            case (state)
                STATE_IDLE: begin
                    if (cmd_valid) begin
                        active_cmd <= cmd;
                        report_error <= 1'b0;
                        if (incoming_needs_parameters)
                            state <= STATE_WAIT_PARAMETER;
                        else
                            state <= STATE_LAUNCH;
                    end
                end

                STATE_WAIT_PARAMETER: begin
                    if (parameter_ready)
                        state <= STATE_LAUNCH;
                end

                STATE_LAUNCH: begin
                    if ((active_cmd.header.opcode < PHASE_E_OP_GEMM) ||
                        (active_cmd.header.opcode > PHASE_E_OP_ARGMAX)) begin
                        report_error <= 1'b1;
                        state <= STATE_REPORT;
                    end else begin
                        state <= STATE_EXECUTE;
                    end
                end

                STATE_EXECUTE: begin
                    if (memory_error_latched) begin
                        report_error <= 1'b1;
                        state <= STATE_REPORT;
                    end else if (selected_done) begin
                        report_error <= selected_error;
                        state <= STATE_REPORT;
                    end
                end

                STATE_REPORT: begin
                    cmd_done <= !report_error;
                    cmd_error <= report_error;
                    state <= STATE_IDLE;
                end

                default: begin
                    report_error <= 1'b1;
                    state <= STATE_REPORT;
                end
            endcase
        end
    end

endmodule
