# Measuring latency

How zigguro measures input-to-photon latency, and how much each number can be trusted. Budgets live in [budgets.md](budgets.md) (`input.key_to_photon` is 8 ms p99), and the tools in [profiling.md](profiling.md).

## 1. The clock contract

Every latency number is a difference of two timestamps, so all of them must come from one clock. This section is normative: platform (E01) and renderer (E02) changes that add or change a timestamp follow it. The code is `zg_perf.frame.clock_contract` (`packages/perf/src/frame/clock_contract.zig`).

### The domain

Every latency timestamp is nanoseconds on `zg_core.time.nowNs(io)`, which is `std.Io.Clock.awake`. In the Zig 0.16.0 standard library (`lib/std/Io/Threaded.zig`):

- On Linux, `.awake` is `CLOCK_MONOTONIC` (`.boot` would be `CLOCK_BOOTTIME`).
- On Windows, `.awake` and `.boot` are both `QueryPerformanceCounter` scaled to nanoseconds (`ns = qpc * 1e9 / qpf`, with a fast path for 10 MHz).

So Wayland `wp_presentation` times in `CLOCK_MONOTONIC`, X11 Present UST on Mesa, and QPC values on Windows convert without an offset. A source on any other clock must be converted before it reaches the timeline, or replaced by the time zigguro read it.

### The timestamps of a frame

| Timestamp | `FrameRecord` field | Taken by |
|---|---|---|
| Input event | `t_input_os_ns` | The platform backend, as `Event.*.time_ns` |
| Platform dequeue | `t_input_dequeue_ns` | The platform thread when it read the event |
| Frame start | `t_frame_start_ns` | `Window.frame` |
| Submit | `t_submit_ns` | The host after handing the frame to the renderer |
| GPU time | `gpu_ns` | Calibrated GPU timestamps (E02) |
| Presented | `t_presented_ns` | `Event.present_feedback`, or submit + one refresh when estimated |

### The ordering invariant

For every frame, `input ≤ dequeue ≤ frame start ≤ submit ≤ presented` (absent timestamps are skipped; estimated presentation times are derived from submit, so they cannot break it). A frame that breaks it has a clock-domain mismatch:

- The timeline counts it (`FrameTimeline.clock_violations`), logs the first one with the pair that is out of order, and emits the trace counter `perf.clock_violation`.
- The frame stays out of every latency histogram.
- The HUD shows `clock x N` in its first row.

### Plausibility checks in the host

Backends can report times on other clocks (the headless backend uses a virtual clock; a buggy driver may report UST on another base). The GUI host guards the timeline:

- An input time is used only when it is not in the future and at most one second old; otherwise the host uses the time it dispatched the event.
- Presentation feedback is matched to frames in submit order (each window keeps the present ids of its last 16 submits). Frames wait for feedback only after the window has had one plausible presentation time. One implausible time marks the window's feedback bad for the rest of its life, and its frames finalize as estimated (`key-photon ... est` in the HUD).

### Per-backend sources and error bars

`clock_contract.profileFor(backend, caps)` returns a `BackendLatencyProfile` with the resolution and accuracy of each source. Reports carry it so that numbers from different machines are only compared when their profiles match. Accuracy is one of `hardware`, `compositor_clock`, `software_estimate` (zigguro's own read time, an upper bound) and `unavailable` (estimated from other timestamps).

| Backend | Input time | Presentation time | Flags |
|---|---|---|---|
| Wayland | 1 ms `software_estimate`: `wl_keyboard.key` time is milliseconds with an undefined base, so the dequeue time is used. With `zwp_input_timestamps_v1`: 1 ns `compositor_clock`, checked against `wp_presentation.clock_id` | `wp_presentation_feedback.presented` in `clock_id` (normally `CLOCK_MONOTONIC`): `hardware` with the `hw_clock` flag, otherwise `compositor_clock` | vsync, hw_clock, hw_completion, zero_copy |
| X11 | 1 ms `software_estimate`: the server timestamp is milliseconds, so the dequeue time is used | Present `CompleteNotify` UST, 1 µs `compositor_clock` (`CLOCK_MONOTONIC` on Mesa; verify per driver). Without Present: estimated | The completion mode (copy, flip, skip) |
| Win32 | 1 ms `software_estimate`: `GetMessageTime` is milliseconds since boot and wraps; it is anchored to QPC, and the dequeue time (QPC when `GetMessage`/`PeekMessage` returned) is the lower bound | GDI: QPC after the present, `software_estimate`. `vkWaitForPresentKHR`: completion time, an upper bound. `VK_EXT_present_timing`: past presentation timing converted through calibrated timestamps, `compositor_clock` | None for GDI; present stages with present timing |
| Cocoa | NSEvent timestamp, not yet anchored | Estimated | None |
| Headless | Virtual clock; the host stamps the dispatch time | Virtual vsync clock; the host ignores it (frames are estimated) | vsync |

Today every real backend stamps input events with `nowNs` when it reads them, so input times are `software_estimate` everywhere until input-timestamp protocols are wired up.

### Conformance

The backend conformance suite (`packages/platform/src/testing/conformance.zig`) checks the input half on every backend that can synthesise keys: the key's `time_ns` must not be in the future and must be under 50 ms old when `pollEvents` returns it. Harnesses on a virtual clock (headless) declare `virtual_clock` and skip it. Presentation times are checked by the backends that send feedback (the Wayland `wp_presentation` test under Weston, the Win32 CPU present test).

Still to verify on real hardware: Wayland presentation feedback with `hw_clock` on a GPU driver, X11 Present UST on non-Mesa drivers, and `VK_EXT_present_timing` on Windows.

## 2. bench-latency

`zig build bench-latency -Doptimize=ReleaseFast` types into a generated 100 000-line file in the real workbench and writes `zig-out/bench-results/latency.json` (E00 bench JSON, `package` "app"). The scenario runs inside the app (`zigguro --bench-scenario=latency`, `apps/zigguro/src/bench/latency.zig`); the build step passes the options below.

| Build option | App flag | Default |
|---|---|---|
| `-Dbench-latency-injection=auto\|os\|ring` | `--bench-injection=` | `auto` |
| `-Dbench-latency-keys=N` | `--bench-keys=N` | 1000 |
| `-Dbench-latency-burst=true` | `--burst` (10 ms between keys) | 150 ms |
| | `--bench-warmup=N` | 50 |
| | `--bench-lines=N`, `--bench-corpus=PATH` | 100 000, in the temp folder |
| | `--bench-out=PATH` | |

The caret starts at line 50 000, column 10. The keys are a to z with a space every 8th key and 8 Backspaces after every 64, so the line stays short.

### Injection

- **os** opens a real window and types at the OS level, waiting the interval after each key so each key gets its own frame:
  - Linux: a uinput virtual keyboard. The compositor reads it like real hardware, under Wayland and X11. It needs write access to `/dev/uinput`; on `EACCES` the app logs the udev rule to add (`KERNEL=="uinput", SUBSYSTEM=="misc", TAG+="uaccess", OPTIONS+="static_node=uinput"`).
  - Windows: `SendInput` with scancodes. The window must be in the foreground.
- **ring** runs on the headless platform and queues key events there, one frame per key, with no waiting. Presentation times are estimated (submit + one refresh), so the key result is named `latency.ring_to_photon`. It runs in CI on any machine.
- **auto** tries `os` and falls back to `ring`.

### Results

| Result | Measures |
|---|---|
| `latency.key_to_photon` (or `latency.ring_to_photon`) | Input time to presentation |
| `latency.input_to_dispatch` | Input time to frame start |
| `latency.dispatch_to_submit` | Frame start to submit |
| `latency.submit_to_present` | Submit to presentation |
| `latency.frame_cpu` | UI-thread CPU of the frame |

Each result has `p50_ns`, `p95_ns`, `p99_ns`, `p999_ns` and `max_ns`. The file also carries the backend's `profile` from section 1, the injection mode, the refresh period, and the counts of estimated frames and clock violations. The budget `input.key_to_photon` (8 ms p99) applies to `latency.key_to_photon` from an `os` run.

A run fails (exit code 1) when nothing was measured, when the keys did not change the text, or when more than 5 % of the frames were estimated on a backend whose profile claims presentation feedback.
