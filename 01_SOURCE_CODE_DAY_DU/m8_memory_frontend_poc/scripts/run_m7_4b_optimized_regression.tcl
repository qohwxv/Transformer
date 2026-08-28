# ================================================================
# M8 MEMORY FRONTEND POC
# M7.4B OPTIMIZED FULL REGRESSION
# ================================================================

set ROOT [file normalize \
"/home/s23520579/Vivado_project/m8_memory_frontend_poc"]

set XPR "$ROOT/m8_memory_frontend_poc.xpr"

set RESULT_DIR \
"$ROOT/results/optimized/m7/M7_4B_FULL_REGRESSION"

set TB_DIR \
"$ROOT/tb/optimized_regression"

set SIMSET sim_1

set SIM_DIR \
"$ROOT/m8_memory_frontend_poc.sim/sim_1/behav/xsim"

set XSIM_BIN \
[file join [file dirname [info nameofexecutable]] xsim]

file mkdir $RESULT_DIR

# ----------------------------------------------------------------
# label | top | file | PASS marker
# ----------------------------------------------------------------

set tests {

    {
        01_layout_read
        tb_opt_01_layout_read
        tb_opt_01_layout_read.sv
        {BASELINE TEST PASS}
    }

    {
        02_layout_write
        tb_opt_02_layout_write
        tb_opt_02_layout_write.sv
        {BASELINE WRITE TEST PASS}
    }

    {
        03_vector_linefill
        tb_opt_03_vector_linefill
        tb_opt_03_vector_linefill.sv
        {VECTOR LINEFILL TEST PASS}
    }

    {
        04_gemm_outstanding2
        tb_opt_04_gemm_outstanding2
        tb_opt_04_gemm_outstanding2.sv
        {GEMM OUTSTANDING=2 TEST PASS}
    }

    {
        05_gemm_packed_cold
        tb_opt_05_gemm_packed_cold
        tb_opt_05_gemm_packed_cold.sv
        {GEMM PACKED COLD PANEL TEST PASS}
    }

    {
        06_gemm_a_cache_reuse
        tb_opt_06_gemm_a_cache_reuse
        tb_opt_06_gemm_a_cache_reuse.sv
        {GEMM PACKED A-CACHE REUSE TEST PASS}
    }

    {
        07_gemm_bias_cache_reuse
        tb_opt_07_gemm_bias_cache_reuse
        tb_opt_07_gemm_bias_cache_reuse.sv
        {GEMM BIAS CACHE COMMIT/REUSE TEST PASS}
    }
}

proc read_file {path} {
    set fp [open $path r]
    set txt [read $fp]
    close $fp
    return $txt
}

proc metric {txt patterns} {
    foreach p $patterns {
        if {[regexp -nocase $p $txt -> v]} {
            return $v
        }
    }
    return ""
}

# ================================================================
# OPEN PROJECT
# ================================================================

open_project $XPR

# Add generated TBs.
foreach test $tests {

    lassign $test label top_name tb_file pass_marker

    set path "$TB_DIR/$tb_file"

    if {![file exists $path]} {
        puts "ERROR: missing generated TB:"
        puts $path
        close_project
        exit 2
    }

    if {[llength [get_files -quiet $path]] == 0} {
        add_files -fileset $SIMSET -norecurse $path
    }

    set_property file_type SystemVerilog \
        [get_files $path]
}

update_compile_order -fileset $SIMSET

# ================================================================
# OUTPUT
# ================================================================

set summary \
"$RESULT_DIR/optimized_summary.csv"

set manifest \
"$RESULT_DIR/optimized_manifest.txt"

set sf [open $summary w]
set mf [open $manifest w]

puts $sf \
"test,status,xsim_rc,logical_reads,logical_writes,AR,R_beats,AW,W,B_resp,linefill_start,linefill_hits,narrow_R,full_R,max_outstanding,cycles"

puts $mf "M8 MEMORY FRONTEND POC"
puts $mf "M7.4B OPTIMIZED REGRESSION"
puts $mf ""
puts $mf "Generated: [clock format [clock seconds]]"
puts $mf "XSim: $XSIM_BIN"
puts $mf ""

set pass_count 0
set fail_count 0
set total_count [llength $tests]

puts ""
puts "============================================================"
puts " M7.4B OPTIMIZED 7-TEST REGRESSION"
puts "============================================================"
puts "TOTAL = $total_count"
puts "============================================================"

# ================================================================
# RUN
# ================================================================

foreach test $tests {

    lassign $test label top_name tb_file pass_marker

    puts ""
    puts "============================================================"
    puts "RUNNING : $label"
    puts "TOP     : $top_name"
    puts "EXPECT  : $pass_marker"
    puts "============================================================"

    catch {close_sim}

    set_property top $top_name \
        [get_filesets $SIMSET]

    update_compile_order -fileset $SIMSET

    # ------------------------------------------------------------
    # BUILD / ELABORATE
    # ------------------------------------------------------------

    set launch_rc [catch {

        launch_simulation \
            -simset $SIMSET \
            -mode behavioral

    } launch_msg]

    if {$launch_rc != 0} {

        puts "RESULT : FAIL_LAUNCH"
        puts $launch_msg

        incr fail_count

        set lf [open "$RESULT_DIR/${label}.log" w]
        puts $lf "FAIL_LAUNCH"
        puts $lf $launch_msg
        close $lf

        puts $sf \
"$label,FAIL_LAUNCH,,,,,,,,,,,,,,"

        puts $mf "$label = FAIL_LAUNCH"

        flush $sf
        flush $mf

        catch {close_sim}
        continue
    }

    # ------------------------------------------------------------
    # FIND SNAPSHOT
    # ------------------------------------------------------------

    set snapshot "${top_name}_behav"

    set snapshot_dir \
"$SIM_DIR/xsim.dir/$snapshot"

    if {![file exists $snapshot_dir]} {

        puts "RESULT : FAIL_NO_SNAPSHOT"

        incr fail_count

        puts $sf \
"$label,FAIL_NO_SNAPSHOT,,,,,,,,,,,,,,"

        puts $mf "$label = FAIL_NO_SNAPSHOT"

        flush $sf
        flush $mf

        catch {close_sim}
        continue
    }

    catch {close_sim}

    # ------------------------------------------------------------
    # EXTERNAL XSIM FROM T=0 UNTIL TB $finish/$fatal
    # ------------------------------------------------------------

    set test_log \
"$RESULT_DIR/${label}.log"

    set shell_cmd \
"cd '$SIM_DIR' && '$XSIM_BIN' '$snapshot' -runall > '$test_log' 2>&1"

    puts "EXTERNAL XSIM..."

    set xsim_rc [catch {
        exec bash -lc $shell_cmd
    } xsim_msg]

    if {![file exists $test_log]} {

        puts "RESULT : FAIL_NO_LOG"

        incr fail_count

        puts $sf \
"$label,FAIL_NO_LOG,$xsim_rc,,,,,,,,,,,,,"

        puts $mf "$label = FAIL_NO_LOG"

        flush $sf
        flush $mf
        continue
    }

    set txt [read_file $test_log]

    # ------------------------------------------------------------
    # PASS MARKER
    # ------------------------------------------------------------

    if {[string first $pass_marker $txt] >= 0} {

        set status PASS
        incr pass_count

    } else {

        set status FAIL
        incr fail_count
    }

    puts "RESULT  : $status"
    puts "XSIM RC : $xsim_rc"

    # ------------------------------------------------------------
    # KPI EXTRACTION
    # ------------------------------------------------------------

    set logical_reads [metric $txt {
        {logical reads\s*=\s*([0-9]+)}
        {logical read words\s*=\s*([0-9]+)}
    }]

    set logical_writes [metric $txt {
        {logical writes\s*=\s*([0-9]+)}
        {logical write words\s*=\s*([0-9]+)}
    }]

    set ar [metric $txt {
        {AR handshakes\s*=\s*([0-9]+)}
    }]

    set rbeats [metric $txt {
        {R beat handshakes\s*=\s*([0-9]+)}
    }]

    set aw [metric $txt {
        {AW handshakes\s*=\s*([0-9]+)}
    }]

    set w [metric $txt {
        {W handshakes\s*=\s*([0-9]+)}
    }]

    set b [metric $txt {
        {B (?:resp|response|handshakes)\s*=\s*([0-9]+)}
    }]

    set lf_start [metric $txt {
        {linefill_start\s*=\s*([0-9]+)}
        {linefill starts\s*=\s*([0-9]+)}
    }]

    set lf_hit [metric $txt {
        {linefill_hits\s*=\s*([0-9]+)}
        {linefill hits\s*=\s*([0-9]+)}
    }]

    set narrow [metric $txt {
        {narrow R beats\s*=\s*([0-9]+)}
    }]

    set full [metric $txt {
        {full R beats\s*=\s*([0-9]+)}
    }]

    set maxout [metric $txt {
        {max outstanding\s*=\s*([0-9]+)}
    }]

    set cycles [metric $txt {
        {request->data cycles\s*=\s*([0-9]+)}
        {cycles\s*=\s*([0-9]+)}
    }]

    puts $sf \
"$label,$status,$xsim_rc,$logical_reads,$logical_writes,$ar,$rbeats,$aw,$w,$b,$lf_start,$lf_hit,$narrow,$full,$maxout,$cycles"

    puts $mf "$label = $status"

    flush $sf
    flush $mf
}

# ================================================================
# FINAL
# ================================================================

puts ""
puts "============================================================"
puts " M7.4B OPTIMIZED REGRESSION SUMMARY"
puts "============================================================"
puts "TOTAL : $total_count"
puts "PASS  : $pass_count"
puts "FAIL  : $fail_count"
puts "============================================================"

puts $mf ""
puts $mf "TOTAL = $total_count"
puts $mf "PASS  = $pass_count"
puts $mf "FAIL  = $fail_count"

close $sf
close $mf

catch {close_sim}
close_project

if {$fail_count != 0} {
    exit 1
}

exit 0
