set ROOT [file normalize \
"/home/s23520579/Vivado_project/m8_memory_frontend_poc"]

set XPR "$ROOT/m8_memory_frontend_poc.xpr"

set ROUTER \
"$ROOT/rtl/optimized/vit_phase_e_read_address_router_optimized.sv"

open_project $XPR

if {[llength [get_files -quiet $ROUTER]] == 0} {
    add_files -fileset sources_1 -norecurse $ROUTER
}

set_property file_type SystemVerilog \
    [get_files $ROUTER]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "================================================"
puts "M3.2A OPTIMIZED ROUTER ADDED"
puts "================================================"
puts "FILE = $ROUTER"

close_project
exit 0
