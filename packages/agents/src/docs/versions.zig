//! A document's version timeline (E13.F04.S02.T01): the union of E12
//! checkpoints that touched the file (accepted agent changes), E09
//! snapshots of it, and save points the person marked, newest first,
//! with snapshots less than a minute apart collapsed into the latest.
//! E13 keeps no copies: each version loads through its provider.
//!
//! Comparing versions is a word diff (`diffWords`): lines first (Myers),
//! then words within each changed run of lines, so a 50k-word document
//! diffs in milliseconds. Restoring a version is an E12 changeset that
//! turns the current text into it, applied by the app with undo.

const std = @import("std");
const comments = @import("comments.zig");
const words = @import("words.zig");
const sections = @import("sections.zig");
const doc_session = @import("doc_session.zig");

const Allocator = std.mem.Allocator;
const Hunk = words.Hunk;

pub const Author = comments.Author;

pub const SourceKind = enum { checkpoint, scm_snapshot, save };

pub const Version = struct {
    /// The provider's id for it.
    id: []const u8,
    source: SourceKind,
    at_ms: i64,
    label: []const u8,
    author: Author,
    words: u32 = 0,
    /// Which provider listed it (set by `listVersions`).
    provider: u8 = 0,
};

/// Lists and loads versions of one kind (E12 checkpoints, E09 history).
pub const Provider = struct {
    ctx: *anyopaque,
    list: *const fn (ctx: *anyopaque, a: Allocator, path: []const u8) anyerror![]Version,
    load: *const fn (ctx: *anyopaque, a: Allocator, id: []const u8) anyerror![]const u8,
    /// Records a save point of the current file (`docs.markVersion`).
    mark: ?*const fn (ctx: *anyopaque, a: Allocator, path: []const u8, label: []const u8) anyerror!Version = null,
};

/// Snapshots closer together than this collapse into the later one.
pub const collapse_ms: i64 = 60_000;

/// Every provider's versions of `path`, newest first, collapsed. A
/// provider that fails is left out.
pub fn listVersions(a: Allocator, path: []const u8, providers: []const Provider) ![]Version {
    var all: std.ArrayList(Version) = .empty;
    for (providers, 0..) |p, i| {
        const vs = p.list(p.ctx, a, path) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => continue,
        };
        for (vs) |v| {
            var x = v;
            x.provider = @intCast(i);
            try all.append(a, x);
        }
    }
    std.mem.sort(Version, all.items, {}, struct {
        fn newer(_: void, x: Version, y: Version) bool {
            return x.at_ms > y.at_ms;
        }
    }.newer);
    return collapse(all.items);
}

/// Drops a snapshot when the next newer entry is a snapshot less than
/// `collapse_ms` later (in place; newest-first input).
pub fn collapse(vs: []Version) []Version {
    var n: usize = 0;
    for (vs) |v| {
        if (n > 0 and v.source == .scm_snapshot and vs[n - 1].source == .scm_snapshot and vs[n - 1].at_ms - v.at_ms < collapse_ms) continue;
        vs[n] = v;
        n += 1;
    }
    return vs[0..n];
}

pub fn loadVersion(a: Allocator, providers: []const Provider, v: Version) ![]const u8 {
    if (v.provider >= providers.len) return error.NoSuchProvider;
    const p = providers[v.provider];
    return p.load(p.ctx, a, v.id);
}

/// Marks a save point through the first provider that can.
pub fn markVersion(a: Allocator, providers: []const Provider, path: []const u8, label: []const u8) !?Version {
    for (providers, 0..) |p, i| if (p.mark) |m| {
        var v = try m(p.ctx, a, path, label);
        v.provider = @intCast(i);
        return v;
    };
    return null;
}

/// The changeset restoring `version_text` over `current` (the person's
/// action; the app applies it with undo). Null when they are the same.
pub fn restore(a: Allocator, port: doc_session.ChangePort, path: []const u8, current: []const u8, current_version: u64, version_text: []const u8, label: []const u8) !?u64 {
    const hs = try diffWords(a, current, version_text);
    if (hs.len == 0) return null;
    return try port.propose(port.ctx, .{
        .path = path,
        .base = current,
        .base_version = current_version,
        .hunks = hs,
        .summary = try std.fmt.allocPrint(a, "Restore {s}", .{label}),
        .rationale = null,
        .prov = .{ .tool = "docs.restoreVersion" },
    });
}

// ---- diff ----

/// Above this many edit steps between line sequences, the changed middle
/// is one hunk.
pub const max_line_edits = 2000;

const Line = struct { start: u32, end: u32, hash: u64 };

fn lines(a: Allocator, text: []const u8) ![]Line {
    var out: std.ArrayList(Line) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const e = if (std.mem.indexOfScalarPos(u8, text, i, '\n')) |nl| nl + 1 else text.len;
        try out.append(a, .{ .start = @intCast(i), .end = @intCast(e), .hash = std.hash.Wyhash.hash(0, text[i..e]) });
        i = e;
    }
    return out.items;
}

fn lineEql(x: []const u8, l: Line, y: []const u8, m: Line) bool {
    return l.hash == m.hash and std.mem.eql(u8, x[l.start..l.end], y[m.start..m.end]);
}

/// A run of changed lines: old[os..oe) became new[ns..ne).
const Region = struct { os: usize, oe: usize, ns: usize, ne: usize };

/// Word hunks turning `old` into `new` (offsets into `old`).
pub fn diffWords(a: Allocator, old: []const u8, new: []const u8) ![]Hunk {
    const ol = try lines(a, old);
    const nl = try lines(a, new);
    var out: std.ArrayList(Hunk) = .empty;
    const regions = try lineRegions(a, old, ol, new, nl);
    for (regions) |r| {
        const os: u32 = if (r.os < ol.len) ol[r.os].start else @intCast(old.len);
        const oe: u32 = if (r.oe > r.os) ol[r.oe - 1].end else os;
        const ns: u32 = if (r.ns < nl.len) nl[r.ns].start else @intCast(new.len);
        const ne: u32 = if (r.ne > r.ns) nl[r.ne - 1].end else ns;
        const hs = try words.hunks(a, old[os..oe], new[ns..ne], os);
        try out.appendSlice(a, hs);
    }
    return out.items;
}

/// Myers' diff over lines, as runs of changes.
fn lineRegions(a: Allocator, old: []const u8, ol: []const Line, new: []const u8, nl: []const Line) ![]Region {
    var pre: usize = 0;
    while (pre < ol.len and pre < nl.len and lineEql(old, ol[pre], new, nl[pre])) pre += 1;
    var suf: usize = 0;
    while (suf < ol.len - pre and suf < nl.len - pre and lineEql(old, ol[ol.len - 1 - suf], new, nl[nl.len - 1 - suf])) suf += 1;
    const x = ol[pre .. ol.len - suf];
    const y = nl[pre .. nl.len - suf];
    var out: std.ArrayList(Region) = .empty;
    if (x.len == 0 and y.len == 0) return out.items;
    const whole: Region = .{ .os = pre, .oe = ol.len - suf, .ns = pre, .ne = nl.len - suf };
    if (x.len == 0 or y.len == 0) {
        try out.append(a, whole);
        return out.items;
    }
    const n: isize = @intCast(x.len);
    const m: isize = @intCast(y.len);
    const max: isize = @min(n + m, max_line_edits);
    const off: isize = max + 1;
    const v = try a.alloc(isize, @intCast(2 * max + 3));
    @memset(v, 0);
    // Each step's V (the diagonals it can reach), for the walk back.
    const Snap = struct {
        lo: isize,
        vals: []isize,
        fn at(sn: @This(), k: isize) isize {
            return sn.vals[@intCast(k - sn.lo)];
        }
    };
    var trace: std.ArrayList(Snap) = .empty;
    var found = false;
    var d: isize = 0;
    outer: while (d <= max) : (d += 1) {
        try trace.append(a, .{ .lo = -d - 1, .vals = try a.dupe(isize, v[@intCast(off - d - 1)..@intCast(off + d + 2)]) });
        var k: isize = -d;
        while (k <= d) : (k += 2) {
            var i: isize = if (k == -d or (k != d and v[@intCast(off + k - 1)] < v[@intCast(off + k + 1)])) v[@intCast(off + k + 1)] else v[@intCast(off + k - 1)] + 1;
            var j = i - k;
            while (i < n and j < m and lineEql(old, x[@intCast(i)], new, y[@intCast(j)])) {
                i += 1;
                j += 1;
            }
            v[@intCast(off + k)] = i;
            if (i >= n and j >= m) {
                found = true;
                break :outer;
            }
        }
    }
    if (!found) {
        try out.append(a, whole);
        return out.items;
    }
    // Walk back into matched-line pairs (in reverse).
    var pairs: std.ArrayList([2]usize) = .empty;
    var i = n;
    var j = m;
    var step = d;
    while (step > 0) : (step -= 1) {
        const vv = trace.items[@intCast(step)];
        const k = i - j;
        const prev_k = if (k == -step or (k != step and vv.at(k - 1) < vv.at(k + 1))) k + 1 else k - 1;
        const prev_i = vv.at(prev_k);
        const prev_j = prev_i - prev_k;
        while (i > prev_i and j > prev_j) {
            i -= 1;
            j -= 1;
            try pairs.append(a, .{ @intCast(i), @intCast(j) });
        }
        i = prev_i;
        j = prev_j;
    }
    while (i > 0 and j > 0) {
        i -= 1;
        j -= 1;
        try pairs.append(a, .{ @intCast(i), @intCast(j) });
    }
    std.mem.reverse([2]usize, pairs.items);
    // Gaps between matched pairs are the changed regions.
    var oi: usize = 0;
    var nj: usize = 0;
    for (pairs.items) |p| {
        if (p[0] > oi or p[1] > nj) try out.append(a, .{ .os = pre + oi, .oe = pre + p[0], .ns = pre + nj, .ne = pre + p[1] });
        oi = p[0] + 1;
        nj = p[1] + 1;
    }
    if (oi < x.len or nj < y.len) try out.append(a, .{ .os = pre + oi, .oe = pre + x.len, .ns = pre + nj, .ne = pre + y.len });
    return out.items;
}

/// The words of `text` (the timeline's counts).
pub fn countWords(text: []const u8) u32 {
    return sections.countWords(text);
}
