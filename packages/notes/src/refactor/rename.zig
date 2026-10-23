//! Link rewriting for renames and moves (E08.F06.S02.T01). Given path
//! moves (files or folders, vault-relative), `planMoves` finds every link
//! that would stop naming its note: backlinks of moved notes and
//! attachments, links from moved notes (their relative paths change), and
//! links to notes sharing a moved note's stem (the move can make a bare
//! name ambiguous). Each is re-resolved against the post-move names; the
//! ones that no longer reach their note get new target text in their
//! original form (bare/path, `.md`, Markdown relative, `<...>` or `%XX`).
//! Edits replace only the target text, so aliases, subpaths and embeds
//! stay as written.
//!
//! `submit` turns a plan into one E12 changeset through `ChangesetPort`
//! (the app wires it to `zg_review.Submitter`), tagged with the FileOps
//! transaction so review shows and undoes them together.

const std = @import("std");
const note_index = @import("../index/note_index.zig");
const names_mod = @import("../index/names.zig");
const note = @import("../vault/note.zig");
const vault_mod = @import("../vault/vault.zig");
const link_text = @import("link_text.zig");

const Allocator = std.mem.Allocator;
const IndexView = note_index.IndexView;
const FileId = note.FileId;
const Names = names_mod.Names;

pub const Move = struct {
    /// Vault-relative; a folder moves everything under it.
    from: []const u8,
    to: []const u8,
};

pub const LinkEdit = struct {
    note: FileId,
    /// Byte range in the note (the link's target text).
    range: [2]u32,
    new_text: []const u8,
};

/// A plan's edits, sorted by note then offset, non-overlapping.
pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    edits: []const LinkEdit,
    /// The expanded file moves (folders expanded).
    moved: []const Moved,

    pub fn deinit(p: *Plan) void {
        p.arena.deinit();
    }

    /// Distinct notes the plan edits.
    pub fn noteCount(p: *const Plan) usize {
        var n: usize = 0;
        for (p.edits, 0..) |e, i| {
            if (i == 0 or !p.edits[i - 1].note.eql(e.note)) n += 1;
        }
        return n;
    }
};

pub const Moved = struct { id: FileId, from: []const u8, to: []const u8, attachment: bool };

/// Plans the link edits for `moves` within `vault`.
pub fn planMoves(gpa: Allocator, view: *const IndexView, vault: *const vault_mod.Vault, moves: []const Move) !Plan {
    var plan: Plan = .{ .arena = .init(gpa), .edits = &.{}, .moved = &.{} };
    errdefer plan.arena.deinit();
    const a = plan.arena.allocator();
    const vid = vault.id;

    // Expand moves to files.
    var moved: std.ArrayList(Moved) = .empty;
    var new_path: std.AutoHashMapUnmanaged(u64, []const u8) = .empty;
    var pit = view.names.places.iterator();
    while (pit.next()) |kv| {
        const place = kv.value_ptr.*;
        if (place.vault != vid) continue;
        for (moves) |m| {
            const to = movedPath(a, place.path, m) catch continue orelse continue;
            const id: FileId = @bitCast(kv.key_ptr.*);
            try moved.append(a, .{ .id = id, .from = place.path, .to = to, .attachment = place.attachment });
            try new_path.put(a, kv.key_ptr.*, to);
            break;
        }
    }
    std.mem.sort(Moved, moved.items, {}, struct {
        fn lt(_: void, x: Moved, y: Moved) bool {
            return @as(u64, @bitCast(x.id)) < @as(u64, @bitCast(y.id));
        }
    }.lt);
    plan.moved = moved.items;
    if (moved.items.len == 0) return plan;

    // The names after the moves.
    var post = try view.names.clone(a);
    var keys: names_mod.KeyBuf = .{};
    for (moved.items) |m| {
        if (m.attachment) {
            try post.removeAttachment(a, &keys, m.id);
            try post.addAttachment(a, &keys, m.id, vid, m.to);
        } else {
            const aliases = if (view.note(m.id)) |meta| meta.aliases else &.{};
            try post.removeNote(a, &keys, m.id, aliases);
            try post.addNote(a, &keys, m.id, vid, m.to, aliases);
        }
    }

    // Candidate links: (source, link index).
    var cands: std.AutoArrayHashMapUnmanaged(u64, void) = .empty;
    const Cand = struct {
        fn key(src: FileId, i: u32) u64 {
            return (@as(u64, src.index) << 32) | i;
        }
    };
    for (moved.items) |m| {
        for (view.backlinks(m.id)) |b| try cands.put(a, Cand.key(b.source, b.link_index), {});
        if (!m.attachment) if (view.note(m.id)) |meta| for (meta.links, 0..) |_, i| {
            try cands.put(a, Cand.key(m.id, @intCast(i)), {});
        };
        // Notes sharing the new stem may lose their bare links.
        const stem_key = try keys.view(a, vid, if (m.attachment) names_mod.basename(m.to) else names_mod.stemOf(m.to));
        const same = if (m.attachment) post.att_names.get(stem_key) else post.stems.get(stem_key);
        if (same) |l| for (l.items) |other| {
            if (other.eql(m.id)) continue;
            for (view.backlinks(other)) |b| try cands.put(a, Cand.key(b.source, b.link_index), {});
        };
    }

    // Source ids by index (the key holds only the index).
    var by_index: std.AutoHashMapUnmanaged(u32, FileId) = .empty;
    for (view.order) |id| try by_index.put(a, id.index, id);

    var edits: std.ArrayList(LinkEdit) = .empty;
    for (cands.keys()) |k| {
        const src = by_index.get(@intCast(k >> 32)) orelse continue;
        const li: u32 = @truncate(k);
        const meta = view.note(src) orelse continue;
        const e = view.entry(src).?;
        if (e.vault != vid) continue;
        const out = view.outgoing(src);
        if (li >= out.len) continue;
        const was = out[li];
        if (was.kind != .note and was.kind != .attachment) continue;
        const l = &meta.links[li];
        const src_path = new_path.get(@bitCast(src)) orelse e.path;
        const target_path = new_path.get(@bitCast(was.id)) orelse (post.placeOf(was.id) orelse continue).path;
        const form: link_text.Form = .of(l);
        const target_moved = new_path.contains(@bitCast(was.id));
        const old_target_path = view.pathOf(was.id) orelse continue;
        const text = try link_text.rewrite(a, &post, &keys, vid, form, src_path, was.id, target_path, was.kind == .attachment);
        if (l.kind == .markdown or l.kind == .markdown_embed) {
            // Markdown destinations are file paths: keep them exact.
            const plain = try link_text.rewritePlain(a, form, src_path, target_path, was.kind == .attachment);
            if (std.mem.eql(u8, plain, trimDot(l.target))) continue;
        } else {
            // A full vault path stays a full path; anything else is kept
            // while it still resolves to its note.
            const t = if (l.target.len > 0 and l.target[0] == '/') l.target[1..] else l.target;
            const full = form.path_form and target_moved and std.ascii.eqlIgnoreCase(names_mod.withoutMd(t), if (was.kind == .attachment) old_target_path else names_mod.withoutMd(old_target_path));
            if (!full) {
                const now = try post.resolve(a, &keys, vid, src_path, l.target, l.kind, vault.config.alias_resolution, null);
                if (now.id.eql(was.id) and now.kind == was.kind and (!now.ambiguous or was.ambiguous)) continue;
            }
        }
        try edits.append(a, .{ .note = src, .range = l.target_src, .new_text = text });
    }
    std.mem.sort(LinkEdit, edits.items, {}, struct {
        fn lt(_: void, x: LinkEdit, y: LinkEdit) bool {
            const xi: u64 = @bitCast(x.note);
            const yi: u64 = @bitCast(y.note);
            if (xi != yi) return xi < yi;
            return x.range[0] < y.range[0];
        }
    }.lt);
    plan.edits = edits.items;
    return plan;
}

fn trimDot(p: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, p, "./")) p[2..] else p;
}

/// Where `path` lands under `m`, or null when `m` does not move it.
fn movedPath(a: Allocator, path: []const u8, m: Move) !?[]const u8 {
    const from = std.mem.trimEnd(u8, m.from, "/");
    const to = std.mem.trimEnd(u8, m.to, "/");
    if (std.mem.eql(u8, path, from)) return try a.dupe(u8, to);
    if (path.len > from.len and std.mem.startsWith(u8, path, from) and path[from.len] == '/') {
        if (to.len == 0) return try a.dupe(u8, path[from.len + 1 ..]);
        return try std.fmt.allocPrint(a, "{s}{s}", .{ to, path[from.len..] });
    }
    return null;
}

/// Applies `edits` (sorted, for one note) to `bytes`.
pub fn applyEdits(gpa: Allocator, bytes: []const u8, edits: []const LinkEdit) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var pos: usize = 0;
    for (edits) |e| {
        try out.appendSlice(gpa, bytes[pos..e.range[0]]);
        try out.appendSlice(gpa, e.new_text);
        pos = e.range[1];
    }
    try out.appendSlice(gpa, bytes[pos..]);
    return out.toOwnedSlice(gpa);
}

// ---- changesets ----

/// One note's edits for a changeset.
pub const PlanFile = struct {
    note: FileId,
    /// Vault-relative path (after the moves).
    path: []const u8,
    edits: []const LinkEdit,
};

/// Submits edits as an E12 changeset; returns its id. `tx` is the FileOps
/// transaction (`Origin.notes.tx`); `auto_apply` applies it at once
/// with an undo group (user actors with the setting on), else it stays
/// pending review.
pub const ChangesetPort = struct {
    ctx: *anyopaque,
    submit: *const fn (ctx: *anyopaque, label: []const u8, tx: u64, files: []const PlanFile, auto_apply: bool) anyerror!u64,
};

/// Groups `plan` by note and submits it labelled "Update N links after
/// renaming X". Returns null when there is nothing to change.
pub fn submit(gpa: Allocator, port: ChangesetPort, view: *const IndexView, plan: *const Plan, what: []const u8, tx: u64, auto_apply: bool) !?u64 {
    if (plan.edits.len == 0) return null;
    var files: std.ArrayList(PlanFile) = .empty;
    defer files.deinit(gpa);
    var i: usize = 0;
    while (i < plan.edits.len) {
        var j = i + 1;
        while (j < plan.edits.len and plan.edits[j].note.eql(plan.edits[i].note)) j += 1;
        const id = plan.edits[i].note;
        const path = for (plan.moved) |m| {
            if (m.id.eql(id)) break m.to;
        } else view.pathOf(id) orelse "";
        try files.append(gpa, .{ .note = id, .path = path, .edits = plan.edits[i..j] });
        i = j;
    }
    const label = try std.fmt.allocPrint(gpa, "Update {d} link{s} after renaming {s}", .{ plan.edits.len, if (plan.edits.len == 1) "" else "s", what });
    defer gpa.free(label);
    return try port.submit(port.ctx, label, tx, files.items, auto_apply);
}
