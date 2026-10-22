//! The protocol model: interfaces with requests, events and enums, read
//! from the XML token stream. Strings point into the XML or the arena.

const std = @import("std");
const xml = @import("xml.zig");

/// Wire argument types.
pub const ArgType = enum { int, uint, fixed, string, object, new_id, array, fd };

/// One message argument.
pub const Arg = struct {
    name: []const u8,
    type: ArgType,
    interface: ?[]const u8 = null,
    allow_null: bool = false,
    /// `enum="..."`: a local name or `interface.enum`.
    enum_ref: ?[]const u8 = null,
    summary: ?[]const u8 = null,
};

/// A request or event.
pub const Message = struct {
    name: []const u8,
    since: u32 = 1,
    destructor: bool = false,
    args: []const Arg = &.{},
    summary: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

/// One enum entry.
pub const Entry = struct {
    name: []const u8,
    value: u32,
    since: u32 = 1,
    summary: ?[]const u8 = null,
};

/// An enum; `bitfield` ones may become packed structs.
pub const Enum = struct {
    name: []const u8,
    bitfield: bool = false,
    entries: []const Entry = &.{},
    summary: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

/// An interface.
pub const Interface = struct {
    name: []const u8,
    version: u32,
    requests: []const Message = &.{},
    events: []const Message = &.{},
    enums: []const Enum = &.{},
    summary: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

/// A protocol file.
pub const Protocol = struct {
    name: []const u8,
    interfaces: []const Interface = &.{},
};

/// Errors from building the model; XML errors keep their position in
/// `Diagnostic`.
pub const Error = error{ Syntax, OutOfMemory, InvalidProtocol };

/// Where a model error happened.
pub const Diagnostic = struct { line: u32 = 0, col: u32 = 0, message: []const u8 = "" };

fn attr(attrs: []const xml.Attr, name: []const u8) ?[]const u8 {
    for (attrs) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
    return null;
}

fn parseU32(s: []const u8) ?u32 {
    if (std.mem.startsWith(u8, s, "0x")) return std.fmt.parseInt(u32, s[2..], 16) catch null;
    return std.fmt.parseInt(u32, s, 10) catch null;
}

const Reader = struct {
    tz: xml.Tokenizer,
    arena: std.mem.Allocator,
    diag: ?*Diagnostic,

    fn next(r: *Reader) Error!xml.Token {
        return r.tz.next() catch |e| {
            if (r.diag) |d| d.* = .{ .line = r.tz.line, .col = r.tz.col, .message = "malformed XML" };
            return e;
        };
    }

    fn invalid(r: *Reader, msg: []const u8) Error {
        if (r.diag) |d| d.* = .{ .message = msg };
        return error.InvalidProtocol;
    }

    /// Skips the rest of an element whose start was just read.
    fn skip(r: *Reader) Error!void {
        var depth: usize = 1;
        while (depth > 0) switch (try r.next()) {
            .start => depth += 1,
            .end => depth -= 1,
            .text => {},
            .eof => return r.invalid("unexpected end of file"),
        };
    }

    /// Reads a `<description>`'s text (its start was just read).
    fn description(r: *Reader) Error!?[]const u8 {
        var text: std.ArrayList(u8) = .empty;
        while (true) switch (try r.next()) {
            .text => |t| try text.appendSlice(r.arena, t),
            .start => try r.skip(),
            .end => break,
            .eof => return r.invalid("unexpected end of file"),
        };
        const s = std.mem.trim(u8, text.items, " \t\r\n");
        return if (s.len == 0) null else s;
    }
};

/// Builds the model of one protocol XML file.
pub fn parse(arena: std.mem.Allocator, src: []const u8, diag: ?*Diagnostic) Error!Protocol {
    var r: Reader = .{ .tz = .init(arena, src), .arena = arena, .diag = diag };
    const root = while (true) switch (try r.next()) {
        .start => |s| break s,
        .text => {},
        else => return r.invalid("no <protocol> element"),
    };
    if (!std.mem.eql(u8, root.name, "protocol")) return r.invalid("root element is not <protocol>");
    var p: Protocol = .{ .name = attr(root.attrs, "name") orelse return r.invalid("protocol without a name") };
    var ifaces: std.ArrayList(Interface) = .empty;
    while (true) switch (try r.next()) {
        .start => |s| if (std.mem.eql(u8, s.name, "interface")) {
            try ifaces.append(arena, try interface(&r, s.attrs));
        } else try r.skip(),
        .end => break,
        .text => {},
        .eof => return r.invalid("unexpected end of file"),
    };
    p.interfaces = ifaces.items;
    return p;
}

fn interface(r: *Reader, attrs: []const xml.Attr) Error!Interface {
    var it: Interface = .{
        .name = attr(attrs, "name") orelse return r.invalid("interface without a name"),
        .version = parseU32(attr(attrs, "version") orelse return r.invalid("interface without a version")) orelse return r.invalid("bad interface version"),
    };
    var requests: std.ArrayList(Message) = .empty;
    var events: std.ArrayList(Message) = .empty;
    var enums: std.ArrayList(Enum) = .empty;
    while (true) switch (try r.next()) {
        .start => |s| {
            if (std.mem.eql(u8, s.name, "description")) {
                it.summary = attr(s.attrs, "summary");
                it.description = try r.description();
            } else if (std.mem.eql(u8, s.name, "request")) {
                try requests.append(r.arena, try message(r, s.attrs));
            } else if (std.mem.eql(u8, s.name, "event")) {
                try events.append(r.arena, try message(r, s.attrs));
            } else if (std.mem.eql(u8, s.name, "enum")) {
                try enums.append(r.arena, try enumeration(r, s.attrs));
            } else try r.skip();
        },
        .end => break,
        .text => {},
        .eof => return r.invalid("unexpected end of file"),
    };
    it.requests = requests.items;
    it.events = events.items;
    it.enums = enums.items;
    return it;
}

fn message(r: *Reader, attrs: []const xml.Attr) Error!Message {
    var m: Message = .{ .name = attr(attrs, "name") orelse return r.invalid("message without a name") };
    if (attr(attrs, "since")) |s| m.since = parseU32(s) orelse return r.invalid("bad since");
    if (attr(attrs, "type")) |t| m.destructor = std.mem.eql(u8, t, "destructor");
    var args: std.ArrayList(Arg) = .empty;
    while (true) switch (try r.next()) {
        .start => |s| {
            if (std.mem.eql(u8, s.name, "description")) {
                m.summary = attr(s.attrs, "summary");
                m.description = try r.description();
            } else if (std.mem.eql(u8, s.name, "arg")) {
                const tname = attr(s.attrs, "type") orelse return r.invalid("arg without a type");
                var a: Arg = .{
                    .name = attr(s.attrs, "name") orelse return r.invalid("arg without a name"),
                    .type = std.meta.stringToEnum(ArgType, tname) orelse return r.invalid("unknown arg type"),
                    .interface = attr(s.attrs, "interface"),
                    .enum_ref = attr(s.attrs, "enum"),
                    .summary = attr(s.attrs, "summary"),
                };
                if (attr(s.attrs, "allow-null")) |n| a.allow_null = std.mem.eql(u8, n, "true");
                try args.append(r.arena, a);
                try r.skip();
            } else try r.skip();
        },
        .end => break,
        .text => {},
        .eof => return r.invalid("unexpected end of file"),
    };
    m.args = args.items;
    return m;
}

fn enumeration(r: *Reader, attrs: []const xml.Attr) Error!Enum {
    var e: Enum = .{ .name = attr(attrs, "name") orelse return r.invalid("enum without a name") };
    if (attr(attrs, "bitfield")) |b| e.bitfield = std.mem.eql(u8, b, "true");
    var entries: std.ArrayList(Entry) = .empty;
    while (true) switch (try r.next()) {
        .start => |s| {
            if (std.mem.eql(u8, s.name, "description")) {
                e.summary = attr(s.attrs, "summary");
                e.description = try r.description();
            } else if (std.mem.eql(u8, s.name, "entry")) {
                var en: Entry = .{
                    .name = attr(s.attrs, "name") orelse return r.invalid("entry without a name"),
                    .value = parseU32(attr(s.attrs, "value") orelse return r.invalid("entry without a value")) orelse return r.invalid("bad entry value"),
                    .summary = attr(s.attrs, "summary"),
                };
                if (attr(s.attrs, "since")) |v| en.since = parseU32(v) orelse return r.invalid("bad since");
                try entries.append(r.arena, en);
                try r.skip();
            } else try r.skip();
        },
        .end => break,
        .text => {},
        .eof => return r.invalid("unexpected end of file"),
    };
    e.entries = entries.items;
    return e;
}

const testing = std.testing;

test "model from wayland.xml has wl_display v1 with sync/get_registry" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    // Run from the repository root (zig build test-tools); skip elsewhere.
    const src = std.Io.Dir.cwd().readFileAlloc(testing.io, "packages/platform/protocols/wayland/wayland.xml", arena.allocator(), .limited(1 << 20)) catch return error.SkipZigTest;
    const p = try parse(arena.allocator(), src, null);
    try testing.expectEqualStrings("wayland", p.name);
    const d = p.interfaces[0];
    try testing.expectEqualStrings("wl_display", d.name);
    try testing.expectEqual(1, d.version);
    try testing.expectEqualStrings("sync", d.requests[0].name);
    try testing.expectEqualStrings("get_registry", d.requests[1].name);
    try testing.expectEqual(ArgType.new_id, d.requests[0].args[0].type);
    try testing.expectEqualStrings("wl_callback", d.requests[0].args[0].interface.?);
    try testing.expectEqualStrings("error", d.events[0].name);
    try testing.expectEqualStrings("asynchronous roundtrip", d.requests[0].summary.?);
    var found_bitfield = false;
    for (p.interfaces) |i| for (i.enums) |e| {
        if (e.bitfield) found_bitfield = true;
    };
    try testing.expect(found_bitfield);
}
