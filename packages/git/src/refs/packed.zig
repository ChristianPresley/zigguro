//! `packed-refs`: one "<hex> <name>" line per ref, optional "^<hex>" peeled
//! lines after annotated tags, and a "# pack-refs with: <traits>" header.

const std = @import("std");
const oid_mod = @import("../oid.zig");
const Oid = oid_mod.Oid;
const ObjectFormat = oid_mod.ObjectFormat;
const Allocator = std.mem.Allocator;

/// Errors for malformed files.
pub const Error = error{CorruptPackedRefs};

/// One packed ref. `name` borrows from the file contents.
pub const PackedRef = struct {
    /// Full ref name.
    name: []const u8,
    /// Target object.
    oid: Oid,
    /// Peeled target of an annotated tag, when recorded.
    peeled: ?Oid = null,
};

/// Header traits.
pub const Traits = struct {
    /// Tag refs carry "^" lines when peelable.
    peeled: bool = false,
    /// Every ref was peeled (a missing "^" line means "not a tag").
    fully_peeled: bool = false,
    /// Lines are sorted by name.
    sorted: bool = false,
};

/// A parsed `packed-refs` file.
pub const PackedRefs = struct {
    /// File contents (owned).
    bytes: []u8,
    /// Refs sorted by name.
    refs: []PackedRef,
    /// Header traits as read.
    traits: Traits,

    /// An empty set (no file).
    pub const empty: PackedRefs = .{ .bytes = &.{}, .refs = &.{}, .traits = .{} };

    /// Reads `packed-refs` from `dir`; a missing file is an empty set.
    pub fn load(gpa: Allocator, io: std.Io, dir: std.Io.Dir, fmt: ObjectFormat) !PackedRefs {
        const bytes = dir.readFileAlloc(io, "packed-refs", gpa, .unlimited) catch |e| switch (e) {
            error.FileNotFound => return empty,
            else => |x| return x,
        };
        return parse(gpa, bytes, fmt);
    }

    /// Parses file contents, taking ownership of `bytes` (freed on error).
    pub fn parse(gpa: Allocator, bytes: []u8, fmt: ObjectFormat) (Error || Allocator.Error)!PackedRefs {
        errdefer gpa.free(bytes);
        var refs: std.ArrayList(PackedRef) = .empty;
        errdefer refs.deinit(gpa);
        var traits: Traits = .{};
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        var first = true;
        const hl = fmt.hexLen();
        while (lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            defer first = false;
            if (line.len == 0) continue;
            if (line[0] == '#') {
                const prefix = "# pack-refs with:";
                if (first and std.mem.startsWith(u8, line, prefix)) {
                    var it = std.mem.tokenizeScalar(u8, line[prefix.len..], ' ');
                    while (it.next()) |tr| {
                        if (std.mem.eql(u8, tr, "peeled")) traits.peeled = true;
                        if (std.mem.eql(u8, tr, "fully-peeled")) traits.fully_peeled = true;
                        if (std.mem.eql(u8, tr, "sorted")) traits.sorted = true;
                    }
                }
                continue;
            }
            if (line[0] == '^') {
                if (refs.items.len == 0) return error.CorruptPackedRefs;
                const last = &refs.items[refs.items.len - 1];
                if (last.peeled != null) return error.CorruptPackedRefs;
                last.peeled = Oid.parseHex(fmt, line[1..]) catch return error.CorruptPackedRefs;
                continue;
            }
            if (line.len < hl + 2 or line[hl] != ' ') return error.CorruptPackedRefs;
            const id = Oid.parseHex(fmt, line[0..hl]) catch return error.CorruptPackedRefs;
            try refs.append(gpa, .{ .name = line[hl + 1 ..], .oid = id });
        }
        if (!traits.sorted) std.mem.sort(PackedRef, refs.items, {}, lessThan);
        return .{ .bytes = bytes, .refs = try refs.toOwnedSlice(gpa), .traits = traits };
    }

    fn lessThan(_: void, a: PackedRef, b: PackedRef) bool {
        return std.mem.order(u8, a.name, b.name) == .lt;
    }

    /// Frees the contents.
    pub fn deinit(p: *PackedRefs, gpa: Allocator) void {
        gpa.free(p.bytes);
        gpa.free(p.refs);
        p.* = undefined;
    }

    /// Binary search by name.
    pub fn find(p: *const PackedRefs, name: []const u8) ?*const PackedRef {
        var lo: usize = 0;
        var hi = p.refs.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, p.refs[mid].name, name)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return &p.refs[mid],
            }
        }
        return null;
    }

    /// Writes the file, skipping refs for which `skip` returns true.
    pub fn write(p: *const PackedRefs, w: *std.Io.Writer, skip: anytype) std.Io.Writer.Error!void {
        try w.writeAll("# pack-refs with:");
        if (p.traits.peeled) try w.writeAll(" peeled");
        if (p.traits.fully_peeled) try w.writeAll(" fully-peeled");
        try w.writeAll(" sorted \n");
        var buf: [64]u8 = undefined;
        for (p.refs) |r| {
            if (skip.skip(r.name)) continue;
            try w.print("{s} {s}\n", .{ r.oid.hex(&buf), r.name });
            if (r.peeled) |pe| try w.print("^{s}\n", .{pe.hex(&buf)});
        }
    }
};

test "packed-refs: parse, find, write" {
    const t = std.testing;
    const gpa = t.allocator;
    const text =
        "# pack-refs with: peeled fully-peeled \n" ++
        "ce013625030ba8dba906f756967f9e9ca394464a refs/tags/v1\n" ++
        "^4b825dc642cb6eb9a060e54bf8d69288fbee4904\n" ++
        "ce013625030ba8dba906f756967f9e9ca394464a refs/heads/main\n";
    var p = try PackedRefs.parse(gpa, try gpa.dupe(u8, text), .sha1);
    defer p.deinit(gpa);
    try t.expect(p.traits.fully_peeled and !p.traits.sorted);
    try t.expectEqualStrings("refs/heads/main", p.refs[0].name);
    try t.expect(p.find("refs/tags/v1").?.peeled != null);
    try t.expect(p.find("refs/heads/nope") == null);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try p.write(&aw.writer, struct {
        fn skip(_: @This(), n: []const u8) bool {
            return std.mem.eql(u8, n, "refs/heads/main");
        }
    }{});
    try t.expectEqualStrings(
        "# pack-refs with: peeled fully-peeled sorted \n" ++
            "ce013625030ba8dba906f756967f9e9ca394464a refs/tags/v1\n" ++
            "^4b825dc642cb6eb9a060e54bf8d69288fbee4904\n",
        aw.written(),
    );
    try t.expectError(error.CorruptPackedRefs, PackedRefs.parse(gpa, try gpa.dupe(u8, "^abc\n"), .sha1));
}
