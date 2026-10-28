//! Manager tests against zg_lsp's scripted fake server: each script is
//! what one server must see, so a wrong message makes it exit 99 and the
//! next request fail.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const options = @import("zg_options");
const test_exes = @import("zg_test_exes");
const Manager = @import("Manager.zig");
const Registry = @import("registry/Registry.zig");

const testing = std.testing;
const Io = std.Io;
const api = zg_editor.model.api;
const DocumentRegistry = api.registry.DocumentRegistry;
const DocHandle = api.registry.DocHandle;
const ChangeSet = zg_editor.model.edit.change_set.ChangeSet;
const pt = zg_editor.model.buffer.piece_tree;
const Client = zg_lsp.client.Client;

/// A workspace in a temp dir, a document registry and a manager whose
/// only Zig server is the fake one playing `script`.
pub const Harness = struct {
    rt: zg_core.Runtime,
    tmp: testing.TmpDir,
    ws_buf: [std.fs.max_path_bytes]u8,
    ws: []const u8,
    script: []u8,
    reg: Registry,
    docs: DocumentRegistry,
    mgr: Manager,

    pub fn init(h: *Harness, script: []const u8, extra: []const Registry.Override) !void {
        h.rt.initTesting();
        const gpa = testing.allocator;
        h.tmp = testing.tmpDir(.{});
        h.ws = h.ws_buf[0..try h.tmp.dir.realPathFile(h.rt.io, ".", &h.ws_buf)];
        h.script = try std.fs.path.join(gpa, &.{ options.package_root, "testdata", "transcripts", script });
        var overrides: std.ArrayList(Registry.Override) = .empty;
        defer overrides.deinit(gpa);
        try overrides.append(gpa, .{ .id = "zls", .enabled = false });
        try overrides.append(gpa, .{
            .id = "fake",
            .command = &.{ test_exes.fake_lsp_server, "--script", h.script, "--workspace", h.ws },
            .languages = &.{"zig"},
            .initialization_options = "{\"x\": 1}",
        });
        try overrides.appendSlice(gpa, extra);
        h.reg = try .init(gpa, .{ .overrides = overrides.items });
        h.docs = .init(gpa, .native);
        h.mgr.init(&h.rt, &h.reg, &h.docs, .{ .workspace_folders = (&h.ws)[0..1], .init_timeout = .fromSeconds(10) });
    }

    pub fn deinit(h: *Harness) void {
        h.mgr.deinit();
        h.docs.deinit();
        h.reg.deinit();
        testing.allocator.free(h.script);
        h.tmp.cleanup();
        _ = h.rt.deinit();
    }

    pub fn open(h: *Harness, name: []const u8, text: []const u8) !DocHandle {
        const path = try std.fs.path.join(testing.allocator, &.{ h.ws, name });
        defer testing.allocator.free(path);
        const d = try h.docs.openFile(path, text);
        try h.mgr.openDoc(d, "zig");
        return d;
    }

    /// Ticks until `pred` holds (10 s at most).
    fn waitFor(h: *Harness, comptime pred: fn (*Harness) bool) !void {
        var i: usize = 0;
        while (i < 2000) : (i += 1) {
            h.mgr.tick();
            if (pred(h)) return;
            try h.rt.io.sleep(.fromMilliseconds(5), .awake);
        }
        return error.Timeout;
    }

    pub fn server(h: *Harness, id: []const u8) ?*Manager.Server {
        for (h.mgr.serverList()) |s| if (std.mem.eql(u8, s.def.id, id)) return s;
        return null;
    }
};

fn fakeSettled(h: *Harness) bool {
    const s = h.server("fake") orelse return false;
    return s.status != .starting;
}

fn fakeCrashed(h: *Harness) bool {
    const s = h.server("fake") orelse return false;
    return s.status == .crashed;
}

fn edit(docs: *DocumentRegistry, d: DocHandle, a: usize, b: usize, text: []const u8) !void {
    const doc = docs.get(d).?;
    var cs = try ChangeSet.fromEdits(testing.allocator, doc.len(), &.{pt.Edit{ .range = .{ .start = a, .end = b }, .text = text }});
    defer cs.deinit();
    try doc.applyChangeSet(&cs, .{ .user = 0 });
}

test "manager: lazy start, sync, routed hover, close and shutdown" {
    var h: Harness = undefined;
    try h.init("manager_session.script", &.{});
    defer h.deinit();
    try testing.expectEqual(@as(usize, 0), h.mgr.serverList().len);

    const d = try h.open("main.zig", "const a = 1;\n");
    defer h.docs.release(d);
    try h.waitFor(fakeSettled);
    const s = h.server("fake").?;
    try testing.expectEqual(Manager.Status.running, s.status);
    try testing.expectEqualStrings(h.ws, s.root);
    // utf-8 was negotiated, incremental sync.
    try testing.expectEqual(@as(?i32, 1), s.sync.?.version(d));

    try edit(&h.docs, d, 6, 7, "b");
    h.mgr.tick();
    h.mgr.saved(d);

    var out: [4]*Client = undefined;
    try testing.expectEqual(@as(usize, 1), h.mgr.clientsFor(d, .hover, &out));
    try testing.expectEqual(@as(usize, 0), h.mgr.clientsFor(d, .rename, &out));
    const uri = h.docs.uri(d).?;
    const r = try out[0].requestBlocking(.@"textDocument/hover", .{
        .textDocument = .{ .uri = uri },
        .position = .{ .line = 0, .character = 6 },
    }, .{});
    defer r.deinit();
    try testing.expectEqualStrings("b: comptime_int", r.ok.value.?.contents.markup_content.value);

    h.mgr.closeDoc(d);
    try testing.expect(!s.sync.?.isTracked(d));
}

test "manager: one server per root, missing executables reported" {
    var h: Harness = undefined;
    // zls is enabled again and absent from the (empty) environment.
    try h.init("manager_two_docs.script", &.{.{ .id = "zls", .enabled = true }});
    defer h.deinit();
    const a = try h.open("a.zig", "const a = 1;\n");
    defer h.docs.release(a);
    try h.waitFor(fakeSettled);
    const b = try h.open("b.zig", "");
    defer h.docs.release(b);
    for (0..20) |_| h.mgr.tick();
    try testing.expectEqual(@as(usize, 2), h.mgr.serverList().len);
    const zls = h.server("zls").?;
    try testing.expectEqual(Manager.Status.missing, zls.status);
    try testing.expect(zls.def.install_hint.len > 0);
    try testing.expect(h.mgr.serverFor(a, "fake") != null);
    try testing.expect(h.mgr.serverFor(a, "zls") == null);
    h.mgr.closeDoc(a);
    h.mgr.closeDoc(b);
}

test "manager: a crash detaches the server without sending" {
    var h: Harness = undefined;
    try h.init("manager_crash.script", &.{});
    defer h.deinit();
    const d = try h.open("main.zig", "x");
    defer h.docs.release(d);
    try h.waitFor(fakeCrashed);
    const s = h.server("fake").?;
    try testing.expect(s.sync == null and s.client == null);
    var out: [4]*Client = undefined;
    try testing.expectEqual(@as(usize, 0), h.mgr.clientsFor(d, .hover, &out));
    // Edits and saves after the crash go nowhere.
    try edit(&h.docs, d, 0, 1, "y");
    h.mgr.tick();
    h.mgr.saved(d);
    h.mgr.closeDoc(d);
}

fn fakeDisabled(h: *Harness) bool {
    const s = h.server("fake") orelse return false;
    return s.status == .disabled;
}

fn fakeCrashedTwice(h: *Harness) bool {
    const s = h.server("fake") orelse return false;
    return s.status == .crashed and s.crashes >= 4;
}

test "manager: crashed servers restart with backoff until disabled; restart, stop and enable by hand" {
    var h: Harness = undefined;
    try h.init("manager_crash.script", &.{});
    defer h.deinit();
    h.mgr.opts.restart = .{ .max_crashes = 3, .base = .fromMilliseconds(10), .window = .fromSeconds(60) };
    const d = try h.open("main.zig", "x");
    defer h.docs.release(d);
    // Every start opens the document again, and the script exits there.
    try h.waitFor(fakeDisabled);
    const s = h.server("fake").?;
    try testing.expectEqual(@as(u32, 3), s.crashes);
    try testing.expect(s.restart_due_ns == null and h.mgr.nextRestartDue() == null);
    // Enabling forgets the crashes: it starts, crashes and waits again.
    h.mgr.enable(s);
    try testing.expectEqual(Manager.Status.starting, s.status);
    try h.waitFor(fakeCrashedTwice);
    try testing.expect(s.restart_due_ns != null);
    // Stopped: no restart comes.
    h.mgr.stop(s);
    try testing.expectEqual(Manager.Status.stopped, s.status);
    try testing.expect(h.mgr.nextRestartDue() == null);
    for (0..10) |_| {
        h.mgr.tick();
        try h.rt.io.sleep(.fromMilliseconds(5), .awake);
    }
    try testing.expectEqual(Manager.Status.stopped, s.status);
    h.mgr.closeDoc(d);
}

fn fakeWatching(h: *Harness) bool {
    const s = h.server("fake") orelse return false;
    return s.status == .running and h.mgr.watch.?.active();
}

fn watchSent(h: *Harness) bool {
    return h.mgr.nextWatchDue() == null;
}

test "manager: watched-file changes reach the servers that registered for them" {
    var h: Harness = undefined;
    try h.init("watched_files.script", &.{});
    defer h.deinit();
    const d = try h.open("main.zig", "const a = 1;\n");
    defer h.docs.release(d);
    try h.waitFor(fakeWatching);

    const gpa = testing.allocator;
    const zon = try std.fs.path.join(gpa, &.{ h.ws, "build.zig.zon" });
    defer gpa.free(zon);
    const main = try std.fs.path.join(gpa, &.{ h.ws, "main.zig" });
    defer gpa.free(main);
    h.mgr.onFsEvents(&.{ .{ .path = zon, .kind = .created }, .{ .path = main, .kind = .changed } });
    try testing.expect(h.mgr.nextWatchDue() != null);
    try h.waitFor(watchSent);

    var out: [4]*Client = undefined;
    try testing.expectEqual(@as(usize, 1), h.mgr.clientsFor(d, .hover, &out));
    const r = try out[0].requestBlocking(.@"textDocument/hover", .{
        .textDocument = .{ .uri = h.docs.uri(d).? },
        .position = .{ .line = 0, .character = 6 },
    }, .{});
    defer r.deinit();
    try testing.expectEqualStrings("ok", r.ok.value.?.contents.markup_content.value);
    h.mgr.closeDoc(d);
}
