#!/usr/bin/env python3
"""Maintainer-only: writes testdata/golden/var/reference.zon.

    python3 testdata/provenance/gen_var_reference.py testdata/fonts > testdata/golden/var/reference.zon

Normalized coordinates follow the otvaroverview algorithm (default
normalization rounded to F2Dot14, then avar on F2Dot14 values, rounded
again); the script asserts they agree with fontTools' float pipeline within
one F2Dot14 unit. Advances and MVAR metrics come from fontTools'
VarStoreInstancer at those coordinates. `zig build` never runs this.
"""
import os, sys
import fontTools
from fontTools.ttLib import TTFont
from fontTools.varLib.varStore import VarStoreInstancer
from fontTools.varLib.models import normalizeValue, piecewiseLinearMap

def rnd(x):  # round half away from zero
    return int(x + 0.5) if x >= 0 else -int(-x + 0.5)

def spec_norm(font, user):
    fvar = font['fvar']; avar = font.get('avar')
    out = []
    for a in fvar.axes:
        v = user.get(a.axisTag, a.defaultValue)
        lo, de, hi = min(a.minValue, a.defaultValue), a.defaultValue, max(a.maxValue, a.defaultValue)
        v = max(lo, min(hi, v))
        n = -(de - v) / (de - lo) if v < de else (v - de) / (hi - de) if v > de else 0.0
        c = rnd(n * 16384)
        if avar is not None and a.axisTag in avar.segments:
            m = sorted((rnd(k * 16384), rnd(t * 16384)) for k, t in avar.segments[a.axisTag].items())
            for k, (f1, t1) in enumerate(m):
                if f1 >= c: break
            if f1 == c or k == 0: c = t1
            else:
                f0, t0 = m[k - 1]
                c = rnd(t0 + (t1 - t0) * (c - f0) / (f1 - f0))
        # fontTools' float pipeline must agree within one unit.
        ft = normalizeValue(user.get(a.axisTag, a.defaultValue), (a.minValue, a.defaultValue, a.maxValue))
        if avar is not None and a.axisTag in avar.segments: ft = piecewiseLinearMap(ft, avar.segments[a.axisTag])
        assert abs(ft * 16384 - c) <= 1, (a.axisTag, ft * 16384, c)
        out.append(c)
    return out

def loc(font, coords):
    return {a.axisTag: c / 16384 for a, c in zip(font['fvar'].axes, coords)}

NORM = [
    ('JetBrainsMono[wght].ttf', [{'wght': 100}, {'wght': 350}, {'wght': 400}, {'wght': 550}, {'wght': 700}, {'wght': 800}, {'wght': 1000}]),
    ('Inter[opsz,wght].ttf', [{'wght': 650, 'opsz': 20}, {'wght': 900, 'opsz': 32}, {'opsz': 10}]),
    ('NotoSansArabic-Subset.ttf', [{'wght': 250, 'wdth': 75}, {'wght': 700}]),
    ('SourceSerif4Variable-Roman.otf', [{'wght': 300, 'opsz': 12}, {'wght': 650, 'opsz': 48}]),
]

def main(d):
    print('// Producer: fontTools %s via testdata/provenance/gen_var_reference.py' % fontTools.version)
    print('.{')
    print('    .normalize = .{')
    for name, cases in NORM:
        f = TTFont(os.path.join(d, name))
        for u in cases:
            user = ', '.join('.{ .tag = "%s", .value = %s }' % (k, v) for k, v in u.items())
            print('        .{ .font = "%s", .user = .{ %s }, .coords = .{ %s } },' % (name, user, ', '.join(map(str, spec_norm(f, u)))))
    print('    },')
    # HVAR advances, 1/64 units, every glyph.
    print('    .advances = .{')
    for name, wghts in (('JetBrainsMono[wght].ttf', (100, 350, 700)), ('Inter[opsz,wght].ttf', (900,))):
        f = TTFont(os.path.join(d, name))
        hvar = f['HVAR'].table; store = hvar.VarStore; hm = f['hmtx'].metrics; order = f.getGlyphOrder()
        for w in wghts:
            coords = spec_norm(f, {'wght': w})
            inst = VarStoreInstancer(store, f['fvar'].axes, loc(f, coords))
            adv = []
            for gid, g in enumerate(order):
                if hvar.AdvWidthMap: idx = hvar.AdvWidthMap.mapping[g]
                else: idx = gid
                adv.append(rnd((hm[g][0] + inst[idx]) * 64))
            print('        .{ .font = "%s", .coords = .{ %s }, .adv64 = .{ %s } },' % (name, ', '.join(map(str, coords)), ', '.join(map(str, adv))))
    print('    },')
    # MVAR metrics.
    print('    .mvar = .{')
    for name, u in (('Inter[opsz,wght].ttf', {'wght': 900, 'opsz': 32}), ('SourceSerif4Variable-Roman.otf', {'wght': 900})):
        f = TTFont(os.path.join(d, name))
        coords = spec_norm(f, u)
        inst = VarStoreInstancer(f['MVAR'].table.VarStore, f['fvar'].axes, loc(f, coords))
        vals = {r.ValueTag: inst[r.VarIdx] for r in f['MVAR'].table.ValueRecord}
        os2 = f['OS/2']; post = f['post']
        print('        .{ .font = "%s", .coords = .{ %s }, .x_height = %r, .strikeout_pos = %r, .underline_pos = %r },' % (
            name, ', '.join(map(str, coords)), os2.sxHeight + vals.get('xhgt', 0), os2.yStrikeoutPosition + vals.get('stro', 0), post.underlinePosition + vals.get('undo', 0)))
    print('    },')
    # Named instances of JetBrains Mono.
    f = TTFont(os.path.join(d, 'JetBrainsMono[wght].ttf'))
    print('    .named = .{')
    for i in f['fvar'].instances:
        print('        .{ .name = "%s", .wght = %r },' % (f['name'].getDebugName(i.subfamilyNameID), i.coordinates['wght']))
    print('    },')
    print('}')

main(sys.argv[1])
