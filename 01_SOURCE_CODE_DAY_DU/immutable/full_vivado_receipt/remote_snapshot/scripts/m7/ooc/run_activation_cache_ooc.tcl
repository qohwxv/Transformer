# Vivado 2023.2 bounded OOC implementation for the M7 R8 activation cache.
# Usage:
#   vivado -mode batch -source run_activation_cache_ooc.tcl -tclargs OUT_DIR

proc m7_cache_fail {message} {
    error "M7_CACHE_OOC_FAIL $message"
}

proc m7_cache_write {path value} {
    set handle [open $path w]
    puts $handle $value
    close $handle
}

if {$argc != 1} {
    m7_cache_fail "usage: run_activation_cache_ooc.tcl OUT_DIR"
}

set out_dir [file normalize [lindex $argv 0]]
set report_dir [file join $out_dir reports]
set artifact_dir [file join $out_dir artifacts]
file mkdir $report_dir
file mkdir $artifact_dir

set script_dir [file normalize [file dirname [info script]]]
set m7_root [file normalize [file join $script_dir ../../..]]
set rtl_file [file join $m7_root rtl blocks gemm \
    vit_gemm_activation_panel_cache.sv]
set expected_version "2023.2"
set part "xczu5ev-sfvc784-1-e"
set top "vit_gemm_activation_panel_cache"

if {[version -short] ne $expected_version} {
    m7_cache_fail "Vivado=[version -short] expected=$expected_version"
}
if {[llength [get_parts -quiet $part]] != 1} {
    m7_cache_fail "part unavailable: $part"
}
if {![file exists $rtl_file]} {
    m7_cache_fail "missing RTL: $rtl_file"
}

set_param general.maxThreads 1
create_project -in_memory -part $part
set_property target_language Verilog [current_project]
read_verilog -sv $rtl_file

synth_design \
    -top $top \
    -part $part \
    -mode out_of_context \
    -flatten_hierarchy none \
    -max_dsp 0 \
    -generic {ARRAY_ROWS=8 DEPTH_WORDS_PER_ROW=3072}

create_clock -name clk -period 20.000 [get_ports clk]
set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports clk]
set data_inputs [get_ports -quiet -filter \
    {DIRECTION == IN && NAME != clk}]
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

set dsp_cells [get_cells -quiet -hierarchical \
    -filter {REF_NAME =~ DSP48* || REF_NAME =~ DSP58*}]
set ramb36_cells [get_cells -quiet -hierarchical \
    -filter {REF_NAME =~ RAMB36*}]
set ramb18_cells [get_cells -quiet -hierarchical \
    -filter {REF_NAME =~ RAMB18*}]
set uram_cells [get_cells -quiet -hierarchical \
    -filter {REF_NAME =~ URAM*}]
set blackboxes [get_cells -quiet -hierarchical \
    -filter {IS_BLACKBOX == 1}]
set latches [get_cells -quiet -hierarchical \
    -filter {REF_NAME =~ LD*}]

if {[llength $dsp_cells] != 0} {
    m7_cache_fail "post_synth DSP count=[llength $dsp_cells]"
}
if {[llength $ramb36_cells] != 32 || [llength $ramb18_cells] != 0} {
    m7_cache_fail "post_synth RAMB36=[llength $ramb36_cells] RAMB18=[llength $ramb18_cells] expected=32/0"
}
if {[llength $uram_cells] != 0 || [llength $blackboxes] != 0 ||
    [llength $latches] != 0} {
    m7_cache_fail "post_synth URAM=[llength $uram_cells] blackbox=[llength $blackboxes] latch=[llength $latches]"
}

report_utilization -hierarchical \
    -file [file join $report_dir post_synth_utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -file \
    [file join $report_dir post_synth_timing_summary.rpt]
write_checkpoint -force [file join $artifact_dir post_synth.dcp]

opt_design
place_design -directive Quick
phys_opt_design -directive Explore
route_design -directive Quick

report_utilization -hierarchical \
    -file [file join $report_dir post_route_utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose -file \
    [file join $report_dir post_route_timing_summary.rpt]
report_route_status -file [file join $report_dir post_route_status.rpt]
report_drc -file [file join $report_dir post_route_drc.rpt]
report_methodology -file [file join $report_dir post_route_methodology.rpt]
write_checkpoint -force [file join $artifact_dir post_route.dcp]

set dsp_cells [get_cells -quiet -hierarchical \
    -filter {REF_NAME =~ DSP48* || REF_NAME =~ DSP58*}]
set ramb36_cells [get_cells -quiet -hierarchical \
    -filter {REF_NAME =~ RAMB36*}]
set ramb18_cells [get_cells -quiet -hierarchical \
    -filter {REF_NAME =~ RAMB18*}]
set uram_cells [get_cells -quiet -hierarchical \
    -filter {REF_NAME =~ URAM*}]
set blackboxes [get_cells -quiet -hierarchical \
    -filter {IS_BLACKBOX == 1}]
set latches [get_cells -quiet -hierarchical \
    -filter {REF_NAME =~ LD*}]
set setup_paths [get_timing_paths -quiet -delay_type max \
    -max_paths 1 -nworst 1]
set hold_paths [get_timing_paths -quiet -delay_type min \
    -max_paths 1 -nworst 1]
if {[llength $setup_paths] == 0} {
    m7_cache_fail "post_route has no setup path"
}
set wns [get_property SLACK [lindex $setup_paths 0]]
set whs "N/A"
if {[llength $hold_paths] != 0} {
    set hold_slack [get_property SLACK [lindex $hold_paths 0]]
    if {$hold_slack ne ""} {
        set whs $hold_slack
    }
}
set route_status [report_route_status -return_string]
set routed_nets -1
set routable_nets -1
set route_errors -1
regexp {# of routable nets[^:]*:[ \t]*([0-9,]+)} \
    $route_status -> routable_nets
regexp {# of fully routed nets[^:]*:[ \t]*([0-9,]+)} \
    $route_status -> routed_nets
regexp {# of nets with routing errors[^:]*:[ \t]*([0-9,]+)} \
    $route_status -> route_errors

if {[llength $dsp_cells] != 0} {
    m7_cache_fail "post_route DSP count=[llength $dsp_cells]"
}
if {[llength $ramb36_cells] != 32 || [llength $ramb18_cells] != 0} {
    m7_cache_fail "post_route RAMB36=[llength $ramb36_cells] RAMB18=[llength $ramb18_cells] expected=32/0"
}
if {[llength $uram_cells] != 0 || [llength $blackboxes] != 0 ||
    [llength $latches] != 0} {
    m7_cache_fail "post_route URAM=[llength $uram_cells] blackbox=[llength $blackboxes] latch=[llength $latches]"
}
if {[expr {double($wns) < 0.0}]} {
    m7_cache_fail "post_route timing WNS=$wns WHS=$whs"
}
if {$whs ne "N/A" && [expr {double($whs) < 0.0}]} {
    m7_cache_fail "post_route timing WNS=$wns WHS=$whs"
}
if {$routed_nets ne $routable_nets} {
    m7_cache_fail "post_route routed=$routed_nets routable=$routable_nets"
}
if {$route_errors != 0} {
    m7_cache_fail "post_route route_errors=$route_errors"
}

set summary [join [list \
    "EVIDENCE_SCOPE=standalone_activation_cache_ooc" \
    "VIVADO=[version -short]" \
    "PART=$part" \
    "CLOCK_MHZ=50" \
    "ARRAY_ROWS=8" \
    "DEPTH_WORDS_PER_ROW=3072" \
    "RAMB36=[llength $ramb36_cells]" \
    "RAMB18=[llength $ramb18_cells]" \
    "URAM=[llength $uram_cells]" \
    "DSP48_DSP58=[llength $dsp_cells]" \
    "BLACKBOX=[llength $blackboxes]" \
    "LATCH=[llength $latches]" \
    "WNS_NS=$wns" \
    "WHS_NS=$whs" \
    "ROUTED_NETS=$routed_nets" \
    "ROUTABLE_NETS=$routable_nets" \
    "ROUTE_ERRORS=$route_errors" \
    "CAVEAT=OOC boundary hold is false-pathed; this is not full-chip timing" \
] "\n"]
m7_cache_write [file join $out_dir SUMMARY.txt] $summary
puts $summary
puts "M7_CACHE_OOC_PASS rows=8 depth=3072 clock_mhz=50 bram36=32 dsp=0 WNS=$wns WHS=$whs"
