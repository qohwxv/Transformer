# Bộ source đầy đủ M8 để mang sang máy khác

## 1. Bộ này là gì?

Đây là bản đóng gói **đúng identity M8 đã sinh ra board candidate tại 50 MHz**,
không phải bản chép tùy ý từ cây làm việc đang thay đổi. Nguồn chuẩn nằm tại:

```text
immutable/full_vivado_receipt/remote_snapshot/
```

Trong đó có RTL, filelist, testbench, Tcl/Vivado flow, board files Digilent,
các receipt simulation/OOC bắt buộc, model/input package-v3 và các report/artifact
của lần full Vivado đã hoàn tất. Thư mục checkpoint đi kèm chứa BIT/XSA, model,
input và board-tool payload đã khóa để chuẩn bị kiểm thử board:

```text
immutable/board_candidate_pause_checkpoint/
```

Hai cây `immutable/` là bằng chứng chỉ đọc. **Không chạy Vivado trực tiếp trong
đó và không sửa file.** Hãy dùng script tạo một worktree có thể ghi.

## 2. Identity đã khóa

| Hạng mục | Giá trị |
|---|---|
| Revision | M8 IP/ABI v1.13, `0x0001000D` |
| Model | Google ViT-Base/Patch16-224, package-v3 mixed FP16/FP32 |
| Board/part | Genesys ZU-5EV / `xczu5ev-sfvc784-1-e` |
| Tool flow | Vivado 2023.2 |
| Filelist SHA-256 | `88166c76fac96e7f4b59f486a3d5867a94001e6d72014ad7187b5e4de40f3524` |
| Ordered 80-source SHA-256 | `db4e84bbe7b28dcccf4d5e574027be06b5162ae9789e0f2ef0ab2dcfb0fffb7e` |
| 409-input manifest SHA-256 | `67c18532e3bb16b24ec6983f99cc54a3ffafb05fe6c02cf0385465c316b31078` |
| Full-receipt anchor | `060bea427080f8fb8cfb9321f2d95b39a9442de0256051869e33949b1468f437` |
| Pause-checkpoint anchor | `203ed8155541063a7b28b096067fd5936bfb342cb003d9c2eece49e08dda23f2` |

`MEASURED` theo report Vivado: route 50 MHz hoàn chỉnh, WNS/WHS
`+0.045/+0.010 ns`, DSP48/DSP58 bằng 0, đúng 41 RAMB36, DRC và methodology
không có violation. Exact BIT/XSA sau đó đã chạy full schedule trên board thật
và chạy retained-DDR mode 5; xem phạm vi bằng chứng tại mục 5.

## 3. Có thật sự “không cần tải gì thêm” không?

- **Có**, đối với source, testbench, project scripts, board files, model, input,
  BIT/XSA và evidence thuộc project: chúng đã nằm offline trong bộ này.
- **Không thể bundle hợp pháp Vivado/Vitis** vào ZIP. Máy đích vẫn phải có bộ
  Xilinx Vivado 2023.2 và license phù hợp. Đây là dependency có bản quyền, không
  phải source của project.
- Kiểm tra content, checksum và tạo worktree không cần mạng.
- Host mục tiêu là Linux 64-bit với GNU userland; script kiểm tra rõ các tiện
  ích `grep/cmp/sort/stat/timeout/sha256sum/tar/git` và `/usr/bin/python3` mà
  flow/verifier thực sự sử dụng.
- Chạy synthesis/place/route cần tài nguyên máy và license Vivado. Để replay
  board không cần build lại: add-on `board_runtime/` đã chứa exact FSBL/PMUFW,
  processor và runner tương ứng với BIT/XSA/model đã khóa.

Vì vậy tên chính xác của gói là **offline self-contained project payload**, không
phải “standalone executable không phụ thuộc công cụ”.

## 4. Cách dùng nhanh

Từ thư mục này:

```bash
./scripts/verify_content.sh
./scripts/check_environment.sh
./scripts/prepare_worktree.sh /duong/dan/m8_work
./scripts/prepare_board_workspace.sh /duong/dan/m8_board_work
```

Máy mới có thể dùng bootstrap tự động để tìm toolchain, dựng workspace, tạo
Python venv và sinh config XSCT (host-only, chưa chạm JTAG):

```bash
./scripts/setup_m8_laptop.sh \
  --workspace "$HOME/m8_board_work" \
  --xilinx-root /duong/dan/Xilinx \
  --cable-serial SERIAL_DOC_TU_JTAG_TARGETS
```

`SOURCE_PACKAGE_SHA256SUMS.txt` khóa exact set của riêng folder source;
`SOURCE_PACKAGE_MANIFEST.sha256` là pointer tới hash của manifest đó. Verifier
từ chối cả file thiếu, file thừa, symlink và content sai hash.

Metadata `.git` lồng của Digilent không thể được GitHub lưu như file thường và
được loại khỏi portable manifest. Commit upstream cùng 5.989 file source,
88.482.412 byte và deterministic tree hash được khóa tại
`board_support/DIGILENT_EMBEDDEDSW_PROVENANCE.txt`; verifier chấp nhận cả bản
source có `.git` lồng và bản GitHub clone không có nó.

Nếu Vivado 2023.2 đã được cài và muốn chạy lại toàn bộ XSim + OOC + synthesis +
place/route + BIT/XSA:

```bash
VIVADO_BIN=/duong/dan/Vivado/2023.2/bin/vivado \
  ./scripts/run_full_vivado.sh /duong/dan/m8_work_fresh
```

Script từ chối dùng một thư mục đích đã tồn tại để tránh trộn kết quả cũ. Nó
luôn đặt `VIT_REUSE_PROJECT=0` và chạy trên worktree, không sửa evidence.

Hướng dẫn replay board đầy đủ nằm ngay trong package tại
[`HUONG_DAN_CHAY_M8_LAPTOP_MOI.md`](HUONG_DAN_CHAY_M8_LAPTOP_MOI.md).

## 5. Trạng thái trung thực

- `PASS`: content full-Vivado receipt, source/filelist identity, BIT/XSA
  integrity, 50 MHz timing, DSP0, RAMB36 và DRC/methodology.
- `SIM-MEASURED`: các regression phase E01/E04 và compact XSim đã được receipt
  khóa trong snapshot.
- `MEASURED`: một cold physical E05 đạt DONE với 249 commands, zero hardware
  error, 22,529,112,087 cycles và top-1 879; một retained-DDR mode 5 tiếp theo
  PASS cả năm job với class `204/109/286/370/757`.
- `FAIL/PENDING`: numerical-vector gate của ảnh chuẩn còn FAIL; accuracy toàn
  dataset và power vẫn `UNKNOWN`; replay trên laptop thứ hai chưa chạy.
- M8 vẫn `DEVELOPMENT_UNSEALED_NOT_PROMOTED`: chạy được board/class index không
  đồng nghĩa đã đạt numerical sign-off hoặc accuracy.

## 6. Nén để chuyển máy

Sau khi `verify_content.sh` PASS, nên nén toàn bộ thư mục `hoanthanh_0908/`
bằng **TAR** (`tar.gz` hoặc `tar.zst`) để giữ executable bit và chế độ chỉ đọc
của evidence. ZIP phổ thông có thể làm mất mode; nếu vẫn dùng ZIP, hãy gọi
script bằng `bash scripts/ten_script.sh` và phục hồi mode trước khi kiểm tra.
Không cần giải nén các archive bất biến trước khi nén. Ở máy đích, kiểm tra
checksum trước rồi mới tạo worktree.

Không đưa license Xilinx, token, mật khẩu hoặc file cấu hình cá nhân vào archive.
