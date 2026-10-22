//! Tests for the session store, writer and loader (E10.F08.S01.T01).

const std = @import("std");
const proto = @import("zg_ai_proto");
const zg_core = @import("zg_core");
const records = @import("records.zig");
const store_mod = @import("store.zig");
const loader = @import("loader.zig");
const writer = @import("writer.zig");

const testing = std.testing;
const Io = std.Io;
const SessionStore = store_mod.SessionStore;

const Fixture = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    store: SessionStore,

    fn init() !Fixture {
        var f: Fixture = .{ .tmp = testing.tmpDir(.{}), .arena = .init(testing.allocator), .store = undefined };
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try f.tmp.dir.realPath(testing.io, &buf);
        f.store = try .init(testing.allocator, buf[0..n], "/work/repo");
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.store.deinit();
        f.tmp.cleanup();
        f.arena.deinit();
    }

    fn path(f: *Fixture, id: proto.SessionId) ![]const u8 {
        return f.store.pathFor(f.arena.allocator(), id);
    }

    fn read(f: *Fixture, id: proto.SessionId) ![]const u8 {
        return Io.Dir.cwd().readFileAlloc(testing.io, try f.path(id), f.arena.allocator(), .limited(1 << 30));
    }
};

fn text(role: proto.Role, t: []const u8) proto.Message {
    const blocks = testing.allocator.alloc(proto.ContentBlock, 1) catch unreachable;
    blocks[0] = .{ .text = .{ .text = t } };
    return .{ .role = role, .content = blocks };
}

const tool_use_msg: proto.Message = .{ .role = .assistant, .content = &.{
    .{ .text = .{ .text = "running" } },
    .{ .tool_use = .{ .id = "t1", .name = "read_file", .input_json = "{\"path\":\"a\"}" } },
    .{ .tool_use = .{ .id = "t2", .name = "grep", .input_json = "{}" } },
} };

const result_parts = [_]proto.ResultPart{.{ .text = "ok" }};
const tool_results_msg: proto.Message = .{ .role = .user, .content = &.{
    .{ .tool_result = .{ .tool_use_id = "t1", .parts = &result_parts } },
    .{ .tool_result = .{ .tool_use_id = "t2", .parts = &result_parts, .is_error = true } },
} };

/// Replaces `"t":<n>` and `"created":<n>` with 0 so goldens are stable.
fn stableTimes(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        inline for (.{ "\"t\":", "\"created\":" }) |k| {
            if (std.mem.startsWith(u8, s[i..], k)) {
                try out.appendSlice(a, k ++ "0");
                i += k.len;
                while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
                break;
            }
        } else {
            try out.append(a, s[i]);
            i += 1;
        }
    }
    return out.items;
}

test "round trip of every record type (golden)" {
    var f = try Fixture.init();
    defer f.deinit();
    const id: proto.SessionId = 0x0192_0000_0000_0000_0000_0000_0000_0001;
    const w = try f.store.create(testing.io, .{ .id = id, .cwd = "/work/repo", .prompt_version = "p1", .app_version = "0.0.0", .origin = .cli, .model = "claude-x" });
    const u = text(.user, "fix the bug");
    defer testing.allocator.free(u.content);
    try w.append(1, .{ .user = u });
    try w.append(2, .{ .checkpoint = .{ .id = 1, .turn = 1, .label = "fix the bug" } });
    try w.append(3, .{ .assistant = tool_use_msg });
    try w.append(4, .{ .tool_results = tool_results_msg });
    try w.append(5, .{ .usage = .{ .model = "claude-x", .usage = .{ .input = 10, .output = 20, .cache_read = 5 }, .cost_micros = 42 } });
    try w.append(6, .{ .event = .{ .kind = "mode", .data_json = "{\"mode\":\"plan\"}" } });
    try w.append(7, .{ .compaction = .{ .head_seq = 8, .trigger = "auto_threshold", .tokens_before = 1000, .tokens_after = 100, .model = "claude-x" } });
    try w.append(8, .{ .title = "Fix the bug" });
    try w.append(9, .{ .rewind = .{ .to_seq = 1, .action = "conversation" } });
    try w.append(10, .{ .end = .{} });
    w.close();
    const raw = try f.read(id);
    try zg_core.testkit.golden.expectGoldenOpts(testing.io, @src(), "all_records", try stableTimes(f.arena.allocator(), raw), .{ .root = @import("zg_options").package_root, .dir = "testdata/sessions" });

    // The golden fixture itself loads (format compatibility).
    const l = try f.store.open(testing.io, id, .{ .mode = .full });
    defer l.deinit();
    try testing.expectEqual(@as(usize, 10), l.tail.len);
    try testing.expectEqual(records.Origin.cli, l.header.origin);
    try testing.expectEqualStrings("p1", l.header.prompt_version);
    try testing.expectEqual(@as(?proto.Message, null), l.interrupted);
}

test "torn last line is repaired" {
    var f = try Fixture.init();
    defer f.deinit();
    const w = try f.store.create(testing.io, .{ .cwd = "/w" });
    const id = w.id;
    const u = text(.user, "hello");
    defer testing.allocator.free(u.content);
    try w.append(1, .{ .user = u });
    try w.append(2, .{ .title = "t" });
    // A torn write: half a record without its newline.
    try w.file.writePositionalAll(testing.io, "{\"v\":1,\"seq\":3,\"t\":0,\"type\":\"assis", w.end);
    w.end += 34;
    w.close();
    const before = (try f.read(id)).len;
    const l = try f.store.open(testing.io, id, .{});
    defer l.deinit();
    try testing.expectEqual(@as(u64, 34), l.repaired_bytes);
    try testing.expectEqual(@as(usize, 2), l.tail.len);
    try testing.expectEqual(before - 34, (try f.read(id)).len);
    // A complete but unparseable last line is torn too.
    const w2 = try f.store.reopen(testing.io, id, 2);
    try w2.file.writePositionalAll(testing.io, "{\"v\":1,\"seq\":3,garbage}\n", w2.end);
    w2.close();
    const l2 = try f.store.open(testing.io, id, .{});
    defer l2.deinit();
    try testing.expectEqual(@as(usize, 2), l2.tail.len);
    try testing.expect(l2.repaired_bytes > 0);
}

test "dangling tool_use is marked interrupted" {
    var f = try Fixture.init();
    defer f.deinit();
    const w = try f.store.create(testing.io, .{ .cwd = "/w" });
    const id = w.id;
    const u = text(.user, "go");
    defer testing.allocator.free(u.content);
    try w.append(1, .{ .user = u });
    try w.append(2, .{ .assistant = tool_use_msg });
    try w.append(3, .{ .usage = .{ .model = "m", .usage = .{} } });
    w.close();
    const l = try f.store.open(testing.io, id, .{});
    defer l.deinit();
    const m = l.interrupted.?;
    try testing.expect(m.meta.interrupted and m.meta.synthetic);
    try testing.expectEqual(@as(usize, 2), m.content.len);
    try testing.expectEqualStrings("t2", m.content[1].tool_result.tool_use_id);
    try testing.expect(m.content[0].tool_result.is_error);
    // The file is unchanged: history is never rewritten.
    const raw = try f.read(id);
    try testing.expect(std.mem.indexOf(u8, raw, "interrupted") == null);
    const msgs = try l.messages(testing.allocator);
    defer testing.allocator.free(msgs);
    try testing.expectEqual(@as(usize, 3), msgs.len);
}

test "tail-first reads only the tail" {
    var f = try Fixture.init();
    defer f.deinit();
    const w = try f.store.create(testing.io, .{ .cwd = "/w" });
    const id = w.id;
    // ~10 MB: 10k messages of 1 KiB.
    const body = try testing.allocator.alloc(u8, 1000);
    defer testing.allocator.free(body);
    @memset(body, 'x');
    const u = text(.user, body);
    defer testing.allocator.free(u.content);
    const a = text(.assistant, body);
    defer testing.allocator.free(a.content);
    var seq: u64 = 1;
    while (seq <= 10_000) : (seq += 1) try w.append(seq, if (seq % 2 == 0) .{ .assistant = a } else .{ .user = u });
    w.close();
    const size = (try Io.Dir.cwd().statFile(testing.io, try f.path(id), .{})).size;
    try testing.expect(size > 10_000_000);

    const l = try f.store.open(testing.io, id, .{});
    defer l.deinit();
    try testing.expectEqual(@as(usize, 50), l.tail.len);
    try testing.expectEqual(@as(u64, 9951), l.tail[0].seq);
    try testing.expectEqual(@as(u64, 10_000), l.tail[49].seq);
    try testing.expect(l.bytes_read * 20 < size);

    // The rest streams in file order.
    const Sink = struct {
        n: u64 = 0,
        last: u64 = 0,
        ordered: bool = true,
        fn on(ctx: *anyopaque, line: records.Line) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.ordered = s.ordered and line.seq == s.last + 1;
            s.last = line.seq;
            s.n += 1;
        }
    };
    var sink: Sink = .{};
    try l.loadRest(testing.io, .{ .ctx = &sink, .on_line = Sink.on });
    try testing.expectEqual(@as(u64, 9950), sink.n);
    try testing.expect(sink.ordered);
}

test "tail-first stops at the last compaction" {
    var f = try Fixture.init();
    defer f.deinit();
    const w = try f.store.create(testing.io, .{ .cwd = "/w" });
    const id = w.id;
    const u = text(.user, "m");
    defer testing.allocator.free(u.content);
    for (1..20) |i| try w.append(i, .{ .user = u });
    try w.append(20, .{ .compaction = .{ .head_seq = 21, .trigger = "manual" } });
    try w.append(21, .{ .user = u });
    try w.append(22, .{ .title = "x" });
    w.close();
    const l = try f.store.open(testing.io, id, .{});
    defer l.deinit();
    try testing.expectEqual(@as(usize, 3), l.tail.len);
    try testing.expect(l.tail[0].record == .compaction);
}

test "a second writer is locked out" {
    var f = try Fixture.init();
    defer f.deinit();
    const w = try f.store.create(testing.io, .{ .cwd = "/w" });
    defer w.close();
    try testing.expectError(error.SessionLocked, f.store.reopen(testing.io, w.id, 0));
}

fn redactSecret(_: ?*anyopaque, a: std.mem.Allocator, t: []const u8) std.mem.Allocator.Error!writer.Redacted {
    const n = std.mem.count(u8, t, "sk-SECRET");
    if (n == 0) return .{ .text = t, .count = 0 };
    return .{ .text = try std.mem.replaceOwned(u8, a, t, "sk-SECRET", "[REDACTED]"), .count = @intCast(n) };
}

test "redaction is applied to user text and tool output" {
    var f = try Fixture.init();
    defer f.deinit();
    f.store.redactor = .{ .redact = redactSecret };
    const w = try f.store.create(testing.io, .{ .cwd = "/w" });
    const id = w.id;
    const u = text(.user, "key sk-SECRET here");
    defer testing.allocator.free(u.content);
    try w.append(1, .{ .user = u });
    const parts = [_]proto.ResultPart{.{ .text = "env: sk-SECRET" }};
    try w.append(2, .{ .tool_results = .{ .role = .user, .content = &.{.{ .tool_result = .{ .tool_use_id = "t", .parts = &parts } }} } });
    try testing.expectEqual(@as(u64, 2), w.redactions);
    w.close();
    const raw = try f.read(id);
    try testing.expect(std.mem.indexOf(u8, raw, "sk-SECRET") == null);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, raw, "[REDACTED]"));

    // Off: nothing is redacted.
    f.store.redact_secrets = false;
    const w2 = try f.store.create(testing.io, .{ .cwd = "/w" });
    try w2.append(1, .{ .user = u });
    const id2 = w2.id;
    w2.close();
    try testing.expect(std.mem.indexOf(u8, try f.read(id2), "sk-SECRET") != null);
}

test "large blobs move to sidecar files" {
    var f = try Fixture.init();
    defer f.deinit();
    const a = f.arena.allocator();
    const w = try f.store.create(testing.io, .{ .cwd = "/w" });
    const id = w.id;
    const raw_small = try a.alloc(u8, 1000);
    @memset(raw_small, 7);
    const raw_big = try a.alloc(u8, 60_000);
    @memset(raw_big, 9);
    const enc = std.base64.standard.Encoder;
    const small = try a.alloc(u8, enc.calcSize(raw_small.len));
    _ = enc.encode(small, raw_small);
    const big = try a.alloc(u8, enc.calcSize(raw_big.len));
    _ = enc.encode(big, raw_big);
    try testing.expect(big.len >= writer.blob_threshold);
    try w.append(1, .{ .user = .{ .role = .user, .content = &.{
        .{ .image = .{ .media_type = "image/png", .data = .{ .base64 = small } } },
        .{ .image = .{ .media_type = "image/png", .data = .{ .base64 = big } } },
    } } });
    w.close();
    const l = try f.store.open(testing.io, id, .{});
    defer l.deinit();
    const m = l.tail[0].record.user;
    try testing.expect(m.content[0].image.data == .base64);
    const side = m.content[1].image.data.file;
    const back = try Io.Dir.cwd().readFileAlloc(testing.io, side, a, .limited(1 << 20));
    try testing.expectEqualSlices(u8, raw_big, back);
    try testing.expect(std.mem.indexOf(u8, side, ".blobs") != null);
}

test "session loader survives truncations and corruption" {
    var f = try Fixture.init();
    defer f.deinit();
    const w = try f.store.create(testing.io, .{ .cwd = "/w" });
    const id = w.id;
    const u = text(.user, "hello there");
    defer testing.allocator.free(u.content);
    for (1..40) |i| try w.append(i, if (i % 3 == 0) .{ .assistant = tool_use_msg } else .{ .user = u });
    w.close();
    const pristine = try testing.allocator.dupe(u8, try f.read(id));
    defer testing.allocator.free(pristine);
    const header_len = std.mem.indexOfScalar(u8, pristine, '\n').? + 1;
    var prng: std.Random.DefaultPrng = .init(0x5e55);
    const rnd = prng.random();
    for (0..150) |_| {
        const data = try testing.allocator.dupe(u8, pristine);
        defer testing.allocator.free(data);
        var len = data.len;
        switch (rnd.uintLessThan(u8, 3)) {
            0 => len = rnd.intRangeAtMost(usize, header_len, data.len),
            1 => for (0..8) |_| {
                data[rnd.intRangeLessThan(usize, header_len, data.len)] = rnd.int(u8);
            },
            else => {
                len = rnd.intRangeAtMost(usize, header_len, data.len);
                data[rnd.intRangeLessThan(usize, header_len, data.len)] = '\n';
            },
        }
        try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try f.path(id), .data = data[0..len] });
        for ([_]loader.LoadMode{ .tail_first, .full }) |mode| {
            const l = try f.store.open(testing.io, id, .{ .mode = mode });
            defer l.deinit();
            try testing.expect(l.tail.len <= 39);
        }
    }
}

test "fuzz: session_loader" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const n = s.slice(&buf);
            var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena_state.deinit();
            var lines = std.mem.splitScalar(u8, buf[0..n], '\n');
            while (lines.next()) |line| {
                const l = records.decode(arena_state.allocator(), line) catch continue;
                _ = try records.encodeAlloc(arena_state.allocator(), l);
            }
        }
    }.one, .{ .corpus = zg_core.testkit.fuzz.corpus(@import("zg_corpus"), "session_loader") });
}
