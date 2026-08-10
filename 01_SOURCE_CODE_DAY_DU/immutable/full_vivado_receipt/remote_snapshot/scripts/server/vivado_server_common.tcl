# Shared fail-closed helpers for the remote Vivado 2023.2 sign-off flow.

namespace eval vit_server {
    variable script_dir [file normalize [file dirname [info script]]]
    variable bundle_root [file normalize [file join $script_dir ../..]]
    variable project_dir [file join \
        $bundle_root VIT_googlebase_rtl ViT_googlebase]
    variable project_file [file join $project_dir ViT_googlebase.xpr]
    variable report_dir [file join \
        $bundle_root VIT_googlebase_rtl reports]
    variable artifact_dir [file join \
        $bundle_root VIT_googlebase_rtl artifacts]
    variable board_repo [file join \
        $bundle_root third_party digilent_board_files]
    variable fpga_part "xczu5ev-sfvc784-1-e"
    variable board_part "digilentinc.com:gzu_5ev:part0:1.1"
    variable expected_version "2023.2"

    proc ensure_output_dirs {} {
        variable project_dir
        variable report_dir
        variable artifact_dir
        file mkdir $project_dir
        file mkdir $report_dir
        file mkdir $artifact_dir
    }

    # Fail before implementation when synthesis already proves that the exact
    # design cannot fit the target CLB-LUT capacity.  This is deliberately an
    # early rejection gate, not a replacement for place/route utilization,
    # timing or DRC.  The parser accepts exactly one top-level `CLB LUTs*` row
    # from Vivado report_utilization and records its disposition separately.
    proc require_clb_lut_fit {stage utilization_report} {
        variable report_dir

        if {![regexp {^[A-Za-z0-9_]+$} $stage]} {
            error "Unsafe CLB-LUT fit stage name: $stage"
        }
        set gate_report [file join \
            $report_dir "${stage}_lut_fit_gate.rpt"]
        if {![file isfile $utilization_report] ||
            [file size $utilization_report] == 0} {
            set gate_handle [open $gate_report w]
            puts $gate_handle \
                "M8_CLB_LUT_FIT FAIL stage=$stage reason=missing_utilization_report"
            puts $gate_handle "SOURCE_REPORT [file normalize $utilization_report]"
            close $gate_handle
            error \
                "Missing utilization report for CLB-LUT fit gate: $utilization_report"
        }

        set utilization_handle [open $utilization_report r]
        set utilization_lines [split [read $utilization_handle] "\n"]
        close $utilization_handle
        set matches {}
        foreach line $utilization_lines {
            if {[regexp \
                {^\|[[:space:]]*CLB LUTs\*[[:space:]]*\|[[:space:]]*([0-9][0-9,]*)[[:space:]]*\|[[:space:]]*[0-9][0-9,]*[[:space:]]*\|[[:space:]]*[0-9][0-9,]*[[:space:]]*\|[[:space:]]*([0-9][0-9,]*)[[:space:]]*\|} \
                $line -> used_text available_text]} {
                lappend matches [list $used_text $available_text]
            }
        }
        if {[llength $matches] != 1} {
            set gate_handle [open $gate_report w]
            puts $gate_handle [format \
                "M8_CLB_LUT_FIT FAIL stage=%s reason=clb_lut_row_count count=%d" \
                $stage [llength $matches]]
            puts $gate_handle "SOURCE_REPORT [file normalize $utilization_report]"
            close $gate_handle
            error [format \
                "Expected exactly one CLB LUTs* row in %s; found %d" \
                $utilization_report [llength $matches]]
        }

        lassign [lindex $matches 0] used_text available_text
        set used [string map {"," ""} $used_text]
        set available [string map {"," ""} $available_text]
        if {![string is integer -strict $used] ||
            ![string is integer -strict $available] ||
            $used < 0 || $available < 1} {
            set gate_handle [open $gate_report w]
            puts $gate_handle \
                "M8_CLB_LUT_FIT FAIL stage=$stage reason=invalid_numeric_fields"
            puts $gate_handle "USED_TEXT $used_text"
            puts $gate_handle "AVAILABLE_TEXT $available_text"
            puts $gate_handle "SOURCE_REPORT [file normalize $utilization_report]"
            close $gate_handle
            error \
                "Invalid CLB-LUT utilization fields in $utilization_report"
        }

        set headroom [expr {$available - $used}]
        set disposition PASS
        if {$headroom < 0} {
            set disposition FAIL
        }
        set gate_handle [open $gate_report w]
        puts $gate_handle \
            "M8_CLB_LUT_FIT $disposition stage=$stage used=$used available=$available headroom=$headroom"
        puts $gate_handle "SOURCE_REPORT [file normalize $utilization_report]"
        close $gate_handle

        if {$disposition ne "PASS"} {
            error [format \
                "CLB-LUT device-fit gate failed for %s: used=%d available=%d; see %s" \
                $stage $used $available $gate_report]
        }
        puts \
            "PASS: $stage CLB-LUT fit used=$used available=$available headroom=$headroom"
        return $gate_report
    }

    proc require_m5_axi_contract_report {} {
        variable report_dir
        set report_path [file join \
            $report_dir vit_system_axi_contract.rpt]
        if {![file isfile $report_path] ||
            [file size $report_path] == 0} {
            error "Missing native AXI-128 BD contract report: $report_path"
        }
        set handle [open $report_path r]
        set lines [split [read $handle] "\n"]
        close $handle
        foreach required_line [list \
            "M5_AXI128_CONTRACT PASS" \
            "vit_phase_e_axi_0/M_AXI CONFIG.DATA_WIDTH 128 exact 128" \
            "vit_phase_e_axi_0/M_AXI CONFIG.MAX_BURST_LENGTH 4 exact 4" \
            "vit_phase_e_axi_0/M_AXI CONFIG.NUM_READ_OUTSTANDING 2 exact 2" \
            "vit_phase_e_axi_0/M_AXI CONFIG.NUM_WRITE_OUTSTANDING 1 exact 1" \
            "smartconnect_ddr/S00_AXI CONFIG.DATA_WIDTH 128 exact 128" \
            "smartconnect_ddr/M00_AXI CONFIG.DATA_WIDTH 128 exact 128" \
            "zynq_ultra_ps_e_0/S_AXI_HP0_FPD CONFIG.DATA_WIDTH 128 exact 128" \
        ] {
            if {[lsearch -exact $lines $required_line] < 0} {
                error \
                    "Native AXI-128 contract line is missing from $report_path: $required_line"
            }
        }
        puts "PASS: retained native AXI-128 BD contract report is exact"
        return $report_path
    }

    proc require_m8_development_manifest {} {
        variable bundle_root
        set manifest [file join \
            $bundle_root M8_DEVELOPMENT_SHA256SUMS.txt]
        set verifier [file join \
            $bundle_root run 00_verify_m8_development.sh]
        if {![file isfile $manifest]} {
            error "Missing M8 development checksum manifest: $manifest"
        }
        if {![file isfile $verifier]} {
            error "Missing M8 development verifier: $verifier"
        }
        set bash_path [auto_execok bash]
        if {$bash_path eq ""} {
            error "bash is required to verify the M8 development inputs"
        }
        set verify_code [catch {
            exec $bash_path $verifier 2>@1
        } verify_result verify_options]
        if {$verify_code != 0} {
            return -options $verify_options \
                "M8 DEVELOPMENT_UNSEALED checksum gate failed: $verify_result"
        }
        puts $verify_result
        puts \
            "PASS: M8 DEVELOPMENT_UNSEALED source manifest is valid: $manifest"
    }

    # Compatibility entry point for inherited stage scripts. It verifies the
    # M8 development identity above; historical M5/M7 manifests are ancestry,
    # never the current build identity.
    proc require_bundle_manifest {} {
        puts \
            "INFO: require_bundle_manifest routes to M8 DEVELOPMENT_UNSEALED verification"
        require_m8_development_manifest
    }

    proc positive_env {name default_value} {
        set value $default_value
        if {[info exists ::env($name)]} {
            set value $::env($name)
        }
        if {![string is integer -strict $value] || $value < 1} {
            error "$name must be a positive integer"
        }
        return $value
    }

    proc configure_threads {{default_value 2}} {
        set threads [positive_env \
            VIT_VIVADO_THREADS $default_value]
        set_param general.maxThreads $threads
        puts "PASS: Vivado general.maxThreads=$threads"
        return $threads
    }

    proc require_version {} {
        variable expected_version
        set actual [version -short]
        if {[string first $expected_version $actual] != 0} {
            error \
                "This bundle requires Vivado $expected_version; found $actual"
        }
        puts "PASS: Vivado version is $actual"
    }

    proc register_and_check_catalog {} {
        variable board_repo
        variable board_part
        variable fpga_part

        if {![file isdirectory $board_repo]} {
            error "Missing bundled Digilent board repository: $board_repo"
        }
        set_param board.repoPaths [list $board_repo]

        # Vivado board/IP catalog queries require an open project in this
        # flow. Use a disposable in-memory project when the production
        # project has not been created yet.
        set probe_created 0
        if {[llength [get_projects -quiet]] == 0} {
            create_project \
                -in_memory \
                vit_server_catalog_probe \
                -part $fpga_part
            set probe_created 1
            puts "INFO: opened temporary in-memory project for catalog checks"
        }

        set catalog_code [catch {
            if {[llength [get_parts -quiet $fpga_part]] != 1} {
                error \
                    "Vivado installation does not contain FPGA part $fpga_part"
            }
            if {[llength [get_board_parts -quiet $board_part]] != 1} {
                error \
                    "Vivado cannot resolve board part $board_part from $board_repo"
            }
            foreach pattern [list \
                "xilinx.com:ip:zynq_ultra_ps_e:*" \
                "xilinx.com:ip:smartconnect:*" \
                "xilinx.com:ip:proc_sys_reset:*" \
                "xilinx.com:ip:xlconstant:*" \
            ] {
                if {[llength [get_ipdefs -all -quiet $pattern]] == 0} {
                    error "Required Vivado IP is unavailable: $pattern"
                }
            }
        } catalog_result catalog_options]

        if {$probe_created &&
            [llength [get_projects -quiet]] != 0} {
            close_project
            puts "INFO: closed temporary in-memory catalog project"
        }
        if {$catalog_code != 0} {
            return -options $catalog_options $catalog_result
        }
        puts "PASS: FPGA part, board part and required IP catalog are present"
    }

    proc open_bundle_project {} {
        variable project_file
        variable project_dir
        variable fpga_part

        if {[llength [get_projects -quiet]] == 0} {
            if {![file isfile $project_file]} {
                error \
                    "Missing generated project $project_file; run stage 30 first"
            }
            open_project $project_file
        }
        set actual_dir [file normalize \
            [get_property DIRECTORY [current_project]]]
        if {$actual_dir ne [file normalize $project_dir]} {
            error \
                "Wrong project directory $actual_dir; expected $project_dir"
        }
        if {[get_property PART [current_project]] ne $fpga_part} {
            error "Open project targets the wrong FPGA part"
        }
    }

    proc require_top {expected_top} {
        set actual_top [get_property TOP [get_filesets sources_1]]
        if {$actual_top ne $expected_top} {
            error \
                "Hardware top is $actual_top; expected $expected_top"
        }
        puts "PASS: hardware top is $actual_top"
    }

    proc cells_by_ref {pattern} {
        set matches [list]
        foreach property [list REF_NAME ORIG_REF_NAME] {
            set expression [format {%s =~ %s} $property $pattern]
            if {![catch {
                set found [get_cells -quiet -hierarchical \
                    -filter $expression]
            }]} {
                foreach cell $found {
                    lappend matches $cell
                }
            }
        }
        return [lsort -unique $matches]
    }

    proc write_reachability_report {stage} {
        variable report_dir
        set report_path [file join \
            $report_dir ${stage}_reachability.rpt]
        set handle [open $report_path w]
        foreach pattern [list \
            vit_phase_e_npu* \
            vit_phase_e_axi_wrapper* \
            vit_phase_e_axi_mem_adapter* \
            vit_layer_param_table* \
            vit_fp32_mul_comb_nodsp* \
        ] {
            set matches [cells_by_ref $pattern]
            puts $handle "$pattern [llength $matches]"
            foreach cell $matches {
                puts $handle "  $cell"
            }
        }
        close $handle
        return $report_path
    }

    proc require_nonvacuous_npu {stage} {
        variable report_dir

        set npu_cells [cells_by_ref vit_phase_e_npu*]
        if {[llength $npu_cells] != 1} {
            error \
                "Non-vacuous gate failed: vit_phase_e_npu* count is [llength $npu_cells]"
        }
        foreach required_pattern [list vit_phase_e_axi_wrapper*] {
            set count [llength [cells_by_ref $required_pattern]]
            if {$count != 1} {
                error \
                    "Non-vacuous gate failed: $required_pattern count is $count"
            }
        }

        # Count physical logic specifically below the NPU, rather than
        # accepting LUTs/FFs that could come only from PS/SmartConnect.
        set npu_name [get_property NAME [lindex $npu_cells 0]]
        set npu_scope "${npu_name}/*"
        set lut_expression [format \
            {NAME =~ "%s" && REF_NAME =~ LUT*} $npu_scope]
        set ff_expression [format \
            {NAME =~ "%s" && REF_NAME =~ FD*} $npu_scope]
        set npu_lut_count [llength [get_cells -quiet -hierarchical \
            -filter $lut_expression]]
        set npu_ff_count [llength [get_cells -quiet -hierarchical \
            -filter $ff_expression]]
        if {$npu_lut_count == 0 || $npu_ff_count == 0} {
            error \
                "NPU subtree is empty: LUT=$npu_lut_count FF=$npu_ff_count"
        }

        # Leaf hierarchy counts are exported by write_reachability_report.
        # They are informational because legal flattening can absorb a
        # combinational leaf even with FLATTEN_HIERARCHY=rebuilt.

        set all_blackboxes [get_cells -quiet -hierarchical \
            -filter {IS_BLACKBOX == 1}]
        set vit_blackboxes [list]
        foreach cell $all_blackboxes {
            set ref_name [get_property REF_NAME $cell]
            if {[string match "vit_*" $ref_name] ||
                [string match "*vit_phase*" $cell]} {
                lappend vit_blackboxes $cell
            }
        }
        set blackbox_report [file join \
            $report_dir ${stage}_blackboxes.rpt]
        set handle [open $blackbox_report w]
        puts $handle "all_blackboxes [llength $all_blackboxes]"
        puts $handle "vit_blackboxes [llength $vit_blackboxes]"
        foreach cell $all_blackboxes {
            puts $handle "[get_property REF_NAME $cell] $cell"
        }
        close $handle
        if {[llength $vit_blackboxes] != 0} {
            error \
                "Unresolved ViT black boxes found; see $blackbox_report"
        }

        set reachability_report [write_reachability_report $stage]
        puts \
            "PASS: non-vacuous NPU subtree LUT=$npu_lut_count FF=$npu_ff_count"
        puts "  reachability: $reachability_report"
        puts "  black boxes : $blackbox_report"
    }

    proc require_no_blackboxes {stage} {
        variable report_dir
        set cells [get_cells -quiet -hierarchical \
            -filter {IS_BLACKBOX == 1}]
        set report_path [file join \
            $report_dir ${stage}_blackboxes.rpt]
        set handle [open $report_path w]
        set disposition PASS
        if {[llength $cells] != 0} {
            set disposition FAIL
        }
        puts $handle \
            "M8_BLACKBOX_GATE $disposition stage=$stage count=[llength $cells]"
        puts $handle "all_blackboxes [llength $cells]"
        foreach cell $cells {
            puts $handle "[get_property REF_NAME $cell] $cell"
        }
        close $handle
        if {$disposition ne "PASS"} {
            error \
                "Unresolved black boxes found; see $report_path"
        }
        puts "PASS: $stage blackbox count is 0"
        return $report_path
    }

    proc require_no_latches {stage} {
        variable report_dir
        set cells [get_cells -quiet -hierarchical \
            -filter {REF_NAME =~ LD*}]
        set report_path [file join \
            $report_dir ${stage}_latches.rpt]
        set handle [open $report_path w]
        set disposition PASS
        if {[llength $cells] != 0} {
            set disposition FAIL
        }
        puts $handle \
            "M8_LATCH_GATE $disposition stage=$stage count=[llength $cells]"
        foreach cell $cells {
            puts $handle "[get_property REF_NAME $cell] $cell"
        }
        close $handle
        if {$disposition ne "PASS"} {
            error \
                "Inferred latch usage is forbidden; see $report_path"
        }
        puts "PASS: $stage inferred latch count is 0"
        return $report_path
    }

    proc require_no_dsp {stage} {
        variable report_dir
        set cells [get_cells -quiet -hierarchical \
            -filter {REF_NAME =~ DSP48* || REF_NAME =~ DSP58*}]
        set report_path [file join $report_dir ${stage}_dsp.rpt]
        set handle [open $report_path w]
        puts $handle "DSP48/DSP58 primitive count: [llength $cells]"
        foreach cell $cells {
            puts $handle "[get_property REF_NAME $cell] $cell"
        }
        close $handle
        if {[llength $cells] != 0} {
            error \
                "DSP usage is forbidden; see $report_path"
        }
        puts "PASS: $stage DSP48/DSP58 primitive count is 0"
        return $report_path
    }

    proc cache_primitive_counts {cache_cell} {
        set cache_name [get_property NAME $cache_cell]
        set expression [format {NAME =~ "%s/*"} $cache_name]
        set descendants [get_cells -quiet -hierarchical \
            -filter $expression]
        set counts [dict create \
            ramb36 0 \
            ramb18 0 \
            uram 0 \
            lutram 0]
        set details [list]

        foreach cell $descendants {
            set ref_name [get_property REF_NAME $cell]
            set category ""
            if {[string match "RAMB36*" $ref_name]} {
                set category ramb36
            } elseif {[string match "RAMB18*" $ref_name]} {
                set category ramb18
            } elseif {[string match "URAM*" $ref_name]} {
                set category uram
            } elseif {
                [string match "RAM32M*" $ref_name] ||
                [string match "RAM64M*" $ref_name] ||
                [string match "RAMD*" $ref_name] ||
                [string match "RAMS*" $ref_name] ||
                [string match "RAM32X*" $ref_name] ||
                [string match "RAM64X*" $ref_name] ||
                [string match "RAM128X*" $ref_name] ||
                [string match "RAM256X*" $ref_name] ||
                [string match "RAM512X*" $ref_name]
            } {
                set category lutram
            }
            if {$category ne ""} {
                dict incr counts $category
                lappend details "$category $ref_name $cell"
            }
        }
        return [list $counts [lsort $details]]
    }

    proc require_m4_r8_cache_mapping {stage} {
        variable report_dir

        set activation_cells \
            [cells_by_ref vit_gemm_activation_panel_cache*]
        set bias_cells [cells_by_ref vit_gemm_bias_cache*]
        set report_path [file join \
            $report_dir ${stage}_cache_mapping.rpt]
        set handle [open $report_path w]
        puts $handle "stage $stage"
        puts $handle "expected_array_rows 8"
        puts $handle "activation_cache_instances [llength $activation_cells]"
        puts $handle "bias_cache_instances [llength $bias_cells]"

        if {[llength $activation_cells] != 1 ||
            [llength $bias_cells] != 1} {
            close $handle
            error \
                "M4-R8 cache hierarchy gate failed; see $report_path"
        }

        lassign [cache_primitive_counts \
            [lindex $activation_cells 0]] activation_counts activation_details
        lassign [cache_primitive_counts \
            [lindex $bias_cells 0]] bias_counts bias_details

        foreach {name counts details} [list \
            activation $activation_counts $activation_details \
            bias $bias_counts $bias_details \
        ] {
            puts $handle "$name.ramb36 [dict get $counts ramb36]"
            puts $handle "$name.ramb18 [dict get $counts ramb18]"
            puts $handle "$name.uram [dict get $counts uram]"
            puts $handle "$name.lutram [dict get $counts lutram]"
            foreach detail $details {
                puts $handle "  $detail"
            }
        }
        close $handle

        set failures [list]
        foreach {name counts expected_ramb36} [list \
            activation $activation_counts 32 \
            bias $bias_counts 4 \
        ] {
            if {[dict get $counts ramb36] != $expected_ramb36} {
                lappend failures \
                    "$name RAMB36=[dict get $counts ramb36] expected=$expected_ramb36"
            }
            foreach forbidden [list ramb18 uram lutram] {
                if {[dict get $counts $forbidden] != 0} {
                    lappend failures \
                        "$name $forbidden=[dict get $counts $forbidden] expected=0"
                }
            }
        }
        if {[llength $failures] != 0} {
            error \
                "M4-R8 cache mapping failed: [join $failures {, }]; see $report_path"
        }
        puts \
            "PASS: $stage M4-R8 caches map to 32+4 RAMB36 and no RAMB18/URAM/LUTRAM"
        return $report_path
    }

    proc require_m8_ram_mapping {stage} {
        variable report_dir

        set report_path [file join \
            $report_dir ${stage}_m8_ram_mapping.rpt]
        set handle [open $report_path w]
        puts $handle "stage $stage"

        set hierarchy_specs [list \
            activation vit_gemm_activation_panel_cache* 32 \
            bias vit_gemm_bias_cache* 4 \
            layernorm vit_layernorm_engine_fp32* 3 \
            softmax vit_softmax_engine_fp32* 1 \
            layer_param vit_layer_param_table* 1 \
        ]
        set hierarchy_counts [dict create]
        set failures [list]

        foreach {name pattern expected_ramb36} $hierarchy_specs {
            set instances [cells_by_ref $pattern]
            puts $handle "$name.instances [llength $instances]"
            if {[llength $instances] != 1} {
                lappend failures \
                    "$name instances=[llength $instances] expected=1"
                continue
            }
            lassign [cache_primitive_counts \
                [lindex $instances 0]] counts details
            dict set hierarchy_counts $name $counts
            foreach resource [list ramb36 ramb18 uram lutram] {
                puts $handle "$name.$resource [dict get $counts $resource]"
            }
            foreach detail $details {
                puts $handle "  $name $detail"
            }
            if {[dict get $counts ramb36] != $expected_ramb36} {
                lappend failures \
                    "$name RAMB36=[dict get $counts ramb36] expected=$expected_ramb36"
            }
            foreach forbidden [list ramb18 uram lutram] {
                if {[dict get $counts $forbidden] != 0} {
                    lappend failures \
                        "$name $forbidden=[dict get $counts $forbidden] expected=0"
                }
            }
        }

        set all_ramb36 [get_cells -quiet -hierarchical \
            -filter {REF_NAME =~ RAMB36*}]
        set all_ramb18 [get_cells -quiet -hierarchical \
            -filter {REF_NAME =~ RAMB18*}]
        set all_uram [get_cells -quiet -hierarchical \
            -filter {REF_NAME =~ URAM*}]
        set all_lutram [get_cells -quiet -hierarchical -filter {
            REF_NAME =~ RAM32M* ||
            REF_NAME =~ RAM64M* ||
            REF_NAME =~ RAMD* ||
            REF_NAME =~ RAMS* ||
            REF_NAME =~ RAM32X* ||
            REF_NAME =~ RAM64X* ||
            REF_NAME =~ RAM128X* ||
            REF_NAME =~ RAM256X* ||
            REF_NAME =~ RAM512X*
        }]
        puts $handle "global.ramb36 [llength $all_ramb36]"
        puts $handle "global.ramb18 [llength $all_ramb18]"
        puts $handle "global.uram [llength $all_uram]"
        puts $handle "global.lutram [llength $all_lutram]"
        foreach cell $all_ramb36 {
            puts $handle \
                "  global ramb36 [get_property REF_NAME $cell] $cell"
        }
        foreach cell $all_ramb18 {
            puts $handle \
                "  global ramb18 [get_property REF_NAME $cell] $cell"
        }
        foreach cell $all_uram {
            puts $handle \
                "  global uram [get_property REF_NAME $cell] $cell"
        }
        foreach cell $all_lutram {
            puts $handle \
                "  global lutram [get_property REF_NAME $cell] $cell"
        }

        if {[llength $all_ramb36] != 41} {
            lappend failures \
                "global RAMB36=[llength $all_ramb36] expected=41"
        }
        if {[llength $all_ramb18] != 0} {
            lappend failures \
                "global RAMB18=[llength $all_ramb18] expected=0"
        }
        if {[llength $all_uram] != 0} {
            lappend failures \
                "global URAM=[llength $all_uram] expected=0"
        }

        set layernorm_lutram -1
        set softmax_lutram -1
        if {[dict exists $hierarchy_counts layernorm]} {
            set layernorm_lutram \
                [dict get $hierarchy_counts layernorm lutram]
        }
        if {[dict exists $hierarchy_counts softmax]} {
            set softmax_lutram \
                [dict get $hierarchy_counts softmax lutram]
        }

        set disposition PASS
        if {[llength $failures] != 0} {
            set disposition FAIL
        }
        puts $handle [format \
            "M8_RAM_HIERARCHY %s stage=%s total_ramb36=%d activation=32 bias=4 layernorm=3 softmax=1 layer_param=1 ramb18=%d uram=%d layernorm_lutram=%d softmax_lutram=%d" \
            $disposition $stage [llength $all_ramb36] \
            [llength $all_ramb18] [llength $all_uram] \
            $layernorm_lutram $softmax_lutram]
        foreach failure $failures {
            puts $handle "FAILURE $failure"
        }
        close $handle

        if {$disposition ne "PASS"} {
            error \
                "M8 RAM hierarchy gate failed: [join $failures {, }]; see $report_path"
        }
        puts \
            "PASS: $stage M8 RAMB36 hierarchy is 32+4+3+1+1=41 with no RAMB18/URAM or hierarchy LUTRAM"
        return $report_path
    }

    proc require_run_complete {run_name} {
        set run [get_runs -quiet $run_name]
        if {[llength $run] != 1} {
            error "Expected exactly one run named $run_name"
        }
        set status [get_property STATUS $run]
        set progress [get_property PROGRESS $run]
        if {![string match "*Complete*" $status] ||
            $progress ne "100%"} {
            error \
                "$run_name did not complete: STATUS=$status PROGRESS=$progress"
        }
        puts "PASS: $run_name completed: $status"
        return $run
    }

    proc require_run_current {run_name} {
        set run [require_run_complete $run_name]
        if {"NEEDS_REFRESH" ni [list_property $run]} {
            error "Vivado run $run_name has no NEEDS_REFRESH property"
        }
        set needs_refresh [get_property NEEDS_REFRESH $run]
        if {![string is boolean -strict $needs_refresh]} {
            error \
                "Unexpected NEEDS_REFRESH value on $run_name: $needs_refresh"
        }
        if {$needs_refresh} {
            error \
                "$run_name is stale and must be regenerated from current inputs"
        }
        puts "PASS: $run_name is current"
        return $run
    }

    proc require_route_complete {stage} {
        variable report_dir
        set fully_routed \
            [report_route_status -boolean_check ROUTED_FULLY]
        set route_errors \
            [report_route_status -boolean_check ERRORS_IN_ROUTES]
        foreach {name value} [list \
            ROUTED_FULLY $fully_routed \
            ERRORS_IN_ROUTES $route_errors \
        ] {
            if {![string is boolean -strict $value]} {
                error "Unexpected $name route status: $value"
            }
        }

        set report_path [file join \
            $report_dir ${stage}_route_gate.rpt]
        set handle [open $report_path w]
        puts $handle "ROUTED_FULLY $fully_routed"
        puts $handle "ERRORS_IN_ROUTES $route_errors"
        close $handle
        if {!$fully_routed || $route_errors} {
            error "Route gate failed; see $report_path"
        }
        puts "PASS: design is fully routed with no route errors"
        return $report_path
    }

    proc write_constraint_coverage_gate {stage} {
        variable report_dir
        set report_path [file join \
            $report_dir ${stage}_constraint_coverage_gate.rpt]
        set handle [open $report_path w]
        set failures [list]

        # Top-level PS fixed I/O is intentionally not covered by PL
        # input/output delays. Internal clock coverage and partial delays
        # must nevertheless be clean.
        foreach check_name [list \
            no_clock \
            unconstrained_internal_endpoints \
            partial_input_delay \
            partial_output_delay \
        ] {
            set result [check_timing \
                -verbose \
                -return_string \
                -override_defaults [list $check_name]]
            puts $handle "===== $check_name ====="
            puts $handle $result
            set summaries [regexp -all -inline -nocase \
                {There (are|is)[ \t\r\n]+([0-9]+)} \
                $result]
            if {[llength $summaries] == 0 ||
                [expr {[llength $summaries] % 3}] != 0} {
                close $handle
                error \
                    "Cannot parse check_timing result for $check_name"
            }
            for {set index 2} {$index < [llength $summaries]} {
                incr index 3
            } {
                set count [lindex $summaries $index]
                if {$count != 0} {
                    lappend failures "$check_name=$count"
                }
            }
        }
        set disposition PASS
        if {[llength $failures] != 0} {
            set disposition FAIL
        }
        puts $handle \
            "M8_CONSTRAINT_COVERAGE_GATE $disposition stage=$stage failures=[llength $failures]"
        close $handle
        if {[llength $failures] != 0} {
            error \
                "Timing constraint coverage failed: [join $failures {, }]; see $report_path"
        }
        puts "PASS: internal timing constraint coverage checks are clean"
        return $report_path
    }

    proc require_no_drc_violations {stage} {
        variable report_dir
        set detail_report [file join \
            $report_dir ${stage}_drc.rpt]
        report_drc -file $detail_report

        set violations [get_drc_violations -quiet]
        set severe [list]
        foreach violation $violations {
            set severity [string toupper [string trim \
                [get_property SEVERITY $violation]]]
            if {[lsearch -exact \
                [list FATAL ERROR "CRITICAL WARNING"] $severity] >= 0} {
                lappend severe [list $severity $violation]
            }
        }

        set gate_report [file join \
            $report_dir ${stage}_drc_gate.rpt]
        set handle [open $gate_report w]
        set disposition PASS
        if {[llength $violations] != 0} {
            set disposition FAIL
        }
        puts $handle \
            "M8_DRC_GATE $disposition stage=$stage total=[llength $violations] severe=[llength $severe]"
        foreach violation $violations {
            set severity [string toupper [string trim \
                [get_property SEVERITY $violation]]]
            puts $handle "$severity $violation"
        }
        close $handle
        if {$disposition ne "PASS"} {
            error \
                "DRC gate requires zero total violations; see $detail_report and $gate_report"
        }
        puts "PASS: $stage total DRC violation count is 0"
        return $gate_report
    }

    proc require_no_methodology_violations {stage} {
        variable report_dir
        set detail_report [file join \
            $report_dir ${stage}_methodology.rpt]
        report_methodology -file $detail_report

        set violations [get_methodology_violations -quiet]
        set severe [list]
        foreach violation $violations {
            set severity [string toupper [string trim \
                [get_property SEVERITY $violation]]]
            if {[lsearch -exact \
                [list FATAL ERROR "CRITICAL WARNING"] $severity] >= 0} {
                lappend severe [list $severity $violation]
            }
        }

        set gate_report [file join \
            $report_dir ${stage}_methodology_gate.rpt]
        set handle [open $gate_report w]
        set disposition PASS
        if {[llength $violations] != 0} {
            set disposition FAIL
        }
        puts $handle \
            "M8_METHODOLOGY_GATE $disposition stage=$stage total=[llength $violations] severe=[llength $severe]"
        foreach violation $violations {
            set severity [string toupper [string trim \
                [get_property SEVERITY $violation]]]
            puts $handle "$severity $violation"
        }
        close $handle
        if {$disposition ne "PASS"} {
            error \
                "Methodology gate requires zero total violations; see $detail_report and $gate_report"
        }
        puts "PASS: $stage total methodology violation count is 0"
        return $gate_report
    }

    proc validate_xsa_contents {xsa_path bit_path stage} {
        variable report_dir
        foreach tool [list unzip cmp sha256sum] {
            if {[auto_execok $tool] eq ""} {
                error "$tool is required to validate XSA contents"
            }
        }
        if {![file exists $bit_path] ||
            [file type $bit_path] eq "link" ||
            ![file isfile $bit_path] ||
            [file size $bit_path] == 0} {
            error "External BIT is missing, empty or symlinked: $bit_path"
        }
        if {![file exists $xsa_path] ||
            [file type $xsa_path] eq "link" ||
            ![file isfile $xsa_path] ||
            [file size $xsa_path] == 0} {
            error "XSA is missing, empty or symlinked: $xsa_path"
        }
        if {[catch {exec unzip -tq $xsa_path} test_result]} {
            error "XSA is not a readable ZIP archive: $test_result"
        }
        if {[catch {exec unzip -Z1 $xsa_path} entry_text]} {
            error "Cannot list XSA contents: $entry_text"
        }

        set bit_entries [list]
        set hwh_entries [list]
        set expected_hwh_entries [list \
            vit_system.hwh \
            vit_system_smartconnect_control_0.hwh \
            vit_system_smartconnect_ddr_0.hwh]
        foreach entry [split $entry_text "\n"] {
            if {[string match -nocase "*.bit" $entry]} {
                lappend bit_entries $entry
            }
            if {[string match -nocase "*.hwh" $entry]} {
                lappend hwh_entries $entry
            }
        }

        set artifact_bit_sha256 UNAVAILABLE
        set embedded_bit_sha256 UNAVAILABLE
        set embedded_bit_equal 0
        set actual_hwh_entries [lsort -ascii $hwh_entries]
        set hwh_set_equal [expr {
            [llength $hwh_entries] == 3 &&
            $actual_hwh_entries eq $expected_hwh_entries
        }]
        if {[llength $bit_entries] == 1 &&
            $hwh_set_equal} {
            set embedded_bit_entry [lindex $bit_entries 0]
            set artifact_hash_text [exec sha256sum $bit_path]
            if {![regexp {^([0-9a-f]{64})[[:space:]]} \
                $artifact_hash_text -> artifact_bit_sha256]} {
                error "Cannot parse external BIT SHA-256: $artifact_hash_text"
            }
            set embedded_hash_text [exec unzip -p \
                $xsa_path $embedded_bit_entry | sha256sum]
            if {![regexp {^([0-9a-f]{64})[[:space:]]} \
                $embedded_hash_text -> embedded_bit_sha256]} {
                error "Cannot parse embedded BIT SHA-256: $embedded_hash_text"
            }
            if {![catch {
                exec unzip -p $xsa_path $embedded_bit_entry | \
                    cmp -s $bit_path -
            }]} {
                set embedded_bit_equal 1
            }
        }

        set disposition FAIL
        if {[llength $bit_entries] == 1 &&
            $hwh_set_equal &&
            $embedded_bit_equal &&
            $artifact_bit_sha256 eq $embedded_bit_sha256} {
            set disposition PASS
        }
        set report_path [file join \
            $report_dir ${stage}_xsa_contents.rpt]
        set handle [open $report_path w]
        puts $handle "bit_entries [llength $bit_entries]"
        foreach entry $bit_entries {
            puts $handle "  $entry"
        }
        puts $handle "hwh_entries [llength $hwh_entries]"
        foreach entry $hwh_entries {
            puts $handle "  $entry"
        }
        puts $handle \
            "M8_XSA_CONTENT_GATE $disposition stage=$stage bit_entries=[llength $bit_entries] hwh_entries=[llength $hwh_entries] hwh_set_equal=$hwh_set_equal hwh_set=[join $actual_hwh_entries ,] embedded_bit_equal=$embedded_bit_equal bit_sha256=$artifact_bit_sha256 embedded_bit_sha256=$embedded_bit_sha256"
        close $handle

        if {$disposition ne "PASS"} {
            error \
                "XSA requires exactly one BIT, the exact three-HWH canonical set and an embedded BIT equal to the external artifact; see $report_path"
        }
        puts \
            "PASS: XSA contains exactly one BIT and the canonical three-HWH set; embedded BIT equals external artifact SHA256=$artifact_bit_sha256"
        return $report_path
    }

    proc write_timing_gate {stage} {
        variable report_dir
        set setup_paths [get_timing_paths -quiet \
            -delay_type max -max_paths 1 -nworst 1]
        set hold_paths [get_timing_paths -quiet \
            -delay_type min -max_paths 1 -nworst 1]
        if {[llength $setup_paths] == 0 ||
            [llength $hold_paths] == 0} {
            error "No setup/hold timing path is available for sign-off"
        }
        set setup_slack [get_property SLACK [lindex $setup_paths 0]]
        set hold_slack [get_property SLACK [lindex $hold_paths 0]]
        set report_path [file join \
            $report_dir ${stage}_timing_gate.rpt]
        set handle [open $report_path w]
        puts $handle "setup_wns $setup_slack"
        puts $handle "hold_whs $hold_slack"
        close $handle
        if {[expr {double($setup_slack) < 0.0}]} {
            error "Setup timing failed: WNS=$setup_slack"
        }
        if {[expr {double($hold_slack) < 0.0}]} {
            error "Hold timing failed: WHS=$hold_slack"
        }
        puts \
            "PASS: timing gate WNS=$setup_slack WHS=$hold_slack"
        return $report_path
    }
}
