//! The Compose(5) text format: one rule per line,
//! `EVENT [EVENT...] : "STRING" [KEYSYM]`, `#` comments, and
//! `include "path"` with `%H`, `%L` and `%S` substitutions. Modifier
//! prefixes on events (`!`, `~`, `None`, `Ctrl`, ...) are parsed and
//! ignored, as libxkbcommon does for client-side compose.

const std = @import("std");
const keysyms = @import("keysyms.zig");

const log = std.log.scoped(.compose);

/// Longest sequence kept; longer rules are dropped.
pub const max_sequence = 16;
/// Include nesting limit.
pub const max_include_depth = 8;

/// One parsed rule. Slices are valid only during the `Sink` call.
pub const Rule = struct {
    sequence: []const u32,
    utf8: []const u8,
    /// 0 when the rule gives none.
    keysym: u32,
};

/// Receives rules in file order.
pub const Sink = struct {
    ctx: *anyopaque,
    add: *const fn (ctx: *anyopaque, rule: Rule) error{OutOfMemory}!void,
};

/// Where includes are resolved.
pub const IncludeContext = struct {
    /// `%H`.
    home: ?[]const u8 = null,
    /// `%L`: the locale's system Compose file.
    locale_file: ?[]const u8 = null,
    /// `%S`: the system locale directory.
    system_dir: ?[]const u8 = null,
    /// Prepended to every path opened (a fake filesystem root in tests).
    root: []const u8 = "",
    /// Current nesting.
    depth: u32 = 0,
};

/// Parse errors. Bad rules are skipped, not errors; only allocation
/// failures stop the parse.
pub const Error = error{OutOfMemory};

/// Parses `text`, sending each valid rule to `sink` and following
/// includes. Unreadable includes are skipped with a log.
pub fn parse(gpa: std.mem.Allocator, io: std.Io, text: []const u8, ctx: IncludeContext, sink: Sink) Error!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    while (lines.next()) |line| {
        line_no += 1;
        parseLine(gpa, io, line, ctx, sink) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => log.debug("line {d}: invalid rule skipped", .{line_no}),
        };
    }
}

const LineError = error{ OutOfMemory, Invalid };

const Cursor = struct {
    s: []const u8,
    i: usize = 0,

    fn skipSpace(c: *Cursor) void {
        while (c.i < c.s.len and (c.s[c.i] == ' ' or c.s[c.i] == '\t' or c.s[c.i] == '\r')) c.i += 1;
    }

    fn atEnd(c: *Cursor) bool {
        c.skipSpace();
        return c.i >= c.s.len or c.s[c.i] == '#';
    }

    fn peek(c: *Cursor) u8 {
        c.skipSpace();
        return if (c.i < c.s.len) c.s[c.i] else 0;
    }

    fn ident(c: *Cursor) []const u8 {
        c.skipSpace();
        const start = c.i;
        while (c.i < c.s.len and (std.ascii.isAlphanumeric(c.s[c.i]) or c.s[c.i] == '_')) c.i += 1;
        return c.s[start..c.i];
    }

    /// A quoted string with escapes decoded into `out`.
    fn string(c: *Cursor, out: []u8) LineError![]const u8 {
        if (c.peek() != '"') return error.Invalid;
        c.i += 1;
        var n: usize = 0;
        while (true) {
            if (c.i >= c.s.len) return error.Invalid;
            var ch = c.s[c.i];
            c.i += 1;
            if (ch == '"') break;
            if (ch == '\\') {
                if (c.i >= c.s.len) return error.Invalid;
                const e = c.s[c.i];
                c.i += 1;
                ch = switch (e) {
                    '\\', '"' => e,
                    'n' => '\n',
                    'x', 'X' => try c.number(16, 2),
                    '0'...'7' => blk: {
                        if (e == '0' and c.i < c.s.len and (c.s[c.i] == 'x' or c.s[c.i] == 'X')) {
                            c.i += 1;
                            break :blk try c.number(16, 2);
                        }
                        c.i -= 1;
                        break :blk try c.number(8, 3);
                    },
                    else => return error.Invalid,
                };
            }
            if (n == out.len) return error.Invalid;
            out[n] = ch;
            n += 1;
        }
        return out[0..n];
    }

    fn number(c: *Cursor, base: u8, max_digits: usize) LineError!u8 {
        var v: u32 = 0;
        var digits: usize = 0;
        while (digits < max_digits and c.i < c.s.len) : (digits += 1) {
            const d = std.fmt.charToDigit(c.s[c.i], base) catch break;
            v = v * base + d;
            c.i += 1;
        }
        if (digits == 0 or v > 0xff) return error.Invalid;
        return @intCast(v);
    }
};

fn parseLine(gpa: std.mem.Allocator, io: std.Io, line: []const u8, ctx: IncludeContext, sink: Sink) LineError!void {
    var c: Cursor = .{ .s = line };
    if (c.atEnd()) return;
    var str_buf: [256]u8 = undefined;

    if (std.mem.startsWith(u8, line[c.i..], "include")) {
        c.i += "include".len;
        const path = try c.string(&str_buf);
        if (!c.atEnd()) return error.Invalid;
        return include(gpa, io, path, ctx, sink);
    }

    var seq: [max_sequence]u32 = undefined;
    var n: usize = 0;
    while (true) {
        switch (c.peek()) {
            ':' => {
                c.i += 1;
                break;
            },
            '!', '~' => c.i += 1,
            '<' => {
                c.i += 1;
                const name = c.ident();
                if (c.peek() != '>') return error.Invalid;
                c.i += 1;
                const ks = keysyms.keysymFromName(name) orelse return error.Invalid;
                if (n == max_sequence) return error.Invalid;
                seq[n] = ks;
                n += 1;
            },
            else => if (c.ident().len == 0) return error.Invalid, // modifier names
        }
    }
    if (n == 0) return error.Invalid;

    var utf8: []const u8 = "";
    if (c.peek() == '"') utf8 = try c.string(&str_buf);
    var keysym: u32 = 0;
    if (!c.atEnd()) {
        keysym = keysyms.keysymFromName(c.ident()) orelse return error.Invalid;
        if (!c.atEnd()) return error.Invalid;
    }
    var cp_buf: [4]u8 = undefined;
    if (utf8.len == 0) {
        // A keysym-only rule produces the keysym's character.
        const cp = keysyms.keysymToCodepoint(keysym) orelse return error.Invalid;
        utf8 = cp_buf[0 .. std.unicode.utf8Encode(cp, &cp_buf) catch return error.Invalid];
    }
    if (!std.unicode.utf8ValidateSlice(utf8)) {
        log.info("rule with invalid UTF-8 dropped", .{});
        return;
    }
    try sink.add(sink.ctx, .{ .sequence = seq[0..n], .utf8 = utf8, .keysym = keysym });
}

/// Expands `%H`, `%L`, `%S` and `%%` in an include path.
pub fn expandPath(out: []u8, path: []const u8, ctx: IncludeContext) error{Invalid}![]const u8 {
    var w: std.Io.Writer = .fixed(out);
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] != '%') {
            w.writeByte(path[i]) catch return error.Invalid;
            continue;
        }
        i += 1;
        if (i >= path.len) return error.Invalid;
        const sub: []const u8 = switch (path[i]) {
            'H' => ctx.home orelse return error.Invalid,
            'L' => ctx.locale_file orelse return error.Invalid,
            'S' => ctx.system_dir orelse return error.Invalid,
            '%' => "%",
            else => return error.Invalid,
        };
        w.writeAll(sub) catch return error.Invalid;
    }
    return w.buffered();
}

fn include(gpa: std.mem.Allocator, io: std.Io, raw: []const u8, ctx: IncludeContext, sink: Sink) LineError!void {
    if (ctx.depth >= max_include_depth) {
        log.info("include nested too deeply: {s}", .{raw});
        return;
    }
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try expandPath(&buf, raw, ctx);
    const text = readFile(gpa, io, ctx.root, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            log.info("cannot read include {s}", .{path});
            return;
        },
    };
    defer gpa.free(text);
    var inner = ctx;
    inner.depth += 1;
    try parse(gpa, io, text, inner, sink);
}

/// Reads `path` under `root` (both may be empty or absolute).
pub fn readFile(gpa: std.mem.Allocator, io: std.Io, root: []const u8, path: []const u8) ![]u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const full = if (root.len == 0) path else std.fmt.bufPrint(&buf, "{s}{s}", .{ root, path }) catch return error.NameTooLong;
    return std.Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(8 << 20));
}

const testing = std.testing;

const Collected = struct {
    arena: std.mem.Allocator,
    rules: std.ArrayList(Rule) = .empty,

    fn sink(c: *Collected) Sink {
        return .{ .ctx = c, .add = add };
    }

    fn add(ctx: *anyopaque, r: Rule) error{OutOfMemory}!void {
        const c: *Collected = @ptrCast(@alignCast(ctx));
        try c.rules.append(c.arena, .{ .sequence = try c.arena.dupe(u32, r.sequence), .utf8 = try c.arena.dupe(u8, r.utf8), .keysym = r.keysym });
    }
};

test "parse escapes and comments" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var col: Collected = .{ .arena = arena.allocator() };
    try parse(testing.allocator, testing.io,
        \\# a comment
        \\<dead_acute> <e>  : "é"  eacute # trailing comment
        \\<Multi_key> <slash> <slash> : "\\" backslash
        \\<Multi_key> <quotedbl> <a> : "\"a\101\x42\0x43"
        \\!Ctrl ~Shift <Multi_key> <c> <o> : "©"
        \\None <Multi_key> <U2192> : U2192
        \\<Multi_key> <bogus_keysym_name> : "x"
        \\<Multi_key> <a> : "\xff"
        \\<Multi_key> <b> "missing colon"
        \\
    , .{}, col.sink());
    const r = col.rules.items;
    try testing.expectEqual(5, r.len);
    try testing.expectEqualSlices(u32, &.{ 0xfe51, 'e' }, r[0].sequence);
    try testing.expectEqualStrings("é", r[0].utf8);
    try testing.expectEqual(0xe9, r[0].keysym);
    try testing.expectEqualStrings("\\", r[1].utf8);
    try testing.expectEqualStrings("\"aABC", r[2].utf8);
    try testing.expectEqualSlices(u32, &.{ 0xff20, 'c', 'o' }, r[3].sequence);
    try testing.expectEqual(0, r[3].keysym);
    try testing.expectEqualStrings("→", r[4].utf8);
    try testing.expectEqual(0x01002192, r[4].keysym);
}

test "include %L/%S/%H expansion with a fake fs root" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    try d.createDirPath(testing.io, "home/u");
    try d.createDirPath(testing.io, "sys/en_US.UTF-8");
    try d.writeFile(testing.io, .{ .sub_path = "sys/en_US.UTF-8/Compose", .data = "<dead_acute> <a> : \"á\"\n" });
    try d.writeFile(testing.io, .{ .sub_path = "sys/extra", .data = "<dead_grave> <a> : \"à\"\n" });
    try d.writeFile(testing.io, .{ .sub_path = "home/u/more", .data = "<dead_tilde> <n> : \"ñ\"\ninclude \"%H/more\"\n" });
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try d.realPath(testing.io, &root_buf)];

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var col: Collected = .{ .arena = arena.allocator() };
    const ctx: IncludeContext = .{ .home = "/home/u", .locale_file = "/sys/en_US.UTF-8/Compose", .system_dir = "/sys", .root = root };
    // The self-include in "more" stops at the depth limit.
    try parse(testing.allocator, testing.io, "include \"%L\"\ninclude \"%S/extra\"\ninclude \"%H/more\"\ninclude \"/missing\"\n", ctx, col.sink());
    const r = col.rules.items;
    try testing.expectEqualStrings("á", r[0].utf8);
    try testing.expectEqualStrings("à", r[1].utf8);
    try testing.expectEqualStrings("ñ", r[2].utf8);
    try testing.expectEqual(2 + max_include_depth, r.len);

    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("/home/u/x%", try expandPath(&out, "%H/x%%", ctx));
    try testing.expectError(error.Invalid, expandPath(&out, "%Q", ctx));
    try testing.expectError(error.Invalid, expandPath(&out, "%H", .{}));
}

test "fuzz: compose parser never crashes" {
    try testing.fuzz({}, struct {
        fn one(_: void, sm: *testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const n = sm.slice(&buf);
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            var col: Collected = .{ .arena = arena.allocator() };
            // No includes reach the filesystem: %X fails expansion and the
            // root points nowhere.
            try parse(testing.allocator, testing.io, buf[0..n], .{ .root = "/nonexistent-zg-root" }, col.sink());
        }
    }.one, .{});
}
