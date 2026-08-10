# Shared helpers for the portable ViT Vivado 2023.2 project flow.

namespace eval vit_project {
    variable script_dir [file normalize [file dirname [info script]]]
    variable repo_root [file normalize [file join $script_dir ../..]]
    variable project_file [file join \
        $repo_root VIT_googlebase_rtl ViT_googlebase ViT_googlebase.xpr]
    variable full_axi_filelist [file join $repo_root filelists full_axi.f]
    variable behavioral_filelist [file join $repo_root vit_phase_e_pure_sv.f]
    variable no_dsp_xdc [file join $script_dir no_dsp.xdc]
    variable report_dir [file join $repo_root VIT_googlebase_rtl reports]
    variable synthesis_flatten_hierarchy "none"

    proc require_synthesis_flatten_policy {{run_name synth_1}} {
        variable synthesis_flatten_hierarchy
        set run [get_runs -quiet $run_name]
        if {[llength $run] != 1} {
            error "Expected exactly one synthesis run named $run_name"
        }
        set actual [get_property \
            STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY $run]
        if {$actual ne $synthesis_flatten_hierarchy} {
            error \
                "$run_name FLATTEN_HIERARCHY is $actual; expected $synthesis_flatten_hierarchy"
        }
        puts \
            "PASS: $run_name FLATTEN_HIERARCHY=$synthesis_flatten_hierarchy"
        return $actual
    }

    proc generated_accelerator_synthesis_run {{create_if_missing 0}} {
        set runs [get_runs -quiet *vit_phase_e_axi*_synth_1]
        if {[llength $runs] == 0 && $create_if_missing} {
            set block_designs [get_files -quiet */vit_system.bd]
            if {[llength $block_designs] != 1} {
                error \
                    "Cannot create generated accelerator run: expected one vit_system.bd; found: $block_designs"
            }
            create_ip_run [lindex $block_designs 0]
            set runs [get_runs -quiet *vit_phase_e_axi*_synth_1]
        }
        if {[llength $runs] != 1} {
            error \
                "Expected exactly one generated accelerator OOC synthesis run; found: $runs"
        }
        return [lindex $runs 0]
    }

    proc require_generated_accelerator_synthesis_policy {} {
        variable synthesis_flatten_hierarchy
        set run [generated_accelerator_synthesis_run]
        set run_name [get_property NAME $run]
        set actual_flatten [get_property \
            STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY $run]
        set actual_max_dsp [get_property \
            STEPS.SYNTH_DESIGN.ARGS.MAX_DSP $run]
        if {$actual_flatten ne $synthesis_flatten_hierarchy} {
            error \
                "$run_name FLATTEN_HIERARCHY is $actual_flatten; expected $synthesis_flatten_hierarchy"
        }
        if {$actual_max_dsp != 0} {
            error "$run_name MAX_DSP is $actual_max_dsp; expected 0"
        }
        puts \
            "PASS: $run_name FLATTEN_HIERARCHY=$actual_flatten MAX_DSP=$actual_max_dsp"
        return $run
    }

    proc configure_generated_accelerator_synthesis_policy {} {
        variable synthesis_flatten_hierarchy
        set run [generated_accelerator_synthesis_run 1]
        set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY \
            $synthesis_flatten_hierarchy $run
        set_property STEPS.SYNTH_DESIGN.ARGS.MAX_DSP 0 $run
        return [require_generated_accelerator_synthesis_policy]
    }

    proc require_no_combinational_loops {stage} {
        variable report_dir
        set report_path [file join \
            $report_dir ${stage}_combinational_loops.rpt]
        set result [check_timing \
            -verbose \
            -return_string \
            -override_defaults [list loops]]

        set handle [open $report_path w]
        puts -nonewline $handle $result
        close $handle

        set loop_count -1
        if {![regexp -nocase \
            {There are ([0-9]+) combinational loops} \
            $result -> loop_count] &&
            ![regexp -nocase \
                {checking loops \(([0-9]+)\)} \
                $result -> loop_count]} {
            error "Unable to parse combinational-loop count; see $report_path"
        }
        set disposition PASS
        if {$loop_count != 0} {
            set disposition FAIL
        }
        set handle [open $report_path a]
        puts $handle ""
        puts $handle \
            "M8_COMBINATIONAL_LOOP_GATE $disposition stage=$stage count=$loop_count"
        close $handle
        if {$loop_count != 0} {
            error \
                "Combinational-loop gate failed: count=$loop_count; see $report_path"
        }
        puts "PASS: $stage combinational-loop count is 0"
        return $report_path
    }

    proc read_filelist {filelist} {
        variable repo_root
        if {![file isfile $filelist]} {
            error "Missing filelist: $filelist"
        }

        set sources [list]
        set handle [open $filelist r]
        set line_number 0
        while {[gets $handle line] >= 0} {
            incr line_number
            regsub {#.*$} $line "" line
            set line [string trim $line]
            if {$line eq ""} {
                continue
            }
            if {[llength $line] != 1} {
                close $handle
                error \
                    "$filelist:$line_number: expected one source path per line"
            }
            set token [lindex $line 0]
            if {[file pathtype $token] eq "absolute"} {
                close $handle
                error \
                    "$filelist:$line_number: absolute source path is forbidden"
            }
            set source [file normalize [file join $repo_root $token]]
            if {![file isfile $source]} {
                close $handle
                error "$filelist:$line_number: missing source $source"
            }
            if {[string first "${repo_root}/" $source] != 0} {
                close $handle
                error "$filelist:$line_number: source escapes repository root"
            }
            lappend sources $source
        }
        close $handle
        return $sources
    }

    proc ensure_project {} {
        variable project_file
        if {[llength [get_projects -quiet]] == 0} {
            if {![file isfile $project_file]} {
                error "Missing Vivado project: $project_file"
            }
            open_project $project_file
        }

        set expected_dir [file normalize [file dirname $project_file]]
        set active_dir [file normalize \
            [get_property DIRECTORY [current_project]]]
        if {$active_dir ne $expected_dir} {
            error \
                "Wrong open project directory: $active_dir; expected $expected_dir"
        }
        if {[get_property PART [current_project]] ne \
            "xczu5ev-sfvc784-1-e"} {
            error "ViT_googlebase must target xczu5ev-sfvc784-1-e"
        }
    }

    proc object_path {file_object} {
        set path [get_property NAME $file_object]
        if {[file pathtype $path] ne "absolute"} {
            set project_dir [get_property DIRECTORY [current_project]]
            set path [file join $project_dir $path]
        }
        return [file normalize $path]
    }

    proc find_by_basename {fileset basename} {
        set matches [list]
        foreach file_object [get_files -quiet -of_objects $fileset] {
            if {[file tail [get_property NAME $file_object]] eq $basename} {
                lappend matches $file_object
            }
        }
        return $matches
    }

    proc add_or_rebind_source {fileset source} {
        set source [file normalize $source]
        set basename [file tail $source]
        set exact [list]

        foreach file_object [find_by_basename $fileset $basename] {
            set existing_path [object_path $file_object]
            if {$existing_path eq $source} {
                lappend exact $file_object
            } elseif {![file exists $existing_path]} {
                puts "Removing stale source reference: $existing_path"
                remove_files -fileset $fileset $file_object
            } else {
                error \
                    "Conflicting source basename $basename: $existing_path and $source"
            }
        }

        if {[llength $exact] == 0} {
            add_files -fileset $fileset -norecurse $source
            set exact [find_by_basename $fileset $basename]
        }
        if {[llength $exact] != 1} {
            error "Expected one project source for $source; found [llength $exact]"
        }
        return [lindex $exact 0]
    }

    proc remove_basename_from_fileset {fileset basename} {
        foreach file_object [find_by_basename $fileset $basename] {
            remove_files -fileset $fileset $file_object
        }
    }

    proc sync_design_sources {} {
        variable full_axi_filelist
        set source_set [get_filesets sources_1]
        set sources [read_filelist $full_axi_filelist]
        set missing_sources [list]
        set ordered_objects [list]

        # Audit/rebind existing entries first, then add every missing source in
        # one collection. Calling add_files once per RTL file causes Vivado
        # 2023.2 to emit CRITICAL WARNING [Vivado 12-3645], which correctly
        # fails this flow's severe-message gate even though the design is
        # otherwise valid.
        foreach source $sources {
            set source [file normalize $source]
            set basename [file tail $source]
            set exact [list]
            foreach file_object [find_by_basename $source_set $basename] {
                set existing_path [object_path $file_object]
                if {$existing_path eq $source} {
                    lappend exact $file_object
                } elseif {![file exists $existing_path]} {
                    puts "Removing stale source reference: $existing_path"
                    remove_files -fileset $source_set $file_object
                } else {
                    error \
                        "Conflicting source basename $basename: $existing_path and $source"
                }
            }
            if {[llength $exact] == 0} {
                lappend missing_sources $source
            } elseif {[llength $exact] != 1} {
                error \
                    "Expected one project source for $source; found [llength $exact]"
            }
        }

        if {[llength $missing_sources] > 0} {
            add_files -fileset $source_set -norecurse $missing_sources
        }

        foreach source $sources {
            set exact [find_by_basename $source_set [file tail $source]]
            if {[llength $exact] != 1} {
                error \
                    "Expected one project source for $source after batch add; found [llength $exact]"
            }
            set file_object [lindex $exact 0]
            if {[object_path $file_object] ne [file normalize $source]} {
                error "Project source did not bind to the requested path: $source"
            }
            if {[file extension $source] eq ".sv"} {
                set_property FILE_TYPE SystemVerilog $file_object
            } else {
                set_property FILE_TYPE Verilog $file_object
            }
            set_property -dict [list \
                USED_IN_SYNTHESIS true \
                USED_IN_IMPLEMENTATION true \
                USED_IN_SIMULATION true \
            ] $file_object
            lappend ordered_objects $file_object
        }

        if {[llength $ordered_objects] > 0} {
            reorder_files -fileset $source_set -front $ordered_objects
        }
        update_compile_order -fileset sources_1
    }

    proc sync_behavioral_sources {} {
        variable behavioral_filelist
        variable full_axi_filelist
        set source_set [get_filesets sources_1]
        set sim_set [get_filesets sim_1]
        set design_basenames [list]
        foreach design_source [read_filelist $full_axi_filelist] {
            lappend design_basenames [file tail $design_source]
        }

        foreach source [read_filelist $behavioral_filelist] {
            set basename [file tail $source]
            if {$basename in $design_basenames} {
                continue
            }
            remove_basename_from_fileset $source_set $basename
            set file_object [add_or_rebind_source $sim_set $source]
            set_property FILE_TYPE SystemVerilog $file_object
            set_property -dict [list \
                USED_IN_SYNTHESIS false \
                USED_IN_IMPLEMENTATION false \
                USED_IN_SIMULATION true \
            ] $file_object
        }

        set_property top tb_vit_phase_e $sim_set
        set_property verilog_define {VIT_PURE_SV_BEHAVIORAL} $sim_set
        update_compile_order -fileset sim_1
    }

    proc strip_simulation_defines_from_hardware {} {
        set hardware_defines [list]
        foreach definition [get_property VERILOG_DEFINE \
            [get_filesets sources_1]] {
            set name [lindex [split $definition "="] 0]
            if {$name ni [list \
                VIT_PURE_SV_BEHAVIORAL \
                VIT_DYNAMIC_SIM_MEMORY \
            ]} {
                lappend hardware_defines $definition
            }
        }
        set_property VERILOG_DEFINE $hardware_defines \
            [get_filesets sources_1]
    }

    proc configure_no_dsp {} {
        variable no_dsp_xdc
        variable synthesis_flatten_hierarchy
        set constraint_set [get_filesets constrs_1]
        set xdc_object [add_or_rebind_source $constraint_set $no_dsp_xdc]
        set_property FILE_TYPE XDC $xdc_object
        set_property -dict [list \
            USED_IN_SYNTHESIS true \
            USED_IN_IMPLEMENTATION true \
        ] $xdc_object

        set synth_run [get_runs -quiet synth_1]
        if {[llength $synth_run] != 1} {
            error "Vivado project must contain exactly one synth_1 run"
        }
        set_property STEPS.SYNTH_DESIGN.ARGS.MAX_DSP 0 $synth_run
        set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY \
            $synthesis_flatten_hierarchy $synth_run
        if {[get_property STEPS.SYNTH_DESIGN.ARGS.MAX_DSP $synth_run] != 0} {
            error "Failed to set synth_1 MAX_DSP=0"
        }
        require_synthesis_flatten_policy synth_1
    }

    proc select_hardware_top {} {
        set source_set [get_filesets sources_1]
        if {[llength [get_files -quiet */vit_system.bd]] == 1 &&
            [llength [get_files -quiet *vit_system_wrapper.v]] == 1} {
            set_property top vit_system_wrapper $source_set
        } else {
            puts \
                "WARNING: generated vit_system_wrapper is unavailable; using standalone AXI shim"
            set_property top vit_phase_e_axi_bd_wrapper $source_set
        }
        update_compile_order -fileset sources_1
    }

    proc configure {} {
        ensure_project
        sync_design_sources
        sync_behavioral_sources
        strip_simulation_defines_from_hardware
        configure_no_dsp
        select_hardware_top

        puts "PASS: ViT_googlebase project synchronized"
        puts "  TOP     : [get_property TOP [get_filesets sources_1]]"
        puts "  MAX_DSP : [get_property \
            STEPS.SYNTH_DESIGN.ARGS.MAX_DSP [get_runs synth_1]]"
        puts "  FLATTEN : [get_property \
            STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY [get_runs synth_1]]"
        puts "  RTL     : repository-relative sources from filelists/full_axi.f"
    }
}
