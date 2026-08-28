set ROOT [file normalize \
"/home/s23520579/Vivado_project/m8_memory_frontend_poc"]

open_project "$ROOT/m8_memory_frontend_poc.xpr"

set_property top \
    tb_m8_memory_subsystem_optimized_smoke \
    [get_filesets sim_1]

if {[current_sim -quiet] ne ""} {
    close_sim
}

reset_simulation

launch_simulation \
    -simset sim_1 \
    -mode behavioral

if {[current_sim -quiet] ne ""} {
    close_sim
}

close_project
exit 0
