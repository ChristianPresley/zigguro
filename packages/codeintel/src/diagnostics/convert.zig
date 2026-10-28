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
const position = @import("../features/position.zig");

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

/// A copy of `src` (its own strings, no byte ranges), to be given byte
/// ranges for a document opened since `src` was reported.
pub fn copySet(gpa: Allocator, src: *const Store.Set) Allocator.Error!*Store.Set {
    const set = try Store.Set.create(gpa, src.owner);
    errdefer set.destroy();
    const a = set.allocator();
    const out = try a.alloc(Store.Diagnostic, src.diags.len);
    for (src.diags, out) |d, *o| {
        o.* = d;
        o.bytes = null;
        o.message = try a.dupe(u8, d.message);
        o.source = try a.dupe(u8, d.source);
        o.code = try a.dupe(u8, d.code);
        o.data = if (d.data) |x| try a.dupe(u8, x) else null;
    }
    set.diags = out;
    set.counts = src.counts;
    return set;
}

/// Sets the byte ranges of `set`'s diagnostics from `tree` (document
/// version `version`), whose columns are in `enc` units. The diagnostics
/// are sorted by start, so the starts are found in one forward walk; the
/// ends walk from their starts.
pub fn mapBytes(gpa: Allocator, set: *Store.Set, tree: *const PieceTree, enc: zg_core.utf8.Encoding, version: u64) Allocator.Error!void {
    var starts: position.Mapper = .{ .gpa = gpa, .tree = tree, .enc = enc };
    defer starts.deinit();
    var ends: position.Mapper = .{ .gpa = gpa, .tree = tree, .enc = enc };
    defer ends.deinit();
    for (set.diags) |*d| {
        const s = try starts.byteOf(.{ .line = d.start.line, .character = d.start.character });
        if (d.end.line != d.start.line) {
            ends.cursor = starts.cursor;
            ends.text_line = std.math.maxInt(u64);
        }
        const m = if (d.end.line == d.start.line) &starts else &ends;
        const e = try m.byteOf(.{ .line = d.end.line, .character = d.end.character });
        d.bytes = .{ .start = s, .end = @max(s, e) };
    }
    set.version = version;
}
