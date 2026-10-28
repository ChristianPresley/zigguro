# Perf baselines

`perf/baselines/<machine>/<suite>.json` holds one bench suite's baseline on one machine class (`ci_linux_x64`, `ci_windows_x64`, `ref_laptop_2024`; see `packages/perf/budgets.zon`). Each row records the machine-independent numbers perfgate checks deterministically (allocations and bytes allocated per op) and an informational median. Rows are sorted by name so a change reviews as a small diff.

## How perfgate decides

`perfgate compare` runs the bench suites on the PR's base and head on the same runner and compares each result. Timings are never compared with stored numbers, only base against head from the same job, because shared runners drift.

| Verdict | Meaning |
|---|---|
| `regressed` | Allocations went up against the stored baseline (more than 0.5 alloc/op, or bytes up more than 5 %), or head is slower: a one-sided Mann–Whitney U test gives p < 0.01 and the median moved by more than the budget's `regression_tolerance_pct` (10 % without a budget). Needs at least 5 samples a side. |
| `improved` | The same test the other way. |
| `noisy` | A side's coefficient of variation is over 15 %: no verdict. |
| `budget_fail` | The head value breaks the bound budget on its own machine class (or the budget is machine-independent). |
| `budget_warn` | It breaks the budget scaled by the calibration factor on another machine class. Advisory. |
| `missing` | The bench is on one side only. |
| `pass` | None of the above. |

For higher-is-better budgets the test flips. Small samples without ties use the exact distribution; otherwise the normal approximation with tie and continuity correction.

A row **blocks** the PR when its budget's gate is `block` and the verdict is `regressed` or `budget_fail`. Warn and track gates only report. `zig build perfgate -- list-gated` lists the bench-bound budgets by gate.

`ref_laptop_2024/calibration.json` holds the reference ns/op of the calibration kernels (`zig build perf-calibrate`; see docs/perf/benchmarks.md). It is provisional until it is recorded on the reference laptop.

## Accepting a regression

Some regressions are the price of a feature. To accept one:

1. Add the `perf-accepted` label to the PR.
2. Regenerate the baseline for the affected machine class and commit it in the same PR:

   ```
   zig build perfgate -- merge --out merged.json <bench JSON files>
   zig build perf-baseline -Dmachine=ci_linux_x64 -- --from merged.json
   ```

3. Say why in the PR description.

The label alone is not enough: a blocking row clears only when the PR also changes `perf/baselines/<machine>/<suite>.json` for that suite. Reviewers see the accepted change as a diff.

## Commands

```
zig build perfgate -- merge --out FILE INPUT...
zig build perfgate -- compare --base FILE --head FILE [--baseline DIR] [--machine CLASS]
                              [--calibration FILE] [--accepted] [--changed-baselines FILE]
                              [--json FILE] [--markdown FILE] [--base-ref REF] [--head-ref REF]
zig build perfgate -- baseline --from FILE --machine CLASS --out DIR
zig build perfgate -- list-gated
zig build perfgate -- env
zig build perf-calibrate
```

Exit status: 0 pass, 1 blocking rows, 2 usage or input errors. `--calibration` takes `{"scale": x}`, the machine's speed against the reference laptop. `--changed-baselines` takes the PR's changed paths, one per line.
