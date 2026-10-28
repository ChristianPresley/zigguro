//! The prompt library picker (E13.F08.S02.T01): a search box over the
//! library (project, user, built-in prompts and E10 skills), results with
//! source and tags, and a preview of the selected entry's text. Choosing
//! an entry with variables opens a form (one field per variable, choices
//! as buttons, the selection prefilled from the focused editor); Insert
//! renders it into the active composer target (the agent pane composer,
//! Mission Control's dispatch box, the doc-mode ask box) or copies it.
//! Skills insert as `/name args` and run in E10, never inlined.
//!
//! Palette: `library.open` shows it (Ctrl+Alt+L); `library.save` makes an
//! entry from a transcript message (`saveFromMessage`).

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const controls = zg_gui.w.controls;
const TextBuffer = zg_gui.w.text_field.TextBuffer;
const library = zg_agents.library;
const PromptLibrary = library.PromptLibrary;

/// Where an expanded prompt goes. The app registers one per composer and
/// passes the focused one in `Ports.target`.
pub const ComposerTarget = struct {
    ctx: *anyopaque,
    /// "Agent pane", "Mission Control", "Document".
    name: []const u8,
    insert: *const fn (ctx: *anyopaque, text: []const u8) void,
};

pub const Ports = struct {
    lib: *PromptLibrary,
    target: ?ComposerTarget = null,
    copy: ?struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, text: []const u8) void } = null,
    /// Editor context for `{{selection}}`, `{{file}}`, `{{date}}`.
    ctx: library.RenderCtx = .{},
    max_results: u32 = 50,
};

pub const Mode = enum { pick, form };

pub const LibraryPicker = struct {
    gpa: Allocator,
    p: Ports,
    query: TextBuffer,
    /// Owned by `arena` (reset on every search).
    arena: std.heap.ArenaAllocator,
    hits: std.ArrayList(PromptLibrary.Hit) = .empty,
    selected: usize = 0,
    last_query: std.ArrayList(u8) = .empty,
    preview: []const u8 = "",
    mode: Mode = .pick,
    /// The entry the form is for.
    form_id: []const u8 = "",
    form_vars: []const library.VarDecl = &.{},
    fields: std.ArrayList(*TextBuffer) = .empty,
    /// Skills: the arguments field.
    args: TextBuffer,
    notice: ?[]const u8 = null,
    notice_buf: [200]u8 = undefined,
    /// Set when something was inserted or copied; the host closes the
    /// picker.
    done: bool = false,

    pub fn init(gpa: Allocator, p: Ports) !*LibraryPicker {
        const v = try gpa.create(LibraryPicker);
        errdefer gpa.destroy(v);
        v.* = .{ .gpa = gpa, .p = p, .query = try .init(gpa, ""), .arena = .init(gpa), .args = try .init(gpa, "") };
        v.refresh();
        return v;
    }

    pub fn deinit(v: *LibraryPicker) void {
        v.clearFields();
        v.fields.deinit(v.gpa);
        v.hits.deinit(v.gpa);
        v.last_query.deinit(v.gpa);
        v.query.deinit();
        v.args.deinit();
        v.arena.deinit();
        v.gpa.destroy(v);
    }

    pub fn build(v: *LibraryPicker, ui: *Ui) void {
        libraryView(ui, v);
    }

    fn say(v: *LibraryPicker, comptime fmt: []const u8, args: anytype) void {
        v.notice = std.fmt.bufPrint(&v.notice_buf, fmt, args) catch "…";
    }

    /// Re-runs the search for the current query.
    pub fn refresh(v: *LibraryPicker) void {
        v.last_query.clearRetainingCapacity();
        v.last_query.appendSlice(v.gpa, v.query.slice()) catch {};
        v.p.lib.search(v.query.slice(), v.p.max_results, &v.hits, v.gpa) catch {
            v.hits.clearRetainingCapacity();
        };
        if (v.selected >= v.hits.items.len) v.selected = 0;
        v.loadPreview();
    }

    fn loadPreview(v: *LibraryPicker) void {
        if (v.mode == .pick) _ = v.arena.reset(.retain_capacity);
        v.preview = "";
        if (v.hits.items.len == 0) return;
        const e = v.hits.items[v.selected].entry;
        v.preview = v.p.lib.body(e.id, v.arena.allocator()) catch "";
    }

    pub fn move(v: *LibraryPicker, delta: i32) void {
        const n: i64 = @intCast(v.hits.items.len);
        if (n == 0) return;
        const i = @mod(@as(i64, @intCast(v.selected)) + delta, n);
        v.selected = @intCast(i);
        v.loadPreview();
    }

    pub fn selectIndex(v: *LibraryPicker, i: usize) void {
        if (i >= v.hits.items.len) return;
        v.selected = i;
        v.loadPreview();
    }

    fn clearFields(v: *LibraryPicker) void {
        for (v.fields.items) |f| {
            f.deinit();
            v.gpa.destroy(f);
        }
        v.fields.clearRetainingCapacity();
    }

    /// Enter on the selected entry: inserts at once when it needs nothing,
    /// else opens the form.
    pub fn choose(v: *LibraryPicker) void {
        if (v.hits.items.len == 0) return;
        const e = v.hits.items[v.selected].entry;
        v.form_id = v.arena.allocator().dupe(u8, e.id) catch return;
        v.form_vars = e.variables;
        v.clearFields();
        v.args.setText("") catch {};
        var needs_form = e.source == .skill and e.argument_hint != null;
        for (e.variables) |d| {
            const f = v.gpa.create(TextBuffer) catch return;
            const initial = if (d.kind == .selection) v.p.ctx.selection orelse "" else d.default orelse "";
            f.* = TextBuffer.init(v.gpa, initial) catch {
                v.gpa.destroy(f);
                return;
            };
            v.fields.append(v.gpa, f) catch {
                f.deinit();
                v.gpa.destroy(f);
                return;
            };
            needs_form = true;
        }
        v.notice = null;
        if (needs_form) {
            v.mode = .form;
        } else v.submit(.insert);
    }

    pub const How = enum { insert, copy };

    /// Renders the form's values and inserts (or copies) the text.
    pub fn submit(v: *LibraryPicker, how: How) void {
        var arena: std.heap.ArenaAllocator = .init(v.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const values = a.alloc(library.Var, v.fields.items.len) catch return;
        for (v.form_vars, v.fields.items, values) |d, f, *val| val.* = .{ .name = d.name, .value = f.slice() };
        const ins = v.p.lib.insertion(a, v.form_id, values, v.p.ctx, std.mem.trim(u8, v.args.slice(), " ")) catch |e| return v.say("Cannot insert: {t}", .{e});
        const text = switch (ins) {
            .command => |c| c,
            .text => |r| blk: {
                if (r.missing.len > 0) return v.say("Fill in {s}", .{r.missing[0]});
                if (r.invalid.len > 0) return v.say("{s}: {s}", .{ r.invalid[0].name, r.invalid[0].reason });
                break :blk r.text;
            },
        };
        switch (how) {
            .insert => {
                const t = v.p.target orelse return v.say("No composer is focused: use Copy", .{});
                t.insert(t.ctx, text);
            },
            .copy => {
                const c = v.p.copy orelse return v.say("Copy is not available", .{});
                c.f(c.ctx, text);
            },
        }
        v.p.lib.noteUse(v.form_id);
        v.mode = .pick;
        v.done = true;
    }

    pub fn back(v: *LibraryPicker) void {
        v.mode = .pick;
        v.notice = null;
    }
};

/// "Save prompt" on a transcript message: a project entry with the text,
/// a title from its first line and the `{{…}}` variables it uses. Returns
/// the new id, or null with the reason in `why`.
pub fn saveFromMessage(lib: *PromptLibrary, arena: Allocator, text: []const u8, why: *[]const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, text, " \r\n"), '\n');
    const first = std.mem.trim(u8, lines.first(), " \r#");
    const title = first[0..@min(first.len, 60)];
    const slug = zg_agents.artifacts.save.slug(arena, title) catch return null;
    const id = std.fmt.allocPrint(arena, "saved/{s}", .{slug}) catch return null;
    const vars = library.template.detectVariables(arena, text) catch return null;
    const c = lib.create(arena, .project, .{ .id = id, .title = if (title.len > 0) title else "Saved prompt", .variables = vars, .body = text }) catch |e| {
        why.* = @errorName(e);
        return null;
    };
    return c.id;
}

/// The view.
pub fn libraryView(ui: *Ui, v: *LibraryPicker) void {
    const th = ui.theme();
    ui.open(.{ .role = .dialog, .label = "Prompt library", .test_id = "library", .style = .{ .dir = .column, .gap = th.dim(.space_sm), .padding = .all(th.dim(.space_sm)), .grow = 1 } });
    defer ui.close();
    if (v.notice) |n| {
        ui.open(.{ .role = .status, .label = n, .test_id = "library-notice" });
        ui.text(n, .{ .color = .warning });
        ui.close();
    }
    switch (v.mode) {
        .pick => pickView(ui, v),
        .form => formView(ui, v),
    }
}

fn pickView(ui: *Ui, v: *LibraryPicker) void {
    const th = ui.theme();
    const r = zg_gui.w.text_field.textField(ui, .{ .buffer = &v.query, .a11y_label = "Search prompts", .placeholder = "Search prompts, templates and skills" });
    if (!std.mem.eql(u8, v.query.slice(), v.last_query.items)) v.refresh();
    if (r.submitted) v.choose();
    ui.open(.{ .style = .{ .dir = .row, .gap = th.dim(.space_sm), .grow = 1 } });
    defer ui.close();
    ui.open(.{ .role = .list, .label = "Prompts", .style = .{ .dir = .column, .gap = 1, .grow = 1 } });
    if (v.hits.items.len == 0) ui.text("No prompts match.", .{ .color = .fg_muted });
    for (v.hits.items, 0..) |h, i| {
        const e = h.entry;
        const sel = i == v.selected;
        const label = std.fmt.allocPrint(ui.arena(), "{s}, {s}, {t}", .{ e.title, e.id, e.source }) catch e.id;
        ui.id(@as(u64, i));
        ui.open(.{ .role = .listitem, .label = label, .hit = true, .test_id = if (sel) "library-selected" else "", .style = .{
            .dir = .column,
            .padding = .xy(4, 2),
            .bg = if (sel) .{ .token = .selection_bg } else .none,
        } });
        const resp = ui.response();
        if (resp.double_clicked) {
            v.selectIndex(i);
            v.choose();
        } else if (resp.clicked) v.selectIndex(i);
        ui.open(.{ .style = .{ .dir = .row, .gap = th.dim(.space_sm), .align_items = .center } });
        ui.text(e.title, .{ .wrap = false, .style = .{ .weight = 700 } });
        ui.text(e.id, .{ .color = .fg_muted, .wrap = false });
        ui.open(.{ .style = .{ .grow = 1 } });
        ui.close();
        ui.text(@tagName(e.source), .{ .color = .fg_muted, .wrap = false });
        ui.close();
        if (e.description.len > 0) ui.text(e.description, .{ .color = .fg_muted, .wrap = false });
        ui.close();
    }
    ui.close();
    ui.open(.{ .role = .group, .label = "Preview", .test_id = "library-preview", .style = .{ .dir = .column, .gap = 4, .grow = 1, .padding = .all(th.dim(.space_sm)), .bg = .{ .token = .bg_elevated } } });
    defer ui.close();
    if (v.hits.items.len == 0) return;
    const e = v.hits.items[v.selected].entry;
    if (e.variables.len > 0) {
        var w: std.Io.Writer.Allocating = .init(ui.arena());
        for (e.variables, 0..) |d, k| w.writer.print("{s}{{{{{s}}}}}", .{ if (k > 0) " " else "", d.name }) catch {};
        ui.textf("Variables: {s}", .{w.written()}, .{ .color = .fg_link });
    }
    if (e.source == .skill) ui.textf("Runs as /{s}{s}{s}", .{ e.title, if (e.argument_hint != null) " " else "", e.argument_hint orelse "" }, .{ .color = .fg_muted });
    ui.text(v.preview, .{ .style = .{ .font = .mono } });
    ui.open(.{ .style = .{ .dir = .row, .gap = 4 } });
    if (controls.button(ui, .{ .label = if (e.variables.len > 0) "Fill in…" else "Insert", .variant = .primary }).clicked) v.choose();
    ui.close();
}

fn formView(ui: *Ui, v: *LibraryPicker) void {
    const th = ui.theme();
    ui.open(.{ .role = .group, .label = "Prompt variables", .test_id = "library-form", .style = .{ .dir = .column, .gap = 4 } });
    defer ui.close();
    ui.textf("{s}", .{v.form_id}, .{ .style = .{ .weight = 700 } });
    const entry = v.p.lib.get(v.form_id);
    if (entry != null and entry.?.source == .skill) {
        _ = zg_gui.w.text_field.textField(ui, .{ .buffer = &v.args, .a11y_label = "Arguments", .placeholder = entry.?.argument_hint orelse "arguments" });
    }
    for (v.form_vars, v.fields.items, 0..) |d, f, k| {
        ui.id(@as(u64, k));
        ui.open(.{ .role = .group, .label = d.name, .style = .{ .dir = .row, .gap = th.dim(.space_sm), .align_items = .center } });
        defer ui.close();
        ui.textf("{s}{s}", .{ d.name, if (d.required) " *" else "" }, .{ .wrap = false });
        switch (d.kind) {
            .choice => for (d.options, 0..) |o, j| {
                ui.id(@as(u64, j));
                const on = std.mem.eql(u8, f.slice(), o);
                if (controls.button(ui, .{ .label = o, .variant = if (on) .primary else .ghost }).clicked) f.setText(o) catch {};
            },
            .bool => {
                var on = std.ascii.eqlIgnoreCase(f.slice(), "true");
                if (controls.checkbox(ui, d.name, &on).clicked) f.setText(if (on) "true" else "false") catch {};
            },
            else => _ = zg_gui.w.text_field.textField(ui, .{
                .buffer = f,
                .a11y_label = d.name,
                .multiline = d.kind == .multiline or d.kind == .selection,
                .max_rows = if (d.kind == .multiline or d.kind == .selection) 6 else 1,
                .placeholder = d.default orelse "",
            }),
        }
    }
    ui.open(.{ .style = .{ .dir = .row, .gap = 4 } });
    const target = if (v.p.target) |t| t.name else "composer";
    if (controls.button(ui, .{ .label = std.fmt.allocPrint(ui.arena(), "Insert into {s}", .{target}) catch "Insert", .variant = .primary, .disabled = v.p.target == null }).clicked) v.submit(.insert);
    if (controls.button(ui, .{ .label = "Copy", .disabled = v.p.copy == null }).clicked) v.submit(.copy);
    if (controls.button(ui, .{ .label = "Back" }).clicked) v.back();
    ui.close();
}
