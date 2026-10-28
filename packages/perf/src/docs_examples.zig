//! The code samples of `docs/perf/threading.md`, compiled and tested so the
//! guide never drifts from the APIs it shows. Each `example_*` section is
//! quoted in the guide.

const std = @import("std");
const zg_core = @import("zg_core");
const activity = @import("runtime/activity.zig");

// example_post_result: blocking work on a worker, result posted to the UI.
/// Message kind for `loadFile` results.
pub const msg_file_loaded: u32 = 1;

/// Reads `path` on a worker and posts the byte count to the UI mailbox.
/// The click handler only calls `sub.spawn(loadFile, ...)`; it never reads.
pub fn loadFile(rt: *zg_core.Runtime, path: []const u8) std.Io.Cancelable!void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(rt.io, path, rt.gpa, .limited(64 << 20)) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            rt.post(.{ .kind = msg_file_loaded, .a = 0, .b = 1 }) catch {};
            return;
        },
    };
    defer rt.gpa.free(bytes);
    rt.post(.{ .kind = msg_file_loaded, .a = bytes.len }) catch {};
}
// end example_post_result

// example_chunked: a background loop that yields to the UI and cancels.
/// Counts newlines in `data` in 64 KiB chunks, calling `yieldPoint`
/// between chunks so a busy frame always wins.
pub fn countLines(io: std.Io, data: []const u8) std.Io.Cancelable!usize {
    var lines: usize = 0;
    var i: usize = 0;
    while (i < data.len) {
        const end = @min(data.len, i + 64 * 1024);
        lines += std.mem.count(u8, data[i..end], "\n");
        i = end;
        try activity.yieldPoint(io);
    }
    return lines;
}
// end example_chunked

// example_latest_wins: coalesce requests; a newer one supersedes the old.
/// A latest-wins slot: the UI stores the newest query generation, the
/// worker checks it between steps and drops stale work.
pub const LatestWins = struct {
    generation: std.atomic.Value(u64) = .init(0),

    /// UI thread: a new request supersedes every older one.
    pub fn submit(l: *LatestWins) u64 {
        return l.generation.fetchAdd(1, .acq_rel) + 1;
    }

    /// Worker: true while `gen` is still the newest request.
    pub fn current(l: *const LatestWins, gen: u64) bool {
        return l.generation.load(.acquire) == gen;
    }
};
// end example_latest_wins

// example_subsystem: one Io.Group per subsystem, canceled in deinit.
/// A subsystem owning its background work.
pub const Indexer = struct {
    sub: zg_core.runtime.Subsystem,
    done: std.atomic.Value(u32) = .init(0),

    /// Starts the indexer's tasks on `io`.
    pub fn init(io: std.Io) Indexer {
        return .{ .sub = .init(io) };
    }

    /// Spawns one short job (may run inline).
    pub fn index(ix: *Indexer, data: []const u8) void {
        ix.sub.spawn(job, .{ ix, data });
    }

    fn job(ix: *Indexer, data: []const u8) std.Io.Cancelable!void {
        _ = try countLines(ix.sub.io, data);
        _ = ix.done.fetchAdd(1, .monotonic);
    }

    /// Cancels and joins every task.
    pub fn deinit(ix: *Indexer) void {
        ix.sub.shutdown();
    }
};
// end example_subsystem

test "docs examples compile and run" {
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    try loadFile(&rt, "build.zig.zon");
    var msgs: [4]zg_core.runtime.UiMsg = undefined;
    const n = rt.drain(&msgs);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(msg_file_loaded, msgs[0].kind);

    try std.testing.expectEqual(@as(usize, 3), try countLines(std.testing.io, "a\nb\nc\n"));

    var lw: LatestWins = .{};
    const g1 = lw.submit();
    const g2 = lw.submit();
    try std.testing.expect(!lw.current(g1) and lw.current(g2));

    var ix = Indexer.init(std.testing.io);
    ix.index("x\ny\n");
    try ix.sub.join();
    ix.deinit();
    try std.testing.expectEqual(@as(u32, 1), ix.done.load(.monotonic));
}
