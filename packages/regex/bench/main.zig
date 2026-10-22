//! zg_regex benchmarks (`zig build bench`). The corpus is generated: a mix
//! of English-like prose, source code and CJK text (16 MiB, 2 MiB with
//! `-Dbench-quick`), so runs are reproducible without vendored data.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_regex = @import("zg_regex");
const bench = zg_core.bench;
const State = bench.State;

pub fn main(min: std.process.Init.Minimal) !u8 {
    return bench.mainFromArgs(min, register);
}

/// Budgeted bench names that have no body yet.
pub const pending = [_][]const u8{
    "regex.teddy_8",
};

const words = [_][]const u8{ "the", "of", "and", "to", "in", "is", "that", "for", "it", "as", "was", "with", "be", "by", "on", "not", "he", "this", "are", "or", "his", "from", "at", "which", "but", "have", "an", "had", "they", "you", "were", "their", "one", "all", "we", "can", "her", "has", "there", "been", "if", "more", "when", "will", "would", "who", "so", "no", "editor", "buffer", "window", "regex", "search" };
const code = [_][]const u8{ "pub fn ", "const ", "var ", "return ", "if (", ") {\n", "}\n", "try ", "self.", "std.mem.", "allocator", "[i]", " = ", "while (", "u8", "usize", ";\n", "// comment about the code\n", "\"string literal\"", "0x1F", "for (items) |item| " };
const cjk = [_][]const u8{ "日本語の", "テキスト", "中文字符", "한국어", "編集者", "検索" };

fn genCorpus(gpa: std.mem.Allocator, size: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, size + 64);
    var rng: std.Random.DefaultPrng = .init(1234);
    const r = rng.random();
    while (out.items.len < size) {
        switch (r.uintLessThan(u8, 10)) {
            0...5 => {
                try out.appendSlice(gpa, words[r.uintLessThan(usize, words.len)]);
                try out.append(gpa, if (r.uintLessThan(u8, 12) == 0) '\n' else ' ');
            },
            6...8 => try out.appendSlice(gpa, code[r.uintLessThan(usize, code.len)]),
            else => try out.appendSlice(gpa, cjk[r.uintLessThan(usize, cjk.len)]),
        }
    }
    out.shrinkRetainingCapacity(size);
    return out.toOwnedSlice(gpa);
}

const Ctx = struct { re: *const zg_regex.Regex, cache: *zg_regex.Cache, hay: []const u8 };

fn countAll(ctx: Ctx, s: *State) void {
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        var it = ctx.re.findIter(ctx.cache, .fromSlice(ctx.hay));
        var n: usize = 0;
        while (it.next()) |_| n += 1;
        bench.doNotOptimizeAway(n);
    }
    s.setBytes(ctx.hay.len);
}

fn runPattern(b: *bench.Bench, name: []const u8, pattern: []const u8, hay: []const u8) !void {
    var re = try zg_regex.Regex.compile(b.gpa, pattern, .{});
    defer re.deinit(b.gpa);
    var cache = try re.newCache(b.gpa);
    defer cache.deinit();
    try b.run(name, Ctx{ .re = &re, .cache = &cache, .hay = hay }, countAll);
}

const CompileCtx = struct { pattern: []const u8 };

fn compileOnce(ctx: CompileCtx, s: *State) void {
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        var re = zg_regex.Regex.compile(s.allocator(), ctx.pattern, .{}) catch unreachable;
        re.deinit(s.allocator());
    }
}

fn cacheCreate(re: *const zg_regex.Regex, s: *State) void {
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        var c = re.newCache(s.allocator()) catch unreachable;
        c.deinit();
    }
}

const PikeCtx = struct { re: *const zg_regex.Regex, hay: []const u8 };

fn pikeOnly(ctx: PikeCtx, s: *State) void {
    const pv = zg_regex.engine.pikevm;
    var pc = pv.Cache.init(s.allocator(), &ctx.re.engines.fwd) catch unreachable;
    defer pc.deinit(s.allocator());
    var i: u64 = 0;
    while (i < s.iterations()) : (i += 1) {
        var slots: [2]u64 = undefined;
        const in = zg_regex.Input.fromSlice(ctx.hay);
        bench.doNotOptimizeAway(pv.search(&ctx.re.engines.fwd, &pc, &in, &slots));
    }
    s.setBytes(ctx.hay.len);
}

fn register(b: *bench.Bench) !void {
    for (pending) |name| if (b.opts.filter == null or std.mem.indexOf(u8, name, b.opts.filter.?) != null)
        std.debug.print("{s:<40} skipped (not implemented yet)\n", .{name});

    const size: usize = if (b.opts.quick) 2 << 20 else 16 << 20;
    const hay = try genCorpus(b.gpa, size);
    defer b.gpa.free(hay);

    try runPattern(b, "regex.memchr_1byte", "@", hay);
    try runPattern(b, "regex.memmem", "Sherlock", hay);
    try runPattern(b, "regex.literal_alt_3", "Holmes|Watson|Moriarty", hay);
    try runPattern(b, "regex.literal_alt_20", "zebra|quokka|axolotl|narwhal|okapi|pangolin|tapir|wombat|dugong|gharial|kakapo|saiga|tarsier|vaquita|binturong|fossa|jerboa|kinkajou|numbat|quoll", hay);
    try runPattern(b, "regex.dfa_word_suffix", "[a-z]+ing\\b", hay);
    try runPattern(b, "regex.dfa_unicode_class", "\\p{Han}{3}", hay);
    try runPattern(b, "regex.dfa_ident", "[A-Za-z_][A-Za-z0-9_]*\\(", hay);
    try runPattern(b, "regex.dfa_no_match", "[0-9]{7}x", hay);
    {
        var re = try zg_regex.Regex.compile(b.gpa, "(?:the|of) (\\w+)", .{});
        defer re.deinit(b.gpa);
        try b.run("regex.pikevm", PikeCtx{ .re = &re, .hay = hay[0..@min(hay.len, 1 << 20)] }, pikeOnly);
    }
    try b.run("regex.compile_20", CompileCtx{ .pattern = "[a-z]+@[a-z]+\\.com" }, compileOnce);
    try b.run("regex.compile_word_unicode", CompileCtx{ .pattern = "\\w+" }, compileOnce);
    {
        var re = try zg_regex.Regex.compile(b.gpa, "\\w+", .{});
        defer re.deinit(b.gpa);
        try b.run("regex.cache_create", &re, cacheCreate);
    }
}
