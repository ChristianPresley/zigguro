//! Name maps and link resolution (E08.F06.S01.T02), Obsidian-compatible:
//!
//! 1. A target with `/` matches a vault-relative path (with or without
//!    `.md`), then a path relative to the source note's folder, then a
//!    unique path suffix (`folder/Note` for `a/folder/Note.md`).
//! 2. Otherwise a stem: unique wins; several prefer the source's folder,
//!    then the shortest path, then the lexically first (still reported as
//!    ambiguous).
//! 3. Non-note targets (`img.png`, `doc.pdf`) match attachments by path
//!    or basename with the same tie-break.
//! 4. With alias resolution on, a unique (or tie-broken) alias.
//! 5. Else unresolved.
//!
//! Markdown links (`[t](rel/path.md)`) are URLs relative to the source
//! folder first, then vault-absolute. Names compare after full case
//! folding; every key starts with the vault id so vaults never mix.

const std = @import("std");
const note = @import("../vault/note.zig");
const tags = @import("../vault/tags.zig");
const vault_mod = @import("../vault/vault.zig");

const Allocator = std.mem.Allocator;
const FileId = note.FileId;
const VaultId = vault_mod.VaultId;

pub fn idKey(id: FileId) u64 {
    return @bitCast(id);
}

pub const ResolvedKind = enum(u8) { note, attachment, self, unresolved };

pub const Resolved = struct {
    kind: ResolvedKind,
    id: FileId = .none,
    /// Several candidates matched; `id` is the tie-break winner.
    ambiguous: bool = false,
};

pub const Place = struct {
    vault: VaultId,
    /// Vault-relative, as stored (original case).
    path: []const u8,
    attachment: bool,
};

const IdList = std.ArrayList(FileId);

/// The maps behind resolution. The writer owns one (keys in `gpa`); each
/// published view holds a copy in its arena.
pub const Names = struct {
    /// vault ++ folded stem → notes.
    stems: std.StringHashMapUnmanaged(IdList) = .empty,
    /// vault ++ folded path without `.md` → notes (one, unless two files
    /// briefly share a path while a rename is in flight).
    paths: std.StringHashMapUnmanaged(IdList) = .empty,
    /// vault ++ folded alias → notes.
    aliases: std.StringHashMapUnmanaged(IdList) = .empty,
    /// vault ++ folded path → attachments (as `paths`).
    att_paths: std.StringHashMapUnmanaged(IdList) = .empty,
    /// vault ++ folded basename → attachments.
    att_names: std.StringHashMapUnmanaged(IdList) = .empty,
    places: std.AutoHashMapUnmanaged(u64, Place) = .empty,
    /// Resolutions performed (tests count them).
    resolutions: u64 = 0,

    pub fn deinit(n: *Names, gpa: Allocator) void {
        freeLists(gpa, &n.stems);
        freeLists(gpa, &n.aliases);
        freeLists(gpa, &n.att_names);
        freeLists(gpa, &n.paths);
        freeLists(gpa, &n.att_paths);
        var it = n.places.valueIterator();
        while (it.next()) |p| gpa.free(p.path);
        n.places.deinit(gpa);
    }

    fn freeLists(gpa: Allocator, m: *std.StringHashMapUnmanaged(IdList)) void {
        var it = m.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            e.value_ptr.deinit(gpa);
        }
        m.deinit(gpa);
    }

    /// A deep copy in `a` (an arena: nothing is freed individually).
    pub fn clone(n: *const Names, a: Allocator) !Names {
        var out: Names = .{};
        try cloneLists(a, &n.stems, &out.stems);
        try cloneLists(a, &n.aliases, &out.aliases);
        try cloneLists(a, &n.att_names, &out.att_names);
        try cloneLists(a, &n.paths, &out.paths);
        try cloneLists(a, &n.att_paths, &out.att_paths);
        try out.places.ensureTotalCapacity(a, n.places.count());
        var it = n.places.iterator();
        while (it.next()) |e| {
            var p = e.value_ptr.*;
            p.path = try a.dupe(u8, p.path);
            out.places.putAssumeCapacity(e.key_ptr.*, p);
        }
        return out;
    }

    fn cloneLists(a: Allocator, from: *const std.StringHashMapUnmanaged(IdList), to: *std.StringHashMapUnmanaged(IdList)) !void {
        try to.ensureTotalCapacity(a, from.count());
        var it = from.iterator();
        while (it.next()) |e| {
            var l: IdList = .empty;
            try l.appendSlice(a, e.value_ptr.items);
            to.putAssumeCapacity(try a.dupe(u8, e.key_ptr.*), l);
        }
    }

    // ---- updates (writer) ----

    pub fn addNote(n: *Names, gpa: Allocator, k: *KeyBuf, id: FileId, v: VaultId, path: []const u8, aliases: []const []const u8) !void {
        try n.places.put(gpa, idKey(id), .{ .vault = v, .path = try gpa.dupe(u8, path), .attachment = false });
        try addTo(gpa, &n.stems, try k.make(gpa, v, stemOf(path)), id);
        try addTo(gpa, &n.paths, try k.make(gpa, v, withoutMd(path)), id);
        for (aliases) |al| try addTo(gpa, &n.aliases, try k.make(gpa, v, al), id);
    }

    pub fn removeNote(n: *Names, gpa: Allocator, k: *KeyBuf, id: FileId, aliases: []const []const u8) !void {
        const kv = n.places.fetchRemove(idKey(id)) orelse return;
        defer gpa.free(kv.value.path);
        const v = kv.value.vault;
        const path = kv.value.path;
        removeFrom(gpa, &n.stems, try k.view(gpa, v, stemOf(path)), id);
        removeFrom(gpa, &n.paths, try k.view(gpa, v, withoutMd(path)), id);
        for (aliases) |al| removeFrom(gpa, &n.aliases, try k.view(gpa, v, al), id);
    }

    pub fn addAttachment(n: *Names, gpa: Allocator, k: *KeyBuf, id: FileId, v: VaultId, path: []const u8) !void {
        try n.places.put(gpa, idKey(id), .{ .vault = v, .path = try gpa.dupe(u8, path), .attachment = true });
        try addTo(gpa, &n.att_paths, try k.make(gpa, v, path), id);
        try addTo(gpa, &n.att_names, try k.make(gpa, v, basename(path)), id);
    }

    pub fn removeAttachment(n: *Names, gpa: Allocator, k: *KeyBuf, id: FileId) !void {
        const kv = n.places.fetchRemove(idKey(id)) orelse return;
        defer gpa.free(kv.value.path);
        removeFrom(gpa, &n.att_paths, try k.view(gpa, kv.value.vault, kv.value.path), id);
        removeFrom(gpa, &n.att_names, try k.view(gpa, kv.value.vault, basename(kv.value.path)), id);
    }

    fn addTo(gpa: Allocator, m: *std.StringHashMapUnmanaged(IdList), key: []u8, id: FileId) !void {
        const gop = try m.getOrPut(gpa, key);
        if (gop.found_existing) {
            gpa.free(key);
        } else gop.value_ptr.* = .empty;
        for (gop.value_ptr.items) |x| if (x.eql(id)) return;
        try gop.value_ptr.append(gpa, id);
    }

    fn removeFrom(gpa: Allocator, m: *std.StringHashMapUnmanaged(IdList), key: []const u8, id: FileId) void {
        const e = m.getEntry(key) orelse return;
        const l = e.value_ptr;
        for (l.items, 0..) |x, i| if (x.eql(id)) {
            _ = l.orderedRemove(i);
            break;
        };
        if (l.items.len == 0) {
            const owned = e.key_ptr.*;
            l.deinit(gpa);
            m.removeByPtr(e.key_ptr);
            gpa.free(owned);
        }
    }

    // ---- queries ----

    pub fn placeOf(n: *const Names, id: FileId) ?Place {
        return n.places.get(idKey(id));
    }

    /// Resolves link `target` (as written) of `kind` from the note at
    /// vault-relative `from` in vault `v`. `out`, when given, receives
    /// every candidate of the winning rule.
    pub fn resolve(n: *Names, gpa: Allocator, k: *KeyBuf, v: VaultId, from: []const u8, target: []const u8, kind: note.LinkKind, alias_resolution: bool, out: ?*std.ArrayList(FileId)) !Resolved {
        n.resolutions += 1;
        if (target.len == 0) return .{ .kind = .self };
        const t = if (target[0] == '/') target[1..] else target;
        const markdown = kind == .markdown or kind == .markdown_embed;
        const has_slash = std.mem.indexOfScalar(u8, t, '/') != null;
        const md_ext = isMdExt(t);
        const no_md = withoutMd(t);
        var rel_buf: std.ArrayList(u8) = .empty;
        defer rel_buf.deinit(gpa);
        const rel: ?[]const u8 = if (has_slash or markdown) try joinRel(gpa, &rel_buf, dirname(from), no_md) else null;

        // Notes by path.
        if (has_slash or markdown) {
            const order: [2]?[]const u8 = if (markdown) .{ rel, no_md } else .{ no_md, rel };
            for (order) |cand| if (cand) |c| {
                if (n.paths.get(try k.view(gpa, v, c))) |l| if (l.items.len > 0) return n.single(gpa, lowest(l.items), .note, out);
            };
        }
        if (has_slash and !markdown) {
            // A unique path suffix among the stem's notes.
            if (n.stems.get(try k.view(gpa, v, stemOf(no_md)))) |l| {
                var hit: ?FileId = null;
                var count: u32 = 0;
                for (l.items) |id| {
                    const p = n.placeOf(id) orelse continue;
                    if (pathSuffixMatch(withoutMd(p.path), no_md)) {
                        hit = id;
                        count += 1;
                        if (out) |o| try o.append(gpa, id);
                    }
                }
                if (hit) |h| return .{ .kind = .note, .id = h, .ambiguous = count > 1 };
            }
        }
        // Notes by stem (wikilinks; markdown links name files, so a stem
        // matches only when no path did and the link has no folder).
        if (!has_slash) {
            if (n.stems.get(try k.view(gpa, v, no_md))) |l| if (l.items.len > 0) {
                if (out) |o| try o.appendSlice(gpa, l.items);
                return n.pick(l.items, from, .note);
            };
        }
        // Attachments.
        if (!md_ext) {
            if (has_slash or markdown) {
                const order: [2]?[]const u8 = if (markdown) .{ rel, t } else .{ t, rel };
                for (order) |cand| if (cand) |c| {
                    if (n.att_paths.get(try k.view(gpa, v, c))) |l| if (l.items.len > 0) return n.single(gpa, lowest(l.items), .attachment, out);
                };
            }
            if (!has_slash) if (n.att_names.get(try k.view(gpa, v, t))) |l| if (l.items.len > 0) {
                if (out) |o| try o.appendSlice(gpa, l.items);
                return n.pick(l.items, from, .attachment);
            };
        }
        // Aliases.
        if (alias_resolution and !has_slash and !markdown) {
            if (n.aliases.get(try k.view(gpa, v, t))) |l| if (l.items.len > 0) {
                if (out) |o| try o.appendSlice(gpa, l.items);
                return n.pick(l.items, from, .note);
            };
        }
        return .{ .kind = .unresolved };
    }

    fn single(_: *Names, gpa: Allocator, id: FileId, kind: ResolvedKind, out: ?*std.ArrayList(FileId)) !Resolved {
        if (out) |o| try o.append(gpa, id);
        return .{ .kind = kind, .id = id };
    }

    /// Same folder as `from`, then shortest path, then lexical.
    fn pick(n: *const Names, ids: []const FileId, from: []const u8, kind: ResolvedKind) Resolved {
        if (ids.len == 1) return .{ .kind = kind, .id = ids[0] };
        const from_dir = dirname(from);
        var best: ?FileId = null;
        var best_p: []const u8 = "";
        for (ids) |id| {
            const p = (n.placeOf(id) orelse continue).path;
            if (best == null or better(p, best_p, from_dir)) {
                best = id;
                best_p = p;
            }
        }
        return .{ .kind = kind, .id = best orelse ids[0], .ambiguous = true };
    }
};

/// The smallest id, so a shared path resolves the same in every order.
fn lowest(ids: []const FileId) FileId {
    var best = ids[0];
    for (ids[1..]) |id| if (@as(u64, @bitCast(id)) < @as(u64, @bitCast(best))) {
        best = id;
    };
    return best;
}

fn better(a: []const u8, b: []const u8, from_dir: []const u8) bool {
    const sa = std.mem.eql(u8, dirname(a), from_dir);
    const sb = std.mem.eql(u8, dirname(b), from_dir);
    if (sa != sb) return sa;
    if (a.len != b.len) return a.len < b.len;
    return std.mem.lessThan(u8, a, b);
}

/// Builds `vault ++ folded(text)` keys with one reusable buffer.
pub const KeyBuf = struct {
    buf: std.ArrayList(u8) = .empty,

    pub fn deinit(k: *KeyBuf, gpa: Allocator) void {
        k.buf.deinit(gpa);
    }

    /// A transient key (valid until the next call).
    pub fn view(k: *KeyBuf, gpa: Allocator, v: VaultId, text: []const u8) ![]const u8 {
        k.buf.clearRetainingCapacity();
        const vid: u16 = @intFromEnum(v);
        try k.buf.appendSlice(gpa, std.mem.asBytes(&vid));
        try @import("zg_text").unicode.casefold.foldAppend(&k.buf, gpa, text, .full);
        return k.buf.items;
    }

    /// An owned key.
    pub fn make(k: *KeyBuf, gpa: Allocator, v: VaultId, text: []const u8) ![]u8 {
        return gpa.dupe(u8, try k.view(gpa, v, text));
    }
};

pub fn basename(p: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| p[i + 1 ..] else p;
}

pub fn dirname(p: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, p, '/')) |i| p[0..i] else "";
}

pub fn isMdExt(p: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(p, ".md") or std.ascii.endsWithIgnoreCase(p, ".markdown");
}

pub fn withoutMd(p: []const u8) []const u8 {
    if (std.ascii.endsWithIgnoreCase(p, ".md")) return p[0 .. p.len - 3];
    if (std.ascii.endsWithIgnoreCase(p, ".markdown")) return p[0 .. p.len - 9];
    return p;
}

pub fn stemOf(p: []const u8) []const u8 {
    return withoutMd(basename(p));
}

/// The folded key a link's target is filed under for re-resolution: its
/// last segment without `.md` (a stem or an attachment basename).
pub fn inverseText(target: []const u8) []const u8 {
    return withoutMd(basename(target));
}

fn pathSuffixMatch(path: []const u8, suffix: []const u8) bool {
    if (path.len < suffix.len) return false;
    if (!std.ascii.endsWithIgnoreCase(path, suffix)) return false;
    return path.len == suffix.len or path[path.len - suffix.len - 1] == '/';
}

/// `dir/rel` with `.` and `..` resolved, into `buf`; null when it climbs
/// out of the vault.
pub fn joinRel(gpa: Allocator, buf: *std.ArrayList(u8), dir: []const u8, rel: []const u8) !?[]const u8 {
    buf.clearRetainingCapacity();
    var segs: [64][]const u8 = undefined;
    var n: usize = 0;
    var parts: [2][]const u8 = .{ dir, rel };
    if (rel.len > 0 and rel[0] == '/') parts[0] = "";
    for (parts) |part| {
        var it = std.mem.tokenizeScalar(u8, part, '/');
        while (it.next()) |s| {
            if (std.mem.eql(u8, s, ".")) continue;
            if (std.mem.eql(u8, s, "..")) {
                if (n == 0) return null;
                n -= 1;
                continue;
            }
            if (n == segs.len) return null;
            segs[n] = s;
            n += 1;
        }
    }
    for (segs[0..n], 0..) |s, i| {
        if (i > 0) try buf.append(gpa, '/');
        try buf.appendSlice(gpa, s);
    }
    return buf.items;
}

/// The vault-relative path from the folder of `from` to `to`, `/`
/// separated (`../x/y.md`).
pub fn relativePath(gpa: Allocator, from: []const u8, to: []const u8) ![]u8 {
    const fd = dirname(from);
    var fi = std.mem.tokenizeScalar(u8, fd, '/');
    var ti = std.mem.tokenizeScalar(u8, to, '/');
    var fsegs: std.ArrayList([]const u8) = .empty;
    defer fsegs.deinit(gpa);
    var tsegs: std.ArrayList([]const u8) = .empty;
    defer tsegs.deinit(gpa);
    while (fi.next()) |s| try fsegs.append(gpa, s);
    while (ti.next()) |s| try tsegs.append(gpa, s);
    var common: usize = 0;
    while (common < fsegs.items.len and common + 1 < tsegs.items.len and std.mem.eql(u8, fsegs.items[common], tsegs.items[common])) common += 1;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (fsegs.items[common..]) |_| try out.appendSlice(gpa, "../");
    for (tsegs.items[common..], 0..) |s, i| {
        if (i > 0) try out.append(gpa, '/');
        try out.appendSlice(gpa, s);
    }
    return out.toOwnedSlice(gpa);
}

test "names: path helpers" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try std.testing.expectEqualStrings("a/c/d", (try joinRel(gpa, &buf, "a/b", "../c/./d")).?);
    try std.testing.expect((try joinRel(gpa, &buf, "a", "../../x")) == null);
    try std.testing.expectEqualStrings("x", (try joinRel(gpa, &buf, "a/b", "/x")).?);
    const r = try relativePath(gpa, "a/b/n.md", "a/c/m.md");
    defer gpa.free(r);
    try std.testing.expectEqualStrings("../c/m.md", r);
    const r2 = try relativePath(gpa, "n.md", "a/m.md");
    defer gpa.free(r2);
    try std.testing.expectEqualStrings("a/m.md", r2);
    const r3 = try relativePath(gpa, "a/n.md", "a/m.md");
    defer gpa.free(r3);
    try std.testing.expectEqualStrings("m.md", r3);
    try std.testing.expectEqualStrings("Note", stemOf("f/Note.md"));
    try std.testing.expect(pathSuffixMatch("a/folder/note", "folder/note"));
    try std.testing.expect(!pathSuffixMatch("a/xfolder/note", "folder/note"));
}
