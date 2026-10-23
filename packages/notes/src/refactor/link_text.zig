//! Link target text for renames (E08.F06.S02.T01): the shortest wiki form
//! that still resolves to a note, Markdown relative destinations with the
//! original escaping style, and the form-preserving rewrite of one link.

const std = @import("std");
const names_mod = @import("../index/names.zig");
const note = @import("../vault/note.zig");

const Allocator = std.mem.Allocator;
const Names = names_mod.Names;
const KeyBuf = names_mod.KeyBuf;
const FileId = note.FileId;
const VaultId = @import("../vault/vault.zig").VaultId;

/// The shortest wiki target naming `target` (at vault-relative
/// `target_path`) from the note at `from_path`: the stem (an attachment's
/// file name) when that resolves uniquely, else the shortest unique path
/// suffix, else the full path (notes without `.md`).
pub fn shortestLinkText(a: Allocator, names: *Names, keys: *KeyBuf, vault: VaultId, from_path: []const u8, target: FileId, target_path: []const u8, attachment: bool) ![]const u8 {
    const full = if (attachment) target_path else names_mod.withoutMd(target_path);
    var start: usize = full.len;
    // Suffixes from the last segment outwards.
    while (true) {
        const cand = full[start..];
        if (cand.len > 0) {
            const r = try names.resolve(a, keys, vault, from_path, cand, .wiki, false, null);
            if ((r.kind == .note or r.kind == .attachment) and r.id.eql(target) and !r.ambiguous) return a.dupe(u8, cand);
        }
        if (start == 0) break;
        start = if (std.mem.lastIndexOfScalar(u8, full[0 .. start - 1], '/')) |i| i + 1 else 0;
    }
    return a.dupe(u8, full);
}

/// Percent-encodes what CommonMark destinations cannot hold bare.
pub fn percentEncode(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| switch (c) {
        ' ' => try out.appendSlice(a, "%20"),
        '(' => try out.appendSlice(a, "%28"),
        ')' => try out.appendSlice(a, "%29"),
        '<' => try out.appendSlice(a, "%3C"),
        '>' => try out.appendSlice(a, "%3E"),
        '%' => try out.appendSlice(a, "%25"),
        '#' => try out.appendSlice(a, "%23"),
        else => try out.append(a, c),
    };
    return out.items;
}

/// The Markdown destination text for `path` (already relative or
/// absolute), in the style of the original link: `%XX`-encoded when the
/// original was, `<...>` when the original was or (with no subpath after
/// it) when the path needs it, else encoded.
pub fn markdownDest(a: Allocator, path: []const u8, angle: bool, encoded: bool, has_subpath: bool) ![]const u8 {
    if (encoded) return percentEncode(a, path);
    if (angle) return a.dupe(u8, path);
    const needs = std.mem.indexOfAny(u8, path, " <>") != null or !balancedParens(path);
    if (!needs) return a.dupe(u8, path);
    if (has_subpath) return percentEncode(a, path);
    return std.fmt.allocPrint(a, "<{s}>", .{path});
}

fn balancedParens(s: []const u8) bool {
    var depth: i32 = 0;
    for (s) |c| {
        if (c == '(') depth += 1;
        if (c == ')') {
            depth -= 1;
            if (depth < 0) return false;
        }
    }
    return depth == 0;
}

/// The original form of a link, kept across the rewrite.
pub const Form = struct {
    kind: note.LinkKind,
    /// Wiki: written with a `/` (a path form).
    path_form: bool,
    md_ext: bool,
    /// Markdown: `/`-rooted.
    absolute: bool,
    angle: bool,
    encoded: bool,
    has_subpath: bool,

    pub fn of(l: *const note.Link) Form {
        const t = l.target;
        return .{
            .kind = l.kind,
            .path_form = std.mem.indexOfScalar(u8, t, '/') != null,
            .md_ext = names_mod.isMdExt(t),
            .absolute = t.len > 0 and t[0] == '/',
            .angle = l.angle,
            .encoded = l.encoded,
            .has_subpath = l.subpath != null,
        };
    }
};

/// The new target text for a link of `form` from `from_path` to the
/// note or attachment at `target_path`, both after the moves.
pub fn rewrite(a: Allocator, names: *Names, keys: *KeyBuf, vault: VaultId, form: Form, from_path: []const u8, target: FileId, target_path: []const u8, attachment: bool) ![]const u8 {
    switch (form.kind) {
        .wiki, .embed => {
            const base = if (form.path_form)
                if (attachment) target_path else names_mod.withoutMd(target_path)
            else
                try shortestLinkText(a, names, keys, vault, from_path, target, target_path, attachment);
            if (!attachment and form.md_ext and !names_mod.isMdExt(base)) return std.fmt.allocPrint(a, "{s}.md", .{base});
            return a.dupe(u8, base);
        },
        .markdown, .markdown_embed => {
            const path = try rewritePlain(a, form, from_path, target_path, attachment);
            return markdownDest(a, path, form.angle, form.encoded, form.has_subpath);
        },
    }
}

/// A Markdown link's new destination path, before escaping.
pub fn rewritePlain(a: Allocator, form: Form, from_path: []const u8, target_path: []const u8, attachment: bool) ![]const u8 {
    const with_ext = if (attachment or form.md_ext) target_path else names_mod.withoutMd(target_path);
    if (form.absolute) return std.fmt.allocPrint(a, "/{s}", .{with_ext});
    return names_mod.relativePath(a, from_path, with_ext);
}

test "link_text: markdown destination styles" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("a/b.md", try markdownDest(a, "a/b.md", false, false, false));
    try std.testing.expectEqualStrings("<a b/c (1).md>", try markdownDest(a, "a b/c (1).md", false, false, false));
    try std.testing.expectEqualStrings("a%20b.md", try markdownDest(a, "a b.md", false, false, true));
    try std.testing.expectEqualStrings("a%20b%28x%29.md", try markdownDest(a, "a b(x).md", false, true, false));
    try std.testing.expectEqualStrings("a b.md", try markdownDest(a, "a b.md", true, false, false));
    try std.testing.expectEqualStrings("x(1).md", try markdownDest(a, "x(1).md", false, false, false));
}
