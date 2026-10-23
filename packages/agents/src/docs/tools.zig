//! Document tools for agents (E13.F04.S01.T01), exported through zg_ai's
//! foreign-tool contract:
//!
//! - `doc_outline`, `doc_read_section`, `doc_search`: read the document
//!   by sections (read-only).
//! - `doc_propose_edit`, `doc_insert`: propose changes, each one E12
//!   changeset of word hunks for the person to review. Nothing writes the
//!   document directly.
//! - `doc_add_comment`, `doc_reply`, `doc_list_comments`,
//!   `doc_resolve_comment`: margin comment threads (E13.F04.S02.T01),
//!   when the session has a comment store.
//!
//! `Source.allow` narrows the tools for one request (the "suggest edits
//! as comments" shortcut takes the editing tools away).
//!
//! The app makes one exporter per session and run (`Source.prov`).

const std = @import("std");
const zg_ai = @import("zg_ai");
const doc = @import("doc_session.zig");
const sections_mod = @import("sections.zig");
const comments_mod = @import("comments.zig");
const words = @import("words.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const foreign = zg_ai.tools.adapters.foreign;
const DocSession = doc.DocSession;

pub const Source = struct {
    session: *DocSession,
    prov: doc.Provenance = .{},
    /// `doc_read_section` returns at most this many tokens of text.
    max_section_tokens: u32 = 8000,
    estimator: ?*const zg_ai.models.estimate.TokenEstimator = null,
    /// Model family for the estimate.
    family: []const u8 = "",
    max_hits: u32 = 50,
    /// The document's comment threads (the comment tools need them).
    comments: ?*comments_mod.CommentStore = null,
    /// Only these tools, for this request (null: all).
    allow: ?[]const []const u8 = null,

    pub fn allows(src: *const Source, tool: []const u8) bool {
        const names = src.allow orelse return true;
        for (names) |t| if (std.mem.eql(u8, t, tool)) return true;
        return false;
    }
};

pub const schemas = struct {
    const section = "\"section\":{\"type\":\"string\",\"description\":\"A section id from doc_outline (such as 2.1), or its slug.\"}";
    const rationale = "\"rationale\":{\"type\":\"string\",\"description\":\"Why, in a sentence, shown to the person reviewing.\"}";
    pub const outline = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}";
    pub const read_section = "{\"type\":\"object\",\"required\":[\"section\"],\"properties\":{" ++ section ++ ",\"include_children\":{\"type\":\"boolean\",\"description\":\"Include subsections (default true).\"}},\"additionalProperties\":false}";
    pub const search = "{\"type\":\"object\",\"required\":[\"text\"],\"properties\":{\"text\":{\"type\":\"string\"}},\"additionalProperties\":false}";
    pub const propose_edit = "{\"type\":\"object\",\"required\":[\"old_text\",\"new_text\"],\"properties\":{" ++ section ++
        ",\"old_text\":{\"type\":\"string\",\"description\":\"The exact text to replace, unique within the section (or the document).\"},\"new_text\":{\"type\":\"string\"}," ++ rationale ++ "},\"additionalProperties\":false}";
    pub const insert = "{\"type\":\"object\",\"required\":[\"text\"],\"properties\":{\"after_section\":{\"type\":\"string\",\"description\":\"Insert after this section and its subsections; omit to append to the document.\"}," ++
        "\"at_anchor\":{\"type\":\"integer\"},\"text\":{\"type\":\"string\",\"description\":\"Markdown to insert.\"}," ++ rationale ++ "},\"additionalProperties\":false}";
    const thread = "\"thread\":{\"type\":\"integer\",\"description\":\"A thread id from doc_list_comments.\"}";
    pub const add_comment = "{\"type\":\"object\",\"required\":[\"anchor_text\",\"text\"],\"properties\":{\"anchor_text\":{\"type\":\"string\",\"description\":\"The exact text the comment is about.\"},\"text\":{\"type\":\"string\"}},\"additionalProperties\":false}";
    pub const reply = "{\"type\":\"object\",\"required\":[\"thread\",\"text\"],\"properties\":{" ++ thread ++ ",\"text\":{\"type\":\"string\"},\"proposal\":{\"type\":\"integer\",\"description\":\"A changeset from doc_propose_edit that this reply offers; accepting it resolves the thread.\"}},\"additionalProperties\":false}";
    pub const list_comments = "{\"type\":\"object\",\"properties\":{\"include_resolved\":{\"type\":\"boolean\"}},\"additionalProperties\":false}";
    pub const resolve_comment = "{\"type\":\"object\",\"required\":[\"thread\"],\"properties\":{" ++ thread ++ "},\"additionalProperties\":false}";
};

pub const tool_list = [_]foreign.ForeignTool{
    .{ .name = "doc_outline", .description = "The open document's sections: id, slug, title, heading level and word count.", .input_schema_json = schemas.outline, .read_only = true },
    .{ .name = "doc_read_section", .description = "The Markdown of one section. Very long sections return their own text and a list of subsections to read one by one.", .input_schema_json = schemas.read_section, .read_only = true },
    .{ .name = "doc_search", .description = "Lines of the document containing the text (ignoring case), with their sections.", .input_schema_json = schemas.search, .read_only = true },
    .{ .name = "doc_propose_edit", .description = "Propose replacing old_text with new_text, within a section or the whole document. The person reviews the change; if they have edited the text meanwhile, the current text comes back to retry with.", .input_schema_json = schemas.propose_edit, .mutates = true },
    .{ .name = "doc_insert", .description = "Propose inserting Markdown after a section (or at the end). The person reviews it.", .input_schema_json = schemas.insert, .mutates = true },
    .{ .name = "doc_add_comment", .description = "Leave a margin comment on some exact text of the document, without changing it.", .input_schema_json = schemas.add_comment },
    .{ .name = "doc_reply", .description = "Reply in a comment thread, optionally offering a proposed changeset.", .input_schema_json = schemas.reply },
    .{ .name = "doc_list_comments", .description = "The document's comment threads: the text each is about and its comments.", .input_schema_json = schemas.list_comments, .read_only = true },
    .{ .name = "doc_resolve_comment", .description = "Mark a comment thread resolved.", .input_schema_json = schemas.resolve_comment },
};

/// The tools a "suggest edits as comments" request keeps: reading, and
/// leaving comments.
pub const comment_only_tools = [_][]const u8{ "doc_outline", "doc_read_section", "doc_search", "doc_list_comments", "doc_add_comment" };

/// Must not move after `exporter`.
pub const ToolExporter = struct {
    src: Source,

    pub fn exporter(self: *ToolExporter) foreign.Exporter {
        return .{ .name = "docs", .kind = .agents, .ctx = self, .list = listFn, .call = callFn };
    }

    fn listFn(ctx: *anyopaque, arena: Allocator) anyerror![]const foreign.ForeignTool {
        const self: *ToolExporter = @ptrCast(@alignCast(ctx));
        return list(&self.src, arena);
    }

    fn callFn(ctx: *anyopaque, io: Io, arena: Allocator, tool: []const u8, input_json: []const u8) anyerror!foreign.Result {
        _ = io;
        const self: *ToolExporter = @ptrCast(@alignCast(ctx));
        const r = try run(&self.src, arena, tool, input_json);
        return .{ .json = r.json, .changeset = r.changeset };
    }
};

/// The tools `src` offers.
pub fn list(src: *const Source, arena: Allocator) ![]const foreign.ForeignTool {
    var out: std.ArrayList(foreign.ForeignTool) = .empty;
    for (tool_list) |t| {
        if (!src.allows(t.name)) continue;
        if (src.comments == null and isCommentTool(t.name)) continue;
        try out.append(arena, t);
    }
    return out.items;
}

fn isCommentTool(name: []const u8) bool {
    return std.mem.indexOf(u8, name, "comment") != null or std.mem.eql(u8, name, "doc_reply");
}

pub const Output = struct { json: []const u8, changeset: ?u64 = null, is_error: bool = false, text: []const u8 = "" };

/// Runs `tool` and wraps its output as a `CallToolResult`.
pub fn run(src: *Source, arena: Allocator, tool: []const u8, input_json: []const u8) !Output {
    var msg: []const u8 = "";
    var cs: ?u64 = null;
    const body = runTool(src, arena, tool, if (input_json.len == 0) "{}" else input_json, &msg, &cs) catch |e| switch (e) {
        error.OutOfMemory, error.UnknownTool => return e,
        error.BadInput => null,
        else => blk: {
            msg = try std.fmt.allocPrint(arena, "{s} failed: {t}", .{ tool, e });
            break :blk null;
        },
    };
    const text = body orelse msg;
    const Block = struct { type: []const u8 = "text", text: []const u8 };
    const R = struct { content: []const Block, isError: bool };
    const json = try std.json.Stringify.valueAlloc(arena, R{ .content = &.{.{ .text = text }}, .isError = body == null }, .{});
    return .{ .json = json, .changeset = cs, .is_error = body == null, .text = text };
}

fn runTool(src: *Source, a: Allocator, tool: []const u8, input: []const u8, msg: *[]const u8, cs: *?u64) ![]const u8 {
    const eq = std.mem.eql;
    if (!src.allows(tool)) {
        msg.* = try std.fmt.allocPrint(a, "{s} is not available for this request", .{tool});
        return error.BadInput;
    }
    if (eq(u8, tool, "doc_outline")) return outlineTool(src, a);
    if (eq(u8, tool, "doc_read_section")) return readTool(src, a, input, msg);
    if (eq(u8, tool, "doc_search")) return searchTool(src, a, input, msg);
    if (eq(u8, tool, "doc_propose_edit")) return proposeTool(src, a, input, msg, cs);
    if (eq(u8, tool, "doc_insert")) return insertTool(src, a, input, msg, cs);
    if (isCommentTool(tool)) {
        const store = src.comments orelse {
            msg.* = "comments are not available for this document";
            return error.BadInput;
        };
        if (eq(u8, tool, "doc_add_comment")) return addCommentTool(src, store, a, input, msg);
        if (eq(u8, tool, "doc_reply")) return replyTool(src, store, a, input, msg);
        if (eq(u8, tool, "doc_list_comments")) return listCommentsTool(store, a, input, msg);
        if (eq(u8, tool, "doc_resolve_comment")) return resolveTool(store, a, input, msg);
    }
    return error.UnknownTool;
}

fn parse(comptime T: type, a: Allocator, input: []const u8, msg: *[]const u8) !T {
    return std.json.parseFromSliceLeaky(T, a, input, .{ .ignore_unknown_fields = false, .allocate = .alloc_always }) catch |e| {
        msg.* = try std.fmt.allocPrint(a, "invalid input: {t}", .{e});
        return error.BadInput;
    };
}

fn outlineTool(src: *Source, a: Allocator) ![]const u8 {
    const snap = try src.session.snapshot(a);
    const Row = struct { id: []const u8, slug: []const u8, title: []const u8, level: u8, words: u32 };
    const rows = try a.alloc(Row, snap.outline.len);
    for (snap.outline, rows) |s, *r| r.* = .{ .id = s.id, .slug = s.slug, .title = s.title, .level = s.level, .words = s.words };
    return std.json.Stringify.valueAlloc(a, rows, .{});
}

fn tokens(src: *const Source, text: []const u8) u32 {
    const e: zg_ai.models.estimate.TokenEstimator = .{};
    return (src.estimator orelse &e).estimate(src.family, text);
}

fn readTool(src: *Source, a: Allocator, input: []const u8, msg: *[]const u8) ![]const u8 {
    const In = struct { section: []const u8, include_children: bool = true };
    const in = try parse(In, a, input, msg);
    const snap = try src.session.snapshot(a);
    const sec = snap.find(in.section) orelse {
        msg.* = try std.fmt.allocPrint(a, "no section {s}; doc_outline lists them", .{in.section});
        return error.BadInput;
    };
    const Child = struct { id: []const u8, title: []const u8, words: u32 };
    const Out = struct { id: []const u8, title: []const u8, text: []const u8, truncated: bool = false, subsections: ?[]const Child = null };
    const whole = snap.text[sec.range.start..sec.range.end];
    if (!in.include_children or tokens(src, whole) > src.max_section_tokens) {
        var own = snap.text[sec.range.start..sec.ownEnd(snap.outline)];
        const big = tokens(src, whole) > src.max_section_tokens;
        var cut = false;
        if (tokens(src, own) > src.max_section_tokens) {
            // Cut at a line end within the budget (4 bytes a token).
            const limit = @min(own.len, @as(usize, src.max_section_tokens) * 3);
            const nl = std.mem.lastIndexOfScalar(u8, own[0..limit], '\n') orelse limit;
            own = own[0..nl];
            cut = true;
        }
        const kids = try a.alloc(Child, sec.children.len);
        for (sec.children, kids) |ci, *k| k.* = .{ .id = snap.outline[ci].id, .title = snap.outline[ci].title, .words = snap.outline[ci].words };
        return std.json.Stringify.valueAlloc(a, Out{ .id = sec.id, .title = sec.title, .text = own, .truncated = big or cut, .subsections = kids }, .{ .emit_null_optional_fields = false });
    }
    return std.json.Stringify.valueAlloc(a, Out{ .id = sec.id, .title = sec.title, .text = whole }, .{ .emit_null_optional_fields = false });
}

fn searchTool(src: *Source, a: Allocator, input: []const u8, msg: *[]const u8) ![]const u8 {
    const In = struct { text: []const u8 };
    const in = try parse(In, a, input, msg);
    if (in.text.len == 0) {
        msg.* = "text is empty";
        return error.BadInput;
    }
    const snap = try src.session.snapshot(a);
    const Hit = struct { section: ?[]const u8, title: ?[]const u8, line: u32, text: []const u8 };
    var hits: std.ArrayList(Hit) = .empty;
    var line_no: u32 = 1;
    var pos: usize = 0;
    while (pos <= snap.text.len and hits.items.len < src.max_hits) : (line_no += 1) {
        const nl = std.mem.indexOfScalarPos(u8, snap.text, pos, '\n');
        const line = snap.text[pos .. nl orelse snap.text.len];
        if (std.ascii.indexOfIgnoreCase(line, in.text) != null) {
            const si = sections_mod.sectionAt(snap.outline, @intCast(pos));
            try hits.append(a, .{
                .section = if (si) |i| snap.outline[i].id else null,
                .title = if (si) |i| snap.outline[i].title else null,
                .line = line_no,
                .text = std.mem.trim(u8, line[0..@min(line.len, 240)], " \t\r"),
            });
        }
        pos = (nl orelse break) + 1;
    }
    return std.json.Stringify.valueAlloc(a, hits.items, .{});
}

fn proposeTool(src: *Source, a: Allocator, input: []const u8, msg: *[]const u8, cs: *?u64) ![]const u8 {
    const In = struct { section: ?[]const u8 = null, old_text: []const u8, new_text: []const u8, rationale: ?[]const u8 = null };
    const in = try parse(In, a, input, msg);
    var prov = src.prov;
    prov.tool = "doc_propose_edit";
    const r = try src.session.propose(a, .{
        .scope = if (in.section) |s| .{ .section = s } else .document,
        .old_text = in.old_text,
        .new_text = in.new_text,
        .rationale = in.rationale,
    }, prov);
    return result(a, r, msg, cs);
}

fn insertTool(src: *Source, a: Allocator, input: []const u8, msg: *[]const u8, cs: *?u64) ![]const u8 {
    const In = struct { after_section: ?[]const u8 = null, at_anchor: ?u32 = null, text: []const u8, rationale: ?[]const u8 = null };
    const in = try parse(In, a, input, msg);
    var prov = src.prov;
    prov.tool = "doc_insert";
    const where: doc.InsertAt = if (in.after_section) |s| .{ .after_section = s } else if (in.at_anchor) |x| .{ .at_anchor = x } else .end;
    return result(a, try src.session.insert(a, where, in.text, in.rationale, prov), msg, cs);
}

fn result(a: Allocator, r: doc.ProposeResult, msg: *[]const u8, cs: *?u64) ![]const u8 {
    switch (r) {
        .ok => |id| {
            cs.* = id;
            return std.fmt.allocPrint(a, "Proposed as changeset {d}; the person will review it.", .{id});
        },
        .stale => |current| {
            msg.* = try std.fmt.allocPrint(a, "old_text is no longer there (the person may have edited it). The current text of the scope is:\n\n{s}", .{current});
            return error.BadInput;
        },
        .not_found => |m| {
            msg.* = m;
            return error.BadInput;
        },
    }
}

fn agentAuthor(src: *const Source) comments_mod.Author {
    return .{ .agent = src.prov.run orelse .zero };
}

fn addCommentTool(src: *Source, store: *comments_mod.CommentStore, a: Allocator, input: []const u8, msg: *[]const u8) ![]const u8 {
    const In = struct { anchor_text: []const u8, text: []const u8 };
    const in = try parse(In, a, input, msg);
    if (in.anchor_text.len == 0 or in.text.len == 0) {
        msg.* = "anchor_text and text must not be empty";
        return error.BadInput;
    }
    const snap = try src.session.snapshot(a);
    const range: [2]u32 = if (std.mem.indexOf(u8, snap.text, in.anchor_text)) |at|
        .{ @intCast(at), @intCast(at + in.anchor_text.len) }
    else blk: {
        var count: u32 = 0;
        break :blk (try words.findLoose(a, snap.text, in.anchor_text, &count)) orelse {
            msg.* = "anchor_text is not in the document; quote it exactly";
            return error.BadInput;
        };
    };
    const id = try store.add(snap.text, .{ .start = range[0], .end = range[1] }, in.text, agentAuthor(src));
    return std.fmt.allocPrint(a, "Comment added as thread {d}.", .{id});
}

fn replyTool(src: *Source, store: *comments_mod.CommentStore, a: Allocator, input: []const u8, msg: *[]const u8) ![]const u8 {
    const In = struct { thread: u32, text: []const u8, proposal: ?u64 = null };
    const in = try parse(In, a, input, msg);
    _ = store.replyWith(in.thread, in.text, agentAuthor(src), in.proposal) catch |e| switch (e) {
        error.NoSuchThread => {
            msg.* = try std.fmt.allocPrint(a, "no thread {d}; see doc_list_comments", .{in.thread});
            return error.BadInput;
        },
        else => return e,
    };
    return std.fmt.allocPrint(a, "Replied in thread {d}.", .{in.thread});
}

fn listCommentsTool(store: *comments_mod.CommentStore, a: Allocator, input: []const u8, msg: *[]const u8) ![]const u8 {
    const In = struct { include_resolved: bool = false };
    const in = try parse(In, a, input, msg);
    const C = struct { author: []const u8, text: []const u8, proposal: ?u64 = null };
    const T = struct { thread: u32, quote: []const u8, orphaned: bool, resolved: bool, comments: []const C };
    var out: std.ArrayList(T) = .empty;
    for (store.threads()) |t| {
        if (t.resolved and !in.include_resolved) continue;
        const cs = try a.alloc(C, t.comments.items.len);
        for (t.comments.items, cs) |c, *o| o.* = .{ .author = switch (c.author) {
            .user => |u| if (u.len > 0) u else "user",
            .agent => "agent",
        }, .text = c.text, .proposal = c.proposal };
        try out.append(a, .{ .thread = t.id, .quote = t.quote, .orphaned = t.anchor == null, .resolved = t.resolved, .comments = cs });
    }
    return std.json.Stringify.valueAlloc(a, out.items, .{ .emit_null_optional_fields = false });
}

fn resolveTool(store: *comments_mod.CommentStore, a: Allocator, input: []const u8, msg: *[]const u8) ![]const u8 {
    const In = struct { thread: u32 };
    const in = try parse(In, a, input, msg);
    store.resolve(in.thread) catch |e| switch (e) {
        error.NoSuchThread => {
            msg.* = try std.fmt.allocPrint(a, "no thread {d}", .{in.thread});
            return error.BadInput;
        },
        else => return e,
    };
    return std.fmt.allocPrint(a, "Thread {d} resolved.", .{in.thread});
}
