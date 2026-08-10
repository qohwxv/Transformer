# Vivado 2023.2 standalone OOC implementation gate for the M8 LayerNorm
# row/gamma/beta buffers.  This is a leaf mapping/timing gate, not full-chip
# Genesys timing sign-off.
#
# Usage:
#   vivado -mode batch -source run_m8_layernorm_buffer_ooc.tcl \
#     -tclargs BUFFER_ENABLE OUT_DIR

proc m8_ln_fail {message} {
    error "M8_LAYERNORM_OOC_FAIL $message"
}

proc m8_ln_write {path text_value} {
    set handle [open $path w]
    puts $handle $text_value
    close $handle
}

proc m8_ln_no_loops {stage report_dir} {
    set result [check_timing -verbose -return_string \
        -override_defaults [list loops]]
    m8_ln_write [file join $report_dir ${stage}_loops.rpt] $result
    set count -1
    if {![regexp -nocase {There are ([0-9]+) combinational loops} \
          $result -> count] &&
        ![regexp -nocase {checking loops \(([0-9]+)\)} \
          $result -> count]} {
        m8_ln_fail "$stage cannot parse combinational-loop check"
    }
    if {$count != 0} {
        m8_ln_fail "$stage combinational_loops=$count"
    }
}

proc m8_ln_metrics {stage buffer_enable report_dir} {
    set dsp [get_cells -quiet -hierarchical \
        -filter {REF_NAME =~ DSP48* || REF_NAME =~ DSP58*}]
    set ramb36 [get_cells -quiet -hierarchical \
        -filter {REF_NAME =~ RAMB36*}]
    set ramb18 [get_cells -quiet -hierarchical \
        -filter {REF_NAME =~ RAMB18*}]
    set uram [get_cells -quiet -hierarchical \
        -filter {REF_NAME =~ URAM*}]
    set lutram [get_cells -quiet -hierarchical -filter {
        REF_NAME =~ RAM32M* || REF_NAME =~ RAM64M* ||
        REF_NAME =~ RAMD* || REF_NAME =~ RAMS* ||
        REF_NAME =~ RAM32X* || REF_NAME =~ RAM64X* ||
        REF_NAME =~ RAM128X* || REF_NAME =~ RAM256X* ||
        REF_NAME =~ RAM512X*
    }]
    set blackbox [get_cells -quiet -hierarchical \
        -filter {IS_BLACKBOX == 1}]
    set latch [get_cells -quiet -hierarchical \
        -filter {REF_NAME =~ LD*}]

    set result [dict create \
        dsp [llength $dsp] \
        ramb36 [llength $ramb36] \
        ramb18 [llength $ramb18] \
        uram [llength $uram] \
        lutram [llength $lutram] \
        blackbox [llength $blackbox] \
        latch [llength $latch]]

    set expected_ramb36 [expr {$buffer_enable ? 3 : 0}]
    if {[dict get $result dsp] != 0 ||
        [dict get $result ramb36] != $expected_ramb36 ||
        [dict get $result ramb18] != 0 ||
        [dict get $result uram] != 0 ||
        [dict get $result lutram] != 0 ||
        [dict get $result blackbox] != 0 ||
        [dict get $result latch] != 0} {
        m8_ln_fail "$stage enable=$buffer_enable DSP=[dict get $result dsp] RAMB36=[dict get $result ramb36] RAMB18=[dict get $result ramb18] URAM=[dict get $result uram] LUTRAM=[dict get $result lutram] blackbox=[dict get $result blackbox] latch=[dict get $result latch] expected_RAM36=$expected_ramb36 and all others zero"
    }

    m8_ln_write [file join $report_dir ${stage}_structure.txt] [join [list \
        "BUFFER_ENABLE=$buffer_enable" \
        "DSP48_DSP58=[dict get $result dsp]" \
        "RAMB36=[dict get $result ramb36]" \
        "RAMB18=[dict get $result ramb18]" \
        "URAM=[dict get $result uram]" \
        "LUTRAM=[dict get $result lutram]" \
        "BLACKBOX=[dict get $result blackbox]" \
        "LATCH=[dict get $result latch]" \
    ] "\n"]
    return $result
}

if {$argc != 2} {
    m8_ln_fail "usage: run_m8_layernorm_buffer_ooc.tcl BUFFER_ENABLE OUT_DIR"
}

set buffer_enable [lindex $argv 0]
if {$buffer_enable ni {0 1}} {
    m8_ln_fail "BUFFER_ENABLE must be 0 or 1"
}
set out_dir [file normalize [lindex $argv 1]]
set report_dir [file join $out_dir reports]
set artifact_dir [file join $out_dir artifacts]
file mkdir $report_dir
file mkdir $artifact_dir

set script_dir [file normalize [file dirname [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
set part xczu5ev-sfvc784-1-e
set top vit_layernorm_engine_fp32

if {[version -short] ne "2023.2"} {
    m8_ln_fail "Vivado=[version -short] expected=2023.2"
}
if {[llength [get_parts -quiet $part]] != 1} {
    m8_ln_fail "part unavailable: $part"
}

set sources [list \
    [file join $repo_root rtl leaf common vit_u32_mul_iterative_nodsp.sv] \
    [file join $repo_root rtl leaf fp32 vit_fp32_add_comb.sv] \
    [file join $repo_root rtl leaf fp32 vit_fp32_mul_comb_nodsp.sv] \
    [file join $repo_root rtl leaf fp32 vit_fp32_recip_u32_serial.sv] \
    [file join $repo_root rtl blocks layernorm vit_layernorm_engine_fp32.sv] \
]
foreach source $sources {
    if {![file isfile $source]} {
        m8_ln_fail "missing RTL: $source"
    }
}

set_param general.maxThreads 1
create_project -in_memory -part $part
set_property target_language Verilog [current_project]
read_verilog -sv $sources
synth_design \
    -top $top \
    -part $part \
    -mode out_of_context \
    -flatten_hierarchy none \
    -max_dsp 0 \
    -generic "USE_EXTERNAL_MUL=1 USE_EXTERNAL_ADD=1 ENABLE_ROW_AFFINE_BUFFER=$buffer_enable ROW_AFFINE_BUFFER_DEPTH=1024"

create_clock -name clk -period 20.000 [get_ports clk]
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]
set data_inputs [get_ports -quiet -filter \
    {DIRECTION == IN && NAME != clk && NAME != rst}]
set data_outputs [get_ports -quiet -filter {DIRECTION == OUT}]
if {[llength $data_inputs] != 0} {
    set_input_delay -clock clk -max 4.000 $data_inputs
    set_input_delay -clock clk -min 1.000 $data_inputs
    set_false_path -hold -from $data_inputs
}
if {[llength $data_outputs] != 0} {
    set_output_delay -clock clk -max 4.000 $data_outputs
    set_output_delay -clock clk -min -1.000 $data_outputs
    set_false_path -hold -to $data_outputs
}

set synth_metrics [m8_ln_metrics post_synth $buffer_enable $report_dir]
m8_ln_no_loops post_synth $report_dir
report_utilization -hierarchical \
    -file [file join $report_dir post_synth_utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose \
    -file [file join $report_dir post_synth_timing_summary.rpt]
write_checkpoint -force [file join $artifact_dir post_synth.dcp]

opt_design
place_design -directive Quick
phys_opt_design -directive ExploreWithAggressiveHoldFix
route_design -directive Explore

# The leaf is fail-closed on hold timing.  One bounded post-route repair is
# allowed because routed clock skew can expose a min-delay path that was not
# accurately visible after placement; any residual negative WHS is still
# rejected by the timing gate below.
set initial_hold_paths [get_timing_paths -quiet -delay_type min \
    -max_paths 1 -nworst 1]
if {[llength $initial_hold_paths] != 0} {
    set initial_whs [get_property SLACK [lindex $initial_hold_paths 0]]
    if {$initial_whs ne "" && [expr {double($initial_whs) < 0.0}]} {
        puts "M8_LAYERNORM_HOLD_REPAIR_BEGIN WHS=$initial_whs"
        phys_opt_design -aggressive_hold_fix
        route_design -directive Explore
        set repaired_hold_paths [get_timing_paths -quiet -delay_type min \
            -max_paths 1 -nworst 1]
        if {[llength $repaired_hold_paths] != 0} {
            puts "M8_LAYERNORM_HOLD_REPAIR_END WHS=[get_property SLACK [lindex $repaired_hold_paths 0]]"
        }
    }
}

set route_metrics [m8_ln_metrics post_route $buffer_enable $report_dir]
m8_ln_no_loops post_route $report_dir

set setup_paths [get_timing_paths -quiet -delay_type max \
    -max_paths 1 -nworst 1]
set hold_paths [get_timing_paths -quiet -delay_type min \
    -max_paths 1 -nworst 1]
if {[llength $setup_paths] == 0} {
    m8_ln_fail "post_route has no setup path"
}
set wns [get_property SLACK [lindex $setup_paths 0]]
set whs N/A
if {[llength $hold_paths] != 0} {
    set hold_value [get_property SLACK [lindex $hold_paths 0]]
    if {$hold_value ne ""} {
        set whs $hold_value
    }
}
if {[expr {double($wns) < 0.0}]} {
    m8_ln_fail "post_route WNS=$wns"
}
if {$whs ne "N/A" && [expr {double($whs) < 0.0}]} {
    m8_ln_fail "post_route WHS=$whs"
}

set route_text [report_route_status -return_string]
set routable -1
set routed -1
set route_errors -1
set explicit_gaps -1
regexp {# of routable nets[^:]*:[ \t]*([0-9,]+)} \
    $route_text -> routable
regexp {# of fully routed nets[^:]*:[ \t]*([0-9,]+)} \
    $route_text -> routed
regexp {# of nets with routing errors[^:]*:[ \t]*([0-9,]+)} \
    $route_text -> route_errors
regexp {# of nets with explicit gaps[^:]*:[ \t]*([0-9,]+)} \
    $route_text -> explicit_gaps
if {$routable ne $routed || $route_errors != 0 || $explicit_gaps > 1} {
    m8_ln_fail "route routable=$routable routed=$routed errors=$route_errors explicit_gaps=$explicit_gaps"
}

report_utilization -hierarchical \
    -file [file join $report_dir post_route_utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose \
    -file [file join $report_dir post_route_timing_summary.rpt]
report_route_status -file [file join $report_dir post_route_status.rpt]
report_drc -file [file join $report_dir post_route_drc.rpt]
report_methodology -file [file join $report_dir post_route_methodology.rpt]
write_checkpoint -force [file join $artifact_dir post_route.dcp]

set drc_severe [list]
foreach violation [get_drc_violations -quiet] {
    set severity [string toupper \
        [string trim [get_property SEVERITY $violation]]]
    if {[lsearch -exact \
        [list FATAL ERROR "CRITICAL WARNING"] $severity] >= 0} {
        lappend drc_severe $violation
    }
}
set methodology_severe [list]
foreach violation [get_methodology_violations -quiet] {
    set severity [string toupper \
        [string trim [get_property SEVERITY $violation]]]
    if {[lsearch -exact \
        [list FATAL ERROR "CRITICAL WARNING"] $severity] >= 0} {
        lappend methodology_severe $violation
    }
}
if {[llength $drc_severe] != 0 ||
    [llength $methodology_severe] != 0} {
    m8_ln_fail "DRC_severe=[llength $drc_severe] methodology_severe=[llength $methodology_severe]"
}

set summary [join [list \
    "RESULT=PASS" \
    "SCOPE=STANDALONE_M8_LAYERNORM_BUFFER_OOC" \
    "VIVADO=[version -short]" \
    "PART=$part" \
    "CLOCK_PERIOD_NS=20.000" \
    "BUFFER_ENABLE=$buffer_enable" \
    "ROW_AFFINE_BUFFER_DEPTH=1024" \
    "POST_SYNTH_RAMB36=[dict get $synth_metrics ramb36]" \
    "POST_ROUTE_RAMB36=[dict get $route_metrics ramb36]" \
    "POST_ROUTE_RAMB18=[dict get $route_metrics ramb18]" \
    "POST_ROUTE_URAM=[dict get $route_metrics uram]" \
    "POST_ROUTE_LUTRAM=[dict get $route_metrics lutram]" \
    "POST_ROUTE_DSP48_DSP58=[dict get $route_metrics dsp]" \
    "BLACKBOX=[dict get $route_metrics blackbox]" \
    "LATCH=[dict get $route_metrics latch]" \
    "COMBINATIONAL_LOOPS=0" \
    "WNS_NS=$wns" \
    "WHS_NS=$whs" \
    "ROUTABLE_NETS=$routable" \
    "FULLY_ROUTED_NETS=$routed" \
    "ROUTING_ERRORS=$route_errors" \
    "EXPLICIT_OOC_GAPS=$explicit_gaps" \
    "DRC_SEVERE=[llength $drc_severe]" \
    "METHODOLOGY_SEVERE=[llength $methodology_severe]" \
    "FULL_CHIP_TIMING_SIGNOFF=0" \
    "CAVEAT=OOC boundary hold is false-pathed; integration must repeat full-device timing" \
] "\n"]
m8_ln_write [file join $out_dir SUMMARY.txt] $summary
puts $summary
puts "M8_LAYERNORM_OOC_PASS enable=$buffer_enable ramb36=[dict get $route_metrics ramb36] ramb18=0 uram=0 lutram=0 dsp=0 loops=0 blackbox=0 latch=0 WNS=$wns WHS=$whs"
close_project
