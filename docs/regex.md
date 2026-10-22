# zg_regex

`zg_regex` is the regex engine for the editor, workspace search and every
other package that needs patterns. It guarantees linear-time search in the
size of the haystack for every pattern, and it searches chunked text (the
piece tree) without copying it.

## Syntax and semantics

The syntax is RE2's, with the extensions and Unicode behaviour of Rust's
`regex` crate:

- Unicode is on by default: `.`, `\w`, `\d`, `\s`, `\b` and case-insensitive
  matching work on code points. `(?-u)` switches to bytes and ASCII. RE2's
  Perl classes are ASCII-only; ours follow Rust.
- Classes support set operations: `[\p{Greek}&&\p{Uppercase}]`,
  `[a-z--[aeiou]]`, `[\w~~\d]`, with precedence `&&` > `--` > `~~`.
- `\p{...}` accepts general categories, scripts, script extensions
  (`scx=`), and the binary properties listed in the generated tables, with
  loose name matching (UAX44-LM3). Tables come from the vendored UCD in
  `packages/text/ucd` through `ucdgen regex`.
- Word boundaries: `\b`, `\B`, `\b{start}`, `\b{end}`, `\b{start-half}`,
  `\b{end-half}`, `\<`, `\>`.
- Flags: `i m s U u x R`, scoped as `(?i:...)` or set as `(?i)`.
- Matching is leftmost-first (Perl order). Iteration skips an empty match
  that starts where the previous match ended, and in Unicode mode never
  reports an empty match inside a UTF-8 sequence.
- Not supported, with a specific error: backreferences, look-around,
  `\G`, possessive and atomic groups, octal escapes.

Limits: patterns up to 1 MiB, repetition counts up to 1000, nesting depth
250 (`Options.nest_limit`), compiled size 10 MiB (`Options.size_limit`).

## Engines

`Regex` picks a strategy per search (`src/engine/meta.zig`):

1. A pattern that is a single literal uses SIMD `memmem`.
2. Otherwise the forward lazy DFA finds the match end. When every match
   starts with one of a few literals, a prefilter (SIMD memchr for 1–3
   first bytes, packed-pair memmem, or Aho-Corasick) skips to candidates.
   The DFA jumps ahead whenever it is idle, but only with the SIMD
   prefilters; Aho-Corasick is about as fast as the DFA itself.
3. The reverse lazy DFA finds the match start.
4. Captures run the PikeVM anchored on the match span.
5. The PikeVM handles the search when a DFA quits (a non-ASCII byte in a
   pattern with a Unicode word boundary) or gives up (cache thrash).

The lazy DFA cache is bounded by `Options.dfa_cache_bytes` per direction.

## Performance

Measured with `zig build bench -Doptimize=ReleaseFast -Dbench-filter=regex.`
on the cloud development container (16 MiB generated corpus of prose, code
and CJK):

| Bench | Throughput | Budget |
|---|---|---|
| `regex.memchr_1byte` | ~22 GB/s | ≥ 4 GB/s |
| `regex.memmem` | ~17 GB/s | ≥ 2 GB/s |
| `regex.literal_alt_20` (Aho-Corasick) | ~500 MB/s | ≥ 1 GB/s |
| `regex.dfa_no_match`, `regex.dfa_ident` | ~500–550 MB/s | ≥ 500 MB/s |
| `regex.dfa_word_suffix` (Unicode `\b`, PikeVM fallback on CJK) | ~23 MB/s | ≥ 30 MB/s PikeVM |

Known gaps: Teddy (packed SIMD multi-literal search) is not implemented, so
large literal sets run on Aho-Corasick; patterns with Unicode `\b` fall back
to the PikeVM on non-ASCII text.
