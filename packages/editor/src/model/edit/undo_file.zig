//! Persistent undo history: a document's undo tree in a versioned binary
//! file, written on save and close and restored on open when the file's
//! bytes still hash to what was saved (Vim's `undofile` rule).
//!
//! Files live at `<state_dir>/zigguro/undo/<hex(blake3(abs_path)[0..16])>.zgundo`.
//! Layout, little-endian:
//!
//! 1. Header (72 bytes, `UndoFileHeader`).
//! 2. Node table: one 48-byte record per node, in creation order (parents
//!    before children; node 0 is the root): parent, redo child, seq,
//!    timestamp (ns), origin tag and payload, coalesce key, and the offset
//!    and length of the node's blob.
//! 3. Blob area: per node its label, forward and inverse ChangeSets
//!    (LEB128 ranges plus raw text) and selections before and after
//!    (LEB128 anchor, head, id, virtual).
//! 4. Trailer: XxHash3 of everything before it.
//!
//! ChangeSet texts are already copies, so deleted text is stored as text.
//! A history over the size cap loses whole branches off the current path
//! first, then its oldest states (`undo.planPrune`). Any parse error or
//! trailer mismatch counts as corruption: `read` logs it, moves the file
//! aside as `<name>.corrupt` and returns null.

const std = @import("std");
const undo_mod = @import("undo.zig");
const cs_mod = @import("change_set.zig");
const sel_mod = @import("selection.zig");
const EditOrigin = @import("../document.zig").EditOrigin;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const UndoTree = undo_mod.UndoTree;
const Node = undo_mod.Node;
const NodeId = undo_mod.NodeId;
const ChangeSet = cs_mod.ChangeSet;
const Selection = sel_mod.Selection;
const Blake3 = std.crypto.hash.Blake3;

const log = std.log.scoped(.undo_file);

/// The fixed header. Written field by field in little-endian order (this
/// struct documents the layout; it is never copied as memory).
pub const UndoFileHeader = extern struct {
    magic: [8]u8 = magic,
    version: u32 = format_version,
    flags: u32 = 0,
    /// Length of the file's bytes as saved.
    content_len: u64,
    /// BLAKE3 of the file's bytes as saved.
    content_hash: [32]u8,
    node_count: u32,
    current: u32,
    /// `none_id` when the saved state was pruned.
    saved: u32,
    _pad: u32 = 0,
};

pub const magic = "ZGUNDO\x00\x01".*;
pub const format_version: u32 = 1;
/// `editor.undoFileMaxBytes`.
pub const default_max_bytes: usize = 16 << 20;
/// Files larger than this are not persisted by default.
pub const huge_file_bytes: u64 = 256 << 20;

const header_size = 72;
const record_size = 48;
const trailer_size = 8;
const none_id = std.math.maxInt(u32);

comptime {
    std.debug.assert(@sizeOf(UndoFileHeader) == header_size);
}

/// BLAKE3 of an absolute path: the undo file's key.
pub fn pathKey(abs_path: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    Blake3.hash(abs_path, &out, .{});
    return out;
}

/// The undo file's name for `key`.
pub fn fileName(key: [32]u8) [32 + ".zgundo".len]u8 {
    return std.fmt.bytesToHex(key[0..16], .lower) ++ ".zgundo".*;
}

/// BLAKE3 of the file's bytes, the content hash an undo file is tied to.
/// Saves compute it on the worker from the bytes being written.
pub fn contentHash(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    Blake3.hash(bytes, &out, .{});
    return out;
}

/// Privacy settings (E16 `security.persistUndo` and secret-file globs).
pub const PersistOptions = struct {
    enabled: bool = true,
    /// Matched against the file's base name; `*` and `?` wildcards.
    secret_globs: []const []const u8 = &default_secret_globs,
    max_file_bytes: u64 = huge_file_bytes,
};

/// Excluded until E16 supplies the workspace's secret-file globs.
pub const default_secret_globs = [_][]const u8{".env*"};

/// Whether the history of the file at `path` (`content_len` bytes) may be
/// written to disk.
pub fn shouldPersist(path: []const u8, content_len: u64, o: PersistOptions) bool {
    if (!o.enabled or content_len > o.max_file_bytes) return false;
    const base = std.fs.path.basename(path);
    for (o.secret_globs) |g| if (globMatch(g, base)) return false;
    return true;
}

/// `*` matches any run, `?` one byte.
fn globMatch(pat: []const u8, s: []const u8) bool {
    var p: usize = 0;
    var i: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (i < s.len) {
        if (p < pat.len and (pat[p] == '?' or pat[p] == s[i])) {
            p += 1;
            i += 1;
        } else if (p < pat.len and pat[p] == '*') {
            star = p;
            p += 1;
            mark = i;
        } else if (star) |st| {
            p = st + 1;
            mark += 1;
            i = mark;
        } else return false;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

/// Serializes `tree`, pruned to fit `max_bytes`.
pub fn encode(gpa: Allocator, tree: *const UndoTree, content_hash: [32]u8, content_len: u64, max_bytes: usize) ![]u8 {
    const items = tree.nodes();
    // Every node's blob, to size it before choosing what to keep.
    var blobs: std.ArrayList(u8) = .empty;
    defer blobs.deinit(gpa);
    const ends = try gpa.alloc(usize, items.len);
    defer gpa.free(ends);
    for (items, ends) |*n, *e| {
        try writeBlob(gpa, &blobs, n, false);
        e.* = blobs.items.len;
    }
    const sizes = try gpa.alloc(usize, items.len);
    defer gpa.free(sizes);
    for (sizes, 0..) |*sz, k| sz.* = record_size + ends[k] - (if (k == 0) 0 else ends[k - 1]);
    var plan: ?undo_mod.PrunePlan = null;
    defer if (plan) |*p| p.deinit(gpa);
    var total: usize = 0;
    for (sizes) |sz| total += sz;
    if (items.len > 0 and header_size + total + trailer_size > max_bytes) {
        const room = max_bytes -| (header_size + trailer_size);
        plan = try undo_mod.planPrune(gpa, items, tree.current, sizes, items.len, room);
    }
    // Old index -> new index.
    const remap = try gpa.alloc(u32, items.len);
    defer gpa.free(remap);
    var kept: u32 = 0;
    for (remap, 0..) |*r, k| {
        if (plan != null and plan.?.dead.isSet(k)) {
            r.* = none_id;
            continue;
        }
        r.* = kept;
        kept += 1;
    }
    const new_root: usize = if (plan) |p| p.new_root else 0;
    var root_blob: std.ArrayList(u8) = .empty;
    defer root_blob.deinit(gpa);
    if (new_root != 0) try writeBlob(gpa, &root_blob, &items[new_root], true);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const map = struct {
        fn f(rm: []const u32, id: NodeId) u32 {
            if (id == .none) return none_id;
            return rm[@intFromEnum(id)];
        }
    }.f;
    try out.appendSlice(gpa, &magic);
    try putInt(gpa, &out, u32, format_version);
    try putInt(gpa, &out, u32, 0);
    try putInt(gpa, &out, u64, content_len);
    try out.appendSlice(gpa, &content_hash);
    try putInt(gpa, &out, u32, kept);
    try putInt(gpa, &out, u32, if (items.len == 0) 0 else map(remap, tree.current));
    try putInt(gpa, &out, u32, if (items.len == 0) none_id else map(remap, tree.saved));
    try putInt(gpa, &out, u32, 0);
    var off: u64 = 0;
    for (items, 0..) |*n, k| {
        if (remap[k] == none_id) continue;
        const len: u64 = if (k == new_root and new_root != 0) root_blob.items.len else ends[k] - (if (k == 0) 0 else ends[k - 1]);
        try putInt(gpa, &out, u32, if (remap[k] == 0) none_id else map(remap, n.parent));
        try putInt(gpa, &out, u32, map(remap, n.redo_child));
        try putInt(gpa, &out, u64, n.seq);
        try putInt(gpa, &out, i64, @intCast(std.math.clamp(n.timestamp.nanoseconds, std.math.minInt(i64), std.math.maxInt(i64))));
        try out.append(gpa, @intFromEnum(std.meta.activeTag(n.origin)));
        try out.append(gpa, if (n.coalesce_key) |c| @intFromEnum(c) else 0xFF);
        try putInt(gpa, &out, u16, 0);
        try putInt(gpa, &out, u32, switch (n.origin) {
            .user, .agent => |v| v,
            else => 0,
        });
        try putInt(gpa, &out, u64, off);
        try putInt(gpa, &out, u64, len);
        off += len;
    }
    for (items, 0..) |_, k| {
        if (remap[k] == none_id) continue;
        if (k == new_root and new_root != 0) {
            try out.appendSlice(gpa, root_blob.items);
        } else {
            try out.appendSlice(gpa, blobs.items[(if (k == 0) 0 else ends[k - 1])..ends[k]]);
        }
    }
    try putInt(gpa, &out, u64, std.hash.XxHash3.hash(0, out.items));
    return out.toOwnedSlice(gpa);
}

/// Appends a node's label, ChangeSets and selections. A new root keeps
/// only its label and later selections, as `UndoTree` does after pruning.
fn writeBlob(gpa: Allocator, out: *std.ArrayList(u8), n: *const Node, as_root: bool) !void {
    try putVar(gpa, out, n.label.len);
    try out.appendSlice(gpa, n.label);
    if (as_root) {
        const id: ChangeSet = .identity(gpa, 0);
        try writeChangeSet(gpa, out, &id);
        try writeChangeSet(gpa, out, &id);
        try writeSelections(gpa, out, &.{});
    } else {
        try writeChangeSet(gpa, out, &n.forward);
        try writeChangeSet(gpa, out, &n.inverse);
        try writeSelections(gpa, out, n.sel_before);
    }
    try writeSelections(gpa, out, n.sel_after);
}

fn writeChangeSet(gpa: Allocator, out: *std.ArrayList(u8), cs: *const ChangeSet) !void {
    try putVar(gpa, out, cs.base_len);
    try putVar(gpa, out, cs.replaces.len);
    var prev: u64 = 0;
    for (cs.replaces) |r| {
        try putVar(gpa, out, r.range.start - prev);
        try putVar(gpa, out, r.range.len());
        try putVar(gpa, out, r.text.len);
        try out.appendSlice(gpa, r.text);
        prev = r.range.end;
    }
}

fn writeSelections(gpa: Allocator, out: *std.ArrayList(u8), sels: []const Selection) !void {
    try putVar(gpa, out, sels.len);
    for (sels) |s| {
        try putVar(gpa, out, s.anchor);
        try putVar(gpa, out, s.head);
        try putVar(gpa, out, s.id);
        try putVar(gpa, out, s.virtual);
    }
}

fn putInt(gpa: Allocator, out: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    try out.appendSlice(gpa, &b);
}

fn putVar(gpa: Allocator, out: *std.ArrayList(u8), v_in: u64) !void {
    var v = v_in;
    while (v >= 0x80) : (v >>= 7) try out.append(gpa, @as(u8, @truncate(v)) | 0x80);
    try out.append(gpa, @intCast(v));
}

/// Why `decode` returned no tree.
pub const DecodeError = error{ Corrupt, OutOfMemory };

/// Parses an undo file. Returns null when it belongs to other content
/// (hash or length differ); `Corrupt` when it is malformed.
pub fn decode(gpa: Allocator, bytes: []const u8, expect_hash: [32]u8, expect_len: u64, limits: undo_mod.Limits) DecodeError!?UndoTree {
    if (bytes.len < header_size + trailer_size) return error.Corrupt;
    const body = bytes[0 .. bytes.len - trailer_size];
    if (std.mem.readInt(u64, bytes[body.len..][0..8], .little) != std.hash.XxHash3.hash(0, body)) return error.Corrupt;
    var r: Reader = .{ .b = body };
    if (!std.mem.eql(u8, try r.take(8), &magic)) return error.Corrupt;
    if (try r.int(u32) != format_version) return error.Corrupt;
    _ = try r.int(u32);
    const content_len = try r.int(u64);
    const content_hash = try r.take(32);
    if (content_len != expect_len or !std.mem.eql(u8, content_hash, &expect_hash)) return null;
    const count = try r.int(u32);
    const current = try r.int(u32);
    const saved = try r.int(u32);
    _ = try r.int(u32);
    if (count == 0) return UndoTree.init(gpa, limits);
    const table_end = header_size + @as(u64, count) * record_size;
    if (table_end > body.len) return error.Corrupt;
    const blob_area = body[@intCast(table_end)..];
    if (current >= count or (saved != none_id and saved >= count)) return error.Corrupt;

    var nodes: std.ArrayList(Node) = .empty;
    defer {
        for (nodes.items) |*n| n.deinit(gpa);
        nodes.deinit(gpa);
    }
    try nodes.ensureTotalCapacity(gpa, count);
    const state_len = try gpa.alloc(?u64, count);
    defer gpa.free(state_len);
    @memset(state_len, null);
    const redo = try gpa.alloc(u32, count);
    defer gpa.free(redo);
    for (0..count) |k| {
        const parent = try r.int(u32);
        redo[k] = try r.int(u32);
        const seq = try r.int(u64);
        const ts = try r.int(i64);
        const tag = (try r.take(1))[0];
        const ck = (try r.take(1))[0];
        _ = try r.int(u16);
        const payload = try r.int(u32);
        const off = try r.int(u64);
        const len = try r.int(u64);
        if ((k == 0) != (parent == none_id)) return error.Corrupt;
        if (k > 0 and parent >= k) return error.Corrupt;
        if (off > blob_area.len or len > blob_area.len - off) return error.Corrupt;
        const origin = try decodeOrigin(tag, payload);
        const coalesce: ?undo_mod.CoalesceKey = if (ck == 0xFF) null else std.enums.fromInt(undo_mod.CoalesceKey, ck) orelse return error.Corrupt;
        var br: Reader = .{ .b = blob_area[@intCast(off)..][0..@intCast(len)] };
        var n = try readNode(gpa, &br);
        n.parent = if (parent == none_id) .none else @enumFromInt(parent);
        n.seq = seq;
        n.timestamp = .{ .nanoseconds = ts };
        n.origin = origin;
        n.coalesce_key = coalesce;
        nodes.appendAssumeCapacity(n);
        if (br.i != br.b.len) return error.Corrupt;
        if (k == 0) continue;
        // The ChangeSets must chain: parent state -> this state and back.
        const f = &n.forward;
        if (state_len[parent]) |pl| {
            if (pl != f.base_len) return error.Corrupt;
        } else state_len[parent] = f.base_len;
        state_len[k] = f.newLen();
        if (n.inverse.base_len != f.newLen() or n.inverse.newLen() != f.base_len) return error.Corrupt;
    }
    for (redo, 0..) |rc, k| {
        if (rc == none_id) {
            nodes.items[k].redo_child = .none;
            continue;
        }
        if (rc >= count or rc <= k or @intFromEnum(nodes.items[rc].parent) != k) return error.Corrupt;
        nodes.items[k].redo_child = @enumFromInt(rc);
    }
    const owned = try nodes.toOwnedSlice(gpa);
    return UndoTree.fromNodes(gpa, limits, owned, @enumFromInt(current), if (saved == none_id) .none else @enumFromInt(saved));
}

fn decodeOrigin(tag: u8, payload: u32) DecodeError!EditOrigin {
    const Tag = std.meta.Tag(EditOrigin);
    const t = std.enums.fromInt(Tag, tag) orelse return error.Corrupt;
    return switch (t) {
        .user => .{ .user = payload },
        .agent => .{ .agent = payload },
        inline else => |x| @unionInit(EditOrigin, @tagName(x), {}),
    };
}

fn readNode(gpa: Allocator, r: *Reader) DecodeError!Node {
    const label = try gpa.dupe(u8, try r.take(try r.varLen()));
    errdefer gpa.free(label);
    var fwd = try readChangeSet(gpa, r);
    errdefer fwd.deinit();
    var inv = try readChangeSet(gpa, r);
    errdefer inv.deinit();
    const sb = try readSelections(gpa, r);
    errdefer gpa.free(sb);
    const sa = try readSelections(gpa, r);
    return .{
        .parent = .none,
        .seq = 0,
        .timestamp = .zero,
        .origin = .reload,
        .coalesce_key = null,
        .label = label,
        .forward = fwd,
        .inverse = inv,
        .sel_before = sb,
        .sel_after = sa,
    };
}

fn readChangeSet(gpa: Allocator, r: *Reader) DecodeError!ChangeSet {
    const base_len = try r.varInt();
    const n = try r.varLen();
    // Each replace takes at least three bytes.
    if (n > r.b.len - r.i) return error.Corrupt;
    const edits = try gpa.alloc(cs_mod.Replace, n);
    defer gpa.free(edits);
    var prev: u64 = 0;
    for (edits) |*e| {
        const start = std.math.add(u64, prev, try r.varInt()) catch return error.Corrupt;
        const end = std.math.add(u64, start, try r.varInt()) catch return error.Corrupt;
        if (end > base_len) return error.Corrupt;
        e.* = .{ .range = .{ .start = start, .end = end }, .text = try r.take(try r.varLen()) };
        prev = end;
    }
    return ChangeSet.fromEdits(gpa, base_len, edits) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.Corrupt,
    };
}

fn readSelections(gpa: Allocator, r: *Reader) DecodeError![]Selection {
    const n = try r.varLen();
    if (n > r.b.len - r.i) return error.Corrupt;
    const out = try gpa.alloc(Selection, n);
    errdefer gpa.free(out);
    for (out) |*s| {
        const anchor = try r.varInt();
        const head = try r.varInt();
        const id = std.math.cast(u32, try r.varInt()) orelse return error.Corrupt;
        const virtual = std.math.cast(u32, try r.varInt()) orelse return error.Corrupt;
        s.* = .{ .anchor = anchor, .head = head, .id = id, .virtual = virtual };
    }
    return out;
}

/// A bounds-checked cursor over untrusted bytes.
const Reader = struct {
    b: []const u8,
    i: usize = 0,

    fn take(r: *Reader, n: usize) error{Corrupt}![]const u8 {
        if (n > r.b.len - r.i) return error.Corrupt;
        defer r.i += n;
        return r.b[r.i..][0..n];
    }

    fn int(r: *Reader, comptime T: type) error{Corrupt}!T {
        return std.mem.readInt(T, (try r.take(@sizeOf(T)))[0..@sizeOf(T)], .little);
    }

    fn varInt(r: *Reader) error{Corrupt}!u64 {
        var v: u64 = 0;
        var shift: u7 = 0;
        while (true) {
            const b = (try r.take(1))[0];
            if (shift == 63 and b > 1) return error.Corrupt;
            v |= @as(u64, b & 0x7F) << @intCast(shift);
            if (b < 0x80) return v;
            shift += 7;
            if (shift > 63) return error.Corrupt;
        }
    }

    /// A length, which cannot exceed the bytes left.
    fn varLen(r: *Reader) error{Corrupt}!usize {
        const v = try r.varInt();
        if (v > r.b.len - r.i) return error.Corrupt;
        return @intCast(v);
    }
};

/// Writes the undo file for `path_key` into `dir` atomically, pruned to
/// `default_max_bytes`.
pub fn write(io: Io, dir: Dir, path_key: [32]u8, tree: *const UndoTree, content_hash: [32]u8, content_len: u64, gpa: Allocator) !void {
    return writeCapped(io, dir, path_key, tree, content_hash, content_len, gpa, default_max_bytes);
}

/// `write` with an explicit size cap (`editor.undoFileMaxBytes`).
pub fn writeCapped(io: Io, dir: Dir, path_key: [32]u8, tree: *const UndoTree, content_hash: [32]u8, content_len: u64, gpa: Allocator, max_bytes: usize) !void {
    const bytes = try encode(gpa, tree, content_hash, content_len, max_bytes);
    defer gpa.free(bytes);
    const name = fileName(path_key);
    var af = try dir.createFileAtomic(io, &name, .{ .replace = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, bytes);
    try af.file.sync(io);
    try af.replace(io);
}

/// Reads the undo file for `path_key` from `dir`: null when there is
/// none, it belongs to other content, or it is corrupt (then it is moved
/// aside as `<name>.corrupt`).
pub fn read(io: Io, dir: Dir, path_key: [32]u8, expect_hash: [32]u8, expect_len: u64, gpa: Allocator) !?UndoTree {
    return readCapped(io, dir, path_key, expect_hash, expect_len, gpa, default_max_bytes, .{});
}

/// `read` with an explicit size cap and limits for the restored tree.
pub fn readCapped(io: Io, dir: Dir, path_key: [32]u8, expect_hash: [32]u8, expect_len: u64, gpa: Allocator, max_bytes: usize, limits: undo_mod.Limits) !?UndoTree {
    const name = fileName(path_key);
    const bytes = dir.readFileAlloc(io, &name, gpa, .limited(max_bytes + 1)) catch |e| switch (e) {
        error.FileNotFound => return null,
        error.StreamTooLong => {
            log.info("{s}: larger than {d} bytes; ignored", .{ &name, max_bytes });
            return null;
        },
        else => |x| return x,
    };
    defer gpa.free(bytes);
    return decode(gpa, bytes, expect_hash, expect_len, limits) catch |e| switch (e) {
        error.OutOfMemory => |x| return x,
        error.Corrupt => {
            log.info("{s}: corrupt; moved aside", .{&name});
            const aside = name ++ ".corrupt".*;
            dir.rename(&name, dir, &aside, io) catch {};
            return null;
        },
    };
}

test "undo_file: glob" {
    try std.testing.expect(globMatch(".env*", ".env.local"));
    try std.testing.expect(globMatch(".env*", ".env"));
    try std.testing.expect(!globMatch(".env*", "x.env"));
    try std.testing.expect(globMatch("*.p?m", "key.pem"));
    try std.testing.expect(!shouldPersist("/w/.env.production", 10, .{}));
    try std.testing.expect(shouldPersist("/w/main.zig", 10, .{}));
    try std.testing.expect(!shouldPersist("/w/main.zig", 10, .{ .enabled = false }));
    try std.testing.expect(!shouldPersist("/w/big.log", huge_file_bytes + 1, .{}));
}
