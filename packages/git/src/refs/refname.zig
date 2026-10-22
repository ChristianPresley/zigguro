//! Reference name validation (git-check-ref-format).

const std = @import("std");

/// Options for `checkRefFormat`.
pub const Options = struct {
    /// Allow names without a '/' ("HEAD", "main").
    allow_onelevel: bool = false,
    /// Allow a single '*' as a whole path component (refspec patterns).
    refspec_pattern: bool = false,
    /// `--branch` rule: the name may not start with '-'.
    branch: bool = false,
};

/// Whether `name` is a valid reference name under git's rules:
///  1. no component starts with '.' or ends with ".lock";
///  2. at least one '/' unless `allow_onelevel`;
///  3. no ".." anywhere;
///  4. no ASCII control characters, space, '~', '^' or ':';
///  5. no '?', '[' or '*' (one '*' component with `refspec_pattern`);
///  6. no leading or trailing '/' and no "//";
///  7. does not end with '.';
///  8. no "@{";
///  9. is not "@";
/// 10. no '\'.
pub fn checkRefFormat(name: []const u8, opts: Options) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, "@")) return false;
    if (opts.branch and name[0] == '-') return false;
    if (name[0] == '/' or name[name.len - 1] == '/' or name[name.len - 1] == '.') return false;
    if (std.mem.indexOf(u8, name, "..") != null or std.mem.indexOf(u8, name, "@{") != null) return false;
    if (std.mem.indexOf(u8, name, "//") != null) return false;
    var stars: usize = 0;
    var comps = std.mem.splitScalar(u8, name, '/');
    var n: usize = 0;
    while (comps.next()) |c| : (n += 1) {
        if (c.len == 0 or c[0] == '.') return false;
        if (std.mem.endsWith(u8, c, ".lock")) return false;
        for (c) |ch| switch (ch) {
            0...0x20, 0x7f, '~', '^', ':', '?', '[', '\\' => return false,
            '*' => {
                if (!opts.refspec_pattern) return false;
                stars += 1;
            },
            else => {},
        };
    }
    if (stars > 1) return false;
    if (n < 2 and !opts.allow_onelevel) return false;
    return true;
}

test "refname: table of valid/invalid from docs" {
    const t = std.testing;
    const valid = [_][]const u8{ "refs/heads/main", "refs/tags/v1.0", "refs/heads/feature/x-y_z", "refs/heads/a.b", "refs/heads/ü" };
    for (valid) |v| try t.expect(checkRefFormat(v, .{}));
    const invalid = [_][]const u8{
        "main",           "refs/heads/.hidden", "refs/heads/x.lock", "refs/heads/a..b",
        "refs/heads/a b", "refs/heads/a~1",     "refs/heads/a^",     "refs/heads/a:b",
        "refs/heads/a?",  "refs/heads/a[",      "refs/heads/a*",     "/refs/heads/a",
        "refs/heads/a/",  "refs//heads",        "refs/heads/a.",     "refs/heads/a@{1}",
        "@",              "refs/heads/a\\b",    "refs/heads/\x01",   "refs/heads/a\x7f",
        "",
    };
    for (invalid) |v| try t.expect(!checkRefFormat(v, .{}));
    try t.expect(checkRefFormat("HEAD", .{ .allow_onelevel = true }));
    try t.expect(checkRefFormat("refs/heads/*", .{ .refspec_pattern = true }));
    try t.expect(checkRefFormat("refs/heads/foo*", .{ .refspec_pattern = true }));
    try t.expect(!checkRefFormat("refs/*/a*", .{ .refspec_pattern = true }));
    try t.expect(!checkRefFormat("-bad", .{ .allow_onelevel = true, .branch = true }));
}
