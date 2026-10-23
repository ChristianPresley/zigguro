const std = @import("std");
const run = @import("run.zig");
const journal = @import("journal.zig");
const RunRegistry = @import("registry.zig");

const testing = std.testing;
const io = testing.io;
const RunId = run.RunId;

fn spec(title: []const u8) run.RunSpec {
    return .{ .kind = .background, .title = title, .prompt = "do it", .origin = .cli };
}

fn idAt(n: u128) RunId {
    return .fromInt((@as(u128, 1_700_000_000_000 + n) << 80) | n);
}

test "views are copy-on-write and freed when released" {
    const r = try RunRegistry.init(testing.allocator, io, null, .{});
    defer r.deinit();
    const a = try r.createWithId(idAt(1), spec("a"));
    const b = try r.createWithId(idAt(2), spec("b"));
    const v1 = r.snapshot();
    try r.update(a, .{ .status = .starting });
    try r.update(a, .{ .summary = "hello" });
    const v2 = r.snapshot();
    // The old view still shows the old record; the new one the change.
    try testing.expectEqual(run.RunStatus.queued, v1.get(a).?.status);
    try testing.expectEqualStrings("hello", v2.get(a).?.summary);
    try testing.expectEqual(run.RunStatus.starting, v2.get(a).?.status);
    // Unchanged records are shared.
    try testing.expectEqual(v1.get(b).?, v2.get(b).?);
    // Newest first.
    try testing.expect(v2.runs[0].id.eql(b));
    try testing.expectEqual(@as(usize, 1), v2.byStatus(.starting).len);
    try testing.expectEqual(@as(usize, 1), v2.byStatus(.queued).len);
    try testing.expectEqual(@as(u32, 0), v2.byStatus(.queued)[0]);
    r.release(v1);
    r.release(v2);
    try testing.expectError(error.InvalidTransition, r.update(a, .{ .status = .completed }));
    try testing.expectError(error.UnknownRun, r.update(idAt(9), .{ .summary = "x" }));
    try testing.expectError(error.NotTerminal, r.remove(a, false));
}

const Counter = struct {
    n: std.atomic.Value(u32) = .init(0),
    last: run.EventKind = .created,
    fn on(ctx: *anyopaque, e: run.RunEvent) void {
        const c: *Counter = @ptrCast(@alignCast(ctx));
        _ = c.n.fetchAdd(1, .monotonic);
        c.last = e.kind;
    }
};

test "listeners see every change" {
    const r = try RunRegistry.init(testing.allocator, io, null, .{});
    defer r.deinit();
    var c: Counter = .{};
    const lid = try r.subscribe(.{ .ctx = &c, .on_event = Counter.on });
    const a = try r.create(spec("a"));
    try r.update(a, .{ .status = .starting });
    try r.update(a, .{ .status = .starting }); // no-op
    try testing.expectEqual(@as(u32, 2), c.n.load(.monotonic));
    try testing.expectEqual(run.EventKind.status, c.last);
    r.unsubscribe(lid);
    try r.update(a, .{ .cost = .{ .micros = 1 } });
    try testing.expectEqual(@as(u32, 2), c.n.load(.monotonic));
}

fn hammer(r: *RunRegistry, id: RunId, n: u32) void {
    var buf: [16]u8 = undefined;
    for (0..n) |i| {
        r.update(id, .{ .cost = .{ .micros = i, .input_tokens = i * 2 } }) catch unreachable;
        if (i % 100 == 0) r.update(id, .{ .summary = std.fmt.bufPrint(&buf, "s{d}", .{i}) catch unreachable }) catch unreachable;
    }
}

test "concurrent_updates_consistent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const threads = 8;
    const per = 10_000;
    var ids: [threads]RunId = undefined;
    {
        const r = try RunRegistry.init(testing.allocator, io, tmp.dir, .{});
        defer r.deinit();
        for (&ids, 0..) |*id, i| id.* = try r.createWithId(idAt(i + 1), spec("c"));
        var g: std.Io.Group = .init;
        for (ids) |id| try g.concurrent(io, hammer, .{ r, id, per });
        try g.await(io);
        r.flush();
        try testing.expectEqual(@as(u32, 0), r.write_errors.load(.monotonic));
    }
    // A fresh registry replays the same state from the journals.
    {
        try tmp.dir.deleteFile(io, RunRegistry.index_name);
        const r = try RunRegistry.init(testing.allocator, io, tmp.dir, .{});
        defer r.deinit();
        const rep = try r.load(.{ .host_alive = true });
        try testing.expectEqual(@as(u32, threads), rep.from_journal);
        try testing.expect(rep.index_rebuilt);
        const v = r.snapshot();
        defer r.release(v);
        for (ids) |id| {
            const rec = v.get(id).?;
            try testing.expectEqual(@as(u64, per - 1), rec.cost.micros);
            try testing.expectEqualStrings("s9900", rec.summary);
            try testing.expectEqual(@as(u64, 1 + per + per / 100), rec.revision);
        }
    }
}

test "no journal I/O on the updating thread" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try RunRegistry.init(testing.allocator, io, tmp.dir, .{});
    defer r.deinit();
    try testing.expect(!r.inline_writes);
    const a = try r.create(spec("a"));
    try r.update(a, .{ .status = .starting });
    r.flush();
    const writer = r.io_thread.load(.monotonic);
    try testing.expect(writer != 0);
    try testing.expect(writer != std.Thread.getCurrentId());
}

fn fillTerminal(r: *RunRegistry, n: usize) !void {
    for (0..n) |i| {
        const id = try r.createWithId(idAt(i + 1), spec("t"));
        if (i % 3 == 2) continue; // stays queued
        try r.update(id, .{ .status = .starting });
        try r.update(id, .{ .status = .working });
        try r.update(id, .{ .output = .{ .file = "out.md" } });
        try r.update(id, .{ .status = .completed });
    }
}

test "index_rebuild_when_corrupt" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const r = try RunRegistry.init(testing.allocator, io, tmp.dir, .{});
        defer r.deinit();
        try fillTerminal(r, 9);
    }
    // A good index: terminal runs come from it, as partial records.
    {
        const r = try RunRegistry.init(testing.allocator, io, tmp.dir, .{});
        defer r.deinit();
        const rep = try r.load(.{ .host_alive = true });
        try testing.expect(!rep.index_rebuilt);
        try testing.expectEqual(@as(u32, 6), rep.from_index);
        try testing.expectEqual(@as(u32, 3), rep.from_journal);
        try testing.expect(r.isPartial(idAt(1)));
        try r.loadDetail(idAt(1));
        try testing.expect(!r.isPartial(idAt(1)));
        const v = r.snapshot();
        defer r.release(v);
        try testing.expectEqualStrings("out.md", v.get(idAt(1)).?.outputs[0].file);
    }
    // Flip bytes: the index is rebuilt from the journals.
    {
        const bytes = try tmp.dir.readFileAlloc(io, RunRegistry.index_name, testing.allocator, .unlimited);
        defer testing.allocator.free(bytes);
        bytes[30] ^= 0x5a;
        try tmp.dir.writeFile(io, .{ .sub_path = RunRegistry.index_name, .data = bytes });
        const r = try RunRegistry.init(testing.allocator, io, tmp.dir, .{});
        defer r.deinit();
        const rep = try r.load(.{ .host_alive = true });
        try testing.expect(rep.index_rebuilt);
        try testing.expectEqual(@as(u32, 9), rep.from_journal);
        const v = r.snapshot();
        defer r.release(v);
        try testing.expectEqual(@as(usize, 6), v.byStatus(.completed).len);
        try testing.expectEqual(@as(usize, 3), v.byStatus(.queued).len);
    }
    // Truncated: same.
    {
        const bytes = try tmp.dir.readFileAlloc(io, RunRegistry.index_name, testing.allocator, .unlimited);
        defer testing.allocator.free(bytes);
        try tmp.dir.writeFile(io, .{ .sub_path = RunRegistry.index_name, .data = bytes[0 .. bytes.len / 2] });
        const r = try RunRegistry.init(testing.allocator, io, tmp.dir, .{});
        defer r.deinit();
        const rep = try r.load(.{ .host_alive = true });
        try testing.expect(rep.index_rebuilt);
        try testing.expectEqual(@as(u32, 9), rep.runs);
    }
}

test "crash_marks_interrupted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const id = idAt(5);
    {
        const r = try RunRegistry.init(testing.allocator, io, tmp.dir, .{});
        defer r.deinit();
        _ = try r.createWithId(id, spec("crashy"));
        try r.update(id, .{ .status = .starting });
        try r.update(id, .{ .status = .working });
        try r.update(id, .{ .output = .{ .note = "half done" } });
    }
    // A torn last line, as if the process died mid-append.
    const path = id.text() ++ "/run.jsonl".*;
    {
        const f = try tmp.dir.openFile(io, &path, .{ .mode = .read_write });
        defer f.close(io);
        const len = try f.length(io);
        try f.writePositionalAll(io, "{\"v\":1,\"seq\":6,\"t\":1,\"ty", len);
    }
    try tmp.dir.deleteFile(io, RunRegistry.index_name);
    {
        const r = try RunRegistry.init(testing.allocator, io, tmp.dir, .{});
        defer r.deinit();
        const rep = try r.load(.{});
        try testing.expectEqual(@as(u32, 1), rep.interrupted);
        try testing.expectEqual(@as(u32, 1), rep.truncated);
        r.flush();
        const v = r.snapshot();
        defer r.release(v);
        const rec = v.get(id).?;
        try testing.expectEqual(run.RunStatus.interrupted, rec.status);
        try testing.expectEqualStrings("host exited unexpectedly", rec.error_.?);
        try testing.expectEqualStrings("half done", rec.outputs[0].note);
    }
    // The journal was cut back to whole lines and ends with the recovery.
    const bytes = try tmp.dir.readFileAlloc(io, &path, testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);
    try testing.expect(std.mem.endsWith(u8, bytes, "\"type\":\"end\",\"status\":\"interrupted\"}\n"));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const rp = try journal.replay(arena.allocator(), bytes);
    try testing.expect(!rp.torn);
    // Resume is allowed from interrupted.
    try testing.expect(run.canTransition(.interrupted, .starting));
}

test "a live host keeps its runs" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        const r = try RunRegistry.init(testing.allocator, io, tmp.dir, .{});
        defer r.deinit();
        const id = try r.createWithId(idAt(1), spec("live"));
        try r.update(id, .{ .status = .starting });
    }
    // Another "process" holds the host lock.
    const lock = try tmp.dir.createFile(io, RunRegistry.host_lock_name, .{ .truncate = false, .lock = .exclusive });
    defer lock.close(io);
    const r = try RunRegistry.init(testing.allocator, io, tmp.dir, .{});
    defer r.deinit();
    const rep = try r.load(.{});
    try testing.expectEqual(@as(u32, 0), rep.interrupted);
}

const Protect = struct {
    keep: RunId,
    fn f(ctx: *anyopaque, rec: *const run.RunRecord) bool {
        const p: *Protect = @ptrCast(@alignCast(ctx));
        return rec.id.eql(p.keep);
    }
};

test "retention_never_deletes_active_or_pending" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try RunRegistry.init(testing.allocator, io, tmp.dir, .{});
    defer r.deinit();
    try fillTerminal(r, 9); // ids 1..9; 3, 6, 9 stay queued
    var p: Protect = .{ .keep = idAt(1) };
    const removed = try r.sweep(.{ .max_age_ms = null, .max_count = 2, .now_ms = 0, .protect = .{ .ctx = &p, .f = Protect.f } });
    r.flush();
    const v = r.snapshot();
    defer r.release(v);
    // Kept: the 3 queued, the protected one, and the 2 newest completed.
    try testing.expectEqual(@as(usize, 6), v.runs.len);
    try testing.expectEqual(@as(u32, 3), removed);
    try testing.expect(v.get(idAt(1)) != null);
    try testing.expect(v.get(idAt(8)) != null);
    try testing.expect(v.get(idAt(7)) != null);
    try testing.expect(v.get(idAt(2)) == null);
    // Its directory is gone.
    const name = idAt(2).text();
    try testing.expectError(error.FileNotFound, tmp.dir.openDir(io, &name, .{}));
    // Age-based: everything terminal and old goes, except protected.
    const n = try r.sweep(.{ .max_age_ms = 1, .max_count = null, .now_ms = std.math.maxInt(i64) / 2, .protect = .{ .ctx = &p, .f = Protect.f } });
    try testing.expectEqual(@as(u32, 2), n);
}

test "gitignore is written once" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const r = try RunRegistry.init(testing.allocator, io, tmp.dir, .{});
    r.deinit();
    const bytes = try tmp.dir.readFileAlloc(io, ".gitignore", testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("*\n", bytes);
}
