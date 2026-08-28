set XPR "/home/s23520579/Vivado_project/m8_memory_frontend_poc/m8_memory_frontend_poc.xpr"
set TOP "vit_m8_memory_subsystem_optimized"
set PART "xczu5ev-sfvc784-1-e"
set OUT "/home/s23520579/Vivado_project/m8_memory_frontend_poc/results/optimized/m7/m7_2a/elab"

file mkdir $OUT

open_project $XPR

set_property top $TOP [current_fileset]
update_compile_order -fileset sources_1

puts ""
puts "============================================================"
puts " M7.2A RTL ELABORATION"
puts "============================================================"

synth_design \
    -rtl \
    -top $TOP \
    -part $PART

puts ""
puts "M7.2A ELABORATION = PASS"

report_utilization \
    -file "$OUT/elab_utilization.rpt"

set fp [open "$OUT/M7_2A_ELAB_SUMMARY.txt" w]
puts $fp "M7.2A RTL ELABORATION"
puts $fp "TOP=$TOP"
puts $fp "PART=$PART"
puts $fp "RESULT=PASS"
close $fp

close_project
exit 0
