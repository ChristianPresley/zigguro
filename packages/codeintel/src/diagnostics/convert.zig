//! LSP diagnostics to store diagnostics. `fromLsp` runs anywhere (the
//! reader thread converts pushes as they arrive): it copies what the store
//! keeps into the set's arena and interns `source` and `code`. `mapBytes`
//! runs on the UI thread against the document text the server saw.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zg_lsp = @import("zg_lsp");
const Store = @import("Store.zig");
const zg_core = @import("zg_core");
const zg_editor = @import("zg_editor");

const PieceTree = zg_editor.model.buffer.piece_tree.PieceTree;

const protocol = zg_lsp.protocol;

/// Parses `publishDiagnostics` params (allocating in `arena`).
pub fn parsePush(arena: Allocator, json: []const u8) !protocol.PublishDiagnosticsParams {
    return std.json.parseFromSliceLeaky(protocol.PublishDiagnosticsParams, arena, json, .{ .ignore_unknown_fields = true });
}

/// Fills `set` with `in` (sorted and counted).
pub fn fromLsp(set: *Store.Set, in: []const protocol.Diagnostic) Allocator.Error!void {
    const a = set.allocator();
    var strings: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer strings.deinit(set.arena.child_allocator);
    const out = try a.alloc(Store.Diagnostic, in.len);
    var code_buf: [16]u8 = undefined;
    for (in, out) |d, *o| {
        var flags: Store.Flags = .{};
        for (d.tags orelse &.{}) |t| switch (t) {
            .Unnecessary => flags.unnecessary = true,
            .Deprecated => flags.deprecated = true,
            _ => {},
        };
        const message = switch (d.message) {
            .string => |s| s,
            .markup_content => |m| blk: {
                flags.markdown = m.kind == .Markdown;
                break :blk m.value;
            },
        };
        const code: []const u8 = if (d.code) |c| switch (c) {
            .string => |s| s,
            .integer => |n| std.fmt.bufPrint(&code_buf, "{d}", .{n}) catch unreachable,
        } else "";
        o.* = .{
            .start = .{ .line = d.range.start.line, .character = d.range.start.character },
            .end = .{ .line = d.range.end.line, .character = d.range.end.character },
            .severity = severityOf(d.severity),
            .flags = flags,
            .message = try a.dupe(u8, message),
            .source = try intern(a, set.arena.child_allocator, &strings, d.source orelse ""),
            .code = try intern(a, set.arena.child_allocator, &strings, code),
            .data = if (d.data) |v| try std.json.Stringify.valueAlloc(a, v, .{}) else null,
        };
    }
    set.diags = out;
    set.finish();
}

fn intern(a: Allocator, gpa: Allocator, strings: *std.StringHashMapUnmanaged([]const u8), s: []const u8) Allocator.Error![]const u8 {
    if (s.len == 0) return "";
    const gop = try strings.getOrPut(gpa, s);
    if (!gop.found_existing) {
        const owned = try a.dupe(u8, s);
        gop.key_ptr.* = owned;
        gop.value_ptr.* = owned;
    }
    return gop.value_ptr.*;
}

pub fn severityOf(s: ?protocol.DiagnosticSeverity) Store.Severity {
    // Missing: the client decides; errors are the common reading.
    const v = s orelse return .err;
    return switch (v) {
        .Error => .err,
        .Warning => .warning,
        .Information => .information,
        .Hint => .hint,
        _ => .information,
    };
}

/// Sets the byte ranges of `set`'s diagnostics from `tree` (document
/// version `version`), whose columns are in `enc` units.
///
/// The diagnostics are sorted by start, so one forward walk over the text
/// finds their lines: looking up each line on its own costs a scan from
/// the start of its piece.
pub fn mapBytes(gpa: Allocator, set: *Store.Set, tree: *const PieceTree, enc: zg_core.utf8.Encoding, version: u64) Allocator.Error!void {
    var starts: Walker = .{ .tree = tree };
    var ends: Walker = .{ .tree = tree };
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(gpa);
    var scratch2: std.ArrayList(u8) = .empty;
    defer scratch2.deinit(gpa);
    for (set.diags) |*d| {
        const ls = starts.seek(d.start.line);
        const text = try starts.lineText(gpa, &scratch);
        const s = ls + zg_core.utf8.columnToByte(text, d.start.character, enc);
        const e = if (d.end.line == d.start.line)
            ls + zg_core.utf8.columnToByte(text, d.end.character, enc)
        else blk: {
            ends.line = starts.line;
            ends.start = starts.start;
            const le = ends.seek(d.end.line);
            break :blk le + zg_core.utf8.columnToByte(try ends.lineText(gpa, &scratch2), d.end.character, enc);
        };
        d.bytes = .{ .start = s, .end = @max(s, e) };
    }
    set.version = version;
}

/// Finds line starts moving forward through a tree (`\n`, `\r\n` and
/// `\r` end lines, as in LSP). Lines past the end clamp to the last.
const Walker = struct {
    tree: *const PieceTree,
    line: u64 = 0,
    start: u64 = 0,

    fn seek(w: *Walker, target: u64) u64 {
        if (target < w.line) {
            w.line = @min(target, w.tree.lineCount() - 1);
            w.start = w.tree.lineStart(w.line);
            return w.start;
        }
        if (target == w.line) return w.start;
        const len = w.tree.len();
        var it = w.tree.slice(.{ .start = w.start, .end = len });
        var off = w.start;
        while (it.next()) |chunk| {
            var i: usize = 0;
            while (std.mem.indexOfAnyPos(u8, chunk, i, "\r\n")) |j| {
                i = j + 1;
                // The CR of a CRLF: the LF ends the line.
                if (chunk[j] == '\r' and off + j + 1 < len and (if (j + 1 < chunk.len) chunk[j + 1] else w.tree.byteAt(off + j + 1)) == '\n') continue;
                w.line += 1;
                w.start = off + j + 1;
                if (w.line == target) return w.start;
            }
            off += chunk.len;
        }
        return w.start;
    }

    /// The current line without its terminator.
    fn lineText(w: *const Walker, gpa: Allocator, scratch: *std.ArrayList(u8)) Allocator.Error![]const u8 {
        var it = w.tree.slice(.{ .start = w.start, .end = w.tree.len() });
        const first = it.next() orelse return "";
        if (std.mem.indexOfAny(u8, first, "\r\n")) |j| return first[0..j];
        scratch.clearRetainingCapacity();
        try scratch.appendSlice(gpa, first);
        while (it.next()) |chunk| {
            const j = std.mem.indexOfAny(u8, chunk, "\r\n") orelse {
                try scratch.appendSlice(gpa, chunk);
                continue;
            };
            try scratch.appendSlice(gpa, chunk[0..j]);
            break;
        }
        return scratch.items;
    }
};
