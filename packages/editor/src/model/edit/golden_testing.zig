//! Test helpers shared by the edit goldens: text with selections marked
//! (`¦` a caret, `«…»` a range) and scenario files
//!
//!     === name
//!     --- before
//!     marked text
//!     --- keys
//!     what to do
//!     --- after
//!     the expected marked text
//!
//! `-Dupdate-golden` rewrites the `after` sections.

const std = @import("std");
const options = @import("zg_options");
const sel_mod = @import("selection.zig");

const Allocator = std.mem.Allocator;
const Selection = sel_mod.Selection;
const gpa = std.testing.allocator;
const io = std.testing.io;

pub const caret = "¦";
pub const open_mark = "«";
pub const close_mark = "»";

/// Splits marked text into plain text and selections.
pub fn parseMarked(marked: []const u8, text: *std.ArrayList(u8), sels: *std.ArrayList(Selection)) !void {
    var i: usize = 0;
    var anchor: ?u64 = null;
    while (i < marked.len) {
        if (std.mem.startsWith(u8, marked[i..], caret)) {
            try sels.append(gpa, .caret(text.items.len));
            i += caret.len;
        } else if (std.mem.startsWith(u8, marked[i..], open_mark)) {
            anchor = text.items.len;
            i += open_mark.len;
        } else if (std.mem.startsWith(u8, marked[i..], close_mark)) {
            try sels.append(gpa, .{ .anchor = anchor.?, .head = text.items.len });
            i += close_mark.len;
        } else {
            try text.append(gpa, marked[i]);
            i += 1;
        }
    }
}

/// `text` with `sels` (sorted) marked, appended to `out`.
pub fn renderMarked(text: []const u8, sels: []const Selection, out: *std.ArrayList(u8)) !void {
    var marks: std.ArrayList(struct { at: u64, s: []const u8 }) = .empty;
    defer marks.deinit(gpa);
    for (sels) |s| {
        if (s.isCaret()) {
            try marks.append(gpa, .{ .at = s.head, .s = caret });
        } else {
            try marks.append(gpa, .{ .at = s.start(), .s = open_mark });
            try marks.append(gpa, .{ .at = s.end(), .s = close_mark });
        }
    }
    var prev: usize = 0;
    for (marks.items) |m| {
        try out.appendSlice(gpa, text[prev..@intCast(m.at)]);
        try out.appendSlice(gpa, m.s);
        prev = @intCast(m.at);
    }
    try out.appendSlice(gpa, text[prev..]);
}

pub const Scenario = struct { name: []const u8, before: []const u8, keys: []const u8, after: []const u8 };

/// Sections of a golden file. Section bodies end before the next "---"
/// or "===" line; the final newline of each body is dropped.
pub fn parseScenarios(text: []const u8, out: *std.ArrayList(Scenario)) !void {
    var it = std.mem.splitSequence(u8, text, "\n=== ");
    var first = true;
    while (it.next()) |chunk_in| {
        var chunk = chunk_in;
        if (first) {
            first = false;
            if (!std.mem.startsWith(u8, chunk, "=== ")) continue;
            chunk = chunk[4..];
        }
        const nl = std.mem.indexOfScalar(u8, chunk, '\n') orelse continue;
        var sc: Scenario = .{ .name = chunk[0..nl], .before = "", .keys = "", .after = "" };
        var rest = chunk[nl + 1 ..];
        while (std.mem.startsWith(u8, rest, "--- ")) {
            const hdr_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
            const name = rest[4..hdr_end];
            rest = if (hdr_end < rest.len) rest[hdr_end + 1 ..] else "";
            const end = std.mem.indexOf(u8, rest, "\n--- ") orelse rest.len;
            var body = rest[0..end];
            body = std.mem.trimEnd(u8, body, "\n");
            rest = if (end < rest.len) rest[end + 1 ..] else "";
            if (std.mem.eql(u8, name, "before")) sc.before = body else if (std.mem.eql(u8, name, "keys")) sc.keys = body else if (std.mem.eql(u8, name, "after")) sc.after = body;
        }
        try out.append(gpa, sc);
    }
}

/// Runs every scenario of `path` (relative to the package root) through
/// `run`, which returns the marked result (freed here), and compares it
/// with `after`. Fails unless the file has at least `min` scenarios.
pub fn runGolden(path: []const u8, min: usize, ctx: anytype, comptime run: fn (@TypeOf(ctx), Scenario) anyerror![]u8) !void {
    var root = try std.Io.Dir.openDirAbsolute(io, options.package_root, .{});
    defer root.close(io);
    const text = try root.readFileAlloc(io, path, gpa, .limited(1 << 20));
    defer gpa.free(text);
    var scenarios: std.ArrayList(Scenario) = .empty;
    defer scenarios.deinit(gpa);
    try parseScenarios(text, &scenarios);
    try std.testing.expect(scenarios.items.len >= min);
    var actuals: std.ArrayList([]u8) = .empty;
    defer {
        for (actuals.items) |a| gpa.free(a);
        actuals.deinit(gpa);
    }
    var failed: usize = 0;
    for (scenarios.items) |sc| {
        const got = try run(ctx, sc);
        try actuals.append(gpa, got);
        if (!std.mem.eql(u8, got, sc.after)) {
            failed += 1;
            if (!options.update_golden) std.debug.print("{s} \"{s}\":\n--- want\n{s}\n--- got\n{s}\n", .{ path, sc.name, sc.after, got });
        }
    }
    if (failed > 0 and options.update_golden) {
        var w: std.ArrayList(u8) = .empty;
        defer w.deinit(gpa);
        for (scenarios.items, actuals.items, 0..) |sc, got, i| {
            if (i > 0) try w.append(gpa, '\n');
            try w.print(gpa, "=== {s}\n--- before\n{s}\n--- keys\n{s}\n--- after\n{s}\n", .{ sc.name, sc.before, sc.keys, got });
        }
        try root.writeFile(io, .{ .sub_path = path, .data = w.items });
        return;
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}
