//! The fielded inverted index behind note search (E08.F06.S03.T01). Each
//! interned term has one posting list of (doc, field, tf); each doc keeps
//! its field lengths and unique terms so a re-extracted note's postings
//! are removed before the new ones are added. Docs are dense slots
//! (reused after removal) so query evaluation can use bitsets and dense
//! score accumulators.

const std = @import("std");
const tokenize = @import("tokenize.zig");

const Allocator = std.mem.Allocator;
const FileId = @import("../vault/note.zig").FileId;

pub const Field = enum(u3) { title, aliases, headings, tags, body };
pub const n_fields = std.meta.fields(Field).len;

pub const Posting = packed struct(u64) {
    doc: u32,
    tf: u16,
    field: Field,
    _pad: u13 = 0,
};

pub const Doc = struct {
    id: FileId,
    live: bool,
    len: [n_fields]u32,
    /// Unique term ids.
    terms: []u32,
};

/// One field's text, as pieces (a note's aliases, its headings).
pub const FieldText = []const []const u8;

pub const Postings = struct {
    gpa: Allocator,
    /// Term text (owned) → id.
    terms: std.StringHashMapUnmanaged(u32) = .empty,
    term_text: std.ArrayList([]const u8) = .empty,
    lists: std.ArrayList(std.ArrayList(Posting)) = .empty,
    /// Live docs holding each term in any field.
    df: std.ArrayList(u32) = .empty,
    docs: std.ArrayList(Doc) = .empty,
    by_id: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    free_docs: std.ArrayList(u32) = .empty,
    total_len: [n_fields]u64 = @splat(0),
    live: u32 = 0,
    tok: tokenize.Tokenizer = .{},
    counts: std.AutoArrayHashMapUnmanaged(u32, [n_fields]u16) = .empty,

    pub fn init(gpa: Allocator) Postings {
        return .{ .gpa = gpa };
    }

    pub fn deinit(p: *Postings) void {
        const gpa = p.gpa;
        for (p.term_text.items) |t| gpa.free(t);
        p.term_text.deinit(gpa);
        p.terms.deinit(gpa);
        for (p.lists.items) |*l| l.deinit(gpa);
        p.lists.deinit(gpa);
        p.df.deinit(gpa);
        for (p.docs.items) |d| gpa.free(d.terms);
        p.docs.deinit(gpa);
        p.by_id.deinit(gpa);
        p.free_docs.deinit(gpa);
        p.tok.deinit(gpa);
        p.counts.deinit(gpa);
    }

    pub fn termId(p: *const Postings, folded: []const u8) ?u32 {
        return p.terms.get(folded);
    }

    pub fn docOf(p: *const Postings, id: FileId) ?u32 {
        return p.by_id.get(@bitCast(id));
    }

    /// The number of doc slots (live or free).
    pub fn slots(p: *const Postings) usize {
        return p.docs.items.len;
    }

    pub fn avgLen(p: *const Postings, f: Field) f32 {
        if (p.live == 0) return 0;
        return @as(f32, @floatFromInt(p.total_len[@intFromEnum(f)])) / @as(f32, @floatFromInt(p.live));
    }

    /// Replaces the postings of note `id`.
    pub fn setDoc(p: *Postings, id: FileId, fields: [n_fields]FieldText) !void {
        const gpa = p.gpa;
        p.remove(id);
        p.counts.clearRetainingCapacity();
        var lens: [n_fields]u32 = @splat(0);
        for (fields, 0..) |pieces, fi| {
            for (pieces) |piece| {
                try p.tok.run(gpa, piece);
                lens[fi] += @intCast(p.tok.len());
                for (0..p.tok.len()) |ti| {
                    const t = try p.intern(p.tok.get(ti).text);
                    const gop = try p.counts.getOrPut(gpa, t);
                    if (!gop.found_existing) gop.value_ptr.* = @splat(0);
                    gop.value_ptr[fi] +|= 1;
                }
            }
        }
        const doc: u32 = p.free_docs.pop() orelse blk: {
            try p.docs.append(gpa, undefined);
            break :blk @intCast(p.docs.items.len - 1);
        };
        const terms = try gpa.dupe(u32, p.counts.keys());
        p.docs.items[doc] = .{ .id = id, .live = true, .len = lens, .terms = terms };
        try p.by_id.put(gpa, @bitCast(id), doc);
        for (p.counts.keys(), p.counts.values()) |t, tfs| {
            for (tfs, 0..) |tf, fi| if (tf > 0) {
                try p.lists.items[t].append(gpa, .{ .doc = doc, .tf = tf, .field = @enumFromInt(fi) });
            };
            p.df.items[t] += 1;
        }
        for (lens, 0..) |l, fi| p.total_len[fi] += l;
        p.live += 1;
    }

    pub fn remove(p: *Postings, id: FileId) void {
        const kv = p.by_id.fetchRemove(@bitCast(id)) orelse return;
        const doc = kv.value;
        const d = &p.docs.items[doc];
        for (d.terms) |t| {
            const l = &p.lists.items[t];
            var i: usize = l.items.len;
            while (i > 0) {
                i -= 1;
                if (l.items[i].doc == doc) _ = l.swapRemove(i);
            }
            p.df.items[t] -= 1;
        }
        for (d.len, 0..) |l, fi| p.total_len[fi] -= l;
        p.gpa.free(d.terms);
        d.* = .{ .id = .none, .live = false, .len = @splat(0), .terms = &.{} };
        p.live -= 1;
        p.free_docs.append(p.gpa, doc) catch {};
    }

    fn intern(p: *Postings, folded: []const u8) !u32 {
        if (p.terms.get(folded)) |t| return t;
        const gpa = p.gpa;
        const owned = try gpa.dupe(u8, folded);
        errdefer gpa.free(owned);
        const t: u32 = @intCast(p.term_text.items.len);
        try p.term_text.append(gpa, owned);
        try p.lists.append(gpa, .empty);
        try p.df.append(gpa, 0);
        try p.terms.put(gpa, owned, t);
        return t;
    }

    /// Approximate heap bytes held.
    pub fn memoryBytes(p: *const Postings) usize {
        var n: usize = 0;
        for (p.term_text.items) |t| n += t.len + 16;
        n += p.terms.capacity() * (@sizeOf([]const u8) + @sizeOf(u32) + 1);
        n += p.lists.capacity * @sizeOf(std.ArrayList(Posting));
        for (p.lists.items) |l| n += l.capacity * @sizeOf(Posting);
        n += p.df.capacity * 4;
        n += p.docs.capacity * @sizeOf(Doc);
        for (p.docs.items) |d| n += d.terms.len * 4;
        n += p.by_id.capacity() * 13;
        return n;
    }
};

test "postings: add, replace and remove keep counts consistent" {
    var p: Postings = .init(std.testing.allocator);
    defer p.deinit();
    const a: FileId = .{ .index = 1, .gen = 0 };
    const b: FileId = .{ .index = 2, .gen = 0 };
    try p.setDoc(a, .{ &.{"Alpha"}, &.{}, &.{}, &.{}, &.{"alpha beta beta"} });
    try p.setDoc(b, .{ &.{"Beta"}, &.{}, &.{}, &.{}, &.{"gamma"} });
    const beta = p.termId("beta").?;
    try std.testing.expectEqual(@as(u32, 2), p.df.items[beta]);
    try std.testing.expectEqual(@as(u64, 4), p.total_len[@intFromEnum(Field.body)]);
    try p.setDoc(a, .{ &.{"Alpha"}, &.{}, &.{}, &.{}, &.{"delta"} });
    try std.testing.expectEqual(@as(u32, 1), p.df.items[beta]);
    try std.testing.expectEqual(@as(usize, 1), p.lists.items[beta].items.len);
    p.remove(b);
    try std.testing.expectEqual(@as(u32, 0), p.df.items[beta]);
    try std.testing.expectEqual(@as(u32, 1), p.live);
    // The freed slot is reused.
    try p.setDoc(b, .{ &.{}, &.{}, &.{}, &.{}, &.{"x"} });
    try std.testing.expectEqual(@as(usize, 2), p.slots());
}
