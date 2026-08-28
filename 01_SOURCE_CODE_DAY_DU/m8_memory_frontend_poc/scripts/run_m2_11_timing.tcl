set ROOT [file normalize \
"/home/s23520579/Vivado_project/m8_memory_frontend_poc"]

set XPR \
"$ROOT/m8_memory_frontend_poc.xpr"

set RESULT_DIR \
"$ROOT/results/optimized/m2_11_timing"

set XDC \
"$RESULT_DIR/m2_11_50mhz.xdc"

set TOP \
"vit_m8_memory_subsystem_optimized"

file mkdir $RESULT_DIR

puts ""
puts "============================================================"
puts " M2.11 SYNTHESIS + IMPLEMENTATION @ 50 MHz"
puts "============================================================"

# ============================================================
# 1. OPEN PROJECT
# ============================================================

open_project $XPR

# ============================================================
# 2. SANITY CHECK TOP
# ============================================================

set top_files [get_files -quiet \
    *vit_m8_memory_subsystem_optimized.sv]

if {[llength $top_files] == 0} {
    puts "ERROR: optimized wrapper source missing"
    close_project
    exit 1
}

set_property top $TOP [get_filesets sources_1]

update_compile_order -fileset sources_1

puts "SYNTH TOP = [get_property top [get_filesets sources_1]]"
puts "PART      = [get_property PART [current_project]]"

# ============================================================
# 3. ADD 50 MHz XDC
# ============================================================

if {![file exists $XDC]} {
    puts "ERROR: XDC missing: $XDC"
    close_project
    exit 2
}

if {[llength [get_files -quiet $XDC]] == 0} {
    add_files -fileset constrs_1 -norecurse $XDC
}

set_property used_in_synthesis true \
    [get_files $XDC]

set_property used_in_implementation true \
    [get_files $XDC]

puts "50 MHz XDC = $XDC"

# ============================================================
# 4. CLEAN OLD RUNS
# ============================================================

catch {close_design}

puts ""
puts "Resetting synth_1 / impl_1 ..."

reset_run synth_1

# ============================================================
# 5. SYNTHESIS
# ============================================================

puts ""
puts "============================================================"
puts " SYNTHESIS"
puts "============================================================"

launch_runs synth_1 -jobs 8
wait_on_run synth_1

set synth_status [get_property STATUS [get_runs synth_1]]

puts "SYNTH STATUS = $synth_status"

if {![string match "*Complete*" $synth_status]} {
    puts "ERROR: synthesis did not complete"
    close_project
    exit 3
}

open_run synth_1

report_utilization \
    -file "$RESULT_DIR/synth_utilization.rpt"

report_timing_summary \
    -delay_type max \
    -max_paths 20 \
    -file "$RESULT_DIR/synth_timing_summary.rpt"

report_high_fanout_nets \
    -timing \
    -load_types \
    -max_nets 50 \
    -file "$RESULT_DIR/synth_high_fanout.rpt"

puts "SYNTH REPORTS = DONE"

close_design

# ============================================================
# 6. IMPLEMENTATION THROUGH ROUTE_DESIGN
# ============================================================

puts ""
puts "============================================================"
puts " IMPLEMENTATION"
puts "============================================================"

launch_runs impl_1 \
    -to_step route_design \
    -jobs 8

wait_on_run impl_1

set impl_status [get_property STATUS [get_runs impl_1]]

puts "IMPL STATUS = $impl_status"

if {![string match "*Complete*" $impl_status]} {
    puts "ERROR: implementation did not complete"
    close_project
    exit 4
}

open_run impl_1

# ============================================================
# 7. POST-ROUTE REPORTS
# ============================================================

report_timing_summary \
    -delay_type max \
    -max_paths 20 \
    -report_unconstrained \
    -check_timing_verbose \
    -file "$RESULT_DIR/impl_timing_summary.rpt"

report_utilization \
    -file "$RESULT_DIR/impl_utilization.rpt"

report_utilization \
    -hierarchical \
    -file "$RESULT_DIR/impl_utilization_hierarchical.rpt"

report_route_status \
    -file "$RESULT_DIR/impl_route_status.rpt"

report_clock_utilization \
    -file "$RESULT_DIR/impl_clock_utilization.rpt"

report_drc \
    -file "$RESULT_DIR/impl_drc.rpt"

# ============================================================
# 8. DIRECT WNS EXTRACTION
# ============================================================

set paths [get_timing_paths \
    -delay_type max \
    -max_paths 1 \
    -nworst 1]

set wns "NA"

if {[llength $paths] != 0} {
    set wns [get_property SLACK [lindex $paths 0]]
}

puts ""
puts "POST-ROUTE WNS = $wns ns"

set result PASS

if {$wns eq "NA"} {
    set result FAIL_NO_TIMING_PATH
} elseif {$wns < 0.0} {
    set result FAIL_TIMING
}

# ============================================================
# 9. WRITE MACHINE-READABLE SUMMARY
# ============================================================

set fp [open "$RESULT_DIR/M2_11_SUMMARY.txt" w]

puts $fp "M2.11 POST-ROUTE SUMMARY"
puts $fp "TOP=$TOP"
puts $fp "TARGET_CLOCK_MHZ=50"
puts $fp "TARGET_PERIOD_NS=20.000"
puts $fp "SYNTH_STATUS=$synth_status"
puts $fp "IMPL_STATUS=$impl_status"
puts $fp "POST_ROUTE_WNS_NS=$wns"
puts $fp "RESULT=$result"

close $fp

puts ""
puts "============================================================"
puts " M2.11 SUMMARY"
puts "============================================================"
puts "TARGET PERIOD   = 20.000 ns"
puts "POST-ROUTE WNS = $wns ns"
puts "RESULT          = $result"
puts "============================================================"

close_design
close_project

if {$result ne "PASS"} {
    exit 5
}

exit 0
