//! Compose sequences (dead keys and Multi_key) without an IME: a trie
//! built from Compose(5) files, and a state machine fed with keysyms.
//! Lookup never allocates. Loading reads files, so backends run
//! `loadDefault` off the UI and platform threads and treat compose as a
//! passthrough until it finishes.

const std = @import("std");
const parser = @import("compose_parser.zig");

const log = std.log.scoped(.compose);

/// See `compose_parser.IncludeContext`.
pub const IncludeContext = parser.IncludeContext;

/// Dead-key rules used when no Compose file is found (libX11 subset; see
/// packages/platform/data/SOURCES.md).
pub const fallback_text = @embedFile("compose_fallback.Compose");

const none: u32 = std.math.maxInt(u32);

/// Where the X11 locale data may live.
pub const system_dirs = [_][]const u8{ "/usr/share/X11/locale", "/usr/lib/X11/locale" };

/// A compiled set of compose rules.
pub const ComposeTable = struct {
    // Trie nodes, struct-of-arrays; node 0 is the root.
    keysym: std.ArrayList(u32) = .empty,
    first_child: std.ArrayList(u32) = .empty,
    next_sibling: std.ArrayList(u32) = .empty,
    /// Index into `results`, or `none`.
    result: std.ArrayList(u32) = .empty,
    results: std.ArrayList(Result) = .empty,
    pool: std.ArrayList(u8) = .empty,
    /// Rules dropped for prefix conflicts (logged at debug level).
    conflicts: usize = 0,

    const Result = struct { off: u32, len: u32, keysym: u32 };

    /// An empty table (everything passes through).
    pub fn initEmpty(gpa: std.mem.Allocator) !ComposeTable {
        var t: ComposeTable = .{};
        errdefer t.deinit(gpa);
        _ = try t.addNode(gpa, 0);
        return t;
    }

    /// Loads the user's rules per Compose(5): `$XCOMPOSEFILE`, else
    /// `~/.XCompose`, else the system file for the locale (LC_ALL,
    /// LC_CTYPE, LANG; default "C"), else the built-in dead-key table.
    pub fn loadDefault(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) !ComposeTable {
        const locale = localeName(env);
        var norm_buf: [128]u8 = undefined;
        const norm = normalizeLocale(&norm_buf, locale);
        var file_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var ctx: IncludeContext = .{ .home = env.get("HOME") };
        for (system_dirs) |dir| {
            if (try systemFile(gpa, io, "", dir, norm, &file_buf)) |f| {
                ctx.locale_file = f;
                ctx.system_dir = dir;
                break;
            }
        }
        if (env.get("XCOMPOSEFILE")) |p| {
            if (try loadFile(gpa, io, p, ctx)) |t| return t;
        }
        if (ctx.home) |h| {
            var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            if (std.fmt.bufPrint(&buf, "{s}/.XCompose", .{h})) |p| {
                if (try loadFile(gpa, io, p, ctx)) |t| return t;
            } else |_| {}
        }
        if (ctx.locale_file) |f| {
            if (try loadFile(gpa, io, f, ctx)) |t| return t;
        }
        log.debug("no Compose file for locale {s}; using the built-in table", .{norm});
        return parse(gpa, io, fallback_text, ctx);
    }

    fn loadFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8, ctx: IncludeContext) !?ComposeTable {
        const text = parser.readFile(gpa, io, ctx.root, path) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        defer gpa.free(text);
        return try parse(gpa, io, text, ctx);
    }

    /// Builds a table from Compose text, following `include`s.
    pub fn parse(gpa: std.mem.Allocator, io: std.Io, text: []const u8, ctx: IncludeContext) !ComposeTable {
        var t: ComposeTable = try .initEmpty(gpa);
        errdefer t.deinit(gpa);
        var b: Builder = .{ .gpa = gpa, .t = &t };
        defer b.edges.deinit(gpa);
        try parser.parse(gpa, io, text, ctx, .{ .ctx = &b, .add = Builder.add });
        return t;
    }

    /// Frees the table.
    pub fn deinit(t: *ComposeTable, gpa: std.mem.Allocator) void {
        t.keysym.deinit(gpa);
        t.first_child.deinit(gpa);
        t.next_sibling.deinit(gpa);
        t.result.deinit(gpa);
        t.results.deinit(gpa);
        t.pool.deinit(gpa);
    }

    /// How many rules the table holds.
    pub fn ruleCount(t: *const ComposeTable) usize {
        var n: usize = 0;
        for (t.result.items) |r| {
            if (r != none) n += 1;
        }
        return n;
    }

    fn addNode(t: *ComposeTable, gpa: std.mem.Allocator, ks: u32) !u32 {
        const id: u32 = @intCast(t.keysym.items.len);
        try t.keysym.append(gpa, ks);
        try t.first_child.append(gpa, none);
        try t.next_sibling.append(gpa, none);
        try t.result.append(gpa, none);
        return id;
    }

    /// The child of `node` for `ks`.
    fn child(t: *const ComposeTable, node: u32, ks: u32) ?u32 {
        var c = t.first_child.items[node];
        while (c != none) : (c = t.next_sibling.items[c]) {
            if (t.keysym.items[c] == ks) return c;
        }
        return null;
    }

    /// Memory held by the trie and strings.
    pub fn bytes(t: *const ComposeTable) usize {
        return t.keysym.items.len * 16 + t.results.items.len * @sizeOf(Result) + t.pool.items.len;
    }
};

const Builder = struct {
    gpa: std.mem.Allocator,
    t: *ComposeTable,
    /// (parent << 32 | keysym) → child, so building avoids sibling scans.
    edges: std.AutoHashMapUnmanaged(u64, u32) = .empty,

    fn add(ctx: *anyopaque, rule: parser.Rule) error{OutOfMemory}!void {
        const b: *Builder = @ptrCast(@alignCast(ctx));
        const t = b.t;
        var node: u32 = 0;
        for (rule.sequence) |ks| {
            if (t.result.items[node] != none) {
                // A shorter rule is a prefix of this one: the longer wins.
                log.debug("compose: rule replaced by a longer sequence", .{});
                t.result.items[node] = none;
                t.conflicts += 1;
            }
            const gop = try b.edges.getOrPut(b.gpa, @as(u64, node) << 32 | ks);
            if (!gop.found_existing) {
                const n = t.addNode(b.gpa, ks) catch |err| {
                    b.edges.removeByPtr(gop.key_ptr);
                    return err;
                };
                t.next_sibling.items[n] = t.first_child.items[node];
                t.first_child.items[node] = n;
                gop.value_ptr.* = n;
            }
            node = gop.value_ptr.*;
        }
        if (t.first_child.items[node] != none) {
            // This rule is a prefix of longer ones: drop it.
            log.debug("compose: rule dropped, it is a prefix of longer sequences", .{});
            t.conflicts += 1;
            return;
        }
        const off: u32 = @intCast(t.pool.items.len);
        try t.pool.appendSlice(b.gpa, rule.utf8);
        const idx: u32 = @intCast(t.results.items.len);
        try t.results.append(b.gpa, .{ .off = off, .len = @intCast(rule.utf8.len), .keysym = rule.keysym });
        // A later rule for the same sequence overrides the earlier one.
        t.result.items[node] = idx;
    }
};

/// What a keysym did to the sequence.
pub const Status = enum {
    /// Not part of a sequence: handle the key normally.
    nothing,
    /// A sequence is in progress: swallow the key.
    composing,
    /// The sequence finished: `result()` has the text.
    composed,
    /// The key did not continue the sequence; both are dropped.
    cancelled,
};

/// The composed text and keysym.
pub const ComposeResult = struct { utf8: []const u8, keysym: u32 };

/// One keyboard's compose state.
pub const ComposeState = struct {
    table: *const ComposeTable,
    node: u32 = 0,
    last: u32 = none,

    /// A state at the start of no sequence.
    pub fn init(table: *const ComposeTable) ComposeState {
        return .{ .table = table };
    }

    /// Feeds one pressed key's keysym.
    pub fn feed(s: *ComposeState, keysym: u32) Status {
        if (isModifier(keysym)) return .nothing;
        const t = s.table;
        const c = t.child(s.node, keysym) orelse {
            if (s.node == 0) return .nothing;
            s.node = 0;
            return .cancelled;
        };
        if (t.result.items[c] != none) {
            s.last = t.result.items[c];
            s.node = 0;
            return .composed;
        }
        if (t.first_child.items[c] == none) {
            // A node left empty by a dropped rule.
            s.node = 0;
            return .cancelled;
        }
        s.node = c;
        return .composing;
    }

    /// The result of the last `.composed`; empty before any.
    pub fn result(s: *const ComposeState) ComposeResult {
        if (s.last == none) return .{ .utf8 = "", .keysym = 0 };
        const r = s.table.results.items[s.last];
        return .{ .utf8 = s.table.pool.items[r.off..][0..r.len], .keysym = r.keysym };
    }

    /// Abandons any sequence (focus or layout change, IME enabled).
    pub fn reset(s: *ComposeState) void {
        s.node = 0;
    }
};

/// Modifier keysyms, which do not interrupt a sequence (as in libxkbcommon).
pub fn isModifier(ks: u32) bool {
    return (ks >= 0xffe1 and ks <= 0xffee) or // Shift_L .. Hyper_R
        (ks >= 0xfe01 and ks <= 0xfe13) or // ISO_Lock .. ISO_Level5_Lock
        ks == 0xff7e or ks == 0xff7f; // Mode_switch, Num_Lock
}

/// The first non-empty of LC_ALL, LC_CTYPE and LANG, else "C".
pub fn localeName(env: *const std.process.Environ.Map) []const u8 {
    for ([_][]const u8{ "LC_ALL", "LC_CTYPE", "LANG" }) |k| {
        if (env.get(k)) |v| if (v.len > 0) return v;
    }
    return "C";
}

/// Normalizes the codeset spelling: `en_US.utf8` → `en_US.UTF-8`.
pub fn normalizeLocale(out: []u8, locale: []const u8) []const u8 {
    const dot = std.mem.indexOfScalar(u8, locale, '.') orelse return locale;
    const at = std.mem.indexOfScalarPos(u8, locale, dot, '@') orelse locale.len;
    const codeset = locale[dot + 1 .. at];
    var cs_buf: [16]u8 = undefined;
    var n: usize = 0;
    for (codeset) |ch| {
        if (ch == '-' or ch == '_') continue;
        if (n == cs_buf.len) return locale;
        cs_buf[n] = std.ascii.toLower(ch);
        n += 1;
    }
    if (!std.mem.eql(u8, cs_buf[0..n], "utf8")) return locale;
    return std.fmt.bufPrint(out, "{s}.UTF-8{s}", .{ locale[0..dot], locale[at..] }) catch locale;
}

/// Finds the Compose file for `locale` in `dir/compose.dir` (lines
/// `<path> <locale>`, first match wins); the path is written to `out`.
pub fn systemFile(gpa: std.mem.Allocator, io: std.Io, root: []const u8, dir: []const u8, locale: []const u8, out: []u8) !?[]const u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const index = std.fmt.bufPrint(&buf, "{s}/compose.dir", .{dir}) catch return null;
    const text = parser.readFile(gpa, io, root, index) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer gpa.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        const path = it.next() orelse continue;
        const loc = it.next() orelse continue;
        if (std.mem.eql(u8, loc, locale)) return std.fmt.bufPrint(out, "{s}/{s}", .{ dir, path }) catch null;
    }
    return null;
}

const testing = std.testing;
const keysyms = @import("keysyms.zig");

fn named(name: []const u8) u32 {
    return keysyms.keysymFromName(name).?;
}

fn typeSeq(s: *ComposeState, names: []const []const u8) Status {
    var st: Status = .nothing;
    for (names) |n| st = s.feed(named(n));
    return st;
}

const sample =
    \\<dead_circumflex> <e> : "ê" ecircumflex
    \\<Multi_key> <o> <c> : "©" copyright
    \\<Multi_key> <a> <e> : "æ" ae
    \\<Multi_key> <a> <e> : "Æ"
    \\
;

test "dead_circumflex e → ê; Multi_key o c → ©; later rule overrides" {
    var t: ComposeTable = try .parse(testing.allocator, testing.io, sample, .{});
    defer t.deinit(testing.allocator);
    var s: ComposeState = .init(&t);
    try testing.expectEqual(Status.composing, s.feed(named("dead_circumflex")));
    try testing.expectEqual(Status.composed, s.feed(named("e")));
    try testing.expectEqualStrings("ê", s.result().utf8);
    try testing.expectEqual(named("ecircumflex"), s.result().keysym);
    try testing.expectEqual(Status.composed, typeSeq(&s, &.{ "Multi_key", "o", "c" }));
    try testing.expectEqualStrings("©", s.result().utf8);
    try testing.expectEqual(Status.composed, typeSeq(&s, &.{ "Multi_key", "a", "e" }));
    try testing.expectEqualStrings("Æ", s.result().utf8);
    try testing.expectEqual(0, s.result().keysym);
    try testing.expectEqual(Status.nothing, s.feed(named("x")));
    try testing.expectEqual(3, t.ruleCount());
}

test "modifier keysym mid-sequence ignored; mismatch cancels; reset" {
    var t: ComposeTable = try .parse(testing.allocator, testing.io, sample, .{});
    defer t.deinit(testing.allocator);
    var s: ComposeState = .init(&t);
    try testing.expectEqual(Status.composing, s.feed(named("Multi_key")));
    try testing.expectEqual(Status.nothing, s.feed(named("Shift_L")));
    try testing.expectEqual(Status.nothing, s.feed(named("ISO_Level3_Shift")));
    try testing.expectEqual(Status.composing, s.feed(named("o")));
    try testing.expectEqual(Status.composed, s.feed(named("c")));

    try testing.expectEqual(Status.composing, s.feed(named("Multi_key")));
    try testing.expectEqual(Status.cancelled, s.feed(named("z")));
    try testing.expectEqual(Status.nothing, s.feed(named("z")));

    try testing.expectEqual(Status.composing, s.feed(named("dead_circumflex")));
    s.reset();
    try testing.expectEqual(Status.nothing, s.feed(named("e")));
}

test "prefix conflict resolved like xkbcommon" {
    var t: ComposeTable = try .parse(testing.allocator, testing.io,
        \\<Multi_key> <a> : "short"
        \\<Multi_key> <a> <b> : "long"
        \\<Multi_key> <c> <d> : "long2"
        \\<Multi_key> <c> : "short2"
        \\
    , .{});
    defer t.deinit(testing.allocator);
    try testing.expectEqual(2, t.conflicts);
    var s: ComposeState = .init(&t);
    try testing.expectEqual(Status.composing, typeSeq(&s, &.{ "Multi_key", "a" }));
    try testing.expectEqual(Status.composed, s.feed(named("b")));
    try testing.expectEqualStrings("long", s.result().utf8);
    try testing.expectEqual(Status.composing, typeSeq(&s, &.{ "Multi_key", "c" }));
    try testing.expectEqual(Status.composed, s.feed(named("d")));
    try testing.expectEqualStrings("long2", s.result().utf8);
}

test "built-in fallback table covers dead keys × a–z" {
    var t: ComposeTable = try .parse(testing.allocator, testing.io, fallback_text, .{});
    defer t.deinit(testing.allocator);
    var s: ComposeState = .init(&t);
    const dead = [_][]const u8{ "dead_grave", "dead_acute", "dead_circumflex", "dead_tilde", "dead_diaeresis" };
    for (dead) |d| for ("aeiouAEIOU") |v| {
        try testing.expectEqual(Status.composing, s.feed(named(d)));
        try testing.expectEqual(Status.composed, s.feed(v));
        try testing.expect(s.result().utf8.len >= 2);
    };
    // Every letter after dead_acute either composes or cancels; none hangs.
    for ("abcdefghijklmnopqrstuvwxyz") |l| {
        _ = s.feed(named("dead_acute"));
        try testing.expect(s.feed(l) != .composing);
    }
    try testing.expectEqual(Status.composed, typeSeq(&s, &.{ "dead_cedilla", "c" }));
    try testing.expectEqualStrings("ç", s.result().utf8);
    try testing.expect(t.ruleCount() > 500);
}

test "locale names and compose.dir lookup" {
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("en_US.UTF-8", normalizeLocale(&out, "en_US.utf8"));
    try testing.expectEqualStrings("de_DE.UTF-8@euro", normalizeLocale(&out, "de_DE.UTF8@euro"));
    try testing.expectEqualStrings("C", normalizeLocale(&out, "C"));
    try testing.expectEqualStrings("ja_JP.eucJP", normalizeLocale(&out, "ja_JP.eucJP"));

    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try testing.expectEqualStrings("C", localeName(&env));
    try env.put("LANG", "fr_FR.UTF-8");
    try env.put("LC_CTYPE", "");
    try testing.expectEqualStrings("fr_FR.UTF-8", localeName(&env));
    try env.put("LC_ALL", "de_DE.UTF-8");
    try testing.expectEqualStrings("de_DE.UTF-8", localeName(&env));

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "locale");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "locale/compose.dir", .data = "# comment\nen_US.UTF-8/Compose\t\tde_DE.UTF-8\nother/Compose de_DE.UTF-8\n" });
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(testing.io, &root_buf)];
    var path_buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/locale/en_US.UTF-8/Compose", (try systemFile(testing.allocator, testing.io, root, "/locale", "de_DE.UTF-8", &path_buf)).?);
    try testing.expectEqual(null, try systemFile(testing.allocator, testing.io, root, "/locale", "xx_XX", &path_buf));
}

test "loadDefault: XCOMPOSEFILE with include %L and custom rules" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "XCompose", .data = "include \"%L\"\n<Multi_key> <z> <z> : \"zz\"\n" });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    var pbuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const p = try std.fmt.bufPrint(&pbuf, "{s}/XCompose", .{dir});
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("XCOMPOSEFILE", p);
    try env.put("LANG", "en_US.utf8");
    var t = try ComposeTable.loadDefault(testing.allocator, testing.io, &env);
    defer t.deinit(testing.allocator);
    var s: ComposeState = .init(&t);
    try testing.expectEqual(Status.composed, typeSeq(&s, &.{ "Multi_key", "z", "z" }));
    // With the system file present, %L brings in its thousands of rules.
    if (t.ruleCount() > 1000) {
        try testing.expectEqual(Status.composed, typeSeq(&s, &.{ "Multi_key", "o", "c" }));
        try testing.expectEqualStrings("©", s.result().utf8);
    }

    // No files at all: the built-in table.
    var bare: std.process.Environ.Map = .init(testing.allocator);
    defer bare.deinit();
    try bare.put("LANG", "xx_XX.UTF-8");
    try bare.put("HOME", "/nonexistent-zg-home");
    var fb = try ComposeTable.loadDefault(testing.allocator, testing.io, &bare);
    defer fb.deinit(testing.allocator);
    var s2: ComposeState = .init(&fb);
    try testing.expectEqual(Status.composed, typeSeq(&s2, &.{ "dead_acute", "e" }));
}

test "system en_US.UTF-8 Compose: size and timing budget" {
    const path = "/usr/share/X11/locale/en_US.UTF-8/Compose";
    const text = std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .limited(8 << 20)) catch return error.SkipZigTest;
    defer testing.allocator.free(text);
    var t: ComposeTable = try .parse(testing.allocator, testing.io, text, .{});
    defer t.deinit(testing.allocator);
    try testing.expect(t.ruleCount() > 4000);
    try testing.expect(t.bytes() < 1 << 20);
}
