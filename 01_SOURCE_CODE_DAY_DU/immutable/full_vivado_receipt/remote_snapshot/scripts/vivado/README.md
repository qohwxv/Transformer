# Vivado production flow

Flow này cập nhật **project hiện có**
`VIT_googlebase_rtl/ViT_googlebase/ViT_googlebase.xpr`; không tạo project thứ hai,
không copy hoặc xóa `.cache`, `.gen`, `.runs`.

Từ repository root:

```bash
vivado -mode batch -source scripts/vivado/configure_project.tcl
vivado -mode batch -source scripts/vivado/create_vit_system_bd.tcl
vivado -mode batch -source scripts/vivado/run_synth_nodsp.tcl
```

`configure_project.tcl` đọc `filelists/full_axi.f`, sửa các reference source
cũ sang hierarchy mới, giữ block design `vit_system`, và cấu hình:

```text
synth_1 MAX_DSP=0
flatten_hierarchy=none
USE_DSP=NO qua no_dsp.xdc
```

`run_synth_nodsp.tcl` xuất utilization tổng và hierarchical vào
`VIT_googlebase_rtl/reports/`, sau đó dừng với lỗi nếu netlist có bất kỳ
`DSP48E1`, `DSP48E2` hoặc `DSP58`.

Có thể đặt số process bằng biến môi trường `VIT_VIVADO_JOBS`.

## Tạo Block Design cho Genesys ZU-5EV

`create_vit_system_bd.tcl` là nguồn chuẩn để tạo hoặc kiểm tra hierarchy:

```text
ZynqMP PS M_AXI_HPM0_FPD
  -> smartconnect_control
  -> vit_phase_e_axi_0/S_AXI

vit_phase_e_axi_0/M_AXI (native AXI4 128 bit, INCR burst <= 4 beat,
                         read outstanding 2, write outstanding 1)
  -> smartconnect_ddr (128 -> 128 bit)
  -> ZynqMP PS S_AXI_HP0_FPD

pl_clk0 50 MHz -> toàn bộ AXI, NPU và proc_sys_reset
irq_o -> pl_ps_irq0[0]
PS Data 0xA0000000..0xA0000FFF -> thanh ghi NPU
NPU M_AXI -> DDR low  0x0000_0000..0x7FFF_FFFF (2 GiB)
NPU M_AXI -> DDR high 0x8_0000_0000..0x8_7FFF_FFFF (2 GiB)
```

Script đăng ký board files đã lưu trong
`third_party/digilent_board_files`, chọn
`digilentinc.com:gzu_5ev:part0:1.1`, rồi dùng
`apply_board_preset` cho DDR và fixed I/O của PS.
Vùng high ở trên là phần 2 GiB có RAM vật lý của board tại đầu aperture high
của PS; script không ánh xạ toàn bộ aperture high tổng quát của IP thành RAM.

Flow là non-destructive:

- Nếu chưa có `vit_system.bd`, script tạo mới, validate, generate output
  products và tạo `vit_system_wrapper.v`.
- Nếu đã có, script kiểm tra cell, bus, clock/reset, IRQ và address map rồi
  regenerate wrapper tại chỗ.
- Nếu design hiện có khác contract, script dừng thay vì tự xóa hoặc ghi đè.
- Sau validation, script đọc lại width/burst/outstanding của NPU,
  SmartConnect và PS HP0. Chỉ khi mọi thuộc tính đúng nó mới ghi
  `VIT_googlebase_rtl/reports/vit_system_axi_contract.rpt` với marker
  `M5_AXI128_CONTRACT PASS`.

Entry point cũ ở repository root vẫn hoạt động và gọi cùng flow:

```bash
vivado -mode batch -source import_vit_system_bd.tcl
```

Script phải vượt qua `validate_bd_design` và exact native-AXI readback trong
Vivado 2023.2 trên máy đích trước synthesis; kiểm tra tĩnh không thay thế
validation của IP Integrator.
