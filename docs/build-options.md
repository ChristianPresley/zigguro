# Build options

Package names in code use underscores (`zg_core`), because a zon `.name` must be a bare Zig identifier.

Every package's `build.zig` calls `zg_build.flags(b)` exactly once and passes `f.args()` **unchanged** to every `b.dependency()`. The forwarded options below are therefore declared in every builder and reach every package as `@import("zg_options")`. Root-only options steer root steps and are never forwarded.

| Option | Type | Default | Forwarded | zg_options field | Owner | Purpose |
|---|---|---|---|---|---|---|
| `-Dtarget` | target triple | native | yes | (none; `builtin.target`) | E00 | Target to build for. |
| `-Doptimize` | Debug, ReleaseSafe, ReleaseFast, ReleaseSmall | Debug | yes | (none; `builtin.mode`) | E00 | Build mode of tests and apps; benches are always ReleaseFast. |
| `-Dtracing` | off, zones, full | off | yes | `tracing` | E00 / E14 | `zg_core.trace` level; `off` compiles zones out. |
| `-Dwayland` | bool | true | yes | `wayland` | E01 | Build the Wayland backend on Linux. |
| `-Dx11` | bool | true | yes | `x11` | E01 | Build the X11 backend on Linux. |
| `-Dvk_validation` | bool | false | yes | `vk_validation` | E02 | Enable Vulkan validation layers when present. |
| `-Dassert_ui_thread` | bool | true in Debug | yes | `assert_ui_thread` | E00 | `Runtime.assertNotUi()` panics on blocking calls from the UI thread. |
| `-Dgpa` | auto, debug, smp | auto | yes | `gpa` | E00 | Process allocator; auto = DebugAllocator in Debug/ReleaseSafe, smp_allocator otherwise. |
| `-Dversion` | string | 0.0.0-dev | yes | `version` | E00 / E17 | SemVer version; `zg_release.current.version_string` adds `+g<commit>` or `+local`. Read it through `zg_release`, not `zg_options`. |
| `-Dupdate-golden` | bool | false | yes | `update_golden` | E00 | Rewrite golden files instead of comparing. |
| `-Dnetwork-tests` | bool | false | yes | `network_tests` | E00 | Enable tests that reach the internet. |
| `-Dslow-tests` | bool | false | yes | `slow_tests` | E00 | Enable slow integration tests (e.g. ones that spawn `zig build`). |
| `-Dchannel` | dev, insiders, rc, stable | dev | yes | `channel` | E17 | Release channel baked into `zg_release.current`. |
| `-Dcommit` | string | unknown | yes | `commit` | E17 | Commit hash; CI passes it. Feeds the `+g<12 hex>` build metadata. |
| `-Dsource-date-epoch` | i64 | 0 | yes | `source_date_epoch` | E17 | Reproducible-build timestamp (commit time); archive mtimes and the update freeze check use it. |
| `-Dupdate-mode` | managed_or_notify, notify_only, disabled | managed_or_notify | yes | `update_mode` | E17 | Update behavior baked into the binary. |
| `-Ddistro` | bool | false | yes | `distro` | E17 | Distro packaging build; forces `update-mode=disabled`. |
| (computed) | string | target | per package | `release_target` | E17 | `{arch}-{os}-{abi}[.glibc]`, e.g. `x86_64-linux-gnu.2.28` (`zg_build.releaseTarget`). Not a `-D` option. |
| (computed) | string | package dir | per package | `package_root` | E00 | Absolute path of the package directory, used by golden tests. Not a `-D` option. |
| `-Dbench-quick` | bool | false | no (root only) | (none) | E00 | Quick benchmark mode. |
| `-Dbench-filter` | string | none | no (root only) | (none) | E00 | Only run benchmarks whose name contains this. |
| `-Dtest-filter` | string | none | no (root only) | (none) | E00 | Only run tests whose name contains this. |
| `-Dzig-version` | string | 0.16.0 | no (root only) | (none) | E00 | Toolchain version for `zig build zig-pin` (E00.F02). |
| `-Dname`, `-Ddir`, `-Dlayer` | string, string, int | none | no (root only) | (none) | E00 | Arguments of `zig build new-package`. |

## The duplicate-module error

```
error: file exists in modules 'zg_core' and 'zg_core0'
```

Zig instantiates a package once per distinct argument tuple. When a diamond (root -> core, root -> jsonrpc -> core) passes different args on its two paths, `zg_core` is built twice and the compile fails with the error above. The only fix is to pass `f.args()` unchanged everywhere; never pass ad-hoc dependency arguments. `zig build test-build -Dslow-tests` checks this with the diamond fixture in `packages/build/testdata/diamond/`.

## Adding an option

Append the option to `Flags`, `Args`, `flags()` and `optionsModule()` in `packages/build/build.zig`, add a row here, and label the pull request `cross-package`. `zig build prlint -- --docs` fails if an `Args` field is missing from this table.
