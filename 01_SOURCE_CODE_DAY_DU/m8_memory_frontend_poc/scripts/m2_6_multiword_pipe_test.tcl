set ROOT [file normalize \
"/home/s23520579/Vivado_project/m8_memory_frontend_poc"]

set XPR "$ROOT/m8_memory_frontend_poc.xpr"

set SRC_TB \
"$ROOT/tb/tb_m8_memory_subsystem_gemm_packed_panel.sv"

set NEW_TB \
"$ROOT/tb/tb_m8_memory_subsystem_optimized_pipe_multiword.sv"

puts ""
puts "========================================================"
puts " M2.6 MULTIWORD FRONTEND PIPE TEST"
puts "========================================================"

if {![file exists $SRC_TB]} {
    puts "ERROR: source packed-panel TB missing"
    exit 1
}

# --------------------------------------------------------
# READ EXISTING GOLDEN PACKED-PANEL TB
# --------------------------------------------------------

set fd [open $SRC_TB r]
set txt [read $fd]
close $fd

# Verify expected source structure.
foreach p {
    "module tb_m8_memory_subsystem_gemm_packed_panel;"
    "vit_m8_memory_subsystem_baseline #("
    "GEMM PACKED COLD PANEL TEST PASS"
    "// MAIN TEST"
} {
    if {[string first $p $txt] < 0} {
        puts "ERROR: source TB structure mismatch: $p"
        exit 2
    }
}

# --------------------------------------------------------
# CREATE OPTIMIZED VERSION
# --------------------------------------------------------

set txt [string map [list \
    "module tb_m8_memory_subsystem_gemm_packed_panel;" \
    "module tb_m8_memory_subsystem_optimized_pipe_multiword;" \
    "vit_m8_memory_subsystem_baseline #(" \
    "vit_m8_memory_subsystem_optimized #(" \
] $txt]

# --------------------------------------------------------
# INSERT PIPE PROFILING BEFORE MAIN TEST
# --------------------------------------------------------

set marker \
"    // ============================================================
    // MAIN TEST"

set pos [string first $marker $txt]

if {$pos < 0} {
    puts "ERROR: MAIN TEST marker missing"
    exit 3
}

set monitor {
    // ============================================================
    // M2.6 FRONTEND PIPE PROFILING
    // ============================================================

    integer pipe_req_count;
    integer pipe_rsp_count;
    integer max_pipe_meta_count;
    integer req_before_first_rsp_count;

    integer frontend_error_count;
    integer axi_r_error_count;
    integer axi_b_error_count;

    logic first_pipe_rsp_seen;

    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            pipe_req_count              <= 0;
            pipe_rsp_count              <= 0;
            max_pipe_meta_count         <= 0;
            req_before_first_rsp_count  <= 0;

            frontend_error_count        <= 0;
            axi_r_error_count           <= 0;
            axi_b_error_count           <= 0;

            first_pipe_rsp_seen         <= 1'b0;

        end else begin

            if (dut.u_memory_frontend.read_pipe_req_fire) begin
                pipe_req_count <= pipe_req_count + 1;

                if (!first_pipe_rsp_seen)
                    req_before_first_rsp_count <=
                        req_before_first_rsp_count + 1;
            end

            if (dut.u_memory_frontend.read_pipe_rsp_fire) begin
                pipe_rsp_count <= pipe_rsp_count + 1;
                first_pipe_rsp_seen <= 1'b1;
            end

            if (dut.u_memory_frontend.read_meta_count >
                max_pipe_meta_count)
                max_pipe_meta_count <=
                    dut.u_memory_frontend.read_meta_count;

            if (profile_frontend_error_o)
                frontend_error_count <=
                    frontend_error_count + 1;

            if (axi_r_protocol_error_o)
                axi_r_error_count <=
                    axi_r_error_count + 1;

            if (axi_b_protocol_error_o)
                axi_b_error_count <=
                    axi_b_error_count + 1;
        end
    end


}

set txt \
    [string replace \
        $txt \
        $pos \
        [expr {$pos - 1}] \
        $monitor]

# --------------------------------------------------------
# ADD HARD PIPE CHECKS BEFORE EXISTING PASS MARKER
# --------------------------------------------------------

set pass_marker \
{                $display("GEMM PACKED COLD PANEL TEST PASS");}

set pass_pos [string first $pass_marker $txt]

if {$pass_pos < 0} {
    puts "ERROR: PASS marker missing"
    exit 4
}

set pipe_checks {
                $display("");
                $display(
                    "---------- M2.6 FRONTEND PIPE COUNTERS ----------"
                );
                $display(
                    "pipe request fires       = %0d",
                    pipe_req_count
                );
                $display(
                    "pipe response fires      = %0d",
                    pipe_rsp_count
                );
                $display(
                    "max metadata occupancy   = %0d",
                    max_pipe_meta_count
                );
                $display(
                    "req before first rsp     = %0d",
                    req_before_first_rsp_count
                );
                $display(
                    "frontend error pulses    = %0d",
                    frontend_error_count
                );
                $display(
                    "AXI R protocol errors    = %0d",
                    axi_r_error_count
                );
                $display(
                    "AXI B protocol errors    = %0d",
                    axi_b_error_count
                );
                $display(
                    "-----------------------------------------------"
                );

                // Must actually exercise the new scalar pipeline.
                if (pipe_req_count < 2) begin
                    $display(
                        "FAIL: scalar pipeline was not exercised"
                    );
                    $fatal(1);
                end

                // One response token per accepted pipeline request.
                if (pipe_rsp_count != pipe_req_count) begin
                    $display(
                        "FAIL: pipe req/rsp count mismatch"
                    );
                    $fatal(1);
                end

                // Depth-2 metadata queue must actually become full.
                if (max_pipe_meta_count != 2) begin
                    $display(
                        "FAIL: expected metadata occupancy 2"
                    );
                    $fatal(1);
                end

                // Critical M2.6 proof:
                // second logical request accepted before first response.
                if (req_before_first_rsp_count < 2) begin
                    $display(
                        "FAIL: no frontend issue-ahead observed"
                    );
                    $fatal(1);
                end

                if (frontend_error_count != 0) begin
                    $display(
                        "FAIL: frontend error observed"
                    );
                    $fatal(1);
                end

                if ((axi_r_error_count != 0) ||
                    (axi_b_error_count != 0)) begin
                    $display(
                        "FAIL: AXI protocol error observed"
                    );
                    $fatal(1);
                end

                $display("");
                $display(
                    "M2.6 FRONTEND MULTIWORD PIPE TEST PASS"
                );

}

set txt \
    [string replace \
        $txt \
        $pass_pos \
        [expr {$pass_pos - 1}] \
        $pipe_checks]

# --------------------------------------------------------
# WRITE NEW TB
# --------------------------------------------------------

set fd [open $NEW_TB w]
puts -nonewline $fd $txt
close $fd

puts "NEW TB = $NEW_TB"
puts "SIZE   = [file size $NEW_TB]"

# Static checks.
set fd [open $NEW_TB r]
set verify [read $fd]
close $fd

foreach p {
    "module tb_m8_memory_subsystem_optimized_pipe_multiword;"
    "vit_m8_memory_subsystem_optimized #("
    "dut.u_memory_frontend.read_pipe_req_fire"
    "dut.u_memory_frontend.read_pipe_rsp_fire"
    "dut.u_memory_frontend.read_meta_count"
    "M2.6 FRONTEND MULTIWORD PIPE TEST PASS"
} {
    if {[string first $p $verify] < 0} {
        puts "ERROR: generated TB missing: $p"
        exit 5
    }
}

puts "GENERATED TB STATIC CHECK = PASS"

# --------------------------------------------------------
# OPEN PROJECT
# --------------------------------------------------------

open_project $XPR

if {[llength [get_files -quiet $NEW_TB]] == 0} {
    add_files -fileset sim_1 -norecurse $NEW_TB
}

set_property file_type SystemVerilog \
    [get_files $NEW_TB]

set_property top \
    tb_m8_memory_subsystem_optimized_pipe_multiword \
    [get_filesets sim_1]

puts "SIM TOP = [get_property top [get_filesets sim_1]]"

if {[current_sim -quiet] ne ""} {
    close_sim
}

reset_simulation

# --------------------------------------------------------
# BUILD + START
# --------------------------------------------------------

launch_simulation \
    -simset sim_1 \
    -mode behavioral

# Existing generated XSim Tcl normally runs first 1000 ns.
# Continue long enough for the full packed panel.
run 120 us

if {[current_sim -quiet] ne ""} {
    close_sim
}

puts ""
puts "========================================================"
puts " M2.6 MULTIWORD XSIM COMPLETE"
puts "========================================================"

close_project
exit 0
