//! `Settings`: the app's settings (E15.F01) on zg_config's
//! `SettingsStore`. Two JSON files feed it: the user's
//! `<config>/settings.json` and the workspace's
//! `<root>/.zigguro/settings.json` (JSONC: comments and trailing commas
//! allowed), over the defaults every package declares in its
//! `settings_schema.zon` (`registry`).
//!
//! Live reload: `poll` re-reads a file whose size or modification time
//! changed and publishes the new snapshot; the workbench calls it from a
//! timer, when the window regains focus and after it saves a file. A file
//! with a syntax error keeps its last good values and reports the error
//! in `problem`. `write` edits one key in a file through
//! `zg_config.json_edit` (comments and layout kept, atomic replace) and
//! reloads it at once.
//!
//! Restricted keys (shells, executables) from the workspace file apply
//! only once the workspace is trusted (`setTrusted`).
//!
//! UI thread only.

const std = @import("std");
const zg_config = @import("zg_config");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const store_mod = zg_config.store;
const SettingsStore = store_mod.SettingsStore;
const Value = zg_config.Value;
const log = std.log.scoped(.settings);

/// Every setting the app knows: zg_config's and the app's own.
pub const registry = zg_config.schema.SchemaRegistry.comptimeInit(.{
    zg_config.settings_schema,
    @import("settings_schema.zon"),
});

/// The file a setting is written to.
pub const Scope = enum {
    user,
    workspace,

    fn kind(s: Scope) store_mod.LayerKind {
        return switch (s) {
            .user => .user,
            .workspace => .workspace,
        };
    }
};

/// The workspace file, relative to the root.
pub const workspace_file = ".zigguro" ++ std.fs.path.sep_str ++ "settings.json";

/// See the module doc.
pub const Settings = struct {
    gpa: Allocator,
    io: Io,
    store: *SettingsStore,
    /// Absolute path of each scope's file (null: no user config folder).
    paths: [2]?[]u8,
    stamps: [2]?Stamp = .{ null, null },
    /// The first problem in each file ("" when none).
    problems: [2]std.ArrayList(u8) = .{ .empty, .empty },
    trusted: bool = false,
    /// Told after a reload changed effective values.
    listeners: std.ArrayList(Listener) = .empty,

    /// A file's identity for change detection; `missing` when absent.
    const Stamp = struct { size: u64, mtime: i96, missing: bool };

    /// Called with the ids whose effective value changed.
    pub const Listener = struct {
        ctx: *anyopaque,
        f: *const fn (ctx: *anyopaque, change: *const store_mod.Change) void,
    };

    /// Creates the settings with `user_path` (absolute, may not exist)
    /// and the workspace file under `root`, and loads both.
    pub fn create(gpa: Allocator, io: Io, user_path: ?[]const u8, root: []const u8) !*Settings {
        const s = try gpa.create(Settings);
        errdefer gpa.destroy(s);
        const up = if (user_path) |p| try gpa.dupe(u8, p) else null;
        errdefer if (up) |p| gpa.free(p);
        const wp = try std.fs.path.join(gpa, &.{ root, workspace_file });
        errdefer gpa.free(wp);
        s.* = .{ .gpa = gpa, .io = io, .store = undefined, .paths = .{ up, wp } };
        s.store = try SettingsStore.init(gpa, io, &registry, .{ .trust = .{ .ctx = s, .isTrustedFn = isTrusted } });
        _ = s.poll();
        return s;
    }

    pub fn destroy(s: *Settings) void {
        s.store.deinit();
        for (s.paths) |p| if (p) |x| s.gpa.free(x);
        for (&s.problems) |*p| p.deinit(s.gpa);
        s.listeners.deinit(s.gpa);
        s.gpa.destroy(s);
    }

    fn isTrusted(ctx: ?*anyopaque, _: ?store_mod.FolderId) bool {
        const s: *Settings = @ptrCast(@alignCast(ctx.?));
        return s.trusted;
    }

    /// Workspace trust changed: restricted workspace keys appear or vanish.
    pub fn setTrusted(s: *Settings, trusted: bool) void {
        if (s.trusted == trusted) return;
        s.trusted = trusted;
        s.store.setTrust(s.store.trust) catch |e| log.err("trust: {t}", .{e});
        _ = s.publish();
    }

    pub fn addListener(s: *Settings, l: Listener) !void {
        try s.listeners.append(s.gpa, l);
    }

    pub fn removeListener(s: *Settings, ctx: *anyopaque) void {
        var i: usize = 0;
        while (i < s.listeners.items.len) {
            if (s.listeners.items[i].ctx == ctx) _ = s.listeners.orderedRemove(i) else i += 1;
        }
    }

    /// The published snapshot.
    pub fn snapshot(s: *const Settings) *const store_mod.Snapshot {
        return s.store.current();
    }

    /// The effective value of `key` (a declared key).
    pub fn get(s: *const Settings, key: []const u8) Value {
        return s.snapshot().getByKey(key, .{}) orelse .null;
    }

    /// The value of `key` for files of language `lang`.
    pub fn getFor(s: *const Settings, key: []const u8, lang: ?[]const u8) Value {
        return s.snapshot().getByKey(key, .{ .lang = lang }) orelse .null;
    }

    pub fn boolean(s: *const Settings, key: []const u8) bool {
        const v = s.get(key);
        return v == .bool and v.bool;
    }

    pub fn int(s: *const Settings, key: []const u8) i64 {
        return switch (s.get(key)) {
            .int => |i| i,
            .float => |f| std.math.lossyCast(i64, f),
            else => 0,
        };
    }

    /// A string or enum value ("" otherwise). Valid until the next reload.
    pub fn string(s: *const Settings, key: []const u8) []const u8 {
        return switch (s.get(key)) {
            .string, .enum_lit => |x| x,
            else => "",
        };
    }

    /// The file of `scope`, if any.
    pub fn path(s: *const Settings, scope: Scope) ?[]const u8 {
        return s.paths[@intFromEnum(scope)];
    }

    /// The first problem in `scope`'s file, or "".
    pub fn problem(s: *const Settings, scope: Scope) []const u8 {
        return s.problems[@intFromEnum(scope)].items;
    }

    /// Re-reads changed files and publishes. Returns whether any effective
    /// value changed.
    pub fn poll(s: *Settings) bool {
        var dirty = false;
        for ([_]Scope{ .user, .workspace }) |sc| {
            const p = s.paths[@intFromEnum(sc)] orelse continue;
            const st = stampOf(s.io, p);
            const old = s.stamps[@intFromEnum(sc)];
            if (old != null and std.meta.eql(old.?, st)) continue;
            s.stamps[@intFromEnum(sc)] = st;
            s.load(sc, p, st.missing);
            dirty = true;
        }
        if (!dirty) return false;
        return s.publish();
    }

    fn publish(s: *Settings) bool {
        const change = (s.store.publish() catch |e| {
            log.err("publish: {t}", .{e});
            return false;
        }) orelse return false;
        if (change.ids.len == 0) return false;
        for (s.listeners.items) |l| l.f(l.ctx, &change);
        return true;
    }

    fn stampOf(io: Io, p: []const u8) Stamp {
        const st = Io.Dir.cwd().statFile(io, p, .{}) catch return .{ .size = 0, .mtime = 0, .missing = true };
        return .{ .size = st.size, .mtime = st.mtime.nanoseconds, .missing = false };
    }

    /// Rebuilds `sc`'s layer from its file. A file that does not parse
    /// keeps the previous layer.
    fn load(s: *Settings, sc: Scope, p: []const u8, missing: bool) void {
        const prob = &s.problems[@intFromEnum(sc)];
        prob.clearRetainingCapacity();
        if (missing) {
            s.store.removeLayer(sc.kind(), null) catch |e| log.err("{s}: {t}", .{ p, e });
            return;
        }
        const src = Io.Dir.cwd().readFileAlloc(s.io, p, s.gpa, .limited(zg_config.zon_load.max_file_bytes)) catch |e| {
            s.say(sc, "{s}: cannot read: {t}", .{ p, e });
            return;
        };
        defer s.gpa.free(src);
        var diags: zg_config.diag.Diags = .init(s.gpa);
        defer diags.deinit();
        if (std.mem.trim(u8, src, " \t\r\n").len == 0) {
            s.store.removeLayer(sc.kind(), null) catch {};
            return;
        }
        var doc = zg_config.jsonc.loadJsonc(s.gpa, src, &diags) catch |e| {
            if (e == error.Invalid and diags.items().len > 0) s.render(sc, p, src, diags.items()[0]) else s.say(sc, "{s}: {t}", .{ p, e });
            return;
        };
        defer doc.deinit();
        _ = s.store.setLayerSource(.{ .kind = sc.kind(), .path = p, .doc = &doc }) catch |e| {
            s.say(sc, "{s}: {t}", .{ p, e });
            return;
        };
        if (s.store.layerDiags(sc.kind(), null)) |d| if (d.items().len > 0) s.render(sc, p, src, d.items()[0]);
    }

    fn say(s: *Settings, sc: Scope, comptime fmt: []const u8, args: anytype) void {
        const prob = &s.problems[@intFromEnum(sc)];
        prob.clearRetainingCapacity();
        prob.print(s.gpa, fmt, args) catch {};
    }

    fn render(s: *Settings, sc: Scope, p: []const u8, src: []const u8, d: zg_config.diag.Diag) void {
        const lc = zg_config.diag.lineCol(src, d.span.start);
        s.say(sc, "{s}:{d}:{d}: {s}", .{ std.fs.path.basename(p), lc.line, lc.col, d.message });
    }

    /// Errors of `write`.
    pub const WriteError = error{
        /// No file for that scope (no user config folder).
        NoFile,
        /// The file has a syntax error: fix it by hand first.
        Invalid,
        NotAnObject,
        OutOfMemory,
        WriteFailed,
    };

    /// Sets `key` to `v` in `scope`'s file (null removes it), creating the
    /// file when needed, then reloads it.
    pub fn write(s: *Settings, scope: Scope, key: []const u8, v: ?Value) WriteError!void {
        return s.writeLang(scope, null, key, v);
    }

    /// `write` inside a language block such as "[zig]".
    pub fn writeLang(s: *Settings, scope: Scope, lang: ?[]const u8, key: []const u8, v: ?Value) WriteError!void {
        const p = s.paths[@intFromEnum(scope)] orelse return error.NoFile;
        const src = Io.Dir.cwd().readFileAlloc(s.io, p, s.gpa, .limited(zg_config.zon_load.max_file_bytes)) catch |e| switch (e) {
            error.FileNotFound => try s.gpa.alloc(u8, 0),
            else => return error.WriteFailed,
        };
        defer s.gpa.free(src);
        const next = if (v) |x|
            try zg_config.json_edit.set(s.gpa, src, lang, key, x)
        else
            try zg_config.json_edit.remove(s.gpa, src, lang, key);
        defer s.gpa.free(next);
        if (std.mem.eql(u8, next, src)) return;
        zg_config.json_edit.writeAtomic(s.io, Io.Dir.cwd(), p, next) catch |e| {
            log.err("{s}: {t}", .{ p, e });
            return error.WriteFailed;
        };
        // Reload now; the stamp may not change within the clock's grain.
        s.stamps[@intFromEnum(scope)] = null;
        _ = s.poll();
    }

    /// Whether `key` is set in `scope`'s file (a non-language value).
    pub fn isSetIn(s: *const Settings, scope: Scope, key: []const u8) bool {
        const id = registry.lookup(key) orelse return false;
        const ins = s.snapshot().inspect(id, .{});
        return ins.layers[@intFromEnum(scope.kind())] != null;
    }

    /// The value of `key` in `scope`'s file, if set there.
    pub fn valueIn(s: *const Settings, scope: Scope, key: []const u8) ?Value {
        const id = registry.lookup(key) orelse return null;
        return s.snapshot().inspect(id, .{}).layers[@intFromEnum(scope.kind())];
    }
};

const testing = std.testing;

test "settings: defaults, user file, live reload and writes" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    const user = try std.fs.path.join(gpa, &.{ root, "user", "settings.json" });
    defer gpa.free(user);

    const s = try Settings.create(gpa, testing.io, user, root);
    defer s.destroy();
    try testing.expectEqual(@as(i64, 13), s.int("editor.fontSize"));
    try testing.expectEqualStrings("system", s.string("workbench.colorTheme"));
    try testing.expect(s.boolean("explorer.confirmDelete"));

    var changes: u32 = 0;
    try s.addListener(.{ .ctx = &changes, .f = struct {
        fn f(ctx: *anyopaque, _: *const store_mod.Change) void {
            const n: *u32 = @ptrCast(@alignCast(ctx));
            n.* += 1;
        }
    }.f });

    // A write creates the file and applies at once.
    try s.write(.user, "editor.fontSize", .{ .int = 16 });
    try testing.expectEqual(@as(i64, 16), s.int("editor.fontSize"));
    try testing.expectEqual(@as(u32, 1), changes);
    try testing.expect(s.isSetIn(.user, "editor.fontSize"));
    try testing.expect(!s.isSetIn(.workspace, "editor.fontSize"));

    // Hand edits (with comments) are picked up by poll.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "user/settings.json", .data = "{\n  // mine\n  \"editor.fontSize\": 18,\n  \"files.autoSave\": \"afterDelay\",\n}\n" });
    s.stamps[0] = null; // the same second may not change the stamp
    try testing.expect(s.poll());
    try testing.expectEqual(@as(i64, 18), s.int("editor.fontSize"));
    try testing.expectEqualStrings("afterDelay", s.string("files.autoSave"));
    try testing.expectEqualStrings("", s.problem(.user));

    // The workspace file wins over the user file.
    try s.write(.workspace, "editor.fontSize", .{ .int = 20 });
    try testing.expectEqual(@as(i64, 20), s.int("editor.fontSize"));
    try s.write(.workspace, "editor.fontSize", null);
    try testing.expectEqual(@as(i64, 18), s.int("editor.fontSize"));

    // A syntax error keeps the last good values and says where.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "user/settings.json", .data = "{\n  \"editor.fontSize\": 30,,\n}\n" });
    s.stamps[0] = null;
    _ = s.poll();
    try testing.expectEqual(@as(i64, 18), s.int("editor.fontSize"));
    try testing.expect(std.mem.startsWith(u8, s.problem(.user), "settings.json:3:1: expected a string key"));
    try testing.expectError(error.Invalid, s.write(.user, "editor.fontSize", .{ .int = 12 }));

    // Unknown keys and bad values are reported, valid keys still apply.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "user/settings.json", .data = "{ \"editor.fontSize\": 14, \"editor.fontSizee\": 1 }" });
    s.stamps[0] = null;
    _ = s.poll();
    try testing.expectEqual(@as(i64, 14), s.int("editor.fontSize"));
    try testing.expect(s.problem(.user).len > 0);

    // Deleting the file goes back to defaults.
    try tmp.dir.deleteFile(testing.io, "user/settings.json");
    _ = s.poll();
    try testing.expectEqual(@as(i64, 13), s.int("editor.fontSize"));
}

test "settings: restricted workspace keys need trust" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    try tmp.dir.createDirPath(testing.io, ".zigguro");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = ".zigguro/settings.json", .data = "{ \"terminal.integrated.shell\": \"/evil/sh\", \"editor.tabSize\": 2 }" });
    const s = try Settings.create(gpa, testing.io, null, root);
    defer s.destroy();
    try testing.expectEqualStrings("", s.string("terminal.integrated.shell"));
    try testing.expectEqual(@as(i64, 2), s.int("editor.tabSize"));
    s.setTrusted(true);
    try testing.expectEqualStrings("/evil/sh", s.string("terminal.integrated.shell"));
    try testing.expectError(error.NoFile, s.write(.user, "editor.tabSize", .{ .int = 3 }));
}

test "settings: language blocks" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    const user = try std.fs.path.join(gpa, &.{ root, "settings.json" });
    defer gpa.free(user);
    const s = try Settings.create(gpa, testing.io, user, root);
    defer s.destroy();
    try s.writeLang(.user, "[zig]", "editor.tabSize", .{ .int = 4 });
    try s.write(.user, "editor.tabSize", .{ .int = 2 });
    try testing.expectEqual(@as(i64, 2), s.int("editor.tabSize"));
    try testing.expectEqual(@as(i64, 4), s.getFor("editor.tabSize", "zig").int);
}
