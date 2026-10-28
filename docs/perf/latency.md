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
