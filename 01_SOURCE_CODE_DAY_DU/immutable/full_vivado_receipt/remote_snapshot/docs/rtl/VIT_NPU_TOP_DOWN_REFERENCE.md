# ViT NPU RTL — tài liệu tham chiếu top-down

> **M4-R8 OVERLAY.** Tài liệu này được thừa kế từ snapshot M3; các bảng
> evidence/run identity và câu PASS/PENDING lịch sử không phải nghiệm thu R8.
> Những mô tả geometry đã được overlay theo production child hiện tại:
> `ARRAY_ROWS=8`, `ARRAY_COLS=2`, `PE_LANES=16`, IP version `0x00010005`,
> A+bias cache 108 KiB. Contract/current status authoritative nằm tại
> `../M4_R8_REUSE_CONTRACT.md` và `../../README_SERVER.md`. Tài liệu mô tả
> **production synthesizable RTL**, đi từ top xuống block rồi đến leaf, nhưng
> thứ tự compile vẫn là leaf → block → core → AXI → top.
>
> Ký hiệu **[CẦN KIỂM CHỨNG]** nghĩa là RTL đã thể hiện ý định kiến trúc nhưng
> kết quả cuối còn phải được xác nhận bằng mô phỏng, synthesis hoặc netlist của
> đúng source revision hiện tại.

## 1. Phạm vi và nguồn sự thật

Nguồn sự thật chính của kiến trúc là:

- package và RTL production dưới [`rtl/`](../../rtl/);
- hai synthesis closure
  [`core_no_axi.f`](../../filelists/core_no_axi.f) và
  [`full_axi.f`](../../filelists/full_axi.f);
- các testbench dưới [`sim/`](../../sim/);
- policy/check script dưới
  [`scripts/checks/`](../../scripts/checks/) và
  [`scripts/vivado/`](../../scripts/vivado/).

Các thư mục [`parameters/`](../../parameters/),
[`preprocessing/`](../../preprocessing/) và
[`preprocessed/`](../../preprocessed/) vẫn phải giữ nguyên. Chúng cung cấp
tham số model, công cụ tiền xử lý và dữ liệu đã tiền xử lý; chúng không thuộc
cây module synthesis.

`sim/reference/` có thể dùng `real`/`shortreal` để làm mô hình tham chiếu.
Những file đó **không được đưa vào production filelist**. RTL production dùng
bit-vector SystemVerilog và các module arithmetic nhìn thấy được trong
hierarchy.

Identity dưới đây thuộc parent evidence ngày 2026-07-30 và được giữ để truy
vết regression trước M3; nó không phải hash identity mới của source M3:

```text
DESIGN_SHA256       d7b4a5612617b637815c448929deea15a752fa3aaf9446984f73c7b8721c6b45
design files        79
VERIFICATION_SHA256 e1ce3d6991efc819e3db12b644722bf4dfa8082dc95753a00d29bd5b437c5552
verification files  206
```

Hai số lượng trên là số file được hash trong design/verification evidence
bundle, không thay thế số source của từng synthesis closure bên dưới.

Evidence riêng của M3 nằm dưới
[`evidence/m3_blocked_b_fp32_2026-08-04/`](../../evidence/m3_blocked_b_fp32_2026-08-04/)
và chỉ là provenance. Evidence R4 được giữ cùng mục đích. Mọi R8 gate phải
dùng `evidence/m4_r8_2026-08-06/` và được khóa vào manifest R8 mới; không được
đổi nhãn log parent thành R8 PASS.

Hai closure chính:

| Phạm vi | Filelist | Top synthesis | Mục đích |
| --- | --- | --- | --- |
| Không AXI | [`core_no_axi.f`](../../filelists/core_no_axi.f) | `vit_phase_e_npu` | Tối ưu compute/control với giao tiếp logical-memory |
| Đã bọc AXI | [`full_axi.f`](../../filelists/full_axi.f) | `vit_phase_e_axi_bd_wrapper` | Tích hợp AXI4-Lite, AXI4 DDR và Vivado Block Design |

Source-structure guard M1 hiện kiểm 67 file HDL production: 2 package và 65
file module. Mỗi file có đúng một declaration, tên module/package khớp tên
file và không có declaration trùng. Closure core có 59 source; closure AXI
đầy đủ có 67 source. M1 chỉ append
`vit_phase_e_profile_counters.sv` vào phía AXI/control; compute closure không
đổi. Phân bố:

```text
leaf=18 → blocks=30 → control=1 → core=8 → axi=7 → top=1
packages=2
```

Đây là quy tắc tổ chức file, không phải số instance reachable: các module
compatibility vẫn được compile nhưng có thể bị prune khỏi production top.

Flow không tin cậy cache/project sinh sẵn dưới
[`VIT_googlebase_rtl/`](../../VIT_googlebase_rtl/). Stage 30 tạo lại và validate
`vit_system.bd`, khóa Module Reference R8, generate `vit_system_wrapper` và
đọc lại geometry; board top là `vit_system_wrapper`, OOC top là
`vit_phase_e_axi_bd_wrapper`. Chỉ log COMPLETE của đúng manifest R8 mới chứng
minh các bước đó đã chạy. PS driver tự động nạp model/input, lập trình register
và xử lý IRQ vẫn nằm ngoài hardware bundle này.

## 2. Cây hệ thống top-down

```text
vit_system_wrapper                         generated board top, nếu có
└── vit_system                            Vivado Block Design
    └── vit_phase_e_axi_bd_wrapper        Verilog-2001 Module Reference shim
        └── vit_phase_e_axi_wrapper
            ├── vit_axi_lite_control_regs
            ├── vit_layer_param_table           dual-port RAM 192×32
            ├── vit_layer_param_loader          FSM 16 word/layer
            ├── vit_phase_e_npu
            │   ├── vit_phase_e_sequencer
            │   └── vit_phase_e_engine_top
            │       ├── vit_phase_e_command_controller
            │       ├── vit_phase_e_engine_dispatch
            │       ├── vit_fp32_mul_comb_nodsp      u_engine_shared_multiplier
            │       ├── vit_fp32_add_comb            u_engine_shared_adder
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

Trách nhiệm từng tầng:

1. `vit_phase_e_axi_bd_wrapper` chỉ công bố metadata interface để Vivado IP
   Integrator nhận đúng AXI/clock/reset; không chứa datapath.
2. `vit_phase_e_axi_wrapper` chốt cấu hình khi START, giữ trạng thái
   done/error/IRQ, nối core với AXI memory adapter.
3. `vit_phase_e_npu` ghép sequencer với execution engine.
4. `vit_phase_e_sequencer` tạo chuỗi descriptor ViT.
5. `vit_phase_e_command_controller` quản lý vòng đời một descriptor.
6. `vit_phase_e_engine_dispatch` giải mã opcode và chỉ chọn một block hoạt
   động cho descriptor hiện tại.
7. `vit_phase_e_memory_frontend` gather operand, giao cho block, rồi scatter
   result qua một giao tiếp logical-memory tuần tự.
8. Bảy compute block đều được instantiate vật lý và chỉ một opcode chạy tại
   một thời điểm. GEMM/Vector/LayerNorm/Softmax/GELU dùng chung đúng một
   multiplier FP32 và một adder FP32 ở engine top.

Đường arithmetic production:

```text
active_cmd.opcode
   ├─ GEMM mul operands
   ├─ Vector mul operands
   ├─ LayerNorm mul operands
   ├─ Softmax mul operands
   └─ GELU mul operands
          │
          ▼
u_engine_shared_multiplier      đúng 1 vit_fp32_mul_comb_nodsp
          │
          └── result broadcast; chỉ block đang active chốt kết quả

Các operand adder đi qua một mux opcode tương tự tới
`u_engine_shared_adder`. Riêng GEMM có mux nội bộ: dot reduction chỉ yêu cầu
trong `REDUCE_*`, accumulator chỉ yêu cầu khi dot đã xong hoặc trong bias
epilogue. Assertion simulation bắt collision; dot có priority xác định.
```

Đây là các mux tổ hợp, không thêm state hoặc latency. Parameter
`USE_EXTERNAL_MUL=0` và `USE_EXTERNAL_ADD=0` mặc định chỉ giúp từng block
standalone tự chứa trong unit test; `vit_phase_e_engine_top` đặt cả hai bằng
`1` cho năm production instance.

## 3. Cấu hình ViT cố định hiện tại

Các hằng số nằm trong
[`vit_phase_e_pkg.sv`](../../rtl/pkg/vit_phase_e_pkg.sv):

| Tham số | Giá trị |
| --- | ---: |
| Patch | 196 |
| Token, gồm CLS | 197 |
| Hidden size | 768 |
| Attention head | 12 |
| Kích thước mỗi head | 64 |
| MLP intermediate | 3072 |
| Class | 1000 |
| Encoder layer | 12 |
| Attention scale | FP32 `0x3e000000` = 0.125 |
| LayerNorm epsilon | FP32 `0x2b8cbccc` |

Số word FP32 hay dùng:

| Tensor shape | Số word |
| --- | ---: |
| Patch activation `196 × 768` | 150528 |
| Hidden `197 × 768` | 151296 |
| Một head `197 × 64` | 12608 |
| Một score matrix `197 × 197` | 38809 |
| Toàn bộ score `12 × 197 × 197` | 465708 |
| FC1 `197 × 3072` | 605184 |

Mọi địa chỉ descriptor là **địa chỉ word FP32 32-bit**, không phải địa chỉ
byte.

## 4. Descriptor 512-bit

Một command có đúng 16 word × 32 bit:

| Word | Trường | Ý nghĩa |
| ---: | --- | --- |
| W0 | `header` | opcode, subop, flags, tag, context |
| W1 | `route` | memory space và tensor ID của src/dst |
| W2 | `src0_base` | base word của operand 0 |
| W3 | `src1_base` | base word của operand 1 |
| W4 | `src2_base` | base word của operand 2 |
| W5 | `dst_base` | base word đích |
| W6..W9 | `dim0..dim3` | kích thước theo opcode |
| W10..W14 | `stride0..stride4` | stride theo opcode |
| W15 | `immediate` | scalar/epsilon/C-row-stride |

### 4.1 Header W0

```text
31                    24 23          16 15           8 7       4 3       0
+-----------------------+--------------+--------------+---------+---------+
| reserved/context      | tag          | flags        | subop   | opcode  |
+-----------------------+--------------+--------------+---------+---------+
```

- `reserved = {section[1:0], current_layer[3:0], 2'b00}`.
- `tag = job_tag + command_ordinal`, tự wrap modulo 256.
- flag bit 0: enable GEMM bias.
- flag bit 1: enable attention mask.
- flag bit 2: metadata in-place.
- flag bit 3: metadata checkpoint.
- flag bit 4: cho phép GEMM reuse A-panel/bias cache. Chỉ bật khi A/bias bất
  biến trong command và C không alias hai nguồn này.
- Sequencer hiện không bật mask cho bước attention scale; block có hỗ trợ
  mask nhưng flow mặc định chỉ scale.
- Flag in-place chỉ là metadata, không tự thay đổi địa chỉ và không có
  consumer thực thi riêng. Gather trước/scatter sau bảo vệ tile/vector native
  hiện tại, nhưng không bảo đảm an toàn cho descriptor có vùng nguồn/đích
  overlap tùy ý; flow sequencer phải dùng pattern overlap đã được kiểm tra.
- Checkpoint handshake của sequencer được điều khiển bởi
  `job.checkpoint_enable`; flag checkpoint đồng thời được gắn vào descriptor
  để trace.
- Sequencer built-in bật cache-safe cho các GEMM vì tensor map cố định dùng
  vùng nguồn/đích rời nhau. Descriptor custom phải tự opt-in; thiếu flag thì
  frontend dùng đường memory cũ.

### 4.2 Route W1

```text
31      24 23    22 21    20 19    18 17    16 15  12 11   8 7    4 3    0
+---------+--------+--------+--------+--------+------+------+------+------+
| context | dst sp | src2sp | src1sp | src0sp | dst  | src2 | src1 | src0 |
+---------+--------+--------+--------+--------+------+------+------+------+
```

- `reserved/context = {3'b000, current_step[4:0]}`.
- Space `0=NONE`, `1=SCRATCH`, `2=PARAM/MODEL`, `3=INPUT`.
- Tensor ID phục vụ trace/default routing; `space` và `base` là trường quyết
  định truy cập thực tế.

### 4.3 Opcode

| Opcode | Giá trị | Block |
| --- | ---: | --- |
| NOP | 0 | metadata only |
| GEMM | 1 | `vit_gemm_tree_array` |
| VECTOR | 2 | add hoặc scale/mask |
| LAYOUT | 3 | copy/reorder rank-3 |
| LAYERNORM | 4 | LayerNorm |
| SOFTMAX | 5 | row-wise Softmax |
| GELU | 6 | GELU |
| ARGMAX | 7 | class argmax |
| END | 8 | metadata only |

Command controller production chỉ chấp nhận opcode 1..7. NOP, END hoặc opcode
khác đi vào đường báo lỗi command.

## 5. Job, phase và dataflow model

### 5.1 Phase

| Phase | Phạm vi | Số command |
| --- | --- | ---: |
| E01 | Embedding | 4 |
| E02 | Encoder layer 0 | 20 |
| E03 | Encoder từ `first_layer` đến `last_layer`, inclusive | `20 × số layer` |
| E04 | Final LN, CLS, classifier, argmax, optional softmax | 4 hoặc 5 |
| E05 | E01 + 12 encoder + E04 | 248 hoặc 249 |

E02/E03/E04 không tự tạo lại toàn bộ tensor đầu vào. Phần mềm phải bảo đảm
scratch chứa đúng trạng thái tiền nhiệm. E05 là flow đầy đủ từ patch đã chuẩn
bị đến class.

`vit_phase_e_npu` và `vit_phase_e_sequencer` có ba parameter
`E04_TOKEN_COUNT`, `E04_HIDDEN_SIZE`, `E04_CLASS_COUNT`. Giá trị mặc định là
ViT-base `197`, `768`, `1000`; override chỉ được chọn khi `job.phase=E04`.

E05 có một bộ parameter độc lập:

```text
E05_PATCH_COUNT
E05_TOKEN_COUNT
E05_HIDDEN_SIZE
E05_HEAD_COUNT
E05_HEAD_SIZE
E05_INTERMEDIATE_SIZE
E05_CLASS_COUNT
E05_ENCODER_LAYERS
E05_ATTN_SCALE_FP32
```

Mọi default đều giữ cấu hình ViT-base `196 patch`, `197 token`, hidden `768`,
`12 head × 64`, intermediate `3072`, `1000 class`, `12` encoder layer và
attention scale `0.125`. Các tích word-count từ parameter là hằng
elaboration-time. Testbench có thể override một cấu hình E05 nhất quán để
chạy đủ hierarchy nhanh hơn; synthesis top mặc định không override nên không
đổi cấu hình ViT-base.

### 5.2 Embedding

```text
PATCH_A × PATCH_WEIGHT + PATCH_BIAS
    → LINEAR_TMP

CLS parameter
    → HIDDEN_A token 0

LINEAR_TMP patches
    → HIDDEN_A token 1..196

HIDDEN_A + POSITION
    → HIDDEN_A
```

### 5.3 Một encoder layer

```text
HIDDEN_A
  → LN1 → HIDDEN_B
  → Q GEMM → LINEAR_TMP → split → Q_HEAD
  → K GEMM → LINEAR_TMP → split → K_HEAD → transpose → LINEAR_TMP
  → V GEMM → LINEAR_TMP → split → V_HEAD

Q_HEAD × K_HEAD^T
  → SCORE_PROB
  → scale 0.125 [mask mặc định không bật]
  → Softmax in-place

SCORE_PROB × V_HEAD
  → Q_HEAD
  → merge heads → LINEAR_TMP
  → output projection → HIDDEN_B
  → residual + HIDDEN_A → HIDDEN_B

HIDDEN_B
  → LN2 → HIDDEN_A
  → FC1 → FC1
  → GELU in-place
  → FC2 → LINEAR_TMP
  → residual + HIDDEN_B → HIDDEN_A
```

20 step được đánh số 0..19 theo đúng thứ tự trên. Weight matrix tuyến tính
phải được lưu ở layout phần cứng `[K,N]`, không phải layout PyTorch `[N,K]`.

### 5.4 Final

```text
HIDDEN_A
  → final LayerNorm → HIDDEN_B
  → copy CLS token → LINEAR_TMP
  → classifier GEMM → LOGITS
  → argmax → class_index/class_logit sideband
  → optional Softmax → CLASS_PROB
```

Argmax không ghi tensor qua write router; class index/logit được chốt vào
register sideband.

## 6. Scratch memory map

Phần mềm chia DDR thành ba region độc lập và lập trình physical base + word
limit trước START:

| Logical space | Kích thước mặc định | Quyền của NPU | Nội dung/layout |
| --- | ---: | --- | --- |
| MODEL/PARAM | v1: 86.567.664 word; M3 v2: 86.567.680 word | read | 200 tensor; v1 row-major, M3 prepack 74 persistent GEMM-B theo K16/N2 |
| INPUT | 150.528 word | read | patch tensor `[1,196,768]`, patch-major |
| SCRATCH | 1.990.656 word | read/write | activation row-major theo bảng dưới |

Ba region lớn này nằm ngoài PL trong PS DDR. On-chip chỉ có native
tile/vector đang xử lý, A-cache 2×3072 word, bias-cache 3072 word,
accumulator nhỏ và layer-parameter RAM `192×32`. AXI adapter không phân tích
tensor; nó chỉ chọn region từ memory-space ID, kiểm word limit rồi đổi word
offset thành byte address.

Các vùng dưới đây là word offset tương đối với `scratch_base`:

| Tensor | Base word | Số word | Word cuối |
| --- | ---: | ---: | ---: |
| HIDDEN_A | `0x000000` | 151296 | `0x024eff` |
| HIDDEN_B | `0x025000` | 151296 | `0x049eff` |
| LINEAR_TMP | `0x04a000` | 151296 | `0x06eeff` |
| Q_HEAD | `0x06f000` | 151296 | `0x093eff` |
| K_HEAD | `0x094000` | 151296 | `0x0b8eff` |
| V_HEAD | `0x0b9000` | 151296 | `0x0ddeff` |
| SCORE_PROB | `0x0de000` | 465708 | `0x14fb2b` |
| FC1 | `0x150000` | 605184 | `0x1e3bff` |
| LOGITS | `0x1e4000` | 1000 | `0x1e43e7` |
| CLASS_PROB | `0x1e5000` | 1000 | `0x1e53e7` |

`PHASE_E_SCRATCH_WORDS = 0x1e6000`; word hợp lệ cuối cùng của allocation là
`0x1e5fff`. Các base tensor cố định được căn theo 4096 word.

Tensor lớn vẫn nằm ngoài RTL qua INPUT/MODEL/SCRATCH. Frontend chỉ giữ
tile/vector đang xử lý và ba RAM cache GEMM nhỏ: hai A bank
`3072 × 32 bit` cùng một bias bank `3072 × 32 bit`, tổng payload mặc định
36 KiB.

Package M3 v2 dùng layout `[N_TILE][K_CHUNK][COL][LANE]` cố định cho
`PE_LANES=16`, `ARRAY_COLS=2`; QK/PV động trong SCRATCH vẫn row-major.
`MODEL_BASE` phải được phần mềm căn 128 byte. RTL hiện chỉ fail-closed ở biên
4 byte, vì vậy điều kiện 128 byte là một phần bắt buộc của loader contract,
không phải kiểm tra phần cứng. `vit_runtime_config.json` v2 chứa đủ ba word
limit, gồm `scratch_words=0x001e6000`, nhưng không chứa physical DDR bases;
loader vẫn phải cấp phát ba vùng không chồng lấn và ghi các base trước START.
Chi tiết và hash package nằm tại
[`VIT_MODEL_PACKAGE_FORMAT_V2_BLOCKED_B_FP32.md`](../VIT_MODEL_PACKAGE_FORMAT_V2_BLOCKED_B_FP32.md).

## 7. Địa chỉ, stride và data movement

### 7.1 GEMM

Descriptor:

```text
dim0 = batch
dim1 = M
dim2 = K
dim3 = N

stride0 = A batch stride
stride1 = A row stride
stride2 = B batch stride
stride3 = B row stride
stride4 = C batch stride
immediate = C row stride
```

Với tile origin `(batch, m, n, k)`, row `r`, column `c`, lane `l`:

```text
A = src0_base
    + batch * stride0
    + (m + r) * stride1
    + k + l

B = src1_base
    + batch * stride2
    + (k + l) * stride3
    + n + c

bias = src2_base + n + c

C = dst_base
    + batch * stride4
    + (m + r) * immediate
    + n + c
```

Bias chỉ được đọc ở K chunk cuối nếu flag bias bật. Lane K, row M và column N
ở biên được mask trước khi truy cập/ghi.

`vit_gemm_memory_address_context` giữ các base mở rộng 66 bit và cập nhật theo
đúng thứ tự vòng lặp cố định
`batch → token tile → output tile → K chunk`. Batch stride, row stride và K
stride được tích lũy bằng phép cộng; read/write router chỉ cộng offset
row/column/lane vào base tương ứng. Cách này loại các phép nhân địa chỉ 32×32
runtime khỏi hot path GEMM, đồng thời vẫn đưa tổng mở rộng vào arithmetic
96 bit của router để giữ nguyên phát hiện overflow.

Khi descriptor bật `PHASE_E_FLAG_GEMM_CACHE_SAFE`, frontend fill A-panel ở
output tile đầu rồi reuse cho các output tile còn lại. Bias được fill trong
token tile đầu của batch đầu rồi reuse cho phần còn lại của command. A tự
fallback về memory nếu `K > GEMM_A_CACHE_DEPTH_WORDS`; bias fallback độc lập
nếu `N > GEMM_BIAS_CACHE_DEPTH_WORDS`.

### 7.2 Các opcode khác

- VECTOR: `src0_base + element`; operand B dùng cùng flat index khi vector-add
  hoặc khi scale-mask và mask được bật; destination cũng contiguous.
- LAYOUT:
  `src = src0_base + i0*stride0 + i1*stride1 + i2*stride2`;
  `dst = dst_base + linear_index`.
- LayerNorm: data contiguous. Gamma/beta chỉ được đọc ở pass affine, địa chỉ
  là `src1_base/src2_base + data_channel_index`. Engine xuất trực tiếp
  `channel_index`, nên address router không cần phép modulo runtime.
- Softmax: row-major contiguous; engine tự quét từng row.
- GELU: contiguous theo vector 16 word, nhưng tính từng lane tuần tự.
- Argmax: contiguous; kết quả đi sideband.

Address router dùng phép tính mở rộng 96 bit và báo lỗi nếu kết quả vượt
32-bit logical word address.

## 8. Memory frontend và AXI

### 8.1 Gather/scatter contract

`vit_phase_e_memory_frontend` thực hiện:

```text
engine data_request
  → duyệt read slots
  → bỏ qua slot bị mask/không cần
  → đọc từng word
  → phát data_valid đúng một lần khi tile/vector đã gather xong

engine result_valid
  → duyệt write slots
  → bỏ qua slot bị mask
  → ghi từng word
  → phát result_ready sau khi scatter xong
```

Nhờ gather hoàn tất trước compute và scatter hoàn tất trước `result_ready`,
GEMM/Vector/GELU không ghi đè operand còn cần cho chính native tile/vector đã
gather. Đây không phải bảo đảm overlap tổng quát: Layout đọc rồi ghi từng
phần tử trước khi tăng index, nên một descriptor Layout có vùng nguồn/đích
overlap sai hướng vẫn có thể phá dữ liệu chưa đọc.

Số slot mặc định:

| Block | Read slots | Write slots | Ghi chú |
| --- | ---: | ---: | --- |
| GEMM R8 8×2×16 | 162 | 16 | 128 A + 32 B + 2 bias; slot mask có thể bị bỏ |
| Vector | 32 | 16 | 16 A + 16 B; B có thể bị bỏ khi scale không mask |
| Layout | 1 | 1 | một word/lần |
| LayerNorm | 3 | 1 | data + gamma + beta; gamma/beta chỉ pass affine |
| Softmax | 1 | 1 | một word/lần |
| GELU | 16 | 16 | lane mask ở tail |
| Argmax | 1 | 0 | result sideband, không ghi memory |

Giao tiếp logical-memory và adapter chỉ cho một transaction outstanding.
Cache hit được phục vụ bằng synchronous RAM nội bộ qua
`MEM_CACHE_RESPONSE`, không tạo transaction ngoài core.

### 8.2 Chuyển logical word sang AXI byte

Chỉ `vit_phase_e_axi_mem_adapter` thực hiện:

```text
physical_byte_address = selected_space_base + (word_address << 2)
```

Adapter kiểm tra:

- space hợp lệ;
- word nằm trong `*_words`;
- base và địa chỉ vật lý căn 4 byte;
- tổng địa chỉ không overflow và vừa `AXI_ADDR_WIDTH`;
- write chỉ được phép vào SCRATCH.

### 8.3 AXI protocol hiện tại

- Một clock `aclk`; metadata khai báo 100 MHz.
- `aresetn` active-low ở interface. Reset bên trong các `always_ff` được lấy
  mẫu đồng bộ theo `aclk`; không có CDC trong wrapper.
- AXI4-Lite: data 32 bit, address 12 bit, một read và một write outstanding.
  AW và W có buffer độc lập; WSTRB được áp dụng.
- Truy cập AXI4-Lite không căn word hoặc không được hỗ trợ trả `SLVERR`.
- Ghi bảng layer `0x400..0x6fc` khi STATUS.BUSY trả `SLVERR`; readback vẫn
  được phép. Khóa được xét lúc write commit nên cả AW/W tách chu kỳ đều an
  toàn.
- M_AXI: data 32 bit, address 40 bit mặc định, ID width 1.
- Mỗi logical request miss cache hiện trở thành **một beat**, dù interface
  khai báo AXI4:
  `LEN=0`, `SIZE=4 byte`, `BURST=INCR`, `LAST=1`, ID=0.
- AW và W có thể handshake độc lập; adapter đợi cả hai trước B response.
- RID/BID, RRESP/BRESP và RLAST được kiểm tra.
- AXI adapter chưa có multi-beat burst, line prefetch hoặc nhiều outstanding.
  A-panel/bias cache nằm phía trên adapter trong memory frontend.

## 9. AXI4-Lite register map

### 9.1 Control/status

| Offset | Tên | Access | Nội dung |
| ---: | --- | --- | --- |
| `0x000` | IP_ID | RO | `0x5649544e` (`VITN`) |
| `0x004` | IP_VERSION | RO | M4-R8 `0x00010005`; R4 `0x00010004`; M3 `0x00010003` |
| `0x008` | CONTROL | WO/pulse | bit0 START, bit1 SOFT_RESET, bit2 ABORT, bit3 CLEAR_ERROR |
| `0x00c` | STATUS | RO | bit0 idle, 1 busy, 2 done-sticky, 3 error-sticky, 4 irq, 5 parameter-wait |
| `0x010` | IRQ_ENABLE | RW | interrupt enable mask |
| `0x014` | IRQ_STATUS | RW1C | bit0 success, bit1 error |
| `0x018` | ERROR_CODE | RO | NPU hoặc wrapper error |
| `0x01c` | ERROR_INFO | RO | section `[12:11]`, layer `[10:7]`, step `[6:2]` |

Một event có ưu tiên hơn clear RW1C cùng chu kỳ. `CONTROL` chỉ nhận pulse nếu
WSTRB byte 0 bật; đọc CONTROL trả 0.

Wrapper error:

- `0x80000001`: START hoặc SOFT_RESET khi đang busy.
- `0x80000002`: ABORT không được hỗ trợ.

NPU error thấp:

- 0: none;
- 1: bad phase;
- 2: bad layer;
- 3: command error.

### 9.2 Memory base/limit và job

| Offset | Tên |
| ---: | --- |
| `0x020/0x024` | MODEL_BASE low/high |
| `0x028/0x02c` | INPUT_BASE low/high |
| `0x030/0x034` | SCRATCH_BASE low/high |
| `0x038` | MODEL_WORDS |
| `0x03c` | INPUT_WORDS |
| `0x040` | SCRATCH_WORDS |
| `0x044` | EXECUTION_MODE; bit 0 chọn MODEL package v2 blocked-B K16/N2 |
| `0x0a0` | JOB_CONFIG |
| `0x0a4` | PATCH_A_BASE |
| `0x180` | CLASS_INDEX |
| `0x184` | CLASS_LOGIT |

`JOB_CONFIG`:

```text
[2:0]   phase
[6:3]   first_layer
[10:7]  last_layer
[11]    class_softmax_enable
[12]    checkpoint_enable
[20:13] job_tag
```

START snapshot job, global parameters, base và word limit. Bảng layer được
lưu trong RAM hai cổng `192×32`, không còn flat bus/snapshot 6.144 bit.
Control bank dùng port A; loader dùng port B để đọc 16 word của layer được
sequencer yêu cầu. Control bank khóa write bảng này suốt BUSY nhưng vẫn cho
readback. Software chỉ nên thay cấu hình cho job kế tiếp sau khi
`STATUS.IDLE=1`.

`EXECUTION_MODE[0]` cũng được snapshot khi START được chấp nhận; ghi register
sau đó không đổi job đang chạy. Mode 0 giữ đường MODEL row-major/package v1.
Mode 1 chỉ gắn blocked flag cho 74 persistent MODEL GEMM-B; 24 QK/PV GEMM-B
trong SCRATCH vẫn row-major. Mode 1 phải đi cùng package v2,
`MODEL_WORDS=86.567.680` và `MODEL_BASE` căn 128 byte.

### 9.3 Global parameter table

| Offset | Trường |
| ---: | --- |
| `0x080` | patch weight |
| `0x084` | patch bias |
| `0x088` | CLS |
| `0x08c` | position |
| `0x090` | final LN gamma |
| `0x094` | final LN beta |
| `0x098` | classifier weight |
| `0x09c` | classifier bias |

### 9.4 Per-layer parameter table

Layer `L` bắt đầu tại:

```text
layer_base(L) = 0x400 + L * 0x40
```

| Offset trong layer | Trường |
| ---: | --- |
| `+0x00/+0x04` | LN1 gamma/beta |
| `+0x08/+0x0c` | Q weight/bias |
| `+0x10/+0x14` | K weight/bias |
| `+0x18/+0x1c` | V weight/bias |
| `+0x20/+0x24` | O weight/bias |
| `+0x28/+0x2c` | LN2 gamma/beta |
| `+0x30/+0x34` | FC1 weight/bias |
| `+0x38/+0x3c` | FC2 weight/bias |

### 9.5 Performance/profile ABI của M3

M3 giữ nguyên các register cũ và append profile ABI v1.2; không renumber
control, memory, global hoặc layer table. Các cửa sổ chính là:

| Offset | Nội dung |
| ---: | --- |
| `0x048/0x04c` | `PERF_CAPABILITY=0x0001001f`, `PERF_STATUS` |
| `0x050..0x074` | năm counter legacy: job cycle, command, AXI read/write và request-stall |
| `0x188/0x18c` | `PROFILE_CAPABILITY2=0x00027fff`, `PROFILE_STATUS2` |
| `0x190..0x19c` | global/opcode overflow mask |
| `0x1a0..0x2fc` | 44 global counter 64 bit, LO/HI |
| `0x300..0x3fc` | 16 opcode slot: count và active cycle 64 bit |
| `0x700..0x71c` | command-trace capability/select/status/data/error |
| `0x720..0x7b4` | response-wait histogram và maxima |

START được chấp nhận sẽ xóa live/published counter của job mới. DONE publish
toàn bộ snapshot nguyên tử; phần mềm chỉ đọc sau khi snapshot-valid. Tổng
opcode count phải bằng command count, còn tổng opcode active cycle phải bằng
global command-active cycle. Định nghĩa machine-readable authoritative nằm
tại [`PERF_PROFILE_ABI_V1_2.json`](../PERF_PROFILE_ABI_V1_2.json); mô tả đầy
đủ register semantics nằm tại
[`PHASE_E_AXI_WRAPPER.md`](../PHASE_E_AXI_WRAPPER.md).

## 10. Compute blocks top-down

### 10.1 GEMM — kiến trúc production hiện tại

```text
vit_gemm_tree_array
├── vit_gemm_controller
├── vit_gemm_operand_router
├── vit_gemm_pe_array                    scheduler time-multiplexed
│   ├── vit_gemm_dot16_serial            đúng 1 instance
│   │   ├── mul operand/result ↔ u_engine_shared_multiplier
│   │   └── add operand/result ↔ u_engine_shared_adder
│   └── vit_gemm_accumulator_bank        đúng 1 bank
│       └── add operand/result ↔ u_engine_shared_adder
└── vit_gemm_result_path
```

Tên `pe_array` được giữ để biểu diễn tile `(ARRAY_ROWS × ARRAY_COLS)`, nhưng
production hiện **không còn một datapath arithmetic cho mỗi PE**. Một
dot-product engine dùng chung lần lượt thăm từng tọa độ PE row-major. Một
accumulator bank giữ trạng thái output-stationary của toàn tile.

Với cấu hình production `ARRAY_ROWS=8`, `ARRAY_COLS=2`, `PE_LANES=16`, hierarchy
GEMM trong production full engine có:

- 1 đường tới multiplier FP32 dùng chung toàn engine;
- 1 đường tới adder FP32 dùng chung toàn engine cho reduction,
  accumulate và bias;
- 16 accumulator register FP32 cùng result register.

`PE_LANES` hiện bị ràng buộc bằng 16 trong `vit_gemm_pe_array`. ARRAY_ROWS và
ARRAY_COLS phải dương và còn parameterized.

#### Serial dot16

`vit_gemm_dot16_serial`:

1. latch 16 activation, 16 weight và lane mask;
2. dùng multiplier chung ở engine để tạo 16 rounded products tuần tự;
3. lane K không hợp lệ được lưu thành `+0`, nên NaN/Inf ở lane bị mask không
   đi vào reduction;
4. dùng một adder replay đúng cây cân bằng:
   8 pair sums → 4 quarter sums → 2 half sums → 1 root;
5. phát `done` rồi về IDLE.

Thứ tự rounding giữ tương đương với cây `vit_fp32_reduce16` song song, nhưng
latency tăng. Mỗi dot cần 16 phép nhân và 15 phép cộng tuần tự, cộng các chu
kỳ chuyển state/handshake.

#### PE scheduler và accumulator bank

`vit_gemm_pe_array` latch cả tile A/B/bias, rồi lần lượt:

```text
(row=0,col=0) → (0,1) → ... → (last_row,last_col)
```

Mỗi `shared_dot_done` hợp lệ cập nhật đúng accumulator index qua adder toàn
engine. Sau K chunk cuối, bank đi qua toàn bộ PE để cộng bias nếu được bật,
đóng băng `result_data`, và giữ `finish_done` cho đến khi `finish` hạ.

#### Compatibility modules

Các file `vit_gemm_dot16`, `vit_fp32_reduce16`, `vit_gemm_pe`,
`vit_gemm_accumulator` và `vit_tree_pe_fp32` vẫn có trong filelist để giữ
tương thích/test. Chúng **không được instantiate trong production path**
`vit_gemm_tree_array → vit_gemm_pe_array` hiện tại.

#### Trade-off hiện tại

Việc chia sẻ arithmetic giảm mạnh LUT so với 4 PE × 16 multiplier song song,
nhưng throughput giảm. **[CẦN KIỂM CHỨNG]** latency chính xác theo command,
Fmax và tổng thời gian một inference phải lấy từ regression/timing report của
đúng revision hiện tại; không nên suy ra chỉ từ số state.

Hai cache GEMM không nằm trong compute hierarchy trên mà thuộc memory
frontend. Với R8, A-cache dùng tám RAM bank 3.072 word và bias-cache dùng một
RAM bank 3.072 word, tổng payload 110.592 byte. Oracle full E05 cho A-cache
lookup/hit/miss `8.782.821.888 / 8.758.926.576 / 23.895.312`, bias-cache
`2.093.800 / 2.009.088 / 84.712`, và 2.318.964.440 AXI read. Đây là schedule
contract tolerance-zero, không phải latency/DDR board measurement.

Trong cặp integration test cùng descriptor/memory-delay pattern, bật cache
giảm read từ 20 xuống 16 và tổng từ 552 xuống 532 chu kỳ; compute giữ nguyên
285 chu kỳ. Case lớn hơn phân loại 5.115 chu kỳ thành 1.680 external-memory,
111 cache, 1.112 frontend, 2.209 compute và 3 control. Đây chỉ là simulation
proxy, không phải performance DDR thật.

### 10.2 Vector — một lane tuần tự

```text
vit_vector_engine_fp32
├── vit_lane_mask
├── mul operand/result ↔ u_engine_shared_multiplier
└── add operand/result ↔ u_engine_shared_adder
```

Interface ngoài vẫn gather/scatter vector 16 word. Engine latch vector rồi
dịch qua một lane theo thời gian:

- ADD: `result = A + B`;
- SCALE_MASK: `scaled = A × scalar`, sau đó cộng B nếu mask enable;
- tail lane không hợp lệ cho kết quả 0 và không được ghi.

`VECTOR_LANES`/`LANES` production hiện bị ràng buộc bằng 16. Vector dùng
multiplier/adder toàn engine. Mỗi lane dùng hai state
`STATE_MULTIPLY → STATE_ADD`; `scaled_data` được đăng ký giữa hai state để
cắt đường tổ hợp multiplier-to-adder. `vit_vector_datapath` và
`vit_vector_lane_alu` vẫn có trong filelist để compatibility/test nhưng không
reachable từ production engine hiện tại.

### 10.3 Layout

```text
vit_layout_engine
├── vit_layout_descriptor_validator
│   └── vit_u32_mul_iterative_nodsp       một multiplier shift/add dùng chung
└── vit_layout_address_generator          counter + stride addition
```

Layout không thay đổi bit FP32. Validator tuần tự kiểm tra:

- `dim0*dim1*dim2` không overflow;
- span theo từng stride không overflow;
- descriptor có kích thước hợp lệ.

`vit_u32_mul_iterative_nodsp` dùng 32 chu kỳ shift/add, không dùng toán tử
nhân phần cứng song song. Address generator chỉ dùng counter và cộng stride.

### 10.4 LayerNorm

```text
vit_layernorm_engine_fp32
├── vit_u32_mul_iterative_nodsp       token_count × hidden_size
├── vit_fp32_recip_u32_serial         reciprocal hidden size tuần tự
├── mul operand/result ↔ u_engine_shared_multiplier
└── add operand/result ↔ u_engine_shared_adder
```

Mỗi token được quét ba lượt:

1. tính sum/mean;
2. tính variance;
3. đọc lại x cùng gamma/beta để affine output.

Phép nhân cấu hình `token_count × hidden_size` dùng multiplier shift/add
32 chu kỳ và kiểm tra 32 bit cao trước khi đọc dữ liệu. Reciprocal hidden size
dùng restoring divider tuần tự với một compare/subtract mỗi chu kỳ, giữ cùng
kết quả round-to-nearest-even như leaf tổ hợp cũ nhưng không suy diễn `/` hoặc
`%`.

Multiplier/adder toàn engine replay toàn bộ mean, variance, inverse square
root và affine. Inverse square root dùng initial approximation rồi ba
bước iterate tuần tự. Các module statistics/rsqrt/affine song song cũ không
nằm trên đường instantiate production hiện tại. Thiết kế tránh buffer cả
hidden vector và giảm arithmetic nhân bản, đổi lại tăng latency và traffic
đọc.

### 10.5 Softmax

```text
vit_softmax_engine_fp32
├── vit_u32_mul_iterative_nodsp       row_count × row_length
├── vit_fp32_compare                  tìm max
├── mul operand/result ↔ u_engine_shared_multiplier
├── add operand/result ↔ u_engine_shared_adder
├── vit_fp32_to_u32_floor_comb
├── vit_fp32_from_u32_comb
└── vit_fp32_scale_pow2_down_comb
```

Mỗi row có ba lượt:

1. tìm max;
2. tính lại `exp(x-max)` và sum;
3. tính lại `exp(x-max)` để normalize và ghi.

Phép nhân cấu hình `row_count × row_length` dùng multiplier shift/add tuần tự
và reject nếu kết quả vượt 32 bit. Không lưu toàn bộ exp row. FSM replay
range-reduction, Horner polynomial của exp và reciprocal sum qua
multiplier/adder toàn engine; reciprocal dùng initial approximation và bốn bước
iterate tuần tự. Các datapath exp/reciprocal song song cũ không nằm trên đường
instantiate production hiện tại.

### 10.6 GELU, không có ReLU

```text
vit_gelu_engine_fp32
└── vit_fp32_gelu_serial                  một core dùng chung
    ├── mul operand/result ↔ u_engine_shared_multiplier
    ├── add operand/result ↔ u_engine_shared_adder
    ├── vit_fp32_to_u32_floor_comb
    ├── vit_fp32_from_u32_comb
    └── vit_fp32_scale_pow2_down_comb
```

ViT hiện dùng **GELU; không có block ReLU**. Engine gather tối đa 16 word
nhưng lần lượt launch từng lane hợp lệ vào một core tuần tự. Core này replay
thứ tự phép toán và điểm rounding của graph GELU tham chiếu bằng
multiplier/adder toàn engine. Các bước reciprocal, Horner polynomial,
exp range-reduction, exp polynomial và final epilogue được điều khiển bằng
FSM, không sở hữu ALU riêng.

`vit_gelu_lane_datapath` và `vit_fp32_gelu_comb` vẫn nằm trong filelist để
đối chiếu bit-exact/test tương thích, nhưng không được instantiate trong
production path `vit_gelu_engine_fp32 → vit_fp32_gelu_serial`.

### 10.7 Argmax

```text
vit_argmax_engine_fp32
└── vit_fp32_compare
```

Argmax quét một logit mỗi lần, giữ index đầu tiên khi bằng nhau, và báo lỗi
nếu gặp giá trị không finite. Kết quả đi về `class_index/class_logit`.

## 11. FSM top-down

Coverage map dưới đây là checklist để không bỏ sót controller khi đọc từ top
xuống leaf:

| Tầng | State/control owner | Mục chi tiết |
| --- | --- | --- |
| AXI/control | wrapper job flags, AXI-Lite AW/W/B + AR/R, layer loader | 11.1 |
| Model control | `vit_phase_e_sequencer` | 11.2 |
| Command | `vit_phase_e_command_controller`; dispatch là mux không state | 11.3 |
| Data movement | `vit_phase_e_memory_frontend` + cache-valid/tag flow | 11.4 |
| DDR protocol | `vit_phase_e_axi_mem_adapter` | 11.5 |
| GEMM | controller, PE scheduler, serial dot, accumulator bank | 11.6–11.9 |
| Vector | `vit_vector_engine_fp32` | 11.10 |
| Layout | engine + descriptor validator; address generator dùng counter | 11.11 |
| LayerNorm | engine + reciprocal-u32 serial leaf | 11.12 |
| Softmax | `vit_softmax_engine_fp32` | 11.13 |
| GELU | vector engine + `vit_fp32_gelu_serial` | 11.14 |
| Argmax | `vit_argmax_engine_fp32` | 11.15 |

`vit_phase_e_engine_dispatch`, read/write address router, layer-parameter RAM,
GEMM operand/result router và arithmetic combinational leaf không có FSM;
chúng được mô tả ở dataflow/hierarchy thay vì tạo state giả trong tài liệu.

### 11.1 AXI wrapper, control bank và layer loader

Wrapper không có một enum FSM duy nhất; vòng đời job được tạo bởi
`job_pending`, `npu_busy` và sticky status:

```text
IDLE/configure
  -- START hợp lệ --> JOB_PENDING
  -- NPU ready ----> BUSY
  -- done/error ---> IDLE + sticky STATUS/IRQ
```

START/SOFT_RESET khi busy bị reject; ABORT báo unsupported thay vì hủy một
AXI transaction đã được DDR nhận. AXI-Lite write có hai buffer AW/W độc lập,
commit khi đủ cả hai rồi giữ BVALID tới BREADY. Read register thường trả ngay;
read layer-table đi qua synchronous RAM và giữ pending tới `a_rvalid`.

FSM `vit_layer_param_loader`:

```text
LOAD_IDLE
  -- request, index 0..11 --> LOAD_RUN
  -- index invalid --------> LOAD_RESPONSE với descriptor zero

LOAD_RUN
  -- phát/nhận 16 word RAM, giữ địa chỉ khi req bị backpressure
  --> LOAD_RESPONSE

LOAD_RESPONSE                 response_valid đúng một chu kỳ
  --> LOAD_WAIT_RELEASE
  -- request hạ ------------> LOAD_IDLE
```

Word `0..15` được map field-by-field, không dựa vào thứ tự packed struct.
`WAIT_RELEASE` ngăn request được giữ cao sinh hai response. Reset giữa
transaction hủy descriptor dở; RAM data không reset, chỉ word-valid 192 bit
reset. Partial-write đầu tiên ép các byte không có WSTRB thành zero, nên
readback sau reset không làm lộ dữ liệu RAM cũ.

### 11.2 Sequencer

```text
SEQ_IDLE
  → SEQ_LOAD_LAYER        nếu cần đọc parameter table
  → SEQ_ISSUE
  → SEQ_WAIT_COMMAND
  → SEQ_CHECKPOINT        nếu checkpoint_enable
  → SEQ_ADVANCE
  → lặp section/layer/step
  → SEQ_DONE
  → SEQ_IDLE
```

Command được giữ ổn định khi `cmd_valid` bị backpressure. Lỗi command đưa
sequencer đến DONE với section/layer/step tương ứng.

Nhánh job/error đầy đủ:

- E01 bắt đầu EMBEDDING; E02 bắt đầu encoder layer 0; E04 bắt đầu FINAL.
- E03 chỉ vào `SEQ_LOAD_LAYER` khi
  `first_layer <= last_layer < 12`; ngược lại `BAD_LAYER → SEQ_DONE`.
- E05 reject `E05_ENCODER_LAYERS==0`; nếu hợp lệ đi
  EMBEDDING → từng encoder layer → FINAL.
- phase không hợp lệ đi `BAD_PHASE → SEQ_DONE`.
- `cmd_error` ở `SEQ_WAIT_COMMAND` chốt `COMMAND_ERROR` cùng
  section/layer/step; checkpoint backpressure giữ
  `SEQ_CHECKPOINT` cho tới `checkpoint_ready`.
- FINAL phát bốn command bắt buộc; command Softmax thứ năm chỉ có khi
  `class_softmax_enable=1`.

### 11.3 Command controller

```text
STATE_IDLE
  → STATE_WAIT_PARAMETER  nếu descriptor đọc PARAM
  → STATE_LAUNCH
  → STATE_EXECUTE
  → STATE_REPORT
  → STATE_IDLE
```

Trong wrapper hiện tại, parameter loader luôn `ready=1`; không có staging DMA
riêng. LAUNCH phát start cho block được opcode chọn, EXECUTE chờ block
done/error, REPORT phát `cmd_done/cmd_error`. `engine_rst` chỉ theo reset hệ
thống hoặc memory error, không được tạo bởi LAUNCH.

Về handshake/error, `STATE_WAIT_PARAMETER` giữ `parameter_request` và
descriptor đã latch cho tới `parameter_ready`. LAUNCH reject opcode ngoài
1..7, đi thẳng REPORT lỗi và không start compute block. Trong EXECUTE,
`memory_error_latched` có ưu tiên; nếu không, `selected_done` chốt
`selected_error`. REPORT phát đúng một pulse `cmd_done` hoặc `cmd_error` rồi
trở về IDLE.

### 11.4 Memory frontend

```text
MEM_IDLE
  → MEM_READ_SELECT
  ├── external → MEM_READ_REQUEST → MEM_READ_RESPONSE
  └── cache hit → MEM_CACHE_RESPONSE
  → ... lặp slot ...
  → MEM_READ_DELIVER
  → MEM_IDLE

MEM_IDLE
  → MEM_WRITE_SELECT
  → MEM_WRITE_REQUEST
  → MEM_WRITE_RESPONSE
  → ... lặp slot ...
  → MEM_WRITE_DELIVER
  → MEM_IDLE

MEM_IDLE
  → MEM_WRITE_DELIVER     Argmax result sideband, không có memory write
  → MEM_IDLE
```

Lỗi memory được latch để một request/result đang giữ high không tự khởi động
lại trước khi command controller report/reset engine.
`MEM_READ_REQUEST`/`MEM_WRITE_REQUEST` giữ native request đến
`mem_req_ready`; `MEM_*_RESPONSE` chỉ nhận khi
`mem_rsp_valid && mem_rsp_ready`. Read/write candidate overflow từ phép tính
96 bit xuống word address 32 bit, `mem_rsp_error` hoặc response lỗi đều set
`memory_error_latched`, đưa FSM về IDLE và invalidate hai cache. Command mới
hoặc reset mới clear latch này.

Nhánh GEMM cache:

```text
command_accept
  → invalidate A/bias

output tile đầu của mỗi (batch, token tile)
  → fill A theo từng K chunk
  → valid sau K chunk cuối
  → output tile sau đọc A qua MEM_CACHE_RESPONSE

batch=0, token tile=0
  → fill bias theo từng output tile
  → valid sau output tile cuối được scatter
  → token tile/batch sau đọc bias qua MEM_CACHE_RESPONSE
```

RAM payload không reset từng word; bit valid/tag quyết định dữ liệu có được
dùng hay không. Reset, command mới hoặc memory error đều invalidate cache.

### 11.5 AXI memory adapter

```text
STATE_IDLE
  ├── read  → STATE_READ_ADDRESS → STATE_READ_DATA ────────┐
  ├── write → STATE_WRITE_ISSUE  → STATE_WRITE_RESPONSE ───┤
  └── local validation error ───────────────────────────────┤
                                                            ↓
                                                 STATE_LOCAL_RESPONSE
                                                            ↓
                                                       STATE_IDLE
```

`STATE_WRITE_ISSUE` theo dõi AW và W độc lập. Read/write response chỉ được trả
về frontend khi native response handshake hoàn tất.
Trước khi phát AXI, adapter kiểm memory space, base/limit, word→byte overflow
và alignment. Vi phạm đi `STATE_LOCAL_RESPONSE` mà không phát AR/AW/W.
`RRESP/BRESP`, response ID hoặc `RLAST` sai cũng trở thành native error.
AR/AW/W payload và native response được giữ ổn định tới handshake tương ứng.

### 11.6 GEMM controller

```text
STATE_IDLE
  → STATE_CLEAR
  → STATE_COMPUTE
  → STATE_WAIT_PE
  → [K chunk kế] STATE_COMPUTE
  → STATE_BIAS
  → STATE_WRITE
  → [tile kế] STATE_CLEAR
  → STATE_DONE
  → STATE_IDLE
```

- IDLE reject batch/M/K/N bằng 0.
- CLEAR xóa accumulator và đặt `k_base=0`.
- COMPUTE yêu cầu gather tile; khi `data_valid`, phát `pe_step`.
- WAIT_PE là handshake bắt buộc với scheduler chia sẻ.
- BIAS giữ `pe_finish` đến `pe_finish_done`.
- WRITE giữ result ổn định đến scatter xong rồi tăng N tile, M tile, batch.

### 11.7 GEMM PE scheduler

```text
STATE_IDLE
  → STATE_START_DOT
  → STATE_WAIT_DOT
  → tọa độ PE kế tiếp hoặc STATE_IDLE + step_done
```

### 11.8 GEMM serial dot

```text
STATE_IDLE
  → STATE_MULTIPLY       16 products
  → STATE_REDUCE_1        8 adds
  → STATE_REDUCE_2        4 adds
  → STATE_REDUCE_3        2 adds
  → STATE_REDUCE_ROOT     1 add
  → STATE_DONE
  → STATE_IDLE
```

### 11.9 GEMM accumulator bank

```text
STATE_IDLE               accumulate theo index
  → STATE_BIAS           quét toàn PE, dùng chung một adder
  → STATE_HOLD           result/finish_done ổn định
  → STATE_IDLE           khi finish hạ
```

### 11.10 Vector

```text
STATE_IDLE
→ STATE_LOAD
→ STATE_MULTIPLY
→ STATE_ADD
→ lặp MULTIPLY/ADD cho đủ 16 lane
→ STATE_WRITE
→ LOAD vector kế hoặc STATE_DONE
→ STATE_IDLE
```

Register giữa MULTIPLY và ADD loại đường tổ hợp multiplier-to-adder.

`cfg_length==0` hoặc mode ngoài ADD/SCALE_MASK đi trực tiếp
`STATE_IDLE → STATE_DONE` với `config_error=1`. `STATE_LOAD` giữ request đến
`data_valid`; `STATE_WRITE` giữ result/base/mask/data ổn định dưới
backpressure cho tới `result_ready`.

### 11.11 Layout

Engine:

```text
STATE_IDLE → STATE_VALIDATE → STATE_REQUEST → STATE_WRITE
           → REQUEST phần tử kế hoặc STATE_DONE → STATE_IDLE
```

Validator:

```text
STATE_IDLE
→ STATE_TOTAL01_START/STATE_TOTAL01_WAIT
→ STATE_TOTAL2_START/STATE_TOTAL2_WAIT
→ STATE_STRIDE0_START/STATE_STRIDE0_WAIT
→ STATE_STRIDE1_START/STATE_STRIDE1_WAIT
→ STATE_STRIDE2_START/STATE_STRIDE2_WAIT
→ STATE_FINAL_CHECK
→ STATE_DONE
```

Dimension bằng 0 đi thẳng IDLE→DONE với `descriptor_valid=0`. Overflow ở
`dim0×dim1` hoặc `dim01×dim2` cũng đi WAIT→DONE sớm. Các stride product được
cộng trong 66 bit; `FINAL_CHECK` chỉ set valid khi cả source span và
destination cuối vừa 32-bit word address. Engine nhận invalid rồi kết thúc
với `config_error`, không phát memory request.

### 11.12 LayerNorm

```text
STATE_IDLE
→ STATE_TOTAL_START → STATE_TOTAL_WAIT
→ STATE_RECIP_START → STATE_RECIP_WAIT
→ STATE_SUM_READ ↔ STATE_SUM_ADD
→ STATE_MEAN_SCALE
→ STATE_VARIANCE_READ → STATE_VARIANCE_CENTER
→ STATE_VARIANCE_SQUARE → STATE_VARIANCE_ADD
→ channel kế hoặc STATE_VARIANCE_SCALE
→ STATE_EPSILON_ADD → STATE_INV_STD_INIT
→ STATE_RSQRT_SQUARE → STATE_RSQRT_OPERAND → STATE_RSQRT_HALF
→ STATE_RSQRT_CORRECTION → STATE_RSQRT_ESTIMATE
→ lặp ba refinement hoặc STATE_AFFINE_READ
→ STATE_AFFINE_CENTER → STATE_AFFINE_NORMALIZE
→ STATE_AFFINE_GAMMA → STATE_AFFINE_BETA → STATE_AFFINE_WRITE
→ channel kế, token kế qua STATE_SUM_READ, hoặc STATE_DONE → STATE_IDLE
```

`TOTAL_START/WAIT` chạy multiplier u32 tuần tự để kiểm tra tổng word;
`RECIP_START/WAIT` chờ restoring divider tạo reciprocal hidden size.
`SUM_ADD`, các state variance/rsqrt và các state affine lần lượt chọn operand
cho cùng một FP multiplier/adder. NaN, âm, zero và infinity có thể bypass vòng
rsqrt từ `INV_STD_INIT` sang `AFFINE_READ`.

`token_count==0`, `hidden_size==0` hoặc high 32 bit của
`token_count×hidden_size` khác 0 đi thẳng DONE với `config_error=1`, trước khi
phát memory request. Các state `SUM_READ`, `VARIANCE_READ`, `AFFINE_READ` chờ
`input_valid`; `AFFINE_WRITE` giữ index/data ổn định đến `result_ready`.

#### 11.12.1 Leaf `vit_fp32_recip_u32_serial`

```text
STATE_IDLE
  ├─ start && value==0  → result=+Inf → STATE_DONE
  └─ start && value!=0 → STATE_DIVIDE
                           │ compare/subtract một quotient bit mỗi clock
                           └─ division_index==0 → STATE_ROUND
                                                   │ RNE + exponent clamp
                                                   ▼
                                               STATE_DONE
                                                   ▼
                                               STATE_IDLE
```

`busy` là `state != IDLE`; `done` chỉ cao trong `STATE_DONE`. `start` chỉ
được lấy mẫu ở IDLE. Nhánh DIVIDE không dùng `/` hoặc `%`; số vòng phụ thuộc
MSB của `value`, sau đó ROUND xử lý overflow thành `+Inf`, underflow thành
`+0`, còn lại ghép exponent/mantissa binary32.

### 11.13 Softmax

```text
STATE_IDLE
→ STATE_TOTAL_START → STATE_TOTAL_WAIT
→ STATE_MAX
→ STATE_EXP_SUM_READ → STATE_EXP_CENTER → STATE_EXP_SCALE
→ STATE_EXP_INITIAL_PRODUCT → STATE_EXP_INITIAL_REMAINDER
→ STATE_EXP_CORRECTED_PRODUCT
→ STATE_EXP_NEGATIVE_REMAINDER → STATE_EXP_POSITIVE_REMAINDER
→ STATE_EXP_POLY_MUL ↔ STATE_EXP_POLY_ADD
→ STATE_EXP_SCALE_DOWN → STATE_EXP_ACCUMULATE
→ element kế qua STATE_EXP_SUM_READ hoặc STATE_RECIPROCAL_INIT
→ STATE_RECIPROCAL_PRODUCT → STATE_RECIPROCAL_CORRECTION
→ STATE_RECIPROCAL_ESTIMATE
→ lặp bốn refinement hoặc STATE_OUTPUT_READ
→ replay exp qua STATE_EXP_CENTER ... STATE_EXP_SCALE_DOWN
→ STATE_OUTPUT_NORMALIZE → STATE_OUTPUT_WRITE
→ element kế, row kế qua STATE_MAX, hoặc STATE_DONE → STATE_IDLE
```

`TOTAL_START/WAIT` kiểm tra `row_count × row_length` bằng multiplier u32 tuần
tự. `EXP_CENTER` đến `EXP_SCALE_DOWN` là một graph tuần tự dùng lại shared
multiplier/adder cho cả pass sum và pass output. NaN, infinity, zero và các
nhánh exp đặc biệt có thể bỏ qua một phần graph; reciprocal đặc biệt có thể đi
thẳng từ `RECIPROCAL_INIT` đến `OUTPUT_READ`.

`row_count==0`, `row_length==0` hoặc high 32 bit của tích khác 0 đi thẳng DONE
với `config_error=1`. MAX/EXP/OUTPUT_READ chỉ tiến khi `input_valid`;
OUTPUT_WRITE giữ index/data ổn định đến `result_ready`.

### 11.14 GELU

Engine:

```text
STATE_IDLE
→ STATE_READ
→ STATE_LAUNCH_LANE
→ STATE_WAIT_LANE
→ STATE_LAUNCH_LANE cho lane kế hoặc STATE_WRITE
→ STATE_READ vector kế hoặc STATE_DONE
```

Core `vit_fp32_gelu_serial`:

```text
STATE_IDLE
→ STATE_SCALE_VALUE
→ STATE_DENOMINATOR_MUL → STATE_DENOMINATOR_ADD
→ STATE_RECIPROCAL_INIT
→ STATE_RECIPROCAL_PRODUCT → STATE_RECIPROCAL_CORRECTION
→ STATE_RECIPROCAL_ESTIMATE
  [lặp 4 refinement]
→ STATE_GELU_POLY_MUL ↔ STATE_GELU_POLY_ADD
→ STATE_SQUARE
→ STATE_EXP_SCALE
→ STATE_EXP_INITIAL_PRODUCT → STATE_EXP_INITIAL_REMAINDER
→ STATE_EXP_CORRECTED_PRODUCT
→ STATE_EXP_NEGATIVE_REMAINDER → STATE_EXP_POSITIVE_REMAINDER
→ STATE_EXP_POLY_MUL ↔ STATE_EXP_POLY_ADD
→ STATE_EXP_SCALE_DOWN
→ STATE_FINAL_POLY_EXP → STATE_FINAL_ERF_SUB → STATE_FINAL_ONE_PLUS
→ STATE_FINAL_HALF → STATE_FINAL_RESULT
→ STATE_DONE → STATE_IDLE
```

NaN và `-Inf` trả qNaN; `+Inf` trả `+Inf`; `+0/-0` trả `+0`. Các nhánh
special-value có thể đi thẳng từ IDLE đến DONE.

Ở GELU engine, `cfg_length==0` đi thẳng IDLE→DONE với `config_error=1`.
`READ` chờ `input_valid`; `WRITE` giữ cả vector result/base/mask dưới
backpressure đến `result_ready`. Tail lane không hợp lệ được ghi zero mà
không launch serial core.

### 11.15 Argmax

```text
STATE_IDLE → STATE_SCAN → STATE_RESULT → STATE_DONE → STATE_IDLE
```

`cfg_length==0` đi IDLE→DONE với `config_error=1`. SCAN chỉ tăng index khi
`data_valid`; RESULT giữ index/value ổn định cho tới `result_ready`. Mọi input
không finite set sticky error; nếu toàn bộ input không finite, output
deterministic là index 0/qNaN và error vẫn phân biệt trường hợp đó.

Các khối tuần tự không có FSM enum riêng nhưng vẫn quan trọng:

- AXI4-Lite có một AW/W/B flow và một AR/R flow outstanding;
- wrapper giữ `job_pending`, sticky done/error/IRQ;
- `vit_u32_mul_iterative_nodsp` không có enum: chỉ nhận `start` khi
  `!busy`, latch hai operand, chạy đúng 32 bước shift/add, hạ `busy` và phát
  `done` một clock; `start` trong lúc busy bị bỏ qua. Nó phục vụ validator
  Layout và kiểm tra tổng word của LayerNorm/Softmax;
- layout address generator giữ ba counter;
- GEMM address context giữ base 66 bit theo batch/token/output/K;
- GEMM accumulator bank giữ state của output tile.

## 12. Leaf arithmetic và thứ tự build

Production compile theo thứ tự:

```text
rtl/pkg
  → rtl/leaf/common + rtl/leaf/fp32
  → rtl/blocks
  → rtl/control
  → rtl/core
  → rtl/axi
  → rtl/top
```

Leaf common:

```text
vit_counter
vit_lane_mask
vit_stream_buffer
vit_u32_mul_iterative_nodsp
```

Leaf FP32:

```text
vit_fp32_add_comb
vit_fp32_sub_comb
vit_fp32_compare
vit_fp32_mul_comb_nodsp
vit_fp32_accumulator
vit_fp32_from_u32_comb
vit_fp32_to_u32_floor_comb
vit_fp32_scale_pow2_down_comb
vit_fp32_recip_u32_comb
vit_fp32_recip_u32_serial
vit_fp32_recip_comb
vit_fp32_rsqrt_step_comb
vit_fp32_exp_neg_comb
vit_fp32_gelu_comb
```

`vit_fp32_recip_u32_serial` là leaf production của LayerNorm; bản
`vit_fp32_recip_u32_comb` được giữ để tương thích và đối chiếu bit-exact.
Trong `vit_fp32_add_comb`, nhánh subtraction chuẩn hóa mantissa bằng
leading-zero count rồi một barrel shift. Cấu trúc này thay chuỗi 26 tầng
shift/decrement lặp nhưng giữ nguyên điểm rounding.

Hai danh sách file phía trên là **compile inventory**, không phải toàn bộ đều
reachable. Với production top mặc định, arithmetic/common leaf reachable là:

```text
vit_lane_mask
vit_u32_mul_iterative_nodsp
vit_fp32_add_comb
vit_fp32_mul_comb_nodsp
vit_fp32_compare
vit_fp32_from_u32_comb
vit_fp32_to_u32_floor_comb
vit_fp32_scale_pow2_down_comb
vit_fp32_recip_u32_serial
```

`vit_counter`, `vit_stream_buffer`, `vit_fp32_sub_comb`,
`vit_fp32_accumulator`, các reciprocal/rsqrt/exp/GELU combinational leaf và
package function lớn là compatibility/reference-only đối với production
hierarchy mặc định. Chúng vẫn được compile để unit test và đối chiếu bit-exact,
nhưng không được cộng vào resource topology reachable.

Các word arithmetic dùng encoding binary32 32-bit. Tuy nhiên đây là leaf RTL
tự viết với xử lý special value/xấp xỉ riêng; **không được tuyên bố tuân thủ
toàn bộ IEEE 754** nếu chưa có exhaustive conformance test. IEEE 754 chỉ là
chuẩn tham chiếu ngữ nghĩa.

## 13. Chính sách DSP = 0

Yêu cầu kiến trúc là **không dùng DSP cho bất kỳ block nào**, kể cả
GEMM/MAC/PE, Vector, LayerNorm, Softmax và GELU.

Các lớp bảo vệ hiện có:

1. `vit_fp32_mul_comb_nodsp` gắn `(* use_dsp = "no" *)` lên hierarchy và
   mantissa product.
2. Các block arithmetic chính cũng gắn `use_dsp="no"`.
3. Layout và phép kiểm tra tổng word của LayerNorm/Softmax dùng multiplier u32
   shift/add, không dùng `*`; reciprocal hidden size dùng restoring divider
   tuần tự, không dùng `/` hoặc `%`.
4. Production filelist loại Xilinx Floating-Point IP và simulation reference.
5. [`vit_project_common.tcl`](../../scripts/vivado/vit_project_common.tcl)
   đặt `STEPS.SYNTH_DESIGN.ARGS.MAX_DSP=0`.
6. [`no_dsp.xdc`](../../scripts/vivado/no_dsp.xdc) áp `USE_DSP NO`.
7. [`check_no_dsp.tcl`](../../scripts/vivado/check_no_dsp.tcl) đếm
   `DSP48*`/`DSP58*` trong netlist và fail nếu khác 0.
8. [`check_shared_arithmetic.sh`](../../scripts/checks/check_shared_arithmetic.sh)
   dùng Verilator XML elaboration để khóa full production engine ở đúng một
   multiplier `u_engine_shared_multiplier`, một adder
   `u_engine_shared_adder` và không có `/`/`%`.
   Guard cũng khóa standalone generate branch và không cho cache có
   mul/div/mod. Với R8, flow Vivado fail closed yêu cầu activation/bias cache
   map đúng `32/4 RAMB36`, zero RAMB18/URAM/LUTRAM ở cả post-synth và
   post-route. Full regression A4 lịch sử không thay thế technology mapping
   của manifest R8.

Thuộc tính RTL, XDC và `MAX_DSP=0` chỉ thể hiện policy. Bằng chứng cuối cùng
phải là post-synthesis netlist/report:

```text
DSP48/DSP58 primitive count = 0
```

**[CẦN KIỂM CHỨNG]** project XPR hiện tại phải được đồng bộ đúng filelist/source
revision `d7b4a561...`, sau đó generate lại no-DSP và hierarchical
utilization report. Không dùng báo cáo cũ hoặc PASS simulation để kết luận
DSP primitive count của GEMM time-multiplexed mới.

## 14. Test nhẹ trước khi mở Vivado

Các lệnh dưới đây không chạy implementation:

```bash
# 1. Filelist, source boundary, no-DSP policy tĩnh
python3 tools/check_synth_filelists.py

# 2. Compile cả core không AXI và full AXI
scripts/checks/compile_rtl.sh

# 3. Guard số instance arithmetic/cache bằng Verilator XML
scripts/checks/check_shared_arithmetic.sh

# 3b. Tcl/XPR/part/board/BD/no-DSP contract, không khởi động Vivado
scripts/checks/check_vivado_flow_static.sh

# 4. GEMM serial dot equivalence
iverilog -g2012 \
  -s tb_vit_gemm_dot16_serial \
  -o /tmp/vit_gemm_dot16_serial.vvp \
  -c sim/gemm/vit_gemm_dot16_serial_iverilog.f
vvp /tmp/vit_gemm_dot16_serial.vvp

# 5. GEMM tree hiện hành
iverilog -g2012 \
  -s tb_vit_gemm_tree_array \
  -o /tmp/vit_gemm_tree_array.vvp \
  -c sim/gemm/vit_gemm_tree_array_iverilog.f
vvp /tmp/vit_gemm_tree_array.vvp

# 6. Vector engine
sim/vector/run_iverilog.sh

# 7. Cache/address/overflow trực tiếp
sim/gemm/run_address_context_iverilog.sh
sim/gemm/run_activation_panel_cache_iverilog.sh
sim/gemm/run_bias_cache_iverilog.sh
sim/config/run_total_words_config_bounds.sh

# 8. Proxy Yosys tùy chọn, không thuộc authoritative regression A4
timeout 90s scripts/checks/report_yosys_structural_proxy.sh \
  reports/yosys_structural_proxy

# 9. Toàn bộ 249 descriptor E05 với default ViT-base, không chạy datapath
sim/control/run_e05_sequencer_iverilog.sh

# 10. Một job compact E05 xuyên production hierarchy đủ 12 encoder layer
sim/end_to_end/run_e05_compact_rtl_verilator.sh

# 11. Cùng compact E05 qua AXI-Lite + M_AXI + DDR model
sim/end_to_end/run_e05_compact_axi_rtl_verilator.sh

# 12. Real-data suite: mặc định E04 rồi E01 qua AXI + DDR model
scripts/checks/run_real_data_regression.sh

# 13. Có thể chạy riêng E04 hoặc E01
VIT_REAL_RUN_E01=0 scripts/checks/run_real_data_regression.sh
VIT_REAL_RUN_E04=0 scripts/checks/run_real_data_regression.sh

# 14. E02 encoder-layer-0 real logical-memory, opt-in nhiều giờ
VIT_REAL_RUN_E04=0 VIT_REAL_RUN_E01=0 VIT_REAL_RUN_E02_LAYER0=1 \
  scripts/checks/run_real_data_regression.sh

# 15. E03 chọn một layer 1..11; thêm PROBE_CYCLES để chỉ smoke
VIT_REAL_RUN_E04=0 VIT_REAL_RUN_E01=0 VIT_REAL_RUN_E03_LAYER=1 \
  VIT_E03_LOGICAL_PROBE_CYCLES=1000000 \
  scripts/checks/run_real_data_regression.sh
```

Các runner Verilator mặc định thêm C++ `-O3` để giảm thời gian mô phỏng
workload nhiều tỷ cycle. Ghi đè bằng `VIT_VERILATOR_CFLAGS` khi cần; mặc định
không dùng `-march=native`, nên tối ưu mô phỏng không làm binary phụ thuộc
riêng CPU đang chạy.

Regression rộng hơn:

```bash
sim/end_to_end/run_e04_rtl_verilator.sh
nice -n 10 scripts/checks/run_regression.sh
```

Full regression authoritative A4 có run ID `fr-final-20260730-a4`. Nó đã
PASS 27 marker `RUN`, 98 marker `PASS`, không có FAIL/FATAL/error; structural
instance guard dùng Verilator XML và không synthesis-map bằng Yosys. Log:
[`full_regression_fr-final-20260730-a4.log`](../../build/test_logs/full_regression_fr-final-20260730-a4.log).
Log SHA-256 là
`745b2b5d95f3ea94268374b7bef590d739fd563180fe0cf1267e57bb6c446075`;
receipt và manifest khóa log với design/verification identity nêu ở mục 1.

Ma trận bằng chứng phải đọc theo phase; không ghép các PASS rời thành một
inference production đã chạy liên tục:

| Workload | Dữ liệu | Đường chạy | Trạng thái/chứng minh |
| --- | --- | --- | --- |
| Behavioral E05 | model/input thật | backend `real/shortreal` | full model golden PASS; không synthesizable |
| Production compact E05 | golden compact | logical memory và AXI DDR model | PASS đủ 249 command/full topology, không chứng minh accuracy model thật |
| Parent production E01 | patch/model thật, package v1 | AXI | A2 `pass_authoritative`: đủ 151.296 embedding word, exact traffic, `invalid=0`, numerical tolerance PASS; provenance trước M3 |
| M3 production E01 | patch/model thật, package v2 | AXI | `SIM-MEASURED` PASS, 658.889.410 cycle, đủ 151.296 embedding word, exact traffic, `invalid=0`, numerical tolerance PASS; receipt dưới evidence M3 |
| Production E02 | layer-0 thật | logical memory | A2 `probe_only_authoritative` 100.000 cycle; full legacy diagnostic đã terminal nhưng chỉ supplemental do thiếu receipt/provenance cuối |
| Production E03 | layer 1 thật | layer-select logical memory | A2 `probe_only_authoritative` 100.000 cycle; chưa có terminal numerical comparator |
| Production E03 | layer 2..11 thật | layer-select logical memory | harness có sẵn; chưa có authoritative probe/comparator cho từng layer |
| Parent production E04 | final tensors/model thật, package v1 | AXI | A2 `pass_authoritative`: Final LN/classifier/Argmax/Softmax trong tolerance; provenance trước M3 |
| M3 production E04 | final tensors/model thật, package v2 | AXI | `SIM-MEASURED` PASS, 16.401.741 cycle, class 879; receipt dưới evidence M3 |
| Production E05 full-size | toàn bộ model/input thật | một job liên tục qua 12 layer | **chưa chạy/không được tuyên bố PASS** |

Runner E04 compact kiểm tra xuyên production hierarchy với kích thước
`3 × 16 × 7`: sequencer, command controller, logical-memory frontend,
LayerNorm, layout, GEMM/cache, Argmax, Softmax, checkpoint và class result.
Kết quả hiện tại là 311 checks, 4.035 cycle, 419 read và 78 write. Golden dùng
zero activation/weight cùng một classifier bias +7 duy nhất, nên đây là
integration smoke; các regression block riêng chịu trách nhiệm kiểm tra số
học nonzero/bit-exact.

Runner sequencer E05 instantiate parameter mặc định, trả `cmd_done` ngay thay
cho compute engine và đã PASS:

```text
checks=3872 cycles=1010 commands=249 checkpoints=249 layer_requests=12
```

Nó kiểm section/layer/step/tag/opcode và các descriptor ViT-base, gồm
embedding `196 × 768`, encoder `197 × 768`, head `12 × 64`, FC `3072`,
attention Softmax `2364 × 197` và classifier `768 × 1000`. Đây chỉ là
regression control/descriptor.

Runner compact E05 không define `VIT_PURE_SV_BEHAVIORAL`; một job duy nhất đi
qua `vit_phase_e_npu`, production engine, logical-memory frontend và đủ bảy
compute opcode cho 4 embedding command, `12 × 20` encoder command và 5 final
command. Cấu hình compact là `2 patch`, `3 token`, hidden `16`,
`2 head × 8`, intermediate `16`, `7 class`. Kết quả:

```text
checks=17484 cycles=704045 commands=249
reads=57819 writes=10646 class=3 logit=40e00000
```

Golden dùng tensor/weight bằng 0, gamma bằng 1 và classifier bias `+7.0` duy
nhất tại class 3. Kết quả này được gọi là **compact production-hierarchy E05
integration smoke**, không phải full-size ViT-base inference với model thật.
Full-size production datapath vẫn chưa chạy.

Runner AXI compact dùng đúng `vit_phase_e_axi_bd_wrapper`, AXI-Lite BFM,
production NPU, M_AXI và DDR model ba vùng. Nó đã PASS:

```text
checks=357 cycles=725741 commands=249
reads=57819 writes=10646
model_reads=40871 input_reads=32 scratch_reads=16916
class=3 logit=40e00000
```

Test đồng thời kiểm đủ 249 checkpoint, 12 layer-table handshake, 101
parameter-command handshake, mọi write chỉ vào SCRATCH và không có access
vượt MODEL/INPUT/SCRATCH limit. So với baseline trước layer-table RAM, loader
thêm đúng `16×12=192` cycle và không đổi traffic/kết quả. Đây vẫn là compact
integration smoke với golden cố ý đơn giản, không phải full-size/model-real
E05.

Runner real-data E04 A2 có run ID `e04-final-20260730-a2`, trạng thái
`pass_authoritative`; log:
[`vit_axi_e04_real_rtl_full_e04-final-20260730-a2.log`](../../build/test_logs/vit_axi_e04_real_rtl_full_e04-final-20260730-a2.log).
Runner dùng đúng production wrapper với dimension mặc định
`197×768`, classifier `768×1000`, checkpoint thật sau encoder layer 11 và
bốn tensor cuối thật. Rerun final-tree sau shared adder và layer-table RAM đã
PASS:

```text
checks=84 cycles=16401733 commands=5 checkpoints=5
reads=1531016 writes=154064 invalid_access=0
class=879
RTL logit=414887b9, behavioral=414887b7, raw delta=+2
final LayerNorm max absolute error=5.722045898e-06
logits max absolute error=1.907348633e-06
probabilities max absolute error=3.576278687e-07
```

Toàn bộ 151.296 output final LayerNorm, 1.000 logit và 1.000 probability
được so với behavioral golden; CLS layout 768 word phải bit-exact. Đây là
full-dimension/model-real **E04**, chưa phải full E05 qua 12 encoder layer.

Runner E01 A2 có run ID `e01-final-20260730-a2`, trạng thái
`pass_authoritative`; log:
[`vit_axi_e01_real_rtl_full_e01-final-20260730-a2.log`](../../build/test_logs/vit_axi_e01_real_rtl_full_e01-final-20260730-a2.log).
Nó dùng prepared input cùng patch weight/bias, CLS và position thật, rồi so
đủ `197×768` output với behavioral checkpoint embedding. Run PASS 75 checks
sau 658.889.397 cycle. Traffic
khớp chính xác:
58.407.936 read
(`57.955.584 MODEL + 150.528 INPUT + 301.824 SCRATCH`) và 453.120 write
SCRATCH, invalid access bằng 0. Toàn bộ 151.296 word có tolerance failures
bằng 0 ở `5e-4`; max/mean absolute error là
`1.788139343e-06`/`1.016216337e-07`, exact mismatch là 132.151 word do
thứ tự làm tròn FP32 nhưng không word nào vượt tolerance. Test cũng xác nhận
`HIDDEN_B` không bị ghi ngoài ý muốn.

Runner E02 bắt đầu từ embedding checkpoint thật, nạp đủ 16 tensor encoder
layer 0 và dùng production shape. Probe A2 có run ID
`e02-probe100k-final-20260730-a2`, trạng thái
`probe_only_authoritative`; log:
[`vit_e02_layer0_real_logical_rtl_probe_e02-probe100k-final-20260730-a2.log`](../../build/test_logs/vit_e02_layer0_real_logical_rtl_probe_e02-probe100k-final-20260730-a2.log).

```text
cycles/commands/checkpoints = 100000 / 1 / 0
reads/writes                = 11330 / 2240
parameter/scratch reads     = 4481 / 6849
requests/responses          = 13570 / 13570
stalls/forced stalls        = 16 / 16
outstanding/invalid/failure = 0 / 0 / 0
```

Một full E02 legacy diagnostic cũng đã terminal đủ 20 command sau
7.636.573.461 cycle: 241 checks, `737.995.740R/4.876.932W`, trong đó
`701.323.008` PARAM read và `36.672.732` SCRATCH read. Comparator đủ 151.296
word có 141.857 exact mismatch nhưng 0 tolerance failure; max/mean absolute
error `4.529953003e-06`/`3.003772886e-07`. Log
[`vit_e02_layer0_real_logical_rtl_e2e_restart_o3.log`](../../build/test_logs/vit_e02_layer0_real_logical_rtl_e2e_restart_o3.log)
không có receipt/provenance binding với identity cuối, nên chỉ là
**supplemental legacy diagnostic**, không phải `pass_authoritative`.

Runner E03 nhận đúng một `VIT_E03_LAYER=1..11`, preload checkpoint layer trước
vào `HIDDEN_A`, nạp 16 tensor của layer được chọn và phát job
`first_layer=last_layer`. Probe A2 layer 1 có run ID
`e03-l01-probe100k-final-20260730-a2`, trạng thái
`probe_only_authoritative`; log:
[`vit_e03_layer01_real_logical_rtl_probe_e03-l01-probe100k-final-20260730-a2.log`](../../build/test_logs/vit_e03_layer01_real_logical_rtl_probe_e03-l01-probe100k-final-20260730-a2.log).

```text
cycles/checks/commands       = 100000 / 158 / 1
layer/parameter requests     = 1 / 1
reads/writes                 = 11331 / 2240
parameter/scratch reads      = 4482 / 6849
requests/responses           = 13571 / 13570
outstanding                  = 1
backpressure/invalid/failure = 30 / 0 / 0
```

Probe dừng có chủ đích trước terminal comparator 151.296 word; một response
còn outstanding tại điểm cắt không phải terminal phase. Đây chỉ là bằng
chứng preload/descriptor/address/handshake layer 1, không phải numerical PASS.
Layer 2..11 chưa có authoritative probe/comparator.

Parent E02/E03 harness hiện fail-closed trước build: package-v1 table được pin SHA-256;
parameter phải khớp exact line count, 8 hex/line, source/binary SHA-256,
offset và word-count của table; checkpoint trước/sau phải khớp manifest
ModelSim đã pin. Sequencer audit nhanh
so exact đủ 512 bit của cả 20 descriptor và tag/opcode/destination của cả 20
checkpoint. Full-run contract kiểm thứ tự duy nhất của 8 operand request,
valid/payload qua backpressure, exact `737.995.740` read
(`701.323.008 PARAM + 36.672.732 SCRATCH`) và `4.876.932` write, cùng
range/coverage vùng. Legacy full diagnostic đã khớp các số này nhưng không có
receipt cuối; probe A2 có marker riêng `PROBE_PASS`, và chỉ full comparator
có binding hợp lệ mới đủ điều kiện `pass_authoritative`.

`report_yosys_structural_proxy.sh` chỉ chạy `proc; opt; memory_collect; stat`,
không gọi `abc` hoặc `synth_xilinx`. Chỉ sau khi các test nhẹ ổn mới nên chạy
synthesis no-DSP trên máy đủ tài nguyên. Synthesis là bước xác nhận tài
nguyên, không phải test đầu tiên để tìm lỗi hierarchy/syntax. Revision hiện
tại chưa có Vivado synthesis/implementation; các PASS simulation không thay
thế gate `MAX_DSP=0`, `USE_DSP=NO` và kiểm primitive DSP trong netlist.

## 15. Các giới hạn hiện tại

1. M_AXI chỉ một beat và một outstanding nên băng thông DDR thấp. A-panel và
   bias cache giảm số request GEMM nhưng chưa che latency miss hoặc traffic B.
   Prototype selective line-fill đã PASS riêng nhưng chưa thuộc production;
   xem [`AXI_READ_LINEFILL_EXPERIMENT.md`](AXI_READ_LINEFILL_EXPERIMENT.md).
2. GEMM dùng một dot16 cho toàn tile. LUT giảm mạnh, latency tăng mạnh.
3. Vector dùng một lane cho 16 phần tử. Đây cũng là đổi throughput lấy LUT.
4. GELU dùng multiplier/adder toàn engine để replay graph tuần tự; LUT giảm
   mạnh nhưng latency mỗi vector tăng.
5. LayerNorm và Softmax cũng replay multiplier/adder toàn engine và đọc lại
   dữ liệu nhiều pass; latency/traffic đọc tăng.
6. Production có đúng một FP32 multiplier và một FP32 adder xuyên năm block;
   các arithmetic cục bộ chỉ tồn tại trong cấu hình standalone unit test.
7. Attention mask block có hỗ trợ nhưng sequencer không cấu hình mask tensor
   trong flow mặc định.
8. `EXECUTION_MODE[0]` chọn địa chỉ MODEL GEMM-B row-major (mode 0) hoặc
   blocked K16/N2 (mode 1) và được snapshot tại START. Mode 1 chỉ hợp lệ với
   package v2 cùng geometry production `PE_LANES=16`, `ARRAY_COLS=2`.
9. ABORT không hủy transaction; chỉ báo lỗi unsupported.
10. SOFT_RESET chỉ được nhận khi wrapper idle.
11. Checkpoint trong AXI wrapper hiện `ready=1` và metadata bị bỏ; chưa có
    checkpoint sink.
12. Parameter-loader handshake hiện `ready=1`; parameter được đọc
    trực tiếp qua logical memory, chưa có DMA/staging riêng.
13. Class register giữ kết quả gần nhất; chỉ coi là hợp lệ sau final flow
    thành công có argmax.
14. Custom FP32 có xấp xỉ và special-value policy riêng. E04 model-real đã
    được khóa bằng numerical tolerance; các phase encoder của full E05 vẫn
    cần regression tương tự trước khi đánh giá accuracy toàn model.
15. **[CẦN KIỂM CHỨNG]** timing, LUT, FF, BRAM, URAM và DSP=0 của revision
    hiện tại bằng post-synthesis/post-route report.
16. Compact E05 production hierarchy đã PASS, nhưng **[CẦN KIỂM CHỨNG]**
    full-size E05 end-to-end trên board với model/input package thực tế, bao
    gồm địa chỉ base và word limit do PS lập trình. Sequencer-only ViT-base
    và behavioral full flow không thay thế bằng chứng datapath này.
17. Tcl tạo Block Design đã có và qua kiểm tra cú pháp/metadata tĩnh, nhưng
    **[CẦN KIỂM CHỨNG]** `validate_bd_design`, generated wrapper, address map
    và clock/reset/IRQ trong Vivado trước khi synthesis board top; PS driver
    nạp package, lập trình AXI-Lite và xử lý IRQ cũng chưa hoàn tất.
18. Burst read-ahead không được bật toàn cục: GEMM-B row-major gather theo
    `stride3=N`; chỉ bật hint cho stream liên tục hoặc sau khi đóng gói B theo
    blocked layout.
19. Bản active snapshot của layer table đã được bỏ, giảm 6.144 bit storage.
    Bảng gốc cũng đã chuyển sang RAM `192×32` + loader tuần tự. Regression A4
    chỉ kiểm cấu trúc bằng Verilator XML, không synthesis-map RAM; primitive
    thật vẫn cần Vivado post-synthesis.
20. Audit source chưa thấy blocker synthesis, nhưng đường timing cần xem đầu
    tiên là priority/shift trong `vit_fp32_from_u32_comb` đi vào multiplier
    LUT dùng chung ở Softmax/GELU. Nếu WNS âm, ưu tiên thêm một state/register
    tại ranh giới conversion→multiply rồi chạy lại numerical regression.

## 16. Cách đọc report để tối ưu tiếp

Đọc hierarchical utilization theo top-down:

1. So sánh `u_gemm`, `u_vector`, `u_layout`, `u_layernorm`, `u_softmax`,
   `u_gelu`, `u_argmax`.
2. Xác nhận toàn `vit_phase_e_engine_top` chỉ có
   `u_engine_shared_multiplier` và `u_engine_shared_adder`. Với GEMM, cả
   multiplier lẫn hai adder local trong generate branch phải bị prune.
3. Nếu vẫn nhiều LUT trong GEMM, xem mantissa multiplier, normalization và
   mux/buffer tile; không tìm các PE song song vì chúng không còn tồn tại.
4. Với GELU, multiplier/adder local phải bị prune; xem mux/state register của
   serial core và phần central arithmetic ở engine top.
5. Với Softmax/LayerNorm, multiplier/adder local cũng phải bị prune; xem
   total-word multiplier, serial reciprocal của LayerNorm và state/mux của
   exp, reciprocal, rsqrt.
6. Với core/memory, xem GEMM address context 66 bit, phép cộng/overflow 96 bit,
   ba RAM cell A/bias cache, mux packed-vector và fanout. Production path
   hiện không cần runtime multiplier 32×32 của địa chỉ GEMM hoặc modulo
   channel của LayerNorm.
7. Đọc timing path cùng hierarchy. Kiểm trước
   `vit_fp32_from_u32_comb`→`u_engine_shared_multiplier` trong Softmax/GELU;
   một thiết kế ít LUT hơn vẫn có thể fail timing vì graph FP tổ hợp sâu.
8. Đối chiếu latency/throughput bằng simulation counter trước và sau mỗi thay
   đổi. Không tối ưu chỉ dựa trên tổng LUT.

Kế hoạch cache/ping-pong/AXI burst và công thức traffic nằm tại
[`GEMM_MEMORY_PIPELINE_PLAN.md`](GEMM_MEMORY_PIPELINE_PLAN.md).

## 17. Tài liệu chuẩn và tài liệu công cụ

Kiến trúc cụ thể của NPU phải lấy từ RTL trong repository; các nguồn ngoài
chỉ định nghĩa protocol/tool semantics:

- AMD Vivado Synthesis User Guide, thuộc tính
  [`USE_DSP`](https://docs.amd.com/r/en-US/ug901-vivado-synthesis/USE_DSP).
- AMD Vivado Synthesis User Guide,
  [memory inference capabilities](https://docs.amd.com/r/2022.2-English/ug901-vivado-synthesis/Memory-Inference-Capabilities).
- AMD Vivado Synthesis User Guide 2022.2,
  [SystemVerilog constructs](https://docs.amd.com/r/2022.2-English/ug901-vivado-synthesis/SystemVerilog-Constructs)
  và
  [system tasks/functions](https://docs.amd.com/r/2022.2-English/ug901-vivado-synthesis/Verilog-System-Tasks-and-Functions);
  đây là cơ sở kiểm package/struct/array và các parameter-check
  `initial $fatal/$error`.
- AMD Vivado Synthesis User Guide, synthesis Tcl và
  [`-max_dsp`](https://docs.amd.com/r/en-US/2026.1/ug901-vivado-synthesis/Running-Synthesis-with-Tcl).
- AMD Vivado IP Integrator User Guide,
  [`Referencing a Module`](https://docs.amd.com/r/2024.2-English/ug994-vivado-ip-subsystems/Referencing-a-Module).
- AMD Vivado IP Integrator User Guide,
  [supported `X_INTERFACE_*` attributes](https://docs.amd.com/r/en-US/ug994-vivado-ip-subsystems/List-of-Supported-X_-Attributes).
- Arm,
  [AMBA AXI and ACE Protocol Specification](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/IHI0022H_amba_axi_protocol_spec.pdf?hash=6325311012DDADF238C35A6C0FD734E520754F82&la=en&revision=71bd7c57-2ed7-487b-bc3e-68c4ab56fa5f).
- NVIDIA CUTLASS,
  [efficient GEMM and double buffering](https://docs.nvidia.com/cutlass/latest/media/docs/cpp/efficient_gemm.html).
- UC Berkeley,
  [Gemmini generator](https://github.com/ucb-bar/gemmini).
- IEEE,
  [IEEE 754-2019 Floating-Point Arithmetic](https://standards.ieee.org/ieee/754/6210/).

Project gốc ghi Vivado 2022.2, còn một số URL AMD ở trên mặc định mở bản tài
liệu mới hơn. **[CẦN KIỂM CHỨNG]** mọi khác biệt option/property nhạy theo
version với manual 2022.2 cài cùng tool trước khi thay Tcl/XDC.
