//! A session's debug console (E07.F06.S02.T01): `output` events routed by
//! category. `console`, `important`, `stdout` and `stderr` lines are kept
//! (up to `max_entries`, oldest dropped); `telemetry` is dropped. `group`
//! `start`/`startCollapsed`/`end` nest the entries that follow.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Category = enum {
    console,
    important,
    stdout,
    stderr,
    telemetry,
    /// Any other category (shown like `console`).
    other,

    pub fn fromWire(s: ?[]const u8) Category {
        // DAP: a missing category means `console`.
        const name = s orelse return .console;
        return std.meta.stringToEnum(Category, name) orelse .other;
    }
};

pub const Group = enum { none, start, start_collapsed, end };

/// The parts of an `output` event body the console uses.
pub const OutputBody = struct {
    category: ?[]const u8 = null,
    output: []const u8 = "",
    group: ?[]const u8 = null,
    variablesReference: ?i64 = null,
    source: ?struct { path: ?[]const u8 = null, name: ?[]const u8 = null } = null,
    line: ?i64 = null,
    column: ?i64 = null,
};

pub const Entry = struct {
    category: Category,
    text: []const u8,
    /// Nesting depth from `group` (0 at the top).
    depth: u16,
    group: Group,
    /// A structured value to expand (`variablesReference`).
    variables_reference: ?i64 = null,
    source_path: ?[]const u8 = null,
    line: ?u32 = null,
    column: ?u32 = null,
};

pub const max_entries = 10_000;

pub const Console = struct {
    gpa: Allocator,
    entries: std.ArrayList(Entry) = .empty,
    depth: u16 = 0,
    /// Entries dropped from the front since the start.
    dropped: u64 = 0,
    telemetry_dropped: u64 = 0,

    pub fn init(gpa: Allocator) Console {
        return .{ .gpa = gpa };
    }

    pub fn deinit(c: *Console) void {
        for (c.entries.items) |e| c.freeEntry(e);
        c.entries.deinit(c.gpa);
        c.* = undefined;
    }

    fn freeEntry(c: *Console, e: Entry) void {
        c.gpa.free(e.text);
        if (e.source_path) |p| c.gpa.free(p);
    }

    pub fn clear(c: *Console) void {
        for (c.entries.items) |e| c.freeEntry(e);
        c.entries.clearRetainingCapacity();
        c.depth = 0;
    }

    /// Adds `body`; returns the category, or null when it was dropped.
    pub fn add(c: *Console, body: OutputBody) Allocator.Error!?Category {
        const cat = Category.fromWire(body.category);
        if (cat == .telemetry) {
            c.telemetry_dropped += 1;
            return null;
        }
        const group: Group = if (body.group) |g|
            (if (std.mem.eql(u8, g, "start")) .start else if (std.mem.eql(u8, g, "startCollapsed")) .start_collapsed else if (std.mem.eql(u8, g, "end")) .end else .none)
        else
            .none;
        if (group == .end and c.depth > 0) c.depth -= 1;
        const copy = try c.gpa.dupe(u8, body.output);
        errdefer c.gpa.free(copy);
        const path: ?[]const u8 = if (body.source) |s| (if (s.path) |p| try c.gpa.dupe(u8, p) else null) else null;
        errdefer if (path) |p| c.gpa.free(p);
        if (c.entries.items.len == max_entries) {
            c.freeEntry(c.entries.orderedRemove(0));
            c.dropped += 1;
        }
        try c.entries.append(c.gpa, .{
            .category = cat,
            .text = copy,
            .depth = c.depth,
            .group = group,
            .variables_reference = if (body.variablesReference) |r| (if (r > 0) r else null) else null,
            .source_path = path,
            .line = if (body.line) |l| (if (l > 0) @intCast(l) else null) else null,
            .column = if (body.column) |l| (if (l > 0) @intCast(l) else null) else null,
        });
        if (group == .start or group == .start_collapsed) c.depth +|= 1;
        return cat;
    }

    /// The entries of `cat`, joined, for tests and the agent tools.
    pub fn text(c: *const Console, a: Allocator, cat: Category) Allocator.Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        for (c.entries.items) |e| if (e.category == cat) try out.appendSlice(a, e.text);
        return out.items;
    }
};
