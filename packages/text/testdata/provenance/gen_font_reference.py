#!/usr/bin/env python3
"""Maintainer-only: writes testdata/fonts/metrics.zon from the test fonts.

Run once when the corpus changes (fontTools 4.x):
    python3 testdata/provenance/gen_font_reference.py testdata/fonts > testdata/fonts/metrics.zon
`zig build` never runs this; the output is reviewed and committed as data.
"""
import hashlib, os, sys
from fontTools.ttLib import TTFont

def names(f):
    n = f['name']
    def get(i):
        for p, e, l in ((3, 1, 0x409), (3, 10, 0x409)):
            r = n.getName(i, p, e, l)
            if r: return r.toUnicode()
        for r in n.names:
            if r.nameID == i and r.platformID == 3 and r.platEncID in (1, 10): return r.toUnicode()
        for r in n.names:
            if r.nameID == i and r.platformID == 0: return r.toUnicode()
        for r in n.names:
            if r.nameID == i and r.platformID == 1 and r.platEncID == 0 and r.langID == 0: return r.toUnicode()
        return None
    return get(1), get(2)

def metrics(f):
    hh, os2, post, head = f['hhea'], f.get('OS/2'), f.get('post'), f['head']
    m = dict(ascender=hh.ascent, descender=hh.descent, line_gap=hh.lineGap, cap_height=0, x_height=0,
             underline_pos=0, underline_thickness=0, strikeout_pos=0, strikeout_thickness=0, units_per_em=head.unitsPerEm)
    if os2 is not None:
        if os2.fsSelection & 0x80:
            m.update(ascender=os2.sTypoAscender, descender=os2.sTypoDescender, line_gap=os2.sTypoLineGap)
        elif hh.ascent == 0 and hh.descent == 0 and hh.lineGap == 0:
            m.update(ascender=os2.usWinAscent, descender=-os2.usWinDescent)
        if os2.version >= 2:
            m.update(cap_height=os2.sCapHeight, x_height=os2.sxHeight)
        m.update(strikeout_pos=os2.yStrikeoutPosition, strikeout_thickness=os2.yStrikeoutSize)
    if post is not None:
        m.update(underline_pos=post.underlinePosition, underline_thickness=post.underlineThickness)
    return m

def style(f):
    os2, head, post = f.get('OS/2'), f['head'], f.get('post')
    s = dict(weight=400, width=5, italic=False, oblique=False, monospace=False)
    if os2 is not None:
        w = os2.usWeightClass
        if 1 <= w <= 9: w *= 100
        if w == 0 or w > 1000: w = 400
        wd = os2.usWidthClass
        if wd == 0 or wd > 9: wd = 5
        s.update(weight=w, width=wd, italic=bool(os2.fsSelection & 1), oblique=os2.version >= 4 and bool(os2.fsSelection & 0x200))
    elif head.macStyle & 1:
        s['weight'] = 700
    if head.macStyle & 2: s['italic'] = True
    mono = bool(post is not None and post.isFixedPitch)
    if not mono and os2 is not None and os2.panose.bFamilyType == 2 and os2.panose.bProportion == 9: mono = True
    if not mono:
        order = f.getGlyphOrder(); hm = f['hmtx']
        widths = [hm[order[g]][0] for g in range(min(len(order), 512))]
        nz = [w for w in widths if w]
        mono = len(nz) > 1 and all(w == nz[0] for w in nz)
    s['monospace'] = mono
    return s

def cmap_hash(f):
    order = f.getGlyphOrder(); gid = {g: i for i, g in enumerate(order)}
    best = f['cmap'].getBestCmap()
    lines = ''.join('%X %d\n' % (cp, gid[g]) for cp, g in sorted(best.items()) if gid[g] != 0)
    return lines.count('\n'), hashlib.sha256(lines.encode()).hexdigest()

def hmtx_hash(f):
    order = f.getGlyphOrder(); hm = f['hmtx']
    lines = ''.join('%d %d %d\n' % (i, hm[g][0], hm[g][1]) for i, g in enumerate(order))
    return hashlib.sha256(lines.encode()).hexdigest()

def zon_str(s): return '"' + s.replace('\\', '\\\\').replace('"', '\\"') + '"'

def main(d):
    print('// Reference values for src/ot/face_test.zig, produced by')
    print('// testdata/provenance/gen_font_reference.py (fontTools). Do not edit by hand.')
    print('.{')
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(('.ttf', '.otf')): continue
        f = TTFont(os.path.join(d, fn), lazy=True)
        kind = 'glyf' if 'glyf' in f else 'cff2' if 'CFF2' in f else 'cff' if 'CFF ' in f else 'none'
        fam, sub = names(f)
        n, h = cmap_hash(f)
        print('    .{')
        print('        .file = %s,' % zon_str(fn))
        print('        .num_glyphs = %d,' % f['maxp'].numGlyphs)
        print('        .outline = .%s,' % kind)
        print('        .family = %s,' % zon_str(fam))
        print('        .subfamily = %s,' % zon_str(sub))
        print('        .tables = %s,' % zon_str(' '.join(sorted(t for t in f.reader.keys()))))
        print('        .metrics = .{ %s },' % ', '.join('.%s = %d' % kv for kv in metrics(f).items()))
        print('        .style = .{ %s },' % ', '.join('.%s = %s' % (k, str(v).lower()) for k, v in style(f).items()))
        print('        .cmap_count = %d,' % n)
        print('        .cmap_sha256 = "%s",' % h)
        print('        .hmtx_sha256 = "%s",' % hmtx_hash(f))
        print('    },')
    print('}')

main(sys.argv[1])
