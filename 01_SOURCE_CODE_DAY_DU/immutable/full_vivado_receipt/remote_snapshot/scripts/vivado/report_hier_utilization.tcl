# Export post-synthesis utilization with hierarchy preserved.

if {[llength [current_design -quiet]] == 0} {
    error "Open a synthesized or implemented design before exporting utilization"
}

set vit_report_script_dir [file normalize [file dirname [info script]]]
set vit_report_repo_root [file normalize \
    [file join $vit_report_script_dir ../..]]
set vit_report_dir [file join \
    $vit_report_repo_root VIT_googlebase_rtl reports]
file mkdir $vit_report_dir

set vit_report_design [current_design]
set vit_report_stage post_synth
if {[string match -nocase "*impl*" $vit_report_design]} {
    set vit_report_stage post_impl
}

set vit_report_summary [file join \
    $vit_report_dir ${vit_report_stage}_utilization.rpt]
set vit_report_hierarchy [file join \
    $vit_report_dir ${vit_report_stage}_utilization_hierarchical.rpt]

report_utilization -file $vit_report_summary
report_utilization \
    -hierarchical \
    -hierarchical_depth 12 \
    -file $vit_report_hierarchy

puts "PASS: utilization reports exported"
puts "  summary   : $vit_report_summary"
puts "  hierarchy : $vit_report_hierarchy"
