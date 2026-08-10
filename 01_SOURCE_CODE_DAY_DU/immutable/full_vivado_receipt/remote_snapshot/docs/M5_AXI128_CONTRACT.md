# M5 native AXI-128 protocol contract

This bundle is an isolated child of the promoted M4-R8 bundle whose manifest
SHA-256 is
`c310266a85500069dfa20e9b72d2cd9d8bb7b0db1e858cda603ba78070fab828`.
The parent is immutable.

The production DDR master becomes 128 bits while the internal logical memory
response remains one FP32 word. Read-ahead is enabled only when the frontend
supplies an exact, proven contiguous-run length. The first production scope is
blocked K16/N2 MODEL B; all other accesses retain a correctness-first narrow
fallback.

Sealed design parameters:

```text
AXI data width            128 bits
words per full beat       4
blocked-B safe run        32 words
maximum burst             4 beats
read outstanding          2
write outstanding         1
logical request FIFO      depth 2
logical response FIFO     depth 2, ordered
ID policy                 same ID, in-order responses
```

When a logical request or response FIFO is empty, its front end has a
fall-through path. This preserves the depth-2 buffering contract under
backpressure without imposing an unconditional enqueue/dequeue bubble on
every scalar logical access. An older stored response always has priority
over a new direct response.

No burst may cross a configured memory region or a 4 KiB boundary. The
adapter validates RID/BID/RRESP/BRESP and exact RLAST/WLAST position, keeps
VALID payload stable under backpressure, and invalidates read-ahead state
after any scratch write. `RRESP`/`BRESP` response errors drain normally and
return an error to the logical client.

A structural RID/RLAST framing fault has a stricter fail-closed contract: the
adapter completes the active and already queued logical requests as ordered
errors, then remains permanently poisoned until reset. It does **not** claim
that already outstanding AXI burst traffic is drained, recovered or
re-synchronized after transaction framing is lost. There is no watchdog for a
slave that accepts a request and never responds.

Only frontend-proven contiguous blocked K16/N2 MODEL-B reads may use full
128-bit read-ahead. Writes and every other read use narrow scalar transfers on
the 128-bit bus; M5 does not coalesce writes.

The AXI4-Lite register bank is not rewritten. Existing register addresses are
protected. IP v1.6 appends the M5 counter bank at `0x7C0..0x80C`; its
machine-readable authority is `PERF_PROFILE_ABI_V1_6.json`. The response-wait
histogram read population is AR transactions, measures AR-to-first-R, and
retires a transaction only at RLAST.

The full E05 oracle expects zero discarded prefetched words. Compact E05
expects 16 discarded words from the padded odd-N=7 classifier tail; both
values are intentional and configuration-specific.

Current final-source simulation evidence (`SIM-MEASURED`, 2026-08-06):

- focused adapter protocol regression PASS, 409 checks;
- randomized raw-DDR and adapter-integration sweeps PASS, 8/8 seeds;
- production XSim suite PASS, 7/7 tests;
- compact E05 PASS, 249 commands, 907,897 total cycles and 900,581 job
  cycles; 20,611 AR transactions produce 24,139 R beats for 38,251 external
  FP32 payload words, with max read outstanding 2, zero protocol errors and
  16 intentionally discarded tail words;
- real E04 PASS, 168 checks and 29,497,114 cycles; numerical tolerances PASS,
  class 879 and logit `0x414887B9`; 811,016 AR transactions produce 955,016
  R beats, including 192,000 full and 763,016 narrow beats;
- final-source real E01 PASS, 159 checks and 424,112,402 cycles; all 151,296
  output words pass tolerance with maximum absolute error
  `1.788139343e-06`; 1,526,784 AR transactions produce 4,291,584 R beats,
  including 3,686,400 full and 605,184 narrow beats.

The reduced transaction counts do not yet prove a board speedup. Relative to
the M4-R8 simulations, compact job cycles regress by 4.459758% and real-E04
total cycles regress by 4.401004%, while the blocked-B-heavy real E01 improves
by 4.205524202%. Therefore M5 is not eligible for promotion from simulation
evidence alone. The bundle is sealed to its exact 68-source identity; Vivado
OOC/BD/full-route/BIT/XSA and physical-board gates have not passed yet.

Completion requires randomized protocol regression, compact E05 and real
E01/E04 numerical closure, BD validation, OOC and full route at 50 MHz,
post-route DSP=0, hashed BIT/XSA, and an exact physical E05 A/B result.
