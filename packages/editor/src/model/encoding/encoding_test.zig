//! Encoding detection, codecs and round trips.

const std = @import("std");
const options = @import("zg_options");
const enc = @import("../encoding.zig");

const gpa = std.testing.allocator;
const io = std.testing.io;
const Encoding = enc.Encoding;

test "encoding: bom sniff table" {
    const cases = [_]struct { head: []const u8, e: Encoding, bom_len: u3 }{
        .{ .head = "\xEF\xBB\xBFabc", .e = .utf8_bom, .bom_len = 3 },
        .{ .head = "\xFE\xFF\x00A", .e = .utf16be_bom, .bom_len = 2 },
        .{ .head = "\xFF\xFEA\x00", .e = .utf16le_bom, .bom_len = 2 },
        .{ .head = "\xFF\xFE\x00\x00A\x00\x00\x00", .e = .utf32le_bom, .bom_len = 4 },
        .{ .head = "\x00\x00\xFE\xFF\x00\x00\x00A", .e = .utf32be_bom, .bom_len = 4 },
        // FF FE 41 00 is UTF-16LE, not UTF-32.
        .{ .head = "\xFF\xFE\x41\x00", .e = .utf16le_bom, .bom_len = 2 },
    };
    for (cases) |c| {
        const d = enc.detect(c.head, null, .windows_1252);
        try std.testing.expectEqual(c.e, d.encoding);
        try std.testing.expectEqual(c.bom_len, d.bom_len);
        try std.testing.expectEqual(.bom, d.confidence);
    }
    // A hint loses to a BOM but beats the heuristics.
    try std.testing.expectEqual(Encoding.utf8_bom, enc.detect("\xEF\xBB\xBFx", .koi8_r, .windows_1252).encoding);
    try std.testing.expectEqual(Encoding.koi8_r, enc.detect("plain", .koi8_r, .windows_1252).encoding);
}

test "encoding: utf16 heuristic" {
    var le: std.ArrayList(u8) = .empty;
    defer le.deinit(gpa);
    try enc.encode(.utf16le, "const x = 1;\nfn f() void {}\n" ** 4, &le, gpa);
    try std.testing.expectEqual(Encoding.utf16le, enc.detect(le.items, null, .windows_1252).encoding);
    var be: std.ArrayList(u8) = .empty;
    defer be.deinit(gpa);
    try enc.encode(.utf16be, "const x = 1;\nfn f() void {}\n" ** 4, &be, gpa);
    try std.testing.expectEqual(Encoding.utf16be, enc.detect(be.items, null, .windows_1252).encoding);
    var jp: std.ArrayList(u8) = .empty;
    defer jp.deinit(gpa);
    try enc.encode(.utf16le, "日本語のテキストです。\n" ** 6, &jp, gpa);
    try std.testing.expectEqual(Encoding.utf16le, enc.detect(jp.items, null, .windows_1252).encoding);
    // Binary with zeros on both sides is not UTF-16.
    var bin: [256]u8 = undefined;
    for (&bin, 0..) |*b, i| b.* = @intCast(i);
    try std.testing.expectEqual(Encoding.binary, enc.detect(&bin, null, .windows_1252).encoding);
    try std.testing.expectEqual(Encoding.binary, enc.detect("hello\x00world\n", null, .windows_1252).encoding);
}

test "encoding: detection fixtures" {
    var root = try std.Io.Dir.openDirAbsolute(io, options.package_root, .{});
    defer root.close(io);
    var dir = try root.openDir(io, "testdata/encodings", .{});
    defer dir.close(io);
    const manifest = try dir.readFileAlloc(io, "expected.txt", gpa, .limited(1 << 16));
    defer gpa.free(manifest);
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const name = f.next().?;
        const want = std.meta.stringToEnum(Encoding, f.next().?).?;
        const conf = f.next().?;
        const bytes = try dir.readFileAlloc(io, name, gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        const d = enc.detect(bytes, null, .windows_1252);
        if (d.encoding != want or !std.mem.eql(u8, @tagName(d.confidence), conf)) {
            std.debug.print("{s}: got {t} {t}, want {t} {s}\n", .{ name, d.encoding, d.confidence, want, conf });
            return error.TestUnexpectedResult;
        }
        // Every fixture round-trips in its detected encoding.
        const text = try enc.decodeAll(d.encoding, bytes, gpa);
        defer gpa.free(text);
        var back: std.ArrayList(u8) = .empty;
        defer back.deinit(gpa);
        try enc.encode(d.encoding, text, &back, gpa);
        try std.testing.expectEqualSlices(u8, bytes, back.items);
        n += 1;
    }
    try std.testing.expect(n >= 30);
}

fn roundTrip(e: Encoding, bytes: []const u8) !void {
    const text = try enc.decodeAll(e, bytes, gpa);
    defer gpa.free(text);
    var back: std.ArrayList(u8) = .empty;
    defer back.deinit(gpa);
    try enc.encode(e, text, &back, gpa);
    try std.testing.expectEqualSlices(u8, bytes, back.items);
}

test "encoding: round-trip every encoding" {
    var all: [256]u8 = undefined;
    for (&all, 0..) |*b, i| b.* = @intCast(i);
    for (std.enums.values(Encoding)) |e| {
        if (e.singleByte() == null and e != .binary) continue;
        try roundTrip(e, &all);
    }
    // UTF-8 keeps even invalid bytes.
    try roundTrip(.utf8, &all);
    var with_bom: std.ArrayList(u8) = .empty;
    defer with_bom.deinit(gpa);
    try with_bom.appendSlice(gpa, "\xEF\xBB\xBF");
    try with_bom.appendSlice(gpa, &all);
    try roundTrip(.utf8_bom, with_bom.items);
    // Random UTF-16 code units, unpaired surrogates included.
    var prng: std.Random.DefaultPrng = .init(450);
    const r = prng.random();
    for (0..200) |_| {
        var units: [64]u8 = undefined;
        const n = 2 * r.uintLessThan(usize, 33);
        for (units[0..n]) |*b| b.* = if (r.boolean()) r.int(u8) else @as(u8, 0xD8 + r.uintLessThan(u8, 8));
        try roundTrip(.utf16le, units[0..n]);
        try roundTrip(.utf16be, units[0..n]);
        var bom_le: [66]u8 = undefined;
        bom_le[0] = 0xFF;
        bom_le[1] = 0xFE;
        @memcpy(bom_le[2..][0..n], units[0..n]);
        try roundTrip(.utf16le_bom, bom_le[0 .. n + 2]);
    }
    // UTF-32 within range.
    for (0..100) |_| {
        var buf: [4 + 4 * 16]u8 = undefined;
        @memcpy(buf[0..4], "\xFF\xFE\x00\x00");
        const n = r.uintLessThan(usize, 17);
        for (0..n) |k| std.mem.writeInt(u32, buf[4 + 4 * k ..][0..4], r.uintLessThan(u32, 0x110000), .little);
        try roundTrip(.utf32le_bom, buf[0 .. 4 + 4 * n]);
    }
}

test "encoding: streaming decode with chunk splits" {
    const samples = [_]struct { e: Encoding, text: []const u8 }{
        .{ .e = .utf16le_bom, .text = "a😀é\n\u{10FFFF}z" },
        .{ .e = .utf16be, .text = "x😀y€" },
        .{ .e = .utf32be_bom, .text = "😀ab" },
        .{ .e = .windows_1251, .text = "Привет" },
        .{ .e = .utf8_bom, .text = "héllo" },
    };
    for (samples) |sm| {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(gpa);
        try enc.encode(sm.e, sm.text, &bytes, gpa);
        // Split once at every offset 0..7 and also into 1-byte chunks.
        for (0..8) |split| {
            const at = @min(split, bytes.items.len);
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(gpa);
            var d: enc.Decoder = .init(sm.e);
            try d.decode(bytes.items[0..at], &out, gpa, false);
            try d.decode(bytes.items[at..], &out, gpa, true);
            try std.testing.expectEqualStrings(sm.text, out.items);
        }
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var d: enc.Decoder = .init(sm.e);
        for (bytes.items) |b| try d.decode(&.{b}, &out, gpa, false);
        try d.decode("", &out, gpa, true);
        try std.testing.expectEqualStrings(sm.text, out.items);
    }
}

test "encoding: unrepresentable reports offset" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try std.testing.expectError(error.Unrepresentable, enc.encode(.windows_1252, "abc日本", &out, gpa));
    try std.testing.expectEqual(@as(?usize, 3), enc.firstUnrepresentable(.windows_1252, "abc日本"));
    try std.testing.expectEqual(@as(?usize, null), enc.firstUnrepresentable(.windows_1252, "café €"));
    try std.testing.expectEqual(@as(?usize, 1), enc.firstUnrepresentable(.utf16le, "a\xFFb"));
    try std.testing.expectEqual(@as(?usize, null), enc.firstUnrepresentable(.utf8, "a\xFFb"));
}

test "encoding: labels" {
    try std.testing.expectEqual(@as(?Encoding, .windows_1252), enc.fromLabel("  Latin1 "));
    try std.testing.expectEqual(@as(?Encoding, .utf16le), enc.fromLabel("UTF-16"));
    try std.testing.expectEqual(@as(?Encoding, .iso_8859_2), enc.fromLabel("iso_8859-2"));
    try std.testing.expectEqual(@as(?Encoding, null), enc.fromLabel("klingon"));
    try std.testing.expectEqualStrings("ISO-8859-15", enc.label(.iso_8859_15));
    try std.testing.expectEqualStrings("windows-1252", enc.label(.windows_1252));
    try std.testing.expectEqualStrings("UTF-16LE with BOM", enc.label(.utf16le_bom));
}

test "fuzz: decode/encode round-trip" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const n = s.slice(&buf);
            const e = std.enums.values(Encoding)[s.index(std.enums.values(Encoding).len)];
            var bytes: []const u8 = buf[0..n];
            // Malformed UTF-16/32 (odd tails, out-of-range units) is not
            // round-trip material: trim to whole, valid units.
            switch (e) {
                .utf16le, .utf16le_bom, .utf16be, .utf16be_bom => bytes = bytes[0 .. bytes.len - bytes.len % 2],
                .utf32le_bom, .utf32be_bom => return,
                else => {},
            }
            const bom = e.bom();
            if (bom.len > 0 and !std.mem.startsWith(u8, bytes, bom)) return;
            try roundTrip(e, bytes);
        }
    }.one, .{});
}
