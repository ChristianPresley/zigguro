//! AT-SPI2 object paths and references (E04.F09.S01.T03). The
//! application is `/org/a11y/atspi/accessible/root`; each node is
//! `/org/a11y/atspi/accessible/<16 hex digits of its id>`, so a path maps
//! back to a node without any per-node registration.

const std = @import("std");

pub const prefix = "/org/a11y/atspi/accessible/";
/// The application object.
pub const root_path = prefix ++ "root";
/// The path of a null reference.
pub const null_path = "/org/a11y/atspi/null";

/// An object reference, `(so)`: the owning connection's bus name and the
/// object's path.
pub const Ref = struct {
    name: []const u8,
    path: []const u8,

    /// The null reference.
    pub const none: Ref = .{ .name = "", .path = null_path };
};

/// Room for one node path.
pub const PathBuf = [prefix.len + 16]u8;

/// The path of node `id`.
pub fn pathOf(id: u64, buf: *PathBuf) []const u8 {
    @memcpy(buf[0..prefix.len], prefix);
    _ = std.fmt.bufPrint(buf[prefix.len..], "{x:0>16}", .{id}) catch unreachable;
    return buf;
}

/// The path of node `id`, allocated in `a`.
pub fn pathAlloc(a: std.mem.Allocator, id: u64) std.mem.Allocator.Error![]const u8 {
    const buf = try a.create(PathBuf);
    return pathOf(id, buf);
}

/// What a path names.
pub const Target = union(enum) {
    application,
    node: u64,
};

/// Parses an object path served by the bridge.
pub fn parse(path: []const u8) ?Target {
    if (std.mem.eql(u8, path, root_path)) return .application;
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const hex = path[prefix.len..];
    if (hex.len != 16) return null;
    return .{ .node = std.fmt.parseInt(u64, hex, 16) catch return null };
}

test "paths round-trip" {
    var buf: PathBuf = undefined;
    const p = pathOf(0x0000_0003_0100_002a, &buf);
    try std.testing.expectEqualStrings("/org/a11y/atspi/accessible/000000030100002a", p);
    try std.testing.expectEqual(Target{ .node = 0x0000_0003_0100_002a }, parse(p).?);
    try std.testing.expectEqual(Target.application, parse(root_path).?);
    try std.testing.expect(parse("/org/a11y/atspi/accessible/xyz") == null);
    try std.testing.expect(parse("/other") == null);
}
