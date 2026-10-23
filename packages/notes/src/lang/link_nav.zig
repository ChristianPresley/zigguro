//! Link navigation (E08.F06.S02.T02): the link under the cursor, where
//! Ctrl+click / F12 goes (the target note, scrolled to its heading or
//! block), and where an unresolved link's note is created.

const std = @import("std");
const note_index = @import("../index/note_index.zig");
const names_mod = @import("../index/names.zig");
const extract_mod = @import("../vault/extract.zig");
const vault_mod = @import("../vault/vault.zig");
const note_mod = @import("../vault/note.zig");

const Allocator = std.mem.Allocator;
const FileId = note_mod.FileId;
const IndexView = note_index.IndexView;

pub const Target = union(enum) {
    /// `range` is the heading line or the block in the target's bytes
    /// (null for the whole note or an unknown subpath).
    open: struct { id: FileId, path: []const u8, range: ?[2]u32, attachment: bool },
    /// No such note: create it at `path` (vault-relative), then open it.
    create: struct { path: []const u8 },
};

/// The link whose bytes contain `cursor`.
pub fn linkAt(meta: *const note_mod.NoteMeta, cursor: u32) ?*const note_mod.Link {
    for (meta.links) |*l| if (cursor >= l.src[0] and cursor <= l.src[1]) return l;
    return null;
}

/// Where the link at `cursor` in `text` (the note at `from_path`) leads.
pub fn definition(a: Allocator, view: *const IndexView, vault: *const vault_mod.Vault, from_path: []const u8, text: []const u8, cursor: u32) !?Target {
    const meta = try extract_mod.extract(a, text, from_path, &vault.config);
    const l = linkAt(&meta, cursor) orelse return null;
    return resolveLink(a, view, vault, from_path, &meta, l);
}

pub fn resolveLink(a: Allocator, view: *const IndexView, vault: *const vault_mod.Vault, from_path: []const u8, from_meta: *const note_mod.NoteMeta, l: *const note_mod.Link) !?Target {
    const r = try view.resolveFrom(a, vault.id, from_path, l.target, l.kind);
    switch (r.kind) {
        .self => {
            const id = (try view.idOfPath(a, vault.id, from_path)) orelse FileId.none;
            return .{ .open = .{ .id = id, .path = from_path, .range = subpathTarget(from_meta, l.subpath), .attachment = false } };
        },
        .note => {
            const meta = view.note(r.id).?;
            return .{ .open = .{ .id = r.id, .path = view.pathOf(r.id).?, .range = subpathTarget(meta, l.subpath), .attachment = false } };
        },
        .attachment => return .{ .open = .{ .id = r.id, .path = view.pathOf(r.id).?, .range = null, .attachment = true } },
        .unresolved => {
            const p = (try newNotePath(a, &vault.config, from_path, l.target, l.kind)) orelse return null;
            return .{ .create = .{ .path = p } };
        },
    }
}

/// Where to scroll for a subpath: the heading's line or the block.
pub fn subpathTarget(meta: *const note_mod.NoteMeta, sub: ?note_mod.Subpath) ?[2]u32 {
    const r = subpathRange(meta, sub, std.math.maxInt(u32)) orelse return null;
    return switch (sub.?) {
        .block => r,
        .heading => for (meta.headings) |h| {
            if (h.src[0] == r[0]) break h.src;
        } else r,
    };
}

/// The range a `#heading` (nested headings outermost first) or `#^block`
/// subpath names in `meta`'s note; `body_end` closes the last section.
/// Null when the subpath is absent or unknown.
pub fn subpathRange(meta: *const note_mod.NoteMeta, sub: ?note_mod.Subpath, body_end: u32) ?[2]u32 {
    const s = sub orelse return null;
    switch (s) {
        .block => |id| {
            for (meta.blocks) |b| if (std.ascii.eqlIgnoreCase(b.id, id)) return b.range;
            return null;
        },
        .heading => |path| {
            if (path.len == 0) return null;
            // Each segment must be found after the previous one, deeper.
            var from: usize = 0;
            var level: u8 = 0;
            var hit: ?usize = null;
            for (path) |seg| {
                hit = null;
                var i = from;
                while (i < meta.headings.len) : (i += 1) {
                    const h = meta.headings[i];
                    if (level > 0 and h.level <= level) break;
                    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, h.text, " "), std.mem.trim(u8, seg, " "))) {
                        hit = i;
                        break;
                    }
                }
                const k = hit orelse return null;
                level = meta.headings[k].level;
                from = k + 1;
            }
            const r = meta.sectionRange(hit.?, body_end);
            return .{ r[0], @min(r[1], body_end) };
        },
    }
}

/// Where a note for unresolved `target` goes: a target with a folder is
/// vault-relative (Markdown links: relative to the linking note), a bare
/// name follows `new_note_dir`. Null for non-note targets (attachments)
/// and paths leaving the vault.
pub fn newNotePath(a: Allocator, cfg: *const vault_mod.VaultConfig, from_path: []const u8, target: []const u8, kind: note_mod.LinkKind) !?[]const u8 {
    if (target.len == 0) return null;
    const ext = std.fs.path.extension(target);
    if (ext.len > 0 and !names_mod.isMdExt(target)) return null;
    const with_md = if (names_mod.isMdExt(target)) target else try std.fmt.allocPrint(a, "{s}.md", .{target});
    var buf: std.ArrayList(u8) = .empty;
    if (kind == .markdown or kind == .markdown_embed) {
        const p = (try names_mod.joinRel(a, &buf, names_mod.dirname(from_path), with_md)) orelse return null;
        return p;
    }
    if (std.mem.indexOfScalar(u8, target, '/') != null) {
        const p = (try names_mod.joinRel(a, &buf, "", with_md)) orelse return null;
        return p;
    }
    const folder = switch (cfg.new_note_dir) {
        .vault_root => "",
        .same_as_current => names_mod.dirname(from_path),
        .fixed => std.mem.trim(u8, cfg.new_note_folder, "/"),
    };
    if (folder.len == 0) return with_md;
    return try std.fmt.allocPrint(a, "{s}/{s}", .{ folder, with_md });
}
