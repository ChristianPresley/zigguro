//! The headless notification backend (E13.F01.S03.T01) for `zg agents
//! host` and the CLI: forwards to an attached GUI when there is one
//! (`Forward`), else writes one line per notification to a writer
//! (stderr). Ids count up; a replacement prints again with "(updated)".

const std = @import("std");
const n_mod = @import("notification.zig");

const Allocator = std.mem.Allocator;
const Notification = n_mod.Notification;

/// Hands a notification to an attached GUI client; false when none took
/// it.
pub const Forward = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, n: *const Notification) bool,
};

pub const Headless = struct {
    gpa: Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    forward: ?Forward,
    mutex: std.Io.Mutex = .init,
    next_id: u64 = 1,

    pub fn backend(h: *Headless) n_mod.OsBackend {
        return .{ .ctx = h, .vtable = &vtable };
    }

    const vtable: n_mod.OsBackend.VTable = .{ .show = show, .close = close, .deinit = deinitFn };

    fn show(ctx: *anyopaque, n: *const Notification, replaces: ?u64) anyerror!u64 {
        const h: *Headless = @ptrCast(@alignCast(ctx));
        h.mutex.lockUncancelable(h.io);
        defer h.mutex.unlock(h.io);
        const id = replaces orelse blk: {
            const i = h.next_id;
            h.next_id += 1;
            break :blk i;
        };
        if (h.forward) |f| if (f.f(f.ctx, n)) return id;
        try h.out.print("zigguro: [{s}] {s}{s}", .{ label(n.severity), n.title, if (replaces != null) " (updated)" else "" });
        if (n.body.len > 0) try h.out.print(": {s}", .{n.body});
        if (n.run) |r| try h.out.print(" (run {f})", .{r});
        try h.out.writeByte('\n');
        try h.out.flush();
        return id;
    }

    fn close(_: *anyopaque, _: u64) void {}

    fn deinitFn(ctx: *anyopaque) void {
        const h: *Headless = @ptrCast(@alignCast(ctx));
        h.gpa.destroy(h);
    }
};

/// A headless backend writing to `out` (which must outlive it). Freed by
/// the backend's `deinit` (the router calls it).
pub fn headlessBackend(gpa: Allocator, io: std.Io, out: *std.Io.Writer, forward: ?Forward) Allocator.Error!n_mod.OsBackend {
    const h = try gpa.create(Headless);
    h.* = .{ .gpa = gpa, .io = io, .out = out, .forward = forward };
    return h.backend();
}

fn label(s: n_mod.Severity) []const u8 {
    return switch (s) {
        .info => "info",
        .success => "done",
        .warning => "warning",
        .error_ => "error",
        .needs_input => "needs input",
    };
}

const testing = std.testing;

test "headless backend writes lines and forwards when a GUI is attached" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const b = try headlessBackend(testing.allocator, testing.io, &aw.writer, null);
    defer b.deinit();
    const n: Notification = .{ .key = "k", .severity = .needs_input, .title = "Fix build needs input", .body = "Allow rm?" };
    const id = try b.show(&n, null);
    _ = try b.show(&n, id);
    try testing.expectEqualStrings(
        "zigguro: [needs input] Fix build needs input: Allow rm?\n" ++
            "zigguro: [needs input] Fix build needs input (updated): Allow rm?\n",
        aw.written(),
    );
    const Gui = struct {
        got: u32 = 0,
        fn take(ctx: *anyopaque, _: *const Notification) bool {
            const g: *@This() = @ptrCast(@alignCast(ctx));
            g.got += 1;
            return true;
        }
    };
    var gui: Gui = .{};
    const h: *Headless = @ptrCast(@alignCast(b.ctx));
    h.forward = .{ .ctx = &gui, .f = Gui.take };
    aw.clearRetainingCapacity();
    _ = try b.show(&n, null);
    try testing.expectEqual(@as(u32, 1), gui.got);
    try testing.expectEqualStrings("", aw.written());
}
