//! Encoding tests: golden IDs, random round trips, canonical-form rejection
//! and the decode fuzz target.

const std = @import("std");
const options = @import("zg_options");
const id_mod = @import("id.zig");
const object = @import("object.zig");
const enc = @import("encode.zig");
const ObjectId = id_mod.ObjectId;
const ChangeId = id_mod.ChangeId;
const Kind = id_mod.Kind;
const Tree = object.Tree;
const TreeEntry = object.TreeEntry;
const Change = object.Change;
const ChunkedBlob = object.ChunkedBlob;
const Signature = object.Signature;
const Allocator = std.mem.Allocator;

/// One golden vector: a value of some kind and its pinned ID.
const Vector = struct {
    name: []const u8,
    kind: Kind,
    id: ObjectId,
    value: Value,

    const Value = union(enum) {
        /// blob, text and kinds whose struct is defined by later tasks.
        bytes: []const u8,
        tree: Tree,
        change: Change,
        chunked_blob: ChunkedBlob,
    };

    fn payload(v: Value, gpa: Allocator) ![]u8 {
        return switch (v) {
            .bytes => |b| gpa.dupe(u8, b),
            .tree => |x| enc.encodeAlloc(gpa, Tree, x),
            .change => |x| enc.encodeAlloc(gpa, Change, x),
            .chunked_blob => |x| enc.encodeAlloc(gpa, ChunkedBlob, x),
        };
    }

    fn computeId(kind: Kind, v: Value, gpa: Allocator) !ObjectId {
        const p = try payload(v, gpa);
        defer gpa.free(p);
        return id_mod.hashObject(kind, p);
    }
};

/// A deterministic ID derived from a label, for building test objects.
fn fakeId(label: []const u8) ObjectId {
    return id_mod.hashObject(.blob, label);
}

const alice: Signature = .{ .name = "Alice Example", .email = "alice@example.com", .time_ms = 1_761_091_200_000, .tz_offset_min = 120 };
const bob: Signature = .{ .name = "Bob", .email = "bob@example.org", .time_ms = 1_761_094_800_123, .tz_offset_min = -300 };
const cid: ChangeId = .{ .bytes = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff } };

fn baseChange(a: Allocator) !Change {
    return .{
        .parents = &.{},
        .tree_terms = try a.dupe(ObjectId, &.{fakeId("empty tree")}),
        .change_id = cid,
        .predecessors = &.{},
        .author = alice,
        .committer = alice,
        .description = "",
        .provenance = null,
        .extra = &.{},
        .sig = null,
    };
}

fn goldenVectors(arena: Allocator) ![]Vector {
    var list: std.ArrayList(Vector) = .empty;
    const Add = struct {
        fn add(l: *std.ArrayList(Vector), a: Allocator, name: []const u8, kind: Kind, v: Vector.Value) !void {
            try l.append(a, .{ .name = name, .kind = kind, .id = try Vector.computeId(kind, v, a), .value = v });
        }
    };
    const add = Add.add;
    try add(&list, arena, "blob-empty", .blob, .{ .bytes = "" });
    try add(&list, arena, "blob-hello", .blob, .{ .bytes = "hello, world\n" });
    try add(&list, arena, "blob-binary", .blob, .{ .bytes = "\x00\x01\x02\xff\xfe" });
    try add(&list, arena, "text-utf8", .text, .{ .bytes = "zigguro \u{2014} ziggurat\n" });
    try add(&list, arena, "tree-empty", .tree, .{ .tree = .{ .entries = &.{} } });
    try add(&list, arena, "tree-files", .tree, .{ .tree = .{ .entries = try arena.dupe(TreeEntry, &.{
        .{ .name = "README.md", .kind = .file, .id = fakeId("readme") },
        .{ .name = "build.zig", .kind = .file, .id = fakeId("build") },
        .{ .name = "run.sh", .kind = .executable, .id = fakeId("run") },
    }) } });
    try add(&list, arena, "tree-git-order", .tree, .{ .tree = .{ .entries = try arena.dupe(TreeEntry, &.{
        .{ .name = "a-b", .kind = .file, .id = fakeId("1") },
        .{ .name = "a.b", .kind = .file, .id = fakeId("2") },
        .{ .name = "a", .kind = .tree, .id = fakeId("3") },
        .{ .name = "a0", .kind = .file, .id = fakeId("4") },
    }) } });
    try add(&list, arena, "tree-all-kinds", .tree, .{ .tree = .{ .entries = try arena.dupe(TreeEntry, &.{
        .{ .name = "conflicted.txt", .kind = .conflict_marker_file, .id = fakeId("c") },
        .{ .name = "exe", .kind = .executable, .id = fakeId("e") },
        .{ .name = "file", .kind = .file, .id = fakeId("f") },
        .{ .name = "link", .kind = .symlink, .id = fakeId("l") },
        .{ .name = "sub", .kind = .tree, .id = fakeId("s") },
        .{ .name = "vendor", .kind = .gitlink, .id = fakeId("v") },
    }) } });
    try add(&list, arena, "tree-unicode-names", .tree, .{ .tree = .{ .entries = try arena.dupe(TreeEntry, &.{
        .{ .name = "CON", .kind = .file, .id = fakeId("con") },
        .{ .name = "caf\u{e9}", .kind = .file, .id = fakeId("cafe") },
        .{ .name = "\u{65e5}\u{672c}", .kind = .tree, .id = fakeId("nihon") },
    }) } });
    try add(&list, arena, "change-root", .change, .{ .change = try baseChange(arena) });
    var c = try baseChange(arena);
    c.parents = try arena.dupe(ObjectId, &.{fakeId("parent")});
    c.description = "feat: add the store\n\nWith a body.\n";
    c.committer = bob;
    try add(&list, arena, "change-described", .change, .{ .change = c });
    c.parents = try arena.dupe(ObjectId, &.{ fakeId("p1"), fakeId("p2"), fakeId("p3") });
    try add(&list, arena, "change-octopus", .change, .{ .change = c });
    c = try baseChange(arena);
    c.parents = try arena.dupe(ObjectId, &.{ fakeId("left"), fakeId("right") });
    c.tree_terms = try arena.dupe(ObjectId, &.{ fakeId("side a"), fakeId("base"), fakeId("side b") });
    try add(&list, arena, "change-conflicted", .change, .{ .change = c });
    c = try baseChange(arena);
    c.parents = try arena.dupe(ObjectId, &.{fakeId("parent")});
    c.predecessors = try arena.dupe(ObjectId, &.{ fakeId("old 1"), fakeId("old 2") });
    c.provenance = fakeId("manifest");
    try add(&list, arena, "change-rewritten-with-provenance", .change, .{ .change = c });
    c = try baseChange(arena);
    c.parents = try arena.dupe(ObjectId, &.{fakeId("parent")});
    c.extra = try arena.dupe(object.Extra, &.{ .{ .key = "gpgsig-mode", .value = "none" }, .{ .key = "x-lane", .value = "agent-3" } });
    c.sig = .{ .format = "sshsig", .data = "-----BEGIN SSH SIGNATURE-----\nAAAA\n-----END SSH SIGNATURE-----\n" };
    try add(&list, arena, "change-extra-and-sig", .change, .{ .change = c });
    try add(&list, arena, "chunked-two", .chunked_blob, .{ .chunked_blob = .{ .total_size = (1 << 20) + 700_000, .chunks = try arena.dupe(object.Chunk, &.{
        .{ .id = fakeId("chunk 1"), .size = 1 << 20 },
        .{ .id = fakeId("chunk 2"), .size = 700_000 },
    }) } });
    try add(&list, arena, "operation-opaque", .operation, .{ .bytes = "\x01op" });
    try add(&list, arena, "view-opaque", .view, .{ .bytes = "\x01view" });
    try add(&list, arena, "attribution-opaque", .attribution, .{ .bytes = "\x01attr" });
    try add(&list, arena, "prov-record-opaque", .prov_record, .{ .bytes = "\x01prov" });
    return list.items;
}

fn renderVectors(gpa: Allocator, vectors: []const Vector) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try std.json.Stringify.value(vectors, .{ .whitespace = .indent_2 }, &aw.writer);
    try aw.writer.writeByte('\n');
    return aw.toOwnedSlice();
}

const golden_path = "testdata/objects/vectors.json";

test "encode: golden vectors" {
    const t = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const vectors = try goldenVectors(arena);
    try t.expect(vectors.len >= 20);
    const rendered = try renderVectors(arena, vectors);

    var root = try std.Io.Dir.openDirAbsolute(t.io, options.package_root, .{});
    defer root.close(t.io);
    if (options.update_golden) {
        try root.createDirPath(t.io, "testdata/objects");
        try root.writeFile(t.io, .{ .sub_path = golden_path, .data = rendered });
    }
    const raw = try root.readFileAlloc(t.io, golden_path, arena, .limited(1 << 20));
    const golden = try std.mem.replaceOwned(u8, arena, raw, "\r\n", "\n");
    try t.expectEqualStrings(golden, rendered);

    // The checked-in file alone pins the IDs: parse it and re-hash.
    const parsed = try enc.fromJson([]Vector, arena, golden);
    try t.expectEqual(vectors.len, parsed.len);
    for (parsed) |v| {
        const got = try Vector.computeId(v.kind, v.value, arena);
        if (!got.eql(v.id)) {
            std.debug.print("golden vector {s}: id {f}, file says {f}\n", .{ v.name, got, v.id });
            return error.TestUnexpectedResult;
        }
    }
}

fn randomBytes(r: std.Random, arena: Allocator, max: usize) ![]u8 {
    const b = try arena.alloc(u8, r.uintAtMost(usize, max));
    r.bytes(b);
    return b;
}

fn randomId(r: std.Random) ObjectId {
    var id: ObjectId = undefined;
    r.bytes(&id.bytes);
    return id;
}

fn randomName(r: std.Random, arena: Allocator) ![]u8 {
    while (true) {
        const n = try arena.alloc(u8, 1 + r.uintLessThan(usize, 12));
        for (n) |*c| c.* = switch (r.uintLessThan(u8, 4)) {
            0 => '.',
            1 => '-',
            else => 'a' + r.uintLessThan(u8, 6),
        };
        if (object.validName(n)) return n;
    }
}

fn randomTree(r: std.Random, arena: Allocator) !Tree {
    var entries: std.ArrayList(TreeEntry) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    const n = r.uintAtMost(usize, 40);
    for (0..n) |_| {
        const name = try randomName(r, arena);
        if ((try seen.getOrPut(arena, name)).found_existing) continue;
        try entries.append(arena, .{ .name = name, .kind = r.enumValue(object.EntryKind), .id = randomId(r) });
    }
    Tree.sort(entries.items);
    return .{ .entries = entries.items };
}

fn randomIds(r: std.Random, arena: Allocator, n: usize) ![]ObjectId {
    const ids = try arena.alloc(ObjectId, n);
    for (ids) |*id| id.* = randomId(r);
    return ids;
}

fn randomSig(r: std.Random, arena: Allocator) !Signature {
    return .{ .name = try randomBytes(r, arena, 20), .email = try randomBytes(r, arena, 20), .time_ms = r.int(i64), .tz_offset_min = r.int(i16) };
}

fn randomChange(r: std.Random, arena: Allocator) !Change {
    const extra = try arena.alloc(object.Extra, r.uintAtMost(usize, 4));
    for (extra, 0..) |*e, i| e.* = .{ .key = try std.fmt.allocPrint(arena, "k{d}", .{i}), .value = try randomBytes(r, arena, 30) };
    var cid_r: ChangeId = undefined;
    r.bytes(&cid_r.bytes);
    return .{
        .parents = try randomIds(r, arena, r.uintAtMost(usize, 3)),
        .tree_terms = try randomIds(r, arena, 1 + 2 * r.uintAtMost(usize, 2)),
        .change_id = cid_r,
        .predecessors = try randomIds(r, arena, r.uintAtMost(usize, 2)),
        .author = try randomSig(r, arena),
        .committer = try randomSig(r, arena),
        .description = try randomBytes(r, arena, 200),
        .provenance = if (r.boolean()) randomId(r) else null,
        .extra = extra,
        .sig = if (r.boolean()) .{ .format = "sshsig", .data = try randomBytes(r, arena, 100) } else null,
    };
}

fn randomChunked(r: std.Random, arena: Allocator) !ChunkedBlob {
    const chunks = try arena.alloc(object.Chunk, 1 + r.uintAtMost(usize, 8));
    var total: u64 = 0;
    for (chunks) |*c| {
        c.* = .{ .id = randomId(r), .size = 1 + r.int(u32) / 2 };
        total += c.size;
    }
    return .{ .total_size = total, .chunks = chunks };
}

fn roundtrip(comptime T: type, gpa: Allocator, v: T) !void {
    const t = std.testing;
    const bytes = try enc.encodeAlloc(gpa, T, v);
    defer gpa.free(bytes);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const back = try enc.decode(T, arena_state.allocator(), bytes);
    try t.expectEqualDeep(v, back);
    const again = try enc.encodeAlloc(gpa, T, back);
    defer gpa.free(again);
    try t.expectEqualSlices(u8, bytes, again);
}

test "encode: roundtrip random" {
    const t = std.testing;
    var prng: std.Random.DefaultPrng = .init(t.random_seed);
    const r = prng.random();
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    for (0..10_000) |i| {
        _ = arena_state.reset(.retain_capacity);
        const a = arena_state.allocator();
        switch (i % 3) {
            0 => try roundtrip(Tree, t.allocator, try randomTree(r, a)),
            1 => try roundtrip(Change, t.allocator, try randomChange(r, a)),
            else => try roundtrip(ChunkedBlob, t.allocator, try randomChunked(r, a)),
        }
    }
}

test "decode: rejects non-canonical" {
    const t = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const z = ObjectId.zero;
    // Encode a sorted tree, then swap the names to unsort it.
    const good: Tree = .{ .entries = &.{ .{ .name = "a", .kind = .file, .id = z }, .{ .name = "b", .kind = .file, .id = z } } };
    const bytes = try enc.encodeAlloc(a, Tree, good);
    _ = try enc.decode(Tree, a, bytes);
    const swapped = try a.dupe(u8, bytes);
    // Layout: [ver][count][ver][len=1]['a']... the names sit at 4 and 4+36.
    try t.expectEqual(@as(u8, 'a'), swapped[4]);
    swapped[4] = 'b';
    swapped[4 + 36] = 'a';
    try t.expectError(error.UnsortedEntries, enc.decode(Tree, a, swapped));
    // Trailing bytes.
    const trailing = try std.mem.concat(a, u8, &.{ bytes, "\x00" });
    try t.expectError(error.TrailingBytes, enc.decode(Tree, a, trailing));
    // Overlong varint for the entry count (2 as 0x82 0x00).
    const overlong = try std.mem.concat(a, u8, &.{ bytes[0..1], "\x82\x00", bytes[2..] });
    try t.expectError(error.NonCanonicalVarint, enc.decode(Tree, a, overlong));
    // Unknown version, unknown entry kind, a count larger than the input.
    try t.expectError(error.UnsupportedVersion, enc.decode(Tree, a, "\x02\x00"));
    const bad_kind = try a.dupe(u8, bytes);
    bad_kind[5] = 9;
    try t.expectError(error.InvalidTag, enc.decode(Tree, a, bad_kind));
    try t.expectError(error.TooManyElements, enc.decode(Tree, a, "\x01\xff\xff\xff\xff\x0f"));
    try t.expectError(error.Truncated, enc.decode(Tree, a, bytes[0 .. bytes.len - 1]));
    // A presence byte other than 0 or 1.
    var c = try baseChange(a);
    c.provenance = z;
    const cb = try a.dupe(u8, try enc.encodeAlloc(a, Change, c));
    const pres = std.mem.indexOf(u8, cb, &([_]u8{1} ++ z.bytes)).?;
    cb[pres] = 2;
    try t.expectError(error.InvalidBool, enc.decode(Change, a, cb));
    // Invalid values cannot be encoded either.
    c.tree_terms = &.{};
    try t.expectError(error.InvalidTreeTerms, enc.encodeAlloc(a, Change, c));
}

test "decode: arena stays within 2x the input" {
    const t = std.testing;
    var prng: std.Random.DefaultPrng = .init(7);
    const r = prng.random();
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // A 10k-entry tree with one-byte-or-longer names, and a merge change.
    const entries = try a.alloc(TreeEntry, 10_000);
    for (entries, 0..) |*e, i| e.* = .{ .name = try std.fmt.allocPrint(a, "{d}", .{i}), .kind = .file, .id = randomId(r) };
    Tree.sort(entries);
    var c = try baseChange(a);
    c.parents = try randomIds(r, a, 8);
    c.tree_terms = try randomIds(r, a, 5);
    c.predecessors = try randomIds(r, a, 3);
    inline for (.{ .{ Tree, Tree{ .entries = entries } }, .{ Change, c } }) |pair| {
        const bytes = try enc.encodeAlloc(t.allocator, pair[0], pair[1]);
        defer t.allocator.free(bytes);
        const buf = try t.allocator.alloc(u8, 2 * bytes.len);
        defer t.allocator.free(buf);
        var fba: std.heap.FixedBufferAllocator = .init(buf);
        _ = try enc.decode(pair[0], fba.allocator(), bytes);
    }
}

test "json: toJson/fromJson round trip" {
    const t = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var c = try baseChange(a);
    c.description = "binary \xff\x00 survives";
    var aw: std.Io.Writer.Allocating = .init(a);
    try enc.toJson(Change, c, &aw.writer);
    const back = try enc.fromJson(Change, a, aw.written());
    try t.expectEqualDeep(c, back);
}

fn fuzzOne(comptime T: type, input: []const u8) !void {
    const t = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const v = enc.decode(T, arena_state.allocator(), input) catch return;
    // Canonical: whatever decodes re-encodes to exactly the input.
    const again = try enc.encodeAlloc(t.allocator, T, v);
    defer t.allocator.free(again);
    try t.expectEqualSlices(u8, input, again);
}

test "fuzz: scm-decode" {
    try std.testing.fuzz({}, struct {
        fn one(_: void, s: *std.testing.Smith) anyerror!void {
            var buf: [4096]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            if (input.len == 0) return;
            const rest = input[1..];
            switch (input[0] % 3) {
                0 => try fuzzOne(Tree, rest),
                1 => try fuzzOne(Change, rest),
                else => try fuzzOne(ChunkedBlob, rest),
            }
        }
    }.one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "scm-decode") });
}

test "decode: fuzz seeds are canonical" {
    const t = std.testing;
    const seeds = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "scm-decode");
    try t.expect(seeds.len >= 4);
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    for (seeds) |seed| {
        const rest = seed[1..];
        const again = switch (seed[0] % 3) {
            0 => try enc.encodeAlloc(t.allocator, Tree, try enc.decode(Tree, arena_state.allocator(), rest)),
            1 => try enc.encodeAlloc(t.allocator, Change, try enc.decode(Change, arena_state.allocator(), rest)),
            else => try enc.encodeAlloc(t.allocator, ChunkedBlob, try enc.decode(ChunkedBlob, arena_state.allocator(), rest)),
        };
        defer t.allocator.free(again);
        try t.expectEqualSlices(u8, rest, again);
    }
}
