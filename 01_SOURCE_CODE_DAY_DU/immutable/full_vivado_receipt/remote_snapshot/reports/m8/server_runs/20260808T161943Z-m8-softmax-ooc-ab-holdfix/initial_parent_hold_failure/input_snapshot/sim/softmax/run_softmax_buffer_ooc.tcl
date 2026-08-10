# Fail-closed Vivado-2023.2 OOC implementation for the M8 Softmax buffer and
# the byte-identical M7/IP-v1.12 parent.  Select with:
#   M8_SOFTMAX_IMPLEMENTATION=candidate|parent
#   M8_SOFTMAX_OOC_OUT=/absolute/output/path

proc softmax_fail {message} {
    error "SOFTMAX_BUFFER_OOC_FAIL $message"
}

proc softmax_write_text {path value} {
    set handle [open $path w]
    puts $handle $value
    close $handle
}

proc softmax_require_no_loops {stage report_dir} {
    set result [check_timing -verbose -return_string \
        -override_defaults [list loops]]
    softmax_write_text [file join $report_dir ${stage}_loops.rpt] $result
    set count -1
    if {![regexp -nocase {There are ([0-9]+) combinational loops} \
          $result -> count] &&
        ![regexp -nocase {checking loops \(([0-9]+)\)} \
          $result -> count]} {
        softmax_fail "$stage cannot parse combinational-loop check"
    }
    if {$count != 0} {
        softmax_fail "$stage combinational_loops=$count"
    }
    puts "SOFTMAX_BUFFER_GATE_PASS stage=$stage combinational_loops=0"
}

proc softmax_get_structure {stage implementation report_dir} {
    set dsp_cells [get_cells -quiet -hierarchical \
        -filter {REF_NAME =~ DSP48* || REF_NAME =~ DSP58*}]
    set ramb36_cells [get_cells -quiet -hierarchical \
        -filter {REF_NAME =~ RAMB36*}]
    set ramb18_cells [get_cells -quiet -hierarchical \
        -filter {REF_NAME =~ RAMB18*}]
    set uram_cells [get_cells -quiet -hierarchical \
        -filter {REF_NAME =~ URAM*}]
    set lutram_cells [get_cells -quiet -hierarchical -filter {
        REF_NAME =~ RAM32M* ||
        REF_NAME =~ RAM64M* ||
        REF_NAME =~ RAMD* ||
        REF_NAME =~ RAMS* ||
        REF_NAME =~ RAM32X* ||
        REF_NAME =~ RAM64X* ||
        REF_NAME =~ RAM128X* ||
        REF_NAME =~ RAM256X* ||
        REF_NAME =~ RAM512X*
    }]
    set blackboxes [get_cells -quiet -hierarchical \
        -filter {IS_BLACKBOX == 1}]
    set latches [get_cells -quiet -hierarchical \
        -filter {REF_NAME =~ LD*}]
    set lut_cells [get_cells -quiet -hierarchical \
        -filter {REF_NAME =~ LUT*}]
    set ff_cells [get_cells -quiet -hierarchical \
        -filter {REF_NAME =~ FD*}]

    set metrics [dict create \
        dsp [llength $dsp_cells] \
        ramb36 [llength $ramb36_cells] \
        ramb18 [llength $ramb18_cells] \
        uram [llength $uram_cells] \
        lutram [llength $lutram_cells] \
        blackbox [llength $blackboxes] \
        latch [llength $latches] \
        lut [llength $lut_cells] \
        ff [llength $ff_cells]]

    softmax_write_text [file join $report_dir ${stage}_structure.rpt] \
        [join [list \
            "IMPLEMENTATION=$implementation" \
            "DSP48_DSP58=[dict get $metrics dsp]" \
            "RAMB36E2=[dict get $metrics ramb36]" \
            "RAMB18E2=[dict get $metrics ramb18]" \
            "URAM288=[dict get $metrics uram]" \
            "LUTRAM_PRIMITIVES=[dict get $metrics lutram]" \
            "BLACKBOX=[dict get $metrics blackbox]" \
            "LATCH=[dict get $metrics latch]" \
            "LUT=[dict get $metrics lut]" \
            "FF=[dict get $metrics ff]" \
        ] "\n"]

    if {[dict get $metrics dsp] != 0 ||
        [dict get $metrics ramb18] != 0 ||
        [dict get $metrics uram] != 0 ||
        [dict get $metrics lutram] != 0 ||
        [dict get $metrics blackbox] != 0 ||
        [dict get $metrics latch] != 0} {
        softmax_fail "$stage structure DSP=[dict get $metrics dsp] RAMB18=[dict get $metrics ramb18] URAM=[dict get $metrics uram] LUTRAM=[dict get $metrics lutram] blackbox=[dict get $metrics blackbox] latch=[dict get $metrics latch]"
    }
    if {$implementation eq "candidate"} {
        if {[dict get $metrics ramb36] != 1} {
            softmax_fail "$stage candidate RAMB36=[dict get $metrics ramb36] expected=1"
        }
    } elseif {[dict get $metrics ramb36] != 0} {
        softmax_fail "$stage exact parent RAMB36=[dict get $metrics ramb36] expected=0"
    }
    if {[dict get $metrics lut] == 0 || [dict get $metrics ff] == 0} {
        softmax_fail "$stage vacuous LUT=[dict get $metrics lut] FF=[dict get $metrics ff]"
    }
    puts "SOFTMAX_BUFFER_GATE_PASS stage=$stage implementation=$implementation DSP=0 RAMB36=[dict get $metrics ramb36] RAMB18=0 URAM=0 LUTRAM=0 blackbox=0 latch=0"
    return $metrics
}

proc softmax_require_timing {stage report_dir} {
    set setup_paths [get_timing_paths -quiet -delay_type max \
        -max_paths 1 -nworst 1]
    set hold_paths [get_timing_paths -quiet -delay_type min \
        -max_paths 1 -nworst 1]
    if {[llength $setup_paths] == 0 || [llength $hold_paths] == 0} {
        softmax_fail "$stage missing setup/hold timing path"
    }
    set wns [get_property SLACK [lindex $setup_paths 0]]
    set whs [get_property SLACK [lindex $hold_paths 0]]
    softmax_write_text [file join $report_dir ${stage}_timing_gate.rpt] \
        "WNS=$wns\nWHS=$whs"
    if {[expr {double($wns) < 0.0}] ||
        [expr {double($whs) < 0.0}]} {
        softmax_fail "$stage timing WNS=$wns WHS=$whs"
    }
    puts "SOFTMAX_BUFFER_GATE_PASS stage=$stage WNS=$wns WHS=$whs"
    return [list $wns $whs]
}

proc softmax_require_route {report_dir} {
    set status [report_route_status -return_string]
    softmax_write_text [file join $report_dir post_route_status.rpt] $status
    set routable -1
    set fully -1
    set errors -1
    regexp {# of routable nets[^:]*:[ \t]*([0-9,]+)} \
        $status -> routable
    regexp {# of fully routed nets[^:]*:[ \t]*([0-9,]+)} \
        $status -> fully
    regexp {# of nets with routing errors[^:]*:[ \t]*([0-9,]+)} \
        $status -> errors
    regsub -all {,} $routable {} routable
    regsub -all {,} $fully {} fully
    regsub -all {,} $errors {} errors
    if {$routable < 0 || $fully < 0 || $errors < 0} {
        softmax_fail "cannot parse route status"
    }
    if {$fully != $routable || $errors != 0} {
        softmax_fail "route routable=$routable fully=$fully errors=$errors"
    }
    puts "SOFTMAX_BUFFER_GATE_PASS stage=post_route routable=$routable fully=$fully errors=0"
    return [list $routable $fully $errors]
}

proc softmax_require_severe_clean {kind report_dir} {
    if {$kind eq "drc"} {
        set path [file join $report_dir post_route_drc.rpt]
        report_drc -file $path
        set objects [get_drc_violations -quiet]
    } else {
        set path [file join $report_dir post_route_methodology.rpt]
        report_methodology -file $path
        set objects [get_methodology_violations -quiet]
    }
    set severe [list]
    foreach object $objects {
        set severity [string toupper \
            [string trim [get_property SEVERITY $object]]]
        if {[lsearch -exact [list FATAL ERROR "CRITICAL WARNING"] \
             $severity] >= 0} {
            lappend severe $object
        }
    }
    if {[llength $severe] != 0} {
        softmax_fail "post_route severe_${kind}=[llength $severe] report=$path"
    }
    puts "SOFTMAX_BUFFER_GATE_PASS stage=post_route severe_${kind}=0"
}

set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ../..]]
set expected_version "2023.2"
set part "xczu5ev-sfvc784-1-e"
set expected_parent_sha \
    "4613263dd791c1d1a2e00a9ce6001b5c7ebc5ce36882c33bbd6aef06de5593da"

if {[info exists ::env(M8_SOFTMAX_OOC_OUT)]} {
    set output_dir [file normalize $::env(M8_SOFTMAX_OOC_OUT)]
} else {
    set output_dir [file normalize [file join $repo_root build softmax_buffer_ooc]]
}
if {[info exists ::env(M8_SOFTMAX_IMPLEMENTATION)]} {
    set implementation [string tolower $::env(M8_SOFTMAX_IMPLEMENTATION)]
} else {
    set implementation "candidate"
}
if {$implementation ni [list candidate parent]} {
    softmax_fail "M8_SOFTMAX_IMPLEMENTATION must be candidate or parent"
}
if {[version -short] ne $expected_version} {
    softmax_fail "Vivado=[version -short] expected=$expected_version"
}
if {[llength [get_parts -quiet $part]] != 1} {
    softmax_fail "part unavailable: $part"
}

set report_dir [file join $output_dir reports]
set artifact_dir [file join $output_dir artifacts]
file mkdir $report_dir
file mkdir $artifact_dir

set common_sources [list \
    [file join $repo_root rtl pkg vit_fp32_pkg.sv] \
    [file join $repo_root rtl leaf common vit_u32_mul_iterative_nodsp.sv] \
    [file join $repo_root rtl leaf fp32 vit_fp32_add_comb.sv] \
    [file join $repo_root rtl leaf fp32 vit_fp32_compare.sv] \
    [file join $repo_root rtl leaf fp32 vit_fp32_mul_comb_nodsp.sv] \
    [file join $repo_root rtl leaf fp32 vit_fp32_from_u32_comb.sv] \
    [file join $repo_root rtl leaf fp32 vit_fp32_to_u32_floor_comb.sv] \
    [file join $repo_root rtl leaf fp32 vit_fp32_scale_pow2_down_comb.sv] \
]
if {$implementation eq "candidate"} {
    set implementation_source \
        [file join $repo_root rtl blocks softmax vit_softmax_engine_fp32.sv]
} else {
    set implementation_source [file join $repo_root sim m8 reference \
        vit_softmax_engine_fp32_parent_v1_12.sv]
}
set sha_output [exec sha256sum $implementation_source]
set implementation_sha [lindex [split $sha_output] 0]
if {$implementation eq "parent" &&
    $implementation_sha ne $expected_parent_sha} {
    softmax_fail "parent SHA=$implementation_sha expected=$expected_parent_sha"
}
softmax_write_text [file join $output_dir source.sha256] \
    "$implementation_sha  $implementation_source"

set_param general.maxThreads 1
create_project -in_memory -part $part
set_property target_language Verilog [current_project]
read_verilog -sv [concat $common_sources [list $implementation_source]]

if {$implementation eq "candidate"} {
    synth_design \
        -mode out_of_context \
        -flatten_hierarchy none \
        -top vit_softmax_engine_fp32 \
        -part $part \
        -max_dsp 0 \
        -generic {USE_EXTERNAL_MUL=1 USE_EXTERNAL_ADD=1 ENABLE_ROW_EXP_BUFFER=1 ROW_EXP_BUFFER_DEPTH=1024}
} else {
    synth_design \
        -mode out_of_context \
        -flatten_hierarchy none \
        -top vit_softmax_engine_fp32 \
        -part $part \
        -max_dsp 0 \
        -generic {USE_EXTERNAL_MUL=1 USE_EXTERNAL_ADD=1}
}

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

set synth_metrics \
    [softmax_get_structure post_synth $implementation $report_dir]
softmax_require_no_loops post_synth $report_dir
report_utilization -hierarchical \
    -file [file join $report_dir post_synth_utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose \
    -file [file join $report_dir post_synth_timing_summary.rpt]
write_checkpoint -force [file join $artifact_dir post_synth.dcp]

opt_design
place_design -directive Quick
phys_opt_design -directive Explore
route_design -directive Quick

set route_metrics [softmax_require_route $report_dir]
set route_structure \
    [softmax_get_structure post_route $implementation $report_dir]
softmax_require_no_loops post_route $report_dir
report_utilization -hierarchical \
    -file [file join $report_dir post_route_utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained \
    -check_timing_verbose \
    -file [file join $report_dir post_route_timing_summary.rpt]
set timing [softmax_require_timing post_route $report_dir]
softmax_require_severe_clean methodology $report_dir
softmax_require_severe_clean drc $report_dir
write_checkpoint -force [file join $artifact_dir post_route.dcp]

softmax_write_text [file join $output_dir SUMMARY.txt] \
    [join [list \
        "RESULT=PASS" \
        "EVIDENCE_SCOPE=standalone_softmax_ooc" \
        "IMPLEMENTATION=$implementation" \
        "SOURCE_SHA256=$implementation_sha" \
        "VIVADO=[version -short]" \
        "PART=$part" \
        "CLOCK_MHZ=50" \
        "WNS_NS=[lindex $timing 0]" \
        "WHS_NS=[lindex $timing 1]" \
        "DSP48_DSP58=0" \
        "RAMB36E2=[dict get $route_structure ramb36]" \
        "RAMB18E2=0" \
        "URAM288=0" \
        "LUTRAM_PRIMITIVES=0" \
        "BLACKBOX=0" \
        "LATCH=0" \
        "COMBINATIONAL_LOOPS=0" \
        "ROUTABLE_NETS=[lindex $route_metrics 0]" \
        "FULLY_ROUTED_NETS=[lindex $route_metrics 1]" \
        "ROUTING_ERRORS=[lindex $route_metrics 2]" \
    ] "\n"]

puts "SOFTMAX_BUFFER_OOC_PASS implementation=$implementation source_sha=$implementation_sha WNS=[lindex $timing 0] WHS=[lindex $timing 1] DSP=0 RAMB36=[dict get $route_structure ramb36] RAMB18=0 URAM=0 LUTRAM=0 loops=0 blackbox=0 latch=0"
close_project
exit 0
