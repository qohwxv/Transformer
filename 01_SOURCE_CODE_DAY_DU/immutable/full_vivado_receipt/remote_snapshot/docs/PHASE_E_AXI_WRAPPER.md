# Phase-E AXI wrapper — Genesys ZU-5EV

## Trạng thái

Đường tích hợp đích trên board là:

```text
ZynqMP A53 software (board) / AXI BFM (simulation)
   |
   +-- M_AXI_HPM0_FPD --> SmartConnect --> NPU S_AXI (AXI4-Lite control)
   |
DDR <-- S_AXI_HP0_FPD <-- SmartConnect <-- NPU M_AXI (128-bit AXI4 data)
                                              |
                                    vit_phase_e_axi_mem_adapter
                                              |
                                    logical FP32-word requests
                                              |
                                    vit_phase_e_npu + engine
```

Bundle M5 không mang theo generated `vit_system.bd` hay project cache. Flow
Vivado 2023.2 tái tạo, validate và generate BD từ Tcl, rồi mới synthesize
`vit_system_wrapper`; vì vậy sơ đồ trên là contract phải được stage 30 xác
nhận lại cho đúng manifest M5. Cho đến khi run M5 hoàn tất, BD/route/BIT/XSA
M5 vẫn là `PENDING`, còn bằng chứng M4-R8 chỉ là provenance. Trên board, A53 chạy
phần mềm nạp DDR và điều khiển job; trong simulation, AXI BFM thay A53/DDR để
phát transaction. OOC top vẫn là `vit_phase_e_axi_bd_wrapper`.

`vit_phase_e_engine_top.sv` không còn ba array input/parameter/scratch khoảng
17 MiB. Một request native được gather tuần tự từ DDR; kết quả được scatter
tuần tự và engine chỉ nhận `result_ready` sau B response cuối.

M5 giữ logical request/response một FP32 word nhưng adapter gom các blocked
MODEL-B word liên tiếp vào full beat 128-bit và burst INCR tối đa bốn beat. Hai
read transaction có thể outstanding; request/response logical đều có FIFO sâu
hai. Chỉ luồng MODEL-B K16/N2 đã được frontend chứng minh contiguous mới được
read-ahead. Mọi write và mọi read khác vẫn là narrow scalar transfer trên bus
128-bit; không có write coalescing hay generic speculative prefetch.

A-panel cache R8 có tám bank 3.072-word, bias cache có một bank 3.072-word và
layer-table RAM đã có trong production; tổng payload A+bias là 110.592 byte
(108 KiB). M5 giảm số AR/R beat cho MODEL-B nhưng không giảm số logical word,
không thay FP32 operation order và không thêm B-tile cache/ping-pong compute
overlap. Vì vậy latency phải được đo lại bằng counter, không suy ra chỉ từ
traffic model. Vivado OOC/full route và physical E05 của exact M5 artifact vẫn
là gate bắt buộc trước khi tuyên bố timing, DSP hay speedup.

## Các file production

Theo đúng thứ tự compile trong
`filelists/vit_phase_e_axi_wrapper_synth.f`:

- `vit_phase_e_pkg.sv`
- `vit_fp32_pkg.sv`
- các compute engine synth
- `vit_phase_e_sequencer.sv`
- `vit_phase_e_engine_top.sv`
- `vit_phase_e_npu.sv`
- `rtl/axi/control/vit_layer_param_table.sv`
- `rtl/axi/control/vit_layer_param_loader.sv`
- `rtl/axi/control/vit_phase_e_perf_counters.sv`
- `rtl/axi/control/vit_phase_e_profile_counters.sv`
- `rtl/axi/control/vit_phase_e_m5_axi_counters.sv`
- `rtl/axi/control/vit_axi_lite_control_regs.sv`
- `vit_phase_e_axi_mem_adapter.sv`
- `vit_phase_e_axi_wrapper.sv`
- `vit_phase_e_axi_bd_wrapper.v`

Core RTL là `vit_phase_e_axi_wrapper`. IP Integrator dùng module Verilog mỏng
`vit_phase_e_axi_bd_wrapper` làm Module Reference shim; shim này chỉ nối thẳng
vào core, không chứa state hay datapath. Trong M5 shim khóa production geometry
`ARRAY_ROWS=8`, `ARRAY_COLS=2`, `PE_LANES=16`.

Không đưa các file sau vào synthesis closure:

- `tb_vit_phase_e.sv`
- `vit_phase_e_behavioral_engine_top.sv`
- `vit_fp32_math_ref_pkg.sv`

Chúng vẫn được giữ cho behavioral simulation.

Full production engine dùng chung đúng một
`vit_fp32_mul_comb_nodsp` và một `vit_fp32_add_comb`. Các generate branch
arithmetic cục bộ chỉ phục vụ unit test từng block và phải bị prune khỏi
production hierarchy. Static guard khóa hai owner này và cấm div/mod, nhưng
chỉ post-synthesis netlist của đúng source revision mới đủ để kết luận số
primitive DSP48/DSP58 bằng 0.

## Memory contract

Mọi địa chỉ trong descriptor và parameter table là offset FP32 word:

```text
AXI byte address = region physical base + (word offset << 2)
```

Mapping:

| Memory space | AXI-Lite base register | Limit register |
|---|---|---|
| PARAM/MODEL | `MODEL_BASE` | `MODEL_WORDS` |
| INPUT | `INPUT_BASE` | `INPUT_WORDS` |
| SCRATCH | `SCRATCH_BASE` | `SCRATCH_WORDS` |

Adapter kiểm tra space, limit, alignment, phép cộng 64-bit và
`AXI_ADDR_WIDTH`. Truy cập sai trả error về command, không phát AXI request.
Compute master chỉ được ghi SCRATCH; MODEL và INPUT là read-only đối với PL và
được PS nạp trực tiếp.

Engine cũng tính `base + stride/index` trên 96 bit trước khi tạo logical word
request. Nếu kết quả vượt quá 32-bit, command dừng với error; địa chỉ không bị
truncate/wrap sang đầu buffer. Regression `tb_vit_phase_e_engine_memory` có
test riêng cho cả read và write tại biên `0xffffffff + 1`.

Package model v1 legacy dùng:

- `MODEL_WORDS = 86,567,664` (`0x0528EAF0`);
- `INPUT_WORDS = 150,528`;
- `SCRATCH_WORDS = 0x001E6000`.

Quy cách đóng gói, tám global offsets và 12×16 layer offsets nằm trong
`docs/VIT_MODEL_PACKAGE_FORMAT_V1.md`. Có thể tạo binary bằng:

```bash
# Chạy trong repository phát triển đầy đủ, không phải bundle hardware-only.
cd <vit_modelsim_standalone>
python3 tools/pack_vit_assets.py
```

M3 thêm package v2 blocked-B FP32, không thay numerical bits:

- `MODEL_WORDS = 86,567,680` (`0x0528EB00`);
- `EXECUTION_MODE[0] = 1` phải được ghi trước START;
- `MODEL_BASE` và mọi tensor bắt đầu tại biên 128 byte;
- 74 persistent MODEL GEMM-B dùng `[N_TILE][K_CHUNK][COL][LANE]` K16/N2;
- 24 QK/PV GEMM-B trong SCRATCH vẫn row-major.

Contract và hash package v2 nằm tại
[`VIT_MODEL_PACKAGE_FORMAT_V2_BLOCKED_B_FP32.md`](VIT_MODEL_PACKAGE_FORMAT_V2_BLOCKED_B_FP32.md).

## AXI-Lite register map

| Offset | Register | Access |
|---:|---|---|
| `0x000` | IP_ID | RO |
| `0x004` | IP_VERSION | RO |
| `0x008` | CONTROL | WO pulse |
| `0x00C` | STATUS | RO |
| `0x010` | IRQ_ENABLE | RW |
| `0x014` | IRQ_STATUS | RW1C |
| `0x018` | ERROR_CODE | RO |
| `0x01C` | ERROR_INFO | RO |
| `0x020/024` | MODEL_BASE LO/HI | RW |
| `0x028/02C` | INPUT_BASE LO/HI | RW |
| `0x030/034` | SCRATCH_BASE LO/HI | RW |
| `0x038` | MODEL_WORDS | RW |
| `0x03C` | INPUT_WORDS | RW |
| `0x040` | SCRATCH_WORDS | RW |
| `0x044` | EXECUTION_MODE | RW; bit 0 selects M3 blocked-B MODEL package |
| `0x048` | PERF_CAPABILITY (`0x0001001F`) | RO |
| `0x04C` | PERF_STATUS | RO |
| `0x050/054` | JOB_CYCLES LO/HI | RO |
| `0x058/05C` | COMMANDS LO/HI | RO |
| `0x060/064` | AXI_READS LO/HI | RO |
| `0x068/06C` | AXI_WRITES LO/HI | RO |
| `0x070/074` | AXI_REQ_STALL_CYCLES LO/HI | RO |
| `0x080..09C` | GLOBAL_PARAM[0..7] | RW |
| `0x0A0` | JOB_CONFIG | RW |
| `0x0A4` | JOB_PATCH_A_BASE | RW |
| `0x180` | CLASS_INDEX | RO |
| `0x184` | CLASS_LOGIT | RO |
| `0x188` | PROFILE_CAPABILITY2 (`0x00027FFF`) | RO |
| `0x18C` | PROFILE_STATUS2 | RO |
| `0x190..19C` | global/opcode overflow masks | RO |
| `0x1A0..2FC` | PROFILE_GLOBAL[0..43] LO/HI | RO |
| `0x300..3FC` | OPCODE[0..15] count/cycles LO/HI | RO |
| `0x400..6FC` | LAYER_PARAM[12][16] | RW |
| `0x700..71C` | trace capability/select/status/data/error | RO; select RW |
| `0x720..7B4` | response-wait histogram capability/data | RO |
| `0x7C0..7CC` | M5 capability/status/overflow/typed protocol | RO |
| `0x7D0..80C` | eight M5 native-AXI counters LO/HI | RO |

`CONTROL`: bit 0 START, bit 1 SOFT_RESET, bit 2 ABORT, bit 3 CLEAR_ERROR.
SOFT_RESET chỉ được chấp nhận khi idle. AXI adapter không thể hủy an toàn một
transaction đã được DDR chấp nhận, nên ABORT trả lỗi explicit.

`STATUS`: bit 0 IDLE, bit 1 BUSY, bit 2 DONE sticky, bit 3 ERROR sticky,
bit 4 IRQ, bit 5 operand-load wait.

`IP_VERSION=0x00010006` identifies the M5 native-AXI128 child while retaining
M3 blocked-B support, R8 geometry and the complete append-only profile ABI
v1.2.
`EXECUTION_MODE[0]` is snapshotted on
an accepted START; later writes cannot alter the active job. The
board-passed frozen v1.0 core returns `0x00010000` and `SLVERR` for the new
performance window. ABI v1.2 retains the complete v1.1 window unchanged:
`PERF_CAPABILITY=0x0001001F`, five legacy counter bits `[4:0]`,
`PERF_STATUS[0]=RUNNING` and `PERF_STATUS[1]=SNAPSHOT_VALID`.

All counters are unsigned 64-bit values and wrap modulo `2^64`. An accepted
START clears the live and published banks, asserts RUNNING and clears
SNAPSHOT_VALID. The NPU DONE edge, including an error completion, publishes
all five next values atomically. The published LO/HI words then remain stable
until the next accepted START or reset, so software does not need a manual
snapshot command and cannot observe a torn pair.

Counter definitions are deliberately narrow and reproducible:

- JOB_CYCLES counts rising edges strictly after the accepted START edge up to
  and including the NPU DONE edge. It excludes PS downloads, AXI-Lite setup
  and software polling after completion.
- COMMANDS counts the exact sequencer-to-engine `valid && ready` descriptor
  handshake; it is independent of optional checkpoints.
- AXI_READS counts accepted M_AXI AR transactions. AXI_WRITES counts accepted
  M_AXI AW transactions. M5 AR transactions may contain up to four 128-bit
  beats; writes remain one narrow FP32 word.
- AXI_REQ_STALL_CYCLES increments once when any of AR, AW or W has VALID high
  and READY low. Simultaneous AW/W backpressure still counts as one cycle. It
  does not include R/B response latency or compute-idle cycles.

These counters cover only PL traffic caused by the accepted NPU job; PS model
and input preload traffic and AXI-Lite register traffic are excluded.

### Profile ABI v1.2

Profile v1.2 is implemented by a second counter block; it does not replace or
renumber the five legacy counters. The machine-readable authority is
[`PERF_PROFILE_ABI_V1_2.json`](PERF_PROFILE_ABI_V1_2.json). Every 64-bit
counter is published atomically on the same NPU DONE edge. Overflow masks and
typed error bits are sticky within a job and are published with the snapshot.

The 44 global counters cover logical read/write words; AXI R/W beats and B
responses; request/response wait and backpressure by channel; load, compute,
store, union and pairwise/three-way overlap cycles; A/bias cache lookup,
hit/miss and B-bypass events; GEMM tile steps plus valid/tail MAC slots; and
command, logical-response, AXI-response, job and trace-drop errors. Global
counter `i` is read at `0x1A0 + 8*i` (LO) and `+4` (HI).

Opcode slot `o` uses `0x300 + 16*o`: count LO/HI at `+0/+4` and active-cycle
LO/HI at `+8/+C`. The sum of all 16 opcode counts must equal COMMANDS; the sum
of opcode cycles must equal global command-active cycles. Command duration
excludes the accept edge and includes the terminal edge.

The command trace stores at most 256 entries of 96 bits (32-bit metadata plus
64-bit duration). A completed command beyond entry 255 increments
TRACE_DROPPED, sets TRUNCATED and never overwrites an earlier entry. Software
writes the 8-bit selector at `0x704`, then polls `TRACE_STATUS` until PENDING
is zero and VALID is one before reading metadata and duration. Selector writes
during a running profile return `SLVERR`.

The response-wait histogram has eight AR-to-first-R buckets and eight
AW-to-B buckets: `0`, `1`, `2–3`, `4–7`, `8–15`, `16–31`, `32–63`, and
`>=64` wait cycles. Entries 16 and 17 are the read/write maxima. The latency
counters saturate at `2^64-1`; corresponding maximum-overflow and typed error
bits are set rather than allowing a wrap to corrupt the maximum. In ABI v1.6,
read histogram population is AR transactions, not R beats; first R sets the
latency bucket and RLAST retires the corresponding outstanding transaction.

### M5 native-AXI profile ABI v1.6

The machine-readable composite authority is
[`PERF_PROFILE_ABI_V1_6.json`](PERF_PROFILE_ABI_V1_6.json). It preserves every
v1.2 address and appends capability `0x01F21008`, status, overflow, typed
protocol status and eight unsigned 64-bit counters:

| Counter | LO offset | Meaning |
|---|---:|---|
| `full_r_beats` | `0x7D0` | accepted full-width 128-bit read beats |
| `narrow_r_beats` | `0x7D8` | accepted narrow scalar read beats |
| `linefill_starts` | `0x7E0` | safe blocked-B linefills started |
| `linefill_hits` | `0x7E8` | logical words served from linefill cache |
| `four_k_splits` | `0x7F0` | linefills clamped/split at 4 KiB |
| `max_read_outstanding` | `0x7F8` | maximum simultaneous read transactions |
| `protocol_errors` | `0x800` | typed adapter-error event popcount |
| `prefetched_words_discarded` | `0x808` | fetched words never consumed logically |

The counters clear on accepted START and publish atomically on DONE. The full
E05 oracle expects discarded=0. Compact E05 expects discarded=16 because its
odd-N=7 classifier has a padded final line.

Read-ahead has a fail-closed protocol boundary. `RRESP`/`BRESP` response
errors drain normally. Structural RID/RLAST framing faults return ordered
logical errors for the active and already queued requests, then permanently
poison the adapter until reset. There is no watchdog and no guarantee that
already outstanding AXI traffic is drained, recovered or re-synchronized
after framing loss.

`JOB_CONFIG`:

| Bits | Field |
|---:|---|
| `[2:0]` | phase |
| `[6:3]` | first_layer |
| `[10:7]` | last_layer |
| `[11]` | class_softmax_enable |
| `[12]` | checkpoint_enable |
| `[20:13]` | job_tag |

START snapshot base, limit, job và global table. Bảng layer nằm trong
`vit_layer_param_table`, một RAM hai cổng `192×32`; FSM
`vit_layer_param_loader` đọc 16 word để tạo descriptor khi sequencer yêu cầu
một layer. Không còn flat register bus hoặc active snapshot 6.144 bit. Write
`0x400..0x6FC` trong lúc BUSY trả `SLVERR` và không đổi dữ liệu; readback vẫn
dùng được. ABI không đổi và phần mềm chỉ lập trình configuration khi IDLE.

## Regression không cần Vivado

Không cần mở Vivado:

```bash
cd <vivado_server_307_perf_v1_m5_axi128_burst_fp32_2023_2>

sim/control/run_perf_counters_iverilog.sh
sim/m5/run_iverilog.sh
sim/m5/run_m5_counter_regression.sh
sim/m5/run_axi128_ddr_model_seed_sweep.sh

iverilog -g2012 -s tb_vit_phase_e_axi_mem_adapter \
  -o /tmp/vit_axi_adapter.vvp \
  -f filelists/vit_phase_e_axi_mem_adapter_iverilog.f
vvp /tmp/vit_axi_adapter.vvp

iverilog -g2012 -s tb_vit_phase_e_engine_memory \
  -o /tmp/vit_engine_memory.vvp \
  -f filelists/vit_phase_e_engine_memory_iverilog.f
vvp /tmp/vit_engine_memory.vvp

iverilog -g2012 -s tb_vit_phase_e_engine_axi \
  -o /tmp/vit_engine_axi.vvp \
  -f filelists/vit_phase_e_engine_axi_iverilog.f
vvp /tmp/vit_engine_axi.vvp

iverilog -g2012 -s tb_vit_phase_e_axi_wrapper \
  -o /tmp/vit_axi_wrapper.vvp \
  -f filelists/vit_phase_e_axi_wrapper_iverilog.f
vvp /tmp/vit_axi_wrapper.vvp
```

Icarus 11 có thể in nhiều dòng `constant selects in always_*`; đó là thông
báo sensitivity-list, không phải test failure.

Kiểm riêng layer-table/control và regression production đầy đủ:

```bash
sim/control/run_layer_param_table_iverilog.sh
scripts/checks/check_layer_param_memory.sh
nice -n 10 scripts/checks/run_regression.sh
```

M4-R8 logs trong `evidence/m4_r8_2026-08-06/` chỉ chứng minh parent/provenance,
không thỏa gate M5. M5 local hiện có các kết quả `SIM-MEASURED` tập trung:

```text
native adapter + FIFO/protocol/tail/error  PASS, 409 checks
random raw-DDR + adapter integration       PASS, 8/8 seeds
M5 counter bank                           PASS, 58 checks
burst-aware profile queue                 PASS, 12 checks
profile counters v1.2                     PASS, 162 checks
AXI-Lite control v1.6 append-only         PASS, 418 checks
blocked-B read-ahead router               PASS, 2012 checks, 10 tail cases
production XSim suite                     PASS, 7/7
compact E05                               PASS, 249 commands, job=900581 cycles
real E04 final-source                     PASS, checks=168, cycles=29497114
real E01 final-source                     PASS, checks=159, cycles=424112402
```

Manifest đã khóa đúng 68-source identity trước server build. Compact E05 quan
sát đúng 16 discarded padded word; full E05 oracle là 0. Mọi OOC/full
route/BIT/XSA/board gate M5 hiện là `PENDING`. Compact và E04 tăng cycle mô
phỏng lần lượt 4,459758% và 4,401004% so với M4-R8, trong khi E01 nhiều
blocked-B giảm 4,205524202%. Simulation RTL không chứng minh utilization,
timing, DSP primitive hay physical-board speedup.

## Bước Vivado tiếp theo

Chưa bấm Run Implementation ngay.

Trước khi tạo/sửa Block Design, có thể kiểm riêng closure RTL+AXI bằng OOC
flow. Nó chọn thẳng đúng top, đặt clock 50 MHz, `MAX_DSP=0` và tạo
utilization/hierarchy/timing/DSP report:

```bash
VIT_VIVADO_THREADS=1 \
  vivado -mode batch -source scripts/vivado/run_rtl_synth_nodsp.tcl
```

1. Add/update mọi file trong `filelists/vit_phase_e_axi_wrapper_synth.f`.
2. Đặt `USED_IN_SYNTHESIS=false` cho behavioral engine, math-ref package và
   testbench.
3. Tạo Block Design với Zynq UltraScale+ MPSoC.
4. Bật PS master `M_AXI_HPM0_FPD`, qua SmartConnect tới `S_AXI` của NPU.
5. Bật PS slave `S_AXI_HP0_FPD`; nối native `M_AXI` 128-bit của NPU qua
   SmartConnect 128-bit tới port này để truy cập DDR. Xác nhận burst=4,
   read-outstanding=2 và write-outstanding=1 bằng report readback.
6. Add Module `vit_phase_e_axi_bd_wrapper`; Vivado sẽ nhận diện `S_AXI`,
   `M_AXI`, `aclk`, `aresetn` và `irq_o` từ interface attributes.
7. Nối tất cả vào `pl_clk0` 50 MHz và reset active-low từ
   `proc_sys_reset/peripheral_aresetn`.
8. Nối `irq_o` tới `pl_ps_irq0[0]`.
9. Assign 4 KiB address cho `S_AXI`, ví dụ `0xA0000000`.
10. Validate BD, Generate Output Products, Create HDL Wrapper.
11. Chạy **Run Synthesis** trước; xem utilization và timing. Chỉ khi synthesis
    không over-utilized và timing path có hướng xử lý rõ mới chạy
    Implementation.

Flow synthesis phải giữ `MAX_DSP=0`/`USE_DSP=NO` và chạy
`check_no_dsp.tcl`. Không dùng simulation, Yosys proxy hoặc report của
revision cũ để tuyên bố `DSP=0` cho bitstream.
