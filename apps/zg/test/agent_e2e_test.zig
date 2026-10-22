//! End-to-end test of `zg agent` (E10.F10.S01.T02): spawns the built `zg`,
//! drives a two-turn stream-json session over pipes with provider HTTP
//! replayed from a cassette, then continues the saved session in print
//! mode. No network and no API key.

const std = @import("std");
const fixtures = @import("zg_e2e");

const testing = std.testing;
const io = testing.io;

const Run = struct {
    out: []u8,
    err: []u8,
    code: u8,

    fn deinit(r: Run) void {
        testing.allocator.free(r.out);
        testing.allocator.free(r.err);
    }
};

fn zg(env: *const std.process.Environ.Map, args: []const []const u8, input: []const u8) !Run {
    const gpa = testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, &.{ fixtures.zg, "agent" });
    try argv.appendSlice(gpa, args);
    var child = try std.process.spawn(io, .{ .argv = argv.items, .environ_map = env, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe, .create_no_window = true });
    try child.stdin.?.writeStreamingAll(io, input);
    child.stdin.?.close(io);
    child.stdin = null;
    var obuf: [4096]u8 = undefined;
    var or_ = child.stdout.?.readerStreaming(io, &obuf);
    const out = try or_.interface.allocRemaining(gpa, .limited(1 << 20));
    errdefer gpa.free(out);
    var ebuf: [4096]u8 = undefined;
    var er = child.stderr.?.readerStreaming(io, &ebuf);
    const err = try er.interface.allocRemaining(gpa, .limited(1 << 20));
    const term = try child.wait(io);
    return .{ .out = out, .err = err, .code = switch (term) {
        .exited => |c| c,
        else => 255,
    } };
}

fn field(arena: std.mem.Allocator, line: []const u8, name: []const u8) ![]const u8 {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
    return v.object.get(name).?.string;
}

test "zg agent: two turns over pipes, then continue" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const state = buf[0..try tmp.dir.realPath(io, &buf)];
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("ZIGGURO_STATE_DIR", state);
    try env.put("LOCALAPPDATA", state);
    try env.put("ZG_CASSETTE", fixtures.cassette);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const input =
        \\{"type":"user","message":{"role":"user","content":"hi"}}
        \\{"type":"user","message":{"role":"user","content":[{"type":"text","text":"again"}]}}
        \\
    ;
    const r = try zg(&env, &.{ "--input-format", "stream-json", "--output-format", "stream-json", "--bare" }, input);
    defer r.deinit();
    testing.expectEqual(@as(u8, 0), r.code) catch |e| {
        std.debug.print("stderr:\n{s}\n", .{r.err});
        return e;
    };
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, r.out, "\n"), '\n');
    while (it.next()) |l| try lines.append(a, l);
    try testing.expectEqual(@as(usize, 4), lines.items.len);
    try testing.expectEqualStrings("system", try field(a, lines.items[0], "type"));
    try testing.expectEqualStrings("zg.stream/1", try field(a, lines.items[0], "protocol"));
    try testing.expectEqualStrings("assistant", try field(a, lines.items[1], "type"));
    try testing.expectEqualStrings("assistant", try field(a, lines.items[2], "type"));
    try testing.expectEqualStrings("result", try field(a, lines.items[3], "type"));
    try testing.expectEqualStrings("Second turn, same session.", try field(a, lines.items[3], "result"));
    const session = try field(a, lines.items[0], "session_id");

    // The session was saved; --continue picks it up.
    const c = try zg(&env, &.{ "-c", "-p", "and once more", "--output-format", "json" }, "");
    defer c.deinit();
    testing.expectEqual(@as(u8, 0), c.code) catch |e| {
        std.debug.print("stderr:\n{s}\n", .{c.err});
        return e;
    };
    try testing.expectEqualStrings(session, try field(a, c.out, "session_id"));

    // A bad flag is exit code 2.
    const u = try zg(&env, &.{"--no-such-flag"}, "");
    defer u.deinit();
    try testing.expectEqual(@as(u8, 2), u.code);
    try testing.expect(std.mem.indexOf(u8, u.err, "unknown flag --no-such-flag") != null);
}

fn lineOf(arena: std.mem.Allocator, out: []const u8, ty: []const u8) !?std.json.Value {
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out, "\n"), '\n');
    while (it.next()) |l| {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, l, .{});
        if (std.mem.eql(u8, v.object.get("type").?.string, ty)) return v;
    }
    return null;
}

test "zg agent: run_command approved over the pipe, denied without a prompt channel" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const state = buf[0..try tmp.dir.realPath(io, &buf)];
    var env = try testing.environ.createMap(testing.allocator);
    defer env.deinit();
    try env.put("ZIGGURO_STATE_DIR", state);
    try env.put("LOCALAPPDATA", state);
    try env.put("ZG_CASSETTE", fixtures.approval_cassette);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The answer may arrive before its request.
    const input =
        \\{"type":"user","message":{"role":"user","content":"run it"}}
        \\{"type":"permission_response","request_id":"perm_1","behavior":"allow"}
        \\
    ;
    const r = try zg(&env, &.{ "--input-format", "stream-json", "--output-format", "stream-json", "--permission-prompts", "stream", "--bare" }, input);
    defer r.deinit();
    testing.expectEqual(@as(u8, 0), r.code) catch |e| {
        std.debug.print("stdout:\n{s}\nstderr:\n{s}\n", .{ r.out, r.err });
        return e;
    };
    const init = (try lineOf(a, r.out, "system")).?;
    try testing.expectEqualStrings("run_command", init.object.get("tools").?.array.items[0].string);
    const req = (try lineOf(a, r.out, "permission_request")).?;
    try testing.expectEqualStrings("run_command", req.object.get("tool").?.string);
    try testing.expectEqualStrings("echo approved", req.object.get("input").?.object.get("command").?.string);
    const res = (try lineOf(a, r.out, "user")).?;
    const block = res.object.get("message").?.object.get("content").?.array.items[0];
    try testing.expectEqualStrings("approved\nExit code: 0\n", block.object.get("content").?.array.items[0].object.get("text").?.string);
    try testing.expectEqualStrings("The command ran.", (try lineOf(a, r.out, "result")).?.object.get("result").?.string);

    // Without a prompt channel the call is denied and the exit code is 4.
    const d = try zg(&env, &.{ "-p", "run it", "--output-format", "json", "--no-session-persistence" }, "");
    defer d.deinit();
    try testing.expectEqual(@as(u8, 4), d.code);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, d.out, .{});
    try testing.expectEqualStrings("run_command", v.object.get("permission_denials").?.array.items[0].object.get("tool_name").?.string);
}
