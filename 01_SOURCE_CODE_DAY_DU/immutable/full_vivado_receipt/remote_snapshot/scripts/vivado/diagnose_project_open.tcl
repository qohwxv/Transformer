# Read-only Vivado project-open diagnostic.
#
# Usage:
#   vivado -mode batch -source scripts/vivado/diagnose_project_open.tcl \
#       -tclargs path/to/project.xpr

if {$argc != 1} {
    error "Expected exactly one .xpr path"
}

set diagnostic_project [file normalize [lindex $argv 0]]
if {![file isfile $diagnostic_project]} {
    error "Missing Vivado project: $diagnostic_project"
}

puts "Opening project read-only: $diagnostic_project"
open_project -read_only $diagnostic_project

set diagnostic_sources [get_filesets sources_1]
puts "PASS: project opened"
puts "  PART    : [get_property PART [current_project]]"
puts "  TOP     : [get_property TOP $diagnostic_sources]"
puts "  SOURCES : [llength [get_files -quiet -of_objects $diagnostic_sources]]"

close_project
