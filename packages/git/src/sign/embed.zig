//! Where signatures live in git objects (gitformat-signature): the
//! `gpgsig` (or, in SHA-256 repositories, `gpgsig-sha256`) commit header
//! with continuation lines, and the signature appended to a tag's
//! message.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ObjectFormat = @import("../oid.zig").ObjectFormat;

/// The header a repository's native signature goes in.
pub fn headerName(fmt: ObjectFormat) []const u8 {
    return if (fmt == .sha256) "gpgsig-sha256" else "gpgsig";
}

fn endOfHeaders(raw: []const u8) usize {
    return if (std.mem.indexOf(u8, raw, "\n\n")) |i| i + 1 else raw.len;
}

pub const Split = struct {
    /// The object without signature headers: what was signed.
    payload: []u8,
    /// The native signature with its line breaks, if there is one.
    signature: ?[]u8,

    pub fn deinit(s: *Split, gpa: Allocator) void {
        gpa.free(s.payload);
        if (s.signature) |sig| gpa.free(sig);
    }
};

/// Splits a raw commit into its signed payload and its signature.
/// Both `gpgsig` and `gpgsig-sha256` headers leave the payload.
pub fn splitCommit(gpa: Allocator, raw: []const u8, fmt: ObjectFormat) !Split {
    const eoh = endOfHeaders(raw);
    var payload: std.ArrayList(u8) = .empty;
    errdefer payload.deinit(gpa);
    var sig: std.ArrayList(u8) = .empty;
    errdefer sig.deinit(gpa);
    var found = false;
    const want = headerName(fmt);
    var in_sig = false;
    var skipping = false;
    var pos: usize = 0;
    while (pos < eoh) {
        const nl = std.mem.indexOfScalarPos(u8, raw, pos, '\n') orelse eoh - 1;
        const line = raw[pos .. nl + 1];
        pos = nl + 1;
        if (line[0] == ' ' and skipping) {
            if (in_sig) try sig.appendSlice(gpa, line[1..]);
            continue;
        }
        skipping = false;
        in_sig = false;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
        const name = line[0..sp];
        if (std.mem.eql(u8, name, "gpgsig") or std.mem.eql(u8, name, "gpgsig-sha256")) {
            skipping = true;
            if (std.mem.eql(u8, name, want) and !found) {
                found = true;
                in_sig = true;
                try sig.appendSlice(gpa, line[@min(line.len, sp + 1)..]);
            }
            continue;
        }
        try payload.appendSlice(gpa, line);
    }
    try payload.appendSlice(gpa, raw[eoh..]);
    return .{
        .payload = try payload.toOwnedSlice(gpa),
        .signature = if (found) try sig.toOwnedSlice(gpa) else blk: {
            sig.deinit(gpa);
            break :blk null;
        },
    };
}

/// Adds `armored` to an unsigned commit as the `header` header, at the
/// end of the headers as git does.
pub fn embedCommit(gpa: Allocator, raw: []const u8, armored: []const u8, header: []const u8) ![]u8 {
    const eoh = endOfHeaders(raw);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, raw[0..eoh]);
    try out.appendSlice(gpa, header);
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, armored, "\n"), '\n');
    while (it.next()) |l| {
        try out.append(gpa, ' ');
        try out.appendSlice(gpa, l);
        try out.append(gpa, '\n');
    }
    try out.appendSlice(gpa, raw[eoh..]);
    return out.toOwnedSlice(gpa);
}

/// Splits a raw tag at its trailing signature: the payload is the tag up
/// to the signature, which starts a line of the message.
pub fn splitTag(raw: []const u8) struct { payload: []const u8, signature: ?[]const u8 } {
    const eoh = endOfHeaders(raw);
    const markers = [_][]const u8{ "-----BEGIN SSH SIGNATURE-----", "-----BEGIN PGP SIGNATURE-----", "-----BEGIN SIGNED MESSAGE-----" };
    var best: ?usize = null;
    for (markers) |m| {
        var from = eoh;
        while (std.mem.indexOfPos(u8, raw, from, m)) |i| : (from = i + 1) {
            if (i == eoh or raw[i - 1] == '\n') {
                if (best == null or i < best.?) best = i;
                break;
            }
        }
    }
    const at = best orelse return .{ .payload = raw, .signature = null };
    return .{ .payload = raw[0..at], .signature = raw[at..] };
}

test "commit signature round trip" {
    const gpa = std.testing.allocator;
    const raw = "tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\nauthor A <a> 1 +0000\ncommitter C <c> 1 +0000\n\nmsg\n";
    const armored = "-----BEGIN SSH SIGNATURE-----\nAAAA\nBBBB\n-----END SSH SIGNATURE-----\n";
    const signed = try embedCommit(gpa, raw, armored, "gpgsig");
    defer gpa.free(signed);
    try std.testing.expectEqualStrings("tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\nauthor A <a> 1 +0000\ncommitter C <c> 1 +0000\n" ++
        "gpgsig -----BEGIN SSH SIGNATURE-----\n AAAA\n BBBB\n -----END SSH SIGNATURE-----\n\nmsg\n", signed);
    var s = try splitCommit(gpa, signed, .sha1);
    defer s.deinit(gpa);
    try std.testing.expectEqualStrings(raw, s.payload);
    try std.testing.expectEqualStrings(armored, s.signature.?);

    const tag = "object x\ntype commit\ntag v1\ntagger T <t> 1 +0000\n\nmsg\n-----BEGIN SSH SIGNATURE-----\nAAAA\n-----END SSH SIGNATURE-----\n";
    const t = splitTag(tag);
    try std.testing.expectEqualStrings("object x\ntype commit\ntag v1\ntagger T <t> 1 +0000\n\nmsg\n", t.payload);
}
