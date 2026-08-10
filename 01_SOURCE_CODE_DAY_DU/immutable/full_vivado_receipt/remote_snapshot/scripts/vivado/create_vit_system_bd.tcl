# Create or verify the production Genesys ZU-5EV block design.
#
# This script is intentionally project-local and non-destructive:
#   * If vit_system does not exist, it is created from the repository RTL.
#   * If vit_system already exists, its required topology is verified in
#     place.  A different or half-built design is never silently deleted.
#
# Architecture (one 50 MHz PL clock domain):
#
#   PS M_AXI_HPM0_FPD
#     -> smartconnect_control (AXI4 -> AXI4-Lite)
#     -> vit_phase_e_axi_0/S_AXI
#
#   vit_phase_e_axi_0/M_AXI (native 128-bit AXI4, up to four beats)
#     -> smartconnect_ddr (128-bit -> 128-bit)
#     -> PS S_AXI_HP0_FPD
#
#   vit_phase_e_axi_0/irq_o -> PS pl_ps_irq0[0]
#
# Batch:
#   vivado -mode batch -source scripts/vivado/create_vit_system_bd.tcl
#
# GUI Tcl console, from the repository root:
#   source scripts/vivado/create_vit_system_bd.tcl

namespace eval vit_system_bd {
    variable script_dir [file normalize [file dirname [info script]]]
    variable repo_root [file normalize [file join $script_dir ../..]]
    variable common_script [file join $script_dir vit_project_common.tcl]
    variable board_repo [file join \
        $repo_root third_party digilent_board_files]
    variable board_part "digilentinc.com:gzu_5ev:part0:1.1"
    variable fpga_part "xczu5ev-sfvc784-1-e"
    variable design_name "vit_system"
    variable module_name "vit_phase_e_axi_bd_wrapper"
    variable module_cell_name "vit_phase_e_axi_0"
    variable array_rows 8
    variable array_cols 2
    variable pe_lanes 16
    variable fp16_streams 8
    variable pl_clock_mhz 50
    variable pl_clock_hz 50000000
    variable m_axi_data_width 128
    variable m_axi_addr_width 40
    variable m_axi_id_width 1
    variable m_axi_max_burst_length 4
    variable m_axi_read_outstanding 2
    variable m_axi_write_outstanding 1
    variable control_base 0xA0000000
    variable control_range 0x00001000
    # The 4 GiB physical DDR map reported by the Digilent preset is split
    # into 2 GiB at address zero and 2 GiB at the start of the PS high DDR
    # aperture.  Map those physical portions, not the entire larger high
    # address aperture advertised by the generic PS IP.
    variable ddr_low_base 0x0000000000
    variable ddr_low_range 0x80000000
    variable ddr_high_base 0x0800000000
    variable ddr_high_range 0x80000000

    proc one {objects description} {
        if {[llength $objects] != 1} {
            error \
                "Expected one $description; found [llength $objects]"
        }
        return [lindex $objects 0]
    }

    proc cell {path} {
        return [one [get_bd_cells -quiet $path] "BD cell $path"]
    }

    proc intf_pin {path} {
        return [one \
            [get_bd_intf_pins -quiet $path] \
            "BD interface pin $path"]
    }

    proc pin {path} {
        return [one [get_bd_pins -quiet $path] "BD pin $path"]
    }

    proc addr_space {path} {
        return [one \
            [get_bd_addr_spaces -quiet $path] \
            "BD address space $path"]
    }

    proc addr_segment_by_tail {interface tail_name} {
        set matches [list]
        foreach segment [get_bd_addr_segs \
            -quiet -of_objects $interface] {
            if {[file tail [get_property NAME $segment]] eq $tail_name} {
                lappend matches $segment
            }
        }
        return [one \
            $matches \
            "address segment $tail_name on [get_property NAME $interface]"]
    }

    proc mapped_segment_by_tail {space tail_name} {
        set matches [list]
        foreach segment [get_bd_addr_segs \
            -quiet -of_objects $space] {
            if {[file tail [get_property NAME $segment]] eq $tail_name} {
                lappend matches $segment
            }
        }
        return [one \
            $matches \
            "mapped address segment $tail_name in [get_property NAME $space]"]
    }

    proc require_interface_net {args} {
        set expected_net ""
        foreach path $args {
            set object [intf_pin $path]
            set nets [get_bd_intf_nets -quiet -of_objects $object]
            set net [one $nets "interface net connected to $path"]
            set net_name [get_property NAME $net]
            if {$expected_net eq ""} {
                set expected_net $net_name
            } elseif {$net_name ne $expected_net} {
                error \
                    "Interface $path is on $net_name, expected $expected_net"
            }
        }
    }

    proc require_scalar_net {args} {
        set expected_net ""
        foreach path $args {
            set object [pin $path]
            set nets [get_bd_nets -quiet -of_objects $object]
            set net [one $nets "net connected to $path"]
            set net_name [get_property NAME $net]
            if {$expected_net eq ""} {
                set expected_net $net_name
            } elseif {$net_name ne $expected_net} {
                error \
                    "Pin $path is on $net_name, expected $expected_net"
            }
        }
    }

    proc require_property {object property expected} {
        set actual [get_property $property $object]
        if {$actual ne $expected} {
            error \
                "$property on [get_property NAME $object] is $actual; expected $expected"
        }
    }

    proc interface_property {path property} {
        set object [intf_pin $path]
        set property_code [catch {
            set value [get_property $property $object]
        } property_result property_options]
        if {$property_code != 0} {
            error \
                "Cannot read $property from BD interface $path: $property_result"
        }
        if {$value eq ""} {
            error "$property on BD interface $path is empty"
        }
        return $value
    }

    proc require_interface_string {path property expected} {
        set actual [interface_property $path $property]
        if {$actual ne $expected} {
            error \
                "$property on BD interface $path is $actual; expected $expected"
        }
        return [list $path $property $actual exact $expected]
    }

    proc require_interface_numeric {path property expected comparison} {
        set actual [interface_property $path $property]
        if {[catch {
            set actual_number [expr {wide($actual)}]
            set expected_number [expr {wide($expected)}]
        } numeric_error]} {
            error \
                "$property on BD interface $path is not numeric: $actual ($numeric_error)"
        }

        switch -- $comparison {
            exact {
                if {$actual_number != $expected_number} {
                    error \
                        "$property on BD interface $path is $actual; expected $expected"
                }
            }
            at_least {
                if {$actual_number < $expected_number} {
                    error \
                        "$property on BD interface $path is $actual; expected at least $expected"
                }
            }
            default {
                error "Unsupported interface comparison $comparison"
            }
        }
        return [list $path $property $actual $comparison $expected]
    }

    proc write_axi_contract_report {} {
        variable repo_root
        variable module_cell_name
        variable m_axi_data_width
        variable m_axi_addr_width
        variable m_axi_id_width
        variable m_axi_max_burst_length
        variable m_axi_read_outstanding
        variable m_axi_write_outstanding

        set report_path [file join \
            $repo_root VIT_googlebase_rtl reports \
            vit_system_axi_contract.rpt]
        # A failed re-validation must not leave a previous PASS report that
        # could be mistaken for evidence from the current generated design.
        if {[file exists $report_path]} {
            file delete -force -- $report_path
        }

        # Read back the resolved BD interface parameters after validation.
        # Checking only the PS HP port is insufficient: the old design exposed
        # a 32-bit accelerator port and relied on SmartConnect width conversion.
        set records [list]
        foreach string_check [list \
            [list ${module_cell_name}/S_AXI CONFIG.PROTOCOL AXI4LITE] \
            [list ${module_cell_name}/M_AXI CONFIG.PROTOCOL AXI4] \
            [list smartconnect_ddr/S00_AXI CONFIG.PROTOCOL AXI4] \
            [list smartconnect_ddr/M00_AXI CONFIG.PROTOCOL AXI4] \
            [list zynq_ultra_ps_e_0/S_AXI_HP0_FPD CONFIG.PROTOCOL AXI4] \
        ] {
            lassign $string_check path property expected
            lappend records \
                [require_interface_string $path $property $expected]
        }

        foreach numeric_check [list \
            [list ${module_cell_name}/S_AXI CONFIG.DATA_WIDTH 32 exact] \
            [list ${module_cell_name}/S_AXI CONFIG.ADDR_WIDTH 12 exact] \
            [list ${module_cell_name}/S_AXI CONFIG.MAX_BURST_LENGTH 1 exact] \
            [list ${module_cell_name}/S_AXI CONFIG.NUM_READ_OUTSTANDING 1 exact] \
            [list ${module_cell_name}/S_AXI CONFIG.NUM_WRITE_OUTSTANDING 1 exact] \
            [list ${module_cell_name}/M_AXI CONFIG.DATA_WIDTH $m_axi_data_width exact] \
            [list ${module_cell_name}/M_AXI CONFIG.ADDR_WIDTH $m_axi_addr_width exact] \
            [list ${module_cell_name}/M_AXI CONFIG.ID_WIDTH $m_axi_id_width exact] \
            [list ${module_cell_name}/M_AXI CONFIG.SUPPORTS_NARROW_BURST 1 exact] \
            [list ${module_cell_name}/M_AXI CONFIG.MAX_BURST_LENGTH $m_axi_max_burst_length exact] \
            [list ${module_cell_name}/M_AXI CONFIG.NUM_READ_OUTSTANDING $m_axi_read_outstanding exact] \
            [list ${module_cell_name}/M_AXI CONFIG.NUM_WRITE_OUTSTANDING $m_axi_write_outstanding exact] \
            [list smartconnect_ddr/S00_AXI CONFIG.DATA_WIDTH $m_axi_data_width exact] \
            [list smartconnect_ddr/S00_AXI CONFIG.MAX_BURST_LENGTH $m_axi_max_burst_length at_least] \
            [list smartconnect_ddr/S00_AXI CONFIG.NUM_READ_OUTSTANDING $m_axi_read_outstanding at_least] \
            [list smartconnect_ddr/S00_AXI CONFIG.NUM_WRITE_OUTSTANDING $m_axi_write_outstanding at_least] \
            [list smartconnect_ddr/M00_AXI CONFIG.DATA_WIDTH $m_axi_data_width exact] \
            [list smartconnect_ddr/M00_AXI CONFIG.MAX_BURST_LENGTH $m_axi_max_burst_length at_least] \
            [list smartconnect_ddr/M00_AXI CONFIG.NUM_READ_OUTSTANDING $m_axi_read_outstanding at_least] \
            [list smartconnect_ddr/M00_AXI CONFIG.NUM_WRITE_OUTSTANDING $m_axi_write_outstanding at_least] \
            [list zynq_ultra_ps_e_0/S_AXI_HP0_FPD CONFIG.DATA_WIDTH $m_axi_data_width exact] \
            [list zynq_ultra_ps_e_0/S_AXI_HP0_FPD CONFIG.MAX_BURST_LENGTH $m_axi_max_burst_length at_least] \
            [list zynq_ultra_ps_e_0/S_AXI_HP0_FPD CONFIG.NUM_READ_OUTSTANDING $m_axi_read_outstanding at_least] \
            [list zynq_ultra_ps_e_0/S_AXI_HP0_FPD CONFIG.NUM_WRITE_OUTSTANDING $m_axi_write_outstanding at_least] \
        ] {
            lassign $numeric_check path property expected comparison
            lappend records [require_interface_numeric \
                $path $property $expected $comparison]
        }

        file mkdir [file dirname $report_path]
        set report_handle [open $report_path w]
        puts $report_handle "M5_AXI128_CONTRACT PASS"
        puts $report_handle \
            "path property actual comparison expected"
        foreach record $records {
            puts $report_handle [join $record " "]
        }
        close $report_handle
        puts "PASS: M5 native AXI-128 BD contract: $report_path"
        return $report_path
    }

    proc require_address {space name expected_offset expected_range} {
        set segment [mapped_segment_by_tail $space $name]
        set actual_offset [get_property OFFSET $segment]
        set actual_range [get_property RANGE $segment]
        if {[expr {$actual_offset != $expected_offset}]} {
            error \
                "$name offset is $actual_offset; expected $expected_offset"
        }
        if {[expr {$actual_range != $expected_range}]} {
            error \
                "$name range is $actual_range; expected $expected_range"
        }
        return $segment
    }

    proc check_prerequisites {} {
        variable board_repo
        variable board_part
        variable fpga_part
        variable module_name

        if {[string first "2023.2" [version -short]] != 0} {
            error \
                "This block-design flow is gated to Vivado 2023.2; found [version -short]"
        }
        if {![file isdirectory $board_repo]} {
            error "Missing project-local Digilent board repository: $board_repo"
        }

        # Register the repository before opening/configuring the project so
        # the checked-in board part is reproducible on a clean workstation.
        set_param board.repoPaths [list $board_repo]
        if {[llength [get_board_parts -quiet $board_part]] != 1} {
            error "Vivado cannot resolve board part $board_part from $board_repo"
        }
        if {[llength [get_parts -quiet $fpga_part]] != 1} {
            error "Vivado cannot resolve FPGA part $fpga_part"
        }

        foreach ip_pattern [list \
            "xilinx.com:ip:zynq_ultra_ps_e:*" \
            "xilinx.com:ip:smartconnect:*" \
            "xilinx.com:ip:proc_sys_reset:*" \
            "xilinx.com:ip:xlconstant:*" \
        ] {
            if {[llength [get_ipdefs -all -quiet $ip_pattern]] == 0} {
                error "Required Vivado IP is unavailable: $ip_pattern"
            }
        }

        if {[can_resolve_reference $module_name] == 0} {
            error \
                "Vivado cannot resolve module reference $module_name; synchronize filelists/full_axi.f first"
        }
    }

    proc configure_project_and_board {} {
        variable board_part
        variable fpga_part

        ::vit_project::configure
        set_property BOARD_PART $board_part [current_project]
        if {[get_property BOARD_PART [current_project]] ne $board_part} {
            error "Failed to select Genesys ZU-5EV board part"
        }
        if {[get_property PART [current_project]] ne $fpga_part} {
            error "Wrong FPGA part after board selection"
        }
    }

    proc configure_ps {ps_cell} {
        variable pl_clock_mhz

        # These GP-to-physical-interface mappings are defined by the
        # Vivado 2022.2 zynq_ultra_ps_e component metadata:
        #   M_AXI_GP0 -> M_AXI_HPM0_FPD
        #   S_AXI_GP2 -> S_AXI_HP0_FPD
        apply_bd_automation \
            -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
            -config {apply_board_preset "1"} \
            $ps_cell

        set_property -dict [list \
            CONFIG.PSU__FPGA_PL0_ENABLE {1} \
            CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $pl_clock_mhz \
            CONFIG.PSU__USE__FABRIC__RST {1} \
            CONFIG.PSU__NUM_FABRIC_RESETS {1} \
            CONFIG.PSU__USE__M_AXI_GP0 {1} \
            CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
            CONFIG.PSU__USE__M_AXI_GP1 {0} \
            CONFIG.PSU__USE__M_AXI_GP2 {0} \
            CONFIG.PSU__USE__S_AXI_GP0 {0} \
            CONFIG.PSU__USE__S_AXI_GP1 {0} \
            CONFIG.PSU__USE__S_AXI_GP2 {1} \
            CONFIG.PSU__SAXIGP2__DATA_WIDTH {128} \
            CONFIG.PSU__USE_DIFF_RW_CLK_GP2 {0} \
            CONFIG.PSU__USE__S_AXI_GP3 {0} \
            CONFIG.PSU__USE__S_AXI_GP4 {0} \
            CONFIG.PSU__USE__S_AXI_GP5 {0} \
            CONFIG.PSU__USE__S_AXI_GP6 {0} \
            CONFIG.PSU__USE__IRQ0 {1} \
            CONFIG.PSU__USE__IRQ1 {0} \
            CONFIG.PSU__HIGH_ADDRESS__ENABLE {1} \
        ] $ps_cell
    }

    proc create_design {} {
        variable design_name
        variable module_name
        variable module_cell_name
        variable array_rows
        variable array_cols
        variable pe_lanes
        variable fp16_streams
        variable control_base
        variable control_range
        variable ddr_low_base
        variable ddr_low_range
        variable ddr_high_base
        variable ddr_high_range

        create_bd_design $design_name
        current_bd_design $design_name

        set ps_cell [create_bd_cell \
            -type ip \
            -vlnv xilinx.com:ip:zynq_ultra_ps_e:* \
            zynq_ultra_ps_e_0]
        configure_ps $ps_cell

        set control_connect [create_bd_cell \
            -type ip \
            -vlnv xilinx.com:ip:smartconnect:* \
            smartconnect_control]
        set_property -dict [list \
            CONFIG.NUM_SI {1} \
            CONFIG.NUM_MI {1} \
        ] $control_connect

        set ddr_connect [create_bd_cell \
            -type ip \
            -vlnv xilinx.com:ip:smartconnect:* \
            smartconnect_ddr]
        set_property -dict [list \
            CONFIG.NUM_SI {1} \
            CONFIG.NUM_MI {1} \
        ] $ddr_connect

        create_bd_cell \
            -type ip \
            -vlnv xilinx.com:ip:proc_sys_reset:* \
            proc_sys_reset_0
        # Select user-driven polarity metadata. In Vivado 2023.2 the derived
        # CONFIG.POLARITY property is read-only; VALUE_SRC plus the connected
        # active-low nets produces C_EXT_RESET_HIGH/C_AUX_RESET_HIGH = 0.
        foreach reset_pin_name [list ext_reset_in aux_reset_in] {
            set reset_pin [pin proc_sys_reset_0/$reset_pin_name]
            set_property CONFIG.POLARITY.VALUE_SRC USER $reset_pin
        }

        set const_zero [create_bd_cell \
            -type ip \
            -vlnv xilinx.com:ip:xlconstant:* \
            const_zero]
        set_property -dict [list \
            CONFIG.CONST_WIDTH {1} \
            CONFIG.CONST_VAL {0} \
        ] $const_zero

        set const_one [create_bd_cell \
            -type ip \
            -vlnv xilinx.com:ip:xlconstant:* \
            const_one]
        set_property -dict [list \
            CONFIG.CONST_WIDTH {1} \
            CONFIG.CONST_VAL {1} \
        ] $const_one

        set module_cell [create_bd_cell \
            -type module \
            -reference $module_name \
            $module_cell_name]
        set_property -dict [list \
            CONFIG.ARRAY_ROWS $array_rows \
            CONFIG.ARRAY_COLS $array_cols \
            CONFIG.PE_LANES $pe_lanes \
            CONFIG.FP16_STREAMS $fp16_streams \
        ] $module_cell

        # PS software control path.
        connect_bd_intf_net \
            [intf_pin zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] \
            [intf_pin smartconnect_control/S00_AXI]
        connect_bd_intf_net \
            [intf_pin smartconnect_control/M00_AXI] \
            [intf_pin ${module_cell_name}/S_AXI]

        # NPU DDR path. Both accelerator and HP0 are native 128-bit. Retain
        # SmartConnect for AXI protocol adaptation and registered connectivity;
        # it must not silently reintroduce width conversion or serialization.
        connect_bd_intf_net \
            [intf_pin ${module_cell_name}/M_AXI] \
            [intf_pin smartconnect_ddr/S00_AXI]
        connect_bd_intf_net \
            [intf_pin smartconnect_ddr/M00_AXI] \
            [intf_pin zynq_ultra_ps_e_0/S_AXI_HP0_FPD]

        # All AXI and compute logic is synchronous to PL_CLK0 at 50 MHz.
        connect_bd_net \
            [pin zynq_ultra_ps_e_0/pl_clk0] \
            [pin zynq_ultra_ps_e_0/maxihpm0_fpd_aclk] \
            [pin zynq_ultra_ps_e_0/saxihp0_fpd_aclk] \
            [pin smartconnect_control/aclk] \
            [pin smartconnect_ddr/aclk] \
            [pin proc_sys_reset_0/slowest_sync_clk] \
            [pin ${module_cell_name}/aclk]

        connect_bd_net \
            [pin zynq_ultra_ps_e_0/pl_resetn0] \
            [pin proc_sys_reset_0/ext_reset_in]
        connect_bd_net \
            [pin const_zero/dout] \
            [pin proc_sys_reset_0/mb_debug_sys_rst]
        connect_bd_net \
            [pin const_one/dout] \
            [pin proc_sys_reset_0/aux_reset_in] \
            [pin proc_sys_reset_0/dcm_locked]
        connect_bd_net \
            [pin proc_sys_reset_0/interconnect_aresetn] \
            [pin smartconnect_control/aresetn] \
            [pin smartconnect_ddr/aresetn]
        connect_bd_net \
            [pin proc_sys_reset_0/peripheral_aresetn] \
            [pin ${module_cell_name}/aresetn]

        connect_bd_net \
            [pin ${module_cell_name}/irq_o] \
            [pin zynq_ultra_ps_e_0/pl_ps_irq0]

        set ps_data_space [addr_space zynq_ultra_ps_e_0/Data]
        set control_target [addr_segment_by_tail \
            [intf_pin ${module_cell_name}/S_AXI] reg0]
        create_bd_addr_seg \
            -range $control_range \
            -offset $control_base \
            $ps_data_space \
            $control_target \
            SEG_vit_control_Reg

        set npu_space [addr_space ${module_cell_name}/M_AXI]
        set hp0_interface [intf_pin \
            zynq_ultra_ps_e_0/S_AXI_HP0_FPD]
        set ddr_low_target [addr_segment_by_tail \
            $hp0_interface HP0_DDR_LOW]
        set ddr_high_target [addr_segment_by_tail \
            $hp0_interface HP0_DDR_HIGH]

        create_bd_addr_seg \
            -range $ddr_low_range \
            -offset $ddr_low_base \
            $npu_space \
            $ddr_low_target \
            SEG_vit_ddr_low
        create_bd_addr_seg \
            -range $ddr_high_range \
            -offset $ddr_high_base \
            $npu_space \
            $ddr_high_target \
            SEG_vit_ddr_high

        validate_bd_design -force
        save_bd_design
    }

    proc verify_design {} {
        variable module_cell_name
        variable array_rows
        variable array_cols
        variable pe_lanes
        variable fp16_streams
        variable pl_clock_mhz
        variable pl_clock_hz
        variable control_base
        variable control_range
        variable ddr_low_base
        variable ddr_low_range
        variable ddr_high_base
        variable ddr_high_range

        foreach path [list \
            zynq_ultra_ps_e_0 \
            smartconnect_control \
            smartconnect_ddr \
            proc_sys_reset_0 \
            const_zero \
            const_one \
            $module_cell_name \
        ] {
            cell $path
        }

        set ps_cell [cell zynq_ultra_ps_e_0]
        set accelerator_cell [cell $module_cell_name]
        require_property $accelerator_cell CONFIG.ARRAY_ROWS $array_rows
        require_property $accelerator_cell CONFIG.ARRAY_COLS $array_cols
        require_property $accelerator_cell CONFIG.PE_LANES $pe_lanes
        require_property $accelerator_cell CONFIG.FP16_STREAMS $fp16_streams
        set ps_contract [list \
            CONFIG.PSU__FPGA_PL0_ENABLE 1 \
            CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $pl_clock_mhz \
            CONFIG.PSU__USE__FABRIC__RST 1 \
            CONFIG.PSU__DDRC__ENABLE 1 \
            CONFIG.PSU__HIGH_ADDRESS__ENABLE 1 \
            CONFIG.PSU__DDR_HIGH_ADDRESS_GUI_ENABLE 1 \
            CONFIG.PSU_DDR_RAM_LOWADDR_OFFSET 0x80000000 \
            CONFIG.PSU_DDR_RAM_HIGHADDR_OFFSET 0x800000000 \
            CONFIG.PSU__USE__M_AXI_GP0 1 \
            CONFIG.PSU__MAXIGP0__DATA_WIDTH 32 \
            CONFIG.PSU__USE__S_AXI_GP2 1 \
            CONFIG.PSU__SAXIGP2__DATA_WIDTH 128 \
            CONFIG.PSU__USE_DIFF_RW_CLK_GP2 0 \
            CONFIG.PSU__USE__IRQ0 1 \
            CONFIG.PSU__NUM_FABRIC_RESETS 1 \
            CONFIG.PSU__NUM_F2P0__INTR__INPUTS 1 \
        ]
        for {set index 0} {$index < [llength $ps_contract]} {
            incr index 2
        } {
            require_property \
                $ps_cell \
                [lindex $ps_contract $index] \
                [lindex $ps_contract [expr {$index + 1}]]
        }
        require_property \
            [pin proc_sys_reset_0/ext_reset_in] \
            CONFIG.POLARITY \
            ACTIVE_LOW
        require_property \
            [pin proc_sys_reset_0/ext_reset_in] \
            CONFIG.POLARITY.VALUE_SRC \
            USER
        require_property \
            [cell proc_sys_reset_0] \
            CONFIG.C_EXT_RESET_HIGH \
            0
        require_property \
            [pin proc_sys_reset_0/aux_reset_in] \
            CONFIG.POLARITY \
            ACTIVE_LOW
        require_property \
            [pin proc_sys_reset_0/aux_reset_in] \
            CONFIG.POLARITY.VALUE_SRC \
            USER
        require_property \
            [cell proc_sys_reset_0] \
            CONFIG.C_AUX_RESET_HIGH \
            0

        foreach connect_name [list \
            smartconnect_control \
            smartconnect_ddr \
        ] {
            set connect_cell [cell $connect_name]
            require_property $connect_cell CONFIG.NUM_SI 1
            require_property $connect_cell CONFIG.NUM_MI 1
        }

        require_interface_net \
            zynq_ultra_ps_e_0/M_AXI_HPM0_FPD \
            smartconnect_control/S00_AXI
        require_interface_net \
            smartconnect_control/M00_AXI \
            ${module_cell_name}/S_AXI
        require_interface_net \
            ${module_cell_name}/M_AXI \
            smartconnect_ddr/S00_AXI
        require_interface_net \
            smartconnect_ddr/M00_AXI \
            zynq_ultra_ps_e_0/S_AXI_HP0_FPD

        require_scalar_net \
            zynq_ultra_ps_e_0/pl_clk0 \
            zynq_ultra_ps_e_0/maxihpm0_fpd_aclk \
            zynq_ultra_ps_e_0/saxihp0_fpd_aclk \
            smartconnect_control/aclk \
            smartconnect_ddr/aclk \
            proc_sys_reset_0/slowest_sync_clk \
            ${module_cell_name}/aclk
        require_scalar_net \
            zynq_ultra_ps_e_0/pl_resetn0 \
            proc_sys_reset_0/ext_reset_in
        require_scalar_net \
            const_zero/dout \
            proc_sys_reset_0/mb_debug_sys_rst
        require_scalar_net \
            const_one/dout \
            proc_sys_reset_0/aux_reset_in \
            proc_sys_reset_0/dcm_locked
        require_scalar_net \
            proc_sys_reset_0/interconnect_aresetn \
            smartconnect_control/aresetn \
            smartconnect_ddr/aresetn
        require_scalar_net \
            proc_sys_reset_0/peripheral_aresetn \
            ${module_cell_name}/aresetn
        require_scalar_net \
            ${module_cell_name}/irq_o \
            zynq_ultra_ps_e_0/pl_ps_irq0

        set ps_data_space [addr_space zynq_ultra_ps_e_0/Data]
        require_address \
            $ps_data_space \
            SEG_vit_control_Reg \
            $control_base \
            $control_range

        set npu_space [addr_space ${module_cell_name}/M_AXI]
        require_address \
            $npu_space \
            SEG_vit_ddr_low \
            $ddr_low_base \
            $ddr_low_range
        require_address \
            $npu_space \
            SEG_vit_ddr_high \
            $ddr_high_base \
            $ddr_high_range

        validate_bd_design -force
        write_axi_contract_report
        require_property \
            [pin ${module_cell_name}/aclk] \
            CONFIG.FREQ_HZ \
            $pl_clock_hz
        require_property \
            $ps_cell \
            CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ \
            $pl_clock_mhz
        save_bd_design
    }

    proc open_or_create {} {
        variable design_name

        set bd_files [get_files -quiet */${design_name}.bd]
        if {[llength $bd_files] == 0} {
            puts "Creating project-local block design $design_name"
            create_design
            set bd_files [get_files -quiet */${design_name}.bd]
        } else {
            set bd_file [one $bd_files "project block design $design_name"]
            set current_design [current_bd_design -quiet]
            if {$current_design ne $design_name} {
                open_bd_design $bd_file
            }
            puts \
                "Verifying existing block design $design_name without deleting it"
        }

        set bd_file [one \
            [get_files -quiet */${design_name}.bd] \
            "project block design $design_name"]
        verify_design
        return $bd_file
    }

    proc generate_wrapper {bd_file} {
        variable design_name

        # Refresh generated products in place.  Do not reset_target: it
        # removes existing generated files before replacement.
        generate_target all $bd_file
        set wrapper_files [make_wrapper -files $bd_file -top]
        set wrapper_file [file normalize \
            [one $wrapper_files "generated ${design_name}_wrapper HDL file"]]

        set source_set [get_filesets sources_1]
        set wrapper_object [::vit_project::add_or_rebind_source \
            $source_set $wrapper_file]
        set_property FILE_TYPE Verilog $wrapper_object
        set_property -dict [list \
            USED_IN_SYNTHESIS true \
            USED_IN_IMPLEMENTATION true \
            USED_IN_SIMULATION true \
        ] $wrapper_object
        return $wrapper_file
    }

    proc run {} {
        variable common_script
        variable board_repo
        variable board_part
        variable fpga_part
        variable design_name
        variable module_cell_name
        variable pl_clock_mhz
        variable control_base
        variable control_range
        variable ddr_low_base
        variable ddr_low_range
        variable ddr_high_base
        variable ddr_high_range
        variable m_axi_data_width
        variable m_axi_max_burst_length
        variable m_axi_read_outstanding
        variable m_axi_write_outstanding

        if {![file isfile $common_script]} {
            error "Missing portable Vivado helper: $common_script"
        }
        # Source the shared namespace at the Tcl global level so this file
        # behaves identically from batch mode and from a GUI Tcl console.
        uplevel #0 [list source $common_script]

        # board.repoPaths must be set before vit_project::configure opens the
        # existing project, so prerequisite setup is split around configure.
        set_param board.repoPaths [list $board_repo]
        configure_project_and_board
        check_prerequisites

        catch {close_sim}
        set bd_file [open_or_create]
        set wrapper_file [generate_wrapper $bd_file]

        # Re-run the portable project synchronization now that the wrapper
        # exists; select_hardware_top will choose vit_system_wrapper.
        ::vit_project::configure
        set_property top ${design_name}_wrapper [get_filesets sources_1]
        update_compile_order -fileset sources_1

        puts "PASS: Genesys ZU-5EV ViT block design created/verified"
        puts "  project       : [get_property DIRECTORY [current_project]]"
        puts "  board         : $board_part"
        puts "  part          : $fpga_part"
        puts "  block design  : $bd_file"
        puts "  wrapper       : $wrapper_file"
        puts "  top           : [get_property TOP [get_filesets sources_1]]"
        puts [format \
            "  control       : 0x%08X / 0x%08X" \
            $control_base $control_range]
        puts [format \
            "  DDR low       : 0x%010X / 0x%08X" \
            $ddr_low_base $ddr_low_range]
        puts [format \
            "  DDR high      : 0x%010X / 0x%08X" \
            $ddr_high_base $ddr_high_range]
        puts "  PS master     : M_AXI_HPM0_FPD"
        puts "  PL DDR master : M_AXI (${m_axi_data_width}-bit, max burst $m_axi_max_burst_length, read outstanding $m_axi_read_outstanding, write outstanding $m_axi_write_outstanding)"
        puts "  PS DDR slave  : S_AXI_HP0_FPD (${m_axi_data_width}-bit)"
        puts "  PL clock      : pl_clk0 @ $pl_clock_mhz MHz"
        puts "  IRQ           : irq_o -> pl_ps_irq0\[0\]"
        puts "  DSP cap       : [get_property \
            STEPS.SYNTH_DESIGN.ARGS.MAX_DSP [get_runs synth_1]]"
    }
}

vit_system_bd::run
