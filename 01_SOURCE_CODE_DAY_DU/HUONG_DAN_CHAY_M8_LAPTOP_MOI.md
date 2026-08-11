# Hướng dẫn chạy M8 trên laptop mới sau khi Git clone

Tài liệu này dành cho một máy Linux 64-bit mới có:

- Vivado/Vitis/XSCT 2023.2 đầy đủ;
- board Digilent Genesys ZU-5EV và cáp JTAG;
- thư mục `01_SOURCE_CODE_DAY_DU` lấy từ GitHub;
- dataset ảnh được tải riêng nếu muốn dùng `--start-index`/`--indices`.

Không cần chạy lại synthesis/place/route để suy luận. Gói đã chứa đúng BIT,
XSA, model mixed FP16/FP32, table, FSBL và PMUFW của lần board PASS. Toàn bộ
quy trình dưới đây là volatile JTAG boot, không ghi QSPI/SD/flash.

Luồng khuyến nghị là **replay artifact**, không phải build lại từ pure RTL.
BIT mới là cấu hình PL; XSA mô tả hardware để build/đối chiếu software; để chạy
end-to-end còn phải có đúng FSBL, PMUFW, model/table, processor và runner. Gói
này đã bổ sung đủ các thành phần đó và khóa chúng bằng SHA-256. Chỉ synthesize/
implement lại khi đã sửa RTL/IP/constraint, artifact bị thiếu/sai hash, hoặc
chủ động muốn tái chứng minh build trên máy mới.

## 0. Phần mềm cần có trước

Máy đích cần Linux 64-bit, Vivado **và** Vitis/XSCT 2023.2, Git LFS và Python
3 có module `venv`. Ví dụ trên Ubuntu/Debian:

```bash
sudo apt update
sudo apt install git git-lfs python3 python3-venv python3-pip
```

Không cần cài CUDA/GPU. PyTorch/Transformers chỉ preprocess ảnh trên CPU và sẽ
được cài vào venv riêng bởi bootstrap ở mục 3A hoặc bằng tay ở mục 4.

## 1. Clone và lấy đủ Git LFS

Archive checkpoint lớn hơn giới hạn file GitHub thông thường, vì vậy máy mới
cần Git LFS nếu repository sử dụng LFS:

```bash
git lfs install
git clone https://github.com/qohwxv/Transformer.git
cd Transformer/01_SOURCE_CODE_DAY_DU
git lfs pull
```

Nếu `01_SOURCE_CODE_DAY_DU` là root của repository thì chỉ cần `cd` vào root.
Một file LFS chưa tải thật thường chỉ vài trăm byte và chứa dòng
`version https://git-lfs.github.com/spec/v1`; trường hợp đó không được chạy
tiếp.

## 2. Kiểm tra package trước khi dùng board

Đặt đúng đường dẫn Vivado 2023.2 của máy:

```bash
export PACKAGE_ROOT="$PWD"
export VIVADO_BIN=/duong/dan/Vivado/2023.2/bin/vivado
export HW_SERVER=/duong/dan/Vivado/2023.2/bin/hw_server
export XSCT=/duong/dan/Vitis/2023.2/bin/xsct

test -x "$VIVADO_BIN"
test -x "$HW_SERVER"
test -x "$XSCT"

./scripts/verify_content.sh
VIVADO_BIN="$VIVADO_BIN" ./scripts/check_environment.sh
```

Phải có marker `M8_OFFLINE_SOURCE_CONTENT_PASS` và
`M8_VIVADO_2023_2_TOOLCHAIN_READY_PASS`. Nếu checksum fail thì dừng; không sửa
hash hoặc bỏ qua kiểm tra.

## 3. Tạo board workspace có thể ghi

Không chạy trực tiếp trong `immutable/`. Tạo một thư mục mới chưa tồn tại:

```bash
export BOARD_WORK="$HOME/m8_board_work_20260811"
./scripts/prepare_board_workspace.sh "$BOARD_WORK"
cd "$BOARD_WORK"
```

Script sẽ dựng layout cần thiết và tự giải nén thêm:

- dataset runner mode 1/2/5/10/1000;
- processor config offline;
- ảnh umbrella chuẩn `inputs/test1.png`;
- exact FSBL/PMUFW cùng boot receipt đã chạy board;
- ground-truth/meta ILSVRC nhỏ, không bao gồm 50.000 ảnh.

Marker cần có:

```text
M8_BOARD_WORKSPACE_PREPARE_PASS ... jtag=NOT_TOUCHED
```

### 3A. Cách tự động khuyến nghị

Thay cho việc làm riêng mục 2–4 và tự viết config, chạy bootstrap ngay trong
`01_SOURCE_CODE_DAY_DU`. `--xilinx-root` là thư mục cha chứa hai thư mục
`Vivado/2023.2` và `Vitis/2023.2`; nếu executable đã có trong `PATH` thì bỏ
tham số này:

```bash
export BOARD_WORK="$HOME/m8_board_work_20260811"

./scripts/setup_m8_laptop.sh \
  --workspace "$BOARD_WORK" \
  --xilinx-root /duong/dan/Xilinx
```

Lần đầu có thể chưa biết serial. Script vẫn verify package, dựng workspace,
tạo `.venv_m8`, cài Python dependency và in lệnh mở `hw_server`/XSCT để đọc
serial; marker là `config=PENDING_CABLE_SERIAL`. Sau khi đọc được serial:

```bash
./scripts/setup_m8_laptop.sh \
  --workspace "$BOARD_WORK" \
  --xilinx-root /duong/dan/Xilinx \
  --cable-serial SERIAL_DOC_TU_JTAG_TARGETS
```

Lần chạy thứ hai tái sử dụng workspace/venv, sinh config và chạy host preflight.
Phải kết thúc bằng `M8_LAPTOP_CONFIG_PASS ... jtag=NOT_TOUCHED`. Script tạo
`$BOARD_WORK/m8_env.sh`; ở mỗi terminal chỉ cần `source` file này. Nếu máy
không có mạng, thêm `--skip-python-install` và cài wheel offline như mục 4.

Bootstrap không tự program board và không giữ `hw_server` chạy nền. Việc này
cố ý tách thành Terminal A/B để không có hai tiến trình cùng giành JTAG.

## 4. Cài Python để preprocess ảnh

Vivado/Vitis không cung cấp PyTorch/Transformers cho runner. Tạo môi trường
Python riêng; preprocessing chỉ dùng CPU:

```bash
python3 -m venv .venv_m8
.venv_m8/bin/python -m pip install --upgrade pip
.venv_m8/bin/python -m pip install \
  -r "$PACKAGE_ROOT/board_runtime/requirements-board.txt"

export VIT_PYTHON="$PWD/.venv_m8/bin/python"
"$VIT_PYTHON" -c 'import numpy, PIL, torch, transformers; print("M8_PYTHON_READY_PASS")'
```

Các version trong requirements là version đã dùng cho regression bit-exact.
Nếu laptop không có mạng, tải wheel trên máy khác rồi cài bằng
`pip install --no-index --find-links /duong/dan/wheels -r ...`.

## 5. Mở hw_server và đọc đúng JTAG serial

Terminal A giữ chạy suốt phiên:

```bash
"$HW_SERVER" -s tcp::3121
```

Terminal B, trong `BOARD_WORK`, mở XSCT:

```bash
"$XSCT"
```

Tại dấu nhắc XSCT:

```tcl
connect -url tcp:127.0.0.1:3121
jtag targets
disconnect
exit
```

Chép chính xác `jtag_cable_serial` của Genesys ZU-5EV. Không đoán và không
dùng serial của board khác. Ví dụ dưới đây dùng biến, không phải giá trị mẫu:

```bash
export CABLE_SERIAL=CHUOI_HEX_DOC_TU_JTAG_TARGETS
```

Chỉ `hw_server` được chạy song song; không mở hai runner/XSCT cùng điều khiển
board.

Vivado Hardware Manager GUI không bắt buộc cho luồng này. Nếu mở GUI chỉ dùng
để quan sát cable/device; không đồng thời bấm Program Device khi runner XSCT
đang chạy.

## 6. Sinh config đúng đường dẫn laptop

Exact boot runtime đã nằm tại đường dẫn mặc định trong workspace. Tạo config:

```bash
"$VIT_PYTHON" tools/board/m8/dataset/configure_portable.py \
  --xsct "$XSCT" \
  --cable-serial "$CABLE_SERIAL"
```

Lệnh này chỉ kiểm tra file/hash và ghi
`tools/board/m8/dataset/m8_session_config.json`; chưa chạm JTAG. Marker:

```text
M8_PORTABLE_CONFIG_PASS
```

Sau đó chạy preflight host-only:

```bash
VIT_PYTHON="$VIT_PYTHON" \
  tools/board/m8/dataset/setup_m8_session.sh --preflight-only
```

Phải thấy `M8_DATASET_SESSION_PREFLIGHT_PASS ... jtag=NOT_TOUCHED`.

## 7. Cold setup board — một lần cho mỗi phiên nguồn/DDR

Đảm bảo Terminal A vẫn chạy `hw_server`, rồi tại Terminal B:

```bash
cd "$BOARD_WORK"
VIT_PYTHON="$VIT_PYTHON" tools/board/m8/dataset/setup_m8_session.sh
```

Lệnh này thực hiện system reset, PMUFW, BIT, FSBL, DDR smoke, nạp model
173.685.760 byte một lần, nạp table và cấu hình M8. Nó chưa START inference.
Cold setup thành công kết thúc bằng:

```text
M8_DATASET_SESSION_READY model_load_count=1 inference_count=0
M8_DATASET_COLD_INIT_PASS ...
M8_DATASET_SESSION_SETUP_PASS ...
```

Giữ board có nguồn và không system reset để tái sử dụng model trong DDR.

## 8. Chạy ảnh đầu tiên

Chạy ảnh umbrella chuẩn đi kèm để kiểm tra toàn tuyến preprocess/JTAG/M8:

```bash
VIT_PYTHON="$VIT_PYTHON" \
  tools/board/m8/dataset/run_1.sh --images inputs/test1.png
```

Lần đã đo trên board trả `class_index=879`. Mỗi ảnh cần khoảng 7 phút 31 giây
inference ở 50 MHz, chưa tính truyền input/xóa scratch.

Ảnh bất kỳ nằm ở đâu trên máy cũng được:

```bash
VIT_PYTHON="$VIT_PYTHON" \
  tools/board/m8/dataset/run_1.sh \
  --images /duong/dan/anh_cua_ban.jpg
```

## 9. Dataset tải riêng và mode 2/5/10/1000

Dataset không nằm trong GitHub package. Nếu dùng ILSVRC2012 validation, đặt
50.000 ảnh vào layout mặc định:

```text
$BOARD_WORK/datasets/ILSVRC2012_img_val/
  ILSVRC2012_val_00000001.JPEG
  ...
  ILSVRC2012_val_00050000.JPEG
```

Kiểm tra:

```bash
find datasets/ILSVRC2012_img_val -maxdepth 1 \
  -type f -name 'ILSVRC2012_val_*.JPEG' | wc -l
```

Sau cold setup, không nạp weight lại. Ví dụ:

```bash
# Hai ảnh đầu tiên
VIT_PYTHON="$VIT_PYTHON" tools/board/m8/dataset/run_2.sh --start-index 1

# Năm ảnh số 10..14
VIT_PYTHON="$VIT_PYTHON" tools/board/m8/dataset/run_5.sh --start-index 10

# Năm ảnh rời rạc
VIT_PYTHON="$VIT_PYTHON" tools/board/m8/dataset/run_5.sh \
  --indices 1 17 105 900 50000

# Mười ảnh liên tiếp từ ảnh 101
VIT_PYTHON="$VIT_PYTHON" tools/board/m8/dataset/run_10.sh --start-index 101

# Một nghìn ảnh liên tiếp từ ảnh 1
VIT_PYTHON="$VIT_PYTHON" tools/board/m8/dataset/run_1000.sh --start-index 1
```

Có thể xem kế hoạch mà không chạm JTAG:

```bash
VIT_PYTHON="$VIT_PYTHON" \
  tools/board/m8/dataset/run_5.sh --start-index 10 --plan-only

VIT_PYTHON="$VIT_PYTHON" \
  tools/board/m8/dataset/run_1000.sh --start-index 1 --plan-only
```

Mode 1000 cần khoảng `450,658 s/ảnh × 1000 = 450 658 s`, tức tối thiểu khoảng
`5,22 ngày` inference liên tục theo lần board đã đo, chưa tính DOW input, xóa
scratch, capture output và cold setup. Nên chạy trong `tmux`, tắt automatic
sleep/suspend và giữ board có nguồn ổn định. Runner checkpoint atomically sau
mỗi ảnh, nhưng bản hiện tại chưa tự resume một campaign bị gián đoạn.

Ví dụ mở terminal bền vững trước khi chạy:

```bash
tmux new -s m8_1000
source "$BOARD_WORK/m8_env.sh"
cd "$BOARD_WORK"
tools/board/m8/dataset/run_1000.sh --start-index 1
```

Detach bằng `Ctrl-b d`, quay lại bằng `tmux attach -t m8_1000`.

## 10. Đọc kết quả

Terminal in dòng chính cho mỗi ảnh:

```text
M8_DATASET_IMAGE_START ordinal=1/5 image=...
INFERENCE_START_UTC=...
INFERENCE_DONE_UTC=... elapsed_ms=...
RESULT class_index=... class_logit=... class_probability=...
M8_DATASET_IMAGE_PASS ordinal=1/5 class_index=...
```

Kết thúc batch:

```text
M8_DATASET_MODE_PASS mode=5 completed=5 run=...
```

Kết quả tổng hợp nằm tại:

```text
build/m8_dataset_runs/<UTC>-m8-modeN/results.csv
```

Runner hiện in class index 0..999, chưa in tên class. Exact mapping
`ILSVRC ID -> WNID -> model class index` chưa được tích hợp, nên không dùng
`ground_truth - 1` và chưa tuyên bố dataset accuracy.

## 11. Khi nào phải cold setup lại?

Không cần setup lại giữa mode 1/2/5/10/1000 nếu board vẫn có nguồn và phiên DDR còn
hợp lệ. Phải chạy lại setup sau:

- power-cycle hoặc mất điện;
- system/PS/DDR reset;
- đổi BIT/XSA/model;
- session marker/model sentinel fail;
- trạng thái DDR không chắc chắn.

## 12. Lỗi thường gặp

- `verify_content.sh` fail ngay sau clone: thường do chưa `git lfs pull`.
- `XSCT is not executable`: đường dẫn `XSCT` sai; dùng Vitis 2023.2, không phải
  chỉ đường dẫn Vivado.
- `Cable serial ... mismatch`: đọc lại `jtag targets`, không sửa validator.
- Không kết nối `tcp:127.0.0.1:3121`: kiểm tra Terminal A `hw_server`.
- Python import fail: kích hoạt đúng `.venv_m8`/`VIT_PYTHON` và cài requirements.
- Runner sau power-cycle báo session/model marker sai: chạy cold setup lại.
- Job đầu tiên chậm trước inference: Python đang load processor/PyTorch và
  preprocess ảnh đầu; đây không phải thời gian inference của FPGA.

Nếu một ảnh fail, giữ nguyên thư mục evidence; không chạy hai runner song song.

## 13. Phạm vi kết quả hiện tại

`MEASURED`: exact M8 đã hoàn tất cold physical full schedule và retained-DDR
mode 5 với 249 command/job, zero hardware error. Tuy nhiên full numerical-vector
gate của ảnh chuẩn còn FAIL tolerance và M8 chưa được promote/sign-off. Chạy
được inference/class index không đồng nghĩa đã chứng minh accuracy toàn dataset.

## Phụ lục — rebuild FSBL/PMUFW nếu không dùng boot bundle

Thông thường không cần bước này. Nếu muốn tự build lại bằng exact XSA:

```bash
flow="$BOARD_WORK/vivado_server_307_perf_v1_m8_nongemm_nodsp_2023_2/reports/m8/server_runs/20260809T032300Z-m8-board-candidate-67c18532-full-vivado-pass-receipt/remote_snapshot"

"$XSCT" tools/board/m8/build_m8_genesys_fsbl.tcl \
  "$BOARD_WORK" \
  "$flow/VIT_googlebase_rtl/artifacts/vit_system_wrapper.xsa" \
  47e764324d9eaedcc343b3cdf66190dbb90635cf8e51b4f6e65b4746c43680ee \
  "$BOARD_WORK/build/board_boot/m8_rebuilt/workspace" \
  "$BOARD_WORK/build/board_boot/m8_rebuilt/m8_boot_receipt.txt"
```

Sau đó chạy lại `configure_portable.py` với `--boot-receipt` trỏ đến receipt
mới và `--force`. Rebuild boot software vẫn chưa chạm JTAG.

## Phụ lục — khi nào mới chạy lại synth/implement?

Không chạy lại chỉ vì chuyển sang laptop khác. Exact BIT/XSA không phụ thuộc
đường dẫn cài đặt của máy đích. Nếu thực sự cần rebuild toàn hardware:

```bash
cd "$PACKAGE_ROOT"
VIVADO_BIN="$VIVADO_BIN" \
  ./scripts/run_full_vivado.sh "$HOME/m8_full_rebuild_fresh"
```

Đích phải là thư mục chưa tồn tại. Sau rebuild phải dùng BIT/XSA mới như một
identity mới, build lại FSBL/PMUFW theo XSA đó và chạy lại toàn bộ checksum,
simulation, timing/DRC và board validation. Không trộn BIT mới với boot receipt
cũ rồi gọi đó là exact M8 đã đo.
