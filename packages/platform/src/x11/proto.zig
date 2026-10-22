//! X11 requests and replies, hand-written from the protocol spec, and the
//! comptime serializer that writes a request struct's fields in
//! declaration order (little-endian; we always send 'l').
//!
//! A request type has `opcode` (core) or `extension` + `minor`. A core
//! request's field named `data` goes in header byte 1. Field types:
//! u8/i8/bool, u16/i16, u32/i32, enums and packed structs of those sizes,
//! `[N]u8` (padding), `[]const u8` (bytes then pad to 4), `[]const u32`,
//! and `ValueList(T)` (a mask then the set values in bit order).
//! Requests with a reply declare `Reply` with `decode(bytes, fds)`.

const std = @import("std");
const FdQueue = @import("../wayland/wire/fdqueue.zig").FdQueue;

/// Bytes are little-endian on our side of the connection.
const le = std.builtin.Endian.little;

/// Reply decoding errors.
pub const DecodeError = error{Malformed};

/// A mask-selected value list: `T` is a struct of optional fields, field
/// `i` being bit `i`.
pub fn ValueList(comptime T: type) type {
    return struct {
        /// The value-list fields.
        pub const Values = T;
        values: T = .{},
    };
}

fn isValueList(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Values");
}

fn fieldSize(comptime T: type, v: T) usize {
    if (comptime isValueList(T)) {
        var n: usize = 4;
        inline for (@typeInfo(T.Values).@"struct".fields) |f| {
            if (@field(v.values, f.name) != null) n += 4;
        }
        return n;
    }
    return switch (@typeInfo(T)) {
        .bool => 1,
        .int => |i| i.bits / 8,
        .@"enum" => |e| @typeInfo(e.tag_type).int.bits / 8,
        .@"struct" => @bitSizeOf(T) / 8,
        .array => |a| a.len,
        .pointer => |p| if (p.child == u8) std.mem.alignForward(usize, v.len, 4) else v.len * @sizeOf(p.child),
        else => @compileError("unsupported X11 field type " ++ @typeName(T)),
    };
}

/// The request's size in bytes (always a multiple of 4), excluding the
/// extra 4 bytes of the BIG-REQUESTS form.
pub fn requestSize(comptime R: type, req: R) usize {
    var n: usize = 4;
    inline for (@typeInfo(R).@"struct".fields) |f| {
        if (comptime isDataField(R, f.name)) continue;
        n += fieldSize(f.type, @field(req, f.name));
    }
    return std.mem.alignForward(usize, n, 4);
}

fn isDataField(comptime R: type, comptime name: []const u8) bool {
    return !@hasDecl(R, "extension") and std.mem.eql(u8, name, "data");
}

fn writeField(out: []u8, pos: usize, comptime T: type, v: T) usize {
    if (comptime isValueList(T)) {
        var mask: u32 = 0;
        var p = pos + 4;
        inline for (@typeInfo(T.Values).@"struct".fields, 0..) |f, bit| {
            if (@field(v.values, f.name)) |x| {
                mask |= @as(u32, 1) << bit;
                std.mem.writeInt(u32, out[p..][0..4], x, le);
                p += 4;
            }
        }
        std.mem.writeInt(u32, out[pos..][0..4], mask, le);
        return p;
    }
    switch (@typeInfo(T)) {
        .bool => {
            out[pos] = @intFromBool(v);
            return pos + 1;
        },
        .int => |i| {
            const U = std.meta.Int(.unsigned, i.bits);
            std.mem.writeInt(U, out[pos..][0 .. i.bits / 8], @bitCast(v), le);
            return pos + i.bits / 8;
        },
        .@"enum" => |e| return writeField(out, pos, e.tag_type, @intFromEnum(v)),
        .@"struct" => {
            const U = std.meta.Int(.unsigned, @bitSizeOf(T));
            return writeField(out, pos, U, @bitCast(v));
        },
        .array => |a| {
            @memcpy(out[pos..][0..a.len], &v);
            return pos + a.len;
        },
        .pointer => |p| {
            if (p.child == u8) {
                @memcpy(out[pos..][0..v.len], v);
                const padded = std.mem.alignForward(usize, v.len, 4);
                @memset(out[pos + v.len .. pos + padded], 0);
                return pos + padded;
            }
            var q = pos;
            for (v) |x| q = writeField(out, q, p.child, x);
            return q;
        },
        else => unreachable,
    }
}

/// Writes `req` into `out` (which must hold `requestSize + 4` bytes);
/// `major` is the extension's opcode for extension requests. With `big`,
/// requests over 65535 words use the BIG-REQUESTS form. Returns the
/// written length, or `error.RequestTooLarge`.
pub fn writeRequest(out: []u8, comptime R: type, req: R, major: u8, big: bool) error{RequestTooLarge}!usize {
    const size = requestSize(R, req);
    const words = size / 4;
    const use_big = words > 0xffff;
    if (use_big and !big) return error.RequestTooLarge;
    out[0] = if (@hasDecl(R, "extension")) major else R.opcode;
    out[1] = if (@hasDecl(R, "extension")) R.minor else if (@hasField(R, "data")) blk: {
        var b: [1]u8 = undefined;
        _ = writeField(&b, 0, @TypeOf(req.data), req.data);
        break :blk b[0];
    } else 0;
    var pos: usize = 4;
    if (use_big) {
        std.mem.writeInt(u16, out[2..4], 0, le);
        std.mem.writeInt(u32, out[4..8], @intCast(words + 1), le);
        pos = 8;
    } else std.mem.writeInt(u16, out[2..4], @intCast(words), le);
    inline for (@typeInfo(R).@"struct".fields) |f| {
        if (comptime isDataField(R, f.name)) continue;
        pos = writeField(out, pos, f.type, @field(req, f.name));
    }
    const end = std.mem.alignForward(usize, pos, 4);
    @memset(out[pos..end], 0);
    std.debug.assert(end == size + @as(usize, if (use_big) 4 else 0));
    return end;
}

fn u16At(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], le);
}
fn u32At(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], le);
}

// Core requests used by the connection and its tests. The backend tasks
// (E01.F05.S02/S03) add the rest next to these.

/// CreateWindow window classes.
pub const WindowClass = enum(u16) { copy_from_parent = 0, input_output = 1, input_only = 2 };

/// CreateWindow / ChangeWindowAttributes values, in bit order.
pub const WindowAttributes = struct {
    background_pixmap: ?u32 = null,
    background_pixel: ?u32 = null,
    border_pixmap: ?u32 = null,
    border_pixel: ?u32 = null,
    bit_gravity: ?u32 = null,
    win_gravity: ?u32 = null,
    backing_store: ?u32 = null,
    backing_planes: ?u32 = null,
    backing_pixel: ?u32 = null,
    override_redirect: ?u32 = null,
    save_under: ?u32 = null,
    event_mask: ?u32 = null,
    do_not_propagate_mask: ?u32 = null,
    colormap: ?u32 = null,
    cursor: ?u32 = null,
};

/// CreateWindow (1).
pub const CreateWindow = struct {
    /// The major opcode.
    pub const opcode = 1;
    data: u8, // depth
    wid: u32,
    parent: u32,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    border_width: u16 = 0,
    class: WindowClass = .input_output,
    visual: u32,
    values: ValueList(WindowAttributes) = .{},
};

/// DestroyWindow (4).
pub const DestroyWindow = struct {
    /// The major opcode.
    pub const opcode = 4;
    window: u32,
};

/// MapWindow (8).
pub const MapWindow = struct {
    /// The major opcode.
    pub const opcode = 8;
    window: u32,
};

/// InternAtom (16).
pub const InternAtom = struct {
    /// The major opcode.
    pub const opcode = 16;
    data: bool = false, // only-if-exists
    name_len: u16,
    _pad: [2]u8 = .{ 0, 0 },
    name: []const u8,

    /// The atom, or 0 with only-if-exists and no such atom.
    pub const Reply = struct {
        atom: u32,
        /// Decodes the reply from its wire bytes.
        pub fn decode(b: []const u8, _: *FdQueue) DecodeError!Reply {
            if (b.len < 32) return error.Malformed;
            return .{ .atom = u32At(b, 8) };
        }
    };
};

/// ChangeProperty modes.
pub const PropMode = enum(u8) { replace = 0, prepend = 1, append = 2 };

/// ChangeProperty (18) with 8-bit data; 32-bit data goes as bytes too.
pub const ChangeProperty = struct {
    /// The major opcode.
    pub const opcode = 18;
    data: PropMode = .replace,
    window: u32,
    property: u32,
    type: u32,
    format: u8,
    _pad: [3]u8 = .{ 0, 0, 0 },
    /// Length in units of `format`.
    length: u32,
    bytes: []const u8,
};

/// GetProperty (20).
pub const GetProperty = struct {
    /// The major opcode.
    pub const opcode = 20;
    data: bool = false, // delete
    window: u32,
    property: u32,
    type: u32 = 0,
    long_offset: u32 = 0,
    long_length: u32 = 0x1fffffff,

    /// The property's type, format and bytes (a view into the reply).
    pub const Reply = struct {
        format: u8,
        type: u32,
        bytes_after: u32,
        value: []const u8,
        /// Decodes the reply from its wire bytes.
        pub fn decode(b: []const u8, _: *FdQueue) DecodeError!Reply {
            if (b.len < 32) return error.Malformed;
            const format = b[1];
            const n = u32At(b, 16);
            const len: usize = switch (format) {
                0 => 0,
                8 => n,
                16 => @as(usize, n) * 2,
                32 => @as(usize, n) * 4,
                else => return error.Malformed,
            };
            if (b.len < 32 + len) return error.Malformed;
            return .{ .format = format, .type = u32At(b, 8), .bytes_after = u32At(b, 12), .value = b[32..][0..len] };
        }
    };
};

/// GetInputFocus (43): also the cheapest round trip (`Conn.sync`).
pub const GetInputFocus = struct {
    /// The major opcode.
    pub const opcode = 43;

    /// The focus window.
    pub const Reply = struct {
        focus: u32,
        /// Decodes the reply from its wire bytes.
        pub fn decode(b: []const u8, _: *FdQueue) DecodeError!Reply {
            if (b.len < 32) return error.Malformed;
            return .{ .focus = u32At(b, 8) };
        }
    };
};

/// QueryExtension (98).
pub const QueryExtension = struct {
    /// The major opcode.
    pub const opcode = 98;
    name_len: u16,
    _pad: [2]u8 = .{ 0, 0 },
    name: []const u8,

    /// Whether it is present, and its opcode and bases.
    pub const Reply = struct {
        present: bool,
        major_opcode: u8,
        first_event: u8,
        first_error: u8,
        /// Decodes the reply from its wire bytes.
        pub fn decode(b: []const u8, _: *FdQueue) DecodeError!Reply {
            if (b.len < 32) return error.Malformed;
            return .{ .present = b[8] != 0, .major_opcode = b[9], .first_event = b[10], .first_error = b[11] };
        }
    };
};

/// NoOperation (127).
pub const NoOperation = struct {
    /// The major opcode.
    pub const opcode = 127;
};

/// BIG-REQUESTS Enable.
pub const BigReqEnable = struct {
    /// The extension that owns this request.
    pub const extension = "BIG-REQUESTS";
    /// The minor opcode.
    pub const minor = 0;

    /// The new maximum request length in 4-byte units.
    pub const Reply = struct {
        max_request_length: u32,
        /// Decodes the reply from its wire bytes.
        pub fn decode(b: []const u8, _: *FdQueue) DecodeError!Reply {
            if (b.len < 32) return error.Malformed;
            return .{ .max_request_length = u32At(b, 8) };
        }
    };
};

/// A protocol error as the server sent it.
pub const XError = struct {
    code: u8,
    sequence: u16,
    bad_value: u32,
    minor_opcode: u16,
    major_opcode: u8,

    /// Parses a 32-byte error.
    pub fn parse(b: *const [32]u8) XError {
        return .{ .code = b[1], .sequence = u16At(b, 2), .bad_value = u32At(b, 4), .minor_opcode = u16At(b, 8), .major_opcode = b[10] };
    }
};

/// Core error codes.
pub const ErrorCode = struct {
    /// BadRequest.
    pub const request = 1;
    /// BadValue.
    pub const value = 2;
    /// BadWindow.
    pub const window = 3;
    /// BadAtom.
    pub const atom = 5;
    /// BadMatch.
    pub const match = 8;
    /// BadLength.
    pub const length = 16;
    /// BadImplementation.
    pub const implementation = 17;
};

/// GenericEvent (XGE) code.
pub const generic_event = 35;

const testing = std.testing;

test "serializer: CreateWindow layout with a value list" {
    var buf: [64]u8 = undefined;
    const n = try writeRequest(&buf, CreateWindow, .{
        .data = 24,
        .wid = 0x400001,
        .parent = 0x3d7,
        .x = -5,
        .y = 10,
        .width = 640,
        .height = 480,
        .visual = 0x21,
        .values = .{ .values = .{ .background_pixel = 0xffffff, .event_mask = 0x8000 } },
    }, 0, false);
    // 32 fixed bytes + mask + 2 values.
    try testing.expectEqual(40, n);
    try testing.expectEqual(1, buf[0]);
    try testing.expectEqual(24, buf[1]);
    try testing.expectEqual(10, u16At(&buf, 2));
    try testing.expectEqual(0x400001, u32At(&buf, 4));
    try testing.expectEqual(@as(u16, @bitCast(@as(i16, -5))), u16At(&buf, 12));
    try testing.expectEqual(640, u16At(&buf, 16));
    try testing.expectEqual(1, u16At(&buf, 22)); // InputOutput
    try testing.expectEqual(0x21, u32At(&buf, 24));
    try testing.expectEqual((1 << 1) | (1 << 11), u32At(&buf, 28));
    try testing.expectEqual(0xffffff, u32At(&buf, 32));
    try testing.expectEqual(0x8000, u32At(&buf, 36));
}

test "serializer: InternAtom pads its name; extension and big requests" {
    var buf: [64]u8 = undefined;
    const n = try writeRequest(&buf, InternAtom, .{ .data = true, .name_len = 5, .name = "WM_XY" }, 0, false);
    try testing.expectEqual(16, n);
    try testing.expectEqualSlices(u8, &.{ 16, 1, 4, 0, 5, 0, 0, 0, 'W', 'M', '_', 'X', 'Y', 0, 0, 0 }, buf[0..16]);
    const e = try writeRequest(&buf, BigReqEnable, .{}, 133, false);
    try testing.expectEqualSlices(u8, &.{ 133, 0, 1, 0 }, buf[0..e]);

    const big_data = try testing.allocator.alloc(u8, 300_000);
    defer testing.allocator.free(big_data);
    const out = try testing.allocator.alloc(u8, 300_100);
    defer testing.allocator.free(out);
    const req: ChangeProperty = .{ .window = 1, .property = 2, .type = 3, .format = 8, .length = 300_000, .bytes = big_data };
    try testing.expectError(error.RequestTooLarge, writeRequest(out, ChangeProperty, req, 0, false));
    const bn = try writeRequest(out, ChangeProperty, req, 0, true);
    try testing.expectEqual(0, u16At(out, 2));
    try testing.expectEqual(bn / 4, u32At(out, 4));
    try testing.expectEqual(requestSize(ChangeProperty, req) + 4, bn);
}

test "reply and error decoding" {
    var b: [40]u8 = @splat(0);
    b[0] = 1;
    b[1] = 8;
    std.mem.writeInt(u32, b[8..12], 31, le);
    std.mem.writeInt(u32, b[16..20], 3, le);
    @memcpy(b[32..35], "abc");
    var q: FdQueue = .{};
    const gp = try GetProperty.Reply.decode(&b, &q);
    try testing.expectEqualStrings("abc", gp.value);
    try testing.expectEqual(31, gp.type);
    try testing.expectError(error.Malformed, GetProperty.Reply.decode(b[0..34], &q));
    var e: [32]u8 = @splat(0);
    e[1] = ErrorCode.window;
    std.mem.writeInt(u16, e[2..4], 77, le);
    std.mem.writeInt(u32, e[4..8], 0xdead, le);
    e[10] = 8;
    const xe = XError.parse(&e);
    try testing.expectEqual(77, xe.sequence);
    try testing.expectEqual(0xdead, xe.bad_value);
    try testing.expectEqual(8, xe.major_opcode);
}
