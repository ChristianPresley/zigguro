//! Posts the default notifications for a registry's runs (E13.F01.S03.T01):
//! listens for status events and posts `map.fromRunEvent` of the run's
//! current record through a router. Subscribe before `RunRegistry.load`
//! so runs interrupted by a crash are reported (as one group).

const std = @import("std");
const RunRegistry = @import("../runs/registry.zig");
const run = @import("../runs/run.zig");
const map = @import("map.zig");
const Router = @import("router.zig");

const RunNotifier = @This();

reg: *RunRegistry,
router: *Router,
listener: RunRegistry.ListenerId,

pub fn init(reg: *RunRegistry, router: *Router) std.mem.Allocator.Error!*RunNotifier {
    const n = try reg.gpa.create(RunNotifier);
    errdefer reg.gpa.destroy(n);
    n.* = .{ .reg = reg, .router = router, .listener = undefined };
    n.listener = try reg.subscribe(.{ .ctx = n, .on_event = onEvent });
    return n;
}

pub fn deinit(n: *RunNotifier) void {
    n.reg.unsubscribe(n.listener);
    n.reg.gpa.destroy(n);
}

fn onEvent(ctx: *anyopaque, e: run.RunEvent) void {
    const n: *RunNotifier = @ptrCast(@alignCast(ctx));
    if (e.kind != .status) return;
    const v = n.reg.snapshot();
    defer n.reg.release(v);
    const rec = v.get(e.run) orelse return;
    var buf: [2048]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const note = (map.fromRunEvent(fba.allocator(), e, rec) catch return) orelse return;
    n.router.post(note);
}
