//! File drops from other apps (E04.F05.S02.T02 prompt hooks).
//!
//! The platform reports a drag over a window (`Event.drop`: enter, over,
//! leave, drop). When the drag offers `text/uri-list`, the window asks
//! the node under the pointer with `InputEvent.drag_files_over`; a widget
//! that returns true accepts, and the window answers the platform with
//! `set_drop_effect` (copy) only when the answer changes. On drop the
//! URI list becomes local paths and the node under the pointer gets
//! `InputEvent.drop_files`. Remote and non-`file:` URIs are skipped.

const std = @import("std");
const builtin = @import("builtin");
const zg_platform = @import("zg_platform");

/// What the window tracks during one external drag.
pub const DropState = struct {
    /// The drag offers a file list.
    files: bool = false,
    /// The last answer sent (null: none yet this drag).
    sent: ?bool = null,
    /// An answer for the Host to send.
    pending: ?bool = null,

    /// Records `accept` as the answer; queued only when it changed.
    pub fn answer(s: *DropState, accept: bool) void {
        if (s.sent == accept) return;
        s.sent = accept;
        s.pending = accept;
    }

    /// The drag ended.
    pub fn reset(s: *DropState) void {
        const pending = s.pending;
        s.* = .{ .pending = pending };
    }
};

/// Whether a packed little-endian `u16` `MimeId` array offers a file list.
pub fn offersFiles(mimes: []const u8) bool {
    var i: usize = 0;
    while (i + 2 <= mimes.len) : (i += 2) {
        if (std.mem.readInt(u16, mimes[i..][0..2], .little) == @intFromEnum(zg_platform.clipboard.MimeId.uri_list)) return true;
    }
    return false;
}

/// The local paths of a `text/uri-list`, allocated in `arena`.
pub fn filePaths(arena: std.mem.Allocator, uris: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (builtin.os.tag == .windows) {
        var it = std.mem.splitScalar(u8, uris, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (try zg_platform.win32.hdrop.uriToPath(arena, line)) |p| try out.append(arena, p);
        }
    } else {
        const packed_paths = try zg_platform.linux_util.uri_list.paths(arena, uris);
        var it = std.mem.splitScalar(u8, packed_paths, 0);
        while (it.next()) |p| if (p.len > 0) try out.append(arena, p);
    }
    return out.items;
}

test "offersFiles finds uri_list among packed ids" {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], @intFromEnum(zg_platform.clipboard.MimeId.text_utf8), .little);
    std.mem.writeInt(u16, buf[2..4], @intFromEnum(zg_platform.clipboard.MimeId.uri_list), .little);
    try std.testing.expect(offersFiles(&buf));
    try std.testing.expect(!offersFiles(buf[0..2]));
    try std.testing.expect(!offersFiles(""));
}

test "filePaths decodes local file URIs and skips the rest" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const got = try filePaths(arena.allocator(), "# comment\r\nfile:///home/me/a%20b.txt\r\nhttps://example.com/x\r\nfile://localhost/tmp/c.md\r\n");
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("/home/me/a b.txt", got[0]);
    try std.testing.expectEqualStrings("/tmp/c.md", got[1]);
}

test "DropState sends an answer only when it changes" {
    var s: DropState = .{};
    s.answer(true);
    try std.testing.expectEqual(@as(?bool, true), s.pending);
    s.pending = null;
    s.answer(true);
    try std.testing.expectEqual(@as(?bool, null), s.pending);
    s.answer(false);
    try std.testing.expectEqual(@as(?bool, false), s.pending);
    s.reset();
    try std.testing.expectEqual(@as(?bool, null), s.sent);
}
