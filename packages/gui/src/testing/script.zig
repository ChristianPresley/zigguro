//! `.zgui` interaction scripts (E04.F01.S03.T01): a line-oriented language
//! over `TestApp` for UI tests and agents. One command per line, `#`
//! starts a comment:
//!
//! ```
//! open <View> [key=value ...]        # a view from Options.views
//! click|dblclick|rclick|hover <query>
//! type "<text>"
//! press <chord>                      # ctrl+shift+p, escape, f10, KeyA
//! scroll <query> <dx> <dy>
//! drag <query> to <query | x,y>
//! wait <n>ms
//! resize <w> <h> [scale]
//! theme dark|light|hc-dark|hc-light
//! expect <query> [exists|absent|focused|checked|unchecked|disabled|
//!                 text="..."|value=<n>|count=<n>]
//! snapshot layout|semantics|pixels "<name>"
//! ```
//!
//! A query is `key=value` terms, all of which must match: `role=button`,
//! `name="Run"`, `name~="Ru"` (contains), `testid=x`, `kind=tab`, `nth=2`
//! (from 0), and `within(<query>)`. Values may be quoted (`\"`, `\\`, `\n`
//! escapes).
//!
//! The whole script is parsed before it runs, so syntax errors come with
//! their line and column and nothing runs. A failing command reports its
//! line and, when a query finds nothing, the closest candidates by name.
//! `ime` is reserved: the window has no composition route yet. Snapshots
//! go to `Options.snapshot` (tests compare them with golden files; `pixels`
//! is the recorded draw list until the software renderer is wired in).

const std = @import("std");
const zg_platform = @import("zg_platform");
const geom = @import("../core/geom.zig");
const ids = @import("../core/ids.zig");
const widget = @import("../core/widget.zig");
const view_mod = @import("../core/view.zig");
const themes = @import("../theme/theme.zig");
const test_app = @import("test_app.zig");

const Allocator = std.mem.Allocator;
const NodeId = ids.NodeId;
const TestApp = test_app.TestApp;
const Key = zg_platform.keys.Key;
const Mods = zg_platform.keys.Mods;

/// Where and why a script stopped.
pub const Diag = struct {
    line: u32 = 0,
    col: u32 = 0,
    buf: [1024]u8 = undefined,
    len: usize = 0,

    /// "line:col: what went wrong".
    pub fn message(d: *const Diag) []const u8 {
        return d.buf[0..d.len];
    }

    fn fail(d: *Diag, line: u32, col: u32, comptime fmt: []const u8, args: anytype) void {
        d.line = line;
        d.col = col;
        var w: std.Io.Writer = .fixed(&d.buf);
        w.print("{d}:{d}: ", .{ line, col }) catch {};
        w.print(fmt, args) catch {};
        d.len = w.end;
    }
};

/// A `key=value` word after a view name.
pub const Arg = struct { key: []const u8, value: []const u8 };

/// A view a script can `open`, and how it goes away.
pub const Mounted = struct {
    view: view_mod.AnyView,
    ptr: *anyopaque,
    destroy: *const fn (ptr: *anyopaque, gpa: Allocator) void,
};

/// A view by name.
pub const ViewEntry = struct {
    name: []const u8,
    ctx: ?*anyopaque = null,
    /// Creates the view from the `key=value` words after its name.
    open: *const fn (ctx: ?*anyopaque, gpa: Allocator, args: []const Arg) anyerror!Mounted,
};

/// What `snapshot` captures.
pub const SnapshotKind = enum { layout, semantics, pixels };

/// Receives snapshots (tests compare them with golden files).
pub const SnapshotFn = struct {
    ctx: ?*anyopaque = null,
    f: *const fn (ctx: ?*anyopaque, kind: SnapshotKind, name: []const u8, text: []const u8) anyerror!void,
};

/// How to run a script.
pub const Options = struct {
    views: []const ViewEntry,
    /// Null skips snapshots.
    snapshot: ?SnapshotFn = null,
    size: geom.Size = .{ .w = 800, .h = 600 },
    scale: f32 = 1,
};

/// Script errors (details in the `Diag`).
pub const Error = error{ ScriptSyntax, ScriptFailed } || Allocator.Error;

/// Parses and runs `src`.
pub fn run(gpa: Allocator, src: []const u8, opts: Options, diag: *Diag) Error!void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const cmds = try parse(arena.allocator(), src, diag);
    var r: Runner = .{ .gpa = gpa, .opts = opts, .diag = diag, .size = opts.size, .scale = opts.scale };
    defer r.close();
    for (cmds) |c| try r.exec(c);
}

/// Reads the script at `path` (at most 1 MiB) and runs it: the entry
/// point for `zg ui-test <file.zgui>`.
pub fn runFile(gpa: Allocator, io: std.Io, path: []const u8, opts: Options, diag: *Diag) (Error || error{ReadFailed})!void {
    const src = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch |e| {
        diag.fail(0, 0, "cannot read {s}: {t}", .{ path, e });
        return error.ReadFailed;
    };
    defer gpa.free(src);
    return run(gpa, src, opts, diag);
}

// -- parsing -----------------------------------------------------------

/// A query as written.
pub const Q = struct {
    q: test_app.Query = .{},
    nth: usize = 0,
    within: ?*const Q = null,
    /// The source text, for messages.
    src: []const u8 = "",
};

const Check = union(enum) {
    exists,
    absent,
    focused,
    checked: bool,
    disabled,
    text: []const u8,
    value: f32,
    count: usize,
};

const Op = union(enum) {
    open: struct { view: []const u8, args: []const Arg },
    click: Q,
    dblclick: Q,
    rclick: Q,
    hover: Q,
    type: []const u8,
    press: Chord,
    scroll: struct { q: Q, dx: f32, dy: f32 },
    drag: struct { q: Q, to: union(enum) { q: Q, pt: geom.Vec2 } },
    wait: u64,
    resize: struct { size: geom.Size, scale: ?f32 },
    theme: *const themes.Theme,
    expect: struct { q: Q, check: Check },
    snapshot: struct { kind: SnapshotKind, name: []const u8 },
};

const Cmd = struct { line: u32, col: u32, op: Op };

const Tok = struct {
    kind: enum { word, string, kv, lparen, rparen },
    /// The word, the unescaped string, or the key.
    text: []const u8,
    /// A kv's unescaped value.
    value: []const u8 = "",
    col: u32,
    /// Byte range in the line.
    start: usize,
    end: usize,
};

const Lexer = struct {
    a: Allocator,
    line: []const u8,
    no: u32,
    diag: *Diag,

    fn tokens(lx: *Lexer) Error![]Tok {
        var out: std.ArrayList(Tok) = .empty;
        var i: usize = 0;
        const s = lx.line;
        while (i < s.len) {
            const c = s[i];
            if (c == ' ' or c == '\t' or c == '\r') {
                i += 1;
                continue;
            }
            if (c == '#') break;
            const col: u32 = @intCast(i + 1);
            if (c == '(' or c == ')') {
                try out.append(lx.a, .{ .kind = if (c == '(') .lparen else .rparen, .text = s[i .. i + 1], .col = col, .start = i, .end = i + 1 });
                i += 1;
                continue;
            }
            if (c == '"') {
                const str, const next = try lx.string(i);
                try out.append(lx.a, .{ .kind = .string, .text = str, .col = col, .start = i, .end = next });
                i = next;
                continue;
            }
            var j = i;
            while (j < s.len and !std.mem.containsAtLeastScalar(u8, " \t\r()\"#", 1, s[j])) : (j += 1) {}
            const word = s[i..j];
            if (std.mem.indexOfScalar(u8, word, '=')) |eq| {
                if (eq + 1 == word.len and j < s.len and s[j] == '"') {
                    const str, const next = try lx.string(j);
                    try out.append(lx.a, .{ .kind = .kv, .text = word[0..eq], .value = str, .col = col, .start = i, .end = next });
                    i = next;
                    continue;
                }
                try out.append(lx.a, .{ .kind = .kv, .text = word[0..eq], .value = word[eq + 1 ..], .col = col, .start = i, .end = j });
            } else try out.append(lx.a, .{ .kind = .word, .text = word, .col = col, .start = i, .end = j });
            i = j;
        }
        return out.toOwnedSlice(lx.a);
    }

    /// The string starting at the quote at `at`, and the index after it.
    fn string(lx: *Lexer, at: usize) Error!struct { []const u8, usize } {
        var out: std.ArrayList(u8) = .empty;
        var i = at + 1;
        const s = lx.line;
        while (i < s.len) : (i += 1) {
            switch (s[i]) {
                '"' => return .{ try out.toOwnedSlice(lx.a), i + 1 },
                '\\' => {
                    i += 1;
                    if (i == s.len) break;
                    try out.append(lx.a, switch (s[i]) {
                        'n' => '\n',
                        't' => '\t',
                        '"', '\\' => s[i],
                        else => {
                            lx.diag.fail(lx.no, @intCast(i), "unknown escape \\{c}", .{s[i]});
                            return error.ScriptSyntax;
                        },
                    });
                },
                else => |c| try out.append(lx.a, c),
            }
        }
        lx.diag.fail(lx.no, @intCast(at + 1), "unterminated string", .{});
        return error.ScriptSyntax;
    }
};

const Parser = struct {
    a: Allocator,
    line: []const u8,
    no: u32,
    toks: []Tok,
    i: usize = 0,
    diag: *Diag,

    fn peek(p: *Parser) ?Tok {
        return if (p.i < p.toks.len) p.toks[p.i] else null;
    }

    fn col(p: *Parser) u32 {
        return if (p.peek()) |t| t.col else @intCast(p.line.len + 1);
    }

    fn err(p: *Parser, comptime fmt: []const u8, args: anytype) Error {
        p.diag.fail(p.no, p.col(), fmt, args);
        return error.ScriptSyntax;
    }

    fn word(p: *Parser, what: []const u8) Error![]const u8 {
        const t = p.peek() orelse return p.err("expected {s}", .{what});
        if (t.kind != .word) return p.err("expected {s}", .{what});
        p.i += 1;
        return t.text;
    }

    fn string(p: *Parser, what: []const u8) Error![]const u8 {
        const t = p.peek() orelse return p.err("expected {s} in quotes", .{what});
        if (t.kind != .string) return p.err("expected {s} in quotes", .{what});
        p.i += 1;
        return t.text;
    }

    fn number(p: *Parser, what: []const u8) Error!f32 {
        const at = p.col();
        const w = try p.word(what);
        return std.fmt.parseFloat(f32, w) catch {
            p.diag.fail(p.no, at, "expected {s}, got \"{s}\"", .{ what, w });
            return error.ScriptSyntax;
        };
    }

    fn end(p: *Parser) Error!void {
        if (p.peek() != null) return p.err("unexpected \"{s}\"", .{p.line[p.toks[p.i].start..p.toks[p.i].end]});
    }

    fn isQueryKey(k: []const u8) bool {
        for ([_][]const u8{ "role", "name", "name~", "testid", "test_id", "kind", "nth" }) |q| if (std.mem.eql(u8, k, q)) return true;
        return false;
    }

    fn query(p: *Parser) Error!Q {
        var q: Q = .{};
        const first = p.peek() orelse return p.err("expected a query", .{});
        var any = false;
        while (p.peek()) |t| {
            if (t.kind == .word and std.mem.eql(u8, t.text, "within")) {
                p.i += 1;
                const lp = p.peek() orelse return p.err("expected ( after within", .{});
                if (lp.kind != .lparen) return p.err("expected ( after within", .{});
                p.i += 1;
                const inner = try p.a.create(Q);
                inner.* = try p.query();
                const rp = p.peek() orelse return p.err("expected )", .{});
                if (rp.kind != .rparen) return p.err("expected )", .{});
                p.i += 1;
                q.within = inner;
            } else if (t.kind == .kv and isQueryKey(t.text)) {
                p.i += 1;
                const k = t.text;
                if (std.mem.eql(u8, k, "role")) {
                    const name = if (std.mem.eql(u8, t.value, "switch")) "switch_" else t.value;
                    q.q.role = std.meta.stringToEnum(widget.Role, name) orelse {
                        p.diag.fail(p.no, t.col, "unknown role \"{s}\"", .{t.value});
                        return error.ScriptSyntax;
                    };
                } else if (std.mem.eql(u8, k, "name")) {
                    q.q.name = t.value;
                } else if (std.mem.eql(u8, k, "name~")) {
                    q.q.name_contains = t.value;
                } else if (std.mem.eql(u8, k, "kind")) {
                    q.q.kind = t.value;
                } else if (std.mem.eql(u8, k, "nth")) {
                    q.nth = std.fmt.parseInt(usize, t.value, 10) catch {
                        p.diag.fail(p.no, t.col, "nth wants a number", .{});
                        return error.ScriptSyntax;
                    };
                } else q.q.test_id = t.value;
            } else break;
            any = true;
        }
        if (!any) return p.err("expected a query (role=, name=, name~=, testid=, kind=, nth=, within(...))", .{});
        const last = p.toks[p.i - 1];
        q.src = p.line[first.start..last.end];
        return q;
    }

    fn command(p: *Parser) Error!Op {
        const verb = try p.word("a command");
        const eql = std.mem.eql;
        if (eql(u8, verb, "open")) {
            const v = try p.word("a view name");
            var args: std.ArrayList(Arg) = .empty;
            while (p.peek()) |t| {
                if (t.kind != .kv) return p.err("expected key=value", .{});
                p.i += 1;
                try args.append(p.a, .{ .key = t.text, .value = t.value });
            }
            return .{ .open = .{ .view = v, .args = try args.toOwnedSlice(p.a) } };
        }
        if (eql(u8, verb, "click")) return .{ .click = try p.query() };
        if (eql(u8, verb, "dblclick")) return .{ .dblclick = try p.query() };
        if (eql(u8, verb, "rclick")) return .{ .rclick = try p.query() };
        if (eql(u8, verb, "hover")) return .{ .hover = try p.query() };
        if (eql(u8, verb, "type")) return .{ .type = try p.string("the text") };
        if (eql(u8, verb, "press")) {
            const at = p.col();
            const chord = try p.word("a key chord");
            return .{ .press = parseChord(chord) orelse {
                p.diag.fail(p.no, at, "unknown key chord \"{s}\"", .{chord});
                return error.ScriptSyntax;
            } };
        }
        if (eql(u8, verb, "scroll")) {
            const q = try p.query();
            return .{ .scroll = .{ .q = q, .dx = try p.number("dx"), .dy = try p.number("dy") } };
        }
        if (eql(u8, verb, "drag")) {
            const q = try p.query();
            const to = try p.word("to");
            if (!eql(u8, to, "to")) {
                p.i -= 1;
                return p.err("expected to", .{});
            }
            if (p.peek()) |t| if (t.kind == .word) if (std.mem.indexOfScalar(u8, t.text, ',')) |comma| {
                p.i += 1;
                const x = std.fmt.parseFloat(f32, t.text[0..comma]) catch null;
                const y = std.fmt.parseFloat(f32, t.text[comma + 1 ..]) catch null;
                if (x == null or y == null) {
                    p.diag.fail(p.no, t.col, "expected x,y", .{});
                    return error.ScriptSyntax;
                }
                return .{ .drag = .{ .q = q, .to = .{ .pt = .{ .x = x.?, .y = y.? } } } };
            };
            return .{ .drag = .{ .q = q, .to = .{ .q = try p.query() } } };
        }
        if (eql(u8, verb, "wait")) {
            const at = p.col();
            const w = try p.word("a duration (500ms)");
            const digits = if (std.mem.endsWith(u8, w, "ms")) w[0 .. w.len - 2] else w;
            return .{ .wait = std.fmt.parseInt(u64, digits, 10) catch {
                p.diag.fail(p.no, at, "expected a duration like 500ms, got \"{s}\"", .{w});
                return error.ScriptSyntax;
            } };
        }
        if (eql(u8, verb, "resize")) {
            const w = try p.number("a width");
            const h = try p.number("a height");
            const scale: ?f32 = if (p.peek() != null) try p.number("a scale") else null;
            return .{ .resize = .{ .size = .{ .w = w, .h = h }, .scale = scale } };
        }
        if (eql(u8, verb, "theme")) {
            const at = p.col();
            const name = try p.word("a theme");
            const map = [_]struct { []const u8, *const themes.Theme }{
                .{ "dark", &themes.zigguro_dark },
                .{ "light", &themes.zigguro_light },
                .{ "hc-dark", &themes.zigguro_hc_dark },
                .{ "hc-light", &themes.zigguro_hc_light },
            };
            for (map) |e| if (eql(u8, e[0], name)) return .{ .theme = e[1] };
            p.diag.fail(p.no, at, "unknown theme \"{s}\" (dark, light, hc-dark, hc-light)", .{name});
            return error.ScriptSyntax;
        }
        if (eql(u8, verb, "expect")) {
            const q = try p.query();
            var check: Check = .exists;
            if (p.peek()) |t| {
                p.i += 1;
                check = switch (t.kind) {
                    .word => if (eql(u8, t.text, "exists")) .exists else if (eql(u8, t.text, "absent")) .absent else if (eql(u8, t.text, "focused")) .focused else if (eql(u8, t.text, "checked")) .{ .checked = true } else if (eql(u8, t.text, "unchecked")) .{ .checked = false } else if (eql(u8, t.text, "disabled")) .disabled else {
                        p.i -= 1;
                        return p.err("unknown expectation \"{s}\"", .{t.text});
                    },
                    .kv => if (eql(u8, t.text, "text")) .{ .text = t.value } else if (eql(u8, t.text, "value")) .{ .value = std.fmt.parseFloat(f32, t.value) catch {
                        p.i -= 1;
                        return p.err("value wants a number", .{});
                    } } else if (eql(u8, t.text, "count")) .{ .count = std.fmt.parseInt(usize, t.value, 10) catch {
                        p.i -= 1;
                        return p.err("count wants a number", .{});
                    } } else {
                        p.i -= 1;
                        return p.err("unknown expectation \"{s}=\"", .{t.text});
                    },
                    else => {
                        p.i -= 1;
                        return p.err("unknown expectation", .{});
                    },
                };
            }
            return .{ .expect = .{ .q = q, .check = check } };
        }
        if (eql(u8, verb, "snapshot")) {
            const at = p.col();
            const k = try p.word("layout, semantics or pixels");
            const kind = std.meta.stringToEnum(SnapshotKind, k) orelse {
                p.diag.fail(p.no, at, "unknown snapshot \"{s}\" (layout, semantics, pixels)", .{k});
                return error.ScriptSyntax;
            };
            return .{ .snapshot = .{ .kind = kind, .name = try p.string("the snapshot name") } };
        }
        if (eql(u8, verb, "ime")) {
            p.i -= 1;
            return p.err("ime is not supported yet (the window has no composition route)", .{});
        }
        p.i -= 1;
        return p.err("unknown command \"{s}\"", .{verb});
    }
};

/// Parses every line of `src` (allocations in `a`).
pub fn parse(a: Allocator, src: []const u8, diag: *Diag) Error![]Cmd {
    var out: std.ArrayList(Cmd) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    var no: u32 = 0;
    while (it.next()) |line| {
        no += 1;
        var lx: Lexer = .{ .a = a, .line = line, .no = no, .diag = diag };
        const toks = try lx.tokens();
        if (toks.len == 0) continue;
        var p: Parser = .{ .a = a, .line = line, .no = no, .toks = toks, .diag = diag };
        const op = try p.command();
        try p.end();
        try out.append(a, .{ .line = no, .col = toks[0].col, .op = op });
    }
    return out.toOwnedSlice(a);
}

/// A key and its modifiers.
pub const Chord = struct { key: Key, mods: Mods };

/// `ctrl+shift+p`, `escape`, `f10`, `KeyA` (W3C code), `a`, `1`.
pub fn parseChord(chord: []const u8) ?Chord {
    var mods: Mods = .{};
    var it = std.mem.splitScalar(u8, chord, '+');
    var last: []const u8 = "";
    while (it.next()) |part| {
        if (it.peek() == null) {
            last = part;
            break;
        }
        var buf: [16]u8 = undefined;
        if (part.len > buf.len) return null;
        const m = std.ascii.lowerString(&buf, part);
        if (std.mem.eql(u8, m, "ctrl") or std.mem.eql(u8, m, "control")) {
            mods.ctrl = true;
        } else if (std.mem.eql(u8, m, "shift")) {
            mods.shift = true;
        } else if (std.mem.eql(u8, m, "alt") or std.mem.eql(u8, m, "option")) {
            mods.alt = true;
        } else if (std.mem.eql(u8, m, "super") or std.mem.eql(u8, m, "cmd") or std.mem.eql(u8, m, "meta") or std.mem.eql(u8, m, "win")) {
            mods.super = true;
        } else return null;
    }
    const key = keyNamed(last) orelse return null;
    return .{ .key = key, .mods = mods };
}

fn keyNamed(s: []const u8) ?Key {
    if (s.len == 0) return null;
    if (Key.fromName(s)) |k| return k;
    var buf: [32]u8 = undefined;
    if (s.len > buf.len - 6) return null;
    const l = std.ascii.lowerString(buf[6..], s);
    if (l.len == 1 and std.ascii.isAlphabetic(l[0])) {
        @memcpy(buf[2..6], "key_");
        return std.meta.stringToEnum(Key, buf[2 .. 6 + 1]);
    }
    if (l.len == 1 and std.ascii.isDigit(l[0])) {
        @memcpy(buf[0..6], "digit_");
        return std.meta.stringToEnum(Key, buf[0 .. 6 + 1]);
    }
    const aliases = [_]struct { []const u8, Key }{
        .{ "esc", .escape },        .{ "del", .delete },      .{ "return", .enter },
        .{ "up", .arrow_up },       .{ "down", .arrow_down }, .{ "left", .arrow_left },
        .{ "right", .arrow_right }, .{ "pgup", .page_up },    .{ "pgdn", .page_down },
        .{ "menu", .context_menu },
    };
    for (aliases) |e| if (std.mem.eql(u8, e[0], l)) return e[1];
    const k = std.meta.stringToEnum(Key, l) orelse return null;
    return if (k == .unknown) null else k;
}

// -- running -----------------------------------------------------------

const Runner = struct {
    gpa: Allocator,
    opts: Options,
    diag: *Diag,
    t: ?*TestApp = null,
    mounted: ?Mounted = null,
    size: geom.Size,
    scale: f32,
    line: u32 = 0,
    col: u32 = 0,

    fn close(r: *Runner) void {
        if (r.t) |t| t.deinit();
        r.t = null;
        if (r.mounted) |m| m.destroy(m.ptr, r.gpa);
        r.mounted = null;
    }

    fn fail(r: *Runner, comptime fmt: []const u8, args: anytype) Error {
        r.diag.fail(r.line, r.col, fmt, args);
        return error.ScriptFailed;
    }

    fn app(r: *Runner) Error!*TestApp {
        return r.t orelse r.fail("no view is open: start with `open <View>`", .{});
    }

    fn resolve(r: *Runner, q: Q) Error!?NodeId {
        const t = try r.app();
        var base = q.q;
        if (q.within) |w| base.within = try r.resolve(w.*) orelse return null;
        return t.findNth(base, q.nth);
    }

    fn need(r: *Runner, q: Q) Error!NodeId {
        if (q.within) |w| if (try r.resolve(w.*) == null) return r.notFound(w.*);
        return try r.resolve(q) orelse r.notFound(q);
    }

    /// Fails with the five closest named nodes.
    fn notFound(r: *Runner, q: Q) Error {
        const t = r.t.?;
        const want = q.q.name orelse q.q.name_contains orelse q.q.test_id orelse "";
        var best: [5]struct { d: usize, n: NodeId } = undefined;
        var nb: usize = 0;
        r.rank(t, t.win.root, want, &best, &nb);
        var buf: [600]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        for (best[0..nb], 0..) |b, i| {
            const info = t.a11yOf(b.n).?;
            w.print("{s}{t} \"{s}\"", .{ if (i > 0) ", " else "", info.role, info.name }) catch break;
        }
        if (nb == 0) return r.fail("nothing matches {s} (no named nodes)", .{q.src});
        return r.fail("nothing matches {s}; closest: {s}", .{ q.src, w.buffered() });
    }

    fn rank(r: *Runner, t: *TestApp, n: NodeId, want: []const u8, best: anytype, nb: *usize) void {
        if (t.win.store.flags(n).hidden) return;
        if (t.a11yOf(n)) |info| if (info.role != .none and info.name.len > 0) {
            const d = levenshtein(info.name, want);
            var i = nb.*;
            if (i < best.len) nb.* += 1 else if (d >= best[best.len - 1].d) i = best.len else i = best.len - 1;
            if (i < best.len) {
                best[i] = .{ .d = d, .n = n };
                while (i > 0 and best[i - 1].d > best[i].d) : (i -= 1) std.mem.swap(@TypeOf(best[0]), &best[i - 1], &best[i]);
            }
        };
        var it = t.win.store.children(n);
        while (it.next()) |c| r.rank(t, c, want, best, nb);
    }

    fn exec(r: *Runner, c: Cmd) Error!void {
        r.line = c.line;
        r.col = c.col;
        switch (c.op) {
            .open => |o| {
                const e = for (r.opts.views) |v| {
                    if (std.mem.eql(u8, v.name, o.view)) break v;
                } else return r.fail("unknown view \"{s}\"", .{o.view});
                r.close();
                const m = e.open(e.ctx, r.gpa, o.args) catch |err| return r.fail("open {s}: {t}", .{ o.view, err });
                r.mounted = m;
                r.t = TestApp.init(r.gpa, .{ .root = m.view, .size = r.size, .scale = r.scale }) catch |err| return r.fail("open {s}: {t}", .{ o.view, err });
                _ = r.t.?.settle();
            },
            .click => |q| try r.at(q, .click),
            .dblclick => |q| try r.at(q, .dblclick),
            .rclick => |q| try r.at(q, .rclick),
            .hover => |q| try r.at(q, .hover),
            .type => |s| (try r.app()).typeText(s),
            .press => |k| (try r.app()).press(k.key, k.mods),
            .scroll => |s| {
                const t = try r.app();
                const n = try r.need(s.q);
                t.scroll(.{ .within = n }, s.dx, s.dy) catch unreachable;
            },
            .drag => |d| {
                const t = try r.app();
                const from = try r.need(d.q);
                const to: geom.Vec2 = switch (d.to) {
                    .pt => |p| p,
                    .q => |q| blk: {
                        const rr = t.win.store.absRect(try r.need(q));
                        break :blk .{ .x = rr.x + rr.w / 2, .y = rr.y + rr.h / 2 };
                    },
                };
                t.drag(.{ .within = from }, to) catch unreachable;
            },
            .wait => |ms| (try r.app()).advance(ms),
            .resize => |s| {
                r.size = s.size;
                if (s.scale) |sc| r.scale = sc;
                const t = r.t orelse return;
                t.win.resize(r.size, r.scale);
                t.win.markAllDirty();
                _ = t.settle();
            },
            .theme => |th| {
                const t = try r.app();
                t.app.follow_system = false;
                t.app.setTheme(th);
                _ = t.settle();
            },
            .expect => |e| try r.expect(e.q, e.check),
            .snapshot => |s| {
                const t = try r.app();
                const sink = r.opts.snapshot orelse return;
                const text = switch (s.kind) {
                    .layout => try t.layoutSnapshot(r.gpa),
                    .semantics => try t.semanticsSnapshot(r.gpa),
                    .pixels => try r.gpa.dupe(u8, t.paintSnapshot()),
                };
                defer r.gpa.free(text);
                sink.f(sink.ctx, s.kind, s.name, text) catch |err| return r.fail("snapshot {t} \"{s}\": {t}", .{ s.kind, s.name, err });
            },
        }
    }

    fn at(r: *Runner, q: Q, what: enum { click, dblclick, rclick, hover }) Error!void {
        const t = try r.app();
        // Match the found node itself (`within` it, first match = it).
        const sel: test_app.Query = .{ .within = try r.need(q) };
        switch (what) {
            .click => t.click(sel) catch unreachable,
            .dblclick => t.doubleClick(sel) catch unreachable,
            .rclick => t.rightClick(sel) catch unreachable,
            .hover => t.hover(sel) catch unreachable,
        }
    }

    fn expect(r: *Runner, q: Q, check: Check) Error!void {
        const t = try r.app();
        switch (check) {
            .absent => if (try r.resolve(q) != null) return r.fail("expected no {s}", .{q.src}),
            .count => |want| {
                var base = q.q;
                if (q.within) |w| base.within = try r.resolve(w.*) orelse return if (want == 0) {} else r.notFound(w.*);
                const got = t.count(base);
                if (got != want) return r.fail("expected {d} of {s}, found {d}", .{ want, q.src, got });
            },
            else => {
                const n = try r.need(q);
                const info = t.a11yOf(n) orelse widget.A11y{};
                switch (check) {
                    .exists, .absent, .count => {},
                    .focused => if (t.win.focus != n) return r.fail("expected {s} to be focused", .{q.src}),
                    .checked => |want| if (info.checked != want) return r.fail("expected {s} to be {s}", .{ q.src, if (want) "checked" else "unchecked" }),
                    .disabled => if (!info.disabled) return r.fail("expected {s} to be disabled", .{q.src}),
                    .text => |want| {
                        const got = if (info.role == .textbox) info.text else info.name;
                        if (!std.mem.eql(u8, got, want)) return r.fail("expected {s} text \"{s}\", got \"{s}\"", .{ q.src, want, got });
                    },
                    .value => |want| {
                        const got = info.value orelse return r.fail("{s} has no value", .{q.src});
                        if (@abs(got - want) > 0.005) return r.fail("expected {s} value {d}, got {d}", .{ q.src, want, got });
                    },
                }
            },
        }
    }
};

fn levenshtein(a: []const u8, b: []const u8) usize {
    var row: [128]usize = undefined;
    const bl = @min(b.len, row.len - 1);
    for (0..bl + 1) |j| row[j] = j;
    for (a, 0..) |ca, i| {
        var prev = row[0];
        row[0] = i + 1;
        for (b[0..bl], 0..) |cb, j| {
            const cur = row[j + 1];
            row[j + 1] = @min(@min(row[j + 1] + 1, row[j] + 1), prev + @intFromBool(std.ascii.toLower(ca) != std.ascii.toLower(cb)));
            prev = cur;
        }
    }
    return row[bl];
}

test "chords" {
    const k = parseChord("ctrl+shift+p").?;
    try std.testing.expectEqual(Key.key_p, k.key);
    try std.testing.expect(k.mods.ctrl and k.mods.shift and !k.mods.alt);
    try std.testing.expectEqual(Key.escape, parseChord("Escape").?.key);
    try std.testing.expectEqual(Key.escape, parseChord("esc").?.key);
    try std.testing.expectEqual(Key.f10, parseChord("shift+f10").?.key);
    try std.testing.expectEqual(Key.key_a, parseChord("KeyA").?.key);
    try std.testing.expectEqual(Key.digit_1, parseChord("alt+1").?.key);
    try std.testing.expectEqual(Key.arrow_left, parseChord("left").?.key);
    try std.testing.expect(parseChord("hyper+x") == null);
    try std.testing.expect(parseChord("nosuchkey") == null);
}

test "levenshtein" {
    try std.testing.expectEqual(@as(usize, 0), levenshtein("Run", "run"));
    try std.testing.expectEqual(@as(usize, 2), levenshtein("Run", "Rnu"));
    try std.testing.expectEqual(@as(usize, 3), levenshtein("", "abc"));
}

test {
    std.testing.refAllDecls(@This());
}
