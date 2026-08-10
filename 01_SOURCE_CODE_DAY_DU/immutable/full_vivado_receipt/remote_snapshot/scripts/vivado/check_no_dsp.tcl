# Fail the active Vivado run if any DSP primitive exists in the netlist.

if {[llength [current_design -quiet]] == 0} {
    error "Open a synthesized or implemented design before checking DSP usage"
}

set vit_dsp_cells [get_cells -quiet -hierarchical \
    -filter {REF_NAME =~ DSP48* || REF_NAME =~ DSP58*}]
set vit_dsp_count [llength $vit_dsp_cells]

set vit_dsp_script_dir [file normalize [file dirname [info script]]]
set vit_dsp_repo_root [file normalize [file join $vit_dsp_script_dir ../..]]
set vit_dsp_report_dir [file join \
    $vit_dsp_repo_root VIT_googlebase_rtl reports]
file mkdir $vit_dsp_report_dir
set vit_dsp_report [file join $vit_dsp_report_dir no_dsp_check.rpt]

set vit_dsp_handle [open $vit_dsp_report w]
puts $vit_dsp_handle "ViT NPU DSP primitive count: $vit_dsp_count"
foreach vit_dsp_cell $vit_dsp_cells {
    puts $vit_dsp_handle \
        "[get_property REF_NAME $vit_dsp_cell] $vit_dsp_cell"
}
close $vit_dsp_handle

if {$vit_dsp_count != 0} {
    puts "FAIL: synthesized design contains $vit_dsp_count DSP primitive(s)"
    foreach vit_dsp_cell $vit_dsp_cells {
        puts "  [get_property REF_NAME $vit_dsp_cell] $vit_dsp_cell"
    }
    error "DSP48/DSP58 usage is forbidden; see $vit_dsp_report"
}

puts "PASS: DSP primitive count is 0"
puts "  report: $vit_dsp_report"
