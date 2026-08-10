# Fail-fast server/tool/catalog/input check. No project is created here.

set vit_preflight_dir [file normalize [file dirname [info script]]]
source [file join $vit_preflight_dir vivado_server_common.tcl]
source [file join \
    $vit_server::bundle_root scripts vivado vit_project_common.tcl]

vit_server::require_m8_development_manifest
vit_server::ensure_output_dirs
vit_server::require_version
vit_server::register_and_check_catalog

set vit_preflight_sources \
    [vit_project::read_filelist $vit_project::full_axi_filelist]
if {[llength $vit_preflight_sources] != 80} {
    error \
        "full_axi.f must resolve exactly 80 M8 production sources; found [llength $vit_preflight_sources]"
}

set vit_preflight_unique [lsort -unique $vit_preflight_sources]
if {[llength $vit_preflight_unique] != 80} {
    error "full_axi.f contains duplicate source paths"
}

puts "PASS: M8 DEVELOPMENT_UNSEALED Vivado server preflight completed"
puts "  bundle : $vit_server::bundle_root"
puts "  RTL    : [llength $vit_preflight_sources] production files"
puts "  part   : $vit_server::fpga_part"
puts "  board  : $vit_server::board_part"
