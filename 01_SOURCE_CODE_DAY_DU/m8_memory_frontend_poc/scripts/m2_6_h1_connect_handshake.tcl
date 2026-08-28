set ROOT [file normalize \
"/home/s23520579/Vivado_project/m8_memory_frontend_poc"]

set XPR "$ROOT/m8_memory_frontend_poc.xpr"

set FE \
"$ROOT/rtl/optimized/vit_phase_e_memory_frontend_optimized.sv"

set BACKUP \
"$ROOT/results/optimized/vit_phase_e_memory_frontend_optimized.pre_m2_6H1.sv"

puts ""
puts "=============================================="
puts " M2.6 H1 - CONNECT PIPE HANDSHAKE"
puts "=============================================="

if {![file exists $FE]} {
    puts "ERROR: frontend missing"
    exit 1
}

# ------------------------------------------------------------
# READ SOURCE
# ------------------------------------------------------------

set fd [open $FE r]
set txt [read $fd]
close $fd

# PIPE body must already exist.
if {[string first "MEM_READ_PIPE: begin" $txt] < 0} {
    puts "ERROR: MEM_READ_PIPE body missing"
    exit 2
}

# PIPE must still be unreachable from READ_SELECT.
set select_pos [string first "MEM_READ_SELECT: begin" $txt]
set pipe_pos   [string first "MEM_READ_PIPE: begin" $txt]

if {($select_pos < 0) || ($pipe_pos <= $select_pos)} {
    puts "ERROR: FSM anchors invalid"
    exit 3
}

set select_area \
    [string range $txt $select_pos [expr {$pipe_pos - 1}]]

if {[string first \
    "mem_state <= MEM_READ_PIPE;" \
    $select_area] >= 0} {

    puts "ERROR: pipeline already active"
    exit 4
}

puts "PRECHECK READ_SELECT -> PIPE = 0"

# ------------------------------------------------------------
# BACKUP
# ------------------------------------------------------------

file copy -force $FE $BACKUP

puts "BACKUP = $BACKUP"

# ------------------------------------------------------------
# LINE-BASED PATCH
# ------------------------------------------------------------

set lines [split $txt "\n"]

# -------------------------
# mem_req_valid block
# -------------------------

set req_start -1
set req_end   -1

for {set i 0} {$i < [llength $lines]} {incr i} {

    set t [string trim [lindex $lines $i]]

    if {$t eq "assign mem_req_valid ="} {
        set req_start $i
        continue
    }

    if {
        ($req_start >= 0) &&
        ($t eq "assign mem_req_write = (mem_state == MEM_WRITE_REQUEST);")
    } {
        set req_end [expr {$i - 1}]
        break
    }
}

puts "REQ START = $req_start"
puts "REQ END   = $req_end"

if {($req_start < 0) || ($req_end < $req_start)} {
    puts "ERROR: mem_req_valid block not found"
    exit 5
}

set new_req [list \
    {    assign mem_req_valid =} \
    {        (mem_state == MEM_READ_REQUEST) ||} \
    {        (mem_state == MEM_WRITE_REQUEST) ||} \
    {        read_pipe_can_issue;} \
]

set lines \
    [lreplace $lines $req_start $req_end {*}$new_req]

# -------------------------
# mem_rsp_ready block
# -------------------------

set rsp_start -1
set rsp_end   -1

for {set i 0} {$i < [llength $lines]} {incr i} {

    set t [string trim [lindex $lines $i]]

    if {$t eq "assign mem_rsp_ready ="} {
        set rsp_start $i
        continue
    }

    if {
        ($rsp_start >= 0) &&
        ($t eq "assign gemm_data_valid =")
    } {
        set rsp_end [expr {$i - 1}]
        break
    }
}

puts "RSP START = $rsp_start"
puts "RSP END   = $rsp_end"

if {($rsp_start < 0) || ($rsp_end < $rsp_start)} {
    puts "ERROR: mem_rsp_ready block not found"
    exit 6
}

set new_rsp [list \
    {    assign mem_rsp_ready =} \
    {        (mem_state == MEM_READ_RESPONSE) ||} \
    {        (mem_state == MEM_WRITE_RESPONSE) ||} \
    {        ((mem_state == MEM_READ_PIPE) &&} \
    {         (read_meta_count != 0));} \
    {} \
]

set lines \
    [lreplace $lines $rsp_start $rsp_end {*}$new_rsp]

set newtxt [join $lines "\n"]

# ------------------------------------------------------------
# STATIC VERIFY BEFORE WRITE
# ------------------------------------------------------------

set req_pos [string first "assign mem_req_valid =" $newtxt]
set req_area \
    [string range $newtxt $req_pos [expr {$req_pos + 400}]]

if {[string first "read_pipe_can_issue;" $req_area] < 0} {
    puts "ERROR: PIPE request handshake not connected"
    exit 7
}

set rsp_pos [string first "assign mem_rsp_ready =" $newtxt]
set rsp_area \
    [string range $newtxt $rsp_pos [expr {$rsp_pos + 400}]]

if {[string first "MEM_READ_PIPE" $rsp_area] < 0} {
    puts "ERROR: PIPE response handshake not connected"
    exit 8
}

# Confirm READ_SELECT still does not enter PIPE.
set select_pos2 [string first "MEM_READ_SELECT: begin" $newtxt]
set pipe_pos2   [string first "MEM_READ_PIPE: begin" $newtxt]

set select_area2 \
    [string range $newtxt $select_pos2 [expr {$pipe_pos2 - 1}]]

if {[string first \
    "mem_state <= MEM_READ_PIPE;" \
    $select_area2] >= 0} {

    puts "ERROR: READ_SELECT -> PIPE changed unexpectedly"
    exit 9
}

puts ""
puts "PIPE -> mem_req_valid = 1"
puts "PIPE -> mem_rsp_ready = 1"
puts "READ_SELECT -> PIPE   = 0"
puts "STATIC CHECK          = PASS"

# ------------------------------------------------------------
# WRITE SOURCE
# ------------------------------------------------------------

set fd [open $FE w]
puts -nonewline $fd $newtxt
close $fd

puts "SHA256 = [lindex [exec sha256sum $FE] 0]"

# ------------------------------------------------------------
# OPEN PROJECT + RUN SMOKE
# ------------------------------------------------------------

open_project $XPR

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

puts ""
puts "=============================================="
puts " M2.6 H1 VIVADO/XSim RUN COMPLETE"
puts "=============================================="

close_project
exit 0
