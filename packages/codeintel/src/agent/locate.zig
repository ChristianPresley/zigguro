//! Symbol addressing for agents (E07.F05.S01.T01): agents name a symbol
//! by a line and a column counted in characters, by its name on a line
//! (agents are often a line or two off, so up to three lines either side
//! are searched), or by a qualified name such as `std.mem.Allocator`,
//! which a `workspace/symbol` search resolves (`pick`).

const std = @import("std");
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const position = @import("../features/position.zig");

const Allocator = std.mem.Allocator;
const protocol = zg_lsp.protocol;

pub const SymbolRef = union(enum) {
    /// A 1-based line; the column (1-based, in Unicode scalar values)
    /// defaults to the line's first non-blank character.
    position: struct { path: []const u8, line: u32, column: ?u32 = null },
    /// The `occurrence`-th whole-word match of `name` on the 1-based
    /// line, else the first within three lines of it.
    name_on_line: struct { path: []const u8, line: u32, name: []const u8, occurrence: u32 = 1 },
    /// `container.name` (`.` or `::` between segments), or a bare name.
    qualified: []const u8,

    pub fn path(r: SymbolRef) ?[]const u8 {
        return switch (r) {
            .position => |p| p.path,
            .name_on_line => |n| n.path,
            .qualified => null,
        };
    }

    pub fn line(r: SymbolRef) ?u32 {
        return switch (r) {
            .position => |p| p.line,
            .name_on_line => |n| n.line,
            .qualified => null,
        };
    }
};

/// How far from its line a name is looked for.
pub const max_line_drift = 3;

pub const Found = union(enum) {
    /// `line` is 0-based; `offset` is the byte offset in the document.
    hit: struct { line: u64, offset: u64 },
    /// The line is past the end; the document's line count.
    past_end: u64,
    /// The name is not on the line or near it.
    not_found,
};

/// Where a `position` or `name_on_line` ref points in `m`'s document.
pub fn inDocument(m: *position.Mapper, ref: SymbolRef) Allocator.Error!Found {
    const lines = m.tree.lineCount();
    const line1 = ref.line() orelse unreachable;
    if (line1 == 0 or line1 > lines) return .{ .past_end = lines };
    const line0: u64 = line1 - 1;
    switch (ref) {
        .name_on_line => |n| {
            if (n.name.len == 0) return .not_found;
            // The line itself, then 1, 2 and 3 lines away (before, then after).
            const order = [_]i64{ 0, -1, 1, -2, 2, -3, 3 };
            for (order) |d| {
                const l = @as(i64, @intCast(line0)) + d;
                if (l < 0 or l >= lines) continue;
                const text, const start = try lineAt(m, @intCast(l));
                if (findWord(text, n.name, if (d == 0) @max(n.occurrence, 1) else 1)) |i| return .{ .hit = .{ .line = @intCast(l), .offset = start + i } };
            }
            return .not_found;
        },
        .position => |p| {
            const text, const start = try lineAt(m, line0);
            const i = if (p.column) |col|
                zg_core.utf8.columnToByte(text, @max(col, 1) - 1, .utf32)
            else
                std.mem.indexOfNone(u8, text, " \t") orelse 0;
            return .{ .hit = .{ .line = line0, .offset = start + i } };
        },
        .qualified => unreachable,
    }
}

fn lineAt(m: *position.Mapper, l: u64) Allocator.Error!struct { []const u8, u64 } {
    const start = m.cursor.seek(m.tree, l);
    const text = try m.cursor.text(m.tree, m.gpa, &m.scratch);
    // The mapper's own line cache now points at other text.
    m.text_line = std.math.maxInt(u64);
    return .{ text, start };
}

/// The first whole-word match of `name` at or after byte `from`, on its
/// line or the `max_lines` lines after it.
pub fn forward(m: *position.Mapper, from: u64, name: []const u8, max_lines: u64) Allocator.Error!?u64 {
    const lines = m.tree.lineCount();
    _ = m.cursor.seekOffset(m.tree, from);
    var line = m.cursor.line;
    const last = @min(lines, line +| max_lines +| 1);
    while (line < last) : (line += 1) {
        const text, const start = try lineAt(m, line);
        const skip: usize = if (from > start) @intCast(@min(from - start, text.len)) else 0;
        var k: u32 = 1;
        while (findWord(text, name, k)) |i| : (k += 1) {
            if (i >= skip) return start + i;
        }
    }
    return null;
}

/// The byte index of the `n`-th whole-word match of `word` in `text`.
pub fn findWord(text: []const u8, word: []const u8, n: u32) ?usize {
    if (word.len == 0) return null;
    var seen: u32 = 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, word)) |i| {
        from = i + 1;
        const before_ok = i == 0 or !isWordByte(text[i - 1]) or !isWordByte(word[0]);
        const after_ok = i + word.len == text.len or !isWordByte(text[i + word.len]) or !isWordByte(word[word.len - 1]);
        if (!before_ok or !after_ok) continue;
        seen += 1;
        if (seen == n) return i;
    }
    return null;
}

/// Word characters as the editor's word motions see them (non-ASCII
/// bytes count as word characters).
fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

// --------------------------------------------------------------- qualified

pub const Qualified = struct {
    /// Segments before the name, joined by `.` (empty for a bare name).
    container: []const u8,
    name: []const u8,
};

/// `q` split at its last separator, with `::` spelled `.`.
pub fn splitQualified(arena: Allocator, q: []const u8) Allocator.Error!Qualified {
    const n = try normalize(arena, std.mem.trim(u8, q, " \t"));
    const i = std.mem.lastIndexOfScalar(u8, n, '.') orelse return .{ .container = "", .name = n };
    return .{ .container = n[0..i], .name = n[i + 1 ..] };
}

fn normalize(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOf(u8, s, "::") == null) return s;
    return std.mem.replaceOwned(u8, arena, s, "::", ".");
}

/// A `workspace/symbol` answer, as `pick` sees it.
pub const Candidate = struct {
    name: []const u8,
    container: ?[]const u8 = null,
    kind: protocol.SymbolKind = .Variable,
    uri: []const u8,
    /// Null when the server sent the symbol without a range.
    range: ?protocol.Range = null,
};

pub const Pick = union(enum) {
    one: usize,
    none,
    /// Indexes of the best matches, at most `max_candidates`.
    ambiguous: []const usize,
};

pub const max_candidates = 10;

/// The candidate `q` names: same name, and a container that matches the
/// qualifier (its tail, or the file's name, as in Zig where files are
/// structs). One exact container match wins over partial ones.
pub fn pick(arena: Allocator, cands: []const Candidate, q: []const u8) Allocator.Error!Pick {
    const want = try splitQualified(arena, q);
    if (want.name.len == 0) return .none;
    var best: u8 = 0;
    var at: std.ArrayList(usize) = .empty;
    for (cands, 0..) |c, i| {
        const s = try score(arena, c, want);
        if (s == 0 or s < best) continue;
        if (s > best) {
            best = s;
            at.clearRetainingCapacity();
        }
        try at.append(arena, i);
    }
    return switch (at.items.len) {
        0 => .none,
        1 => .{ .one = at.items[0] },
        else => .{ .ambiguous = at.items[0..@min(at.items.len, max_candidates)] },
    };
}

/// 0: no match; 1: the name matches, the container partly (or no
/// container was asked for); 2: the container is the one asked for.
fn score(arena: Allocator, c: Candidate, want: Qualified) Allocator.Error!u8 {
    var name = try normalize(arena, c.name);
    var container = try normalize(arena, c.container orelse "");
    // Some servers send qualified names.
    if (!std.mem.eql(u8, name, want.name)) {
        if (!endsWithSegment(name, want.name)) return 0;
        const prefix = name[0 .. name.len - want.name.len - 1];
        container = if (container.len == 0) prefix else try std.mem.concat(arena, u8, &.{ container, ".", prefix });
        name = want.name;
    }
    if (want.container.len == 0) return if (container.len == 0) 2 else 1;
    if (container.len > 0) {
        if (std.mem.eql(u8, container, want.container)) return 2;
        if (endsWithSegment(container, want.container) or endsWithSegment(want.container, container)) return 1;
    }
    const stem = fileStem(c.uri);
    if (stem.len > 0 and (std.mem.eql(u8, stem, want.container) or endsWithSegment(want.container, stem))) return 1;
    return 0;
}

/// `long` is `short` or ends with `.short`.
fn endsWithSegment(long: []const u8, short: []const u8) bool {
    if (short.len == 0) return false;
    if (std.mem.eql(u8, long, short)) return true;
    return long.len > short.len and std.mem.endsWith(u8, long, short) and long[long.len - short.len - 1] == '.';
}

/// The file name of `uri` without its extension.
fn fileStem(uri: []const u8) []const u8 {
    const base = uri[if (std.mem.lastIndexOfAny(u8, uri, "/\\")) |i| i + 1 else 0..];
    return base[0 .. std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len];
}
