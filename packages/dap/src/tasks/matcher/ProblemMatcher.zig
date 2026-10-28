//! Problem matchers (E07.F08.S01.T02): task output, one line at a time,
//! to problems, in the VS Code problem-matcher model.
//!
//! - Patterns match consecutive lines in order. The first pattern starts
//!   a candidate; a line that fails the next pattern resets it and is
//!   tried again as a first line. Groups gather across the patterns.
//! - `loop` on the last pattern emits a problem for every consecutive
//!   line it matches, each with the data of the patterns before it.
//! - `location` groups take `line`, `line,col` or
//!   `line,col,endLine,endCol`; lines and columns stay 1-based as
//!   printed (columns are what the tool counts: bytes for Zig and GCC).
//! - Problems with the same file, line and column collapse (per run, or
//!   per cycle for background matchers).
//! - `related_note`: lines whose severity word is `note` attach to the
//!   problem before them (Zig), so a problem is held until the next one,
//!   `idle` or `finish`.
//! - `trailer`: problems wait for a line giving their message, the last
//!   candidate winning (Python tracebacks end with the exception).
//! - Background matchers report cycles: `begins` starts one (or the
//!   first line after an end with `implicit_begin_after_end`, or a
//!   clear-screen with `begin_on_clear`), `ends` ends it; the sink
//!   replaces the owner's problems with the cycle's at the end.
//!
//! Matching runs on the task output worker. Lines that match nothing do
//! not allocate; groups are copied only for problems.

const std = @import("std");
const builtin = @import("builtin");
const zg_regex = @import("zg_regex");
const ansi = @import("ansi_strip.zig");

const Allocator = std.mem.Allocator;

pub const Severity = enum { err, warning, info, hint };

pub const Kind = enum { location, file };

pub const Pattern = struct {
    regexp: []const u8,
    file: ?u8 = null,
    location: ?u8 = null,
    line: ?u8 = null,
    column: ?u8 = null,
    end_line: ?u8 = null,
    end_column: ?u8 = null,
    severity: ?u8 = null,
    code: ?u8 = null,
    message: ?u8 = null,
    loop: bool = false,
    kind: Kind = .location,
    /// A quick check before the regex: the line must contain one of
    /// these (no effect on what matches when the regex needs one).
    requires: []const []const u8 = &.{},
    /// The regex is `^(.+?):(\d+):(\d+): (w|…): (.*)$` with these words:
    /// ASCII lines are split by hand, which gives the same groups much
    /// faster than the regex's capture engine (tested against it).
    shape: ?Shape = null,
};

pub const Shape = struct {
    words: []const []const u8,
};

/// How a matched file name becomes a path: as it is, relative to a base
/// (null: the task's cwd), or absolute when it is and relative otherwise.
pub const FileLocation = union(enum) {
    absolute,
    relative: ?[]const u8,
    auto_detect: ?[]const u8,
};

pub const Background = struct {
    active_on_start: bool = false,
    begins: []const u8,
    ends: []const u8,
    /// The first line after an end begins a cycle (`zig build --watch`
    /// prints no begin line).
    implicit_begin_after_end: bool = false,
    /// A clear-screen begins a cycle (`--error-style minimal_clear`).
    begin_on_clear: bool = false,
};

/// Lines whose severity word is `word` attach to the problem before them.
pub const RelatedRule = struct {
    word: []const u8 = "note",
};

/// Problems wait for a line matching `regexp`; its `message` group
/// becomes the message of the last one.
pub const Trailer = struct {
    regexp: []const u8,
    message: u8 = 1,
};

pub const MatcherDef = struct {
    /// `zig` for `$zig`.
    name: []const u8,
    owner: []const u8,
    source: ?[]const u8 = null,
    file_location: FileLocation = .{ .auto_detect = null },
    severity: Severity = .err,
    patterns: []const Pattern,
    background: ?Background = null,
    related_note: ?RelatedRule = null,
    trailer: ?Trailer = null,
};

pub const Related = struct {
    file: []const u8,
    line: u32,
    column: u32,
    message: []const u8,
};

pub const Problem = struct {
    /// Resolved path.
    file: []const u8,
    /// 1-based as printed; 0 when not given.
    line: u32 = 0,
    column: u32 = 0,
    end_line: u32 = 0,
    end_column: u32 = 0,
    severity: Severity,
    code: []const u8 = "",
    message: []const u8,
    /// The matcher's source, else its owner.
    source: []const u8,
    kind: Kind = .location,
    related: []const Related = &.{},
};

pub const Cycle = enum { begin, end };

pub const ProblemSink = struct {
    ctx: *anyopaque,
    /// `p` and its texts live until the call returns.
    problem: *const fn (ctx: *anyopaque, p: *const Problem) void,
    cycle: *const fn (ctx: *anyopaque, ev: Cycle) void,
};

pub const PathStyle = enum { posix, windows };

pub const Options = struct {
    style: PathStyle = if (builtin.os.tag == .windows) .windows else .posix,
};

/// The built-in matchers (`builtin.zon`).
pub const builtins: []const MatcherDef = @import("builtin.zon");

/// `$zig` or `zig`.
pub fn builtinNamed(name: []const u8) ?*const MatcherDef {
    const n = if (std.mem.startsWith(u8, name, "$")) name[1..] else name;
    for (builtins) |*d| if (std.mem.eql(u8, d.name, n)) return d;
    return null;
}

const Compiled = struct {
    re: zg_regex.Regex,
    cache: zg_regex.Cache,
    caps: zg_regex.Captures,
    requires: []const []const u8 = &.{},
    shape: ?Shape = null,
    /// Groups 1-5 of the last match, when `shape` split it.
    split: ?[6][2]u32 = null,

    fn init(gpa: Allocator, pattern: []const u8) !Compiled {
        var re = try zg_regex.Regex.compile(gpa, pattern, .{});
        errdefer re.deinit(gpa);
        var cache = try re.newCache(gpa);
        errdefer cache.deinit();
        return .{ .re = re, .cache = cache, .caps = try re.newCaptures(gpa) };
    }

    fn deinit(c: *Compiled, gpa: Allocator) void {
        c.caps.deinit(gpa);
        c.cache.deinit();
        c.re.deinit(gpa);
    }

    fn match(c: *Compiled, line: []const u8) bool {
        c.split = null;
        if (c.requires.len > 0 and !containsAny(line, c.requires)) return false;
        if (c.shape) |sh| if (isAscii(line)) {
            c.split = splitShape(sh, line);
            return c.split != null;
        };
        // The lazy DFA rejects most lines; only matches pay for captures.
        if (!c.re.isMatch(&c.cache, .fromSlice(line))) return false;
        return c.re.captures(&c.cache, .fromSlice(line), &c.caps);
    }

    fn isMatch(c: *Compiled, line: []const u8) bool {
        return c.re.isMatch(&c.cache, .fromSlice(line));
    }

    fn group(c: *const Compiled, line: []const u8, i: ?u8) ?[]const u8 {
        const g = i orelse return null;
        if (c.split) |sp| {
            if (g == 0 or g > 5) return null;
            return line[sp[g][0]..sp[g][1]];
        }
        if (g >= c.caps.len()) return null;
        const m = c.caps.get(g) orelse return null;
        return line[@intCast(m.start)..@intCast(m.end)];
    }
};

/// Groups gathered for one candidate (in the candidate arena).
const Fields = struct {
    file: ?[]const u8 = null,
    location: ?[]const u8 = null,
    line: ?[]const u8 = null,
    column: ?[]const u8 = null,
    end_line: ?[]const u8 = null,
    end_column: ?[]const u8 = null,
    severity: ?[]const u8 = null,
    code: ?[]const u8 = null,
    message: ?[]const u8 = null,
    kind: Kind = .location,
};

pub const Matcher = struct {
    gpa: Allocator,
    def: *const MatcherDef,
    cwd: []u8,
    style: PathStyle,
    pats: []Compiled,
    begins: ?Compiled = null,
    ends: ?Compiled = null,
    trailer: ?Compiled = null,
    splitter: ansi.LineSplitter,
    /// The pattern the next line must match (0: no candidate).
    next: usize = 0,
    cand: std.heap.ArenaAllocator,
    base: Fields = .{},
    /// A problem waiting for notes or its trailer (in `held_arena`).
    held: ?Problem = null,
    held_related: std.ArrayList(Related) = .empty,
    held_arena: std.heap.ArenaAllocator,
    in_cycle: bool = false,
    after_end: bool = false,
    started: bool = false,
    /// File/line/column of the problems so far (per run or cycle).
    seen: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Problems emitted (tests, status).
    emitted: u32 = 0,

    pub fn init(gpa: Allocator, def: *const MatcherDef, cwd: []const u8, o: Options) !Matcher {
        const pats = try gpa.alloc(Compiled, def.patterns.len);
        var n: usize = 0;
        errdefer {
            for (pats[0..n]) |*p| p.deinit(gpa);
            gpa.free(pats);
        }
        for (def.patterns, pats) |p, *c| {
            c.* = try .init(gpa, p.regexp);
            c.requires = p.requires;
            c.shape = p.shape;
            n += 1;
        }
        var m: Matcher = .{
            .gpa = gpa,
            .def = def,
            .cwd = try gpa.dupe(u8, cwd),
            .style = o.style,
            .pats = pats,
            .splitter = undefined,
            .cand = .init(gpa),
            .held_arena = .init(gpa),
        };
        errdefer m.deinitParts();
        if (def.background) |bg| {
            m.begins = try .init(gpa, bg.begins);
            m.ends = try .init(gpa, bg.ends);
        }
        if (def.trailer) |t| m.trailer = try .init(gpa, t.regexp);
        m.splitter = try .init(gpa);
        return m;
    }

    fn deinitParts(m: *Matcher) void {
        if (m.begins) |*c| c.deinit(m.gpa);
        if (m.ends) |*c| c.deinit(m.gpa);
        if (m.trailer) |*c| c.deinit(m.gpa);
        m.cand.deinit();
        m.held_arena.deinit();
        m.gpa.free(m.cwd);
    }

    pub fn deinit(m: *Matcher) void {
        for (m.pats) |*p| p.deinit(m.gpa);
        m.gpa.free(m.pats);
        m.splitter.deinit(m.gpa);
        m.seen.deinit(m.gpa);
        m.deinitParts();
    }

    /// Raw output bytes (escape sequences and `\r\n` allowed, lines may
    /// span calls).
    pub fn feedBytes(m: *Matcher, bytes: []const u8, sink: ProblemSink) void {
        const Ctx = struct { m: *Matcher, sink: ProblemSink };
        var ctx: Ctx = .{ .m = m, .sink = sink };
        m.splitter.feed(bytes, &ctx, struct {
            fn f(c: *Ctx, line: []const u8, cleared: bool) void {
                c.m.feedLine(line, cleared, c.sink);
            }
        }.f);
    }

    /// One line, without its newline or escape sequences.
    pub fn feed(m: *Matcher, line: []const u8, sink: ProblemSink) void {
        m.feedLine(line, false, sink);
    }

    fn feedLine(m: *Matcher, line: []const u8, cleared: bool, sink: ProblemSink) void {
        if (m.def.background) |bg| {
            if (!m.started) {
                m.started = true;
                if (bg.active_on_start) m.beginCycle(sink);
            }
            if ((cleared and bg.begin_on_clear) or m.begins.?.isMatch(line)) {
                m.beginCycle(sink);
                if (!cleared) return;
            } else if (m.after_end and bg.implicit_begin_after_end) {
                m.beginCycle(sink);
            }
            if (m.ends.?.isMatch(line)) {
                m.endCycle(sink);
                return;
            }
            if (!m.in_cycle) return;
        }
        m.matchLine(line, sink);
    }

    /// No output for a while: a held problem gets no more notes.
    pub fn idle(m: *Matcher, sink: ProblemSink) void {
        if (m.def.trailer == null) m.flushHeld(sink);
    }

    /// The output ended.
    pub fn finish(m: *Matcher, sink: ProblemSink) void {
        const Ctx = struct { m: *Matcher, sink: ProblemSink };
        var ctx: Ctx = .{ .m = m, .sink = sink };
        m.splitter.finish(&ctx, struct {
            fn f(c: *Ctx, line: []const u8, cleared: bool) void {
                c.m.feedLine(line, cleared, c.sink);
            }
        }.f);
        // A traceback without its exception line has no message.
        if (m.def.trailer != null) m.dropHeld() else m.flushHeld(sink);
        m.resetCandidate();
    }

    fn beginCycle(m: *Matcher, sink: ProblemSink) void {
        m.flushHeld(sink);
        m.resetCandidate();
        m.seen.clearRetainingCapacity();
        m.in_cycle = true;
        m.after_end = false;
        sink.cycle(sink.ctx, .begin);
    }

    fn endCycle(m: *Matcher, sink: ProblemSink) void {
        if (m.def.trailer != null) m.dropHeld() else m.flushHeld(sink);
        m.resetCandidate();
        if (m.in_cycle) sink.cycle(sink.ctx, .end);
        m.in_cycle = false;
        m.after_end = true;
    }

    fn resetCandidate(m: *Matcher) void {
        m.next = 0;
        m.base = .{};
        _ = m.cand.reset(.retain_capacity);
    }

    fn matchLine(m: *Matcher, line: []const u8, sink: ProblemSink) void {
        if (m.trailer) |*t| if (m.held != null and t.match(line)) {
            const msg = t.group(line, m.def.trailer.?.message) orelse "";
            m.held.?.message = m.held_arena.allocator().dupe(u8, msg) catch return m.dropHeld();
            m.flushHeld(sink);
            return;
        };
        const defs = m.def.patterns;
        if (m.next > 0) {
            const i = m.next;
            if (m.pats[i].match(line)) {
                if (i == defs.len - 1) {
                    var cur = m.base;
                    m.gather(&cur, i, line) catch return m.resetCandidate();
                    m.emit(&cur, sink);
                    if (!defs[i].loop) m.resetCandidate();
                } else {
                    m.gather(&m.base, i, line) catch return m.resetCandidate();
                    m.next = i + 1;
                }
                return;
            }
            m.resetCandidate();
        }
        if (!m.pats[0].match(line)) return;
        m.resetCandidate();
        m.gather(&m.base, 0, line) catch return m.resetCandidate();
        if (defs.len == 1) {
            var cur = m.base;
            m.emit(&cur, sink);
            m.resetCandidate();
        } else {
            m.next = 1;
        }
    }

    /// Copies pattern `i`'s groups in `line` into `f`.
    fn gather(m: *Matcher, f: *Fields, i: usize, line: []const u8) Allocator.Error!void {
        const a = m.cand.allocator();
        const p = m.def.patterns[i];
        const c = &m.pats[i];
        inline for (.{ "file", "location", "line", "column", "end_line", "end_column", "severity", "code", "message" }) |name| {
            if (c.group(line, @field(p, name))) |g| @field(f, name) = try a.dupe(u8, g);
        }
        if (p.file != null) f.kind = p.kind;
    }

    fn emit(m: *Matcher, f: *const Fields, sink: ProblemSink) void {
        m.build(f, sink) catch {};
    }

    fn build(m: *Matcher, f: *const Fields, sink: ProblemSink) Allocator.Error!void {
        const raw_file = std.mem.trim(u8, f.file orelse return, " \t");
        if (raw_file.len == 0) return;
        var p: Problem = .{
            .file = try m.resolve(m.cand.allocator(), raw_file),
            .severity = m.def.severity,
            .code = f.code orelse "",
            .message = std.mem.trim(u8, f.message orelse "", " \t"),
            .source = m.def.source orelse m.def.owner,
            .kind = f.kind,
        };
        if (f.location) |loc| {
            var it = std.mem.splitScalar(u8, loc, ',');
            const nums = [_]*u32{ &p.line, &p.column, &p.end_line, &p.end_column };
            for (nums) |n| n.* = num(it.next() orelse break);
        } else {
            p.line = num(f.line orelse "");
            p.column = num(f.column orelse "");
            p.end_line = num(f.end_line orelse "");
            p.end_column = num(f.end_column orelse "");
        }
        const word = if (f.severity) |s| std.mem.trim(u8, s, " \t") else "";
        if (parseSeverity(word)) |s| p.severity = s;
        if (m.def.related_note) |rr| if (std.ascii.eqlIgnoreCase(word, rr.word)) {
            if (m.held != null and m.def.trailer == null) {
                const a = m.held_arena.allocator();
                try m.held_related.append(a, .{ .file = try a.dupe(u8, p.file), .line = p.line, .column = p.column, .message = try a.dupe(u8, p.message) });
                return;
            }
            p.severity = .info;
        };
        if (m.def.trailer != null) {
            // The innermost frame comes last.
            m.dropHeld();
            try m.hold(&p);
            return;
        }
        if (!try m.firstAt(&p)) return;
        if (m.def.related_note != null) {
            m.flushHeld(sink);
            try m.hold(&p);
            return;
        }
        m.emitted += 1;
        sink.problem(sink.ctx, &p);
    }

    /// False when a problem at the same place was reported.
    fn firstAt(m: *Matcher, p: *const Problem) Allocator.Error!bool {
        var h: std.hash.Wyhash = .init(0);
        h.update(p.file);
        h.update(std.mem.asBytes(&p.line));
        h.update(std.mem.asBytes(&p.column));
        const gop = try m.seen.getOrPut(m.gpa, h.final());
        return !gop.found_existing;
    }

    fn hold(m: *Matcher, p: *const Problem) Allocator.Error!void {
        const a = m.held_arena.allocator();
        var q = p.*;
        q.file = try a.dupe(u8, p.file);
        q.code = try a.dupe(u8, p.code);
        q.message = try a.dupe(u8, p.message);
        q.source = try a.dupe(u8, p.source);
        m.held = q;
    }

    fn flushHeld(m: *Matcher, sink: ProblemSink) void {
        if (m.held) |*h| {
            h.related = m.held_related.items;
            m.emitted += 1;
            sink.problem(sink.ctx, h);
        }
        m.dropHeld();
    }

    fn dropHeld(m: *Matcher) void {
        m.held = null;
        m.held_related = .empty;
        _ = m.held_arena.reset(.retain_capacity);
    }

    /// `raw` as a path per the matcher's `file_location`.
    pub fn resolve(m: *const Matcher, a: Allocator, raw: []const u8) Allocator.Error![]const u8 {
        const base: ?[]const u8 = switch (m.def.file_location) {
            .absolute => null,
            .relative => |b| b orelse m.cwd,
            .auto_detect => |b| if (isAbsolute(m.style, raw)) null else b orelse m.cwd,
        };
        var rel = raw;
        while (std.mem.startsWith(u8, rel, "./") or std.mem.startsWith(u8, rel, ".\\")) rel = rel[2..];
        const joined = if (base) |b| try std.mem.concat(a, u8, &.{ std.mem.trimEnd(u8, b, "/\\"), if (m.style == .windows) "\\" else "/", rel }) else try a.dupe(u8, raw);
        if (m.style == .windows) std.mem.replaceScalar(u8, joined, '/', '\\');
        return joined;
    }
};

fn isAscii(line: []const u8) bool {
    const V = @Vector(16, u8);
    var i: usize = 0;
    while (i + 16 <= line.len) : (i += 16) {
        const v: V = line[i..][0..16].*;
        if (@reduce(.Or, v) >= 0x80) return false;
    }
    for (line[i..]) |b| if (b >= 0x80) return false;
    return true;
}

/// `^(.+?):(\d+):(\d+): (word): (.*)$` on an ASCII line: the shortest
/// file name after which the rest matches, as the lazy regex picks.
pub fn splitShape(sh: Shape, line: []const u8) ?[6][2]u32 {
    var p: usize = 1;
    while (std.mem.indexOfScalarPos(u8, line, p, ':')) |colon| : (p = colon + 1) {
        if (splitAfter(sh, line, colon)) |g| return g;
    }
    return null;
}

fn splitAfter(sh: Shape, line: []const u8, colon: usize) ?[6][2]u32 {
    var g: [6][2]u32 = undefined;
    const n: u32 = @intCast(line.len);
    g[0] = .{ 0, n };
    g[1] = .{ 0, @intCast(colon) };
    var i = colon + 1;
    inline for (.{ 2, 3 }) |k| {
        const start = i;
        while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
        if (i == start or i >= line.len or line[i] != ':') return null;
        g[k] = .{ @intCast(start), @intCast(i) };
        i += 1;
    }
    if (!std.mem.startsWith(u8, line[i..], " ")) return null;
    i += 1;
    for (sh.words) |w| {
        if (!std.mem.startsWith(u8, line[i..], w) or !std.mem.startsWith(u8, line[i + w.len ..], ": ")) continue;
        g[4] = .{ @intCast(i), @intCast(i + w.len) };
        g[5] = .{ @intCast(i + w.len + 2), n };
        return g;
    }
    return null;
}

/// Whether `line` contains one of `needles` (short lines: no tables, a
/// vectorized scan for each first byte).
fn containsAny(line: []const u8, needles: []const []const u8) bool {
    // Needles that start alike are tried at each hit of one scan.
    const same = for (needles) |n| {
        if (n[0] != needles[0][0]) break false;
    } else true;
    if (same) {
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, line, i, needles[0][0])) |at| : (i = at + 1) {
            for (needles) |n| if (std.mem.startsWith(u8, line[at..], n)) return true;
        }
        return false;
    }
    for (needles) |n| {
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, line, i, n[0])) |at| : (i = at + 1) {
            if (std.mem.startsWith(u8, line[at..], n)) return true;
        }
    }
    return false;
}

pub fn isAbsolute(style: PathStyle, p: []const u8) bool {
    if (p.len == 0) return false;
    return switch (style) {
        .posix => p[0] == '/',
        .windows => p[0] == '/' or p[0] == '\\' or (p.len >= 3 and std.ascii.isAlphabetic(p[0]) and p[1] == ':' and (p[2] == '\\' or p[2] == '/')),
    };
}

fn num(s: []const u8) u32 {
    return std.fmt.parseInt(u32, std.mem.trim(u8, s, " \t"), 10) catch 0;
}

/// `error`/`warning`/`info` in any case, `note` as info, `hint`.
pub fn parseSeverity(word: []const u8) ?Severity {
    const table = [_]struct { []const u8, Severity }{
        .{ "error", .err }, .{ "fatal error", .err },  .{ "warning", .warning }, .{ "warn", .warning },
        .{ "info", .info }, .{ "information", .info }, .{ "note", .info },       .{ "hint", .hint },
    };
    for (table) |e| if (std.ascii.eqlIgnoreCase(word, e[0])) return e[1];
    return null;
}
