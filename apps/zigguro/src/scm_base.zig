//! The gutter's change bars against git `HEAD` (E09 IDE integration): an
//! open file inside a git working tree diffs against its committed text
//! instead of the text on disk. The blob is decoded like the document
//! (encoding, and CRLF when the file on disk uses it while the repository
//! stores LF, as `core.autocrlf` does). `headCommit` tells the workbench
//! when HEAD moved (a commit, checkout or reset), so it can diff again.

const std = @import("std");
const zg_git = @import("zg_git");
const zg_editor = @import("zg_editor");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Encoding = zg_editor.model.encoding.Encoding;
const Eol = zg_editor.model.buffer.eol.Eol;

/// The digest of the commit HEAD points at in the working tree holding
/// `abs`; null outside a git working tree or on an unborn branch.
pub fn headCommit(gpa: Allocator, io: Io, abs: []const u8) !?[32]u8 {
    var d = (try zg_git.worktree.discover(gpa, io, abs)) orelse return null;
    defer d.deinit(gpa);
    const id = (try zg_git.worktree.headId(gpa, io, &d)) orelse return null;
    return id.bytes;
}

/// `abs`'s text at `HEAD`, decoded; null outside a git working tree or
/// when HEAD has no such file. Blocking (a few file reads).
pub fn headText(gpa: Allocator, io: Io, abs: []const u8, encoding: Encoding, eol: Eol) !?[]u8 {
    var d = (try zg_git.worktree.discover(gpa, io, abs)) orelse return null;
    defer d.deinit(gpa);
    const rel = (try d.relative(gpa, abs)) orelse return null;
    defer gpa.free(rel);
    const blob = (try zg_git.worktree.readHeadFile(gpa, io, &d, rel)) orelse return null;
    defer gpa.free(blob);
    const text = try zg_editor.model.encoding.decodeAll(encoding, blob, gpa);
    if (eol != .crlf or std.mem.indexOfScalar(u8, text, '\r') != null) return text;
    defer gpa.free(text);
    return try toCrlf(gpa, text);
}

fn toCrlf(gpa: Allocator, text: []const u8) ![]u8 {
    const n = std.mem.count(u8, text, "\n");
    const out = try gpa.alloc(u8, text.len + n);
    var j: usize = 0;
    for (text) |c| {
        if (c == '\n') {
            out[j] = '\r';
            j += 1;
        }
        out[j] = c;
        j += 1;
    }
    return out;
}

test "scm base: CRLF working copies of LF blobs" {
    const gpa = std.testing.allocator;
    const out = try toCrlf(gpa, "a\nb\n\nc");
    defer gpa.free(out);
    try std.testing.expectEqualStrings("a\r\nb\r\n\r\nc", out);
}
