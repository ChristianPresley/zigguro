# zg_text test data

## Fonts (`fonts/`)

Only OFL-1.1 or Apache-2.0 fonts. Each file has an entry in
`fonts/manifest.zon` (source URL, upstream version, license file,
modification and SHA-256) and its license text under `fonts/LICENSES/`.
`src/ot/face_test.zig` checks every checksum and keeps the corpus under 8 MB.

| File | Covers |
|---|---|
| `JetBrainsMono[wght].ttf` | glyf + gvar + HVAR, `calt` code ligatures, monospace |
| `FiraCode-Regular.ttf` | static glyf (instance of the variable font), ligatures |
| `Inter[opsz,wght].ttf` | GPOS kerning and marks, two variation axes (Latin subset) |
| `SourceSerif4-Regular.otf` | CFF1, proportional serif |
| `SourceSerif4Variable-Roman.otf` | CFF2 variable (Latin subset) |
| `SourceHanSansJP-Subset.otf` | CID-keyed CFF (kana + common kanji) |
| `NotoSansArabic-Subset.ttf` | Arabic joining, marks (P1 goldens) |
| `NotoSansDevanagari-Subset.ttf` | Indic (P2 goldens) |
| `NotoColorEmoji-COLRv1-Subset.ttf` | COLRv1 emoji incl. ZWJ, keycap, flags |
| `test_glyphs-glyf_colr_1*.ttf` | googlefonts COLRv1 conformance glyphs (static, variable) |

A CBDT/CBLC test font is hand-built by the bitmap-strike task
(E03.F03.S03.T04) because upstream Noto Color Emoji CBDT is not reachable as
a plain file.

Subsets and the Fira Code instance were made once with fontTools 4.x:

```
pyftsubset <src> --unicodes=<list> --layout-features='*' --name-IDs='*' \
  --name-languages='*' --notdef-outline --no-hinting --drop-tables+=DSIG,SVG,vhea,vmtx,VORG
fonttools varLib.instancer FiraCode[wght].ttf wght=400 --update-name-table
```

The exact code point lists are recorded in each manifest entry's
`modification` field.

## Reference values

`fonts/metrics.zon` holds, per font: glyph count, outline kind, family and
subfamily names, table tags, `FontMetrics` (USE_TYPO_METRICS rule), `Style`,
and SHA-256 digests of the full `cmap` mapping (`"%X %d\n"` per mapped code
point, ascending) and of every glyph's `hmtx` entry (`"%d %d %d\n"`:
gid, advance, lsb). Producer: `provenance/gen_font_reference.py`, run with
fontTools 4.x:

```
python3 testdata/provenance/gen_font_reference.py testdata/fonts > testdata/fonts/metrics.zon
```

It is an independent implementation of the spec rules, so a disagreement
with `zg_text` points at a bug in one of them. `zig build` never runs it.

## Golden conventions

- Goldens live in `golden/<area>/` as `.golden` text (via
  `zg_core.testkit.golden`), `.zon` (structured) or `.pgm`/`.ppm` (images).
- Each golden file starts with a header naming its producer: either
  `text-dump` (our code, reviewed by a human) or an external reference tool
  run once by a maintainer (`hb-shape` for shaping, fontTools pens for
  outlines) with the exact command line and tool version. External tools are
  never invoked by `zig build`.
- `text-dump shape` emits exactly the `hb-shape --no-glyph-names` grammar
  (`[gid=cluster@xoff,yoff+xadv|...]`) so external and internal outputs diff
  line by line.
- Regenerate `zg_core.testkit.golden` files with `zig build test-text -Dupdate-golden`.

## text-dump

From `packages/text`:

```
zig build text-dump -- metrics testdata/fonts/JetBrainsMono[wght].ttf
zig build text-dump -- outline <font> <gid|U+XXXX>... [--coords wght=700]
zig build text-dump -- shape <font> <text> [--features "liga=0,ss01"] [--dir rtl] [--script arab]
zig build text-dump -- raster <font> <gid> <px> [--mode gray|lcd_rgb|sdf]
```

Subcommands whose engine has not landed print `not implemented` and exit 2.
