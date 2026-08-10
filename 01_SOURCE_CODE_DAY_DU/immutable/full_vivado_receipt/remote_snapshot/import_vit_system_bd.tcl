# Backward-compatible repository-root entry point.
#
# The production implementation now lives beside the other Vivado scripts
# and can create the project-local vit_system design when it is absent, or
# verify/regenerate it without deleting an existing design.
#
# Batch:
#   vivado -mode batch -source import_vit_system_bd.tcl
# GUI Tcl console, from the repository root:
#   source import_vit_system_bd.tcl

set vit_bd_repo_root [file normalize [file dirname [info script]]]
set vit_bd_create_script [file join \
    $vit_bd_repo_root scripts vivado create_vit_system_bd.tcl]

if {![file isfile $vit_bd_create_script]} {
    error "Missing production block-design flow: $vit_bd_create_script"
}

source $vit_bd_create_script
