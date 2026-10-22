# Releasing zigguro

This document is normative for version numbers, release keys and release archives (E17.F01, E17.F04).

## Version scheme

- Stable releases are `X.Y.Z`, tagged `vX.Y.Z`. `build.zig.zon .version` is the single source of truth, and the release workflow fails when the tag disagrees with it.
- Release candidates are `X.Y.Z-rc.N`.
- Insiders builds are `X.Y.Z-insiders.YYYYMMDD.N`, where `X.Y.Z` is the *next* minor version. They sort above the current stable and below the next stable (SemVer pre-release precedence).
- Build metadata is `+g<12 hex commit>`, for example `0.4.0+g1a2b3c4d5e6f`. Local builds without `-Dcommit` get `+local`. Metadata is ignored for precedence.
- Windows `FILEVERSION` is `major.minor.patch.build`. `build` is 0 for stable, `N` for `rc.N`, and `(day_of_year * 100 + N) mod 65536` for insiders, so it only orders insiders builds within one calendar year (`zg_release.Version.winFileVersion`).

`zigguro --version` and `zg --version` print `<name> <version_string> (<channel>, <target>, <optimize>, <commit>)`.

## Build options

`-Dversion`, `-Dchannel`, `-Dcommit`, `-Dsource-date-epoch`, `-Dupdate-mode` and `-Ddistro` are described in [build-options.md](build-options.md). CI passes the commit hash and the commit time; the build never runs git.

## Icons and Windows resources

- The logo is vector data in `packaging/icons/logo.zig` (1024×1024 design space). `zig build icons` rasterizes it into `packaging/icons/out/`: `dev.zigguro.zigguro-<N>.png` for 16, 24, 32, 48, 64, 128, 256 and 512 px, and `zigguro.ico` (16 to 256 px, PNG-embedded). The outputs are committed, and `zig build test` fails through `icons-check` when they are stale.
- Every Windows executable gets an application manifest, VERSIONINFO and the icon, from the templates in `packaging/windows/` (`build/release_resources.zig`). The manifest declares Windows 10/11, PerMonitorV2 DPI awareness, long paths, the UTF-8 code page and `asInvoker`. The setup executable also depends on Common Controls v6. `-Dsegment-heap` opts into the segment heap.
- `zig build test-build-resources` checks the resources of a fixture executable of each kind, cross-built for Windows, and of both apps when `-Dtarget` is Windows.

## Release keys (key ceremony)

Update manifests and `SHA256SUMS` are signed with minisign-compatible Ed25519 keys (prehashed `ED`). A build with `-Dchannel` other than `dev` fails until `packaging/product.zon` lists at least one key:

```
error: product.zon release_keys is empty; run the key ceremony (docs/release.md)
```

To create a key:

1. On a trusted machine, run `zig build && zig-out/bin/zg-release keygen --out <offline dir> --channel stable`. It writes `stable.pub`, a mode 0600 `stable.seed` holding `seed=<64 hex>` and `key_id=<16 hex>`, and prints the `RW...` public key line.
2. Add the `RW...` line to the front of `.release_keys` in `packaging/product.zon` (newest first) in a reviewed pull request.
3. Store the seed and key id as the release environment secrets `ZIGGURO_RELEASE_SEED` and `ZIGGURO_RELEASE_KEY_ID`. Keep the seed file offline; never commit it.
4. Rotation: add the new key first, release with it, and remove the old key only after every supported version trusts the new one.

`zg-release sign --file <f> [--trusted "<comment>"]` reads the key from those variables, and `zg-release verify --pub <RW...|file> --file <f>` checks a signature. Signatures also verify with the reference tool: `minisign -V -P <RW...> -m <f>`.

## Archives

`zig build package -Dtarget=<t> -Doptimize=ReleaseFast -Dversion=<v> -Dcommit=<hex> -Dsource-date-epoch=<s>` installs both apps into `zig-out/dist/<t>/` and runs `zg-release package`, which writes into `zig-out/release/`:

| File | Contents |
|---|---|
| `zigguro-<v>-<t>.zip` (Windows) / `.tar.gz` (Linux) | top-level `zigguro-<v>-<t>/` app directory; also the update payload |
| `zigguro-<v>-<t>-portable.zip` (Windows) | the same plus `zigguro-data/` (portable mode marker) |
| `zigguro-<v>-<t>-symbols.tar.gz` | with `--symbols <dir>`: `.debug` files by build id (Linux) or `.pdb` files (Windows) |

`<v>` is the version without build metadata. The Linux tarball is a valid AppDir (`AppRun`, `.desktop`, icon, `.DirIcon`).

Archives are deterministic: entries sorted byte-wise with explicit directories, every timestamp is `SOURCE_DATE_EPOCH`, modes are 0755 for executables, directories and links and 0644 otherwise, owners are 0 with empty names, gzip has MTIME 0 and OS 3 at level 9, and zip entries use version made by Unix 6.3, UTF-8 names and no extra fields. Input file mtimes never reach the archives.

Then:

- `zg-release sums --dir zig-out/release` writes `SHA256SUMS` (`sha256sum -c` compatible).
- `zg-release repro-compare <dirA> <dirB>` byte-compares two release trees, ignoring Authenticode signatures and the PE CheckSum, and prints the first difference.
- `zg-release notices --check true` (run by `zig build test`) fails when a third-party data file has no `packaging/notices/*.zon` entry; `--generate true` writes `THIRD_PARTY_NOTICES.md`.
