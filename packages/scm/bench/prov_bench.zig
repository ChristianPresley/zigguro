//! E09.F05.S01.T01 provenance benchmark: recording one agent edit
//! (`Recorder.onEdit`, copying and enqueueing the event; budget 20 µs),
//! with the queue drained every 4096 events as the worker would.

const std = @import("std");
const zg_core = @import("zg_core");
const scm = @import("zg_scm");
const bench = zg_core.bench;
const State = bench.State;

const recorder = scm.prov.recorder;
const bench_dir = ".zig-cache/scm-prov-bench";

pub fn register(b: *bench.Bench) !void {
    if (b.opts.filter) |f| if (std.mem.indexOf(u8, "prov.on_edit", f) == null) return;
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(b.io, bench_dir) catch {};
    defer cwd.deleteTree(b.io, bench_dir) catch {};
    var root = try cwd.createDirPathOpen(b.io, bench_dir, .{});
    defer root.close(b.io);
    const store = try scm.Store.open(b.gpa, b.io, root, .{ .fsync = false });
    defer store.close();
    try b.run("prov.on_edit: record one agent edit (enqueue)", store, onEdit);
}

fn onEdit(store: *scm.Store, s: *State) void {
    const r = recorder.Recorder.init(s.allocator(), s.ioHandle(), store, .{}) catch unreachable;
    defer r.deinit();
    const actor = scm.prov.record.Actor.agent("claude", "anthropic/claude-x", "session-1");
    for (0..s.iterations()) |i| {
        r.onEdit(.{
            .path = "src/parser/expression.zig",
            .workspace = "default",
            .ranges = &.{.{ .old_start_line = @intCast(i % 500), .old_len = 1, .new_len = 2 }},
            .actor = actor,
            .prompt = "Make the parser accept trailing commas in argument lists.",
            .at_ms = 1,
        });
        if (i % 4096 == 4095) r.drain() catch unreachable;
    }
}
