# Standalone NPU+AXI synthesis clock.
#
# This constraint is only for the RTL closure whose top is
# vit_phase_e_axi_bd_wrapper. The board/PS clock remains owned by vit_system.bd.

create_clock -name aclk -period 10.000 [get_ports aclk]
set_clock_uncertainty 0.200 [get_clocks aclk]
