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
const pull = @import("../model/pull.zig");

const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const Value = std.json.Value;
const Changeset = model.Changeset;
const FileChange = model.FileChange;
const ChangeSet = model.changeset.ChangeSet;
const Replace = model.changeset.Replace;
const BlobHash = model.BlobHash;
const Tokens = pull.Pull;

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
pub fn writeDecided(w: *std.Io.Writer, d: *const model.Decided) Stringify.Error!void {
    var s: Stringify = .{ .writer = w };
    try s.beginObject();
    try field(&s, "cs", @intFromEnum(d.cs));
    if (d.apply) |x| try field(&s, "apply", x);
    try s.objectField("files");
    try s.beginArray();
    for (d.files) |f| {
        try s.beginObject();
        try field(&s, "path", f.path);
        try s.objectField("hunks");
        try s.beginArray();
        for (f.hunks) |h| {
            try s.beginArray();
            try s.write(h.hunk);
            try s.write(@tagName(h.decision));
            try s.endArray();
        }
        try s.endArray();
        if (f.edits.len > 0) {
            try s.objectField("edits");
            try s.beginArray();
            for (f.edits) |e| {
                try s.beginObject();
                try field(&s, "hunk", e.hunk);
                try field(&s, "proposed", e.proposed);
                try field(&s, "user", e.user);
                try s.endObject();
            }
            try s.endArray();
        }
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
}

pub fn readDecided(arena: Allocator, v: Value) Error!model.Decided {
    const o = try obj(v);
    const fs = try arr(get(o, "files") orelse return error.InvalidRecord);
    const files = try arena.alloc(model.FileDecisions, fs.items.len);
    for (fs.items, files) |fv, *f| {
        const fo = try obj(fv);
        const hs = try arr(get(fo, "hunks") orelse return error.InvalidRecord);
        const hunks = try arena.alloc(model.HunkDecision, hs.items.len);
        for (hs.items, hunks) |hv, *h| {
            const pair = try arr(hv);
            if (pair.items.len != 2) return error.InvalidRecord;
            h.* = .{ .hunk = try int(u32, pair.items[0]), .decision = try enumOf(model.Decision, pair.items[1]) };
        }
        var edits: []model.HunkEdit = &.{};
        if (get(fo, "edits")) |ev| {
            const es = try arr(ev);
            edits = try arena.alloc(model.HunkEdit, es.items.len);
            for (es.items, edits) |x, *e| {
                const eo = try obj(x);
                e.* = .{ .hunk = try int(u32, get(eo, "hunk")), .proposed = try dupe(arena, get(eo, "proposed")), .user = try dupe(arena, get(eo, "user")) };
            }
        }
        f.* = .{ .path = try dupe(arena, get(fo, "path")), .hunks = hunks, .edits = edits };
    }
    return .{
        .cs = @enumFromInt(try int(u64, get(o, "cs"))),
        .apply = if (get(o, "apply")) |x| try int(u64, x) else null,
        .files = files,
    };
}

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

/// Rebuilds a changeset from its snapshot's JSON text. Strings are copied
/// into the changeset's arena; `blobs` serves large edits. A cold load
/// decodes every snapshot, so this pulls tokens instead of building a
/// `std.json.Value` tree (E12.F01.S02 load budget).
pub fn readChangeset(gpa: Allocator, json: []const u8, blobs: model.Blobs) anyerror!*Changeset {
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const sa = scratch.allocator();
    var t: Tokens = .init(sa, json);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    const a = arena.allocator();
    var files: std.ArrayList(FileChange) = .empty;
    errdefer {
        for (files.items) |*f| f.deinitContent();
        arena.deinit();
    }
    var id: ?u64 = null;
    var prov: ?model.Provenance = null;
    var state: ?model.State = null;
    var revision: ?u16 = null;
    var presentation: ?model.Presentation = null;
    var created_ms: ?i64 = null;
    var have_files = false;
    var cs: Changeset = undefined;
    cs.supersedes = null;
    cs.checkpoint = null;
    cs.auto_applied = false;
    cs.decided_ms = null;
    try t.expect(.object_begin);
    while (try t.key()) |k| {
        if (try t.isNull()) continue;
        if (eql(k, "id")) {
            id = try t.int(u64);
        } else if (eql(k, "prov")) {
            prov = try model.provenance.readProvenance(a, &t);
        } else if (eql(k, "state")) {
            state = try t.enumOf(model.State);
        } else if (eql(k, "revision")) {
            revision = try t.int(u16);
        } else if (eql(k, "supersedes")) {
            cs.supersedes = @enumFromInt(try t.int(u64));
        } else if (eql(k, "checkpoint")) {
            cs.checkpoint = try t.int(u64);
        } else if (eql(k, "auto_applied")) {
            cs.auto_applied = try t.boolean();
        } else if (eql(k, "presentation")) {
            presentation = try t.enumOf(model.Presentation);
        } else if (eql(k, "created_ms")) {
            created_ms = try t.int(i64);
        } else if (eql(k, "decided_ms")) {
            cs.decided_ms = try t.int(i64);
        } else if (eql(k, "files")) {
            if (have_files) return error.InvalidRecord;
            have_files = true;
            try t.expect(.array_begin);
            while (try t.more()) {
                var f = try readFile(gpa, a, &t, blobs);
                files.append(sa, f) catch |e| {
                    f.deinitContent();
                    return e;
                };
            }
        } else try t.skip();
    }
    try t.expect(.end);
    if (!have_files) return error.InvalidRecord;
    cs.id = @enumFromInt(id orelse return error.InvalidRecord);
    cs.prov = prov orelse return error.InvalidRecord;
    cs.state = state orelse return error.InvalidRecord;
    cs.revision = revision orelse return error.InvalidRecord;
    cs.presentation = presentation orelse return error.InvalidRecord;
    cs.created_ms = created_ms orelse return error.InvalidRecord;
    cs.files = try a.dupe(FileChange, files.items);
    const out = try gpa.create(Changeset);
    cs.arena = arena.state;
    out.* = cs;
    return out;
}

fn readFile(gpa: Allocator, a: Allocator, t: *Tokens, blobs: model.Blobs) anyerror!FileChange {
    var f: FileChange = .{ .path = "", .op = .modify, .content = .none };
    errdefer f.deinitContent();
    var path: ?[]const u8 = null;
    var op: ?model.FileOp = null;
    var state: ?model.FileState = null;
    var hunks: ?[]model.Hunk = null;
    var have_content = false;
    try t.expect(.object_begin);
    while (try t.key()) |k| {
        if (try t.isNull()) continue;
        if (eql(k, "path")) {
            path = try a.dupe(u8, try t.str());
        } else if (eql(k, "op")) {
            op = try readOp(a, t);
        } else if (eql(k, "state")) {
            state = try t.enumOf(model.FileState);
        } else if (eql(k, "base")) {
            f.base = try readBase(t);
        } else if (eql(k, "folded_from")) {
            var ids: std.ArrayList(model.ChangesetId) = .empty;
            try t.expect(.array_begin);
            while (try t.more()) try ids.append(t.a, @enumFromInt(try t.int(u64)));
            f.folded_from = try a.dupe(model.ChangesetId, ids.items);
        } else if (eql(k, "previous")) {
            f.previous = try readHash(t);
        } else if (eql(k, "content")) {
            if (have_content) return error.InvalidRecord;
            have_content = true;
            f.content = try readContent(gpa, t, blobs);
        } else if (eql(k, "hunks")) {
            hunks = try readHunks(a, t);
        } else try t.skip();
    }
    if (!have_content) return error.InvalidRecord;
    f.path = path orelse return error.InvalidRecord;
    f.op = op orelse return error.InvalidRecord;
    f.state = state orelse return error.InvalidRecord;
    f.hunks = hunks orelse return error.InvalidRecord;
    return f;
}

fn readOp(a: Allocator, t: *Tokens) Error!model.FileOp {
    var kind: ?std.meta.Tag(model.FileOp) = null;
    var flag: ?bool = null;
    var from: ?[]const u8 = null;
    try t.expect(.object_begin);
    while (try t.key()) |k| {
        if (try t.isNull()) continue;
        if (eql(k, "type")) {
            kind = try t.enumOf(std.meta.Tag(model.FileOp));
        } else if (eql(k, "executable") or eql(k, "on")) {
            flag = try t.boolean();
        } else if (eql(k, "from")) {
            from = try a.dupe(u8, try t.str());
        } else try t.skip();
    }
    return switch (kind orelse return error.InvalidRecord) {
        .create => .{ .create = .{ .executable = flag orelse return error.InvalidRecord } },
        .modify => .modify,
        .delete => .delete,
        .rename => .{ .rename = .{ .from = from orelse return error.InvalidRecord } },
        .set_executable => .{ .set_executable = flag orelse return error.InvalidRecord },
    };
}

/// The `content` object. `base` is a `BaseRef` object for text and a
/// hash for binaries.
fn readContent(gpa: Allocator, t: *Tokens, blobs: model.Blobs) anyerror!model.Content {
    var kind: ?std.meta.Tag(model.Content) = null;
    var base_ref: ?model.BaseRef = null;
    var base_hash: ?BlobHash = null;
    var base_len: ?u64 = null;
    var edits: ?[]Replace = null;
    var edits_blob: ?BlobHash = null;
    var new: ?BlobHash = null;
    var new_size: ?u64 = null;
    try t.expect(.object_begin);
    while (try t.key()) |k| {
        if (try t.isNull()) continue;
        if (eql(k, "type")) {
            kind = try t.enumOf(std.meta.Tag(model.Content));
        } else if (eql(k, "base")) {
            if (try t.peek() == .object_begin) base_ref = try readBase(t) else base_hash = try readHash(t);
        } else if (eql(k, "base_len")) {
            base_len = try t.int(u64);
        } else if (eql(k, "edits")) {
            edits = try readEdits(t);
        } else if (eql(k, "edits_blob")) {
            edits_blob = try readHash(t);
        } else if (eql(k, "new")) {
            new = try readHash(t);
        } else if (eql(k, "new_size")) {
            new_size = try t.int(u64);
        } else try t.skip();
    }
    switch (kind orelse return error.InvalidRecord) {
        .none => return .none,
        .text => {
            const reps = edits orelse blk: {
                const bytes = (try blobs.get(t.a, edits_blob orelse return error.InvalidRecord)) orelse return error.InvalidRecord;
                var bt: Tokens = .init(t.a, bytes);
                const r = try readEdits(&bt);
                try bt.expect(.end);
                break :blk r;
            };
            const cs = ChangeSet.fromEdits(gpa, base_len orelse return error.InvalidRecord, reps) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidRecord,
            };
            return .{ .text = .{ .base = base_ref, .edits = cs } };
        },
        .binary => return .{ .binary = .{
            .base = base_hash,
            .new = new orelse return error.InvalidRecord,
            .new_size = new_size orelse return error.InvalidRecord,
        } },
    }
}

/// `[[start, end, "text"], ...]`, in `t`'s scratch.
fn readEdits(t: *Tokens) Error![]Replace {
    var reps: std.ArrayList(Replace) = .empty;
    try t.expect(.array_begin);
    while (try t.more()) {
        try t.expect(.array_begin);
        const start = try t.int(u64);
        const end = try t.int(u64);
        const text = try t.str();
        try t.expect(.array_end);
        try reps.append(t.a, .{ .range = .{ .start = start, .end = end }, .text = text });
    }
    return reps.items;
}

fn readHunks(a: Allocator, t: *Tokens) Error![]model.Hunk {
    var hunks: std.ArrayList(model.Hunk) = .empty;
    try t.expect(.array_begin);
    while (try t.more()) {
        try t.expect(.array_begin);
        var n: [7]u32 = undefined;
        for (&n) |*x| x.* = try t.int(u32);
        if (n[6] > @intFromEnum(model.Decision.edited)) return error.InvalidRecord;
        var h: model.Hunk = .{
            .id = @intCast(hunks.items.len),
            .base_lines = .{ .start = n[0], .count = n[1] },
            .new_lines = .{ .start = n[2], .count = n[3] },
            .replace_span = .{ n[4], n[5] },
            .decision = @enumFromInt(n[6]),
            .key = std.fmt.parseInt(u64, try t.str(), 16) catch return error.InvalidRecord,
        };
        if (try t.more()) {
            h.conflict = try readConflict(a, t);
            try t.expect(.array_end);
        }
        try hunks.append(t.a, h);
    }
    return a.dupe(model.Hunk, hunks.items);
}

fn readConflict(a: Allocator, t: *Tokens) Error!model.ConflictInfo {
    var kind: ?model.ConflictKind = null;
    var other: ?model.ChangesetId = null;
    var start: ?u32 = null;
    var count: ?u32 = null;
    var theirs: ?[]const u8 = null;
    try t.expect(.object_begin);
    while (try t.key()) |k| {
        if (try t.isNull()) continue;
        if (eql(k, "kind")) {
            kind = try t.enumOf(model.ConflictKind);
        } else if (eql(k, "other")) {
            other = @enumFromInt(try t.int(u64));
        } else if (eql(k, "start")) {
            start = try t.int(u32);
        } else if (eql(k, "count")) {
            count = try t.int(u32);
        } else if (eql(k, "theirs")) {
            theirs = try a.dupe(u8, try t.str());
        } else try t.skip();
    }
    return .{
        .kind = kind orelse return error.InvalidRecord,
        .other = other,
        .ours_lines = .{ .start = start orelse return error.InvalidRecord, .count = count orelse return error.InvalidRecord },
        .theirs_text = theirs orelse return error.InvalidRecord,
    };
}

fn readBase(t: *Tokens) Error!model.BaseRef {
    var hash: ?BlobHash = null;
    var size: ?u64 = null;
    var doc_version: ?u64 = null;
    var eol: ?model.Eol = null;
    try t.expect(.object_begin);
    while (try t.key()) |k| {
        if (try t.isNull()) continue;
        if (eql(k, "hash")) {
            hash = try readHash(t);
        } else if (eql(k, "size")) {
            size = try t.int(u64);
        } else if (eql(k, "doc_version")) {
            doc_version = try t.int(u64);
        } else if (eql(k, "eol")) {
            eol = try t.enumOf(model.Eol);
        } else try t.skip();
    }
    return .{
        .hash = hash orelse return error.InvalidRecord,
        .size = size orelse return error.InvalidRecord,
        .doc_version = doc_version,
        .eol = eol orelse return error.InvalidRecord,
    };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn readHash(t: *Tokens) Error!BlobHash {
    const s = try t.str();
    var h: BlobHash = undefined;
    if (s.len != 64) return error.InvalidRecord;
    _ = std.fmt.hexToBytes(&h, s) catch return error.InvalidRecord;
    return h;
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
    const back = try readChangeset(testing.allocator, aw.written(), mem.blobs());
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
    q.getMut(id).?.files[1].folded_from = &.{ @enumFromInt(2), @enumFromInt(3) };
    try roundTrip(q, &mem, id);
    q.getMut(id).?.files[0].hunks[0].conflict = .{ .kind = .sibling_changeset, .other = @enumFromInt(3), .ours_lines = .{ .start = 0, .count = 1 }, .theirs_text = "x\n" };
    try roundTrip(q, &mem, id);
}

test "records: changeset decoder takes keys in any order, nulls as absent" {
    var mem: model.MemBlobs = .init(testing.allocator);
    defer mem.deinit();
    const json =
        \\{"files":[{"hunks":[[0,1,0,1,0,1,2,"00000000000000ff",{"theirs":"t\n","count":1,"start":0,"kind":"sibling_changeset"}]],
        \\"content":{"edits":[[0,1,"A\u0022"]],"base_len":2,"type":"text","base":null},"previous":null,"op":{"from":"old","type":"rename"},
        \\"state":"pending","path":"p\/q","extra":[1,{"x":null}]}],"created_ms":-5,"presentation":"queue","revision":2,"state":"pending","supersedes":null,
        \\"prov":{"workspace":"/w","label":"l","origin":{"type":"search_replace","query":"foo"},"created_ms":0},"id":12}
    ;
    const cs = try readChangeset(testing.allocator, json, mem.blobs());
    defer {
        cs.deinit(testing.allocator);
        testing.allocator.destroy(cs);
    }
    try testing.expectEqual(@as(u64, 12), @intFromEnum(cs.id));
    try testing.expectEqual(@as(i64, -5), cs.created_ms);
    try testing.expectEqual(@as(?model.ChangesetId, null), cs.supersedes);
    const f = cs.files[0];
    try testing.expectEqualStrings("p/q", f.path);
    try testing.expectEqualStrings("old", f.op.rename.from);
    try testing.expectEqualStrings("A\"", f.content.text.edits.replaces[0].text);
    try testing.expectEqual(@as(u64, 0xff), f.hunks[0].key);
    try testing.expectEqual(model.Decision.rejected, f.hunks[0].decision);
    try testing.expectEqualStrings("t\n", f.hunks[0].conflict.?.theirs_text);
    // Missing fields, wrong types and trailing text are refused.
    for ([_][]const u8{ "{}", "{\"files\":[]}", "[1]", json ++ "1", "{\"id\":\"1\"}" }) |bad| {
        try testing.expectError(error.InvalidRecord, readChangeset(testing.allocator, bad, mem.blobs()));
    }
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
