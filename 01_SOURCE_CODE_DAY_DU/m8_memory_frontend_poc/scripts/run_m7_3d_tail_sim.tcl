set XPR "/home/s23520579/Vivado_project/m8_memory_frontend_poc/m8_memory_frontend_poc.xpr"
set TB  "/home/s23520579/Vivado_project/m8_memory_frontend_poc/tb/tb_m8_memory_subsystem_gemm_wide_write_tail.sv"
set TOP "tb_m8_memory_subsystem_gemm_wide_write_tail"

open_project $XPR

if {[llength [get_files -quiet $TB]] == 0} {
    add_files -fileset sim_1 $TB
}

set_property top $TOP [get_filesets sim_1]
update_compile_order -fileset sim_1

puts ""
puts "============================================================"
puts " M7.3D GEMM WRITE TAIL TEST"
puts "============================================================"

launch_simulation -mode behavioral
run all

close_sim
close_project
exit 0
