//! `@path` imports inside memory files (E10.F07.S01.T02): a token that
//! starts with `@` at the start of a line or after whitespace, outside
//! inline code spans and fenced code blocks. `\ ` escapes a space in the
//! path. Resolution (relative to the importing file, depth, cycles, trust)
//! is the loader's job.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// One import token.
pub const Import = struct {
    /// The path as written, with `\ ` unescaped.
    path: []const u8,
    /// 1-based line of the token.
    line: u32,
};

/// Collects the imports in `text`. Paths are allocated in `arena`.
pub fn scan(arena: Allocator, text: []const u8) Allocator.Error![]const Import {
    var out: std.ArrayList(Import) = .empty;
    var fence: ?[]const u8 = null;
    var line_no: u32 = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        const lead = std.mem.trimStart(u8, line, " ");
        if (fenceMarker(lead)) |m| {
            if (fence) |f| {
                if (std.mem.startsWith(u8, lead, f) and std.mem.trim(u8, lead[m.len..], " `~").len == 0) fence = null;
            } else fence = m;
            continue;
        }
        if (fence != null) continue;
        // Indented code blocks (4 spaces) are code too.
        if (line.len - lead.len >= 4) continue;
        var k: usize = 0;
        var in_code: usize = 0; // backtick run length of the open code span
        while (k < line.len) {
            const c = line[k];
            if (c == '`') {
                var n: usize = 0;
                while (k + n < line.len and line[k + n] == '`') n += 1;
                if (in_code == 0) in_code = n else if (in_code == n) in_code = 0;
                k += n;
                continue;
            }
            if (in_code == 0 and c == '@' and (k == 0 or line[k - 1] == ' ' or line[k - 1] == '\t' or line[k - 1] == '(')) {
                var path: std.ArrayList(u8) = .empty;
                var j = k + 1;
                while (j < line.len) : (j += 1) {
                    const d = line[j];
                    if (d == '\\' and j + 1 < line.len and line[j + 1] == ' ') {
                        try path.append(arena, ' ');
                        j += 1;
                        continue;
                    }
                    if (d == ' ' or d == '\t' or d == ')' or d == '`' or d == ',' or d == ';') break;
                    try path.append(arena, d);
                }
                // Trailing sentence punctuation is not part of the path.
                while (path.items.len > 0 and (path.getLast() == '.' or path.getLast() == ':')) _ = path.pop();
                if (looksLikePath(path.items)) try out.append(arena, .{ .path = path.items, .line = line_no });
                k = j;
                continue;
            }
            k += 1;
        }
    }
    return out.items;
}

fn fenceMarker(lead: []const u8) ?[]const u8 {
    for ([_]u8{ '`', '~' }) |ch| {
        var n: usize = 0;
        while (n < lead.len and lead[n] == ch) n += 1;
        if (n >= 3) return lead[0..n];
    }
    return null;
}

/// Mentions like `@alice` are not paths: require a separator or a dot.
fn looksLikePath(p: []const u8) bool {
    if (p.len == 0) return false;
    return std.mem.indexOfAny(u8, p, "/\\.") != null or std.mem.eql(u8, p, "~");
}

test "imports outside code" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text =
        \\See @docs/conventions.md and @README.md.
        \\Ping @alice about it; mail bob@example.com.
        \\Inline `@not/this.md` but (@this/one.md).
        \\```
        \\@inside/fence.md
        \\```
        \\    @indented/code.md
        \\~~~zig
        \\@tilde/fence.md
        \\~~~
        \\@my\ file.md
        \\@~/notes.md
    ;
    const imps = try scan(a, text);
    const want = [_][]const u8{ "docs/conventions.md", "README.md", "this/one.md", "my file.md", "~/notes.md" };
    try std.testing.expectEqual(want.len, imps.len);
    for (want, imps) |w, i| try std.testing.expectEqualStrings(w, i.path);
    try std.testing.expectEqual(@as(u32, 11), imps[3].line);
}
