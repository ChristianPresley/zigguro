//! Diagnostics tests: the store on its own, decorations, and the driver
//! against the fake server (pushes, pulls, the settle detector).

const std = @import("std");
const zg_editor = @import("zg_editor");
const zg_lsp = @import("zg_lsp");
const Store = @import("Store.zig");
const convert = @import("convert.zig");
const Driver = @import("Driver.zig");
const Decorator = @import("decorate.zig");
const SettleDetector = @import("settle.zig");
const Harness = @import("../Manager_test.zig").Harness;

const testing = std.testing;
const Io = std.Io;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const Document = zg_editor.model.document.Document;
const DecorationStore = zg_editor.model.decorations.store.DecorationStore;
const ChangeSet = zg_editor.model.edit.change_set.ChangeSet;
const pt = zg_editor.model.buffer.piece_tree;
const protocol = zg_lsp.protocol;

fn lspDiag(line: u32, a: u32, b: u32, sev: ?protocol.DiagnosticSeverity, msg: []const u8) protocol.Diagnostic {
    return .{
        .range = .{ .start = .{ .line = line, .character = a }, .end = .{ .line = line, .character = b } },
        .severity = sev,
        .message = .{ .string = msg },
    };
}

fn setOf(owner: Store.Owner, in: []const protocol.Diagnostic) !*Store.Set {
    const s = try Store.Set.create(testing.allocator, owner);
    errdefer s.destroy();
    try convert.fromLsp(s, in);
    return s;
}

const Commits = struct {
    n: u32 = 0,
    last: std.ArrayList([]const u8) = .empty,
    fn on(ctx: *anyopaque, _: *const Store.Snapshot, changed: []const []const u8) void {
        const c: *Commits = @ptrCast(@alignCast(ctx));
        c.n += 1;
        for (c.last.items) |k| testing.allocator.free(k);
        c.last.clearRetainingCapacity();
        for (changed) |k| c.last.append(testing.allocator, testing.allocator.dupe(u8, k) catch unreachable) catch unreachable;
    }
    fn deinit(c: *Commits) void {
        for (c.last.items) |k| testing.allocator.free(k);
        c.last.deinit(testing.allocator);
    }
};

test "diag: push replace per owner; counts; clearOwner" {
    var rt: @import("zg_core").Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var st = try Store.init(testing.allocator, rt.io, .posix);
    defer st.deinit();
    var commits: Commits = .{};
    defer commits.deinit();
    try st.addListener(.{ .ctx = &commits, .func = Commits.on });

    const a: Store.Owner = .{ .server = 0 };
    const b: Store.Owner = .{ .task = 7 };
    try st.replace("/w/a.zig", a, try setOf(a, &.{ lspDiag(2, 0, 1, .Error, "e1"), lspDiag(1, 0, 1, .Warning, "w1") }));
    try st.replace("/w/a.zig", b, try setOf(b, &.{lspDiag(0, 0, 1, .Error, "task")}));
    try st.replace("/w/b.zig", a, try setOf(a, &.{lspDiag(0, 0, 1, .Hint, "h")}));
    st.commit();
    try testing.expectEqual(@as(u32, 1), commits.n);
    try testing.expectEqual(@as(usize, 2), commits.last.items.len);

    {
        const snap = st.acquire();
        defer snap.release();
        try testing.expectEqual(@as(u64, 1), snap.generation);
        try testing.expectEqual(@as(u32, 2), snap.errors());
        try testing.expectEqual(@as(u32, 1), snap.warnings());
        var all: std.ArrayList(*const Store.Diagnostic) = .empty;
        defer all.deinit(testing.allocator);
        try snap.forKey("/w/a.zig", testing.allocator, &all);
        // Every owner's, by position.
        try testing.expectEqual(@as(usize, 3), all.items.len);
        try testing.expectEqualStrings("task", all.items[0].message);
        try testing.expectEqualStrings("w1", all.items[1].message);
        try testing.expectEqualStrings("e1", all.items[2].message);
        try testing.expectEqualStrings("/w/a.zig", snap.keys()[0]);
    }

    // Replacing one owner's set keeps the other's.
    try st.replace("/w/a.zig", a, try setOf(a, &.{lspDiag(5, 0, 1, .Warning, "w2")}));
    st.commit();
    {
        const snap = st.acquire();
        defer snap.release();
        try testing.expectEqual(@as(u32, 1), snap.errors());
        try testing.expectEqual(@as(u32, 1), snap.warnings());
        try testing.expect(snap.bucket("/w/a.zig").?.setOf(b) != null);
    }
    // An unchanged replacement (nothing to remove) commits nothing.
    try st.replace("/w/c.zig", a, null);
    st.commit();
    try testing.expectEqual(@as(u32, 2), commits.n);

    // A stopped server loses everything it reported.
    try st.clearOwner(a);
    st.commit();
    const snap = st.acquire();
    defer snap.release();
    try testing.expectEqual(@as(usize, 1), snap.keys().len);
    try testing.expectEqual(@as(u32, 1), snap.errors());
    try testing.expectEqual(@as(u32, 0), snap.warnings());
}

test "diag: snapshot isolation" {
    var rt: @import("zg_core").Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var st = try Store.init(testing.allocator, rt.io, .posix);
    defer st.deinit();
    const a: Store.Owner = .{ .server = 0 };
    try st.replace("/w/a.zig", a, try setOf(a, &.{lspDiag(0, 0, 1, .Error, "old")}));
    try st.replace("/w/b.zig", a, try setOf(a, &.{lspDiag(0, 0, 1, .Error, "kept")}));
    st.commit();

    const old = st.acquire();
    defer old.release();
    try st.replace("/w/a.zig", a, try setOf(a, &.{lspDiag(0, 0, 1, .Warning, "new")}));
    st.commit();
    const cur = st.acquire();
    defer cur.release();

    // The reader still sees its generation; untouched buckets are shared.
    try testing.expectEqual(old.generation + 1, cur.generation);
    try testing.expectEqualStrings("old", old.bucket("/w/a.zig").?.sets[0].diags[0].message);
    try testing.expectEqualStrings("new", cur.bucket("/w/a.zig").?.sets[0].diags[0].message);
    try testing.expect(old.bucket("/w/b.zig").? == cur.bucket("/w/b.zig").?);
    try testing.expectEqual(@as(u32, 2), old.errors());
    try testing.expectEqual(@as(u32, 1), cur.errors());
}

test "diag: conversion keeps codes, tags, markdown and data" {
    const s = try Store.Set.create(testing.allocator, .{ .server = 1 });
    defer s.destroy();
    var data: std.json.ObjectMap = .empty;
    defer data.deinit(testing.allocator);
    try data.put(testing.allocator, "fix", .{ .integer = 3 });
    var d1 = lspDiag(0, 1, 2, .Information, "");
    d1.message = .{ .markup_content = .{ .kind = .Markdown, .value = "**bold**" } };
    d1.code = .{ .integer = 2322 };
    d1.tags = &.{ .Deprecated, .Unnecessary };
    d1.source = "ts";
    d1.data = .{ .object = data };
    var d2 = lspDiag(0, 0, 1, null, "no severity");
    d2.source = "ts";
    d2.code = .{ .string = "E1" };
    try convert.fromLsp(s, &.{ d1, d2 });
    try testing.expectEqual(@as(usize, 2), s.diags.len);
    const x = s.diags[1];
    try testing.expectEqualStrings("**bold**", x.message);
    try testing.expect(x.flags.markdown and x.flags.deprecated and x.flags.unnecessary);
    try testing.expectEqualStrings("2322", x.code);
    try testing.expectEqualStrings("{\"fix\":3}", x.data.?);
    try testing.expectEqual(Store.Severity.information, x.severity);
    // A missing severity reads as an error; sources are interned.
    try testing.expectEqual(Store.Severity.err, s.diags[0].severity);
    try testing.expect(s.diags[0].source.ptr == x.source.ptr);
    try testing.expectEqual([4]u32{ 1, 0, 1, 0 }, s.counts);
}

test "diag: decorations batch per frame" {
    const gpa = testing.allocator;
    var rt: @import("zg_core").Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var st = try Store.init(gpa, rt.io, .posix);
    defer st.deinit();
    const doc = try Document.initBytes(gpa, @enumFromInt(1), "const a = 1;\nconst b = x;\n");
    defer doc.deinit();
    var ds: DecorationStore = .init(gpa, doc);
    defer ds.deinit();
    const lid = try doc.subscribe(ds.listener());
    defer doc.unsubscribe(lid);
    var dec: Decorator = undefined;
    try dec.init(gpa, &st, .{ .severity = .{ @enumFromInt(1), @enumFromInt(2), @enumFromInt(3), @enumFromInt(4) }, .faded = @enumFromInt(9) });
    defer dec.deinit();
    try dec.attach("/w/a.zig", &ds);
    try testing.expect(try dec.flush());
    try testing.expectEqual(@as(usize, 0), ds.count());

    const a: Store.Owner = .{ .server = 0 };
    const v0 = doc.version;
    const s = try setOf(a, &.{ lspDiag(1, 10, 11, .Error, "x"), lspDiag(1, 6, 7, .Warning, "b"), lspDiag(0, 6, 7, .Hint, "a") });
    s.diags[0].flags.unnecessary = true;
    for (s.diags, [_]Store.ByteRange{ .{ .start = 6, .end = 7 }, .{ .start = 19, .end = 20 }, .{ .start = 23, .end = 24 } }) |*d, r| d.bytes = r;
    s.version = v0;
    try st.replace("/w/a.zig", a, s);
    // Another document's change does not rebuild this one.
    try st.replace("/w/other.zig", a, try setOf(a, &.{lspDiag(0, 0, 1, .Error, "o")}));
    st.commit();

    // Edited since: everything moves 5 bytes down.
    var cs = try ChangeSet.fromEdits(gpa, doc.len(), &.{pt.Edit{ .range = .{ .start = 0, .end = 0 }, .text = "// c\n" }});
    defer cs.deinit();
    try doc.applyChangeSet(&cs, .{ .user = 0 });

    try testing.expect(try dec.flush());
    try testing.expectEqual(@as(u32, 2), dec.rebuilt);
    try testing.expect(!try dec.flush());
    var out: std.ArrayList(zg_editor.model.decorations.store.DecoRef) = .empty;
    defer out.deinit(gpa);
    try ds.query(.{ .start = 0, .end = doc.len() }, .initMany(&.{.underline}), gpa, &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqual(@as(u64, 11), out.items[0].range.start);
    try testing.expectEqual(.dotted, out.items[0].deco.kind.underline.kind);
    try testing.expectEqual(@as(u64, 28), out.items[2].range.start);
    out.clearRetainingCapacity();
    // One gutter mark per line, with the line's worst severity.
    try ds.query(.{ .start = 0, .end = doc.len() }, .initMany(&.{.gutter}), gpa, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(u32, 1), out.items[1].deco.kind.gutter.icon);
    out.clearRetainingCapacity();
    try ds.query(.{ .start = 0, .end = doc.len() }, .initMany(&.{ .text_style, .overview }), gpa, &out);
    try testing.expectEqual(@as(usize, 4), out.items.len);

    // Cleared diagnostics clear the decorations.
    try st.replace("/w/a.zig", a, null);
    st.commit();
    try testing.expect(try dec.flush());
    try testing.expectEqual(@as(usize, 0), ds.count());
}

// ------------------------------------------------------------- driver

fn edit(h: *Harness, d: DocHandle, a: usize, b: usize, text: []const u8) !void {
    const doc = h.docs.get(d).?;
    var cs = try ChangeSet.fromEdits(testing.allocator, doc.len(), &.{pt.Edit{ .range = .{ .start = a, .end = b }, .text = text }});
    defer cs.deinit();
    try doc.applyChangeSet(&cs, .{ .user = 0 });
}

const Ctx = struct {
    h: *Harness,
    d: *Driver,
    doc: DocHandle,

    fn pump(c: *Ctx, comptime done: fn (*Ctx) bool) !void {
        for (0..2000) |_| {
            c.h.mgr.tick();
            _ = c.d.tick();
            if (done(c)) return;
            try c.h.rt.io.sleep(.fromMilliseconds(5), .awake);
        }
        return error.Timeout;
    }

    fn diags(c: *Ctx) []const Store.Diagnostic {
        const key = c.d.keyOfDoc(c.doc) orelse return &.{};
        const b = c.d.store.current.bucket(key) orelse return &.{};
        return b.sets[0].diags;
    }

    fn two(c: *Ctx) bool {
        return c.diags().len == 2;
    }
    fn stale(c: *Ctx) bool {
        const ds = c.diags();
        return ds.len == 1 and std.mem.eql(u8, ds[0].message, "stale");
    }
    fn cleared(c: *Ctx) bool {
        return c.d.store.current.keys().len == 0;
    }
    fn related(c: *Ctx) bool {
        return c.d.store.current.keys().len == 2;
    }
    fn resultId(c: *Ctx, id: []const u8) bool {
        const s = c.h.mgr.serverList()[0];
        const t = c.d.tracks.get(.{ .server = s.id, .h = c.doc }) orelse return false;
        return t.result_id != null and std.mem.eql(u8, t.result_id.?, id);
    }
    fn r2(c: *Ctx) bool {
        return c.resultId("r2");
    }
    fn r3(c: *Ctx) bool {
        return c.resultId("r3") and c.d.store.current.keys().len == 1;
    }
};

/// Runs `afterAgentEdit` on another thread while the test pumps.
const Settle = struct {
    sd: *SettleDetector,
    path: []const u8,
    arena: std.heap.ArenaAllocator,
    result: ?[]const u8 = null,
    took_ns: i96 = 0,
    done: std.atomic.Value(bool) = .init(false),

    fn run(s: *Settle, io: Io) void {
        const t0 = Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        s.result = s.sd.afterAgentEdit(io, s.arena.allocator(), s.path) catch null;
        s.took_ns = Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - t0;
        s.done.store(true, .release);
    }

    fn finished(_: *Ctx) bool {
        return current.done.load(.acquire);
    }
    var current: *Settle = undefined;
};

test "diag: push with stale version maps ranges / drops edited; settle detector" {
    var h: Harness = undefined;
    try h.init("diag_push.script", &.{});
    var st = try Store.init(testing.allocator, h.rt.io, .native);
    var d: Driver = undefined;
    try d.init(&h.mgr, &st, .{ .settle = .{ .timeout = .fromSeconds(5) } });
    const doc = try h.open("main.zig", "const a = 1;\nconst b = x + 1;\n");
    defer {
        h.mgr.closeDoc(doc);
        h.docs.release(doc);
        h.mgr.deinit();
        d.deinit();
        h.mgr = undefined;
        st.deinit();
        h.docs.deinit();
        h.reg.deinit();
        testing.allocator.free(h.script);
        h.tmp.cleanup();
        _ = h.rt.deinit();
    }
    var c: Ctx = .{ .h = &h, .d = &d, .doc = doc };
    try c.pump(Ctx.two);
    const v1 = h.docs.get(doc).?.version;
    {
        const ds = c.diags();
        try testing.expectEqualStrings("unused constant", ds[0].message);
        try testing.expect(ds[0].flags.unnecessary);
        try testing.expectEqual(Store.ByteRange{ .start = 6, .end = 7 }, ds[0].bytes.?);
        try testing.expectEqual(Store.ByteRange{ .start = 23, .end = 24 }, ds[1].bytes.?);
        try testing.expectEqualStrings("42", ds[1].code);
        try testing.expectEqual(@as(u32, 1), st.current.errors());
        // The summary the agent sees: the server answered version 1.
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const path = try std.fs.path.join(arena.allocator(), &.{ h.ws, "main.zig" });
        const r = try d.settle.wait(h.rt.io, arena.allocator(), .{ .paths = &.{path}, .timeout = .fromSeconds(3) });
        try testing.expect(r.settled and !r.heuristic and r.reason == null);
        try testing.expectEqualStrings(
            \\1 error, 1 warning:
            \\main.zig:1:7: warning: unused constant [fake]
            \\main.zig:2:11: error: use of undeclared identifier 'x' [fake 42]
        , try d.settle.renderResult(arena.allocator(), r, &.{path}, h.ws));
    }

    // A task's problems for the open document get byte ranges at its
    // text (characters counted as bytes), beside the server's set.
    {
        const key = d.keyOfDoc(doc).?;
        const t = try Store.Set.create(testing.allocator, .{ .task = 7 });
        t.diags = try t.allocator().dupe(Store.Diagnostic, &.{.{ .start = .{ .line = 1, .character = 6 }, .end = .{ .line = 1, .character = 7 }, .message = "from the build" }});
        t.finish();
        try d.replaceExternal(key, .{ .task = 7 }, t, .utf8);
        _ = d.tick();
        const got = st.current.bucket(key).?.setOf(.{ .task = 7 }).?;
        try testing.expectEqual(Store.ByteRange{ .start = 19, .end = 20 }, got.diags[0].bytes.?);
        try testing.expectEqual(@as(usize, 2), st.current.bucket(key).?.sets.len);
        try d.replaceExternal(key, .{ .task = 7 }, null, .utf8);
        _ = d.tick();
        try testing.expect(st.current.bucket(key).?.setOf(.{ .task = 7 }) == null);
    }

    // The server answers the edit with a push about the old text: the
    // ranges stay at that version, for decorations to map forward.
    try edit(&h, doc, 0, 0, "// c\n");
    try c.pump(Ctx.stale);
    {
        const set = st.current.bucket(d.keyOfDoc(doc).?).?.sets[0];
        try testing.expectEqual(v1, set.version.?);
        try testing.expectEqual(Store.ByteRange{ .start = 23, .end = 24 }, set.diags[0].bytes.?);
        const cur = h.docs.get(doc).?;
        try testing.expectEqual(pt.Range{ .start = 28, .end = 29 }, cur.mapForward(v1, .{ .start = 23, .end = 24 }, .right).?);
        // Deleted text drops the range.
        try edit(&h, doc, 27, 30, "");
        try testing.expect(cur.mapForward(v1, .{ .start = 23, .end = 24 }, .right) == null);
    }

    // The agent's edit: the detector waits for the server's answer to it
    // (the empty push), then reports nothing.
    const path = try std.fs.path.join(testing.allocator, &.{ h.ws, "main.zig" });
    defer testing.allocator.free(path);
    var s: Settle = .{ .sd = &d.settle, .path = path, .arena = .init(testing.allocator) };
    defer s.arena.deinit();
    Settle.current = &s;
    var fut = try h.rt.io.concurrent(Settle.run, .{ &s, h.rt.io });
    defer fut.cancel(h.rt.io);
    try c.pump(Settle.finished);
    try testing.expect(c.cleared());
    try testing.expect(s.result == null);
    try testing.expect(s.took_ns < std.time.ns_per_s * 4);
}

test "diag: pull full/unchanged resultId flow; relatedDocuments applied; refresh" {
    var h: Harness = undefined;
    try h.init("diag_pull.script", &.{});
    var st = try Store.init(testing.allocator, h.rt.io, .native);
    var d: Driver = undefined;
    try d.init(&h.mgr, &st, .{ .pull = .{ .debounce = .fromMilliseconds(10) } });
    const doc = try h.open("main.zig", "const a = 1;\n");
    defer {
        h.mgr.closeDoc(doc);
        h.docs.release(doc);
        h.mgr.deinit();
        d.deinit();
        h.mgr = undefined;
        st.deinit();
        h.docs.deinit();
        h.reg.deinit();
        testing.allocator.free(h.script);
        h.tmp.cleanup();
        _ = h.rt.deinit();
    }
    var c: Ctx = .{ .h = &h, .d = &d, .doc = doc };
    try c.pump(Ctx.related);
    try testing.expectEqualStrings("first", c.diags()[0].message);
    try testing.expectEqual(Store.ByteRange{ .start = 0, .end = 5 }, c.diags()[0].bytes.?);
    {
        // The related file is not open: no byte ranges.
        const other = try std.fs.path.join(testing.allocator, &.{ h.ws, "other.zig" });
        defer testing.allocator.free(other);
        const key = try st.keyOfPath(testing.allocator, other);
        defer testing.allocator.free(key);
        const od = st.current.bucket(key).?.sets[0].diags[0];
        try testing.expectEqualStrings("in other", od.message);
        try testing.expect(od.bytes == null);
        try testing.expectEqual(@as(u32, 1), st.current.warnings());
    }

    // After an edit the pull carries `r1` and gets `unchanged`: the set
    // stays.
    try edit(&h, doc, 0, 0, " ");
    try c.pump(Ctx.r2);
    try testing.expectEqualStrings("first", c.diags()[0].message);
    // The refresh pulls again; the empty report clears the file.
    try c.pump(Ctx.r3);
    try testing.expectEqual(@as(usize, 0), c.diags().len);
}

const Problems = @import("problems.zig");

test "problems: grouping and order; filter text and severity; next/prev wraps across files" {
    var rt: @import("zg_core").Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var st = try Store.init(testing.allocator, rt.io, .posix);
    defer st.deinit();
    const a: Store.Owner = .{ .server = 0 };
    const b: Store.Owner = .{ .task = 1 };
    try st.replace("/w/b.zig", a, try setOf(a, &.{ lspDiag(4, 0, 1, .Error, "bad thing"), lspDiag(1, 2, 3, .Warning, "unused x") }));
    try st.replace("/w/b.zig", b, try setOf(b, &.{lspDiag(2, 0, 1, .Error, "build: expected ';'")}));
    try st.replace("/w/a.zig", a, try setOf(a, &.{lspDiag(0, 0, 1, .Hint, "consider const")}));
    st.commit();

    var p = Problems.init(testing.allocator);
    defer p.deinit();
    try testing.expect(try p.update(&st, .{}));
    try testing.expect(!try p.update(&st, .{}));
    // Files by key, diagnostics merged by position across owners.
    try testing.expectEqual(@as(usize, 2), p.files.items.len);
    try testing.expectEqualStrings("/w/a.zig", p.files.items[0].key);
    const bi = p.fileItems(1);
    try testing.expectEqual(@as(usize, 3), bi.len);
    try testing.expectEqualStrings("unused x", bi[0].diag.message);
    try testing.expectEqualStrings("build: expected ';'", bi[1].diag.message);
    try testing.expect(bi[1].owner.eql(b));
    try testing.expectEqual(@as(u32, 2), p.files.items[1].counts[0]);
    // Ids name their nodes; files have the top bit.
    try testing.expectEqual(Problems.Node{ .file = 1 }, p.node(p.files.items[1].id).?);
    try testing.expectEqual(Problems.Node{ .item = .{ .file = 1, .item = 2 } }, p.node(bi[2].id).?);
    const id_bad = bi[2].id;

    // Next from the top of b.zig, then on, wrapping to a.zig and back.
    var l = p.step("/w/b.zig", .{ .line = 0, .character = 0 }, .next, false).?;
    try testing.expectEqualStrings("unused x", p.item(l).diag.message);
    l = p.step("/w/b.zig", p.item(l).diag.start, .next, false).?;
    l = p.step("/w/b.zig", p.item(l).diag.start, .next, false).?;
    try testing.expectEqualStrings("bad thing", p.item(l).diag.message);
    l = p.step("/w/b.zig", p.item(l).diag.start, .next, false).?;
    try testing.expectEqualStrings("consider const", p.item(l).diag.message);
    l = p.step("/w/a.zig", p.item(l).diag.start, .prev, false).?;
    try testing.expectEqualStrings("bad thing", p.item(l).diag.message);
    // In-file wraps inside the file; a file without problems goes to the
    // next one in key order.
    l = p.step("/w/b.zig", .{ .line = 9, .character = 0 }, .next, true).?;
    try testing.expectEqualStrings("unused x", p.item(l).diag.message);
    try testing.expect(p.step("/w/c.zig", .{ .line = 0, .character = 0 }, .next, true) == null);
    l = p.step("/w/aa.zig", .{ .line = 0, .character = 0 }, .next, false).?;
    try testing.expectEqual(@as(u32, 1), l.file);

    // Text (case folded, message, source or code) and severity filters.
    _ = try p.update(&st, .{ .text = "BUILD" });
    try testing.expectEqual(@as(usize, 1), p.count());
    _ = try p.update(&st, .{ .min_severity = .warning });
    try testing.expectEqual(@as(usize, 3), p.count());
    try testing.expectEqual(@as(usize, 1), p.files.items.len);
    _ = try p.update(&st, .{ .key = "/w/a.zig" });
    try testing.expectEqual(@as(usize, 1), p.count());

    // Ids stay across updates: a new diagnostic elsewhere keeps them.
    try st.replace("/w/c.zig", a, try setOf(a, &.{lspDiag(0, 0, 1, .Error, "c")}));
    st.commit();
    _ = try p.update(&st, .{});
    try testing.expectEqual(@as(usize, 3), p.files.items.len);
    try testing.expectEqual(Problems.Node{ .item = .{ .file = 1, .item = 2 } }, p.node(id_bad).?);
    try testing.expectEqual([4]u32{ 3, 1, 0, 1 }, Problems.totals(&st));
}

test "problems: duplicate diagnostics get distinct ids" {
    var rt: @import("zg_core").Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var st = try Store.init(testing.allocator, rt.io, .posix);
    defer st.deinit();
    const a: Store.Owner = .{ .server = 0 };
    try st.replace("/w/a.zig", a, try setOf(a, &.{ lspDiag(0, 0, 1, .Error, "same"), lspDiag(0, 0, 1, .Error, "same") }));
    st.commit();
    var p = Problems.init(testing.allocator);
    defer p.deinit();
    _ = try p.update(&st, .{});
    const its = p.fileItems(0);
    try testing.expect(its[0].id != its[1].id);
    try testing.expectEqual(@as(u32, 3), p.nodes.count());
}

const WorkspacePull = @import("workspace_pull.zig");

const WsSink = struct {
    got: std.ArrayList(u8) = .empty,

    fn full(ctx: *anyopaque, _: *@import("../Manager.zig").Server, uri: []const u8, items: []const protocol.Diagnostic) void {
        const s: *WsSink = @ptrCast(@alignCast(ctx));
        s.got.print(testing.allocator, "{s} {d}", .{ uri, items.len }) catch unreachable;
        for (items) |it| s.got.print(testing.allocator, " {s}", .{it.message.string}) catch unreachable;
        s.got.append(testing.allocator, '\n') catch unreachable;
    }
};

test "diag: workspace pull streams partial results, re-polls with result ids, retriggers on ServerCancelled" {
    var h: Harness = undefined;
    try h.init("diag_workspace.script", &.{});
    var w: WorkspacePull = .init(&h.mgr, .{ .min_interval = .fromMilliseconds(10) });
    const doc = try h.open("main.zig", "const a = 1;\n");
    var sink: WsSink = .{};
    defer {
        sink.got.deinit(testing.allocator);
        h.mgr.closeDoc(doc);
        h.docs.release(doc);
        h.mgr.deinit();
        w.deinit();
        h.docs.deinit();
        h.reg.deinit();
        testing.allocator.free(h.script);
        h.tmp.cleanup();
        _ = h.rt.deinit();
    }
    var done = false;
    for (0..3000) |_| {
        h.mgr.tick();
        w.tick(Io.Clock.Timestamp.now(h.rt.io, .awake).raw.nanoseconds, .{ .ctx = &sink, .full = WsSink.full });
        // The third poll answered: stop before a fourth.
        if (w.states.count() == 1 and w.states.values()[0].sent == 3 and !w.states.values()[0].busy) {
            done = true;
            break;
        }
        try h.rt.io.sleep(.fromMilliseconds(2), .awake);
    }
    try testing.expect(done);
    try testing.expectEqualStrings(
        \\file:///w/closed.zig 1 closed file error
        \\file:///w/closed.zig 0
        \\
    , sink.got.items);
    // The empty full report has no result id: forgotten.
    const ids = &w.states.values()[0].ids;
    try testing.expectEqual(@as(usize, 1), ids.count());
    try testing.expectEqualStrings("o1", ids.get("file:///w/other.zig").?);
}

test "diag: a set reported for a closed file gets byte ranges when it opens" {
    const gpa = testing.allocator;
    const s = try setOf(.{ .server = 0 }, &.{ lspDiag(1, 2, 5, .Error, "later line"), lspDiag(0, 0, 3, .Warning, "first") });
    defer s.destroy();
    try testing.expect(s.diags[0].bytes == null);
    const doc = try Document.initBytes(gpa, @enumFromInt(0), "abcdef\nghijkl\n");
    defer doc.deinit();
    const c = try convert.copySet(gpa, s);
    defer c.destroy();
    try convert.mapBytes(gpa, c, &doc.tree, .utf16, doc.version);
    try testing.expectEqualStrings("first", c.diags[0].message);
    try testing.expectEqual(Store.ByteRange{ .start = 0, .end = 3 }, c.diags[0].bytes.?);
    try testing.expectEqual(Store.ByteRange{ .start = 9, .end = 12 }, c.diags[1].bytes.?);
    try testing.expectEqual(s.counts, c.counts);
    // The copy owns its strings.
    try testing.expect(c.diags[1].message.ptr != s.diags[1].message.ptr);
}
