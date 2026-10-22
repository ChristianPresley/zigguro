//! Annotated tag objects, including the boundary between the signed payload
//! and the trailing PGP, SSH or X.509 signature.

const std = @import("std");
const oid_mod = @import("oid.zig");
const commit = @import("commit.zig");
const ObjectType = @import("object.zig").ObjectType;
const Oid = oid_mod.Oid;
const ObjectFormat = oid_mod.ObjectFormat;
const Allocator = std.mem.Allocator;

/// A parsed tag. Slices borrow from the parsed data or the arena.
pub const Tag = struct {
    /// Tagged object.
    object: Oid,
    /// Type of the tagged object.
    type: ObjectType,
    /// Tag name.
    name: []const u8,
    /// Tagger; absent in some very old tags.
    tagger: ?commit.Ident,
    /// Headers after the tagger, in order.
    extra_headers: []const commit.Header = &.{},
    /// Message after the blank line, including any trailing signature.
    message: []const u8,
    /// True when the object ends after the headers without a blank line.
    no_separator: bool = false,
};

/// Line prefixes that start a tag signature (gitformat-signature).
pub const signature_markers = [_][]const u8{
    "-----BEGIN PGP SIGNATURE-----",
    "-----BEGIN PGP MESSAGE-----",
    "-----BEGIN SSH SIGNATURE-----",
    "-----BEGIN SIGNED MESSAGE-----",
};

/// Parses a tag object.
pub fn parseTag(arena: Allocator, fmt: ObjectFormat, data: []const u8) commit.ParseError!Tag {
    var it: commit.HeaderIterator = .{ .data = data };
    const h1 = (try it.next()) orelse return error.CorruptObject;
    if (!std.mem.eql(u8, h1.key, "object")) return error.CorruptObject;
    const object = Oid.parseHex(fmt, h1.value) catch return error.CorruptObject;
    const h2 = (try it.next()) orelse return error.CorruptObject;
    if (!std.mem.eql(u8, h2.key, "type")) return error.CorruptObject;
    const t = ObjectType.fromName(h2.value) orelse return error.CorruptObject;
    const h3 = (try it.next()) orelse return error.CorruptObject;
    if (!std.mem.eql(u8, h3.key, "tag") or std.mem.indexOfScalar(u8, h3.value, '\n') != null) return error.CorruptObject;
    var tagger: ?commit.Ident = null;
    var extra: std.ArrayList(commit.Header) = .empty;
    if (try it.next()) |h4| {
        if (std.mem.eql(u8, h4.key, "tagger") and std.mem.indexOfScalar(u8, h4.value, '\n') == null) {
            tagger = try commit.Ident.parse(arena, h4.value);
        } else {
            try extra.append(arena, h4);
        }
        while (try it.next()) |x| try extra.append(arena, x);
    }
    return .{
        .object = object,
        .type = t,
        .name = h3.value,
        .tagger = tagger,
        .extra_headers = extra.items,
        .message = it.rest(),
        .no_separator = !it.saw_separator,
    };
}

/// Serializes a tag; byte-identical to the input for parsed tags.
pub fn serializeTag(tg: *const Tag, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var buf: [64]u8 = undefined;
    try w.print("object {s}\ntype {s}\ntag {s}\n", .{ tg.object.hex(&buf), tg.type.name(), tg.name });
    if (tg.tagger) |id| {
        try w.writeAll("tagger ");
        try id.write(w);
        try w.writeByte('\n');
    }
    for (tg.extra_headers) |h| try w.print("{s} {s}\n", .{ h.key, h.value });
    if (!tg.no_separator) try w.writeByte('\n');
    try w.writeAll(tg.message);
}

/// Offset in `data` (a whole tag object) where the signature starts: the
/// last line beginning with a signature marker. `data[0..off]` is the
/// signed payload.
pub fn signatureOffset(data: []const u8) ?usize {
    var found: ?usize = null;
    var pos: usize = 0;
    while (pos < data.len) {
        const end = if (std.mem.indexOfScalarPos(u8, data, pos, '\n')) |e| e + 1 else data.len;
        for (signature_markers) |m| {
            if (std.mem.startsWith(u8, data[pos..end], m)) found = pos;
        }
        pos = end;
    }
    return found;
}

test "tag: signature boundary" {
    const t = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const data =
        "object ce013625030ba8dba906f756967f9e9ca394464a\n" ++
        "type commit\n" ++
        "tag v1.0\n" ++
        "tagger T <t@example.com> 1700000000 +0000\n" ++
        "\nRelease 1.0\n" ++
        "-----BEGIN SSH SIGNATURE-----\nU1NIU0lH\n-----END SSH SIGNATURE-----\n";
    const tg = try parseTag(arena_state.allocator(), .sha1, data);
    try t.expectEqualStrings("v1.0", tg.name);
    try t.expectEqual(ObjectType.commit, tg.type);
    try t.expectEqualStrings("T", tg.tagger.?.name);
    const off = signatureOffset(data).?;
    try t.expect(std.mem.endsWith(u8, data[0..off], "Release 1.0\n"));
    try t.expect(std.mem.startsWith(u8, data[off..], "-----BEGIN SSH SIGNATURE-----"));

    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    try serializeTag(&tg, &aw.writer);
    try t.expectEqualStrings(data, aw.written());
    try t.expect(signatureOffset("object x\n\nunsigned\n") == null);
}
