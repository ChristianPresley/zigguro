# Manual test: vector canvas SVG export (E13.F07.S01.T02)

The SVG writer is checked byte for byte by `svg_golden_and_wellformed`,
but whether a document renders the same everywhere needs real viewers.
Run this checklist for any change to `packages/agents/src/vector/svg.zig`
using `packages/agents/testdata/vector/chart.svg.golden` (copy it to
`chart.svg` first).

## Viewers

Open the file in at least two of: Firefox, Chromium (or Edge), Inkscape,
the system image viewer (Windows Photos, GNOME Image Viewer, macOS
Preview).

- [ ] The document is 320×200 on a white background with no errors or
  warnings from the viewer.
- [ ] The four blue bars, the dashed red curve and the dashed grey
  gridlines are drawn; the curve's dashes have round ends.
- [ ] The curve and bars stop at the plot area (the clip path), but the
  red marker at the curve's end is drawn whole.
- [ ] The bottom label reads `Revenue <Q1 & Q2>` and is centred on x = 170.
- [ ] The left label reads `"usd" 'k'` in bold, rotated to read bottom to
  top, centred on the axis.
- [ ] The top-left label is grey, right-aligned to the axis and hangs
  below y = 50.
- [ ] Gridlines are light grey and half-transparent, under the bars.

## Compared with the app

- [ ] The same display list in a vector view (zoom 1) matches the SVG in
  shapes, colours, stroke widths, joins, caps and dashes; text may differ
  in font only.
