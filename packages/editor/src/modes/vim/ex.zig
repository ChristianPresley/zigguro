//! A subset of Vim's ex commands (cmdline.txt): ranges (`%`, `.`, `$`,
//! numbers, marks, `/pat/`, `+n`/`-n`), `:{n}`, `:s` (flags `g`, `i`,
//! `I`, `e`, `n`, `&`), `:g`/`:v` with any of these commands (`:d` in one
//! pass), `:normal`, `:p` (moves the cursor only), `:d`, `:noh`, `:set`
//! for `number`, `relativenumber`, `wrap`, `ignorecase`, `smartcase`, and
//! `:w`, `:q`, `:wq`, `:x`, `:e` through the host's actions.
//!
//! `:s` and `:g` translate the pattern with `pattern.zig`, match with the
//! find engine's tree input and expand replacements with the replace
//! engine (E05.F06); each command is one undo step, `:g` and `:normal`
//! included (`VimState.group_held`).

const std = @import("std");
const zg_regex = @import("zg_regex");
const state_mod = @import("state.zig");
const mode_mod = @import("../mode.zig");
const ops = @import("operators.zig");
const text_mod = @import("text.zig");
const pattern = @import("pattern.zig");
const search_mod = @import("search.zig");
const registers = @import("registers.zig");
const find = @import("../../model/search/find.zig");
const replace_mod = @import("../../model/search/replace.zig");
const cs_mod = @import("../../model/edit/change_set.zig");

const Allocator = std.mem.Allocator;
const VimState = state_mod.VimState;
const Host = mode_mod.Host;
const Text = text_mod.Text;

pub const ExResult = union(enum) {
    ok,
    /// Information for the status line.
    message: []const u8,
    err: []const u8,
};

/// Vim's 'report': changes to more lines than this are reported.
const report = 2;

const Range = struct { l0: u64, l1: u64, given: bool };

const Parser = struct {
    s: []const u8,
    i: usize = 0,

    fn peek(p: *const Parser) ?u8 {
        return if (p.i < p.s.len) p.s[p.i] else null;
    }

    fn skipSpace(p: *Parser) void {
        while (p.i < p.s.len and (p.s[p.i] == ' ' or p.s[p.i] == '\t' or p.s[p.i] == ':')) p.i += 1;
    }

    fn number(p: *Parser) ?u64 {
        const st = p.i;
        while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i])) p.i += 1;
        if (p.i == st) return null;
        return std.fmt.parseInt(u64, p.s[st..p.i], 10) catch std.math.maxInt(u64);
    }

    /// Text up to an unescaped `delim` (escapes kept, except `\delim` for
    /// a delimiter other than `/`, which becomes the delimiter itself);
    /// the delimiter is consumed.
    fn until(p: *Parser, gpa: Allocator, delim: u8, out: *std.ArrayList(u8)) !bool {
        while (p.i < p.s.len) {
            const c = p.s[p.i];
            if (c == '\\' and p.i + 1 < p.s.len) {
                if (p.s[p.i + 1] == delim and delim != '/') {
                    try out.append(gpa, delim);
                } else try out.appendSlice(gpa, p.s[p.i .. p.i + 2]);
                p.i += 2;
                continue;
            }
            p.i += 1;
            if (c == delim) return true;
            try out.append(gpa, c);
        }
        return false;
    }
};

const ExError = error{ExFailed} || Allocator.Error;

/// Runs one command line (without the leading `:`).
pub fn runEx(vs: *VimState, host: *Host, line: []const u8) anyerror!ExResult {
    var e: Ex = .{ .vs = vs, .host = host, .p = .{ .s = line } };
    return e.run() catch |err| switch (err) {
        error.ExFailed => .{ .err = vs.message[0..vs.message_len] },
        else => return err,
    };
}

const Ex = struct {
    vs: *VimState,
    host: *Host,
    p: Parser,

    fn fail(e: *Ex, comptime fmt: []const u8, args: anytype) ExError {
        _ = e.vs.setMessage(true, fmt, args);
        return error.ExFailed;
    }

    fn msg(e: *Ex, comptime fmt: []const u8, args: anytype) ExResult {
        return .{ .message = e.vs.setMessage(false, fmt, args) };
    }

    fn x(e: *Ex) Text {
        return ops.txt(e.host);
    }

    fn curLine(e: *Ex) u64 {
        const c = e.vs.cursors.items;
        return e.x().lineOf(if (c.len > 0) c[0].pos else 0);
    }

    fn run(e: *Ex) !ExResult {
        e.p.skipSpace();
        if (e.p.i >= e.p.s.len) return .ok;
        const range = try e.parseRange();
        e.p.skipSpace();
        const name_start = e.p.i;
        if (e.p.peek() == '&') {
            // ":&&" repeats the last substitute with its flags.
            e.p.i += 1;
            const flags = std.mem.trim(u8, e.p.s[e.p.i..], " \t");
            return e.substitute(range, if (flags.len == 0) " " else flags);
        }
        while (e.p.i < e.p.s.len and std.ascii.isAlphabetic(e.p.s[e.p.i])) e.p.i += 1;
        const name = e.p.s[name_start..e.p.i];
        var bang = false;
        if (e.p.peek() == '!') {
            bang = true;
            e.p.i += 1;
        }
        if (name.len == 0) {
            if (bang or e.p.i < e.p.s.len) return e.fail("E492: Not an editor command: {s}", .{e.p.s});
            if (!range.given) return .ok;
            return e.gotoLine(range.l1);
        }
        const rest = std.mem.trim(u8, e.p.s[e.p.i..], " \t");
        if (abbrev(name, "substitute", 1)) return e.substitute(range, rest);
        if (abbrev(name, "global", 1) or abbrev(name, "vglobal", 1)) return e.global(range, std.mem.eql(u8, name[0..1], "v") or bang, rest);
        if (abbrev(name, "delete", 1)) return e.deleteLines(range.l0, range.l1, rest);
        if (abbrev(name, "normal", 4)) return e.normal(range, rest);
        if (abbrev(name, "nohlsearch", 3)) {
            e.vs.sh().highlight_off = true;
            return .ok;
        }
        if (abbrev(name, "set", 2)) return e.set(rest);
        // Nothing to print to; `:g/pat/` (`:g/pat/p`) just moves the cursor.
        if (abbrev(name, "print", 1)) {
            const xx = e.x();
            const pos = xx.firstNonBlank(range.l1);
            e.vs.cursors.clearRetainingCapacity();
            try e.vs.cursors.append(e.vs.gpa, .{ .pos = pos, .want = xx.column(pos) });
            return .ok;
        }
        if (abbrev(name, "let", 3)) return e.let(rest);
        if (std.mem.eql(u8, name, "wq") or std.mem.eql(u8, name, "x") or abbrev(name, "xit", 2) or abbrev(name, "exit", 3)) {
            if (std.mem.eql(u8, name, "wq")) {
                try e.action(.{ .write = .{ .path = nonEmpty(rest), .force = bang } });
                try e.action(.{ .quit = .{ .force = bang } });
            } else try e.action(.exit);
            return .ok;
        }
        if (abbrev(name, "write", 1)) {
            try e.action(.{ .write = .{ .path = nonEmpty(rest), .force = bang } });
            return .ok;
        }
        if (abbrev(name, "quit", 1)) {
            try e.action(.{ .quit = .{ .force = bang } });
            return .ok;
        }
        if (abbrev(name, "edit", 1)) {
            try e.action(.{ .edit = .{ .path = nonEmpty(rest), .force = bang } });
            return .ok;
        }
        return e.fail("E492: Not an editor command: {s}", .{e.p.s});
    }

    fn action(e: *Ex, a: mode_mod.Action) !void {
        const acts = e.host.actions orelse return e.fail("E492: Not available here: {s}", .{e.p.s});
        acts.runFn(acts.ctx, a) catch |err| return e.fail("E: {t}", .{err});
    }

    // -- ranges -------------------------------------------------------------------

    fn parseRange(e: *Ex) !Range {
        const cur = e.curLine();
        const last = e.x().lineCount() - 1;
        if (e.p.peek() == '%') {
            e.p.i += 1;
            return .{ .l0 = 0, .l1 = last, .given = true };
        }
        const a = try e.address(cur) orelse return .{ .l0 = cur, .l1 = cur, .given = false };
        var b = a;
        while (e.p.peek() == ',' or e.p.peek() == ';') {
            e.p.i += 1;
            b = try e.address(cur) orelse cur;
        }
        if (a > b) return e.fail("E493: Backwards range given", .{});
        if (b > last) return e.fail("E16: Invalid range", .{});
        return .{ .l0 = a, .l1 = b, .given = true };
    }

    /// One address with its `+n`/`-n` offsets (lines, zero-based).
    fn address(e: *Ex, cur: u64) !?u64 {
        e.p.skipSpace();
        const xx = e.x();
        const last = xx.lineCount() - 1;
        var base: ?i64 = null;
        if (e.p.peek()) |c| switch (c) {
            '0'...'9' => {
                const n = e.p.number().?;
                base = @as(i64, @intCast(@min(n, 1 << 40))) - 1;
            },
            '.' => {
                e.p.i += 1;
                base = @intCast(cur);
            },
            '$' => {
                e.p.i += 1;
                base = @intCast(last);
            },
            '\'' => {
                if (e.p.i + 1 >= e.p.s.len) return e.fail("E20: Mark not set", .{});
                const m = e.p.s[e.p.i + 1];
                e.p.i += 2;
                const pos = e.vs.markPos(m) orelse return e.fail("E20: Mark not set", .{});
                base = @intCast(xx.lineOf(pos));
            },
            '/', '?' => {
                e.p.i += 1;
                var pat: std.ArrayList(u8) = .empty;
                defer pat.deinit(e.vs.gpa);
                _ = try e.p.until(e.vs.gpa, c, &pat);
                base = @intCast(try e.searchLine(pat.items, cur, c == '?'));
            },
            else => {},
        };
        while (e.p.peek()) |c| {
            if (c != '+' and c != '-') break;
            e.p.i += 1;
            const n: i64 = @intCast(e.p.number() orelse 1);
            if (base == null) base = @intCast(cur);
            base = if (c == '+') base.? + n else base.? - n;
        }
        const b = base orelse return null;
        if (b < 0) return e.fail("E16: Invalid range", .{});
        return @intCast(b);
    }

    /// `/pat/` in a range: the next line (after the cursor's) that matches.
    fn searchLine(e: *Ex, pat_in: []const u8, cur: u64, backward: bool) !u64 {
        const sh = e.vs.sh();
        const pat = if (pat_in.len == 0) sh.search.pattern.items else pat_in;
        if (pat.len == 0) return e.fail("E35: No previous regular expression", .{});
        e.vs.setSearch(pat, backward) catch return error.ExFailed;
        const xx = e.x();
        const from = if (backward) xx.lineStart(cur) else xx.lineEnd(cur);
        const p = sh.search.next(&e.host.doc.tree, from, backward) orelse return e.fail("E486: Pattern not found: {s}", .{pat});
        return xx.lineOf(p);
    }

    fn gotoLine(e: *Ex, l: u64) !ExResult {
        const xx = e.x();
        const vs = e.vs;
        const before = if (vs.cursors.items.len > 0) vs.cursors.items[0].pos else 0;
        const p = xx.firstNonBlank(@min(l, xx.lineCount() - 1));
        vs.cursors.clearRetainingCapacity();
        try vs.cursors.append(vs.gpa, .{ .pos = p, .want = xx.column(p) });
        try vs.marks.pushJump(vs.gpa, before);
        return .ok;
    }

    /// `:let @r = 'text'` (or "text"): sets a register, the only use of
    /// `:let` supported.
    fn let(e: *Ex, rest: []const u8) !ExResult {
        const vs = e.vs;
        if (rest.len < 2 or rest[0] != '@') return e.fail("E5: only :let @r = 'text' is supported", .{});
        const name = rest[1];
        const value = std.mem.trim(u8, rest[2..], " \t");
        if (value.len < 3 or value[0] != '=') return e.fail("E15: Invalid expression: {s}", .{rest});
        const lit = std.mem.trim(u8, value[1..], " \t");
        if (lit.len < 2 or (lit[0] != '\'' and lit[0] != '"') or lit[lit.len - 1] != lit[0]) return e.fail("E15: Invalid expression: {s}", .{lit});
        if (!registers.Registers.valid(name) or name == '.' or name == ':' or name == '%') return e.fail("E354: Invalid register name: '{c}'", .{name});
        const body = lit[1 .. lit.len - 1];
        try vs.sh().regs.put(name, body, .charwise);
        return .ok;
    }

    // -- :s ---------------------------------------------------------------------

    fn substitute(e: *Ex, range: Range, rest: []const u8) !ExResult {
        const vs = e.vs;
        const gpa = vs.gpa;
        const sh = vs.sh();
        var pat: std.ArrayList(u8) = .empty;
        defer pat.deinit(gpa);
        var rep: std.ArrayList(u8) = .empty;
        defer rep.deinit(gpa);
        var flags: []const u8 = "";
        var p: Parser = .{ .s = rest };
        const repeat_last = rest.len == 0 or std.ascii.isAlphanumeric(rest[0]) or rest[0] == '&' or rest[0] == ' ';
        if (repeat_last) {
            // ":s" (and ":s g") repeats the last substitute.
            if (!sh.sub_used) return e.fail("E35: No previous regular expression", .{});
            try pat.appendSlice(gpa, sh.search.pattern.items);
            try rep.appendSlice(gpa, sh.sub_replacement.items);
            flags = std.mem.trim(u8, rest, " ");
            if (flags.len > 0 and flags[0] == '&') {
                const keep = sh.sub_flags[0..sh.sub_flags_len];
                var buf: [16]u8 = undefined;
                const merged = std.fmt.bufPrint(&buf, "{s}{s}", .{ keep, flags[1..] }) catch keep;
                return e.substituteWith(range, pat.items, rep.items, merged);
            }
        } else {
            const delim = rest[0];
            if (delim == '\\' or delim == '"' or delim == '|') return e.fail("E146: Regular expressions can't be delimited by letters", .{});
            p.i = 1;
            _ = try p.until(gpa, delim, &pat);
            _ = try p.until(gpa, delim, &rep);
            flags = std.mem.trim(u8, p.s[@min(p.i, p.s.len)..], " ");
            if (pat.items.len == 0) {
                if (sh.search.pattern.items.len == 0) return e.fail("E35: No previous regular expression", .{});
                try pat.appendSlice(gpa, sh.search.pattern.items);
            }
        }
        return e.substituteWith(range, pat.items, rep.items, flags);
    }

    fn substituteWith(e: *Ex, range: Range, pat: []const u8, rep_in: []const u8, flags_in: []const u8) !ExResult {
        const vs = e.vs;
        const gpa = vs.gpa;
        const sh = vs.sh();
        var all = false;
        var report_only = false;
        var quiet = false;
        var case: ?bool = null;
        var flags = flags_in;
        if (flags.len > 0 and flags[0] == '&') {
            flags = flags[1..];
        }
        for (flags) |f| switch (f) {
            'g' => all = !all,
            'i' => case = true,
            'I' => case = false,
            'e' => quiet = true,
            'n' => report_only = true,
            'c' => return e.fail("E5: the c flag (confirm) is not supported yet", .{}),
            ' ', '0'...'9' => {},
            else => return e.fail("E488: Trailing characters: {s}", .{flags}),
        };
        // The pattern becomes the last search pattern; ~ is the previous
        // replacement.
        const pat_copy = try gpa.dupe(u8, pat);
        defer gpa.free(pat_copy);
        vs.setSearch(pat_copy, false) catch return error.ExFailed;
        var d: pattern.Diag = .{};
        const template = pattern.translateReplacement(gpa, rep_in, sh.sub_replacement.items, &d) catch |err| switch (err) {
            error.Unsupported, error.Syntax => return e.fail("E5: {s}", .{d.msg}),
            else => return err,
        };
        defer gpa.free(template);
        // Store the replacement with ~ expanded.
        {
            var expanded: std.ArrayList(u8) = .empty;
            defer expanded.deinit(gpa);
            var k: usize = 0;
            while (k < rep_in.len) : (k += 1) {
                if (rep_in[k] == '\\' and k + 1 < rep_in.len) {
                    try expanded.appendSlice(gpa, rep_in[k .. k + 2]);
                    k += 1;
                } else if (rep_in[k] == '~') {
                    try expanded.appendSlice(gpa, sh.sub_replacement.items);
                } else try expanded.append(gpa, rep_in[k]);
            }
            sh.sub_replacement.clearRetainingCapacity();
            try sh.sub_replacement.appendSlice(gpa, expanded.items);
            sh.sub_used = true;
            const fl = flags[0..@min(flags.len, sh.sub_flags.len)];
            @memcpy(sh.sub_flags[0..fl.len], fl);
            sh.sub_flags_len = @intCast(fl.len);
        }

        // Without i/I the pattern compiles as the last search did, so
        // that regex is reused (`:g` runs :s once per line).
        var own: ?zg_regex.Regex = if (case != null) try compileFor(e, pat_copy, case) else null;
        defer if (own) |*r| r.deinit(gpa);
        const re: *zg_regex.Regex = if (own) |*r| r else &sh.search.re.?;
        var own_cache: ?zg_regex.Cache = if (own) |*r| try r.newCache(gpa) else null;
        defer if (own_cache) |*c| c.deinit();
        const cache: *zg_regex.Cache = if (own_cache) |*c| c else &sh.search.cache.?;
        var caps = try re.newCaptures(gpa);
        defer caps.deinit(gpa);

        const xx = e.x();
        const tree = &e.host.doc.tree;
        const in = find.treeInput(tree);
        const span_start = xx.lineStart(range.l0);
        const span_end = xx.nextLineStart(range.l1);
        const limit = xx.lineEnd(range.l1);
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var edits: std.ArrayList(cs_mod.Replace) = .empty;
        var lines: u64 = 0;
        var last_line: ?u64 = null;
        var last_text: []const u8 = "";
        var it = re.findIter(cache, in.withSpan(.{ .start = span_start, .end = span_end }));
        while (it.next()) |m| {
            if (m.start > limit) break;
            const l = xx.lineOf(m.start);
            if (last_line != null and last_line.? == l and !all) continue;
            // A match may not start inside the previous replacement.
            if (edits.items.len > 0 and m.start < edits.items[edits.items.len - 1].range.end) continue;
            if (last_line == null or last_line.? != l) lines += 1;
            last_line = l;
            const texts = try a.alloc(?[]const u8, caps.len());
            if (re.captures(cache, in.withSpan(.{ .start = m.start, .end = span_end }).withAnchored(true), &caps)) {
                for (texts, 0..) |*t, i| t.* = if (caps.get(i)) |g| try tree.copyRange(a, .{ .start = g.start, .end = g.end }) else null;
            } else {
                @memset(texts, null);
                texts[0] = try tree.copyRange(a, .{ .start = m.start, .end = m.end });
            }
            const sg: replace_mod.SliceGroups = .{ .texts = texts, .names = re.captureNames() };
            const out = try replace_mod.expandReplacement(a, template, sg.groups(), false);
            try edits.append(a, .{ .range = .{ .start = m.start, .end = m.end }, .text = out });
            last_text = texts[0] orelse "";
        }
        const n = edits.items.len;
        if (n == 0) {
            if (quiet) return .ok;
            return e.fail("E486: Pattern not found: {s}", .{pat_copy});
        }
        if (report_only) return e.msg("{d} match{s} on {d} line{s}", .{ n, if (n == 1) "" else "es", lines, if (lines == 1) "" else "s" });

        // One undo step; the cursor goes to the start of the last line
        // changed.
        try vs.beginChange(e.host);
        defer vs.commitChange(e.host) catch {};
        try ops.apply(e.host, edits.items);
        var shift: i64 = 0;
        for (edits.items[0 .. n - 1]) |ed| shift += @as(i64, @intCast(ed.text.len)) - @as(i64, @intCast(ed.range.end - ed.range.start));
        const last = edits.items[n - 1];
        const new_end: u64 = @intCast(@as(i64, @intCast(last.range.start)) + shift + @as(i64, @intCast(last.text.len)));
        const nx = e.x();
        // When the last match took a line break (lines were joined) the
        // cursor stays where the join was, as in Vim (except under :g,
        // which leaves it at the first non-blank).
        const joined = std.mem.indexOfScalar(u8, last_text, '\n') != null and !vs.group_held;
        const pos = if (joined) nx.clampNormal(new_end) else nx.firstNonBlank(nx.lineOf(new_end));
        vs.cursors.clearRetainingCapacity();
        try vs.cursors.append(gpa, .{ .pos = pos, .want = nx.column(pos) });
        if (lines > report) return e.msg("{d} substitution{s} on {d} line{s}", .{ n, if (n == 1) "" else "s", lines, if (lines == 1) "" else "s" });
        return .ok;
    }

    fn compileFor(e: *Ex, pat: []const u8, case: ?bool) !zg_regex.Regex {
        const o = e.vs.sh().options;
        var d: pattern.Diag = .{};
        const flags: pattern.Flags = if (case) |ci| .{ .ignorecase = ci, .diag = &d } else .{ .ignorecase = o.ignorecase, .smartcase = o.smartcase, .diag = &d };
        return search_mod.Search.compile(e.vs.gpa, pat, flags) catch |err| switch (err) {
            error.Unsupported, error.Syntax => return e.fail("E486: {s}: {s}", .{ d.msg, pat[@min(d.start, pat.len)..@min(@max(d.end, d.start), pat.len)] }),
            error.OutOfMemory => return error.OutOfMemory,
            else => return e.fail("E486: invalid pattern: {s}", .{pat}),
        };
    }

    // -- :g, :d ---------------------------------------------------------------

    fn global(e: *Ex, range_in: Range, invert: bool, rest: []const u8) !ExResult {
        const vs = e.vs;
        const gpa = vs.gpa;
        if (rest.len == 0) return e.fail("E35: No previous regular expression", .{});
        const xx = e.x();
        const range: Range = if (range_in.given) range_in else .{ .l0 = 0, .l1 = xx.lineCount() - 1, .given = true };
        const delim = rest[0];
        var p: Parser = .{ .s = rest, .i = 1 };
        var pat: std.ArrayList(u8) = .empty;
        defer pat.deinit(gpa);
        _ = try p.until(gpa, delim, &pat);
        if (pat.items.len == 0) try pat.appendSlice(gpa, vs.sh().search.pattern.items);
        const cmd = std.mem.trim(u8, p.s[@min(p.i, p.s.len)..], " \t:");
        var cname = cmd;
        var reg_arg: []const u8 = "";
        if (std.mem.indexOfScalar(u8, cmd, ' ')) |sp| {
            cname = cmd[0..sp];
            reg_arg = std.mem.trim(u8, cmd[sp..], " ");
        }
        if (vs.group_held) return e.fail("E147: Cannot do :global recursive", .{});
        const pat_copy = try gpa.dupe(u8, pat.items);
        defer gpa.free(pat_copy);
        vs.setSearch(pat_copy, false) catch return error.ExFailed;
        var re = try compileFor(e, pat_copy, null);
        defer re.deinit(gpa);
        var cache = try re.newCache(gpa);
        defer cache.deinit();
        const in = find.treeInput(&e.host.doc.tree);
        var marked: std.ArrayList(u64) = .empty;
        defer marked.deinit(gpa);
        var l = range.l0;
        while (l <= range.l1) : (l += 1) {
            const hit = re.find(&cache, in.withSpan(.{ .start = xx.lineStart(l), .end = xx.lineEnd(l) })) != null;
            if (hit != invert) try marked.append(gpa, l);
        }
        if (marked.items.len == 0) {
            if (invert) return e.fail("Pattern found in every line: {s}", .{pat_copy});
            return e.fail("E486: Pattern not found: {s}", .{pat_copy});
        }
        // `:g/pat/d` deletes the marked lines in one pass; any other
        // command runs on each marked line in turn.
        if (cmd.len == 0 or !abbrev(cname, "delete", 1)) return e.eachLine(marked.items, .{ .ex = if (cmd.len == 0) "p" else cmd });
        try vs.beginChange(e.host);
        defer vs.commitChange(e.host) catch {};
        // Each line goes through the registers as Vim's :d does, top first.
        const reg_name: ?u8 = if (reg_arg.len > 0) reg_arg[0] else null;
        for (marked.items) |ml| try e.recordLines(xx, ml, ml, reg_name);
        // Runs of adjacent lines are deleted together (their spans would
        // overlap otherwise).
        var edits: std.ArrayList(cs_mod.Replace) = .empty;
        defer edits.deinit(gpa);
        var k: usize = 0;
        while (k < marked.items.len) {
            var j = k;
            while (j + 1 < marked.items.len and marked.items[j + 1] == marked.items[j] + 1) j += 1;
            const sp = ops.lineSpan(xx, marked.items[k], marked.items[j]);
            try edits.append(gpa, .{ .range = .{ .start = sp.start, .end = sp.end }, .text = "" });
            k = j + 1;
        }
        try ops.apply(e.host, edits.items);
        const n = marked.items.len;
        const nx = e.x();
        const target = @min(marked.items[n - 1] + 1 - n, nx.lineCount() - 1);
        const pos = nx.firstNonBlank(target);
        vs.cursors.clearRetainingCapacity();
        try vs.cursors.append(gpa, .{ .pos = pos, .want = nx.column(pos) });
        if (n > report) return e.msg("{d} fewer lines", .{n});
        return .ok;
    }

    const LineCmd = union(enum) { ex: []const u8, keys: []const mode_mod.Key };

    /// Runs `cmd` with the cursor at the start of each of `lines`, top
    /// first, as one undo step. Lines are marked first, as Vim does: a
    /// line deleted by an earlier command is skipped, and the rest follow
    /// the edits (mapped through the document's change log); a line joined
    /// onto the one above counts as deleted.
    fn eachLine(e: *Ex, lines: []const u64, cmd: LineCmd) !ExResult {
        const vs = e.vs;
        const gpa = vs.gpa;
        const doc = e.host.doc;
        const xx = e.x();
        // Each line's span [start, next line start). Spans not handled yet
        // are at `span + shift` in the current text: a command that only
        // changes text before them (the usual case: its own line) just
        // moves them all, so each line costs O(1) on top of its command.
        const spans = try gpa.alloc(Span, lines.len);
        defer gpa.free(spans);
        for (spans, lines) |*sp, l| sp.* = .{ .s = xx.lineStart(l), .e = xx.nextLineStart(l), .blank = xx.lineStart(l) == xx.nextLineStart(l) };
        var shift: i64 = 0;
        var ver = doc.version;
        try vs.beginChange(e.host);
        vs.group_held = true;
        defer {
            vs.group_held = false;
            vs.commitChange(e.host) catch {};
        }
        var err_buf: [160]u8 = undefined;
        var first_err: ?[]const u8 = null;
        var any_ok = false;
        var msg_buf: [160]u8 = undefined;
        var last_msg: ?[]const u8 = null;
        for (spans, 0..) |sp, k| {
            const s0: u64 = @intCast(@as(i64, @intCast(sp.s)) + shift);
            const e0: u64 = @intCast(@as(i64, @intCast(sp.e)) + shift);
            run: {
                if (s0 >= e0 and !sp.blank) break :run; // deleted
                // Joined onto the line above: no longer a line of its own.
                const now = e.x();
                const pos = @min(s0, doc.len());
                if (now.lineStart(now.lineOf(pos)) != pos) break :run;
                vs.cursors.clearRetainingCapacity();
                try vs.cursors.append(gpa, .{ .pos = pos, .want = 0 });
                switch (cmd) {
                    .ex => |c| switch (try runEx(vs, e.host, c)) {
                        .ok => any_ok = true,
                        .message => |m| {
                            any_ok = true;
                            const n = @min(m.len, msg_buf.len);
                            @memcpy(msg_buf[0..n], m[0..n]);
                            last_msg = msg_buf[0..n];
                        },
                        .err => |m| if (first_err == null) {
                            const n = @min(m.len, err_buf.len);
                            @memcpy(err_buf[0..n], m[0..n]);
                            first_err = err_buf[0..n];
                        },
                    },
                    .keys => |keys| {
                        try vs.runNormal(keys, e.host);
                        any_ok = true;
                    },
                }
            }
            // Bring the spans still to come up to date.
            if (doc.version == ver) continue;
            const entries = doc.change_log.since(ver) orelse return e.fail("E: the document changed too much during :global", .{});
            for (entries) |*en| {
                const cs = &en.changes;
                if (cs.replaces.len == 0 or k + 1 == spans.len) continue;
                const delta = @as(i64, @intCast(cs.newLen())) - @as(i64, @intCast(cs.base_len));
                const next: u64 = @intCast(@as(i64, @intCast(spans[k + 1].s)) + shift);
                if (cs.replaces[cs.replaces.len - 1].range.end <= next) {
                    shift += delta;
                    continue;
                }
                for (spans[k + 1 ..]) |*r| {
                    const rs: u64 = @intCast(@as(i64, @intCast(r.s)) + shift);
                    const re: u64 = @intCast(@as(i64, @intCast(r.e)) + shift);
                    r.s = cs.mapPos(rs, .right);
                    r.e = cs.mapPos(re, .left);
                }
                shift = 0;
            }
            ver = doc.version;
        }
        if (!any_ok) if (first_err) |m| return e.fail("{s}", .{m});
        if (last_msg) |m| return e.msg("{s}", .{m});
        return .ok;
    }

    /// A marked line; `blank` when it had no bytes (the empty last line).
    const Span = struct { s: u64, e: u64, blank: bool };

    // -- :normal ----------------------------------------------------------------

    fn normal(e: *Ex, range: Range, rest_in: []const u8) !ExResult {
        const gpa = e.vs.gpa;
        // `:normal!` (no mappings here anyway) and the separating blank.
        const rest = if (rest_in.len > 0 and rest_in[0] == '!') std.mem.trimStart(u8, rest_in[1..], " ") else rest_in;
        if (rest.len == 0) return e.fail("E471: Argument required", .{});
        var keys: std.ArrayList(mode_mod.Key) = .empty;
        defer keys.deinit(gpa);
        const view = std.unicode.Utf8View.init(rest) catch return e.fail("E: invalid UTF-8 in :normal", .{});
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| try keys.append(gpa, switch (cp) {
            0x1b => .named(.esc),
            '\r', '\n' => .named(.enter),
            '\t' => .named(.tab),
            0x01...0x08, 0x0b, 0x0c, 0x0e...0x1a => .ctrlOf(cp + 'a' - 1),
            else => .char(cp),
        });
        if (!range.given) {
            if (e.vs.group_held) {
                try e.vs.runNormal(keys.items, e.host);
                return .ok;
            }
            try e.vs.beginChange(e.host);
            e.vs.group_held = true;
            defer {
                e.vs.group_held = false;
                e.vs.commitChange(e.host) catch {};
            }
            try e.vs.runNormal(keys.items, e.host);
            return .ok;
        }
        const lines = try gpa.alloc(u64, range.l1 - range.l0 + 1);
        defer gpa.free(lines);
        for (lines, 0..) |*l, i| l.* = range.l0 + i;
        return e.eachLine(lines, .{ .keys = keys.items });
    }

    fn recordLines(e: *Ex, xx: Text, l0: u64, l1: u64, name: ?u8) !void {
        const gpa = e.vs.gpa;
        var r: ops.Register = .{ .kind = .linewise };
        defer r.deinit(gpa);
        var piece: std.ArrayList(u8) = .empty;
        defer piece.deinit(gpa);
        try ops.yankLines(xx, l0, l1, &piece, gpa);
        try r.prepend(gpa, piece.items);
        try e.vs.sh().regs.record(name, .delete, &r, false);
    }

    fn deleteLines(e: *Ex, l0: u64, l1: u64, rest: []const u8) !ExResult {
        const vs = e.vs;
        const xx = e.x();
        const name: ?u8 = if (rest.len > 0) rest[0] else null;
        try vs.beginChange(e.host);
        defer vs.commitChange(e.host) catch {};
        try e.recordLines(xx, l0, l1, name);
        const sp = ops.lineSpan(xx, l0, l1);
        try ops.replace(e.host, sp.start, sp.end, "");
        const nx = e.x();
        const pos = nx.firstNonBlank(@min(l0, nx.lineCount() - 1));
        vs.cursors.clearRetainingCapacity();
        try vs.cursors.append(vs.gpa, .{ .pos = pos, .want = nx.column(pos) });
        const n = l1 - l0 + 1;
        if (n > report) return e.msg("{d} fewer lines", .{n});
        return .ok;
    }

    // -- :set -------------------------------------------------------------------

    fn set(e: *Ex, rest: []const u8) !ExResult {
        const o = &e.vs.sh().options;
        var it = std.mem.tokenizeScalar(u8, rest, ' ');
        var shown: ?ExResult = null;
        while (it.next()) |arg| {
            var name = arg;
            var op: enum { on, off, toggle, show } = .on;
            if (std.mem.endsWith(u8, name, "?")) {
                op = .show;
                name = name[0 .. name.len - 1];
            } else if (std.mem.endsWith(u8, name, "!")) {
                op = .toggle;
                name = name[0 .. name.len - 1];
            } else if (std.mem.startsWith(u8, name, "inv")) {
                op = .toggle;
                name = name[3..];
            } else if (std.mem.startsWith(u8, name, "no") and optionPtr(o, name[2..]) != null) {
                op = .off;
                name = name[2..];
            }
            if (std.mem.indexOfScalar(u8, name, '=') != null) return e.fail("E518: Unknown option: {s}", .{arg});
            const ptr = optionPtr(o, name) orelse return e.fail("E518: Unknown option: {s}", .{arg});
            switch (op) {
                .on => ptr.value.* = true,
                .off => ptr.value.* = false,
                .toggle => ptr.value.* = !ptr.value.*,
                .show => shown = e.msg("  {s}{s}", .{ if (ptr.value.*) "" else "no", ptr.full }),
            }
        }
        return shown orelse .ok;
    }
};

const OptionRef = struct { value: *bool, full: []const u8 };

fn optionPtr(o: *state_mod.Options, name: []const u8) ?OptionRef {
    const table = [_]struct { []const u8, []const u8 }{
        .{ "number", "nu" },
        .{ "relativenumber", "rnu" },
        .{ "wrap", "wrap" },
        .{ "ignorecase", "ic" },
        .{ "smartcase", "scs" },
    };
    for (table) |t| {
        if (!std.mem.eql(u8, name, t[0]) and !std.mem.eql(u8, name, t[1])) continue;
        const v: *bool = if (std.mem.eql(u8, t[0], "number")) &o.number else if (std.mem.eql(u8, t[0], "relativenumber")) &o.relativenumber else if (std.mem.eql(u8, t[0], "wrap")) &o.wrap else if (std.mem.eql(u8, t[0], "ignorecase")) &o.ignorecase else &o.smartcase;
        return .{ .value = v, .full = t[0] };
    }
    return null;
}

/// Whether `name` abbreviates `full` with at least `min` characters.
fn abbrev(name: []const u8, full: []const u8, min: usize) bool {
    return name.len >= min and name.len <= full.len and std.mem.eql(u8, name, full[0..name.len]);
}

fn nonEmpty(s: []const u8) ?[]const u8 {
    return if (s.len == 0) null else s;
}
