# Synthesize the standalone NPU+AXI RTL without opening the board project.
#
# This is intentionally independent of vit_system.bd so RTL resource usage and
# DSP=0 can still be checked if the board project metadata needs repair.
#
#   vivado -mode batch -source scripts/vivado/run_rtl_synth_nodsp.tcl

set vit_rtl_script_dir [file normalize [file dirname [info script]]]
source [file join $vit_rtl_script_dir vit_project_common.tcl]

set vit_rtl_part xczu5ev-sfvc784-1-e
set vit_rtl_top vit_phase_e_axi_bd_wrapper
set vit_rtl_report_dir [file join \
    $vit_project::repo_root VIT_googlebase_rtl reports]
file mkdir $vit_rtl_report_dir

set vit_rtl_threads 2
if {[info exists ::env(VIT_VIVADO_THREADS)]} {
    set vit_rtl_threads $::env(VIT_VIVADO_THREADS)
}
if {![string is integer -strict $vit_rtl_threads] ||
    $vit_rtl_threads < 1} {
    error "VIT_VIVADO_THREADS must be a positive integer"
}
set_param general.maxThreads $vit_rtl_threads

create_project -in_memory vit_rtl_nodsp -part $vit_rtl_part
set_property TARGET_LANGUAGE Verilog [current_project]
set_property SIMULATOR_LANGUAGE Mixed [current_project]

set vit_rtl_sources \
    [vit_project::read_filelist $vit_project::full_axi_filelist]
foreach vit_rtl_source $vit_rtl_sources {
    switch -- [string tolower [file extension $vit_rtl_source]] {
        ".sv" {
            read_verilog -sv $vit_rtl_source
        }
        ".v" {
            read_verilog $vit_rtl_source
        }
        default {
            error "Unsupported RTL source extension: $vit_rtl_source"
        }
    }
}

read_xdc [file join $vit_rtl_script_dir standalone_axi_50mhz.xdc]
read_xdc $vit_project::no_dsp_xdc

if {$vit_project::synthesis_flatten_hierarchy ne "none"} {
    error "This flow-only checkpoint requires FLATTEN_HIERARCHY=none"
}
puts \
    "Synthesizing $vit_rtl_top with MAX_DSP=0 FLATTEN_HIERARCHY=$vit_project::synthesis_flatten_hierarchy"
synth_design \
    -top $vit_rtl_top \
    -part $vit_rtl_part \
    -mode out_of_context \
    -flatten_hierarchy $vit_project::synthesis_flatten_hierarchy \
    -max_dsp 0

set vit_rtl_aclk [get_clocks -quiet aclk]
if {[llength $vit_rtl_aclk] != 1} {
    error "The standalone 50 MHz aclk constraint was not applied"
}
set vit_rtl_aclk_period [get_property PERIOD $vit_rtl_aclk]
if {![string is double -strict $vit_rtl_aclk_period] ||
    abs(double($vit_rtl_aclk_period) - 20.0) > 0.001} {
    error \
        "Wrong standalone aclk period: expected 20.000 ns, got $vit_rtl_aclk_period"
}

set vit_rtl_utilization [file join \
    $vit_rtl_report_dir rtl_standalone_post_synth_utilization.rpt]
set vit_rtl_hierarchy [file join \
    $vit_rtl_report_dir rtl_standalone_post_synth_hierarchical.rpt]
set vit_rtl_timing [file join \
    $vit_rtl_report_dir rtl_standalone_post_synth_timing.rpt]

report_utilization -file $vit_rtl_utilization
report_utilization \
    -hierarchical \
    -hierarchical_depth 12 \
    -file $vit_rtl_hierarchy
report_timing_summary \
    -delay_type max \
    -max_paths 20 \
    -report_unconstrained \
    -check_timing_verbose \
    -file $vit_rtl_timing
set vit_rtl_loop_gate \
    [vit_project::require_no_combinational_loops rtl_standalone_post_synth]

set vit_rtl_dsp_cells [get_cells -quiet -hierarchical \
    -filter {REF_NAME =~ DSP48* || REF_NAME =~ DSP58*}]
set vit_rtl_dsp_count [llength $vit_rtl_dsp_cells]
set vit_rtl_dsp_report [file join \
    $vit_rtl_report_dir rtl_standalone_post_synth_dsp.rpt]
set vit_rtl_dsp_handle [open $vit_rtl_dsp_report w]
puts $vit_rtl_dsp_handle \
    "ViT standalone NPU+AXI DSP primitive count: $vit_rtl_dsp_count"
foreach vit_rtl_dsp_cell $vit_rtl_dsp_cells {
    puts $vit_rtl_dsp_handle \
        "[get_property REF_NAME $vit_rtl_dsp_cell] $vit_rtl_dsp_cell"
}
close $vit_rtl_dsp_handle

if {$vit_rtl_dsp_count != 0} {
    error \
        "DSP48/DSP58 usage is forbidden; see $vit_rtl_dsp_report"
}

puts "PASS: standalone NPU+AXI synthesis completed with DSP=0"
puts "  utilization : $vit_rtl_utilization"
puts "  hierarchy   : $vit_rtl_hierarchy"
puts "  timing      : $vit_rtl_timing"
puts "  loop gate   : $vit_rtl_loop_gate"
puts "  DSP check   : $vit_rtl_dsp_report"
