//! `file:` URI <-> filesystem path mapping and URI comparison (the URI half
//! of E07.F01.S01.T02; `docUriFromLsp` follows with E05's `DocUri`).
//!
//! Behaviour follows VS Code's `URI.file` / `fsPath`:
//! - `uriFromPath` percent-encodes everything except unreserved characters
//!   and `/`, lowercases a Windows drive letter and encodes its colon
//!   (`C:\a b` -> `file:///c%3A/a%20b`), and maps UNC paths to an
//!   authority (`\\server\share\x` -> `file://server/share/x`).
//! - `pathFromUri` accepts either drive spelling (`/c%3A/x`, `/C:/x`) and
//!   returns `C:\x` with an uppercase drive. On POSIX a non-empty authority
//!   other than `localhost` is rejected.
//! - Non-`file:` URIs give null.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Path syntax of the host the path belongs to.
pub const Style = enum {
    posix,
    windows,

    pub const native: Style = if (builtin.os.tag == .windows) .windows else .posix;
};

pub const Error = error{ OutOfMemory, InvalidUri, UnsupportedAuthority };

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

fn hexVal(c: u8) ?u8 {
    return std.fmt.charToDigit(c, 16) catch null;
}

/// Percent-decodes `s` into `out` (which must be at least `s.len`);
/// returns the decoded length. Malformed escapes are kept literally.
fn decodeInto(s: []const u8, out: []u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            if (hexVal(s[i + 1])) |h| if (hexVal(s[i + 2])) |l| {
                out[n] = h * 16 + l;
                n += 1;
                i += 3;
                continue;
            };
        }
        out[n] = s[i];
        n += 1;
        i += 1;
    }
    return n;
}

fn isDrive(s: []const u8) bool {
    return s.len >= 2 and std.ascii.isAlphabetic(s[0]) and s[1] == ':';
}

/// The `file:` URI of absolute path `abs_path` in the native style.
pub fn uriFromPath(gpa: Allocator, abs_path: []const u8) Allocator.Error![]u8 {
    return uriFromPathStyle(gpa, abs_path, .native);
}

/// `uriFromPath` for an explicit path style.
pub fn uriFromPathStyle(gpa: Allocator, abs_path: []const u8, style: Style) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    var rest = abs_path;
    w.writeAll("file://") catch return error.OutOfMemory;
    if (style == .windows) {
        if (std.mem.startsWith(u8, rest, "\\\\") or std.mem.startsWith(u8, rest, "//")) {
            // UNC: the server becomes the authority.
            rest = rest[2..];
            const end = std.mem.indexOfAny(u8, rest, "\\/") orelse rest.len;
            for (rest[0..end]) |c| try encodeByte(w, std.ascii.toLower(c));
            rest = rest[end..];
        } else if (isDrive(rest)) {
            w.print("/{c}%3A", .{std.ascii.toLower(rest[0])}) catch return error.OutOfMemory;
            rest = rest[2..];
        }
    }
    for (rest) |c| {
        const ch = if (style == .windows and c == '\\') '/' else c;
        try encodeByte(w, ch);
    }
    return out.toOwnedSlice();
}

fn encodeByte(w: *std.Io.Writer, c: u8) Allocator.Error!void {
    if (isUnreserved(c) or c == '/') {
        w.writeByte(c) catch return error.OutOfMemory;
    } else {
        w.print("%{X:0>2}", .{c}) catch return error.OutOfMemory;
    }
}

/// The filesystem path of a `file:` URI in the native style, or null for
/// any other scheme.
pub fn pathFromUri(gpa: Allocator, uri: []const u8) Error!?[]u8 {
    return pathFromUriStyle(gpa, uri, .native);
}

/// `pathFromUri` for an explicit path style.
pub fn pathFromUriStyle(gpa: Allocator, uri: []const u8, style: Style) Error!?[]u8 {
    const prefix = "file:";
    if (uri.len < prefix.len or !std.ascii.eqlIgnoreCase(uri[0..prefix.len], prefix)) return null;
    var rest = uri[prefix.len..];
    // Drop a query or fragment.
    if (std.mem.indexOfAny(u8, rest, "?#")) |i| rest = rest[0..i];
    var authority: []const u8 = "";
    if (std.mem.startsWith(u8, rest, "//")) {
        rest = rest[2..];
        const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        authority = rest[0..end];
        rest = rest[end..];
    }
    if (std.ascii.eqlIgnoreCase(authority, "localhost")) authority = "";

    const buf = try gpa.alloc(u8, rest.len + authority.len + 2);
    errdefer gpa.free(buf);
    var n: usize = 0;
    switch (style) {
        .posix => {
            if (authority.len > 0) return error.UnsupportedAuthority;
            n = decodeInto(rest, buf);
            if (n == 0) {
                buf[0] = '/';
                n = 1;
            }
        },
        .windows => {
            if (authority.len > 0) {
                buf[0] = '\\';
                buf[1] = '\\';
                n = 2 + decodeInto(authority, buf[2..]);
            }
            n += decodeInto(rest, buf[n..]);
            var path = buf[0..n];
            // "/c:/x" -> "c:/x"
            if (authority.len == 0 and path.len >= 3 and path[0] == '/' and isDrive(path[1..])) {
                std.mem.copyForwards(u8, path[0 .. path.len - 1], path[1..]);
                n -= 1;
                path = buf[0..n];
                path[0] = std.ascii.toUpper(path[0]);
            }
            for (path) |*c| if (c.* == '/') {
                c.* = '\\';
            };
        },
    }
    if (n == 0) return error.InvalidUri;
    return try gpa.realloc(buf, n);
}

/// Writes the canonical form of `u` into `buf`: percent escapes decoded,
/// a drive letter lowercased, a trailing `/` removed. Null when `buf` is
/// too small.
fn canonical(u: []const u8, buf: []u8) ?[]const u8 {
    if (u.len > buf.len) return null;
    var n = decodeInto(u, buf);
    const s = buf[0..n];
    // file:///C:/ -> file:///c:/
    if (std.mem.startsWith(u8, s, "file:///") and isDrive(s["file:///".len..])) {
        const i = "file:///".len;
        s[i] = std.ascii.toLower(s[i]);
    }
    if (n > 1 and s[n - 1] == '/' and !std.mem.endsWith(u8, s[0..n], "://")) n -= 1;
    return buf[0..n];
}

/// Whether two URIs name the same resource, ignoring percent-encoding
/// differences, drive-letter case and a trailing slash.
pub fn eqlUri(a: []const u8, b: []const u8) bool {
    if (std.mem.eql(u8, a, b)) return true;
    var ba: [4096]u8 = undefined;
    var bb: [4096]u8 = undefined;
    const ca = canonical(a, &ba) orelse return false;
    const cb = canonical(b, &bb) orelse return false;
    return std.mem.eql(u8, ca, cb);
}
