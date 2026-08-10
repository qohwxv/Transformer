<!-- Tài liệu diễn giải; sơ đồ duy nhất nằm trong ARCHITECTURE.md. -->

# Kiến trúc RTL ViT NPU

> **R8 OVERLAY / HISTORICAL EVIDENCE WARNING.** Phần mô tả hierarchy vẫn là
> tài liệu đọc kiến trúc, nhưng bảng evidence, identity và trạng thái build
> bên dưới là snapshot 2026-07-30, không phải nghiệm thu M4-R8. Geometry hiện
> hành là `ARRAY_ROWS=8`, `ARRAY_COLS=2`, `PE_LANES=16`, IP version
> `0x00010005`; contract/current status nằm tại
> `../M4_R8_REUSE_CONTRACT.md` và `../../README_SERVER.md`. Tài liệu đi theo
> hướng **board → AXI → NPU → engine → compute block → arithmetic leaf**;
> thứ tự compile vẫn là **leaf → block → core → AXI → top**.

## 1. Phạm vi và trạng thái hiện tại

Mục tiêu cuối là chạy `google/vit-base-patch16-224` trên Genesys ZU-5EV. RTL
hiện áp contract nguồn **không suy diễn DSP** cho toàn bộ arithmetic; điều
kiện nghiệm thu cuối vẫn là primitive DSP bằng 0 trong netlist Vivado của
đúng revision.

Phải phân biệt rõ các mức bằng chứng:

| Mức | Trạng thái hiện tại | Điều đã được chứng minh |
| --- | --- | --- |
| Behavioral full model | Đã chạy đúng, dùng làm golden | Chuỗi ViT và model/input thật cho kết quả tham chiếu |
| Production RTL compact, logical memory | PASS | Đủ 249 command E05 đi qua sequencer và bảy compute block |
| Production RTL compact, AXI memory model | PASS | Cùng E05 đi qua AXI-Lite, wrapper, M_AXI và DDR model |
| Production RTL full-dimension/model-real E04 qua AXI | `pass_authoritative` | 84 checks, 16.401.733 cycle, 5 command, `1.531.016R/154.064W`, class 879; toàn bộ Final LN/logit/probability nằm trong tolerance |
| Production RTL E01 model-real qua AXI | `pass_authoritative` | 75 checks, 658.889.397 cycle, đủ 151.296 embedding word, traffic `58.407.936R/453.120W` exact, `invalid=0`, max abs error `1.788139343e-06` |
| Production RTL E02 layer 0 model-real, logical memory | `probe_only_authoritative` | Probe 100.000 cycle: 1 command, `11.330R/2.240W`, 16 forced stall, `invalid=0`, 0 failure; chưa tới comparator |
| Production RTL E02 full diagnostic cũ | Hoàn tất nhưng chỉ supplemental | 241 checks, 7.636.573.461 cycle, đủ 20 command và numerical comparator; log không có receipt/provenance của revision cuối nên không được nâng thành authoritative evidence |
| Production RTL E03 layer 1 model-real | `probe_only_authoritative` | Probe 100.000 cycle: 158 checks, 1 command, `11.331R/2.240W`, 30 backpressure cycle, `invalid=0`, 0 failure; chưa tới comparator |
| Production RTL E03 layer 2..11 model-real | **Chưa chạy comparator đầy đủ** | Layer-select harness đã compile; chưa có terminal numerical evidence cho từng layer |
| Production RTL full-size/model thật, một E05 liên tục | **Chưa chạy** | Chưa có một production run từ patch input qua đủ 12 layer tới class |
| Production RTL full-size/model thật trên board | **Chưa hoàn tất** | Chưa được phép tuyên bố end-to-end phần cứng |

Project tại
[`VIT_googlebase_rtl/`](../../VIT_googlebase_rtl/) hiện chưa có Block Design
`vit_system.bd` và board wrapper được generate. Vì vậy sơ đồ kết nối PS/DDR ở
mục 2 là **kiến trúc đích**, không phải một Block Design đã hoàn tất. Script
[`create_vit_system_bd.tcl`](../../scripts/vivado/create_vit_system_bd.tcl)
đã mô tả kết nối này theo cách có thể tái tạo và static gate đã PASS; nó vẫn
chưa được `validate_bd_design`/generate bằng Vivado trên revision hiện tại.

Revision RTL hiện tại cũng chưa có post-synthesis report Vivado mới đủ để
khẳng định LUT/timing và DSP primitive count. Compile, lint, structural guard
bằng Verilator XML và simulation không thay thế bằng chứng netlist đó. Full
regression A4 không chạy Yosys synthesis/technology mapping.

Identity đã khóa trong evidence cuối:

```text
DESIGN_SHA256       d7b4a5612617b637815c448929deea15a752fa3aaf9446984f73c7b8721c6b45
design files        79
VERIFICATION_SHA256 e1ce3d6991efc819e3db12b644722bf4dfa8082dc95753a00d29bd5b437c5552
verification files  206
```

Full regression A4 trên đúng identity này có run ID
`fr-final-20260730-a4`: 27 marker `RUN`, 98 marker `PASS`, không có
FAIL/FATAL/error. Compact E05 logical chốt ở 704.045 cycle; compact E05 AXI
chốt ở 725.741 cycle. Log authoritative:
[`full_regression_fr-final-20260730-a4.log`](../../build/test_logs/full_regression_fr-final-20260730-a4.log).
Trạng thái và binding log/receipt được tổng hợp trong
[`vit_rtl_evidence_manifest.md`](../../build/evidence/vit_rtl_evidence_manifest.md).

## 2. Kiến trúc hệ thống đích trên Genesys ZU-5EV

```text
Ảnh RGB bất kỳ
    │
    ▼
Python hoặc phần mềm trên PS
resize → normalize → patchify 16×16
    │
    └── prepared_input.bin: [1,196,768], 150528 FP32 word

200 tensor parameter
    │
    └── vit_model.bin + vit_model_table.bin

                       Zynq UltraScale+ MPSoC
┌─────────────────────────────────────────────────────────────────────┐
│ A53/PS software                                                     │
│  1. kiểm tra model table/hash                                       │
│  2. nạp MODEL, INPUT và cấp SCRATCH trong PS DDR                    │
│  3. lập trình offset tensor, base/limit DDR và JOB_CONFIG           │
│  4. START, chờ IRQ/done, đọc class_index/class_logit                │
│                                                                     │
│ PS M_AXI_HPM0_FPD ──► AXI interconnect ──► NPU S_AXI AXI4-Lite     │
│ PS S_AXI_HP0_FPD  ◄── AXI interconnect ◄── NPU M_AXI 32-bit        │
│ PS DDR             ◄──────────────────────── MODEL/INPUT/SCRATCH    │
│ pl_ps_irq0         ◄──────────────────────── done/error IRQ         │
└─────────────────────────────────────────────────────────────────────┘
```

AXI chỉ vận chuyển transaction. AXI không hiểu GEMM, Softmax hay tên file
weight. Sequencer/controller chọn operation và logical address; phần mềm PS
đóng gói model, phân vùng DDR và lập trình register.

QEMU có thể kiểm phần mềm/luồng register ở mức nhất định, nhưng không thay thế
RTL simulation của PL, timing closure hoặc DDR behavior trên Genesys ZU-5EV.

## 3. Tiền xử lý và gói dữ liệu ngoài RTL

### 3.1 Tiền xử lý ảnh

[`prepare_image.py`](../../preprocessing/prepare_image.py) thực hiện:

1. decode và chuyển RGB;
2. resize/normalize bằng processor cục bộ;
3. tạo tensor `[1,3,224,224]`;
4. `unfold` patch `16×16`, stride `16`;
5. transpose thành `[1,196,768]`;
6. ghi 150.528 raw FP32 word.

Thứ tự word trong mỗi patch là:

```text
patch_y → patch_x → channel → kernel_y → kernel_x
```

Mặc dù `224×224×3` và `196×768` có cùng số phần tử, NPU không nhận raster RGB
thô. NPU nhận tensor đã normalize và patchify. Patch embedding vẫn được tính
trong NPU:

```text
PATCH_A[196,768]
× PATCH_WEIGHT[768,768]
+ PATCH_BIAS[768]
→ 196 patch embedding
```

Thư mục [`preprocessing/`](../../preprocessing/),
[`preprocessed/`](../../preprocessed/), [`parameters/`](../../parameters/) và
[`inputs/`](../../inputs/) nằm ngoài synthesis tree nhưng là phần bắt buộc
của flow end-to-end. Manifest preprocessing giữ hash ảnh nguồn, processor,
layout và output để tránh dùng nhầm input cũ.

### 3.2 Gói model

Hai trăm file parameter phát triển được đóng gói một lần thành:

| Artifact | Kích thước |
| --- | ---: |
| `vit_model.bin` | 86.567.664 word = 346.270.656 byte |
| `vit_model_table.bin` | 200 entry, 12.928 byte |
| `prepared_input.bin` | 150.528 word = 602.112 byte |

`vit_model_table.bin` là contract cho phần mềm. PS kiểm header/CRC/hash và lấy
offset canonical, sau đó ghi 8 global offset và `12×16` layer offset vào
AXI-Lite. NPU không mở file và không đọc filename. Đặc tả chi tiết nằm tại
[`VIT_MODEL_PACKAGE_FORMAT_V1.md`](../VIT_MODEL_PACKAGE_FORMAT_V1.md).

## 4. Hai closure synthesizable

| Closure | Filelist | Top |
| --- | --- | --- |
| Core không AXI | [`core_no_axi.f`](../../filelists/core_no_axi.f) | `vit_phase_e_npu` |
| Core đã bọc AXI | [`full_axi.f`](../../filelists/full_axi.f) | `vit_phase_e_axi_bd_wrapper` |

Thứ tự source:

```text
rtl/pkg
  → rtl/leaf/common + rtl/leaf/fp32
  → rtl/blocks
  → rtl/control
  → rtl/core
  → rtl/axi
  → rtl/top
```

File xuất hiện trong filelist chưa có nghĩa file đó nằm trong netlist
reachable. Một số module song song cũ vẫn được compile để regression
bit-exact/compatibility, nhưng production engine không instantiate chúng.

## 5. Cây module production reachable

```text
vit_system_wrapper                         đích: Vivado-generated board top
└── vit_system                            đích: Block Design
    └── vit_phase_e_axi_bd_wrapper        Verilog shim cho IP Integrator
        └── vit_phase_e_axi_wrapper
            ├── vit_axi_lite_control_regs
            ├── vit_layer_param_table          RAM hai cổng 192×32
            ├── vit_layer_param_loader         nạp tuần tự 16 word/layer
            ├── vit_phase_e_npu
            │   ├── vit_phase_e_sequencer
            │   └── vit_phase_e_engine_top
            │       ├── vit_phase_e_command_controller
            │       ├── vit_phase_e_engine_dispatch
            │       ├── vit_fp32_mul_comb_nodsp      shared toàn engine
            │       ├── vit_fp32_add_comb            shared toàn engine
            │       ├── vit_phase_e_memory_frontend
            │       │   ├── vit_gemm_memory_address_context
            │       │   ├── vit_gemm_activation_panel_cache
            │       │   ├── vit_gemm_bias_cache
            │       │   ├── vit_phase_e_read_address_router
            │       │   └── vit_phase_e_write_address_router
            │       ├── vit_gemm_tree_array
            │       ├── vit_vector_engine_fp32
            │       ├── vit_layout_engine
            │       ├── vit_layernorm_engine_fp32
            │       ├── vit_softmax_engine_fp32
            │       ├── vit_gelu_engine_fp32
            │       └── vit_argmax_engine_fp32
            └── vit_phase_e_axi_mem_adapter
```

Trách nhiệm theo tầng:

- `vit_phase_e_axi_bd_wrapper`: shim interface, không chứa compute datapath.
- `vit_phase_e_axi_wrapper`: snapshot job/global/base/limit khi START, khóa
  write RAM layer trong lúc BUSY, chạy loader 16 word khi sequencer yêu cầu,
  nối control plane, NPU và memory adapter, giữ done/error/IRQ.
- `vit_phase_e_npu`: ghép một sequencer với một execution engine.
- `vit_phase_e_sequencer`: tạo descriptor cho E01..E05.
- `vit_phase_e_command_controller`: quản lý vòng đời một descriptor.
- `vit_phase_e_engine_dispatch`: decode opcode và chọn một compute block.
- `vit_phase_e_memory_frontend`: gather operand, giao block, scatter result.
- `vit_phase_e_axi_mem_adapter`: đổi logical FP32 word address thành AXI byte
  address và kiểm range/protocol.

Bảy compute block tồn tại đồng thời trong netlist và chỉ một block chạy cho
mỗi descriptor. GEMM/Vector/LayerNorm/Softmax/GELU đưa operand tới đúng một
`u_engine_shared_multiplier` và một `u_engine_shared_adder` ở
`vit_phase_e_engine_top`; kết quả tổ hợp được broadcast về block đang active.
Standalone block test giữ arithmetic cục bộ qua parameter mặc định;
production engine đặt `USE_EXTERNAL_MUL=1` và `USE_EXTERNAL_ADD=1`.

## 6. Behavioral golden và production RTL là hai engine khác nhau

Trong [`vit_phase_e_npu.sv`](../../rtl/core/vit_phase_e_npu.sv), sequencer và
giao diện job không thay đổi. Macro simulation chọn engine:

```text
                         cùng job và cùng sequencer
                                  │
                 ┌────────────────┴────────────────┐
                 │                                 │
VIT_PURE_SV_BEHAVIORAL được define       không define macro
                 │                                 │
vit_phase_e_behavioral_engine_top         vit_phase_e_engine_top
file-backed/real/shortreal                bit-vector synthesizable RTL
                 │                                 │
behavioral golden                         production hardware candidate
```

Behavioral full model đã chạy đúng nên được giữ làm golden. Tuy nhiên:

- behavioral source không nằm trong production synthesis closure;
- behavioral PASS không chứng minh production arithmetic bit-exact;
- production compact PASS không chứng minh full-size model thật;
- tuyệt đối không bật `VIT_PURE_SV_BEHAVIORAL` trong hardware fileset.

## 7. ViT dataflow và command flow

Cấu hình mặc định:

| Thuộc tính | Giá trị |
| --- | ---: |
| Patch | 196 |
| Token gồm CLS | 197 |
| Hidden | 768 |
| Head | 12 |
| Head size | 64 |
| MLP intermediate | 3072 |
| Encoder layer | 12 |
| Class | 1000 |

Một E05 đầy đủ:

```text
E01 embedding:       4 command
12 encoder layer:   12 × 20 command
E04 final:           4 command, hoặc 5 nếu bật class Softmax
------------------------------------------------------------
Tổng:                248 hoặc 249 command
```

Luồng tensor chính:

```text
PATCH_A
  → patch GEMM + CLS + position
  → HIDDEN_A

Mỗi encoder layer:
  HIDDEN_A
    → LN1
    → Q/K/V projection
    → split head
    → Q × Kᵀ
    → scale
    → Softmax
    → attention × V
    → merge head
    → output projection
    → residual
    → LN2
    → FC1
    → GELU
    → FC2
    → residual
    → HIDDEN_A của layer kế

Final:
  HIDDEN_A
    → final LayerNorm
    → copy CLS
    → classifier GEMM
    → Argmax
    → class_index + class_logit
    → optional class Softmax
```

ViT này dùng **GELU, không dùng ReLU**.

Mỗi command là descriptor 512 bit gồm 16 word:

| Word | Nội dung |
| ---: | --- |
| W0 | opcode, subop, flags, tag, section/layer context |
| W1 | src/dst memory space và tensor ID |
| W2..W5 | `src0/src1/src2/dst_base` |
| W6..W9 | `dim0..dim3` |
| W10..W14 | `stride0..stride4` |
| W15 | immediate hoặc C-row-stride |

Logical address trong descriptor luôn là FP32 word offset, không phải byte.

## 8. Mô hình bộ nhớ

### 8.1 Ba logical space

| Space | Quyền của NPU | Nội dung |
| --- | --- | --- |
| INPUT | đọc | patch input `[1,196,768]` |
| MODEL/PARAM | đọc | 200 tensor parameter |
| SCRATCH | đọc/ghi | activation trung gian và output |

Memory adapter chỉ cho phép write vào SCRATCH. MODEL và INPUT là read-only từ
góc nhìn accelerator.

Kích thước runtime mặc định:

| Region | Word | Byte |
| --- | ---: | ---: |
| MODEL | 86.567.664 | 346.270.656 |
| INPUT | 150.528 | 602.112 |
| SCRATCH | 1.990.656 (`0x1e6000`) | 7.962.624 (`0x798000`) |

Phần mềm chọn ba physical base không overlap và lập trình base/word limit
trước START. Base nên căn ít nhất 64 byte theo model package contract.

### 8.2 Scratch map

Mọi base dưới đây là word offset tương đối với `SCRATCH_BASE`:

| Tensor | Base word | Số word | Word cuối |
| --- | ---: | ---: | ---: |
| HIDDEN_A | `0x000000` | 151.296 | `0x024eff` |
| HIDDEN_B | `0x025000` | 151.296 | `0x049eff` |
| LINEAR_TMP | `0x04a000` | 151.296 | `0x06eeff` |
| Q_HEAD | `0x06f000` | 151.296 | `0x093eff` |
| K_HEAD | `0x094000` | 151.296 | `0x0b8eff` |
| V_HEAD | `0x0b9000` | 151.296 | `0x0ddeff` |
| SCORE_PROB | `0x0de000` | 465.708 | `0x14fb2b` |
| FC1 | `0x150000` | 605.184 | `0x1e3bff` |
| LOGITS | `0x1e4000` | 1.000 | `0x1e43e7` |
| CLASS_PROB | `0x1e5000` | 1.000 | `0x1e53e7` |

Allocation kết thúc tại word `0x1e5fff`; khoảng padding giữa các tensor dành
cho alignment và headroom, không được xem là tensor.

### 8.3 Logical memory frontend

```text
compute data_request
  → read router tạo từng logical address
  → frontend đọc từng slot hoặc cache hit
  → gather đủ tile/vector
  → data_valid tới compute block

compute result_valid
  → write router tạo từng logical address
  → frontend ghi từng slot SCRATCH
  → result_ready tới compute block
```

Frontend và AXI adapter hiện chỉ có một external transaction outstanding.
Gather hoàn tất trước compute và scatter hoàn tất trước khi nhận result tiếp
theo. Điều này bảo vệ native tile/vector đã gather, nhưng không bảo đảm mọi
descriptor có src/dst overlap tùy ý.

GEMM có cache nhỏ trong frontend:

| Cache | Cấu trúc mặc định | Payload |
| --- | --- | ---: |
| A-panel | 2 bank × 3072 word | 24 KiB |
| Bias | 1 bank × 3072 word | 12 KiB |
| Tổng | 3 RAM bank | 36 KiB |

Cache giảm logical read lặp lại nhưng chưa thay thế AXI burst/prefetch.

### 8.4 GEMM address và stride

Descriptor GEMM dùng:

```text
dim0=batch, dim1=M, dim2=K, dim3=N
stride0=A batch stride
stride1=A row stride
stride2=B batch stride
stride3=B row stride
stride4=C batch stride
immediate=C row stride
```

Địa chỉ một tile:

```text
A = src0 + batch*stride0 + (m+row)*stride1 + k+lane
B = src1 + batch*stride2 + (k+lane)*stride3 + n+column
bias = src2 + n+column
C = dst + batch*stride4 + (m+row)*immediate + n+column
```

`vit_gemm_memory_address_context` giữ base mở rộng 66 bit và cập nhật bằng
phép cộng theo vòng `batch → M tile → N tile → K chunk`. Router dùng tổng mở
rộng 96 bit để phát hiện overflow. Hot path không cần multiplier địa chỉ
32×32 runtime.

## 9. AXI wrapper

### 9.1 Control plane

`vit_axi_lite_control_regs` cung cấp AXI4-Lite 32-bit:

- CONTROL: START, SOFT_RESET, ABORT, CLEAR_ERROR;
- STATUS và sticky done/error/IRQ;
- MODEL/INPUT/SCRATCH base low/high và word limit;
- JOB_CONFIG và PATCH_A_BASE;
- 8 global parameter offset;
- `12×16` per-layer parameter offset;
- CLASS_INDEX và CLASS_LOGIT.

START snapshot job/global/base/limit cho job hiện tại. Bảng layer nằm trong
`vit_layer_param_table`, một RAM hai cổng `192×32`: port A phục vụ AXI-Lite,
port B phục vụ `vit_layer_param_loader`. Khi sequencer giữ
`layer_param_request`, loader phát 16 địa chỉ liên tiếp, ghép rõ từng word
thành `phase_e_layer_params_t`, pulse valid đúng một lần rồi đợi request hạ.
Control bank trả `SLVERR` nếu software ghi `0x400..0x6FC` trong lúc BUSY;
readback vẫn hoạt động. Software chỉ sửa cấu hình job kế tiếp khi STATUS.IDLE.

Data array không reset từng word để giữ khả năng infer block RAM. Một
word-valid vector 192 bit được reset. Ở lần partial-write đầu tiên, RAM ghi cả
bốn byte và ép byte không có WSTRB thành zero; các partial-write sau dùng byte
enable bình thường. Vì vậy reset/readback không làm lộ dữ liệu RAM cũ. Yosys
pre-map giữ đúng một `$mem_v2`; lightweight Xilinx mapping tạo đúng một
`RAMB36E2`.

### 9.2 Data plane hiện tại

`vit_phase_e_axi_mem_adapter` ánh xạ:

```text
physical_byte_address =
    selected_space_base + (uint64(logical_word_address) << 2)
```

Adapter kiểm space, limit, alignment, overflow, response ID/RESP/LAST và
chính sách write-only-to-SCRATCH.

M_AXI hiện tại là correctness-first:

| Thuộc tính | Hiện trạng |
| --- | --- |
| Data width | 32 bit |
| Burst | mỗi request `LEN=0`, một beat 4 byte |
| Outstanding | một transaction |
| Read/write concurrency | không có nhiều request song song |
| Prefetch/line buffer | chưa có |

Vì vậy compact AXI simulation có thể chứng minh protocol và functional flow,
nhưng không đại diện throughput DDR của full ViT. Bước tối ưu hiệu năng sau
correctness baseline là data width lớn hơn, multi-beat burst, B/weight tile
buffer và ping-pong prefetch.

## 10. Compute block production

### 10.1 GEMM: tile production R8 8×2, dùng arithmetic chung toàn engine

```text
vit_gemm_tree_array
├── vit_gemm_controller
├── vit_gemm_operand_router
├── vit_gemm_pe_array
│   ├── vit_gemm_dot16_serial           đúng 1 instance
│   │   ├── mul operand/result ↔ u_engine_shared_multiplier
│   │   └── add operand/result ↔ u_engine_shared_adder
│   └── vit_gemm_accumulator_bank
│       └── add operand/result ↔ u_engine_shared_adder
└── vit_gemm_result_path
```

`ARRAY_ROWS=8`, `ARRAY_COLS=2`, `PE_LANES=16` mô tả tile và storage 16 output,
không phải 16 PE arithmetic song song. Scheduler quét 16 tọa độ row-major và
dùng chung một dot16.

Dot16 trong production:

1. latch 16 activation/weight và lane mask;
2. tạo 16 rounded product tuần tự bằng multiplier chung ở engine;
3. replay cây reduction cân bằng `8→4→2→1` bằng một adder;
4. accumulator bank cộng partial sum vào một trong 16 output;
5. sau K chunk cuối, cùng adder bank cộng bias tuần tự.

Production full engine không đặt arithmetic FP32 riêng dưới GEMM; GEMM dùng
**1 multiplier và 1 adder chung toàn engine**, đổi LUT lấy latency. Dot
reduction chỉ yêu cầu adder trong các state `REDUCE_*`; accumulator chỉ yêu
cầu khi dot đã `DONE` hoặc trong bias epilogue. Dot có priority xác định và
assertion simulation bắt mọi collision. Khi instantiate độc lập với
`USE_EXTERNAL_MUL=0`/`USE_EXTERNAL_ADD=0`, generate branch tạo một multiplier
và hai adder cục bộ để unit test tự chứa. Các module parallel cũ
`vit_gemm_dot16`, `vit_fp32_reduce16`,
`vit_gemm_pe`, `vit_gemm_accumulator`, `vit_tree_pe_fp32` được compile để
tương thích/test nhưng không reachable từ `vit_gemm_tree_array`.

Tile-shape regression đã PASS `1×1`, `4×2`, `8×2`, `4×4`, `8×4`; production
child này khóa `8×2`. Vì multiplier không nhân theo số row, tăng
`ARRAY_ROWS` giảm số lần đọc lại B với chi phí A-cache bank/mux lớn hơn.
Oracle full E05 R8 cho 2.318.964.440 AXI read và 59.130.368 AXI write; cache
payload là 108 KiB. Compact E05 R8 PASS đủ 249 command với 38.235 read,
10.646 write và 862.132 job cycle; workload ba-token có tail lớn nên cycle
compact không dùng để dự đoán speedup full-size. Timing/resource R8 vẫn phải
được chứng minh bằng đúng netlist child.

### 10.2 Vector: multiplier và adder toàn engine

```text
vit_vector_engine_fp32
├── vit_lane_mask
├── mul operand/result ↔ u_engine_shared_multiplier
└── add operand/result ↔ u_engine_shared_adder
```

Interface vẫn gather/scatter 16 word, nhưng engine xử lý một lane theo thời
gian:

```text
ADD:        result = A + B
SCALE_MASK: scaled = A × scalar
            result = mask_enable ? scaled + B : scaled
```

Mỗi lane đi qua hai state riêng:

```text
STATE_MULTIPLY → register scaled_data → STATE_ADD
```

Register này cắt đường tổ hợp multiplier→adder. `vit_vector_datapath` và
`vit_vector_lane_alu` vẫn có trong filelist nhưng không nằm trên production
path hiện tại.

### 10.3 Layout

```text
vit_layout_engine
├── vit_layout_descriptor_validator
│   └── vit_u32_mul_iterative_nodsp
└── vit_layout_address_generator
```

Layout chỉ di chuyển raw FP32 bit theo rank-3 descriptor. Validator dùng một
multiplier shift/add 32 chu kỳ để kiểm `dim0×dim1×dim2`, span/stride và
overflow. Address generator dùng counter+cộng stride, không instantiate ba
multiplier địa chỉ.

### 10.4 LayerNorm

```text
vit_layernorm_engine_fp32
├── vit_u32_mul_iterative_nodsp
├── vit_fp32_recip_u32_serial
├── mul operand/result ↔ u_engine_shared_multiplier
└── add operand/result ↔ u_engine_shared_adder
```

Mỗi token được đọc ba pass: sum/mean, variance và affine. Reciprocal hidden
size dùng divider tuần tự; inverse square root dùng initial approximation và
ba refinement. Mean, variance, rsqrt và affine replay multiplier/adder toàn
engine. `vit_layernorm_statistics_datapath` và
`vit_layernorm_affine_datapath` là compatibility/reference block, không
reachable từ engine production hiện tại.

### 10.5 Softmax

```text
vit_softmax_engine_fp32
├── vit_u32_mul_iterative_nodsp
├── vit_fp32_compare
├── mul operand/result ↔ u_engine_shared_multiplier
├── add operand/result ↔ u_engine_shared_adder
├── vit_fp32_to_u32_floor_comb
├── vit_fp32_from_u32_comb
└── vit_fp32_scale_pow2_down_comb
```

Mỗi row có ba pass: tìm max, tính/sum exp, tính lại exp để normalize. Không
buffer toàn bộ row exp. Range reduction, Horner polynomial và bốn reciprocal
refinement replay multiplier/adder toàn engine.
`vit_softmax_exp_datapath` và
`vit_softmax_reciprocal_step` không reachable trong production path.

### 10.6 GELU, không phải ReLU

```text
vit_gelu_engine_fp32
└── vit_fp32_gelu_serial
    ├── mul operand/result ↔ u_engine_shared_multiplier
    ├── add operand/result ↔ u_engine_shared_adder
    ├── vit_fp32_to_u32_floor_comb
    ├── vit_fp32_from_u32_comb
    └── vit_fp32_scale_pow2_down_comb
```

Engine gather tối đa 16 word rồi chạy từng lane hợp lệ qua một serial core.
Core tuần tự replay reciprocal, polynomial và exp approximation. Module
`vit_gelu_lane_datapath`/`vit_fp32_gelu_comb` được giữ cho compatibility và
bit-exact regression, không reachable từ engine production.

### 10.7 Argmax

```text
vit_argmax_engine_fp32
└── vit_fp32_compare
```

Argmax quét một logit mỗi lần, giữ index đầu tiên nếu bằng nhau và báo lỗi
với input không finite. Kết quả đi sideband tới class register; Argmax không
ghi tensor qua write router.

## 11. FSM từ top xuống leaf

### 11.1 AXI wrapper và control

Wrapper giữ một `job_pending` và sticky status. Trình tự phần mềm:

```text
IDLE/configure
  → START snapshot job/global/base/limit; lock write layer table
  → NPU busy
  → done hoặc error event
  → sticky STATUS/IRQ
  → software đọc result và RW1C IRQ
```

AXI-Lite có một flow AW/W/B và một flow AR/R outstanding; AW và W được buffer
độc lập. B/R response được giữ đến handshake. Write bảng layer
`0x400..0x6fc` trong lúc BUSY trả `SLVERR`, kể cả trường hợp AW đã vào buffer
trước khi BUSY nhưng W đến sau đó. `done/error/IRQ` là sticky ở wrapper cho
đến khi phần mềm clear theo ABI.

FSM loader layer:

```text
LOAD_IDLE
  -- request, index 0..11 --> LOAD_RUN
  -- invalid index -------> LOAD_RESPONSE với descriptor zero

LOAD_RUN
  -- issue/receive 16 synchronous RAM word, có req backpressure
  --> LOAD_RESPONSE

LOAD_RESPONSE                 valid đúng một chu kỳ
  --> LOAD_WAIT_RELEASE
  -- request hạ ------------> LOAD_IDLE
```

Request/index của sequencer giữ ổn định tới response. Loader có assertion
simulation để bắt response không có request và receive vượt issue; reset giữa
transaction hủy descriptor dở mà không reset data RAM.

### 11.2 Sequencer

```text
SEQ_IDLE
  → SEQ_LOAD_LAYER          nếu cần layer parameter
  → SEQ_ISSUE
  → SEQ_WAIT_COMMAND
  → SEQ_CHECKPOINT          nếu checkpoint_enable
  → SEQ_ADVANCE
  → lặp section/layer/step
  → SEQ_DONE
  → SEQ_IDLE
```

`cmd_valid` và descriptor được giữ ổn định khi backpressure.
E03 reject range layer không thỏa `first_layer <= last_layer < 12`; E05 reject
`E05_ENCODER_LAYERS==0`; phase không hợp lệ đi thẳng `SEQ_DONE` với mã lỗi.
`cmd_error` chốt section/layer/step gây lỗi. `SEQ_CHECKPOINT` giữ metadata và
`checkpoint_valid` cho tới `checkpoint_ready`.

### 11.3 Command controller

```text
STATE_IDLE
  → STATE_WAIT_PARAMETER    nếu command đọc MODEL
  → STATE_LAUNCH
  → STATE_EXECUTE
  → STATE_REPORT
  → STATE_IDLE
```

Dispatch là decode/mux tổ hợp; nó không có FSM riêng.
`STATE_WAIT_PARAMETER` giữ request đến `parameter_ready`. LAUNCH reject opcode
ngoài 1..7 và đi REPORT lỗi mà không start compute block. Trong EXECUTE,
memory error hoặc `selected_done && selected_error` được chốt rồi REPORT phát
một pulse `cmd_error`; đường thành công phát `cmd_done`.

### 11.4 Memory frontend

Read:

```text
MEM_IDLE
  → MEM_READ_SELECT
  → external: MEM_READ_REQUEST → MEM_READ_RESPONSE
     hoặc cache: MEM_CACHE_RESPONSE
  → lặp slot
  → MEM_READ_DELIVER
  → MEM_IDLE
```

Write:

```text
MEM_IDLE
  → MEM_WRITE_SELECT
  → MEM_WRITE_REQUEST
  → MEM_WRITE_RESPONSE
  → lặp slot
  → MEM_WRITE_DELIVER
  → MEM_IDLE
```

Argmax đi thẳng tới `MEM_WRITE_DELIVER` vì result là sideband.
Native request được giữ qua `MEM_*_REQUEST` đến `mem_req_ready`; response chỉ
được nhận khi `mem_rsp_valid && mem_rsp_ready`. Overflow địa chỉ 96→32 bit,
`mem_rsp_error` hoặc write response lỗi set `memory_error_latched`, đưa
frontend về IDLE và invalidate cache. Latch chỉ được clear khi nhận command
mới/reset, nên một valid vẫn đang high không thể tự khởi động lại transaction
lỗi.

### 11.5 AXI memory adapter

```text
STATE_IDLE
  ├── read  → STATE_READ_ADDRESS → STATE_READ_DATA
  ├── write → STATE_WRITE_ISSUE  → STATE_WRITE_RESPONSE
  └── validation error
          ↓
STATE_LOCAL_RESPONSE
  → STATE_IDLE
```

`STATE_WRITE_ISSUE` theo dõi handshake AW và W độc lập.
Adapter reject local trước khi phát AXI nếu space không hợp lệ, word address
không vừa/range không hợp lệ, phép đổi word→byte bị overflow hoặc alignment
sai. AXI `RRESP/BRESP`, ID và `RLAST` sai được trả thành error response native.
AR/AW/W và native response đều giữ ổn định cho tới handshake tương ứng.

### 11.6 GEMM

Controller:

```text
IDLE → CLEAR → COMPUTE → WAIT_PE
     → lặp K chunk
     → BIAS → WRITE
     → lặp N tile, M tile, batch
     → DONE → IDLE
```

PE scheduler:

```text
IDLE → START_DOT → WAIT_DOT
     → tọa độ row/column kế hoặc IDLE + step_done
```

Serial dot:

```text
IDLE
  → MULTIPLY       16 product
  → REDUCE_1        8 add
  → REDUCE_2        4 add
  → REDUCE_3        2 add
  → REDUCE_ROOT     1 add
  → DONE
  → IDLE
```

Accumulator bank:

```text
IDLE/accumulate → BIAS/quét output → HOLD → IDLE
```

GEMM reject `batch_count`, M, K hoặc N bằng 0 và đi DONE với
`config_error=1`. COMPUTE giữ yêu cầu gather cho tới `data_valid`; WAIT_PE chờ
scheduler hoàn tất. WRITE giữ tile result và metadata ổn định cho tới
`result_ready`, sau đó mới tăng N tile, M tile hoặc batch.

### 11.7 Vector

```text
STATE_IDLE
  → STATE_LOAD
  → STATE_MULTIPLY
  → STATE_ADD
  → lặp MULTIPLY→ADD cho đủ 16 lane
  → STATE_WRITE
  → LOAD vector kế hoặc STATE_DONE
  → STATE_IDLE
```

Đây là FSM production mới; không còn `STATE_COMPUTE` chứa multiplier và adder
trên cùng đường tổ hợp.
`cfg_length==0` hoặc mode ngoài ADD/SCALE_MASK đi thẳng DONE với
`config_error=1`. LOAD chờ `data_valid`; WRITE giữ result/base/mask/data ổn
định dưới backpressure tới `result_ready`.

### 11.8 Layout

Engine:

```text
IDLE → VALIDATE → REQUEST → WRITE
     → phần tử kế hoặc DONE → IDLE
```

Validator:

```text
IDLE
→ TOTAL01_START/WAIT
→ TOTAL2_START/WAIT
→ STRIDE0_START/WAIT
→ STRIDE1_START/WAIT
→ STRIDE2_START/WAIT
→ FINAL_CHECK
→ DONE
```

Dimension bằng 0 hoặc overflow của `dim0×dim1×dim2` làm validator kết thúc với
`descriptor_valid=0`. Các tích stride và địa chỉ cuối được giữ rộng đến
`FINAL_CHECK`; source/destination không vừa word address 32-bit cũng invalid.
Engine không phát memory request cho descriptor invalid. REQUEST chờ
`data_valid`, còn WRITE giữ source/destination/result đến `result_ready`.

### 11.9 LayerNorm

```text
IDLE
→ TOTAL_START/WAIT
→ RECIP_START/WAIT
→ SUM_READ/ADD
→ MEAN_SCALE
→ VARIANCE_READ/CENTER/SQUARE/ADD/SCALE
→ EPSILON_ADD
→ INV_STD_INIT
→ ba vòng RSQRT: SQUARE/OPERAND/HALF/CORRECTION/ESTIMATE
→ AFFINE_READ/CENTER/NORMALIZE/GAMMA/BETA/WRITE
→ token kế hoặc DONE
→ IDLE
```

`token_count==0`, `hidden_size==0` hoặc high 32 bit của
`token_count×hidden_size` khác 0 đi DONE với `config_error=1`, trước mọi memory
request. Các state `*_READ` chỉ tiến khi `input_valid`; `AFFINE_WRITE` giữ
index/data tới `result_ready`. Special value ở inverse-square-root có thể
bypass vòng lặp nhưng vẫn đi qua cùng output handshake.

### 11.10 Softmax

```text
IDLE
→ TOTAL_START/WAIT
→ MAX pass
→ EXP_SUM pass:
     CENTER/SCALE/range-reduction/Horner/SCALE_DOWN/ACCUMULATE
→ bốn vòng RECIPROCAL
→ OUTPUT pass:
     replay exp/NORMALIZE/WRITE
→ row kế hoặc DONE
→ IDLE
```

`row_count==0`, `row_length==0` hoặc overflow high 32 bit của tích hai giá trị
đi DONE với `config_error=1`. MAX/EXP/OUTPUT_READ chờ `input_valid`;
OUTPUT_WRITE giữ index/data tới `result_ready`. Nhánh NaN/Inf/zero có thể rút
ngắn exp/reciprocal graph nhưng không bỏ qua quy tắc handshake.

### 11.11 GELU

Engine:

```text
IDLE → READ → LAUNCH_LANE → WAIT_LANE
     → lane kế hoặc WRITE
     → vector kế hoặc DONE
```

Serial core:

```text
IDLE
→ scale và denominator
→ bốn reciprocal refinement
→ GELU polynomial
→ square và exp range-reduction
→ exp Horner polynomial
→ final erf/half/result
→ DONE
```

Special value có thể bypass một số state nhưng vẫn dùng cùng một result
handshake.
`cfg_length==0` đi DONE với `config_error=1`. READ chờ `input_valid`; WRITE
giữ cả vector result/base/mask tới `result_ready`. Tail lane invalid được ghi
zero mà không launch serial core.

### 11.12 Argmax

```text
IDLE → SCAN → RESULT → DONE → IDLE
```

`cfg_length==0` đi DONE với `config_error=1`. SCAN chỉ tăng index khi
`data_valid`; RESULT giữ index/value tới `result_ready`. Giá trị không finite
set sticky error; nếu toàn bộ input không finite, output deterministic là
index 0/qNaN và error vẫn được báo.

### 11.13 Hai leaf tuần tự không có enum lớn

`vit_fp32_recip_u32_serial`:

```text
IDLE
  ├── start && value==0  → result=+Inf → DONE
  └── start && value!=0 → DIVIDE → ROUND → DONE
```

Leaf chỉ lấy mẫu `start` ở IDLE. DIVIDE tạo một quotient bit mỗi clock bằng
compare/subtract, không dùng `/` hoặc `%`; ROUND áp dụng round-to-nearest-even,
clamp overflow thành `+Inf` và underflow thành `+0`. `busy` cao ngoài IDLE,
`done` chỉ cao ở DONE.

`vit_u32_mul_iterative_nodsp` không có state enum công khai: nó chỉ nhận
`start` khi `!busy`, latch hai operand rồi chạy đúng 32 bước shift/add. Sau
bước cuối nó hạ `busy` và pulse `done` một clock; `start` trong lúc busy bị bỏ
qua. Leaf này phục vụ validator Layout và kiểm tra total-word của
LayerNorm/Softmax.

## 12. Arithmetic leaf và compatibility boundary

Leaf reachable trong production hierarchy mặc định:

```text
rtl/leaf/common/
├── vit_lane_mask
└── vit_u32_mul_iterative_nodsp

rtl/leaf/fp32/
├── vit_fp32_add_comb
├── vit_fp32_mul_comb_nodsp
├── vit_fp32_compare
├── vit_fp32_from_u32_comb
├── vit_fp32_to_u32_floor_comb
├── vit_fp32_scale_pow2_down_comb
└── vit_fp32_recip_u32_serial
```

`vit_counter`, `vit_stream_buffer`, `vit_fp32_sub_comb`, các leaf
combinational `recip`, `rsqrt_step`, `exp_neg`, `gelu` cùng package function
lớn vẫn được compile cho regression/compatibility nhưng không reachable từ
full production top mặc định. Các production engine LayerNorm/Softmax/GELU
đã thay graph song song đó bằng FSM và arithmetic chia sẻ.

Mỗi word dùng encoding binary32 32-bit, nhưng đây là arithmetic RTL tự viết
với approximation và special-value policy riêng. Không tuyên bố tuân thủ toàn
bộ IEEE-754 khi chưa có exhaustive conformance test.

## 13. Chính sách DSP = 0

Yêu cầu DSP=0 áp dụng cho mọi block, kể cả GEMM/MAC/PE.

Các lớp bảo vệ:

1. production filelist loại behavioral reference và Xilinx Floating-Point IP;
2. `vit_fp32_mul_comb_nodsp` và compute hierarchy có `use_dsp="no"`;
3. phép nhân cấu hình/địa chỉ quan trọng dùng
   `vit_u32_mul_iterative_nodsp`;
4. [`vit_project_common.tcl`](../../scripts/vivado/vit_project_common.tcl)
   đặt `MAX_DSP=0`;
5. [`no_dsp.xdc`](../../scripts/vivado/no_dsp.xdc) đặt `USE_DSP=NO`;
6. [`check_shared_arithmetic.sh`](../../scripts/checks/check_shared_arithmetic.sh)
   khóa số instance arithmetic production và cấm `$div/$mod`;
7. [`check_no_dsp.tcl`](../../scripts/vivado/check_no_dsp.tcl) đếm
   `DSP48*`/`DSP58*` trong netlist và fail nếu khác 0.

Static check và Verilator XML chỉ chứng minh contract nguồn/cấu trúc, không
phải ánh xạ primitive. Kết luận cuối bắt buộc là report post-synthesis của
đúng revision:

```text
DSP48/DSP58 primitive count = 0
```

Hiện chưa có post-synthesis Vivado của identity `d7b4a561...`; không được
dùng report cũ hoặc PASS simulation để khẳng định production netlist đã đạt
DSP=0.

## 14. Bằng chứng simulation production hiện có

### 14.1 Compact E05 qua logical memory

Runner:

```bash
sim/end_to_end/run_e05_compact_rtl_verilator.sh
```

Cấu hình compact:

```text
2 patch, 3 token, hidden 16
2 head × 8, intermediate 16
7 class, đủ 12 encoder layer
```

Nó không define behavioral macro. Test đã PASS:

```text
249 command
249 checkpoint
57819 read
10646 write
class=3, logit=0x40e00000 (+7.0)
```

### 14.2 Compact E05 qua AXI

Runner:

```bash
sim/end_to_end/run_e05_compact_axi_rtl_verilator.sh
```

Test đi qua đúng:

```text
AXI-Lite BFM
→ vit_phase_e_axi_bd_wrapper
→ AXI wrapper
→ production NPU
→ M_AXI
→ 3-region AXI DDR model
```

Nó cũng đã PASS đủ 249 command/249 checkpoint, 101 operand-parameter
handshake và cùng kết quả class 3. Layer loader thêm đúng `16×12=192` cycle;
source tree hiện tại hoàn tất sau 725.741 cycle. Traffic:

```text
model reads   = 40871
input reads   =    32
scratch reads = 16916
total reads   = 57819
scratch writes= 10646
```

Golden compact dùng activation/weight 0, gamma 1 và classifier bias `+7.0`
tại class 3. Đây là **production-hierarchy integration smoke**, không phải
accuracy test full model.

### 14.3 Full-dimension/model-real E04 qua AXI

Runner:

```bash
sim/end_to_end/run_e04_real_axi_rtl_verilator.sh
```

Evidence A2 có trạng thái `pass_authoritative`, run ID
`e04-final-20260730-a2`; log:
[`vit_axi_e04_real_rtl_full_e04-final-20260730-a2.log`](../../build/test_logs/vit_axi_e04_real_rtl_full_e04-final-20260730-a2.log).
Test preload checkpoint thật sau encoder layer 11, final LayerNorm
gamma/beta thật, classifier weight/bias thật, sau đó chạy đúng production
wrapper với kích thước mặc định. Đây là rerun trên final-tree đã có shared
adder và layer-table RAM:

```text
checks = 84
cycles = 16401733
197 token × 768 hidden
classifier 768 × 1000
5 command/checkpoint
AXI reads  = 1531016
AXI writes = 154064
class      = 879
RTL logit  = 0x414887B9
golden     = 0x414887B7
```

Không có access ngoài MODEL/SCRATCH; AXI-Lite IDLE/BUSY/DONE/ERROR, sticky
IRQ và RW1C đều được kiểm. Ngoài top-1, test so toàn bộ checkpoint:

```text
151296 final-LayerNorm word: max absolute error 5.722045898e-06
1000 logit word           : max absolute error 1.907348633e-06
1000 probability word     : max absolute error 3.576278687e-07
CLS layout 768 word       : bit exact
```

Đây là bằng chứng production với model thật cho riêng final phase E04. Nó
không thay thế full E05 từ patch input qua 12 encoder layer.

### 14.4 Full-dimension/model-real E01 qua AXI

Evidence A2 có trạng thái `pass_authoritative`, run ID
`e01-final-20260730-a2`; log:
[`vit_axi_e01_real_rtl_full_e01-final-20260730-a2.log`](../../build/test_logs/vit_axi_e01_real_rtl_full_e01-final-20260730-a2.log).
Runner dùng prepared input cùng patch weight/bias, CLS và position thật, rồi
so đủ `197×768 = 151.296` output embedding với behavioral checkpoint:

```text
checks                  = 75
cycles                  = 658889397
commands                = 4
reads/writes            = 58407936 / 453120
MODEL/INPUT/SCRATCH read= 57955584 / 150528 / 301824
invalid access          = 0
exact mismatch          = 132151
tolerance failures      = 0 at 5e-4
max/mean absolute error = 1.788139343e-06 / 1.016216337e-07
```

`HIDDEN_B` không bị ghi ngoài ý muốn. Exact mismatch phản ánh thứ tự làm
tròn của custom FP32; không word nào vượt numerical tolerance.

### 14.5 E02 layer 0: probe authoritative và full diagnostic supplemental

Probe A2 có trạng thái `probe_only_authoritative`, run ID
`e02-probe100k-final-20260730-a2`; log:
[`vit_e02_layer0_real_logical_rtl_probe_e02-probe100k-final-20260730-a2.log`](../../build/test_logs/vit_e02_layer0_real_logical_rtl_probe_e02-probe100k-final-20260730-a2.log).

```text
cycles/commands/checkpoints = 100000 / 1 / 0
reads/writes                = 11330 / 2240
parameter/scratch reads     = 4481 / 6849
requests/responses          = 13570 / 13570
stalls/forced stalls        = 16 / 16
outstanding/invalid/failure = 0 / 0 / 0
```

Probe này chứng minh bounded execution, address routing, stall handling và
không có invalid access trên đúng source/evidence identity. Nó dừng trước
terminal comparator nên không phải numerical PASS của cả layer 0.

Một lượt full E02 cũ đã thực sự đi tới terminal:

```text
checks/commands/cycles      = 241 / 20 / 7636573461
reads/writes                = 737995740 / 4876932
parameter/scratch reads     = 701323008 / 36672732
compared words              = 151296
exact mismatch              = 141857
tolerance failures          = 0
max/mean absolute error     = 4.529953003e-06 / 3.003772886e-07
```

Log
[`vit_e02_layer0_real_logical_rtl_e2e_restart_o3.log`](../../build/test_logs/vit_e02_layer0_real_logical_rtl_e2e_restart_o3.log)
không có receipt/provenance binding theo identity cuối. Vì vậy nó chỉ là
**supplemental legacy diagnostic**, không thay thế E02 A2 authoritative
probe và không được gắn nhãn `pass_authoritative`.

### 14.6 E03 layer 1 probe

Probe A2 có trạng thái `probe_only_authoritative`, run ID
`e03-l01-probe100k-final-20260730-a2`; log:
[`vit_e03_layer01_real_logical_rtl_probe_e03-l01-probe100k-final-20260730-a2.log`](../../build/test_logs/vit_e03_layer01_real_logical_rtl_probe_e03-l01-probe100k-final-20260730-a2.log).

```text
cycles/checks/commands      = 100000 / 158 / 1
layer/parameter requests    = 1 / 1
reads/writes                = 11331 / 2240
parameter/scratch reads     = 4482 / 6849
requests/responses          = 13571 / 13570
outstanding                 = 1
backpressure/invalid/failure = 30 / 0 / 0
```

Một response còn outstanding tại đúng điểm cắt bounded probe là trạng thái
được receipt ghi nhận, không phải terminal phase. Probe chứng minh preload,
descriptor/address/handshake của layer 1; nó không chạy numerical comparator
151.296 word. Layer 2..11 và full comparator layer 1 vẫn đang chờ.

### 14.7 Điều chưa được chứng minh

- full-size E05 production một job liên tục đủ 249 command với 200 tensor
  thật;
- E03 layer 1..11 chưa có terminal phase-level numerical comparator cho
  từng layer trên evidence identity cuối;
- Block Design PS↔PL↔DDR đã có Tcl tái tạo nhưng chưa được Vivado
  validate/generate;
- phần mềm/driver PS để nạp model/input, lập trình AXI-Lite và xử lý IRQ;
- post-synthesis LUT/FF/BRAM/URAM/timing và primitive DSP=0;
- performance DDR thật.

## 15. Giới hạn và hướng tối ưu tiếp

1. M_AXI 32-bit, single-beat, một outstanding là bottleneck lớn nhất của
   memory system.
2. GEMM chỉ có một dot16 dùng chung cho tile R8 8×2; LUT arithmetic thấp hơn
   kiến trúc nhiều PE song song nhưng latency compute vẫn cao.
3. Vector xử lý 16 lane tuần tự và có hai stage arithmetic cho mỗi lane.
4. LayerNorm/Softmax đọc lại tensor nhiều pass để tránh buffer lớn.
5. GELU replay toàn graph bằng multiplier và adder toàn engine.
6. Năm compute block chia sẻ đúng một FP32 multiplier và một FP32 adder xuyên
   opcode. Standalone unit test vẫn có arithmetic cục bộ qua parameter mặc
   định, nhưng generate branch đó bị prune khỏi production.
7. A-panel/bias cache giảm read lặp, nhưng B-weight chưa có tile cache và
   chưa có ping-pong.
8. `ARRAY_ROWS=8` giảm traffic lý thuyết nhưng tăng A-cache lên khoảng
   110.592 byte tính cả bias; chưa biết BRAM padding/timing thực tế.
9. Checkpoint sink và parameter staging DMA chưa tồn tại trong AXI wrapper.
10. Full real E05 qua scalar AXI model có lượng traffic cực lớn; thời gian
   simulation không phải thước đo throughput board.
11. Layer-table đã dùng một RAM `192×32` và loader tuần tự; E05 tăng 192
    cycle nhưng traffic/kết quả không đổi. Regression A4 chỉ kiểm cấu trúc
    bằng Verilator XML, không synthesis-map RAM; primitive thật phải chờ
    Vivado post-synthesis.

Prototype line-fill 1–256 beat ở
[`AXI_READ_LINEFILL_EXPERIMENT.md`](AXI_READ_LINEFILL_EXPERIMENT.md) đã PASS
protocol regression nhưng cố ý nằm ngoài production. Hint read-ahead chỉ được
bật cho stream liên tục; GEMM-B hiện gather theo `stride3=N`, nên bật burst
toàn cục có thể tăng traffic gần bằng chiều dài line.

Thứ tự tối ưu hợp lý sau khi khóa correctness:

```text
1. lấy hierarchical synthesis baseline và xác nhận DSP=0 trong netlist
2. xác định LUT/timing hot hierarchy
3. mở rộng M_AXI data width
4. tạo burst coalescer và nhiều outstanding có kiểm soát
5. thêm B/weight tile cache
6. ping-pong A/B buffer để overlap load và compute
7. chỉ tăng compute parallelism khi băng thông đủ
```

Không tối ưu bằng cách đưa behavioral `real/shortreal`, DSP hoặc floating
point IP cũ trở lại production.

## 16. Lệnh kiểm tra nhẹ

Không chạy Vivado implementation:

```bash
python3 tools/check_synth_filelists.py
scripts/checks/compile_rtl.sh
scripts/checks/lint_rtl.sh
scripts/checks/check_shared_arithmetic.sh
scripts/checks/check_runtime_contract.sh
scripts/checks/check_vivado_flow_static.sh
sim/end_to_end/run_e05_compact_rtl_verilator.sh
sim/end_to_end/run_e05_compact_axi_rtl_verilator.sh
scripts/checks/run_real_data_regression.sh
```

Khi chuyển sang máy đủ RAM để lấy bằng chứng synthesis:

```bash
vivado -mode batch -source scripts/vivado/run_rtl_synth_nodsp.tcl
```

Chỉ coi DSP=0 là PASS khi script hoàn tất và report của đúng revision ghi
primitive count bằng 0.

Tài liệu descriptor/register/FSM chi tiết hơn nằm tại
[`VIT_NPU_TOP_DOWN_REFERENCE.md`](VIT_NPU_TOP_DOWN_REFERENCE.md). Kế hoạch
cache/burst/ping-pong nằm tại
[`GEMM_MEMORY_PIPELINE_PLAN.md`](GEMM_MEMORY_PIPELINE_PLAN.md).
