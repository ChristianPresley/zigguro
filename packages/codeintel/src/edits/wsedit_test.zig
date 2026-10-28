//! Workspace edit engine tests (E07.F04.S02.T01) over an in-memory file
//! system.

const std = @import("std");
const testing = std.testing;
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const plan_mod = @import("plan.zig");
const Engine = @import("Engine.zig");

const Allocator = std.mem.Allocator;
const protocol = zg_lsp.protocol;
const DocumentRegistry = zg_editor.model.api.registry.DocumentRegistry;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const EditPlan = plan_mod.EditPlan;

/// Files and folders in memory; `fail_*` inject failures.
pub const MemFs = struct {
    const Trashed = struct { rel: []u8, bytes: []u8 };

    gpa: Allocator,
    /// Path -> bytes (files). Folders are implied by their files, plus
    /// `dirs`.
    files: std.StringArrayHashMapUnmanaged([]u8) = .empty,
    dirs: std.StringArrayHashMapUnmanaged(void) = .empty,
    /// Token -> the files trashed under it (paths relative to the root).
    trashed: std.StringArrayHashMapUnmanaged(std.ArrayList(Trashed)) = .empty,
    next_token: u32 = 0,
    fail_move: bool = false,
    fail_write: ?[]const u8 = null,
    writes: u32 = 0,

    pub fn deinit(m: *MemFs) void {
        for (m.files.keys(), m.files.values()) |k, v| {
            m.gpa.free(k);
            m.gpa.free(v);
        }
        m.files.deinit(m.gpa);
        for (m.dirs.keys()) |k| m.gpa.free(k);
        m.dirs.deinit(m.gpa);
        for (m.trashed.keys(), m.trashed.values()) |k, *l| {
            m.gpa.free(k);
            for (l.items) |it| {
                m.gpa.free(it.rel);
                m.gpa.free(it.bytes);
            }
            l.deinit(m.gpa);
        }
        m.trashed.deinit(m.gpa);
    }

    pub fn put(m: *MemFs, path: []const u8, bytes: []const u8) !void {
        const gop = try m.files.getOrPut(m.gpa, path);
        if (gop.found_existing) {
            m.gpa.free(gop.value_ptr.*);
        } else gop.key_ptr.* = try m.gpa.dupe(u8, path);
        gop.value_ptr.* = try m.gpa.dupe(u8, bytes);
    }

    pub fn get(m: *const MemFs, path: []const u8) ?[]const u8 {
        return m.files.get(path);
    }

    pub fn ops(m: *MemFs) plan_mod.FileOps {
        return .{ .ctx = m, .vtable = &vtable };
    }

    const vtable: plan_mod.FileOps.VTable = .{
        .kind = kind,
        .read = read,
        .write = write,
        .move = move,
        .trash = trash,
        .restore = restore,
        .forget = forget,
    };

    fn self(ctx: *anyopaque) *MemFs {
        return @ptrCast(@alignCast(ctx));
    }

    fn under(path: []const u8, dir: []const u8) bool {
        return path.len > dir.len and std.mem.startsWith(u8, path, dir) and path[dir.len] == '/';
    }

    fn kind(ctx: *anyopaque, path: []const u8) ?plan_mod.FileKind {
        const m = self(ctx);
        if (m.files.contains(path)) return .file;
        if (m.dirs.contains(path)) return .dir;
        for (m.files.keys()) |k| if (under(k, path)) return .dir;
        return null;
    }

    fn read(ctx: *anyopaque, gpa: Allocator, path: []const u8) anyerror![]u8 {
        const b = self(ctx).files.get(path) orelse return error.FileNotFound;
        return gpa.dupe(u8, b);
    }

    fn write(ctx: *anyopaque, path: []const u8, bytes: []const u8) anyerror!void {
        const m = self(ctx);
        if (m.fail_write) |f| if (std.mem.eql(u8, f, path)) return error.AccessDenied;
        m.writes += 1;
        try m.put(path, bytes);
    }

    fn move(ctx: *anyopaque, old: []const u8, new: []const u8) anyerror!void {
        const m = self(ctx);
        if (m.fail_move) return error.AccessDenied;
        if (kind(ctx, new) != null) return error.PathAlreadyExists;
        if (m.files.fetchSwapRemove(old)) |kv| {
            m.gpa.free(kv.key);
            try m.files.put(m.gpa, try m.gpa.dupe(u8, new), kv.value);
            return;
        }
        if (kind(ctx, old) != .dir) return error.FileNotFound;
        var i: usize = 0;
        while (i < m.files.count()) {
            const k = m.files.keys()[i];
            if (under(k, old)) {
                const v = m.files.values()[i];
                const nk = try std.mem.concat(m.gpa, u8, &.{ new, k[old.len..] });
                m.files.swapRemoveAt(i);
                m.gpa.free(k);
                try m.files.put(m.gpa, nk, v);
                i = 0;
                continue;
            }
            i += 1;
        }
        if (m.dirs.fetchSwapRemove(old)) |kv| m.gpa.free(kv.key);
        try m.dirs.put(m.gpa, try m.gpa.dupe(u8, new), {});
    }

    fn trash(ctx: *anyopaque, gpa: Allocator, path: []const u8) anyerror![]u8 {
        const m = self(ctx);
        if (kind(ctx, path) == null) return error.FileNotFound;
        var list: std.ArrayList(Trashed) = .empty;
        var i: usize = 0;
        while (i < m.files.count()) {
            const k = m.files.keys()[i];
            if (std.mem.eql(u8, k, path) or under(k, path)) {
                try list.append(m.gpa, .{ .rel = try m.gpa.dupe(u8, k[path.len..]), .bytes = m.files.values()[i] });
                m.files.swapRemoveAt(i);
                m.gpa.free(k);
                continue;
            }
            i += 1;
        }
        if (m.dirs.fetchSwapRemove(path)) |kv| m.gpa.free(kv.key);
        const tok = try std.fmt.allocPrint(m.gpa, "t{d}", .{m.next_token});
        m.next_token += 1;
        try m.trashed.put(m.gpa, tok, list);
        return gpa.dupe(u8, tok);
    }

    fn restore(ctx: *anyopaque, token: []const u8, path: []const u8) anyerror!void {
        const m = self(ctx);
        var kv = m.trashed.fetchSwapRemove(token) orelse return error.FileNotFound;
        defer {
            m.gpa.free(kv.key);
            kv.value.deinit(m.gpa);
        }
        for (kv.value.items) |it| {
            const p = try std.mem.concat(m.gpa, u8, &.{ path, it.rel });
            defer m.gpa.free(p);
            try m.put(p, it.bytes);
            m.gpa.free(it.rel);
            m.gpa.free(it.bytes);
        }
    }

    fn forget(ctx: *anyopaque, token: []const u8) void {
        const m = self(ctx);
        var kv = m.trashed.fetchSwapRemove(token) orelse return;
        for (kv.value.items) |it| {
            m.gpa.free(it.rel);
            m.gpa.free(it.bytes);
        }
        kv.value.deinit(m.gpa);
        m.gpa.free(kv.key);
    }
};

const Fixture = struct {
    fs: MemFs,
    docs: DocumentRegistry,
    engine: Engine,
    held: std.ArrayList(DocHandle) = .empty,

    fn init(f: *Fixture) void {
        f.* = .{ .fs = .{ .gpa = testing.allocator }, .docs = .init(testing.allocator, .posix), .engine = undefined };
        f.engine = .init(testing.allocator, &f.docs, f.fs.ops(), .{});
    }

    fn deinit(f: *Fixture) void {
        f.engine.deinit();
        for (f.held.items) |h| f.docs.release(h);
        f.held.deinit(testing.allocator);
        f.docs.deinit();
        f.fs.deinit();
    }

    /// Opens `path` as an open editor document.
    fn open(f: *Fixture, path: []const u8, contents: []const u8) !DocHandle {
        const h = try f.docs.openFile(path, contents);
        try f.held.append(testing.allocator, h);
        return h;
    }

    fn text(f: *Fixture, h: DocHandle) ![]u8 {
        const d = f.docs.get(h).?;
        return d.tree.copyRange(testing.allocator, .{ .start = 0, .end = d.len() });
    }

    fn expectText(f: *Fixture, h: DocHandle, want: []const u8) !void {
        const t = try f.text(h);
        defer testing.allocator.free(t);
        try testing.expectEqualStrings(want, t);
    }

    fn parse(json: []const u8) !std.json.Parsed(protocol.WorkspaceEdit) {
        return std.json.parseFromSlice(protocol.WorkspaceEdit, testing.allocator, json, .{ .ignore_unknown_fields = true });
    }

    fn planJson(f: *Fixture, json: []const u8, src: plan_mod.Source, fail: ?*plan_mod.Failure) !EditPlan {
        const parsed = try parse(json);
        defer parsed.deinit();
        return f.engine.plan(&parsed.value, src, "test", fail);
    }
};

test "wsedit: changes vs documentChanges preference" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const h = try f.open("/w/a.txt", "hello world\n");
    var p = try f.planJson(
        \\{"changes":{"file:///w/a.txt":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},"newText":"bye"}]},
        \\ "documentChanges":[{"textDocument":{"uri":"file:///w/a.txt","version":null},"edits":[{"range":{"start":{"line":0,"character":6},"end":{"line":0,"character":11}},"newText":"there"}]}]}
    , .{}, null);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.steps.len);
    const out = try f.engine.apply(&p, .user, .auto);
    try testing.expect(out == .applied);
    try f.expectText(h, "hello there\n");

    // `changes` alone.
    var p2 = try f.planJson(
        \\{"changes":{"file:///w/a.txt":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":5}},"newText":"bye"}]}}
    , .{}, null);
    defer p2.deinit();
    _ = try f.engine.apply(&p2, .user, .auto);
    try f.expectText(h, "bye there\n");
}

test "wsedit: version mismatch fails" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    _ = try f.open("/w/a.txt", "x\n");
    const Versions = struct {
        v: ?i32,
        fn get(ctx: *anyopaque, _: DocHandle) ?i32 {
            return @as(*@This(), @ptrCast(@alignCast(ctx))).v;
        }
    };
    var vs: Versions = .{ .v = 3 };
    const json =
        \\{"documentChanges":[{"textDocument":{"uri":"file:///w/a.txt","version":4},"edits":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"y"}]}]}
    ;
    var fail: plan_mod.Failure = undefined;
    try testing.expectError(error.VersionMismatch, f.planJson(json, .{ .versions = .{ .ctx = &vs, .f = Versions.get } }, &fail));
    try testing.expectEqual(@as(u32, 0), fail.index);
    // Unsent changes count as a mismatch too.
    vs.v = null;
    try testing.expectError(error.VersionMismatch, f.planJson(json, .{ .versions = .{ .ctx = &vs, .f = Versions.get } }, null));
    vs.v = 4;
    var p = try f.planJson(json, .{ .versions = .{ .ctx = &vs, .f = Versions.get } }, null);
    p.deinit();
}

test "wsedit: overlapping edits rejected" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    _ = try f.open("/w/a.txt", "abcdef\n");
    try testing.expectError(error.Overlap, f.planJson(
        \\{"changes":{"file:///w/a.txt":[
        \\ {"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},"newText":"x"},
        \\ {"range":{"start":{"line":0,"character":2},"end":{"line":0,"character":4}},"newText":"y"}]}}
    , .{}, null));
    // Inserts at one point keep their order; touching edits are fine.
    const h = (try f.docs.findFile("/w/a.txt")).?;
    var p = try f.planJson(
        \\{"changes":{"file:///w/a.txt":[
        \\ {"range":{"start":{"line":0,"character":3},"end":{"line":0,"character":6}},"newText":"Z"},
        \\ {"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"1"},
        \\ {"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"2"},
        \\ {"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},"newText":"Y"}]}}
    , .{}, null);
    defer p.deinit();
    _ = try f.engine.apply(&p, .user, .auto);
    try f.expectText(h, "12YZ\n");
}

test "wsedit: multi-file text edits apply + single undo" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const a = try f.open("/w/a.zig", "const foo = 1;\n");
    try f.fs.put("/w/b.zig", "_ = foo;\nfoo();\n");
    var p = try f.planJson(
        \\{"changes":{
        \\ "file:///w/a.zig":[{"range":{"start":{"line":0,"character":6},"end":{"line":0,"character":9}},"newText":"bar"}],
        \\ "file:///w/b.zig":[{"range":{"start":{"line":0,"character":4},"end":{"line":0,"character":7}},"newText":"bar"},
        \\                    {"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":3}},"newText":"bar"}]}}
    , .{}, null);
    defer p.deinit();
    try testing.expectEqual(@as(usize, 2), p.files.len);
    const out = try f.engine.apply(&p, .user, .auto);
    try f.expectText(a, "const bar = 1;\n");
    // The closed file was opened, edited, saved and closed again.
    try testing.expectEqualStrings("_ = bar;\nbar();\n", f.fs.get("/w/b.zig").?);
    try testing.expect((try f.docs.findFile("/w/b.zig")) == null);
    try testing.expectEqual(@as(usize, 2), f.engine.lastUndo().?.files);

    try f.engine.undo(out.applied.undo_id);
    try f.expectText(a, "const foo = 1;\n");
    try testing.expectEqualStrings("_ = foo;\nfoo();\n", f.fs.get("/w/b.zig").?);
    try testing.expect(f.engine.lastUndo() == null);
}

test "wsedit: undo refuses when a file changed since" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const a = try f.open("/w/a.txt", "one\n");
    var p = try f.planJson(
        \\{"changes":{"file:///w/a.txt":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},"newText":"two"}]}}
    , .{}, null);
    defer p.deinit();
    const out = try f.engine.apply(&p, .user, .auto);
    const d = f.docs.get(a).?;
    const edits = [_]plan_mod.Replace{.{ .range = .{ .start = 0, .end = 0 }, .text = "!" }};
    var cs = try zg_editor.model.edit.change_set.ChangeSet.fromEdits(testing.allocator, d.len(), &edits);
    defer cs.deinit();
    try d.applyChangeSet(&cs, .{ .user = 0 });
    try testing.expectError(error.Changed, f.engine.undo(out.applied.undo_id));
    try f.expectText(a, "!two\n");
}

test "wsedit: resource ops order create/rename/delete with flags" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.fs.put("/w/old.txt", "old\n");
    try f.fs.put("/w/gone.txt", "gone\n");
    try f.fs.put("/w/keep.txt", "keep\n");
    var p = try f.planJson(
        \\{"documentChanges":[
        \\ {"kind":"create","uri":"file:///w/new.txt"},
        \\ {"textDocument":{"uri":"file:///w/new.txt","version":null},"edits":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}},"newText":"fresh\n"}]},
        \\ {"kind":"create","uri":"file:///w/keep.txt","options":{"ignoreIfExists":true}},
        \\ {"kind":"rename","oldUri":"file:///w/old.txt","newUri":"file:///w/moved.txt"},
        \\ {"textDocument":{"uri":"file:///w/moved.txt","version":null},"edits":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},"newText":"OLD"}]},
        \\ {"kind":"delete","uri":"file:///w/gone.txt"},
        \\ {"kind":"delete","uri":"file:///w/never.txt","options":{"ignoreIfNotExists":true}}]}
    , .{}, null);
    defer p.deinit();
    try testing.expect(p.steps[2].op == .skip);
    try testing.expect(p.steps[6].op == .skip);
    const out = try f.engine.apply(&p, .user, .auto);
    try testing.expect(out == .applied);
    try testing.expectEqualStrings("fresh\n", f.fs.get("/w/new.txt").?);
    try testing.expectEqualStrings("keep\n", f.fs.get("/w/keep.txt").?);
    try testing.expectEqualStrings("OLD\n", f.fs.get("/w/moved.txt").?);
    try testing.expect(f.fs.get("/w/old.txt") == null);
    try testing.expect(f.fs.get("/w/gone.txt") == null);

    // Flags: an existing target without overwrite or ignore fails the plan.
    try testing.expectError(error.Exists, f.planJson(
        \\{"documentChanges":[{"kind":"create","uri":"file:///w/keep.txt"}]}
    , .{}, null));
    try testing.expectError(error.NotFound, f.planJson(
        \\{"documentChanges":[{"kind":"delete","uri":"file:///w/never.txt"}]}
    , .{}, null));
    // Overwrite wins over ignoreIfExists.
    var p2 = try f.planJson(
        \\{"documentChanges":[{"kind":"rename","oldUri":"file:///w/keep.txt","newUri":"file:///w/new.txt","options":{"overwrite":true,"ignoreIfExists":true}}]}
    , .{}, null);
    defer p2.deinit();
    const out2 = try f.engine.apply(&p2, .user, .auto);
    try testing.expectEqualStrings("keep\n", f.fs.get("/w/new.txt").?);

    // Undo both, newest first: everything is back.
    try f.engine.undo(out2.applied.undo_id);
    try testing.expectEqualStrings("fresh\n", f.fs.get("/w/new.txt").?);
    try testing.expectEqualStrings("keep\n", f.fs.get("/w/keep.txt").?);
    try f.engine.undo(out.applied.undo_id);
    try testing.expect(f.fs.get("/w/new.txt") == null);
    try testing.expect(f.fs.get("/w/moved.txt") == null);
    try testing.expectEqualStrings("old\n", f.fs.get("/w/old.txt").?);
    try testing.expectEqualStrings("gone\n", f.fs.get("/w/gone.txt").?);
}

test "wsedit: folder rename moves open documents and later edits" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.fs.put("/w/src/a.txt", "a\n");
    try f.fs.put("/w/src/b.txt", "b\n");
    const a = try f.open("/w/src/a.txt", "a\n");
    var p = try f.planJson(
        \\{"documentChanges":[
        \\ {"kind":"rename","oldUri":"file:///w/src","newUri":"file:///w/lib"},
        \\ {"textDocument":{"uri":"file:///w/lib/b.txt","version":null},"edits":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"newText":"B"}]}]}
    , .{}, null);
    defer p.deinit();
    _ = try f.engine.apply(&p, .user, .auto);
    try testing.expectEqualStrings("/w/lib/a.txt", f.docs.name(a).?);
    try testing.expectEqualStrings("B\n", f.fs.get("/w/lib/b.txt").?);
    try testing.expect(f.fs.get("/w/src/b.txt") == null);
}

test "wsedit: transactional rollback on failure at step k" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const a = try f.open("/w/a.txt", "a\n");
    try f.fs.put("/w/b.txt", "b\n");
    try f.fs.put("/w/c.txt", "c\n");
    var p = try f.planJson(
        \\{"documentChanges":[
        \\ {"textDocument":{"uri":"file:///w/a.txt","version":null},"edits":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"newText":"A"}]},
        \\ {"kind":"delete","uri":"file:///w/b.txt"},
        \\ {"kind":"create","uri":"file:///w/d.txt"},
        \\ {"kind":"rename","oldUri":"file:///w/c.txt","newUri":"file:///w/e.txt"}]}
    , .{}, null);
    defer p.deinit();
    f.fs.fail_move = true;
    const out = try f.engine.apply(&p, .user, .auto);
    try testing.expectEqual(@as(u32, 3), out.failed.step);
    try f.expectText(a, "a\n");
    try testing.expectEqualStrings("b\n", f.fs.get("/w/b.txt").?);
    try testing.expect(f.fs.get("/w/d.txt") == null);
    try testing.expectEqualStrings("c\n", f.fs.get("/w/c.txt").?);
    try testing.expect(f.engine.lastUndo() == null);

    // A save failure at the end rolls back too, rewriting saved files.
    f.fs.fail_move = false;
    var p2 = try f.planJson(
        \\{"changes":{
        \\ "file:///w/b.txt":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"newText":"B"}],
        \\ "file:///w/c.txt":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"newText":"C"}]}}
    , .{}, null);
    defer p2.deinit();
    f.fs.fail_write = "/w/c.txt";
    const out2 = try f.engine.apply(&p2, .user, .auto);
    try testing.expect(out2 == .failed);
    try testing.expectEqualStrings("b\n", f.fs.get("/w/b.txt").?);
    try testing.expectEqualStrings("c\n", f.fs.get("/w/c.txt").?);
}

const FakeReview = struct {
    plans: u32 = 0,
    files: usize = 0,
    origin: ?Engine.Origin = null,
    fn submit(ctx: *anyopaque, p: *const EditPlan, origin: Engine.Origin) anyerror!u64 {
        const r: *FakeReview = @ptrCast(@alignCast(ctx));
        r.plans += 1;
        r.files = p.files.len;
        r.origin = origin;
        return 77;
    }
};

test "wsedit: agent origin routes to review; nothing written" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const a = try f.open("/w/a.txt", "a\n");
    try f.fs.put("/w/b.txt", "b\n");
    var p = try f.planJson(
        \\{"changes":{
        \\ "file:///w/a.txt":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"newText":"A"}],
        \\ "file:///w/b.txt":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"newText":"B"}]}}
    , .{}, null);
    defer p.deinit();
    // No review sink: fail closed.
    try testing.expect((try f.engine.apply(&p, .{ .agent = 1 }, .auto)) == .failed);
    var rv: FakeReview = .{};
    f.engine.review = .{ .ctx = &rv, .submit = FakeReview.submit };
    const writes = f.fs.writes;
    const out = try f.engine.apply(&p, .{ .agent = 1 }, .auto);
    try testing.expectEqual(@as(u64, 77), out.queued.changeset);
    // A server edit caused by an agent-run command too.
    _ = try f.engine.apply(&p, .{ .server = 1 }, .auto);
    try testing.expectEqual(@as(u32, 2), rv.plans);
    try testing.expectEqual(@as(usize, 2), rv.files);
    try f.expectText(a, "a\n");
    try testing.expectEqualStrings("b\n", f.fs.get("/w/b.txt").?);
    try testing.expectEqual(writes, f.fs.writes);
    // The user's server edits and previews.
    try testing.expect((try f.engine.apply(&p, .user, .force_review)) == .queued);
    try testing.expect((try f.engine.apply(&p, .{ .server = null }, .auto)) == .applied);
}

test "wsedit: needsConfirmation routes to review" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    _ = try f.open("/w/a.txt", "a\n");
    var rv: FakeReview = .{};
    f.engine.review = .{ .ctx = &rv, .submit = FakeReview.submit };
    var p = try f.planJson(
        \\{"documentChanges":[{"textDocument":{"uri":"file:///w/a.txt","version":null},"edits":[
        \\  {"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"newText":"A","annotationId":"risky"}]}],
        \\ "changeAnnotations":{"risky":{"label":"Rename in comments","needsConfirmation":true}}}
    , .{}, null);
    defer p.deinit();
    try testing.expect(p.needs_confirmation);
    try testing.expectEqual(@as(?u32, 0), p.steps[0].annotation);
    try testing.expect((try f.engine.apply(&p, .user, .auto)) == .queued);
    try testing.expectError(error.UnknownAnnotation, f.planJson(
        \\{"documentChanges":[{"textDocument":{"uri":"file:///w/a.txt","version":null},"edits":[
        \\  {"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"newText":"A","annotationId":"nope"}]}]}
    , .{}, null));
}

test "wsedit: closed files opened, edited and saved" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.fs.put("/w/c.txt", "one\ntwo\n");
    f.engine.opts.save_untouched = false;
    var p = try f.planJson(
        \\{"changes":{"file:///w/c.txt":[{"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":3}},"newText":"2"}]}}
    , .{}, null);
    defer p.deinit();
    _ = try f.engine.apply(&p, .user, .auto);
    // Not saved, and the background document is closed again.
    try testing.expectEqualStrings("one\ntwo\n", f.fs.get("/w/c.txt").?);
    f.engine.opts.save_untouched = true;
    var p2 = try f.planJson(
        \\{"changes":{"file:///w/c.txt":[{"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":3}},"newText":"2"}]}}
    , .{}, null);
    defer p2.deinit();
    _ = try f.engine.apply(&p2, .user, .auto);
    try testing.expectEqualStrings("one\n2\n", f.fs.get("/w/c.txt").?);
    try testing.expectEqual(@as(usize, 0), f.docs.count());
}

test "wsedit: encoding per server" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    // "😀" is 4 bytes, 2 UTF-16 units, 1 UTF-32 unit.
    const h = try f.open("/w/e.txt", "a😀b\n");
    var p16 = try f.planJson(
        \\{"changes":{"file:///w/e.txt":[{"range":{"start":{"line":0,"character":3},"end":{"line":0,"character":4}},"newText":"X"}]}}
    , .{ .enc = .utf16 }, null);
    defer p16.deinit();
    _ = try f.engine.apply(&p16, .user, .auto);
    try f.expectText(h, "a😀X\n");
    var p8 = try f.planJson(
        \\{"changes":{"file:///w/e.txt":[{"range":{"start":{"line":0,"character":5},"end":{"line":0,"character":6}},"newText":"Y"}]}}
    , .{ .enc = .utf8 }, null);
    defer p8.deinit();
    _ = try f.engine.apply(&p8, .user, .auto);
    try f.expectText(h, "a😀Y\n");
    var p32 = try f.planJson(
        \\{"changes":{"file:///w/e.txt":[{"range":{"start":{"line":0,"character":1},"end":{"line":0,"character":2}},"newText":"Z"}]}}
    , .{ .enc = .utf32 }, null);
    defer p32.deinit();
    _ = try f.engine.apply(&p32, .user, .auto);
    try f.expectText(h, "aZY\n");
}

test "wsedit: a file changed between plan and apply fails the step" {
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    try f.fs.put("/w/c.txt", "one\n");
    var p = try f.planJson(
        \\{"changes":{"file:///w/c.txt":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},"newText":"1"}]}}
    , .{}, null);
    defer p.deinit();
    try f.fs.put("/w/c.txt", "uno\n");
    const out = try f.engine.apply(&p, .user, .auto);
    try testing.expectEqualStrings("the file changed since the edit was computed", out.failed.reason);
    try testing.expectEqualStrings("uno\n", f.fs.get("/w/c.txt").?);
}

fn fuzzPlan(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = testing.allocator;
    var f: Fixture = undefined;
    f.init();
    defer f.deinit();
    const names = [_][]const u8{ "/w/a", "/w/b", "/w/c" };
    var originals: [3][]u8 = undefined;
    for (names, &originals) |n, *o| {
        var buf: [64]u8 = undefined;
        const len = smith.valueRangeAtMost(u8, 0, 40);
        for (buf[0..len]) |*c| c.* = "ab\n\r😀"[smith.valueRangeAtMost(u8, 0, 4)];
        o.* = try gpa.dupe(u8, buf[0..len]);
        try f.fs.put(n, o.*);
    }
    defer for (originals) |o| gpa.free(o);
    if (smith.valueRangeAtMost(u8, 0, 1) == 1) _ = try f.open(names[0], originals[0]);

    // A random edit: text edits on random files at random positions, plus
    // maybe a create or a rename.
    var json: std.Io.Writer.Allocating = .init(gpa);
    defer json.deinit();
    const w = &json.writer;
    try w.writeAll("{\"documentChanges\":[");
    const n = smith.valueRangeAtMost(u8, 1, 4);
    var i: u8 = 0;
    while (i < n) : (i += 1) {
        if (i > 0) try w.writeAll(",");
        const which = smith.valueRangeAtMost(u8, 0, 2);
        switch (smith.valueRangeAtMost(u8, 0, 5)) {
            0 => try w.print("{{\"kind\":\"create\",\"uri\":\"file:///w/n{d}\",\"options\":{{\"ignoreIfExists\":true}}}}", .{i}),
            1 => try w.print("{{\"kind\":\"rename\",\"oldUri\":\"file://{s}\",\"newUri\":\"file:///w/r{d}\",\"options\":{{\"ignoreIfExists\":true}}}}", .{ names[which], i }),
            else => {
                const line = smith.valueRangeAtMost(u8, 0, 4);
                const ch = smith.valueRangeAtMost(u8, 0, 6);
                const len = smith.valueRangeAtMost(u8, 0, 4);
                try w.print("{{\"textDocument\":{{\"uri\":\"file://{s}\",\"version\":null}},\"edits\":[{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"newText\":\"x\\n\"}}]}}", .{ names[which], line, ch, line, ch + len });
            },
        }
    }
    try w.writeAll("]}");
    var p = f.planJson(json.written(), .{}, null) catch return;
    defer p.deinit();
    const out = try f.engine.apply(&p, .user, .auto);
    if (out != .applied) return;
    try f.engine.undo(out.applied.undo_id);
    for (names, originals) |nm, o| {
        if (try f.docs.findFile(nm)) |h| try f.expectText(h, o) else try testing.expectEqualStrings(o, f.fs.get(nm).?);
    }
    try testing.expectEqual(@as(usize, 3), f.fs.files.count());
}

test "fuzz-wsedit-plan: apply then undo restores the files" {
    try std.testing.fuzz({}, fuzzPlan, .{});
}

test "wsedit: workspace/applyEdit from a server, version checked" {
    const Harness = @import("../Manager_test.zig").Harness;
    var h: Harness = undefined;
    try h.init("apply_edit.script", &.{});
    defer h.deinit();
    const d = try h.open("main.zig", "const foo = 1;\n");
    defer {
        h.mgr.closeDoc(d);
        h.docs.release(d);
    }
    var fs: MemFs = .{ .gpa = testing.allocator };
    defer fs.deinit();
    var engine: Engine = .init(testing.allocator, &h.docs, fs.ops(), .{});
    defer engine.deinit();
    const Hook = struct {
        engine: *Engine,
        results: std.ArrayList(zg_lsp.client.host.ApplyEditResult) = .empty,
        fn f(ctx: *anyopaque, s: *@import("../Manager.zig").Server, params: *const protocol.ApplyWorkspaceEditParams, reply: zg_lsp.client.host.ApplyEditCb) void {
            const hk: *@This() = @ptrCast(@alignCast(ctx));
            const r = hk.engine.serverEdit(s, params, null);
            hk.results.append(testing.allocator, r) catch {};
            reply.call(r);
        }
    };
    var hook: Hook = .{ .engine = &engine };
    defer hook.results.deinit(testing.allocator);
    h.mgr.apply_edit_hook = .{ .ctx = &hook, .f = Hook.f };
    const doc = h.docs.get(d).?;
    for (0..2000) |_| {
        h.mgr.tick();
        if (doc.version > 1 and engine.lastUndo() != null) break;
        try h.rt.io.sleep(.fromMilliseconds(5), .awake);
    }
    const t = try doc.tree.copyRange(testing.allocator, .{ .start = 0, .end = doc.len() });
    defer testing.allocator.free(t);
    try testing.expectEqualStrings("const bar = 1;\n", t);
    try testing.expectEqualStrings("Rename", engine.lastUndo().?.label);
    // The second edit (now at an old version) is refused.
    for (0..2000) |_| {
        h.mgr.tick();
        if (hook.results.items.len == 2) break;
        try h.rt.io.sleep(.fromMilliseconds(5), .awake);
    }
    try testing.expectEqual(@as(usize, 2), hook.results.items.len);
    try testing.expect(hook.results.items[0].applied);
    const r = hook.results.items[1];
    try testing.expect(!r.applied);
    try testing.expectEqualStrings("document version mismatch", r.failure_reason.?);
    try testing.expectEqual(@as(?u32, 0), r.failed_change);
}
