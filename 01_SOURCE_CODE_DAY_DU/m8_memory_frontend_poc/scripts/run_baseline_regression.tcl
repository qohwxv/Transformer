
# ================================================================
# M8 MEMORY FRONTEND POC
# BASELINE REGRESSION V3
#
# Flow:
#   Vivado launch_simulation -> build/elaborate snapshot
#   close GUI XSim
#   external xsim <snapshot> -runall
#   stdout/stderr -> dedicated testcase log
#   search PASS marker
#
# This avoids:
#   - simulate.log ambiguity
#   - redirect/launch_simulation incompatibility
#   - arbitrary simulation runtime limits
# ================================================================

set POC_ROOT [file normalize  "/home/s23520579/Vivado_project/m8_memory_frontend_poc"]

set RESULT_DIR "$POC_ROOT/results/baseline"
file mkdir $RESULT_DIR

set SIMSET sim_1

set SIM_DIR  "$POC_ROOT/m8_memory_frontend_poc.sim/sim_1/behav/xsim"

set XSIM_BIN  [file join [file dirname [info nameofexecutable]] xsim]


# ----------------------------------------------------------------
# label | top | PASS marker
# ----------------------------------------------------------------
set tests {

    {
        01_layout_read
        tb_m8_memory_subsystem_baseline
        {BASELINE TEST PASS}
    }

    {
        02_layout_write
        tb_m8_memory_subsystem_layout_write
        {BASELINE WRITE TEST PASS}
    }

    {
        03_vector_linefill
        tb_m8_memory_subsystem_vector_linefill
        {VECTOR LINEFILL TEST PASS}
    }

    {
        04_gemm_outstanding2
        tb_m8_memory_subsystem_gemm_outstanding2
        {GEMM OUTSTANDING=2 TEST PASS}
    }

    {
        05_gemm_packed_cold
        tb_m8_memory_subsystem_gemm_packed_panel
        {GEMM PACKED COLD PANEL TEST PASS}
    }

    {
        06_gemm_a_cache_reuse
        tb_m8_memory_subsystem_gemm_packed_cache_reuse
        {GEMM PACKED A-CACHE REUSE TEST PASS}
    }

    {
        07_gemm_bias_cache_reuse
        tb_m8_memory_subsystem_gemm_bias_cache_reuse
        {GEMM BIAS CACHE COMMIT/REUSE TEST PASS}
    }
}


# ================================================================
# Helpers
# ================================================================

proc read_text_file {path} {

    set fp [open $path r]
    set txt [read $fp]
    close $fp

    return $txt
}


proc extract_metric {text patterns} {

    foreach pattern $patterns {

        if {[regexp $pattern $text -> value]} {
            return $value
        }
    }

    return ""
}


# ================================================================
# Clean previous generated baseline evidence
# ================================================================

foreach f [glob -nocomplain "$RESULT_DIR/*.log"] {
    file delete -force $f
}

foreach name {
    baseline_summary.csv
    baseline_manifest.txt
} {
    catch {
        file delete -force "$RESULT_DIR/$name"
    }
}


# ================================================================
# Output files
# ================================================================

set summary_path  "$RESULT_DIR/baseline_summary.csv"

set manifest_path  "$RESULT_DIR/baseline_manifest.txt"

set sf [open $summary_path w]
set mf [open $manifest_path w]


puts $sf  "test,status,xsim_rc,logical_reads,logical_writes,AR,R_beats,AW,W,B_resp,linefill_starts,linefill_hits,narrow_R,full_R,max_outstanding,A_vector_words,bias_hits,bias_misses,cycles_metric"


puts $mf "M8 MEMORY FRONTEND POC"
puts $mf "FROZEN BASELINE REGRESSION V3"
puts $mf ""
puts $mf "Generated: [clock format [clock seconds]]"
puts $mf "POC root : $POC_ROOT"
puts $mf "XSim     : $XSIM_BIN"
puts $mf ""


# ================================================================
# Regression
# ================================================================

set total_count [llength $tests]
set pass_count 0
set fail_count 0


puts ""
puts "============================================================"
puts " M8 MEMORY FRONTEND — BASELINE REGRESSION V3"
puts "============================================================"
puts "TOTAL   : $total_count"
puts "SIM DIR : $SIM_DIR"
puts "XSIM    : $XSIM_BIN"
puts "RESULTS : $RESULT_DIR"
puts "============================================================"


foreach test $tests {

    lassign $test label top_name pass_marker

    puts ""
    puts "============================================================"
    puts "RUNNING : $label"
    puts "TOP     : $top_name"
    puts "EXPECT  : $pass_marker"
    puts "============================================================"


    # ------------------------------------------------------------
    # Make sure no previous GUI simulator is active.
    # ------------------------------------------------------------
    catch {close_sim}


    # ------------------------------------------------------------
    # Select this TB as sim_1 top.
    # ------------------------------------------------------------
    set_property top  $top_name  [get_filesets $SIMSET]

    puts "SIM TOP = [get_property top [get_filesets $SIMSET]]"


    # ------------------------------------------------------------
    # Build/elaborate snapshot using normal Vivado flow.
    #
    # launch_simulation may also run the first 1000ns.
    # That does not matter; external XSim will restart from t=0.
    # ------------------------------------------------------------
    set launch_rc [catch {

        launch_simulation  -simset $SIMSET  -mode behavioral

    } launch_msg]


    if {$launch_rc != 0} {

        puts "RESULT  : FAIL_LAUNCH"
        puts "DETAIL  : $launch_msg"

        incr fail_count

        set fail_log "$RESULT_DIR/${label}.log"

        set lf [open $fail_log w]
        puts $lf "FAIL_LAUNCH"
        puts $lf $launch_msg
        close $lf

        puts $sf  "$label,FAIL_LAUNCH,,,,,,,,,,,,,,,,,"

        puts $mf "$label = FAIL_LAUNCH"

        flush $sf
        flush $mf

        catch {close_sim}

        continue
    }


    # ------------------------------------------------------------
    # Snapshot name generated by Vivado.
    # ------------------------------------------------------------
    set snapshot  "${top_name}_behav"

    set snapshot_dir  "$SIM_DIR/xsim.dir/$snapshot"


    if {![file exists $snapshot_dir]} {

        puts "RESULT  : FAIL_NO_SNAPSHOT"
        puts "MISSING : $snapshot_dir"

        incr fail_count

        set fail_log "$RESULT_DIR/${label}.log"

        set lf [open $fail_log w]
        puts $lf "FAIL_NO_SNAPSHOT"
        puts $lf "Expected:"
        puts $lf $snapshot_dir
        close $lf

        puts $sf  "$label,FAIL_NO_SNAPSHOT,,,,,,,,,,,,,,,,,"

        puts $mf "$label = FAIL_NO_SNAPSHOT"

        flush $sf
        flush $mf

        catch {close_sim}

        continue
    }


    # ------------------------------------------------------------
    # Close GUI simulator before starting external XSim.
    # ------------------------------------------------------------
    catch {close_sim}


    # ------------------------------------------------------------
    # Dedicated log per testcase.
    # ------------------------------------------------------------
    set test_log  "$RESULT_DIR/${label}.log"


    # ------------------------------------------------------------
    # Run external XSim until the testbench itself exits.
    #
    # TB controls termination with:
    #   $finish -> PASS
    #   $fatal  -> FAIL
    # ------------------------------------------------------------
    set shell_cmd  "cd '$SIM_DIR' && '$XSIM_BIN' '$snapshot' -runall > '$test_log' 2>&1"


    puts "EXTERNAL XSIM..."

    set xsim_rc [catch {

        exec bash -lc $shell_cmd

    } xsim_msg]


    # ------------------------------------------------------------
    # Confirm output log exists.
    # ------------------------------------------------------------
    if {![file exists $test_log]} {

        puts "RESULT : FAIL_NO_LOG"

        incr fail_count

        puts $sf  "$label,FAIL_NO_LOG,$xsim_rc,,,,,,,,,,,,,,,,"

        puts $mf "$label = FAIL_NO_LOG"

        flush $sf
        flush $mf

        continue
    }


    set log_text [read_text_file $test_log]


    # ------------------------------------------------------------
    # PASS decision.
    #
    # PASS marker is authoritative because every TB performs its
    # own functional assertions before printing this marker.
    # ------------------------------------------------------------
    set pass_index  [string first $pass_marker $log_text]


    if {$pass_index >= 0} {

        set status PASS
        incr pass_count

        puts "RESULT  : PASS"
        puts "XSIM RC : $xsim_rc"
        puts "MARKER  : $pass_index"

    } else {

        set status FAIL
        incr fail_count

        puts "RESULT  : FAIL"
        puts "XSIM RC : $xsim_rc"
        puts "Missing PASS marker:"
        puts "  $pass_marker"
    }


    # ============================================================
    # KPI extraction
    #
    # Missing metric = blank.
    # Different TBs expose different counters.
    # ================================================================

    set logical_reads [extract_metric  $log_text  [list  {logical read words[ \t]*=[ \t]*([0-9]+)}  {logical reads[ \t]*=[ \t]*([0-9]+)}  ]]


    set logical_writes [extract_metric  $log_text  [list  {logical write words[ \t]*=[ \t]*([0-9]+)}  {logical writes[ \t]*=[ \t]*([0-9]+)}  ]]


    set ar [extract_metric  $log_text  [list  {AR handshakes[ \t]*=[ \t]*([0-9]+)}  {AR[ \t]*=[ \t]*([0-9]+)}  ]]


    set rbeats [extract_metric  $log_text  [list  {R beat handshakes[ \t]*=[ \t]*([0-9]+)}  {R beats[ \t]*=[ \t]*([0-9]+)}  ]]


    set aw [extract_metric  $log_text  [list  {AW handshakes[ \t]*=[ \t]*([0-9]+)}  ]]


    set wc [extract_metric  $log_text  [list  {W handshakes[ \t]*=[ \t]*([0-9]+)}  ]]


    set bc [extract_metric  $log_text  [list  {B handshakes[ \t]*=[ \t]*([0-9]+)}  ]]


    set linefill_starts [extract_metric  $log_text  [list  {linefill starts[ \t]*=[ \t]*([0-9]+)}  {linefill_start[ \t]*=[ \t]*([0-9]+)}  ]]


    set linefill_hits [extract_metric  $log_text  [list  {linefill hits[ \t]*=[ \t]*([0-9]+)}  {linefill_hit[ \t]*=[ \t]*([0-9]+)}  ]]


    set narrow_r [extract_metric  $log_text  [list  {narrow R beats[ \t]*=[ \t]*([0-9]+)}  {narrow R delta[ \t]*=[ \t]*([0-9]+)}  ]]


    set full_r [extract_metric  $log_text  [list  {full R beats[ \t]*=[ \t]*([0-9]+)}  {full R delta[ \t]*=[ \t]*([0-9]+)}  ]]


    set max_out [extract_metric  $log_text  [list  {max outstanding seen[ \t]*=[ \t]*([0-9]+)}  {max outstanding[ \t]*=[ \t]*([0-9]+)}  ]]


    set a_vec [extract_metric  $log_text  [list  {A vector hit words[ \t]*=[ \t]*([0-9]+)}  ]]


    set bias_hits [extract_metric  $log_text  [list  {bias hit delta[ \t]*=[ \t]*([0-9]+)}  ]]


    set bias_misses [extract_metric  $log_text  [list  {bias miss delta[ \t]*=[ \t]*([0-9]+)}  ]]


    set cycles_metric [extract_metric  $log_text  [list  {request->data cycles[ \t]*=[ \t]*([0-9]+)}  {P1 -> P2 cycles[ \t]*=[ \t]*([0-9]+)}  {cycles[ \t]*=[ \t]*([0-9]+)}  ]]


    # ------------------------------------------------------------
    # CSV row
    # ------------------------------------------------------------
    puts $sf  "$label,$status,$xsim_rc,$logical_reads,$logical_writes,$ar,$rbeats,$aw,$wc,$bc,$linefill_starts,$linefill_hits,$narrow_r,$full_r,$max_out,$a_vec,$bias_hits,$bias_misses,$cycles_metric"

    flush $sf


    # ------------------------------------------------------------
    # Manifest
    # ------------------------------------------------------------
    puts $mf  "$label = $status | xsim_rc=$xsim_rc | log=[file tail $test_log]"

    flush $mf

    puts "LOG     : $test_log"
}


# ================================================================
# Finish
# ================================================================

close $sf


puts ""
puts "============================================================"
puts " BASELINE REGRESSION SUMMARY"
puts "============================================================"
puts "TOTAL : $total_count"
puts "PASS  : $pass_count"
puts "FAIL  : $fail_count"
puts "============================================================"
puts "CSV   : $summary_path"
puts "LOGS  : $RESULT_DIR"
puts "============================================================"


puts $mf ""
puts $mf "TOTAL = $total_count"
puts $mf "PASS  = $pass_count"
puts $mf "FAIL  = $fail_count"

close $mf


if {$fail_count != 0} {

    error  "BASELINE REGRESSION FAILED: $fail_count test(s)"
}


puts ""
puts "============================================================"
puts " ALL BASELINE TESTS PASS"
puts " BASELINE IS FROZEN"
puts "============================================================"

