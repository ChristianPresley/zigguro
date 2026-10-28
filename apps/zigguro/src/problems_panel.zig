//! `ProblemsPanel`: the Problems panel (E07.F02.S02.T02): every
//! diagnostic the language servers report, as a tree of files (relative
//! path and counts) over their diagnostics (severity, message, source,
//! code and `[line:col]`), from zg_codeintel's `Problems` model over the
//! diagnostic store. It docks in the bottom area, next to the terminal.
//!
//! The header filters by text (message, source or code), by severity
//! (errors only, errors and warnings, everything) and to the current
//! file. A click on a diagnostic shows it in its editor; Enter or a
//! double click also moves focus there. The context menu copies the
//! diagnostic or its message. Files start open; the tree keeps its
//! selection and open files across updates (the model's node ids are
//! stable).
//!
//! The workbench calls `refresh` every frame (cheap when nothing
//! changed) and owns the commands (`workbench.showProblems`,
//! `editor.nextProblem`, `editor.previousProblem`, `problems.copy`,
//! `problems.copyMessage`). UI thread only.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_codeintel = @import("zg_codeintel");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const Window = zg_gui.Window;
const virtual = zg_gui.virtual;
const TreeView = virtual.TreeView;
const TreeSource = virtual.TreeSource;
const ChildCount = virtual.tree_view.ChildCount;
const RowInfo = virtual.tree_view.RowInfo;
const Store = zg_codeintel.diagnostics.Store;
pub const Problems = zg_codeintel.diagnostics.Problems;

/// What the panel asks of its host (the workbench).
pub const Hooks = struct {
    ctx: *anyopaque,
    /// Shows item `it` of the file with store key `key` in an editor
    /// (`focus`: and moves focus there).
    open: *const fn (ctx: *anyopaque, key: []const u8, it: Problems.Item, focus: bool) void,
};

/// Which severities show.
pub const Level = enum { errors, warnings, all };

/// See the module doc.
pub const ProblemsPanel = struct {
    gpa: Allocator,
    store: *Store,
    model: Problems,
    tv: TreeView = undefined,
    hooks: Hooks,
    /// Paths show relative to it.
    root: []const u8,
    win: ?*Window = null,
    filter_buf: zg_gui.w.TextBuffer,
    level: Level = .all,
    current_only: bool = false,
    /// The current editor's store key (for "current file only").
    current_key: std.ArrayList(u8) = .empty,
    has_current: bool = false,
    /// Model revision the tree rows were built from.
    rev_seen: u64 = 0,
    /// Files seen open (new ones start open; closed ones stay closed).
    seen_files: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Scratch for row texts.
    scratch: [512]u8 = undefined,

    /// A panel over `store`; `root` (absolute) must outlive it. `p`
    /// must not move afterwards.
    pub fn init(p: *ProblemsPanel, gpa: Allocator, store: *Store, root: []const u8, hooks: Hooks) !void {
        p.* = .{ .gpa = gpa, .store = store, .model = .init(gpa), .hooks = hooks, .root = root, .filter_buf = try .init(gpa, "") };
        errdefer p.filter_buf.deinit();
        errdefer p.model.deinit();
        _ = try p.model.update(store, p.filter());
        p.tv = try TreeView.init(gpa, p.source(), .{
            .label = "Problems",
            .test_id = "problems-tree",
            .on_open = .{ .ctx = p, .f = onOpen },
            .on_click = .{ .ctx = p, .f = onClick },
        });
        p.rev_seen = p.model.revision;
        p.openNewFiles();
    }

    pub fn deinit(p: *ProblemsPanel) void {
        p.tv.deinit();
        p.model.deinit();
        p.filter_buf.deinit();
        p.current_key.deinit(p.gpa);
        p.seen_files.deinit(p.gpa);
    }

    fn self(ptr: *anyopaque) *ProblemsPanel {
        return @ptrCast(@alignCast(ptr));
    }

    fn filter(p: *ProblemsPanel) Problems.Filter {
        return .{
            .min_severity = switch (p.level) {
                .errors => .err,
                .warnings => .warning,
                .all => .hint,
            },
            .text = std.mem.trim(u8, p.filter_buf.slice(), " "),
            .key = if (p.current_only and p.has_current) p.current_key.items else null,
        };
    }

    /// The current editor's file changed (its store key; null: none).
    pub fn setCurrent(p: *ProblemsPanel, key: ?[]const u8) void {
        if (key) |k| {
            if (p.has_current and std.mem.eql(u8, k, p.current_key.items)) return;
            p.current_key.clearRetainingCapacity();
            p.current_key.appendSlice(p.gpa, k) catch return;
            p.has_current = true;
        } else p.has_current = false;
    }

    /// Brings the tree to the store and the filter; true when it changed.
    pub fn refresh(p: *ProblemsPanel) bool {
        _ = p.model.update(p.store, p.filter()) catch return false;
        if (p.model.revision == p.rev_seen) return false;
        p.rev_seen = p.model.revision;
        p.tv.reload() catch {};
        p.openNewFiles();
        return true;
    }

    fn openNewFiles(p: *ProblemsPanel) void {
        for (p.model.files.items) |f| {
            const gop = p.seen_files.getOrPut(p.gpa, f.id) catch return;
            if (gop.found_existing) continue;
            if (p.tv.flat.rowOf(f.id)) |i| _ = p.tv.expandRow(i) catch {};
        }
    }

    // -- the tree's data ------------------------------------------------------

    fn source(p: *ProblemsPanel) TreeSource {
        return .{ .ptr = p, .vtable = &vtable };
    }

    const vtable: TreeSource.VTable = .{
        .root_count = rootCount,
        .child_count = childCount,
        .child = child,
        .label = label,
        .build_row = buildRow,
    };

    fn rootCount(ptr: *anyopaque) u32 {
        return @intCast(self(ptr).model.files.items.len);
    }

    fn childCount(ptr: *anyopaque, node: u64) ChildCount {
        return switch (self(ptr).model.node(node) orelse return .leaf) {
            .file => |f| .{ .known = self(ptr).model.files.items[f].len },
            .item => .leaf,
        };
    }

    fn child(ptr: *anyopaque, parent: ?u64, i: u32) u64 {
        const m = &self(ptr).model;
        const q = parent orelse return m.files.items[i].id;
        return m.fileItems(m.node(q).?.file)[i].id;
    }

    /// The path shown for store key `key`: relative to the root when
    /// inside it.
    pub fn displayPath(p: *const ProblemsPanel, key: []const u8) []const u8 {
        const root = std.mem.trimEnd(u8, p.root, "/\\");
        if (root.len > 0 and key.len > root.len + 1 and std.ascii.startsWithIgnoreCase(key, root) and (key[root.len] == '/' or key[root.len] == '\\'))
            return key[root.len + 1 ..];
        return key;
    }

    fn firstLine(s: []const u8) []const u8 {
        return s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
    }

    fn label(ptr: *anyopaque, node: u64) []const u8 {
        const p = self(ptr);
        return switch (p.model.node(node) orelse return "") {
            .file => |f| p.displayPath(p.model.files.items[f].key),
            .item => |l| p.itemName(l),
        };
    }

    /// The accessible name of a diagnostic row: "error: message,
    /// file line N".
    fn itemName(p: *ProblemsPanel, l: Problems.Loc) []const u8 {
        const it = p.model.item(l);
        const f = p.model.files.items[l.file];
        return std.fmt.bufPrint(&p.scratch, "{s}: {s}, {s} line {d}", .{ it.diag.severity.label(), firstLine(it.diag.message), std.fs.path.basename(f.key), it.diag.start.line + 1 }) catch firstLine(it.diag.message);
    }

    fn severityGlyph(s: Problems.Severity) struct { []const u8, zg_gui.theme.Token } {
        return switch (s) {
            .err => .{ "\u{2297}", .danger },
            .warning => .{ "\u{26a0}", .warning },
            .information => .{ "\u{24d8}", .info },
            .hint => .{ "\u{2026}", .fg_muted },
        };
    }

    fn buildRow(ptr: *anyopaque, ui: *Ui, node: u64, _: RowInfo) void {
        const p = self(ptr);
        const n = p.model.node(node) orelse return;
        ui.open(.{ .style = .{ .dir = .row, .gap = 6, .align_items = .center, .grow = 1, .shrink = 1 } });
        defer ui.close();
        var buf: [64]u8 = undefined;
        switch (n) {
            .file => |fi| {
                const f = p.model.files.items[fi];
                const path = p.displayPath(f.key);
                ui.text(std.fs.path.basename(path), .{ .wrap = false });
                if (std.fs.path.dirname(path)) |dir| ui.text(dir, .{ .color = .fg_muted, .wrap = false });
                const total = f.counts[0] + f.counts[1] + f.counts[2] + f.counts[3];
                ui.text(std.fmt.bufPrint(&buf, "{d}", .{total}) catch "", .{ .color = .fg_muted, .wrap = false });
            },
            .item => |l| {
                const it = p.model.item(l);
                const g, const tok = severityGlyph(it.diag.severity);
                ui.text(g, .{ .color = tok, .wrap = false });
                ui.text(firstLine(it.diag.message), .{ .wrap = false });
                if (it.diag.source.len > 0 or it.diag.code.len > 0) {
                    const sc = if (it.diag.code.len > 0)
                        std.fmt.bufPrint(&buf, "{s}({s})", .{ it.diag.source, it.diag.code }) catch it.diag.source
                    else
                        it.diag.source;
                    ui.text(sc, .{ .color = .fg_muted, .wrap = false });
                }
                var pb: [32]u8 = undefined;
                ui.text(std.fmt.bufPrint(&pb, "[{d}:{d}]", .{ it.diag.start.line + 1, it.diag.start.character + 1 }) catch "", .{ .color = .fg_muted, .wrap = false });
            },
        }
    }

    // -- actions ----------------------------------------------------------------

    fn onOpen(ctx: *anyopaque, node: u64) void {
        const p = self(ctx);
        switch (p.model.node(node) orelse return) {
            .file => {
                if (p.tv.flat.rowOf(node)) |i| {
                    if (p.tv.flat.isExpanded(node)) _ = p.tv.collapseRow(i) else _ = p.tv.expandRow(i) catch {};
                }
            },
            .item => |l| p.show(l, true),
        }
    }

    fn onClick(ctx: *anyopaque, node: u64) void {
        const p = self(ctx);
        switch (p.model.node(node) orelse return) {
            .file => {},
            .item => |l| p.show(l, false),
        }
    }

    /// Opens diagnostic `l` in its editor and selects its row.
    pub fn show(p: *ProblemsPanel, l: Problems.Loc, move_focus: bool) void {
        const it = p.model.item(l);
        p.hooks.open(p.hooks.ctx, p.model.files.items[l.file].key, it, move_focus);
    }

    /// Selects diagnostic `l`'s row (after the editor moved there).
    pub fn select(p: *ProblemsPanel, l: Problems.Loc) void {
        const id = p.model.item(l).id;
        const fid = p.model.files.items[l.file].id;
        if (!p.tv.flat.isExpanded(fid)) if (p.tv.flat.rowOf(fid)) |i| {
            _ = p.tv.expandRow(i) catch {};
        };
        if (p.tv.flat.rowOf(id)) |i| {
            p.tv.moveTo(i, .replace);
            p.tv.reveal(i);
        }
    }

    /// The diagnostic of the active row, if it is one.
    pub fn activeItem(p: *const ProblemsPanel) ?Problems.Loc {
        const a = p.tv.active orelse return null;
        return switch (p.model.node(a) orelse return null) {
            .item => |l| l,
            .file => null,
        };
    }

    /// Copies the active diagnostic ("path:line:col: severity: message
    /// [source(code)]") or, with `message_only`, its message.
    pub fn copyActive(p: *ProblemsPanel, message_only: bool) void {
        const w = p.win orelse return;
        const l = p.activeItem() orelse return;
        const it = p.model.item(l);
        if (message_only) return w.app.clipboard.set(w.gpa, it.diag.message);
        var out: std.Io.Writer.Allocating = .init(p.gpa);
        defer out.deinit();
        out.writer.print("{s}:{d}:{d}: {s}: {s}", .{ p.displayPath(p.model.files.items[l.file].key), it.diag.start.line + 1, it.diag.start.character + 1, it.diag.severity.label(), it.diag.message }) catch return;
        if (it.diag.source.len > 0) out.writer.print(" [{s}{s}{s}{s}]", .{ it.diag.source, if (it.diag.code.len > 0) "(" else "", it.diag.code, if (it.diag.code.len > 0) ")" else "" }) catch return;
        w.app.clipboard.set(w.gpa, out.written());
    }

    /// Focuses the tree.
    pub fn focus(p: *ProblemsPanel, w: *Window) void {
        if (!p.tv.node.isNone() and w.store.valid(p.tv.node)) w.setFocus(p.tv.node, true);
    }

    // -- building -----------------------------------------------------------

    pub fn build(p: *ProblemsPanel, ui: *Ui) void {
        p.win = ui.window();
        _ = p.refresh();
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 }, .bg = .{ .token = .bg_elevated } }, .role = .group, .label = "Problems" });
        defer ui.close();
        p.header(ui);
        if (p.model.files.items.len == 0) {
            ui.open(.{ .style = .{ .padding = .xy(12, 6), .shrink = 0 } });
            ui.text(if (p.filter_buf.len() > 0 or p.level != .all or p.current_only) "No problems match the filter." else "No problems have been detected in the workspace.", .{ .color = .fg_muted });
            ui.close();
            return;
        }
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } }, .key_context = "problemsFocus" });
        p.contextMenu(ui);
        p.tv.build(ui);
        ui.close();
    }

    fn header(p: *ProblemsPanel, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .row, .gap = 8, .align_items = .center, .padding = .xy(10, 2), .h = .{ .px = 30 }, .shrink = 0 } });
        defer ui.close();
        const tot = Problems.totals(p.store);
        var cb: [64]u8 = undefined;
        ui.text(std.fmt.bufPrint(&cb, "\u{2297} {d}  \u{26a0} {d}  \u{24d8} {d}", .{ tot[0], tot[1], tot[2] + tot[3] }) catch "", .{ .color = .fg_muted, .wrap = false });
        ui.open(.{ .style = .{ .grow = 1, .basis = .{ .px = 120 }, .max_w = 360 } });
        _ = zg_gui.w.textField(ui, .{ .buffer = &p.filter_buf, .placeholder = "Filter (e.g. text, source)", .a11y_label = "Filter problems" });
        ui.close();
        const levels = [_]struct { Level, []const u8 }{ .{ .errors, "Errors" }, .{ .warnings, "+ Warnings" }, .{ .all, "All" } };
        for (levels) |lv| {
            if (zg_gui.w.button(ui, .{ .label = lv[1], .variant = if (p.level == lv[0]) .primary else .ghost }).clicked) p.level = lv[0];
        }
        _ = zg_gui.w.checkbox(ui, "Current file", &p.current_only);
    }

    fn contextMenu(p: *ProblemsPanel, ui: *Ui) void {
        const on_item = p.activeItem() != null;
        const items = [_]zg_gui.w.MenuItem{
            .{ .action = .{ .label = "Go to Problem", .action = "problems.open", .enabled = on_item } },
            .separator,
            .{ .action = .{ .label = "Copy", .action = "problems.copy", .enabled = on_item } },
            .{ .action = .{ .label = "Copy Message", .action = "problems.copyMessage", .enabled = on_item } },
        };
        zg_gui.w.contextMenu(ui, &items, .{ .test_id = "problems-menu" });
    }
};

const testing = std.testing;

const TestHost = struct {
    opened: std.ArrayList(u8) = .empty,
    line: u32 = 0,
    focus: bool = false,

    fn open(ctx: *anyopaque, key: []const u8, it: Problems.Item, focus: bool) void {
        const h: *TestHost = @ptrCast(@alignCast(ctx));
        h.opened.clearRetainingCapacity();
        h.opened.appendSlice(testing.allocator, key) catch {};
        h.line = it.diag.start.line;
        h.focus = focus;
    }
};

const TestPage = struct {
    p: *ProblemsPanel,
    pub fn build(pg: *TestPage, ui: *Ui) void {
        ui.open(.{ .style = .{ .w = .{ .px = 700 }, .h = .{ .px = 300 }, .dir = .column } });
        defer ui.close();
        pg.p.build(ui);
    }
};

fn testSet(owner: Store.Owner, diags: []const Store.Diagnostic) !*Store.Set {
    const s = try Store.Set.create(testing.allocator, owner);
    errdefer s.destroy();
    s.diags = try s.allocator().dupe(Store.Diagnostic, diags);
    s.finish();
    return s;
}

test "problems panel: files open, rows name their diagnostics, a click shows one, filters apply" {
    const gpa = testing.allocator;
    var rt: @import("zg_core").Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    var st = try Store.init(gpa, rt.io, .posix);
    defer st.deinit();
    const o: Store.Owner = .{ .server = 0 };
    try st.replace("/w/src/a.zig", o, try testSet(o, &.{
        .{ .start = .{ .line = 3, .character = 4 }, .end = .{ .line = 3, .character = 5 }, .message = "expected ';'", .source = "zls" },
        .{ .start = .{ .line = 9, .character = 0 }, .end = .{ .line = 9, .character = 1 }, .severity = .warning, .message = "unused x", .source = "zls", .code = "W1" },
    }));
    st.commit();

    var host: TestHost = .{};
    defer host.opened.deinit(gpa);
    var p: ProblemsPanel = undefined;
    try p.init(gpa, &st, "/w", .{ .ctx = &host, .open = TestHost.open });
    defer p.deinit();
    var page: TestPage = .{ .p = &p };
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .root = zg_gui.AnyView.of(&page) });
    defer t.deinit();
    _ = t.settle();

    // The file row (relative path) and its two diagnostics.
    try testing.expectEqual(@as(usize, 3), p.tv.flat.len());
    try testing.expectEqualStrings("src/a.zig", ProblemsPanel.label(&p, p.tv.flat.rows.items[0].node));
    try testing.expectEqualStrings("error: expected ';', a.zig line 4", ProblemsPanel.label(&p, p.tv.flat.rows.items[1].node));
    // Selecting a diagnostic and opening it shows it in the editor.
    p.tv.moveTo(2, .replace);
    ProblemsPanel.onOpen(&p, p.tv.flat.rows.items[2].node);
    try testing.expectEqualStrings("/w/src/a.zig", host.opened.items);
    try testing.expectEqual(@as(u32, 9), host.line);
    try testing.expect(host.focus);
    try testing.expectEqualStrings("unused x", p.model.item(p.activeItem().?).diag.message);

    // A new push keeps the selection on the same diagnostic.
    try st.replace("/w/src/b.zig", o, try testSet(o, &.{.{ .start = .{ .line = 0, .character = 0 }, .end = .{ .line = 0, .character = 1 }, .message = "b" }}));
    st.commit();
    try testing.expect(p.refresh());
    try testing.expectEqual(@as(usize, 5), p.tv.flat.len());
    try testing.expectEqualStrings("unused x", p.model.item(p.activeItem().?).diag.message);

    // Errors only; then text.
    p.level = .errors;
    try testing.expect(p.refresh());
    try testing.expectEqual(@as(usize, 4), p.tv.flat.len());
    p.level = .all;
    try p.filter_buf.setText("w1");
    try testing.expect(p.refresh());
    try testing.expectEqual(@as(usize, 2), p.tv.flat.len());
    // The current file only.
    try p.filter_buf.setText("");
    p.setCurrent("/w/src/b.zig");
    p.current_only = true;
    try testing.expect(p.refresh());
    try testing.expectEqual(@as(usize, 2), p.tv.flat.len());
    try testing.expectEqualStrings("src/b.zig", ProblemsPanel.label(&p, p.tv.flat.rows.items[0].node));
}
