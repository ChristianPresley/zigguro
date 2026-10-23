//! The note search index (E08.F06.S03.T01): fielded postings fed by the
//! NoteIndex as notes are indexed, plus a bounded LRU of recent note
//! text for verification operators (phrases, `line:`, regex). Text not in
//! the cache is read on demand through a `ContentSource` (open editor
//! buffers, then disk). Everything is guarded by the NoteIndex lock.

const std = @import("std");
const note_index = @import("../index/note_index.zig");
const mentions = @import("../index/mentions.zig");
const postings_mod = @import("postings.zig");
const bm25 = @import("bm25.zig");

const Allocator = std.mem.Allocator;
const NoteIndex = note_index.NoteIndex;
const Entry = note_index.Entry;
const FileId = @import("../vault/note.zig").FileId;
const Postings = postings_mod.Postings;

pub const ContentSource = mentions.ContentSource;

pub const Options = struct {
    /// Reads notes the cache does not hold.
    content: ?ContentSource = null,
    cache_bytes: usize = 64 << 20,
    cache_notes: u32 = 2000,
    params: bm25.Bm25Params = .{},
};

pub const SearchIndex = struct {
    gpa: Allocator,
    ix: *NoteIndex,
    postings: Postings,
    content: ?ContentSource,
    params: bm25.Bm25Params,
    cache: std.AutoHashMapUnmanaged(u64, Cached) = .empty,
    cache_total: usize = 0,
    cache_bytes: usize,
    cache_notes: u32,
    tick: u64 = 0,

    const Cached = struct { bytes: []u8, tick: u64 };

    /// Attaches a search index to `ix`. Attach before indexing: notes
    /// already indexed have no text here.
    pub fn attach(ix: *NoteIndex, opts: Options) !*SearchIndex {
        const s = try ix.gpa.create(SearchIndex);
        s.* = .{
            .gpa = ix.gpa,
            .ix = ix,
            .postings = .init(ix.gpa),
            .content = opts.content,
            .params = opts.params,
            .cache_bytes = opts.cache_bytes,
            .cache_notes = opts.cache_notes,
        };
        ix.mutex.lockUncancelable(ix.io);
        defer ix.mutex.unlock(ix.io);
        ix.sink = .{ .ctx = s, .update = sinkUpdate, .remove = sinkRemove };
        return s;
    }

    /// Detaches and frees.
    pub fn deinit(s: *SearchIndex) void {
        const ix = s.ix;
        ix.mutex.lockUncancelable(ix.io);
        if (ix.sink) |sk| if (sk.ctx == @as(*anyopaque, s)) {
            ix.sink = null;
        };
        ix.mutex.unlock(ix.io);
        s.postings.deinit();
        var it = s.cache.valueIterator();
        while (it.next()) |c| s.gpa.free(c.bytes);
        s.cache.deinit(s.gpa);
        s.gpa.destroy(s);
    }

    fn sinkUpdate(ctx: *anyopaque, id: FileId, e: *const Entry, bytes: []const u8) anyerror!void {
        const s: *SearchIndex = @ptrCast(@alignCast(ctx));
        const m = &e.meta;
        var heads: std.ArrayList([]const u8) = .empty;
        defer heads.deinit(s.gpa);
        for (m.headings) |h| try heads.append(s.gpa, h.text);
        var tags: std.ArrayList([]const u8) = .empty;
        defer tags.deinit(s.gpa);
        for (m.tags) |t| try tags.append(s.gpa, t.display);
        const body = bodyOf(m, bytes);
        try s.postings.setDoc(id, .{ &.{m.title}, m.aliases, heads.items, tags.items, &.{body} });
        try s.cachePut(id, bytes);
    }

    fn sinkRemove(ctx: *anyopaque, id: FileId) void {
        const s: *SearchIndex = @ptrCast(@alignCast(ctx));
        s.postings.remove(id);
        if (s.cache.fetchRemove(@bitCast(id))) |kv| {
            s.cache_total -= kv.value.bytes.len;
            s.gpa.free(kv.value.bytes);
        }
    }

    fn cachePut(s: *SearchIndex, id: FileId, bytes: []const u8) !void {
        if (bytes.len > s.cache_bytes) return;
        s.tick += 1;
        const gop = try s.cache.getOrPut(s.gpa, @bitCast(id));
        if (gop.found_existing) {
            s.cache_total -= gop.value_ptr.bytes.len;
            s.gpa.free(gop.value_ptr.bytes);
        }
        gop.value_ptr.* = .{ .bytes = s.gpa.dupe(u8, bytes) catch |err| {
            s.cache.removeByPtr(gop.key_ptr);
            return err;
        }, .tick = s.tick };
        s.cache_total += bytes.len;
        while (s.cache_total > s.cache_bytes or s.cache.count() > s.cache_notes) s.evictOldest();
    }

    fn evictOldest(s: *SearchIndex) void {
        var it = s.cache.iterator();
        var oldest: ?u64 = null;
        var t: u64 = std.math.maxInt(u64);
        while (it.next()) |kv| if (kv.value_ptr.tick < t) {
            t = kv.value_ptr.tick;
            oldest = kv.key_ptr.*;
        };
        const kv = s.cache.fetchRemove(oldest orelse return).?;
        s.cache_total -= kv.value.bytes.len;
        s.gpa.free(kv.value.bytes);
    }

    /// The text of note `id` (call with the index locked): from the cache
    /// (borrowed) or the content source (owned, in `gpa`).
    pub fn text(s: *SearchIndex, gpa: Allocator, id: FileId, path: []const u8) !?Text {
        if (s.cache.getPtr(@bitCast(id))) |c| {
            s.tick += 1;
            c.tick = s.tick;
            return .{ .bytes = c.bytes, .owned = false };
        }
        const src = s.content orelse return null;
        const bytes = (try src.read(src.ctx, gpa, id, path)) orelse return null;
        return .{ .bytes = bytes, .owned = true };
    }

    pub const Text = struct {
        bytes: []u8,
        owned: bool,

        pub fn deinit(t: Text, gpa: Allocator) void {
            if (t.owned) gpa.free(t.bytes);
        }
    };

    /// Approximate heap bytes held by the postings (not the text cache).
    pub fn memoryBytes(s: *const SearchIndex) usize {
        return s.postings.memoryBytes();
    }
};

/// A note's bytes after its frontmatter.
pub fn bodyOf(m: *const @import("../vault/note.zig").NoteMeta, bytes: []const u8) []const u8 {
    const r = m.fm_range orelse return bytes;
    return bytes[@min(r[1], bytes.len)..];
}
