# Benchmarks

How zigguro's macro benchmarks get their inputs and how they run. Micro benches follow the E00 convention (`bench/main.zig` per package, [bench-format.md](../bench-format.md)). Startup has its own harness ([startup.md](startup.md)), and so does typing latency ([latency.md](latency.md)).

## Corpora

Benchmarks run against synthetic corpora that `corpusgen` generates deterministically from a profile, a seed and the generator version, with std only. Corpora are cached and never committed or downloaded.

```
zig build corpus -- linux                 # generates (or reuses) the cached corpus, prints its folder
zig build corpus -- chromium --tree       # real files instead of paths only
zig build corpus -- bigfile_1g --sparse   # right size, no content
zig build corpus -- notes_10k --out DIR --verify
```

The code is `tools/corpusgen/` (`lib.zig` is the `zg_corpus` module). A scenario or bench asks for a corpus with:

```zig
const zg_corpus = @import("zg_corpus");
const root = zg_corpus.cacheRoot(env, fallback); // ZG_CORPUS_DIR, else <global zig cache>/zg-corpus
const dir = try zg_corpus.ensure(gpa, io, .{ .profile = .lines_100k }, root);
```

`ensure` returns the cached folder when its `MANIFEST.json` matches (version, profile, seed, scale and the Blake3 of `paths.txt`) and generates it otherwise. A cache hit takes a few milliseconds.

### Profiles

| Profile | What | Default | Measured (cloud, ReleaseFast) |
|---|---|---|---|
| `linux` | 108 158 files in 6 000 dirs, depth up to 9 | files | 1.52 GB, 37.4 M lines, 10.3 s |
| `chromium` | 1 000 000 paths in 80 000 dirs, depth up to 14, long names, `third_party` subtrees, test-data clusters | paths only | 4.6 s |
| `huge` | 2 000 000 paths, for fuzzy-finder and explorer stress | paths only | 11.8 s |
| `lines_100k` | one Zig-like file of 100 000 lines | file | 4.1 MB, 57 ms |
| `bigfile_1g` | one 1 GiB log (timestamps, levels, messages) | file (`--sparse` for size only) | 13.6 M lines, 7.1 s (sparse: 3 ms) |
| `minified_50m` | one 50 MB line of JSON-like tokens | file | 0.3 s |
| `notes_10k` | 10 000 Markdown notes with frontmatter, tags, headings and `[[wikilinks]]` | files | 6.4 MB, 0.5 s |
| `mixed_unicode_10m` | 10 MB of CJK, Hebrew, Arabic, combining marks and emoji ZWJ sequences | file | 45 ms |

Each folder holds `paths.txt` (sorted, `/`-separated, one per line), `paths.bin` (u32 little-endian length, then the bytes, per path), `MANIFEST.json` and, unless paths only, the files.

### The shape model

The values are model parameters, not copied data.

- **Directories** attach to a parent picked with probability proportional to its child count plus one (preferential attachment), below the depth limit. This gives the Zipf-like fan-out of real trees. `drivers` and `arch` in `linux`, and `third_party`, `chrome` and `components` in the Chromium-like profiles, start with extra weight.
- **Files** go to a directory with probability proportional to the files it already has, plus one. A few directories end up with more than 1 000 entries.
- **Extensions** are dealt from exact quotas, then shuffled, so the shares are exact. In `linux`: `.c` 45 %, `.h` 22 %, `.rst`/`.txt` 8 %, `.yaml` 5 %, `.S` 2 %, `Makefile`/`Kconfig` 6 %, and 12 % of others (`.sh`, `.py`, `.json`, `.dts`, `.rs`).
- **File sizes** are log-normal with a median of 6 KiB, p99 about 90 KiB and a cap of 384 KiB. With 108 k files that gives about 1.5 GB and, at about 40 bytes a line, about 40 M lines: the scale of Linux 7.2 (108 158 files, 43.9 M lines). The p99 is below the "200 KiB" first estimate because a log-normal with that tail would put the total near 2.6 GB.
- **Lines** are 70 % code-like (indentation that follows braces, identifiers, operators, numbers), 20 % comments and 10 % blank. Line lengths before indentation are log-normal with a median of 33 and p99 120 (mean about 38).
- **Names** come from a fixed syllable table (`kmem_cache_pool`, `vrtx_q2_ctrl`). Collisions get `_2`, `_3`, and so on.
- **Notes** link to targets picked by preferential attachment, so in-degree is heavy-tailed. 2 % of links point at notes that do not exist, like real vaults.
- **Unicode** comes only from fixed tables of assigned characters.

### Determinism

- One `std.Random.DefaultPrng` (Xoshiro256), seeded from `seed ^ Wyhash(profile)`, plans the tree.
- Each file's content comes from its own PRNG, seeded from `Wyhash(seed, path)`. Contents therefore don't depend on the order files are written in, and the writers split the sorted list across workers.
- Distributions are integer tables only: a size is a uniform pick inside one of 64 equal-probability buckets whose edges are pinned in `profiles.zig`. Every draw is a `u64`, so 32- and 64-bit targets match. No floating point, time or OS entropy is used.
- The digest is Blake3 over the Blake3 of `paths.txt`, then each file's Blake3 in path order. `paths_only` corpora use the `paths.txt` digest alone. For `--sparse`, a file's digest covers its size.
- `zig build test-tools` pins the digest of `linux` at 1 % scale. Bump `zg_corpus.version` together with the pinned digest whenever the output changes on purpose. Baselines record the corpus version, so a bump invalidates them.
