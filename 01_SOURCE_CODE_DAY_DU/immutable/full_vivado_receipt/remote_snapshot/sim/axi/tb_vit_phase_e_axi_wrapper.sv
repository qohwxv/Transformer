`timescale 1ns/1ps

module tb_vit_phase_e_axi_wrapper;

    localparam integer AXI_ADDR_WIDTH = 40;
    localparam integer AXI_ID_WIDTH = 1;
    localparam logic [1:0] RESP_OKAY = 2'b00;

    logic aclk = 1'b0;
    logic aresetn = 1'b0;

    logic [11:0] s_axi_awaddr = '0;
    logic [2:0] s_axi_awprot = '0;
    logic s_axi_awvalid = 1'b0;
    logic s_axi_awready;
    logic [31:0] s_axi_wdata = '0;
    logic [3:0] s_axi_wstrb = '0;
    logic s_axi_wvalid = 1'b0;
    logic s_axi_wready;
    logic [1:0] s_axi_bresp;
    logic s_axi_bvalid;
    logic s_axi_bready = 1'b0;
    logic [11:0] s_axi_araddr = '0;
    logic [2:0] s_axi_arprot = '0;
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
    logic m_axi_awready = 1'b1;
    logic [127:0] m_axi_wdata;
    logic [15:0] m_axi_wstrb;
    logic m_axi_wlast;
    logic m_axi_wvalid;
    logic m_axi_wready = 1'b1;
    logic [AXI_ID_WIDTH-1:0] m_axi_bid = '0;
    logic [1:0] m_axi_bresp = RESP_OKAY;
    logic m_axi_bvalid = 1'b0;
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
    logic m_axi_arready = 1'b1;
    logic [AXI_ID_WIDTH-1:0] m_axi_rid = '0;
    logic [127:0] m_axi_rdata = '0;
    logic [1:0] m_axi_rresp = RESP_OKAY;
    logic m_axi_rlast = 1'b1;
    logic m_axi_rvalid = 1'b0;
    logic m_axi_rready;
    logic irq_o;

    integer checks = 0;
    integer failures = 0;
    integer perf_start_accept_count = 0;
    integer adapter_reset_count = 0;
    logic [1:0] response;
    logic [31:0] read_data;

    always #5 aclk = ~aclk;

    vit_phase_e_axi_wrapper #(
        .AXI_ADDR_WIDTH(AXI_ADDR_WIDTH),
        .AXI_ID_WIDTH(AXI_ID_WIDTH)
    ) dut (.*);

    always @(posedge aclk) begin
        if (aresetn && dut.perf_start_accept)
            perf_start_accept_count = perf_start_accept_count + 1;
        if (aresetn && !dut.adapter_aresetn)
            adapter_reset_count = adapter_reset_count + 1;
        if (aresetn && dut.perf_start_accept && dut.recovery_required_q)
            $fatal(1, "START accepted while recovery reset is required");
    end

    task automatic check(input logic condition, input string message);
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                failures = failures + 1;
                $error("CHECK FAILED: %s", message);
            end
        end
    endtask

    task automatic axi_write(
        input logic [11:0] address,
        input logic [31:0] data,
        input logic [3:0] strobe,
        output logic [1:0] write_response
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
            s_axi_wstrb = strobe;
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
            write_response = s_axi_bresp;
            @(negedge aclk);
            s_axi_bready = 1'b1;
            @(posedge aclk);
            @(negedge aclk);
            s_axi_bready = 1'b0;
        end
    endtask

    task automatic axi_read(
        input logic [11:0] address,
        output logic [31:0] data,
        output logic [1:0] read_response
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
            read_response = s_axi_rresp;
            @(negedge aclk);
            s_axi_rready = 1'b1;
            @(posedge aclk);
            @(negedge aclk);
            s_axi_rready = 1'b0;
        end
    endtask

    task automatic expect_execution_mode_reject(
        input logic [31:0] rejected_mode,
        input string mode_name
    );
        integer accepted_before;
        logic [2:0] job_snapshot_before;
        begin
            accepted_before = perf_start_accept_count;
            job_snapshot_before = {
                dut.job_active.fp16_gemm_compat_enable,
                dut.job_active.model_b_fp16_packed2,
                dut.job_active.model_b_blocked_k16_n2
            };

            check(!dut.recovery_required_q,
                  $sformatf("%s begins outside recovery", mode_name));
            axi_write(12'h010, 32'h0000_0002, 4'hf, response);
            check(response == RESP_OKAY,
                  $sformatf("%s error IRQ enable write", mode_name));
            axi_write(12'h044, rejected_mode, 4'hf, response);
            check(response == RESP_OKAY,
                  $sformatf("%s execution-mode write", mode_name));
            axi_read(12'h044, read_data, response);
            check(response == RESP_OKAY && read_data == rejected_mode,
                  $sformatf("%s execution-mode readback", mode_name));

            axi_write(12'h008, 32'h0000_0001, 4'hf, response);
            check(response == RESP_OKAY,
                  $sformatf("%s rejected START bus response", mode_name));
            repeat (3) @(posedge aclk);

            check(irq_o,
                  $sformatf("%s rejected START raises error IRQ", mode_name));
            check(!m_axi_arvalid && !m_axi_awvalid && !m_axi_wvalid,
                  $sformatf("%s rejected START issues no DDR request", mode_name));
            check(!dut.job_pending && !dut.npu_busy,
                  $sformatf("%s rejected START never reaches NPU", mode_name));
            check(perf_start_accept_count == accepted_before,
                  $sformatf("%s rejected START opens no profile epoch", mode_name));
            check(!dut.recovery_required_q,
                  $sformatf("%s wrapper rejection needs no recovery", mode_name));
            check({
                      dut.job_active.fp16_gemm_compat_enable,
                      dut.job_active.model_b_fp16_packed2,
                      dut.job_active.model_b_blocked_k16_n2
                  } == job_snapshot_before,
                  $sformatf("%s rejection preserves the prior job snapshot", mode_name));

            axi_read(12'h00c, read_data, response);
            check(response == RESP_OKAY && read_data[3] && read_data[0] &&
                  !read_data[1],
                  $sformatf("%s reports ERROR while staying idle", mode_name));
            axi_read(12'h018, read_data, response);
            check(response == RESP_OKAY && read_data == 32'h8000_0003,
                  $sformatf("%s reports EXECUTION_MODE error", mode_name));
            axi_read(12'h01c, read_data, response);
            check(response == RESP_OKAY && read_data == rejected_mode,
                  $sformatf("%s ERROR_INFO preserves rejected value", mode_name));

            axi_write(12'h014, 32'h0000_0002, 4'hf, response);
            check(response == RESP_OKAY,
                  $sformatf("%s error IRQ clear write", mode_name));
            axi_write(12'h008, 32'h0000_0008, 4'hf, response);
            check(response == RESP_OKAY,
                  $sformatf("%s CLEAR_ERROR write", mode_name));
            repeat (3) @(posedge aclk);
            check(!irq_o,
                  $sformatf("%s rejection IRQ clears", mode_name));
            axi_read(12'h018, read_data, response);
            check(response == RESP_OKAY && read_data == 32'd0,
                  $sformatf("%s rejection error code clears", mode_name));
        end
    endtask

    initial begin
        repeat (5) @(posedge aclk);
        @(negedge aclk);
        aresetn = 1'b1;

        // Exercise both ends of the extended full-model register windows.
        axi_write(12'h080, 32'h1234_5678, 4'hf, response);
        check(response == RESP_OKAY, "global parameter write response");
        axi_read(12'h080, read_data, response);
        check(response == RESP_OKAY, "global parameter read response");
        check(read_data == 32'h1234_5678, "global parameter readback");

        axi_write(12'h6fc, 32'hcafe_f00d, 4'hf, response);
        check(response == RESP_OKAY, "last layer parameter write response");
        axi_read(12'h6fc, read_data, response);
        check(read_data == 32'hcafe_f00d, "last layer parameter readback");

        // M7 changes the reachable hardware identity without moving any
        // legacy register or changing the M5 counter capability.
        axi_read(12'h004, read_data, response);
        check(read_data == 32'h0001_000d, "M8 IP version is v1.13");
        axi_read(12'h7c0, read_data, response);
        check(read_data == 32'h01f2_1008, "M5 capability register");
        axi_read(12'h810, read_data, response);
        check(read_data == 32'h01ff_0817,
              "M7 FIFO/generation capability register");
        axi_read(12'h828, read_data, response);
        check(read_data == 32'h0008_0202,
              "M7 operand/FIFO/generation configuration register");

        // Enable error IRQ. Phase zero is deliberately invalid, so START must
        // reach the NPU and produce BAD_PHASE without any DDR transaction.
        axi_write(12'h010, 32'h0000_0002, 4'hf, response);
        check(response == RESP_OKAY, "IRQ enable write");
        axi_write(12'h0a0, 32'h0000_0000, 4'hf, response);
        check(response == RESP_OKAY, "job config write");
        axi_write(12'h044, 32'h0000_0003, 4'hf, response);
        check(response == RESP_OKAY,
              "FP16-only wrapper selects legal mode 3 before START");
        axi_write(12'h008, 32'h0000_0001, 4'hf, response);
        check(response == RESP_OKAY, "START write");

        fork
            begin : timeout_block
                repeat (100) @(posedge aclk);
                $fatal(1, "timeout waiting for wrapper error IRQ");
            end
            begin : wait_block
                wait (irq_o);
                disable timeout_block;
            end
        join

        check(!m_axi_arvalid && !m_axi_awvalid && !m_axi_wvalid,
              "invalid job issued no DDR request");
        axi_read(12'h00c, read_data, response);
        check(response == RESP_OKAY, "STATUS read response");
        check(read_data[3], "STATUS.ERROR set");
        axi_read(12'h018, read_data, response);
        check(read_data == 32'd1, "ERROR_CODE is BAD_PHASE");
        check(dut.recovery_required_q,
              "terminal NPU error requires recovery reset");
        check(perf_start_accept_count == 1,
              "first invalid job was the only accepted START");

        // Even an invalid job receives an atomic terminal snapshot.  It uses
        // wrapper/sequencer cycles but never accepts a compute descriptor or
        // reaches the AXI DDR master.
        axi_read(12'h048, read_data, response);
        check(read_data == 32'h0001_001f, "performance capability register");
        axi_read(12'h04c, read_data, response);
        check(read_data == 32'h0000_0002, "error job snapshot is valid");
        axi_read(12'h050, read_data, response);
        check(read_data != 0, "invalid job still reports nonzero cycles");
        axi_read(12'h054, read_data, response);
        check(read_data == 0, "short invalid-job cycle high word is zero");
        axi_read(12'h058, read_data, response);
        check(read_data == 0, "invalid job accepts no commands");
        axi_read(12'h05c, read_data, response);
        check(read_data == 0, "command high word is zero");
        axi_read(12'h060, read_data, response);
        check(read_data == 0, "invalid job issues no AXI reads");
        axi_read(12'h064, read_data, response);
        check(read_data == 0, "AXI read high word is zero");
        axi_read(12'h068, read_data, response);
        check(read_data == 0, "invalid job issues no AXI writes");
        axi_read(12'h06c, read_data, response);
        check(read_data == 0, "AXI write high word is zero");
        axi_read(12'h070, read_data, response);
        check(read_data == 0, "invalid job has no AXI request stalls");
        axi_read(12'h074, read_data, response);
        check(read_data == 0, "AXI stall high word is zero");

        // The sequencer keeps its error level until another job is accepted;
        // the wrapper must nevertheless let software clear IRQ and status.
        axi_read(12'h014, read_data, response);
        check(read_data[1], "error IRQ status latched");
        axi_write(12'h014, 32'h0000_0002, 4'hf, response);
        check(response == RESP_OKAY, "IRQ RW1C write");
        axi_write(12'h008, 32'h0000_0008, 4'hf, response);
        check(response == RESP_OKAY, "CLEAR_ERROR write");
        repeat (3) @(posedge aclk);
        check(!irq_o, "error IRQ remains clear while NPU error level is sticky");
        axi_read(12'h00c, read_data, response);
        check(!read_data[3], "STATUS.ERROR cleared");
        axi_read(12'h018, read_data, response);
        check(read_data == 32'd0, "ERROR_CODE cleared");
        check(dut.recovery_required_q,
              "CLEAR_ERROR does not release recovery interlock");

        // A new START must not consume an AXI response that survived the
        // failed job.  The rejection is a wrapper error and must not open a
        // new profiling epoch or enter the sequencer.
        axi_write(12'h008, 32'h0000_0001, 4'hf, response);
        check(response == RESP_OKAY, "reset-required START bus response");
        repeat (3) @(posedge aclk);
        check(irq_o, "reset-required START raises error IRQ");
        check(dut.recovery_required_q,
              "rejected START keeps recovery interlock set");
        check(!dut.job_pending && !dut.npu_busy,
              "reset-required START does not reach NPU");
        check(!m_axi_arvalid && !m_axi_awvalid && !m_axi_wvalid,
              "reset-required START issues no DDR request");
        check(perf_start_accept_count == 1,
              "reset-required START does not open profile epoch");
        axi_read(12'h018, read_data, response);
        check(read_data == 32'h8000_0005,
              "rejected START reports RESET_REQUIRED");
        axi_read(12'h01c, read_data, response);
        check(read_data == 32'd0,
              "RESET_REQUIRED has zero error info");

        // Only an accepted idle SOFT_RESET releases the interlock.  Detect
        // the internal reset pulse and prove the adapter state/queues are in
        // their reset state before accepting another job.
        axi_write(12'h014, 32'h0000_0002, 4'hf, response);
        axi_write(12'h008, 32'h0000_0008, 4'hf, response);
        check(dut.recovery_required_q,
              "IRQ/CLEAR_ERROR still do not release recovery interlock");
        begin : recovery_soft_reset
            integer reset_count_before;
            reset_count_before = adapter_reset_count;
            fork
                begin
                    axi_write(12'h008, 32'h0000_0002, 4'hf, response);
                end
                begin
                    // Seed representative stale adapter state after the
                    // wrapper has accepted SOFT_RESET but before its reset
                    // pulse reaches the adapter on the following clock.
                    wait (dut.local_reset_pulse);
                    @(negedge aclk);
                    force dut.u_mem_adapter.req_fifo_count = 2'd2;
                    force dut.u_mem_adapter.rsp_fifo_count = 2'd1;
                    force dut.u_mem_adapter.scalar_read_outstanding = 1'b1;
                    force dut.u_mem_adapter.line_valid = 1'b1;
                    #1;
                    release dut.u_mem_adapter.req_fifo_count;
                    release dut.u_mem_adapter.rsp_fifo_count;
                    release dut.u_mem_adapter.scalar_read_outstanding;
                    release dut.u_mem_adapter.line_valid;
                    check(dut.u_mem_adapter.req_fifo_count == 2 &&
                          dut.u_mem_adapter.rsp_fifo_count == 1 &&
                          dut.u_mem_adapter.scalar_read_outstanding &&
                          dut.u_mem_adapter.line_valid,
                          "recovery test preloads nonempty adapter state");
                end
            join
            check(response == RESP_OKAY, "recovery SOFT_RESET bus response");
            repeat (3) @(posedge aclk);
            check(adapter_reset_count > reset_count_before,
                  "SOFT_RESET pulses AXI adapter reset");
        end
        check(!dut.recovery_required_q,
              "accepted SOFT_RESET releases recovery interlock");
        check(dut.u_mem_adapter.state == 0,
              "SOFT_RESET returns adapter to IDLE");
        check(dut.u_mem_adapter.req_fifo_count == 0,
              "SOFT_RESET clears adapter request queue");
        check(dut.u_mem_adapter.rsp_fifo_count == 0,
              "SOFT_RESET clears adapter response queue");
        check(!dut.u_mem_adapter.scalar_read_outstanding &&
              dut.u_mem_adapter.fill_ar_accepted_count == 0 &&
              dut.u_mem_adapter.fill_r_completed_count == 0,
              "SOFT_RESET clears adapter outstanding bookkeeping");
        check(!dut.u_mem_adapter.line_valid,
              "SOFT_RESET invalidates adapter read-ahead cache");

        // Re-run the short BAD_PHASE job to prove START acceptance resumes.
        axi_write(12'h008, 32'h0000_0001, 4'hf, response);
        check(response == RESP_OKAY, "post-reset START bus response");
        fork
            begin
                wait (irq_o);
            end
            begin
                repeat (100) @(posedge aclk);
                $fatal(1, "timeout waiting for post-reset accepted START");
            end
        join_any
        disable fork;
        check(perf_start_accept_count == 2,
              "START acceptance resumes after SOFT_RESET");
        check(dut.recovery_required_q,
              "second terminal NPU error relocks recovery");
        axi_write(12'h014, 32'h0000_0002, 4'hf, response);
        axi_write(12'h008, 32'h0000_0002, 4'hf, response);
        repeat (3) @(posedge aclk);
        check(!dut.recovery_required_q,
              "second SOFT_RESET restores clean test state");
        check(!irq_o, "second error IRQ clears");

        // This production board specialization has no FP32 GEMM datapath.
        // Prove the two formerly executable FP32 modes, malformed mode 2,
        // and representative reserved/full-width values all fail closed at
        // START without mutating the last accepted mode-3 job snapshot.
        expect_execution_mode_reject(32'd0, "mode 0");
        expect_execution_mode_reject(32'd1, "mode 1");
        expect_execution_mode_reject(32'd2, "mode 2");
        expect_execution_mode_reject(32'd4, "reserved mode 4");
        expect_execution_mode_reject(32'hffff_ffff, "reserved all-ones mode");

        // Packed-v3 requires a 128-byte-aligned physical MODEL base.  Reject
        // an otherwise legal mode-3 launch before the job or AXI master sees
        // it; the host hash/table checks remain an additional software gate.
        axi_write(12'h020, 32'h0000_0004, 4'hf, response);
        check(response == RESP_OKAY, "misaligned MODEL base write");
        axi_write(12'h044, 32'h0000_0003, 4'hf, response);
        check(response == RESP_OKAY, "mode 3 alignment-test mode write");
        axi_write(12'h008, 32'h0000_0001, 4'hf, response);
        check(response == RESP_OKAY, "misaligned mode-3 START bus response");
        repeat (3) @(posedge aclk);
        check(irq_o, "misaligned mode 3 raises error IRQ");
        check(!m_axi_arvalid && !m_axi_awvalid && !m_axi_wvalid,
              "misaligned mode 3 issued no DDR request");
        check(!dut.job_pending && !dut.npu_busy,
              "misaligned mode 3 was not accepted by NPU");
        axi_read(12'h018, read_data, response);
        check(read_data == 32'h8000_0004,
              "misaligned mode 3 reports MODEL_ALIGNMENT");
        axi_read(12'h01c, read_data, response);
        check(read_data == 32'h0000_0004,
              "alignment ERROR_INFO preserves MODEL base low word");
        axi_write(12'h014, 32'h0000_0002, 4'hf, response);
        axi_write(12'h008, 32'h0000_0008, 4'hf, response);
        axi_write(12'h020, 32'h0000_0000, 4'hf, response);
        check(response == RESP_OKAY, "restore aligned MODEL base");
        repeat (3) @(posedge aclk);
        check(!irq_o, "alignment error IRQ clears");

        // Mode 3 is package-v3 packed persistent B with FP16 GEMM compute.
        // The deliberately invalid phase proves acceptance and captures the
        // exact three-bit internal snapshot without issuing a DDR request.
        axi_write(12'h044, 32'h0000_0003, 4'hf, response);
        check(response == RESP_OKAY, "mode 3 execution-mode write");
        axi_read(12'h044, read_data, response);
        check(read_data == 32'h0000_0003, "mode 3 execution-mode readback");
        axi_write(12'h008, 32'h0000_0001, 4'hf, response);
        check(response == RESP_OKAY, "mode 3 START accepted");
        repeat (3) @(posedge aclk);
        check(dut.job_active.model_b_blocked_k16_n2,
              "mode 3 snapshots blocked storage bit");
        check(dut.job_active.model_b_fp16_packed2,
              "mode 3 snapshots packed-FP16 storage bit");
        check(dut.job_active.fp16_gemm_compat_enable,
              "mode 3 snapshots FP16 GEMM compute bit");

        fork
            begin
                wait (irq_o);
            end
            begin
                repeat (100) @(posedge aclk);
                $fatal(1, "timeout waiting for mode-3 invalid-phase completion");
            end
        join_any
        disable fork;
        check(!m_axi_arvalid && !m_axi_awvalid && !m_axi_wvalid,
              "mode 3 invalid-phase job issued no DDR request");
        axi_read(12'h018, read_data, response);
        check(read_data == 32'd1,
              "legal mode 3 reached sequencer BAD_PHASE path");

        axi_write(12'h014, 32'h0000_0002, 4'hf, response);
        axi_write(12'h008, 32'h0000_0002, 4'hf, response);
        repeat (3) @(posedge aclk);
        check(!irq_o, "mode-3 recovery reset clears error IRQ");

        // Mode 5 is the explicit compatibility A/B path: blocked-v2 FP32
        // storage with FP16 GEMM compute.  Verify the public register and the
        // exact internal job snapshot independently of the reserved mode.
        axi_write(12'h044, 32'h0000_0005, 4'hf, response);
        check(response == RESP_OKAY, "mode 5 execution-mode write");
        axi_read(12'h044, read_data, response);
        check(read_data == 32'h0000_0005, "mode 5 execution-mode readback");
        axi_write(12'h008, 32'h0000_0001, 4'hf, response);
        check(response == RESP_OKAY, "mode 5 START accepted");
        repeat (3) @(posedge aclk);
        check(dut.job_active.model_b_blocked_k16_n2,
              "mode 5 snapshots blocked-v2 storage bit");
        check(!dut.job_active.model_b_fp16_packed2,
              "mode 5 keeps packed-FP16 storage bit clear");
        check(dut.job_active.fp16_gemm_compat_enable,
              "mode 5 snapshots FP16 GEMM compatibility bit");

        fork
            begin
                wait (irq_o);
            end
            begin
                repeat (100) @(posedge aclk);
                $fatal(1, "timeout waiting for mode-5 invalid-phase completion");
            end
        join_any
        disable fork;
        check(!m_axi_arvalid && !m_axi_awvalid && !m_axi_wvalid,
              "mode 5 invalid-phase job issued no DDR request");
        axi_read(12'h018, read_data, response);
        check(read_data == 32'd1,
              "legal mode 5 reached sequencer BAD_PHASE path");

        if (failures == 0)
            $display("VIT_PHASE_E_AXI_WRAPPER_TEST_PASS checks=%0d", checks);
        else
            $fatal(1, "wrapper failures=%0d checks=%0d", failures, checks);
        $finish;
    end

endmodule
