//! The debug console's input history (E07.F06.S04.T02): up to `max`
//! lines per adapter type, consecutive duplicates collapsed, navigated
//! with `prev`/`next`. Lines are kept exactly as typed (lldb-dap's
//! command escape prefix, a backtick by default, included).
//!
//! All adapter types share `<workspace-state>/debug/repl_history.zon`;
//! `encodeInto` replaces one type's lines in the file's current text.

const ReplHistory = @This();
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const sub_path = "debug/repl_history.zon";
pub const default_max = 1000;
const file_version = 1;

gpa: Allocator,
lines: std.ArrayList([]u8) = .empty,
max: usize = default_max,
/// The line shown while navigating; null at the (empty) input line.
cursor: ?usize = null,

pub fn init(gpa: Allocator) ReplHistory {
    return .{ .gpa = gpa };
}

pub fn deinit(h: *ReplHistory) void {
    for (h.lines.items) |l| h.gpa.free(l);
    h.lines.deinit(h.gpa);
    h.* = undefined;
}

/// Records a submitted line and ends navigation.
pub fn push(h: *ReplHistory, line: []const u8) void {
    h.cursor = null;
    if (line.len == 0) return;
    if (h.lines.items.len > 0 and std.mem.eql(u8, h.lines.items[h.lines.items.len - 1], line)) return;
    const copy = h.gpa.dupe(u8, line) catch return;
    h.lines.append(h.gpa, copy) catch return h.gpa.free(copy);
    h.trim();
}

fn trim(h: *ReplHistory) void {
    if (h.lines.items.len <= h.max) return;
    const drop = h.lines.items.len - h.max;
    for (h.lines.items[0..drop]) |l| h.gpa.free(l);
    h.lines.replaceRangeAssumeCapacity(0, drop, &.{});
}

/// The line before the one shown (the newest first); null when there is
/// none.
pub fn prev(h: *ReplHistory) ?[]const u8 {
    const n = h.lines.items.len;
    if (n == 0) return null;
    const c: usize = if (h.cursor) |c| (if (c == 0) 0 else c - 1) else n - 1;
    h.cursor = c;
    return h.lines.items[c];
}

/// The line after the one shown; null back at the input line.
pub fn next(h: *ReplHistory) ?[]const u8 {
    const c = h.cursor orelse return null;
    if (c + 1 >= h.lines.items.len) {
        h.cursor = null;
        return null;
    }
    h.cursor = c + 1;
    return h.lines.items[c + 1];
}

// ---------------------------------------------------------------------
// Persistence.

const Entry = struct { type: []const u8, lines: []const []const u8 = &.{} };
const File = struct {
    version: u32 = file_version,
    adapters: []const Entry = &.{},
};

fn decode(a: Allocator, bytes: []const u8) !File {
    const z = try a.dupeZ(u8, bytes);
    const f = try std.zon.parse.fromSliceAlloc(File, a, z, null, .{ .ignore_unknown_fields = true, .free_on_error = false });
    if (f.version != file_version) return error.UnsupportedVersion;
    return f;
}

/// Loads `adapter_type`'s lines from a `repl_history.zon` text.
pub fn load(h: *ReplHistory, bytes: []const u8, adapter_type: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(h.gpa);
    defer arena.deinit();
    const f = try decode(arena.allocator(), bytes);
    for (f.adapters) |e| if (std.mem.eql(u8, e.type, adapter_type)) {
        for (e.lines) |l| h.push(l);
        break;
    };
    h.cursor = null;
}

/// The file text with `adapter_type`'s lines replaced by `h`'s, in `a`.
/// `existing` is the file's current text (null or invalid: start empty).
pub fn encodeInto(h: *const ReplHistory, a: Allocator, existing: ?[]const u8, adapter_type: []const u8) Allocator.Error![]u8 {
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    const old: File = if (existing) |b| decode(aa, b) catch .{} else .{};
    var entries: std.ArrayList(Entry) = .empty;
    for (old.adapters) |e| if (!std.mem.eql(u8, e.type, adapter_type)) try entries.append(aa, e);
    const mine = try aa.alloc([]const u8, h.lines.items.len);
    for (mine, h.lines.items) |*d, l| d.* = l;
    try entries.append(aa, .{ .type = adapter_type, .lines = mine });
    var out: std.Io.Writer.Allocating = .init(a);
    std.zon.stringify.serialize(File{ .adapters = entries.items }, .{}, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    return out.toOwnedSlice() catch error.OutOfMemory;
}
