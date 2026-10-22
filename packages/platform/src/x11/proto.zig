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

/// GetAtomName (17).
pub const GetAtomName = struct {
    /// The major opcode.
    pub const opcode = 17;
    atom: u32,

    /// The atom's name.
    pub const Reply = struct {
        name: []const u8,
        /// Decodes the reply from its wire bytes.
        pub fn decode(b: []const u8, _: *FdQueue) DecodeError!Reply {
            if (b.len < 32) return error.Malformed;
            const len = u16At(b, 8);
            if (b.len < 32 + @as(usize, len)) return error.Malformed;
            return .{ .name = b[32..][0..len] };
        }
    };
};

/// SetInputFocus (42).
pub const SetInputFocus = struct {
    /// The major opcode.
    pub const opcode = 42;
    /// Revert-to: 0 None, 1 PointerRoot, 2 Parent.
    data: u8 = 2,
    focus: u32,
    time: u32 = 0,
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

/// DeleteProperty (19).
pub const DeleteProperty = struct {
    /// The major opcode.
    pub const opcode = 19;
    window: u32,
    property: u32,
};

/// ChangeWindowAttributes (2).
pub const ChangeWindowAttributes = struct {
    /// The major opcode.
    pub const opcode = 2;
    window: u32,
    values: ValueList(WindowAttributes) = .{},
};

/// SetSelectionOwner (22); `owner` 0 gives the selection up.
pub const SetSelectionOwner = struct {
    /// The major opcode.
    pub const opcode = 22;
    owner: u32,
    selection: u32,
    time: u32,
};

/// GetSelectionOwner (23).
pub const GetSelectionOwner = struct {
    /// The major opcode.
    pub const opcode = 23;
    selection: u32,

    /// The owner window, or 0.
    pub const Reply = struct {
        owner: u32,
        /// Decodes the reply from its wire bytes.
        pub fn decode(b: []const u8, _: *FdQueue) DecodeError!Reply {
            if (b.len < 32) return error.Malformed;
            return .{ .owner = u32At(b, 8) };
        }
    };
};

/// ConvertSelection (24): asks the owner to store `target` in
/// `property` on `requestor`, answered by SelectionNotify.
pub const ConvertSelection = struct {
    /// The major opcode.
    pub const opcode = 24;
    requestor: u32,
    selection: u32,
    target: u32,
    property: u32,
    time: u32,
};

/// XFIXES QueryVersion; required before other XFIXES requests.
pub const XFixesQueryVersion = struct {
    /// The extension that owns this request.
    pub const extension = "XFIXES";
    /// The minor opcode.
    pub const minor = 0;
    client_major: u32 = 5,
    client_minor: u32 = 0,

    /// The server's version.
    pub const Reply = struct {
        major: u32,
        minor: u32,
        /// Decodes the reply from its wire bytes.
        pub fn decode(b: []const u8, _: *FdQueue) DecodeError!Reply {
            if (b.len < 32) return error.Malformed;
            return .{ .major = u32At(b, 8), .minor = u32At(b, 12) };
        }
    };
};

/// XFIXES SelectSelectionInput: XFixesSelectionNotify for `selection`.
pub const XFixesSelectSelectionInput = struct {
    /// The extension that owns this request.
    pub const extension = "XFIXES";
    /// The minor opcode.
    pub const minor = 2;
    window: u32,
    selection: u32,
    /// Bit 0: SetSelectionOwner; 1: SelectionWindowDestroy; 2:
    /// SelectionClientClose.
    event_mask: u32,
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

/// SendEvent (25): delivers a 32-byte event to `destination`.
pub const SendEvent = struct {
    /// The major opcode.
    pub const opcode = 25;
    data: bool = false, // propagate
    destination: u32,
    event_mask: u32,
    event: [32]u8,
};

/// ConfigureWindow (12) values, in bit order.
pub const ConfigureValues = struct {
    x: ?u32 = null,
    y: ?u32 = null,
    width: ?u32 = null,
    height: ?u32 = null,
    border_width: ?u32 = null,
    sibling: ?u32 = null,
    stack_mode: ?u32 = null,
};

/// ConfigureWindow (12). The mask is 16 bits here, unlike other lists.
pub const ConfigureWindow = struct {
    /// The major opcode.
    pub const opcode = 12;
    window: u32,
    mask: u16,
    _pad: [2]u8 = .{ 0, 0 },
    values: []const u32,
};

/// CreateGC / ChangeGC values, in bit order (up to graphics-exposures).
pub const GcValues = struct {
    function: ?u32 = null,
    plane_mask: ?u32 = null,
    foreground: ?u32 = null,
    background: ?u32 = null,
    line_width: ?u32 = null,
    line_style: ?u32 = null,
    cap_style: ?u32 = null,
    join_style: ?u32 = null,
    fill_style: ?u32 = null,
    fill_rule: ?u32 = null,
    tile: ?u32 = null,
    stipple: ?u32 = null,
    tile_stipple_x_origin: ?u32 = null,
    tile_stipple_y_origin: ?u32 = null,
    font: ?u32 = null,
    subwindow_mode: ?u32 = null,
    graphics_exposures: ?u32 = null,
};

/// CreateGC (55).
pub const CreateGC = struct {
    /// The major opcode.
    pub const opcode = 55;
    cid: u32,
    drawable: u32,
    values: ValueList(GcValues) = .{},
};

/// FreeGC (60).
pub const FreeGC = struct {
    /// The major opcode.
    pub const opcode = 60;
    gc: u32,
};

/// FreePixmap (54).
pub const FreePixmap = struct {
    /// The major opcode.
    pub const opcode = 54;
    pixmap: u32,
};

/// Image formats of PutImage and GetImage.
pub const ImageFormat = enum(u8) { bitmap = 0, xy_pixmap = 1, z_pixmap = 2 };

/// PutImage (72).
pub const PutImage = struct {
    /// The major opcode.
    pub const opcode = 72;
    data: ImageFormat = .z_pixmap,
    drawable: u32,
    gc: u32,
    width: u16,
    height: u16,
    dst_x: i16,
    dst_y: i16,
    left_pad: u8 = 0,
    depth: u8,
    _pad: [2]u8 = .{ 0, 0 },
    pixels: []const u8,
};

/// GetImage (73).
pub const GetImage = struct {
    /// The major opcode.
    pub const opcode = 73;
    data: ImageFormat = .z_pixmap,
    drawable: u32,
    x: i16,
    y: i16,
    width: u16,
    height: u16,
    plane_mask: u32 = 0xffffffff,

    /// The image depth, visual and pixels (a view into the reply).
    pub const Reply = struct {
        depth: u8,
        visual: u32,
        pixels: []const u8,
        /// Decodes the reply from its wire bytes.
        pub fn decode(b: []const u8, _: *FdQueue) DecodeError!Reply {
            if (b.len < 32) return error.Malformed;
            const len = @as(usize, u32At(b, 4)) * 4;
            if (b.len < 32 + len) return error.Malformed;
            return .{ .depth = b[1], .visual = u32At(b, 8), .pixels = b[32..][0..len] };
        }
    };
};

/// GetKeyboardMapping (101).
pub const GetKeyboardMapping = struct {
    /// The major opcode.
    pub const opcode = 101;
    first_keycode: u8,
    count: u8,
    _pad: [2]u8 = .{ 0, 0 },

    /// `keysyms_per_keycode` keysyms for each keycode from `first_keycode`.
    pub const Reply = struct {
        keysyms_per_keycode: u8,
        /// Little-endian u32 keysyms.
        keysyms: []const u8,
        /// Decodes the reply from its wire bytes.
        pub fn decode(b: []const u8, _: *FdQueue) DecodeError!Reply {
            if (b.len < 32) return error.Malformed;
            const len = @as(usize, u32At(b, 4)) * 4;
            if (b.len < 32 + len) return error.Malformed;
            return .{ .keysyms_per_keycode = b[1], .keysyms = b[32..][0..len] };
        }
    };
};

/// MIT-SHM QueryVersion.
pub const ShmQueryVersion = struct {
    /// The extension that owns this request.
    pub const extension = "MIT-SHM";
    /// The minor opcode.
    pub const minor = 0;

    /// The server's MIT-SHM version.
    pub const Reply = struct {
        major: u16,
        minor: u16,
        /// Decodes the reply from its wire bytes.
        pub fn decode(b: []const u8, _: *FdQueue) DecodeError!Reply {
            if (b.len < 32) return error.Malformed;
            return .{ .major = u16At(b, 8), .minor = u16At(b, 10) };
        }
    };
};

/// MIT-SHM Detach.
pub const ShmDetach = struct {
    /// The extension that owns this request.
    pub const extension = "MIT-SHM";
    /// The minor opcode.
    pub const minor = 2;
    shmseg: u32,
};

/// MIT-SHM PutImage: copies from a segment to a drawable.
pub const ShmPutImage = struct {
    /// The extension that owns this request.
    pub const extension = "MIT-SHM";
    /// The minor opcode.
    pub const minor = 3;
    drawable: u32,
    gc: u32,
    total_width: u16,
    total_height: u16,
    src_x: u16,
    src_y: u16,
    src_width: u16,
    src_height: u16,
    dst_x: i16,
    dst_y: i16,
    depth: u8,
    format: ImageFormat = .z_pixmap,
    send_event: bool,
    _pad: u8 = 0,
    shmseg: u32,
    offset: u32,
};

/// MIT-SHM AttachFd (1.2): attaches the memory behind the fd sent with it.
pub const ShmAttachFd = struct {
    /// The extension that owns this request.
    pub const extension = "MIT-SHM";
    /// The minor opcode.
    pub const minor = 6;
    shmseg: u32,
    read_only: bool = false,
    _pad: [3]u8 = .{ 0, 0, 0 },
};

/// Core event codes (byte 0, without the SendEvent bit).
pub const EventCode = struct {
    /// KeyPress.
    pub const key_press = 2;
    /// KeyRelease.
    pub const key_release = 3;
    /// ButtonPress.
    pub const button_press = 4;
    /// ButtonRelease.
    pub const button_release = 5;
    /// MotionNotify.
    pub const motion_notify = 6;
    /// EnterNotify.
    pub const enter_notify = 7;
    /// LeaveNotify.
    pub const leave_notify = 8;
    /// FocusIn.
    pub const focus_in = 9;
    /// FocusOut.
    pub const focus_out = 10;
    /// Expose.
    pub const expose = 12;
    /// VisibilityNotify.
    pub const visibility_notify = 15;
    /// UnmapNotify.
    pub const unmap_notify = 18;
    /// MapNotify.
    pub const map_notify = 19;
    /// ConfigureNotify.
    pub const configure_notify = 22;
    /// PropertyNotify.
    pub const property_notify = 28;
    /// SelectionClear.
    pub const selection_clear = 29;
    /// SelectionRequest.
    pub const selection_request = 30;
    /// SelectionNotify.
    pub const selection_notify = 31;
    /// ClientMessage.
    pub const client_message = 33;
    /// MappingNotify.
    pub const mapping_notify = 34;
};

/// Core event-mask bits.
pub const EventMask = struct {
    /// KeyPress.
    pub const key_press: u32 = 1 << 0;
    /// KeyRelease.
    pub const key_release: u32 = 1 << 1;
    /// ButtonPress.
    pub const button_press: u32 = 1 << 2;
    /// ButtonRelease.
    pub const button_release: u32 = 1 << 3;
    /// EnterWindow.
    pub const enter_window: u32 = 1 << 4;
    /// LeaveWindow.
    pub const leave_window: u32 = 1 << 5;
    /// PointerMotion.
    pub const pointer_motion: u32 = 1 << 6;
    /// Exposure.
    pub const exposure: u32 = 1 << 15;
    /// VisibilityChange.
    pub const visibility_change: u32 = 1 << 16;
    /// StructureNotify.
    pub const structure_notify: u32 = 1 << 17;
    /// SubstructureNotify.
    pub const substructure_notify: u32 = 1 << 19;
    /// SubstructureRedirect.
    pub const substructure_redirect: u32 = 1 << 20;
    /// FocusChange.
    pub const focus_change: u32 = 1 << 21;
    /// PropertyChange.
    pub const property_change: u32 = 1 << 22;
};

/// Predefined atoms.
pub const Atom = struct {
    /// PRIMARY.
    pub const primary: u32 = 1;
    /// ATOM.
    pub const atom: u32 = 4;
    /// CARDINAL.
    pub const cardinal: u32 = 6;
    /// INTEGER.
    pub const integer: u32 = 19;
    /// RESOURCE_MANAGER.
    pub const resource_manager: u32 = 23;
    /// STRING.
    pub const string: u32 = 31;
    /// WM_NAME.
    pub const wm_name: u32 = 39;
    /// WM_NORMAL_HINTS.
    pub const wm_normal_hints: u32 = 40;
    /// WM_SIZE_HINTS.
    pub const wm_size_hints: u32 = 41;
    /// WM_CLASS.
    pub const wm_class: u32 = 67;
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

test "PutImage and ShmPutImage layouts" {
    var buf: [64]u8 = undefined;
    const px = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const n = try writeRequest(&buf, PutImage, .{ .drawable = 7, .gc = 9, .width = 2, .height = 1, .dst_x = 3, .dst_y = -1, .depth = 24, .pixels = &px }, 0, false);
    try testing.expectEqual(@as(usize, 32), n);
    try testing.expectEqual(@as(u8, 72), buf[0]);
    try testing.expectEqual(@as(u8, 2), buf[1]); // ZPixmap
    try testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, buf[2..4], .little));
    try testing.expectEqual(@as(i16, -1), std.mem.readInt(i16, buf[18..20], .little));
    try testing.expectEqual(@as(u8, 24), buf[21]);
    try testing.expectEqualSlices(u8, &px, buf[24..32]);

    const m = try writeRequest(&buf, ShmPutImage, .{ .drawable = 1, .gc = 2, .total_width = 10, .total_height = 20, .src_x = 1, .src_y = 2, .src_width = 3, .src_height = 4, .dst_x = 5, .dst_y = 6, .depth = 24, .send_event = true, .shmseg = 0x55, .offset = 0 }, 130, false);
    try testing.expectEqual(@as(usize, 40), m);
    try testing.expectEqual(@as(u8, 130), buf[0]);
    try testing.expectEqual(@as(u8, 3), buf[1]);
    try testing.expectEqual(@as(u8, 24), buf[28]);
    try testing.expectEqual(@as(u8, 2), buf[29]);
    try testing.expectEqual(@as(u8, 1), buf[30]);
    try testing.expectEqual(@as(u32, 0x55), std.mem.readInt(u32, buf[32..36], .little));
}

test "CreateGC value list and GetKeyboardMapping reply" {
    var buf: [32]u8 = undefined;
    const n = try writeRequest(&buf, CreateGC, .{ .cid = 1, .drawable = 2, .values = .{ .values = .{ .graphics_exposures = 0 } } }, 0, false);
    try testing.expectEqual(@as(usize, 20), n);
    try testing.expectEqual(@as(u32, 1 << 16), std.mem.readInt(u32, buf[12..16], .little));
    var r: [40]u8 = @splat(0);
    r[0] = 1;
    r[1] = 2;
    std.mem.writeInt(u32, r[4..8], 2, .little);
    std.mem.writeInt(u32, r[32..36], 0x61, .little);
    std.mem.writeInt(u32, r[36..40], 0x41, .little);
    var fds: FdQueue = .{};
    const km = try GetKeyboardMapping.Reply.decode(&r, &fds);
    try testing.expectEqual(@as(u8, 2), km.keysyms_per_keycode);
    try testing.expectEqual(@as(usize, 8), km.keysyms.len);
}
