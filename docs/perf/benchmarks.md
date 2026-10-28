# Benchmarks

How zigguro's macro benchmarks get their inputs and how they run. Micro benches follow the E00 convention (`bench/main.zig` per package, [bench-format.md](../bench-format.md)). Startup has its own harness ([startup.md](startup.md)), and so does typing latency ([latency.md](latency.md)).

## Corpora

Benchmarks run against synthetic corpora that `corpusgen` generates deterministically from a profile, a seed and the generator version, with std only. Corpora are cached and never committed or downloaded.

```
zig build corpus -- linux                 # generates (or reuses) the cached corpus, prints its folder
zig build corpus -- chromium --tree       # real files instead of paths only
zig build corpus -- bigfile_1g --sparse   # right size, no content
zig build corpus -- notes_10k --out DIR --verify
```

The code is `tools/corpusgen/` (`lib.zig` is the `zg_corpus` module). A scenario or bench asks for a corpus with:

```zig
const zg_corpus = @import("zg_corpus");
const root = zg_corpus.cacheRoot(env, fallback); // ZG_CORPUS_DIR, else <global zig cache>/zg-corpus
const dir = try zg_corpus.ensure(gpa, io, .{ .profile = .lines_100k }, root);
```

`ensure` returns the cached folder when its `MANIFEST.json` matches (version, profile, seed, scale and the Blake3 of `paths.txt`) and generates it otherwise. A cache hit takes a few milliseconds.

### Profiles

| Profile | What | Default | Measured (cloud, ReleaseFast) |
|---|---|---|---|
| `linux` | 108 158 files in 6 000 dirs, depth up to 9 | files | 1.52 GB, 37.4 M lines, 10.3 s |
| `chromium` | 1 000 000 paths in 80 000 dirs, depth up to 14, long names, `third_party` subtrees, test-data clusters | paths only | 4.6 s |
| `huge` | 2 000 000 paths, for fuzzy-finder and explorer stress | paths only | 11.8 s |
| `lines_100k` | one Zig-like file of 100 000 lines | file | 4.1 MB, 57 ms |
| `bigfile_1g` | one 1 GiB log (timestamps, levels, messages) | file (`--sparse` for size only) | 13.6 M lines, 7.1 s (sparse: 3 ms) |
| `minified_50m` | one 50 MB line of JSON-like tokens | file | 0.3 s |
| `notes_10k` | 10 000 Markdown notes with frontmatter, tags, headings and `[[wikilinks]]` | files | 6.4 MB, 0.5 s |
| `mixed_unicode_10m` | 10 MB of CJK, Hebrew, Arabic, combining marks and emoji ZWJ sequences | file | 45 ms |

Each folder holds `paths.txt` (sorted, `/`-separated, one per line), `paths.bin` (u32 little-endian length, then the bytes, per path), `MANIFEST.json` and, unless paths only, the files.

### The shape model

The values are model parameters, not copied data.

- **Directories** attach to a parent picked with probability proportional to its child count plus one (preferential attachment), below the depth limit. This gives the Zipf-like fan-out of real trees. `drivers` and `arch` in `linux`, and `third_party`, `chrome` and `components` in the Chromium-like profiles, start with extra weight.
- **Files** go to a directory with probability proportional to the files it already has, plus one. A few directories end up with more than 1 000 entries.
- **Extensions** are dealt from exact quotas, then shuffled, so the shares are exact. In `linux`: `.c` 45 %, `.h` 22 %, `.rst`/`.txt` 8 %, `.yaml` 5 %, `.S` 2 %, `Makefile`/`Kconfig` 6 %, and 12 % of others (`.sh`, `.py`, `.json`, `.dts`, `.rs`).
- **File sizes** are log-normal with a median of 6 KiB, p99 about 90 KiB and a cap of 384 KiB. With 108 k files that gives about 1.5 GB and, at about 40 bytes a line, about 40 M lines: the scale of Linux 7.2 (108 158 files, 43.9 M lines). The p99 is below the "200 KiB" first estimate because a log-normal with that tail would put the total near 2.6 GB.
- **Lines** are 70 % code-like (indentation that follows braces, identifiers, operators, numbers), 20 % comments and 10 % blank. Line lengths before indentation are log-normal with a median of 33 and p99 120 (mean about 38).
- **Names** come from a fixed syllable table (`kmem_cache_pool`, `vrtx_q2_ctrl`). Collisions get `_2`, `_3`, and so on.
- **Notes** link to targets picked by preferential attachment, so in-degree is heavy-tailed. 2 % of links point at notes that do not exist, like real vaults.
- **Unicode** comes only from fixed tables of assigned characters.

### Determinism

- One `std.Random.DefaultPrng` (Xoshiro256), seeded from `seed ^ Wyhash(profile)`, plans the tree.
- Each file's content comes from its own PRNG, seeded from `Wyhash(seed, path)`. Contents therefore don't depend on the order files are written in, and the writers split the sorted list across workers.
- Distributions are integer tables only: a size is a uniform pick inside one of 64 equal-probability buckets whose edges are pinned in `profiles.zig`. Every draw is a `u64`, so 32- and 64-bit targets match. No floating point, time or OS entropy is used.
- The digest is Blake3 over the Blake3 of `paths.txt`, then each file's Blake3 in path order. `paths_only` corpora use the `paths.txt` digest alone. For `--sparse`, a file's digest covers its size.
- `zig build test-tools` pins the digest of `linux` at 1 % scale. Bump `zg_corpus.version` together with the pinned digest whenever the output changes on purpose. Baselines record the corpus version, so a bump invalidates them.

## Running everything

```
zig build bench -Doptimize=ReleaseFast                    # every package's bench binary
zig build bench -Doptimize=ReleaseFast -Dbench-repeats=5  # each binary 5 times, for perfgate
```

Each package writes `zig-out/bench-results/<package>.json` (the first run), and `perfgate merge` folds every run into `zig-out/bench-results/all.json`: per result, `samples_ns` gathers each run's samples (or its `ns_per_op`) and the other numbers are medians over the runs. `-Dbench-quick` and `-Dbench-filter` still apply. perfgate is described in [perf/baselines/README.md](../../perf/baselines/README.md).

## Scenarios

A scenario drives the composed app through one macro workload (`zg_perf.scenario`, `packages/perf/src/scenario/`):

```zig
const sc = zg_perf.scenario;
pub const scenario: sc.Scenario = .{
    .name = "view_switch",
    .budgets = &.{"ui.view_switch"},
    .repeats = 10,
    .setup = setup,
    .run = run, // fn (*sc.Context) !void, once per repeat
    .teardown = teardown,
};

fn run(c: *sc.Context) !void {
    var m = c.measurement();
    m.start();
    // ... command, then wait for the frame ...
    m.stop();
    try c.record("command_to_frame", m.sampleNs()); // result "view_switch.command_to_frame"
}
```

`runScenario` calls `setup` once, `run` for the warm-up repeats (samples dropped), then the measured repeats (`quick_repeats` with `Context.quick`), and `teardown` even after a failure. `Context.writeJson` writes E00 bench JSON (package `scenarios`) with every sample, so perfgate can compare them. Every result binds to a budget in `budgets.zon`.

## Environment

`zg_perf.scenario.captureEnv` records the CPU model, logical CPUs, frequency governor, turbo boost, AC or battery power, OS and kernel (Linux: `/proc/cpuinfo`, cpufreq sysfs, `/sys/class/power_supply`; Windows: the registry's `ProcessorNameString`, `GetSystemPowerStatus`, `RtlGetVersion`). The caller adds the git SHA, refresh rate, corpus version and machine class. `warnings` prints what [Google Benchmark's variance guide](https://github.com/google/benchmark/blob/main/docs/reducing_variance.md) warns about: a governor other than `performance`, boost on, battery power. They are reported, never fatal. `zig build perfgate -- env` prints both.

`stabilize` pins the calling thread to one CPU (`sched_setaffinity`, `SetThreadAffinityMask`) and raises its priority where allowed, and reports what it did. Micro benches can be pinned. Scenarios use many threads, so they only get the priority.

## Calibration

```
zig build perf-calibrate     # zig-out/bench-results/calibration.json
```

Four fixed kernels run for 0.5 s each (always ReleaseFast):

- an integer hash round;
- a streaming copy of 64 MiB;
- a lookup in a 4 095-node array-laid binary search tree with pseudo-random keys;
- an allocation and free of 16 to 4 096 bytes.

The scale is the geometric mean of ns/op over the reference numbers in `perf/baselines/ref_laptop_2024/calibration.json`, so above 1 means slower than the reference laptop. perfgate takes it with `--calibration` and uses it only for advisory (`budget_warn`) checks of absolute budgets on other machines. Blocking absolute checks run on the reference machine.

The checked-in reference is **provisional**: it was recorded on a cloud VM (Xeon @ 2.1 GHz). Re-record it on the reference laptop by copying the output of `zig build perf-calibrate` there. On that VM two runs differed by about 4 %.

## App scenarios

```
zig build bench-scenarios -Doptimize=ReleaseFast   # zig-out/bench-results/scenarios.json
zig build test-bench-scenarios                     # each once in quick mode (part of zig build test)
zigguro --bench-scenario=view_switch [--bench-quick] [--bench-repeats=N] [--bench-out=FILE] [--bench-corpus-root=DIR]
```

The runner (`apps/zigguro/src/bench/runner.zig`) runs one scenario per process on the headless platform with the software renderer. Frames are driven on the platform's virtual clock, so a measurement is CPU time from the action to the end of the frame that shows it. Presentation needs a real window: `zig build bench-latency`. Corpora come from `corpusgen`, cached under `ZG_CORPUS_DIR` or `<tmp>/zg-corpus`.

| Scenario | What it does | Results → budget |
|---|---|---|
| `view_switch` | Toggles the side bar, terminal, agent pane, review queue and theme on and off, 10 commands per cycle, 10 cycles | `command_to_frame` → `ui.view_switch` |
| `editing_100k` (alias `typing_100k`) | 500 keys into the middle of `lines_100k`, one frame per key; reads each key frame's UI CPU from the frame timeline | `frame_cpu` → `ui.frame_cpu_keystroke` |
| `open_1gb` | Opens `bigfile_1g` in a fresh workbench, 5 times | `first_screen` → `file.open_1gb_first_screen` |
| `fuzzy_find_1m` | Ranks the 1 M `chromium` paths for 20 fixed queries with the quick-pick matcher, keeping the best 50 | `ranked` → `workspace.fuzzy_find_1m` |
| `idle` (alias `idle_memory`) | Opens the `linux` workspace, 5 files and the terminal, settles 5 s, then idles 30 s on the real clock | `wakeups_per_s` → `idle.wakeups`, `cpu_pct` → `idle.cpu`, `private_bytes` → `mem.idle_private`, `rss_bytes` |

Quick mode uses small corpora (5 % of `lines_100k`, 64 MiB instead of 1 GiB, 10 k paths, a 1 % `linux`) and fewer repeats.

Not yet covered:
- `agents_10_streaming`: it needs the E10 replay provider wired into the app.
- `fuzzy_find_1m` excludes painting, because the app has no file quick-open yet.
- `input.key_to_photon` comes from `bench-latency`.

Samples are integers. Rates and percentages (`per_second` and `percent` budgets) are therefore recorded in thousandths: 250 means 0.25 wakeups/s. perfgate divides them back when it checks the budget. Scenario budgets bind to suite `scenarios`, result `<scenario>.<metric>`, using the field of the budget's statistic (`max` from the samples).
