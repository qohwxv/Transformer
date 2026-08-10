# Self-contained pure-SystemVerilog ViT reference inference.
# Production RTL remains in rtl/; real/shortreal reference sources are
# isolated under sim/reference and are selected only by this simulation flow.

set package_dir [file normalize [file dirname [info script]]]
set input_hex [file join $package_dir preprocessed embedding_input_patch_A_f32.hex]
set output_dir [file join $package_dir results]
set behavioral_filelist [file join $package_dir vit_phase_e_pure_sv.f]

cd $package_dir
file mkdir build/modelsim
file mkdir $output_dir

if {![file exists $input_hex]} {
    error "Missing preprocessed input: $input_hex"
}
if {![file isdirectory parameters]} {
    error "Missing parameter directory: [file join $package_dir parameters]"
}
if {![file isfile $behavioral_filelist]} {
    error "Missing behavioral filelist: $behavioral_filelist"
}
if {![file isdirectory build/modelsim/work]} {
    vlib build/modelsim/work
}
vmap work build/modelsim/work

transcript file [file join $output_dir modelsim_transcript.log]
transcript on

vlog -sv \
    +define+VIT_PURE_SV_BEHAVIORAL \
    -work work \
    -f $behavioral_filelist

vsim -t 1ps -voptargs=+acc work.tb_vit_phase_e \
    +TEST_ID=24 \
    +CASE_ID=2 \
    +CASE_DIR=$package_dir \
    +INPUT_HEX=$input_hex \
    +OUTPUT_DIR=$output_dir \
    +CHECKPOINT_INJECT=0 \
    +MAJOR_ONLY=1

run -all
