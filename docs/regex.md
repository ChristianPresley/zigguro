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
   first bytes, packed-pair memmem, case-folding memmem for `(?i)` literals,
   a fingerprint search for up to 64 literals of two bytes or more, or
   Aho-Corasick) skips to candidates. Case-insensitive literals become
   up to four lower-cased needles (for example `sherl` and `ſherl` for
   `(?i)sherlock`), each searched with ASCII letters folded.
   The DFA jumps ahead whenever it is idle, but not with Aho-Corasick,
   which is about as fast as the DFA itself. The fingerprint search
   (`src/prefilter/packed.zig`) stands in for Teddy: Zig has no portable
   runtime byte shuffle, so instead of nibble tables it tests each
   position's first two or three bytes against 64 Ki-bit tables, with no
   dependency between positions.
3. The reverse lazy DFA finds the match start.
4. Captures run the PikeVM anchored on the match span.
5. The PikeVM handles the search when a DFA quits (a Unicode word
   boundary to decide next to a non-ASCII byte, whose word-ness the DFA
   cannot know) or gives up (cache thrash). Non-ASCII text elsewhere runs
   through the DFA.

The lazy DFA cache is bounded by `Options.dfa_cache_bytes` per direction.

## Performance

Measured with `zig build bench -Doptimize=ReleaseFast -Dbench-filter=regex.`
on the cloud development container (16 MiB generated corpus of prose, code
and CJK):

| Bench | Throughput | Budget |
|---|---|---|
| `regex.memchr_1byte` | ~22 GB/s | ≥ 4 GB/s |
| `regex.memmem` | ~17 GB/s | ≥ 2 GB/s |
| `regex.memmem_icase` (`(?i)sherlock`) | ~7.5 GB/s | ≥ 1 GB/s |
| `regex.teddy_8` (fingerprint search, no hits) | ~1.6 GB/s | ≥ 1.5 GB/s |
| `regex.literal_alt_20` (fingerprint search) | ~1.25 GB/s | ≥ 1 GB/s |
| `regex.dfa_no_match`, `regex.dfa_ident` | ~500–550 MB/s | ≥ 500 MB/s |
| `regex.dfa_word_suffix` (Unicode `\b`) | ~480 MB/s | ≥ 500 MB/s |

Known gaps: sets of more than 64 literals, or with a one-byte literal,
run on Aho-Corasick; a Unicode `\b` right next to non-ASCII text (for
example `\w+\b` over CJK) still falls back to the PikeVM. The numbers above
were taken while other work ran on the container, so they are on the low
side.