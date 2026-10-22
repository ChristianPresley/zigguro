//! D-Bus messages: the fixed 12-byte prefix, the `a(yv)` header fields,
//! padding to 8 and the body. `write` builds little-endian messages;
//! `frameLen` and `parse` read either byte order and enforce the limits.

const std = @import("std");
const marshal = @import("marshal.zig");
const signature = @import("signature.zig");
const Value = @import("variant.zig").Value;

/// Longest message, header included.
pub const max_message: usize = 128 * 1024 * 1024;

/// Message types.
pub const Type = enum(u8) {
    method_call = 1,
    method_return = 2,
    @"error" = 3,
    signal = 4,
    _,
};

/// Header flags.
pub const Flags = packed struct(u8) {
    no_reply_expected: bool = false,
    no_auto_start: bool = false,
    allow_interactive_authorization: bool = false,
    _pad: u5 = 0,
};

/// Header field codes.
pub const Field = enum(u8) {
    path = 1,
    interface = 2,
    member = 3,
    error_name = 4,
    reply_serial = 5,
    destination = 6,
    sender = 7,
    signature = 8,
    unix_fds = 9,
    _,
};

/// A message header. Strings are views when parsed.
pub const Header = struct {
    type: Type,
    flags: Flags = .{},
    serial: u32,
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    reply_serial: ?u32 = null,
    destination: ?[]const u8 = null,
    sender: ?[]const u8 = null,
    /// The body signature; empty when there is no body.
    signature: []const u8 = "",
    /// How many fds travel with the message.
    unix_fds: u32 = 0,
};

/// A parsed message: the header and a view of the body.
pub const Message = struct {
    header: Header,
    body: []const u8,
    big_endian: bool,

    /// A decoder over the body, allocating containers in `arena`.
    pub fn decoder(m: *const Message, arena: std.mem.Allocator, fds: []const i32) marshal.Decoder {
        // The body starts 8-aligned, so body offsets align like message offsets.
        return .{ .buf = m.body, .big_endian = m.big_endian, .arena = arena, .fds = fds };
    }

    /// Decodes the whole body by its signature.
    pub fn args(m: *const Message, arena: std.mem.Allocator, fds: []const i32) marshal.DecodeError![]Value {
        var d = m.decoder(arena, fds);
        return d.decodeAll(m.header.signature);
    }
};

/// Errors from `parse` and `frameLen`.
pub const ParseError = error{ Malformed, TooLarge };

/// The full length of the message whose first 16 bytes are `fixed`.
pub fn frameLen(fixed: *const [16]u8) ParseError!usize {
    const big = switch (fixed[0]) {
        'l' => false,
        'B' => true,
        else => return error.Malformed,
    };
    if (fixed[3] != 1) return error.Malformed;
    const e: std.builtin.Endian = if (big) .big else .little;
    const body_len = std.mem.readInt(u32, fixed[4..8], e);
    const fields_len = std.mem.readInt(u32, fixed[12..16], e);
    const total = @as(u64, 16) + std.mem.alignForward(u64, fields_len, 8) + body_len;
    if (total > max_message) return error.TooLarge;
    return @intCast(total);
}

/// Parses one complete message occupying all of `buf`.
pub fn parse(buf: []const u8) ParseError!Message {
    if (buf.len < 16) return error.Malformed;
    const total = try frameLen(buf[0..16]);
    if (total != buf.len) return error.Malformed;
    const big = buf[0] == 'B';
    const e: std.builtin.Endian = if (big) .big else .little;
    var h: Header = .{
        .type = @enumFromInt(buf[1]),
        .flags = @bitCast(buf[2]),
        .serial = std.mem.readInt(u32, buf[8..12], e),
    };
    if (h.serial == 0) return error.Malformed;
    const body_len = std.mem.readInt(u32, buf[4..8], e);
    const fields_len = std.mem.readInt(u32, buf[12..16], e);

    // Header fields are a(yv) starting at offset 12; decode them in place
    // without allocating.
    var d: marshal.Decoder = .{ .buf = buf[0 .. 16 + fields_len], .pos = 16, .big_endian = big, .arena = undefined };
    var sig_set = false;
    while (!d.atEnd()) {
        d.alignTo(8) catch return error.Malformed;
        const code: Field = @enumFromInt(d.readInt(u8) catch return error.Malformed);
        const vsig = d.readSignature() catch return error.Malformed;
        const want: u8 = switch (code) {
            .path => 'o',
            .interface, .member, .error_name, .destination, .sender => 's',
            .signature => 'g',
            .reply_serial, .unix_fds => 'u',
            _ => {
                // Unknown fields must be ignored; skip their value.
                try skipValue(&d, vsig);
                continue;
            },
        };
        if (vsig.len != 1 or vsig[0] != want) return error.Malformed;
        switch (code) {
            .path => h.path = d.readObjectPath() catch return error.Malformed,
            .interface => h.interface = d.readString() catch return error.Malformed,
            .member => h.member = d.readString() catch return error.Malformed,
            .error_name => h.error_name = d.readString() catch return error.Malformed,
            .destination => h.destination = d.readString() catch return error.Malformed,
            .sender => h.sender = d.readString() catch return error.Malformed,
            .signature => {
                h.signature = d.readSignature() catch return error.Malformed;
                sig_set = true;
            },
            .reply_serial => h.reply_serial = d.readInt(u32) catch return error.Malformed,
            .unix_fds => h.unix_fds = d.readInt(u32) catch return error.Malformed,
            _ => unreachable,
        }
    }
    const body_at = std.mem.alignForward(usize, 16 + fields_len, 8);
    for (buf[16 + fields_len .. body_at]) |b| if (b != 0) return error.Malformed;
    if (body_len > 0 and !sig_set) return error.Malformed;
    switch (h.type) {
        .method_call => if (h.path == null or h.member == null) return error.Malformed,
        .method_return => if (h.reply_serial == null) return error.Malformed,
        .@"error" => if (h.reply_serial == null or h.error_name == null) return error.Malformed,
        .signal => if (h.path == null or h.interface == null or h.member == null) return error.Malformed,
        _ => {},
    }
    return .{ .header = h, .body = buf[body_at..], .big_endian = big };
}

fn skipValue(d: *marshal.Decoder, vsig: []const u8) ParseError!void {
    signature.validateSingle(vsig) catch return error.Malformed;
    var scratch: [4096]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&scratch);
    d.arena = fba.allocator();
    _ = d.decode(vsig) catch return error.Malformed;
}

/// Appends a little-endian message with `h` and `body` to `out`.
pub fn write(gpa: std.mem.Allocator, out: *std.ArrayList(u8), h: Header, body: []const u8) marshal.EncodeError!void {
    var e: marshal.Encoder = .init(gpa, 0);
    defer e.deinit();
    try e.buf.appendSlice(gpa, &.{ 'l', @intFromEnum(h.type), @bitCast(h.flags), 1 });
    try e.writeInt(u32, @intCast(body.len));
    try e.writeInt(u32, h.serial);
    const m = try e.beginArray(8);
    if (h.path) |p| try field(&e, .path, "o", p);
    if (h.interface) |s| try field(&e, .interface, "s", s);
    if (h.member) |s| try field(&e, .member, "s", s);
    if (h.error_name) |s| try field(&e, .error_name, "s", s);
    if (h.reply_serial) |s| try field(&e, .reply_serial, "u", s);
    if (h.destination) |s| try field(&e, .destination, "s", s);
    if (h.sender) |s| try field(&e, .sender, "s", s);
    if (h.signature.len > 0) try field(&e, .signature, "g", h.signature);
    if (h.unix_fds > 0) try field(&e, .unix_fds, "u", h.unix_fds);
    try e.endArray(m);
    try e.pad(8);
    if (e.buf.items.len + body.len > max_message) return error.TooLarge;
    try out.ensureUnusedCapacity(gpa, e.buf.items.len + body.len);
    out.appendSliceAssumeCapacity(e.buf.items);
    out.appendSliceAssumeCapacity(body);
}

fn field(e: *marshal.Encoder, code: Field, comptime sig: []const u8, v: anytype) marshal.EncodeError!void {
    try e.pad(8);
    try e.writeInt(u8, @intFromEnum(code));
    try e.writeSignature(sig);
    try marshal.encode(e, sig, .{v});
}

const testing = std.testing;

test "header field parsing: write then parse" {
    var body: marshal.Encoder = .init(testing.allocator, 0);
    defer body.deinit();
    try marshal.encode(&body, "su", .{ "org.example", @as(u32, 4) });
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try write(testing.allocator, &out, .{
        .type = .method_call,
        .flags = .{ .no_auto_start = true },
        .serial = 7,
        .path = "/org/freedesktop/DBus",
        .interface = "org.freedesktop.DBus",
        .member = "RequestName",
        .destination = "org.freedesktop.DBus",
        .signature = "su",
    }, body.buf.items);
    try testing.expectEqual(0, (out.items.len - body.buf.items.len) % 8);
    try testing.expectEqual(out.items.len, try frameLen(out.items[0..16]));
    const m = try parse(out.items);
    try testing.expectEqual(Type.method_call, m.header.type);
    try testing.expect(m.header.flags.no_auto_start);
    try testing.expectEqual(7, m.header.serial);
    try testing.expectEqualStrings("RequestName", m.header.member.?);
    try testing.expectEqualStrings("/org/freedesktop/DBus", m.header.path.?);
    try testing.expectEqualStrings("su", m.header.signature);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = try m.args(arena.allocator(), &.{});
    try testing.expectEqualStrings("org.example", a[0].string);
    try testing.expectEqual(4, a[1].u32);
}

test "a big-endian message from the spec layout parses" {
    // A signal with path "/a", interface "b.c", member "D" and no body.
    const msg = [_]u8{
        'B', 4, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0x2a, // fields length 42
        1, 1, 'o', 0, 0, 0, 0, 2, '/', 'a', 0, 0, 0, 0, 0, 0, //
        2, 1, 's', 0, 0, 0, 0, 3, 'b', '.', 'c', 0, 0, 0, 0, 0, //
        3, 1, 's', 0, 0, 0, 0, 1, 'D', 0, 0, 0, 0, 0, 0, 0, // last 6 bytes are padding
    };
    const m = try parse(&msg);
    try testing.expectEqual(Type.signal, m.header.type);
    try testing.expectEqual(1, m.header.serial);
    try testing.expectEqualStrings("/a", m.header.path.?);
    try testing.expectEqualStrings("b.c", m.header.interface.?);
    try testing.expectEqualStrings("D", m.header.member.?);
}

test "parse rejects missing required fields, bad sizes and zero serial" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try write(testing.allocator, &out, .{ .type = .signal, .serial = 1, .path = "/a", .member = "M" }, "");
    try testing.expectError(error.Malformed, parse(out.items));
    out.clearRetainingCapacity();
    try write(testing.allocator, &out, .{ .type = .method_return, .serial = 0, .reply_serial = 1 }, "");
    try testing.expectError(error.Malformed, parse(out.items));
    var big = [_]u8{ 'l', 1, 0, 1, 0, 0, 0, 0x09, 1, 0, 0, 0, 0, 0, 0, 0 };
    try testing.expectError(error.TooLarge, frameLen(&big));
    big[0] = 'x';
    try testing.expectError(error.Malformed, frameLen(&big));
}

test "fuzz: dbus message parse never crashes" {
    try testing.fuzz({}, struct {
        fn one(_: void, sm: *testing.Smith) anyerror!void {
            var buf: [1024]u8 = undefined;
            const input = buf[0..sm.slice(&buf)];
            if (input.len < 16) return;
            const n = frameLen(input[0..16]) catch return;
            if (n > input.len) return;
            const m = parse(input[0..n]) catch return;
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            _ = m.args(arena.allocator(), &.{}) catch return;
        }
    }.one, .{});
}
