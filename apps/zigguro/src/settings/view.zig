//! `SettingsView`: the settings editor (E15.F02.S01), a tab generated from
//! the schema. A search box filters by key, title, description and enum
//! values (`@modified` lists what the chosen file sets); User and
//! Workspace pick the file edits go to. Each setting shows its title,
//! description and a control for its type: a checkbox, a button per
//! enum value, or a text field (numbers, strings, paths; lists and
//! objects as one line of JSON) that is validated against the schema on
//! Enter or when it loses focus. "Reset" removes the key from the file.
//! "Edit in settings.json" opens the file itself in an editor.
//!
//! Edits go through `Settings.write`, so they land in the JSON file with
//! its comments kept, and apply at once.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_config = @import("zg_config");
const service = @import("service.zig");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const Settings = service.Settings;
const Scope = service.Scope;
const Value = zg_config.Value;
const SettingId = zg_config.schema.SettingId;
const SettingDef = zg_config.schema.SettingDef;
const reg = &service.registry;

/// Category order: the key's first segment.
const categories = [_][]const u8{ "workbench", "editor", "files", "explorer", "terminal", "git", "keyboard", "commands" };

/// See the module doc.
pub const SettingsView = struct {
    gpa: Allocator,
    settings: *Settings,
    scope: Scope = .user,
    search: zg_gui.w.TextBuffer,
    /// Every setting in display order.
    order: []SettingId,
    /// Text of each text-edited setting, by id (boxed: the fields hold
    /// pointers to their buffers across builds).
    fields: std.AutoHashMapUnmanaged(u32, *Field) = .empty,
    /// The last outcome, under the header.
    status: [256]u8 = undefined,
    status_len: usize = 0,
    status_bad: bool = false,
    /// A change made by a control, written after the build.
    pending: ?Pending = null,
    /// Opens a scope's settings.json in an editor.
    open_json: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, scope: Scope) void } = null,

    const Field = struct {
        buf: zg_gui.w.TextBuffer,
        /// The value text last put in `buf` (to refresh when the file changes).
        shown: std.ArrayList(u8) = .empty,
        invalid: bool = false,
        focused: bool = false,
    };

    const Pending = union(enum) {
        set: struct { id: SettingId, value: Value },
        /// Parse and validate the field's text, then set.
        commit: SettingId,
        reset: SettingId,
        open_json,
    };

    pub fn create(gpa: Allocator, settings: *Settings) !*SettingsView {
        const v = try gpa.create(SettingsView);
        errdefer gpa.destroy(v);
        var ids: std.ArrayList(SettingId) = .empty;
        errdefer ids.deinit(gpa);
        for (0..reg.count()) |i| {
            const id: SettingId = @enumFromInt(i);
            if (reg.isTombstone(id)) continue;
            if (reg.def(id).deprecated != null) continue;
            try ids.append(gpa, id);
        }
        std.sort.pdq(SettingId, ids.items, {}, lessThan);
        v.* = .{ .gpa = gpa, .settings = settings, .search = try .init(gpa, ""), .order = try ids.toOwnedSlice(gpa) };
        return v;
    }

    pub fn destroy(v: *SettingsView) void {
        var it = v.fields.valueIterator();
        while (it.next()) |f| {
            f.*.buf.deinit();
            f.*.shown.deinit(v.gpa);
            v.gpa.destroy(f.*);
        }
        v.fields.deinit(v.gpa);
        v.search.deinit();
        v.gpa.free(v.order);
        v.gpa.destroy(v);
    }

    fn categoryRank(key: []const u8) usize {
        const head = key[0 .. std.mem.indexOfScalar(u8, key, '.') orelse key.len];
        for (categories, 0..) |c, i| if (std.mem.eql(u8, c, head)) return i;
        return categories.len;
    }

    fn lessThan(_: void, a: SettingId, b: SettingId) bool {
        const da = reg.def(a);
        const db = reg.def(b);
        const ra = categoryRank(da.key);
        const rb = categoryRank(db.key);
        if (ra != rb) return ra < rb;
        if (ra == categories.len) {
            const ha = da.key[0 .. std.mem.indexOfScalar(u8, da.key, '.') orelse da.key.len];
            const hb = db.key[0 .. std.mem.indexOfScalar(u8, db.key, '.') orelse db.key.len];
            const o = std.mem.order(u8, ha, hb);
            if (o != .eq) return o == .lt;
        }
        if (da.order != db.order) return da.order < db.order;
        return std.mem.lessThan(u8, da.key, db.key);
    }

    fn say(v: *SettingsView, bad: bool, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&v.status, fmt, args) catch v.status[0..v.status.len];
        v.status_len = s.len;
        v.status_bad = bad;
    }

    /// Whether `d` matches the search text (case-insensitive words).
    fn matches(v: *SettingsView, d: *const SettingDef) bool {
        var words = std.mem.tokenizeScalar(u8, v.search.slice(), ' ');
        while (words.next()) |w| {
            if (std.mem.eql(u8, w, "@modified")) {
                if (!v.settings.isSetIn(v.scope, d.key)) return false;
                continue;
            }
            if (containsIgnoreCase(d.key, w) or containsIgnoreCase(d.title, w) or containsIgnoreCase(d.description, w)) continue;
            const in_enum = for (d.enum_values) |e| {
                if (containsIgnoreCase(e, w)) break true;
            } else false;
            if (!in_enum) return false;
        }
        return true;
    }

    pub fn build(v: *SettingsView, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } }, .role = .group, .label = "Settings" });
        defer ui.close();
        v.header(ui);
        _ = zg_gui.w.scrollArea(ui, .{ .style = .{ .grow = 1, .basis = .{ .px = 0 }, .dir = .column, .gap = 2, .padding = .xy(16, 8) }, .test_id = "settings-list" });
        var shown: usize = 0;
        var last_cat: usize = std.math.maxInt(usize);
        var last_head: []const u8 = "";
        for (v.order) |id| {
            const d = reg.def(id);
            if (!v.matches(d)) continue;
            const cat = categoryRank(d.key);
            const head = d.key[0 .. std.mem.indexOfScalar(u8, d.key, '.') orelse d.key.len];
            if (cat != last_cat or (cat == categories.len and !std.mem.eql(u8, head, last_head))) {
                last_cat = cat;
                last_head = head;
                var hb: [48]u8 = undefined;
                ui.id(@as(u64, 1 << 40) | cat);
                ui.open(.{ .style = .{ .padding = .{ .t = if (shown == 0) 4 else 16, .b = 4 }, .shrink = 0 } });
                ui.text(titleCase(&hb, head), .{ .style = .{ .size = 16, .weight = 600 }, .theme_size = false, .wrap = false });
                ui.close();
            }
            shown += 1;
            ui.id(id.index());
            v.row(ui, id, d);
        }
        if (shown == 0) ui.text("No settings match the search.", .{ .color = .fg_muted });
        ui.close();
        if (v.pending) |p| {
            v.pending = null;
            v.apply(p);
            ui.window().markAllDirty();
        }
    }

    fn header(v: *SettingsView, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .column, .padding = .xy(16, 8), .gap = 6, .shrink = 0, .bg = .{ .token = .bg_elevated } } });
        defer ui.close();
        ui.open(.{ .style = .{ .dir = .row, .align_items = .center, .gap = 6 } });
        ui.text("Settings", .{ .style = .{ .size = 18, .weight = 600 }, .theme_size = false, .wrap = false });
        ui.open(.{ .style = .{ .grow = 1 } });
        ui.close();
        for ([_]Scope{ .user, .workspace }) |sc| {
            ui.id(@intFromEnum(sc));
            const label = if (sc == .user) "User" else "Workspace";
            if (zg_gui.w.button(ui, .{ .label = label, .variant = if (v.scope == sc) .primary else .ghost }).clicked) {
                v.scope = sc;
                v.resyncFields();
                ui.window().markAllDirty();
            }
        }
        if (zg_gui.w.button(ui, .{ .label = "Edit in settings.json", .variant = .ghost }).clicked) v.pending = .open_json;
        ui.close();
        _ = zg_gui.w.textField(ui, .{ .buffer = &v.search, .placeholder = "Search settings (@modified: only what this file sets)", .a11y_label = "Search settings" });
        if (v.settings.path(v.scope)) |p| {
            ui.text(p, .{ .color = .fg_muted, .wrap = false });
        } else ui.text("No user settings folder (no home directory)", .{ .color = .warning, .wrap = false });
        const prob = v.settings.problem(v.scope);
        if (prob.len > 0) ui.text(prob, .{ .color = .danger });
        if (v.status_len > 0) ui.text(v.status[0..v.status_len], .{ .color = if (v.status_bad) .danger else .fg_muted });
    }

    /// The value the chosen scope shows: the user file's value or the
    /// default for User, the effective value for Workspace.
    fn shownValue(v: *SettingsView, id: SettingId) Value {
        const d = reg.def(id);
        return switch (v.scope) {
            .user => v.settings.valueIn(.user, d.key) orelse reg.default(id),
            .workspace => v.settings.get(d.key),
        };
    }

    fn row(v: *SettingsView, ui: *Ui, id: SettingId, d: *const SettingDef) void {
        ui.open(.{ .style = .{ .dir = .column, .gap = 3, .padding = .xy(0, 6), .shrink = 0 } });
        defer ui.close();
        const set_here = v.settings.isSetIn(v.scope, d.key);
        const other: Scope = if (v.scope == .user) .workspace else .user;
        ui.open(.{ .style = .{ .dir = .row, .align_items = .center, .gap = 8 } });
        var tb: [128]u8 = undefined;
        ui.text(std.fmt.bufPrint(&tb, "{s}{s}", .{ if (set_here) "\u{2022} " else "", d.title }) catch d.title, .{ .style = .{ .weight = 600 }, .wrap = false });
        ui.text(d.key, .{ .color = .fg_muted, .wrap = false, .style = .{ .size = 11 } });
        if (v.settings.isSetIn(other, d.key)) {
            ui.text(if (other == .workspace) "(also set in Workspace, which wins)" else "(also set in User)", .{ .color = .warning, .wrap = false, .style = .{ .size = 11 } });
        }
        if (d.restricted and v.scope == .workspace and !v.settings.trusted)
            ui.text("(applies once the folder is trusted)", .{ .color = .warning, .wrap = false, .style = .{ .size = 11 } });
        ui.open(.{ .style = .{ .grow = 1 } });
        ui.close();
        if (set_here) {
            ui.id(2);
            if (zg_gui.w.button(ui, .{ .label = "Reset", .variant = .ghost }).clicked) v.pending = .{ .reset = id };
        }
        ui.close();
        const val = v.shownValue(id);
        if (d.type != .bool and d.description.len > 0) ui.text(d.description, .{ .color = .fg_muted });
        switch (d.type) {
            .bool => {
                var b = val == .bool and val.bool;
                ui.id(3);
                if (zg_gui.w.checkbox(ui, if (d.description.len > 0) d.description else d.title, &b).changed)
                    v.pending = .{ .set = .{ .id = id, .value = .{ .bool = b } } };
            },
            .enum_ => {
                const cur = switch (val) {
                    .string, .enum_lit => |x| x,
                    else => "",
                };
                ui.open(.{ .style = .{ .dir = .row, .gap = 4, .wrap = true } });
                for (d.enum_values, 0..) |e, i| {
                    ui.id(100 + i);
                    if (zg_gui.w.button(ui, .{ .label = e, .variant = if (std.mem.eql(u8, e, cur)) .primary else .secondary }).clicked)
                        v.pending = .{ .set = .{ .id = id, .value = .{ .string = e } } };
                }
                ui.close();
                for (d.enum_values, 0..) |e, i| if (std.mem.eql(u8, e, cur) and i < d.enum_descriptions.len) {
                    ui.text(d.enum_descriptions[i], .{ .color = .fg_muted, .style = .{ .size = 11 } });
                };
            },
            else => v.textRow(ui, id, d, val),
        }
    }

    fn textRow(v: *SettingsView, ui: *Ui, id: SettingId, d: *const SettingDef, val: Value) void {
        const f = v.fields.get(id.index()) orelse blk: {
            const nf = v.gpa.create(Field) catch return;
            nf.* = .{ .buf = zg_gui.w.TextBuffer.init(v.gpa, "") catch {
                v.gpa.destroy(nf);
                return;
            } };
            v.fields.put(v.gpa, id.index(), nf) catch {
                nf.buf.deinit();
                v.gpa.destroy(nf);
                return;
            };
            break :blk nf;
        };
        // Refresh from the file unless the user is typing in it.
        if (!f.focused) {
            var tmp: std.Io.Writer.Allocating = .init(v.gpa);
            defer tmp.deinit();
            valueText(&tmp.writer, val) catch {};
            if (!std.mem.eql(u8, tmp.written(), f.shown.items)) {
                f.shown.clearRetainingCapacity();
                f.shown.appendSlice(v.gpa, tmp.written()) catch {};
                f.buf.setText(tmp.written()) catch {};
                f.invalid = false;
            }
        }
        ui.open(.{ .style = .{ .dir = .row, .align_items = .center, .gap = 6 } });
        defer ui.close();
        ui.id(4);
        const placeholder = switch (d.type) {
            .array, .object, .any => "JSON, e.g. [\"a\", \"b\"] or { \"**/build\": true }",
            .path => "A path (empty: default)",
            else => "",
        };
        ui.open(.{ .style = .{ .grow = 1, .max_w = 560 } });
        const r = zg_gui.w.textField(ui, .{ .buffer = &f.buf, .placeholder = placeholder, .invalid = f.invalid, .font = if (d.type == .array or d.type == .object) .mono else .ui, .a11y_label = d.title });
        ui.close();
        const was = f.focused;
        f.focused = r.focused;
        if (r.submitted or (was and r.focus_lost) or (was and !r.focused and !std.mem.eql(u8, f.buf.slice(), f.shown.items))) {
            if (!std.mem.eql(u8, f.buf.slice(), f.shown.items)) v.pending = .{ .commit = id };
        }
        if (d.type == .array or d.type == .object or d.type == .any) {
            ui.id(5);
            if (zg_gui.w.button(ui, .{ .label = "Edit in settings.json", .variant = .ghost }).clicked) v.pending = .open_json;
        }
    }

    /// Text fields show their value from the newly chosen file.
    fn resyncFields(v: *SettingsView) void {
        var it = v.fields.valueIterator();
        while (it.next()) |f| {
            f.*.focused = false;
            f.*.shown.clearRetainingCapacity();
            f.*.shown.append(v.gpa, 0) catch {};
        }
    }

    fn apply(v: *SettingsView, p: Pending) void {
        switch (p) {
            .open_json => if (v.open_json) |o| o.f(o.ctx, v.scope),
            .set => |s| v.write(s.id, s.value),
            .reset => |id| {
                const d = reg.def(id);
                v.settings.write(v.scope, d.key, null) catch |e| return v.writeFailed(e);
                if (v.fields.get(id.index())) |f| f.focused = false;
                v.say(false, "Reset {s} in {s} settings", .{ d.key, scopeName(v.scope) });
            },
            .commit => |id| v.commit(id),
        }
    }

    /// Parses and validates a text field, then writes it.
    fn commit(v: *SettingsView, id: SettingId) void {
        const d = reg.def(id);
        const f = v.fields.get(id.index()) orelse return;
        var arena_state: std.heap.ArenaAllocator = .init(v.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const text = f.buf.slice();
        // String-like settings take the text as is; the rest is JSON.
        const json = switch (d.type) {
            .string, .path, .glob, .color, .keybinding, .command_id, .when_clause => blk: {
                var w: std.Io.Writer.Allocating = .init(arena);
                zg_config.value.writeJsonString(&w.writer, text) catch return;
                break :blk w.written();
            },
            else => text,
        };
        var diags: zg_config.diag.Diags = .init(v.gpa);
        defer diags.deinit();
        var doc = zg_config.jsonc.loadJsonc(v.gpa, json, &diags) catch {
            f.invalid = true;
            const msg = if (diags.items().len > 0) diags.items()[0].message else "not valid JSON";
            return v.say(true, "{s}: {s}", .{ d.title, msg });
        };
        defer doc.deinit();
        const val = (reg.validate(arena, id, doc.root, &diags) catch return) orelse {
            f.invalid = true;
            const msg = if (diags.items().len > 0) diags.items()[0].message else "invalid value";
            return v.say(true, "{s}: {s}", .{ d.title, msg });
        };
        f.invalid = false;
        f.focused = false;
        v.write(id, val);
    }

    fn write(v: *SettingsView, id: SettingId, val: Value) void {
        const d = reg.def(id);
        // The user file keeps only what differs from the default.
        const remove = v.scope == .user and val.eql(reg.default(id));
        v.settings.write(v.scope, d.key, if (remove) null else val) catch |e| return v.writeFailed(e);
        var buf: [128]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        valueText(&w, val) catch {};
        v.say(false, "{s} = {s} ({s} settings)", .{ d.key, w.buffered(), scopeName(v.scope) });
    }

    fn writeFailed(v: *SettingsView, e: Settings.WriteError) void {
        switch (e) {
            error.Invalid => v.say(true, "{s} settings.json has a syntax error: fix it first (Edit in settings.json)", .{scopeName(v.scope)}),
            error.NotAnObject => v.say(true, "{s} settings.json is not a JSON object", .{scopeName(v.scope)}),
            error.NoFile => v.say(true, "There is no user settings folder", .{}),
            else => v.say(true, "Writing settings failed: {t}", .{e}),
        }
    }
};

fn scopeName(s: Scope) []const u8 {
    return if (s == .user) "User" else "Workspace";
}

/// A value as the text field shows it: strings raw, the rest as JSON.
fn valueText(w: *std.Io.Writer, v: Value) std.Io.Writer.Error!void {
    switch (v) {
        .string, .enum_lit => |s| try w.writeAll(s),
        .null => {},
        .array => |xs| {
            try w.writeByte('[');
            for (xs, 0..) |x, i| {
                if (i != 0) try w.writeAll(", ");
                try x.writeJson(w);
            }
            try w.writeByte(']');
        },
        .object => |fs| {
            if (fs.len == 0) return w.writeAll("{}");
            try w.writeAll("{ ");
            for (fs, 0..) |f, i| {
                if (i != 0) try w.writeAll(", ");
                try zg_config.value.writeJsonString(w, f.key);
                try w.writeAll(": ");
                try f.value.writeJson(w);
            }
            try w.writeAll(" }");
        },
        else => try v.writeJson(w),
    }
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(hay, needle) != null;
}

fn titleCase(buf: []u8, s: []const u8) []const u8 {
    const n = @min(s.len, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    if (n > 0) buf[0] = std.ascii.toUpper(buf[0]);
    return buf[0..n];
}

const testing = std.testing;

test "settings view: lists, filters and edits settings" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", gpa);
    defer gpa.free(root);
    const user = try std.fs.path.join(gpa, &.{ root, "settings.json" });
    defer gpa.free(user);
    const s = try Settings.create(gpa, testing.io, user, root);
    defer s.destroy();

    const Root = struct {
        v: ?*SettingsView = null,
        pub fn build(r: *@This(), ui: *Ui) void {
            if (r.v) |x| x.build(ui);
        }
    };
    var rv: Root = .{};
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 900, .h = 2400 }, .root = .of(&rv) });
    defer t.deinit();
    const v = try SettingsView.create(gpa, s);
    defer v.destroy();
    rv.v = v;
    t.win.markAllDirty();
    _ = t.settle();
    try testing.expect(t.find(.{ .name_contains = "Font Size" }) != null);
    try testing.expect(t.find(.{ .name_contains = "Keymap Preset" }) != null);

    // An enum button writes the user file.
    try t.click(.{ .role = .button, .name = "afterDelay" });
    _ = t.settle();
    try testing.expectEqualStrings("afterDelay", s.string("files.autoSave"));
    const text = try tmp.dir.readFileAlloc(testing.io, "settings.json", gpa, .limited(4096));
    defer gpa.free(text);
    try testing.expectEqualStrings("{\n    \"files.autoSave\": \"afterDelay\"\n}\n", text);

    // A checkbox.
    try t.click(.{ .role = .checkbox, .name_contains = "Ask before deleting" });
    _ = t.settle();
    try testing.expect(!s.boolean("explorer.confirmDelete"));

    // Reset removes the key.
    try testing.expect(s.isSetIn(.user, "explorer.confirmDelete"));
    v.apply(.{ .reset = service.registry.lookup("explorer.confirmDelete").? });
    try testing.expect(!s.isSetIn(.user, "explorer.confirmDelete"));

    // Text fields validate against the schema.
    const fs_id = service.registry.lookup("editor.fontSize").?;
    t.win.markAllDirty();
    _ = t.settle();
    const f = v.fields.get(fs_id.index()).?;
    try testing.expectEqualStrings("13", f.buf.slice());
    try f.buf.setText("200");
    v.commit(fs_id);
    try testing.expect(f.invalid);
    try testing.expectEqual(@as(i64, 13), s.int("editor.fontSize"));
    try f.buf.setText("15");
    v.commit(fs_id);
    try testing.expect(!f.invalid);
    try testing.expectEqual(@as(i64, 15), s.int("editor.fontSize"));
    // Objects as JSON.
    const ex = service.registry.lookup("files.exclude").?;
    _ = t.settle();
    const fx = v.fields.get(ex.index()).?;
    try fx.buf.setText("{ \"**/zig-out\": true }");
    v.commit(ex);
    try testing.expect(!fx.invalid);
    try testing.expect(s.get("files.exclude").get("**/zig-out") != null);

    // Search, and @modified.
    try v.search.setText("autosave");
    t.win.markAllDirty();
    _ = t.settle();
    try testing.expect(t.find(.{ .name_contains = "Font Size" }) == null);
    try testing.expect(t.find(.{ .name_contains = "Auto Save Delay" }) != null);
    try v.search.setText("@modified");
    t.win.markAllDirty();
    _ = t.settle();
    try testing.expect(t.find(.{ .name_contains = "Font Size" }) != null);
    try testing.expect(t.find(.{ .name_contains = "Tab Size" }) == null);

    // The workspace scope.
    v.scope = .workspace;
    v.write(fs_id, .{ .int = 20 });
    try testing.expectEqual(@as(i64, 20), s.int("editor.fontSize"));
    try testing.expect(s.isSetIn(.workspace, "editor.fontSize"));
}
