# Third-party và toolchain boundary

## Đã kèm trong payload

- Source RTL/SystemVerilog, filelists, Tcl/run scripts và testbench của project.
- Digilent Genesys ZU-5EV board files cùng license/README tương ứng trong exact
  snapshot.
- Digilent `embeddedsw` commit
  `b218adf07bb98e57d8941b16cbe0eb3dadd0b1b2`, gồm Genesys DDR source SHA-256
  `16762bf40e86d7ccb839cb1028ba8edfe5218f9fce67aeb32dd3d02b437542ba`,
  để build exact-XSA FSBL/PMUFW mà không tải source từ mạng.
- Model/input package-v3 dùng cho M8 và các manifest/hash kiểm tra.
- BIT/XSA/DCP/report do project tạo ra; đây là artifact, không phải Vivado binary.

## Không kèm

- Xilinx Vivado/Vitis/XSCT, installer, JRE/tool installation tree.
- License Xilinx, cable driver hệ thống, token, private key hoặc credential.
- Board vật lý và JTAG cable.

## Tool version mục tiêu

Flow đã đóng bằng Vivado 2023.2 build 4029153 cho part
`xczu5ev-sfvc784-1-e`. Dùng version/part khác tạo ra một build identity mới và
phải chạy lại simulation, synthesis, implementation, timing, DRC, BIT/XSA và
board validation tương ứng; không được gắn kết quả đó vào receipt M8 hiện tại.

## Redistribution

Trước khi chia sẻ công khai, chủ dự án cần kiểm tra quyền phân phối model
weights/dataset input và các third-party files. Tài liệu này không tuyên bố một
license mới và không ghi đè license gốc đi kèm từng thành phần.
