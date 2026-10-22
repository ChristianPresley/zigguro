//! Commit objects: parse and serialize byte-exactly, keeping signature and
//! unknown headers in order.

const std = @import("std");
const oid_mod = @import("oid.zig");
const Oid = oid_mod.Oid;
const ObjectFormat = oid_mod.ObjectFormat;
const Allocator = std.mem.Allocator;

/// Errors for malformed commits.
pub const ParseError = error{CorruptObject} || Allocator.Error;

/// An author, committer or tagger line: `Name <email> 1700000000 +0100`.
pub const Ident = struct {
    /// Name, without the space before `<`.
    name: []const u8,
    /// Email, without the angle brackets.
    email: []const u8,
    /// Seconds since the epoch.
    time: i64,
    /// Timezone exactly as written, e.g. "+0100".
    tz: []const u8,
    /// The whole line value when it does not have the canonical shape (git
    /// tolerates broken idents in old history). Serialization writes it
    /// verbatim so such objects keep their hash; clear it after editing.
    raw: ?[]const u8 = null,

    /// Parses an ident line value. Never fails: a value that cannot be split
    /// keeps everything in `raw`.
    pub fn parse(arena: Allocator, value: []const u8) Allocator.Error!Ident {
        var id: Ident = .{ .name = "", .email = "", .time = 0, .tz = "", .raw = value };
        const lt = std.mem.indexOfScalar(u8, value, '<') orelse return id;
        const gt = std.mem.indexOfScalarPos(u8, value, lt, '>') orelse return id;
        id.name = std.mem.trimEnd(u8, value[0..lt], " ");
        id.email = value[lt + 1 .. gt];
        const rest = std.mem.trimStart(u8, value[gt + 1 ..], " ");
        if (std.mem.indexOfScalar(u8, rest, ' ')) |sp| {
            id.time = std.fmt.parseInt(i64, rest[0..sp], 10) catch 0;
            id.tz = rest[sp + 1 ..];
        } else {
            id.time = std.fmt.parseInt(i64, rest, 10) catch 0;
        }
        var aw: std.Io.Writer.Allocating = .init(arena);
        defer aw.deinit();
        var canon = id;
        canon.raw = null;
        canon.write(&aw.writer) catch return error.OutOfMemory;
        if (std.mem.eql(u8, aw.written(), value)) id.raw = null;
        return id;
    }

    /// Writes the line value (without the "author " key or newline).
    pub fn write(id: Ident, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (id.raw) |r| return w.writeAll(r);
        try w.print("{s} <{s}> {d} {s}", .{ id.name, id.email, id.time, id.tz });
    }
};

/// A header line. `value` keeps continuation lines verbatim, joined by
/// "\n " exactly as stored (gpgsig, mergetag).
pub const Header = struct {
    /// Header name, e.g. "gpgsig".
    key: []const u8,
    /// Header value, possibly multi-line.
    value: []const u8,
};

/// A parsed commit. Slices borrow from the parsed data or the arena.
pub const Commit = struct {
    /// Root tree.
    tree: Oid,
    /// Parents in order.
    parents: []const Oid,
    /// Author.
    author: Ident,
    /// Committer.
    committer: Ident,
    /// `encoding` header value, when present.
    encoding: ?[]const u8 = null,
    /// How many `extra_headers` precede `encoding` (0 is git's own order).
    encoding_pos: usize = 0,
    /// Other headers in order: gpgsig, gpgsig-sha256, mergetag, change-id and
    /// unknown ones.
    extra_headers: []const Header = &.{},
    /// Message after the blank line.
    message: []const u8,
    /// True when the object ends after the headers without a blank line.
    no_separator: bool = false,

    /// First header with this key, if any.
    pub fn header(c: *const Commit, key: []const u8) ?[]const u8 {
        for (c.extra_headers) |h| if (std.mem.eql(u8, h.key, key)) return h.value;
        return null;
    }
};

/// Splits the next header line ("key value", plus continuation lines) off
/// `data[pos..]`. Returns null at the blank line or end of data.
pub const HeaderIterator = struct {
    data: []const u8,
    pos: usize = 0,
    /// Set once the separating blank line was consumed.
    saw_separator: bool = false,

    /// Next header, or null when the header block ends.
    pub fn next(it: *HeaderIterator) error{CorruptObject}!?Header {
        const d = it.data;
        if (it.pos >= d.len) return null;
        if (d[it.pos] == '\n') {
            it.pos += 1;
            it.saw_separator = true;
            return null;
        }
        var end = std.mem.indexOfScalarPos(u8, d, it.pos, '\n') orelse return error.CorruptObject;
        while (end + 1 < d.len and d[end + 1] == ' ') {
            end = std.mem.indexOfScalarPos(u8, d, end + 1, '\n') orelse return error.CorruptObject;
        }
        const line = d[it.pos..end];
        it.pos = end + 1;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return error.CorruptObject;
        if (sp == 0) return error.CorruptObject;
        return .{ .key = line[0..sp], .value = line[sp + 1 ..] };
    }

    /// Everything after the header block.
    pub fn rest(it: *const HeaderIterator) []const u8 {
        return it.data[it.pos..];
    }
};

fn singleLine(h: Header) error{CorruptObject}![]const u8 {
    if (std.mem.indexOfScalar(u8, h.value, '\n') != null) return error.CorruptObject;
    return h.value;
}

/// Parses a commit. `arena` holds the parents and headers lists; strings
/// borrow from `data`.
pub fn parseCommit(arena: Allocator, fmt: ObjectFormat, data: []const u8) ParseError!Commit {
    var it: HeaderIterator = .{ .data = data };
    const first = (try it.next()) orelse return error.CorruptObject;
    if (!std.mem.eql(u8, first.key, "tree")) return error.CorruptObject;
    const tree = Oid.parseHex(fmt, try singleLine(first)) catch return error.CorruptObject;

    var parents: std.ArrayList(Oid) = .empty;
    var h = (try it.next()) orelse return error.CorruptObject;
    while (std.mem.eql(u8, h.key, "parent")) {
        try parents.append(arena, Oid.parseHex(fmt, try singleLine(h)) catch return error.CorruptObject);
        h = (try it.next()) orelse return error.CorruptObject;
    }
    if (!std.mem.eql(u8, h.key, "author")) return error.CorruptObject;
    const author = try Ident.parse(arena, try singleLine(h));
    h = (try it.next()) orelse return error.CorruptObject;
    if (!std.mem.eql(u8, h.key, "committer")) return error.CorruptObject;
    const committer = try Ident.parse(arena, try singleLine(h));

    var extra: std.ArrayList(Header) = .empty;
    var encoding: ?[]const u8 = null;
    var encoding_pos: usize = 0;
    while (try it.next()) |x| {
        if (encoding == null and std.mem.eql(u8, x.key, "encoding")) {
            encoding = x.value;
            encoding_pos = extra.items.len;
        } else {
            try extra.append(arena, x);
        }
    }
    return .{
        .tree = tree,
        .parents = parents.items,
        .author = author,
        .committer = committer,
        .encoding = encoding,
        .encoding_pos = encoding_pos,
        .extra_headers = extra.items,
        .message = it.rest(),
        .no_separator = !it.saw_separator,
    };
}

fn writeHeader(w: *std.Io.Writer, key: []const u8, value: []const u8) std.Io.Writer.Error!void {
    try w.writeAll(key);
    try w.writeByte(' ');
    try w.writeAll(value);
    try w.writeByte('\n');
}

/// Serializes a commit. Byte-identical to the input for parsed commits.
pub fn serializeCommit(c: *const Commit, w: *std.Io.Writer) std.Io.Writer.Error!void {
    var buf: [64]u8 = undefined;
    try writeHeader(w, "tree", c.tree.hex(&buf));
    for (c.parents) |p| try writeHeader(w, "parent", p.hex(&buf));
    try w.writeAll("author ");
    try c.author.write(w);
    try w.writeAll("\ncommitter ");
    try c.committer.write(w);
    try w.writeByte('\n');
    for (c.extra_headers, 0..) |h, i| {
        if (c.encoding != null and i == c.encoding_pos) try writeHeader(w, "encoding", c.encoding.?);
        try writeHeader(w, h.key, h.value);
    }
    if (c.encoding != null and c.encoding_pos >= c.extra_headers.len) try writeHeader(w, "encoding", c.encoding.?);
    if (!c.no_separator) try w.writeByte('\n');
    try w.writeAll(c.message);
}

/// Splits a signed commit into the signature (gpgsig or gpgsig-sha256 for
/// `fmt`, unfolded) and the payload that was signed (the commit without
/// that header), as `git verify-commit` does.
pub fn signedPayload(arena: Allocator, fmt: ObjectFormat, data: []const u8) ParseError!?struct { signature: []const u8, payload: []const u8 } {
    const key = switch (fmt) {
        .sha1 => "gpgsig",
        .sha256 => "gpgsig-sha256",
    };
    var it: HeaderIterator = .{ .data = data };
    while (true) {
        const start = it.pos;
        const h = (try it.next()) orelse return null;
        if (!std.mem.eql(u8, h.key, key)) continue;
        const payload = try std.mem.concat(arena, u8, &.{ data[0..start], data[it.pos..] });
        const sig = try std.mem.replaceOwned(u8, arena, h.value, "\n ", "\n");
        return .{ .signature = sig, .payload = payload };
    }
}

test "commit: parse and serialize roundtrip" {
    const t = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const data =
        "tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\n" ++
        "parent ce013625030ba8dba906f756967f9e9ca394464a\n" ++
        "author A U Thor <author@example.com> 1700000000 +0100\n" ++
        "committer C O Mitter <c@example.com> 1700000001 -0730\n" ++
        "encoding ISO-8859-1\n" ++
        "gpgsig -----BEGIN PGP SIGNATURE-----\n \n abc\n -----END PGP SIGNATURE-----\n" ++
        "\nsubject\n\nbody\n";
    const c = try parseCommit(arena, .sha1, data);
    try t.expectEqual(@as(usize, 1), c.parents.len);
    try t.expectEqualStrings("A U Thor", c.author.name);
    try t.expectEqualStrings("author@example.com", c.author.email);
    try t.expectEqual(@as(i64, 1700000000), c.author.time);
    try t.expectEqualStrings("-0730", c.committer.tz);
    try t.expect(c.author.raw == null);
    try t.expectEqualStrings("ISO-8859-1", c.encoding.?);
    try t.expectEqualStrings("subject\n\nbody\n", c.message);
    try t.expect(std.mem.startsWith(u8, c.header("gpgsig").?, "-----BEGIN PGP SIGNATURE-----\n \n abc"));

    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    try serializeCommit(&c, &aw.writer);
    try t.expectEqualStrings(data, aw.written());

    const sp = (try signedPayload(arena, .sha1, data)).?;
    try t.expectEqualStrings("-----BEGIN PGP SIGNATURE-----\n\nabc\n-----END PGP SIGNATURE-----", sp.signature);
    try t.expect(std.mem.indexOf(u8, sp.payload, "gpgsig") == null);
    try t.expect(std.mem.endsWith(u8, sp.payload, "encoding ISO-8859-1\n\nsubject\n\nbody\n"));
}

test "commit: broken idents keep their bytes" {
    const t = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const data =
        "tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\n" ++
        "author Nobody <x@y>  1112911993 -0700 extra\n" ++
        "committer no-angle-brackets\n" ++
        "change-id zzzz\n";
    const c = try parseCommit(arena_state.allocator(), .sha1, data);
    try t.expect(c.author.raw != null);
    try t.expect(c.committer.raw != null);
    try t.expect(c.no_separator);
    var aw: std.Io.Writer.Allocating = .init(t.allocator);
    defer aw.deinit();
    try serializeCommit(&c, &aw.writer);
    try t.expectEqualStrings(data, aw.written());
}

test "commit: malformed rejected" {
    const t = std.testing;
    var arena_state: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try t.expectError(error.CorruptObject, parseCommit(a, .sha1, ""));
    try t.expectError(error.CorruptObject, parseCommit(a, .sha1, "tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\n\nmsg"));
    try t.expectError(error.CorruptObject, parseCommit(a, .sha256, "tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\nauthor a <b> 1 +0000\ncommitter a <b> 1 +0000\n\n"));
}
