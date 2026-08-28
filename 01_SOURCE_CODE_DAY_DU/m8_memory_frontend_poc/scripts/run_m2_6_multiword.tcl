set ROOT [file normalize \
"/home/s23520579/Vivado_project/m8_memory_frontend_poc"]

set XPR "$ROOT/m8_memory_frontend_poc.xpr"

set TB \
"$ROOT/tb/tb_m8_memory_subsystem_optimized_pipe_multiword.sv"

puts ""
puts "============================================"
puts " M2.6 MULTIWORD PIPE TEST"
puts "============================================"

open_project $XPR

if {[llength [get_files -quiet $TB]] == 0} {
    add_files -fileset sim_1 -norecurse $TB
}

set_property file_type SystemVerilog [get_files $TB]

set_property top \
    tb_m8_memory_subsystem_optimized_pipe_multiword \
    [get_filesets sim_1]

puts "SIM TOP = [get_property top [get_filesets sim_1]]"

if {[current_sim -quiet] ne ""} {
    close_sim
}

reset_simulation

launch_simulation \
    -simset sim_1 \
    -mode behavioral

# Allow full packed-panel transaction if initial tclbatch
# has not already reached $finish.
if {[current_sim -quiet] ne ""} {
    run 120 us
    close_sim
}

puts ""
puts "============================================"
puts " M2.6 MULTIWORD XSIM COMPLETE"
puts "============================================"

close_project
exit 0
