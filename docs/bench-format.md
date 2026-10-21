# Benchmark output format (schema 1)

`zig build bench` runs each package's `<name>-bench` executable (always ReleaseFast) and writes `zig-out/bench-results/<package>.json`. E14 (E14.F06) consumes these files for budget gates; any change to the schema bumps `schema`.

```json
{
  "schema": 1,
  "package": "zg_core",
  "zig": "0.16.0",
  "target": "x86_64-linux",
  "optimize": "ReleaseFast",
  "cpu": "znver4",
  "quick": false,
  "results": [
    {
      "name": "mailbox post+drain (1 producer)",
      "iters": 2640120,
      "ns_per_op": 71.6,
      "p50_ns": 71.9,
      "p99_ns": 79.7,
      "bytes_per_op": null,
      "allocs_per_op": 0,
      "bytes_alloc_per_op": 0
    }
  ]
}
```

| Field | Meaning |
|---|---|
| `schema` | Format version, currently 1. |
| `package` | Package name (`--package`). |
| `zig`, `target`, `optimize`, `cpu` | Toolchain version, `<arch>-<os>`, build mode and CPU model of the measuring binary. |
| `quick` | True for `-Dbench-quick` runs (20 ms measurement, 5 ms warmup); do not gate on quick runs. |
| `results[].name` | Benchmark name; stable across runs so results can be compared. |
| `results[].iters` | Operations measured (after warmup). |
| `results[].ns_per_op` | Mean nanoseconds per operation over all samples. |
| `results[].p50_ns`, `p99_ns` | Median and 99th percentile of per-sample ns/op (each sample is at least 1 ms of work). |
| `results[].bytes_per_op` | Bytes processed per operation if the benchmark declared it (`State.setBytes`), else null. Throughput = `bytes_per_op / ns_per_op` GB/s. |
| `results[].allocs_per_op`, `bytes_alloc_per_op` | Allocations and bytes allocated per operation through `State.allocator()`. |

Method: warm up for `warmup_ns` (doubling the batch), size batches so each sample takes at least 1 ms, then collect samples until `min_time_ns` has passed and at least 10 samples exist.
