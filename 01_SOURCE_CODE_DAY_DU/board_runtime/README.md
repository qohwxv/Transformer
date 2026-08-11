# M8 portable board runtime add-on

Thư mục này bổ sung runtime đã được dùng cho cold setup và batch inference.
Mode 1/2/5/10 đã có physical scope; mode 1000 là host-verified extension sau
đó và chưa được chạy trọn vẹn trên board.

- `M8_DATASET_RUNTIME.tar.gz`: dataset runner mode 1/2/5/10/1000, processor offline, ảnh umbrella
  chuẩn và ground-truth ILSVRC (không chứa 50.000 ảnh validation).
- `M8_BOOT_RUNTIME.tar.gz`: exact FSBL/PMUFW và boot receipt đã dùng trong lần
  cold physical PASS ngày 2026-08-10.
- `requirements-board.txt`: dependency Python cho preprocess ảnh tùy ý.
- `RUNTIME_ARTIFACTS.sha256`: hash hai archive runtime.

Hai archive được giải nén tự động bởi `scripts/prepare_board_workspace.sh`.
Chúng không sửa hoặc thay thế bất kỳ file nào trong `immutable/`.

`scripts/setup_m8_laptop.sh` là bootstrap host-only: tự dò executable 2023.2,
dựng board workspace, tạo Python venv, cài requirements và sinh config XSCT.
Script không tự mở JTAG hoặc program board.

Trạng thái bằng chứng:

- Exact BIT/XSA/model/boot identity đã chạy vật lý trên Genesys ZU-5EV.
- Retained-DDR mode 5 cho ILSVRC ảnh 10..14 PASS năm job, 249 command/job,
  zero hardware error.
- M8 vẫn chưa đạt numerical-vector sign-off và chưa có dataset accuracy.

Xem `HUONG_DAN_CHAY_M8_LAPTOP_MOI.md` ở thư mục cha.
