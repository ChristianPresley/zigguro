//! JSONC (comments and trailing commas) to JSON for `tasks.json` and
//! `launch.json`: the stripper of zg_config's `jsonc.zig`, which sits on
//! the same layer (zg_config depends on zg_gui, so zg_dap does not import
//! it). Comments and trailing commas become spaces and no byte moves, so
//! std.json's error offsets point into the original text.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Errors of `stripJsonc`.
pub const StripError = error{ OutOfMemory, UnterminatedComment };

/// Returns a copy of `src` with comments replaced by spaces (newlines kept)
/// and trailing commas before `}`/`]` replaced by a space. Byte offsets are
/// unchanged. `//` inside strings is kept.
pub fn stripJsonc(gpa: Allocator, src: []const u8) StripError![]u8 {
    const out = try gpa.dupe(u8, src);
    errdefer gpa.free(out);
    try stripInPlace(out);
    return out;
}

/// `stripJsonc` on a mutable buffer.
pub fn stripInPlace(buf: []u8) error{UnterminatedComment}!void {
    var i: usize = 0;
    // Index of a comma that is the last significant byte so far, if any.
    var pending_comma: ?usize = null;
    while (i < buf.len) {
        const c = buf[i];
        switch (c) {
            '"' => {
                pending_comma = null;
                i += 1;
                while (i < buf.len and buf[i] != '"') : (i += 1) {
                    if (buf[i] == '\\') i += 1;
                }
                i += 1;
            },
            '/' => {
                if (i + 1 < buf.len and buf[i + 1] == '/') {
                    while (i < buf.len and buf[i] != '\n') : (i += 1) buf[i] = ' ';
                } else if (i + 1 < buf.len and buf[i + 1] == '*') {
                    const start = i;
                    i += 2;
                    while (i + 1 < buf.len and !(buf[i] == '*' and buf[i + 1] == '/')) i += 1;
                    if (i + 1 >= buf.len) return error.UnterminatedComment;
                    i += 2;
                    for (buf[start..i]) |*b| {
                        if (b.* != '\n' and b.* != '\r') b.* = ' ';
                    }
                } else {
                    pending_comma = null;
                    i += 1;
                }
            },
            ',' => {
                pending_comma = i;
                i += 1;
            },
            '}', ']' => {
                if (pending_comma) |p| buf[p] = ' ';
                pending_comma = null;
                i += 1;
            },
            ' ', '\t', '\r', '\n' => i += 1,
            else => {
                pending_comma = null;
                i += 1;
            },
        }
    }
}
