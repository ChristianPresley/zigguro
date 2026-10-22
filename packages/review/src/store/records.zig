//! JSON records of the review journal (E12.F01.S02.T01): a changeset
//! snapshot (everything but blob contents), an apply record
//! (E12.F02.S03.T02), a checkpoint (E12.F04.S01.T01), and their decoders.
//!
//! Edits are inlined as `[[start, end, "text"], ...]`; when their texts
//! exceed `inline_limit` they go to a blob holding the same JSON and the
//! record names it (`edits_blob`). Hunks are stored, so loading never
//! reads base texts: `[base_start, base_count, new_start, new_count,
//! span0, span1, decision, "key"]`, plus a ninth element, the conflict
//! object, when a rebase marked the hunk.

const std = @import("std");
const proto = @import("zg_ai_proto");
const model = @import("../model/root.zig");

const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const Value = std.json.Value;
const Changeset = model.Changeset;
const FileChange = model.FileChange;
const ChangeSet = model.changeset.ChangeSet;
const Replace = model.changeset.Replace;
const BlobHash = model.BlobHash;

pub const inline_limit = 16 << 10;

pub const Error = error{ InvalidRecord, OutOfMemory };

/// Writes the snapshot of `cs`; large edits go through `blobs`.
pub fn writeChangeset(w: *std.Io.Writer, cs: *const Changeset, blobs: model.Blobs, scratch: Allocator) anyerror!void {
    var s: Stringify = .{ .writer = w };
    try s.beginObject();
    try field(&s, "id", @intFromEnum(cs.id));
    try s.objectField("prov");
    try model.provenance.writeProvenance(&s, cs.prov);
    try field(&s, "state", @tagName(cs.state));
    try field(&s, "revision", cs.revision);
    if (cs.supersedes) |x| try field(&s, "supersedes", @intFromEnum(x));
    if (cs.checkpoint) |x| try field(&s, "checkpoint", x);
    try field(&s, "auto_applied", cs.auto_applied);
    try field(&s, "presentation", @tagName(cs.presentation));
    try field(&s, "created_ms", cs.created_ms);
    if (cs.decided_ms) |x| try field(&s, "decided_ms", x);
    try s.objectField("files");
    try s.beginArray();
    for (cs.files) |*f| try writeFile(&s, f, blobs, scratch);
    try s.endArray();
    try s.endObject();
}

/// Writes a `History` record: hashes only, contents are blobs.
pub fn writeApply(w: *std.Io.Writer, a: *const model.Apply) Stringify.Error!void {
    var s: Stringify = .{ .writer = w };
    try s.beginObject();
    try field(&s, "id", a.id);
    try field(&s, "kind", @tagName(a.kind));
    if (a.cs) |x| try field(&s, "cs", @intFromEnum(x));
    if (a.undoes) |x| try field(&s, "undoes", x);
    if (a.session) |x| try field(&s, "session", &proto.agent_ref.format(x));
    try field(&s, "created_ms", a.created_ms);
    try s.objectField("files");
    try s.beginArray();
    for (a.files) |f| {
        try s.beginObject();
        try field(&s, "path", f.path);
        if (f.from) |x| try field(&s, "from", x);
        if (f.pre) |h| try field(&s, "pre", &hex(h));
        if (f.post) |h| try field(&s, "post", &hex(h));
        if (f.pre_exec) try field(&s, "pre_exec", true);
        if (f.post_exec) try field(&s, "post_exec", true);
        try s.endObject();
    }
    try s.endArray();
    if (a.closed.len > 0) {
        try s.objectField("closed");
        try s.beginArray();
        for (a.closed) |c| {
            try s.beginObject();
            try field(&s, "cs", @intFromEnum(c.cs));
            try field(&s, "from", @tagName(c.from));
            try s.endObject();
        }
        try s.endArray();
    }
    try s.endObject();
}

/// Decodes `writeApply`'s record; strings are allocated in `arena`.
pub fn readApply(arena: Allocator, v: Value) Error!model.Apply {
    const o = try obj(v);
    const fs = try arr(get(o, "files") orelse return error.InvalidRecord);
    const files = try arena.alloc(model.ApplyFile, fs.items.len);
    for (fs.items, files) |fv, *f| {
        const fo = try obj(fv);
        f.* = .{
            .path = try dupe(arena, get(fo, "path")),
            .from = if (get(fo, "from")) |x| try dupe(arena, x) else null,
            .pre = if (get(fo, "pre")) |x| try unhex(x) else null,
            .post = if (get(fo, "post")) |x| try unhex(x) else null,
            .pre_exec = if (get(fo, "pre_exec")) |x| try boolean(x) else false,
            .post_exec = if (get(fo, "post_exec")) |x| try boolean(x) else false,
        };
    }
    var closed: []model.Closed = &.{};
    if (get(o, "closed")) |cv| {
        const cs = try arr(cv);
        closed = try arena.alloc(model.Closed, cs.items.len);
        for (cs.items, closed) |x, *c| {
            const co = try obj(x);
            c.* = .{ .cs = @enumFromInt(try int(u64, get(co, "cs"))), .from = try enumOf(model.State, get(co, "from")) };
        }
    }
    return .{
        .closed = closed,
        .id = try int(u64, get(o, "id")),
        .kind = try enumOf(model.ApplyKind, get(o, "kind")),
        .cs = if (get(o, "cs")) |x| @enumFromInt(try int(u64, x)) else null,
        .undoes = if (get(o, "undoes")) |x| try int(u64, x) else null,
        .session = if (get(o, "session")) |x| proto.agent_ref.parse(try str(x)) catch return error.InvalidRecord else null,
        .created_ms = try int(i64, get(o, "created_ms")),
        .files = files,
    };
}

/// Writes a checkpoint record.
pub fn writeCheckpoint(w: *std.Io.Writer, c: *const model.Checkpoint) Stringify.Error!void {
    var s: Stringify = .{ .writer = w };
    try s.beginObject();
    try field(&s, "id", c.id);
    try field(&s, "session", &proto.agent_ref.format(c.session));
    if (c.agent != 0) try field(&s, "agent", c.agent);
    try field(&s, "turn", c.turn);
    if (c.label.len > 0) try field(&s, "label", c.label);
    try field(&s, "created_ms", c.created_ms);
    try field(&s, "after_apply", c.after_apply);
    try field(&s, "next_changeset", c.next_changeset);
    if (c.pinned) try field(&s, "pinned", true);
    try s.endObject();
}

/// Decodes `writeCheckpoint`'s record; the label is allocated in `arena`.
pub fn readCheckpoint(arena: Allocator, v: Value) Error!model.Checkpoint {
    const o = try obj(v);
    return .{
        .id = try int(u64, get(o, "id")),
        .session = proto.agent_ref.parse(try str(get(o, "session") orelse return error.InvalidRecord)) catch return error.InvalidRecord,
        .agent = if (get(o, "agent")) |x| try int(u32, x) else 0,
        .turn = try int(u32, get(o, "turn")),
        .label = if (get(o, "label")) |x| try dupe(arena, x) else "",
        .created_ms = try int(i64, get(o, "created_ms")),
        .after_apply = try int(u64, get(o, "after_apply")),
        .next_changeset = try int(u64, get(o, "next_changeset")),
        .pinned = if (get(o, "pinned")) |x| try boolean(x) else false,
    };
}

fn field(s: *Stringify, name: []const u8, v: anytype) Stringify.Error!void {
    try s.objectField(name);
    try s.write(v);
}

fn hex(h: BlobHash) [64]u8 {
    return std.fmt.bytesToHex(h, .lower);
}

fn writeBase(s: *Stringify, b: model.BaseRef) Stringify.Error!void {
    try s.beginObject();
    try field(s, "hash", &hex(b.hash));
    try field(s, "size", b.size);
    if (b.doc_version) |v| try field(s, "doc_version", v);
    try field(s, "eol", @tagName(b.eol));
    try s.endObject();
}

fn writeFile(s: *Stringify, f: *const FileChange, blobs: model.Blobs, scratch: Allocator) anyerror!void {
    try s.beginObject();
    try field(s, "path", f.path);
    try s.objectField("op");
    try s.beginObject();
    try field(s, "type", @tagName(f.op));
    switch (f.op) {
        .create => |c| try field(s, "executable", c.executable),
        .rename => |r| try field(s, "from", r.from),
        .set_executable => |on| try field(s, "on", on),
        .modify, .delete => {},
    }
    try s.endObject();
    try field(s, "state", @tagName(f.state));
    if (f.base) |b| {
        try s.objectField("base");
        try writeBase(s, b);
    }
    if (f.folded_from.len > 0) {
        try s.objectField("folded_from");
        try s.beginArray();
        for (f.folded_from) |id| try s.write(@intFromEnum(id));
        try s.endArray();
    }
    if (f.previous) |h| try field(s, "previous", &hex(h));
    try s.objectField("content");
    try s.beginObject();
    try field(s, "type", @tagName(f.content));
    switch (f.content) {
        .none => {},
        .text => |t| {
            if (t.base) |b| {
                try s.objectField("base");
                try writeBase(s, b);
            }
            try field(s, "base_len", t.edits.base_len);
            if (t.edits.insertedBytes() > inline_limit) {
                var aw: std.Io.Writer.Allocating = .init(scratch);
                defer aw.deinit();
                var es: Stringify = .{ .writer = &aw.writer };
                try writeEdits(&es, &t.edits);
                try field(s, "edits_blob", &hex(try blobs.put(aw.written())));
            } else {
                try s.objectField("edits");
                try writeEdits(s, &t.edits);
            }
        },
        .binary => |b| {
            if (b.base) |h| try field(s, "base", &hex(h));
            try field(s, "new", &hex(b.new));
            try field(s, "new_size", b.new_size);
        },
    }
    try s.endObject();
    try s.objectField("hunks");
    try s.beginArray();
    for (f.hunks) |h| {
        try s.beginArray();
        for ([_]u64{ h.base_lines.start, h.base_lines.count, h.new_lines.start, h.new_lines.count, h.replace_span[0], h.replace_span[1], @intFromEnum(h.decision) }) |x| try s.write(x);
        var kb: [16]u8 = undefined;
        try s.write(std.fmt.bufPrint(&kb, "{x:0>16}", .{h.key}) catch unreachable);
        if (h.conflict) |c| {
            try s.beginObject();
            try field(s, "kind", @tagName(c.kind));
            if (c.other) |o| try field(s, "other", @intFromEnum(o));
            try field(s, "start", c.ours_lines.start);
            try field(s, "count", c.ours_lines.count);
            try field(s, "theirs", c.theirs_text);
            try s.endObject();
        }
        try s.endArray();
    }
    try s.endArray();
    try s.endObject();
}

fn writeEdits(s: *Stringify, cs: *const ChangeSet) Stringify.Error!void {
    try s.beginArray();
    for (cs.replaces) |r| {
        try s.beginArray();
        try s.write(r.range.start);
        try s.write(r.range.end);
        try s.write(r.text);
        try s.endArray();
    }
    try s.endArray();
}

// ---------------------------------------------------------------- decode

/// Rebuilds a changeset from its snapshot. Strings are copied into the
/// changeset's arena; `blobs` serves large edits.
pub fn readChangeset(gpa: Allocator, v: Value, blobs: model.Blobs) anyerror!*Changeset {
    const o = try obj(v);
    const cs = try gpa.create(Changeset);
    errdefer gpa.destroy(cs);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const a = arena.allocator();
    const files_v = try arr(get(o, "files") orelse return error.InvalidRecord);
    const files = a.alloc(FileChange, files_v.items.len) catch |e| {
        arena.deinit();
        return e;
    };
    var built: usize = 0;
    errdefer {
        for (files[0..built]) |*f| f.deinitContent();
        arena.deinit();
    }
    for (files, files_v.items) |*f, fv| {
        f.* = try readFile(gpa, a, fv, blobs);
        built += 1;
    }
    cs.* = .{
        .id = @enumFromInt(try int(u64, get(o, "id"))),
        .prov = try model.parseProvenanceJson(a, get(o, "prov") orelse return error.InvalidRecord),
        .files = files,
        .state = try enumOf(model.State, get(o, "state")),
        .revision = try int(u16, get(o, "revision")),
        .supersedes = if (get(o, "supersedes")) |x| @enumFromInt(try int(u64, x)) else null,
        .checkpoint = if (get(o, "checkpoint")) |x| try int(u64, x) else null,
        .auto_applied = if (get(o, "auto_applied")) |x| x == .bool and x.bool else false,
        .presentation = try enumOf(model.Presentation, get(o, "presentation")),
        .created_ms = try int(i64, get(o, "created_ms")),
        .decided_ms = if (get(o, "decided_ms")) |x| try int(i64, x) else null,
        .arena = arena.state,
    };
    return cs;
}

fn readFile(gpa: Allocator, a: Allocator, v: Value, blobs: model.Blobs) anyerror!FileChange {
    const o = try obj(v);
    var f: FileChange = .{ .path = try dupe(a, get(o, "path")), .op = .modify, .content = .none };
    const op = try obj(get(o, "op") orelse return error.InvalidRecord);
    f.op = switch (try enumOf(std.meta.Tag(model.FileOp), get(op, "type"))) {
        .create => .{ .create = .{ .executable = try boolean(get(op, "executable")) } },
        .modify => .modify,
        .delete => .delete,
        .rename => .{ .rename = .{ .from = try dupe(a, get(op, "from")) } },
        .set_executable => .{ .set_executable = try boolean(get(op, "on")) },
    };
    f.state = try enumOf(model.FileState, get(o, "state"));
    if (get(o, "base")) |b| f.base = try readBase(b);
    if (get(o, "folded_from")) |ff| {
        const items = (try arr(ff)).items;
        const out = try a.alloc(model.ChangesetId, items.len);
        for (out, items) |*d, x| d.* = @enumFromInt(try int(u64, x));
        f.folded_from = out;
    }
    if (get(o, "previous")) |x| f.previous = try unhex(x);
    const c = try obj(get(o, "content") orelse return error.InvalidRecord);
    switch (try enumOf(std.meta.Tag(model.Content), get(c, "type"))) {
        .none => {},
        .text => {
            const base_len = try int(u64, get(c, "base_len"));
            var scratch: std.heap.ArenaAllocator = .init(gpa);
            defer scratch.deinit();
            const edits_v: Value = if (get(c, "edits")) |e| e else blk: {
                const h = try unhex(get(c, "edits_blob"));
                const bytes = (try blobs.get(scratch.allocator(), h)) orelse return error.InvalidRecord;
                break :blk try std.json.parseFromSliceLeaky(Value, scratch.allocator(), bytes, .{});
            };
            const items = (try arr(edits_v)).items;
            const reps = try scratch.allocator().alloc(Replace, items.len);
            for (reps, items) |*r, x| {
                const t = (try arr(x)).items;
                if (t.len != 3) return error.InvalidRecord;
                r.* = .{ .range = .{ .start = try int(u64, t[0]), .end = try int(u64, t[1]) }, .text = try str(t[2]) };
            }
            const edits = ChangeSet.fromEdits(gpa, base_len, reps) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidRecord,
            };
            f.content = .{ .text = .{ .base = if (get(c, "base")) |b| try readBase(b) else null, .edits = edits } };
        },
        .binary => f.content = .{ .binary = .{
            .base = if (get(c, "base")) |b| try unhex(b) else null,
            .new = try unhex(get(c, "new")),
            .new_size = try int(u64, get(c, "new_size")),
        } },
    }
    errdefer f.deinitContent();
    const hs = (try arr(get(o, "hunks") orelse return error.InvalidRecord)).items;
    const hunks = try a.alloc(model.Hunk, hs.len);
    for (hunks, hs, 0..) |*h, hv, i| {
        const t = (try arr(hv)).items;
        if (t.len != 8 and t.len != 9) return error.InvalidRecord;
        const dec = try int(u8, t[6]);
        if (dec > @intFromEnum(model.Decision.edited)) return error.InvalidRecord;
        h.* = .{
            .id = @intCast(i),
            .base_lines = .{ .start = try int(u32, t[0]), .count = try int(u32, t[1]) },
            .new_lines = .{ .start = try int(u32, t[2]), .count = try int(u32, t[3]) },
            .replace_span = .{ try int(u32, t[4]), try int(u32, t[5]) },
            .decision = @enumFromInt(dec),
            .key = std.fmt.parseInt(u64, try str(t[7]), 16) catch return error.InvalidRecord,
        };
        if (t.len == 9) {
            const co = try obj(t[8]);
            h.conflict = .{
                .kind = try enumOf(model.ConflictKind, get(co, "kind")),
                .other = if (get(co, "other")) |x| @enumFromInt(try int(u64, x)) else null,
                .ours_lines = .{ .start = try int(u32, get(co, "start")), .count = try int(u32, get(co, "count")) },
                .theirs_text = try dupe(a, get(co, "theirs")),
            };
        }
    }
    f.hunks = hunks;
    return f;
}

fn readBase(v: Value) Error!model.BaseRef {
    const o = try obj(v);
    return .{
        .hash = try unhex(get(o, "hash")),
        .size = try int(u64, get(o, "size")),
        .doc_version = if (get(o, "doc_version")) |x| try int(u64, x) else null,
        .eol = try enumOf(model.Eol, get(o, "eol")),
    };
}

fn get(o: std.json.ObjectMap, k: []const u8) ?Value {
    const v = o.get(k) orelse return null;
    return if (v == .null) null else v;
}

fn obj(v: Value) Error!std.json.ObjectMap {
    return if (v == .object) v.object else error.InvalidRecord;
}

fn arr(v: Value) Error!std.json.Array {
    return if (v == .array) v.array else error.InvalidRecord;
}

fn str(v: Value) Error![]const u8 {
    return if (v == .string) v.string else error.InvalidRecord;
}

fn dupe(a: Allocator, v: ?Value) Error![]const u8 {
    return a.dupe(u8, try str(v orelse return error.InvalidRecord));
}

fn boolean(v: ?Value) Error!bool {
    const x = v orelse return error.InvalidRecord;
    return if (x == .bool) x.bool else error.InvalidRecord;
}

fn int(comptime T: type, v: ?Value) Error!T {
    const x = v orelse return error.InvalidRecord;
    return switch (x) {
        .integer => |i| std.math.cast(T, i) orelse error.InvalidRecord,
        .number_string => |s| std.fmt.parseInt(T, s, 10) catch error.InvalidRecord,
        else => error.InvalidRecord,
    };
}

fn enumOf(comptime E: type, v: ?Value) Error!E {
    return std.meta.stringToEnum(E, try str(v orelse return error.InvalidRecord)) orelse error.InvalidRecord;
}

fn unhex(v: ?Value) Error!BlobHash {
    const s = try str(v orelse return error.InvalidRecord);
    var h: BlobHash = undefined;
    if (s.len != 64) return error.InvalidRecord;
    _ = std.fmt.hexToBytes(&h, s) catch return error.InvalidRecord;
    return h;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn roundTrip(q: *model.Queue, mem: *model.MemBlobs, id: model.ChangesetId) !void {
    const cs = q.get(id).?;
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeChangeset(&aw.writer, cs, mem.blobs(), testing.allocator);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(Value, arena.allocator(), aw.written(), .{});
    const back = try readChangeset(testing.allocator, v, mem.blobs());
    defer {
        back.deinit(testing.allocator);
        testing.allocator.destroy(back);
    }
    var aw2: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw2.deinit();
    try writeChangeset(&aw2.writer, back, mem.blobs(), testing.allocator);
    try testing.expectEqualStrings(aw.written(), aw2.written());
}

test "store: changeset record round trip" {
    var mem: model.MemBlobs = .init(testing.allocator);
    defer mem.deinit();
    const q = try model.Queue.init(testing.allocator, testing.io, .{ .root = "/w", .blobs = mem.blobs() });
    defer q.deinit();
    const b = try q.beginBatch(.{ .origin = .{ .agent = .{ .ref = .{ .session = 77, .tool_call = "c1" }, .turn = 3, .model = "m" } }, .label = "Turn 3: x", .workspace = "/w", .created_ms = 1 });
    var e: ChangeSet = try .fromEdits(testing.allocator, 6, &.{.{ .range = .{ .start = 0, .end = 1 }, .text = "A\"\n" }});
    defer e.deinit();
    try q.addEdit(b, "a.txt", "a\nb\nc\n", 3, &e);
    try q.addCreate(b, "big.txt", "x" ** (inline_limit + 1));
    try q.addDelete(b, "gone", "bye");
    try q.addRename(b, "r1", "r2");
    try q.setExecutable(b, "run", true);
    const id = try q.commitBatch(b, .{ .checkpoint = 4, .presentation = .inline_ });
    q.getMut(id).?.files[0].hunks[0].decision = .rejected;
    try roundTrip(q, &mem, id);
    q.getMut(id).?.files[0].hunks[0].conflict = .{ .kind = .sibling_changeset, .other = @enumFromInt(3), .ours_lines = .{ .start = 0, .count = 1 }, .theirs_text = "x\n" };
    try roundTrip(q, &mem, id);
}

test "records: apply record round trip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_]model.ApplyFile{
        .{ .path = "a/b.txt", .from = "old.txt", .pre = model.blobHash("x"), .post = model.blobHash("y"), .post_exec = true },
        .{ .path = "gone.txt", .pre = model.blobHash("z"), .post = null, .pre_exec = true },
    };
    const closed = [_]model.Closed{ .{ .cs = @enumFromInt(5), .from = .pending }, .{ .cs = @enumFromInt(6), .from = .partially_applied } };
    const in: model.Apply = .{ .id = 4, .kind = .undo, .cs = @enumFromInt(9), .undoes = 2, .session = 77, .created_ms = 1234, .files = &files, .closed = &closed };
    var aw: std.Io.Writer.Allocating = .init(a);
    try writeApply(&aw.writer, &in);
    const v = try std.json.parseFromSliceLeaky(Value, a, aw.written(), .{});
    const out = try readApply(a, v);
    try testing.expectEqual(in.id, out.id);
    try testing.expectEqual(in.kind, out.kind);
    try testing.expectEqual(in.cs, out.cs);
    try testing.expectEqual(in.undoes, out.undoes);
    try testing.expectEqual(in.session, out.session);
    try testing.expectEqual(in.created_ms, out.created_ms);
    try testing.expectEqualSlices(model.Closed, &closed, out.closed);
    try testing.expectEqual(@as(usize, 2), out.files.len);
    for (files, out.files) |x, y| {
        try testing.expectEqualStrings(x.path, y.path);
        if (x.from) |f| try testing.expectEqualStrings(f, y.from.?) else try testing.expectEqual(@as(?[]const u8, null), y.from);
        try testing.expectEqual(x.pre, y.pre);
        try testing.expectEqual(x.post, y.post);
        try testing.expectEqual(x.pre_exec, y.pre_exec);
        try testing.expectEqual(x.post_exec, y.post_exec);
    }
}

test "records: checkpoint round trip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const in: model.Checkpoint = .{ .id = 3, .session = 99, .agent = 2, .turn = 7, .label = "Fix it", .created_ms = 5, .after_apply = 11, .next_changeset = 4, .pinned = true };
    var aw: std.Io.Writer.Allocating = .init(a);
    try writeCheckpoint(&aw.writer, &in);
    const out = try readCheckpoint(a, try std.json.parseFromSliceLeaky(Value, a, aw.written(), .{}));
    try testing.expectEqualStrings(in.label, out.label);
    var x = out;
    x.label = in.label;
    try testing.expectEqual(in, x);
}
