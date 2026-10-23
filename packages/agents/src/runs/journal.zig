//! Run journals (E13.F01.S01.T01): one append-only JSON Lines file per run,
//! `.zigguro/runs/<run_id>/run.jsonl`. Every line is
//! `{"v":1,"seq":N,"t":<ms>,"type":"…",…}`; `create` carries the spec,
//! the others one `Update`, and `end` the terminal status. Encoding and
//! replay are pure; the registry's writer task does the file I/O.

const std = @import("std");
const run = @import("run.zig");

const Allocator = std.mem.Allocator;
const RunId = run.RunId;
const RunRecord = run.RunRecord;
const Update = run.Update;

pub const version = 1;

/// One decoded line.
pub const Line = struct {
    seq: u64,
    t: i64,
    body: Body,

    pub const Body = union(enum) {
        create: struct { id: RunId, spec: run.RunSpec },
        update: Update,
    };
};

fn typeName(u: Update) []const u8 {
    return switch (u) {
        .status => |s| if (s.isTerminal()) "end" else "status",
        .error_ => "error",
        else => @tagName(u),
    };
}

/// Appends the `create` line for `r` (with its newline) to `w`.
pub fn writeCreate(w: *std.Io.Writer, r: *const RunRecord) std.Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try header(&s, 1, r.created_ms, "create");
    try s.objectField("id");
    try s.write(r.id);
    try s.objectField("spec");
    try s.write(r.spec);
    try s.endObject();
    try w.writeByte('\n');
}

/// Appends the line for update `u` (with its newline) to `w`.
pub fn writeUpdate(w: *std.Io.Writer, seq: u64, t: i64, u: Update) std.Io.Writer.Error!void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try header(&s, seq, t, typeName(u));
    switch (u) {
        .status => |st| {
            try s.objectField("status");
            try s.write(@tagName(st));
        },
        .summary, .lane, .error_, .title => |txt| {
            try s.objectField("text");
            try s.write(txt);
        },
        .question => |q| {
            try s.objectField("text");
            if (q) |txt| try s.write(txt) else try s.write(null);
        },
        .cost => |c| {
            try s.objectField("cost");
            try s.write(c);
        },
        .output => |o| {
            try s.objectField("output");
            try s.write(o);
        },
        .session => |id| {
            try s.objectField("session");
            try s.write(&ulidText(id));
        },
        .started, .ended => |ms| {
            try s.objectField("at");
            try s.write(ms);
        },
        .pinned => |on| {
            try s.objectField("on");
            try s.write(on);
        },
    }
    try s.endObject();
    try w.writeByte('\n');
}

fn header(s: *std.json.Stringify, seq: u64, t: i64, ty: []const u8) !void {
    try s.objectField("v");
    try s.write(version);
    try s.objectField("seq");
    try s.write(seq);
    try s.objectField("t");
    try s.write(t);
    try s.objectField("type");
    try s.write(ty);
}

pub fn ulidText(id: u128) [26]u8 {
    return RunId.fromInt(id).text();
}

pub const DecodeError = error{ InvalidJournal, OutOfMemory };

/// Decodes one line (without its newline). Strings point into `arena`.
pub fn decodeLine(arena: Allocator, line: []const u8) DecodeError!Line {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJournal,
    };
    const o = switch (v) {
        .object => |o| o,
        else => return error.InvalidJournal,
    };
    const seq = intField(o, "seq") orelse return error.InvalidJournal;
    const t = intField(o, "t") orelse return error.InvalidJournal;
    const ty = strField(o, "type") orelse return error.InvalidJournal;
    const opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    const body: Line.Body = if (std.mem.eql(u8, ty, "create")) blk: {
        const id = RunId.parse(strField(o, "id") orelse return error.InvalidJournal) catch return error.InvalidJournal;
        const spec = std.json.parseFromValueLeaky(run.RunSpec, arena, o.get("spec") orelse return error.InvalidJournal, opts) catch
            return error.InvalidJournal;
        break :blk .{ .create = .{ .id = id, .spec = spec } };
    } else if (std.mem.eql(u8, ty, "status") or std.mem.eql(u8, ty, "end")) blk: {
        const name = strField(o, "status") orelse return error.InvalidJournal;
        break :blk .{ .update = .{ .status = std.meta.stringToEnum(run.RunStatus, name) orelse return error.InvalidJournal } };
    } else if (std.mem.eql(u8, ty, "summary")) blk: {
        break :blk .{ .update = .{ .summary = strField(o, "text") orelse return error.InvalidJournal } };
    } else if (std.mem.eql(u8, ty, "lane")) blk: {
        break :blk .{ .update = .{ .lane = strField(o, "text") orelse return error.InvalidJournal } };
    } else if (std.mem.eql(u8, ty, "title")) blk: {
        break :blk .{ .update = .{ .title = strField(o, "text") orelse return error.InvalidJournal } };
    } else if (std.mem.eql(u8, ty, "pinned")) blk: {
        const on = switch (o.get("on") orelse return error.InvalidJournal) {
            .bool => |b| b,
            else => return error.InvalidJournal,
        };
        break :blk .{ .update = .{ .pinned = on } };
    } else if (std.mem.eql(u8, ty, "error")) blk: {
        break :blk .{ .update = .{ .error_ = strField(o, "text") orelse return error.InvalidJournal } };
    } else if (std.mem.eql(u8, ty, "question")) blk: {
        break :blk .{ .update = .{ .question = strField(o, "text") } };
    } else if (std.mem.eql(u8, ty, "cost")) blk: {
        const c = std.json.parseFromValueLeaky(run.Cost, arena, o.get("cost") orelse return error.InvalidJournal, opts) catch
            return error.InvalidJournal;
        break :blk .{ .update = .{ .cost = c } };
    } else if (std.mem.eql(u8, ty, "output")) blk: {
        const out = std.json.parseFromValueLeaky(run.Output, arena, o.get("output") orelse return error.InvalidJournal, opts) catch
            return error.InvalidJournal;
        break :blk .{ .update = .{ .output = out } };
    } else if (std.mem.eql(u8, ty, "session")) blk: {
        const id = RunId.parse(strField(o, "session") orelse return error.InvalidJournal) catch return error.InvalidJournal;
        break :blk .{ .update = .{ .session = id.toInt() } };
    } else if (std.mem.eql(u8, ty, "started") or std.mem.eql(u8, ty, "ended")) blk: {
        const at = intField(o, "at") orelse return error.InvalidJournal;
        break :blk .{ .update = if (ty[0] == 's') .{ .started = at } else .{ .ended = at } };
    } else return error.InvalidJournal;
    return .{ .seq = @intCast(@max(0, seq)), .t = t, .body = body };
}

fn intField(o: std.json.ObjectMap, k: []const u8) ?i64 {
    return switch (o.get(k) orelse return null) {
        .integer => |i| i,
        else => null,
    };
}

fn strField(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
    return switch (o.get(k) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

/// Applies `u` to `r` in place, with strings borrowed from the caller (the
/// registry clones the result). Does not check transitions.
pub fn apply(gpa: Allocator, r: *RunRecord, u: Update) Allocator.Error!void {
    switch (u) {
        .status => |s| {
            r.status = s;
            if (s != .needs_input) r.question = null;
        },
        .summary => |s| r.summary = s,
        .question => |q| r.question = q,
        .cost => |c| r.cost = c,
        .output => |o| {
            const outs = try gpa.alloc(run.Output, r.outputs.len + 1);
            @memcpy(outs[0..r.outputs.len], r.outputs);
            outs[r.outputs.len] = o;
            r.outputs = outs;
        },
        .session => |id| r.session = id,
        .lane => |l| r.lane = l,
        .error_ => |e| r.error_ = e,
        .started => |ms| r.started_ms = ms,
        .ended => |ms| r.ended_ms = ms,
        .title => |t| r.spec.title = t,
        .pinned => |on| r.pinned = on,
    }
    r.revision += 1;
}

/// The result of replaying a journal.
pub const Replay = struct {
    record: RunRecord,
    /// Bytes of complete lines; a torn tail starts here.
    good_len: usize,
    /// The file ended inside a line (a crash during an append).
    torn: bool,
    /// The last line's timestamp.
    last_t: i64,
};

/// Replays journal `bytes` into one record allocated in `arena`. Stops at
/// a torn tail or an undecodable line.
pub fn replay(arena: Allocator, bytes: []const u8) DecodeError!Replay {
    var rec: ?RunRecord = null;
    var pos: usize = 0;
    var last_t: i64 = 0;
    while (pos < bytes.len) {
        const nl = std.mem.indexOfScalarPos(u8, bytes, pos, '\n') orelse break;
        const line = bytes[pos..nl];
        const l = decodeLine(arena, line) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidJournal => if (rec == null) return error.InvalidJournal else break,
        };
        switch (l.body) {
            .create => |c| rec = .{ .id = c.id, .spec = c.spec, .created_ms = l.t },
            .update => |u| {
                const r = &(rec orelse return error.InvalidJournal);
                try apply(arena, r, u);
            },
        }
        last_t = l.t;
        pos = nl + 1;
    }
    const r = rec orelse return error.InvalidJournal;
    return .{ .record = r, .good_len = pos, .torn = pos < bytes.len, .last_t = last_t };
}

const testing = std.testing;

fn sampleJournal(gpa: Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const tags = [_][]const u8{"nightly"};
    const r: RunRecord = .{
        .id = try RunId.parse("01JABCDEFGHJKMNPQRSTVWXYZ0"),
        .spec = .{
            .kind = .scheduled,
            .title = "Triage \"issues\"",
            .prompt = "Look at new issues",
            .origin = .{ .automation = .{ .name = "triage", .fire_id = "f1" } },
            .tags = &tags,
            .budgets = .{ .max_turns = 20 },
        },
        .created_ms = 1000,
    };
    const w = &aw.writer;
    try writeCreate(w, &r);
    try writeUpdate(w, 2, 1001, .{ .status = .starting });
    try writeUpdate(w, 3, 1002, .{ .started = 1002 });
    try writeUpdate(w, 4, 1003, .{ .session = 0x0123456789 });
    try writeUpdate(w, 5, 1004, .{ .status = .working });
    try writeUpdate(w, 6, 1005, .{ .question = "Allow `rm`?" });
    try writeUpdate(w, 7, 1006, .{ .status = .needs_input });
    try writeUpdate(w, 8, 1007, .{ .status = .working });
    try writeUpdate(w, 9, 1008, .{ .cost = .{ .micros = 1500, .input_tokens = 10, .output_tokens = 4 } });
    try writeUpdate(w, 10, 1009, .{ .output = .{ .changeset = 17 } });
    try writeUpdate(w, 11, 1010, .{ .output = .{ .pr = .{ .url = "https://example.test/pr/3", .number = 3 } } });
    try writeUpdate(w, 12, 1011, .{ .summary = "Labelled 3 issues" });
    try writeUpdate(w, 13, 1012, .{ .ended = 1012 });
    try writeUpdate(w, 14, 1012, .{ .status = .completed });
    return aw.toOwnedSlice();
}

test "journal_replay_equals_memory" {
    const bytes = try sampleJournal(testing.allocator);
    defer testing.allocator.free(bytes);
    const golden = @embedFile("testdata/basic.jsonl");
    try testing.expectEqualStrings(golden, bytes);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const rp = try replay(arena.allocator(), bytes);
    const r = rp.record;
    try testing.expect(!rp.torn);
    try testing.expectEqual(run.RunStatus.completed, r.status);
    try testing.expectEqual(run.RunKind.scheduled, r.spec.kind);
    try testing.expectEqualStrings("Triage \"issues\"", r.spec.title);
    try testing.expectEqualStrings("triage", r.spec.origin.automation.name);
    try testing.expectEqualStrings("nightly", r.spec.tags[0]);
    try testing.expectEqual(@as(?u32, 20), r.spec.budgets.max_turns);
    try testing.expectEqual(@as(?u128, 0x0123456789), r.session);
    try testing.expectEqual(@as(?[]const u8, null), r.question);
    try testing.expectEqual(@as(u64, 1500), r.cost.micros);
    try testing.expectEqual(@as(usize, 2), r.outputs.len);
    try testing.expectEqual(@as(u32, 3), r.outputs[1].pr.number);
    try testing.expectEqualStrings("Labelled 3 issues", r.summary);
    try testing.expectEqual(@as(?i64, 1002), r.started_ms);
    try testing.expectEqual(@as(?i64, 1012), r.ended_ms);
    try testing.expectEqual(@as(u64, 14), r.revision);
}

test "replay stops at a torn tail" {
    const bytes = try sampleJournal(testing.allocator);
    defer testing.allocator.free(bytes);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Cut inside the last line.
    const cut = bytes[0 .. bytes.len - 5];
    const rp = try replay(arena.allocator(), cut);
    try testing.expect(rp.torn);
    try testing.expectEqual(run.RunStatus.working, rp.record.status);
    try testing.expectEqual(@as(u8, '\n'), cut[rp.good_len - 1]);
    try testing.expectError(error.InvalidJournal, replay(arena.allocator(), "{\"v\":1}\n"));
}

test "title and pinned updates round trip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    const rec: RunRecord = .{ .id = .fromInt(7), .spec = .{ .kind = .background, .title = "old", .prompt = "p" }, .created_ms = 1 };
    try writeCreate(&aw.writer, &rec);
    try writeUpdate(&aw.writer, 2, 2, .{ .title = "new name" });
    try writeUpdate(&aw.writer, 3, 3, .{ .pinned = true });
    const rp = try replay(a, aw.written());
    try testing.expectEqualStrings("new name", rp.record.spec.title);
    try testing.expect(rp.record.pinned);
    try testing.expectEqual(@as(u64, 3), rp.record.revision);
}
