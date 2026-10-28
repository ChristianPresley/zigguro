//! Snippet transforms (E07.F03.S01.T01): `${1/regex/format/flags}` and
//! `${VAR/regex/format/flags}`. The regex is compiled with zg_regex
//! (RE2 syntax, close to the JavaScript patterns snippets are written
//! in); the JavaScript flags map to `g` (replace every match), `i`
//! (case-insensitive) and `m` (multi-line); `u`, `s` and `y` are
//! accepted and ignored. A pattern zg_regex rejects (backreferences,
//! look-around) makes the transform a no-op: the text passes through.
//!
//! Format strings insert groups (`$1`, `${1}`), case-convert them
//! (`${1:/upcase}` and downcase, capitalize, camelcase, pascalcase,
//! snakecase, kebabcase) or choose text by whether a group matched
//! (`${1:+if}`, `${1:?if:else}`, `${1:-else}`, `${1:else}`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const zg_regex = @import("zg_regex");

const log = std.log.scoped(.snippet);

pub const CaseOp = enum { upcase, downcase, capitalize, camelcase, pascalcase, snakecase, kebabcase };

pub const FormatItem = union(enum) {
    text: []const u8,
    group: u32,
    case: struct { group: u32, op: CaseOp },
    if_else: struct { group: u32, if_text: ?[]const u8, else_text: ?[]const u8 },
};

pub const Transform = struct {
    /// Null when the pattern did not compile (the transform is a no-op).
    regex: ?zg_regex.Regex,
    format: []const FormatItem,
    global: bool = false,
    case_insensitive: bool = false,
    multiline: bool = false,
    /// Search scratch, kept between uses (one thread at a time).
    scratch: ?*Scratch = null,

    const Scratch = struct { cache: zg_regex.Cache, caps: zg_regex.Captures };

    /// Compiles `pattern` with the JavaScript `flags`.
    pub fn init(gpa: Allocator, pattern: []const u8, format: []const FormatItem, flags: []const u8) Allocator.Error!Transform {
        var t: Transform = .{ .regex = null, .format = format };
        for (flags) |c| switch (c) {
            'g' => t.global = true,
            'i' => t.case_insensitive = true,
            'm' => t.multiline = true,
            else => log.debug("snippet transform flag '{c}' ignored", .{c}),
        };
        t.regex = zg_regex.Regex.compile(gpa, pattern, .{ .case_insensitive = t.case_insensitive, .multi_line = t.multiline }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => blk: {
                log.warn("snippet transform /{s}/ not supported ({t}); text left as is", .{ pattern, e });
                break :blk null;
            },
        };
        if (t.regex) |*re| {
            errdefer re.deinit(gpa);
            const sc = try gpa.create(Scratch);
            errdefer gpa.destroy(sc);
            sc.cache = try re.newCache(gpa);
            errdefer sc.cache.deinit();
            sc.caps = try re.newCaptures(gpa);
            t.scratch = sc;
        }
        return t;
    }

    pub fn deinit(t: *Transform, gpa: Allocator) void {
        if (t.scratch) |sc| {
            sc.cache.deinit();
            sc.caps.deinit(gpa);
            gpa.destroy(sc);
        }
        t.scratch = null;
        if (t.regex) |*r| r.deinit(gpa);
        t.regex = null;
    }
};

/// Appends `input` transformed by `t` to `out`.
pub fn applyTransform(gpa: Allocator, t: *const Transform, input: []const u8, out: *std.ArrayList(u8)) Allocator.Error!void {
    const re = if (t.regex) |*r| r else return out.appendSlice(gpa, input);
    const sc = t.scratch.?;
    const cache = &sc.cache;
    const caps = &sc.caps;
    const whole: zg_regex.Input = .fromSlice(input);
    var at: usize = 0;
    var copied: usize = 0;
    while (at <= input.len) {
        if (!re.captures(cache, whole.withSpan(.{ .start = at, .end = input.len }), caps)) break;
        const m = caps.get(0).?;
        const s: usize = @intCast(m.start);
        const e: usize = @intCast(m.end);
        try out.appendSlice(gpa, input[copied..s]);
        try applyFormat(gpa, t.format, input, caps, out);
        copied = e;
        if (!t.global) break;
        if (e > s) {
            at = e;
            continue;
        }
        // An empty match: keep the next character and move past it.
        if (e >= input.len) break;
        const n = @min(input.len - e, std.unicode.utf8ByteSequenceLength(input[e]) catch 1);
        try out.appendSlice(gpa, input[e .. e + n]);
        copied = e + n;
        at = e + n;
    }
    if (copied < input.len) try out.appendSlice(gpa, input[copied..]);
}

fn groupText(input: []const u8, caps: *const zg_regex.Captures, g: u32) ?[]const u8 {
    if (g >= caps.len()) return null;
    const m = caps.get(g) orelse return null;
    return input[@intCast(m.start)..@intCast(m.end)];
}

fn applyFormat(gpa: Allocator, items: []const FormatItem, input: []const u8, caps: *const zg_regex.Captures, out: *std.ArrayList(u8)) Allocator.Error!void {
    for (items) |it| switch (it) {
        .text => |x| try out.appendSlice(gpa, x),
        .group => |g| if (groupText(input, caps, g)) |x| try out.appendSlice(gpa, x),
        .case => |c| if (groupText(input, caps, c.group)) |x| try convertCase(gpa, c.op, x, out),
        .if_else => |ie| {
            const matched = if (groupText(input, caps, ie.group)) |x| x.len > 0 else false;
            if (if (matched) ie.if_text else ie.else_text) |x| try out.appendSlice(gpa, x);
        },
    };
}

/// Appends `s` in case `op`. The word splitting cases split on `_`, `-`,
/// spaces and lower-to-upper boundaries (ASCII case mapping).
pub fn convertCase(gpa: Allocator, op: CaseOp, s: []const u8, out: *std.ArrayList(u8)) Allocator.Error!void {
    switch (op) {
        .upcase => for (s) |c| try out.append(gpa, std.ascii.toUpper(c)),
        .downcase => for (s) |c| try out.append(gpa, std.ascii.toLower(c)),
        .capitalize => {
            if (s.len == 0) return;
            try out.append(gpa, std.ascii.toUpper(s[0]));
            try out.appendSlice(gpa, s[1..]);
        },
        .camelcase, .pascalcase, .snakecase, .kebabcase => {
            var it: WordIter = .{ .s = s };
            var first = true;
            while (it.next()) |w| {
                switch (op) {
                    .camelcase, .pascalcase => {
                        const up = !first or op == .pascalcase;
                        try out.append(gpa, if (up) std.ascii.toUpper(w[0]) else std.ascii.toLower(w[0]));
                        for (w[1..]) |c| try out.append(gpa, std.ascii.toLower(c));
                    },
                    else => {
                        if (!first) try out.append(gpa, if (op == .snakecase) '_' else '-');
                        for (w) |c| try out.append(gpa, std.ascii.toLower(c));
                    },
                }
                first = false;
            }
        },
    }
}

const WordIter = struct {
    s: []const u8,
    i: usize = 0,

    fn isSep(c: u8) bool {
        return c == '_' or c == '-' or c == ' ' or c == '\t';
    }

    fn next(it: *WordIter) ?[]const u8 {
        while (it.i < it.s.len and isSep(it.s[it.i])) it.i += 1;
        if (it.i >= it.s.len) return null;
        const start = it.i;
        it.i += 1;
        while (it.i < it.s.len and !isSep(it.s[it.i])) : (it.i += 1) {
            const prev = it.s[it.i - 1];
            const c = it.s[it.i];
            if (std.ascii.isUpper(c) and (std.ascii.isLower(prev) or std.ascii.isDigit(prev))) break;
            // "HTTPServer": the last capital before a lower starts a word.
            if (std.ascii.isUpper(prev) and std.ascii.isUpper(c) and it.i + 1 < it.s.len and std.ascii.isLower(it.s[it.i + 1])) break;
        }
        return it.s[start..it.i];
    }
};
