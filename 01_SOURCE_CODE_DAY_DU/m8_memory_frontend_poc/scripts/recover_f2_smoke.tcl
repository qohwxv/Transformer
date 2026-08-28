set ROOT [file normalize \
"/home/s23520579/Vivado_project/m8_memory_frontend_poc"]

set XPR "$ROOT/m8_memory_frontend_poc.xpr"

set FE \
"$ROOT/rtl/optimized/vit_phase_e_memory_frontend_optimized.sv"

set F2 \
"$ROOT/results/optimized/vit_phase_e_memory_frontend_optimized.pre_m2_6F3A.sv"

puts ""
puts "========================================"
puts " M8 HEADLESS RECOVER F2"
puts "========================================"

foreach f [list $XPR $FE $F2] {
    if {![file exists $f]} {
        puts "ERROR: missing $f"
        exit 1
    }
}

# Save current frontend before restore.
file copy -force \
    $FE \
    "$ROOT/results/optimized/frontend_before_headless_recovery.sv"

# Restore known clean F2 checkpoint.
file copy -force $F2 $FE

set expected_sha \
"1c88585bd35b8e7e600f0dd2834f5e5e6d574b9d5e7a7174883f2d1c73713d1a"

set actual_sha [lindex [exec sha256sum $FE] 0]

puts "EXPECTED SHA = $expected_sha"
puts "ACTUAL SHA   = $actual_sha"

if {$actual_sha ne $expected_sha} {
    puts "ERROR: SHA mismatch"
    exit 2
}

puts "SHA CHECK = PASS"

# ------------------------------------------------------------
# Structural check
# ------------------------------------------------------------

set fd [open $FE r]
set txt [read $fd]
close $fd

set pipe_body \
    [expr {[string first "MEM_READ_PIPE: begin" $txt] >= 0}]

set select_pos \
    [string first "MEM_READ_SELECT: begin" $txt]

set pipe_pos \
    [string first "MEM_READ_PIPE: begin" $txt]

set select_to_pipe 0

if {($select_pos >= 0) && ($pipe_pos > $select_pos)} {
    set area \
        [string range $txt $select_pos [expr {$pipe_pos - 1}]]

    set select_to_pipe \
        [expr {[string first \
            "mem_state <= MEM_READ_PIPE;" \
            $area] >= 0}]
}

puts "PIPE BODY           = $pipe_body"
puts "READ_SELECT -> PIPE = $select_to_pipe"

if {$pipe_body != 1} {
    puts "ERROR: MEM_READ_PIPE body missing"
    exit 3
}

if {$select_to_pipe != 0} {
    puts "ERROR: MEM_READ_PIPE already active"
    exit 4
}

puts "F2 STRUCTURE CHECK = PASS"

# ------------------------------------------------------------
# Open project + run XSim
# ------------------------------------------------------------

open_project $XPR

set_property top \
    tb_m8_memory_subsystem_optimized_smoke \
    [get_filesets sim_1]

puts "SIM TOP = [get_property top [get_filesets sim_1]]"

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

puts ""
puts "========================================"
puts " VIVADO/XSim RUN COMPLETE"
puts "========================================"

close_project
exit 0
