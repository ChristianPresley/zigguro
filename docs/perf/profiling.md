# Profiling zigguro

How to find out where zigguro spends its time, from a one-off hitch to a hot function, on Linux and Windows. Budgets live in [budgets.md](budgets.md), the trace naming rules in [tracing-conventions.md](tracing-conventions.md), the threading rules in [threading.md](threading.md), and how latency is measured in [latency.md](latency.md).

## Which tool when

| Symptom | Start with | Then |
|---|---|---|
| Is it slow right now? | The HUD (`Ctrl+Alt+Shift+H`, **Toggle Performance HUD**, or `zigguro --hud`) | An in-app trace |
| A hitch you just saw | The flight recorder dump (`perf.flightRecorder.*`, written on slow frames, UI stalls and crashes) | An in-app trace of the same steps |
| A slow operation you can repeat | An in-app trace (`perf.trace.toggle` or `--trace=`) | Sampling with `perf` / WPA for the hot zone |
| A hot function | Sampling: `perf record --call-graph fp` (Linux), WPR CPU sampling (Windows) | `-Dprofile=true` build for symbols and zones |
| Slow startup | `ZG_TRACE=startup` | `zig build bench-startup` once it lands (E14.F05) |
| Memory growth | The memory page (E14.F04) | Allocation tags in the trace counters |
| GPU time | The GPU track (`gpu.*` zones) in the trace | RenderDoc, Nsight, Radeon GPU Profiler or PIX |

## Profiling builds

```sh
zig build -Dprofile=true
```

The preset turns on `-Doptimize=ReleaseFast` (unless you pass another mode), `-Dtracing=zones` (unless you pass `-Dtracing`), and keeps symbols. The flag goes through the shared `zg_build` flags, so every package sees the same settings. The app executables always keep frame pointers because crash reports need them. `zig build check-frame-pointers -Dprofile=true` verifies that: it finds the `zg_perf_fp_probe` symbol in the ELF symbol table or the PE export table and checks for `push rbp; mov rbp, rsp`.

Default builds compile every zone out (`-Dtracing=off`), so traces from them contain only thread names.

## In-app traces

- Command palette: **Start Performance Trace** / **Stop Performance Trace** (`perf.trace.start`, `perf.trace.stop`, `perf.trace.toggle`). **Show Performance Trace Folder** (`perf.trace.openFolder`) shows where traces go: `$XDG_STATE_HOME/zigguro/traces` (default `~/.local/state/zigguro/traces`) on Linux, `%LOCALAPPDATA%\zigguro\traces` on Windows.
- Command line: `zigguro --trace=out.pftrace` records until exit. `--trace-format=chrome` writes Chrome JSON instead.
- Environment: `ZG_TRACE=startup` records from `main` to the first frame + 2 s. `ZG_TRACE=<path>` records until exit, and `ZG_TRACE=startup:<path>` combines the two.

Stopping writes the file on a worker (temp file, then rename) and shows a toast with the path.

Open `.pftrace` files at [ui.perfetto.dev](https://ui.perfetto.dev). The UI runs in the browser and does not upload the trace. The layout:

- one track per named thread (`ui`, workers);
- a **GPU** track for `gpu.*` zones;
- one track per counter (`perf.key_to_photon_ns`, `perf.frame_cpu_ns`, ...);
- async lanes per span name (`ai.request`, `lsp.request`, `ai.request #2` when two overlap). Flows (arrows) connect work handed between threads.

Press `/` to search slice names, and click a slice to see its arguments. Flight recorder dumps carry a `perf.flight_recorder` instant with the trigger, note, build and dropped-event counts.

### trace_processor SQL

[trace_processor](https://perfetto.dev/docs/analysis/trace-processor) runs SQL over a trace: `trace_processor_shell -q <file.sql> trace.pftrace`, or the Query (SQL) page of the Perfetto UI. The tables you need:

- `slice`: every zone and async span (`ts`, `dur` in ns, `name`, `category`, `depth`, `parent_id`, `track_id`);
- `thread_track` and `thread`: which thread a slice ran on (`thread.name` is the name from `setThreadName`);
- `counter` and `counter_track`: counter samples by track name;
- `args`: slice arguments (flight recorder metadata), joined on `slice.arg_set_id`.

Recipes in `tools/perf/sql/`:

| File | Answers |
|---|---|
| [`slowest_frames.sql`](../../tools/perf/sql/slowest_frames.sql) | The 20 longest `gui.frame` slices |
| [`zone_self_time.sql`](../../tools/perf/sql/zone_self_time.sql) | Self time per zone name (duration minus direct children) |
| [`key_to_photon.sql`](../../tools/perf/sql/key_to_photon.sql) | The worst key-to-photon samples |
| [`ui_thread_blocking.sql`](../../tools/perf/sql/ui_thread_blocking.sql) | Top-level UI-thread work over 4 ms |

## The HUD

`Ctrl+Alt+Shift+H` (**Toggle Performance HUD**, `perf.hud.toggle`) or `zigguro --hud` shows an overlay in the top-right corner:

- a graph of the last 240 frames, one stacked bar per frame: dispatch, build, layout, paint, submit and GPU time. Lines mark the refresh period and 16.67 ms. Bars over the refresh period are drawn in the theme's danger colour;
- FPS, frame CPU p99 and the number of frames over budget, GPU p99, key-to-photon p50/p99 over the last 1 000 keys (`est` while no presentation feedback is wired up, so the photon time is submit + one refresh), wakeups per second and memory (the last two once E14.F04/F05 provide them).

Clicking a bar asks the flight recorder for a dump. The recorder runs in builds with zones (`-Dprofile=true`); it also dumps on slow frames. The HUD costs nothing while the app is idle: it refreshes at 4 Hz only while other frames are being drawn, then shows "idle" with the last values.

## Linux: perf and ftrace

Sample with frame-pointer unwinding:

```sh
perf record -F 999 --call-graph fp -k CLOCK_MONOTONIC -p "$(pidof zigguro)" -- sleep 10
perf report --no-children
```

- `--call-graph fp` walks frame pointers. It is cheap per sample, but it gives bogus stacks for code built without frame pointers. zigguro's apps always keep them. `--call-graph dwarf` works without frame pointers but copies 8 KiB of stack per sample.
- `-k CLOCK_MONOTONIC` stamps samples on the clock zigguro's traces use (`.awake` is `CLOCK_MONOTONIC` on Linux, and the Perfetto export stamps that clock id), so timestamps line up.
- `kernel.perf_event_paranoid` above 1 blocks profiling other processes as a normal user: `sudo sysctl kernel.perf_event_paranoid=1` for the session.
- `perf script > perf.txt` produces text that the Perfetto UI opens directly (Open trace file), next to an in-app trace of the same run.

**ftrace markers.** With `ZG_OS_TRACE=ftrace`, zones in the `gui`, `render`, `startup` and `perf` categories, plus every presented frame, are written to `/sys/kernel/tracing/trace_marker` as `zg:B|<tid>|<name>`, `zg:E|<tid>|<name>|<dur_ns>`, `zg:F|<seq>` and `zg:I|<name>|<value>`. The file is root-only by default; zigguro logs a warning and turns the bridge off when it cannot open it. Record the markers with:

```sh
sudo trace-cmd record -e ftrace:print -- zigguro     # or: perf record -e ftrace:print
```

## Windows: WPR and WPA

```bat
set ZG_OS_TRACE=etw
zigguro
wpr -start GeneralProfile -start tools\perf\zigguro.wprp
rem ... reproduce ...
wpr -stop zigguro.etl
```

- `tools/perf/zigguro.wprp` enables the TraceLogging provider **Zigguro** (GUID `625b5a21-8f0d-4b3e-8d0e-893db16cf3d4`) at level 5 with keywords `0x7` (frames, zones, instants).
- Open `zigguro.etl` in WPA:
  - **CPU Usage (Sampled)** with symbols: point the symbol path at the build's PDBs (Trace, then Configure Symbol Paths).
  - **Generic Events**, filtered to the Zigguro provider, shows `Frame{seq}`, `ZoneBegin{name, tid}`, `Zone{name, dur_ns}` and `Instant{name, value}` with decoded fields.
  - Regions of interest built from `ZoneBegin`/`Zone` pairs mark zones on the CPU graph.
- The provider writes nothing unless a session enabled it, so leaving `ZG_OS_TRACE=etw` set costs only a check per zone.

## GPU

The GPU track holds `gpu.*` zones from Vulkan timestamp queries (E02). For deeper GPU work, use vendor tools: [RenderDoc](https://renderdoc.org) for frame captures, NVIDIA Nsight Graphics, AMD Radeon GPU Profiler, and PIX on Windows, which supports Vulkan. `-Dvk_validation=true` enables the validation layers when they are installed. These are external tools; zigguro neither ships nor requires them.

## Benchmark hygiene

Before comparing numbers (see Google Benchmark's [reducing variance](https://github.com/google/benchmark/blob/main/docs/reducing_variance.md) guide):

- Plug laptops into AC power and close browsers and other heavy apps.
- Linux: `sudo cpupower frequency-set --governor performance`. Turn off turbo while measuring (`echo 1 | sudo tee /sys/devices/system/cpu/intel_pstate/no_turbo`, or `boost` under cpufreq). Pin with `taskset -c 2 ...`, and disable ASLR for one run with `setarch -R ...`.
- Windows: use the High performance power plan, and pin with `start /affinity 4 ...`.
- Run benches with `zig build bench -Doptimize=ReleaseFast` and compare medians, not single runs.

## Reporting a performance bug

Attach:

1. the flight recorder file (`flight-*.pftrace` in the trace folder) or an in-app trace of the steps;
2. a screenshot of the HUD (`Ctrl+Alt+Shift+H`);
3. machine info: OS, CPU, GPU and the zigguro version (shown on the welcome screen);
4. the exact steps, the file sizes involved, and what you expected.

Traces contain zone and file names. Use path redaction (`Redact.paths`) when sharing them outside the team.

## Verification status

The checks run while writing this page:

- In the cloud: `zig build -Dprofile=true`, `zig build check-frame-pointers -Dprofile=true`, and a headless `zigguro --trace=` run. That run's trace decoded with Perfetto's own trace protos.
- Not yet run, and still needed on real machines: `perf`, `trace-cmd`, WPR/WPA, the Perfetto UI and `trace_processor_shell` (the SQL recipes).
