//! LSP glob patterns (LSP 3.17 `Pattern`), used by document selectors,
//! the watched-files bridge, file-operation filters and the server
//! registry.
//!
//! Syntax: `*` matches zero or more characters inside one path segment,
//! `?` one character inside a segment, `**` zero or more whole segments,
//! `{a,b}` alternatives (nesting allowed), `[a-z]` a range and `[!a-z]` (or
//! `[^a-z]`) a negated range. `/` is the only separator; callers normalize
//! `\` before matching.
//!
//! The pattern is compiled into a small Thompson NFA. Braces become
//! alternation nodes instead of being expanded, so `{a,b}/{c,d}/{e,f}`
//! stays linear in size. `match` simulates the NFA with two bit sets on
//! the stack: O(path * states), no backtracking and no allocation.
//!
//! Edge cases (following VS Code): an empty pattern matches nothing; a
//! trailing `/` restricts the pattern to directories and is accepted with
//! or without the trailing separator in the path; `**` that is not a whole
//! segment (`a**b`) behaves like `*`; an unmatched `[` or `{` is literal.
//! Case-insensitive matching folds ASCII only; Unicode case folding is out
//! of scope.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// Compile options.
pub const GlobOptions = struct {
    /// Fold ASCII case. Defaults to true on Windows, whose file systems are
    /// case-insensitive.
    case_insensitive: bool = (builtin.os.tag == .windows),
};

/// Maximum number of NFA states; longer patterns are `InvalidGlob`.
pub const max_states = 1024;
/// Maximum brace nesting depth.
pub const max_depth = 32;

const Op = enum(u8) {
    /// Consume `arg` (case-folded when the glob is case-insensitive).
    char,
    /// Consume one character other than `/`.
    any,
    /// Consume one character other than `/` that is in class `arg`.
    class,
    /// Consume a character other than `/` and stay; or move on (epsilon).
    star,
    /// Consume any character and stay; or move on (epsilon).
    any_loop,
    /// Epsilon to `x` and to `y`.
    split,
    /// Epsilon to `x`.
    jmp,
    /// Accept.
    match,
};

const Inst = struct {
    op: Op,
    arg: u16 = 0,
    x: u16 = 0,
    y: u16 = 0,
};

const ByteSet = [4]u64;

fn setHas(s: *const ByteSet, c: u8) bool {
    return (s[c >> 6] >> @intCast(c & 63)) & 1 != 0;
}

fn setAdd(s: *ByteSet, c: u8) void {
    s[c >> 6] |= @as(u64, 1) << @intCast(c & 63);
}

/// A compiled glob pattern.
pub const Glob = struct {
    insts: []const Inst,
    classes: []const ByteSet,
    case_insensitive: bool,
    dir_only: bool,
    /// Bit-parallel tables, present when the NFA has at most 64 states.
    small: ?*const Small = null,
    /// The pattern was `**/<p>` with no `/` in `<p>`: only the last path
    /// segment is matched (against `<p>`).
    basename_only: bool = false,

    /// Compiles `pattern`. Fails with `InvalidGlob` when the pattern needs
    /// more than `max_states` states or nests braces deeper than
    /// `max_depth`.
    pub fn compile(gpa: Allocator, pattern: []const u8, opts: GlobOptions) error{ OutOfMemory, InvalidGlob }!Glob {
        var c: Compiler = .{ .gpa = gpa, .src = pattern, .ci = opts.case_insensitive };
        defer c.insts.deinit(gpa);
        defer c.classes.deinit(gpa);
        var src = pattern;
        var dir_only = false;
        if (src.len > 1 and src[src.len - 1] == '/') {
            src = src[0 .. src.len - 1];
            dir_only = true;
        }
        // `**/<segment pattern>` only ever matches the last segment.
        var basename_only = false;
        if (src.len > 3 and std.mem.startsWith(u8, src, "**/") and
            std.mem.indexOfScalar(u8, src[3..], '/') == null and std.mem.indexOf(u8, src[3..], "**") == null)
        {
            src = src[3..];
            basename_only = true;
        }
        c.src = src;
        if (src.len == 0) {
            // Matches nothing: no accepting state is reachable.
            try c.emit(.{ .op = .char, .arg = 0x100 });
        } else {
            try c.sequence(0, src.len, 0);
        }
        try c.emit(.{ .op = .match });
        const insts = try c.insts.toOwnedSlice(gpa);
        errdefer gpa.free(insts);
        const classes = try c.classes.toOwnedSlice(gpa);
        errdefer gpa.free(classes);
        var g: Glob = .{
            .insts = insts,
            .classes = classes,
            .case_insensitive = opts.case_insensitive,
            .dir_only = dir_only,
            .basename_only = basename_only,
        };
        if (insts.len <= 64) {
            const sm = try gpa.create(Small);
            sm.build(&g);
            g.small = sm;
        }
        return g;
    }

    /// Frees the compiled pattern.
    pub fn deinit(g: *Glob, gpa: Allocator) void {
        gpa.free(g.insts);
        gpa.free(g.classes);
        if (g.small) |sm| gpa.destroy(sm);
        g.* = undefined;
    }

    /// Returns whether `path` (with `/` separators) matches. Never
    /// allocates.
    pub fn match(g: *const Glob, path_in: []const u8) bool {
        var path = path_in;
        if (g.dir_only and path.len > 1 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
        if (g.basename_only) {
            if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path = path[i + 1 ..];
        }
        if (g.small) |sm| return sm.match(path);
        const n = g.insts.len;
        const words = (n + 63) / 64;
        var cur_bits: [max_states / 64]u64 = undefined;
        var next_bits: [max_states / 64]u64 = undefined;
        var cur_list: [max_states]u16 = undefined;
        var next_list: [max_states]u16 = undefined;
        var stack: [max_states]u16 = undefined;
        @memset(cur_bits[0..words], 0);
        var cur_len = g.addClosure(0, cur_bits[0..words], &cur_list, 0, &stack);
        for (path) |raw| {
            if (cur_len == 0) return false;
            const ch = if (g.case_insensitive) std.ascii.toLower(raw) else raw;
            @memset(next_bits[0..words], 0);
            var next_len: usize = 0;
            for (cur_list[0..cur_len]) |pc| {
                const in = g.insts[pc];
                const target: ?u16 = switch (in.op) {
                    .char => if (in.arg == ch) pc + 1 else null,
                    .any => if (ch != '/') pc + 1 else null,
                    .class => if (ch != '/' and setHas(&g.classes[in.arg], ch)) pc + 1 else null,
                    .star => if (ch != '/') pc else null,
                    .any_loop => pc,
                    .split, .jmp, .match => null,
                };
                if (target) |t| next_len = g.addClosure(t, next_bits[0..words], &next_list, next_len, &stack);
            }
            @memcpy(cur_bits[0..words], next_bits[0..words]);
            @memcpy(cur_list[0..next_len], next_list[0..next_len]);
            cur_len = next_len;
        }
        for (cur_list[0..cur_len]) |pc| if (g.insts[pc].op == .match) return true;
        return false;
    }

    /// Adds `start` and its epsilon closure to the state list.
    fn addClosure(g: *const Glob, start: u16, bits: []u64, list: *[max_states]u16, len_in: usize, stack: *[max_states]u16) usize {
        var len = len_in;
        var sp: usize = 0;
        stack[0] = start;
        sp = 1;
        while (sp > 0) {
            sp -= 1;
            const pc = stack[sp];
            const w = pc >> 6;
            const bit = @as(u64, 1) << @intCast(pc & 63);
            if (bits[w] & bit != 0) continue;
            bits[w] |= bit;
            const in = g.insts[pc];
            switch (in.op) {
                .split => {
                    stack[sp] = in.y;
                    stack[sp + 1] = in.x;
                    sp += 2;
                },
                .jmp => {
                    stack[sp] = in.x;
                    sp += 1;
                },
                .star, .any_loop => {
                    list[len] = pc;
                    len += 1;
                    stack[sp] = pc + 1;
                    sp += 1;
                },
                else => {
                    list[len] = pc;
                    len += 1;
                },
            }
        }
        return len;
    }
};

/// Bit-parallel simulation for NFAs of at most 64 states: bit `i` of a
/// state set is instruction `i`. Case folding is baked into `accept`.
const Small = struct {
    /// States that consume byte `c`.
    accept: [256]u64,
    /// `star` and `any_loop` states, which stay put after consuming.
    loop: u64,
    /// Epsilon closure of each state, restricted to consuming and match
    /// states.
    closure: [64]u64,
    /// Accepting states.
    final: u64,

    fn build(sm: *Small, g: *const Glob) void {
        @memset(&sm.accept, 0);
        sm.loop = 0;
        sm.final = 0;
        for (g.insts, 0..) |in, i| {
            const bit = @as(u64, 1) << @intCast(i);
            switch (in.op) {
                .char => if (in.arg < 256) {
                    const ch: u8 = @intCast(in.arg);
                    sm.accept[ch] |= bit;
                    if (g.case_insensitive) sm.accept[std.ascii.toUpper(ch)] |= bit;
                },
                .any, .star => {
                    for (0..256) |ch| if (ch != '/') {
                        sm.accept[ch] |= bit;
                    };
                    if (in.op == .star) sm.loop |= bit;
                },
                .class => for (0..256) |ch| {
                    const folded = if (g.case_insensitive) std.ascii.toLower(@intCast(ch)) else @as(u8, @intCast(ch));
                    if (ch != '/' and setHas(&g.classes[in.arg], folded)) sm.accept[ch] |= bit;
                },
                .any_loop => {
                    for (&sm.accept) |*a| a.* |= bit;
                    sm.loop |= bit;
                },
                .match => sm.final |= bit,
                .split, .jmp => {},
            }
        }
        var stack: [max_states]u16 = undefined;
        var bits: [max_states / 64]u64 = undefined;
        var list: [max_states]u16 = undefined;
        for (0..g.insts.len) |i| {
            bits[0] = 0;
            const len = g.addClosure(@intCast(i), bits[0..1], &list, 0, &stack);
            var mask: u64 = 0;
            for (list[0..len]) |s| mask |= @as(u64, 1) << @intCast(s);
            sm.closure[i] = mask;
        }
    }

    fn match(sm: *const Small, path: []const u8) bool {
        var cur = sm.closure[0];
        for (path) |ch| {
            const m = cur & sm.accept[ch];
            var t = ((m & ~sm.loop) << 1) | (m & sm.loop);
            if (t == 0) return false;
            var next: u64 = 0;
            while (t != 0) : (t &= t - 1) next |= sm.closure[@ctz(t)];
            cur = next;
        }
        return cur & sm.final != 0;
    }
};

const Compiler = struct {
    gpa: Allocator,
    src: []const u8,
    ci: bool,
    insts: std.ArrayList(Inst) = .empty,
    classes: std.ArrayList(ByteSet) = .empty,

    fn emit(c: *Compiler, in: Inst) error{ OutOfMemory, InvalidGlob }!void {
        if (c.insts.items.len >= max_states) return error.InvalidGlob;
        try c.insts.append(c.gpa, in);
    }

    fn pc(c: *const Compiler) u16 {
        return @intCast(c.insts.items.len);
    }

    fn fold(c: *const Compiler, ch: u8) u8 {
        return if (c.ci) std.ascii.toLower(ch) else ch;
    }

    /// Whether position `i` starts a segment: the pattern start, after `/`,
    /// or at the start of a brace alternative that itself starts a segment.
    fn atSegmentStart(c: *const Compiler, i: usize) bool {
        var j = i;
        while (j > 0) {
            switch (c.src[j - 1]) {
                '/' => return true,
                '{', ',' => j -= 1,
                else => return false,
            }
        }
        return true;
    }

    /// Whether position `i` ends a segment: the pattern end, before `/`, or
    /// at the end of a brace alternative.
    fn atSegmentEnd(c: *const Compiler, i: usize) bool {
        if (i >= c.src.len) return true;
        return switch (c.src[i]) {
            '/', ',', '}' => true,
            else => false,
        };
    }

    /// Returns the index of the `}` that closes the brace at `open`, or
    /// null when it is unmatched (then the `{` is literal).
    fn findClose(c: *const Compiler, open: usize, end: usize) ?usize {
        var depth: usize = 0;
        var i = open;
        while (i < end) : (i += 1) {
            switch (c.src[i]) {
                '[' => if (c.classEnd(i, end)) |e| {
                    i = e;
                },
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) return i;
                },
                else => {},
            }
        }
        return null;
    }

    /// Returns the index of the `]` closing a class at `open`, or null.
    fn classEnd(c: *const Compiler, open: usize, end: usize) ?usize {
        var i = open + 1;
        if (i < end and (c.src[i] == '!' or c.src[i] == '^')) i += 1;
        // A `]` right after the opening is a literal member.
        if (i < end and c.src[i] == ']') i += 1;
        while (i < end) : (i += 1) {
            if (c.src[i] == ']') return i;
            if (c.src[i] == '/') return null;
        }
        return null;
    }

    /// Compiles `src[start..end]`.
    fn sequence(c: *Compiler, start: usize, end: usize, depth: usize) error{ OutOfMemory, InvalidGlob }!void {
        var i = start;
        while (i < end) {
            const ch = c.src[i];
            switch (ch) {
                '*' => {
                    var j = i;
                    while (j < end and c.src[j] == '*') j += 1;
                    const globstar = j - i >= 2 and c.atSegmentStart(i) and c.atSegmentEnd(j);
                    if (!globstar) {
                        try c.emit(.{ .op = .star });
                        i = j;
                        continue;
                    }
                    if (j < end and c.src[j] == '/') {
                        // `**/`: zero segments, or anything ending in `/`.
                        const split = c.pc();
                        try c.emit(.{ .op = .split });
                        const body = c.pc();
                        try c.emit(.{ .op = .any_loop });
                        try c.emit(.{ .op = .char, .arg = '/' });
                        c.insts.items[split].x = body;
                        c.insts.items[split].y = c.pc();
                        i = j + 1;
                    } else {
                        // `**` at the end of the pattern or an alternative.
                        try c.emit(.{ .op = .any_loop });
                        i = j;
                    }
                },
                '?' => {
                    try c.emit(.{ .op = .any });
                    i += 1;
                },
                '[' => {
                    const close = c.classEnd(i, end) orelse {
                        try c.emit(.{ .op = .char, .arg = c.fold('[') });
                        i += 1;
                        continue;
                    };
                    try c.class(i, close);
                    i = close + 1;
                },
                '{' => {
                    const close = c.findClose(i, end) orelse {
                        try c.emit(.{ .op = .char, .arg = c.fold('{') });
                        i += 1;
                        continue;
                    };
                    try c.alternation(i + 1, close, depth + 1);
                    i = close + 1;
                },
                '/' => {
                    // `/**` at the very end also matches the bare prefix.
                    if (end == c.src.len and i + 3 == end and std.mem.eql(u8, c.src[i + 1 .. end], "**") and i > start) {
                        const split = c.pc();
                        try c.emit(.{ .op = .split });
                        const body = c.pc();
                        try c.emit(.{ .op = .char, .arg = '/' });
                        try c.emit(.{ .op = .any_loop });
                        c.insts.items[split].x = body;
                        c.insts.items[split].y = c.pc();
                        i = end;
                        continue;
                    }
                    try c.emit(.{ .op = .char, .arg = '/' });
                    i += 1;
                },
                else => {
                    try c.emit(.{ .op = .char, .arg = c.fold(ch) });
                    i += 1;
                },
            }
        }
    }

    /// Compiles the alternatives in `src[start..end]` (between braces).
    /// Pending `jmp`s to the join point are chained through their `x`.
    fn alternation(c: *Compiler, start: usize, end: usize, depth: usize) error{ OutOfMemory, InvalidGlob }!void {
        if (depth > max_depth) return error.InvalidGlob;
        const none = std.math.maxInt(u16);
        var chain: u16 = none;
        var alt_start = start;
        while (true) {
            const alt_end = c.nextComma(alt_start, end);
            if (alt_end == end) {
                try c.sequence(alt_start, alt_end, depth);
                break;
            }
            const split = c.pc();
            try c.emit(.{ .op = .split });
            c.insts.items[split].x = c.pc();
            try c.sequence(alt_start, alt_end, depth);
            const j = c.pc();
            try c.emit(.{ .op = .jmp, .x = chain });
            chain = j;
            c.insts.items[split].y = c.pc();
            alt_start = alt_end + 1;
        }
        const join = c.pc();
        while (chain != none) {
            const prev = c.insts.items[chain].x;
            c.insts.items[chain].x = join;
            chain = prev;
        }
    }

    /// Returns the index of the next top-level `,` in `src[i..end]`, or
    /// `end`.
    fn nextComma(c: *const Compiler, start: usize, end: usize) usize {
        var i = start;
        while (i < end) : (i += 1) {
            switch (c.src[i]) {
                ',' => return i,
                '[' => if (c.classEnd(i, end)) |e| {
                    i = e;
                },
                '{' => if (c.findClose(i, end)) |e| {
                    i = e;
                },
                else => {},
            }
        }
        return end;
    }

    /// Compiles the class `src[open..close]` (inclusive brackets).
    fn class(c: *Compiler, open: usize, close: usize) error{ OutOfMemory, InvalidGlob }!void {
        var set: ByteSet = .{ 0, 0, 0, 0 };
        var i = open + 1;
        var negate = false;
        if (c.src[i] == '!' or c.src[i] == '^') {
            negate = true;
            i += 1;
        }
        while (i < close) {
            const lo = c.src[i];
            if (i + 2 < close and c.src[i + 1] == '-') {
                const hi = c.src[i + 2];
                if (lo <= hi) {
                    var x: u16 = lo;
                    while (x <= hi) : (x += 1) c.addMember(&set, @intCast(x));
                }
                i += 3;
            } else {
                c.addMember(&set, lo);
                i += 1;
            }
        }
        if (negate) {
            for (&set) |*w| w.* = ~w.*;
        }
        if (c.classes.items.len >= std.math.maxInt(u16)) return error.InvalidGlob;
        try c.classes.append(c.gpa, set);
        try c.emit(.{ .op = .class, .arg = @intCast(c.classes.items.len - 1) });
    }

    fn addMember(c: *const Compiler, set: *ByteSet, ch: u8) void {
        if (c.ci) {
            setAdd(set, std.ascii.toLower(ch));
            setAdd(set, std.ascii.toUpper(ch));
        } else setAdd(set, ch);
    }
};
