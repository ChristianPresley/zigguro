#!/usr/bin/env python3
"""Maintainer-only: writes outline goldens from fontTools pens.

    python3 testdata/provenance/gen_outline_golden.py <font> <glyph>... > testdata/golden/<area>/<name>.zon
    python3 testdata/provenance/gen_outline_golden.py --all <font>   # "gid path" per glyph, for ad-hoc diffs

Paths use the `Path.format` grammar: M x y, L x y, Q cx cy x y,
C c1x c1y c2x c2y x y, Z. Quadratic B-splines are split at implied on-curve
midpoints by fontTools' BasePen. `zig build` never runs this; the output is
reviewed and committed as data.
"""
import os, sys
import fontTools
from fontTools.ttLib import TTFont
from fontTools.pens.basePen import BasePen

def num(v):
    return str(int(v)) if float(v).is_integer() else repr(float(v))

class FmtPen(BasePen):
    def __init__(self, gs):
        super().__init__(gs)
        self.out = []
    def _moveTo(self, p): self.out.append('M %s %s' % (num(p[0]), num(p[1])))
    def _lineTo(self, p): self.out.append('L %s %s' % (num(p[0]), num(p[1])))
    def _qCurveToOne(self, c, p): self.out.append('Q %s %s %s %s' % tuple(map(num, (*c, *p))))
    def _curveToOne(self, a, b, p): self.out.append('C %s %s %s %s %s %s' % tuple(map(num, (*a, *b, *p))))
    def _closePath(self): self.out.append('Z')
    def _endPath(self): self.out.append('Z')

def path(gs, name):
    pen = FmtPen(gs)
    gs[name].draw(pen)
    return ' '.join(pen.out)

def main(argv):
    if argv[0] == '--all':
        f = TTFont(argv[1]); gs = f.getGlyphSet()
        for gid, n in enumerate(f.getGlyphOrder()):
            print(gid, path(gs, n))
        return
    font, glyphs = argv[0], argv[1:]
    f = TTFont(font); gs = f.getGlyphSet(); order = f.getGlyphOrder()
    print('// Producer: fontTools %s BasePen, via testdata/provenance/gen_outline_golden.py' % fontTools.version)
    print('// Command: gen_outline_golden.py %s %s' % (os.path.basename(font), ' '.join(glyphs)))
    print('.{')
    print('    .font = "%s",' % os.path.basename(font))
    print('    .glyphs = .{')
    for n in glyphs:
        print('        .{ .gid = %d, .name = "%s", .path = "%s" },' % (order.index(n), n, path(gs, n)))
    print('    },')
    print('}')

if __name__ == '__main__':
    main(sys.argv[1:])
