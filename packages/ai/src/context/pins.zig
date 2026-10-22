//! Pinned context and one-shot mentions (E10.F07.S02.T01). E08's
//! `ContextResolver` turns `ContextRef`s into `ContextItem`s on a worker;
//! the assembler attaches them to the newest user message as
//! `<context-item>` text blocks. Pins are re-checked before each request:
//! a changed pin is re-attached with a fresh excerpt and a reminder, while
//! earlier copies stay in place so the cached prefix is untouched.

const std = @import("std");
const proto = @import("zg_ai_proto");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// E08.F08 `ContextResolver.resolve(refs, budget)`; returns one item per
/// ref, in order, allocated in `arena`.
pub const ContextResolver = struct {
    ctx: *anyopaque,
    resolve: *const fn (ctx: *anyopaque, io: Io, arena: Allocator, refs: []const proto.ContextRef, budget_tokens: u32) anyerror![]const proto.ContextItem,
};

/// One pin and the version last attached.
pub const Pin = struct {
    ref: proto.ContextRef,
    attached: ?u64 = null,
};

/// The pins of an agent. Refs are copied into `arena`.
pub const PinSet = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Pin) = .empty,

    pub fn init(gpa: Allocator) PinSet {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(p: *PinSet) void {
        p.arena.deinit();
    }

    /// Adds `ref` unless already pinned.
    pub fn add(p: *PinSet, ref: proto.ContextRef) Allocator.Error!void {
        for (p.items.items) |x| if (refEql(x.ref, ref)) return;
        try p.items.append(p.arena.allocator(), .{ .ref = try cloneRef(p.arena.allocator(), ref) });
    }

    /// Removes `ref`; true when it was pinned.
    pub fn remove(p: *PinSet, ref: proto.ContextRef) bool {
        for (p.items.items, 0..) |x, i| if (refEql(x.ref, ref)) {
            _ = p.items.orderedRemove(i);
            return true;
        };
        return false;
    }
};

/// Deep-copies `ref` into `a`.
pub fn cloneRef(a: Allocator, ref: proto.ContextRef) Allocator.Error!proto.ContextRef {
    return switch (ref) {
        inline else => |payload, tag| blk: {
            const P = @TypeOf(payload);
            if (P == []const u8) break :blk @unionInit(proto.ContextRef, @tagName(tag), try a.dupe(u8, payload));
            var c = payload;
            inline for (std.meta.fields(P)) |f| {
                if (f.type == []const u8) @field(c, f.name) = try a.dupe(u8, @field(payload, f.name));
            }
            break :blk @unionInit(proto.ContextRef, @tagName(tag), c);
        },
    };
}

/// Structural equality of two refs.
pub fn refEql(x: proto.ContextRef, y: proto.ContextRef) bool {
    var bx: [512]u8 = undefined;
    var by: [512]u8 = undefined;
    const sx = refLabel(&bx, x);
    const sy = refLabel(&by, y);
    return std.mem.eql(u8, sx, sy);
}

/// A compact label, e.g. `file:src/a.zig` or `range:src/a.zig:10-20`.
pub fn refLabel(buf: []u8, ref: proto.ContextRef) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.writeAll(@tagName(ref)) catch return buf[0..0];
    w.writeByte(':') catch {};
    switch (ref) {
        .file, .folder, .symbol, .search, .tag, .url, .scm_diff => |s| w.writeAll(s) catch {},
        .range => |r| w.print("{s}:{d}-{d}", .{ r.path, r.lines[0], r.lines[1] }) catch {},
        .note => |n| w.print("{s}#{d}", .{ n.target, n.depth }) catch {},
        .selection => |s| w.print("{d}:{d}-{d}", .{ s.doc, s.range[0], s.range[1] }) catch {},
        .terminal => |t| w.print("{d}:{?d}", .{ t.terminal, t.block }) catch {},
    }
    return w.buffered();
}

/// Renders an item as the text of a user-message block.
pub fn renderItem(a: Allocator, item: proto.ContextItem) Allocator.Error![]const u8 {
    var buf: [512]u8 = undefined;
    const label = refLabel(&buf, item.ref);
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "<context-item ref=\"{s}\" title=\"{s}\"", .{ label, item.title });
    if (item.truncated) try out.appendSlice(a, " truncated=\"true\"");
    try out.print(a, ">\n{s}\n</context-item>", .{std.mem.trimEnd(u8, item.text, "\n")});
    return out.items;
}

test "pin set dedupes and labels" {
    var p: PinSet = .init(std.testing.allocator);
    defer p.deinit();
    try p.add(.{ .file = "docs/api.md" });
    try p.add(.{ .file = "docs/api.md" });
    try p.add(.{ .range = .{ .path = "a.zig", .lines = .{ 1, 5 } } });
    try std.testing.expectEqual(@as(usize, 2), p.items.items.len);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("range:a.zig:1-5", refLabel(&buf, p.items.items[1].ref));
    try std.testing.expect(p.remove(.{ .file = "docs/api.md" }));
    try std.testing.expectEqual(@as(usize, 1), p.items.items.len);
}
