# Continuous integration

CI runs on GitHub-hosted runners only and uses no third-party actions:
`actions/checkout`, `actions/cache` and `actions/upload-artifact`. The only
external binary it runs is the official Zig release named in
`.github/zig-toolchain.txt` (see [ADR 0008](adr/0008-toolchain-trust.md)).

## Workflows

| Workflow | Trigger | Jobs |
|---|---|---|
| `.github/workflows/ci.yml` | pull requests to `main`, pushes to `main`, manual | `lint`, `test` (4 runners × Debug/ReleaseSafe), `cross`, `bench-smoke`, `fuzz-smoke`, `eval`, `vulkan` |
| `.github/workflows/nightly.yml` | 03:17 UTC daily, manual | `fuzz` (35 min per target on x86_64 and aarch64 Linux), `bench` (full ReleaseFast benches with 7 repeats and, on Linux, the app scenarios; trend against the previous nightly), `bench-ref-laptop` (only with the repository variable `ZG_REF_LAPTOP=true`), `toolchain-selftest` (cold cache, all 4 runners) |
| `.github/workflows/perf-gate.yml` | pull requests to `main` that change more than docs, manual | `gate` (Linux and Windows): base and head benches interleaved, compared by perfgate |
| `.github/workflows/perf-baseline.yml` | manual (input `machine`) | `baseline`: full benches, `perfgate baseline`, and a PR updating `perf/baselines/<machine>/` |

`ci.yml` cancels the previous run of the same pull request when a new push
arrives. Every push to `main` runs in its own concurrency group (keyed by
commit), so no merge's run is cancelled or replaced by a later one. The PR title and branch reach `prlint` only through `env:`, never by
interpolation into a script, and no workflow uses `pull_request_target`.

`fuzz-smoke` and the nightly fuzz jobs run on Linux only: Zig 0.16's build
runner rejects `--fuzz` on Windows. They build in ReleaseSafe because
`--fuzz` in Debug fails to compile the 0.16.0 test runner. Windows test cells
still run every `fuzz:` test once over its corpus.

Nightly fuzz crashes are copied to `fuzz-crashes/<target>/`, uploaded as an
artifact, and reported by `.github/scripts/fuzz-triage.sh` as an issue
labelled `fuzz-crash`, one per distinct input SHA-256. A run ended by
`timeout` (exit 124) is a pass.

`vulkan` installs Mesa lavapipe and the Khronos validation layer from the
Ubuntu archive and runs `zig build test-vulkan-gpu test-golden`: the
`gpu:` tests (pipelines, frame scheduling, readback, and the scene corpus
through the Vulkan backend compared with the software goldens at
`Tolerance.gpu`). On failure the `*.actual.png` and `*.diff.png` images are
uploaded as an artifact. Elsewhere the `gpu:` tests skip when no Vulkan
driver is found.

### Perf gate

`perf-gate.yml` checks out the PR, adds a worktree at the merge base, and builds both with `zig build -Doptimize=ReleaseFast bench-build`. That step compiles the bench binaries and perfgate into `zig-out/bench-bin/`, plus the app and the startup harness. Nothing is measured while building.

`.github/scripts/perf-ab.sh` then alternates base and head runs on the same VM:
- 5 rounds of the bench binaries of every package with a block or warn budget;
- 3 rounds of the headless scenarios `editing_100k`, `view_switch`, `fuzzy_find_1m` and `idle` in quick mode (Linux only);
- 5 headless startup launches per round.

`perfgate compare` writes the table to the job summary and `gate.json` to the artifact, and its exit code is the job's. The `perf-accepted` label clears a blocking row only when the PR also changes that suite's file under `perf/baselines/` (see [perf/baselines/README.md](../perf/baselines/README.md)). The runner is calibrated against the reference laptop (`perfgate calibrate`), so absolute budgets are advisory there.

When the merge base predates `bench-build`, the job has nothing to compare and passes with a notice. The gate is not a required check yet. Make it one once its false-positive rate has been measured on real PRs.

The nightly reference-laptop job runs on a self-hosted runner labelled `zg-ref-laptop`. To enable it, register that runner and set the repository variable `ZG_REF_LAPTOP` to `true`. It checks the absolute budgets on `ref_laptop_2024` and opens one `[perf] budget failure <id>` issue per failing budget, skipping budgets that already have an open issue.

## Required checks

A maintainer sets branch protection on `main` to require these checks:

- `lint`
- `test (ubuntu-24.04, Debug)`, `test (ubuntu-24.04, ReleaseSafe)`,
  `test (ubuntu-24.04-arm, Debug)`, `test (ubuntu-24.04-arm, ReleaseSafe)`,
  `test (windows-2025, Debug)`, `test (windows-2025, ReleaseSafe)`,
  `test (windows-11-arm, Debug)`, `test (windows-11-arm, ReleaseSafe)`
- `cross`
- `bench-smoke`
- `fuzz-smoke`
- `eval`
- `vulkan`

## Toolchain setup

`.github/scripts/setup-zig.sh` (Linux) and `setup-zig.ps1` (Windows) read the
pin, pick the archive for the runner's architecture, try the shuffled
community mirrors and then ziglang.org, and check the SHA-256 with
`sha256sum` / `Get-FileHash` **before** extracting. The extracted toolchain
is cached by `actions/cache`, keyed by the pin file's hash, and re-checked
with `zig version` on a cache hit.

| Exit code | Meaning |
|---|---|
| 0 | Zig is on `PATH` (`$GITHUB_PATH`) and `ZIG_VERSION` is set |
| 10 | Hash mismatch (`zig toolchain hash mismatch`); nothing was extracted |
| 11 | Every mirror and ziglang.org failed |
| 12 | Unsupported architecture or no pin entry |

`zig build test-ci-scripts` runs `setup-zig.sh` against a loopback fixture
mirror: a failing mirror then the fallback, a cache hit, a hash mismatch and
every source failing.

## Bumping Zig

1. On a machine with network access and a working Zig, run
   `zig build zig-pin -Dzig-version=<version>`. It downloads the four tier-1
   archives and their `.minisig` files from the shuffled community mirrors
   (falling back to ziglang.org), verifies each signature against the Zig
   Software Foundation key and checks the trusted comment's `file:` name,
   then rewrites `.github/zig-toolchain.txt`. If any archive fails, the pin
   is not written.
2. Cross-check at least one SHA-256 out of band, for example against
   `https://ziglang.org/download/index.json` or with the reference
   `minisign -Vm <archive> -P <key>`. Record what you checked in the PR
   description.
3. Open a PR with the new pin. CI then installs the new toolchain on all
   runners; fix any breakage in the same PR.

**Bootstrap trust.** The very first pin was produced by a maintainer with a
Zig downloaded from ziglang.org, cross-checked against `index.json`. From then
on CI trusts only the pinned hashes, so a compromised mirror can deny service
but cannot change the toolchain.

`zig-verify verify --pubkey <key> --file <archive> --sig <archive>.minisig`
checks a single download by hand.
