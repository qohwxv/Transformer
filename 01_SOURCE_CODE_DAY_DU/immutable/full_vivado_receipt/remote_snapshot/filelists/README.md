# RTL filelists

Tất cả đường dẫn trong filelist là đường dẫn tương đối tính từ repository
root. Hai biên synthesis chuẩn là:

| Filelist | Top | Nội dung |
| --- | --- | --- |
| `core_no_axi.f` | `vit_phase_e_npu` | NPU core và giao tiếp memory word-level, không chứa AXI |
| `full_axi.f` | `vit_phase_e_axi_bd_wrapper` | Core + AXI-Lite + AXI memory adapter + shim cho Vivado IP Integrator |

Thứ tự source trong hai file trên luôn là:

```text
package -> leaf -> compute block -> control -> core -> AXI -> Vivado top
```

`vit_phase_e_engine_integration.f` và
`vit_phase_e_axi_wrapper_synth.f` được giữ để tương thích với flow cũ; nội
dung của chúng phải lần lượt trùng với `core_no_axi.f` và `full_axi.f`.

Các filelist `*_iverilog.f` là regression theo từng interface/testbench.
LayerNorm, Softmax và GELU có filelist OOC riêng. Reference backend dùng
`real/shortreal` chỉ nằm trong `vit_phase_e_pure_sv.f`, không được đưa vào
bất kỳ synthesis boundary nào.

Source dưới `legacy/xilinx_fp/` chỉ phục vụ thí nghiệm Xilinx Floating-Point
IP cũ. Chúng bị cấm trong hai closure production vì production yêu cầu
`DSP48 = 0`.

Kiểm tra toàn bộ path, thứ tự hierarchy và ranh giới synth/sim:

```bash
python3 tools/check_synth_filelists.py
```

Compile nhanh các top bằng Icarus:

```bash
scripts/checks/compile_rtl.sh
```
