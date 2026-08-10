# Vivado 2023.2 non-project OOC implementation of the bounded M7.2 leaf.
# Usage:
#   vivado -mode batch -source run_leaf_ooc_case.tcl \
#     -tclargs STREAMS CLOCK_MHZ OUT_DIR

proc m7_fail {message} {
    error "M7_LEAF_OOC_FAIL $message"
}

proc m7_write_text {path text_value} {
    set handle [open $path w]
    puts $handle $text_value
    close $handle
}

proc m7_cells_by_ref {wanted_ref} {
    set matches [list]
    foreach cell [get_cells -quiet -hierarchical] {
        set original_ref [get_property -quiet ORIG_REF_NAME $cell]
        set ref_name [get_property -quiet REF_NAME $cell]
        if {$original_ref eq $wanted_ref || $ref_name eq $wanted_ref} {
            lappend matches $cell
        }
    }
    return $matches
}

proc m7_require_no_dsp {stage report_dir} {
    set cells [get_cells -quiet -hierarchical \
        -filter {REF_NAME =~ DSP48* || REF_NAME =~ DSP58*}]
    set lines [list "DSP48_DSP58_COUNT=[llength $cells]"]
    foreach cell $cells {
        lappend lines "[get_property REF_NAME $cell] $cell"
    }
    m7_write_text [file join $report_dir ${stage}_dsp.rpt] \
        [join $lines "\n"]
    if {[llength $cells] != 0} {
        m7_fail "$stage inferred [llength $cells] DSP48/DSP58 primitives"
    }
    puts "M7_LEAF_GATE_PASS stage=$stage dsp=0"
}

proc m7_require_structure {stage streams report_dir} {
    set stream_cells [m7_cells_by_ref vit_fp16_dot_stream_csa_nodsp]
    set converter_cells [m7_cells_by_ref vit_fp32_to_fp16_rne_gradual]
    set bias_adder_cells [m7_cells_by_ref vit_fp32_add_comb]
    set lut_cells [get_cells -quiet -hierarchical -filter {REF_NAME =~ LUT*}]
    set ff_cells [get_cells -quiet -hierarchical -filter {REF_NAME =~ FD*}]
    set carry_cells [get_cells -quiet -hierarchical -filter {REF_NAME =~ CARRY*}]
    set ramb36_cells [get_cells -quiet -hierarchical -filter {REF_NAME =~ RAMB36*}]
    set ramb18_cells [get_cells -quiet -hierarchical -filter {REF_NAME =~ RAMB18*}]
    set uram_cells [get_cells -quiet -hierarchical -filter {REF_NAME =~ URAM*}]
    set blackboxes [get_cells -quiet -hierarchical -filter {IS_BLACKBOX == 1}]
    set latches [get_cells -quiet -hierarchical -filter {REF_NAME =~ LD*}]

    set metrics [dict create \
        streams [llength $stream_cells] \
        converters [llength $converter_cells] \
        bias_adders [llength $bias_adder_cells] \
        lut [llength $lut_cells] \
        ff [llength $ff_cells] \
        carry [llength $carry_cells] \
        ramb36 [llength $ramb36_cells] \
        ramb18 [llength $ramb18_cells] \
        uram [llength $uram_cells] \
        blackbox [llength $blackboxes] \
        latch [llength $latches]]
    set lines [list \
        "EXPECTED_STREAMS=$streams" \
        "STREAM_CELLS=[dict get $metrics streams]" \
        "EXPECTED_CONVERTERS=10" \
        "CONVERTER_CELLS=[dict get $metrics converters]" \
        "EXPECTED_BIAS_ADDERS=1" \
        "BIAS_ADDER_CELLS=[dict get $metrics bias_adders]" \
        "LUT_CELLS=[dict get $metrics lut]" \
        "FF_CELLS=[dict get $metrics ff]" \
        "CARRY_CELLS=[dict get $metrics carry]" \
        "RAMB36_CELLS=[dict get $metrics ramb36]" \
        "RAMB18_CELLS=[dict get $metrics ramb18]" \
        "URAM_CELLS=[dict get $metrics uram]" \
        "BLACKBOX_CELLS=[dict get $metrics blackbox]" \
        "LATCH_CELLS=[dict get $metrics latch]"]
    m7_write_text [file join $report_dir ${stage}_structure.rpt] \
        [join $lines "\n"]

    if {[dict get $metrics streams] != $streams} {
        m7_fail "$stage stream hierarchy=[dict get $metrics streams] expected=$streams"
    }
    if {[dict get $metrics converters] != 10} {
        m7_fail "$stage converter hierarchy=[dict get $metrics converters] expected=10"
    }
    if {[dict get $metrics bias_adders] != 1} {
        m7_fail "$stage bias-adder hierarchy=[dict get $metrics bias_adders] expected=1"
    }
    if {[dict get $metrics lut] == 0 || [dict get $metrics ff] == 0 ||
        [dict get $metrics carry] == 0} {
        m7_fail "$stage vacuous LUT=[dict get $metrics lut] FF=[dict get $metrics ff] CARRY=[dict get $metrics carry]"
    }
    if {[dict get $metrics blackbox] != 0} {
        m7_fail "$stage blackboxes=[dict get $metrics blackbox]"
    }
    if {[dict get $metrics latch] != 0} {
        m7_fail "$stage latches=[dict get $metrics latch]"
    }
    puts "M7_LEAF_GATE_PASS stage=$stage streams=$streams converters=10 bias_adders=1 LUT=[dict get $metrics lut] FF=[dict get $metrics ff] CARRY=[dict get $metrics carry] blackbox=0 latch=0"
    return $metrics
}

proc m7_require_no_loops {stage report_dir} {
    set result [check_timing -verbose -return_string \
        -override_defaults [list loops]]
    m7_write_text [file join $report_dir ${stage}_loops.rpt] $result
    set count -1
    if {![regexp -nocase {There are ([0-9]+) combinational loops} \
          $result -> count] &&
        ![regexp -nocase {checking loops \(([0-9]+)\)} \
          $result -> count]} {
        m7_fail "$stage cannot parse combinational-loop check"
    }
    if {$count != 0} {
        m7_fail "$stage combinational_loops=$count"
    }
    puts "M7_LEAF_GATE_PASS stage=$stage combinational_loops=0"
}

proc m7_require_timing {stage report_dir} {
    set setup_paths [get_timing_paths -quiet -delay_type max \
        -max_paths 1 -nworst 1]
    set hold_paths [get_timing_paths -quiet -delay_type min \
        -max_paths 1 -nworst 1]
    if {[llength $setup_paths] == 0 || [llength $hold_paths] == 0} {
        m7_fail "$stage has no setup/hold timing path"
    }
    set wns [get_property SLACK [lindex $setup_paths 0]]
    set whs [get_property SLACK [lindex $hold_paths 0]]
    m7_write_text [file join $report_dir ${stage}_timing_gate.rpt] \
        "WNS=$wns\nWHS=$whs"
    if {[expr {double($wns) < 0.0}] || [expr {double($whs) < 0.0}]} {
        m7_fail "$stage timing WNS=$wns WHS=$whs"
    }
    puts "M7_LEAF_GATE_PASS stage=$stage WNS=$wns WHS=$whs"
    return [list $wns $whs]
}

proc m7_require_constraint_coverage {stage report_dir} {
    set failures [list]
    set report_lines [list]
    foreach check_name [list \
        no_clock \
        unconstrained_internal_endpoints \
        partial_input_delay \
        partial_output_delay \
    ] {
        set result [check_timing -verbose -return_string \
            -override_defaults [list $check_name]]
        lappend report_lines "===== $check_name =====" $result
        set summaries [regexp -all -inline -nocase \
            {There (are|is)[ \t\r\n]+([0-9]+)} $result]
        if {[llength $summaries] == 0 ||
            [expr {[llength $summaries] % 3}] != 0} {
            m7_fail "$stage cannot parse constraint check $check_name"
        }
        for {set index 2} {$index < [llength $summaries]} {incr index 3} {
            set count [lindex $summaries $index]
            if {$count != 0} {
                lappend failures "$check_name=$count"
            }
        }
    }
    m7_write_text [file join $report_dir ${stage}_constraint_coverage.rpt] \
        [join $report_lines "\n"]
    if {[llength $failures] != 0} {
        m7_fail "$stage constraint coverage [join $failures {, }]"
    }
    puts "M7_LEAF_GATE_PASS stage=$stage constraint_coverage=clean"
}

proc m7_require_severe_clean {kind report_dir} {
    if {$kind eq "drc"} {
        set report_path [file join $report_dir post_route_drc.rpt]
        report_drc -file $report_path
        set objects [get_drc_violations -quiet]
    } else {
        set report_path [file join $report_dir post_route_methodology.rpt]
        report_methodology -file $report_path
        set objects [get_methodology_violations -quiet]
    }
    set severe [list]
    foreach object $objects {
        set severity [string toupper \
            [string trim [get_property SEVERITY $object]]]
        if {[lsearch -exact \
            [list FATAL ERROR "CRITICAL WARNING"] $severity] >= 0} {
            lappend severe $object
        }
    }
    m7_write_text [file join $report_dir post_route_${kind}_gate.rpt] \
        "TOTAL=[llength $objects]\nSEVERE=[llength $severe]"
    if {[llength $severe] != 0} {
        m7_fail "post_route severe_${kind}=[llength $severe] report=$report_path"
    }
    puts "M7_LEAF_GATE_PASS stage=post_route severe_${kind}=0 total_${kind}=[llength $objects]"
    return [llength $objects]
}

if {$argc != 3} {
    m7_fail "usage: run_leaf_ooc_case.tcl STREAMS CLOCK_MHZ OUT_DIR"
}
set streams [lindex $argv 0]
set clock_mhz [lindex $argv 1]
if {$streams ni [list 8 16]} {
    m7_fail "STREAMS must be 8 or 16; got $streams"
}
if {$clock_mhz ni [list 50 100]} {
    m7_fail "CLOCK_MHZ must be 50 or 100; got $clock_mhz"
}
if {$clock_mhz == 50} {
    set period_ns "20.000"
    set input_max_ns "4.000"
    set input_min_ns "1.000"
    set output_max_ns "4.000"
    set output_min_ns "-1.000"
} else {
    set period_ns "10.000"
    set input_max_ns "2.000"
    set input_min_ns "0.500"
    set output_max_ns "2.000"
    set output_min_ns "-0.500"
}

set out_dir [file normalize [lindex $argv 2]]
set report_dir [file join $out_dir reports]
set artifact_dir [file join $out_dir artifacts]
file mkdir $report_dir
file mkdir $artifact_dir

set script_dir [file normalize [file dirname [info script]]]
set m7_root [file normalize [file join $script_dir ../../..]]
set expected_version "2023.2"
set part "xczu5ev-sfvc784-1-e"
set top "vit_gemm_fp16_stream_array"

if {[version -short] ne $expected_version} {
    m7_fail "Vivado=[version -short] expected=$expected_version"
}
if {[llength [get_parts -quiet $part]] != 1} {
    m7_fail "part unavailable: $part"
}

set max_threads 2
if {[info exists ::env(M7_VIVADO_MAX_THREADS)]} {
    set max_threads $::env(M7_VIVADO_MAX_THREADS)
}
if {$max_threads ni [list 1 2]} {
    m7_fail "M7_VIVADO_MAX_THREADS must be 1 or 2; got $max_threads"
}
set_param general.maxThreads $max_threads
puts "M7_LEAF_RESOURCE_POLICY max_threads=$max_threads"
create_project -in_memory -part $part
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

set rtl_sources [list]
set filelist_path [file join $m7_root filelists m7 m7_leaf_ooc.f]
set filelist_handle [open $filelist_path r]
while {[gets $filelist_handle line] >= 0} {
    regsub {#.*$} $line "" line
    set line [string trim $line]
    if {$line ne ""} {
        set source_path [file normalize [file join $m7_root $line]]
        if {![file isfile $source_path]} {
            close $filelist_handle
            m7_fail "missing RTL source $source_path"
        }
        lappend rtl_sources $source_path
    }
}
close $filelist_handle
if {[llength $rtl_sources] != 9} {
    m7_fail "expected 9 ordered RTL sources; got [llength $rtl_sources]"
}

read_verilog -sv $rtl_sources
set ::M7_OOC_PERIOD_NS $period_ns
set ::M7_OOC_INPUT_MAX_NS $input_max_ns
set ::M7_OOC_INPUT_MIN_NS $input_min_ns
set ::M7_OOC_OUTPUT_MAX_NS $output_max_ns
set ::M7_OOC_OUTPUT_MIN_NS $output_min_ns
read_xdc [file join $m7_root constraints m7 m7_leaf_ooc.xdc]

puts "M7_LEAF_STAGE synth streams=$streams clock_mhz=$clock_mhz"
synth_design -top $top -part $part -mode out_of_context \
    -flatten_hierarchy none -max_dsp 0 -generic STREAMS=$streams
if {[llength [get_sites -quiet BUFGCTRL_X0Y0]] != 1} {
    m7_fail "OOC clock anchor BUFGCTRL_X0Y0 unavailable on $part"
}
set synth_metrics [m7_require_structure \
    post_synth $streams $report_dir]
m7_require_no_dsp post_synth $report_dir
m7_require_no_loops post_synth $report_dir
report_utilization -hierarchical \
    -file [file join $report_dir post_synth_utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $report_dir post_synth_timing_summary.rpt]
write_checkpoint -force [file join $artifact_dir post_synth.dcp]

puts "M7_LEAF_STAGE opt streams=$streams clock_mhz=$clock_mhz"
opt_design
puts "M7_LEAF_STAGE place streams=$streams clock_mhz=$clock_mhz"
place_design
puts "M7_LEAF_STAGE phys_opt streams=$streams clock_mhz=$clock_mhz"
phys_opt_design
puts "M7_LEAF_STAGE route streams=$streams clock_mhz=$clock_mhz"
route_design

set routed_fully [report_route_status -boolean_check ROUTED_FULLY]
set route_errors_boolean [report_route_status -boolean_check ERRORS_IN_ROUTES]
set route_report [file join $report_dir post_route_status.rpt]
report_route_status -file $route_report
set route_handle [open $route_report r]
set route_text [read $route_handle]
close $route_handle
foreach {label pattern} [list \
    routable {# of routable nets\.+[ \t]*:[ \t]*([0-9]+)} \
    fully {# of fully routed nets\.+[ \t]*:[ \t]*([0-9]+)} \
    errors {# of nets with routing errors\.+[ \t]*:[ \t]*([0-9]+)} \
    gaps {# of nets with explicit gaps\.+[ \t]*:[ \t]*([0-9]+)} \
] {
    if {![regexp -nocase $pattern $route_text -> value]} {
        m7_fail "cannot parse route field $label from $route_report"
    }
    set route_${label} $value
}
if {![string is boolean -strict $routed_fully] ||
    ![string is boolean -strict $route_errors_boolean] ||
    $route_errors_boolean || $route_errors != 0 ||
    $route_routable != $route_fully || $route_gaps > 1} {
    m7_fail "route status routed_fully=$routed_fully boolean_errors=$route_errors_boolean routable=$route_routable fully=$route_fully errors=$route_errors gaps=$route_gaps"
}
puts "M7_LEAF_GATE_PASS stage=post_route routable=$route_routable fully=$route_fully net_errors=$route_errors explicit_gaps=$route_gaps routed_fully_boolean=$routed_fully"

set route_metrics [m7_require_structure \
    post_route $streams $report_dir]
m7_require_no_dsp post_route $report_dir
m7_require_no_loops post_route $report_dir
report_utilization -hierarchical \
    -file [file join $report_dir post_route_utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -file [file join $report_dir post_route_timing_summary.rpt]
report_power -file [file join $report_dir post_route_power.rpt]
write_checkpoint -force [file join $artifact_dir post_route.dcp]
set timing [m7_require_timing post_route $report_dir]
m7_require_constraint_coverage post_route $report_dir
set methodology_total [m7_require_severe_clean methodology $report_dir]
set drc_total [m7_require_severe_clean drc $report_dir]

set limitations [join [list \
    "EVIDENCE_SCOPE=STANDALONE_M7_2_LEAF_OOC_ONLY" \
    "NOT_FULL_CHIP_TIMING=1" \
    "NOT_PRODUCTION_PS_AXI_PL_ROUTE=1" \
    "CLOCK_SOURCE=OOC_HD.CLK_SRC_BUFGCTRL_X0Y0" \
    "BOUNDARY_HOLD_FALSE_PATH_FROM_INPUTS=1" \
    "BOUNDARY_HOLD_FALSE_PATH_TO_OUTPUTS=1" \
    "SYNCHRONOUS_RESET_FALSE_PATH=1" \
    "BOUNDARY_SETUP_TIMED=1" \
    "INTERNAL_SETUP_HOLD_TIMED=1" \
    "EXPLICIT_GAPS=$route_gaps" \
    "FULL_INTEGRATION_MUST_REMOVE_OOC_EXCEPTIONS=1" \
] "\n"]
m7_write_text [file join $out_dir OOC_LIMITATIONS.txt] $limitations

set summary [join [list \
    "RESULT=PASS" \
    "EVIDENCE_CLASS=MEASURED_TOOL_REPORT" \
    "SCOPE=STANDALONE_M7_2_LEAF_OOC" \
    "VIVADO=[version -short]" \
    "PART=$part" \
    "TOP=$top" \
    "STREAMS=$streams" \
    "CLOCK_PERIOD_NS=$period_ns" \
    "CLOCK_MHZ=$clock_mhz" \
    "WNS=[lindex $timing 0]" \
    "WHS=[lindex $timing 1]" \
    "POST_ROUTE_LUT=[dict get $route_metrics lut]" \
    "POST_ROUTE_FF=[dict get $route_metrics ff]" \
    "POST_ROUTE_CARRY=[dict get $route_metrics carry]" \
    "POST_ROUTE_RAMB36=[dict get $route_metrics ramb36]" \
    "POST_ROUTE_RAMB18=[dict get $route_metrics ramb18]" \
    "POST_ROUTE_URAM=[dict get $route_metrics uram]" \
    "STREAM_HIERARCHY=[dict get $route_metrics streams]" \
    "CONVERTER_HIERARCHY=[dict get $route_metrics converters]" \
    "BIAS_ADDER_HIERARCHY=[dict get $route_metrics bias_adders]" \
    "BLACKBOX=0" \
    "LATCH=0" \
    "COMBINATIONAL_LOOPS=0" \
    "DSP48_DSP58=0" \
    "ROUTABLE_NETS=$route_routable" \
    "FULLY_ROUTED_NETS=$route_fully" \
    "ROUTING_ERRORS=$route_errors" \
    "ROUTE_ERRORS_BOOLEAN=$route_errors_boolean" \
    "EXPLICIT_GAPS=$route_gaps" \
    "ROUTED_FULLY_BOOLEAN=$routed_fully" \
    "DRC_TOTAL=$drc_total" \
    "DRC_SEVERE=0" \
    "METHODOLOGY_TOTAL=$methodology_total" \
    "METHODOLOGY_SEVERE=0" \
    "OOC_BOUNDARY_HOLD_EXCEPTED=1" \
    "OOC_SYNCHRONOUS_RESET_EXCEPTED=1" \
    "FULL_CHIP_TIMING_SIGNOFF=0" \
] "\n"]
m7_write_text [file join $out_dir SUMMARY.txt] $summary
puts "M7_LEAF_OOC_PASS streams=$streams clock_mhz=$clock_mhz WNS=[lindex $timing 0] WHS=[lindex $timing 1] DSP=0 out=$out_dir"
close_project
