# Export-only recovery for a current routed implementation.
#
# This script never resets synthesis or implementation and never reruns
# placement/routing. It advances the existing current impl_1 run only through
# write_bitstream, copies that run-associated BIT into artifacts, and exports
# an XSA that must contain both BIT and HWH entries.

set vit_export_dir [file normalize [file dirname [info script]]]
source [file join $vit_export_dir vivado_server_common.tcl]
source [file join \
    $vit_server::bundle_root scripts vivado vit_project_common.tcl]

vit_server::require_bundle_manifest
vit_server::ensure_output_dirs
vit_server::require_version
vit_server::register_and_check_catalog
vit_server::configure_threads
vit_server::open_bundle_project
vit_server::require_top vit_system_wrapper
vit_server::require_m5_axi_contract_report
vit_server::require_run_current synth_1
vit_server::require_run_current impl_1
vit_project::require_synthesis_flatten_policy synth_1

set vit_export_jobs [vit_server::positive_env VIT_VIVADO_JOBS 1]
set vit_export_run [get_runs impl_1]

catch {close_design}
open_run impl_1
vit_server::require_nonvacuous_npu board_export_current
set vit_export_blackbox_gate \
    [vit_server::require_no_blackboxes board_export_current]
set vit_export_latch_gate \
    [vit_server::require_no_latches board_export_current]
vit_server::require_no_dsp board_export_current
set vit_export_ram_gate \
    [vit_server::require_m8_ram_mapping board_export_current]
set vit_export_loop_gate \
    [vit_project::require_no_combinational_loops board_export_current]
set vit_export_route_gate \
    [vit_server::require_route_complete board_export_current]
set vit_export_timing_gate \
    [vit_server::write_timing_gate board_export_current]
set vit_export_constraint_gate \
    [vit_server::write_constraint_coverage_gate board_export_current]
set vit_export_methodology_gate \
    [vit_server::require_no_methodology_violations board_export_current]
set vit_export_drc_gate \
    [vit_server::require_no_drc_violations board_export_current]

catch {close_design}
launch_runs \
    $vit_export_run \
    -to_step write_bitstream \
    -jobs $vit_export_jobs
wait_on_run $vit_export_run
vit_server::require_run_current impl_1

set vit_export_run_bit [file join \
    [get_property DIRECTORY $vit_export_run] vit_system_wrapper.bit]
set vit_export_bit [file join \
    $vit_server::artifact_dir vit_system_wrapper.bit]
set vit_export_xsa [file join \
    $vit_server::artifact_dir vit_system_wrapper.xsa]

if {![file isfile $vit_export_run_bit] ||
    [file size $vit_export_run_bit] == 0} {
    error \
        "Implementation-run bitstream is missing or empty: $vit_export_run_bit"
}
file copy -force $vit_export_run_bit $vit_export_bit

write_hw_platform \
    -fixed \
    -include_bit \
    -force \
    -file $vit_export_xsa

foreach artifact [list $vit_export_bit $vit_export_xsa] {
    if {![file isfile $artifact] || [file size $artifact] == 0} {
        error "Required export artifact is missing or empty: $artifact"
    }
}

set vit_export_xsa_report \
    [vit_server::validate_xsa_contents \
        $vit_export_xsa $vit_export_bit board_post_route]

puts "PASS: current routed implementation exported without rerouting"
puts "  BIT        : $vit_export_bit"
puts "  XSA + BIT  : $vit_export_xsa"
puts "  XSA report : $vit_export_xsa_report"
puts "  blackboxes : $vit_export_blackbox_gate"
puts "  latches    : $vit_export_latch_gate"
puts "  RAM gate   : $vit_export_ram_gate"
puts "  loop gate  : $vit_export_loop_gate"
puts "  route gate : $vit_export_route_gate"
puts "  timing gate: $vit_export_timing_gate"
puts "  constraints: $vit_export_constraint_gate"
puts "  DRC gate   : $vit_export_drc_gate"
puts "  methodology: $vit_export_methodology_gate"
