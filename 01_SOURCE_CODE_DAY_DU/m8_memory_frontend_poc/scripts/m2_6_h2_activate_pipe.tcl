set ROOT [file normalize \
"/home/s23520579/Vivado_project/m8_memory_frontend_poc"]

set XPR "$ROOT/m8_memory_frontend_poc.xpr"

set FE \
"$ROOT/rtl/optimized/vit_phase_e_memory_frontend_optimized.sv"

set BACKUP \
"$ROOT/results/optimized/vit_phase_e_memory_frontend_optimized.pre_m2_6H2.sv"

puts ""
puts "=============================================="
puts " M2.6 H2 - ACTIVATE MEM_READ_PIPE"
puts "=============================================="

if {![file exists $FE]} {
    puts "ERROR: frontend missing"
    exit 1
}

# ============================================================
# READ SOURCE
# ============================================================

set fd [open $FE r]
set txt [read $fd]
close $fd

# PIPE body must exist.
if {[string first "MEM_READ_PIPE: begin" $txt] < 0} {
    puts "ERROR: MEM_READ_PIPE body missing"
    exit 2
}

# ============================================================
# VERIFY H1 HANDSHAKE EXISTS
# ============================================================

set req_pos [string first "assign mem_req_valid =" $txt]

if {$req_pos < 0} {
    puts "ERROR: mem_req_valid missing"
    exit 3
}

set req_area \
    [string range $txt $req_pos [expr {$req_pos + 500}]]

if {[string first "read_pipe_can_issue" $req_area] < 0} {
    puts "ERROR: H1 request handshake missing"
    exit 4
}

set rsp_pos [string first "assign mem_rsp_ready =" $txt]

if {$rsp_pos < 0} {
    puts "ERROR: mem_rsp_ready missing"
    exit 5
}

set rsp_area \
    [string range $txt $rsp_pos [expr {$rsp_pos + 500}]]

if {[string first "MEM_READ_PIPE" $rsp_area] < 0} {
    puts "ERROR: H1 response handshake missing"
    exit 6
}

puts "H1 REQUEST HANDSHAKE = PASS"
puts "H1 RESPONSE HANDSHAKE = PASS"

# ============================================================
# FIND READ_SELECT / PIPE RANGE
# ============================================================

set lines [split $txt "\n"]

set select_start -1
set pipe_start   -1

for {set i 0} {$i < [llength $lines]} {incr i} {

    set t [string trim [lindex $lines $i]]

    if {$t eq "MEM_READ_SELECT: begin"} {
        set select_start $i
        continue
    }

    if {
        ($select_start >= 0) &&
        ($t eq "MEM_READ_PIPE: begin")
    } {
        set pipe_start $i
        break
    }
}

puts "READ_SELECT START = $select_start"
puts "READ_PIPE START   = $pipe_start"

if {($select_start < 0) || ($pipe_start <= $select_start)} {
    puts "ERROR: FSM range invalid"
    exit 7
}

# PIPE must still be unreachable before this patch.
set current_select_area \
    [join [lrange $lines $select_start [expr {$pipe_start - 1}]] "\n"]

if {[string first \
    "mem_state <= MEM_READ_PIPE;" \
    $current_select_area] >= 0} {

    puts "ERROR: pipeline already active"
    exit 8
}

puts "PRECHECK READ_SELECT -> PIPE = 0"

# ============================================================
# FIND EXACT HISTORICAL READ_REQUEST TRANSITION
# ============================================================

set request_line  -1
set request_count 0

for {set i $select_start} {$i < $pipe_start} {incr i} {

    if {[string trim [lindex $lines $i]] eq \
        "mem_state <= MEM_READ_REQUEST;"} {

        set request_line $i
        incr request_count
    }
}

puts "READ_REQUEST TRANSITIONS = $request_count"
puts "TARGET LINE              = $request_line"

if {$request_count != 1} {
    puts "ERROR: expected exactly one READ_REQUEST transition"
    exit 9
}

# ============================================================
# BACKUP
# ============================================================

file copy -force $FE $BACKUP

puts "BACKUP = $BACKUP"

# ============================================================
# PATCH ONLY THIS TRANSITION
# ============================================================

set replacement [list \
    {                            if (read_pipe_candidate)} \
    {                                mem_state <= MEM_READ_PIPE;} \
    {                            else} \
    {                                mem_state <= MEM_READ_REQUEST;} \
]

set lines \
    [lreplace \
        $lines \
        $request_line \
        $request_line \
        {*}$replacement]

set newtxt [join $lines "\n"]

# ============================================================
# STATIC VERIFY
# ============================================================

set select_pos2 \
    [string first "MEM_READ_SELECT: begin" $newtxt]

set pipe_pos2 \
    [string first "MEM_READ_PIPE: begin" $newtxt]

if {($select_pos2 < 0) || ($pipe_pos2 <= $select_pos2)} {
    puts "ERROR: patched FSM anchors invalid"
    exit 10
}

set select_area2 \
    [string range $newtxt $select_pos2 [expr {$pipe_pos2 - 1}]]

set pipe_transition_count 0
set search_pos 0

while {1} {

    set p [string first \
        "mem_state <= MEM_READ_PIPE;" \
        $select_area2 \
        $search_pos]

    if {$p < 0} {
        break
    }

    incr pipe_transition_count
    set search_pos [expr {$p + 1}]
}

puts ""
puts "READ_SELECT -> PIPE COUNT = $pipe_transition_count"

if {$pipe_transition_count != 1} {
    puts "ERROR: expected exactly one READ_SELECT -> PIPE transition"
    exit 11
}

if {[string first \
    "if (read_pipe_candidate)" \
    $select_area2] < 0} {

    puts "ERROR: read_pipe_candidate guard missing"
    exit 12
}

if {[string first \
    "mem_state <= MEM_READ_REQUEST;" \
    $select_area2] < 0} {

    puts "ERROR: historical READ_REQUEST fallback missing"
    exit 13
}

puts "READ_SELECT -> PIPE   = 1"
puts "READ_REQUEST FALLBACK = 1"
puts "STATIC ACTIVATION     = PASS"

# ============================================================
# WRITE SOURCE
# ============================================================

set fd [open $FE w]
puts -nonewline $fd $newtxt
close $fd

puts "SHA256 = [lindex [exec sha256sum $FE] 0]"

# ============================================================
# OPEN PROJECT + XSIM
# ============================================================

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
puts " M2.6 H2 VIVADO/XSim RUN COMPLETE"
puts "=============================================="

close_project
exit 0
