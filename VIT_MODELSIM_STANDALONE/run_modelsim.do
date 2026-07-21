# Self-contained pure-SystemVerilog ViT inference.
# From ModelSim Transcript: do /absolute/path/vit_modelsim_standalone/run_modelsim.do

set package_dir [file normalize [file dirname [info script]]]
set input_hex [file join $package_dir preprocessed embedding_input_patch_A_f32.hex]
set output_dir [file join $package_dir results]

cd $package_dir
file mkdir build/modelsim
file mkdir $output_dir

if {![file exists $input_hex]} {
    error "Missing preprocessed input: $input_hex"
}
if {![file isdirectory parameters]} {
    error "Missing parameter directory: [file join $package_dir parameters]"
}
if {![file isdirectory build/modelsim/work]} {
    vlib build/modelsim/work
}
vmap work build/modelsim/work

transcript file results/modelsim_transcript.log
transcript on

vlog -sv \
    +define+VIT_PURE_SV_BEHAVIORAL \
    -work work \
    -f vit_phase_e_pure_sv.f

vsim -t 1ps -voptargs=+acc work.tb_vit_phase_e \
    +TEST_ID=24 \
    +CASE_ID=2 \
    +CASE_DIR=$package_dir \
    +INPUT_HEX=$input_hex \
    +OUTPUT_DIR=$output_dir \
    +CHECKPOINT_INJECT=0 \
    +MAJOR_ONLY=1

run -all
