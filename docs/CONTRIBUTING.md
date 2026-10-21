# Contributing to zigguro

Humans and AI agents follow the same rules. Agents should also read [AGENTS.md](AGENTS.md). Shared contracts live in [interfaces.md](interfaces.md) and [build-options.md](build-options.md).

## Toolchain

- Zig **0.16.0**, the official build, and nothing else. CI verifies the tarball's SHA-256 and minisign signature (ADR 0008); locally, `.github/scripts/setup-zig.sh` / `setup-zig.ps1` do the same.
- No C compiler, libc, package manager or third-party Zig package is used. `build.zig.zon` files contain only `.path` dependencies.

## Building

```sh
zig build                         # zigguro + zg into zig-out/bin
zig build run-zg -- --version     # run the headless CLI
zig build cross                   # x86_64/aarch64 Linux and Windows into zig-out/cross/<triple>/
zig build docs                    # autodocs into zig-out/docs/<package>
cd packages/net && zig build test # any package builds standalone
```

Every `-D` option is listed in [build-options.md](build-options.md). If you see `file exists in modules 'zg_core' and 'zg_core0'`, some `build.zig` passed arguments other than `f.args()` to `b.dependency()`.

## Testing

- `zig build test` runs every package and tool; `zig build test-<pkg>` runs one (`test-core`, `test-net`, ...); `-Dtest-filter=<text>` narrows it.
- Pass `--test-timeout 60s` locally; CI always does.
- `zig build test-build -Dslow-tests` self-tests the build graph.
- Golden-file and fuzzing conventions are in [testing.md](testing.md).

## Benchmarks

- Each package's `bench/main.zig` uses `zg_core.bench`; benches always build ReleaseFast.
- `zig build bench` writes `zig-out/bench-results/<package>.json` ([bench-format.md](bench-format.md)); `-Dbench-quick` and `-Dbench-filter=<text>` are root-only options.
- Any change on a path with a performance budget includes its benchmark numbers in the pull request.

## Fuzzing

- Name fuzz tests `"fuzz: <target>"` and keep seeds in `packages/<pkg>/fuzz/corpus/<target>/`.
- `zig build test -Doptimize=ReleaseSafe --fuzz=10K` runs a smoke fuzz (Linux only in 0.16); `zig build fuzz-list` lists the targets. Details in [testing.md](testing.md).

## Style

- `zig fmt` (`zig build fmt-check` must pass).
- Zig naming: `camelCase` functions, `TitleCase` types, `snake_case` fields and files. Use `snake_case.zig` for namespaces and `TitleCase.zig` for files that are a struct type.
- Pass allocators and `io` explicitly, in the order `gpa`, then `io`, then the rest (as std 0.16 does, e.g. `Bundle.rescan(gpa, io, now)`).
- Specific error sets on `pub` functions; `anyerror` only in callbacks. User-facing detail goes through `zg_core.report.Diagnostics` (ADR 0005).
- Every `pub` declaration has a doc comment. No TODO without an issue link.

## Package layout

```
build.zig  build.zig.zon  build/packages.zig
packages/<dir>/{build.zig, build.zig.zon, src/root.zig, src/**, bench/main.zig, fuzz/corpus/<target>/*, testdata/**}
packages/build/        zg_build: build-time helper imported by every build.zig
apps/zigguro/  apps/zg/
tools/pkgtool/  tools/prlint/  tools/fuzz-list/  tools/zig-verify/
docs/  docs/adr/
```

Create a package with `zig build new-package -Dname=zg_demo -Ddir=demo -Dlayer=4`. Package names in code use underscores (`zg_core`) because a zon `.name` must be a bare identifier; prose may say "zg-core".

## Layering

`tools/pkgtool/layers.zon` assigns each package a layer: core (0) < jsonrpc, net, regex (1) < platform, text, vulkan (2) < gui, syntax (3) < domain packages (4) < mcp-servers (5) < apps (6). A package may depend only on lower layers, or on a same-layer package whitelisted in `allow_same_layer` with the spec ID that justifies it. `zig build check-layers` rejects violations, cycles and `.url` dependencies.

## ADRs

Decisions that affect more than one package are recorded in [docs/adr/](adr/README.md) using the template `0000-template.md`. Add the next number, link it from the index, and reference it in the pull request.
