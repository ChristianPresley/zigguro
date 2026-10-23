//! Tests for the provenance recorder (`recorder.zig`).

const std = @import("std");
const enc = @import("../store/encode.zig");
const fx = @import("../oplog/test_fixture.zig");
const record = @import("record.zig");
const attribution = @import("attribution.zig");
const recorder_mod = @import("recorder.zig");
const Recorder = recorder_mod.Recorder;
const Actor = record.Actor;
const t = std.testing;

const agent = Actor.agent("claude", "anthropic/claude-x", "s-1");
const alice = Actor.human("Alice", "alice@example.com");

var fake_now: i64 = 10_000;

fn clockNow(_: ?*anyopaque) i64 {
    return fake_now;
}

fn newRecorder(f: *fx.Fixture, cfg: recorder_mod.RecorderConfig) !*Recorder {
    var c = cfg;
    c.clock = .{ .now_ms = clockNow };
    c.user = alice;
    return Recorder.init(f.gpa, f.io, f.store, c);
}

fn edit(path: []const u8, ranges: []const recorder_mod.LineRange, actor: Actor) recorder_mod.EditEvent {
    return .{ .path = path, .workspace = "default", .ranges = ranges, .actor = actor, .at_ms = fake_now };
}

fn readRecord(f: *fx.Fixture, arena: std.mem.Allocator, id: record.ProvenanceId) !record.ProvenanceRecord {
    const r = try f.store.read(id);
    defer r.release();
    return enc.decode(record.ProvenanceRecord, arena, try arena.dupe(u8, r.bytes));
}

fn flushAll(f: *fx.Fixture, r: *Recorder) !void {
    var b = f.store.batch();
    try r.flush(&b);
    try b.commit();
}

test "recorder: splices runs" {
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = try newRecorder(&f, .{});
    defer r.deinit();

    // Two events: replace line 2 with two lines, then append one at the end.
    r.onEdit(edit("a.txt", &.{.{ .old_start_line = 2, .old_len = 1, .new_len = 2 }}, alice));
    r.onEdit(edit("a.txt", &.{.{ .old_start_line = 6, .old_len = 0, .new_len = 1 }}, agent));
    const m = try r.attributionFor(a, "default", "a.txt", null, "0\n1\n2\n3\n4\n", "0\n1\nX\nY\n3\n4\nZ\n");
    try m.validate();
    try t.expectEqual(@as(u32, 7), m.lineCount());
    try t.expectEqual(@as(usize, 4), m.runs.len);
    try t.expect(m.at(0).?.prov.eql(attribution.inherited));
    const h = m.at(2).?;
    try t.expectEqual(@as(u32, 2), h.len);
    try t.expectEqual(record.ActorKind.human, (try readRecordAfterFlush(&f, r, a, h.prov)).actor.kind);
    try t.expectEqual(record.ActorKind.agent, (try readRecord(&f, a, m.at(6).?.prov)).actor.kind);
    try t.expect(m.at(4).?.prov.eql(attribution.inherited));

    // Several ranges in one event use the coordinates before it.
    r.onEdit(edit("b.txt", &.{ .{ .old_start_line = 0, .old_len = 1, .new_len = 1 }, .{ .old_start_line = 2, .old_len = 0, .new_len = 2 } }, alice));
    const m2 = try r.attributionFor(a, "default", "b.txt", null, "a\nb\n", "A\nb\nc\nd\n");
    try t.expect(!m2.at(0).?.prov.eql(attribution.inherited));
    try t.expect(m2.at(1).?.prov.eql(attribution.inherited));
    try t.expect(m2.at(2).?.prov.eql(m2.at(0).?.prov));
    try t.expectEqual(@as(u32, 4), m2.lineCount());
}

fn readRecordAfterFlush(f: *fx.Fixture, r: *Recorder, a: std.mem.Allocator, id: record.ProvenanceId) !record.ProvenanceRecord {
    try flushAll(f, r);
    return readRecord(f, a, id);
}

test "recorder: mixed lines" {
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = try newRecorder(&f, .{});
    defer r.deinit();

    // The agent writes a new three-line file.
    r.onEdit(edit("n.zig", &.{.{ .old_start_line = 0, .old_len = 0, .new_len = 3 }}, agent));
    const m1 = try r.attributionFor(a, "default", "n.zig", null, null, "a\nb\nc\n");
    try t.expectEqual(@as(usize, 1), m1.runs.len);
    const agent_rec = m1.runs[0].prov;

    // Alice edits the middle line and adds one of her own.
    r.onEdit(edit("n.zig", &.{.{ .old_start_line = 1, .old_len = 1, .new_len = 2 }}, alice));
    const m2 = try r.attributionFor(a, "default", "n.zig", m1, "a\nb\nc\n", "a\nB\nnew\nc\n");
    try m2.validate();
    const mixed = m2.at(1).?;
    try t.expect(mixed.mixed);
    try t.expect(!m2.at(2).?.mixed);
    try t.expect(m2.at(0).?.prov.eql(agent_rec));
    try t.expect(m2.at(3).?.prov.eql(agent_rec));
    try flushAll(&f, r);
    const rec = try readRecord(&f, a, mixed.prov);
    try t.expect(rec.actor.eql(alice));
    try t.expect(rec.parent.?.eql(agent_rec));

    // The agent re-editing its own lines is not mixed.
    r.onEdit(edit("n.zig", &.{.{ .old_start_line = 0, .old_len = 1, .new_len = 1 }}, agent));
    const m3 = try r.attributionFor(a, "default", "n.zig", m2, "a\nB\nnew\nc\n", "A\nB\nnew\nc\n");
    try t.expect(!m3.at(0).?.mixed);
    try t.expect(m3.at(0).?.prov.eql(agent_rec));
}

test "recorder: unobserved edit is human or unknown" {
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = try newRecorder(&f, .{});
    defer r.deinit();

    const old = "a\nb\nc\n";
    const new = "a\nX\nc\nd\n";
    const m = try r.attributionFor(a, "default", "x.txt", null, old, new);
    try flushAll(&f, r);
    try t.expectEqual(record.ActorKind.unknown, (try readRecord(&f, a, m.at(1).?.prov)).actor.kind);
    try t.expect(m.at(3).?.prov.eql(m.at(1).?.prov));
    try t.expect(m.at(2).?.prov.eql(attribution.inherited));

    // With the editor focused within 2 s it is the user's.
    r.noteFocus("default", fake_now - 1500);
    const m2 = try r.attributionFor(a, "default", "x.txt", null, old, new);
    try flushAll(&f, r);
    try t.expect((try readRecord(&f, a, m2.at(1).?.prov)).actor.eql(alice));

    // Reported edits that do not add up fall back to the diff too.
    r.onEdit(edit("x.txt", &.{.{ .old_start_line = 0, .old_len = 0, .new_len = 5 }}, agent));
    const m3 = try r.attributionFor(a, "default", "x.txt", null, old, new);
    try t.expectEqual(@as(u32, 4), m3.lineCount());
    try t.expect(m3.at(0).?.prov.eql(attribution.inherited));

    // A tool's whole-file write, matched by hash.
    var h: [32]u8 = undefined;
    std.crypto.hash.Blake3.hash(new, &h, .{});
    r.onFileWritten("x.txt", "default", Actor.tool("formatter"), h);
    const m4 = try r.attributionFor(a, "default", "x.txt", null, old, new);
    try flushAll(&f, r);
    try t.expectEqualStrings("formatter", (try readRecord(&f, a, m4.at(1).?.prov)).actor.name);
}

test "recorder: interning (1000 edits, 1 record)" {
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const r = try newRecorder(&f, .{});
    defer r.deinit();
    var text: std.ArrayList(u8) = .empty;
    for (0..1000) |i| {
        var ev = edit("big.zig", &.{.{ .old_start_line = @intCast(i), .old_len = 0, .new_len = 1 }}, agent);
        ev.prompt = "add the lines";
        r.onEdit(ev);
        try text.appendSlice(a, "x\n");
    }
    const m = try r.attributionFor(a, "default", "big.zig", null, null, text.items);
    try t.expectEqual(@as(usize, 1), m.runs.len);
    try t.expectEqual(@as(usize, 1), r.unflushed());
    try t.expect((try r.activeAgentActor(a, "default")).?.eql(agent));
    r.endTurn("default");
    try t.expect((try r.activeAgentActor(a, "default")) == null);
}

/// Whether `needle` occurs in any file under `dir`.
fn storeHas(io: std.Io, dir: std.Io.Dir, needle: []const u8) !bool {
    var walker = try dir.walk(t.allocator);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind != .file) continue;
        const data = try e.dir.readFileAlloc(io, e.basename, t.allocator, .unlimited);
        defer t.allocator.free(data);
        if (std.mem.indexOf(u8, data, needle) != null) return true;
    }
    return false;
}

test "recorder: privacy levels" {
    const prompt = "PROMPT-zq7-do-the-thing";
    inline for (.{ record.PromptPrivacy.none, record.PromptPrivacy.hash, record.PromptPrivacy.excerpt, record.PromptPrivacy.full }) |level| {
        var f = try fx.Fixture.init(t.allocator);
        defer f.deinit();
        var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const r = try newRecorder(&f, .{ .privacy = level, .excerpt_bytes = 10 });
        defer r.deinit();
        var ev = edit("p.txt", &.{.{ .old_start_line = 0, .old_len = 0, .new_len = 1 }}, agent);
        ev.prompt = prompt;
        r.onEdit(ev);
        const m = try r.attributionFor(a, "default", "p.txt", null, null, "x\n");
        try flushAll(&f, r);
        const rec = try readRecord(&f, a, m.runs[0].prov);
        const p = rec.prompt.?;
        try t.expectEqual(level, p.privacy);
        switch (level) {
            .none => try t.expect(p.hash == null),
            .hash => try t.expect(p.hash.?.eql(record.promptHash(prompt))),
            .excerpt => try t.expectEqualStrings(prompt[0..10], p.excerpt),
            .full => {
                const txt = try f.store.read(p.text.?);
                defer txt.release();
                try t.expectEqualStrings(prompt, txt.bytes);
            },
        }
        if (level == .none or level == .hash) {
            try t.expect(!try storeHas(f.io, f.tmp.dir, prompt[0..10]));
        }
    }
}

test "recorder: excerpts are redacted" {
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Mask = struct {
        fn redact(_: *anyopaque, arena: std.mem.Allocator, text: []const u8) anyerror![]const u8 {
            return std.mem.replaceOwned(u8, arena, text, "sk-123", "[secret]");
        }
    };
    var dummy: u8 = 0;
    const r = try newRecorder(&f, .{ .redact = .{ .ctx = &dummy, .redact = Mask.redact } });
    defer r.deinit();
    var ev = edit("p.txt", &.{.{ .old_start_line = 0, .old_len = 0, .new_len = 1 }}, agent);
    ev.prompt = "use key sk-123 please";
    r.onEdit(ev);
    const m = try r.attributionFor(a, "default", "p.txt", null, null, "x\n");
    try flushAll(&f, r);
    try t.expectEqualStrings("use key [secret] please", (try readRecord(&f, a, m.runs[0].prov)).prompt.?.excerpt);
}

test "recorder: editor adapter mapping table" {
    const Sessions = struct {
        fn get(_: *anyopaque, s: u32) ?Actor {
            return if (s == 7) agent else null;
        }
    };
    var dummy: u8 = 0;
    const lookup: recorder_mod.SessionLookup = .{ .ctx = &dummy, .get = Sessions.get };
    const cases = [_]struct { origin: recorder_mod.EditorOrigin, want: ?Actor }{
        .{ .origin = .user, .want = alice },
        .{ .origin = .undo, .want = alice },
        .{ .origin = .redo, .want = alice },
        .{ .origin = .{ .agent = 7 }, .want = agent },
        .{ .origin = .{ .agent = 8 }, .want = .{ .kind = .agent, .name = "agent" } },
        .{ .origin = .lsp_edit, .want = Actor.tool("lsp.edit") },
        .{ .origin = .format, .want = Actor.tool("formatter") },
        .{ .origin = .reload, .want = null },
    };
    for (cases) |c| {
        const got = recorder_mod.adaptOrigin(c.origin, alice, lookup);
        if (c.want) |w| try t.expect(got.?.eql(w)) else try t.expect(got == null);
    }
    const ev = recorder_mod.adaptEditorChange(.format, "a.zig", "ws", 3, &.{.{ .old_start_line = 0, .old_len = 1, .new_len = 1 }}, alice, null, 5).?;
    try t.expectEqualStrings("formatter", ev.actor.name);
    try t.expectEqual(@as(?u64, 3), ev.base_version);
    try t.expect(recorder_mod.adaptEditorChange(.reload, "a.zig", "ws", null, &.{}, alice, null, 5) == null);
}
