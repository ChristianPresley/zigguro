//! D-Bus type signatures: validation, single complete types and alignment.
//! Every function also works at comptime, which `marshal.encode` relies on
//! to check its arguments against the signature.

const std = @import("std");

/// A signature that breaks the D-Bus grammar or its limits.
pub const Error = error{InvalidSignature};

/// Longest signature the wire format allows.
pub const max_len = 255;
/// Deepest array nesting in one signature.
pub const max_array_depth = 32;
/// Deepest struct nesting in one signature.
pub const max_struct_depth = 32;
/// Deepest total nesting of containers, variants included, when decoding.
pub const max_depth = 64;

/// The alignment of a type, by its first signature character.
pub fn alignOf(code: u8) usize {
    return switch (code) {
        'n', 'q' => 2,
        'b', 'i', 'u', 's', 'o', 'a', 'h' => 4,
        'x', 't', 'd', '(', '{' => 8,
        else => 1,
    };
}

/// Whether `code` is a basic type, which dict keys must be.
pub fn isBasic(code: u8) bool {
    return switch (code) {
        'y', 'b', 'n', 'q', 'i', 'u', 'x', 't', 'd', 's', 'o', 'g', 'h' => true,
        else => false,
    };
}

/// The length of the single complete type that starts `sig`.
pub fn completeLen(sig: []const u8) Error!usize {
    return parseOne(sig, 0, 0, 0);
}

/// Checks a whole signature: zero or more complete types.
pub fn validate(sig: []const u8) Error!void {
    if (sig.len > max_len) return error.InvalidSignature;
    var i: usize = 0;
    while (i < sig.len) i = try parseOne(sig, i, 0, 0);
}

/// Checks that `sig` is exactly one complete type, as a variant needs.
pub fn validateSingle(sig: []const u8) Error!void {
    if (sig.len == 0 or sig.len > max_len) return error.InvalidSignature;
    if (try completeLen(sig) != sig.len) return error.InvalidSignature;
}

/// How many complete types `sig` holds. `sig` must be valid.
pub fn count(sig: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < sig.len) : (n += 1) i = parseOne(sig, i, 0, 0) catch unreachable;
    return n;
}

fn parseOne(sig: []const u8, start: usize, arrays: u32, structs: u32) Error!usize {
    if (start >= sig.len) return error.InvalidSignature;
    const c = sig[start];
    if (isBasic(c) or c == 'v') return start + 1;
    switch (c) {
        'a' => {
            if (arrays + 1 > max_array_depth) return error.InvalidSignature;
            if (start + 1 < sig.len and sig[start + 1] == '{') return parseDictEntry(sig, start + 1, arrays + 1, structs);
            return parseOne(sig, start + 1, arrays + 1, structs);
        },
        '(' => {
            if (structs + 1 > max_struct_depth) return error.InvalidSignature;
            var i = start + 1;
            if (i >= sig.len or sig[i] == ')') return error.InvalidSignature;
            while (i < sig.len and sig[i] != ')') i = try parseOne(sig, i, arrays, structs + 1);
            if (i >= sig.len) return error.InvalidSignature;
            return i + 1;
        },
        else => return error.InvalidSignature,
    }
}

fn parseDictEntry(sig: []const u8, start: usize, arrays: u32, structs: u32) Error!usize {
    if (structs + 1 > max_struct_depth) return error.InvalidSignature;
    const k = start + 1;
    if (k >= sig.len or !isBasic(sig[k])) return error.InvalidSignature;
    const v_end = try parseOne(sig, k + 1, arrays, structs + 1);
    if (v_end >= sig.len or sig[v_end] != '}') return error.InvalidSignature;
    return v_end + 1;
}

const testing = std.testing;

test "valid signatures and their single complete types" {
    const ok = [_][]const u8{ "", "y", "s", "a{sv}", "(ii)", "a(sa{sv})", "aai", "v", "ua{sv}", "a{oa{sa{sv}}}", "h" };
    for (ok) |s| try validate(s);
    try testing.expectEqual(5, try completeLen("a{sv}u"));
    try testing.expectEqual(4, try completeLen("(ii)s"));
    try testing.expectEqual(3, count("ua{sv}s"));
}

test "invalid signatures" {
    const bad = [_][]const u8{ "a", "(", "()", "(i", "{sv}", "a{vs}", "a{s}", "a{svs}", "z", "a{(i)s}", ")" };
    for (bad) |s| try testing.expectError(error.InvalidSignature, validate(s));
    try testing.expectError(error.InvalidSignature, validateSingle("ii"));
    try validateSingle("a{sv}");
}

test "nesting limits" {
    const deep_ok = "a" ** 32 ++ "y";
    try validate(deep_ok);
    try testing.expectError(error.InvalidSignature, validate("a" ** 33 ++ "y"));
    try validate("(" ** 32 ++ "y" ++ ")" ** 32);
    try testing.expectError(error.InvalidSignature, validate("(" ** 33 ++ "y" ++ ")" ** 33));
    try testing.expectError(error.InvalidSignature, validate("y" ** 256));
}

test "works at comptime" {
    comptime {
        std.debug.assert(completeLen("a{sv}") catch unreachable == 5);
        std.debug.assert(alignOf('t') == 8);
    }
}
