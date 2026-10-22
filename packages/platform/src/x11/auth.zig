//! `DISPLAY` parsing and Xauthority cookies (MIT-MAGIC-COOKIE-1).

const std = @import("std");

/// A parsed `[host]:display[.screen]`.
pub const Display = struct {
    /// Empty for the local socket.
    host: []const u8,
    display: u32,
    screen: u32,

    /// Whether the display is on this machine (a local socket).
    pub fn isLocal(d: Display) bool {
        return d.host.len == 0 or std.mem.eql(u8, d.host, "unix") or std.mem.eql(u8, d.host, "localhost");
    }
};

/// Parses `DISPLAY`. A `unix/` or `unix:` prefix means local.
pub fn parseDisplay(s: []const u8) error{InvalidDisplay}!Display {
    var rest = s;
    if (std.mem.startsWith(u8, rest, "unix/")) rest = rest["unix/".len..];
    const colon = std.mem.lastIndexOfScalar(u8, rest, ':') orelse return error.InvalidDisplay;
    const host = rest[0..colon];
    const num = rest[colon + 1 ..];
    const dot = std.mem.indexOfScalar(u8, num, '.');
    const disp = std.fmt.parseInt(u32, num[0 .. dot orelse num.len], 10) catch return error.InvalidDisplay;
    const screen = if (dot) |d| std.fmt.parseInt(u32, num[d + 1 ..], 10) catch return error.InvalidDisplay else 0;
    return .{ .host = host, .display = disp, .screen = screen };
}

/// An authorization protocol name and its data.
pub const Cookie = struct {
    name: []const u8,
    data: []const u8,
};

/// The only protocol we send.
pub const mit_magic_cookie = "MIT-MAGIC-COOKIE-1";

const family_local: u16 = 256;
const family_wild: u16 = 65535;
const family_inet: u16 = 0;

/// Finds the cookie for `display` on `hostname` in Xauthority file
/// contents: family Local with our hostname, or the wildcard family, with
/// a matching (or empty) display number and MIT-MAGIC-COOKIE-1. Slices
/// point into `bytes`.
pub fn findCookie(bytes: []const u8, display: u32, hostname: []const u8) ?Cookie {
    var num_buf: [10]u8 = undefined;
    const num = std.fmt.bufPrint(&num_buf, "{d}", .{display}) catch unreachable;
    var i: usize = 0;
    while (true) {
        if (i + 2 > bytes.len) return null;
        const family = std.mem.readInt(u16, bytes[i..][0..2], .big);
        i += 2;
        var fields: [4][]const u8 = undefined;
        for (&fields) |*f| {
            if (i + 2 > bytes.len) return null;
            const len = std.mem.readInt(u16, bytes[i..][0..2], .big);
            i += 2;
            if (i + len > bytes.len) return null;
            f.* = bytes[i..][0..len];
            i += len;
        }
        const address, const number, const name, const data = fields;
        const host_ok = switch (family) {
            family_wild => true,
            family_local => std.mem.eql(u8, address, hostname),
            // 127.0.0.1 entries also describe the local display.
            family_inet => std.mem.eql(u8, address, &.{ 127, 0, 0, 1 }),
            else => false,
        };
        const num_ok = number.len == 0 or std.mem.eql(u8, number, num);
        if (host_ok and num_ok and std.mem.eql(u8, name, mit_magic_cookie)) return .{ .name = name, .data = data };
    }
}

/// Reads the Xauthority file at `path` into `gpa` memory (the caller
/// frees it) and finds the cookie for `display`. Null when the file is
/// missing or has no match; slices point into `*out_bytes`.
pub fn readXauthority(gpa: std.mem.Allocator, io: std.Io, path: []const u8, display: u32, hostname: []const u8, out_bytes: *?[]u8) !?Cookie {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    out_bytes.* = bytes;
    return findCookie(bytes, display, hostname);
}

const testing = std.testing;

test "parse DISPLAY forms" {
    const a = try parseDisplay(":0");
    try testing.expectEqualStrings("", a.host);
    try testing.expectEqual(0, a.display);
    try testing.expect(a.isLocal());
    const b = try parseDisplay("unix:12.3");
    try testing.expectEqual(12, b.display);
    try testing.expectEqual(3, b.screen);
    try testing.expect(b.isLocal());
    const c = try parseDisplay("remote.example:1");
    try testing.expectEqualStrings("remote.example", c.host);
    try testing.expect(!c.isLocal());
    try testing.expectError(error.InvalidDisplay, parseDisplay("nocolon"));
    try testing.expectError(error.InvalidDisplay, parseDisplay(":x"));
    try testing.expectEqual(99, (try parseDisplay("unix/:99")).display);
}

fn record(out: *std.ArrayList(u8), family: u16, address: []const u8, number: []const u8, name: []const u8, data: []const u8) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, family, .big);
    try out.appendSlice(testing.allocator, &b);
    for ([_][]const u8{ address, number, name, data }) |f| {
        std.mem.writeInt(u16, &b, @intCast(f.len), .big);
        try out.appendSlice(testing.allocator, &b);
        try out.appendSlice(testing.allocator, f);
    }
}

test "Xauthority match local/wildcard" {
    var f: std.ArrayList(u8) = .empty;
    defer f.deinit(testing.allocator);
    try record(&f, family_local, "otherhost", "0", mit_magic_cookie, "AAAA");
    try record(&f, family_local, "myhost", "1", mit_magic_cookie, "BBBB");
    try record(&f, family_local, "myhost", "0", "XDM-AUTHORIZATION-1", "CCCC");
    try record(&f, family_local, "myhost", "0", mit_magic_cookie, "DDDD");
    try record(&f, family_wild, "", "5", mit_magic_cookie, "EEEE");
    try testing.expectEqualStrings("DDDD", findCookie(f.items, 0, "myhost").?.data);
    try testing.expectEqualStrings("BBBB", findCookie(f.items, 1, "myhost").?.data);
    try testing.expectEqualStrings("EEEE", findCookie(f.items, 5, "anyhost").?.data);
    try testing.expectEqual(null, findCookie(f.items, 7, "myhost"));
    // Truncated files end the search without crashing.
    try testing.expectEqual(null, findCookie(f.items[0 .. f.items.len - 3], 5, "anyhost"));
}
