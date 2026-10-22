//! Skill and command argument substitution (E10.F09.S04.T01), as in
//! Claude Code:
//!
//! - `$ARGUMENTS` is the raw argument string;
//! - `$ARGUMENTS[N]` and `$N` are the N-th argument (0-based) of a
//!   shell-like split, empty when missing;
//! - `$name` is the argument at `name`'s position in the frontmatter
//!   `arguments` list (other `$words`, such as `$HOME`, stay);
//! - `${ZIGGURO_SESSION_ID}`, `${ZIGGURO_SKILL_DIR}` and
//!   `${ZIGGURO_PROJECT_DIR}`, and in compat mode the same with `CLAUDE_`;
//! - `\$` writes a literal `$`.
//!
//! When the body has no argument placeholder and arguments were given,
//! `ARGUMENTS: <value>` is appended.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Vars = struct {
    session_id: []const u8 = "",
    skill_dir: []const u8 = "",
    project_dir: []const u8 = "",
    /// Also accept the `CLAUDE_` names.
    compat: bool = false,
};

/// Splits `raw` like a shell: whitespace separates, single quotes keep
/// everything, double quotes keep everything but `\"` and `\\`, and a
/// backslash outside quotes escapes the next character.
pub fn splitArgs(arena: Allocator, raw: []const u8) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var cur: std.ArrayList(u8) = .empty;
    var in_word = false;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        switch (c) {
            ' ', '\t', '\r', '\n' => {
                if (in_word) {
                    try out.append(arena, try cur.toOwnedSlice(arena));
                    in_word = false;
                }
            },
            '\'' => {
                in_word = true;
                const end = std.mem.indexOfScalarPos(u8, raw, i + 1, '\'') orelse raw.len;
                try cur.appendSlice(arena, raw[i + 1 .. end]);
                i = end;
            },
            '"' => {
                in_word = true;
                i += 1;
                while (i < raw.len and raw[i] != '"') : (i += 1) {
                    if (raw[i] == '\\' and i + 1 < raw.len and (raw[i + 1] == '"' or raw[i + 1] == '\\')) i += 1;
                    try cur.append(arena, raw[i]);
                }
            },
            '\\' => {
                in_word = true;
                if (i + 1 < raw.len) {
                    i += 1;
                    try cur.append(arena, raw[i]);
                }
            },
            else => {
                in_word = true;
                try cur.append(arena, c);
            },
        }
    }
    if (in_word) try out.append(arena, try cur.toOwnedSlice(arena));
    return out.items;
}

/// Expands the placeholders in `body`.
pub fn substitute(arena: Allocator, body: []const u8, raw_args: []const u8, names: []const []const u8, vars: Vars) Allocator.Error![]const u8 {
    const raw = std.mem.trim(u8, raw_args, " \t\r\n");
    const args = try splitArgs(arena, raw);
    var out: std.ArrayList(u8) = .empty;
    var used = false;
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c == '\\' and i + 1 < body.len and body[i + 1] == '$') {
            try out.append(arena, '$');
            i += 2;
            continue;
        }
        if (c != '$' or i + 1 >= body.len) {
            try out.append(arena, c);
            i += 1;
            continue;
        }
        const rest = body[i + 1 ..];
        if (rest[0] == '{') if (std.mem.indexOfScalar(u8, rest, '}')) |close| {
            if (variable(rest[1..close], vars)) |v| {
                try out.appendSlice(arena, v);
                i += close + 2;
                continue;
            }
        };
        if (std.mem.startsWith(u8, rest, "ARGUMENTS")) {
            const after = rest["ARGUMENTS".len..];
            if (after.len > 0 and after[0] == '[') if (std.mem.indexOfScalar(u8, after, ']')) |close| {
                if (std.fmt.parseInt(usize, after[1..close], 10)) |n| {
                    try out.appendSlice(arena, if (n < args.len) args[n] else "");
                    used = true;
                    i += 1 + "ARGUMENTS".len + close + 1;
                    continue;
                } else |_| {}
            };
            if (after.len == 0 or !isWord(after[0])) {
                try out.appendSlice(arena, raw);
                used = true;
                i += 1 + "ARGUMENTS".len;
                continue;
            }
        }
        if (std.ascii.isDigit(rest[0])) {
            var end: usize = 0;
            while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
            const n = std.fmt.parseInt(usize, rest[0..end], 10) catch std.math.maxInt(usize);
            try out.appendSlice(arena, if (n < args.len) args[n] else "");
            used = true;
            i += 1 + end;
            continue;
        }
        if (isWordStart(rest[0])) {
            var end: usize = 0;
            while (end < rest.len and isWord(rest[end])) end += 1;
            if (indexOf(names, rest[0..end])) |n| {
                try out.appendSlice(arena, if (n < args.len) args[n] else "");
                used = true;
                i += 1 + end;
                continue;
            }
        }
        try out.append(arena, '$');
        i += 1;
    }
    if (!used and raw.len > 0) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(arena, '\n');
        try out.print(arena, "\nARGUMENTS: {s}", .{raw});
    }
    return out.items;
}

fn variable(name: []const u8, vars: Vars) ?[]const u8 {
    const suffix = if (std.mem.startsWith(u8, name, "ZIGGURO_"))
        name["ZIGGURO_".len..]
    else if (vars.compat and std.mem.startsWith(u8, name, "CLAUDE_"))
        name["CLAUDE_".len..]
    else
        return null;
    if (std.mem.eql(u8, suffix, "SESSION_ID")) return vars.session_id;
    if (std.mem.eql(u8, suffix, "SKILL_DIR")) return vars.skill_dir;
    if (std.mem.eql(u8, suffix, "PROJECT_DIR")) return vars.project_dir;
    return null;
}

fn isWordStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn indexOf(names: []const []const u8, s: []const u8) ?usize {
    for (names, 0..) |n, k| if (std.mem.eql(u8, n, s)) return k;
    return null;
}
