//! D-Bus wire marshalling. `Encoder` writes little-endian bodies, with
//! `encode` checking its arguments against a comptime signature. `Decoder`
//! reads either byte order and validates everything it touches: padding,
//! strings, object paths, signatures, booleans and the size limits.

const std = @import("std");
const signature = @import("signature.zig");
const variant = @import("variant.zig");
const Value = variant.Value;

/// Longest array in bytes.
pub const max_array_len: usize = 64 * 1024 * 1024;

/// Errors from encoding.
pub const EncodeError = error{ OutOfMemory, InvalidObjectPath, InvalidSignature, InvalidString, TooLarge, TypeMismatch };

/// Errors from decoding: anything that breaks the wire format is `Malformed`.
pub const DecodeError = error{ Malformed, OutOfMemory };

/// Appends marshalled values to a growing buffer.
pub const Encoder = struct {
    gpa: std.mem.Allocator,
    /// The bytes written so far.
    buf: std.ArrayList(u8) = .empty,
    /// File descriptors referenced by `h` values, in index order. The
    /// encoder does not own them.
    fds: std.ArrayList(i32) = .empty,
    /// The offset of `buf[0]` within the message, for alignment.
    base: usize = 0,

    /// An empty encoder whose first byte sits at message offset `base`.
    pub fn init(gpa: std.mem.Allocator, base: usize) Encoder {
        return .{ .gpa = gpa, .base = base };
    }

    /// Frees the buffer and fd list.
    pub fn deinit(e: *Encoder) void {
        e.buf.deinit(e.gpa);
        e.fds.deinit(e.gpa);
    }

    fn pos(e: *const Encoder) usize {
        return e.base + e.buf.items.len;
    }

    /// Writes zero bytes up to the next multiple of `alignment`.
    pub fn pad(e: *Encoder, alignment: usize) EncodeError!void {
        const n = std.mem.alignForward(usize, e.pos(), alignment) - e.pos();
        try e.buf.appendNTimes(e.gpa, 0, n);
    }

    /// Writes an aligned integer.
    pub fn writeInt(e: *Encoder, comptime T: type, v: T) EncodeError!void {
        try e.pad(@sizeOf(T));
        var b: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &b, v, .little);
        try e.buf.appendSlice(e.gpa, &b);
    }

    /// Writes a BOOLEAN.
    pub fn writeBool(e: *Encoder, v: bool) EncodeError!void {
        try e.writeInt(u32, @intFromBool(v));
    }

    /// Writes a DOUBLE.
    pub fn writeDouble(e: *Encoder, v: f64) EncodeError!void {
        try e.writeInt(u64, @bitCast(v));
    }

    /// Writes a STRING: valid UTF-8 without NUL bytes.
    pub fn writeString(e: *Encoder, s: []const u8) EncodeError!void {
        if (!validString(s)) return error.InvalidString;
        try e.writeInt(u32, @intCast(s.len));
        try e.buf.appendSlice(e.gpa, s);
        try e.buf.append(e.gpa, 0);
    }

    /// Writes an OBJECT_PATH.
    pub fn writeObjectPath(e: *Encoder, s: []const u8) EncodeError!void {
        if (!validObjectPath(s)) return error.InvalidObjectPath;
        try e.writeString(s);
    }

    /// Writes a SIGNATURE.
    pub fn writeSignature(e: *Encoder, s: []const u8) EncodeError!void {
        try signature.validate(s);
        try e.buf.append(e.gpa, @intCast(s.len));
        try e.buf.appendSlice(e.gpa, s);
        try e.buf.append(e.gpa, 0);
    }

    /// Writes a UNIX_FD: the fd joins `fds` and its index goes on the wire.
    pub fn writeFd(e: *Encoder, fd: i32) EncodeError!void {
        try e.writeInt(u32, @intCast(e.fds.items.len));
        try e.fds.append(e.gpa, fd);
    }

    /// Where an open array's length and data start.
    pub const ArrayMark = struct { len_at: usize, data_at: usize };

    /// Starts an array of elements aligned to `elem_align`.
    pub fn beginArray(e: *Encoder, elem_align: usize) EncodeError!ArrayMark {
        try e.writeInt(u32, 0);
        const len_at = e.buf.items.len - 4;
        try e.pad(elem_align);
        return .{ .len_at = len_at, .data_at = e.buf.items.len };
    }

    /// Patches the length of an array opened by `beginArray`.
    pub fn endArray(e: *Encoder, m: ArrayMark) EncodeError!void {
        const n = e.buf.items.len - m.data_at;
        if (n > max_array_len) return error.TooLarge;
        std.mem.writeInt(u32, e.buf.items[m.len_at..][0..4], @intCast(n), .little);
    }
};

/// A value for a `v` argument with a signature fixed at comptime, as made
/// by `variantOf`.
pub fn Variant(comptime sig: []const u8, comptime T: type) type {
    return struct {
        /// The wrapped value's signature.
        pub const dbus_variant_sig = sig;
        /// The wrapped value.
        value: T,
    };
}

/// Wraps `value` for a `v` argument as type `sig`.
pub fn variantOf(comptime sig: []const u8, value: anytype) Variant(sig, @TypeOf(value)) {
    return .{ .value = value };
}

/// Writes `args`, a tuple with one field per complete type in `sig`.
/// Mismatches between `sig` and the argument types are compile errors.
/// For `v`, pass a `Value` or a `variantOf(...)`; for arrays, a slice or
/// tuple; for dicts, a slice or tuple of two-field structs or tuples; for
/// structs, a struct or tuple with one field per member.
pub fn encode(e: *Encoder, comptime sig: []const u8, args: anytype) EncodeError!void {
    comptime signature.validate(sig) catch @compileError("invalid D-Bus signature: " ++ sig);
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;
    comptime if (fields.len != signature.count(sig))
        @compileError(std.fmt.comptimePrint("signature \"{s}\" needs {d} arguments, got {d}", .{ sig, signature.count(sig), fields.len }));
    comptime var i: usize = 0;
    inline for (fields) |f| {
        const len = comptime signature.completeLen(sig[i..]) catch unreachable;
        try encodeOne(e, sig[i..][0..len], @field(args, f.name));
        i += len;
    }
}

fn encodeOne(e: *Encoder, comptime t: []const u8, v: anytype) EncodeError!void {
    switch (t[0]) {
        'y' => try e.writeInt(u8, v),
        'b' => try e.writeBool(v),
        'n' => try e.writeInt(i16, v),
        'q' => try e.writeInt(u16, v),
        'i' => try e.writeInt(i32, v),
        'u' => try e.writeInt(u32, v),
        'x' => try e.writeInt(i64, v),
        't' => try e.writeInt(u64, v),
        'd' => try e.writeDouble(v),
        's' => try e.writeString(v),
        'o' => try e.writeObjectPath(v),
        'g' => try e.writeSignature(v),
        'h' => try e.writeFd(v),
        'v' => try encodeVariant(e, v),
        '(' => {
            try e.pad(8);
            try encode(e, t[1 .. t.len - 1], v);
        },
        'a' => try encodeArray(e, t[1..], v),
        else => comptime unreachable,
    }
}

fn encodeVariant(e: *Encoder, v: anytype) EncodeError!void {
    const T = @TypeOf(v);
    if (T == Value) return variant.encodeVariant(e, v);
    if (!@hasDecl(T, "dbus_variant_sig")) @compileError("a `v` argument must be a Value or variantOf(...), got " ++ @typeName(T));
    const sig = T.dbus_variant_sig;
    comptime signature.validateSingle(sig) catch @compileError("invalid variant signature: " ++ sig);
    try e.writeSignature(sig);
    try encodeOne(e, sig, v.value);
}

fn encodeArray(e: *Encoder, comptime elem: []const u8, v: anytype) EncodeError!void {
    const m = try e.beginArray(signature.alignOf(elem[0]));
    const T = @TypeOf(v);
    const is_tuple = @typeInfo(T) == .@"struct" and @typeInfo(T).@"struct".is_tuple;
    if (comptime elem[0] == 'y' and !is_tuple) {
        const bytes: []const u8 = v;
        try e.buf.appendSlice(e.gpa, bytes);
    } else if (is_tuple) {
        inline for (v) |item| try encodeElem(e, elem, item);
    } else {
        for (v) |item| try encodeElem(e, elem, item);
    }
    try e.endArray(m);
}

fn encodeElem(e: *Encoder, comptime elem: []const u8, item: anytype) EncodeError!void {
    if (elem[0] == '{') {
        const fields = @typeInfo(@TypeOf(item)).@"struct".fields;
        if (fields.len != 2) @compileError("a dict entry needs two fields");
        const klen = 1;
        try e.pad(8);
        try encodeOne(e, elem[1..][0..klen], @field(item, fields[0].name));
        try encodeOne(e, elem[2 .. elem.len - 1], @field(item, fields[1].name));
    } else try encodeOne(e, elem, item);
}

/// Reads marshalled values from a message buffer. Strings and arrays of
/// bytes decode to views into `buf`; containers are allocated in `arena`.
pub const Decoder = struct {
    buf: []const u8,
    pos: usize = 0,
    /// The offset of `buf[0]` within the message, for alignment.
    base: usize = 0,
    big_endian: bool = false,
    /// Where containers and variants are allocated.
    arena: std.mem.Allocator,
    /// The message's file descriptors, indexed by `h` values.
    fds: []const i32 = &.{},
    /// Current container nesting.
    depth: u32 = 0,

    /// Whether every byte has been read.
    pub fn atEnd(d: *const Decoder) bool {
        return d.pos == d.buf.len;
    }

    /// Skips padding to `alignment`; padding must be zero.
    pub fn alignTo(d: *Decoder, alignment: usize) DecodeError!void {
        const to = std.mem.alignForward(usize, d.base + d.pos, alignment) - d.base;
        if (to > d.buf.len) return error.Malformed;
        for (d.buf[d.pos..to]) |b| if (b != 0) return error.Malformed;
        d.pos = to;
    }

    fn take(d: *Decoder, n: usize) DecodeError![]const u8 {
        if (n > d.buf.len - d.pos) return error.Malformed;
        defer d.pos += n;
        return d.buf[d.pos..][0..n];
    }

    /// Reads an aligned integer.
    pub fn readInt(d: *Decoder, comptime T: type) DecodeError!T {
        try d.alignTo(@sizeOf(T));
        const b = try d.take(@sizeOf(T));
        return std.mem.readInt(T, b[0..@sizeOf(T)], if (d.big_endian) .big else .little);
    }

    /// Reads a BOOLEAN, which must be 0 or 1.
    pub fn readBool(d: *Decoder) DecodeError!bool {
        return switch (try d.readInt(u32)) {
            0 => false,
            1 => true,
            else => error.Malformed,
        };
    }

    /// Reads a DOUBLE.
    pub fn readDouble(d: *Decoder) DecodeError!f64 {
        return @bitCast(try d.readInt(u64));
    }

    /// Reads a STRING as a view.
    pub fn readString(d: *Decoder) DecodeError![]const u8 {
        const n = try d.readInt(u32);
        const s = try d.take(n);
        const nul = try d.take(1);
        if (nul[0] != 0 or !validString(s)) return error.Malformed;
        return s;
    }

    /// Reads an OBJECT_PATH as a view.
    pub fn readObjectPath(d: *Decoder) DecodeError![]const u8 {
        const s = try d.readString();
        if (!validObjectPath(s)) return error.Malformed;
        return s;
    }

    /// Reads a SIGNATURE as a view.
    pub fn readSignature(d: *Decoder) DecodeError![]const u8 {
        const n = (try d.take(1))[0];
        const s = try d.take(n);
        const nul = try d.take(1);
        if (nul[0] != 0) return error.Malformed;
        signature.validate(s) catch return error.Malformed;
        return s;
    }

    /// Reads a UNIX_FD index and returns the fd it names.
    pub fn readFd(d: *Decoder) DecodeError!i32 {
        const idx = try d.readInt(u32);
        if (idx >= d.fds.len) return error.Malformed;
        return d.fds[idx];
    }

    /// Reads one value of single complete type `sig`.
    pub fn decode(d: *Decoder, sig: []const u8) DecodeError!Value {
        return variant.decode(d, sig);
    }

    /// Reads every value of `sig` and requires the buffer to end there.
    pub fn decodeAll(d: *Decoder, sig: []const u8) DecodeError![]Value {
        signature.validate(sig) catch return error.Malformed;
        var out: std.ArrayList(Value) = .empty;
        var i: usize = 0;
        while (i < sig.len) {
            const len = signature.completeLen(sig[i..]) catch unreachable;
            try out.append(d.arena, try variant.decode(d, sig[i..][0..len]));
            i += len;
        }
        if (!d.atEnd()) return error.Malformed;
        return out.toOwnedSlice(d.arena);
    }
};

/// Whether `s` is valid UTF-8 without NUL bytes.
pub fn validString(s: []const u8) bool {
    if (std.mem.indexOfScalar(u8, s, 0) != null) return false;
    return std.unicode.utf8ValidateSlice(s);
}

/// Whether `s` is a valid object path: "/" or "/" separated non-empty
/// elements of [A-Za-z0-9_], with no trailing slash.
pub fn validObjectPath(s: []const u8) bool {
    if (s.len == 0 or s[0] != '/') return false;
    if (s.len == 1) return true;
    if (s[s.len - 1] == '/') return false;
    var prev_slash = true;
    for (s[1..]) |c| {
        if (c == '/') {
            if (prev_slash) return false;
            prev_slash = true;
        } else if (std.ascii.isAlphanumeric(c) or c == '_') {
            prev_slash = false;
        } else return false;
    }
    return true;
}

const testing = std.testing;

test "alignment golden bytes" {
    var e: Encoder = .init(testing.allocator, 0);
    defer e.deinit();
    // y then u: three padding bytes; then s; then t aligned to 8.
    try encode(&e, "yust", .{ @as(u8, 1), @as(u32, 0x01020304), "ab", @as(u64, 5) });
    const want = [_]u8{
        1, 0, 0, 0, 4, 3, 2, 1, // y, pad, u
        2, 0, 0, 0, 'a', 'b', 0, 0, // s "ab" NUL, pad to 8
        5, 0, 0, 0, 0, 0, 0, 0, // t
    };
    try testing.expectEqualSlices(u8, &want, e.buf.items);
}

test "array padding is not counted in the length" {
    var e: Encoder = .init(testing.allocator, 0);
    defer e.deinit();
    // The spec's example: an array of INT64 starts with a 4-byte length,
    // then 4 bytes of padding that the length excludes.
    try encode(&e, "ax", .{&[_]i64{ 1, 2 }});
    try testing.expectEqual(24, e.buf.items.len);
    try testing.expectEqualSlices(u8, &.{ 16, 0, 0, 0, 0, 0, 0, 0 }, e.buf.items[0..8]);
    // Empty arrays still pad to the element alignment.
    var e2: Encoder = .init(testing.allocator, 0);
    defer e2.deinit();
    try encode(&e2, "a(i)", .{&[_]struct { i32 }{}});
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, e2.buf.items);
}

test "a{sv} and signatures encode as the spec describes" {
    var e: Encoder = .init(testing.allocator, 0);
    defer e.deinit();
    try encode(&e, "ga{sv}", .{ "s", .{.{ "k", variantOf("u", @as(u32, 7)) }} });
    const want = [_]u8{
        1, 's', 0, 0, // g "s", pad to 4
        16, 0, 0, 0, // array length
        1, 0, 0, 0, 'k', 0, // key "k"
        1, 'u', 0, 0, 0, 0, // variant signature "u", pad to 4
        7, 0, 0, 0, // u 7
    };
    try testing.expectEqualSlices(u8, &want, e.buf.items);
}

test "decoder rejects bad padding, booleans, strings and paths" {
    const d0 = struct {
        fn run(bytes: []const u8, sig: []const u8) DecodeError![]Value {
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            var d: Decoder = .{ .buf = bytes, .arena = arena.allocator() };
            return d.decodeAll(sig);
        }
    };
    try testing.expectError(error.Malformed, d0.run(&.{ 1, 9, 0, 0, 0, 0, 0, 0 }, "yu"));
    try testing.expectError(error.Malformed, d0.run(&.{ 2, 0, 0, 0 }, "b"));
    try testing.expectError(error.Malformed, d0.run(&.{ 1, 0, 0, 0, 'a', 1 }, "s"));
    try testing.expectError(error.Malformed, d0.run(&.{ 2, 0, 0, 0, '/', '/', 0 }, "o"));
    try testing.expectError(error.Malformed, d0.run(&.{ 1, 0, 0, 0, 0xff, 0 }, "s"));
    try testing.expectError(error.Malformed, d0.run(&.{ 0, 0, 0, 0 }, "s"));
}

test "object path rules" {
    for ([_][]const u8{ "/", "/a", "/org/freedesktop/DBus", "/a_1/B2" }) |p| try testing.expect(validObjectPath(p));
    for ([_][]const u8{ "", "a", "/a/", "//", "/a//b", "/a-b", "/a.b" }) |p| try testing.expect(!validObjectPath(p));
}
