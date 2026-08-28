set ROOT [file normalize \
"/home/s23520579/Vivado_project/m8_memory_frontend_poc"]

set XPR "$ROOT/m8_memory_frontend_poc.xpr"

set OUT \
"$ROOT/results/optimized/m7/m7_2a/ooc"

set TOP \
"vit_m8_memory_subsystem_optimized"

set PART \
"xczu5ev-sfvc784-1-e"

file mkdir $OUT

puts ""
puts "============================================================"
puts " M7.2A OOC POST-ROUTE @ 50 MHz"
puts "============================================================"

# ------------------------------------------------------------
# OPEN PROJECT
# ------------------------------------------------------------

open_project $XPR

set_property top $TOP [get_filesets sources_1]
update_compile_order -fileset sources_1

puts "TOP  = $TOP"
puts "PART = $PART"

# ------------------------------------------------------------
# OOC SYNTHESIS
#
# Critical point:
# -mode out_of_context prevents thousands of subsystem ports
# from becoming package I/O buffers.
# ------------------------------------------------------------

puts ""
puts "================ SYNTH OOC ================="

synth_design \
    -top $TOP \
    -part $PART \
    -mode out_of_context \
    -flatten_hierarchy rebuilt

# ------------------------------------------------------------
# CLOCK
# ------------------------------------------------------------

set clk_ports [get_ports -quiet aclk]

if {[llength $clk_ports] != 1} {
    puts "ERROR: expected exactly one aclk port"
    exit 1
}

create_clock \
    -name aclk \
    -period 20.000 \
    $clk_ports

puts "CLOCK PERIOD = 20.000 ns"

# ------------------------------------------------------------
# SYNTH REPORTS
# ------------------------------------------------------------

report_utilization \
    -file "$OUT/synth_utilization.rpt"

report_timing_summary \
    -delay_type max \
    -max_paths 20 \
    -file "$OUT/synth_timing_summary.rpt"

write_checkpoint -force \
    "$OUT/post_synth_ooc.dcp"

# ------------------------------------------------------------
# OPT
# ------------------------------------------------------------

puts ""
puts "================ OPT DESIGN ================="

opt_design

write_checkpoint -force \
    "$OUT/post_opt_ooc.dcp"

# ------------------------------------------------------------
# PLACE
# ------------------------------------------------------------

puts ""
puts "================ PLACE DESIGN ==============="

place_design

write_checkpoint -force \
    "$OUT/post_place_ooc.dcp"

# ------------------------------------------------------------
# PHYS OPT
# ------------------------------------------------------------

puts ""
puts "================ PHYS OPT ==================="

phys_opt_design

write_checkpoint -force \
    "$OUT/post_physopt_ooc.dcp"

# ------------------------------------------------------------
# ROUTE
# ------------------------------------------------------------

puts ""
puts "================ ROUTE DESIGN ==============="

route_design

write_checkpoint -force \
    "$OUT/post_route_ooc.dcp"

# ------------------------------------------------------------
# REPORTS
# ------------------------------------------------------------

report_timing_summary \
    -delay_type max \
    -max_paths 50 \
    -report_unconstrained \
    -check_timing_verbose \
    -file "$OUT/impl_timing_summary.rpt"

report_utilization \
    -file "$OUT/impl_utilization.rpt"

report_utilization \
    -hierarchical \
    -file "$OUT/impl_utilization_hierarchical.rpt"

report_route_status \
    -file "$OUT/impl_route_status.rpt"

report_drc \
    -file "$OUT/impl_drc.rpt"

report_clock_utilization \
    -file "$OUT/impl_clock_utilization.rpt"

# ------------------------------------------------------------
# EXTRACT WNS
# ------------------------------------------------------------

set paths [get_timing_paths \
    -delay_type max \
    -max_paths 1 \
    -nworst 1]

set wns "NA"

if {[llength $paths] > 0} {
    set wns [get_property SLACK [lindex $paths 0]]
}

puts ""
puts "============================================================"
puts " M7.2A OOC RESULT"
puts "============================================================"
puts "TARGET PERIOD = 20.000 ns"
puts "POST-ROUTE WNS = $wns ns"

set result PASS

if {$wns eq "NA"} {
    set result FAIL_NO_TIMING_PATH
} elseif {$wns < 0.0} {
    set result FAIL_TIMING
}

puts "RESULT = $result"
puts "============================================================"

set fp [open "$OUT/M7_2A_OOC_SUMMARY.txt" w]

puts $fp "M7.2A OOC POST-ROUTE"
puts $fp "TOP=$TOP"
puts $fp "PART=$PART"
puts $fp "TARGET_CLOCK_MHZ=50"
puts $fp "TARGET_PERIOD_NS=20.000"
puts $fp "POST_ROUTE_WNS_NS=$wns"
puts $fp "RESULT=$result"

close $fp

close_project

if {$result ne "PASS"} {
    exit 2
}

exit 0
