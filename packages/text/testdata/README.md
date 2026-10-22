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
| `NotoColorEmoji-CBDT-Subset.ttf` | CBDT/CBLC bitmap emoji (6 glyphs, 109 ppem strike) |
| `NotoColorEmoji-COLRv1-Subset.ttf` | COLRv1 emoji incl. ZWJ, keycap, flags |
| `test_glyphs-glyf_colr_1*.ttf` | googlefonts COLRv1 conformance glyphs (static, variable) |

The CBDT font comes from the noto-emoji repository at a pinned commit (the
manifest's `source`), subset with `--no-layout-closure --layout-features=''`.
Other CBLC index formats and sbix are covered by tables built in the tests.

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

## Terminal cell goldens

`golden/cells/procedural_WxH.pgm` hold every procedural glyph (box
drawing, blocks, braille, Powerline, sextants) drawn at a W×H cell, 32 per
row in `box_drawing.id` order, produced by `sheet()` in
`src/layout/cells_test.zig` and checked by eye. The test compares them
byte for byte; after a deliberate drawing change, delete the files and run
the tests twice per size to write new ones.

## Outline goldens

`golden/glyf/*.zon` hold fontTools `BasePen` paths for selected glyphs (the
`Path.format` grammar), written by `provenance/gen_outline_golden.py`:

```
python3 testdata/provenance/gen_outline_golden.py testdata/fonts/FiraCode-Regular.ttf A a g O at ampersand zero Adieresis uni0123 Aacute > testdata/golden/glyf/FiraCode-Regular.zon
```

The exact command for each file is in its header. Tests compare
coordinates within 1/64 unit. For a full check, diff
`gen_outline_golden.py --all <font>` against `zig build text-dump -- outline <font> all`.

## Raster goldens

`golden/raster/hashes.zon` holds an FNV-1a 64 hash per font and pixel size
of the golden glyph set (30 glyphs from JetBrains Mono, Source Serif 4,
Source Han Sans JP and Noto Sans Arabic at 8, 11, 14, 20, 32 and 72 px; the
list is `golden_fonts` in `src/raster/coverage_test.zig`). The hashes must
match on every target. After a deliberate rasterizer change the failing
test prints the new entries to paste in. Look at any glyph with
`text-dump raster`, which writes an ASCII PGM.

Coverage itself is checked against a reference in the same test file: the
winding number integrated exactly in x on 128 sub-scanlines per pixel row,
within 2/255 per pixel.

## Colour glyph goldens

`golden/colr/` holds Skia renderings (through blackrenderer) of every
googlefonts COLRv1 test glyph at 32 px: `test_glyphs-32px` from the static
font and `test_glyphs-variable-32px` from the variable one at the axis
settings named in its `.zon` header (`golden_loc` in
`src/raster/colr_test.zig`). Each set is an atlas `.png` of premultiplied
RGBA, an `-edges.png` mask and a `.zon` index, written by
`provenance/gen_colr_golden.py` (its docstring lists the setup and the
patches it applies to blackrenderer):

```
python3 testdata/provenance/gen_colr_golden.py testdata/fonts/test_glyphs-glyf_colr_1.ttf 32 testdata/golden/colr/test_glyphs-32px --fg 1,0.5,0,1
```

Glyphs are rendered at 16× and box-filtered, so edge pixels hold the exact
area average. The test compares pixels away from the marked edges to ±2
and the whole glyph through its alpha total and centroid; the exceptions,
each with its reason, are `exceptions` in `colr_test.zig`.

## Shaping goldens

`golden/shape/*.zon` hold HarfBuzz's output for UTF-8 strings: per glyph the
gid, cluster (byte offset), x advance, x offset and y offset in font units,
in visual order. Sets: `code_ligatures` (JetBrains Mono and Fira Code
operators, `liga=0,calt=0`, stylistic sets, a bold instance), `gpos_kern`
(Inter and Source Serif kerning, fractions, CFF2 at wght=650), `gpos_marks`
(precomposed and decomposed mark stacks), `driver` (ignorables, variation
selectors, `.notdef`, space fallbacks, U+2011, RTL Latin), `random`
(seeded code-punctuation and accented strings) and `arabic` (Noto Sans
Arabic joining forms, ZWJ/ZWNJ, tatweel, marks and modifier combining marks,
Persian letters, digits, feature toggles, Syriac selection, and seeded random
strings). A case's `.script` defaults to Latin. `src/shape/shaper_test.zig`
compares every case exactly. Producer: `provenance/gen_shape_golden.py`, run
with uharfbuzz 0.56 (HarfBuzz 14.6):

```
python3 testdata/provenance/gen_shape_golden.py testdata/fonts testdata/golden/shape
```

## text-dump

From `packages/text`:

```
zig build text-dump -- metrics testdata/fonts/JetBrainsMono[wght].ttf
zig build text-dump -- outline <font> <gid|U+XXXX>... [--coords wght=700]
zig build text-dump -- shape <font> <text> [--features "liga=0,ss01"] [--dir rtl] [--script arab]
zig build text-dump -- raster <font> <gid|U+XXXX> <px> [--subpixel 0.25] [--coords wght=700]
```

Subcommands whose engine has not landed print `not implemented` and exit 2.

## Font discovery fixtures

`fontconfig/root/` and `fontconfig/noconfig/` are fake file system roots
for the Linux discovery tests (`src/fonts/discovery_test.zig`), passed as
`Options.sysroot` with `HOME=/home/u`. The `.conf` files are hand-written
in fontconfig's format (fonts-conf(5)) to cover dir prefixes, `conf.d`
ordering, include cycles, aliases, the match-prepend pattern and a
malformed file. The `.ttf`/`.otf`/`.ttc`/`.otc` files there are one-line
placeholders, not fonts: discovery only looks at names.

## Last-resort glyph golden

`golden/last_resort/boxes.pgm` holds the last-resort boxes of U+E0001,
U+10FFFD and U+0378 at 12, 16, 24 and 48 px, side by side, written by
`sheet()` in `src/fonts/fallback_db_test.zig` and checked by eye. A
missing golden is written by the test (which then skips); delete it to
regenerate after a deliberate change.
