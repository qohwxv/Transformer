# Digilent Genesys ZU-5EV board files

Nguồn chính thức:
`https://github.com/Digilent/vivado-boards`

- Upstream commit: `36f34ab687b7fa9c778b779d027f3bce63b3ace9`
- Upstream path: `new/board_files/genesys-zu-5ev`
- Ngày vendor vào project: 2026-07-23
- Board revision: C.0
- Board file version: 1.1
- FPGA part: `xczu5ev-sfvc784-1-e`
- License: MIT; xem `LICENSE_DIGILENT_VIVADO_BOARDS.txt`

Board files được giữ project-local. Không cần ghi vào installation directory
của Vivado. Tcl script phải đặt:

```tcl
set_param board.repoPaths [list <project-root>/third_party/digilent_board_files]
```

Kiểm tra bằng:

```bash
cd <vivado_server_307>
source /path/to/Xilinx/Vivado/2022.2/settings64.sh
vivado -mode batch -source scripts/server/00_preflight.tcl
```
