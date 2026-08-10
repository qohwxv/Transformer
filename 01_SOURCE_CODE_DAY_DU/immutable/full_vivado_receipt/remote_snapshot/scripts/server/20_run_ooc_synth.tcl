# Standalone production RTL+AXI synthesis before any Block Design work.

set vit_ooc_server_dir [file normalize [file dirname [info script]]]
source [file join $vit_ooc_server_dir vivado_server_common.tcl]
vit_server::require_bundle_manifest
vit_server::ensure_output_dirs
vit_server::require_version
vit_server::register_and_check_catalog

source [file join \
    $vit_server::bundle_root scripts vivado run_rtl_synth_nodsp.tcl]

if {[llength [current_design -quiet]] == 0} {
    error "OOC synthesis returned without an open synthesized design"
}
vit_server::require_nonvacuous_npu rtl_ooc_post_synth
set vit_ooc_blackbox_gate \
    [vit_server::require_no_blackboxes rtl_ooc_post_synth]
set vit_ooc_latch_gate \
    [vit_server::require_no_latches rtl_ooc_post_synth]
vit_server::require_no_dsp rtl_ooc_post_synth
set vit_ooc_ram_gate \
    [vit_server::require_m8_ram_mapping rtl_ooc_post_synth]
set vit_ooc_loop_gate \
    [vit_project::require_no_combinational_loops rtl_ooc_post_synth]
set vit_ooc_fit_gate [vit_server::require_clb_lut_fit \
    rtl_ooc_post_synth \
    [file join $vit_server::report_dir \
        rtl_standalone_post_synth_utilization.rpt]]

set vit_ooc_dcp [file join \
    $vit_server::artifact_dir rtl_ooc_post_synth.dcp]
write_checkpoint -force $vit_ooc_dcp
if {![file isfile $vit_ooc_dcp]} {
    error "OOC checkpoint was not created: $vit_ooc_dcp"
}

puts "PASS: non-vacuous standalone RTL+AXI OOC synthesis"
puts "  checkpoint: $vit_ooc_dcp"
puts "  blackboxes: $vit_ooc_blackbox_gate"
puts "  latches   : $vit_ooc_latch_gate"
puts "  RAM gate  : $vit_ooc_ram_gate"
puts "  loop gate : $vit_ooc_loop_gate"
puts "  LUT fit   : $vit_ooc_fit_gate"
puts \
    "  note: OOC timing is an internal proxy; board timing is gated post-route"
