# Checkpoint RTL ViT NPU — 2026-07-30

> **HISTORICAL INHERITED CHECKPOINT.** Mọi identity, PASS/PENDING và geometry
> trong file này chỉ mô tả snapshot 2026-07-30, không phải trạng thái M4-R8.
> Contract hiện hành của child là `../M4_R8_REUSE_CONTRACT.md`; trạng thái build
> hiện hành nằm tại `../../README_SERVER.md`. Không dùng checkpoint này để
> nghiệm thu simulation, Vivado hay board của R8.

Checkpoint này chốt bằng chứng simulation hiện hành sau khi full regression,
E01, E04 và hai bounded probe E02/E03 được chạy lại trên cùng design và
verification bundle. Tài liệu ngày 29/07 chỉ còn giá trị lịch sử.

## 1. Kết luận ngắn

```text
production hierarchy leaf -> block -> control -> core -> AXI -> top  PASS static/compile/lint
full regression, 27 RUN / 98 PASS marker                            pass_authoritative
compact E05 logical-memory, đủ 249 command / 12 layer               PASS
compact E05 qua AXI, đủ 249 command / 12 layer                      PASS
E01 real AXI, full patch embedding + CLS + position                 pass_authoritative
E04 real AXI, final LN + classifier + Argmax + Softmax              pass_authoritative
E02 real logical, encoder layer 0 bounded 100k-cycle probe          probe_only_authoritative
E03 real logical, encoder layer 1 bounded 100k-cycle probe          probe_only_authoritative
full real 12-layer E05 production RTL                               PENDING
Vivado synthesis / implementation / netlist / timing               NOT RUN
physical DSP primitive count                                       NOT PROVEN
```

Behavioral ModelSim full model vẫn là golden tham chiếu và không thuộc
synthesis closure. Production RTL đã có bằng chứng end-to-end theo từng phase
và compact full-sequence, nhưng chưa có một run production duy nhất đưa input
thật qua toàn bộ 12 encoder layer đến class output.

## 2. Identity được khóa

Mọi log authority trong checkpoint này phải khớp hai aggregate hash sau:

```text
DESIGN_SHA256       d7b4a5612617b637815c448929deea15a752fa3aaf9446984f73c7b8721c6b45
design file count   79
VERIFICATION_SHA256 e1ce3d6991efc819e3db12b644722bf4dfa8082dc95753a00d29bd5b437c5552
verification files  206
```

Design identity bao phủ RTL và filelist. Verification identity bao phủ RTL,
filelist, simulation source/runner, check scripts, evidence generator và các
trusted model-package/baseline manifest. Receipt được tạo sau khi process kết
thúc, khóa run-id, command, exit status, asset set và hai identity trên.

Nguồn machine-readable:

- [`vit_rtl_evidence_manifest.json`](../../build/evidence/vit_rtl_evidence_manifest.json)
- [`vit_rtl_evidence_manifest.md`](../../build/evidence/vit_rtl_evidence_manifest.md)

Ý nghĩa trạng thái:

- `pass_authoritative`: run tới terminal PASS, receipt và mọi binding hợp lệ;
- `probe_only_authoritative`: bounded probe hợp lệ trong đúng số cycle đã
  khai báo, không chứng minh terminal numerical result;
- `incomplete_non_authoritative`: không được dùng làm bằng chứng PASS.

## 3. Evidence hiện hành

| Evidence | Run ID | Trạng thái | Kết quả chính |
| --- | --- | --- | --- |
| Full regression | `fr-final-20260730-a4` | `pass_authoritative` | 27 RUN, 98 PASS-marker |
| E01 real AXI | `e01-final-20260730-a2` | `pass_authoritative` | 75 checks, 658.889.397 cycle, 151.296 word |
| E04 real AXI | `e04-final-20260730-a2` | `pass_authoritative` | 84 checks, 16.401.733 cycle, class 879 |
| E02 layer 0 | `e02-probe100k-final-20260730-a2` | `probe_only_authoritative` | 100.000 cycle, 13.570 request/response |
| E03 layer 1 | `e03-l01-probe100k-final-20260730-a2` | `probe_only_authoritative` | 100.000 cycle, 158 checks |

### 3.1 Full regression A4

Log authority:
[`full_regression_fr-final-20260730-a4.log`](../../build/test_logs/full_regression_fr-final-20260730-a4.log).

```text
RUN groups       27
PASS-marker      98
log SHA256       745b2b5d95f3ea94268374b7bef590d739fd563180fe0cf1267e57bb6c446075
```

Regression bao gồm compile/lint/static/no-DSP policy guards, leaf/block/core,
memory/AXI protocol, sequencer default ViT-base và compact E05. Một số marker
đáng chú ý:

```text
4-state protocol: checks=5809 failures=0 cycles=488 aborted=1
restart requests/responses=13/13 reads=10 writes=3 stalls=14
E05 sequencer: commands=249 checkpoints=249
E05 compact logical: checks=17484 cycles=704045 reads=57819 writes=10646
E05 compact AXI: checks=357 cycles=725741 reads=57819 writes=10646
```

Compact E05 đi qua đủ 12 layer và 249 command trong một job, nhưng dùng shape
nhỏ và golden có chủ ý đơn giản. Nó chứng minh composition/FSM/routing, không
thay thế full model-real E05.

### 3.2 E01 real AXI A2

Log authority:
[`vit_axi_e01_real_rtl_full_e01-final-20260730-a2.log`](../../build/test_logs/vit_axi_e01_real_rtl_full_e01-final-20260730-a2.log).

```text
checks=75 cycles=658889397 commands=4
reads=58407936 writes=453120 invalid=0
MODEL reads=57955584 INPUT reads=150528 SCRATCH reads=301824
numeric words=151296 tolerance_failures=0 tolerance=5e-4
max_abs=1.788139343e-06 mean_abs=1.016216337e-07
hidden_b_modified=0
```

Test đi qua AXI-Lite BFM, `vit_phase_e_axi_bd_wrapper`, production
sequencer/NPU/engine, M_AXI adapter và DDR model. Nó thực thi patch embedding,
chèn CLS và position add bằng input/weight/checkpoint thật.

### 3.3 E04 real AXI A2

Log authority:
[`vit_axi_e04_real_rtl_full_e04-final-20260730-a2.log`](../../build/test_logs/vit_axi_e04_real_rtl_full_e04-final-20260730-a2.log).

```text
checks=84 cycles=16401733 commands=5
reads=1531016 writes=154064
MODEL reads=1071592 SCRATCH reads=459424
class=879 RTL logit=0x414887b9 golden=0x414887b7 raw_delta=2
final-LN max_abs=5.722045898e-06
logits max_abs=1.907348633e-06
probabilities max_abs=3.576278687e-07
```

Test thực thi final LayerNorm, CLS layout, classifier GEMM, Argmax và final
Softmax với dimension production `197×768`, classifier `768×1000`.

### 3.4 E02 encoder layer 0

Authority evidence hiện hành là bounded probe:
[`vit_e02_layer0_real_logical_rtl_probe_e02-probe100k-final-20260730-a2.log`](../../build/test_logs/vit_e02_layer0_real_logical_rtl_probe_e02-probe100k-final-20260730-a2.log).

```text
cycles=100000 commands=1 checkpoints=0
reads=11330 writes=2240
parameter_reads=4481 scratch_reads=6849
requests=13570 responses=13570 outstanding=0
stalls=16 forced_stalls=16 invalid=0 failures=0
```

Probe nạp embedding checkpoint và đủ 16 tensor encoder layer 0, kiểm
provenance, address traffic, reset/stall và không có invalid access. Nó chưa
tới command 20 hoặc comparator 151.296 word, vì vậy trạng thái chính xác là
`probe_only_authoritative`.

Một long run riêng đã hoàn tất:

```text
cycles=7636573461 commands=20
reads=737995740 writes=4876932 invalid=0
numeric words=151296 tolerance_failures=0
max_abs=4.529953003e-06 mean_abs=3.003772886e-07
```

Log:
[`vit_e02_layer0_real_logical_rtl_e2e_restart_o3.log`](../../build/test_logs/vit_e02_layer0_real_logical_rtl_e2e_restart_o3.log).
Run này dùng runner cũ và không có receipt/provenance binding với verification
bundle hiện hành. Nó chỉ là bằng chứng chẩn đoán bổ sung
**non-authoritative**, không được nâng thành sign-off E02.

### 3.5 E03 encoder layer 1

Authority evidence hiện hành:
[`vit_e03_layer01_real_logical_rtl_probe_e03-l01-probe100k-final-20260730-a2.log`](../../build/test_logs/vit_e03_layer01_real_logical_rtl_probe_e03-l01-probe100k-final-20260730-a2.log).

```text
layer=1 cycles=100000 commands=1 checkpoints=0
layer_requests=1 parameter_requests=1
reads=11331 writes=2240
parameter_reads=4482 scratch_reads=6849
requests=13571 responses=13570 outstanding=1
invalid=0 backpressure_cycles=30 checks=158 failures=0
```

Probe dùng checkpoint output layer 0 làm input, nạp đúng 16 tensor layer 1 và
đi qua production NPU/logical-memory. Outstanding cuối bằng 1 là transaction
đang hợp lệ tại biên bounded stop, không phải mất response. Probe chưa tới
full comparator. Layer 1 numerical full run và layer 2..11 vẫn pending.

## 4. Trạng thái kiến trúc

Production source vẫn được tổ chức:

```text
package
  -> leaf arithmetic/common
  -> GEMM/vector/layout/LayerNorm/Softmax/GELU/Argmax block
  -> command/dispatch/memory frontend
  -> vit_phase_e_npu
  -> AXI-Lite control + M_AXI memory adapter
  -> vit_phase_e_axi_bd_wrapper
```

`filelists/core_no_axi.f` giữ closure không AXI;
`filelists/full_axi.f` giữ closure đầy đủ AXI/top. Behavioral
`sim/reference/` và `sim/full/` nằm ngoài synthesis closure. Tài liệu module,
memory map, stride và toàn bộ FSM nằm tại
[`VIT_NPU_TOP_DOWN_REFERENCE.md`](VIT_NPU_TOP_DOWN_REFERENCE.md).

## 5. No-DSP: phạm vi đã và chưa chứng minh

RTL production không instantiate Xilinx Floating-Point IP hoặc primitive
DSP48/DSP58. Multiplier FP32 có `use_dsp="no"`; flow Tcl đặt
`MAX_DSP=0` và `USE_DSP=NO`; static/structural guards hiện PASS. Đây là
contract ở mức source và flow.

Checkpoint này **không có**:

- Vivado synthesis;
- Vivado implementation/place-and-route;
- synthesized hoặc implemented netlist;
- utilization/timing/power report;
- phép đếm primitive DSP48 vật lý.

Vì vậy chưa được tuyên bố physical `DSP=0`. Chỉ khi Vivado chạy trên đúng
`xczu5ev-sfvc784-1-e` và post-synthesis/post-route check xác nhận không có
`DSP48E1`, `DSP48E2` hoặc `DSP58` mới được chốt DSP vật lý bằng 0.

## 6. Những việc còn lại trước board

1. Hoàn tất E03 numerical comparator cho layer 1, sau đó chạy layer 2..11 với
   input checkpoint của layer trước.
2. Chạy một production full real E05 liên tục từ patch input qua đủ 12
   encoder layer đến classifier. Behavioral full model và compact E05 không
   thay thế test này.
3. Tạo/validate `vit_system.bd`: PS `M_AXI_HPM0_FPD` điều khiển AXI-Lite,
   NPU M_AXI nối DDR qua `S_AXI_HP0_FPD`, clock/reset/IRQ và address map.
4. Chạy Vivado synthesis OOC trước, kiểm utilization + primitive DSP; chỉ sau
   đó chạy implementation và timing closure.
5. Trên board, đóng gói model/input vào DDR, viết driver PS để cấu hình base,
   limits, layer table, start/status/IRQ và đọc class/logit.

AXI RTL đã được test bằng BFM/DDR model ở E01, E04 và compact E05. Điều đó
giảm rủi ro protocol, nhưng không đồng nghĩa Block Design PS/DDR vật lý đã
được tạo hoặc xác nhận.

## 7. Lệnh kiểm tra evidence nhẹ

Các lệnh sau chỉ đọc/validate log và manifest, không gọi Vivado:

```bash
VIT_EVIDENCE_E02_LOG=\
build/test_logs/vit_e02_layer0_real_logical_rtl_probe_e02-probe100k-final-20260730-a2.log \
  scripts/checks/check_evidence_manifest.sh

jq -r '.design_snapshot.aggregate_sha256,
       .verification_bundle.aggregate_sha256,
       (.evidence | to_entries[] | [.key,.value.status] | @tsv)' \
  build/evidence/vit_rtl_evidence_manifest.json
```

Nếu bất kỳ RTL/filelist/test/runner/check script nào đổi, hai identity có thể
đổi và log cũ không còn authority cho source mới. Khi đó phải tạo run-id mới,
chạy lại test tương ứng và tạo post-exit receipt mới; không sửa log hoặc
receipt cũ.

## 8. Điều kiện chốt tiếp theo

Mốc kế tiếp chỉ nên gọi là “full production model-real RTL PASS” khi một run
E05 duy nhất đạt terminal, đủ 249 command/249 checkpoint, không invalid
access, và class/logit hoặc các checkpoint chính được so với golden thật.
Mốc “ready for FPGA sign-off” còn yêu cầu Vivado synthesis/implementation,
timing closure và physical DSP count bằng 0.
