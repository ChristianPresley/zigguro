//! The notes sidebar, properties editor and vault setup in a headless
//! zg_gui window over a fixture vault.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_notes = @import("zg_notes");
const ports = @import("ports.zig");
const model_mod = @import("sidebar_model.zig");
const sidebar = @import("notes_sidebar.zig");
const properties_panel = @import("properties_panel.zig");
const vault_setup = @import("vault_setup.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const TestApp = zg_gui.testing.TestApp;
const FileId = zg_notes.FileId;

/// An in-memory vault: files, the index, and recorded changes applied
/// back to the files (as the app's apply port would).
const Vault = struct {
    vault: zg_notes.Vault,
    ix: *zg_notes.NoteIndex,
    arena: std.heap.ArenaAllocator,
    files: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    ids: std.StringArrayHashMapUnmanaged(FileId) = .empty,
    next: u32 = 0,
    applied: u32 = 0,
    last_label: []const u8 = "",
    last: []const ports.FileChange = &.{},

    fn init(v: *Vault) !void {
        v.* = .{ .vault = .{ .id = .of(0), .root = .of(0), .rel_dir = "", .config = .{} }, .ix = undefined, .arena = .init(gpa) };
        v.ix = try zg_notes.NoteIndex.init(gpa, io, &.{v.vault});
    }

    fn deinit(v: *Vault) void {
        v.ix.deinit();
        v.arena.deinit();
    }

    fn put(v: *Vault, path: []const u8, bytes: []const u8) !FileId {
        const a = v.arena.allocator();
        const g = try v.ids.getOrPut(a, path);
        if (!g.found_existing) {
            g.key_ptr.* = try a.dupe(u8, path);
            g.value_ptr.* = .{ .index = v.next, .gen = 0 };
            v.next += 1;
        }
        try v.files.put(a, g.key_ptr.*, try a.dupe(u8, bytes));
        try v.ix.indexNote(g.value_ptr.*, .of(0), path, bytes);
        try v.ix.commit();
        return g.value_ptr.*;
    }

    fn read(ctx: *anyopaque, a: std.mem.Allocator, id: FileId, path: []const u8) anyerror!?[]u8 {
        _ = id;
        const v: *Vault = @ptrCast(@alignCast(ctx));
        return try a.dupe(u8, v.files.get(path) orelse return null);
    }

    fn apply(ctx: *anyopaque, label: []const u8, changes: []const ports.FileChange) anyerror!u64 {
        const v: *Vault = @ptrCast(@alignCast(ctx));
        const a = v.arena.allocator();
        v.applied += 1;
        v.last_label = try a.dupe(u8, label);
        const copy = try a.alloc(ports.FileChange, changes.len);
        for (changes, copy) |c, *o| o.* = .{ .path = try a.dupe(u8, c.path), .base = if (c.base) |b| try a.dupe(u8, b) else null, .new = try a.dupe(u8, c.new) };
        v.last = copy;
        for (copy) |c| _ = try v.put(c.path, c.new);
        return 500 + v.applied;
    }

    fn options(v: *Vault) model_mod.Options {
        return .{ .gpa = gpa, .io = io, .ix = v.ix, .vault = &v.vault, .content = .{ .ctx = v, .read = read }, .apply = .{ .ctx = v, .apply = apply } };
    }
};

/// Holds spawned jobs until `runAll`.
const Deferred = struct {
    jobs: [8]Job = undefined,
    n: usize = 0,

    const Job = struct { f: *const fn (*anyopaque) void, arg: *anyopaque };

    fn run(ctx: *anyopaque, f: *const fn (arg: *anyopaque) void, arg: *anyopaque) void {
        const d: *Deferred = @ptrCast(@alignCast(ctx));
        d.jobs[d.n] = .{ .f = f, .arg = arg };
        d.n += 1;
    }

    fn runAll(d: *Deferred) void {
        for (d.jobs[0..d.n]) |j| j.f(j.arg);
        d.n = 0;
    }
};

const Opened = struct {
    path: [128]u8 = undefined,
    len: usize = 0,
    range: ?[2]u32 = null,
    query: [128]u8 = undefined,
    qlen: usize = 0,

    fn open(ctx: *anyopaque, path: []const u8, range: ?[2]u32, to_side: bool) void {
        _ = to_side;
        const o: *Opened = @ptrCast(@alignCast(ctx));
        @memcpy(o.path[0..path.len], path);
        o.len = path.len;
        o.range = range;
    }

    fn search(ctx: *anyopaque, q: []const u8) void {
        const o: *Opened = @ptrCast(@alignCast(ctx));
        @memcpy(o.query[0..q.len], q);
        o.qlen = q.len;
    }
};

const Fx = struct {
    v: Vault,
    m: *model_mod.NotesSidebarModel,
    view: *sidebar.SidebarView,
    t: *TestApp,
    opened: Opened = .{},
    deferred: Deferred = .{},

    fn init(f: *Fx, spawn: bool) !void {
        try f.v.init();
        f.opened = .{};
        f.deferred = .{};
        var o = f.v.options();
        if (spawn) o.spawn = .{ .ctx = &f.deferred, .run = Deferred.run };
        f.m = try model_mod.NotesSidebarModel.init(o);
        f.view = try sidebar.SidebarView.init(gpa, f.m, .{ .open = .{ .ctx = &f.opened, .open = Opened.open }, .search = .{ .ctx = &f.opened, .f = Opened.search } });
        f.t = try TestApp.init(gpa, .{ .root = .of(f.view), .size = .{ .w = 420, .h = 1400 } });
    }

    fn deinit(f: *Fx) void {
        f.deferred.runAll();
        f.t.deinit();
        f.view.deinit();
        f.m.deinit();
        f.v.deinit();
    }

    fn settle(f: *Fx) void {
        f.t.win.markAllDirty();
        _ = f.t.settle();
    }

    fn activate(f: *Fx, path: []const u8) void {
        f.m.setActiveNote(f.v.ids.get(path).?);
        f.settle();
    }
};

fn fixture(v: *Vault) !void {
    _ = try v.put("Alpha.md", "---\nstatus: open\ndue: 2026-10-20\ndone: false\ntags: [proj/alpha, urgent]\n---\n# Alpha\nSee [[Beta]] and [[Nowhere]] and [[Dup]].\n");
    _ = try v.put("Beta.md", "# Beta\nBack to [[Alpha]] here.\nAgain [[Alpha#Alpha|alpha]].\n#proj/beta\n");
    _ = try v.put("Gamma.md", "# Gamma\nGamma mentions Alpha in passing.\nAnd [[Alpha]].\n#proj/alpha\n");
    _ = try v.put("Delta.md", "# Delta\nalpha is lower case here.\n");
    _ = try v.put("a/Dup.md", "# Dup\n");
    _ = try v.put("b/Dup.md", "# Dup\n");
}

test "sidebar: backlinks grouped by source with snippets" {
    var f: Fx = undefined;
    try f.init(false);
    defer f.deinit();
    try fixture(&f.v);
    f.activate("Alpha.md");
    try testing.expectEqual(@as(usize, 2), f.m.backlinks.len);
    try testing.expectEqualStrings("Beta", f.m.backlinks[0].title);
    try testing.expectEqual(@as(usize, 2), f.m.backlinks[0].rows.len);
    const r = f.m.backlinks[0].rows[0];
    try testing.expectEqualStrings("Back to [[Alpha]] here.", r.text);
    try testing.expectEqualStrings("[[Alpha]]", r.text[r.highlight[0]..r.highlight[1]]);
    try testing.expectEqualStrings("Gamma", f.m.backlinks[1].title);
    try testing.expect(f.t.find(.{ .role = .group, .name = "Backlinks" }) != null);
    try testing.expect(f.t.find(.{ .name = "Linked from Beta: Back to [[Alpha]] here." }) != null);
    try f.t.click(.{ .name = "Linked from Gamma: And [[Alpha]]." });
    try testing.expectEqualStrings("Gamma.md", f.opened.path[0..f.opened.len]);
    try testing.expect(f.opened.range != null);
}

test "sidebar: unlinked mentions lazily computed and cancelled on note switch" {
    var f: Fx = undefined;
    try f.init(true);
    defer f.deinit();
    try fixture(&f.v);
    f.activate("Alpha.md");
    try testing.expect(f.m.unlinkedState() == .idle);
    try f.t.click(.{ .role = .button, .name = "Show unlinked mentions" });
    f.settle();
    try testing.expect(f.m.unlinkedState() == .running);
    // Switching notes before the job runs drops its result.
    f.activate("Beta.md");
    f.deferred.runAll();
    try testing.expect(f.m.unlinkedState() == .idle);

    f.activate("Alpha.md");
    try f.m.requestUnlinked();
    f.deferred.runAll();
    f.settle();
    const rows = f.m.unlinkedState().done;
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("Gamma", rows[0].source_title);
    try testing.expectEqualStrings("Delta", rows[1].source_title);
    try testing.expectEqualStrings("alpha", rows[1].text[rows[1].highlight[0]..rows[1].highlight[1]]);
}

test "sidebar: link mention produces changeset with [[Title]] or [[Title|text]]" {
    var f: Fx = undefined;
    try f.init(false);
    defer f.deinit();
    try fixture(&f.v);
    f.activate("Alpha.md");
    try f.t.click(.{ .role = .button, .name = "Show unlinked mentions" });
    f.settle();
    try testing.expectEqual(@as(usize, 2), f.m.unlinkedState().done.len);
    try f.t.click(.{ .role = .button, .name = "Link", .within = f.t.find(.{ .name_contains = "Mentioned in Delta" }) });
    try testing.expectEqual(@as(u32, 1), f.v.applied);
    try testing.expectEqualStrings("Delta.md", f.v.last[0].path);
    try testing.expectEqualStrings("# Delta\n[[Alpha|alpha]] is lower case here.\n", f.v.last[0].new);
    // What is left, by exact text, through Link all.
    try f.m.requestUnlinked();
    f.settle();
    try testing.expectEqual(@as(usize, 1), f.m.unlinkedState().done.len);
    _ = (try f.m.linkAll()) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("# Gamma\nGamma mentions [[Alpha]] in passing.\nAnd [[Alpha]].\n#proj/alpha\n", f.v.last[0].new);
}

test "sidebar: outgoing pane shows unresolved with create action" {
    var f: Fx = undefined;
    try f.init(false);
    defer f.deinit();
    try fixture(&f.v);
    f.activate("Alpha.md");
    try testing.expectEqual(@as(usize, 3), f.m.outgoing.len);
    try testing.expectEqual(model_mod.OutKind.note, f.m.outgoing[0].kind);
    try testing.expectEqual(model_mod.OutKind.unresolved, f.m.outgoing[1].kind);
    try testing.expectEqual(model_mod.OutKind.ambiguous, f.m.outgoing[2].kind);
    try testing.expectEqual(@as(usize, 2), f.m.outgoing[2].candidates.len);
    try testing.expect(f.t.find(.{ .name = "Dup (ambiguous)" }) != null);
    try f.t.click(.{ .role = .button, .name = "Create Nowhere.md" });
    try testing.expectEqual(@as(u32, 1), f.v.applied);
    try testing.expect(f.v.last[0].base == null);
    try testing.expectEqualStrings("Nowhere.md", f.opened.path[0..f.opened.len]);
}

test "sidebar: tags pane counts and nested display" {
    var f: Fx = undefined;
    try f.init(false);
    defer f.deinit();
    try fixture(&f.v);
    f.activate("Alpha.md");
    try testing.expect(f.t.find(.{ .role = .treeitem, .name = "#proj (3)" }) != null);
    try testing.expect(f.t.find(.{ .role = .treeitem, .name = "#urgent (1)" }) != null);
    try testing.expect(f.t.find(.{ .role = .treeitem, .name = "#alpha (2)" }) == null);
    try f.t.click(.{ .role = .treeitem, .name = "#proj (3)" });
    f.settle();
    try testing.expect(f.t.find(.{ .role = .treeitem, .name = "#alpha (2)" }) != null);
    try testing.expect(f.t.find(.{ .role = .treeitem, .name = "#beta (1)" }) != null);
    try f.t.doubleClick(.{ .role = .treeitem, .name = "#alpha (2)" });
    try testing.expectEqualStrings("tag:#proj/alpha", f.opened.query[0..f.opened.qlen]);
    // Filtering keeps the ancestors of matches.
    try f.m.setTagFilter("beta");
    f.settle();
    try testing.expect(f.t.find(.{ .role = .treeitem, .name = "#urgent (1)" }) == null);
    try testing.expect(f.t.find(.{ .role = .treeitem, .name = "#proj (3)" }) != null);
    try f.m.setTagFilter("");
    try f.m.setTagSort(.count);
    try testing.expectEqualStrings("proj", f.m.tagOf(f.m.tagsSource().child(null, 0)).?.name);
}

test "properties: date edit rewrites only that value" {
    var f: Fx = undefined;
    try f.init(false);
    defer f.deinit();
    try fixture(&f.v);
    f.activate("Alpha.md");
    try testing.expectEqual(@as(usize, 4), f.m.props.len);
    const before = f.v.files.get("Alpha.md").?;
    try f.t.click(.{ .role = .textbox, .name = "due" });
    f.t.press(.end, .{});
    for (0..2) |_| f.t.press(.backspace, .{});
    f.t.typeText("31");
    f.t.press(.enter, .{});
    f.settle();
    try testing.expectEqual(@as(u32, 1), f.v.applied);
    const after = f.v.last[0].new;
    try testing.expectEqual(before.len, after.len);
    var diff: usize = 0;
    for (before, after) |x, y| diff += @intFromBool(x != y);
    try testing.expectEqual(@as(usize, 2), diff);
    try testing.expect(std.mem.indexOf(u8, after, "due: 2026-10-31\n") != null);
    // A bad date is refused.
    try f.t.click(.{ .role = .textbox, .name = "due" });
    f.t.press(.end, .{});
    f.t.typeText("x");
    f.t.press(.enter, .{});
    f.settle();
    try testing.expectEqual(@as(u32, 1), f.v.applied);
    // Checkbox and chips.
    try f.t.click(.{ .role = .checkbox, .name = "done" });
    f.settle();
    try testing.expect(std.mem.indexOf(u8, f.v.last[0].new, "done: true\n") != null);
    try f.t.click(.{ .role = .button, .name = "Remove urgent" });
    f.settle();
    try testing.expect(std.mem.indexOf(u8, f.v.last[0].new, "tags: [proj/alpha]\n") != null);
    try testing.expectEqual(@as(f64, 4.5), properties_panel.parseValue(.number, "4.5").?.float);
    try testing.expect(properties_panel.parseValue(.number, "four") == null);
}

test "properties: conflicting type shows warning" {
    var f: Fx = undefined;
    try f.init(false);
    defer f.deinit();
    _ = try f.v.put("a.md", "---\nrating: 4\n---\n");
    _ = try f.v.put("b.md", "---\nrating: 5\n---\n");
    _ = try f.v.put("c.md", "---\nrating: lots\n---\n");
    f.activate("c.md");
    try testing.expect(f.m.props[0].conflict);
    try testing.expect(f.t.find(.{ .role = .img, .name = "Value does not match the number type" }) != null);
    f.activate("a.md");
    try testing.expect(!f.m.props[0].conflict);
    try testing.expect(f.t.find(.{ .test_id = "prop-conflict" }) == null);
}

const Store = struct {
    folder: [64]u8 = undefined,
    len: usize = 0,
    d: ?vault_setup.Decision = null,
    puts: u32 = 0,

    fn get(ctx: *anyopaque, folder: []const u8) ?vault_setup.Decision {
        const s: *Store = @ptrCast(@alignCast(ctx));
        if (s.d == null or !std.mem.eql(u8, s.folder[0..s.len], folder)) return null;
        return s.d;
    }

    fn put(ctx: *anyopaque, folder: []const u8, d: vault_setup.Decision) anyerror!void {
        const s: *Store = @ptrCast(@alignCast(ctx));
        @memcpy(s.folder[0..folder.len], folder);
        s.len = folder.len;
        s.d = d;
        s.puts += 1;
    }
};

const Banner = struct {
    s: *vault_setup.VaultSetup,
    got: ?vault_setup.Choice = null,
    pub fn build(b: *Banner, ui: *zg_gui.Ui) void {
        ui.open(.{ .style = .{ .w = .{ .pct = 100 }, .dir = .column } });
        defer ui.close();
        if (vault_setup.vaultBanner(ui, b.s)) |c| b.got = c;
    }
};

test "vault_setup: .obsidian detection prompts once and persists decision" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".obsidian");
    try tmp.dir.writeFile(io, .{ .sub_path = ".obsidian/app.json", .data = "{\"newFileLocation\":\"folder\",\"newFileFolderPath\":\"inbox\"}" });
    var store: Store = .{};
    var s: vault_setup.VaultSetup = .{ .gpa = gpa, .store = .{ .ctx = &store, .get = Store.get, .put = Store.put } };
    defer s.deinit();
    var b: Banner = .{ .s = &s };
    const t = try TestApp.init(gpa, .{ .root = .of(&b) });
    defer t.deinit();

    try testing.expect(try s.check(io, "notes", tmp.dir));
    // Asked once even if checked again.
    try testing.expect(!try s.check(io, "notes", tmp.dir));
    t.win.markAllDirty();
    _ = t.settle();
    try testing.expect(t.find(.{ .role = .status, .name = "Treat notes as a notes vault?" }) != null);
    try t.click(.{ .role = .button, .name = "Yes" });
    const cfg = (try s.answer(b.got.?)).?;
    try testing.expectEqualStrings("inbox", cfg.new_note_folder);
    try testing.expectEqual(@as(u32, 1), store.puts);
    try testing.expectEqual(vault_setup.Decision.vault, store.d.?);
    // Decided: no prompt next time.
    try testing.expect(!try s.check(io, "notes", tmp.dir));
    t.win.markAllDirty();
    _ = t.settle();
    try testing.expect(t.find(.{ .test_id = "vault-banner" }) == null);
    // Not now lasts for the session only.
    try testing.expect(try s.check(io, "other", tmp.dir));
    try testing.expect(try s.answer(.not_now) == null);
    try testing.expect(!try s.check(io, "other", tmp.dir));
    try testing.expectEqual(@as(u32, 1), store.puts);
    // No vault markers: no prompt.
    var plain = testing.tmpDir(.{});
    defer plain.cleanup();
    try testing.expect(!try s.check(io, "plain", plain.dir));
}
