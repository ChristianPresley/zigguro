#!/usr/bin/env python3
"""Reference RGBA for CBDT bitmap emoji resampled to a target size.

Usage:
  python3 testdata/provenance/gen_strike_golden.py <font> <px> <U+XXXX>... > out.zon

Independent of zg_text: fontTools reads CBLC/CBDT, Pillow decodes the PNG,
and the resampling is written out here in float64 from the definition:

- target scale s = px / strike_ppem; the image covers
  [bx*s, (bx+w)*s] x [-by*s, (-by+h)*s] in target pixels (y down), where
  bx/by are the CBDT bearings;
- the bitmap is the integer box around that (floor/ceil), left/top relative
  to the pen origin and baseline;
- each target pixel is the exact-area average of the source pixels it
  overlaps, computed on premultiplied linear-light RGB (sRGB transfer
  function) and alpha, then converted back to sRGB and premultiplied in
  encoded space, rounded to 8 bits.

Output: `.{ .glyphs = .{ .{ .cp, .px, .left, .top, .width, .height,
.rgba = "<hex>" }, ... } }`.
"""
import io
import math
import sys

from fontTools.ttLib import TTFont
from PIL import Image


def to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def to_srgb(l):
    l = min(max(l, 0.0), 1.0)
    return l * 12.92 if l <= 0.0031308 else 1.055 * l ** (1 / 2.4) - 0.055


def weights(n, s, off, m):
    """For each target index t, a list of (source index, overlap)."""
    out = [[] for _ in range(m)]
    for i in range(n):
        a = off + i * s
        b = a + s
        t = max(0, math.floor(a))
        while t < b and t < m:
            ov = min(b, t + 1) - max(a, t)
            if ov > 0:
                out[t].append((i, ov))
            t += 1
    return out


def main():
    font = TTFont(sys.argv[1])
    px = float(sys.argv[2])
    cmap = font.getBestCmap()
    strike = font["CBDT"].strikeData[0]
    ppem = font["CBLC"].strikes[0].bitmapSizeTable.ppemY
    s = px / ppem
    print(".{")
    print(f"    // {' '.join(sys.argv[1:])}")
    print("    .glyphs = .{")
    for spec in sys.argv[3:]:
        cp = int(spec[2:], 16)
        g = strike[cmap[cp]]
        m = g.metrics
        img = Image.open(io.BytesIO(g.imageData)).convert("RGBA")
        w, h = img.size
        px_ = img.load()
        lin = [[None] * w for _ in range(h)]
        for y in range(h):
            for x in range(w):
                r, gg, b, a = px_[x, y]
                af = a / 255
                lin[y][x] = (to_linear(r / 255) * af, to_linear(gg / 255) * af, to_linear(b / 255) * af, af)
        x0 = m.BearingX * s
        y0 = -m.BearingY * s
        left = math.floor(x0)
        top = math.floor(y0)
        ow = math.ceil(x0 + w * s) - left
        oh = math.ceil(y0 + h * s) - top
        wx = weights(w, s, x0 - left, ow)
        wy = weights(h, s, y0 - top, oh)
        out = bytearray()
        for ty in range(oh):
            for tx in range(ow):
                acc = [0.0, 0.0, 0.0, 0.0]
                for sy, oy in wy[ty]:
                    for sx, ox in wx[tx]:
                        v = lin[sy][sx]
                        k = oy * ox
                        for c in range(4):
                            acc[c] += v[c] * k
                a = min(max(acc[3], 0.0), 1.0)
                if a <= 0:
                    out += bytes(4)
                    continue
                for c in range(3):
                    out.append(int(to_srgb(acc[c] / a) * a * 255 + 0.5))
                out.append(int(a * 255 + 0.5))
        print(f'        .{{ .cp = 0x{cp:X}, .px = {px:g}, .left = {left}, .top = {top}, .width = {ow}, .height = {oh}, .rgba = "{out.hex()}" }},')
    print("    },")
    print("}")


if __name__ == "__main__":
    main()
