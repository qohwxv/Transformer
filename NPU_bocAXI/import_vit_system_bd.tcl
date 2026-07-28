# Import the validated AXI/PS/DDR block design into the new ViT_googlebase
# project, regenerate project-local output products, and select the generated
# board-level HDL wrapper as the synthesis top.
#
# Run from the Tcl Console after opening:
#   ViT_googlebase/ViT_googlebase/ViT_googlebase.xpr
#
# Command:
#   source /home/qh/Downloads/vit_modelsim_standalone/import_vit_system_bd.tcl

set vit_bd_repo_root [file normalize [file dirname [info script]]]
set vit_bd_expected_project_dir [file normalize \
    [file join $vit_bd_repo_root ViT_googlebase ViT_googlebase]]
set vit_bd_old_file [file normalize \
    /home/qh/Vivado_project/ViT_googlebase/ViT_googlebase/ViT_googlebase.srcs/sources_1/bd/vit_system/vit_system.bd]
set vit_bd_synth_filelist [file join \
    $vit_bd_repo_root filelists vit_phase_e_axi_wrapper_synth.f]

if {[llength [get_projects -quiet]] == 0} {
    error "Open the new ViT_googlebase project before sourcing this script"
}

set vit_bd_project_dir [file normalize \
    [get_property DIRECTORY [current_project]]]
if {$vit_bd_project_dir ne $vit_bd_expected_project_dir} {
    error \
        "Wrong open project directory: $vit_bd_project_dir; expected $vit_bd_expected_project_dir"
}
if {[get_property PART [current_project]] ne "xczu5ev-sfvc784-1-e"} {
    error "The open project does not target xczu5ev-sfvc784-1-e"
}
if {![file isfile $vit_bd_old_file]} {
    error "Validated source block design is missing: $vit_bd_old_file"
}
if {![file isfile $vit_bd_synth_filelist]} {
    error "Synthesis filelist is missing: $vit_bd_synth_filelist"
}

# Free the XSim kernel and its memory before IP/output-product generation.
catch {close_sim}

# Read the canonical 17-file hardware closure.  Existing files are reused;
# the current simulation project only needs the AXI-Lite control-register RTL
# added, but reading the canonical list also guards against future drift.
set vit_bd_synth_sources [list]
set vit_bd_filelist_handle [open $vit_bd_synth_filelist r]
while {[gets $vit_bd_filelist_handle vit_bd_line] >= 0} {
    set vit_bd_line [string trim $vit_bd_line]
    if {$vit_bd_line eq "" || [string match "#*" $vit_bd_line]} {
        continue
    }
    set vit_bd_source [file normalize \
        [file join $vit_bd_repo_root $vit_bd_line]]
    if {![file isfile $vit_bd_source]} {
        close $vit_bd_filelist_handle
        error "Missing synthesis source: $vit_bd_source"
    }
    lappend vit_bd_synth_sources $vit_bd_source
}
close $vit_bd_filelist_handle

if {[llength $vit_bd_synth_sources] != 17} {
    error \
        "Expected 17 synthesis sources, found [llength $vit_bd_synth_sources]"
}

foreach vit_bd_source $vit_bd_synth_sources {
    set vit_bd_source_object [get_files -quiet [file tail $vit_bd_source]]
    if {[llength $vit_bd_source_object] == 0} {
        add_files -fileset sources_1 -norecurse $vit_bd_source
        set vit_bd_source_object [get_files -quiet [file tail $vit_bd_source]]
    }
    if {[llength $vit_bd_source_object] != 1} {
        error \
            "Expected one project source for $vit_bd_source; found [llength $vit_bd_source_object]"
    }
    set_property -dict [list \
        USED_IN_SYNTHESIS true \
        USED_IN_IMPLEMENTATION true \
    ] $vit_bd_source_object
}

# Keep the pure-SV reference backend and its testbench out of the hardware
# closure while preserving them for sim_1.
foreach vit_bd_sim_only_name [list \
    vit_fp32_math_ref_pkg.sv \
    vit_phase_e_behavioral_engine_top.sv \
    tb_vit_phase_e.sv \
] {
    set vit_bd_sim_only [get_files -quiet $vit_bd_sim_only_name]
    if {[llength $vit_bd_sim_only] == 1} {
        set_property -dict [list \
            USED_IN_SYNTHESIS false \
            USED_IN_IMPLEMENTATION false \
            USED_IN_SIMULATION true \
        ] $vit_bd_sim_only
    }
}

# A simulation-only backend define on sources_1 would disconnect the logical
# DDR request interface.  Preserve unrelated user defines and remove only the
# two simulation-only selectors.
set vit_bd_hardware_defines [list]
foreach vit_bd_define [get_property VERILOG_DEFINE \
    [get_filesets sources_1]] {
    set vit_bd_define_name [lindex [split $vit_bd_define "="] 0]
    if {$vit_bd_define_name ni [list \
        VIT_PURE_SV_BEHAVIORAL \
        VIT_DYNAMIC_SIM_MEMORY \
    ]} {
        lappend vit_bd_hardware_defines $vit_bd_define
    }
}
set_property VERILOG_DEFINE $vit_bd_hardware_defines \
    [get_filesets sources_1]

# Import a project-local copy.  Do not reference or copy the old .gen/XCI
# directories: Vivado regenerates those products for this project.
set vit_bd_file [get_files -quiet */vit_system.bd]
if {[llength $vit_bd_file] == 0} {
    puts "Importing validated vit_system.bd into the new project"
    puts "NOTE: warnings about missing OLD .gen products are expected here"
    import_files -fileset sources_1 -norecurse $vit_bd_old_file
    set vit_bd_file [get_files -quiet */vit_system.bd]
}
if {[llength $vit_bd_file] != 1} {
    error \
        "Expected one imported vit_system.bd; found [llength $vit_bd_file]"
}

open_bd_design $vit_bd_file
validate_bd_design -force
save_bd_design

puts "Regenerating project-local IP and block-design output products"
reset_target all $vit_bd_file
generate_target all $vit_bd_file
set vit_bd_ip_runs [create_ip_run $vit_bd_file]
puts "Created/refreshed OOC IP runs: $vit_bd_ip_runs"

set vit_bd_wrapper_files [make_wrapper -files $vit_bd_file -top]
if {[llength $vit_bd_wrapper_files] != 1} {
    error \
        "Expected one generated vit_system HDL wrapper; found [llength $vit_bd_wrapper_files]"
}

set vit_bd_wrapper_file [lindex $vit_bd_wrapper_files 0]
if {[llength [get_files -quiet [file tail $vit_bd_wrapper_file]]] == 0} {
    add_files -fileset sources_1 -norecurse $vit_bd_wrapper_file
}

set_property top vit_system_wrapper [get_filesets sources_1]
update_compile_order -fileset sources_1

if {[get_property TOP [get_filesets sources_1]] ne \
    "vit_system_wrapper"} {
    error "Failed to set vit_system_wrapper as the synthesis top"
}

puts "PASS: AXI/PS/DDR block design imported and regenerated"
puts "  BD : $vit_bd_file"
puts "  HDL: $vit_bd_wrapper_file"
puts "  TOP: [get_property TOP [get_filesets sources_1]]"
puts "Next: inspect/validate the BD in the GUI, then run synthesis only"
