//! Tests for the session index, search, retention, titles and export
//! (E10.F08.S01.T02).

const std = @import("std");
const builtin = @import("builtin");
const proto = @import("zg_ai_proto");
const zg_core = @import("zg_core");
const records = @import("records.zig");
const store_mod = @import("store.zig");
const index = @import("index.zig");
const search = @import("search.zig");
const retention = @import("retention.zig");
const title = @import("title.zig");
const exp = @import("export.zig");
const sp = @import("../provider/scripted.zig");

const testing = std.testing;
const Io = std.Io;
const SessionIndex = index.SessionIndex;

const Fixture = struct {
    tmp: testing.TmpDir,
    arena: std.heap.ArenaAllocator,
    store: store_mod.SessionStore,
    dir: Io.Dir,

    fn init() !Fixture {
        var f: Fixture = .{ .tmp = testing.tmpDir(.{}), .arena = .init(testing.allocator), .store = undefined, .dir = undefined };
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try f.tmp.dir.realPath(testing.io, &buf);
        f.store = try .init(testing.allocator, buf[0..n], "/work/repo");
        try Io.Dir.cwd().createDirPath(testing.io, f.store.dir);
        f.dir = try Io.Dir.cwd().openDir(testing.io, f.store.dir, .{ .iterate = true });
        return f;
    }

    fn deinit(f: *Fixture) void {
        f.dir.close(testing.io);
        f.store.deinit();
        f.tmp.cleanup();
        f.arena.deinit();
    }

    fn msg(f: *Fixture, role: proto.Role, t: []const u8) proto.Message {
        const a = f.arena.allocator();
        const b = a.alloc(proto.ContentBlock, 1) catch unreachable;
        b[0] = .{ .text = .{ .text = t } };
        return .{ .role = role, .content = b };
    }

    /// A session with alternating user/assistant `texts` and an optional title.
    fn session(f: *Fixture, id: proto.SessionId, new: store_mod.NewSession, texts: []const []const u8, ttl: ?[]const u8) !void {
        var m = new;
        m.id = id;
        const w = try f.store.create(testing.io, m);
        defer w.close();
        var seq: u64 = 1;
        for (texts, 0..) |t, i| {
            try w.append(seq, records.Record.fromMessage(f.msg(if (i % 2 == 0) .user else .assistant, t)));
            seq += 1;
        }
        if (ttl) |t| try w.append(seq, .{ .title = t });
    }

    fn files(f: *Fixture) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var it = f.dir.iterate();
        while (try it.next(testing.io)) |e| try out.append(f.arena.allocator(), try f.arena.allocator().dupe(u8, e.name));
        std.mem.sort([]const u8, out.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        return out.items;
    }
};

fn meta(id: proto.SessionId, updated: i64) index.SessionMeta {
    return .{ .id = id, .created_ms = updated - 10, .updated_ms = updated };
}

test "rebuild index from headers" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.session(1, .{ .cwd = "/w", .origin = .cli, .model = "m1" }, &.{ "fix the auth bug", "done" }, "Fix auth");
    try f.session(2, .{ .cwd = "/w", .parent = .{ .session = 1, .seq = 2 } }, &.{"more"}, null);
    var ix = try SessionIndex.load(testing.allocator, testing.io, f.dir);
    defer ix.deinit();
    try testing.expect(ix.rebuilt);
    try testing.expectEqual(@as(usize, 2), ix.count());
    const a = ix.get(1).?;
    try testing.expectEqualStrings("Fix auth", a.title.?);
    try testing.expectEqual(records.Origin.cli, a.origin);
    try testing.expectEqualStrings("m1", a.model);
    try testing.expect(a.updated_ms >= a.created_ms);
    try testing.expect(a.bytes > 0);
    try testing.expectEqual(@as(?proto.SessionId, 1), ix.get(2).?.parent);

    // A long session: the title is found in the last 4 KiB only.
    var long: [200][]const u8 = undefined;
    for (&long) |*t| t.* = "padding padding padding padding padding padding padding";
    try f.session(3, .{ .cwd = "/w" }, &long, "Late title");
    try ix.rebuild();
    try testing.expectEqualStrings("Late title", ix.get(3).?.title.?);

    // Garbage files are skipped.
    try f.dir.writeFile(testing.io, .{ .sub_path = "junk.jsonl", .data = "not json\n" });
    try ix.rebuild();
    try testing.expectEqual(@as(usize, 3), ix.count());
}

test "atomic index write" {
    var f = try Fixture.init();
    defer f.deinit();
    {
        var ix = try SessionIndex.load(testing.allocator, testing.io, f.dir);
        defer ix.deinit();
        try ix.upsert(.{ .id = 7, .title = "Seven \"quoted\"", .name = "my name", .created_ms = 1, .updated_ms = 2, .branch = "main", .model = "m", .messages = 3, .cost_micros = 4, .parent = 6, .pinned = true, .origin = .schedule, .bytes = 5 });
        try testing.expect(try ix.flush());
        // Debounced: a second change within a second is not written yet.
        try ix.upsert(meta(8, 3));
        try testing.expect(!try ix.flush());
        try testing.expectEqual(@as(u32, 1), ix.saves);
        try ix.save();
    }
    // Only the index (no temp file) is left in the directory.
    const names = try f.files();
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings(index.file_name, names[0]);

    var ix = try SessionIndex.load(testing.allocator, testing.io, f.dir);
    defer ix.deinit();
    try testing.expect(!ix.rebuilt);
    const m = ix.get(7).?;
    try testing.expectEqualStrings("Seven \"quoted\"", m.title.?);
    try testing.expectEqualStrings("my name", m.name.?);
    try testing.expectEqualStrings("main", m.branch.?);
    try testing.expectEqual(@as(?proto.SessionId, 6), m.parent);
    try testing.expect(m.pinned);
    try testing.expectEqual(records.Origin.schedule, m.origin);
    try testing.expectEqual(@as(u64, 5), m.bytes);
    try testing.expect(ix.get(8) != null);

    // A corrupt index is rebuilt from the (here: no) session files.
    try f.dir.writeFile(testing.io, .{ .sub_path = index.file_name, .data = ".{ .version = 1, .sessions = .{ .{ .id = " });
    var bad = try SessionIndex.load(testing.allocator, testing.io, f.dir);
    defer bad.deinit();
    try testing.expect(bad.rebuilt);
    try testing.expectEqual(@as(usize, 0), bad.count());
}

test "list filter sort" {
    var f = try Fixture.init();
    defer f.deinit();
    var ix = try SessionIndex.load(testing.allocator, testing.io, f.dir);
    defer ix.deinit();
    try ix.upsert(.{ .id = 1, .title = "Fix the Auth bug", .created_ms = 0, .updated_ms = 100, .branch = "main", .origin = .gui });
    try ix.upsert(.{ .id = 2, .title = "Write docs", .created_ms = 0, .updated_ms = 300, .branch = "docs", .origin = .cli, .pinned = true });
    try ix.upsert(.{ .id = 3, .name = "auth follow-up", .created_ms = 0, .updated_ms = 200, .branch = "main", .origin = .subagent });
    var out: std.ArrayList(*const index.SessionMeta) = .empty;
    defer out.deinit(testing.allocator);

    try ix.list(testing.allocator, .{}, &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqual(@as(proto.SessionId, 2), out.items[0].id);
    try testing.expectEqual(@as(proto.SessionId, 3), out.items[1].id);
    try testing.expectEqual(@as(proto.SessionId, 1), out.items[2].id);

    const cases = [_]struct { f: index.Filter, want: []const proto.SessionId }{
        .{ .f = .{ .branch = "main" }, .want = &.{ 3, 1 } },
        .{ .f = .{ .origin = .cli }, .want = &.{2} },
        .{ .f = .{ .text = "AUTH" }, .want = &.{ 3, 1 } },
        .{ .f = .{ .pinned = true }, .want = &.{2} },
        .{ .f = .{ .since_ms = 150, .until_ms = 300 }, .want = &.{3} },
        .{ .f = .{ .branch = "main", .text = "fix" }, .want = &.{1} },
    };
    for (cases) |c| {
        out.clearRetainingCapacity();
        try ix.list(testing.allocator, c.f, &out);
        try testing.expectEqual(c.want.len, out.items.len);
        for (c.want, out.items) |w, m| try testing.expectEqual(w, m.id);
    }

    // Updates replace the entry; removal drops it.
    try ix.upsert(.{ .id = 1, .title = "Renamed", .created_ms = 0, .updated_ms = 400 });
    try testing.expect(ix.remove(2));
    out.clearRetainingCapacity();
    try ix.list(testing.allocator, .{}, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("Renamed", out.items[0].title.?);
}

test "list over 5k sessions" {
    var f = try Fixture.init();
    defer f.deinit();
    var ix = try SessionIndex.load(testing.allocator, testing.io, f.dir);
    defer ix.deinit();
    var prng: std.Random.DefaultPrng = .init(5);
    for (0..5000) |i| try ix.upsert(.{ .id = i + 1, .title = "A session title of usual length", .created_ms = 0, .updated_ms = prng.random().int(u32), .branch = if (i % 3 == 0) "main" else "dev" });
    var out: std.ArrayList(*const index.SessionMeta) = .empty;
    defer out.deinit(testing.allocator);
    try out.ensureTotalCapacity(testing.allocator, 5000);
    const sw = zg_core.time.Stopwatch.start(testing.io);
    try ix.list(testing.allocator, .{ .text = "usual" }, &out);
    const ns = sw.readNs(testing.io);
    try testing.expectEqual(@as(usize, 5000), out.items.len);
    for (out.items[1..], out.items[0 .. out.items.len - 1]) |b, a| try testing.expect(a.updated_ms >= b.updated_ms);
    // Budget: < 10 ms in release builds (debug builds are much slower).
    if (builtin.mode != .Debug) try testing.expect(ns < 10 * std.time.ns_per_ms);
}

const Collect = struct {
    gpa: std.mem.Allocator,
    hits: std.ArrayList(struct { session: proto.SessionId, seq: u64, snippet: []const u8, match: []const u8 }) = .empty,
    cancel_after: ?usize = null,
    cancel: *std.atomic.Value(bool),

    fn sink(c: *Collect) search.SearchSink {
        return .{ .ctx = c, .on_hit = onHit };
    }

    fn onHit(ctx: *anyopaque, h: search.Hit) bool {
        const c: *Collect = @ptrCast(@alignCast(ctx));
        const s = c.gpa.dupe(u8, h.snippet) catch return false;
        c.hits.append(c.gpa, .{ .session = h.session, .seq = h.seq, .snippet = s, .match = s[h.match_start..h.match_end] }) catch return false;
        if (c.cancel_after) |n| if (c.hits.items.len >= n) c.cancel.store(true, .release);
        return true;
    }
};

test "search literal and regex, streaming and cancel" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.session(1, .{ .cwd = "/w" }, &.{ "the auth token expires", "I will refresh it", "say \"hello\"\nthen stop" }, "Auth refresh");
    try f.session(2, .{ .cwd = "/w" }, &.{ "refactor the parser", "Refreshing the AUTH cache" }, null);
    var ix = try SessionIndex.load(testing.allocator, testing.io, f.dir);
    defer ix.deinit();
    // Session 2 is the newest.
    try ix.upsert(.{ .id = 1, .created_ms = 0, .updated_ms = 10 });
    try ix.upsert(.{ .id = 2, .created_ms = 0, .updated_ms = 20 });

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var cancel: std.atomic.Value(bool) = .init(false);

    // Literal, case-insensitive, newest session first.
    var c: Collect = .{ .gpa = arena.allocator(), .cancel = &cancel };
    var r = try search.search(&ix, testing.io, .{ .text = "auth" }, c.sink(), &cancel);
    try testing.expectEqual(@as(u32, 3), r.hits);
    try testing.expectEqual(@as(proto.SessionId, 2), c.hits.items[0].session);
    try testing.expectEqualStrings("AUTH", c.hits.items[0].match);
    try testing.expectEqual(@as(u64, 1), c.hits.items[1].seq);
    // The title record is searchable.
    try testing.expectEqualStrings("Auth", c.hits.items[2].match);

    // Quotes and newlines match the decoded text, not the JSON escapes.
    c = .{ .gpa = arena.allocator(), .cancel = &cancel };
    r = try search.search(&ix, testing.io, .{ .text = "\"hello\"\nthen" }, c.sink(), &cancel);
    try testing.expectEqual(@as(u32, 1), r.hits);
    try testing.expectEqualStrings("\"hello\" then", c.hits.items[0].match);

    // JSON keys never match.
    c = .{ .gpa = arena.allocator(), .cancel = &cancel };
    r = try search.search(&ix, testing.io, .{ .text = "role" }, c.sink(), &cancel);
    try testing.expectEqual(@as(u32, 0), r.hits);

    // Regex.
    c = .{ .gpa = arena.allocator(), .cancel = &cancel };
    r = try search.search(&ix, testing.io, .{ .text = "ref(resh|actor)\\w*", .regex = true, .case_insensitive = false }, c.sink(), &cancel);
    try testing.expectEqual(@as(u32, 3), r.hits);
    try testing.expectEqualStrings("refactor", c.hits.items[0].match);
    try testing.expectEqualStrings("refresh", c.hits.items[1].match);
    try testing.expectEqualStrings("refresh", c.hits.items[2].match);
    try testing.expectError(error.InvalidPattern, search.search(&ix, testing.io, .{ .text = "(", .regex = true }, c.sink(), &cancel));

    // Cancel after the first hit.
    c = .{ .gpa = arena.allocator(), .cancel = &cancel, .cancel_after = 1 };
    r = try search.search(&ix, testing.io, .{ .text = "auth" }, c.sink(), &cancel);
    try testing.expect(r.canceled);
    try testing.expectEqual(@as(usize, 1), c.hits.items.len);

    // max_hits and filters.
    cancel.store(false, .release);
    c = .{ .gpa = arena.allocator(), .cancel = &cancel };
    r = try search.search(&ix, testing.io, .{ .text = "auth", .max_hits = 2 }, c.sink(), &cancel);
    try testing.expectEqual(@as(u32, 2), r.hits);
    c = .{ .gpa = arena.allocator(), .cancel = &cancel };
    r = try search.search(&ix, testing.io, .{ .text = "auth", .filter = .{ .until_ms = 15 } }, c.sink(), &cancel);
    try testing.expectEqual(@as(u32, 1), r.sessions_searched);
}

test "retention respects pins and branch parents" {
    var f = try Fixture.init();
    defer f.deinit();
    const day = std.time.ms_per_day;
    const now: i64 = 1000 * day;
    // 1: old; 2: old, pinned; 3: old parent of 4 (recent); 5: old parent of
    // 6 (old) -> both go; 7: recent.
    for ([_]proto.SessionId{ 1, 2, 3, 4, 5, 6, 7 }) |id| try f.session(id, .{ .cwd = "/w" }, &.{"x"}, null);
    try f.dir.createDirPath(testing.io, &(proto.agent_ref.format(1) ++ ".blobs".*));
    try f.dir.writeFile(testing.io, .{ .sub_path = &(proto.agent_ref.format(1) ++ ".blobs/abc".*), .data = "blob" });
    var ix = try SessionIndex.load(testing.allocator, testing.io, f.dir);
    defer ix.deinit();
    const old = now - 40 * day;
    const recent = now - day;
    try ix.upsert(meta(1, old));
    try ix.upsert(.{ .id = 2, .created_ms = 0, .updated_ms = old, .pinned = true });
    try ix.upsert(meta(3, old));
    try ix.upsert(.{ .id = 4, .created_ms = 0, .updated_ms = recent, .parent = 3 });
    try ix.upsert(meta(5, old));
    try ix.upsert(.{ .id = 6, .created_ms = 0, .updated_ms = old, .parent = 5 });
    try ix.upsert(meta(7, recent));

    const Gc = struct {
        var seen: [8]proto.SessionId = undefined;
        var n: usize = 0;
        fn deleted(_: ?*anyopaque, ids: []const proto.SessionId) void {
            @memcpy(seen[0..ids.len], ids);
            n = ids.len;
        }
    };
    const deleted = try retention.sweep(&ix, testing.io, .{ .retention_days = 30, .now_ms = now, .gc = .{ .sessions_deleted = Gc.deleted } });
    try testing.expectEqual(@as(u32, 3), deleted);
    try testing.expectEqual(@as(usize, 3), Gc.n);
    for ([_]proto.SessionId{ 1, 5, 6 }) |id| try testing.expect(ix.get(id) == null);
    for ([_]proto.SessionId{ 2, 3, 4, 7 }) |id| try testing.expect(ix.get(id) != null);
    const names = try f.files();
    // index.zon plus the four kept session files; the blob dir is gone.
    try testing.expectEqual(@as(usize, 5), names.len);
    for (names) |n| try testing.expect(!std.mem.endsWith(u8, n, ".blobs"));
    // Nothing more to delete.
    try testing.expectEqual(@as(u32, 0), try retention.sweep(&ix, testing.io, .{ .retention_days = 30, .now_ms = now }));
}

test "title async, skipped when named" {
    var f = try Fixture.init();
    defer f.deinit();
    var ix = try SessionIndex.load(testing.allocator, testing.io, f.dir);
    defer ix.deinit();
    try ix.upsert(meta(1, 1));
    try ix.upsert(.{ .id = 2, .name = "mine", .created_ms = 0, .updated_ms = 1 });

    const turns = [_][]const sp.ScriptedProvider.Step{sp.script.text("\"Fix the auth refresh bug.\"")};
    const s = try sp.ScriptedProvider.init(testing.allocator, &turns, .all);
    const p = s.provider();
    defer p.deinit();

    const Seen = struct {
        var id: proto.SessionId = 0;
        fn on(_: *anyopaque, _: Io, i: proto.SessionId, _: []const u8) void {
            id = i;
        }
    };
    var dummy: u8 = 0;
    var t: title.Titler = .{ .gpa = testing.allocator, .provider = p, .model = "haiku", .ix = &ix, .on_title = .{ .ctx = &dummy, .call = Seen.on } };
    try testing.expect(!try t.maybeStart(testing.io, 2, "fix it", .{ .named = true }));
    try testing.expect(!try t.maybeStart(testing.io, 1, "fix it", .{ .print_mode = true }));
    try testing.expect(try t.maybeStart(testing.io, 1, "the auth token refresh fails", .{}));
    t.wait(testing.io);
    try testing.expectEqualStrings("Fix the auth refresh bug", ix.get(1).?.title.?);
    try testing.expectEqual(@as(proto.SessionId, 1), Seen.id);
    const req = s.requests()[0];
    try testing.expectEqual(@as(u32, title.max_output_tokens), req.max_output_tokens);
    try testing.expectEqualStrings("haiku", req.model);
    try testing.expectEqual(@as(usize, 1), s.requests().len);
    // A session named meanwhile keeps its name and gets no title.
    try testing.expect(!try ix.setTitle(2, "Other"));
    try testing.expectEqual(@as(?[]const u8, null), ix.get(2).?.title);
}

test "export markdown golden" {
    var f = try Fixture.init();
    defer f.deinit();
    const id: proto.SessionId = 0x0192_0000_0000_0000_0000_0000_0000_00AA;
    const w = try f.store.create(testing.io, .{ .id = id, .cwd = "/work/repo", .model = "claude-x" });
    try w.append(1, .{ .user = f.msg(.user, "Read a.zig and tell me what it does.") });
    try w.append(2, .{ .assistant = .{ .role = .assistant, .content = &.{
        .{ .thinking = .{ .text = "Let me read it.", .signature = "s", .origin = .anthropic } },
        .{ .text = .{ .text = "Reading it." } },
        .{ .tool_use = .{ .id = "t1", .name = "read_file", .input_json = "{\"path\":\"a.zig\"}" } },
    } } });
    var big: [300]u8 = undefined;
    @memset(&big, 'x');
    big[0] = '`';
    big[1] = '`';
    big[2] = '`';
    try w.append(3, .{ .tool_results = .{ .role = .user, .content = &.{.{ .tool_result = .{ .tool_use_id = "t1", .parts = &.{.{ .text = &big }} } }} } });
    try w.append(4, .{ .assistant = f.msg(.assistant, "It defines `a`.") });
    try w.append(5, .{ .user = f.msg(.user, "Undo that") });
    try w.append(6, .{ .rewind = .{ .to_seq = 4, .action = "conversation" } });
    try w.append(7, .{ .title = "What a.zig does" });
    w.close();
    const l = try f.store.open(testing.io, id, .{ .mode = .full });
    defer l.deinit();

    var out: Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try exp.exportMarkdown(testing.allocator, l, &out.writer, .{ .max_output_bytes = 60 });
    try zg_core.testkit.golden.expectGoldenOpts(testing.io, @src(), "export", out.written(), .{ .root = @import("zg_options").package_root, .dir = "testdata/sessions" });
    try testing.expect(std.mem.indexOf(u8, out.written(), "Undo that") == null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "Let me read it") == null);

    out.clearRetainingCapacity();
    try exp.exportMarkdown(testing.allocator, l, &out.writer, .{ .include_thinking = true });
    try testing.expect(std.mem.indexOf(u8, out.written(), "Let me read it") != null);

    out.clearRetainingCapacity();
    try exp.exportJson(testing.allocator, l, &out.writer);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), out.written(), .{});
    try testing.expectEqual(@as(usize, 4), v.array.items.len);
}
