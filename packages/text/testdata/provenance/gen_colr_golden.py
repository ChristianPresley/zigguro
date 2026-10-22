#!/usr/bin/env python3
"""Reference RGBA for COLR colour glyphs, rendered by blackrenderer's Skia
backend.

Usage:
  python3 testdata/provenance/gen_colr_golden.py <font> <px> <out-stem>
      [--loc TAG=value,...] [--fg r,g,b,a] [--palette N] [U+XXXX ...]

Without code points, every COLR base glyph with one is rendered. Writes
<out-stem>.png, an atlas of the glyphs, <out-stem>-edges.png, a mask of
their edge pixels, and <out-stem>.zon, the index. The atlas holds
premultiplied RGBA bytes stored as if they were straight PNG RGBA (so a
reader must not premultiply again).

Each glyph is rendered at `--ss` (16) times the size and box-filtered
down: Skia anti-aliases paths by 4x4 supersampling, which quantizes edge
coverage to quarter pixels; at 16x the averaged coverage is within about
1/128 of the exact area that zg_text computes. Gradients are thereby
area-averaged too, so pixels on a hard colour stop or a sweep centre are
the mean of their area where zg_text samples the pixel centre. The edge
mask marks pixels whose supersamples span more than EDGE_SPREAD levels in
some channel: outline and clip edges, hard stops and singularities.

Setup (versions used: blackrenderer 0.8.2, skia-python 144.1,
fonttools 4.67.0, uharfbuzz 0.56.3):
  python3 -m venv env && env/bin/pip install blackrenderer[skia] pillow

Rendering follows blackrenderer.render with these choices, which the
zg_text renderer shares:
- the canvas maps font units to pixels with scale s = px / upem, y down:
  pixel = (x*s, -y*s), and covers the glyph's clip box rounded out to whole
  pixels; without a clip box, blackrenderer's glyph bounds plus 2 pixels
  (the test compares in absolute pixel positions, zero outside a bitmap);
- gradients interpolate premultiplied colours (Skia's
  kInterpolateColorsInPremul flag; Skia's default is unpremultiplied), and
  so does blackrenderer's resampling of sweep colour lines (patched);
- colour stops are sorted by offset (patched; variations can reorder them);
- varied sweep angles take their deltas without the angle bias (patched;
  fontTools adds 180° to each);
- the text colour (`--fg`, sRGB-encoded straight RGBA) fills palette index
  0xFFFF.
Glyphs blackrenderer refuses (cycles) are listed under `.refused`.

Output: `.{ .font, .px, .glyphs = .{ .{ .cp, .gid, .left, .top, .width,
.height, .x, .y }, ... }, .refused = .{ cp, ... } }`, with x/y the glyph's
position in the atlas.
"""
import argparse
import math

import numpy as np
import skia
from blackrenderer.backends import skia as bskia
from blackrenderer.backends import sweepGradient
from blackrenderer import font as bfont
from blackrenderer.font import BlackRendererFont
from PIL import Image

PREMUL = 1  # SkGradientShader::kInterpolateColorsInPremul_Flag
# A pixel whose supersamples span more than this (any channel, 0..255) is
# an edge: an outline or clip boundary, a hard colour stop or a gradient
# singularity.
EDGE_SPREAD = 8


def _sample_premul(colorLine, t):
    """blackrenderer's sweep colour-line resampling, interpolating
    premultiplied colours like the gradients themselves (it interpolates
    straight colours, which shifts hues next to translucent stops)."""
    if t <= colorLine[0][0]:
        return colorLine[0][1]
    if t >= colorLine[-1][0]:
        return colorLine[-1][1]
    for (s0, c0), (s1, c1) in zip(colorLine, colorLine[1:]):
        if s1 < t:
            continue
        if s1 == s0:
            return c1
        f = (t - s0) / (s1 - s0)
        p0 = [c * c0[3] for c in c0[:3]] + [c0[3]]
        p1 = [c * c1[3] for c in c1[:3]] + [c1[3]]
        p = [a + f * (b - a) for a, b in zip(p0, p1)]
        return tuple(c / p[3] for c in p[:3]) + (p[3],) if p[3] > 0 else (0, 0, 0, 0)
    return colorLine[-1][1]


sweepGradient._sampleColorLine = _sample_premul

_get_delta = bfont.VarTableWrapper._getDeltaForAttr


def _get_delta_unbiased(self, attrName, varIdx):
    """fontTools converts a delta of a biased field (the sweep angles, whose
    stored value is degrees / 180 - 1) with the bias, which adds 180° to
    every varied angle; a delta is a difference and takes no bias."""
    d = _get_delta(self, attrName, varIdx)
    conv = self._wrapped.getConverterByName(attrName)
    return d - getattr(conv, "bias", 0) * 180 if hasattr(conv, "bias") else d


bfont.VarTableWrapper._getDeltaForAttr = _get_delta_unbiased

_normalize = bfont._normalizeColorLine


def _normalize_sorted(colorLine):
    """Colour stops in offset order, as the spec requires (blackrenderer
    passes them on as stored, and Skia then clamps each offset to the one
    before); Python's sort is stable, keeping equal offsets in order."""
    return _normalize(sorted(colorLine, key=lambda s: s[0]))


bfont._normalizeColorLine = _normalize_sorted


class PremulCanvas(bskia.SkiaCanvas):
    def drawPathLinearGradient(self, path, colorLine, pt1, pt2, extendMode, gradientTransform):
        m = skia.Matrix()
        m.setAffine(gradientTransform)
        colors, stops = bskia._unpackColorLine(colorLine)
        shader = skia.GradientShader.MakeLinear(
            points=[pt1, pt2], colors=colors, positions=stops,
            mode=bskia._extendModeMap[extendMode], flags=PREMUL, localMatrix=m)
        self._drawPath(path, skia.Paint(AntiAlias=True, Shader=shader))

    def drawPathRadialGradient(self, path, colorLine, startCenter, startRadius, endCenter, endRadius, extendMode, gradientTransform):
        m = skia.Matrix()
        m.setAffine(gradientTransform)
        colors, stops = bskia._unpackColorLine(colorLine)
        shader = skia.GradientShader.MakeTwoPointConical(
            start=startCenter, startRadius=startRadius, end=endCenter, endRadius=endRadius,
            colors=colors, positions=stops, mode=bskia._extendModeMap[extendMode],
            flags=PREMUL, localMatrix=m)
        self._drawPath(path, skia.Paint(AntiAlias=True, Shader=shader))

    def drawPathSweepGradient(self, path, colorLine, center, startAngle, endAngle, extendMode, gradientTransform):
        colorLine, startAngle, endAngle = bskia.normalizeSweepColorLineAndAngles(
            colorLine, startAngle, endAngle, extendMode)
        if not colorLine:
            return
        m = skia.Matrix()
        m.setAffine(gradientTransform)
        colors, stops = bskia._unpackColorLine(colorLine)
        shader = skia.GradientShader.MakeSweep(
            cx=center[0], cy=center[1], colors=colors, positions=stops,
            mode=skia.TileMode.kClamp, startAngle=startAngle, endAngle=endAngle,
            flags=PREMUL, localMatrix=m)
        self._drawPath(path, skia.Paint(AntiAlias=True, Shader=shader))


def canvas_box(font, name, s):
    box = font._getClipBox(name)
    if box is not None:
        x0, y0, x1, y1 = box.xMin, box.yMin, box.xMax, box.yMax
        margin = 0
    else:
        x0, y0, x1, y1 = font.getGlyphBounds(name)
        margin = 2
    left = math.floor(x0 * s) - margin
    top = math.floor(-y1 * s) - margin
    right = math.ceil(x1 * s) + margin
    bottom = math.ceil(-y0 * s) + margin
    return left, top, right - left, bottom - top


def render(font, name, s, fg, palette, ss):
    left, top, w, h = canvas_box(font, name, s)
    surface = skia.Surface(w * ss, h * ss)
    sk = surface.getCanvas()
    sk.clear(skia.Color4f(0, 0, 0, 0))
    sk.scale(ss, ss)
    sk.translate(-left, -top)
    sk.scale(s, -s)
    font.drawGlyph(name, PremulCanvas(sk), palette=palette, textColor=fg)
    px = surface.makeImageSnapshot().toarray(
        colorType=skia.ColorType.kRGBA_8888_ColorType, alphaType=skia.AlphaType.kPremul_AlphaType)
    blocks = px.reshape(h, ss, w, ss, 4).astype(np.float64)
    avg = np.floor(blocks.mean(axis=(1, 3)) + 0.5).astype(np.uint8)
    spread = (blocks.max(axis=(1, 3)) - blocks.min(axis=(1, 3))).max(axis=2)
    edge = np.where(spread > EDGE_SPREAD, 255, 0).astype(np.uint8)
    return left, top, w, h, avg.tobytes(), edge.tobytes()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("font")
    ap.add_argument("px", type=float)
    ap.add_argument("out")
    ap.add_argument("--loc", default="")
    ap.add_argument("--fg", default="0,0,0,1")
    ap.add_argument("--palette", type=int, default=0)
    ap.add_argument("--ss", type=int, default=16)
    ap.add_argument("cps", nargs="*")
    a = ap.parse_args()
    font = BlackRendererFont(a.font)
    if a.loc:
        font.setLocation({k: float(v) for k, v in (kv.split("=") for kv in a.loc.split(","))})
    fg = tuple(float(v) for v in a.fg.split(","))
    palette = font.getPalette(a.palette)
    s = a.px / font.unitsPerEm
    cmap = font.ttFont.getBestCmap()
    by_name = {}
    for cp, n in sorted(cmap.items()):
        by_name.setdefault(n, cp)
    if a.cps:
        names = [cmap[int(c[2:], 16)] for c in a.cps]
    else:
        names = [n for n in by_name if n in font.colrV1Glyphs or n in font.colrV0Glyphs]
        names.sort(key=lambda n: by_name[n])

    rendered, refused = [], []
    for n in names:
        try:
            rendered.append((n, render(font, n, s, fg, palette, a.ss)))
        except RecursionError:
            refused.append(by_name[n])

    # Shelf-pack into a 1024-wide atlas.
    W = 1024
    x = y = shelf = 0
    pos = []
    for _, (_, _, w, h, _, _) in rendered:
        if x + w > W:
            x, y, shelf = 0, y + shelf, 0
        pos.append((x, y))
        x += w
        shelf = max(shelf, h)
    H = max(1, y + shelf)
    atlas = Image.new("RGBA", (W, H))
    edges = Image.new("L", (W, H))
    for (n, (_, _, w, h, data, edge)), (px_, py_) in zip(rendered, pos):
        atlas.paste(Image.frombytes("RGBA", (w, h), data), (px_, py_))
        edges.paste(Image.frombytes("L", (w, h), edge), (px_, py_))
    atlas.save(a.out + ".png", optimize=True)
    edges.save(a.out + "-edges.png", optimize=True)

    gid = font.ttFont.getGlyphID
    with open(a.out + ".zon", "w") as f:
        f.write(".{\n")
        f.write(f"    // gen_colr_golden.py {a.font.split('/')[-1]} {a.px:g} --loc '{a.loc}' --fg {a.fg} --palette {a.palette} --ss {a.ss}\n")
        f.write(f"    .px = {a.px:g},\n")
        f.write("    .glyphs = .{\n")
        for (n, (left, top, w, h, _, _)), (px_, py_) in zip(rendered, pos):
            f.write(f"        .{{ .cp = 0x{by_name[n]:X}, .gid = {gid(n)}, .left = {left}, .top = {top}, .width = {w}, .height = {h}, .x = {px_}, .y = {py_} }}, // {n}\n")
        f.write("    },\n")
        # No trailing comma: zig fmt keeps the list on one line.
        f.write("    .refused = .{" + (" " + ", ".join(f"0x{c:X}" for c in refused) + " " if refused else "") + "},\n")
        f.write("}\n")


if __name__ == "__main__":
    main()
