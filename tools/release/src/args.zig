//! `--name value` option parsing shared by the zg-release subcommands.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Parsed options: `--name value` pairs, repeatable names keep every value.
pub const Options = struct {
    names: []const []const u8 = &.{},
    values: []const []const u8 = &.{},

    /// The last value of `--name`, or null.
    pub fn get(o: *const Options, name: []const u8) ?[]const u8 {
        var i = o.names.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, o.names[i], name)) return o.values[i];
        }
        return null;
    }

    /// The value of a required option, or `error.Usage`.
    pub fn need(o: *const Options, name: []const u8) error{Usage}![]const u8 {
        return o.get(name) orelse {
            std.debug.print("missing --{s}\n", .{name});
            return error.Usage;
        };
    }

    /// Every value of a repeatable `--name`, in order.
    pub fn all(o: *const Options, gpa: Allocator, name: []const u8) Allocator.Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (o.names, o.values) |n, v| if (std.mem.eql(u8, n, name)) try out.append(gpa, v);
        return out.items;
    }
};

/// Everything a subcommand gets.
pub const Context = struct {
    gpa: Allocator,
    io: std.Io,
    env: *const std.process.Environ.Map,
    opts: Options,
};

/// Parses `--name value` pairs. A trailing name without a value, or a bare
/// word, is a usage error.
pub fn parse(gpa: Allocator, argv: []const []const u8) error{ Usage, OutOfMemory }!Options {
    var names: std.ArrayList([]const u8) = .empty;
    var values: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < argv.len) : (i += 2) {
        if (!std.mem.startsWith(u8, argv[i], "--") or i + 1 >= argv.len) return error.Usage;
        try names.append(gpa, argv[i][2..]);
        try values.append(gpa, argv[i + 1]);
    }
    return .{ .names = names.items, .values = values.items };
}

/// Decodes exactly `out.len` bytes of hex.
pub fn hexExact(out: []u8, hex: []const u8) error{InvalidHex}!void {
    const t = std.mem.trim(u8, hex, " \t\r\n");
    if (t.len != out.len * 2) return error.InvalidHex;
    _ = std.fmt.hexToBytes(out, t) catch return error.InvalidHex;
}

test "args: parse" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const o = try parse(arena.allocator(), &.{ "--file", "a", "--file", "b", "--out", "c" });
    try std.testing.expectEqualStrings("b", o.get("file").?);
    try std.testing.expectEqual(@as(usize, 2), (try o.all(arena.allocator(), "file")).len);
    try std.testing.expectError(error.Usage, parse(arena.allocator(), &.{"--file"}));
    try std.testing.expectError(error.Usage, parse(arena.allocator(), &.{ "x", "y" }));
    var id: [8]u8 = undefined;
    try hexExact(&id, "0102030405060708\n");
    try std.testing.expectEqual(@as(u8, 8), id[7]);
    try std.testing.expectError(error.InvalidHex, hexExact(&id, "01"));
}
