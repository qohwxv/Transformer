# Clean full-board synthesis with explicit production-top and non-vacuous gates.

set vit_board_synth_dir [file normalize [file dirname [info script]]]
source [file join $vit_board_synth_dir vivado_server_common.tcl]
source [file join \
    $vit_server::bundle_root scripts vivado vit_project_common.tcl]

vit_server::require_bundle_manifest
vit_server::ensure_output_dirs
vit_server::require_version
vit_server::register_and_check_catalog
vit_server::configure_threads
vit_server::open_bundle_project
vit_project::configure
vit_server::require_top vit_system_wrapper
vit_server::require_m5_axi_contract_report

if {[llength [get_files -quiet */vit_system.bd]] != 1} {
    error "Production Block Design is missing; run stage 30 first"
}
if {[llength [get_files -quiet *vit_system_wrapper.v]] != 1} {
    error "Generated board wrapper is missing; run stage 30 first"
}

set vit_board_jobs [vit_server::positive_env VIT_VIVADO_JOBS 4]
set vit_board_synth_run [get_runs synth_1]
set vit_board_impl_run [get_runs impl_1]
set vit_board_accel_synth_run \
    [vit_project::generated_accelerator_synthesis_run]

# The bundle is a sign-off baseline, so stale completed runs are never reused.
reset_run $vit_board_impl_run
reset_run $vit_board_synth_run
reset_run $vit_board_accel_synth_run
set_property STEPS.SYNTH_DESIGN.ARGS.MAX_DSP 0 $vit_board_synth_run
set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY \
    $vit_project::synthesis_flatten_hierarchy \
    $vit_board_synth_run
if {[get_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY \
    $vit_board_synth_run] ne $vit_project::synthesis_flatten_hierarchy} {
    error "Board synthesis flatten-hierarchy policy was not applied"
}
vit_project::configure_generated_accelerator_synthesis_policy

launch_runs $vit_board_synth_run -jobs $vit_board_jobs
wait_on_run $vit_board_synth_run
vit_server::require_run_current synth_1
set vit_board_accel_synth_run_name \
    [get_property NAME $vit_board_accel_synth_run]
vit_server::require_run_current $vit_board_accel_synth_run_name
vit_project::require_generated_accelerator_synthesis_policy

set vit_board_accel_synth_log [file join \
    [get_property DIRECTORY $vit_board_accel_synth_run] runme.log]
set vit_board_accel_synth_log_copy [file join \
    $vit_server::bundle_root server_logs \
    40_accelerator_child_synth.runme.log]
if {![file isfile $vit_board_accel_synth_log] ||
    [file size $vit_board_accel_synth_log] == 0} {
    error \
        "Generated accelerator synthesis log is missing: $vit_board_accel_synth_log"
}
file copy -force \
    $vit_board_accel_synth_log \
    $vit_board_accel_synth_log_copy

catch {close_design}
open_run synth_1
vit_server::require_nonvacuous_npu board_post_synth
set vit_board_blackbox_gate \
    [vit_server::require_no_blackboxes board_post_synth]
set vit_board_latch_gate \
    [vit_server::require_no_latches board_post_synth]
vit_server::require_no_dsp board_post_synth
set vit_board_ram_mapping_gate \
    [vit_server::require_m8_ram_mapping board_post_synth]
set vit_board_loop_gate \
    [vit_project::require_no_combinational_loops board_post_synth]

set vit_board_utilization [file join \
    $vit_server::report_dir board_post_synth_utilization.rpt]
report_utilization -file $vit_board_utilization
set vit_board_lut_fit_gate [vit_server::require_clb_lut_fit \
    board_post_synth $vit_board_utilization]
report_utilization \
    -hierarchical \
    -hierarchical_depth 16 \
    -file [file join \
        $vit_server::report_dir board_post_synth_hierarchical.rpt]
report_ram_utilization -file [file join \
    $vit_server::report_dir board_post_synth_ram_utilization.rpt]
report_timing_summary \
    -delay_type max \
    -max_paths 50 \
    -report_unconstrained \
    -check_timing_verbose \
    -file [file join \
        $vit_server::report_dir board_post_synth_timing.rpt]
report_ip_status -file [file join \
    $vit_server::report_dir board_post_synth_ip_status.rpt]

set vit_board_synth_dcp [file join \
    $vit_server::artifact_dir board_post_synth.dcp]
write_checkpoint -force $vit_board_synth_dcp
if {![file isfile $vit_board_synth_dcp]} {
    error "Board post-synthesis checkpoint was not created"
}

puts "PASS: clean production board synthesis completed"
puts "  top       : [current_design]"
puts "  checkpoint: $vit_board_synth_dcp"
puts "  blackboxes: $vit_board_blackbox_gate"
puts "  latches   : $vit_board_latch_gate"
puts "  loop gate : $vit_board_loop_gate"
puts "  RAM gate  : $vit_board_ram_mapping_gate"
puts "  LUT fit   : $vit_board_lut_fit_gate"
