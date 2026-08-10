# Synchronize the existing ViT_googlebase project with the repository RTL.
#
# Batch:
#   vivado -mode batch -source scripts/vivado/configure_project.tcl
# GUI Tcl console:
#   source scripts/vivado/configure_project.tcl

set vit_configure_script_dir [file normalize [file dirname [info script]]]
source [file join $vit_configure_script_dir vit_project_common.tcl]
vit_project::configure
