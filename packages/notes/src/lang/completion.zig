//! Note completion (E08.F06.S02.T02): `[[` notes (title, alias and path,
//! with recents and link-neighbour boosts), `![[` embeds (images first),
//! headings and blocks of a target, `#` tags and frontmatter property
//! names and values. Headless: the editor's completion UI shows `Item`s
//! and applies `edit` (plus `extra`, a block id added to the target
//! note, through E05.F08 when it is open or an auto-applied E12 edit).

const std = @import("std");
const context = @import("context.zig");
const note_index = @import("../index/note_index.zig");
const names_mod = @import("../index/names.zig");
const fuzzy = @import("../index/fuzzy.zig");
const tag_tree = @import("../index/tag_tree.zig");
const mentions = @import("../index/mentions.zig");
const link_text = @import("../refactor/link_text.zig");
const vault_mod = @import("../vault/vault.zig");
const frontmatter = @import("../vault/frontmatter.zig");
const note_mod = @import("../vault/note.zig");
const extract_mod = @import("../vault/extract.zig");

const Allocator = std.mem.Allocator;
const FileId = note_mod.FileId;
const IndexView = note_index.IndexView;

pub const Kind = enum { note, alias, attachment, heading, block, tag, property, value };

pub const TextEdit = struct { range: [2]u32, text: []const u8 };

/// An edit to another note made when the item is accepted.
pub const NoteEdit = struct { path: []const u8, at: u32, text: []const u8 };

pub const Item = struct {
    label: []const u8,
    kind: Kind,
    /// The folder, a count, or the property type.
    detail: []const u8 = "",
    /// The start of the note (notes only, when `content` is given).
    documentation: []const u8 = "",
    edit: TextEdit,
    extra: ?NoteEdit = null,
    score: i32 = 0,
};

pub const Request = struct {
    /// The document's current bytes and the cursor in them.
    text: []const u8,
    cursor: u32,
    /// The document's vault-relative path.
    path: []const u8,
    vault: *const vault_mod.Vault,
    /// Recently opened notes, most recent first.
    recents: []const FileId = &.{},
    /// Note bytes for documentation and block lists.
    content: ?mentions.ContentSource = null,
    /// New block ids (`io.random` in the app).
    random: ?std.Random = null,
    limit: u32 = 50,
};

/// The completion items at the cursor, best first (in `a`, an arena).
pub fn complete(a: Allocator, view: *const IndexView, req: Request) ![]Item {
    var out: std.ArrayList(Item) = .empty;
    switch (context.detect(req.text, req.cursor)) {
        .none => {},
        .note => |t| try notes(a, view, req, t.query, t.start, t.embed, t.closed, &out),
        .heading => |t| try headings(a, view, req, t.target, t.query, t.start, t.closed, &out),
        .block => |t| try blocks(a, view, req, t.target, t.query, t.start, t.closed, &out),
        .tag => |t| try tags(a, view, req, t.query, t.start, &out),
        .prop_key => |t| try propKeys(a, view, req, t.query, t.start, &out),
        .prop_value => |t| try propValues(a, view, req, t.key, t.query, t.start, &out),
    }
    std.mem.sort(Item, out.items, {}, struct {
        fn lt(_: void, x: Item, y: Item) bool {
            if (x.score != y.score) return x.score > y.score;
            return std.mem.lessThan(u8, x.label, y.label);
        }
    }.lt);
    if (out.items.len > req.limit) out.items.len = req.limit;
    // Documentation for the visible notes only.
    if (req.content) |src| for (out.items) |*it| if (it.kind == .note or it.kind == .alias) {
        it.documentation = try snippetOf(a, view, req, src, it.detail);
    };
    return out.items;
}

fn closing(closed: bool) []const u8 {
    return if (closed) "" else "]]";
}

fn selfId(a: Allocator, view: *const IndexView, req: Request) !?FileId {
    return view.idOfPath(a, req.vault.id, req.path);
}

fn notes(a: Allocator, view: *const IndexView, req: Request, q: []const u8, start: u32, embed: bool, closed: bool, out: *std.ArrayList(Item)) !void {
    const me = try selfId(a, view, req);
    // Notes one or two links away from this one.
    var near: std.AutoHashMapUnmanaged(u64, void) = .empty;
    if (me) |id| {
        var hop1: std.ArrayList(FileId) = .empty;
        for (view.outgoing(id)) |r| if (r.kind == .note) try hop1.append(a, r.id);
        for (view.backlinks(id)) |b| try hop1.append(a, b.source);
        for (hop1.items) |h| {
            try near.put(a, names_mod.idKey(h), {});
            for (view.outgoing(h)) |r| if (r.kind == .note) try near.put(a, names_mod.idKey(r.id), {});
        }
    }
    var names = view.names;
    var keys: names_mod.KeyBuf = .{};
    const hits = try view.findByName(a, q, if (q.len == 0) @intCast(view.order.len) else 500);
    for (hits) |h| {
        if (me) |id| if (id.eql(h.id)) continue;
        const e = view.entry(h.id) orelse continue;
        if (e.vault != req.vault.id) continue;
        var s = h.score;
        for (req.recents, 0..) |r, i| if (r.eql(h.id)) {
            s += 40 - @as(i32, @intCast(@min(i, 30)));
            break;
        };
        if (near.contains(names_mod.idKey(h.id))) s += 15;
        const target = try link_text.shortestLinkText(a, &names, &keys, req.vault.id, req.path, h.id, e.path, false);
        if (h.matched == .alias) {
            const alias = for (e.meta.aliases) |al| {
                if (fuzzy.score(q, al)) |_| break al;
            } else e.meta.title;
            try out.append(a, .{
                .label = alias,
                .kind = .alias,
                .detail = e.path,
                .edit = .{ .range = .{ start, req.cursor }, .text = try std.mem.concat(a, u8, &.{ target, "|", alias, closing(closed) }) },
                .score = s,
            });
        } else try out.append(a, .{
            .label = e.meta.title,
            .kind = .note,
            .detail = e.path,
            .edit = .{ .range = .{ start, req.cursor }, .text = try std.mem.concat(a, u8, &.{ target, closing(closed) }) },
            .score = s,
        });
    }
    if (!embed) return;
    // Attachments, images first.
    var it = view.names.places.iterator();
    while (it.next()) |kv| {
        const p = kv.value_ptr.*;
        if (!p.attachment or p.vault != req.vault.id) continue;
        const s = fuzzy.score(q, p.path) orelse continue;
        const id: FileId = @bitCast(kv.key_ptr.*);
        const target = try link_text.shortestLinkText(a, &names, &keys, req.vault.id, req.path, id, p.path, true);
        try out.append(a, .{
            .label = names_mod.basename(p.path),
            .kind = .attachment,
            .detail = p.path,
            .edit = .{ .range = .{ start, req.cursor }, .text = try std.mem.concat(a, u8, &.{ target, closing(closed) }) },
            .score = s + @as(i32, if (isImage(p.path)) 30 else 0),
        });
    }
}

pub fn isImage(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    for ([_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".svg", ".webp", ".avif" }) |x| if (std.ascii.eqlIgnoreCase(ext, x)) return true;
    return false;
}

/// The target note of `[[target#...`: this note when empty.
fn targetOf(a: Allocator, view: *const IndexView, req: Request, target: []const u8) !?FileId {
    if (target.len == 0) return selfId(a, view, req);
    const r = try view.resolveFrom(a, req.vault.id, req.path, target, .wiki);
    return if (r.kind == .note or r.kind == .self) r.id else null;
}

fn headings(a: Allocator, view: *const IndexView, req: Request, target: []const u8, q: []const u8, start: u32, closed: bool, out: *std.ArrayList(Item)) !void {
    const id = (try targetOf(a, view, req, target)) orelse return;
    const meta = view.note(id) orelse return;
    for (meta.headings, 0..) |h, i| {
        const s = fuzzy.score(q, h.text) orelse continue;
        try out.append(a, .{
            .label = h.text,
            .kind = .heading,
            .detail = try std.fmt.allocPrint(a, "H{d}", .{h.level}),
            .edit = .{ .range = .{ start, req.cursor }, .text = try std.mem.concat(a, u8, &.{ h.text, closing(closed) }) },
            // Document order when the scores tie.
            .score = s * 1000 - @as(i32, @intCast(@min(i, 999))),
        });
    }
}

/// A paragraph or list item of a note.
pub const Block = struct { range: [2]u32, id: ?[]const u8 };

/// The paragraphs and list items of `text` outside frontmatter and code
/// fences, with their `^id`s from `meta`.
pub fn listBlocks(a: Allocator, text: []const u8, meta: *const note_mod.NoteMeta) ![]Block {
    var out: std.ArrayList(Block) = .empty;
    var i: usize = if (meta.fm_range) |r| r[1] else 0;
    var para: ?[2]u32 = null;
    var fence = false;
    while (i < text.len) {
        const eol = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        const line = std.mem.trimEnd(u8, text[i..eol], "\r");
        const t = std.mem.trimStart(u8, line, " \t");
        const end: u32 = @intCast(i + line.len);
        if (std.mem.startsWith(u8, t, "```") or std.mem.startsWith(u8, t, "~~~")) {
            fence = !fence;
            if (para) |p| try out.append(a, .{ .range = p, .id = null });
            para = null;
        } else if (fence) {} else if (t.len == 0 or t[0] == '#') {
            if (para) |p| try out.append(a, .{ .range = p, .id = null });
            para = null;
        } else if (isListItem(t)) {
            if (para) |p| try out.append(a, .{ .range = p, .id = null });
            para = null;
            try out.append(a, .{ .range = .{ @intCast(i), end }, .id = null });
        } else if (para) |*p| p[1] = end else para = .{ @intCast(i), end };
        i = eol + 1;
    }
    if (para) |p| try out.append(a, .{ .range = p, .id = null });
    for (out.items) |*b| for (meta.blocks) |m| if (m.marker[0] >= b.range[0] and m.marker[1] <= b.range[1]) {
        b.id = m.id;
    };
    return out.items;
}

fn isListItem(t: []const u8) bool {
    if (t.len >= 2 and (t[0] == '-' or t[0] == '*' or t[0] == '+') and t[1] == ' ') return true;
    var d: usize = 0;
    while (d < t.len and std.ascii.isDigit(t[d])) d += 1;
    return d > 0 and d + 1 < t.len and (t[d] == '.' or t[d] == ')') and t[d + 1] == ' ';
}

fn blocks(a: Allocator, view: *const IndexView, req: Request, target: []const u8, q: []const u8, start: u32, closed: bool, out: *std.ArrayList(Item)) !void {
    const id = (try targetOf(a, view, req, target)) orelse return;
    const e = view.entry(id) orelse return;
    const is_self = std.mem.eql(u8, e.path, req.path);
    const text = if (is_self) req.text else blk: {
        const src = req.content orelse return;
        break :blk (try src.read(src.ctx, a, id, e.path)) orelse return;
    };
    var self_meta: note_mod.NoteMeta = undefined;
    const meta: *const note_mod.NoteMeta = if (is_self) blk: {
        self_meta = try extract_mod.extract(a, text, req.path, &req.vault.config);
        break :blk &self_meta;
    } else &e.meta;
    for (try listBlocks(a, text, meta), 0..) |b, i| {
        const body = std.mem.trim(u8, text[b.range[0]..b.range[1]], " \t-*+");
        const label = body[0..prefixLen(body, 60)];
        const s = (fuzzy.score(q, body) orelse if (b.id) |bid| fuzzy.score(q, bid) else null) orelse continue;
        var item: Item = .{
            .label = label,
            .kind = .block,
            .edit = undefined,
            .score = s * 1000 - @as(i32, @intCast(@min(i, 999))),
        };
        if (b.id) |bid| {
            item.detail = try std.fmt.allocPrint(a, "^{s}", .{bid});
            item.edit = .{ .range = .{ start, req.cursor }, .text = try std.mem.concat(a, u8, &.{ bid, closing(closed) }) };
        } else {
            const new_id = try newBlockId(a, meta, req.random);
            item.detail = "new id";
            item.edit = .{ .range = .{ start, req.cursor }, .text = try std.mem.concat(a, u8, &.{ new_id, closing(closed) }) };
            item.extra = .{ .path = e.path, .at = b.range[1], .text = try std.fmt.allocPrint(a, " ^{s}", .{new_id}) };
        }
        try out.append(a, item);
    }
}

/// Bytes of `s` up to `n`, not splitting a UTF-8 sequence.
fn prefixLen(s: []const u8, n: usize) usize {
    if (s.len <= n) return s.len;
    var k = n;
    while (k > 0 and (s[k] & 0xC0) == 0x80) k -= 1;
    return k;
}

/// A 6-character base36 id not used in `meta`.
pub fn newBlockId(a: Allocator, meta: *const note_mod.NoteMeta, random: ?std.Random) ![]const u8 {
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    var fallback: std.Random.DefaultPrng = .init(meta.blocks.len *% 0x9e3779b97f4a7c15 +% meta.word_count);
    const r = random orelse fallback.random();
    while (true) {
        const id = try a.alloc(u8, 6);
        for (id) |*c| c.* = digits[r.uintLessThan(usize, digits.len)];
        const used = for (meta.blocks) |b| {
            if (std.mem.eql(u8, b.id, id)) break true;
        } else false;
        if (!used) return id;
    }
}

fn tags(a: Allocator, view: *const IndexView, req: Request, q: []const u8, start: u32, out: *std.ArrayList(Item)) !void {
    var stack: std.ArrayList(*const tag_tree.TagNode) = .empty;
    try stack.append(a, view.tagTree());
    while (stack.pop()) |n| {
        for (n.children) |c| try stack.append(a, c);
        if (n.full.len == 0 or n.count == 0) continue;
        const s = fuzzy.score(q, n.full) orelse continue;
        try out.append(a, .{
            .label = n.full,
            .kind = .tag,
            .detail = try std.fmt.allocPrint(a, "{d}", .{n.count}),
            .edit = .{ .range = .{ start, req.cursor }, .text = n.full },
            .score = s * 4 + @as(i32, @intCast(std.math.log2_int(u32, n.count + 1))),
        });
    }
}

fn propKeys(a: Allocator, view: *const IndexView, req: Request, q: []const u8, start: u32, out: *std.ArrayList(Item)) !void {
    for (view.properties()) |p| {
        const s = fuzzy.score(q, p.name) orelse continue;
        try out.append(a, .{
            .label = p.name,
            .kind = .property,
            .detail = @tagName(p.ty),
            .edit = .{ .range = .{ start, req.cursor }, .text = try std.fmt.allocPrint(a, "{s}: ", .{p.name}) },
            .score = s * 4 + @as(i32, @intCast(std.math.log2_int(u32, p.count + 1))),
        });
    }
}

fn propValues(a: Allocator, view: *const IndexView, req: Request, key: []const u8, q: []const u8, start: u32, out: *std.ArrayList(Item)) !void {
    if (std.ascii.eqlIgnoreCase(key, "tags") or std.ascii.eqlIgnoreCase(key, "tag")) return tags(a, view, req, q, start, out);
    var freq: std.StringArrayHashMapUnmanaged(u32) = .empty;
    for (view.order) |id| {
        const e = view.entry(id) orelse continue;
        if (e.vault != req.vault.id) continue;
        const p = e.meta.prop(key) orelse continue;
        switch (p.node.value) {
            .list => |l| for (l) |n| try bump(a, &freq, n.value),
            else => try bump(a, &freq, p.node.value),
        }
    }
    const Pair = struct { v: []const u8, n: u32 };
    var pairs: std.ArrayList(Pair) = .empty;
    var it = freq.iterator();
    while (it.next()) |kv| try pairs.append(a, .{ .v = kv.key_ptr.*, .n = kv.value_ptr.* });
    std.mem.sort(Pair, pairs.items, {}, struct {
        fn lt(_: void, x: Pair, y: Pair) bool {
            return x.n > y.n or (x.n == y.n and std.mem.lessThan(u8, x.v, y.v));
        }
    }.lt);
    for (pairs.items[0..@min(pairs.items.len, 50)], 0..) |p, i| {
        const s = fuzzy.score(q, p.v) orelse continue;
        try out.append(a, .{
            .label = p.v,
            .kind = .value,
            .detail = try std.fmt.allocPrint(a, "{d}", .{p.n}),
            .edit = .{ .range = .{ start, req.cursor }, .text = p.v },
            .score = s * 1000 - @as(i32, @intCast(i)),
        });
    }
}

fn bump(a: Allocator, freq: *std.StringArrayHashMapUnmanaged(u32), v: frontmatter.Value) !void {
    const s = switch (v) {
        .string => |s| s,
        else => return,
    };
    if (s.len == 0) return;
    const g = try freq.getOrPut(a, s);
    if (!g.found_existing) g.value_ptr.* = 0;
    g.value_ptr.* += 1;
}

/// The first 80 bytes of a note's body (after frontmatter and its title
/// heading), on one line.
fn snippetOf(a: Allocator, view: *const IndexView, req: Request, src: mentions.ContentSource, path: []const u8) ![]const u8 {
    const id = (try view.idOfPath(a, req.vault.id, path)) orelse return "";
    const meta = view.note(id) orelse return "";
    const text = (try src.read(src.ctx, a, id, path)) orelse return "";
    var body: []const u8 = text[if (meta.fm_range) |r| @min(r[1], text.len) else 0..];
    body = std.mem.trimStart(u8, body, " \r\n");
    if (std.mem.startsWith(u8, body, "# ")) body = std.mem.trimStart(u8, body[(std.mem.indexOfScalar(u8, body, '\n') orelse body.len)..], " \r\n");
    const cut = std.mem.trimEnd(u8, body[0..prefixLen(body, 80)], " \r\n");
    const flat = try a.dupe(u8, cut);
    for (flat) |*c| if (c.* == '\n' or c.* == '\r') {
        c.* = ' ';
    };
    return flat;
}
