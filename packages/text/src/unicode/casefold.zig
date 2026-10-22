//! Case folding (Unicode CaseFolding.txt, status C+F or C+S): bulk
//! folding with an ASCII vector fast path, and a streaming `Folder` that
//! maps each folded code point back to its source bytes for search.

const std = @import("std");
const Allocator = std.mem.Allocator;
const p = @import("props.zig");
const decode = @import("decode.zig");
const normalize = @import("normalize.zig");

/// Full folding (C+F, may expand: ß -> ss) or simple folding (C+S, one
/// code point for one).
pub const FoldMode = enum { full, simple };

const V = @Vector(16, u8);

/// Appends the case folding of `bytes` to `out`. Ill-formed bytes become
/// U+FFFD.
pub fn foldAppend(out: *std.ArrayList(u8), gpa: Allocator, bytes: []const u8, mode: FoldMode) !void {
    try out.ensureUnusedCapacity(gpa, bytes.len);
    var i: usize = 0;
    while (i < bytes.len) {
        if (i + 16 <= bytes.len) {
            const v: V = bytes[i..][0..16].*;
            if (@reduce(.And, v < @as(V, @splat(0x80)))) {
                const upper = (v >= @as(V, @splat('A'))) & (v <= @as(V, @splat('Z')));
                const folded = v | @select(u8, upper, @as(V, @splat(0x20)), @as(V, @splat(0)));
                try out.ensureUnusedCapacity(gpa, 16);
                out.appendSliceAssumeCapacity(&@as([16]u8, folded));
                i += 16;
                continue;
            }
        }
        const c = bytes[i];
        if (c < 0x80) {
            try out.append(gpa, if (c >= 'A' and c <= 'Z') c | 0x20 else c);
            i += 1;
            continue;
        }
        const u = decode.at(bytes, i);
        i += u.len;
        const cp: u21 = if (u.valid) u.cp else 0xFFFD;
        switch (mode) {
            .full => {
                const m = p.caseFoldFull(cp);
                for (m.slice()) |f| try appendCp(out, gpa, f);
            },
            .simple => try appendCp(out, gpa, p.caseFoldSimple(cp)),
        }
    }
}

/// Appends `cp` as UTF-8.
pub fn appendCp(out: *std.ArrayList(u8), gpa: Allocator, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable;
    try out.appendSlice(gpa, buf[0..n]);
}

/// One folded code point and the source bytes it came from.
pub const Folded = struct { cp: u21, src_start: usize, src_end: usize };

/// Streaming full case folding without allocation: each folded code point
/// carries the byte range of the source code point it came from (an
/// expansion such as ß -> s s yields two items with the same range).
pub const Folder = struct {
    bytes: []const u8,
    i: usize = 0,
    pending: p.Mapping = .{},
    k: u8 = 0,
    start: usize = 0,
    /// Canonical caseless mode (D145): NFD(toCasefold(NFD(x))).
    canon: ?normalize.CanonicalFolder = null,

    /// Folds `bytes`; with `canonical`, canonically equivalent inputs
    /// produce the same stream (canonical caseless matching), and code
    /// points reordered by normalization keep their own source ranges.
    pub fn init(bytes: []const u8, canonical: bool) Folder {
        return .{ .bytes = bytes, .canon = if (canonical) normalize.CanonicalFolder.init(bytes) else null };
    }

    /// The next folded code point, or null at the end.
    pub fn next(f: *Folder) ?Folded {
        if (f.canon) |*c| {
            const it = c.next() orelse return null;
            return .{ .cp = it.cp, .src_start = it.src_start, .src_end = it.src_end };
        }
        if (f.k < f.pending.len) {
            f.k += 1;
            return .{ .cp = f.pending.buf[f.k - 1], .src_start = f.start, .src_end = f.i };
        }
        if (f.i >= f.bytes.len) return null;
        f.start = f.i;
        const c = f.bytes[f.i];
        if (c < 0x80) {
            f.i += 1;
            return .{ .cp = if (c >= 'A' and c <= 'Z') c | 0x20 else c, .src_start = f.start, .src_end = f.i };
        }
        const u = decode.at(f.bytes, f.i);
        f.i += u.len;
        f.pending = p.caseFoldFull(if (u.valid) u.cp else 0xFFFD);
        f.k = 1;
        return .{ .cp = f.pending.buf[0], .src_start = f.start, .src_end = f.i };
    }
};

test {
    _ = @import("case_test.zig");
}
