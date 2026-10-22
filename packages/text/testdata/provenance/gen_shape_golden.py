#!/usr/bin/env python3
"""Maintainer-only: writes testdata/golden/shape/<set>.zon from HarfBuzz.

    python3 testdata/provenance/gen_shape_golden.py testdata/fonts testdata/golden/shape

Each case shapes UTF-8 text with uharfbuzz (font scale = units per em, so
values are font units; default cluster level, i.e. monotone graphemes) and
records gid, cluster (byte offset), x advance, x offset and y offset per
glyph in output (visual) order. `zig build` never runs this; the Zig tests
compare zg_text's shaper against the stored values.
"""
import os, subprocess, sys
import uharfbuzz as hb

LIGS = ["a != b && c => d", "->", "=>", "!=", "===", "<!--", "www", "0xFF", "|> <|> </> ::: ... ;;", "fi ffi fl", "x == y || z <= w"]

SETS = {
    "code_ligatures": [
        *[("JetBrainsMono[wght].ttf", t, {}, {}) for t in LIGS],
        *[("FiraCode-Regular.ttf", t, {}, {}) for t in LIGS],
        ("JetBrainsMono[wght].ttf", "a != b && c => d", {"liga": 0, "calt": 0}, {}),
        ("FiraCode-Regular.ttf", "a != b && c => d", {"liga": 0, "calt": 0}, {}),
        ("FiraCode-Regular.ttf", "0xFF 0 @ & r", {"ss01": 1, "cv05": 1, "zero": 1}, {}),
        ("JetBrainsMono[wght].ttf", "0xFF 0 r == g", {"zero": 1, "ss01": 1}, {}),
        ("JetBrainsMono[wght].ttf", "a != b && c => d", {}, {"wght": 800}),
    ],
    "gpos_kern": [
        ("Inter[opsz,wght].ttf", "AVATAR", {}, {}),
        ("Inter[opsz,wght].ttf", "AVATAR Wave To Ty", {}, {"wght": 700}),
        ("Inter[opsz,wght].ttf", "AVATAR", {"kern": 0}, {}),
        ("SourceSerif4-Regular.otf", "AVATAR Wave ffi", {}, {}),
        ("SourceSerif4Variable-Roman.otf", "AVATAR Wave", {}, {"wght": 650}),
        ("Inter[opsz,wght].ttf", "office 1/2 x⁄y 3⁄4", {}, {}),
    ],
    "gpos_marks": [
        ("Inter[opsz,wght].ttf", "Tô ẫ", {}, {}),
        ("Inter[opsz,wght].ttf", "Tô ẫ", {}, {}),
        ("Inter[opsz,wght].ttf", "ẹ́ ộ Å", {}, {}),
        ("Inter[opsz,wght].ttf", "x́́ q̧", {}, {}),
        ("SourceSerif4-Regular.otf", "Tô ẫ ñ", {}, {}),
        ("JetBrainsMono[wght].ttf", "é ǟ", {}, {}),
    ],
    "driver": [
        ("Inter[opsz,wght].ttf", "a‍b a­b a‌b", {}, {}),
        ("Inter[opsz,wght].ttf", "a️b ❤︎", {}, {}),
        ("Inter[opsz,wght].ttf", "a一b", {}, {}),
        ("Inter[opsz,wght].ttf", "a b c d e　f", {}, {}),
        ("Inter[opsz,wght].ttf", "a‑b", {}, {}),
        ("Inter[opsz,wght].ttf", "(a) [b] <c>", {}, {}, "rtl"),
        ("JetBrainsMono[wght].ttf", "-> => !=", {}, {}, "rtl"),
        ("Inter[opsz,wght].ttf", "́a", {}, {}),
        ("JetBrainsMono[wght].ttf", "\t\n x", {}, {}),
    ],
    "arabic": [
        *[("NotoSansArabic-Subset.ttf", t, {}, {}, "rtl", "Arab") for t in [
            "بسم الله الرحمن الرحيم",
            "لا لأ لإ لآ",
            "مَرْحَبًا بِكُمْ",
            "شَدَّة دَّ دَّ",
            "ب\u200dب ب\u200cب \u200dب\u200d",
            "بـب ـبـ ـ",
            "عام 2024 ١٢٣",
            "پیک گچ ژ ڤ",
            "ب\u0650\u0655 ب\u064e\u0654 ب\u0654\u064e",
            "ه\u0654 ي\u0654 و\u0654",
            "a ب c",
            "ءاب ؤة ئي",
        ]],
        ("NotoSansArabic-Subset.ttf", "بسم الله", {"init": 0}, {}, "rtl", "Arab"),
        ("NotoSansArabic-Subset.ttf", "لا بب", {"rlig": 0, "liga": 0}, {}, "rtl", "Arab"),
        ("NotoSansArabic-Subset.ttf", "بسم", {}, {}, "ltr", "Arab"),
        ("NotoSansArabic-Subset.ttf", "\u0710\u0712\u0710 \u0715\u0710", {}, {}, "rtl", "Syrc"),
    ],
    "use": [
        # Javanese: pre-base taling (moves before the base, and after a
        # pangkon), medials, pasangan, layar/cecak finals, a broken cluster.
        *[("NotoSansJavanese-Subset.ttf", t, {}, {}, "ltr", "Java") for t in [
            "\ua98f\ua9ba",
            "\ua98f\ua9ba\ua9b4",
            "\ua98f\ua9c0\ua9b1\ua9ba",
            "\ua9a7\ua9be\ua9ba\ua9b4",
            "\ua9b2\ua9a4\ua995\ua9ab\ua98f",
            "\ua9a7\ua9bf\ua9b8\ua982",
            "\ua9a4\ua9bc\ua981 \ua997\ua9b6\ua983",
            "\ua9ba",
            "\ua9ba\ua9b4 \ua9c0",
            "\ua98f\u200c\ua9ba",
        ]],
        # Tibetan: subjoined stacks, split vowels, marks, a broken cluster.
        *[("NotoSerifTibetan-Subset.ttf", t, {}, {}, "ltr", "Tibt") for t in [
            "\u0f56\u0f40\u0fb2\u0f0b\u0f64\u0f72\u0f66\u0f0b\u0f56\u0f51\u0f7a\u0f0b\u0f63\u0f7a\u0f42\u0f66\u0f0d",
            "\u0f66\u0f92\u0fb2\u0f74\u0f56",
            "\u0f62\u0f92\u0fb1\u0f0b\u0f58\u0f5a",
            "\u0f40\u0f73 \u0f40\u0f71\u0f72 \u0f40\u0f75",
            "\u0f68\u0f7c\u0f7e",
            "\u0f40\u0f7f \u0f40\u0f80\u0f84",
            "\u0f72\u0f40",
            "\u0f22\u0f20\u0f22\u0f26",
        ]],
    ],
    "indic": [
        # Devanagari (dev2): reph, pre-base matra, conjuncts, half forms,
        # ZWJ/ZWNJ, nukta, signs, broken clusters.
        *[("NotoSansDevanagari-Subset.ttf", t, {}, {}, "ltr", "Deva") for t in [
            "\u0930\u094d\u0915",
            "\u0915\u093f",
            "\u0915\u094d\u0937\u0924\u094d\u0930\u093f\u092f",
            "\u0930\u094d\u0915\u093f \u0930\u094d\u0915\u0947\u0902",
            "\u0938\u094d\u0924\u094d\u0930\u093f \u0939\u093f\u0928\u094d\u0926\u0940",
            "\u0915\u094d\u200d\u0937 \u0915\u094d\u200c\u0937 \u0915\u094d\u200c",
            "\u0930\u094d\u200d\u092f \u0930\u200d\u094d\u092f",
            "\u0915\u093c \u0921\u093c\u0940 \u0915\u0903 \u0915\u0949",
            "\u0926\u094d\u0927 \u0924\u094d\u0924 \u0936\u094d\u0930\u0940",
            "\u093f \u094d\u0915 \u0902",
            "\u0930\u094d \u0905\u0902 \u0906\u0930\u094d\u092f",
            # Vowel constraints: dotted circles in discouraged spellings.
            "\u0905\u093e \u0906\u0947 \u0930\u094d\u0907 \u0909\u0941 \u0905\u093e\u093e",
        ]],
        # Old-spec Devanagari (deva only): halant reordering, eyelash Ra.
        *[("NotoSansDevanagariOld-Subset.ttf", t, {}, {}, "ltr", "Deva") for t in [
            "\u0915\u094d\u0937\u0924\u094d\u0930\u093f\u092f",
            "\u0930\u094d\u0915\u093f",
            "\u0924\u094d\u0930 \u0915\u094d\u0924\u094d\u092f",
            "\u0924\u094d\u0930\u094d\u0915 \u0924\u094d\u0930\u094d\u200d\u0915",
            "\u0915\u093f \u0938\u094d\u0924\u094b",
        ]],
        # Bengali: ya-phala, reph, split matras, khanda ta, nukta forms.
        *[("NotoSansBengali-Subset.ttf", t, {}, {}, "ltr", "Beng") for t in [
            "\u0995\u09cd\u09af",
            "\u09b0\u09cd\u0995 \u0995\u09bf \u0995\u09cb \u0995\u09cc",
            "\u0995\u09cd\u09b7 \u09b6\u09cd\u09b0\u09c0",
            "\u09b0\u200d\u09cd\u09af \u09b0\u09cd\u09af",
            "\u09af\u09bc \u09a1\u09bc \u09ce",
            "\u09b8\u09cd\u09a4\u09cd\u09b0\u09c0 \u0995\u09cd\u09b0\u09bf",
            "\u09c7 \u09cd\u0995",
            "\u0985\u09be \u098b\u09c3",
        ]],
        # Malayalam: chillus (atomic and with ZWJ), pre-base ra, split
        # matras, logical repha.
        *[("NotoSansMalayalam-Subset.ttf", t, {}, {}, "ltr", "Mlym") for t in [
            "\u0d23\u0d4d\u200d \u0d28\u0d4d\u200d \u0d7b \u0d7a",
            "\u0d15\u0d4d\u0d15 \u0d15\u0d4a \u0d15\u0d46 \u0d15\u0d4c",
            "\u0d15\u0d4d\u0d30 \u0d15\u0d4d\u0d30\u0d46",
            "\u0d30\u0d4d\u200d \u0d30\u0d4d\u0d15 \u0d4e\u0d15",
            "\u0d38\u0d4d\u0d24\u0d4d\u0d30\u0d40 \u0d2e\u0d32\u0d2f\u0d3e\u0d33\u0d02",
            "\u0d46 \u0d4d",
            "\u0d07\u0d57 \u0d12\u0d3e \u0d0e\u0d46 \u0d14",
        ]],
        # Tamil: pre-base vowels, split vowels, ksha, shri.
        *[("NotoSansTamil-Subset.ttf", t, {}, {}, "ltr", "Taml") for t in [
            "\u0b95\u0bca \u0b95\u0bc6 \u0b95\u0bc8 \u0b95\u0bcc",
            "\u0b95\u0bcd\u0bb7 \u0bb8\u0bcd\u0bb0\u0bc0",
            "\u0b95\u0bcd\u0b95 \u0ba4\u0bae\u0bbf\u0bb4\u0bcd",
            "\u0bc6 \u0bcd",
            "\u0b85\u0bc2",
        ]],
        # Khmer: coeng stacks, coeng + RO before the base, pre-base and
        # split vowels, robat, a broken cluster.
        *[("NotoSansKhmer-Subset.ttf", t, {}, {}, "ltr", "Khmr") for t in [
            "\u1780\u17d2\u1780",
            "\u179f\u17d2\u178f\u17d2\u179a\u17b8",
            "\u1781\u17d2\u1798\u17c2\u179a",
            "\u1780\u17d2\u179a\u17c1\u17c7",
            "\u1780\u17be \u1780\u17c4\u17c7 \u1780\u17c5",
            "\u1784\u17d2\u179a\u17d2\u1782 \u1784\u17d2\u1782\u17d2\u179a",
            "\u1792\u17cc\u1798\u17cc",
            "\u17c1 \u17d2\u1780",
        ]],
        # Myanmar (mym2): medial ra and pre-base vowels before the base,
        # kinzi, stacked consonants, asat, tones, broken clusters.
        *[("NotoSansMyanmar-Subset.ttf", t, {}, {}, "ltr", "Mymr") for t in [
            "\u1000\u103c\u1031\u102c\u1004\u103a\u1038",
            "\u1021\u1004\u103a\u1039\u1002\u101c\u102d\u1015\u103a",
            "\u1019\u1039\u1018 \u1000\u1039\u1000",
            "\u1000\u103b\u103d\u1014\u103a\u102f\u1015\u103a",
            "\u101e\u1031\u1037 \u1019\u103e\u102c",
            "\u1031 \u103c",
            "\u1000\u1031\u1031",
        ]],
    ],
}


def arabic_random_cases():
    """Seeded random Arabic: letters of every joining type, marks
    (including modifier combining marks), tatweel, ZWJ/ZWNJ and spaces."""
    import random
    rng = random.Random(0xA4AB)
    letters = [chr(c) for c in range(0x0621, 0x064B)] + list("پچژگکیۀە")
    marks = ["\u064b", "\u064c", "\u064d", "\u064e", "\u064f", "\u0650", "\u0651", "\u0652", "\u0654", "\u0655", "\u0670"]
    extra = [" ", "\u0640", "\u200c", "\u200d"]
    cases = []
    for _ in range(30):
        out = []
        for _ in range(rng.randint(4, 16)):
            out.append(rng.choice(letters) if rng.random() < 0.85 else rng.choice(extra))
            while rng.random() < 0.25:
                out.append(rng.choice(marks))
        cases.append(("NotoSansArabic-Subset.ttf", "".join(out), {}, {}, "rtl", "Arab"))
    return cases


def use_random_cases():
    """Seeded random Javanese and Tibetan: bases, signs of every position,
    halants, joiners and spaces, so broken clusters and reordering occur."""
    import random
    rng = random.Random(0x05E5)
    java = [chr(c) for c in range(0xA984, 0xA9B3)] + [chr(c) for c in range(0xA9B3, 0xA9C1)] + ["\ua980", "\ua981", "\ua982", "\ua983", " ", "\u200c", "\u200d"]
    tibt_cps = [0x0F0B, 0x0F40, 0x0F42, 0x0F44, 0x0F51, 0x0F56, 0x0F58, 0x0F61, 0x0F62, 0x0F63, 0x0F64, 0x0F66, 0x0F68,
                0x0F71, 0x0F72, 0x0F73, 0x0F74, 0x0F75, 0x0F7A, 0x0F7C, 0x0F7E, 0x0F7F, 0x0F80, 0x0F84, 0x0F39,
                0x0F90, 0x0F92, 0x0F94, 0x0FA1, 0x0FA6, 0x0FA8, 0x0FB1, 0x0FB2, 0x0FB3, 0x0FB6, 0x0020]
    tibt = [chr(c) for c in tibt_cps]
    cases = []
    for font, script, chars in [("NotoSansJavanese-Subset.ttf", "Java", java), ("NotoSerifTibetan-Subset.ttf", "Tibt", tibt)]:
        for _ in range(20):
            cases.append((font, "".join(rng.choice(chars) for _ in range(rng.randint(3, 14))), {}, {}, "ltr", script))
    return cases


def indic_random_cases():
    """Seeded random Khmer and Myanmar: consonants, coengs and viramas,
    vowels of every position, signs, joiners and spaces."""
    import random
    rng = random.Random(0x1D1C)
    khmr = [chr(c) for c in list(range(0x1780, 0x17A3)) + list(range(0x17B6, 0x17D4))] + ["\u17d2"] * 6 + [" ", "\u200c", "\u200d"]
    mymr = [chr(c) for c in list(range(0x1000, 0x1022)) + list(range(0x102B, 0x103F))] + ["\u1039"] * 4 + [" ", "\u200c", "\u200d"]
    cases = []
    deva = [chr(c) for c in list(range(0x0915, 0x093A)) + list(range(0x093E, 0x094D)) + [0x0902, 0x0903, 0x093C, 0x0905, 0x0906]] + ["\u094d"] * 8 + [" ", "\u200c", "\u200d"]
    beng = [chr(c) for c in list(range(0x0995, 0x09BA)) + list(range(0x09BE, 0x09CD)) + [0x0981, 0x0982, 0x0983, 0x09BC, 0x0985, 0x09CE]] + ["\u09cd"] * 8 + [" ", "\u200c", "\u200d"]
    mlym = [chr(c) for c in list(range(0x0D15, 0x0D3A)) + list(range(0x0D3E, 0x0D4D)) + [0x0D02, 0x0D03, 0x0D05, 0x0D7A, 0x0D7B, 0x0D4E]] + ["\u0d4d"] * 8 + [" ", "\u200c", "\u200d"]
    taml = [chr(c) for c in list(range(0x0B95, 0x0BBA)) + list(range(0x0BBE, 0x0BCD)) + [0x0B82, 0x0B83, 0x0B85]] + ["\u0bcd"] * 8 + [" ", "\u200c", "\u200d"]
    for font, script, chars in [("NotoSansKhmer-Subset.ttf", "Khmr", khmr), ("NotoSansMyanmar-Subset.ttf", "Mymr", mymr),
                                ("NotoSansDevanagari-Subset.ttf", "Deva", deva), ("NotoSansBengali-Subset.ttf", "Beng", beng),
                                ("NotoSansMalayalam-Subset.ttf", "Mlym", mlym), ("NotoSansTamil-Subset.ttf", "Taml", taml)]:
        for _ in range(20):
            cases.append((font, "".join(rng.choice(chars) for _ in range(rng.randint(3, 14))), {}, {}, "ltr", script))
    return cases


def random_cases():
    """Seeded random strings: code punctuation runs, accented Latin and
    combining-mark stacks, per font."""
    import random
    rng = random.Random(0x5EED)
    code = list("abcdefxyzABRTVW0123456789 _-=+<>!&|:;.,/*#$%@?()[]{}~^'\"\\")
    latin = list("aeiouAEOVWTYfkl ") + ["\u00e9", "\u00f1", "\u00fc", "\u1eab", "\u0131", "\u00df"]
    marks = ["\u0300", "\u0301", "\u0302", "\u0303", "\u0308", "\u0323", "\u0327", "\u030a", "\u0304"]
    cases = []
    for font in ["JetBrainsMono[wght].ttf", "FiraCode-Regular.ttf"]:
        for _ in range(20):
            cases.append((font, "".join(rng.choice(code) for _ in range(rng.randint(8, 28))), {}, {}))
    for font in ["Inter[opsz,wght].ttf", "SourceSerif4-Regular.otf"]:
        for _ in range(20):
            out = []
            for _ in range(rng.randint(6, 18)):
                out.append(rng.choice(latin))
                while rng.random() < 0.3:
                    out.append(rng.choice(marks))
            cases.append((font, "".join(out), {}, {}))
    return cases


def shape(fonts_dir, case):
    font_name, text, feats, axes = case[:4]
    direction = case[4] if len(case) > 4 else "ltr"
    script = case[5] if len(case) > 5 else "Latn"
    blob = hb.Blob.from_file_path(os.path.join(fonts_dir, font_name))
    face = hb.Face(blob)
    font = hb.Font(face)
    if axes:
        font.set_variations(axes)
    buf = hb.Buffer()
    buf.add_utf8(text.encode("utf-8"))
    buf.direction = direction
    buf.script = script
    hb.shape(font, buf, feats)
    glyphs = [(i.codepoint, i.cluster, p.x_advance, p.x_offset, p.y_offset)
              for i, p in zip(buf.glyph_infos, buf.glyph_positions)]
    return font_name, text, feats, axes, direction, script, glyphs


def zstr(s):
    out = []
    for ch in s:
        o = ord(ch)
        if ch == '"': out.append('\\"')
        elif ch == '\\': out.append('\\\\')
        elif 0x20 <= o < 0x7f: out.append(ch)
        else: out.append('\\u{%x}' % o)
    return '"' + "".join(out) + '"'


def main():
    fonts_dir, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)
    SETS["random"] = random_cases()
    SETS["arabic"] += arabic_random_cases()
    SETS["use"] += use_random_cases()
    SETS["indic"] += indic_random_cases()
    for name, cases in SETS.items():
        lines = ["// Generated by testdata/provenance/gen_shape_golden.py with HarfBuzz %s." % hb.version_string(),
                 "// Glyphs: .{ gid, cluster, x_advance, x_offset, y_offset } in font units.",
                 ".{"]
        for case in cases:
            font_name, text, feats, axes, direction, script, glyphs = shape(fonts_dir, case)
            fstr = ",".join(("%s=%d" % (k, v)) for k, v in feats.items())
            ax = ", ".join(".{ .tag = %s, .value = %s }" % (zstr(k), float(v)) for k, v in axes.items())
            g = ", ".join(".{ %d, %d, %d, %d, %d }" % t for t in glyphs)
            sc = "" if script == "Latn" else " .script = .%s," % script
            lines.append("    .{ .font = %s, .text = %s, .features = %s, .dir = .%s,%s .axes = .{%s}, .glyphs = .{ %s } }," % (
                zstr(font_name), zstr(text), zstr(fstr), direction, sc, (" " + ax + " ") if ax else "", g))
        lines.append("}")
        with open(os.path.join(out_dir, name + ".zon"), "w") as f:
            f.write("\n".join(lines) + "\n")
    # The repository's fmt-check covers .zon files.
    subprocess.run(["zig", "fmt", out_dir], check=True)


if __name__ == "__main__":
    main()
