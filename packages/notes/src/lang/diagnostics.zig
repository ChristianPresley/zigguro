//! Link diagnostics (E08.F06.S02.T02), hint severity: unresolved links
//! (quick fix: create the note), ambiguous links (quick fix: use the path
//! form) and unknown `#heading` / `#^block` subpaths. Computed from the
//! document's live bytes against the index.

const std = @import("std");
const note_index = @import("../index/note_index.zig");
const names_mod = @import("../index/names.zig");
const extract_mod = @import("../vault/extract.zig");
const vault_mod = @import("../vault/vault.zig");
const note_mod = @import("../vault/note.zig");
const link_nav = @import("link_nav.zig");

const Allocator = std.mem.Allocator;
const FileId = note_mod.FileId;

pub const Code = enum { unresolved, ambiguous, unknown_heading, unknown_block };

pub const Fix = union(enum) {
    /// Create this vault-relative note.
    create_note: []const u8,
    /// Replace `range` (the link target) with `text`.
    use_path: struct { range: [2]u32, text: []const u8 },
};

pub const Diagnostic = struct {
    range: [2]u32,
    code: Code,
    message: []const u8,
    fix: ?Fix = null,
};

pub fn diagnose(a: Allocator, view: *const note_index.IndexView, vault: *const vault_mod.Vault, from_path: []const u8, text: []const u8) ![]Diagnostic {
    const meta = try extract_mod.extract(a, text, from_path, &vault.config);
    const me = try view.idOfPath(a, vault.id, from_path);
    var out: std.ArrayList(Diagnostic) = .empty;
    var cands: std.ArrayList(FileId) = .empty;
    for (meta.links) |*l| {
        cands.clearRetainingCapacity();
        const r = if (me) |id|
            try view.resolve(a, id, l.target, l.kind, &cands)
        else
            try view.resolveFrom(a, vault.id, from_path, l.target, l.kind);
        switch (r.kind) {
            .unresolved => {
                const p = try link_nav.newNotePath(a, &vault.config, from_path, l.target, l.kind);
                try out.append(a, .{
                    .range = l.target_src,
                    .code = .unresolved,
                    .message = try std.fmt.allocPrint(a, "No note named \"{s}\"", .{l.target}),
                    .fix = if (p) |x| .{ .create_note = x } else null,
                });
                continue;
            },
            .attachment => continue,
            .note, .self => {},
        }
        if (r.ambiguous) {
            const path = view.pathOf(r.id).?;
            const full = if (l.kind == .wiki or l.kind == .embed) names_mod.withoutMd(path) else path;
            try out.append(a, .{
                .range = l.target_src,
                .code = .ambiguous,
                .message = try std.fmt.allocPrint(a, "\"{s}\" matches {d} notes; it links to {s}", .{ l.target, @max(cands.items.len, 2), path }),
                .fix = .{ .use_path = .{ .range = l.target_src, .text = full } },
            });
        }
        const sub = l.subpath orelse continue;
        if (sub == .heading and sub.heading.len == 0) continue;
        const tmeta: *const note_mod.NoteMeta = if (r.kind == .self) &meta else view.note(r.id) orelse continue;
        if (link_nav.subpathRange(tmeta, sub, std.math.maxInt(u32)) != null) continue;
        try out.append(a, switch (sub) {
            .heading => |h| .{ .range = l.src, .code = .unknown_heading, .message = try std.fmt.allocPrint(a, "No heading \"{s}\" in {s}", .{ h[h.len - 1], tmeta.title }) },
            .block => |b| .{ .range = l.src, .code = .unknown_block, .message = try std.fmt.allocPrint(a, "No block ^{s} in {s}", .{ b, tmeta.title }) },
        });
    }
    return out.items;
}
