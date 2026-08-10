set expected_version "2023.2"
set expected_part "xczu5ev-sfvc784-1-e"

set actual_version [version -short]
if {$actual_version ne $expected_version} {
    error "M7_LEAF_PREFLIGHT_FAIL Vivado=$actual_version expected=$expected_version"
}
set matching_parts [get_parts -quiet $expected_part]
if {[llength $matching_parts] != 1} {
    error "M7_LEAF_PREFLIGHT_FAIL part=$expected_part matches=[llength $matching_parts]"
}
create_project -in_memory -part $expected_part
if {[get_property PART [current_project]] ne $expected_part} {
    error "M7_LEAF_PREFLIGHT_FAIL current part mismatch"
}
puts "M7_LEAF_PREFLIGHT_PASS vivado=$actual_version part=$expected_part"
close_project
