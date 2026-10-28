# Startup

How zigguro times its startup. The goal is the first interactive frame in under 150 ms (`startup.first_interactive_frame` in [budgets.md](budgets.md)), with a budget per owning epic (`startup.phase.<owner>`). The code is `zg_perf.startup` (`packages/perf/src/startup/`).

## Phase marks

`zg_perf.startup.mark(.phase)` records a phase on the process's `StartupTimeline`. The first call wins. The first call costs about 45 ns (`perf.startup_mark`, budget 50 ns). Once a phase is set, a call costs one atomic load, so marks can sit on hot paths. A first mark also records the trace instant `startup.<phase>`, so the phases line up with everything else in a `ZG_TRACE=startup` trace.

| Phase | Marked by | Owner |
|---|---|---|
| `process_created` | The OS (see below), at `install` | os |
| `main_entered` | The first statement of `main` | os |
| `runtime_ready` | `main`, after `Runtime.init` | E00 |
| `config_loaded` | `main`, after settings.json and keybindings.json load | E15 |
| `platform_ready` | `main`, after the platform backend starts | E01 |
| `gpu_ready` | E02, once the renderer exists (not wired yet: window creation includes it) | E02 |
| `fonts_ready` | `main`, after the UI and monospace fonts load | E03 |
| `window_created` | `main`, after `Host.open` | E01 |
| `workbench_built` | `main`, after the workbench attaches to the window | E04 |
| `session_restored` | `main`, after the saved layout loads (the E08 session model will mark it itself) | E08 |
| `first_frame_submitted` | The Host, after the first submit | E04 |
| `first_frame_presented` | The Host, at the first plausible presentation feedback | E04 |
| `interactive` | The Host, the first time the UI thread waits for input after the first frame is presented (or submitted, when no window gets presentation feedback) | E04 |
| `first_input_handled` | The Host, after the first key or pointer press | E04 |

An owner's budget covers the time from the previous mark to each of its marks.

Marks taken before the runtime exists (`main_entered`) store raw CPU ticks; `install(io)` starts a tick calibration, and `summary()` converts them to the `.awake` clock.

## Process creation time

- **Linux:** `starttime` (field 22 of `/proc/self/stat`, counted after the last `)` because the command name can hold spaces), in clock ticks since boot. It is moved from the boot clock to the awake clock using the closest of three back-to-back reads of both. Clock ticks are 10 ms, so the total starts at `main_entered`, and "OS to main" is reported separately as a coarse number.
- **Windows:** the creation FILETIME from `GetProcessTimes`, moved from the real clock to the awake clock. Its resolution is 100 ns, so the total starts at process creation.

## The report

`zigguro --startup-report` prints the report once the first frame is interactive. Headless and `--frames` runs print it after their frames.

```
startup (cold_guess launch)
phase                     at ms     +ms  owner
process_created         -   8.0     0.0  os
main_entered                0.0     8.0  os
runtime_ready               1.2     1.2  e00
...
interactive                80.0     2.0  e04

OS to main 8.0 ms (process start resolution 10.0 ms)

owner      ms  budget
e00      1.2     2.0
e02     43.0    40.0  over
...

total 80.0 ms of 150.0 ms budget (main to interactive)
```

- "presentation estimated" means no presentation feedback arrived, so the submit time stands in for presentation.
- `warm` launches came less than 10 minutes after the previous one, when the OS file cache is probably still hot. `cold_guess` is everything else; neither is certain.

Interactive runs record each summary in `startup.json` in the state folder (the last 20 runs). The file is written atomically on a worker. Runs with `--frames` or on the headless platform don't write it.

`ZG_TRACE=startup` stops the trace 2 s after the first interactive frame.

## Deferring work

Anything that is not needed for the first frame waits.

- `zg_perf.startup.Lazy(T)` initialises a value on first use, from any thread: `try lazy.get(io, "name", initFn, args)`. Once ready, `get` is one acquire load. The first call runs `initFn` in the trace zone `init.<name>`. A failed init stays failed unless `retry` is set. On the UI thread, use `peek()` (never blocks) and `getAsync()` (starts the init on a worker) for values whose init blocks.
- `zg_perf.startup.InitRegistry` holds named services with a phase and dependencies:
  - `critical` services run in dependency order before the first frame. Ones flagged `parallel_ok` (GPU bring-up) run on a worker alongside window creation, and their dependents wait for them.
  - `after_first_frame` services run on one worker once `scheduleDeferred` is called at the first presented frame, highest priority first.
  - `idle` services run after those, once the activity signal reads idle.
  - `on_demand` services run only through `ensure(name)`.

  Each run is timed (`timings`) and traced as the zone `init.service`.

### Classification

The app's list is `apps/zigguro/src/startup/services.zig`. Today `main` still runs the critical steps inline in this order; services move onto the registry's scheduling as their owners give them an init function.

| Phase | Services |
|---|---|
| critical | runtime (E00), config and keymap (E15), fonts (E03), platform (E01), GPU (E02, parallel), window (E01), session model from its snapshot (E08), workbench (E04) |
| after_first_frame | font database, file watcher, indexer (E08), SCM (E09), LSP registry (E07), MCP catalog (E11, 0 ms on the critical path), agent session list (E10), CA bundle (E00), update check (E17) |
| idle | trigram index build, pipeline cache save, shader prewarm |
| on_demand | debugger (E07), terminal (first open), notes graph |

### Requesting a critical slot

`packages/perf/startup_allowlist.zon` lists every service allowed on the critical path and the budget it counts against. `zig build test-startup-allowlist` (in PR CI, and part of `zig build test`) fails when the app registers a critical service that is not listed, or when a listed one is gone. To add one:

1. Show that the service has to exist before the first frame, and that `Lazy`, `after_first_frame` or `idle` will not do.
2. Measure its cost with `--startup-report` and name the `startup.phase.<owner>` budget it fits in.
3. Add the entry to the allowlist in the same PR as the registration. E14 reviews changes to the file (CODEOWNERS).

## The startup benchmark

`zig build bench-startup -Doptimize=ReleaseFast -- --runs 20 --cold-runs 5 --workspace DIR` launches the real app again and again and writes `zig-out/bench-results/startup.json` (E00 bench JSON, package `startup`). The harness is `apps/zigguro/src/bench/startup.zig` (`zigguro-bench-startup`).

- Each launch gets `--startup-report-json=<tmp>/run-N.json --exit-after-startup --bench-inject-key-after-first-frame`. The child writes its marks as absolute `.awake` times, the clock the harness reads just before it spawns the child. So `startup.os_to_main` (spawn to `main_entered`) is exact, and `startup.first_interactive_frame` runs from spawn to the first interactive frame.
- Warm runs: 2 discarded warm-ups (`--warmup-runs`), then `--runs` measured runs.
- Cold runs (`--cold-runs`, results with `_cold`): as root on Linux, `sync` and `echo 3 > /proc/sys/vm/drop_caches` before each run (`cold_kind: drop_caches`). Otherwise, and on Windows, each run launches a fresh copy of the binary and of the workspace, files that are not in the page cache yet (`pseudo_cold`). Shared system libraries stay warm either way.
- Children get their own empty state folder (`ZIGGURO_STATE_DIR`), so the user's last folder and layout are left alone. Without `--workspace` they open the welcome window.
- `--platform headless` sets `ZG_PLATFORM` for the children. Headless results only compare with other headless results.
- On the headless platform the child injects one key after the first frame. A launch that handles it later than two frames after the first presented frame counts in `input_late` and fails the run. Native windows do not inject a key yet.
- Results:
  - `startup.first_interactive_frame` and `startup.os_to_main`;
  - `startup.phase.<owner>`, the time each owner's marks took, as in the report;
  - each with `p50_ns`, `p95_ns`, `p99_ns`, `max_ns` and every run in `samples_ns`.
- The `startup.first_interactive_frame` and `startup.phase.<owner>` budgets bind to the `p95_ns` of these results. The metadata says the platform, the cold kind, the refresh interval and the Linux CPU governor; the harness warns when the governor is not `performance`.
- `zig build test-bench-startup` (part of `zig build test`) runs 2 warm launches and 1 cold launch on the headless platform.

### True cold runs

Page-cache tricks leave shared libraries and the GPU driver warm. For a real cold number:

1. Reboot, log in and wait until the machine is idle (about 2 minutes).
2. Run `zigguro-bench-startup --exe zig-out/bin/zigguro --runs 1 --warmup-runs 0 --cold-runs 0 --workspace DIR --out cold.json` (build it first with `zig build bench-startup -Doptimize=ReleaseFast`).
3. Repeat from step 1 for each sample you need.

## Not done yet

- `gpu_ready` and the E08 `session_restored` marks belong to their owners.
- `--session` is accepted but not used until the E08 session model restores sessions.
- The reference-laptop baseline (`perf/baselines/ref_laptop_2024/startup.json`) comes with the baseline procedure (E14.F06.S02).
