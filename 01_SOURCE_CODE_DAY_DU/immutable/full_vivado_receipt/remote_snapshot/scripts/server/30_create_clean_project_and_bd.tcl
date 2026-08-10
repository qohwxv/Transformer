# Create a relocatable project from source, then create/validate vit_system.bd.

set vit_create_server_dir [file normalize [file dirname [info script]]]
source [file join $vit_create_server_dir vivado_server_common.tcl]

vit_server::require_bundle_manifest
vit_server::ensure_output_dirs
vit_server::require_version
vit_server::register_and_check_catalog
vit_server::configure_threads

if {[llength [get_projects -quiet]] == 0} {
    if {[file isfile $vit_server::project_file]} {
        open_project $vit_server::project_file
    } else {
        create_project \
            ViT_googlebase \
            $vit_server::project_dir \
            -part $vit_server::fpga_part \
            -force
        set_property TARGET_LANGUAGE Verilog [current_project]
        set_property SIMULATOR_LANGUAGE Mixed [current_project]
        set_property BOARD_PART \
            $vit_server::board_part \
            [current_project]
    }
}

source [file join \
    $vit_server::bundle_root scripts vivado create_vit_system_bd.tcl]

# The module-reference accelerator is synthesized into a generated OOC DCP.
# Its run has independent defaults from synth_1, so lock the same no-loop and
# no-DSP policy before the project is handed to the board synthesis stage.
vit_project::configure_generated_accelerator_synthesis_policy

vit_server::require_top vit_system_wrapper
if {[llength [get_files -quiet */vit_system.bd]] != 1} {
    error "Expected exactly one generated vit_system.bd"
}
if {[llength [get_files -quiet *vit_system_wrapper.v]] != 1} {
    error "Expected exactly one generated vit_system_wrapper.v"
}

# Persist the exact accelerator geometry read back from the generated BD.
# This makes a board artifact unable to claim R8 while silently retaining a
# stale R4/R2 Module-Reference configuration.
set vit_create_accelerator_cell [get_bd_cells -quiet vit_phase_e_axi_0]
if {[llength $vit_create_accelerator_cell] != 1} {
    error "Expected exactly one vit_phase_e_axi_0 Module-Reference cell"
}
set vit_create_geometry_report [file join \
    $vit_server::report_dir vit_system_geometry.rpt]
set vit_create_geometry_handle [open $vit_create_geometry_report w]
foreach vit_create_geometry_property [list \
    CONFIG.ARRAY_ROWS CONFIG.ARRAY_COLS CONFIG.PE_LANES \
    CONFIG.FP16_STREAMS] {
    puts $vit_create_geometry_handle [format \
        "%s %s" \
        $vit_create_geometry_property \
        [get_property $vit_create_geometry_property \
            $vit_create_accelerator_cell]]
}
close $vit_create_geometry_handle

# create_vit_system_bd.tcl writes this only after every resolved interface
# property has passed the native AXI-128 contract. Refuse to continue with a
# missing, partial, or stale-width report.
set vit_create_axi_contract_report \
    [vit_server::require_m5_axi_contract_report]

set vit_create_export_dir [file join \
    $vit_server::artifact_dir project_exports]
file mkdir $vit_create_export_dir
write_project_tcl -force [file join \
    $vit_create_export_dir recreate_project.tcl]
write_bd_tcl -force [file join \
    $vit_create_export_dir vit_system_bd.tcl]

puts "PASS: clean project and production Block Design are ready"
puts "  project: $vit_server::project_file"
puts "  top    : [get_property TOP [get_filesets sources_1]]"
puts "  geometry: $vit_create_geometry_report"
puts "  AXI contract: $vit_create_axi_contract_report"
