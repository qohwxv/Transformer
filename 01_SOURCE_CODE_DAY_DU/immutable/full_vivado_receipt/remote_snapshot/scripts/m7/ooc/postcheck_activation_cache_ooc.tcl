# Re-evaluate a completed M7 activation-cache OOC route checkpoint without
# repeating synthesis/place/route.  This is used when report generation
# completed but a later evidence-script check needs correction.
# Usage: vivado -mode batch -source postcheck_activation_cache_ooc.tcl \
#        -tclargs POST_ROUTE_DCP OUT_DIR

proc m7_cache_post_fail {message} {
    error "M7_CACHE_OOC_POSTCHECK_FAIL $message"
}

proc m7_cache_post_write {path value} {
    set handle [open $path w]
    puts $handle $value
    close $handle
}

if {$argc != 2} {
    m7_cache_post_fail "usage: postcheck_activation_cache_ooc.tcl POST_ROUTE_DCP OUT_DIR"
}
if {[version -short] ne "2023.2"} {
    m7_cache_post_fail "Vivado=[version -short] expected=2023.2"
}

set checkpoint [file normalize [lindex $argv 0]]
set out_dir [file normalize [lindex $argv 1]]
if {![file exists $checkpoint]} {
    m7_cache_post_fail "missing checkpoint: $checkpoint"
}
file mkdir $out_dir
set_param general.maxThreads 1
open_checkpoint $checkpoint

set dsp_count [llength [get_cells -quiet -hierarchical \
    -filter {REF_NAME =~ DSP48* || REF_NAME =~ DSP58*}]]
set ramb36_count [llength [get_cells -quiet -hierarchical \
    -filter {REF_NAME =~ RAMB36*}]]
set ramb18_count [llength [get_cells -quiet -hierarchical \
    -filter {REF_NAME =~ RAMB18*}]]
set uram_count [llength [get_cells -quiet -hierarchical \
    -filter {REF_NAME =~ URAM*}]]
set blackbox_count [llength [get_cells -quiet -hierarchical \
    -filter {IS_BLACKBOX == 1}]]
set latch_count [llength [get_cells -quiet -hierarchical \
    -filter {REF_NAME =~ LD*}]]

set setup_paths [get_timing_paths -quiet -delay_type max \
    -max_paths 1 -nworst 1]
if {[llength $setup_paths] == 0} {
    m7_cache_post_fail "no setup timing path"
}
set wns [get_property SLACK [lindex $setup_paths 0]]
set hold_paths [get_timing_paths -quiet -delay_type min \
    -max_paths 1 -nworst 1]
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
set explicit_gaps -1
regexp {# of routable nets[^:]*:[ \t]*([0-9,]+)} \
    $route_status -> routable_nets
regexp {# of fully routed nets[^:]*:[ \t]*([0-9,]+)} \
    $route_status -> routed_nets
regexp {# of nets with routing errors[^:]*:[ \t]*([0-9,]+)} \
    $route_status -> route_errors
regexp {# of nets with explicit gaps[^:]*:[ \t]*([0-9,]+)} \
    $route_status -> explicit_gaps

set drc_objects [get_drc_violations -quiet]
report_methodology -file [file join $out_dir postcheck_methodology.rpt]
set methodology_objects [get_methodology_violations -quiet]

if {$ramb36_count != 32 || $ramb18_count != 0 || $uram_count != 0} {
    m7_cache_post_fail "RAMB36=$ramb36_count RAMB18=$ramb18_count URAM=$uram_count expected=32/0/0"
}
if {$dsp_count != 0 || $blackbox_count != 0 || $latch_count != 0} {
    m7_cache_post_fail "DSP=$dsp_count blackbox=$blackbox_count latch=$latch_count"
}
if {[expr {double($wns) < 0.0}]} {
    m7_cache_post_fail "WNS=$wns"
}
if {$whs ne "N/A" && [expr {double($whs) < 0.0}]} {
    m7_cache_post_fail "WHS=$whs"
}
if {$routed_nets ne $routable_nets || $route_errors != 0} {
    m7_cache_post_fail "routed=$routed_nets routable=$routable_nets errors=$route_errors"
}
if {[llength $drc_objects] != 0 || [llength $methodology_objects] != 0} {
    m7_cache_post_fail "DRC=[llength $drc_objects] methodology=[llength $methodology_objects]"
}

set summary [join [list \
    "EVIDENCE_SCOPE=standalone_activation_cache_post_route_ooc" \
    "VIVADO=[version -short]" \
    "PART=[get_property PART [current_design]]" \
    "CLOCK_MHZ=50" \
    "ARRAY_ROWS=8" \
    "DEPTH_WORDS_PER_ROW=3072" \
    "RAMB36=$ramb36_count" \
    "RAMB18=$ramb18_count" \
    "URAM=$uram_count" \
    "DSP48_DSP58=$dsp_count" \
    "BLACKBOX=$blackbox_count" \
    "LATCH=$latch_count" \
    "WNS_NS=$wns" \
    "WHS_NS=$whs" \
    "ROUTED_NETS=$routed_nets" \
    "ROUTABLE_NETS=$routable_nets" \
    "EXPLICIT_OOC_GAPS=$explicit_gaps" \
    "ROUTE_ERRORS=$route_errors" \
    "DRC_VIOLATIONS=[llength $drc_objects]" \
    "METHODOLOGY_VIOLATIONS=[llength $methodology_objects]" \
    "CAVEAT=No internal hold path remains after OOC boundary-hold false paths; this is not full-chip timing" \
] "\n"]
m7_cache_post_write [file join $out_dir POSTCHECK_SUMMARY.txt] $summary
puts $summary
puts "M7_CACHE_OOC_POSTCHECK_PASS rows=8 depth=3072 bram36=32 dsp=0 WNS=$wns WHS=$whs"
