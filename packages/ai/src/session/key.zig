//! Directory keys shared by sessions (E10.F08) and auto memory
//! (E10.F07.S01.T03): `<slug>-<hex16>`, where `hex16` is the first 16 hex
//! digits of the SHA-256 of the canonical root path and `slug` is a
//! readable form of its last component. Every lane and worktree of one
//! repository passes the same repository root and so shares the key.

const std = @import("std");
const builtin = @import("builtin");

/// Maximum slug length.
pub const max_slug = 24;
/// Maximum key length.
pub const max_len = max_slug + 1 + 16;

/// Writes the key for `root` into `buf` and returns it. Trailing
/// separators are ignored; on Windows the path is hashed lowercased with
/// `/` separators, so drive-letter case and separator style do not matter.
pub fn workspaceKey(buf: *[max_len]u8, root: []const u8) []const u8 {
    var r = root;
    while (r.len > 1 and (r[r.len - 1] == '/' or r[r.len - 1] == '\\')) r = r[0 .. r.len - 1];
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    if (builtin.os.tag == .windows) {
        for (r) |c| h.update(&.{if (c == '\\') '/' else std.ascii.toLower(c)});
    } else h.update(r);
    var digest: [32]u8 = undefined;
    h.final(&digest);

    const base = std.fs.path.basename(r);
    var n: usize = 0;
    var dash = false;
    for (base) |c| {
        if (n == max_slug) break;
        if (std.ascii.isAlphanumeric(c)) {
            buf[n] = std.ascii.toLower(c);
            n += 1;
            dash = false;
        } else if (!dash and n > 0) {
            buf[n] = '-';
            n += 1;
            dash = true;
        }
    }
    while (n > 0 and buf[n - 1] == '-') n -= 1;
    if (n == 0) {
        @memcpy(buf[0..4], "root");
        n = 4;
    }
    buf[n] = '-';
    const hex = std.fmt.bytesToHex(digest[0..8], .lower);
    @memcpy(buf[n + 1 ..][0..16], &hex);
    return buf[0 .. n + 17];
}

test "workspace key" {
    var b1: [max_len]u8 = undefined;
    var b2: [max_len]u8 = undefined;
    const k = workspaceKey(&b1, "/home/me/My Project.git/");
    try std.testing.expect(std.mem.startsWith(u8, k, "my-project-git-"));
    try std.testing.expectEqual(@as(usize, "my-project-git-".len + 16), k.len);
    try std.testing.expectEqualStrings(k, workspaceKey(&b2, "/home/me/My Project.git"));
    try std.testing.expect(!std.mem.eql(u8, k, workspaceKey(&b2, "/home/you/My Project.git")));
    try std.testing.expect(std.mem.startsWith(u8, workspaceKey(&b2, "/"), "root-"));
}
