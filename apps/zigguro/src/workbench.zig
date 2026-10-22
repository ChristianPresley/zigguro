//! The workbench until the docking shell (E04.F07) lands: one editor on a
//! file (or an empty buffer) above a status line, driven by the E15 keymap
//! (VS Code preset) and command palette.
//!
//! Commands: `file.save` (Ctrl+S), `workbench.showCommands`
//! (Ctrl+Shift+P, F1), `editor.undo`, `editor.redo`, `editor.selectAll`
//! and `workbench.toggleTheme`.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_config = @import("zg_config");
const zg_editor = @import("zg_editor");
const zg_syntax = @import("zg_syntax");

const Ui = zg_gui.Ui;
const Window = zg_gui.Window;
const EditorView = zg_editor.view.EditorView;
const Document = zg_editor.model.document.Document;
const DocumentSyntax = zg_editor.model.syntax.DocumentSyntax;
const registry = zg_config.commands;
const themes = zg_gui.theme.theme;

/// See the module doc.
pub const Workbench = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// The file being edited, or null for an untitled buffer.
    path: ?[]u8 = null,
    doc: *Document,
    view: *EditorView,
    langs: zg_syntax.Registry,
    syntax: ?DocumentSyntax = null,
    keys: zg_config.context.ContextKeyService,
    reg: *registry.CommandRegistry,
    diags: zg_config.diag.Diags,
    keymap_docs: std.ArrayList(zg_config.zon_load.Doc) = .empty,
    keymap: ?*zg_config.keymap.Keymap = null,
    resolver: *zg_config.resolver.Resolver,
    adapter: zg_config.ui.KeymapAdapter = undefined,
    palette: zg_config.ui.PaletteProvider = undefined,
    win: ?*Window = null,
    /// The last save result, shown in the status line.
    message: [96]u8 = undefined,
    message_len: usize = 0,
    dark: bool = true,
    editor_node: zg_gui.core.NodeId = .none,
    focused: bool = false,

    /// Loads `path` (a missing file opens as a new empty one) and sets up
    /// commands and key bindings. Call `attach` once the window exists.
    pub fn init(wb: *Workbench, gpa: std.mem.Allocator, io: std.Io, path: ?[]const u8) !void {
        wb.* = .{
            .gpa = gpa,
            .io = io,
            .doc = undefined,
            .view = undefined,
            .langs = try zg_syntax.defaultRegistry(gpa),
            .keys = .init(gpa),
            .reg = undefined,
            .diags = .init(gpa),
            .resolver = undefined,
        };
        var bytes: []u8 = &.{};
        defer gpa.free(bytes);
        if (path) |p| {
            wb.path = try gpa.dupe(u8, p);
            bytes = std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(256 << 20)) catch |e| switch (e) {
                error.FileNotFound => try gpa.alloc(u8, 0),
                else => return e,
            };
        }
        wb.doc = try Document.initBytes(gpa, @enumFromInt(1), bytes);
        wb.view = try EditorView.init(gpa, wb.doc, .{});
        if (wb.langs.detect(wb.path, bytes[0..@min(bytes.len, 256)])) |id| if (wb.langs.get(id)) |lang| {
            wb.syntax = try DocumentSyntax.init(gpa, lang, &wb.langs, &wb.doc.tree, wb.doc.version);
        };

        wb.reg = try registry.CommandRegistry.init(gpa, &wb.keys, .{ .io = io });
        try registry.registerBuiltins(wb.reg);
        try wb.registerCommands();
        wb.resolver = try zg_config.resolver.Resolver.init(gpa, &wb.keys, &zg_config.keys.us_layout, .{});
        try wb.loadKeymap();
    }

    /// Unhooks from the window; call while it still exists.
    pub fn detach(wb: *Workbench) void {
        const w = wb.win orelse return;
        wb.palette.handle.close(w);
        wb.adapter.deinit();
        wb.palette.deinit();
        wb.view.on_change = null;
        wb.win = null;
    }

    /// Frees everything (after `detach`).
    pub fn deinit(wb: *Workbench) void {
        wb.detach();
        wb.resolver.deinit();
        if (wb.keymap) |k| k.deinit();
        for (wb.keymap_docs.items) |*d| d.deinit();
        wb.keymap_docs.deinit(wb.gpa);
        wb.reg.deinit();
        wb.diags.deinit();
        wb.keys.deinit();
        wb.view.deinit();
        if (wb.syntax) |*s| s.deinit();
        wb.doc.deinit();
        wb.langs.deinit(wb.gpa);
        if (wb.path) |p| wb.gpa.free(p);
    }

    /// Hooks the keymap and the palette into `win` and focuses the editor.
    pub fn attach(wb: *Workbench, win: *Window) !void {
        wb.win = win;
        if (wb.syntax) |*s| wb.view.syntax = s;
        wb.adapter = .init(wb.gpa, wb.reg, wb.resolver, win);
        wb.adapter.install();
        wb.adapter.on_status = .{ .ctx = wb, .f = onStatus };
        wb.palette = .init(wb.gpa, wb.reg, &wb.adapter);
        try wb.palette.registerCommands();
        wb.view.on_change = .{ .ctx = wb, .f = onViewChange };
    }

    fn loadKeymap(wb: *Workbench) !void {
        for (zg_config.presets.presetLayers(.vscode)) |src| {
            try wb.keymap_docs.append(wb.gpa, try zg_config.zon_load.loadZon(wb.gpa, src, &wb.diags));
        }
        var inputs: std.ArrayList(zg_config.keymap.LayerInput) = .empty;
        defer inputs.deinit(wb.gpa);
        for (wb.keymap_docs.items) |*d| try inputs.append(wb.gpa, .{ .layer = .preset, .doc = d });
        wb.keymap = try zg_config.keymap.Keymap.build(wb.gpa, inputs.items, wb.reg, &wb.keys, zg_config.keyspec.Platform.of(@import("builtin").os.tag), &wb.diags);
        wb.resolver.reload(wb.keymap.?);
    }

    const Cmd = struct { id: []const u8, title: []const u8, category: []const u8, run: *const fn (wb: *Workbench) anyerror!void };

    const commands = [_]Cmd{
        .{ .id = "file.save", .title = "Save", .category = "File", .run = save },
        .{ .id = "editor.undo", .title = "Undo", .category = "Edit", .run = undo },
        .{ .id = "editor.redo", .title = "Redo", .category = "Edit", .run = redo },
        .{ .id = "editor.selectAll", .title = "Select All", .category = "Selection", .run = selectAll },
        .{ .id = "workbench.toggleTheme", .title = "Toggle Light/Dark Theme", .category = "Preferences", .run = toggleTheme },
    };

    fn registerCommands(wb: *Workbench) !void {
        inline for (commands) |c| {
            _ = try wb.reg.register(.{
                .id = c.id,
                .title = c.title,
                .category = c.category,
                .source = .{ .builtin = "zigguro" },
                .handler = .{ .ctx = wb, .run = struct {
                    fn f(ctx: ?*anyopaque, _: *registry.Invocation) anyerror!void {
                        const self: *Workbench = @ptrCast(@alignCast(ctx.?));
                        try c.run(self);
                        if (self.win) |w| w.markAllDirty();
                    }
                }.f },
            });
        }
    }

    fn setMessage(wb: *Workbench, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&wb.message, fmt, args) catch wb.message[0..0];
        wb.message_len = s.len;
    }

    /// Writes the document to its file.
    pub fn save(wb: *Workbench) !void {
        const p = wb.path orelse {
            wb.setMessage("Untitled: start zigguro with a file path to save", .{});
            return;
        };
        const bytes = try wb.view.allText(wb.gpa);
        defer wb.gpa.free(bytes);
        std.Io.Dir.cwd().writeFile(wb.io, .{ .sub_path = p, .data = bytes }) catch |e| {
            wb.setMessage("Save failed: {t}", .{e});
            return e;
        };
        wb.doc.saved_version = wb.doc.version;
        wb.setMessage("Saved {d} bytes", .{bytes.len});
    }

    fn undo(wb: *Workbench) !void {
        _ = try wb.view.undoStep();
    }

    fn redo(wb: *Workbench) !void {
        _ = try wb.view.redoStep();
    }

    fn selectAll(wb: *Workbench) !void {
        wb.view.selectAll();
    }

    fn toggleTheme(wb: *Workbench) !void {
        const w = wb.win orelse return;
        wb.dark = !wb.dark;
        w.app.follow_system = false;
        w.app.setTheme(if (wb.dark) &themes.zigguro_dark else &themes.zigguro_light);
    }

    fn onStatus(ctx: *anyopaque, _: ?[]const u8) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        if (wb.win) |w| w.markAllDirty();
    }

    fn onViewChange(ctx: *anyopaque, _: *EditorView) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        if (wb.win) |w| w.markAllDirty();
    }

    pub fn build(wb: *Workbench, ui: *Ui) void {
        ui.open(.{ .style = .{ .w = .{ .pct = 100 }, .h = .{ .pct = 100 }, .dir = .column, .bg = .{ .token = .bg_base } } });
        defer ui.close();
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } }, .key_context = "editorFocus editorTextFocus" });
        const r = zg_editor.view.editor(ui, .{ .view = wb.view, .a11y_label = wb.path orelse "Untitled" });
        wb.editor_node = ui.lastNode();
        ui.close();
        if (r.changed) wb.message_len = 0;
        // Focus the editor once it exists.
        if (!wb.focused) {
            wb.focused = true;
            ui.win.afterNextFrame(.{ .ctx = wb, .f = focusEditor });
        }
        wb.statusLine(ui);
    }

    fn focusEditor(ctx: *anyopaque, w: *Window) void {
        const wb: *Workbench = @ptrCast(@alignCast(ctx));
        if (w.focus.isNone() and !wb.editor_node.isNone()) w.setFocus(wb.editor_node, false);
    }

    fn statusLine(wb: *Workbench, ui: *Ui) void {
        ui.open(.{ .role = .status, .style = .{ .dir = .row, .gap = 16, .padding = .xy(10, 3), .bg = .{ .token = .bg_elevated }, .shrink = 0 } });
        defer ui.close();
        const name = if (wb.path) |p| std.fs.path.basename(p) else "Untitled";
        ui.textf("{s}{s}", .{ name, if (wb.doc.isDirty()) " \u{25cf}" else "" }, .{ .wrap = false });
        const head = wb.view.primarySel().head;
        const line = wb.view.lineOf(head);
        const col = head - wb.view.lineRange(line).start;
        ui.textf("Ln {d}, Col {d}", .{ line + 1, col + 1 }, .{ .color = .fg_muted, .wrap = false });
        if (wb.view.sels.items.len > 1) ui.textf("{d} selections", .{wb.view.sels.items.len}, .{ .color = .fg_muted, .wrap = false });
        if (wb.syntax) |s| ui.text(s.lang.name, .{ .color = .fg_muted, .wrap = false });
        if (wb.adapter.status()) |st| ui.text(st, .{ .color = .warning, .wrap = false }) else if (wb.message_len > 0) ui.text(wb.message[0..wb.message_len], .{ .color = .fg_muted, .wrap = false });
    }
};
