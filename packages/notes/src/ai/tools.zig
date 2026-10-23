//! zg_notes' tools for agents (E08.F08.S02.T01): `search_notes`,
//! `read_note`, `note_links` (read-only) and `create_note`,
//! `update_note`, `daily_note`, which never write: they propose E12
//! pending changes through `ChangePort` and return the changeset id. Like
//! zg_scm, the exporter is generic over zg_ai's foreign-tool contract:
//!
//! ```zig
//! const X = zg_notes.ai.tools.ToolExporter(zg_ai.tools.adapters.foreign);
//! var x: X = .{ .src = .{ ... } };
//! services.notes = &.{x.exporter()};
//! ```
//!
//! Results are MCP `CallToolResult` JSON whose text block is the tool's
//! JSON output, capped at `max_output` bytes (lists drop their tail and
//! say `truncated`). Every path is checked against `PathPolicy` first.

const std = @import("std");
const note_index = @import("../index/note_index.zig");
const search_index = @import("../search/search_index.zig");
const query = @import("../search/query.zig");
const exec = @import("../search/exec.zig");
const retriever = @import("../search/retriever.zig");
const vault_mod = @import("../vault/vault.zig");
const note = @import("../vault/note.zig");
const frontmatter = @import("zg_frontmatter").frontmatter;
const fm_writer = @import("zg_frontmatter").fm_writer;
const names = @import("../index/names.zig");
const commands = @import("../daily/commands.zig");
const daily = @import("../daily/daily.zig");
const datefmt = @import("../daily/datefmt.zig");
const localtime = @import("../daily/localtime.zig");
const templates = @import("../daily/templates.zig");
const edits_mod = @import("edits.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const FileId = note.FileId;

pub const schemas = struct {
    pub const search_notes = @embedFile("schemas/search_notes.json");
    pub const read_note = @embedFile("schemas/read_note.json");
    pub const note_links = @embedFile("schemas/note_links.json");
    pub const create_note = @embedFile("schemas/create_note.json");
    pub const update_note = @embedFile("schemas/update_note.json");
    pub const daily_note = @embedFile("schemas/daily_note.json");
};

/// One proposed file change: `base` null creates the file.
pub const FileChange = struct { path: []const u8, base: ?[]const u8, new: []const u8 };

/// Submits agent changes as one E12 changeset (agent actor, pending
/// review; open documents go through `AgentEditSession.propose`).
pub const ChangePort = struct {
    ctx: *anyopaque,
    propose: *const fn (ctx: *anyopaque, label: []const u8, tool: []const u8, changes: []const FileChange) anyerror!u64,
};

/// E16 path policy: null allows, else the reason for refusing.
pub const PathPolicy = struct {
    ctx: *anyopaque,
    check: *const fn (ctx: *anyopaque, vault_path: []const u8, write: bool) ?[]const u8,
};

pub const Source = struct {
    gpa: Allocator,
    ix: *note_index.NoteIndex,
    search: ?*search_index.SearchIndex = null,
    vault: *const vault_mod.Vault,
    /// Reads note text (writes go through `changes`).
    files: commands.FilePort,
    changes: ChangePort,
    tz: *localtime.LocalTz,
    io: Io,
    policy: ?PathPolicy = null,
    max_output: usize = 32 << 10,
};

pub const Error = error{ BadInput, Denied };

/// `Foreign` is `zg_ai.tools.adapters.foreign` (or a test double with the
/// same declarations). Must not move after `exporter`.
pub fn ToolExporter(comptime Foreign: type) type {
    return struct {
        const Self = @This();

        src: Source,

        pub fn exporter(self: *Self) Foreign.Exporter {
            return .{ .name = "notes", .kind = .notes, .ctx = self, .list = list, .call = call };
        }

        fn list(ctx: *anyopaque, arena: Allocator) anyerror![]const Foreign.ForeignTool {
            _ = ctx;
            return arena.dupe(Foreign.ForeignTool, &.{
                .{ .name = "search_notes", .description = "Search the notes vault (BM25 ranking, Obsidian query syntax). Returns paths, titles, scores, snippets and tags.", .input_schema_json = schemas.search_notes, .read_only = true },
                .{ .name = "read_note", .description = "Read a note, or one section or ^block of it, with its properties, outgoing links and backlink count.", .input_schema_json = schemas.read_note, .read_only = true },
                .{ .name = "note_links", .description = "The notes a note links to and/or that link to it, up to two hops.", .input_schema_json = schemas.note_links, .read_only = true },
                .{ .name = "create_note", .description = "Propose a new note (from a template, content and properties). Nothing is written until a human approves the change.", .input_schema_json = schemas.create_note, .mutates = true },
                .{ .name = "update_note", .description = "Propose edits to a note: append, append_section, replace_section, str_replace (unique match), set_property, remove_property, add_tag. Applied only after review.", .input_schema_json = schemas.update_note, .mutates = true },
                .{ .name = "daily_note", .description = "The daily note's path for a date (default today); with `append`, propose appending to it (creating it from the daily template if needed).", .input_schema_json = schemas.daily_note, .mutates = true },
            });
        }

        fn call(ctx: *anyopaque, io: Io, arena: Allocator, tool: []const u8, input_json: []const u8) anyerror!Foreign.Result {
            _ = io;
            const self: *Self = @ptrCast(@alignCast(ctx));
            const r = try run(&self.src, arena, tool, input_json);
            return .{ .json = r.json, .changeset = r.changeset };
        }
    };
}

pub const Output = struct { json: []const u8, changeset: ?u64 = null, is_error: bool = false };

/// Runs `tool` and wraps its output as a `CallToolResult`.
pub fn run(src: *Source, arena: Allocator, tool: []const u8, input_json: []const u8) !Output {
    var msg: []const u8 = "";
    var cs: ?u64 = null;
    const body = runTool(src, arena, tool, if (input_json.len == 0) "{}" else input_json, &msg, &cs) catch |e| switch (e) {
        error.OutOfMemory => return e,
        error.BadInput, error.Denied => null,
        error.UnknownTool => return e,
        else => blk: {
            msg = try std.fmt.allocPrint(arena, "{s} failed: {t}", .{ tool, e });
            break :blk null;
        },
    };
    const text = body orelse msg;
    return .{ .json = try resultJson(arena, text, body == null), .changeset = cs, .is_error = body == null };
}

fn resultJson(arena: Allocator, text: []const u8, is_error: bool) ![]const u8 {
    const Block = struct { type: []const u8 = "text", text: []const u8 };
    const R = struct { content: []const Block, isError: bool };
    return std.json.Stringify.valueAlloc(arena, R{ .content = &.{.{ .text = text }}, .isError = is_error }, .{});
}

fn bad(arena: Allocator, msg: *[]const u8, comptime fmt: []const u8, args: anytype) Error {
    msg.* = std.fmt.allocPrint(arena, fmt, args) catch "invalid input";
    return error.BadInput;
}

fn checkPath(src: *Source, arena: Allocator, msg: *[]const u8, path: []const u8, write: bool) !void {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOf(u8, path, "..") != null or std.mem.indexOfScalar(u8, path, '\\') != null)
        return bad(arena, msg, "invalid path \"{s}\": use a vault-relative path", .{path});
    if (src.policy) |p| if (p.check(p.ctx, path, write)) |reason| {
        msg.* = try std.fmt.allocPrint(arena, "access to {s} denied: {s}", .{ path, reason });
        return error.Denied;
    };
}

fn runTool(src: *Source, arena: Allocator, tool: []const u8, input: []const u8, msg: *[]const u8, cs: *?u64) !?[]const u8 {
    if (std.mem.eql(u8, tool, "search_notes")) return searchNotes(src, arena, input, msg);
    if (std.mem.eql(u8, tool, "read_note")) return readNote(src, arena, input, msg);
    if (std.mem.eql(u8, tool, "note_links")) return noteLinks(src, arena, input, msg);
    if (std.mem.eql(u8, tool, "create_note")) return createNote(src, arena, input, msg, cs);
    if (std.mem.eql(u8, tool, "update_note")) return updateNote(src, arena, input, msg, cs);
    if (std.mem.eql(u8, tool, "daily_note")) return dailyNote(src, arena, input, msg, cs);
    return error.UnknownTool;
}

fn parse(comptime T: type, arena: Allocator, input: []const u8, msg: *[]const u8) !T {
    return std.json.parseFromSliceLeaky(T, arena, input, .{}) catch
        bad(arena, msg, "the arguments do not match the tool's schema", .{});
}

/// A JSON object whose `items` array is cut to fit `cap` bytes.
fn boundedList(arena: Allocator, comptime T: type, items: []const T, cap: usize, hint: []const u8) ![]const u8 {
    var n = items.len;
    while (true) {
        const truncated = n < items.len;
        const s = try std.json.Stringify.valueAlloc(arena, .{ .items = items[0..n], .truncated = truncated, .hint = if (truncated) hint else null }, .{ .emit_null_optional_fields = false });
        if (s.len <= cap or n == 0) return s;
        n = n * 3 / 4;
    }
}

// ---- read tools ----

fn searchNotes(src: *Source, arena: Allocator, input: []const u8, msg: *[]const u8) !?[]const u8 {
    const In = struct { query: []const u8, limit: ?u32 = null };
    const in = try parse(In, arena, input, msg);
    const s = src.search orelse return bad(arena, msg, "note search is not available", .{});
    const ast = switch (query.parseQuery(arena, in.query)) {
        .ok => |x| x,
        .err => |e| return bad(arena, msg, "query error at {d}..{d}: {s}", .{ e.span[0], e.span[1], e.msg }),
    };
    var hits: std.ArrayList(retriever.Scored) = .empty;
    try exec.search(s, arena, &ast, @min(in.limit orelse 20, 50), &hits);
    const view = try src.ix.reader();
    defer view.release();
    const Hit = struct { id: u64, path: []const u8, title: []const u8, score: f32, snippets: []const []const u8, tags: []const []const u8 };
    var out: std.ArrayList(Hit) = .empty;
    for (hits.items) |h| {
        const meta = view.note(h.note) orelse continue;
        const path = view.pathOf(h.note) orelse continue;
        if (src.policy) |p| if (p.check(p.ctx, path, false) != null) continue;
        var snips: std.ArrayList([]const u8) = .empty;
        if (h.n_snippets > 0) if (try src.files.read(src.files.ctx, arena, path)) |text| {
            for (h.snippets[0..h.n_snippets]) |sn| try snips.append(arena, text[@min(sn.range[0], text.len)..@min(sn.range[1], text.len)]);
        };
        var tags: std.ArrayList([]const u8) = .empty;
        for (meta.tags) |t| try tags.append(arena, t.display);
        try out.append(arena, .{ .id = names.idKey(h.note), .path = path, .title = meta.title, .score = h.score, .snippets = snips.items, .tags = tags.items });
    }
    return try boundedList(arena, Hit, out.items, src.max_output, "lower `limit` or narrow the query");
}

fn readNote(src: *Source, arena: Allocator, input: []const u8, msg: *[]const u8) !?[]const u8 {
    const In = struct { path: ?[]const u8 = null, id: ?u64 = null, section: ?[]const u8 = null, block: ?[]const u8 = null, include_frontmatter: bool = false };
    const args = try parse(In, arena, input, msg);
    const view = try src.ix.reader();
    defer view.release();
    var in = args;
    const id: FileId = if (args.path) |p| blk: {
        try checkPath(src, arena, msg, p, false);
        break :blk (try view.idOfPath(arena, src.vault.id, p)) orelse return bad(arena, msg, "no note at {s}", .{p});
    } else if (args.id) |raw| blk: {
        const fid: FileId = @bitCast(raw);
        const e = view.entry(fid) orelse return bad(arena, msg, "no note with id {d}", .{raw});
        if (e.vault != src.vault.id) return bad(arena, msg, "no note with id {d}", .{raw});
        try checkPath(src, arena, msg, e.path, false);
        in.path = e.path;
        break :blk fid;
    } else return bad(arena, msg, "give `path` or `id`", .{});
    const path = in.path.?;
    const meta = view.note(id) orelse return bad(arena, msg, "{s} is not a note", .{path});
    const text = (try src.files.read(src.files.ctx, arena, path)) orelse return bad(arena, msg, "cannot read {s}", .{path});
    var range: [2]u32 = .{ 0, @intCast(text.len) };
    if (!in.include_frontmatter) if (meta.fm_range) |r| {
        range[0] = @min(r[1], range[1]);
    };
    if (in.section) |want| {
        const w = std.mem.trim(u8, std.mem.trimStart(u8, want, "#"), " ");
        const hi = for (meta.headings, 0..) |h, i| {
            if (std.ascii.eqlIgnoreCase(h.text, w)) break i;
        } else return bad(arena, msg, "no heading \"{s}\" in {s}", .{ w, path });
        range = meta.sectionRange(hi, @intCast(text.len));
    } else if (in.block) |want| {
        const b = std.mem.trimStart(u8, want, "^");
        const blk = for (meta.blocks) |x| {
            if (std.mem.eql(u8, x.id, b)) break x;
        } else return bad(arena, msg, "no block ^{s} in {s}", .{ b, path });
        range = blk.range;
    }
    var body = text[@min(range[0], text.len)..@min(range[1], text.len)];
    var truncated = false;
    const budget = src.max_output -| 4096;
    if (body.len > budget) {
        var cut = budget;
        while (cut > 0 and (body[cut] & 0xC0) == 0x80) cut -= 1;
        body = body[0..cut];
        truncated = true;
    }
    const Prop = struct { name: []const u8, type: []const u8, value: []const u8 };
    var props: std.ArrayList(Prop) = .empty;
    for (meta.props) |p| try props.append(arena, .{ .name = p.name, .type = @tagName(p.ty), .value = text[@min(p.node.src[0], text.len)..@min(p.node.src[1], text.len)] });
    const Out = struct { target: []const u8, path: ?[]const u8 };
    var outs: std.ArrayList(Out) = .empty;
    for (meta.links, view.outgoing(id)) |l, r| if (outs.items.len < 200) {
        try outs.append(arena, .{ .target = l.target, .path = if (r.kind == .note or r.kind == .attachment) view.pathOf(r.id) else null });
    };
    const lines = std.mem.count(u8, body, "\n") + @intFromBool(body.len > 0 and body[body.len - 1] != '\n');
    return try std.json.Stringify.valueAlloc(arena, .{
        .path = path,
        .text = body,
        .lines = lines,
        .properties = props.items,
        .links_out = outs.items,
        .backlinks_count = view.backlinks(id).len,
        .truncated = truncated,
        .hint = if (truncated) @as(?[]const u8, "read one `section` or `block` at a time") else null,
    }, .{ .emit_null_optional_fields = false });
}

fn noteLinks(src: *Source, arena: Allocator, input: []const u8, msg: *[]const u8) !?[]const u8 {
    const Dir = enum { in, out, both };
    const In = struct { path: []const u8, direction: Dir, depth: u8 = 1 };
    const in = try parse(In, arena, input, msg);
    if (in.depth < 1 or in.depth > 2) return bad(arena, msg, "depth must be 1 or 2", .{});
    try checkPath(src, arena, msg, in.path, false);
    const view = try src.ix.reader();
    defer view.release();
    const start = (try view.idOfPath(arena, src.vault.id, in.path)) orelse return bad(arena, msg, "no note at {s}", .{in.path});
    const Edge = struct { from: []const u8, to: []const u8, depth: u8 };
    var edges: std.ArrayList(Edge) = .empty;
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    var edge_seen: std.StringHashMapUnmanaged(void) = .empty;
    var frontier: std.ArrayList(FileId) = .empty;
    try frontier.append(arena, start);
    try seen.put(arena, @bitCast(start), {});
    var d: u8 = 1;
    while (d <= in.depth) : (d += 1) {
        var next: std.ArrayList(FileId) = .empty;
        for (frontier.items) |id| {
            const from = view.pathOf(id).?;
            if (in.direction != .in) for (view.outgoing(id)) |r| {
                if (r.kind != .note and r.kind != .attachment) continue;
                try addEdge(arena, &edges, &edge_seen, from, view.pathOf(r.id).?, d, Edge);
                if ((try seen.getOrPut(arena, @bitCast(r.id))).found_existing) continue;
                try next.append(arena, r.id);
            };
            if (in.direction != .out) for (view.backlinks(id)) |b| {
                try addEdge(arena, &edges, &edge_seen, view.pathOf(b.source).?, from, d, Edge);
                if ((try seen.getOrPut(arena, @bitCast(b.source))).found_existing) continue;
                try next.append(arena, b.source);
            };
        }
        frontier = next;
    }
    // Policy-denied notes are left out.
    var kept: std.ArrayList(Edge) = .empty;
    for (edges.items) |e| {
        if (src.policy) |p| if (p.check(p.ctx, e.from, false) != null or p.check(p.ctx, e.to, false) != null) continue;
        try kept.append(arena, e);
    }
    return try boundedList(arena, Edge, kept.items, src.max_output, "use depth 1 or a single direction");
}

fn addEdge(arena: Allocator, edges: anytype, seen: *std.StringHashMapUnmanaged(void), from: []const u8, to: []const u8, d: u8, comptime Edge: type) !void {
    const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ from, to });
    if ((try seen.getOrPut(arena, key)).found_existing) return;
    try edges.append(arena, Edge{ .from = from, .to = to, .depth = d });
}

// ---- write tools ----

fn propose(src: *Source, arena: Allocator, tool: []const u8, label: []const u8, changes: []const FileChange) !u64 {
    _ = arena;
    return src.changes.propose(src.changes.ctx, label, tool, changes);
}

/// A file-name-safe version of `title`.
pub fn slugTitle(a: Allocator, title: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (std.mem.trim(u8, title, " .")) |c| switch (c) {
        '/', '\\', ':', '*', '?', '"', '<', '>', '|', '#', '^', '[', ']' => try out.append(a, '-'),
        else => if (c >= 0x20) try out.append(a, c),
    };
    if (out.items.len == 0) try out.appendSlice(a, "Untitled");
    return out.items;
}

fn createNote(src: *Source, arena: Allocator, input: []const u8, msg: *[]const u8, cs: *?u64) !?[]const u8 {
    const In = struct { path: ?[]const u8 = null, title: ?[]const u8 = null, template: ?[]const u8 = null, content: ?[]const u8 = null, properties: ?std.json.Value = null };
    const in = try parse(In, arena, input, msg);
    const cfg = &src.vault.config;
    const path = if (in.path) |p|
        (if (names.isMdExt(p)) p else try std.fmt.allocPrint(arena, "{s}.md", .{p}))
    else blk: {
        const title = in.title orelse return bad(arena, msg, "give `path` or `title`", .{});
        const folder = if (cfg.new_note_dir == .fixed) std.mem.trim(u8, cfg.new_note_folder, "/") else "";
        const slug = try slugTitle(arena, title);
        break :blk if (folder.len > 0) try std.fmt.allocPrint(arena, "{s}/{s}.md", .{ folder, slug }) else try std.fmt.allocPrint(arena, "{s}.md", .{slug});
    };
    try checkPath(src, arena, msg, path, true);
    {
        const view = try src.ix.reader();
        defer view.release();
        if (try view.idOfPath(arena, src.vault.id, path) != null) return bad(arena, msg, "{s} exists; use update_note", .{path});
    }
    const title = in.title orelse names.stemOf(path);
    var text: []const u8 = "";
    if (in.template) |t| {
        var c: commands.NotesCtx = .{ .gpa = arena, .io = src.io, .ix = src.ix, .vault = src.vault, .files = src.files, .tz = src.tz };
        const r = c.insertTemplate(t, .{ .title = title, .now = localtime.nowLocal(src.io, src.tz) }) catch |e| switch (e) {
            error.TemplateNotFound => return bad(arena, msg, "no template \"{s}\"", .{t}),
            else => return e,
        };
        text = r.text;
    }
    if (in.content) |c| text = if (text.len > 0) try std.mem.concat(arena, u8, &.{ text, if (text[text.len - 1] == '\n') "" else "\n", c }) else c;
    if (text.len > 0 and text[text.len - 1] != '\n') text = try std.mem.concat(arena, u8, &.{ text, "\n" });
    if (in.properties) |props| {
        if (props != .object) return bad(arena, msg, "`properties` must be an object", .{});
        var pe: std.ArrayList(fm_writer.PropEdit) = .empty;
        var it = props.object.iterator();
        while (it.next()) |kv| {
            const v = (try edits_mod.valueFromJson(arena, kv.value_ptr.*)) orelse return bad(arena, msg, "property {s}: use a string, number, boolean, null or a list of those", .{kv.key_ptr.*});
            try pe.append(arena, .{ .set = .{ .name = kv.key_ptr.*, .value = v } });
        }
        text = try fm_writer.applyPropEdits(arena, text, pe.items);
    }
    const id = try propose(src, arena, "create_note", try std.fmt.allocPrint(arena, "Create {s}", .{path}), &.{.{ .path = path, .base = null, .new = text }});
    cs.* = id;
    return try std.json.Stringify.valueAlloc(arena, .{ .pending_change = id, .path = path }, .{});
}

const EditIn = struct {
    op: []const u8,
    text: ?[]const u8 = null,
    heading: ?[]const u8 = null,
    old: ?[]const u8 = null,
    new: ?[]const u8 = null,
    name: ?[]const u8 = null,
    value: ?std.json.Value = null,
    tag: ?[]const u8 = null,
};

fn toEdit(arena: Allocator, e: EditIn, msg: *[]const u8) !edits_mod.Edit {
    const op = e.op;
    if (std.mem.eql(u8, op, "append")) return .{ .append = e.text orelse return bad(arena, msg, "append needs `text`", .{}) };
    if (std.mem.eql(u8, op, "append_section") or std.mem.eql(u8, op, "replace_section")) {
        const h = e.heading orelse return bad(arena, msg, "{s} needs `heading`", .{op});
        const t = e.text orelse return bad(arena, msg, "{s} needs `text`", .{op});
        return if (op[0] == 'a') .{ .append_section = .{ .heading = h, .text = t } } else .{ .replace_section = .{ .heading = h, .text = t } };
    }
    if (std.mem.eql(u8, op, "str_replace")) return .{ .str_replace = .{ .old = e.old orelse return bad(arena, msg, "str_replace needs `old`", .{}), .new = e.new orelse return bad(arena, msg, "str_replace needs `new`", .{}) } };
    if (std.mem.eql(u8, op, "set_property")) {
        const n = e.name orelse return bad(arena, msg, "set_property needs `name`", .{});
        const v = (try edits_mod.valueFromJson(arena, e.value orelse .null)) orelse return bad(arena, msg, "property {s}: use a string, number, boolean, null or a list of those", .{n});
        return .{ .set_property = .{ .name = n, .value = v } };
    }
    if (std.mem.eql(u8, op, "remove_property")) return .{ .remove_property = e.name orelse return bad(arena, msg, "remove_property needs `name`", .{}) };
    if (std.mem.eql(u8, op, "add_tag")) return .{ .add_tag = e.tag orelse return bad(arena, msg, "add_tag needs `tag`", .{}) };
    return bad(arena, msg, "unknown op \"{s}\"", .{op});
}

fn updateNote(src: *Source, arena: Allocator, input: []const u8, msg: *[]const u8, cs: *?u64) !?[]const u8 {
    const In = struct { path: []const u8, edits: []const EditIn };
    const in = try parse(In, arena, input, msg);
    if (in.edits.len == 0) return bad(arena, msg, "`edits` is empty", .{});
    try checkPath(src, arena, msg, in.path, true);
    {
        const view = try src.ix.reader();
        defer view.release();
        if (try view.idOfPath(arena, src.vault.id, in.path) == null) return bad(arena, msg, "no note at {s}", .{in.path});
    }
    const base = (try src.files.read(src.files.ctx, arena, in.path)) orelse return bad(arena, msg, "cannot read {s}", .{in.path});
    const es = try arena.alloc(edits_mod.Edit, in.edits.len);
    for (in.edits, es) |e, *o| o.* = try toEdit(arena, e, msg);
    const new = switch (try edits_mod.apply(arena, base, es, &src.vault.config)) {
        .ok => |t| t,
        .err => |m| return bad(arena, msg, "{s}", .{m}),
    };
    if (std.mem.eql(u8, new, base)) return try std.json.Stringify.valueAlloc(arena, .{ .pending_change = null, .unchanged = true }, .{});
    const id = try propose(src, arena, "update_note", try std.fmt.allocPrint(arena, "Edit {s}", .{in.path}), &.{.{ .path = in.path, .base = base, .new = new }});
    cs.* = id;
    return try std.json.Stringify.valueAlloc(arena, .{ .pending_change = id }, .{});
}

fn dailyNote(src: *Source, arena: Allocator, input: []const u8, msg: *[]const u8, cs: *?u64) !?[]const u8 {
    const In = struct { date: ?[]const u8 = null, append: ?[]const u8 = null };
    const in = try parse(In, arena, input, msg);
    const now = localtime.nowLocal(src.io, src.tz);
    const date: datefmt.Date = if (in.date) |d|
        (if (d.len == 10) frontmatter.parseDate(d) else null) orelse return bad(arena, msg, "date must be YYYY-MM-DD", .{})
    else
        now.date;
    const path = try daily.dailyPath(arena, &src.vault.config, date);
    try checkPath(src, arena, msg, path, in.append != null);
    const exists = blk: {
        const view = try src.ix.reader();
        defer view.release();
        break :blk try view.idOfPath(arena, src.vault.id, path) != null;
    };
    const add = in.append orelse return try std.json.Stringify.valueAlloc(arena, .{ .path = path, .exists = exists }, .{});
    var change: FileChange = undefined;
    if (exists) {
        const base = (try src.files.read(src.files.ctx, arena, path)) orelse return bad(arena, msg, "cannot read {s}", .{path});
        const new = (try edits_mod.apply(arena, base, &.{.{ .append = add }}, &src.vault.config)).ok;
        change = .{ .path = path, .base = base, .new = new };
    } else {
        var c: commands.NotesCtx = .{ .gpa = arena, .io = src.io, .ix = src.ix, .vault = src.vault, .files = src.files, .tz = src.tz };
        const r = c.insertTemplate(src.vault.config.daily_template, .{ .title = names.stemOf(path), .now = .{ .date = date, .h = now.h, .min = now.min, .s = now.s, .utc_offset_s = now.utc_offset_s } }) catch |e| switch (e) {
            error.TemplateNotFound => try templates.renderTemplate(arena, "", .{ .title = "", .now = now }),
            else => return e,
        };
        const new = (try edits_mod.apply(arena, r.text, &.{.{ .append = add }}, &src.vault.config)).ok;
        change = .{ .path = path, .base = null, .new = new };
    }
    const id = try propose(src, arena, "daily_note", try std.fmt.allocPrint(arena, "Append to {s}", .{path}), &.{change});
    cs.* = id;
    return try std.json.Stringify.valueAlloc(arena, .{ .path = path, .pending_change = id }, .{});
}
