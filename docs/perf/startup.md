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

## Not done yet

- `gpu_ready` and the E08 `session_restored` marks belong to their owners.
- The loader estimate for Linux (spawn to `main_entered`, measured by `bench-startup`) comes with the startup scenario (E14.F06).
- Deferring work off the critical path (`Lazy`, `InitRegistry`, the critical-path allowlist) is E14.F05.S01.T02.
