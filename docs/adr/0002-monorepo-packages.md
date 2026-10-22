# 0002. Monorepo of path-dependency packages

Status: Accepted
Date: 2026-10-21

## Context

Twenty or more agents work on separate packages at once. Each needs to build and test its package in isolation, while the root composes everything into two apps. The Zig build system is the only build tool. In Zig 0.16 a package is instantiated once per distinct dependency-argument tuple; an experiment with a diamond (root -> core, root -> jsonrpc -> core) passing different args failed with `file exists in modules 'zg_core' and 'zg_core0'`, while identical args deduplicated it.

## Decision

- Every package lives in `packages/<dir>/` with its own `build.zig`, `build.zig.zon` and `src/root.zig`, and is referenced by `.path` from the root `build.zig.zon` and from its dependents.
- Every `build.zig` calls `zg_build.flags(b)` once and passes `f.args()` unchanged to every `b.dependency()`. New `-D` options are added only to `zg_build`.
- Package modules leave `optimize` unset and inherit the importer's mode; tests use `zg_build.testModule`, benches build ReleaseFast.
- A layer table (`tools/pkgtool/layers.zon`) orders packages; a package depends only on lower layers or whitelisted same-layer packages. `zig build check-layers` enforces it and rejects cycles.

## Consequences

- `cd packages/<pkg> && zig build test` works standalone; the root runs everything.
- Ad-hoc dependency args are a bug; `zig build test-build -Dslow-tests` guards the invariant.
- Cross-package edits need a `cross-package` pull request (docs/AGENTS.md).

## References

- [Zig Build System guide](https://ziglang.org/learn/build-system/)
- [Zig 0.16.0 release notes](https://ziglang.org/download/0.16.0/release-notes.html)
- docs/build-options.md (the duplicate-module error)
