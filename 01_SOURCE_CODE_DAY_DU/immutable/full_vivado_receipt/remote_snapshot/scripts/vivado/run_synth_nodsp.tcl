# Configure and synthesize the existing ViT_googlebase project with DSP=0.
#
#   vivado -mode batch -source scripts/vivado/run_synth_nodsp.tcl

set vit_synth_script_dir [file normalize [file dirname [info script]]]
source [file join $vit_synth_script_dir vit_project_common.tcl]
vit_project::configure
vit_project::require_synthesis_flatten_policy synth_1

# A clean clone intentionally has no .gen directory. Recreate the generated
# board wrapper from the checked-in project-local BD before board synthesis.
if {[get_property TOP [get_filesets sources_1]] ne "vit_system_wrapper" &&
    [llength [get_files -quiet */vit_system.bd]] == 1} {
    puts "Generated board wrapper is absent; regenerating it from vit_system.bd"
    source [file join $vit_project::repo_root import_vit_system_bd.tcl]
}

set vit_synth_jobs 4
if {[info exists ::env(VIT_VIVADO_JOBS)]} {
    set vit_synth_jobs $::env(VIT_VIVADO_JOBS)
}
if {![string is integer -strict $vit_synth_jobs] || $vit_synth_jobs < 1} {
    error "VIT_VIVADO_JOBS must be a positive integer"
}

set vit_synth_run [get_runs synth_1]
set vit_synth_status [get_property STATUS $vit_synth_run]
set vit_synth_progress [get_property PROGRESS $vit_synth_run]
if {"NEEDS_REFRESH" ni [list_property $vit_synth_run]} {
    error "Vivado run synth_1 has no NEEDS_REFRESH property"
}
set vit_synth_needs_refresh [get_property NEEDS_REFRESH $vit_synth_run]
if {![string is boolean -strict $vit_synth_needs_refresh]} {
    error \
        "Unexpected synth_1 NEEDS_REFRESH value: $vit_synth_needs_refresh"
}
if {[string match "*Complete*" $vit_synth_status] &&
    $vit_synth_progress eq "100%" &&
    !$vit_synth_needs_refresh} {
    puts "Reusing current completed synth_1 netlist"
} else {
    if {[string match "*Complete*" $vit_synth_status] ||
        $vit_synth_progress ne "0%"} {
        puts \
            "Resetting stale/incomplete synth_1: STATUS=$vit_synth_status PROGRESS=$vit_synth_progress NEEDS_REFRESH=$vit_synth_needs_refresh"
        reset_run synth_1
    }
    puts "Launching synth_1 with MAX_DSP=0 FLATTEN_HIERARCHY=none"
    launch_runs synth_1 -jobs $vit_synth_jobs
    wait_on_run synth_1
}

set vit_synth_status [get_property STATUS $vit_synth_run]
set vit_synth_progress [get_property PROGRESS $vit_synth_run]
set vit_synth_needs_refresh [get_property NEEDS_REFRESH $vit_synth_run]
if {![string match "*Complete*" $vit_synth_status] ||
    $vit_synth_progress ne "100%" ||
    $vit_synth_needs_refresh} {
    error \
        "synth_1 is not current: STATUS=$vit_synth_status PROGRESS=$vit_synth_progress NEEDS_REFRESH=$vit_synth_needs_refresh"
}
vit_project::require_synthesis_flatten_policy synth_1

catch {close_design}
open_run synth_1
file mkdir $vit_project::report_dir
set vit_synth_loop_gate \
    [vit_project::require_no_combinational_loops project_post_synth]
source [file join $vit_synth_script_dir report_hier_utilization.tcl]
source [file join $vit_synth_script_dir check_no_dsp.tcl]

puts "PASS: no-DSP synthesis flow completed"
puts "  loop gate: $vit_synth_loop_gate"
