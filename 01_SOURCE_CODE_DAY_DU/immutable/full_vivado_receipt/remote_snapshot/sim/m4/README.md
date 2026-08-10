# M4 cache-capacity and tail-safety gates

This directory adds simulation-only safety gates for the M4 R4/R8 reuse
work. It does not replace or modify production RTL.

Run from the revision root:

```bash
bash sim/m4/run_m4_capacity_safety_iverilog.sh
```

The script deliberately runs all tests with `ARRAY_ROWS=4` before repeating
them with `ARRAY_ROWS=8`:

- `tb_m4_cache_capacity.sv` checks every activation row bank at addresses 0
  and 3071, the bias-cache endpoints, address non-aliasing, synchronous read
  validity and clear cancellation/persistence.
- `tb_m4_frontend_cache_boundary.sv` checks the production frontend policy at
  exact `K/N=3072` capacity and the `3073` physical-read fallback. Its dynamic
  final-K16 gather proves that the safe case reaches index 3071 and that the
  fallback never writes an aliased cache entry.
- `tb_m4_tail_output_sentinel.sv` drives simultaneous M, K and N tails through
  the production operand and write routers. It proves that only valid M/N
  intersections are written and all padded output locations retain a sentinel.

These are RTL simulation gates. BRAM/URAM inference and post-route DSP/timing
remain separate Vivado evidence gates.
