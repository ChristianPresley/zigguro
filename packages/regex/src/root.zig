//! zg_regex: linear-time regular expressions in RE2/Rust syntax (E05.F03).
//!
//! Patterns are parsed to an AST, translated to HIR, compiled to Thompson
//! NFAs over bytes (forward with captures, and reverse) and run by a meta
//! engine: literal prefilters, a lazy DFA forward for the match end and in
//! reverse for the start, and a PikeVM for captures and as the universal
//! fallback. Search time is O(m·n) for every pattern; backreferences and
//! look-around are rejected at parse time.
//!
//! ```zig
//! var re = try zg_regex.Regex.compile(gpa, "(?i)fo+", .{});
//! defer re.deinit(gpa);
//! var cache = try re.newCache(gpa);
//! defer cache.deinit();
//! if (re.find(&cache, .fromSlice("say FOO"))) |m| _ = m; // 4..7
//! ```
//!
//! A `Regex` is immutable and may be shared between threads; each thread
//! uses its own `Cache`.

const std = @import("std");

/// Syntax: AST, parser, errors, HIR.
pub const syntax = @import("syntax.zig");
/// The NFA compiler and literal extraction.
pub const nfa = @import("nfa.zig");
/// The engines.
pub const engine = @import("engine.zig");
/// Prefilters.
pub const prefilter = @import("prefilter.zig");
const input_mod = @import("input.zig");
const meta = engine.meta;
const pikevm = engine.pikevm;

const Allocator = std.mem.Allocator;

/// The haystack and search parameters.
pub const Input = input_mod.Input;
/// A chunk source for `Input.fromChunks`.
pub const ChunkSource = input_mod.ChunkSource;
/// One chunk of a chunk source.
pub const Chunk = input_mod.Chunk;
/// A byte range.
pub const Range = input_mod.Range;
/// A `ChunkSource` over a list of slices.
pub const SliceChunks = input_mod.SliceChunks;
/// A match span.
pub const Match = meta.Match;
/// A syntax error with its span.
pub const Error = syntax.errors.Error;
/// Every syntax error kind.
pub const ErrorKind = syntax.errors.ErrorKind;
/// Human text for an error.
pub const errorMessage = syntax.errors.errorMessage;

/// Compilation options. The flag fields set the initial inline flags.
pub const Options = struct {
    case_insensitive: bool = false,
    multi_line: bool = false,
    dot_all: bool = false,
    crlf: bool = false,
    swap_greed: bool = false,
    unicode: bool = true,
    ignore_whitespace: bool = false,
    /// Match the pattern text literally (every character escaped).
    literal: bool = false,
    /// Only match whole words: wraps the pattern in `\b{start-half}` and
    /// `\b{end-half}`.
    whole_word: bool = false,
    /// Fail with `error.SizeLimitExceeded` above this compiled size.
    size_limit: usize = 10 << 20,
    /// Lazy DFA cache budget per regex per thread (forward and reverse each).
    dfa_cache_bytes: usize = 2 << 20,
    nest_limit: u32 = 250,
    /// Receives the error span and kind on `error.Syntax`.
    diag: ?*Error = null,
};

/// Compilation errors. `error.Syntax` details go to `Options.diag`.
pub const CompileError = error{ Syntax, SizeLimitExceeded } || Allocator.Error;

/// Per-thread mutable scratch for searches.
pub const Cache = meta.Cache;

/// Capture positions of one match.
pub const Captures = struct {
    slots: []u64,

    /// Number of groups (group 0 is the whole match).
    pub fn len(c: *const Captures) usize {
        return c.slots.len / 2;
    }

    /// Group `i`'s span, or null when it did not participate.
    pub fn get(c: *const Captures, i: usize) ?Match {
        const s = c.slots[2 * i];
        const e = c.slots[2 * i + 1];
        if (s == pikevm.none or e == pikevm.none) return null;
        return .{ .start = s, .end = e };
    }

    /// Frees the slots.
    pub fn deinit(c: *Captures, gpa: Allocator) void {
        gpa.free(c.slots);
    }
};

/// A compiled regular expression.
pub const Regex = struct {
    engines: meta.Engines,
    names: []const ?[]const u8,
    names_storage: [][]u8,
    unicode: bool,

    /// Compiles `pattern`.
    pub fn compile(gpa: Allocator, pattern: []const u8, o: Options) CompileError!Regex {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const h = try buildHir(arena, pattern, o);

        // Group names in index order.
        var names: std.ArrayList(?[]const u8) = .empty;
        try names.append(arena, null);
        collectNames(h.hir, &names, arena) catch return error.OutOfMemory;

        var fwd = nfa.compile.compile(gpa, &.{h.hir}, names.items, .{ .size_limit = o.size_limit }) catch |e| return mapCompileErr(e, o);
        errdefer fwd.deinit();
        var rev = nfa.compile.compile(gpa, &.{h.hir}, &.{null}, .{ .reverse = true, .size_limit = o.size_limit }) catch |e| return mapCompileErr(e, o);
        errdefer rev.deinit();

        // Prefilter and pure-literal detection.
        var pf: ?prefilter.Prefilter = null;
        if (try nfa.literal_extract.prefilterLiterals(arena, try nfa.literal_extract.prefixes(arena, h.hir))) |lits| {
            pf = try prefilter.Prefilter.init(gpa, lits);
        }
        errdefer if (pf) |*p| p.deinit(gpa);
        const lit_bytes: []const u8 = switch (h.hir.*) {
            .literal => |b| b,
            else => "",
        };
        const owned_lit = try gpa.dupe(u8, lit_bytes);
        errdefer gpa.free(owned_lit);

        // Owned names.
        const storage = try gpa.alloc([]u8, names.items.len);
        var filled: usize = 0;
        errdefer {
            for (storage[0..filled]) |s| gpa.free(s);
            gpa.free(storage);
        }
        const out_names = try gpa.alloc(?[]const u8, names.items.len);
        errdefer gpa.free(out_names);
        for (names.items, 0..) |n, i| {
            storage[i] = try gpa.dupe(u8, n orelse "");
            filled += 1;
            out_names[i] = if (n != null) storage[i] else null;
        }

        var re: Regex = .{
            .engines = .{
                .fwd = fwd,
                .rev = rev,
                .prefilter = pf,
                .literal = null,
                .literal_bytes = owned_lit,
                .dfa_cache_bytes = o.dfa_cache_bytes,
            },
            .names = out_names,
            .names_storage = storage,
            .unicode = o.unicode,
        };
        if (owned_lit.len > 0) re.engines.literal = .init(owned_lit);
        return re;
    }

    /// Frees the regex.
    pub fn deinit(re: *Regex, gpa: Allocator) void {
        re.engines.deinit(gpa);
        for (re.names_storage) |s| gpa.free(s);
        gpa.free(re.names_storage);
        gpa.free(re.names);
    }

    /// Fixes the literal finder's pointer after the value moved (the finder
    /// borrows `literal_bytes`, which is heap-allocated, so moves are safe;
    /// kept for clarity of ownership).
    fn literalOk(re: *const Regex) bool {
        return re.engines.literal == null or re.engines.literal.?.needle.ptr == re.engines.literal_bytes.ptr;
    }

    /// Creates per-thread scratch for this regex.
    pub fn newCache(re: *const Regex, gpa: Allocator) Allocator.Error!Cache {
        _ = re;
        return .{ .gpa = gpa };
    }

    /// Allocates a `Captures` sized for this regex.
    pub fn newCaptures(re: *const Regex, gpa: Allocator) Allocator.Error!Captures {
        const s = try gpa.alloc(u64, re.names.len * 2);
        @memset(s, pikevm.none);
        return .{ .slots = s };
    }

    /// Whether the regex matches anywhere in the input span.
    pub fn isMatch(re: *const Regex, cache: *Cache, input: Input) bool {
        std.debug.assert(re.literalOk());
        return meta.isMatch(&re.engines, cache, &input);
    }

    /// The leftmost-first match in the input span.
    pub fn find(re: *const Regex, cache: *Cache, input: Input) ?Match {
        return meta.find(&re.engines, cache, &input);
    }

    /// The leftmost-first match with its capture groups.
    pub fn captures(re: *const Regex, cache: *Cache, input: Input, out: *Captures) bool {
        std.debug.assert(out.slots.len == re.names.len * 2);
        return meta.captures(&re.engines, cache, &input, out.slots);
    }

    /// Iterates non-overlapping matches. An empty match immediately after
    /// the previous match is skipped, and in Unicode mode empty matches
    /// never split a UTF-8 sequence (as in Rust `regex`).
    pub fn findIter(re: *const Regex, cache: *Cache, input: Input) FindIter {
        return .{ .re = re, .cache = cache, .input = input, .at = input.span.start };
    }

    /// Capture group names; index 0 (the whole match) is always null.
    pub fn captureNames(re: *const Regex) []const ?[]const u8 {
        return re.names;
    }

    /// Number of capture groups including group 0.
    pub fn groupCount(re: *const Regex) usize {
        return re.names.len;
    }
};

/// Iterator over non-overlapping matches.
pub const FindIter = struct {
    re: *const Regex,
    cache: *Cache,
    input: Input,
    at: u64,
    last_end: ?u64 = null,

    /// The next match, or null.
    pub fn next(it: *FindIter) ?Match {
        while (it.at <= it.input.span.end) {
            const sub = it.input.withSpan(.{ .start = it.at, .end = it.input.span.end });
            const m = it.re.find(it.cache, sub) orelse {
                it.at = it.input.span.end + 1;
                return null;
            };
            if (m.start == m.end) {
                const skip = (it.last_end != null and it.last_end.? == m.end) or
                    (it.re.unicode and m.end < it.input.total_len and m.end > 0 and isContinuation(it.input.byteAt(m.end)));
                if (skip) {
                    it.at = m.end + 1;
                    continue;
                }
                it.at = m.end + 1;
            } else {
                it.at = m.end;
            }
            it.last_end = m.end;
            return m;
        }
        return null;
    }
};

fn isContinuation(b: u8) bool {
    return b & 0xC0 == 0x80;
}

const BuiltHir = struct { hir: *const syntax.hir.Hir };

fn buildHir(arena: Allocator, pattern_in: []const u8, o: Options) CompileError!BuiltHir {
    var pattern = pattern_in;
    if (o.literal) {
        var out: std.ArrayList(u8) = .empty;
        try syntax.parse.escape(&out, arena, pattern_in);
        pattern = out.items;
    }
    if (o.whole_word) pattern = try std.mem.concat(arena, u8, &.{ "\\b{start-half}(?:", pattern, ")\\b{end-half}" });
    const a = switch (try syntax.parse.parse(arena, pattern, .{ .ignore_whitespace = o.ignore_whitespace, .nest_limit = o.nest_limit })) {
        .ok => |x| x,
        .err => |e| {
            if (o.diag) |d| d.* = adjustSpan(e, o, pattern_in);
            return error.Syntax;
        },
    };
    const flags: syntax.ast.Flags = .{
        .case_insensitive = o.case_insensitive,
        .multi_line = o.multi_line,
        .dot_all = o.dot_all,
        .crlf = o.crlf,
        .swap_greed = o.swap_greed,
        .unicode = o.unicode,
        .ignore_whitespace = o.ignore_whitespace,
    };
    const h = switch (try syntax.translate.translate(arena, a, flags)) {
        .ok => |x| x,
        .err => |e| {
            if (o.diag) |d| d.* = adjustSpan(e, o, pattern_in);
            return error.Syntax;
        },
    };
    return .{ .hir = h };
}

/// Maps a span in the wrapped pattern (whole-word prefix) back to the user's
/// pattern.
fn adjustSpan(e: Error, o: Options, pattern: []const u8) Error {
    if (!o.whole_word or o.literal) return e;
    const off: u32 = "\\b{start-half}(?:".len;
    var r = e;
    const clamp = struct {
        fn f(v: u32, off2: u32, len: usize) u32 {
            return @intCast(@min(v -| off2, len));
        }
    }.f;
    r.span = .{ .start = clamp(e.span.start, off, pattern.len), .end = clamp(e.span.end, off, pattern.len) };
    return r;
}

fn mapCompileErr(e: nfa.compile.Error, o: Options) CompileError {
    return switch (e) {
        error.SizeLimitExceeded => {
            if (o.diag) |d| d.* = .{ .kind = .size_limit_exceeded, .span = .{ .start = 0, .end = 0 } };
            return error.SizeLimitExceeded;
        },
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn collectNames(h: *const syntax.hir.Hir, names: *std.ArrayList(?[]const u8), arena: Allocator) Allocator.Error!void {
    switch (h.*) {
        .capture => |c| {
            while (names.items.len <= c.index) try names.append(arena, null);
            names.items[c.index] = c.name;
            try collectNames(c.sub, names, arena);
        },
        .repetition => |r| try collectNames(r.sub, names, arena),
        .concat, .alternation => |items| for (items) |it| try collectNames(it, names, arena),
        else => {},
    }
}

/// SIMD byte and substring search, shared with the text buffer (E05) and
/// the workspace scanner (E08).
pub const simd = struct {
    /// First index of `b` in `hay[from..]`.
    pub fn memchr(hay: []const u8, b: u8, from: usize) ?usize {
        return prefilter.memchr.memchr(b, hay, from);
    }
    /// Last index of `b` in `hay[0..to]`.
    pub fn memrchr(hay: []const u8, b: u8, to: usize) ?usize {
        return prefilter.memchr.memrchr(b, hay, to);
    }
    /// A reusable substring finder.
    pub const Memmem = prefilter.memmem.Finder;
};

/// Appends `literal` with every meta character escaped.
pub const escape = syntax.parse.escape;

/// Smart case: true when `pattern` has no uppercase letter outside escapes,
/// i.e. the search should be case-insensitive.
pub fn smartCaseInsensitive(pattern: []const u8) bool {
    var i: usize = 0;
    while (i < pattern.len) : (i += 1) {
        const c = pattern[i];
        if (c == '\\') {
            i += 1; // skip the escaped character (\D, \W, \P{..} are not letters)
            if (i < pattern.len and (pattern[i] == 'p' or pattern[i] == 'P') and i + 1 < pattern.len and pattern[i + 1] == '{') {
                while (i < pattern.len and pattern[i] != '}') i += 1;
            }
            continue;
        }
        if (std.ascii.isUpper(c)) return false;
        if (c >= 0x80) {
            const n = std.unicode.utf8ByteSequenceLength(c) catch continue;
            if (i + n <= pattern.len) {
                const cp = std.unicode.utf8Decode(pattern[i..][0..n]) catch continue;
                if (isUpperCp(cp)) return false;
                i += n - 1;
            }
        }
    }
    return true;
}

fn isUpperCp(cp: u21) bool {
    const r = syntax.unicode.propertyRanges("Uppercase", null) orelse return false;
    for (r.ranges) |x| if (cp >= x[0] and cp <= x[1]) return true;
    return false;
}

/// A set of patterns matched together; reports which patterns match.
pub const RegexSet = struct {
    program: nfa.program.Program,
    count: usize,

    /// Compiles every pattern into one program.
    pub fn compile(gpa: Allocator, patterns: []const []const u8, o: Options) CompileError!RegexSet {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const hirs = try arena.alloc(*const syntax.hir.Hir, patterns.len);
        for (patterns, 0..) |p, i| hirs[i] = (try buildHir(arena, p, o)).hir;
        const program = nfa.compile.compile(gpa, hirs, &.{}, .{ .captures = false, .size_limit = o.size_limit }) catch |e| return mapCompileErr(e, o);
        return .{ .program = program, .count = patterns.len };
    }

    /// Frees the set.
    pub fn deinit(set: *RegexSet) void {
        set.program.deinit();
    }

    /// Per-thread scratch for this set.
    pub fn newCache(set: *const RegexSet, gpa: Allocator) Allocator.Error!SetCache {
        return .{ .gpa = gpa, .pike = try pikevm.Cache.init(gpa, &set.program) };
    }

    /// Sets bit `i` of `out` (which must hold `count` bits, cleared by the
    /// caller) for every pattern `i` that matches somewhere in the span.
    pub fn matches(set: *const RegexSet, cache: *SetCache, input: Input, out: *std.DynamicBitSetUnmanaged) void {
        pikevm.searchSet(&set.program, &cache.pike, &input, out);
    }
};

/// Scratch for `RegexSet`.
pub const SetCache = struct {
    gpa: Allocator,
    pike: pikevm.Cache,

    /// Frees the scratch.
    pub fn deinit(c: *SetCache) void {
        c.pike.deinit(c.gpa);
    }
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("syntax/parse_test.zig");
    _ = @import("testing/backtrack_ref.zig");
    _ = @import("regex_test.zig");
}

test "simd: memchr, memrchr and memmem" {
    const hay = "abc,def,ghi" ** 8;
    try std.testing.expectEqual(@as(?usize, 3), simd.memchr(hay, ',', 0));
    try std.testing.expectEqual(@as(?usize, 7), simd.memchr(hay, ',', 4));
    try std.testing.expectEqual(@as(?usize, hay.len - 4), simd.memrchr(hay, ',', hay.len));
    try std.testing.expectEqual(@as(?usize, null), simd.memchr(hay, '!', 0));
    const f: simd.Memmem = .init("ghiabc");
    try std.testing.expectEqual(@as(?usize, 8), f.find(hay, 0));
}
