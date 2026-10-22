const std = @import("std");
const builtin = @import("builtin");
const model = @import("../model/root.zig");
const qm = @import("queue_model.zig");

const testing = std.testing;
const gpa = testing.allocator;
const ChangesetId = model.ChangesetId;
const QueueModel = qm.QueueModel;

const Fx = struct {
    blobs: model.MemBlobs,
    q: *model.Queue,
    m: *QueueModel,
    clock: i64 = 0,

    fn init(fx: *Fx, o: qm.Options) !void {
        fx.* = .{ .blobs = .init(gpa), .q = undefined, .m = undefined };
        fx.q = try model.Queue.init(gpa, testing.io, .{ .root = "/w", .blobs = fx.blobs.blobs() });
        var opts = o;
        opts.now_ms = now;
        opts.names = .{ .ctx = fx, .name = name };
        fx.m = try QueueModel.init(gpa, fx.q, opts);
    }

    fn deinit(fx: *Fx) void {
        fx.m.deinit();
        fx.q.deinit();
        fx.blobs.deinit();
    }

    fn now() i64 {
        return 100 * std.time.ms_per_hour;
    }

    fn name(_: *anyopaque, session: u128) ?[]const u8 {
        return switch (session) {
            1 => "Builder",
            2 => "Docs Writer",
            else => null,
        };
    }

    fn submit(fx: *Fx, origin: model.Origin, label: []const u8, path: []const u8) !ChangesetId {
        fx.clock += 1;
        const b = try fx.q.beginBatch(.{ .origin = origin, .label = label, .workspace = "/w", .created_ms = fx.clock });
        var e = try model.merge3.lineChangeSet(gpa, "a\nb\n", "A\nb\nc\n");
        defer e.deinit();
        try fx.q.addEdit(b, path, "a\nb\n", null, &e);
        return fx.q.commitBatch(b, .{});
    }

    fn agent(fx: *Fx, session: u128, sub: u32, label: []const u8, path: []const u8) !ChangesetId {
        return fx.submit(.{ .agent = .{ .ref = .{ .session = session, .agent = sub }, .turn = 1, .model = "m" } }, label, path);
    }

    /// The rows as "kind:label" lines, groups unindented.
    fn dump(fx: *Fx, buf: []u8) ![]const u8 {
        var w: std.Io.Writer = .fixed(buf);
        for (fx.m.rows()) |r| {
            for (0..r.depth) |_| try w.writeAll("  ");
            try w.print("{s}\n", .{r.label});
        }
        return w.buffered();
    }
};

test "queue_model: grouping by session/agent/origin/path ordering" {
    var fx: Fx = undefined;
    try fx.init(.{});
    defer fx.deinit();
    _ = try fx.agent(1, 0, "Turn 1: parser", "src/parse.zig");
    _ = try fx.agent(2, 0, "Turn 1: guide", "docs/guide.md");
    _ = try fx.submit(.{ .lsp = .{ .server = "zls" } }, "Rename symbol", "src/a.zig");
    _ = try fx.agent(1, 3, "Turn 2: tests", "README.md");
    var buf: [1024]u8 = undefined;

    // Newest group first, newest first inside; LSP has no session.
    try testing.expectEqualStrings(
        \\Builder 000001…
        \\  Turn 2: tests
        \\  Turn 1: parser
        \\LSP
        \\  Rename symbol
        \\Docs Writer 000002…
        \\  Turn 1: guide
        \\
    , try fx.dump(&buf));

    fx.m.setGroupBy(.agent);
    try testing.expectEqualStrings(
        \\Builder 000001… / subagent 3
        \\  Turn 2: tests
        \\LSP
        \\  Rename symbol
        \\Docs Writer 000002…
        \\  Turn 1: guide
        \\Builder 000001…
        \\  Turn 1: parser
        \\
    , try fx.dump(&buf));

    fx.m.setGroupBy(.origin);
    try testing.expectEqualStrings(
        \\Agent
        \\  Turn 2: tests
        \\  Turn 1: guide
        \\  Turn 1: parser
        \\LSP
        \\  Rename symbol
        \\
    , try fx.dump(&buf));

    fx.m.setGroupBy(.path);
    try testing.expectEqualStrings(
        \\(workspace root)
        \\  Turn 2: tests
        \\src/
        \\  Rename symbol
        \\  Turn 1: parser
        \\docs/
        \\  Turn 1: guide
        \\
    , try fx.dump(&buf));

    fx.m.setGroupBy(.none);
    try testing.expectEqualStrings(
        \\Turn 2: tests
        \\Rename symbol
        \\Turn 1: guide
        \\Turn 1: parser
        \\
    , try fx.dump(&buf));
}

test "queue_model: expand files and collapse groups" {
    var fx: Fx = undefined;
    try fx.init(.{});
    defer fx.deinit();
    const id = try fx.agent(1, 0, "Turn 1", "src/a.zig");
    var buf: [512]u8 = undefined;
    try fx.m.toggle(1);
    try testing.expectEqualStrings("Builder 000001…\n  Turn 1\n    src/a.zig\n", try fx.dump(&buf));
    const file = fx.m.rows()[2];
    try testing.expectEqual(qm.RowKind.file, file.kind);
    try testing.expectEqual(@as(?ChangesetId, id), file.cs);
    try testing.expectEqual(@as(u32, 2), file.added);
    try testing.expectEqual(@as(u32, 1), file.removed);
    try fx.m.toggle(0);
    try testing.expectEqualStrings("Builder 000001…\n", try fx.dump(&buf));
    try testing.expect(!fx.m.rows()[0].expanded);
    try fx.m.toggle(0);
    try testing.expectEqual(@as(usize, 3), fx.m.rows().len);
}

test "queue_model: filter parser table" {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const f = try qm.parseFilter(a, "state:pending state:applied path:src/** agent:Build origin:lsp origin:agent conflicts:yes fix the  parser");
    try testing.expect(f.states.contains(.pending));
    try testing.expect(f.states.contains(.applied));
    try testing.expect(!f.states.contains(.partially_applied));
    try testing.expect(f.origins.?.contains(.lsp));
    try testing.expect(f.origins.?.contains(.agent));
    try testing.expectEqualStrings("src/**", f.path_glob.?);
    try testing.expectEqualStrings("Build", f.agent.?);
    try testing.expectEqual(@as(?bool, true), f.has_conflicts);
    try testing.expectEqualStrings("fix the parser", f.text.?);

    const d = try qm.parseFilter(a, "");
    try testing.expect(d.states.eql(qm.pending_like));
    try testing.expectEqual(@as(?[]const u8, null), d.text);
    try testing.expect((try qm.parseFilter(a, "state:all")).states.eql(.initFull()));
    try testing.expectError(error.UnknownKey, qm.parseFilter(a, "colour:red"));
    try testing.expectError(error.BadValue, qm.parseFilter(a, "state:maybe"));
    try testing.expectError(error.BadValue, qm.parseFilter(a, "conflicts:"));
}

test "queue_model: filters, counts and the auto-applied group" {
    var fx: Fx = undefined;
    try fx.init(.{ .group_by = .none });
    defer fx.deinit();
    const a = try fx.agent(1, 0, "Turn 1: Parser fix", "src/parse.zig");
    const b = try fx.agent(2, 0, "Turn 1: Guide", "docs/guide.md");
    const c = try fx.agent(2, 0, "Turn 2: More docs", "docs/more.md");
    // `c` was applied without review an hour ago.
    const cs = fx.q.getMut(c).?;
    try model.transition(cs, .applied);
    cs.auto_applied = true;
    cs.decided_ms = Fx.now() - std.time.ms_per_hour;
    fx.q.persist(c);
    fx.q.emit(.{ .state = .{ .cs = c, .from = .pending, .to = .applied } });

    const n = fx.m.counts();
    try testing.expectEqual(@as(u32, 2), n.pending_changesets);
    try testing.expectEqual(@as(u32, 4), n.pending_hunks); // two hunks each
    try testing.expectEqual(@as(usize, 2), n.per_session.len);

    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(
        \\Turn 1: Guide
        \\Turn 1: Parser fix
        \\Recently auto-applied (last 24 h)
        \\  Turn 2: More docs
        \\
    , try fx.dump(&buf));

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    try fx.m.setFilter(try qm.parseFilter(ar, "PARSER"));
    try testing.expectEqual(@as(?ChangesetId, a), fx.m.rows()[0].cs);
    try fx.m.setFilter(try qm.parseFilter(ar, "path:docs/**"));
    try testing.expectEqual(@as(?ChangesetId, b), fx.m.rows()[0].cs);
    try fx.m.setFilter(try qm.parseFilter(ar, "agent:writer"));
    try testing.expectEqual(@as(?ChangesetId, b), fx.m.rows()[0].cs);
    // The pinned group is filtered too, but not by state.
    try fx.m.setFilter(try qm.parseFilter(ar, "conflicts:yes"));
    try testing.expectEqual(@as(usize, 0), fx.m.rows().len);
    try fx.m.setFilter(try qm.parseFilter(ar, "origin:lsp"));
    try testing.expectEqual(@as(usize, 0), fx.m.rows().len);
    try fx.m.setFilter(try qm.parseFilter(ar, "more"));
    try testing.expectEqualStrings("Recently auto-applied (last 24 h)", fx.m.rows()[0].label);
    try testing.expectEqual(@as(?ChangesetId, c), fx.m.rows()[1].cs);

    // Older than a day: gone from the pinned group (and applied).
    try fx.m.setFilter(try qm.parseFilter(ar, ""));
    fx.q.getMut(c).?.decided_ms = Fx.now() - 2 * qm.auto_applied_window_ms;
    fx.q.emit(.{ .updated = c });
    try testing.expectEqual(@as(usize, 2), fx.m.rows().len);
}

test "queue_model: 5,000 rows filter and incremental updates" {
    var fx: Fx = undefined;
    try fx.init(.{});
    defer fx.deinit();
    var label: [32]u8 = undefined;
    var path: [32]u8 = undefined;
    for (0..5000) |i| _ = try fx.agent(@intCast(i % 7 + 1), 0, try std.fmt.bufPrint(&label, "Turn {d}", .{i}), try std.fmt.bufPrint(&path, "src/f{d}.zig", .{i}));
    try testing.expectEqual(@as(usize, 5007), fx.m.rows().len);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const v0 = fx.m.version;
    const t0 = std.Io.Timestamp.now(testing.io, .awake);
    try fx.m.setFilter(try qm.parseFilter(arena_state.allocator(), "turn 49"));
    const rs = fx.m.rows();
    const ms = t0.untilNow(testing.io, .awake).toMilliseconds();
    try testing.expect(fx.m.version != v0);
    // "Turn 49" and "Turn 490".."Turn 4999": 1 + 10 + 100 = 111, plus the groups.
    var n: usize = 0;
    for (rs) |r| n += @intFromBool(r.kind == .changeset);
    try testing.expectEqual(@as(usize, 111), n);
    if (builtin.mode != .Debug) try testing.expect(ms < 8);
}
