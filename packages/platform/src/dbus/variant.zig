//! `Value`: a decoded D-Bus value of any type. Strings and byte arrays are
//! views into the message; containers live in the decoder's arena. Values
//! can be encoded back, which is how dynamic `v` arguments are written.

const std = @import("std");
const signature = @import("signature.zig");
const marshal = @import("marshal.zig");
const Decoder = marshal.Decoder;
const Encoder = marshal.Encoder;

/// Any D-Bus value.
pub const Value = union(enum) {
    byte: u8,
    boolean: bool,
    i16: i16,
    u16: u16,
    i32: i32,
    u32: u32,
    i64: i64,
    u64: u64,
    double: f64,
    string: []const u8,
    object_path: []const u8,
    signature: []const u8,
    unix_fd: i32,
    array: Array,
    structure: []const Value,
    variant: *const Value,
    dict: Dict,

    /// The variant's inner value, or the value itself.
    pub fn unwrap(v: Value) Value {
        return switch (v) {
            .variant => |p| p.*.unwrap(),
            else => v,
        };
    }

    /// The string, object path or signature, through variants.
    pub fn asString(v: Value) ?[]const u8 {
        return switch (v.unwrap()) {
            .string, .object_path, .signature => |s| s,
            else => null,
        };
    }

    /// Any unsigned or non-negative integer as u64, through variants.
    pub fn asU64(v: Value) ?u64 {
        return switch (v.unwrap()) {
            .byte => |x| x,
            .u16 => |x| x,
            .u32 => |x| x,
            .u64 => |x| x,
            .i16 => |x| std.math.cast(u64, x),
            .i32 => |x| std.math.cast(u64, x),
            .i64 => |x| std.math.cast(u64, x),
            else => null,
        };
    }

    /// The boolean, through variants.
    pub fn asBool(v: Value) ?bool {
        return switch (v.unwrap()) {
            .boolean => |b| b,
            else => null,
        };
    }

    /// Writes this value's signature into `out`, returning its length.
    pub fn writeSignature(v: Value, out: []u8) error{InvalidSignature}!usize {
        var n: usize = 0;
        try sigInto(v, out, &n);
        return n;
    }
};

/// An array. For `ay` the elements are the view `bytes` and `items` is
/// empty; otherwise `items` holds them.
pub const Array = struct {
    /// The element signature: one complete type.
    elem_sig: []const u8,
    items: []const Value = &.{},
    bytes: []const u8 = &.{},

    /// The number of elements.
    pub fn len(a: Array) usize {
        return if (isBytes(a.elem_sig)) a.bytes.len else a.items.len;
    }
};

/// A key and value of a `Dict`.
pub const DictEntry = struct { key: Value, value: Value };

/// An array of dict entries, `a{..}`.
pub const Dict = struct {
    /// The key signature: one basic type.
    key_sig: []const u8,
    /// The value signature: one complete type.
    value_sig: []const u8,
    entries: []const DictEntry = &.{},

    /// The value under string key `key`, if any.
    pub fn get(d: Dict, key: []const u8) ?Value {
        for (d.entries) |e| if (e.key.asString()) |k| if (std.mem.eql(u8, k, key)) return e.value;
        return null;
    }
};

fn isBytes(sig: []const u8) bool {
    return sig.len == 1 and sig[0] == 'y';
}

fn put(out: []u8, n: *usize, s: []const u8) error{InvalidSignature}!void {
    if (out.len - n.* < s.len) return error.InvalidSignature;
    @memcpy(out[n.*..][0..s.len], s);
    n.* += s.len;
}

fn sigInto(v: Value, out: []u8, n: *usize) error{InvalidSignature}!void {
    switch (v) {
        .byte => try put(out, n, "y"),
        .boolean => try put(out, n, "b"),
        .i16 => try put(out, n, "n"),
        .u16 => try put(out, n, "q"),
        .i32 => try put(out, n, "i"),
        .u32 => try put(out, n, "u"),
        .i64 => try put(out, n, "x"),
        .u64 => try put(out, n, "t"),
        .double => try put(out, n, "d"),
        .string => try put(out, n, "s"),
        .object_path => try put(out, n, "o"),
        .signature => try put(out, n, "g"),
        .unix_fd => try put(out, n, "h"),
        .variant => try put(out, n, "v"),
        .array => |a| {
            try put(out, n, "a");
            try put(out, n, a.elem_sig);
        },
        .dict => |d| {
            try put(out, n, "a{");
            try put(out, n, d.key_sig);
            try put(out, n, d.value_sig);
            try put(out, n, "}");
        },
        .structure => |fields| {
            if (fields.len == 0) return error.InvalidSignature;
            try put(out, n, "(");
            for (fields) |f| try sigInto(f, out, n);
            try put(out, n, ")");
        },
    }
}

/// Reads one value of single complete type `sig`.
pub fn decode(d: *Decoder, sig: []const u8) marshal.DecodeError!Value {
    const len = signature.completeLen(sig) catch return error.Malformed;
    return decodeType(d, sig[0..len]);
}

fn enter(d: *Decoder) marshal.DecodeError!void {
    d.depth += 1;
    if (d.depth > signature.max_depth) return error.Malformed;
}

fn decodeType(d: *Decoder, t: []const u8) marshal.DecodeError!Value {
    return switch (t[0]) {
        'y' => .{ .byte = try d.readInt(u8) },
        'b' => .{ .boolean = try d.readBool() },
        'n' => .{ .i16 = try d.readInt(i16) },
        'q' => .{ .u16 = try d.readInt(u16) },
        'i' => .{ .i32 = try d.readInt(i32) },
        'u' => .{ .u32 = try d.readInt(u32) },
        'x' => .{ .i64 = try d.readInt(i64) },
        't' => .{ .u64 = try d.readInt(u64) },
        'd' => .{ .double = try d.readDouble() },
        's' => .{ .string = try d.readString() },
        'o' => .{ .object_path = try d.readObjectPath() },
        'g' => .{ .signature = try d.readSignature() },
        'h' => .{ .unix_fd = try d.readFd() },
        'v' => {
            const s = try d.readSignature();
            signature.validateSingle(s) catch return error.Malformed;
            try enter(d);
            defer d.depth -= 1;
            const inner = try d.arena.create(Value);
            inner.* = try decodeType(d, s);
            return .{ .variant = inner };
        },
        '(' => {
            try enter(d);
            defer d.depth -= 1;
            try d.alignTo(8);
            var fields: std.ArrayList(Value) = .empty;
            var i: usize = 1;
            while (t[i] != ')') {
                const l = signature.completeLen(t[i..]) catch unreachable;
                try fields.append(d.arena, try decodeType(d, t[i..][0..l]));
                i += l;
            }
            return .{ .structure = try fields.toOwnedSlice(d.arena) };
        },
        'a' => decodeArray(d, t[1..]),
        else => error.Malformed,
    };
}

fn decodeArray(d: *Decoder, elem: []const u8) marshal.DecodeError!Value {
    try enter(d);
    defer d.depth -= 1;
    const n = try d.readInt(u32);
    if (n > marshal.max_array_len) return error.Malformed;
    try d.alignTo(signature.alignOf(elem[0]));
    if (n > d.buf.len - d.pos) return error.Malformed;
    const end = d.pos + n;
    if (isBytes(elem)) {
        const bytes = d.buf[d.pos..end];
        d.pos = end;
        return .{ .array = .{ .elem_sig = elem, .bytes = bytes } };
    }
    if (elem[0] == '{') {
        const key_sig = elem[1..2];
        const value_sig = elem[2 .. elem.len - 1];
        var entries: std.ArrayList(DictEntry) = .empty;
        while (d.pos < end) {
            try d.alignTo(8);
            const k = try decodeType(d, key_sig);
            const v = try decodeType(d, value_sig);
            try entries.append(d.arena, .{ .key = k, .value = v });
        }
        if (d.pos != end) return error.Malformed;
        return .{ .dict = .{ .key_sig = key_sig, .value_sig = value_sig, .entries = try entries.toOwnedSlice(d.arena) } };
    }
    var items: std.ArrayList(Value) = .empty;
    while (d.pos < end) {
        const before = d.pos;
        try items.append(d.arena, try decodeType(d, elem));
        // Zero-size elements cannot exist, but guard the loop anyway.
        if (d.pos == before) return error.Malformed;
    }
    if (d.pos != end) return error.Malformed;
    return .{ .array = .{ .elem_sig = elem, .items = try items.toOwnedSlice(d.arena) } };
}

/// Writes `v` as a variant: its signature, then the value.
pub fn encodeVariant(e: *Encoder, v: Value) marshal.EncodeError!void {
    var buf: [signature.max_len]u8 = undefined;
    const n = try v.writeSignature(&buf);
    try e.writeSignature(buf[0..n]);
    try encodeValue(e, v);
}

/// Writes `v` as its own type. Array items and dict entries must match the
/// declared element signatures, or `error.TypeMismatch` is returned.
pub fn encodeValue(e: *Encoder, v: Value) marshal.EncodeError!void {
    switch (v) {
        .byte => |x| try e.writeInt(u8, x),
        .boolean => |x| try e.writeBool(x),
        .i16 => |x| try e.writeInt(i16, x),
        .u16 => |x| try e.writeInt(u16, x),
        .i32 => |x| try e.writeInt(i32, x),
        .u32 => |x| try e.writeInt(u32, x),
        .i64 => |x| try e.writeInt(i64, x),
        .u64 => |x| try e.writeInt(u64, x),
        .double => |x| try e.writeDouble(x),
        .string => |s| try e.writeString(s),
        .object_path => |s| try e.writeObjectPath(s),
        .signature => |s| try e.writeSignature(s),
        .unix_fd => |fd| try e.writeFd(fd),
        .variant => |p| try encodeVariant(e, p.*),
        .structure => |fields| {
            if (fields.len == 0) return error.InvalidSignature;
            try e.pad(8);
            for (fields) |f| try encodeValue(e, f);
        },
        .array => |a| {
            try signature.validateSingle(a.elem_sig);
            const m = try e.beginArray(signature.alignOf(a.elem_sig[0]));
            if (isBytes(a.elem_sig)) {
                try e.buf.appendSlice(e.gpa, a.bytes);
            } else for (a.items) |item| {
                try expectSig(item, a.elem_sig);
                try encodeValue(e, item);
            }
            try e.endArray(m);
        },
        .dict => |d| {
            if (d.key_sig.len != 1 or !signature.isBasic(d.key_sig[0])) return error.InvalidSignature;
            try signature.validateSingle(d.value_sig);
            const m = try e.beginArray(8);
            for (d.entries) |entry| {
                try expectSig(entry.key, d.key_sig);
                try expectSig(entry.value, d.value_sig);
                try e.pad(8);
                try encodeValue(e, entry.key);
                try encodeValue(e, entry.value);
            }
            try e.endArray(m);
        },
    }
}

fn expectSig(v: Value, want: []const u8) marshal.EncodeError!void {
    var buf: [signature.max_len]u8 = undefined;
    const n = try v.writeSignature(&buf);
    if (!std.mem.eql(u8, buf[0..n], want)) return error.TypeMismatch;
}

const testing = std.testing;

fn roundtrip(comptime sig: []const u8, args: anytype) !void {
    var e: Encoder = .init(testing.allocator, 0);
    defer e.deinit();
    try marshal.encode(&e, sig, args);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: Decoder = .{ .buf = e.buf.items, .arena = arena.allocator(), .fds = e.fds.items };
    const values = try d.decodeAll(sig);
    // Re-encode the decoded values and expect identical bytes.
    var e2: Encoder = .init(testing.allocator, 0);
    defer e2.deinit();
    for (values) |v| try encodeValue(&e2, v);
    try testing.expectEqualSlices(u8, e.buf.items, e2.buf.items);
    try testing.expectEqualSlices(i32, e.fds.items, e2.fds.items);
}

test "marshal/unmarshal roundtrip for every type incl. nested a{sv}" {
    try roundtrip("ybnqiuxtd", .{ @as(u8, 0xfe), true, @as(i16, -2), @as(u16, 65535), @as(i32, -7), @as(u32, 9), @as(i64, -1 << 40), @as(u64, 1 << 63), @as(f64, 2.5) });
    try roundtrip("sog", .{ "héllo", "/org/freedesktop/DBus", "a{sv}" });
    try roundtrip("hh", .{ @as(i32, 5), @as(i32, 9) });
    try roundtrip("ay", .{"bytes\x00\xff"});
    try roundtrip("aai(ys)", .{ .{ &[_]i32{ 1, 2 }, &[_]i32{} }, .{ @as(u8, 1), "x" } });
    const inner = .{ .{ "n", marshal.variantOf("u", @as(u32, 3)) }, .{ "s", marshal.variantOf("s", "v") } };
    try roundtrip("a{sv}", .{.{
        .{ "a", marshal.variantOf("b", true) },
        .{ "nested", marshal.variantOf("a{sv}", inner) },
        .{ "vv", marshal.variantOf("v", marshal.variantOf("x", @as(i64, -9))) },
        .{ "arr", marshal.variantOf("a(ot)", .{.{ "/a", @as(u64, 1) }}) },
    }});
    try roundtrip("a{oa{sa{sv}}}", .{.{.{ "/o", .{.{ "iface", .{.{ "p", marshal.variantOf("d", @as(f64, 1)) }} }} }}});
}

test "decoded values expose views and helpers" {
    var e: Encoder = .init(testing.allocator, 0);
    defer e.deinit();
    try marshal.encode(&e, "ua{sv}", .{ @as(u32, 0), .{
        .{ "uris", marshal.variantOf("as", &[_][]const u8{ "file:///a", "file:///b" }) },
        .{ "choice", marshal.variantOf("u", @as(u32, 2)) },
    } });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: Decoder = .{ .buf = e.buf.items, .arena = arena.allocator() };
    const v = try d.decodeAll("ua{sv}");
    try testing.expectEqual(0, v[0].asU64().?);
    const dict = v[1].dict;
    try testing.expectEqual(2, dict.get("choice").?.asU64().?);
    const uris = dict.get("uris").?.unwrap().array;
    try testing.expectEqual(2, uris.len());
    try testing.expectEqualStrings("file:///b", uris.items[1].asString().?);
    // Views point into the encoded buffer.
    const s = uris.items[0].asString().?;
    try testing.expect(@intFromPtr(s.ptr) >= @intFromPtr(e.buf.items.ptr) and @intFromPtr(s.ptr) < @intFromPtr(e.buf.items.ptr) + e.buf.items.len);
}

test "encodeValue rejects mismatched array items" {
    var e: Encoder = .init(testing.allocator, 0);
    defer e.deinit();
    const bad: Value = .{ .array = .{ .elem_sig = "s", .items = &.{ .{ .string = "a" }, .{ .u32 = 1 } } } };
    try testing.expectError(error.TypeMismatch, encodeValue(&e, bad));
}

test "decode depth limit" {
    // 65 nested variants each wrapping the next.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    for (0..65) |_| try buf.appendSlice(testing.allocator, &.{ 1, 'v', 0 });
    try buf.appendSlice(testing.allocator, &.{ 1, 'y', 0, 7 });
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var d: Decoder = .{ .buf = buf.items, .arena = arena.allocator() };
    try testing.expectError(error.Malformed, d.decode("v"));
}

test "fuzz: dbus decode never crashes" {
    try testing.fuzz({}, struct {
        fn one(_: void, sm: *testing.Smith) anyerror!void {
            var bytes: [512]u8 = undefined;
            const input = bytes[0..sm.slice(&bytes)];
            if (input.len < 2) return;
            const sig_len = @min(input[0] % 16, input.len - 1);
            const sig = input[1..][0..sig_len];
            signature.validate(sig) catch return;
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            var d: Decoder = .{ .buf = input[1 + sig_len ..], .arena = arena.allocator(), .big_endian = input[0] & 0x80 != 0 };
            _ = d.decodeAll(sig) catch return;
        }
    }.one, .{});
}
