# Full pure-SystemVerilog ViT inference in Vivado/XSim.
#
# From the Tcl Console of the open ViT_googlebase project:
#   source /home/qh/Downloads/vit_modelsim_standalone/run_vivado_xsim_e2e.tcl

set vit_e2e_root [file normalize [file dirname [info script]]]
set vit_e2e_input \
    [file join $vit_e2e_root preprocessed embedding_input_patch_A_f32.hex]
set vit_e2e_output [file join $vit_e2e_root results]

if {![file exists $vit_e2e_input]} {
    error "Missing prepared input: $vit_e2e_input"
}
if {![file isdirectory [file join $vit_e2e_root parameters]]} {
    error "Missing parameter directory: [file join $vit_e2e_root parameters]"
}
file mkdir $vit_e2e_output

if {[llength [get_projects -quiet]] == 0} {
    error "Open the ViT_googlebase Vivado project before sourcing this script"
}

set vit_e2e_simset [get_filesets -quiet sim_1]
if {[llength $vit_e2e_simset] != 1} {
    error "Simulation fileset sim_1 was not found"
}

# A previous launch may have already ended through $fatal.  It must be
# relaunched because plusargs are sampled at time zero.
catch {close_sim}

set_property top tb_vit_phase_e $vit_e2e_simset
set_property verilog_define {VIT_PURE_SV_BEHAVIORAL} $vit_e2e_simset
set vit_e2e_xsim_options [list \
    -testplusarg TEST_ID=24 \
    -testplusarg CASE_ID=2 \
    -testplusarg CASE_DIR=$vit_e2e_root \
    -testplusarg INPUT_HEX=$vit_e2e_input \
    -testplusarg OUTPUT_DIR=$vit_e2e_output \
    -testplusarg CHECKPOINT_INJECT=0 \
    -testplusarg MAJOR_ONLY=1 \
]
# The option string begins with "-testplusarg", so the positional
# set_property form would parse it as a set_property option.  The dictionary
# form preserves the complete value.
set_property -dict [list \
    XSIM.SIMULATE.XSIM.MORE_OPTIONS $vit_e2e_xsim_options \
    XSIM.SIMULATE.RUNTIME all \
] $vit_e2e_simset

puts "Launching full ViT end-to-end simulation"
puts "  input : $vit_e2e_input"
puts "  output: $vit_e2e_output"
puts "Expected completion marker:"
puts "  PASS functional run complete: commands=249 checkpoints=249"

launch_simulation -simset sim_1 -mode behavioral
