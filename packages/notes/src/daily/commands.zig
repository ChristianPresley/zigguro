//! Daily-note and template commands (E08.F07.S02.T01), headless: the app
//! registers `commands` with E15 and calls the `NotesCtx` methods. Files
//! go through `FilePort` (FileOps `create_file` as the user actor once
//! E08.F03 lands; `DirFiles` writes a directory directly meanwhile).
//! New notes with `{{ai: ...}}` sections are handed to the E10 fill hook
//! with the note and, for daily notes, yesterday's note as context.

const std = @import("std");
const datefmt = @import("datefmt.zig");
const localtime = @import("localtime.zig");
const templates = @import("templates.zig");
const daily = @import("daily.zig");
const note_index = @import("../index/note_index.zig");
const vault_mod = @import("../vault/vault.zig");
const names = @import("../index/names.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const FileId = @import("../vault/note.zig").FileId;
const Date = datefmt.Date;

pub const Command = struct { id: []const u8, title: []const u8, key: ?[]const u8 = null };

pub const commands = [_]Command{
    .{ .id = "notes.daily.today", .title = "Notes: Open Today's Daily Note", .key = "Alt+D" },
    .{ .id = "notes.daily.prev", .title = "Notes: Previous Daily Note" },
    .{ .id = "notes.daily.next", .title = "Notes: Next Daily Note" },
    .{ .id = "notes.newFromTemplate", .title = "Notes: New Note from Template" },
    .{ .id = "notes.insertTemplate", .title = "Notes: Insert Template" },
};

/// Vault-relative file access.
pub const FilePort = struct {
    ctx: *anyopaque,
    read: *const fn (ctx: *anyopaque, gpa: Allocator, path: []const u8) anyerror!?[]u8,
    /// Creates a new file (and its folders); fails if it exists.
    create: *const fn (ctx: *anyopaque, path: []const u8, bytes: []const u8) anyerror!void,
};

/// A `FilePort` over a vault directory.
pub const DirFiles = struct {
    dir: Io.Dir,
    io: Io,

    pub fn port(d: *DirFiles) FilePort {
        return .{ .ctx = d, .read = read, .create = create };
    }

    fn read(ctx: *anyopaque, gpa: Allocator, path: []const u8) anyerror!?[]u8 {
        const d: *DirFiles = @ptrCast(@alignCast(ctx));
        return d.dir.readFileAlloc(d.io, path, gpa, .limited(16 << 20)) catch |e| switch (e) {
            error.FileNotFound => null,
            else => e,
        };
    }

    fn create(ctx: *anyopaque, path: []const u8, bytes: []const u8) anyerror!void {
        const d: *DirFiles = @ptrCast(@alignCast(ctx));
        const parent = names.dirname(path);
        if (parent.len > 0) try d.dir.createDirPath(d.io, parent);
        const f = try d.dir.createFile(d.io, path, .{ .exclusive = true });
        defer f.close(d.io);
        try f.writeStreamingAll(d.io, bytes);
    }
};

/// The E10 hook that fills `{{ai: ...}}` placeholders (through an E12
/// pending change as the agent actor). `context` lists vault-relative
/// note paths.
pub const AiFill = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, note_path: []const u8, sections: []const templates.AiSection, context: []const []const u8) void,
};

pub const Opened = struct {
    /// Vault-relative (owned).
    path: []u8,
    /// Null for a note just created (the indexer has not seen it yet).
    id: ?FileId,
    created: bool,
    cursor: ?u32 = null,

    pub fn deinit(o: *Opened, gpa: Allocator) void {
        gpa.free(o.path);
    }
};

pub const NotesCtx = struct {
    gpa: Allocator,
    io: Io,
    ix: *note_index.NoteIndex,
    vault: *const vault_mod.Vault,
    files: FilePort,
    tz: *localtime.LocalTz,
    /// Null when E10 is absent: placeholders stay, with a Run action.
    ai_fill: ?AiFill = null,

    fn now(c: *NotesCtx) datefmt.DateTime {
        return localtime.nowLocal(c.io, c.tz);
    }

    /// `notes.daily.today`.
    pub fn today(c: *NotesCtx) !Opened {
        return c.openDaily(c.now());
    }

    /// Opens (creating from the daily template if needed) the note of
    /// `when`'s date.
    pub fn openDaily(c: *NotesCtx, when: datefmt.DateTime) !Opened {
        const cfg = &c.vault.config;
        const path = try daily.dailyPath(c.gpa, cfg, when.date);
        errdefer c.gpa.free(path);
        const view = try c.ix.reader();
        defer view.release();
        if (try view.idOfPath(c.gpa, c.vault.id, path)) |id| return .{ .path = path, .id = id, .created = false };
        const title = names.stemOf(path);
        var r = try c.render(cfg.daily_template, .{ .title = title, .now = when });
        defer r.deinit(c.gpa);
        try c.files.create(c.files.ctx, path, r.text);
        // Yesterday's note (the latest before today) as AI context.
        var list: std.ArrayList(daily.DailyNote) = .empty;
        defer list.deinit(c.gpa);
        try daily.listDailyNotes(c.gpa, view, c.vault, &list);
        var ctx_paths: [2][]const u8 = .{ path, "" };
        var n_ctx: usize = 1;
        if (daily.neighbor(list.items, when.date, .prev)) |y| if (view.pathOf(y.id)) |p| {
            ctx_paths[1] = p;
            n_ctx = 2;
        };
        c.fill(path, r.ai_sections, ctx_paths[0..n_ctx]);
        return .{ .path = path, .id = null, .created = true, .cursor = r.cursor };
    }

    /// `notes.daily.prev` / `notes.daily.next` from the daily note of
    /// `from` (or any date).
    pub fn step(c: *NotesCtx, from: Date, dir: daily.Direction) !?Opened {
        const view = try c.ix.reader();
        defer view.release();
        var list: std.ArrayList(daily.DailyNote) = .empty;
        defer list.deinit(c.gpa);
        try daily.listDailyNotes(c.gpa, view, c.vault, &list);
        const hit = daily.neighbor(list.items, from, dir) orelse return null;
        return .{ .path = try c.gpa.dupe(u8, view.pathOf(hit.id).?), .id = hit.id, .created = false };
    }

    /// `notes.newFromTemplate`: a new note titled `title` in the
    /// configured folder (` 1`, ` 2`, ... on clashes).
    pub fn newFromTemplate(c: *NotesCtx, template_path: []const u8, title: []const u8, current_dir: []const u8) !Opened {
        const cfg = &c.vault.config;
        const folder = switch (cfg.new_note_dir) {
            .vault_root => "",
            .same_as_current => current_dir,
            .fixed => std.mem.trim(u8, cfg.new_note_folder, "/"),
        };
        const view = try c.ix.reader();
        defer view.release();
        var k: u32 = 0;
        const path = while (true) : (k += 1) {
            var buf: [16]u8 = undefined;
            const suffix = if (k == 0) "" else try std.fmt.bufPrint(&buf, " {d}", .{k});
            const p = try joinPath(c.gpa, folder, title, suffix);
            if (try view.idOfPath(c.gpa, c.vault.id, p) == null) break p;
            c.gpa.free(p);
        };
        errdefer c.gpa.free(path);
        var r = try c.render(template_path, .{ .title = names.stemOf(path), .now = c.now() });
        defer r.deinit(c.gpa);
        try c.files.create(c.files.ctx, path, r.text);
        c.fill(path, r.ai_sections, &.{path});
        return .{ .path = path, .id = null, .created = true, .cursor = r.cursor };
    }

    /// `notes.insertTemplate`: the rendered template for the editor to
    /// insert at its cursor (`selection`/`clipboard` from the editor).
    pub fn insertTemplate(c: *NotesCtx, template_path: []const u8, vars: templates.TemplateVars) !templates.Rendered {
        return c.render(template_path, vars);
    }

    /// Renders the template at `template_path` (vault-relative, `.md`
    /// optional, inside `templates_dir` when bare); empty for none.
    fn render(c: *NotesCtx, template_path: []const u8, vars: templates.TemplateVars) !templates.Rendered {
        if (template_path.len == 0) return templates.renderTemplate(c.gpa, "", vars);
        const with_ext = if (names.isMdExt(template_path)) try c.gpa.dupe(u8, template_path) else try std.fmt.allocPrint(c.gpa, "{s}.md", .{template_path});
        defer c.gpa.free(with_ext);
        const tpl = (try c.files.read(c.files.ctx, c.gpa, with_ext)) orelse blk: {
            if (std.mem.indexOfScalar(u8, with_ext, '/') != null) break :blk null;
            const in_dir = try joinPath(c.gpa, std.mem.trim(u8, c.vault.config.templates_dir, "/"), names.withoutMd(with_ext), "");
            defer c.gpa.free(in_dir);
            break :blk try c.files.read(c.files.ctx, c.gpa, in_dir);
        } orelse return error.TemplateNotFound;
        defer c.gpa.free(tpl);
        return templates.renderTemplate(c.gpa, tpl, vars);
    }

    fn fill(c: *NotesCtx, path: []const u8, sections: []const templates.AiSection, context: []const []const u8) void {
        if (sections.len == 0) return;
        const hook = c.ai_fill orelse return;
        hook.run(hook.ctx, path, sections, context);
    }
};

fn joinPath(gpa: Allocator, folder: []const u8, name: []const u8, suffix: []const u8) ![]u8 {
    if (folder.len == 0) return std.fmt.allocPrint(gpa, "{s}{s}.md", .{ name, suffix });
    return std.fmt.allocPrint(gpa, "{s}/{s}{s}.md", .{ folder, name, suffix });
}
