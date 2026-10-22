//! The default `RegexEngine`: zg_regex with ECMA-262 compatibility for
//! `pattern`, `patternProperties` and the `regex` format (E11.F01.S02.T01).
//!
//! JSON Schema patterns are ECMA-262 regexes, searched unanchored with the
//! `u` flag. zg_regex follows Rust `regex` syntax, so `translate` rewrites
//! the differences that change meaning:
//!
//! - `\d`, `\D`, `\w`, `\W`, `\b` and `\B` are ASCII in ECMA-262 (Unicode
//!   in zg_regex);
//! - `\/` and other identity escapes of non-alphanumeric characters are
//!   plain characters;
//! - `\cX` is a control character.
//!
//! Lookaround and backreferences do not compile in zg_regex; the schema
//! compiler then keeps the pattern as an annotation (or rejects the
//! schema, by option).
//!
//! A search makes a fresh zg_regex cache on a stack-first allocator, so
//! validation stays thread-safe without shared mutable state.

const std = @import("std");
const zg_regex = @import("zg_regex");
const Schema = @import("Schema.zig");

const Allocator = std.mem.Allocator;

pub const engine: Schema.RegexEngine = .{ .ctx = null, .compile = compile, .search = search };

fn compile(_: ?*anyopaque, arena: Allocator, source: []const u8) ?*const anyopaque {
    const pattern = translate(arena, source) catch return null;
    const re = arena.create(zg_regex.Regex) catch return null;
    re.* = zg_regex.Regex.compile(arena, pattern, .{ .unicode = true }) catch return null;
    return re;
}

fn search(_: ?*anyopaque, ptr: *const anyopaque, s: []const u8) bool {
    const re: *const zg_regex.Regex = @ptrCast(@alignCast(ptr));
    var fallback = std.heap.stackFallback(16 * 1024, std.heap.smp_allocator);
    var cache = re.newCache(fallback.get()) catch return false;
    defer cache.deinit();
    return re.isMatch(&cache, .fromSlice(s));
}

/// The `regex` format: whether `s` is a valid ECMA-262 regex. Patterns
/// that are valid but that zg_regex does not run (lookaround,
/// backreferences) count as valid.
pub fn isValid(s: []const u8) bool {
    var fallback = std.heap.stackFallback(32 * 1024, std.heap.smp_allocator);
    var arena: std.heap.ArenaAllocator = .init(fallback.get());
    defer arena.deinit();
    const a = arena.allocator();
    const pattern = translate(a, s) catch return true;
    var diag: zg_regex.Error = undefined;
    _ = zg_regex.Regex.compile(a, pattern, .{ .unicode = true, .diag = &diag }) catch |e| return switch (e) {
        error.Syntax => switch (diag.kind) {
            .unsupported_backreference, .unsupported_lookaround => true,
            else => false,
        },
        else => true,
    };
    return true;
}

/// Rewrites ECMA-262 syntax into zg_regex syntax with the same meaning.
pub fn translate(arena: Allocator, src: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var in_class = false;
    var i: usize = 0;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (c == '[' and !in_class) {
            in_class = true;
            try out.append(arena, c);
            if (i + 1 < src.len and src[i + 1] == '^') {
                i += 1;
                try out.append(arena, '^');
            }
            continue;
        }
        if (c == ']' and in_class) {
            in_class = false;
            try out.append(arena, c);
            continue;
        }
        if (c != '\\' or i + 1 >= src.len) {
            // A literal `[` inside a class must be escaped in zg_regex.
            if (in_class and c == '[') try out.append(arena, '\\');
            try out.append(arena, c);
            continue;
        }
        i += 1;
        const e = src[i];
        switch (e) {
            'd' => try out.appendSlice(arena, if (in_class) "0-9" else "[0-9]"),
            'w' => try out.appendSlice(arena, if (in_class) "A-Za-z0-9_" else "[A-Za-z0-9_]"),
            'D' => try out.appendSlice(arena, if (in_class) "\\D" else "[^0-9]"),
            'W' => try out.appendSlice(arena, if (in_class) "\\W" else "[^A-Za-z0-9_]"),
            'b' => try out.appendSlice(arena, if (in_class) "\\x{8}" else "(?-u:\\b)"),
            'B' => try out.appendSlice(arena, if (in_class) "B" else "(?-u:\\B)"),
            'c' => if (i + 1 < src.len and std.ascii.isAlphabetic(src[i + 1])) {
                i += 1;
                try out.print(arena, "\\x{{{x}}}", .{src[i] % 32});
            } else try out.appendSlice(arena, "\\\\c"),
            '/' => try out.append(arena, '/'),
            '-' => try out.appendSlice(arena, if (in_class) "\\-" else "-"),
            else => {
                try out.append(arena, '\\');
                try out.append(arena, e);
            },
        }
    }
    return out.items;
}

test translate {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = std.testing;
    try t.expectEqualStrings("^[0-9]+$", try translate(a, "^\\d+$"));
    try t.expectEqualStrings("[0-9a-f]", try translate(a, "[\\da-f]"));
    try t.expectEqualStrings("a/b", try translate(a, "a\\/b"));
    try t.expectEqualStrings("(?-u:\\b)x", try translate(a, "\\bx"));
    try t.expectEqualStrings("\\x{3}", try translate(a, "\\cC"));
    try t.expectEqualStrings("\\p{Letter}", try translate(a, "\\p{Letter}"));
    try t.expectEqualStrings("[a\\[]", try translate(a, "[a[]"));
}

test "ecma engine" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = std.testing;
    const re = compile(null, a, "^\\d{3}-\\w+$").?;
    try t.expect(search(null, re, "123-abc"));
    try t.expect(!search(null, re, "١٢٣-abc"));
    // Unanchored by default.
    try t.expect(search(null, compile(null, a, "b").?, "abc"));
    // Lookaround and backreferences are not supported.
    try t.expect(compile(null, a, "^(?=a)") == null);
    try t.expect(compile(null, a, "(a)\\1") == null);
    try t.expect(isValid("^(?=a)[a-z]+$"));
    try t.expect(!isValid("^(abc]"));
}
