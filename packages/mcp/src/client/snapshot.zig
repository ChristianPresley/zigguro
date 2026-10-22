//! Tool catalog snapshots (E11.F03.S01.T02): the host persists catalogs so
//! a restart lists a server's tools before the server is even connected.
//!
//! JSON Lines: a header, then one tool definition per line, as the server
//! sent it:
//!
//! ```
//! {"zgCatalog":1,"kind":"tools","serverInfo":{...},"revision":"2026-07-28","fetchedAtMs":...,"ttlMs":...,"scope":"public","complete":true,"fingerprints":["9f0c...",...]}
//! {"name":"read_file","inputSchema":{...}}
//! ```
//!
//! Decoding runs the hygiene checks but leaves schemas uncompiled; they
//! compile on first use (`Catalog.inputSchema`). A `private` catalog's
//! file name carries its auth context (`fileName`), so it is never read
//! for another user or workspace.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const protocol = @import("../protocol/root.zig");
const catalog = @import("catalog.zig");

const M = protocol.messages;
const Catalog = catalog.Catalog;

pub const format_version = 1;

/// What the header records besides the catalog.
pub const Header = struct {
    server_info: ?M.Implementation = null,
    revision: ?[]const u8 = null,
};

/// Writes `cat` (a tool catalog).
pub fn encodeSnapshot(w: *Io.Writer, cat: *const Catalog, h: Header) Io.Writer.Error!void {
    std.debug.assert(cat.kind == .tools);
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("zgCatalog");
    try s.write(format_version);
    try s.objectField("kind");
    try s.write("tools");
    if (h.server_info) |info| {
        try s.objectField("serverInfo");
        try protocol.codec.encodeValue(&s, info);
    }
    if (h.revision) |r| {
        try s.objectField("revision");
        try s.write(r);
    }
    try s.objectField("version");
    try s.write(cat.version);
    try s.objectField("fetchedAtMs");
    try s.write(cat.fetched_at_ms);
    if (cat.fresh_until_ms) |u| {
        try s.objectField("freshUntilMs");
        try s.write(u);
    }
    try s.objectField("scope");
    try s.write(@tagName(cat.scope));
    try s.objectField("complete");
    try s.write(cat.complete);
    try s.objectField("fingerprints");
    try s.beginArray();
    var buf: [16]u8 = undefined;
    for (cat.prints) |p| try s.write(std.fmt.bufPrint(&buf, "{x:0>16}", .{p}) catch unreachable);
    try s.endArray();
    try s.endObject();
    try w.writeByte('\n');
    for (cat.entries) |e| {
        try protocol.codec.encode(w, e.def);
        try w.writeByte('\n');
    }
}

pub const DecodeError = error{ OutOfMemory, InvalidSnapshot, UnsupportedVersion, ReadFailed, StreamTooLong };

/// Reads a snapshot written by `encodeSnapshot`. The catalog has one
/// reference (the caller's, or `CatalogStore.adopt`'s).
pub fn decodeSnapshot(gpa: Allocator, io: Io, r: *Io.Reader) DecodeError!*Catalog {
    const c = try gpa.create(Catalog);
    c.* = .{ .gpa = gpa, .io = io, .arena = .init(gpa), .kind = .tools };
    errdefer {
        c.arena.deinit();
        gpa.destroy(c);
    }
    const a = c.arena.allocator();
    const head_line = (try takeLine(r)) orelse return error.InvalidSnapshot;
    const head = std.json.parseFromSliceLeaky(std.json.Value, a, head_line, .{}) catch return error.InvalidSnapshot;
    if (head != .object) return error.InvalidSnapshot;
    const ver = head.object.get("zgCatalog") orelse return error.InvalidSnapshot;
    if (ver != .integer) return error.InvalidSnapshot;
    if (ver.integer != format_version) return error.UnsupportedVersion;
    c.version = @intCast(intField(head, "version") orelse 0);
    c.fetched_at_ms = intField(head, "fetchedAtMs") orelse 0;
    c.fresh_until_ms = intField(head, "freshUntilMs");
    if (head.object.get("scope")) |sv| if (sv == .string and std.mem.eql(u8, sv.string, "private")) {
        c.scope = .private;
    };
    if (head.object.get("complete")) |cv| if (cv == .bool) {
        c.complete = cv.bool;
    };

    var defs: std.ArrayList(M.Tool) = .empty;
    while (try takeLine(r)) |line| {
        if (line.len == 0) continue;
        // `line` points into the reader's buffer: copy before decoding.
        const owned = try a.dupe(u8, line);
        try defs.append(a, protocol.codec.decodeBytes(M.Tool, a, owned, .{}) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidSnapshot,
        });
    }
    try catalog.fillOpts(c, .{ .tools = defs.items }, .{ .compile = false });
    return c;
}

fn takeLine(r: *Io.Reader) DecodeError!?[]const u8 {
    const line = r.takeDelimiter('\n') catch |e| return switch (e) {
        error.ReadFailed => error.ReadFailed,
        error.StreamTooLong => error.StreamTooLong,
    };
    return line;
}

fn intField(v: std.json.Value, name: []const u8) ?i64 {
    const f = v.object.get(name) orelse return null;
    return if (f == .integer) f.integer else null;
}

/// The snapshot file name for `server_id`: `<server>.tools.jsonl`, or
/// `<server>.tools.<auth context>.jsonl` for a private catalog.
pub fn fileName(buf: []u8, server_id: []const u8, cat: *const Catalog) error{NoSpaceLeft}![]const u8 {
    if (cat.scope == .private)
        return std.fmt.bufPrint(buf, "{s}.{s}.{x:0>16}.jsonl", .{ server_id, @tagName(cat.kind), cat.auth_context orelse 0 });
    return std.fmt.bufPrint(buf, "{s}.{s}.jsonl", .{ server_id, @tagName(cat.kind) });
}
