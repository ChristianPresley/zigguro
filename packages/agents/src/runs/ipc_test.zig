const std = @import("std");
const zg_core = @import("zg_core");
const run = @import("run.zig");
const port = @import("port.zig");
const protocol = @import("protocol.zig");
const ipc = @import("ipc.zig");
const handoff = @import("handoff.zig");
const RunRegistry = @import("registry.zig");
const RunHost = @import("host.zig");
const Fake = @import("fake_agents.zig").Fake;

const testing = std.testing;
const io = testing.io;
const gpa = testing.allocator;
const RunId = run.RunId;

/// A headless host on a temp workspace.
const Side = struct {
    reg: *RunRegistry,
    host: *RunHost,
    fake: Fake = .{},

    fn init(s: *Side, dir: std.Io.Dir) !void {
        s.reg = try RunRegistry.init(gpa, io, dir, .{});
        s.host = try RunHost.init(gpa, io, s.reg, s.fake.agentPort(), null, .builtin, .{});
    }

    fn deinit(s: *Side) void {
        s.host.deinit();
        s.reg.deinit();
        s.fake.deinit();
    }

    fn status(s: *Side, id: RunId) ?run.RunStatus {
        const v = s.reg.snapshot();
        defer s.reg.release(v);
        return if (v.get(id)) |r| r.status else null;
    }

    fn waitStatus(s: *Side, id: RunId, want: run.RunStatus) !void {
        for (0..3000) |_| {
            if (s.status(id) == want) return;
            io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        return error.Timeout;
    }
};

const Events = struct {
    mutex: std.Io.Mutex = .init,
    got: std.ArrayList(protocol.EventNote) = .empty,

    fn sink(e: *Events) ipc.EventSink {
        return .{ .ctx = e, .f = on };
    }
    fn on(ctx: *anyopaque, n: protocol.EventNote) void {
        const e: *Events = @ptrCast(@alignCast(ctx));
        e.mutex.lockUncancelable(io);
        defer e.mutex.unlock(io);
        e.got.append(gpa, n) catch {};
    }
    fn count(e: *Events) usize {
        e.mutex.lockUncancelable(io);
        defer e.mutex.unlock(io);
        return e.got.items.len;
    }
    fn waitCount(e: *Events, n: usize) !void {
        for (0..3000) |_| {
            if (e.count() >= n) return;
            io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        return error.Timeout;
    }
};

fn absPath(dir: std.Io.Dir) ![:0]u8 {
    return dir.realPathFileAlloc(io, ".", gpa);
}

test "ipc_roundtrip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    const abs = try absPath(tmp.dir);
    defer gpa.free(abs);

    var side: Side = .{ .reg = undefined, .host = undefined };
    try side.init(tmp.dir);
    defer side.deinit();
    side.fake.auto_complete = true;
    const lock = (try ipc.HostLock.acquire(io, tmp.dir)).?;
    defer lock.release(io);
    const server = try ipc.HostServer.listen(&rt, side.host, side.reg, tmp.dir, abs, .{});
    defer server.deinit();

    const client = (try ipc.HostClient.connect(&rt, tmp.dir)).?;
    defer client.deinit();
    var events: Events = .{};
    defer events.got.deinit(gpa);
    _ = try client.subscribe(0, events.sink());

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const started = try client.call(protocol.methods.start, protocol.StartParams{ .spec = .{ .kind = .background, .title = "remote", .prompt = "go" } }, protocol.IdParams, a);
    try side.waitStatus(started.id, .completed);
    // created, status starting, started, session, working, summary, ended, completed...
    try events.waitCount(8);
    {
        events.mutex.lockUncancelable(io);
        defer events.mutex.unlock(io);
        try testing.expectEqual(run.EventKind.created, events.got.items[0].kind);
        for (events.got.items, 1..) |e, i| {
            try testing.expectEqual(@as(u64, i), e.seq);
            try testing.expect(e.id.eql(started.id));
        }
    }
    const rows = try client.call(protocol.methods.list, .{}, []protocol.RunSummary, a);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("remote", rows[0].title);
    try testing.expectEqual(run.RunStatus.completed, rows[0].status);
    const rec = try client.call(protocol.methods.show, protocol.IdParams{ .id = started.id }, std.json.Value, a);
    try testing.expectEqualStrings("go", rec.object.get("spec").?.object.get("prompt").?.string);
    // `zg runs attach` and `outputs` read the record typed.
    const typed = try client.call(protocol.methods.show, protocol.IdParams{ .id = started.id }, run.RunRecord, a);
    try testing.expectEqual(run.RunStatus.completed, typed.status);
    try testing.expect(typed.id.eql(started.id));
    try testing.expectError(error.RemoteError, client.call(protocol.methods.reply, protocol.ReplyParams{ .id = started.id, .text = "x" }, protocol.Ok, a));
    _ = try client.call(protocol.methods.rename, protocol.RenameParams{ .id = started.id, .title = "renamed" }, protocol.Ok, a);
    _ = try client.call(protocol.methods.pin, protocol.PinParams{ .id = started.id }, protocol.Ok, a);
    {
        const v = side.reg.snapshot();
        defer side.reg.release(v);
        try testing.expectEqualStrings("renamed", v.get(started.id).?.spec.title);
        try testing.expect(v.get(started.id).?.pinned);
    }
    // Stop a queued-then-running run.
    side.fake.auto_complete = false;
    const s2 = try client.call(protocol.methods.start, protocol.StartParams{ .spec = .{ .kind = .background, .title = "two", .prompt = "go" } }, protocol.IdParams, a);
    try side.waitStatus(s2.id, .working);
    _ = try client.call(protocol.methods.stop, protocol.StopParams{ .id = s2.id, .how = .now }, protocol.Ok, a);
    try side.waitStatus(s2.id, .stopped);
    _ = try client.call(protocol.methods.remove, protocol.RemoveParams{ .id = s2.id }, protocol.Ok, a);
    const left = try client.call(protocol.methods.list, .{}, []protocol.RunSummary, a);
    try testing.expectEqual(@as(usize, 1), left.len);
}

test "ipc_rejects_bad_token" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    const abs = try absPath(tmp.dir);
    defer gpa.free(abs);
    var side: Side = .{ .reg = undefined, .host = undefined };
    try side.init(tmp.dir);
    defer side.deinit();
    const server = try ipc.HostServer.listen(&rt, side.host, side.reg, tmp.dir, abs, .{});
    defer server.deinit();
    const bad: ipc.Token = @splat(7);
    try testing.expect(!std.mem.eql(u8, &bad, &server.token));
    try testing.expectError(error.Unauthorized, ipc.HostClient.connectPath(&rt, server.sock_path, bad));
    // The right token works, and the token file is owner-only.
    const c = try ipc.HostClient.connectPath(&rt, server.sock_path, ipc.readToken(io, tmp.dir).?);
    c.deinit();
    if (@import("builtin").os.tag != .windows) {
        const st = try tmp.dir.statFile(io, ipc.token_name, .{});
        try testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
    }
}

test "second_host_exits_code_3" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = (try ipc.HostLock.acquire(io, tmp.dir)).?;
    try testing.expect(try ipc.HostLock.acquire(io, tmp.dir) == null);
    try testing.expect(ipc.hostAlive(io, tmp.dir));
    try testing.expectEqual(ipc.currentPid(), ipc.HostLock.holderPid(io, tmp.dir).?);
    first.release(io);
    try testing.expect(!ipc.hostAlive(io, tmp.dir));
    const again = (try ipc.HostLock.acquire(io, tmp.dir)).?;
    again.release(io);
}

test "long_workspace_path_uses_runtime_dir" {
    const short = try ipc.socketPath(gpa, "/w/.zigguro/runs", "/run/user/1000");
    defer gpa.free(short);
    try testing.expectEqualStrings("/w/.zigguro/runs/host.sock", short);
    const long_root = "/" ++ "d" ** 120 ++ "/.zigguro/runs";
    const p = try ipc.socketPath(gpa, long_root, "/run/user/1000");
    defer gpa.free(p);
    const key = ipc.workspaceKey(long_root);
    try testing.expectEqualStrings("/run/user/1000/zigguro/" ++ key ++ ".sock", p);
}

test "subscribe_since_revision_replays_gap" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    const abs = try absPath(tmp.dir);
    defer gpa.free(abs);
    var side: Side = .{ .reg = undefined, .host = undefined };
    try side.init(tmp.dir);
    defer side.deinit();
    const server = try ipc.HostServer.listen(&rt, side.host, side.reg, tmp.dir, abs, .{});
    defer server.deinit();
    const token = ipc.readToken(io, tmp.dir).?;

    const id = try side.reg.create(.{ .kind = .background, .title = "gap", .prompt = "p" });
    var first: Events = .{};
    defer first.got.deinit(gpa);
    var last: u64 = 0;
    {
        const c = try ipc.HostClient.connectPath(&rt, server.sock_path, token);
        defer c.deinit();
        _ = try c.subscribe(0, first.sink());
        try first.waitCount(1); // the replayed `created`
        try side.reg.update(id, .{ .summary = "a" });
        try first.waitCount(2);
        last = c.last_seq.load(.acquire);
    }
    for (0..50) |i| try side.reg.update(id, .{ .cost = .{ .micros = i } });
    var second: Events = .{};
    defer second.got.deinit(gpa);
    const c = try ipc.HostClient.connectPath(&rt, server.sock_path, token);
    defer c.deinit();
    const seq = try c.subscribe(last, second.sink());
    try testing.expectEqual(last + 50, seq);
    try second.waitCount(50);
    io.sleep(.fromMilliseconds(10), .awake) catch {};
    try testing.expectEqual(@as(usize, 50), second.count());
    try testing.expectEqual(last + 1, second.got.items[0].seq);
    try testing.expectEqual(run.EventKind.cost, second.got.items[49].kind);
}

fn boundaryLater(f: *Fake) void {
    io.sleep(.fromMilliseconds(20), .awake) catch return;
    f.agent(0).sink.send(.tool_boundary);
}

test "handoff_transfers_without_duplicate_tool_calls" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    const abs = try absPath(tmp.dir);
    defer gpa.free(abs);

    // The GUI side, with one run mid-turn.
    var gui: Side = .{ .reg = undefined, .host = undefined };
    try gui.init(tmp.dir);
    const id = try gui.host.start(.{ .kind = .background, .title = "long job", .prompt = "do three steps" });
    try gui.waitStatus(id, .working);
    gui.fake.agent(0).sink.send(.tool_boundary); // step 1 done

    // The headless host.
    var headless: Side = .{ .reg = undefined, .host = undefined };
    try headless.init(tmp.dir);
    defer headless.deinit();
    headless.fake.auto_complete = true;
    const lock = (try ipc.HostLock.acquire(io, tmp.dir)).?;
    defer lock.release(io);
    const server = try ipc.HostServer.listen(&rt, headless.host, headless.reg, tmp.dir, abs, .{});
    defer server.deinit();

    const client = (try ipc.HostClient.connect(&rt, tmp.dir)).?;
    defer client.deinit();
    var g: std.Io.Group = .init;
    try g.concurrent(io, boundaryLater, .{&gui.fake}); // step 2 finishes during the handoff
    const res = try handoff.handoff(gpa, io, gui.host, gui.reg, client, .{});
    try g.await(io);
    try testing.expectEqual(@as(u32, 1), res.transferred);
    try testing.expectEqual(@as(u32, 0), res.left_running);
    const session = gui.fake.agent(0).session;
    try testing.expect(gui.fake.agent(0).disposed);
    gui.deinit();

    try headless.waitStatus(id, .completed);
    const ag = headless.fake.agent(0);
    try testing.expectEqual(@as(?u128, session), ag.resumed);
    try testing.expectEqual(@as(usize, 1), ag.submits.items.len);
    try testing.expectEqualStrings(RunHost.continue_text, ag.submits.items[0]);
    // The journal tells the whole story once: paused, then resumed.
    headless.reg.flush();
    const path = id.text() ++ "/run.jsonl".*;
    const bytes = try tmp.dir.readFileAlloc(io, &path, gpa, .unlimited);
    defer gpa.free(bytes);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\"status\":\"paused\""));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, bytes, "\"status\":\"completed\""));
}
