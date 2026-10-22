//! Replacement templates (VS Code / JavaScript style):
//! - `$0` and `$&`: the whole match; `$1`..`$99`: groups (two digits when
//!   that group exists, else one); `${name}` / `${7}`: named or numbered;
//!   `$$`: a dollar sign. Unknown or non-participating groups expand to
//!   nothing.
//! - `\n`, `\t`, `\\`.
//! - Case modifiers: `\u` / `\l` (next character), `\U` ... `\E` and
//!   `\L` ... `\E` (until `\E` or the end).
//! Preserve case (optional) is applied to the expanded text against the
//! whole match.

const std = @import("std");
const zg_text = @import("zg_text");
const preserve_case = @import("preserve_case.zig");

const Allocator = std.mem.Allocator;
const casemap = zg_text.unicode.casemap;

/// Reads the text of capture groups.
pub const Groups = struct {
    ctx: *const anyopaque,
    /// Group `i`'s text, or null when it did not participate (or does not
    /// exist).
    getFn: *const fn (ctx: *const anyopaque, i: usize) ?[]const u8,
    /// Capture group names in index order (index 0 is null).
    names: []const ?[]const u8,

    fn get(g: Groups, i: usize) ?[]const u8 {
        if (i >= g.names.len) return null;
        return g.getFn(g.ctx, i);
    }

    fn named(g: Groups, name: []const u8) ?[]const u8 {
        for (g.names, 0..) |n, i| if (n != null and std.mem.eql(u8, n.?, name)) return g.get(i);
        return null;
    }
};

/// Groups over plain slices (index 0 is the whole match).
pub const SliceGroups = struct {
    texts: []const ?[]const u8,
    names: []const ?[]const u8,

    fn getFn(ctx: *const anyopaque, i: usize) ?[]const u8 {
        const s: *const SliceGroups = @ptrCast(@alignCast(ctx));
        return if (i < s.texts.len) s.texts[i] else null;
    }

    /// The `Groups` view.
    pub fn groups(s: *const SliceGroups) Groups {
        return .{ .ctx = s, .getFn = getFn, .names = s.names };
    }
};

const CaseMode = enum { none, upper, lower };

/// Expands `template` for one match.
pub fn expandReplacement(gpa: Allocator, template: []const u8, g: Groups, preserve: bool) Allocator.Error![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    var mode: CaseMode = .none;
    var one: CaseMode = .none;
    var i: usize = 0;
    while (i < template.len) {
        const c = template[i];
        if (c == '$' and i + 1 < template.len) {
            const d = template[i + 1];
            if (d == '$') {
                try put(&raw, gpa, "$", mode, &one);
                i += 2;
                continue;
            }
            if (d == '&') {
                try put(&raw, gpa, g.get(0) orelse "", mode, &one);
                i += 2;
                continue;
            }
            if (std.ascii.isDigit(d)) {
                var n: usize = d - '0';
                var len: usize = 2;
                if (i + 2 < template.len and std.ascii.isDigit(template[i + 2])) {
                    const two = n * 10 + (template[i + 2] - '0');
                    if (two < g.names.len) {
                        n = two;
                        len = 3;
                    }
                }
                try put(&raw, gpa, g.get(n) orelse "", mode, &one);
                i += len;
                continue;
            }
            if (d == '{') {
                if (std.mem.indexOfScalarPos(u8, template, i + 2, '}')) |close| {
                    const name = template[i + 2 .. close];
                    const text = if (std.fmt.parseInt(usize, name, 10)) |n| g.get(n) else |_| g.named(name);
                    try put(&raw, gpa, text orelse "", mode, &one);
                    i = close + 1;
                    continue;
                }
            }
        }
        if (c == '\\' and i + 1 < template.len) {
            const d = template[i + 1];
            switch (d) {
                'n' => try put(&raw, gpa, "\n", mode, &one),
                't' => try put(&raw, gpa, "\t", mode, &one),
                '\\' => try put(&raw, gpa, "\\", mode, &one),
                'u' => one = .upper,
                'l' => one = .lower,
                'U' => mode = .upper,
                'L' => mode = .lower,
                'E' => mode = .none,
                else => {
                    try put(&raw, gpa, template[i .. i + 2], mode, &one);
                },
            }
            i += 2;
            continue;
        }
        try put(&raw, gpa, template[i .. i + 1], mode, &one);
        i += 1;
    }
    if (preserve) {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try preserve_case.apply(&out, gpa, g.get(0) orelse "", raw.items);
        return out.toOwnedSlice(gpa);
    }
    return gpa.dupe(u8, raw.items);
}

/// Appends `s` under the active case modes; a pending one-character
/// modifier applies to its first character.
fn put(out: *std.ArrayList(u8), gpa: Allocator, s: []const u8, mode: CaseMode, one: *CaseMode) Allocator.Error!void {
    if (s.len == 0) return;
    var rest = s;
    if (one.* != .none) {
        const n = @min(std.unicode.utf8ByteSequenceLength(s[0]) catch 1, s.len);
        try conv(out, gpa, s[0..n], one.*);
        one.* = .none;
        rest = s[n..];
    }
    try conv(out, gpa, rest, mode);
}

fn conv(out: *std.ArrayList(u8), gpa: Allocator, s: []const u8, mode: CaseMode) Allocator.Error!void {
    switch (mode) {
        .none => try out.appendSlice(gpa, s),
        .upper => casemap.toUpper(out, gpa, s) catch return error.OutOfMemory,
        .lower => casemap.toLower(out, gpa, s) catch return error.OutOfMemory,
    }
}
