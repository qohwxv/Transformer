# Route, sign off timing/DRC/DSP, then write bitstream and full-NPU XSA.

set vit_board_impl_dir [file normalize [file dirname [info script]]]
source [file join $vit_board_impl_dir vivado_server_common.tcl]
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
vit_project::require_synthesis_flatten_policy synth_1
vit_project::require_generated_accelerator_synthesis_policy

# Implementation is never allowed to rely on an informal resource estimate or
# on a stale console observation.  Re-parse both authoritative synthesis
# utilization reports immediately before launch.  In the normal clean
# run_all.sh flow these reports were produced by stages 20 and 40 after the
# output tree was emptied; a direct stage-50 invocation therefore also fails
# closed when either prerequisite report is absent or over device capacity.
set vit_impl_ooc_lut_fit_gate [vit_server::require_clb_lut_fit \
    rtl_ooc_post_synth \
    [file join $vit_server::report_dir \
        rtl_standalone_post_synth_utilization.rpt]]
set vit_impl_board_lut_fit_gate [vit_server::require_clb_lut_fit \
    board_post_synth \
    [file join $vit_server::report_dir \
        board_post_synth_utilization.rpt]]

set vit_impl_jobs [vit_server::positive_env VIT_VIVADO_JOBS 4]
set vit_impl_run [get_runs impl_1]
reset_run $vit_impl_run

# Stop at routed design. Bitstream is written only after all sign-off gates.
launch_runs $vit_impl_run -to_step route_design -jobs $vit_impl_jobs
wait_on_run $vit_impl_run
vit_server::require_run_current impl_1

catch {close_design}
open_run impl_1
vit_server::require_nonvacuous_npu board_post_route
set vit_impl_blackbox_gate \
    [vit_server::require_no_blackboxes board_post_route]
set vit_impl_latch_gate \
    [vit_server::require_no_latches board_post_route]
vit_server::require_no_dsp board_post_route
set vit_impl_ram_mapping_gate \
    [vit_server::require_m8_ram_mapping board_post_route]
set vit_impl_loop_gate \
    [vit_project::require_no_combinational_loops board_post_route]

report_utilization -file [file join \
    $vit_server::report_dir board_post_route_utilization.rpt]
report_utilization \
    -hierarchical \
    -hierarchical_depth 16 \
    -file [file join \
        $vit_server::report_dir board_post_route_hierarchical.rpt]
report_ram_utilization -file [file join \
    $vit_server::report_dir board_post_route_ram_utilization.rpt]
report_timing_summary \
    -delay_type min_max \
    -max_paths 100 \
    -report_unconstrained \
    -check_timing_verbose \
    -file [file join \
        $vit_server::report_dir board_post_route_timing.rpt]
check_timing -verbose -file [file join \
    $vit_server::report_dir board_post_route_check_timing.rpt]
report_route_status -file [file join \
    $vit_server::report_dir board_post_route_status.rpt]
set vit_impl_route_gate \
    [vit_server::require_route_complete board_post_route]
report_clock_utilization -file [file join \
    $vit_server::report_dir board_post_route_clock_utilization.rpt]
set vit_impl_methodology_gate \
    [vit_server::require_no_methodology_violations board_post_route]
set vit_impl_drc_gate \
    [vit_server::require_no_drc_violations board_post_route]

set vit_impl_timing_gate \
    [vit_server::write_timing_gate board_post_route]
set vit_impl_constraint_gate \
    [vit_server::write_constraint_coverage_gate board_post_route]

set vit_impl_dcp [file join \
    $vit_server::artifact_dir board_post_route.dcp]
set vit_impl_bit [file join \
    $vit_server::artifact_dir vit_system_wrapper.bit]
set vit_impl_xsa [file join \
    $vit_server::artifact_dir vit_system_wrapper.xsa]

write_checkpoint -force $vit_impl_dcp

# Generate the bitstream through impl_1 so write_hw_platform -include_bit can
# resolve it from the implementation run. A direct write_bitstream from the
# opened routed design leaves impl_1 marked only as route_design Complete.
catch {close_design}
launch_runs $vit_impl_run -to_step write_bitstream -jobs $vit_impl_jobs
wait_on_run $vit_impl_run
vit_server::require_run_current impl_1

set vit_impl_run_bit [file join \
    [get_property DIRECTORY $vit_impl_run] vit_system_wrapper.bit]
if {![file isfile $vit_impl_run_bit] ||
    [file size $vit_impl_run_bit] == 0} {
    error "Implementation-run bitstream is missing or empty: $vit_impl_run_bit"
}
file copy -force $vit_impl_run_bit $vit_impl_bit

write_hw_platform \
    -fixed \
    -include_bit \
    -force \
    -file $vit_impl_xsa

foreach artifact [list \
    $vit_impl_dcp \
    $vit_impl_bit \
    $vit_impl_xsa \
] {
    if {![file isfile $artifact] || [file size $artifact] == 0} {
        error "Required hardware artifact is missing or empty: $artifact"
    }
}
set vit_impl_xsa_report \
    [vit_server::validate_xsa_contents \
        $vit_impl_xsa $vit_impl_bit board_post_route]

puts "PASS: production board implementation sign-off completed"
puts "  OOC LUT fit: $vit_impl_ooc_lut_fit_gate"
puts "  board LUT fit: $vit_impl_board_lut_fit_gate"
puts "  blackboxes: $vit_impl_blackbox_gate"
puts "  latches   : $vit_impl_latch_gate"
puts "  timing gate: $vit_impl_timing_gate"
puts "  loop gate  : $vit_impl_loop_gate"
puts "  RAM gate   : $vit_impl_ram_mapping_gate"
puts "  constraints: $vit_impl_constraint_gate"
puts "  route gate : $vit_impl_route_gate"
puts "  DRC gate   : $vit_impl_drc_gate"
puts "  methodology: $vit_impl_methodology_gate"
puts "  XSA report : $vit_impl_xsa_report"
puts "  routed DCP : $vit_impl_dcp"
puts "  bitstream  : $vit_impl_bit"
puts "  XSA + bit  : $vit_impl_xsa"
