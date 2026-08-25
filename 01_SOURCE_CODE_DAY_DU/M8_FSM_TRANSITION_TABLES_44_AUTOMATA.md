# M8 NPU — FSM TRANSITION TABLES (44 reachable automata)
> Nguồn duy nhất: `FSM_ARCHITECTURE_MASTER_SOURCE_M8.md`. Chỉ giữ các automata reachable của exact M8; bỏ `NOAUT-*` và các FSM legacy `ELIM-*` không có trong post-synthesis hierarchy.
> **Quy ước Moore/Mealy:** hồ sơ G2 không phân loại các máy là Moore thuần hay Mealy thuần; tất cả được đánh dấu `MIXED_OR_PROTOCOL`. Vì vậy bảng dưới giữ cách phân loại bảo thủ này. Với explicit FSM, có thể vẽ state output theo Moore-like và ghi transition guard/input trên cạnh; với implicit automaton, vẽ mode/occupancy/valid tracker thay vì ép thành FSM Moore/Mealy cổ điển.
> Tổng hợp: **44 automata reachable**, **493 transition clauses duy nhất**.

## 1. `CM-HOST-JOB` — `vit_phase_e_axi_wrapper`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `implicit` |
| State register / tracker | `job_pending; recovery_required_q` |
| State encoding | `IDLE/PENDING/RUNNING/RECOVERY` |
| Clock / Reset | `aclk` / `aresetn (synchronous active-low)` |
| Moore / Mealy | Implicit protocol automaton — không nên ép thành Moore hoặc Mealy thuần; vẽ theo mode/occupancy/valid tracker + guard. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Host job snapshot/lifetime |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `0/ALL` | `!aresetn` | `IDLE, clear all wrapper-owned registers` | `CONTROL_RESET` | `!aresetn` |
| 2 | `1/any` | `clear_error_pulse` | `clear error/reject stickies; không clear recovery` | `CONTROL_ONLY` | `clear_error_pulse` |
| 3 | `2/IDLE` | `start_pulse && accept` | `snapshot all job fields; job_pending=1` | `JOB_SNAPSHOT` | `start_pulse && accept` |
| 4 | `2/not acceptable` | `start_pulse` | `reject priority BUSY > RESET_REQUIRED > EXECUTION_MODE > MODEL_ALIGNMENT` | `CONTROL_ONLY` | `start_pulse` |
| 5 | `3/PENDING` | `job_fire` | `job_pending=0; NPU captures job same edge` | `JOB_DISPATCH` | `job_fire` |
| 6 | `4/RUN` | `terminal && npu_error` | `sticky error, code/info; recovery_required_q=1` | `CONTROL_ONLY` | `terminal && npu_error` |
| 7 | `4/RUN` | `terminal && !npu_error` | `sticky done` | `CONTROL_ONLY` | `terminal && !npu_error` |
| 8 | `5/IDLE` | `soft_reset_pulse` | `clear pending/stickies/recovery directly; pulse local_reset_pulse one cycle` | `CONTROL_RESET` | `soft_reset_pulse` |
| 9 | `5/busy` | `soft_reset_pulse` | `BUSY error` | `CONTROL_ONLY` | `soft_reset_pulse` |
| 10 | `6/any` | `abort_pulse` | `unsupported-abort error` | `CONTROL_ONLY` | `abort_pulse` |
| 11 | `last` | `otherwise` | `hold` | `CONTROL_ONLY` | `otherwise` |

## 2. `CM-AXIL-WRITE` — `vit_axi_lite_control_regs`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `implicit` |
| State register / tracker | `awaddr_hold_valid; wdata_hold_valid; s_axi_bvalid` |
| State encoding | `EMPTY/CAPTURED/RESPONSE` |
| Clock / Reset | `aclk` / `aresetn (synchronous active-low)` |
| Moore / Mealy | Implicit protocol automaton — không nên ép thành Moore hoặc Mealy thuần; vẽ theo mode/occupancy/valid tracker + guard. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Join AW/W and hold B |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `any` | `rst` | `EMPTY` | `CONTROL_RESET` | `rst` |
| 2 | `EMPTY` | `aw_fire` | `FULL; latch AWADDR` | `CAPTURE_AW` | `aw_fire` |
| 3 | `FULL` | `write_commit` | `EMPTY` | `CONSUME_AW` | `write_commit` |
| 4 | `any` | `otherwise` | `hold` | `CONTROL_ONLY` | `otherwise` |
| 5 | `EMPTY` | `w_fire` | `FULL; latch WDATA/WSTRB` | `CAPTURE_W` | `w_fire` |
| 6 | `FULL` | `write_commit` | `EMPTY` | `CONSUME_W` | `write_commit` |
| 7 | `FULL` | `b_fire and no same-edge commit possible` | `EMPTY` | `RETIRE_B` | `b_fire and no same-edge commit possible` |
| 8 | `EMPTY` | `write_commit` | `FULL; BRESP=OKAY/SLVERR` | `COMMIT_REGISTER_OR_TABLE` | `write_commit` |

## 3. `CM-AXIL-READ` — `vit_axi_lite_control_regs`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `implicit` |
| State register / tracker | `s_axi_rvalid; layer_read_pending` |
| State encoding | `IDLE/TABLE_WAIT/RESPONSE` |
| Clock / Reset | `aclk` / `aresetn (synchronous active-low)` |
| Moore / Mealy | Implicit protocol automaton — không nên ép thành Moore hoặc Mealy thuần; vẽ theo mode/occupancy/valid tracker + guard. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Serialize control reads |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `any` | `rst` | `pending=0` | `CONTROL_RESET` | `rst` |
| 2 | `no-pending` | `ar_fire && layer_addr && aligned` | `pending=1; table A read enable/address` | `TABLE_READ_REQUEST` | `ar_fire && layer_addr && aligned` |
| 3 | `pending` | `table_read_data_valid_i` | `pending=0; publish R/OKAY` | `TABLE_READ_RETURN` | `table_read_data_valid_i` |
| 4 | `any` | `otherwise` | `hold` | `CONTROL_ONLY` | `otherwise` |
| 5 | `any` | `rst` | `EMPTY/data=0/OKAY` | `CONTROL_RESET` | `rst` |
| 6 | `FULL` | `r_fire` | `EMPTY` | `RETIRE_R` | `r_fire` |
| 7 | `EMPTY` | `ar_fire && (!aligned \|\| !supported)` | `FULL, zero/SLVERR` | `LOCAL_ERROR_RESPONSE` | `ar_fire && (!aligned \|\| !supported)` |
| 8 | `EMPTY` | `ar_fire && !layer_addr && legal` | `FULL, decoded data/OKAY` | `LOCAL_READ_RESPONSE` | `ar_fire && !layer_addr && legal` |
| 9 | `EMPTY` | `pending and table_read_data_valid_i` | `FULL, table data/OKAY` | `TABLE_READ_RETURN` | `pending and table_read_data_valid_i` |

## 4. `CM-IRQ-STICKY` — `vit_axi_lite_control_regs`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `implicit` |
| State register / tracker | `irq_status_o` |
| State encoding | `bitwise sticky; event wins RW1C` |
| Clock / Reset | `aclk` / `aresetn (synchronous active-low)` |
| Moore / Mealy | Implicit protocol automaton — không nên ép thành Moore hoặc Mealy thuần; vẽ theo mode/occupancy/valid tracker + guard. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Retain IRQ causes |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `any` | `!aresetn` | `0` | `CONTROL_RESET` | `!aresetn` |
| 2 | `any` | `otherwise` | `(old & ~irq_clear_mask) \| irq_event_i` | `STICKY_EVENT_UPDATE` | `otherwise` |

## 5. `CM-SEQUENCER` — `vit_phase_e_sequencer`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `explicit` |
| State register / tracker | `state` |
| State encoding | `SEQ_IDLE,SEQ_LOAD_LAYER,SEQ_ISSUE,SEQ_WAIT_COMMAND,SEQ_CHECKPOINT,SEQ_ADVANCE,SEQ_DONE` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | MIXED / protocol — khi vẽ: state-qualified outputs có thể xem là Moore-like; guard/input quyết định transition và registered micro-op là Mealy-controlled. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Issue layer/phase commands |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `ALL` | `rst` | `IDLE, clear` | `CONTROL_RESET` | `rst` |
| 2 | `IDLE` | `no job` | `hold` | `CONTROL_ONLY` | `no job` |
| 3 | `IDLE` | `valid E01/E04` | `ISSUE, section EMBEDDING/FINAL` | `JOB_CONTEXT_LOAD` | `valid E01/E04` |
| 4 | `IDLE` | `valid E02/E03/E05 encoder start` | `LOAD_LAYER or initial ISSUE` | `JOB_CONTEXT_LOAD` | `valid E02/E03/E05 encoder start` |
| 5 | `IDLE` | `bad phase/layer/zero E05 layers` | `DONE; typed error` | `LOCAL_ERROR` | `bad phase/layer/zero E05 layers` |
| 6 | `LOAD_LAYER` | `layer_param_valid` | `latch params,step=0,ISSUE` | `LAYER_PARAM_CAPTURE` | `layer_param_valid` |
| 7 | `LOAD_LAYER` | `otherwise` | `hold` | `CONTROL_ONLY` | `otherwise` |
| 8 | `ISSUE` | `cmd_ready` | `WAIT_COMMAND` | `COMMAND_DISPATCH` | `cmd_ready` |
| 9 | `ISSUE` | `otherwise` | `hold command` | `CONTROL_ONLY` | `otherwise` |
| 10 | `WAIT_COMMAND` | `cmd_error` | `DONE; command error context` | `CONTROL_ONLY` | `cmd_error` |
| 11 | `WAIT_COMMAND` | `!cmd_error&&cmd_done&&checkpoint_enable` | `CHECKPOINT` | `CONTROL_ONLY` | `!cmd_error&&cmd_done&&checkpoint_enable` |
| 12 | `WAIT_COMMAND` | `!cmd_error&&cmd_done&&!checkpoint_enable` | `ADVANCE` | `CONTROL_ONLY` | `!cmd_error&&cmd_done&&!checkpoint_enable` |
| 13 | `WAIT_COMMAND` | `otherwise` | `hold` | `CONTROL_ONLY` | `otherwise` |
| 14 | `CHECKPOINT` | `ready` | `ADVANCE` | `CHECKPOINT_TRANSFER` | `ready` |
| 15 | `CHECKPOINT` | `otherwise` | `hold` | `CONTROL_ONLY` | `otherwise` |
| 16 | `ADVANCE` | `section-specific next step/layer/section` | `ISSUE/LOAD_LAYER/DONE` | `CURSOR_ADVANCE` | `section-specific next step/layer/section` |
| 17 | `ADVANCE` | `illegal section` | `DONE; bad-phase error` | `LOCAL_ERROR` | `illegal section` |
| 18 | `DONE` | `unconditional` | `IDLE` | `CONTROL_ONLY` | `unconditional` |
| 19 | `illegal state` | `default` | `DONE; bad-phase error` | `ILLEGAL_RECOVER` | `default` |

## 6. `CM-COMMAND` — `vit_phase_e_command_controller`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `explicit` |
| State register / tracker | `state` |
| State encoding | `STATE_IDLE,STATE_WAIT_PARAMETER,STATE_LAUNCH,STATE_EXECUTE,STATE_REPORT` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | MIXED / protocol — khi vẽ: state-qualified outputs có thể xem là Moore-like; guard/input quyết định transition và registered micro-op là Mealy-controlled. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Dispatch one command |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `ALL` | `rst` | `IDLE, clear all` | `CONTROL_RESET` | `rst` |
| 2 | `IDLE` | `cmd_valid & needs-param` | `latch cmd,clear report error,WAIT_PARAMETER` | `COMMAND_CAPTURE` | `cmd_valid & needs-param` |
| 3 | `IDLE` | `cmd_valid & !needs-param` | `latch cmd,clear error,LAUNCH` | `COMMAND_CAPTURE` | `cmd_valid & !needs-param` |
| 4 | `IDLE` | `otherwise` | `hold` | `CONTROL_ONLY` | `otherwise` |
| 5 | `WAIT_PARAMETER` | `ready` | `LAUNCH` | `PARAMETER_GATE_RELEASE` | `ready` |
| 6 | `WAIT_PARAMETER` | `otherwise` | `hold` | `CONTROL_ONLY` | `otherwise` |
| 7 | `LAUNCH` | `invalid opcode` | `report_error=1,REPORT` | `LOCAL_ERROR` | `invalid opcode` |
| 8 | `LAUNCH` | `valid opcode` | `EXECUTE` | `ENGINE_LAUNCH` | `valid opcode` |
| 9 | `EXECUTE` | `memory_error_latched` | `report_error=1,REPORT` | `CONTROL_ONLY` | `memory_error_latched` |
| 10 | `EXECUTE` | `!memory error & selected_done` | `report_error=selected_error,REPORT` | `CONTROL_ONLY` | `!memory error & selected_done` |
| 11 | `EXECUTE` | `otherwise` | `hold` | `CONTROL_ONLY` | `otherwise` |
| 12 | `REPORT` | `unconditional` | `pulse done xor error,IDLE` | `COMMAND_RETIRE` | `unconditional` |
| 13 | `illegal` | `default` | `report_error=1,REPORT` | `ILLEGAL_RECOVER` | `default` |

## 7. `CM-LAYER-LOADER` — `vit_layer_param_loader`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `explicit` |
| State register / tracker | `state` |
| State encoding | `LOAD_IDLE,LOAD_RUN,LOAD_RESPONSE,LOAD_WAIT_RELEASE` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | MIXED / protocol — khi vẽ: state-qualified outputs có thể xem là Moore-like; guard/input quyết định transition và registered micro-op là Mealy-controlled. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Load layer descriptor |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `ALL` | `rst` | `IDLE, clear` | `CONTROL_RESET` | `rst` |
| 2 | `IDLE` | `request_i && index_ok` | `RUN; latch index; clear counts/data` | `BEGIN_LAYER_LOAD` | `request_i && index_ok` |
| 3 | `IDLE` | `request_i && !index_ok` | `RESPONSE with zero data` | `LOCAL_ZERO_RESPONSE` | `request_i && !index_ok` |
| 4 | `IDLE` | `otherwise` | `hold` | `CONTROL_ONLY` | `otherwise` |
| 5 | `RUN` | `req_fire` | `issue_count++` | `TABLE_B_READ_REQUEST` | `req_fire` |
| 6 | `RUN` | `rsp_fire && !last_rsp` | `shift data; receive_count++` | `GATHER_WORD` | `rsp_fire && !last_rsp` |
| 7 | `RUN` | `rsp_fire && last_rsp` | `shift final data; RESPONSE` | `GATHER_FINAL_WORD` | `rsp_fire && last_rsp` |
| 8 | `RESPONSE` | `unconditional` | `WAIT_RELEASE` | `CONTROL_ONLY` | `unconditional` |
| 9 | `WAIT_RELEASE` | `!request_i` | `IDLE` | `CONTROL_ONLY` | `!request_i` |
| 10 | `WAIT_RELEASE` | `otherwise` | `hold` | `CONTROL_ONLY` | `otherwise` |
| 11 | `illegal` | `default` | `IDLE` | `ILLEGAL_RECOVER` | `default` |

## 8. `CM-LAYER-TABLE` — `vit_layer_param_table`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `implicit` |
| State register / tracker | `word_valid; a_word_valid; a_rvalid_o; b_word_valid; b_rvalid_o` |
| State encoding | `INVALID/VALID; IDLE/PENDING` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | Implicit protocol automaton — không nên ép thành Moore hoặc Mealy thuần; vẽ theo mode/occupancy/valid tracker + guard. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Own table validity/read latency |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `any` | `rst` | `IDLE; valid/data sideband clear` | `CONTROL_RESET` | `rst` |
| 2 | `any` | `a_req` | `PULSE; sample old RAM and validity; optionally write bytes/set valid` | `TABLE_A_READ_FIRST_ACCESS` | `a_req` |
| 3 | `any` | `!a_req` | `IDLE; data holds` | `CONTROL_ONLY` | `!a_req` |
| 4 | `any` | `rst` | `IDLE` | `CONTROL_RESET` | `rst` |
| 5 | `any` | `b_req` | `PULSE; sample old RAM/validity` | `TABLE_B_READ` | `b_req` |
| 6 | `any` | `!b_req` | `IDLE; data holds` | `CONTROL_ONLY` | `!b_req` |

## 9. `CM-PERF-EPOCH` — `vit_phase_e_perf_counters`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `implicit` |
| State register / tracker | `running_o; snapshot_valid_o; live_job_cycles; live_command_count; live_axi_read_count; live_axi_write_count; live_axi_request_stall_cycles; job_cycles_o; command_count_o; axi_read_count_o; axi_write_count_o; axi_request_stall_cycles_o` |
| State encoding | `IDLE/RUNNING/PUBLISHED` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | Implicit protocol automaton — không nên ép thành Moore hoặc Mealy thuần; vẽ theo mode/occupancy/valid tracker + guard. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Publish performance counters |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `any` | `rst` | `EMPTY; all zero` | `CONTROL_RESET` | `rst` |
| 2 | `any` | `start` | `RUN; clear live/published/snapshot` | `EPOCH_START` | `start` |
| 3 | `RUN` | `done` | `PUBLISHED; live increments; publish live+edge_delta` | `EPOCH_PUBLISH` | `done` |
| 4 | `RUN` | `!done` | `RUN; add event deltas` | `COUNTER_ACCUMULATE` | `!done` |
| 5 | `EMPTY/PUBLISHED` | `no start` | `hold` | `CONTROL_ONLY` | `no start` |

## 10. `CM-PROFILE-EPOCH` — `vit_phase_e_profile_counters`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `implicit` |
| State register / tracker | `profile_running_o; profile_snapshot_valid_o; global_live; global_published; opcode_count_live; opcode_count_published; opcode_cycle_live; opcode_cycle_published; histogram_live; histogram_published; error_status_live; error_status_published` |
| State encoding | `IDLE/RUNNING/PUBLISHED` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | Implicit protocol automaton — không nên ép thành Moore hoặc Mealy thuần; vẽ theo mode/occupancy/valid tracker + guard. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Publish profile counters |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `any` | `rst` | `EMPTY; clear all registered banks/trackers` | `CONTROL_RESET` | `rst` |
| 2 | `any` | `start` | `RUN; clear live/published/status/trackers` | `PROFILE_EPOCH_START` | `start` |
| 3 | `RUN` | `done` | `PUBLISHED; update live and atomically copy all next banks` | `PROFILE_EPOCH_PUBLISH` | `done` |
| 4 | `RUN` | `!done` | `RUN; commit all next live banks` | `PROFILE_ACCUMULATE` | `!done` |
| 5 | `EMPTY/PUBLISHED` | `no start` | `hold published data` | `CONTROL_ONLY` | `no start` |

## 11. `CM-PROFILE-TRACE` — `vit_phase_e_profile_counters`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `implicit` |
| State register / tracker | `trace_count_live; trace_count_o; trace_truncated_live; trace_truncated_o; trace_read_address; trace_read_pending_o; trace_selected_valid_o` |
| State encoding | `EMPTY/CAPTURING/FULL; IDLE/PENDING/VALID` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | Implicit protocol automaton — không nên ép thành Moore hoặc Mealy thuần; vẽ theo mode/occupancy/valid tracker + guard. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Trace capture/read ownership |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `inactive` | `cmd_accept, with or without same-edge cmd_complete` | `active; latch opcode/tag/section/layer/step;duration=0; simultaneous cmd_complete also sets ERROR_COMPLETE_WITHOUT_ACTIVE because the pre-edge tracker was inactive; no trace is stored` | `TRACE_COMMAND_CLAIM + optional TRACE_PROTOCOL_ERROR` | `cmd_accept, with or without same-edge cmd_complete` |
| 2 | `active` | `trace_completion, with or without same-edge cmd_accept` | `inactive; optionally write old bound metadata to RAM/count++; reset duration; simultaneous accept also sets ERROR_ACCEPT_WHILE_ACTIVE` | `TRACE_COMMAND_COMMIT + optional TRACE_PROTOCOL_ERROR` | `trace_completion, with or without same-edge cmd_accept` |
| 3 | `active` | `!trace_completion && cmd_accept` | `metadata does not overwrite; duration ages; set ERROR_ACCEPT_WHILE_ACTIVE` | `TRACE_COMMAND_AGE + TRACE_PROTOCOL_ERROR` | `!trace_completion && cmd_accept` |
| 4 | `active` | `!trace_completion && !cmd_accept` | `duration=duration+1 modulo 2^64; at max it wraps to zero and sets sticky duration-overflow` | `TRACE_COMMAND_AGE` | `!trace_completion && !cmd_accept` |
| 5 | `inactive` | `!cmd_accept && cmd_complete` | `stay inactive; set ERROR_COMPLETE_WITHOUT_ACTIVE` | `TRACE_PROTOCOL_ERROR` | `!cmd_accept && cmd_complete` |
| 6 | `inactive` | `no accept/cmd_complete` | `hold` | `CONTROL_ONLY` | `no accept/cmd_complete` |
| 7 | `0` | `AR and RLAST same edge, legacy alias inactive` | `remain0; sample zero-cycle first-R latency; no queue debt` | `AR_LATENCY_ZERO_CYCLE_RETIRE` | `AR and RLAST same edge, legacy alias inactive` |
| 8 | `0` | `AR and RLAST same edge, legacy alias active` | `count remains0, but alias active/wait retain their old values; histogram samples the pre-edge alias wait` | `AR_LATENCY_ALIAS_ZERO_CYCLE_RETIRE` | `AR and RLAST same edge, legacy alias active` |
| 9 | `0` | `AR and nonlast R same edge` | `1; slot0 wait0,first_seen0=1` | `AR_LATENCY_PUSH_SEEN` | `AR and nonlast R same edge` |
| 10 | `0` | `AR and no R beat` | `1; slot0 wait0,first_seen0=0` | `AR_LATENCY_PUSH` | `AR and no R beat` |
| 11 | `0` | `R beat without AR and read_latency_active=0` | `remain0; set ERROR_R_WITHOUT_AR; no queue mutation` | `TRACE_PROTOCOL_ERROR` | `R beat without AR and read_latency_active=0` |
| 12 | `0` | `R beat without AR and legacy alias read_latency_active=1` | `remain0; clear alias/wait; compatibility-only saturation-test recovery` | `AR_LATENCY_ALIAS_CLEAR` | `R beat without AR and legacy alias read_latency_active=1` |
| 13 | `0` | `no AR/R beat` | `remain0` | `CONTROL_ONLY` | `no AR/R beat` |
| 14 | `1` | `RLAST + AR` | `remain1; retire old head and replace it with new unseen slot0` | `AR_LATENCY_EXCHANGE` | `RLAST + AR` |
| 15 | `1` | `RLAST without AR` | `0; clear head` | `AR_LATENCY_POP` | `RLAST without AR` |
| 16 | `1` | `nonlast R + AR` | `2; mark slot0 seen and initialize unseen slot1` | `AR_FIRST_R_OBSERVE + AR_LATENCY_PUSH` | `nonlast R + AR` |
| 17 | `1` | `nonlast R without AR` | `remain1; mark slot0 seen; histogram samples old wait if first beat` | `AR_FIRST_R_OBSERVE` | `nonlast R without AR` |
| 18 | `1` | `AR without R beat` | `2; initialize unseen slot1` | `AR_LATENCY_PUSH` | `AR without R beat` |
| 19 | `1` | `no AR/R beat` | `remain1; age every unseen slot, saturating` | `LATENCY_AGE` | `no AR/R beat` |
| 20 | `2` | `RLAST + AR` | `remain2; retire head, shift slot1→slot0 and fill new unseen slot1` | `AR_LATENCY_SHIFT_PUSH` | `RLAST + AR` |
| 21 | `2` | `RLAST without AR` | `1; retire head and shift slot1→slot0` | `AR_LATENCY_SHIFT` | `RLAST without AR` |
| 22 | `2` | `nonlast R + AR` | `remain2; mark head seen; drop new AR tracker and set overflow error` | `AR_FIRST_R_OBSERVE + TRACE_PROTOCOL_ERROR` | `nonlast R + AR` |
| 23 | `2` | `nonlast R without AR` | `remain2; mark head seen if first beat` | `AR_FIRST_R_OBSERVE` | `nonlast R without AR` |
| 24 | `2` | `AR without R beat` | `remain2; drop new tracker entry and set overflow error` | `TRACE_PROTOCOL_ERROR` | `AR without R beat` |
| 25 | `2` | `no AR/R beat` | `remain2; age every unseen slot, saturating` | `LATENCY_AGE` | `no AR/R beat` |
| 26 | `active` | `B response, with or without same-edge write accept` | `inactive,wait0; histogram samples old active wait; simultaneous accept also sets ERROR_AW_WHILE_ACTIVE` | `B_LATENCY_RETIRE + optional TRACE_PROTOCOL_ERROR` | `B response, with or without same-edge write accept` |
| 27 | `inactive` | `B response + same-edge write accept` | `inactive,wait0 because the later B block wins; histogram samples zero; neither without-AW nor accept-while-active error fires` | `B_LATENCY_START_RETIRE` | `B response + same-edge write accept` |
| 28 | `inactive` | `B response without write accept` | `remain inactive,wait0; set ERROR_B_WITHOUT_AW; do not add a latency histogram sample` | `TRACE_PROTOCOL_ERROR` | `B response without write accept` |
| 29 | `active` | `no B response && write accept` | `active,wait0; set ERROR_AW_WHILE_ACTIVE` | `B_LATENCY_START + TRACE_PROTOCOL_ERROR` | `no B response && write accept` |
| 30 | `inactive` | `no B response && write accept` | `active,wait0` | `B_LATENCY_START` | `no B response && write accept` |
| 31 | `active` | `no B response/accept && B-wait` | `wait++/saturate` | `LATENCY_AGE` | `no B response/accept && B-wait` |
| 32 | `any` | `otherwise` | `hold` | `CONTROL_ONLY` | `otherwise` |
| 33 | `any` | `rst or START` | `idle,selected invalid/data0` | `CONTROL_RESET` | `rst or START` |
| 34 | `any` | `selector strobe` | `pending=1; latch address; selected_valid=0` | `TRACE_READ_REQUEST` | `selector strobe` |
| 35 | `pending` | `no new strobe` | `pending=0; if published/in-range latch RAM+valid else zero/invalid` | `TRACE_READ_RETURN` | `no new strobe` |
| 36 | `idle` | `otherwise` | `hold` | `CONTROL_ONLY` | `otherwise` |

## 12. `CM-M5-EPOCH` — `vit_phase_e_m5_axi_counters`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `implicit` |
| State register / tracker | `running_o; snapshot_valid_o; live; published; overflow_live; overflow_published; protocol_error_live; protocol_error_published` |
| State encoding | `IDLE/RUNNING/PUBLISHED` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | Implicit protocol automaton — không nên ép thành Moore hoặc Mealy thuần; vẽ theo mode/occupancy/valid tracker + guard. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | M5 traffic counters |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `any` | `rst` | `EMPTY; clear banks/status` | `CONTROL_RESET` | `rst` |
| 2 | `any` | `start` | `RUN; clear live/published/status` | `M5_EPOCH_START` | `start` |
| 3 | `RUN` | `done` | `PUBLISHED; commit live next and publish same next/status` | `M5_EPOCH_PUBLISH` | `done` |
| 4 | `RUN` | `!done` | `RUN; commit next live/status` | `M5_ACCUMULATE` | `!done` |
| 5 | `EMPTY/PUBLISHED` | `no start` | `hold` | `CONTROL_ONLY` | `no start` |

## 13. `CM-M7-EPOCH` — `vit_phase_e_m7_overlap_counters`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `implicit` |
| State register / tracker | `running_o; snapshot_valid_o; live; published; overflow_live; overflow_published; error_live; error_published; claim_seen_live; claim_seen_published` |
| State encoding | `IDLE/RUNNING/PUBLISHED` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | Implicit protocol automaton — không nên ép thành Moore hoặc Mealy thuần; vẽ theo mode/occupancy/valid tracker + guard. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | M7 overlap counters |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `any` | `rst` | `EMPTY; clear banks/status/claims` | `CONTROL_RESET` | `rst` |
| 2 | `any` | `start` | `RUN; clear live/published/status/claims` | `M7_EPOCH_START` | `start` |
| 3 | `RUN` | `done` | `PUBLISHED; commit and publish all next/error/claim values` | `M7_EPOCH_PUBLISH` | `done` |
| 4 | `RUN` | `!done` | `RUN; commit live next/error/claims` | `M7_ACCUMULATE` | `!done` |
| 5 | `EMPTY/PUBLISHED` | `no start` | `hold` | `CONTROL_ONLY` | `no start` |

## 14. `CM-AXI-MASTER` — `vit_phase_e_axi_mem_adapter`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `explicit` |
| State register / tracker | `state` |
| State encoding | `STATE_IDLE,STATE_SCALAR_READ_ADDRESS,STATE_SCALAR_READ_DATA,STATE_LINE_FILL,STATE_WRITE_ISSUE,STATE_WRITE_RESPONSE,STATE_LOCAL_RESPONSE,STATE_POISON_RESPONSE,STATE_POISON_FLUSH,STATE_POISON` |
| Clock / Reset | `aclk` / `aresetn (synchronous active-low)` |
| Moore / Mealy | MIXED / protocol — khi vẽ: state-qualified outputs có thể xem là Moore-like; guard/input quyết định transition và registered micro-op là Mealy-controlled. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Native AXI transaction phases |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `ALL` | `!aresetn` | `IDLE; clear` | `CONTROL_RESET` | `!aresetn` |
| 2 | `IDLE` | `no req_core_start` | `hold` | `CONTROL_ONLY` | `no req_core_start` |
| 3 | `IDLE` | `invalid logical request` | `LOCAL_RESPONSE,error=1` | `LOCAL_ERROR_RESPONSE` | `invalid logical request` |
| 4 | `IDLE` | `line hit` | `LOCAL_RESPONSE,data=line word` | `LINE_HIT_RESPONSE` | `line hit` |
| 5 | `IDLE` | `legal linefill` | `initialize descriptors,LINE_FILL` | `LINEFILL_START` | `legal linefill` |
| 6 | `IDLE` | `legal write` | `latch lane data/strobe;WRITE_ISSUE` | `WRITE_PREPARE` | `legal write` |
| 7 | `IDLE` | `otherwise legal read` | `SCALAR_READ_ADDRESS` | `READ_PREPARE` | `otherwise legal read` |
| 8 | `SCALAR_READ_ADDRESS` | `AR fire` | `outstanding=1;SCALAR_READ_DATA` | `AXI_AR_ISSUE` | `AR fire` |
| 9 | `SCALAR_READ_ADDRESS` | `otherwise` | `hold` | `CONTROL_ONLY` | `otherwise` |
| 10 | `SCALAR_READ_DATA` | `no R fire` | `hold` | `CONTROL_ONLY` | `no R fire` |
| 11 | `SCALAR_READ_DATA` | `R fire, bad ID or !RLAST` | `POISON_RESPONSE,error` | `AXI_R_FRAMING_ERROR` | `R fire, bad ID or !RLAST` |
| 12 | `SCALAR_READ_DATA` | `R fire, framing good` | `LOCAL_RESPONSE; lane data; RRESP status` | `AXI_R_RETIRE` | `R fire, framing good` |
| 13 | `LINE_FILL` | `exact tracker relation` | `LOCAL_RESPONSE or POISON_RESPONSE` | `LINEFILL_ACCESS` | `exact tracker relation` |
| 14 | `WRITE_ISSUE` | `independent AW/W fires until both complete` | `WRITE_RESPONSE` | `AXI_AW_W_ISSUE` | `independent AW/W fires until both complete` |
| 15 | `WRITE_RESPONSE` | `B fire` | `LOCAL_RESPONSE; BRESP/BID status` | `AXI_B_RETIRE` | `B fire` |
| 16 | `LOCAL_RESPONSE` | `rsp_complete` | `IDLE` | `LOGICAL_RESPONSE_RETIRE` | `rsp_complete` |
| 17 | `POISON_RESPONSE` | `rsp_complete` | `POISON_FLUSH` | `POISON_TOKEN_RETIRE` | `rsp_complete` |
| 18 | `POISON_FLUSH` | `req FIFO empty` | `POISON` | `POISON_DRAIN_COMPLETE` | `req FIFO empty` |
| 19 | `POISON_FLUSH` | `otherwise` | `hold while one queued token may flush` | `POISON_FLUSH_TOKEN` | `otherwise` |
| 20 | `POISON` | `always` | `hold terminal` | `CONTROL_ONLY` | `always` |
| 21 | `illegal` | `default` | `POISON_RESPONSE,error; invalidate line` | `ILLEGAL_RECOVER` | `default` |

## 15. `CM-AXI-REQ-FIFO` — `vit_phase_e_axi_mem_adapter`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `implicit` |
| State register / tracker | `req_fifo_read_pointer; req_fifo_write_pointer; req_fifo_count` |
| State encoding | `EMPTY/PARTIAL/FULL` |
| Clock / Reset | `aclk` / `aresetn (synchronous active-low)` |
| Moore / Mealy | Implicit protocol automaton — không nên ép thành Moore hoặc Mealy thuần; vẽ theo mode/occupancy/valid tracker + guard. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Buffer logical requests |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `any` | `reset` | `0,pointers=0` | `CONTROL_RESET` | `reset` |
| 2 | `0/1` | `10` | `count+1; write payload/base/size; toggle WP` | `REQ_FIFO_PUSH` | `10` |
| 3 | `1/2` | `01` | `count-1; toggle RP` | `REQ_FIFO_POP` | `01` |
| 4 | `1/2` | `11` | `count hold; both pointers toggle; replace tail while consuming head` | `REQ_FIFO_EXCHANGE` | `11` |
| 5 | `any` | `00` | `hold` | `CONTROL_ONLY` | `00` |

## 16. `CM-AXI-RSP-FIFO` — `vit_phase_e_axi_mem_adapter`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `implicit` |
| State register / tracker | `rsp_fifo_read_pointer; rsp_fifo_write_pointer; rsp_fifo_count` |
| State encoding | `EMPTY/PARTIAL/FULL` |
| Clock / Reset | `aclk` / `aresetn (synchronous active-low)` |
| Moore / Mealy | Implicit protocol automaton — không nên ép thành Moore hoặc Mealy thuần; vẽ theo mode/occupancy/valid tracker + guard. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Buffer logical responses |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `any` | `reset` | `0,pointers/data/error clear` | `CONTROL_RESET` | `reset` |
| 2 | `0/1` | `10` | `count+1; write data/error; toggle WP` | `RSP_FIFO_PUSH` | `10` |
| 3 | `1/2` | `01` | `count-1; toggle RP` | `RSP_FIFO_POP` | `01` |
| 4 | `1/2` | `11` | `count hold; replace tail while retiring head` | `RSP_FIFO_EXCHANGE` | `11` |
| 5 | `any` | `00` | `hold` | `CONTROL_ONLY` | `00` |

## 17. `CM-AXI-LINEFILL` — `vit_phase_e_axi_mem_adapter`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `implicit` |
| State register / tracker | `fill_burst_count; fill_ar_issue_index; fill_ar_accepted_count; fill_r_burst_index; fill_r_completed_count; fill_r_beat_index; fill_error; fill_discard` |
| State encoding | `IDLE/ISSUING/OUTSTANDING/COLLECTING/COMPLETE` |
| Clock / Reset | `aclk` / `aresetn (synchronous active-low)` |
| Moore / Mealy | Implicit protocol automaton — không nên ép thành Moore hoặc Mealy thuần; vẽ theo mode/occupancy/valid tracker + guard. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Track two same-ID bursts |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `inactive` | `linefill admission` | `write 1/2 descriptors; indices/counts=0; invalidate old line` | `LINEFILL_CLAIM` | `linefill admission` |
| 2 | `active` | `ar_fire` | `issue_index++,accepted_count++` | `AXI_BURST_AR_ISSUE` | `ar_fire` |
| 3 | `active` | `r_fire && framing_error` | `line invalid,error token,main POISON_RESPONSE` | `LINEFILL_FRAMING_ERROR` | `r_fire && framing_error` |
| 4 | `active` | `r_fire&&!framing_error&&!RLAST` | `store four words; beat_index++` | `LINEFILL_BEAT_STORE` | `r_fire&&!framing_error&&!RLAST` |
| 5 | `active` | `good RLAST,more descriptor` | `store;completed++;burst_index++;beat=0` | `LINEFILL_BURST_RETIRE` | `good RLAST,more descriptor` |
| 6 | `active` | `final RLAST but accepted/completed totals mismatch` | `POISON_RESPONSE` | `LINEFILL_ACCOUNTING_ERROR` | `final RLAST but accepted/completed totals mismatch` |
| 7 | `active` | `final clean accounting` | `line valid iff no final error; main LOCAL_RESPONSE` | `LINEFILL_COMMIT` | `final clean accounting` |
| 8 | `active` | `cache invalidate` | `fill_discard=1,fill_error=1; continue draining` | `LINEFILL_DISCARD_MARK` | `cache invalidate` |
| 9 | `inactive` | `line hit request` | `consumed bitmap bit set` | `LINE_HIT_CONSUME` | `line hit request` |
| 10 | `any` | `otherwise` | `hold` | `CONTROL_ONLY` | `otherwise` |

## 18. `CM-MEM-FRONTEND` — `vit_phase_e_memory_frontend`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `explicit` |
| State register / tracker | `mem_state` |
| State encoding | `MEM_IDLE,MEM_READ_SELECT,MEM_READ_REQUEST,MEM_READ_RESPONSE,MEM_CACHE_RESPONSE,MEM_READ_DELIVER,MEM_WRITE_SELECT,MEM_WRITE_REQUEST,MEM_WRITE_RESPONSE,MEM_WRITE_DELIVER,MEM_GEMM_A_VECTOR_PRIME,MEM_GEMM_A_VECTOR_RUN,MEM_GEMM_A_VECTOR_DRAIN` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | MIXED / protocol — khi vẽ: state-qualified outputs có thể xem là Moore-like; guard/input quyết định transition và registered micro-op là Mealy-controlled. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Route engine/GEMM memory |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `IDLE/arbitration` | `load_req and not packed store-turn tie` | `READ_SELECT or VECTOR_PRIME; clear operand buffers` | `BEGIN_OPERAND_LOAD` | `load_req and not packed store-turn tie` |
| 2 | `IDLE/arbitration` | `packed simultaneous load/store first tie` | `load; set store-turn` | `ROUND_ROBIN_LOAD` | `packed simultaneous load/store first tie` |
| 3 | `IDLE/arbitration` | `store_req, packed defer eligible` | `IDLE; set defer once` | `CONTROL_ONLY` | `store_req, packed defer eligible` |
| 4 | `IDLE/arbitration` | `store_req otherwise` | `snapshot result ownership; WRITE_SELECT; Argmax→WRITE_DELIVER` | `BEGIN_RESULT_STORE` | `store_req otherwise` |
| 5 | `IDLE` | `otherwise` | `hold/index=0` | `CONTROL_ONLY` | `otherwise` |
| 6 | `READ_SELECT` | `candidate overflow` | `latch error, IDLE` | `LOCAL_ERROR` | `candidate overflow` |
| 7 | `READ_SELECT` | `A/bias cache hit` | `CACHE_RESPONSE` | `CACHE_READ_REQUEST` | `A/bias cache hit` |
| 8 | `READ_SELECT` | `no physical word` | `increment or READ_DELIVER` | `ZERO_OR_SKIP_WORD` | `no physical word` |
| 9 | `READ_SELECT` | `physical candidate` | `READ_REQUEST` | `CONTROL_ONLY` | `physical candidate` |
| 10 | `READ_REQUEST` | `mem_req_fire` | `READ_RESPONSE` | `LOGICAL_READ_REQUEST` | `mem_req_fire` |
| 11 | `READ_RESPONSE` | `no response` | `hold` | `CONTROL_ONLY` | `no response` |
| 12 | `READ_RESPONSE` | `response error` | `latch error, IDLE` | `LOCAL_ERROR` | `response error` |
| 13 | `READ_RESPONSE` | `good response` | `gather word; increment→READ_SELECT or READ_DELIVER` | `GATHER_OPERAND_WORD` | `good response` |
| 14 | `CACHE_RESPONSE` | `A valid else bias valid` | `gather; increment/select or deliver` | `GATHER_CACHE_WORD` | `A valid else bias valid` |
| 15 | `READ_DELIVER` | `unconditional` | `IDLE; optionally mark A-cache valid` | `OPERAND_BUNDLE_DELIVER` | `unconditional` |
| 16 | `VECTOR PRIME/RUN/DRAIN` | `exact lane/valid guards` | `issue/capture rows; error→IDLE; finally READ_SELECT at B words` | `VECTOR_CACHE_GATHER` | `exact lane/valid guards` |
| 17 | `WRITE_SELECT` | `address overflow` | `latch error,IDLE` | `LOCAL_ERROR` | `address overflow` |
| 18 | `WRITE_SELECT` | `no physical word` | `increment or WRITE_DELIVER` | `SKIP_WRITE_WORD` | `no physical word` |
| 19 | `WRITE_SELECT` | `candidate` | `WRITE_REQUEST` | `CONTROL_ONLY` | `candidate` |
| 20 | `WRITE_REQUEST` | `mem_req_fire` | `WRITE_RESPONSE` | `LOGICAL_WRITE_REQUEST` | `mem_req_fire` |
| 21 | `WRITE_RESPONSE` | `response error` | `latch error,IDLE` | `LOCAL_ERROR` | `response error` |
| 22 | `WRITE_RESPONSE` | `good response` | `increment/select or WRITE_DELIVER` | `RETIRE_STORE_WORD` | `good response` |
| 23 | `WRITE_DELIVER` | `opcode GEMM and gemm_bias_cache_allowed && !gemm_bias_cache_valid && gemm_result_batch_index_store_q==0 && gemm_result_token_base_store_q==0 && ({1'b0,gemm_result_output_base_store_q}+33'(ARRAY_COLS))>={1'b0,active_cmd.dim3}` | `set gemm_bias_cache_valid=1; IDLE` | `BIAS_CACHE_OWNERSHIP_COMMIT` | `opcode GEMM and gemm_bias_cache_allowed && !gemm_bias_cache_valid && gemm_result_batch_index_store_q==0 && gemm_result_token_base_store_q==0 && ({1'b0,gemm_result_output_base_store_q}+33'(ARRAY_COLS))>={1'b0,active_cmd.dim3}` |
| 24 | `WRITE_DELIVER` | `complement of the exact bias-commit guard` | `IDLE; bias-valid holds` | `RESULT_HANDSHAKE` | `complement of the exact bias-commit guard` |
| 25 | `illegal` | `default` | `IDLE` | `ILLEGAL_RECOVER` | `default` |

## 19. `CM-GEMM-PREFETCH` — `vit_phase_e_memory_frontend`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `implicit` |
| State register / tracker | `gemm_a_vector_issue_lane_q; gemm_a_vector_response_lane_q; gemm_a_vector_request_active_q; gemm_a_vector_row_valid_q` |
| State encoding | `IDLE/ISSUE/WAIT/ROW_VALID` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | Implicit protocol automaton — không nên ép thành Moore hoặc Mealy thuần; vẽ theo mode/occupancy/valid tracker + guard. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Packed A prefetch progress |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `inactive` | `GEMM load admission and vector-path hit` | `snapshot coordinates/row-valid; lane counters=0; request-active=1; enter PRIME` | `PREFETCH_CLAIM` | `GEMM load admission and vector-path hit` |
| 2 | `PRIME` | `K-tail lane invalid` | `jump to first packed-B word/READ_SELECT` | `PREFETCH_ZERO_TAIL` | `K-tail lane invalid` |
| 3 | `PRIME` | `final issue lane` | `record response lane; enter DRAIN` | `PREFETCH_FINAL_ISSUE` | `final issue lane` |
| 4 | `PRIME` | `more lanes` | `issue lane++; enter RUN` | `PREFETCH_ISSUE` | `more lanes` |
| 5 | `RUN` | `response valid and more lanes` | `capture all valid rows; advance issue/response lanes` | `PREFETCH_CAPTURE_ISSUE` | `response valid and more lanes` |
| 6 | `RUN` | `response valid and final lane` | `capture; enter DRAIN` | `PREFETCH_CAPTURE_FINAL` | `response valid and final lane` |
| 7 | `RUN/DRAIN` | `response missing when required` | `latch memory error; invalidate A; IDLE` | `PREFETCH_RESPONSE_ERROR` | `response missing when required` |
| 8 | `DRAIN` | `response valid` | `capture final rows; request-active=0 later at deliver; READ_SELECT at B` | `PREFETCH_DRAIN` | `response valid` |
| 9 | `active` | `live coordinates differ from snapshot` | `latch coordinate error; IDLE` | `PREFETCH_COORDINATE_ERROR` | `live coordinates differ from snapshot` |

## 20. `CM-GEMM-STORE-ARB` — `vit_phase_e_memory_frontend`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `implicit` |
| State register / tracker | `gemm_packed_store_turn_q; gemm_packed_result_defer_q; gemm_result_address_base_store_q; gemm_result_generation_store_q; gemm_result_token_base_store_q; gemm_result_output_base_store_q; gemm_result_batch_index_store_q` |
| State encoding | `DIRECT/DEFERRED/TURN` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | Implicit protocol automaton — không nên ép thành Moore hoặc Mealy thuần; vẽ theo mode/occupancy/valid tracker + guard. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Packed store arbitration |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `IDLE` | `packed simultaneous load/store and turn=0` | `admit load; set store-turn=1; clear defer` | `STORE_ARB_LOAD_TURN` | `packed simultaneous load/store and turn=0` |
| 2 | `IDLE` | `packed simultaneous load/store and turn=1` | `admit store; clear turn/defer; snapshot destination/generation` | `STORE_ARB_STORE_TURN` | `packed simultaneous load/store and turn=1` |
| 3 | `IDLE` | `packed store alone, turn=0,defer=0` | `remain IDLE; set defer once` | `STORE_ARB_DEFER_ONCE` | `packed store alone, turn=0,defer=0` |
| 4 | `IDLE` | `store otherwise` | `snapshot address/generation/token/output/batch; WRITE_SELECT` | `STORE_OWNERSHIP_CLAIM` | `store otherwise` |
| 5 | `owned write path` | `all live fields equal snapshot` | `hold snapshot` | `CONTROL_ONLY` | `all live fields equal snapshot` |
| 6 | `admission/write` | `generation/address/coordinate mismatch` | `frontend error, abandon IDLE` | `STORE_OWNERSHIP_ERROR` | `generation/address/coordinate mismatch` |
| 7 | `WRITE_DELIVER` | `unconditional` | `release by returning IDLE; stale snapshot is no longer owned` | `STORE_OWNERSHIP_RELEASE` | `unconditional` |

## 21. `CM-GEMM-CACHE-OWNERSHIP` — `vit_phase_e_memory_frontend`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `implicit` |
| State register / tracker | `gemm_a_cache_valid; gemm_a_cache_batch_tag; gemm_a_cache_token_tag; gemm_bias_cache_valid; gemm_bias_cache_column` |
| State encoding | `INVALID/VALID with tags` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | Implicit protocol automaton — không nên ép thành Moore hoặc Mealy thuần; vẽ theo mode/occupancy/valid tracker + guard. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Cache hit ownership |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `any` | `reset/command_accept` | `A-valid=0,bias-valid=0` | `CACHE_OWNERSHIP_CLEAR` | `reset/command_accept` |
| 2 | `A invalid/tag changed at first output/K` | `new load admission` | `invalidate A; latch batch/token tags` | `A_CACHE_OWNERSHIP_CLAIM` | `new load admission` |
| 3 | `A filling` | `successful responses` | `write cache words; ownership not yet valid` | `A_CACHE_FILL` | `successful responses` |
| 4 | `A filling` | `final safe K delivery` | `A-valid=1` | `A_CACHE_OWNERSHIP_COMMIT` | `final safe K delivery` |
| 5 | `bias invalid` | `first batch/token bias responses` | `fill bias RAM` | `BIAS_CACHE_FILL` | `first batch/token bias responses` |
| 6 | `bias invalid` | `final safe first batch/token store` | `bias-valid=1` | `BIAS_CACHE_OWNERSHIP_COMMIT` | `final safe first batch/token store` |
| 7 | `any` | `old memory_error_latched observed by quarantine, or generation/coordinate top-level error` | `clear both cache-valid bits; A vector request ownership clears` | `CACHE_OWNERSHIP_ABORT` | `old memory_error_latched observed by quarantine, or generation/coordinate top-level error` |
| 8 | `A vector active` | `gemm_a_vector_response_error in RUN/DRAIN` | `clear A-valid and vector request ownership in the same edge; latch memory error` | `A_CACHE_OWNERSHIP_ABORT` | `gemm_a_vector_response_error in RUN/DRAIN` |
| 9 | `any` | `otherwise` | `hold` | `CONTROL_ONLY` | `otherwise` |

## 22. `CM-GEMM-ADDR-CONTEXT` — `vit_gemm_memory_address_context`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `implicit` |
| State register / tracker | `context_valid; previous_token_base; previous_output_base; previous_k_base; previous_batch_index; activation_address_base; weight_address_base; bias_address_base; result_address_base` |
| State encoding | `INVALID/CURRENT/PREVIOUS` |
| Clock / Reset | `clk` / `rst (synchronous active-high); clear active-high` |
| Moore / Mealy | Implicit protocol automaton — không nên ép thành Moore hoặc Mealy thuần; vẽ theo mode/occupancy/valid tracker + guard. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Retain GEMM address contexts |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `any` | `rst or clear` | `invalidate; zero all bases/previous coords` | `CONTROL_RESET` | `rst or clear` |
| 2 | `invalid` | `request_start` | `set valid; initialize all bases from descriptor` | `ADDRESS_CONTEXT_INIT` | `request_start` |
| 3 | `valid` | `request_start & batch changed` | `increment batch bases; reset child bases` | `ADDRESS_BATCH_ADVANCE` | `request_start & batch changed` |
| 4 | `valid` | `else token changed` | `advance token bases; reset weight/bias child` | `ADDRESS_TOKEN_ADVANCE` | `else token changed` |
| 5 | `valid` | `else output changed` | `reset A; advance B/bias/result tile bases` | `ADDRESS_OUTPUT_ADVANCE` | `else output changed` |
| 6 | `valid` | `else K changed & rewound` | `restore tile-local A/B bases` | `ADDRESS_K_REWIND` | `else K changed & rewound` |
| 7 | `valid` | `else K changed forward` | `advance A/B by packed/blocked/stride rule` | `ADDRESS_K_ADVANCE` | `else K changed forward` |
| 8 | `any` | `otherwise` | `hold` | `CONTROL_ONLY` | `otherwise` |

## 23. `CM-ACT-CACHE-READ` — `vit_gemm_activation_panel_cache`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `implicit` |
| State register / tracker | `read_data_valid; vector_read_data_valid; read_row_hold` |
| State encoding | `IDLE/REQUEST/VALID` |
| Clock / Reset | `clk` / `rst (synchronous active-high); clear active-high` |
| Moore / Mealy | Implicit protocol automaton — không nên ép thành Moore hoặc Mealy thuần; vẽ theo mode/occupancy/valid tracker + guard. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Activation-cache read latency |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `any` | `rst/clear` | `scalar/vector valid=0; row hold=0` | `CONTROL_RESET` | `rst/clear` |
| 2 | `any` | `vector_read_enable` | `vector valid=1 next cycle; all banks read shared K` | `A_CACHE_VECTOR_READ` | `vector_read_enable` |
| 3 | `any` | `scalar read & !vector` | `scalar valid=1 next cycle; latch row/read selected bank` | `A_CACHE_SCALAR_READ` | `scalar read & !vector` |
| 4 | `any` | `no read` | `both valid=0; data registers hold` | `CONTROL_ONLY` | `no read` |

## 24. `CM-BIAS-CACHE-READ` — `vit_gemm_bias_cache`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `implicit` |
| State register / tracker | `read_data_valid; read_data` |
| State encoding | `IDLE/REQUEST/VALID` |
| Clock / Reset | `clk` / `rst (synchronous active-high); clear active-high` |
| Moore / Mealy | Implicit protocol automaton — không nên ép thành Moore hoặc Mealy thuần; vẽ theo mode/occupancy/valid tracker + guard. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Bias-cache read latency |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `any` | `rst/clear` | `read valid/data=0` | `CONTROL_RESET` | `rst/clear` |
| 2 | `any` | `read_enable` | `read valid=1 next cycle; sample indexed word` | `BIAS_CACHE_READ` | `read_enable` |
| 3 | `any` | `write_enable` | `update indexed word; may coincide with read` | `BIAS_CACHE_WRITE` | `write_enable` |
| 4 | `any` | `no read` | `read valid=0; data holds` | `CONTROL_ONLY` | `no read` |

## 25. `CE-GEMM-SCHED` — `vit_gemm_fp16_parallel_scheduler`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `explicit` |
| State register / tracker | `state` |
| State encoding | `STATE_IDLE,STATE_REQUEST_CHUNK,STATE_START_TILE,STATE_SEND_CHUNK,STATE_WAIT_RESULT,STATE_PACK_WAIT_FIRST,STATE_PACK_START_TILE,STATE_PACK_WAIT_PANEL,STATE_PACK_SEND_CHUNK,STATE_PACK_WAIT_RESULT,STATE_PACK_DRAIN_RESULT,STATE_DONE` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | MIXED / protocol — khi vẽ: state-qualified outputs có thể xem là Moore-like; guard/input quyết định transition và registered micro-op là Mealy-controlled. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Schedule chunks/panels/results |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `STATE_IDLE` | `Any batch/M/K/N zero -> error,DONE.` | `STATE_DONE` | `token_base; output_base; k_base; batch_index; config_error_q; fallback_column_q; panel_state_q[0]; panel_state_q[1]; load_request_active_q; load_bank_q; compute_bank_q; next_load_k_q; all_chunks_loaded_q; active_m; active_k; active_n; active_batch_count; active_bias_enable; active_weight_fp16_packed2; active_result_generation` | `Any batch/M/K/N zero -> error,DONE.` |
| 2 | `STATE_IDLE` | `packed flag -> PACK_WAIT_FIRST, otherwise REQUEST_CHUNK.` | `STATE_PACK_WAIT_FIRST` | `token_base; output_base; k_base; batch_index; config_error_q; fallback_column_q; panel_state_q[0]; panel_state_q[1]; load_request_active_q; load_bank_q; compute_bank_q; next_load_k_q; all_chunks_loaded_q; active_m; active_k; active_n; active_batch_count; active_bias_enable; active_weight_fp16_packed2; active_result_generation` | `packed flag -> PACK_WAIT_FIRST, otherwise REQUEST_CHUNK.` |
| 3 | `STATE_IDLE` | `packed flag -> PACK_WAIT_FIRST, otherwise REQUEST_CHUNK.` | `STATE_REQUEST_CHUNK` | `token_base; output_base; k_base; batch_index; config_error_q; fallback_column_q; panel_state_q[0]; panel_state_q[1]; load_request_active_q; load_bank_q; compute_bank_q; next_load_k_q; all_chunks_loaded_q; active_m; active_k; active_n; active_batch_count; active_bias_enable; active_weight_fp16_packed2; active_result_generation` | `packed flag -> PACK_WAIT_FIRST, otherwise REQUEST_CHUNK.` |
| 4 | `STATE_REQUEST_CHUNK` | `k_base==0 -> START_TILE` | `STATE_START_TILE` | `activation_q; weight_q; bias_q` | `k_base==0 -> START_TILE` |
| 5 | `STATE_REQUEST_CHUNK` | `otherwise SEND_CHUNK.` | `STATE_SEND_CHUNK` | `activation_q; weight_q; bias_q` | `otherwise SEND_CHUNK.` |
| 6 | `STATE_START_TILE` | `ready -> SEND_CHUNK` | `STATE_SEND_CHUNK` | `CONTROL_ONLY` | `ready -> SEND_CHUNK` |
| 7 | `STATE_SEND_CHUNK` | `fire,last -> WAIT_RESULT.` | `STATE_WAIT_RESULT` | `k_base` | `fire,last -> WAIT_RESULT.` |
| 8 | `STATE_SEND_CHUNK` | `Fire,not-last: k+=16 -> REQUEST_CHUNK.` | `STATE_REQUEST_CHUNK` | `k_base` | `Fire,not-last: k+=16 -> REQUEST_CHUNK.` |
| 9 | `STATE_PACK_WAIT_FIRST` | `latch compute owner -> PACK_START_TILE.` | `STATE_PACK_START_TILE` | `compute_bank_q` | `latch compute owner -> PACK_START_TILE.` |
| 10 | `STATE_PACK_START_TILE` | `ready: selected bank READY->COMPUTE -> PACK_SEND_CHUNK.` | `STATE_PACK_SEND_CHUNK` | `panel_state_q[compute_bank_q]` | `ready: selected bank READY->COMPUTE -> PACK_SEND_CHUNK.` |
| 11 | `STATE_PACK_WAIT_PANEL` | `claim selected READY->COMPUTE -> PACK_SEND_CHUNK.` | `STATE_PACK_SEND_CHUNK` | `compute_bank_q; panel_state_q[ready_bank_select]` | `claim selected READY->COMPUTE -> PACK_SEND_CHUNK.` |
| 12 | `STATE_PACK_SEND_CHUNK` | `last panel -> PACK_WAIT_RESULT, otherwise PACK_WAIT_PANEL.` | `STATE_PACK_WAIT_RESULT` | `panel_state_q[compute_bank_q]` | `last panel -> PACK_WAIT_RESULT, otherwise PACK_WAIT_PANEL.` |
| 13 | `STATE_PACK_SEND_CHUNK` | `last panel -> PACK_WAIT_RESULT, otherwise PACK_WAIT_PANEL.` | `STATE_PACK_WAIT_PANEL` | `panel_state_q[compute_bank_q]` | `last panel -> PACK_WAIT_RESULT, otherwise PACK_WAIT_PANEL.` |
| 14 | `STATE_PACK_WAIT_RESULT` | `if FIFO empty or single entry pops same edge -> DONE, else DRAIN.` | `STATE_DONE` | `config_error_q; panel_state_q[0]; panel_state_q[1]; load_request_active_q; all_chunks_loaded_q; load_bank_q; compute_bank_q; next_load_k_q; k_base; fallback_column_q; output_base; token_base; batch_index` | `if FIFO empty or single entry pops same edge -> DONE, else DRAIN.` |
| 15 | `STATE_PACK_WAIT_RESULT` | `Highest priority poisoned valid: set error, stop/free producer; if FIFO empty or single entry pops same edge -> DONE, else DRAIN. Else fifo_push_fire: reset panel-load context/K. First S8 pass with col1 -> fallback and WAIT_FIRST; final tile -> DRAIN; else advance output/token/batch -> WAIT_FIRST. Otherwise self (including FIFO-full stall).` | `STATE_PACK_DRAIN_RESULT` | `config_error_q; panel_state_q[0]; panel_state_q[1]; load_request_active_q; all_chunks_loaded_q; load_bank_q; compute_bank_q; next_load_k_q; k_base; fallback_column_q; output_base; token_base; batch_index` | `Highest priority poisoned valid: set error, stop/free producer; if FIFO empty or single entry pops same edge -> DONE, else DRAIN. Else fifo_push_fire: reset panel-load context/K. First S8 pass with col1 -> fallback and WAIT_FIRST; final tile -> DRAIN; else advance output/token/batch -> WAIT_FIRST. Otherwise self (including FIFO-full stall).` |
| 16 | `STATE_PACK_WAIT_RESULT` | `Highest priority poisoned valid: set error, stop/free producer; if FIFO empty or single entry pops same edge -> DONE, else DRAIN. Else fifo_push_fire: reset panel-load context/K. First S8 pass with col1 -> fallback and WAIT_FIRST; final tile -> DRAIN; else advance output/token/batch -> WAIT_FIRST. Otherwise self (including FIFO-full stall).` | `STATE_PACK_WAIT_FIRST` | `config_error_q; panel_state_q[0]; panel_state_q[1]; load_request_active_q; all_chunks_loaded_q; load_bank_q; compute_bank_q; next_load_k_q; k_base; fallback_column_q; output_base; token_base; batch_index` | `Highest priority poisoned valid: set error, stop/free producer; if FIFO empty or single entry pops same edge -> DONE, else DRAIN. Else fifo_push_fire: reset panel-load context/K. First S8 pass with col1 -> fallback and WAIT_FIRST; final tile -> DRAIN; else advance output/token/batch -> WAIT_FIRST. Otherwise self (including FIFO-full stall).` |
| 17 | `STATE_PACK_DRAIN_RESULT` | `Only fifo_pop_fire && occupancy==1: final old head accepted, clear context -> DONE` | `STATE_DONE` | `panel_state_q[0]; panel_state_q[1]; load_request_active_q; load_bank_q; compute_bank_q; next_load_k_q; all_chunks_loaded_q; k_base` | `Only fifo_pop_fire && occupancy==1: final old head accepted, clear context -> DONE` |
| 18 | `STATE_WAIT_RESULT` | `Highest priority bridge_valid&&numerical_error: consume internally, set error -> DONE.` | `STATE_DONE` | `config_error_q; k_base; fallback_column_q; output_base; token_base; batch_index` | `Highest priority bridge_valid&&numerical_error: consume internally, set error -> DONE.` |
| 19 | `STATE_WAIT_RESULT` | `final -> DONE.` | `STATE_DONE` | `config_error_q; k_base; fallback_column_q; output_base; token_base; batch_index` | `final -> DONE.` |
| 20 | `STATE_WAIT_RESULT` | `Highest priority bridge_valid&&numerical_error: consume internally, set error -> DONE. Else bridge_valid&&result_ready: k=0; for S8 first pass with valid col1 set fallback -> REQUEST; else advance output by 2, then token by 8, then batch; final -> DONE. Otherwise self; clean result_valid is held by bridge.` | `STATE_REQUEST_CHUNK` | `config_error_q; k_base; fallback_column_q; output_base; token_base; batch_index` | `Highest priority bridge_valid&&numerical_error: consume internally, set error -> DONE. Else bridge_valid&&result_ready: k=0; for S8 first pass with valid col1 set fallback -> REQUEST; else advance output by 2, then token by 8, then batch; final -> DONE. Otherwise self; clean result_valid is held by bridge.` |
| 21 | `STATE_DONE` | `free panels/cancel producer/clear all-loaded -> IDLE.` | `STATE_IDLE` | `panel_state_q[0]; panel_state_q[1]; load_request_active_q; all_chunks_loaded_q` | `free panels/cancel producer/clear all-loaded -> IDLE.` |

## 26. `CE-GEMM-PANEL[0..1]` — `vit_gemm_fp16_parallel_scheduler`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `explicit` |
| State register / tracker | `panel_state_q[0:1]` |
| State encoding | `PANEL_FREE,PANEL_RESERVED,PANEL_READY,PANEL_COMPUTE` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | MIXED / protocol — khi vẽ: state-qualified outputs có thể xem là Moore-like; guard/input quyết định transition và registered micro-op là Mealy-controlled. G2: MIXED_OR_PROTOCOL; exact registered side effects listed; MIXED_OR_PROTOCOL; synchronous registered reset side effects listed |
| Purpose | Own two physical panels |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `PANEL_FREE` | `In a packed load-active main state, if no request is outstanding, not all chunks loaded, and selected free: producer writes command coordinates/K/batch/last, latches load bank, sets request active, bank -> RESERVED. Free selector prefers bank0.` | `SOURCE ASSIGNMENTS TO PANEL_FREE` | `panel_state_q[0:1]` | `In a packed load-active main state, if no request is outstanding, not all chunks loaded, and selected free: producer writes command coordinates/K/batch/last, latches load bank, sets request active, bank -> RESERVED. Free selector prefers bank0.` |
| 2 | `PANEL_RESERVED` | `data_valid: write the selected bank payload, bank -> READY, clear request; update all-loaded or next-load-K. No data: self. Cleanup/reset -> FREE.` | `SOURCE ASSIGNMENTS TO PANEL_RESERVED` | `panel_state_q[0:1]` | `data_valid: write the selected bank payload, bank -> READY, clear request; update all-loaded or next-load-K. No data: self. Cleanup/reset -> FREE.` |
| 3 | `PANEL_READY` | `WAIT_FIRST selects READY and records compute bank, but transition to COMPUTE occurs in PACK_START only when bridge start-ready. WAIT_PANEL selects and sets COMPUTE on the claim edge. Cleanup -> FREE.` | `SOURCE ASSIGNMENTS TO PANEL_READY` | `panel_state_q[0:1]` | `WAIT_FIRST selects READY and records compute bank, but transition to COMPUTE occurs in PACK_START only when bridge start-ready. WAIT_PANEL selects and sets COMPUTE on the claim edge. Cleanup -> FREE.` |
| 4 | `PANEL_COMPUTE` | `PACK_SEND + bridge chunk-ready: release -> FREE and advance to WAIT_PANEL or WAIT_RESULT. No ready: self/stable. Cleanup -> FREE.` | `SOURCE ASSIGNMENTS TO PANEL_COMPUTE` | `panel_state_q[0:1]` | `PACK_SEND + bridge chunk-ready: release -> FREE and advance to WAIT_PANEL or WAIT_RESULT. No ready: self/stable. Cleanup -> FREE.` |

## 27. `CE-GEMM-STREAM-ARRAY` — `vit_gemm_fp16_stream_array`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `explicit` |
| State register / tracker | `state` |
| State encoding | `STATE_IDLE,STATE_WAIT_CHUNK,STATE_FEED,STATE_WAIT_RESULTS,STATE_BIAS,STATE_OUTPUT` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | MIXED / protocol — khi vẽ: state-qualified outputs có thể xem là Moore-like; guard/input quyết định transition và registered micro-op là Mealy-controlled. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Feed/collect eight streams |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `STATE_IDLE` | `Accept start: latch bias/token/output/pass/packing and initial bias, clear result/flags, derive selected output mask (S8 col0 or fallback col1), clear capture -> WAIT_CHUNK.` | `STATE_WAIT_CHUNK` | `Accept start: latch bias/token/output/pass/packing and initial bias, clear result/flags, derive selected output mask (S8 col0 or fallback col1), clear capture -> WAIT_CHUNK.` | `Accept start: latch bias/token/output/pass/packing and initial bias, clear result/flags, derive selected output mask (S8 col0 or fallback col1), clear capture -> WAIT_CHUNK.` |
| 2 | `STATE_WAIT_CHUNK` | `lane=0, term_pending=all8 -> FEED.` | `STATE_FEED` | `chunk_valid latches K16 A/B/lane mask/last; refresh bias on final K panel; lane=0, term_pending=all8 -> FEED.` | `lane=0, term_pending=all8 -> FEED.` |
| 3 | `STATE_FEED` | `When all accepted: lane15+last -> clear capture,WAIT_RESULTS` | `STATE_WAIT_RESULTS` | `No term_fire self. On fires clear matching pending bits. When all accepted: lane15+last -> clear capture,WAIT_RESULTS; lane15+not-last -> WAIT_CHUNK; otherwise lane++,reload all pending and self FEED.` | `When all accepted: lane15+last -> clear capture,WAIT_RESULTS` |
| 4 | `STATE_FEED` | `lane15+not-last -> WAIT_CHUNK` | `STATE_WAIT_CHUNK` | `No term_fire self. On fires clear matching pending bits. When all accepted: lane15+last -> clear capture,WAIT_RESULTS; lane15+not-last -> WAIT_CHUNK; otherwise lane++,reload all pending and self FEED.` | `lane15+not-last -> WAIT_CHUNK` |
| 5 | `STATE_WAIT_RESULTS` | `When all eight captured set bias index=0 -> BIAS` | `STATE_BIAS` | `Capture each independent result/flag on its fire; update capture mask. When all eight captured set bias index=0 -> BIAS; otherwise self.` | `When all eight captured set bias index=0 -> BIAS` |
| 6 | `STATE_BIAS` | `index7 -> OUTPUT` | `STATE_OUTPUT` | `For valid token/selected col, commit raw or bias-added FP32 word and merge NaN/Inf flags. index7 -> OUTPUT; else index++.` | `index7 -> OUTPUT` |
| 7 | `STATE_OUTPUT` | `Ready: pulse registered done_o=1 and return IDLE.` | `STATE_IDLE` | `!result_ready self. Ready: pulse registered done_o=1 and return IDLE.` | `Ready: pulse registered done_o=1 and return IDLE.` |
| 8 | `default 6/7` | `no error/default payload rewrite.` | `state->IDLE; later outputs become invalid, registers hold.` | `state->IDLE; later outputs become invalid, registers hold.` | `no error/default payload rewrite.` |

## 28. `CE-GEMM-DOT-STREAM[0..7]` — `vit_fp16_dot_stream_csa_nodsp`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `implicit` |
| State register / tracker | `s0_valid; s1_valid; s2_valid; f0_valid; f1_valid; f2_valid; out_valid; accumulator_term_count; accumulator_sum; accumulator_carry; accumulator_nan; accumulator_pos_inf; accumulator_neg_inf; accumulator_subnormal_flushed; accumulator_alignment_error; accumulator_length_error` |
| State encoding | `EMPTY/PIPELINED/ACCUMULATING/OUTPUT` |
| Clock / Reset | `clk` / `rst_n (synchronous active-low)` |
| Moore / Mealy | Implicit protocol automaton — không nên ép thành Moore hoặc Mealy thuần; vẽ theo mode/occupancy/valid tracker + guard. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | FP16 dot pipeline |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `Term accept / s0` | `Capture A/B/enable/TLAST whenever input valid; s0_valid<=tvalid. If not valid, valid clears while payload may hold. Acceptance is tvalid&&tready.` | `Capture A/B/enable/TLAST whenever input valid; s0_valid<=tvalid. If not valid, valid clears while payload may hold. Acceptance is tvalid&&tready.` | `s0_valid; s1_valid; s2_valid; f0_valid; f1_valid; f2_valid; out_valid; accumulator_term_count; accumulator_sum; accumulator_carry; accumulator_nan; accumulator_pos_inf; accumulator_neg_inf; accumulator_subnormal_flushed; accumulator_alignment_error; accumulator_length_error` | `Capture A/B/enable/TLAST whenever input valid; s0_valid<=tvalid. If not valid, valid clears while payload may hold. Acceptance is tvalid&&tready.` |
| 2 | `Product / s1` | `s1_valid<=s0_valid. Enabled term uses combinational FP16 product plus NaN/Inf/sign/subnormal flags; disabled term becomes exact zero and clears all special flags. TLAST propagates.` | `s1_valid<=s0_valid. Enabled term uses combinational FP16 product plus NaN/Inf/sign/subnormal flags; disabled term becomes exact zero and clears all special flags. TLAST propagates.` | `s0_valid; s1_valid; s2_valid; f0_valid; f1_valid; f2_valid; out_valid; accumulator_term_count; accumulator_sum; accumulator_carry; accumulator_nan; accumulator_pos_inf; accumulator_neg_inf; accumulator_subnormal_flushed; accumulator_alignment_error; accumulator_length_error` | `s1_valid<=s0_valid. Enabled term uses combinational FP16 product plus NaN/Inf/sign/subnormal flags; disabled term becomes exact zero and clears all special flags. TLAST propagates.` |
| 3 | `Alignment / s2` | `s2_valid<=s1_valid. Convert finite FP32 product exactly to signed fixed addend; latch alignment lost/range overflow and special flags/TLAST.` | `s2_valid<=s1_valid. Convert finite FP32 product exactly to signed fixed addend; latch alignment lost/range overflow and special flags/TLAST.` | `s0_valid; s1_valid; s2_valid; f0_valid; f1_valid; f2_valid; out_valid; accumulator_term_count; accumulator_sum; accumulator_carry; accumulator_nan; accumulator_pos_inf; accumulator_neg_inf; accumulator_subnormal_flushed; accumulator_alignment_error; accumulator_length_error` | `s2_valid<=s1_valid. Convert finite FP32 product exactly to signed fixed addend; latch alignment lost/range overflow and special flags/TLAST.` |
| 4 | `CSA accumulate` | `On valid non-last s2, compute sum^carry^addend and majority carry shifted left, increment term count, OR special/alignment/length flags. Otherwise holds.` | `On valid non-last s2, compute sum^carry^addend and majority carry shifted left, increment term count, OR special/alignment/length flags. Otherwise holds.` | `s0_valid; s1_valid; s2_valid; f0_valid; f1_valid; f2_valid; out_valid; accumulator_term_count; accumulator_sum; accumulator_carry; accumulator_nan; accumulator_pos_inf; accumulator_neg_inf; accumulator_subnormal_flushed; accumulator_alignment_error; accumulator_length_error` | `On valid non-last s2, compute sum^carry^addend and majority carry shifted left, increment term count, OR special/alignment/length flags. Otherwise holds.` |
| 5 | `TLAST fork / f0` | `On valid last s2, snapshot next CSA sum/carry and combined flags, then clear accumulator/count/flags for the next dot. Invalid is NaN or alignment or length; force-Inf only for a single-sign infinity without invalid.` | `On valid last s2, snapshot next CSA sum/carry and combined flags, then clear accumulator/count/flags for the next dot. Invalid is NaN or alignment or length; force-Inf only for a single-sign infinity without invalid.` | `s0_valid; s1_valid; s2_valid; f0_valid; f1_valid; f2_valid; out_valid; accumulator_term_count; accumulator_sum; accumulator_carry; accumulator_nan; accumulator_pos_inf; accumulator_neg_inf; accumulator_subnormal_flushed; accumulator_alignment_error; accumulator_length_error` | `On valid last s2, snapshot next CSA sum/carry and combined flags, then clear accumulator/count/flags for the next dot. Invalid is NaN or alignment or length; force-Inf only for a single-sign infinity without invalid.` |
| 6 | `Carry propagate/analyze / f1` | `f1_valid<=f0_valid; add signed f0 sum+carry and latch flags. Combinational analyzer derives sign, magnitude, zero, leading index.` | `f1_valid<=f0_valid; add signed f0 sum+carry and latch flags. Combinational analyzer derives sign, magnitude, zero, leading index.` | `s0_valid; s1_valid; s2_valid; f0_valid; f1_valid; f2_valid; out_valid; accumulator_term_count; accumulator_sum; accumulator_carry; accumulator_nan; accumulator_pos_inf; accumulator_neg_inf; accumulator_subnormal_flushed; accumulator_alignment_error; accumulator_length_error` | `f1_valid<=f0_valid; add signed f0 sum+carry and latch flags. Combinational analyzer derives sign, magnitude, zero, leading index.` |
| 7 | `RNE pack / f2` | `f2_valid<=f1_valid; latch analyze outputs/flags. Combinational normalizer produces binary32 RNE, including forced infinity.` | `f2_valid<=f1_valid; latch analyze outputs/flags. Combinational normalizer produces binary32 RNE, including forced infinity.` | `s0_valid; s1_valid; s2_valid; f0_valid; f1_valid; f2_valid; out_valid; accumulator_term_count; accumulator_sum; accumulator_carry; accumulator_nan; accumulator_pos_inf; accumulator_neg_inf; accumulator_subnormal_flushed; accumulator_alignment_error; accumulator_length_error` | `f2_valid<=f1_valid; latch analyze outputs/flags. Combinational normalizer produces binary32 RNE, including forced infinity.` |
| 8 | `Output hold / out` | `out_valid<=f2_valid; when f2 valid latch data/flags. If out_valid and not ready, global hold preserves this and all upstream state. TLAST output is constant one.` | `out_valid<=f2_valid; when f2 valid latch data/flags. If out_valid and not ready, global hold preserves this and all upstream state. TLAST output is constant one.` | `s0_valid; s1_valid; s2_valid; f0_valid; f1_valid; f2_valid; out_valid; accumulator_term_count; accumulator_sum; accumulator_carry; accumulator_nan; accumulator_pos_inf; accumulator_neg_inf; accumulator_subnormal_flushed; accumulator_alignment_error; accumulator_length_error` | `out_valid<=f2_valid; when f2 valid latch data/flags. If out_valid and not ready, global hold preserves this and all upstream state. TLAST output is constant one.` |

## 29. `CE-GEMM-RESULT-FIFO` — `vit_gemm_result_fifo`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `implicit` |
| State register / tracker | `read_pointer_q; write_pointer_q; count_q; entry_memory` |
| State encoding | `EMPTY/PARTIAL/FULL` |
| Clock / Reset | `clk` / `rst (synchronous active-high); flush_i active-high` |
| Moore / Mealy | Implicit protocol automaton — không nên ép thành Moore hoặc Mealy thuần; vẽ theo mode/occupancy/valid tracker + guard. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Decouple GEMM results |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `EMPTY(0)` | `no fires hold` | `POST_EDGE: no fires hold` | `read_pointer_q; write_pointer_q; count_q; entry_memory` | `no fires hold` |
| 2 | `EMPTY(0)` | `push only writes tail, toggles write pointer,count=1.` | `POST_EDGE: push only writes tail, toggles write pointer,count=1.` | `read_pointer_q; write_pointer_q; count_q; entry_memory` | `push only writes tail, toggles write pointer,count=1.` |
| 3 | `EMPTY(0)` | `Pop cannot fire.` | `POST_EDGE: Pop cannot fire.` | `read_pointer_q; write_pointer_q; count_q; entry_memory` | `Pop cannot fire.` |
| 4 | `ONE(1)` | `push only -> count2/write toggle` | `POST_EDGE: push only -> count2/write toggle` | `read_pointer_q; write_pointer_q; count_q; entry_memory` | `push only -> count2/write toggle` |
| 5 | `ONE(1)` | `pop only -> count0/read toggle` | `POST_EDGE: pop only -> count0/read toggle` | `read_pointer_q; write_pointer_q; count_q; entry_memory` | `pop only -> count0/read toggle` |
| 6 | `ONE(1)` | `both -> overwrite old tail slot, toggle both,count holds1` | `POST_EDGE: both -> overwrite old tail slot, toggle both,count holds1` | `read_pointer_q; write_pointer_q; count_q; entry_memory` | `both -> overwrite old tail slot, toggle both,count holds1` |
| 7 | `ONE(1)` | `neither hold.` | `POST_EDGE: neither hold.` | `read_pointer_q; write_pointer_q; count_q; entry_memory` | `neither hold.` |
| 8 | `FULL(2)` | `no pop: push cannot fire and state holds.` | `POST_EDGE: no pop: push cannot fire and state holds.` | `read_pointer_q; write_pointer_q; count_q; entry_memory` | `no pop: push cannot fire and state holds.` |
| 9 | `FULL(2)` | `Pop only -> count1/read toggle.` | `POST_EDGE: Pop only -> count1/read toggle.` | `read_pointer_q; write_pointer_q; count_q; entry_memory` | `Pop only -> count1/read toggle.` |
| 10 | `FULL(2)` | `Pop+push -> atomically consume old head and write new tail, toggle both,count holds2.` | `POST_EDGE: Pop+push -> atomically consume old head and write new tail, toggle both,count holds2.` | `read_pointer_q; write_pointer_q; count_q; entry_memory` | `Pop+push -> atomically consume old head and write new tail, toggle both,count holds2.` |
| 11 | `illegal 3` | `count update still +/-/hold` | `POST_EDGE: count update still +/-/hold` | `read_pointer_q; write_pointer_q; count_q; entry_memory` | `count update still +/-/hold` |
| 12 | `illegal 3` | `only reset/flush guarantees recovery.` | `POST_EDGE: only reset/flush guarantees recovery.` | `read_pointer_q; write_pointer_q; count_q; entry_memory` | `only reset/flush guarantees recovery.` |
| 13 | `illegal 3` | `Simulation-only fatal reports count>2` | `POST_EDGE: Simulation-only fatal reports count>2` | `read_pointer_q; write_pointer_q; count_q; entry_memory` | `Simulation-only fatal reports count>2` |
| 14 | `illegal 3` | `no synthesized error flag.` | `POST_EDGE: no synthesized error flag.` | `read_pointer_q; write_pointer_q; count_q; entry_memory` | `no synthesized error flag.` |

## 30. `CE-GEMM-DUAL-MODE` — `vit_gemm_dual_mode_array`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `implicit` |
| State register / tracker | `mode_fp16_q; packed_without_fp16_q; legacy_unavailable_q` |
| State encoding | `IDLE/FP16/REJECT` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | Implicit protocol automaton — không nên ép thành Moore hoặc Mealy thuần; vẽ theo mode/occupancy/valid tracker + guard. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Latch supported mode/reject |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `QUIET/legacy-mode-bit=0` | `reset or no prior FP16 start; reject flags zero.` | `reset or no prior FP16 start; reject flags zero.` | `mode_fp16_q; packed_without_fp16_q; legacy_unavailable_q` | `reset or no prior FP16 start; reject flags zero.` |
| 2 | `FP16_SELECTED` | `start with cfg_fp16_enable=1; latch mode=1. Packed flag may be 0 or 1.` | `start with cfg_fp16_enable=1; latch mode=1. Packed flag may be 0 or 1.` | `mode_fp16_q; packed_without_fp16_q; legacy_unavailable_q` | `start with cfg_fp16_enable=1; latch mode=1. Packed flag may be 0 or 1.` |
| 3 | `REJECT_PACKED_WITHOUT_FP16` | `start with packed flag=1 and fp16=0.` | `start with packed flag=1 and fp16=0.` | `mode_fp16_q; packed_without_fp16_q; legacy_unavailable_q` | `start with packed flag=1 and fp16=0.` |
| 4 | `REJECT_LEGACY_UNAVAILABLE` | `start with fp16=0 and M8 INCLUDE_LEGACY_GEMM==0.` | `start with fp16=0 and M8 INCLUDE_LEGACY_GEMM==0.` | `mode_fp16_q; packed_without_fp16_q; legacy_unavailable_q` | `start with fp16=0 and M8 INCLUDE_LEGACY_GEMM==0.` |

## 31. `CE-GEMM-GENERATION` — `vit_phase_e_engine_top`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `implicit` |
| State register / tracker | `gemm_result_generation_q` |
| State encoding | `MOD-256 TAG` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | Implicit protocol automaton — không nên ép thành Moore hoặc Mealy thuần; vẽ theo mode/occupancy/valid tracker + guard. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Reject stale results |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `COMMAND_EPOCH(g)` | `engine-top gemm_result_generation_q` | `Synchronous reset sets 0. On command_accept && opcode==GEMM, increment modulo 256. command_accept precedes launch, so this new value is stable at scheduler start. Other commands/edges hold.` | `gemm_result_generation_q` | `engine-top gemm_result_generation_q` |
| 2 | `SCHEDULER_ACTIVE(g)` | `scheduler active_result_generation` | `Reset=0. A valid scheduler IDLE start latches result_generation_i; it remains command-scoped through all tiles/passes. Direct result output uses this tag.` | `gemm_result_generation_q` | `scheduler active_result_generation` |
| 3 | `FIFO_OWNED(g,context)` | `each packed-result FIFO entry` | `On clean fifo_push_fire, atomically captures g together with absolute address base, coordinates, masks and data. Stalls/pops obey FIFO ownership; output tag comes from the head, never the live scheduler counter.` | `gemm_result_generation_q` | `each packed-result FIFO entry` |
| 4 | `STORE_ADMIT_CHECK` | `memory frontend combinational guard in MEM_IDLE` | `If selected GEMM result is valid at execute admission and its store tag differs from current expected command epoch, generation error is asserted before write-context capture.` | `gemm_result_generation_q` | `memory frontend combinational guard in MEM_IDLE` |
| 5 | `STORE_ACTIVE(g,context)` | `frontend gemm_result_generation_store_q plus address/coordinate snapshots` | `On accepted result selection, capture tag/context before MEM_WRITE_SELECT. During SELECT/REQUEST/RESPONSE/DELIVER, compare live selected tag/address/coordinates with snapshots; any change is terminal generation/context error.` | `gemm_result_generation_q` | `frontend gemm_result_generation_store_q plus address/coordinate snapshots` |
| 6 | `TERMINAL_ERROR` | `frontend memory_error_latched` | `Generation/context mismatch sets latch, forces MEM_IDLE, clears caches/turn/defer state, and prevents native request restart. Wrapper contract requires SOFT_RESET before another job.` | `gemm_result_generation_q` | `frontend memory_error_latched` |

## 32. `CE-U32-MUL-LN` — `vit_u32_mul_iterative_nodsp`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `implicit` |
| State register / tracker | `busy; done; product; shifted_multiplicand; shifted_multiplier; bit_index` |
| State encoding | `IDLE/RUN(0..31)/DONE` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | Implicit protocol automaton — không nên ép thành Moore hoặc Mealy thuần; vẽ theo mode/occupancy/valid tracker + guard. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | u32 multiply no DSP |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `READY` | `Datapath holds.` | `Datapath holds.` | `busy; done; product; shifted_multiplicand; shifted_multiplier; bit_index` | `Datapath holds.` |
| 2 | `ITERATE[k]` | `Conditionally add current multiplicand when multiplier LSB is one; shift left/right.` | `Conditionally add current multiplicand when multiplier LSB is one; shift left/right.` | `busy; done; product; shifted_multiplicand; shifted_multiplier; bit_index` | `Conditionally add current multiplicand when multiplier LSB is one; shift left/right.` |

## 33. `CE-U32-MUL-LAYOUT` — `vit_u32_mul_iterative_nodsp`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `implicit` |
| State register / tracker | `busy; done; product; shifted_multiplicand; shifted_multiplier; bit_index` |
| State encoding | `IDLE/RUN(0..31)/DONE` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | Implicit protocol automaton — không nên ép thành Moore hoặc Mealy thuần; vẽ theo mode/occupancy/valid tracker + guard. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | u32 multiply no DSP |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `READY` | `Hold all datapath registers; done is forced low each non-reset edge.` | `Hold all datapath registers; done is forced low each non-reset edge.` | `Hold all datapath registers; done is forced low each non-reset edge.` | `Hold all datapath registers; done is forced low each non-reset edge.` |
| 2 | `ITERATE[k]` | `If multiplier bit 0 is one, product <= product + shifted_multiplicand; shift multiplicand left and multiplier right.` | `If multiplier bit 0 is one, product <= product + shifted_multiplicand; shift multiplicand left and multiplier right.` | `If multiplier bit 0 is one, product <= product + shifted_multiplicand; shift multiplicand left and multiplier right.` | `If multiplier bit 0 is one, product <= product + shifted_multiplicand; shift multiplicand left and multiplier right.` |

## 34. `CE-U32-MUL-SOFTMAX` — `vit_u32_mul_iterative_nodsp`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `implicit` |
| State register / tracker | `busy; done; product; shifted_multiplicand; shifted_multiplier; bit_index` |
| State encoding | `IDLE/RUN(0..31)/DONE` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | Implicit protocol automaton — không nên ép thành Moore hoặc Mealy thuần; vẽ theo mode/occupancy/valid tracker + guard. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | u32 multiply no DSP |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `READY` | `Hold product/shift registers/index and force done low.` | `Hold product/shift registers/index and force done low.` | `Hold product/shift registers/index and force done low.` | `Hold product/shift registers/index and force done low.` |
| 2 | `ITERATE[k]` | `Add shifted multiplicand iff multiplier LSB; shift multiplicand left and multiplier right.` | `Add shifted multiplicand iff multiplier LSB; shift multiplicand left and multiplier right.` | `Add shifted multiplicand iff multiplier LSB; shift multiplicand left and multiplier right.` | `Add shifted multiplicand iff multiplier LSB; shift multiplicand left and multiplier right.` |

## 35. `CE-LN-RECIP-U32` — `vit_fp32_recip_u32_serial`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `explicit` |
| State register / tracker | `state` |
| State encoding | `STATE_IDLE,STATE_DIVIDE,STATE_ROUND,STATE_DONE` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | MIXED / protocol — khi vẽ: state-qualified outputs có thể xem là Moore-like; guard/input quyết định transition và registered micro-op là Mealy-controlled. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Serial reciprocal |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `STATE_IDLE` | `start,value=0: result=+Inf, DONE. Start,nonzero: derive MSB/power-of-two shift, initialize restoring division registers and exponent, DIVIDE.` | `STATE_DONE` | `result; denominator; dividend; quotient; remainder; division_index; unbiased_exponent` | `start,value=0: result=+Inf, DONE. Start,nonzero: derive MSB/power-of-two shift, initialize restoring division registers and exponent, DIVIDE.` |
| 2 | `STATE_IDLE` | `start,value=0: result=+Inf, DONE. Start,nonzero: derive MSB/power-of-two shift, initialize restoring division registers and exponent, DIVIDE.` | `STATE_DIVIDE` | `result; denominator; dividend; quotient; remainder; division_index; unbiased_exponent` | `start,value=0: result=+Inf, DONE. Start,nonzero: derive MSB/power-of-two shift, initialize restoring division registers and exponent, DIVIDE.` |
| 3 | `STATE_DIVIDE` | `index=0 -> ROUND` | `STATE_ROUND` | `remainder; quotient[division_index]; division_index` | `index=0 -> ROUND` |
| 4 | `STATE_ROUND` | `Round quotient nearest-even using remainder/denominator; normalize carry. Biased exponent >=255 -> +Inf; <=0 -> +0; otherwise pack positive binary32. Go DONE.` | `STATE_DONE` | `result; biased_exponent` | `Round quotient nearest-even using remainder/denominator; normalize carry. Biased exponent >=255 -> +Inf; <=0 -> +0; otherwise pack positive binary32. Go DONE.` |
| 5 | `STATE_DONE` | `Unconditionally IDLE.` | `STATE_IDLE` | `CONTROL_ONLY` | `Unconditionally IDLE.` |
| 6 | `default/X` | `outputs follow comparison uncertainty before edge.` | `State only -> IDLE; datapath/result hold; no error pulse.` | `state` | `outputs follow comparison uncertainty before edge.` |

## 36. `CE-VECTOR` — `vit_vector_engine_fp32`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `explicit` |
| State register / tracker | `state` |
| State encoding | `STATE_IDLE,STATE_LOAD,STATE_MULTIPLY,STATE_ADD,STATE_WRITE,STATE_DONE` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | MIXED / protocol — khi vẽ: state-qualified outputs có thể xem là Moore-like; guard/input quyết định transition và registered micro-op là Mealy-controlled. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Vector engine sequence |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `STATE_IDLE` | `start then invalid (length==0)\|\|(mode!=ADD&&mode!=SCALE_MASK) -> error,DONE` | `STATE_DONE` | `start then invalid (length==0)\|\|(mode!=ADD&&mode!=SCALE_MASK) -> error,DONE; otherwise latch config/base=0 -> LOAD.` | `start then invalid (length==0)\|\|(mode!=ADD&&mode!=SCALE_MASK) -> error,DONE` |
| 2 | `STATE_IDLE` | `otherwise latch config/base=0 -> LOAD.` | `STATE_LOAD` | `start then invalid (length==0)\|\|(mode!=ADD&&mode!=SCALE_MASK) -> error,DONE; otherwise latch config/base=0 -> LOAD.` | `otherwise latch config/base=0 -> LOAD.` |
| 3 | `STATE_LOAD` | `ADD mode -> ADD, else MULTIPLY.` | `STATE_ADD` | `On valid, latch two 16x32 vectors, derived lane mask, clear output, capture result metadata/lane=0; ADD mode -> ADD, else MULTIPLY.` | `ADD mode -> ADD, else MULTIPLY.` |
| 4 | `STATE_LOAD` | `ADD mode -> ADD, else MULTIPLY.` | `STATE_MULTIPLY` | `On valid, latch two 16x32 vectors, derived lane mask, clear output, capture result metadata/lane=0; ADD mode -> ADD, else MULTIPLY.` | `ADD mode -> ADD, else MULTIPLY.` |
| 5 | `STATE_MULTIPLY` | `Mask-add enabled: latch scaled lane -> ADD.` | `STATE_ADD` | `Mask-add enabled: latch scaled lane -> ADD. Otherwise commit scaled-or-zero lane, shift inputs/mask; lane15 -> WRITE, else lane++ and self.` | `Mask-add enabled: latch scaled lane -> ADD.` |
| 6 | `STATE_MULTIPLY` | `lane15 -> WRITE, else lane++ and self.` | `STATE_WRITE` | `Mask-add enabled: latch scaled lane -> ADD. Otherwise commit scaled-or-zero lane, shift inputs/mask; lane15 -> WRITE, else lane++ and self.` | `lane15 -> WRITE, else lane++ and self.` |
| 7 | `STATE_MULTIPLY` | `Otherwise commit scaled-or-zero lane, shift inputs/mask` | `STATE_MULTIPLY` | `Mask-add enabled: latch scaled lane -> ADD. Otherwise commit scaled-or-zero lane, shift inputs/mask; lane15 -> WRITE, else lane++ and self.` | `Otherwise commit scaled-or-zero lane, shift inputs/mask` |
| 8 | `STATE_MULTIPLY` | `lane15 -> WRITE, else lane++ and self.` | `STATE_MULTIPLY` | `Mask-add enabled: latch scaled lane -> ADD. Otherwise commit scaled-or-zero lane, shift inputs/mask; lane15 -> WRITE, else lane++ and self.` | `lane15 -> WRITE, else lane++ and self.` |
| 9 | `STATE_ADD` | `Lane15 -> WRITE` | `STATE_WRITE` | `Commit zero for invalid lane, scaled value when SCALE_MASK without add mask, else shared add result; shift. Lane15 -> WRITE; otherwise lane++, ADD mode self else MULTIPLY.` | `Lane15 -> WRITE` |
| 10 | `STATE_ADD` | `Commit zero for invalid lane, scaled value when SCALE_MASK without add mask, else shared add result` | `STATE_ADD` | `Commit zero for invalid lane, scaled value when SCALE_MASK without add mask, else shared add result; shift. Lane15 -> WRITE; otherwise lane++, ADD mode self else MULTIPLY.` | `Commit zero for invalid lane, scaled value when SCALE_MASK without add mask, else shared add result` |
| 11 | `STATE_ADD` | `otherwise lane++, ADD mode self else MULTIPLY.` | `STATE_ADD` | `Commit zero for invalid lane, scaled value when SCALE_MASK without add mask, else shared add result; shift. Lane15 -> WRITE; otherwise lane++, ADD mode self else MULTIPLY.` | `otherwise lane++, ADD mode self else MULTIPLY.` |
| 12 | `STATE_ADD` | `otherwise lane++, ADD mode self else MULTIPLY.` | `STATE_MULTIPLY` | `Commit zero for invalid lane, scaled value when SCALE_MASK without add mask, else shared add result; shift. Lane15 -> WRITE; otherwise lane++, ADD mode self else MULTIPLY.` | `otherwise lane++, ADD mode self else MULTIPLY.` |
| 13 | `STATE_WRITE` | `On ready, if element_base+16>=length -> DONE` | `STATE_DONE` | `!result_ready: self. On ready, if element_base+16>=length -> DONE; else base+=16 -> LOAD.` | `On ready, if element_base+16>=length -> DONE` |
| 14 | `STATE_WRITE` | `else base+=16 -> LOAD.` | `STATE_LOAD` | `!result_ready: self. On ready, if element_base+16>=length -> DONE; else base+=16 -> LOAD.` | `else base+=16 -> LOAD.` |
| 15 | `STATE_DONE` | `Unconditionally IDLE.` | `STATE_IDLE` | `Unconditionally IDLE.` | `Unconditionally IDLE.` |

## 37. `CE-LAYOUT` — `vit_layout_engine`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `explicit` |
| State register / tracker | `state` |
| State encoding | `STATE_IDLE,STATE_VALIDATE,STATE_REQUEST,STATE_WRITE,STATE_DONE` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | MIXED / protocol — khi vẽ: state-qualified outputs có thể xem là Moore-like; guard/input quyết định transition và registered micro-op là Mealy-controlled. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Layout transform |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `STATE_IDLE` | `start simultaneously starts validator and latches bank/base/dims1-2/strides, clears index/error -> VALIDATE.` | `STATE_VALIDATE` | `linear_output_index; config_error; active_src_bank; active_src_base; active_dst_base; active_dim1; active_dim2; active_src_stride0; active_src_stride1; active_src_stride2` | `start simultaneously starts validator and latches bank/base/dims1-2/strides, clears index/error -> VALIDATE.` |
| 2 | `STATE_VALIDATE` | `pulse iterator start combinationally -> REQUEST.` | `STATE_REQUEST` | `active_total_words; config_error` | `pulse iterator start combinationally -> REQUEST.` |
| 3 | `STATE_VALIDATE` | `done&&!valid: error=1 -> DONE.` | `STATE_DONE` | `active_total_words; config_error` | `done&&!valid: error=1 -> DONE.` |
| 4 | `STATE_REQUEST` | `data_valid: capture dst_base+linear_index and source data -> WRITE` | `STATE_WRITE` | `result_address_reg; result_data_reg` | `data_valid: capture dst_base+linear_index and source data -> WRITE` |
| 5 | `STATE_WRITE` | `ready and last (index+1>=total) -> DONE.` | `STATE_DONE` | `linear_output_index` | `ready and last (index+1>=total) -> DONE.` |
| 6 | `STATE_WRITE` | `ready,not-last: index++, pulse iterator advance -> REQUEST.` | `STATE_REQUEST` | `linear_output_index` | `ready,not-last: index++, pulse iterator advance -> REQUEST.` |
| 7 | `STATE_DONE` | `unconditional IDLE.` | `STATE_IDLE` | `CONTROL_ONLY` | `unconditional IDLE.` |
| 8 | `default` | `illegal 5..7/X-equivalent branch.` | `set config error and state IDLE; other registers hold.` | `state` | `illegal 5..7/X-equivalent branch.` |

## 38. `CE-LAYOUT-VALIDATOR` — `vit_layout_descriptor_validator`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `explicit` |
| State register / tracker | `state` |
| State encoding | `STATE_IDLE,STATE_TOTAL01_START,STATE_TOTAL01_WAIT,STATE_TOTAL2_START,STATE_TOTAL2_WAIT,STATE_STRIDE0_START,STATE_STRIDE0_WAIT,STATE_STRIDE1_START,STATE_STRIDE1_WAIT,STATE_STRIDE2_START,STATE_STRIDE2_WAIT,STATE_FINAL_CHECK,STATE_DONE` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | MIXED / protocol — khi vẽ: state-qualified outputs có thể xem là Moore-like; guard/input quyết định transition và registered micro-op là Mealy-controlled. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Validate descriptor |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `STATE_IDLE` | `Any dim zero -> DONE invalid` | `STATE_DONE` | `active_dst_base; active_dim0; active_dim1; active_dim2; active_stride0; active_stride1; active_stride2; dim01_product; maximum_source_address; descriptor_valid; total_words` | `Any dim zero -> DONE invalid` |
| 2 | `STATE_IDLE` | `else TOTAL01_START.` | `STATE_TOTAL01_START` | `active_dst_base; active_dim0; active_dim1; active_dim2; active_stride0; active_stride1; active_stride2; dim01_product; maximum_source_address; descriptor_valid; total_words` | `else TOTAL01_START.` |
| 3 | `STATE_TOTAL01_START` | `unconditional TOTAL01_WAIT.` | `STATE_TOTAL01_WAIT` | `CONTROL_ONLY` | `unconditional TOTAL01_WAIT.` |
| 4 | `STATE_TOTAL01_WAIT` | `done & high32!=0 -> DONE invalid` | `STATE_DONE` | `dim01_product` | `done & high32!=0 -> DONE invalid` |
| 5 | `STATE_TOTAL01_WAIT` | `else latch low32 -> TOTAL2_START.` | `STATE_TOTAL2_START` | `dim01_product` | `else latch low32 -> TOTAL2_START.` |
| 6 | `STATE_TOTAL2_START` | `overflow -> DONE; clean -> latch total_words, STRIDE0_START.` | `STATE_TOTAL2_WAIT` | `CONTROL_ONLY` | `overflow -> DONE; clean -> latch total_words, STRIDE0_START.` |
| 7 | `STATE_TOTAL2_WAIT` | `overflow -> DONE` | `STATE_DONE` | `total_words` | `overflow -> DONE` |
| 8 | `STATE_TOTAL2_WAIT` | `clean -> latch total_words, STRIDE0_START.` | `STATE_STRIDE0_START` | `total_words` | `clean -> latch total_words, STRIDE0_START.` |
| 9 | `STATE_STRIDE0_START` | `on done add zero-extended 64-bit product into 66-bit maximum source -> STRIDE1_START.` | `STATE_STRIDE0_WAIT` | `CONTROL_ONLY` | `on done add zero-extended 64-bit product into 66-bit maximum source -> STRIDE1_START.` |
| 10 | `STATE_STRIDE0_WAIT` | `on done add zero-extended 64-bit product into 66-bit maximum source -> STRIDE1_START.` | `STATE_STRIDE1_START` | `maximum_source_address` | `on done add zero-extended 64-bit product into 66-bit maximum source -> STRIDE1_START.` |
| 11 | `STATE_STRIDE1_START` | `on done accumulate -> STRIDE2_START.` | `STATE_STRIDE1_WAIT` | `CONTROL_ONLY` | `on done accumulate -> STRIDE2_START.` |
| 12 | `STATE_STRIDE1_WAIT` | `on done accumulate -> STRIDE2_START.` | `STATE_STRIDE2_START` | `maximum_source_address` | `on done accumulate -> STRIDE2_START.` |
| 13 | `STATE_STRIDE2_START` | `on done accumulate -> FINAL_CHECK.` | `STATE_STRIDE2_WAIT` | `CONTROL_ONLY` | `on done accumulate -> FINAL_CHECK.` |
| 14 | `STATE_STRIDE2_WAIT` | `on done accumulate -> FINAL_CHECK.` | `STATE_FINAL_CHECK` | `maximum_source_address` | `on done accumulate -> FINAL_CHECK.` |
| 15 | `STATE_FINAL_CHECK` | `-> DONE.` | `STATE_DONE` | `descriptor_valid` | `-> DONE.` |
| 16 | `STATE_DONE` | `unconditional IDLE.` | `STATE_IDLE` | `CONTROL_ONLY` | `unconditional IDLE.` |
| 17 | `default 13..15` | `illegal recovery.` | `valid=0; IDLE; other registers hold.` | `state` | `illegal recovery.` |

## 39. `CE-LAYOUT-ITERATOR` — `vit_layout_address_generator`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `implicit` |
| State register / tracker | `index1; index2` |
| State encoding | `INNER/OUTER ADVANCE/DONE` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | Implicit protocol automaton — không nên ép thành Moore hoặc Mealy thuần; vẽ theo mode/occupancy/valid tracker + guard. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Layout address iteration |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `UNINITIALIZED/HOLD` | `after reset or whenever neither start nor advance; indefinite.` | `All registers hold; output is registered source_address.` | `All registers hold; output is registered source_address.` | `after reset or whenever neither start nor advance; indefinite.` |
| 2 | `LOAD_ORIGIN` | `start=1, one edge; wins if advance is also 1.` | `Capture dim1/dim2/strides; set both indices=0 and plane/row/source address=cfg_src_base.` | `Capture dim1/dim2/strides; set both indices=0 and plane/row/source address=cfg_src_base.` | `start=1, one edge; wins if advance is also 1.` |
| 3 | `STEP_INNER` | `advance and index2+1<dim2.` | `index2++; source += stride2.` | `index2++; source += stride2.` | `advance and index2+1<dim2.` |
| 4 | `STEP_ROW` | `advance, inner false, index1+1<dim1.` | `index1++; index2=0; row base += stride1; source=old row base+stride1.` | `index1++; index2=0; row base += stride1; source=old row base+stride1.` | `advance, inner false, index1+1<dim1.` |
| 5 | `STEP_PLANE` | `advance and both prior predicates false.` | `index1=index2=0; plane base += stride0; row/source=old plane base+stride0.` | `index1=index2=0; plane base += stride0; row/source=old plane base+stride0.` | `advance and both prior predicates false.` |

## 40. `CE-LAYERNORM` — `vit_layernorm_engine_fp32`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `explicit` |
| State register / tracker | `state` |
| State encoding | `STATE_IDLE,STATE_TOTAL_START,STATE_TOTAL_WAIT,STATE_RECIP_START,STATE_RECIP_WAIT,STATE_SUM_READ,STATE_SUM_ADD,STATE_MEAN_SCALE,STATE_VARIANCE_READ,STATE_VARIANCE_CACHE_WAIT,STATE_VARIANCE_CENTER,STATE_VARIANCE_SQUARE,STATE_VARIANCE_ADD,STATE_VARIANCE_SCALE,STATE_EPSILON_ADD,STATE_INV_STD_INIT,STATE_RSQRT_SQUARE,STATE_RSQRT_OPERAND,STATE_RSQRT_HALF,STATE_RSQRT_CORRECTION,STATE_RSQRT_ESTIMATE,STATE_AFFINE_READ,STATE_AFFINE_CACHE_WAIT,STATE_AFFINE_CENTER,STATE_AFFINE_NORMALIZE,STATE_AFFINE_GAMMA,STATE_AFFINE_BETA,STATE_AFFINE_WRITE,STATE_DONE` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | MIXED / protocol — khi vẽ: state-qualified outputs có thể xem là Moore-like; guard/input quyết định transition và registered micro-op là Mealy-controlled. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | LayerNorm passes |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `STATE_IDLE` | `Invalid token/hidden zero, epsilon exponent ff, or negative nonzero epsilon -> error,DONE.` | `STATE_DONE` | `No start self. Start clears token/channel/statistics and selects buffer iff enabled, depth>0, hidden<=1024. Invalid token/hidden zero, epsilon exponent ff, or negative nonzero epsilon -> error,DONE. Else latch config -> TOTAL_START.` | `Invalid token/hidden zero, epsilon exponent ff, or negative nonzero epsilon -> error,DONE.` |
| 2 | `STATE_IDLE` | `Else latch config -> TOTAL_START.` | `STATE_TOTAL_START` | `No start self. Start clears token/channel/statistics and selects buffer iff enabled, depth>0, hidden<=1024. Invalid token/hidden zero, epsilon exponent ff, or negative nonzero epsilon -> error,DONE. Else latch config -> TOTAL_START.` | `Else latch config -> TOTAL_START.` |
| 3 | `STATE_TOTAL_START` | `unconditional TOTAL_WAIT.` | `STATE_TOTAL_WAIT` | `One edge; asserts u32 multiply start for token_count*hidden_size; unconditional TOTAL_WAIT.` | `unconditional TOTAL_WAIT.` |
| 4 | `STATE_TOTAL_WAIT` | `High product bits nonzero -> error,DONE` | `STATE_DONE` | `Self until helper done. High product bits nonzero -> error,DONE; clean -> RECIP_START.` | `High product bits nonzero -> error,DONE` |
| 5 | `STATE_TOTAL_WAIT` | `clean -> RECIP_START.` | `STATE_RECIP_START` | `Self until helper done. High product bits nonzero -> error,DONE; clean -> RECIP_START.` | `clean -> RECIP_START.` |
| 6 | `STATE_RECIP_START` | `unconditional RECIP_WAIT.` | `STATE_RECIP_WAIT` | `One edge; asserts serial 1/hidden_size start; unconditional RECIP_WAIT.` | `unconditional RECIP_WAIT.` |
| 7 | `STATE_RECIP_WAIT` | `then latch binary32 reciprocal -> SUM_READ.` | `STATE_SUM_READ` | `Self until done; then latch binary32 reciprocal -> SUM_READ.` | `then latch binary32 reciprocal -> SUM_READ.` |
| 8 | `STATE_SUM_READ` | `On valid latch sample and, in buffered mode, write sample BRAM -> SUM_ADD.` | `STATE_SUM_ADD` | `request/pass=MEAN; self until input_valid. On valid latch sample and, in buffered mode, write sample BRAM -> SUM_ADD.` | `On valid latch sample and, in buffered mode, write sample BRAM -> SUM_ADD.` |
| 9 | `STATE_SUM_ADD` | `Last channel resets channel -> MEAN_SCALE` | `STATE_MEAN_SCALE` | `Commit shared FP32 add into sum. Last channel resets channel -> MEAN_SCALE; otherwise channel++ -> SUM_READ.` | `Last channel resets channel -> MEAN_SCALE` |
| 10 | `STATE_SUM_ADD` | `otherwise channel++ -> SUM_READ.` | `STATE_SUM_READ` | `Commit shared FP32 add into sum. Last channel resets channel -> MEAN_SCALE; otherwise channel++ -> SUM_READ.` | `otherwise channel++ -> SUM_READ.` |
| 11 | `STATE_MEAN_SCALE` | `clear variance/channel -> VARIANCE_READ.` | `STATE_VARIANCE_READ` | `Commit sum*(1/hidden) as token mean; clear variance/channel -> VARIANCE_READ.` | `clear variance/channel -> VARIANCE_READ.` |
| 12 | `STATE_VARIANCE_READ` | `Buffered: issue synchronous sample read and immediately -> CACHE_WAIT. Unbuffered: self until input_valid, latch sample -> VARIANCE_CENTER.` | `STATE_VARIANCE_CACHE_WAIT` | `Buffered: issue synchronous sample read and immediately -> CACHE_WAIT. Unbuffered: self until input_valid, latch sample -> VARIANCE_CENTER.` | `Buffered: issue synchronous sample read and immediately -> CACHE_WAIT. Unbuffered: self until input_valid, latch sample -> VARIANCE_CENTER.` |
| 13 | `STATE_VARIANCE_READ` | `Unbuffered: self until input_valid, latch sample -> VARIANCE_CENTER.` | `STATE_VARIANCE_CENTER` | `Buffered: issue synchronous sample read and immediately -> CACHE_WAIT. Unbuffered: self until input_valid, latch sample -> VARIANCE_CENTER.` | `Unbuffered: self until input_valid, latch sample -> VARIANCE_CENTER.` |
| 14 | `STATE_VARIANCE_CACHE_WAIT` | `latch registered sample -> VARIANCE_CENTER.` | `STATE_VARIANCE_CENTER` | `One BRAM latency edge; latch registered sample -> VARIANCE_CENTER.` | `latch registered sample -> VARIANCE_CENTER.` |
| 15 | `STATE_VARIANCE_CENTER` | `Commit sample-mean -> VARIANCE_SQUARE.` | `STATE_VARIANCE_SQUARE` | `Commit sample-mean -> VARIANCE_SQUARE.` | `Commit sample-mean -> VARIANCE_SQUARE.` |
| 16 | `STATE_VARIANCE_SQUARE` | `Commit centered squared -> VARIANCE_ADD.` | `STATE_VARIANCE_ADD` | `Commit centered squared -> VARIANCE_ADD.` | `Commit centered squared -> VARIANCE_ADD.` |
| 17 | `STATE_VARIANCE_ADD` | `Last channel resets channel -> VARIANCE_SCALE` | `STATE_VARIANCE_SCALE` | `Accumulate squared value. Last channel resets channel -> VARIANCE_SCALE; otherwise channel++ -> VARIANCE_READ.` | `Last channel resets channel -> VARIANCE_SCALE` |
| 18 | `STATE_VARIANCE_ADD` | `otherwise channel++ -> VARIANCE_READ.` | `STATE_VARIANCE_READ` | `Accumulate squared value. Last channel resets channel -> VARIANCE_SCALE; otherwise channel++ -> VARIANCE_READ.` | `otherwise channel++ -> VARIANCE_READ.` |
| 19 | `STATE_VARIANCE_SCALE` | `Commit variance accumulator times reciprocal hidden -> EPSILON_ADD.` | `STATE_EPSILON_ADD` | `Commit variance accumulator times reciprocal hidden -> EPSILON_ADD.` | `Commit variance accumulator times reciprocal hidden -> EPSILON_ADD.` |
| 20 | `STATE_EPSILON_ADD` | `iteration=0 -> INV_STD_INIT.` | `STATE_INV_STD_INIT` | `Commit variance+epsilon as rsqrt operand; iteration=0 -> INV_STD_INIT.` | `iteration=0 -> INV_STD_INIT.` |
| 21 | `STATE_INV_STD_INIT` | `each shortcut clears channel -> AFFINE_READ.` | `STATE_AFFINE_READ` | `NaN or negative nonzero -> qNaN; +Inf -> +0; either signed zero -> sign-selected +/-Inf; each shortcut clears channel -> AFFINE_READ. Normal nonzero finite operand, including a positive subnormal encoding, uses magic seed 0x5f375a86-(x>>1) -> RSQRT_SQUARE.` | `each shortcut clears channel -> AFFINE_READ.` |
| 22 | `STATE_INV_STD_INIT` | `Normal nonzero finite operand, including a positive subnormal encoding, uses magic seed 0x5f375a86-(x>>1) -> RSQRT_SQUARE.` | `STATE_RSQRT_SQUARE` | `NaN or negative nonzero -> qNaN; +Inf -> +0; either signed zero -> sign-selected +/-Inf; each shortcut clears channel -> AFFINE_READ. Normal nonzero finite operand, including a positive subnormal encoding, uses magic seed 0x5f375a86-(x>>1) -> RSQRT_SQUARE.` | `Normal nonzero finite operand, including a positive subnormal encoding, uses magic seed 0x5f375a86-(x>>1) -> RSQRT_SQUARE.` |
| 23 | `STATE_RSQRT_SQUARE` | `estimate*estimate -> RSQRT_OPERAND.` | `STATE_RSQRT_OPERAND` | `estimate*estimate -> RSQRT_OPERAND.` | `estimate*estimate -> RSQRT_OPERAND.` |
| 24 | `STATE_RSQRT_OPERAND` | `multiply by operand -> RSQRT_HALF.` | `STATE_RSQRT_HALF` | `multiply by operand -> RSQRT_HALF.` | `multiply by operand -> RSQRT_HALF.` |
| 25 | `STATE_RSQRT_HALF` | `scale product by 0.5 -> RSQRT_CORRECTION.` | `STATE_RSQRT_CORRECTION` | `scale product by 0.5 -> RSQRT_CORRECTION.` | `scale product by 0.5 -> RSQRT_CORRECTION.` |
| 26 | `STATE_RSQRT_CORRECTION` | `compute 1.5-scaled -> RSQRT_ESTIMATE.` | `STATE_RSQRT_ESTIMATE` | `compute 1.5-scaled -> RSQRT_ESTIMATE.` | `compute 1.5-scaled -> RSQRT_ESTIMATE.` |
| 27 | `STATE_RSQRT_ESTIMATE` | `Old iteration==2: also latch token inv-std,clear channel -> AFFINE_READ` | `STATE_AFFINE_READ` | `commit estimate*correction. Old iteration==2: also latch token inv-std,clear channel -> AFFINE_READ; else iteration++ -> RSQRT_SQUARE. Exactly three Newton updates.` | `Old iteration==2: also latch token inv-std,clear channel -> AFFINE_READ` |
| 28 | `STATE_RSQRT_ESTIMATE` | `else iteration++ -> RSQRT_SQUARE.` | `STATE_RSQRT_SQUARE` | `commit estimate*correction. Old iteration==2: also latch token inv-std,clear channel -> AFFINE_READ; else iteration++ -> RSQRT_SQUARE. Exactly three Newton updates.` | `else iteration++ -> RSQRT_SQUARE.` |
| 29 | `STATE_AFFINE_READ` | `Buffered token>0: issue sample/gamma/beta reads -> CACHE_WAIT. Otherwise self until input_valid; latch result index/gamma/beta. Buffered token0 deliberately ignores redundant sample from packet and -> CACHE_WAIT; unbuffered latches sample -> AFFINE_CENTER.` | `STATE_AFFINE_CACHE_WAIT` | `Buffered token>0: issue sample/gamma/beta reads -> CACHE_WAIT. Otherwise self until input_valid; latch result index/gamma/beta. Buffered token0 deliberately ignores redundant sample from packet and -> CACHE_WAIT; unbuffered latches sample -> AFFINE_CENTER.` | `Buffered token>0: issue sample/gamma/beta reads -> CACHE_WAIT. Otherwise self until input_valid; latch result index/gamma/beta. Buffered token0 deliberately ignores redundant sample from packet and -> CACHE_WAIT; unbuffered latches sample -> AFFINE_CENTER.` |
| 30 | `STATE_AFFINE_READ` | `unbuffered latches sample -> AFFINE_CENTER.` | `STATE_AFFINE_CENTER` | `Buffered token>0: issue sample/gamma/beta reads -> CACHE_WAIT. Otherwise self until input_valid; latch result index/gamma/beta. Buffered token0 deliberately ignores redundant sample from packet and -> CACHE_WAIT; unbuffered latches sample -> AFFINE_CENTER.` | `unbuffered latches sample -> AFFINE_CENTER.` |
| 31 | `STATE_AFFINE_CACHE_WAIT` | `set result index -> AFFINE_CENTER.` | `STATE_AFFINE_CENTER` | `One synchronous-read edge; latch sample and, for token>0, gamma/beta; set result index -> AFFINE_CENTER.` | `set result index -> AFFINE_CENTER.` |
| 32 | `STATE_AFFINE_CENTER` | `sample-mean -> AFFINE_NORMALIZE.` | `STATE_AFFINE_NORMALIZE` | `sample-mean -> AFFINE_NORMALIZE.` | `sample-mean -> AFFINE_NORMALIZE.` |
| 33 | `STATE_AFFINE_NORMALIZE` | `centered*inv_std -> AFFINE_GAMMA.` | `STATE_AFFINE_GAMMA` | `centered*inv_std -> AFFINE_GAMMA.` | `centered*inv_std -> AFFINE_GAMMA.` |
| 34 | `STATE_AFFINE_GAMMA` | `normalized*gamma -> AFFINE_BETA.` | `STATE_AFFINE_BETA` | `normalized*gamma -> AFFINE_BETA.` | `normalized*gamma -> AFFINE_BETA.` |
| 35 | `STATE_AFFINE_BETA` | `gamma product+beta -> result register -> AFFINE_WRITE.` | `STATE_AFFINE_WRITE` | `gamma product+beta -> result register -> AFFINE_WRITE.` | `gamma product+beta -> result register -> AFFINE_WRITE.` |
| 36 | `STATE_AFFINE_WRITE` | `Ready and more channels: channel++ -> AFFINE_READ.` | `STATE_AFFINE_READ` | `!result_ready self/hold. Ready and more channels: channel++ -> AFFINE_READ. End channel but more tokens: token/base++, clear stats/channel -> SUM_READ. Final token/channel -> DONE.` | `Ready and more channels: channel++ -> AFFINE_READ.` |
| 37 | `STATE_AFFINE_WRITE` | `End channel but more tokens: token/base++, clear stats/channel -> SUM_READ.` | `STATE_SUM_READ` | `!result_ready self/hold. Ready and more channels: channel++ -> AFFINE_READ. End channel but more tokens: token/base++, clear stats/channel -> SUM_READ. Final token/channel -> DONE.` | `End channel but more tokens: token/base++, clear stats/channel -> SUM_READ.` |
| 38 | `STATE_AFFINE_WRITE` | `Final token/channel -> DONE.` | `STATE_DONE` | `!result_ready self/hold. Ready and more channels: channel++ -> AFFINE_READ. End channel but more tokens: token/base++, clear stats/channel -> SUM_READ. Final token/channel -> DONE.` | `Final token/channel -> DONE.` |
| 39 | `STATE_DONE` | `unconditional IDLE.` | `STATE_IDLE` | `done=1,busy=1 one cycle; unconditional IDLE. Default 29..31 instead sets error and IDLE.` | `unconditional IDLE.` |

## 41. `CE-SOFTMAX` — `vit_softmax_engine_fp32`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `explicit` |
| State register / tracker | `state` |
| State encoding | `STATE_IDLE,STATE_TOTAL_START,STATE_TOTAL_WAIT,STATE_MAX,STATE_EXP_SUM_READ,STATE_EXP_CENTER,STATE_EXP_SCALE,STATE_EXP_INITIAL_PRODUCT,STATE_EXP_INITIAL_REMAINDER,STATE_EXP_CORRECTED_PRODUCT,STATE_EXP_NEGATIVE_REMAINDER,STATE_EXP_POSITIVE_REMAINDER,STATE_EXP_POLY_MUL,STATE_EXP_POLY_ADD,STATE_EXP_SCALE_DOWN,STATE_EXP_ACCUMULATE,STATE_RECIPROCAL_INIT,STATE_RECIPROCAL_PRODUCT,STATE_RECIPROCAL_CORRECTION,STATE_RECIPROCAL_ESTIMATE,STATE_OUTPUT_READ,STATE_OUTPUT_NORMALIZE,STATE_OUTPUT_WRITE,STATE_DONE` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | MIXED / protocol — khi vẽ: state-qualified outputs có thể xem là Moore-like; guard/input quyết định transition và registered micro-op là Mealy-controlled. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Softmax passes |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `STATE_IDLE` | `Zero row count/length -> error,DONE` | `STATE_DONE` | `row_index; row_base_index; element_index; row_maximum; exponential_sum; reciprocal_sum; row_exp_buffer_active; cfg_row_length; config_error; active_row_count; active_row_length` | `Zero row count/length -> error,DONE` |
| 2 | `STATE_IDLE` | `otherwise latch dimensions -> TOTAL_START.` | `STATE_TOTAL_START` | `row_index; row_base_index; element_index; row_maximum; exponential_sum; reciprocal_sum; row_exp_buffer_active; cfg_row_length; config_error; active_row_count; active_row_length` | `otherwise latch dimensions -> TOTAL_START.` |
| 3 | `STATE_TOTAL_START` | `asserts row_count*row_length multiplier start -> TOTAL_WAIT.` | `STATE_TOTAL_WAIT` | `NONE_BEYOND_STATE` | `asserts row_count*row_length multiplier start -> TOTAL_WAIT.` |
| 4 | `STATE_TOTAL_WAIT` | `Product high bits nonzero -> error,DONE` | `STATE_DONE` | `config_error` | `Product high bits nonzero -> error,DONE` |
| 5 | `STATE_TOTAL_WAIT` | `otherwise -> MAX.` | `STATE_MAX` | `config_error` | `otherwise -> MAX.` |
| 6 | `STATE_MAX` | `Last resets element/sum -> EXP_SUM_READ` | `STATE_EXP_SUM_READ` | `row_maximum; element_index; exponential_sum` | `Last resets element/sum -> EXP_SUM_READ` |
| 7 | `STATE_EXP_SUM_READ` | `Buffer mode issues synchronous read, sets output_phase=0, -> EXP_CENTER.` | `STATE_EXP_CENTER` | `exp_output_phase; exp_input_value` | `Buffer mode issues synchronous read, sets output_phase=0, -> EXP_CENTER.` |
| 8 | `STATE_EXP_SUM_READ` | `Unbuffered self until valid, latches input,phase=0 -> EXP_CENTER.` | `STATE_EXP_CENTER` | `exp_output_phase; exp_input_value` | `Unbuffered self until valid, latches input,phase=0 -> EXP_CENTER.` |
| 9 | `STATE_EXP_CENTER` | `Commit input-minus-row-max -> EXP_SCALE.` | `STATE_EXP_SCALE` | `centered_value` | `Commit input-minus-row-max -> EXP_SCALE.` |
| 10 | `STATE_EXP_SCALE` | `Each shortcut routes by phase to OUTPUT_NORMALIZE or EXP_ACCUMULATE.` | `STATE_OUTPUT_NORMALIZE` | `exponential_value; exp_scaled` | `Each shortcut routes by phase to OUTPUT_NORMALIZE or EXP_ACCUMULATE.` |
| 11 | `STATE_EXP_SCALE` | `Each shortcut routes by phase to OUTPUT_NORMALIZE or EXP_ACCUMULATE.` | `STATE_EXP_ACCUMULATE` | `exponential_value; exp_scaled` | `Each shortcut routes by phase to OUTPUT_NORMALIZE or EXP_ACCUMULATE.` |
| 12 | `STATE_EXP_SCALE` | `Normal negative commits scaled argument -> EXP_INITIAL_PRODUCT.` | `STATE_EXP_INITIAL_PRODUCT` | `exponential_value; exp_scaled` | `Normal negative commits scaled argument -> EXP_INITIAL_PRODUCT.` |
| 13 | `STATE_EXP_INITIAL_PRODUCT` | `Capture integer scale. If scale>=127, exp=0 and route by phase; else capture range product -> EXP_INITIAL_REMAINDER.` | `STATE_OUTPUT_NORMALIZE` | `exp_scale_integer_initial; exponential_value; exp_scale_product` | `Capture integer scale. If scale>=127, exp=0 and route by phase; else capture range product -> EXP_INITIAL_REMAINDER.` |
| 14 | `STATE_EXP_INITIAL_PRODUCT` | `Capture integer scale. If scale>=127, exp=0 and route by phase; else capture range product -> EXP_INITIAL_REMAINDER.` | `STATE_EXP_ACCUMULATE` | `exp_scale_integer_initial; exponential_value; exp_scale_product` | `Capture integer scale. If scale>=127, exp=0 and route by phase; else capture range product -> EXP_INITIAL_REMAINDER.` |
| 15 | `STATE_EXP_INITIAL_PRODUCT` | `else capture range product -> EXP_INITIAL_REMAINDER.` | `STATE_EXP_INITIAL_REMAINDER` | `exp_scale_integer_initial; exponential_value; exp_scale_product` | `else capture range product -> EXP_INITIAL_REMAINDER.` |
| 16 | `STATE_EXP_INITIAL_REMAINDER` | `Register first remainder -> EXP_CORRECTED_PRODUCT.` | `STATE_EXP_CORRECTED_PRODUCT` | `exp_remainder_initial` | `Register first remainder -> EXP_CORRECTED_PRODUCT.` |
| 17 | `STATE_EXP_CORRECTED_PRODUCT` | `Register negative-correction flag/integer and corrected product -> EXP_NEGATIVE_REMAINDER.` | `STATE_EXP_NEGATIVE_REMAINDER` | `exp_correct_negative; exp_scale_integer_after_negative; exp_scale_product` | `Register negative-correction flag/integer and corrected product -> EXP_NEGATIVE_REMAINDER.` |
| 18 | `STATE_EXP_NEGATIVE_REMAINDER` | `Register remainder -> EXP_POSITIVE_REMAINDER.` | `STATE_EXP_POSITIVE_REMAINDER` | `exp_remainder_negative` | `Register remainder -> EXP_POSITIVE_REMAINDER.` |
| 19 | `STATE_EXP_POSITIVE_REMAINDER` | `Apply positive correction, capture final integer/remainder, polynomial step=0 -> EXP_POLY_MUL.` | `STATE_EXP_POLY_MUL` | `exp_scale_integer_final; exp_remainder_final; exp_polynomial_step` | `Apply positive correction, capture final integer/remainder, polynomial step=0 -> EXP_POLY_MUL.` |
| 20 | `STATE_EXP_POLY_MUL` | `Store current Horner multiply -> EXP_POLY_ADD.` | `STATE_EXP_POLY_ADD` | `temporary_result` | `Store current Horner multiply -> EXP_POLY_ADD.` |
| 21 | `STATE_EXP_POLY_ADD` | `Old step==7 -> EXP_SCALE_DOWN` | `STATE_EXP_SCALE_DOWN` | `exp_polynomial; exp_polynomial_step` | `Old step==7 -> EXP_SCALE_DOWN` |
| 22 | `STATE_EXP_POLY_ADD` | `else step++ -> EXP_POLY_MUL.` | `STATE_EXP_POLY_MUL` | `exp_polynomial; exp_polynomial_step` | `else step++ -> EXP_POLY_MUL.` |
| 23 | `STATE_EXP_SCALE_DOWN` | `route by output_phase to OUTPUT_NORMALIZE or EXP_ACCUMULATE.` | `STATE_OUTPUT_NORMALIZE` | `exponential_value` | `route by output_phase to OUTPUT_NORMALIZE or EXP_ACCUMULATE.` |
| 24 | `STATE_EXP_SCALE_DOWN` | `route by output_phase to OUTPUT_NORMALIZE or EXP_ACCUMULATE.` | `STATE_EXP_ACCUMULATE` | `exponential_value` | `route by output_phase to OUTPUT_NORMALIZE or EXP_ACCUMULATE.` |
| 25 | `STATE_EXP_ACCUMULATE` | `Last element resets index -> RECIPROCAL_INIT` | `STATE_RECIPROCAL_INIT` | `exponential_sum; element_index` | `Last element resets index -> RECIPROCAL_INIT` |
| 26 | `STATE_EXP_ACCUMULATE` | `else index++ -> EXP_SUM_READ.` | `STATE_EXP_SUM_READ` | `exponential_sum; element_index` | `else index++ -> EXP_SUM_READ.` |
| 27 | `STATE_RECIPROCAL_INIT` | `each resets index -> OUTPUT_READ.` | `STATE_OUTPUT_READ` | `reciprocal_operand; reciprocal_iteration; reciprocal_sum; element_index; reciprocal_estimate` | `each resets index -> OUTPUT_READ.` |
| 28 | `STATE_RECIPROCAL_INIT` | `Normal uses magic seed -> RECIPROCAL_PRODUCT.` | `STATE_RECIPROCAL_PRODUCT` | `reciprocal_operand; reciprocal_iteration; reciprocal_sum; element_index; reciprocal_estimate` | `Normal uses magic seed -> RECIPROCAL_PRODUCT.` |
| 29 | `STATE_RECIPROCAL_PRODUCT` | `Register sum*estimate -> RECIPROCAL_CORRECTION.` | `STATE_RECIPROCAL_CORRECTION` | `reciprocal_product` | `Register sum*estimate -> RECIPROCAL_CORRECTION.` |
| 30 | `STATE_RECIPROCAL_CORRECTION` | `Register correction -> RECIPROCAL_ESTIMATE.` | `STATE_RECIPROCAL_ESTIMATE` | `reciprocal_correction` | `Register correction -> RECIPROCAL_ESTIMATE.` |
| 31 | `STATE_RECIPROCAL_ESTIMATE` | `Old iteration==3: latch reciprocal, reset index -> OUTPUT_READ` | `STATE_OUTPUT_READ` | `reciprocal_estimate; reciprocal_sum; element_index; reciprocal_iteration` | `Old iteration==3: latch reciprocal, reset index -> OUTPUT_READ` |
| 32 | `STATE_RECIPROCAL_ESTIMATE` | `Commit Newton estimate. Old iteration==3: latch reciprocal, reset index -> OUTPUT_READ; else iteration++ -> PRODUCT. Exactly four updates.` | `STATE_RECIPROCAL_PRODUCT` | `reciprocal_estimate; reciprocal_sum; element_index; reciprocal_iteration` | `Commit Newton estimate. Old iteration==3: latch reciprocal, reset index -> OUTPUT_READ; else iteration++ -> PRODUCT. Exactly four updates.` |
| 33 | `STATE_OUTPUT_READ` | `Buffer mode issues exp read, sets result index -> OUTPUT_NORMALIZE.` | `STATE_OUTPUT_NORMALIZE` | `result_index; exp_input_value; exp_output_phase` | `Buffer mode issues exp read, sets result index -> OUTPUT_NORMALIZE.` |
| 34 | `STATE_OUTPUT_READ` | `Unbuffered self until input_valid, latches raw input, sets output_phase=1 -> EXP_CENTER and recomputes exp.` | `STATE_EXP_CENTER` | `result_index; exp_input_value; exp_output_phase` | `Unbuffered self until input_valid, latches raw input, sets output_phase=1 -> EXP_CENTER and recomputes exp.` |
| 35 | `STATE_OUTPUT_NORMALIZE` | `Commit exp*reciprocal into result -> OUTPUT_WRITE.` | `STATE_OUTPUT_WRITE` | `result_data` | `Commit exp*reciprocal into result -> OUTPUT_WRITE.` |
| 36 | `STATE_OUTPUT_WRITE` | `Ready and more elements: index++ -> OUTPUT_READ.` | `STATE_OUTPUT_READ` | `element_index; row_index; row_base_index; row_maximum; exponential_sum; reciprocal_sum` | `Ready and more elements: index++ -> OUTPUT_READ.` |
| 37 | `STATE_OUTPUT_WRITE` | `End row but more rows: row/base++, reset row stats/index -> MAX.` | `STATE_MAX` | `element_index; row_index; row_base_index; row_maximum; exponential_sum; reciprocal_sum` | `End row but more rows: row/base++, reset row stats/index -> MAX.` |
| 38 | `STATE_OUTPUT_WRITE` | `Final -> DONE.` | `STATE_DONE` | `element_index; row_index; row_base_index; row_maximum; exponential_sum; reciprocal_sum` | `Final -> DONE.` |
| 39 | `STATE_DONE` | `done=1,busy=1 one cycle -> IDLE.` | `STATE_IDLE` | `NONE_BEYOND_STATE` | `done=1,busy=1 one cycle -> IDLE.` |

## 42. `CE-GELU-ENGINE` — `vit_gelu_engine_fp32`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `explicit` |
| State register / tracker | `state` |
| State encoding | `STATE_IDLE,STATE_READ,STATE_LAUNCH_LANE,STATE_WAIT_LANE,STATE_WRITE,STATE_DONE` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | MIXED / protocol — khi vẽ: state-qualified outputs có thể xem là Moore-like; guard/input quyết định transition và registered micro-op là Mealy-controlled. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Sequence GELU elements |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `STATE_IDLE` | `start,length=0 -> error,DONE` | `STATE_DONE` | `base_index; config_error; active_length` | `start,length=0 -> error,DONE` |
| 2 | `STATE_IDLE` | `start,length>0 -> latch length/base=0,clear error -> READ.` | `STATE_READ` | `base_index; config_error; active_length` | `start,length>0 -> latch length/base=0,clear error -> READ.` |
| 3 | `STATE_READ` | `valid: latch 16 words and tail mask, clear result, capture result base/mask, lane=0 -> LAUNCH.` | `STATE_LAUNCH_LANE` | `result_base_index; result_lane_mask; result_data; latched_input_data; latched_lane_mask; compute_lane_index` | `valid: latch 16 words and tail mask, clear result, capture result base/mask, lane=0 -> LAUNCH.` |
| 4 | `STATE_LAUNCH_LANE` | `lane15 -> WRITE, else lane++ and self.` | `STATE_WRITE` | `result_data[compute_lane_index*32+:32]; compute_lane_index` | `lane15 -> WRITE, else lane++ and self.` |
| 5 | `STATE_LAUNCH_LANE` | `inactive lane: write zero; lane15 -> WRITE, else lane++ and self. Active lane: -> WAIT.` | `STATE_WAIT_LANE` | `result_data[compute_lane_index*32+:32]; compute_lane_index` | `inactive lane: write zero; lane15 -> WRITE, else lane++ and self. Active lane: -> WAIT.` |
| 6 | `STATE_WAIT_LANE` | `lane15 -> WRITE, else lane++ -> LAUNCH.` | `STATE_WRITE` | `result_data[compute_lane_index*32+:32]; compute_lane_index` | `lane15 -> WRITE, else lane++ -> LAUNCH.` |
| 7 | `STATE_WAIT_LANE` | `no done self. Done: commit scalar result; lane15 -> WRITE, else lane++ -> LAUNCH.` | `STATE_LAUNCH_LANE` | `result_data[compute_lane_index*32+:32]; compute_lane_index` | `no done self. Done: commit scalar result; lane15 -> WRITE, else lane++ -> LAUNCH.` |
| 8 | `STATE_WRITE` | `Ready and base+16<length: base+=16 -> READ` | `STATE_READ` | `base_index` | `Ready and base+16<length: base+=16 -> READ` |
| 9 | `STATE_WRITE` | `else -> DONE.` | `STATE_DONE` | `base_index` | `else -> DONE.` |
| 10 | `STATE_DONE` | `unconditional IDLE.` | `STATE_IDLE` | `NONE_BEYOND_STATE` | `unconditional IDLE.` |
| 11 | `default 6/7` | `illegal recovery.` | `set error, return IDLE; payload registers hold.` | `state` | `illegal recovery.` |

## 43. `CE-GELU-SERIAL` — `vit_fp32_gelu_serial`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `explicit` |
| State register / tracker | `state` |
| State encoding | `STATE_IDLE,STATE_SCALE_VALUE,STATE_DENOMINATOR_MUL,STATE_DENOMINATOR_ADD,STATE_RECIPROCAL_INIT,STATE_RECIPROCAL_PRODUCT,STATE_RECIPROCAL_CORRECTION,STATE_RECIPROCAL_ESTIMATE,STATE_GELU_POLY_MUL,STATE_GELU_POLY_ADD,STATE_SQUARE,STATE_EXP_SCALE,STATE_EXP_INITIAL_PRODUCT,STATE_EXP_INITIAL_REMAINDER,STATE_EXP_CORRECTED_PRODUCT,STATE_EXP_NEGATIVE_REMAINDER,STATE_EXP_POSITIVE_REMAINDER,STATE_EXP_POLY_MUL,STATE_EXP_POLY_ADD,STATE_EXP_SCALE_DOWN,STATE_FINAL_POLY_EXP,STATE_FINAL_ERF_SUB,STATE_FINAL_ONE_PLUS,STATE_FINAL_HALF,STATE_FINAL_RESULT,STATE_DONE` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | MIXED / protocol — khi vẽ: state-qualified outputs có thể xem là Moore-like; guard/input quyết định transition và registered micro-op là Mealy-controlled. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Serial no-DSP GELU |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `STATE_IDLE` | `NaN or -Inf -> qNaN,DONE` | `STATE_DONE` | `input_value; result` | `NaN or -Inf -> qNaN,DONE` |
| 2 | `STATE_IDLE` | `+Inf -> +Inf,DONE` | `STATE_DONE` | `input_value; result` | `+Inf -> +Inf,DONE` |
| 3 | `STATE_IDLE` | `either signed zero -> +0,DONE` | `STATE_DONE` | `input_value; result` | `either signed zero -> +0,DONE` |
| 4 | `STATE_IDLE` | `No start self. On start latch value; NaN or -Inf -> qNaN,DONE; +Inf -> +Inf,DONE; either signed zero -> +0,DONE; otherwise SCALE.` | `STATE_SCALE_VALUE` | `input_value; result` | `No start self. On start latch value; NaN or -Inf -> qNaN,DONE; +Inf -> +Inf,DONE; either signed zero -> +0,DONE; otherwise SCALE.` |
| 5 | `STATE_DENOMINATOR_MUL` | `Register scaled input, denominator product, then denominator sum; advance one state each edge.` | `STATE_DENOMINATOR_ADD` | `temporary_result` | `Register scaled input, denominator product, then denominator sum; advance one state each edge.` |
| 6 | `STATE_DENOMINATOR_ADD` | `Register scaled input, denominator product, then denominator sum; advance one state each edge.` | `STATE_RECIPROCAL_INIT` | `reciprocal_denominator` | `Register scaled input, denominator product, then denominator sum; advance one state each edge.` |
| 7 | `STATE_RECIPROCAL_INIT` | `Denominator +Inf -> estimate=0,poly step=0,GELU_POLY_MUL` | `STATE_GELU_POLY_MUL` | `reciprocal_iteration; reciprocal_estimate; gelu_polynomial_step` | `Denominator +Inf -> estimate=0,poly step=0,GELU_POLY_MUL` |
| 8 | `STATE_RECIPROCAL_INIT` | `otherwise magic seed -> RECIP_PRODUCT.` | `STATE_RECIPROCAL_PRODUCT` | `reciprocal_iteration; reciprocal_estimate; gelu_polynomial_step` | `otherwise magic seed -> RECIP_PRODUCT.` |
| 9 | `STATE_RECIPROCAL_PRODUCT` | `Newton reciprocal micro-ops. ESTIMATE commits new estimate; old iteration==3 -> polynomial; else iteration++ and loop. Thus four estimates.` | `STATE_RECIPROCAL_CORRECTION` | `reciprocal_product` | `Newton reciprocal micro-ops. ESTIMATE commits new estimate; old iteration==3 -> polynomial; else iteration++ and loop. Thus four estimates.` |
| 10 | `STATE_RECIPROCAL_CORRECTION` | `Newton reciprocal micro-ops. ESTIMATE commits new estimate; old iteration==3 -> polynomial; else iteration++ and loop. Thus four estimates.` | `STATE_RECIPROCAL_ESTIMATE` | `reciprocal_correction` | `Newton reciprocal micro-ops. ESTIMATE commits new estimate; old iteration==3 -> polynomial; else iteration++ and loop. Thus four estimates.` |
| 11 | `STATE_RECIPROCAL_ESTIMATE` | `Newton reciprocal micro-ops. ESTIMATE commits new estimate; old iteration==3 -> polynomial; else iteration++ and loop. Thus four estimates.` | `STATE_GELU_POLY_MUL` | `reciprocal_estimate; gelu_polynomial_step; reciprocal_iteration` | `Newton reciprocal micro-ops. ESTIMATE commits new estimate; old iteration==3 -> polynomial; else iteration++ and loop. Thus four estimates.` |
| 12 | `STATE_RECIPROCAL_ESTIMATE` | `Newton reciprocal micro-ops. ESTIMATE commits new estimate; old iteration==3 -> polynomial; else iteration++ and loop. Thus four estimates.` | `STATE_RECIPROCAL_PRODUCT` | `reciprocal_estimate; gelu_polynomial_step; reciprocal_iteration` | `Newton reciprocal micro-ops. ESTIMATE commits new estimate; old iteration==3 -> polynomial; else iteration++ and loop. Thus four estimates.` |
| 13 | `STATE_GELU_POLY_MUL` | `Horner sequence: MUL step4 commits polynomial and -> SQUARE` | `STATE_SQUARE` | `gelu_polynomial; temporary_result` | `Horner sequence: MUL step4 commits polynomial and -> SQUARE` |
| 14 | `STATE_GELU_POLY_MUL` | `Horner sequence: MUL step4 commits polynomial and -> SQUARE; steps0..3 store temp -> ADD; ADD commits polynomial,step++ -> MUL. Five mul/four add edges.` | `STATE_GELU_POLY_ADD` | `gelu_polynomial; temporary_result` | `Horner sequence: MUL step4 commits polynomial and -> SQUARE; steps0..3 store temp -> ADD; ADD commits polynomial,step++ -> MUL. Five mul/four add edges.` |
| 15 | `STATE_GELU_POLY_ADD` | `Horner sequence: MUL step4 commits polynomial and -> SQUARE; steps0..3 store temp -> ADD; ADD commits polynomial,step++ -> MUL. Five mul/four add edges.` | `STATE_GELU_POLY_MUL` | `gelu_polynomial; gelu_polynomial_step` | `Horner sequence: MUL step4 commits polynomial and -> SQUARE; steps0..3 store temp -> ADD; ADD commits polynomial,step++ -> MUL. Five mul/four add edges.` |
| 16 | `STATE_SQUARE` | `Register square and scaled exponent argument. INITIAL_PRODUCT captures integer scale; >=127 sets exp=0 -> FINAL_POLY_EXP, else captures product -> INITIAL_REMAINDER.` | `STATE_EXP_SCALE` | `squared_value` | `Register square and scaled exponent argument. INITIAL_PRODUCT captures integer scale; >=127 sets exp=0 -> FINAL_POLY_EXP, else captures product -> INITIAL_REMAINDER.` |
| 17 | `STATE_EXP_SCALE` | `Register square and scaled exponent argument. INITIAL_PRODUCT captures integer scale; >=127 sets exp=0 -> FINAL_POLY_EXP, else captures product -> INITIAL_REMAINDER.` | `STATE_EXP_INITIAL_PRODUCT` | `exp_scaled` | `Register square and scaled exponent argument. INITIAL_PRODUCT captures integer scale; >=127 sets exp=0 -> FINAL_POLY_EXP, else captures product -> INITIAL_REMAINDER.` |
| 18 | `STATE_EXP_INITIAL_PRODUCT` | `>=127 sets exp=0 -> FINAL_POLY_EXP, else captures product -> INITIAL_REMAINDER.` | `STATE_FINAL_POLY_EXP` | `exp_scale_integer_initial; exponential; exp_scale_product` | `>=127 sets exp=0 -> FINAL_POLY_EXP, else captures product -> INITIAL_REMAINDER.` |
| 19 | `STATE_EXP_INITIAL_PRODUCT` | `Register square and scaled exponent argument. INITIAL_PRODUCT captures integer scale; >=127 sets exp=0 -> FINAL_POLY_EXP, else captures product -> INITIAL_REMAINDER.` | `STATE_EXP_INITIAL_REMAINDER` | `exp_scale_integer_initial; exponential; exp_scale_product` | `Register square and scaled exponent argument. INITIAL_PRODUCT captures integer scale; >=127 sets exp=0 -> FINAL_POLY_EXP, else captures product -> INITIAL_REMAINDER.` |
| 20 | `STATE_EXP_INITIAL_REMAINDER` | `Register range-reduction remainder; apply negative and positive correction predicates; set final integer/remainder, exp-poly step=0.` | `STATE_EXP_CORRECTED_PRODUCT` | `exp_remainder_initial` | `Register range-reduction remainder; apply negative and positive correction predicates; set final integer/remainder, exp-poly step=0.` |
| 21 | `STATE_EXP_CORRECTED_PRODUCT` | `Register range-reduction remainder; apply negative and positive correction predicates; set final integer/remainder, exp-poly step=0.` | `STATE_EXP_NEGATIVE_REMAINDER` | `exp_correct_negative; exp_scale_integer_after_negative; exp_scale_product` | `Register range-reduction remainder; apply negative and positive correction predicates; set final integer/remainder, exp-poly step=0.` |
| 22 | `STATE_EXP_NEGATIVE_REMAINDER` | `Register range-reduction remainder; apply negative and positive correction predicates; set final integer/remainder, exp-poly step=0.` | `STATE_EXP_POSITIVE_REMAINDER` | `exp_remainder_negative` | `Register range-reduction remainder; apply negative and positive correction predicates; set final integer/remainder, exp-poly step=0.` |
| 23 | `STATE_EXP_POSITIVE_REMAINDER` | `Register range-reduction remainder; apply negative and positive correction predicates; set final integer/remainder, exp-poly step=0.` | `STATE_EXP_POLY_MUL` | `exp_scale_integer_final; exp_remainder_final; exp_polynomial_step` | `Register range-reduction remainder; apply negative and positive correction predicates; set final integer/remainder, exp-poly step=0.` |
| 24 | `STATE_EXP_POLY_MUL` | `Eight Horner terms: MUL stores temp -> ADD; ADD step7 -> SCALE_DOWN, else step++ -> MUL.` | `STATE_EXP_POLY_ADD` | `temporary_result` | `Eight Horner terms: MUL stores temp -> ADD; ADD step7 -> SCALE_DOWN, else step++ -> MUL.` |
| 25 | `STATE_EXP_POLY_ADD` | `Eight Horner terms: MUL stores temp -> ADD; ADD step7 -> SCALE_DOWN, else step++ -> MUL.` | `STATE_EXP_SCALE_DOWN` | `exp_polynomial; exp_polynomial_step` | `Eight Horner terms: MUL stores temp -> ADD; ADD step7 -> SCALE_DOWN, else step++ -> MUL.` |
| 26 | `STATE_EXP_POLY_ADD` | `Eight Horner terms: MUL stores temp -> ADD; ADD step7 -> SCALE_DOWN, else step++ -> MUL.` | `STATE_EXP_POLY_MUL` | `exp_polynomial; exp_polynomial_step` | `Eight Horner terms: MUL stores temp -> ADD; ADD step7 -> SCALE_DOWN, else step++ -> MUL.` |
| 27 | `STATE_EXP_SCALE_DOWN` | `Register scaled polynomial exponential -> FINAL_POLY_EXP.` | `STATE_FINAL_POLY_EXP` | `exponential` | `Register scaled polynomial exponential -> FINAL_POLY_EXP.` |
| 28 | `STATE_FINAL_POLY_EXP` | `Multiply polynomial*exp; subtract/clamp magnitude to [0,1]; add one; multiply half; multiply original input; register result -> DONE.` | `STATE_FINAL_ERF_SUB` | `polynomial_exponential` | `Multiply polynomial*exp; subtract/clamp magnitude to [0,1]; add one; multiply half; multiply original input; register result -> DONE.` |
| 29 | `STATE_FINAL_ERF_SUB` | `Multiply polynomial*exp; subtract/clamp magnitude to [0,1]; add one; multiply half; multiply original input; register result -> DONE.` | `STATE_FINAL_ONE_PLUS` | `erf_magnitude` | `Multiply polynomial*exp; subtract/clamp magnitude to [0,1]; add one; multiply half; multiply original input; register result -> DONE.` |
| 30 | `STATE_FINAL_ONE_PLUS` | `Multiply polynomial*exp; subtract/clamp magnitude to [0,1]; add one; multiply half; multiply original input; register result -> DONE.` | `STATE_FINAL_HALF` | `one_plus_erf` | `Multiply polynomial*exp; subtract/clamp magnitude to [0,1]; add one; multiply half; multiply original input; register result -> DONE.` |
| 31 | `STATE_FINAL_HALF` | `Multiply polynomial*exp; subtract/clamp magnitude to [0,1]; add one; multiply half; multiply original input; register result -> DONE.` | `STATE_FINAL_RESULT` | `half_value` | `Multiply polynomial*exp; subtract/clamp magnitude to [0,1]; add one; multiply half; multiply original input; register result -> DONE.` |
| 32 | `STATE_FINAL_RESULT` | `register result -> DONE.` | `STATE_DONE` | `result` | `register result -> DONE.` |
| 33 | `STATE_DONE` | `unconditional IDLE.` | `STATE_IDLE` | `CONTROL_ONLY` | `unconditional IDLE.` |
| 34 | `default 26..31` | `state->IDLE; datapath/result hold; no error flag.` | `state->IDLE; datapath/result hold; no error flag.` | `state` | `state->IDLE; datapath/result hold; no error flag.` |

## 44. `CE-ARGMAX` — `vit_argmax_engine_fp32`
| Thuộc tính | Giá trị |
|---|---|
| Classification | `explicit` |
| State register / tracker | `state` |
| State encoding | `STATE_IDLE,STATE_SCAN,STATE_RESULT,STATE_DONE` |
| Clock / Reset | `clk` / `rst (synchronous active-high)` |
| Moore / Mealy | MIXED / protocol — khi vẽ: state-qualified outputs có thể xem là Moore-like; guard/input quyết định transition và registered micro-op là Mealy-controlled. G2: MIXED_OR_PROTOCOL; exact registered side effects listed |
| Purpose | Scan class logits |

| # | Current state / mode | Transition guard / signal | Next state / update | Registered micro-op / control effect | Arrow label nên ghi |
|---:|---|---|---|---|---|
| 1 | `STATE_IDLE` | `cfg_length==0 -> config_error,DONE` | `STATE_DONE` | `element_index; have_best; input_nonfinite_error; config_error; active_length` | `cfg_length==0 -> config_error,DONE` |
| 2 | `STATE_IDLE` | `otherwise latch length -> SCAN.` | `STATE_SCAN` | `element_index; have_best; input_nonfinite_error; config_error; active_length` | `otherwise latch length -> SCAN.` |
| 3 | `STATE_SCAN` | `If last, choose current if better, else prior best, else {index=0,value=qNaN} and -> RESULT` | `STATE_RESULT` | `input_nonfinite_error; have_best; best_index; best_value; result_index_reg; result_value_reg; element_index` | `If last, choose current if better, else prior best, else {index=0,value=qNaN} and -> RESULT` |
| 4 | `STATE_RESULT` | `ready -> DONE.` | `STATE_DONE` | `NONE_BEYOND_STATE` | `ready -> DONE.` |
| 5 | `STATE_DONE` | `unconditional IDLE.` | `STATE_IDLE` | `NONE_BEYOND_STATE` | `unconditional IDLE.` |
| 6 | `default 4..7` | `illegal recovery.` | `set config error, return IDLE; result registers hold.` | `state` | `illegal recovery.` |
