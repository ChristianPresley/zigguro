//! Path redaction for exported traces: every path component is replaced by
//! the first 8 hex digits of its hash, keeping the extension, so a trace
//! can be shared without revealing file or folder names.

const std = @import("std");

/// What exporters redact.
pub const Redact = enum { none, paths };

/// True when `s` looks like a path (contains a separator).
pub fn isPath(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, "/\\") != null;
}

/// Writes `s` with each path component hashed (`src/main.zig` becomes
/// `1a2b3c4d/5e6f7a8b.zig`). Strings without a separator are written as is.
pub fn writeRedacted(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    if (!isPath(s)) return w.writeAll(s);
    var start: usize = 0;
    var i: usize = 0;
    while (i <= s.len) : (i += 1) {
        if (i < s.len and s[i] != '/' and s[i] != '\\') continue;
        const comp = s[start..i];
        if (comp.len != 0) {
            const dot = std.mem.lastIndexOfScalar(u8, comp, '.');
            const stem = if (dot) |d| (if (d == 0) comp else comp[0..d]) else comp;
            const ext = if (dot) |d| (if (d == 0) "" else comp[d..]) else "";
            const h: u32 = @truncate(std.hash.Wyhash.hash(0x7a69, stem));
            try w.print("{x:0>8}{s}", .{ h, ext });
        }
        if (i < s.len) try w.writeByte(s[i]);
        start = i + 1;
    }
}

/// `writeRedacted` into `buf` (truncated to it).
pub fn redactInto(buf: []u8, s: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    writeRedacted(&w, s) catch {};
    return w.buffered();
}

test "redact: path components hashed" {
    var buf: [128]u8 = undefined;
    const r = redactInto(&buf, "/home/me/src/main.zig");
    try std.testing.expect(std.mem.indexOf(u8, r, "home") == null);
    try std.testing.expect(std.mem.indexOf(u8, r, "main") == null);
    try std.testing.expect(std.mem.endsWith(u8, r, ".zig"));
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, r, "/"));
    // Deterministic.
    var buf2: [128]u8 = undefined;
    try std.testing.expectEqualStrings("gui.layout", redactInto(&buf2, "gui.layout"));
    try std.testing.expectEqualStrings(r, redactInto(&buf2, "/home/me/src/main.zig"));
    try std.testing.expect(std.mem.indexOf(u8, redactInto(&buf2, "C:\\Users\\me\\a.txt"), "Users") == null);
}
