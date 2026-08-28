set ROOT [file normalize \
"/home/s23520579/Vivado_project/m8_memory_frontend_poc"]

set XPR "$ROOT/m8_memory_frontend_poc.xpr"

set FE \
"$ROOT/rtl/optimized/vit_phase_e_memory_frontend_optimized.sv"

set BACKUP \
"$ROOT/results/optimized/vit_phase_e_memory_frontend_optimized.pre_m2_6H3.sv"

puts ""
puts "=============================================="
puts " M2.6 H3 - PIPE PROFILING FIX"
puts "=============================================="

if {![file exists $FE]} {
    puts "ERROR: frontend missing"
    exit 1
}

set fd [open $FE r]
set txt [read $fd]
close $fd

# ------------------------------------------------------------
# PRECHECK: H2 must already be active.
# ------------------------------------------------------------

set select_pos [string first "MEM_READ_SELECT: begin" $txt]
set pipe_pos   [string first "MEM_READ_PIPE: begin" $txt]

if {($select_pos < 0) || ($pipe_pos <= $select_pos)} {
    puts "ERROR: FSM anchors invalid"
    exit 2
}

set select_area \
    [string range $txt $select_pos [expr {$pipe_pos - 1}]]

if {[string first \
    "mem_state <= MEM_READ_PIPE;" \
    $select_area] < 0} {

    puts "ERROR: H2 pipeline activation missing"
    exit 3
}

puts "H2 PIPE ACTIVATION = PASS"

# ------------------------------------------------------------
# BACKUP
# ------------------------------------------------------------

file copy -force $FE $BACKUP
puts "BACKUP = $BACKUP"

set lines [split $txt "\n"]

# ============================================================
# 1. REPLACE profile_logical_read_word_o
# ============================================================

set p_start -1
set p_end   -1

for {set i 0} {$i < [llength $lines]} {incr i} {

    set t [string trim [lindex $lines $i]]

    if {$t eq "assign profile_logical_read_word_o ="} {
        set p_start $i
        continue
    }

    if {
        ($p_start >= 0) &&
        ($t eq "assign profile_logical_write_word_o =")
    } {
        set p_end [expr {$i - 1}]
        break
    }
}

puts "PROFILE READ START = $p_start"
puts "PROFILE READ END   = $p_end"

if {($p_start < 0) || ($p_end < $p_start)} {
    puts "ERROR: profile_logical_read_word_o block not found"
    exit 4
}

set new_profile_read [list \
    {    // Historical/cache/linefill reads are counted in SELECT.} \
    {    // Scalar pipeline reads are counted when actually accepted.} \
    {    assign profile_logical_read_word_o =} \
    {        ((mem_state == MEM_READ_SELECT) &&} \
    {         read_candidate_needed &&} \
    {         (read_candidate_space != PHASE_E_MEM_NONE) &&} \
    {         !read_candidate_address_overflow &&} \
    {         !read_pipe_candidate) ||} \
    {        read_pipe_req_fire;} \
]

set lines \
    [lreplace $lines $p_start $p_end {*}$new_profile_read]

# ============================================================
# 2. ADD MEM_READ_PIPE TO profile_load_active_o
# ============================================================

set load_start -1
set load_end   -1

for {set i 0} {$i < [llength $lines]} {incr i} {

    set t [string trim [lindex $lines $i]]

    if {$t eq "assign profile_load_active_o ="} {
        set load_start $i
        continue
    }

    if {
        ($load_start >= 0) &&
        ($t eq "assign profile_store_active_o =")
    } {
        set load_end [expr {$i - 1}]
        break
    }
}

if {($load_start < 0) || ($load_end < $load_start)} {
    puts "ERROR: profile_load_active_o block not found"
    exit 5
}

set old_load \
    [join [lrange $lines $load_start $load_end] "\n"]

if {[string first "(mem_state == MEM_READ_PIPE)" $old_load] < 0} {

    set anchor \
        "        (mem_state == MEM_READ_DELIVER) ||"

    set pos [string first $anchor $old_load]

    if {$pos < 0} {
        puts "ERROR: load-active insertion anchor missing"
        exit 6
    }

    set replacement \
"        (mem_state == MEM_READ_DELIVER) ||
        (mem_state == MEM_READ_PIPE) ||"

    set old_load \
        [string replace \
            $old_load \
            $pos \
            [expr {$pos + [string length $anchor] - 1}] \
            $replacement]
}

set load_new_lines [split $old_load "\n"]

set lines \
    [lreplace $lines $load_start $load_end {*}$load_new_lines]

# ============================================================
# 3. ADD PIPE RESPONSE ERROR TO frontend error profile
# ============================================================

set err_start -1
set err_end   -1

for {set i 0} {$i < [llength $lines]} {incr i} {

    set t [string trim [lindex $lines $i]]

    if {$t eq "assign profile_frontend_error_o ="} {
        set err_start $i
        continue
    }

    if {
        ($err_start >= 0) &&
        ($t eq "assign profile_a_vector_protocol_error_o =")
    } {
        set err_end [expr {$i - 1}]
        break
    }
}

if {($err_start < 0) || ($err_end < $err_start)} {
    puts "ERROR: frontend error profile block not found"
    exit 7
}

set old_err \
    [join [lrange $lines $err_start $err_end] "\n"]

if {[string first \
    "read_pipe_rsp_fire && mem_rsp_error" \
    $old_err] < 0} {

    set anchor \
"        gemm_a_vector_coordinate_error ||"

    set pos [string first $anchor $old_err]

    if {$pos < 0} {
        puts "ERROR: error-profile insertion anchor missing"
        exit 8
    }

    set replacement \
"        (read_pipe_rsp_fire && mem_rsp_error) ||
        gemm_a_vector_coordinate_error ||"

    set old_err \
        [string replace \
            $old_err \
            $pos \
            [expr {$pos + [string length $anchor] - 1}] \
            $replacement]
}

set err_new_lines [split $old_err "\n"]

set lines \
    [lreplace $lines $err_start $err_end {*}$err_new_lines]

set newtxt [join $lines "\n"]

# ============================================================
# STATIC VERIFY
# ============================================================

foreach p {
    "read_pipe_req_fire;"
    "!read_pipe_candidate"
    "(mem_state == MEM_READ_PIPE) ||"
    "(read_pipe_rsp_fire && mem_rsp_error)"
} {
    if {[string first $p $newtxt] < 0} {
        puts "ERROR: missing patched pattern: $p"
        exit 9
    }
}

puts ""
puts "PIPE LOGICAL READ PROFILE = CONNECTED"
puts "PIPE LOAD ACTIVE          = CONNECTED"
puts "PIPE ERROR PROFILE        = CONNECTED"
puts "STATIC PROFILING CHECK    = PASS"

# ============================================================
# WRITE SOURCE
# ============================================================

set fd [open $FE w]
puts -nonewline $fd $newtxt
close $fd

puts "SHA256 = [lindex [exec sha256sum $FE] 0]"

# ============================================================
# RUN SMOKE
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
puts " M2.6 H3 VIVADO/XSim RUN COMPLETE"
puts "=============================================="

close_project
exit 0
