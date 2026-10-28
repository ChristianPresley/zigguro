//! `json_edit`: comment-preserving programmatic edits of JSONC settings
//! files (E15.F01.S02.T02 for the JSON format). `set` replaces or inserts
//! one member of the root object (or of a `"[lang]"` block in it) and
//! `remove` deletes one; every other byte of the file, comments and
//! formatting included, is kept. `writeAtomic` replaces a file through a
//! temporary file so a crash never leaves half a settings file.
//!
//! Keys are written flat, the way VS Code writes them:
//! `"editor.fontSize": 14`. A key nested in the file
//! (`"editor": { "fontSize": 14 }`) is not found by `set`, which then
//! adds the flat key; the layer loader gives the later member priority.

const std = @import("std");
const jsonc = @import("jsonc.zig");
const zon_load = @import("zon_load.zig");
const value_mod = @import("value.zig");
const diag = @import("diag.zig");

const Allocator = std.mem.Allocator;
const Value = value_mod.Value;
const Node = zon_load.Node;
const Field = zon_load.Field;

/// Errors of `set` and `remove`.
pub const Error = error{
    OutOfMemory,
    /// The file is not valid JSONC (fix it by hand first).
    Invalid,
    /// The root (or the language block) is not an object.
    NotAnObject,
};

/// The default indentation of a new file.
const indent_unit = "    ";

/// Returns `src` with `key` set to `v` in the root object, or in the
/// `lang` block (`"[zig]"`) when given. An empty `src` becomes a new
/// object. The caller owns the result.
pub fn set(gpa: Allocator, src: []const u8, lang: ?[]const u8, key: []const u8, v: Value) Error![]u8 {
    if (isBlank(src)) {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        writeBody(w, lang, key, v) catch return error.OutOfMemory;
        return out.toOwnedSlice() catch error.OutOfMemory;
    }
    var diags: diag.Diags = .init(gpa);
    defer diags.deinit();
    var doc = jsonc.loadJsonc(gpa, src, &diags) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Invalid => error.Invalid,
    };
    defer doc.deinit();
    if (doc.root.v != .object) return error.NotAnObject;
    if (lang) |l| {
        if (findField(doc.root, l)) |f| {
            if (f.value.v != .object) return error.NotAnObject;
            return setIn(gpa, src, f.value, key, v);
        }
        // A new block holding the one key.
        var tmp: std.Io.Writer.Allocating = .init(gpa);
        defer tmp.deinit();
        const ind = memberIndent(src, doc.root);
        writeBlock(&tmp.writer, ind, key, v) catch return error.OutOfMemory;
        return insertRaw(gpa, src, doc.root, l, tmp.written());
    }
    return setIn(gpa, src, doc.root, key, v);
}

/// Returns `src` without the member `key` (of the `lang` block when given),
/// or an unchanged copy when it is not there. An emptied language block
/// is removed too.
pub fn remove(gpa: Allocator, src: []const u8, lang: ?[]const u8, key: []const u8) Error![]u8 {
    if (isBlank(src)) return gpa.dupe(u8, src);
    var diags: diag.Diags = .init(gpa);
    defer diags.deinit();
    var doc = jsonc.loadJsonc(gpa, src, &diags) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Invalid => error.Invalid,
    };
    defer doc.deinit();
    if (doc.root.v != .object) return error.NotAnObject;
    var obj = doc.root;
    if (lang) |l| {
        const f = findField(doc.root, l) orelse return gpa.dupe(u8, src);
        if (f.value.v != .object) return error.NotAnObject;
        if (f.value.v.object.len == 1 and std.mem.eql(u8, f.value.v.object[0].key, key))
            return removeField(gpa, src, doc.root, f);
        obj = f.value;
    }
    const f = findField(obj, key) orelse return gpa.dupe(u8, src);
    return removeField(gpa, src, obj, f);
}

/// Writes `bytes` to `sub_path` in `dir` through a temporary file, creating
/// missing parent directories.
pub fn writeAtomic(io: std.Io, dir: std.Io.Dir, sub_path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(sub_path)) |parent| try dir.createDirPath(io, parent);
    var af = try dir.createFileAtomic(io, sub_path, .{ .replace = true });
    defer af.deinit(io);
    try af.file.writeStreamingAll(io, bytes);
    try af.file.sync(io);
    try af.replace(io);
}

fn isBlank(src: []const u8) bool {
    return std.mem.trim(u8, src, " \t\r\n").len == 0;
}

fn findField(obj: Node, key: []const u8) ?Field {
    // The loader keeps the first of duplicate keys, so edit that one.
    for (obj.v.object) |f| if (std.mem.eql(u8, f.key, key)) return f;
    return null;
}

fn writeBody(w: *std.Io.Writer, lang: ?[]const u8, key: []const u8, v: Value) std.Io.Writer.Error!void {
    try w.writeAll("{\n" ++ indent_unit);
    if (lang) |l| {
        try value_mod.writeJsonString(w, l);
        try w.writeAll(": ");
        try writeBlock(w, indent_unit, key, v);
    } else {
        try value_mod.writeJsonString(w, key);
        try w.writeAll(": ");
        try writePretty(w, v, indent_unit);
    }
    try w.writeAll("\n}\n");
}

fn writeBlock(w: *std.Io.Writer, ind: []const u8, key: []const u8, v: Value) std.Io.Writer.Error!void {
    try w.writeAll("{\n");
    try w.writeAll(ind);
    try w.writeAll(indent_unit);
    try value_mod.writeJsonString(w, key);
    try w.writeAll(": ");
    var buf: [64]u8 = undefined;
    const inner = std.fmt.bufPrint(&buf, "{s}" ++ indent_unit, .{ind}) catch ind;
    try writePretty(w, v, inner);
    try w.writeAll("\n");
    try w.writeAll(ind);
    try w.writeAll("}");
}

/// JSON for `v`: scalars and short arrays on one line, objects and longer
/// arrays one member per line, indented from `ind`.
pub fn writePretty(w: *std.Io.Writer, v: Value, ind: []const u8) std.Io.Writer.Error!void {
    switch (v) {
        .object => |fs| {
            if (fs.len == 0) return w.writeAll("{}");
            try w.writeAll("{\n");
            for (fs, 0..) |f, i| {
                try w.writeAll(ind);
                try w.writeAll(indent_unit);
                try value_mod.writeJsonString(w, f.key);
                try w.writeAll(": ");
                var buf: [256]u8 = undefined;
                try writePretty(w, f.value, std.fmt.bufPrint(&buf, "{s}" ++ indent_unit, .{ind}) catch ind);
                try w.writeAll(if (i + 1 < fs.len) ",\n" else "\n");
            }
            try w.writeAll(ind);
            try w.writeAll("}");
        },
        .array => |xs| {
            var scalar = xs.len <= 8;
            for (xs) |x| if (x == .object or x == .array) {
                scalar = false;
            };
            if (scalar) {
                try w.writeByte('[');
                for (xs, 0..) |x, i| {
                    if (i != 0) try w.writeAll(", ");
                    try x.writeJson(w);
                }
                return w.writeByte(']');
            }
            try w.writeAll("[\n");
            for (xs, 0..) |x, i| {
                try w.writeAll(ind);
                try w.writeAll(indent_unit);
                var buf: [256]u8 = undefined;
                try writePretty(w, x, std.fmt.bufPrint(&buf, "{s}" ++ indent_unit, .{ind}) catch ind);
                try w.writeAll(if (i + 1 < xs.len) ",\n" else "\n");
            }
            try w.writeAll(ind);
            try w.writeAll("]");
        },
        else => try v.writeJson(w),
    }
}

/// `key` set in the object `obj` (a member's value is replaced in place).
fn setIn(gpa: Allocator, src: []const u8, obj: Node, key: []const u8, v: Value) Error![]u8 {
    var tmp: std.Io.Writer.Allocating = .init(gpa);
    defer tmp.deinit();
    if (findField(obj, key)) |f| {
        writePretty(&tmp.writer, v, indentOf(src, f.key_span.start)) catch return error.OutOfMemory;
        return splice(gpa, src, f.value.span.start, f.value.span.end, tmp.written());
    }
    writePretty(&tmp.writer, v, memberIndent(src, obj)) catch return error.OutOfMemory;
    return insertRaw(gpa, src, obj, key, tmp.written());
}

/// Adds the member `"key": raw` at the end of `obj`.
fn insertRaw(gpa: Allocator, src: []const u8, obj: Node, key: []const u8, raw: []const u8) Error![]u8 {
    var member: std.Io.Writer.Allocating = .init(gpa);
    defer member.deinit();
    const mw = &member.writer;
    const ind = memberIndent(src, obj);
    const fs = obj.v.object;
    if (fs.len == 0) {
        // `{}` or `{ /* comments */ }`: the member goes after the brace.
        const open = obj.span.start + 1;
        const inner = src[open .. obj.span.end - 1];
        const blank = isBlank(inner);
        const close_ind = indentOf(src, obj.span.start);
        mw.writeAll("\n") catch return error.OutOfMemory;
        mw.writeAll(ind) catch return error.OutOfMemory;
        value_mod.writeJsonString(mw, key) catch return error.OutOfMemory;
        mw.writeAll(": ") catch return error.OutOfMemory;
        mw.writeAll(raw) catch return error.OutOfMemory;
        if (blank) {
            mw.writeAll("\n") catch return error.OutOfMemory;
            mw.writeAll(close_ind) catch return error.OutOfMemory;
            return splice(gpa, src, open, obj.span.end - 1, member.written());
        }
        return splice(gpa, src, open, open, member.written());
    }
    // After the last member, and after its comma when it has one.
    const last = fs[fs.len - 1];
    var at = last.value.span.end;
    const after = skipWsComments(src, at, obj.span.end - 1);
    const has_comma = after < src.len and src[after] == ',';
    if (has_comma) at = @intCast(after + 1) else mw.writeAll(",") catch return error.OutOfMemory;
    mw.writeAll("\n") catch return error.OutOfMemory;
    mw.writeAll(ind) catch return error.OutOfMemory;
    value_mod.writeJsonString(mw, key) catch return error.OutOfMemory;
    mw.writeAll(": ") catch return error.OutOfMemory;
    mw.writeAll(raw) catch return error.OutOfMemory;
    // Keep a trailing comma style when the file uses one.
    if (has_comma) mw.writeAll(",") catch return error.OutOfMemory;
    return splice(gpa, src, at, at, member.written());
}

/// Removes member `f` of `obj` with its comma and, when it sits on lines
/// of its own, those lines.
fn removeField(gpa: Allocator, src: []const u8, obj: Node, f: Field) Error![]u8 {
    const fs = obj.v.object;
    const idx = for (fs, 0..) |x, i| {
        if (x.key_span.start == f.key_span.start) break i;
    } else unreachable;
    const start: usize = f.key_span.start;
    var end: usize = f.value.span.end;
    const after = skipWsComments(src, @intCast(end), obj.span.end - 1);
    const has_comma = after < src.len and src[after] == ',';
    if (has_comma) end = after + 1;
    if (!has_comma and idx > 0) {
        // The last member: drop the previous member's comma instead.
        const prev_end = fs[idx - 1].value.span.end;
        const c = skipWsComments(src, prev_end, @intCast(start));
        if (c < start and src[c] == ',') {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(gpa);
            try out.appendSlice(gpa, src[0..c]);
            const rs, const re = wholeLines(src, start, end);
            // Inline, the space before the member goes with it.
            if (rs != start) try out.appendSlice(gpa, src[c + 1 .. rs]);
            try out.appendSlice(gpa, src[re..]);
            return out.toOwnedSlice(gpa);
        }
    }
    const rs, var re = wholeLines(src, start, end);
    // Inline (`{ "a": 1, "b": 2 }`): the space after the comma goes too.
    if (rs == start) while (re < src.len and src[re] == ' ') {
        re += 1;
    };
    return splice(gpa, src, rs, re, "");
}

/// Widens `[start, end)` to whole lines when nothing else is on them.
fn wholeLines(src: []const u8, start: usize, end: usize) struct { usize, usize } {
    var ls = start;
    while (ls > 0 and (src[ls - 1] == ' ' or src[ls - 1] == '\t')) ls -= 1;
    if (ls != 0 and src[ls - 1] != '\n') return .{ start, end };
    var le = end;
    while (le < src.len and (src[le] == ' ' or src[le] == '\t' or src[le] == '\r')) le += 1;
    if (le < src.len and src[le] != '\n') return .{ start, end };
    if (le < src.len) le += 1;
    return .{ ls, le };
}

/// The first byte at or after `i` (and before `limit`) that is not
/// whitespace or inside a comment; `limit` when there is none.
fn skipWsComments(src: []const u8, from: u32, limit: u32) usize {
    var i: usize = from;
    while (i < limit) {
        const c = src[i];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            i += 1;
        } else if (c == '/' and i + 1 < limit and src[i + 1] == '/') {
            while (i < limit and src[i] != '\n') i += 1;
        } else if (c == '/' and i + 1 < limit and src[i + 1] == '*') {
            i += 2;
            while (i + 1 < limit and !(src[i] == '*' and src[i + 1] == '/')) i += 1;
            i += 2;
        } else return i;
    }
    return limit;
}

/// The indentation of members of `obj`: its first member's, or the
/// object's own plus one unit.
fn memberIndent(src: []const u8, obj: Node) []const u8 {
    const fs = obj.v.object;
    if (fs.len > 0) {
        const ks = fs[0].key_span.start;
        const ind = indentOf(src, ks);
        // Members on the brace's line (`{ "a": 1 }`): one unit.
        if (lineStart(src, ks) <= obj.span.start) return indent_unit;
        return ind;
    }
    const own = indentOf(src, obj.span.start);
    return if (own.len == 0) indent_unit else nested_indents.get(own);
}

/// Owned copies of "own indent + one unit" for the common cases.
const nested_indents = struct {
    fn get(own: []const u8) []const u8 {
        if (std.mem.eql(u8, own, indent_unit)) return indent_unit ++ indent_unit;
        if (std.mem.eql(u8, own, "  ")) return "    ";
        if (std.mem.eql(u8, own, "\t")) return "\t\t";
        return indent_unit ++ indent_unit;
    }
};

fn lineStart(src: []const u8, i: usize) usize {
    var s = i;
    while (s > 0 and src[s - 1] != '\n') s -= 1;
    return s;
}

/// The whitespace at the start of the line holding byte `i`.
fn indentOf(src: []const u8, i: usize) []const u8 {
    const s = lineStart(src, i);
    var e = s;
    while (e < src.len and (src[e] == ' ' or src[e] == '\t')) e += 1;
    return src[s..e];
}

fn splice(gpa: Allocator, src: []const u8, start: usize, end: usize, with: []const u8) Error![]u8 {
    const out = try gpa.alloc(u8, src.len - (end - start) + with.len);
    @memcpy(out[0..start], src[0..start]);
    @memcpy(out[start..][0..with.len], with);
    @memcpy(out[start + with.len ..], src[end..]);
    return out;
}

const testing = std.testing;

fn expectSet(src: []const u8, lang: ?[]const u8, key: []const u8, v: Value, want: []const u8) !void {
    const got = try set(testing.allocator, src, lang, key, v);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
    // Always valid JSONC afterwards.
    var diags: diag.Diags = .init(testing.allocator);
    defer diags.deinit();
    var d = try jsonc.loadJsonc(testing.allocator, got, &diags);
    d.deinit();
}

fn expectRemove(src: []const u8, lang: ?[]const u8, key: []const u8, want: []const u8) !void {
    const got = try remove(testing.allocator, src, lang, key);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "json_edit: a new file" {
    try expectSet("", null, "editor.fontSize", .{ .int = 14 }, "{\n    \"editor.fontSize\": 14\n}\n");
    try expectSet("  \n", "[zig]", "editor.tabSize", .{ .int = 4 }, "{\n    \"[zig]\": {\n        \"editor.tabSize\": 4\n    }\n}\n");
}

test "json_edit: replace keeps comments and layout" {
    const src =
        \\{
        \\    // Bigger text.
        \\    "editor.fontSize": 13, // was 12
        \\    "files.autoSave": "off"
        \\}
        \\
    ;
    try expectSet(src, null, "editor.fontSize", .{ .int = 16 },
        \\{
        \\    // Bigger text.
        \\    "editor.fontSize": 16, // was 12
        \\    "files.autoSave": "off"
        \\}
        \\
    );
    try expectSet(src, null, "files.autoSave", .{ .string = "afterDelay" },
        \\{
        \\    // Bigger text.
        \\    "editor.fontSize": 13, // was 12
        \\    "files.autoSave": "afterDelay"
        \\}
        \\
    );
}

test "json_edit: insert after the last member" {
    try expectSet("{\n  \"a\": 1\n}\n", null, "b", .{ .bool = true }, "{\n  \"a\": 1,\n  \"b\": true\n}\n");
    // A trailing comma stays a trailing comma.
    try expectSet("{\n  \"a\": 1,\n}\n", null, "b", .{ .bool = true }, "{\n  \"a\": 1,\n  \"b\": true,\n}\n");
    // A comment after the last member stays where it is.
    try expectSet("{\n  \"a\": 1 // one\n}\n", null, "b", .{ .int = 2 }, "{\n  \"a\": 1,\n  \"b\": 2 // one\n}\n");
    try expectSet("{}", null, "a", .{ .int = 1 }, "{\n    \"a\": 1\n}");
    try expectSet("{ // nothing yet\n}", null, "a", .{ .int = 1 }, "{\n    \"a\": 1 // nothing yet\n}");
}

test "json_edit: arrays and objects are pretty-printed" {
    const fields = [_]Value.Field{ .{ .key = "**/.git", .value = .{ .bool = true } }, .{ .key = "zig-out", .value = .{ .bool = true } } };
    try expectSet("{\n    \"a\": 1\n}\n", null, "files.exclude", .{ .object = &fields },
        \\{
        \\    "a": 1,
        \\    "files.exclude": {
        \\        "**/.git": true,
        \\        "zig-out": true
        \\    }
        \\}
        \\
    );
    const xs = [_]Value{ .{ .string = "a" }, .{ .string = "b" } };
    try expectSet("{}", null, "l", .{ .array = &xs }, "{\n    \"l\": [\"a\", \"b\"]\n}");
}

test "json_edit: language blocks" {
    try expectSet("{\n    \"a\": 1\n}\n", "[zig]", "editor.tabSize", .{ .int = 4 },
        \\{
        \\    "a": 1,
        \\    "[zig]": {
        \\        "editor.tabSize": 4
        \\    }
        \\}
        \\
    );
    try expectSet("{\n    \"[zig]\": {\n        \"x\": 1\n    }\n}\n", "[zig]", "editor.tabSize", .{ .int = 4 },
        \\{
        \\    "[zig]": {
        \\        "x": 1,
        \\        "editor.tabSize": 4
        \\    }
        \\}
        \\
    );
    try expectRemove("{\n    \"a\": 1,\n    \"[zig]\": {\n        \"x\": 1\n    }\n}\n", "[zig]", "x", "{\n    \"a\": 1\n}\n");
}

test "json_edit: remove" {
    const src =
        \\{
        \\    "a": 1,
        \\    // about b
        \\    "b": 2,
        \\    "c": 3
        \\}
        \\
    ;
    try expectRemove(src, null, "b",
        \\{
        \\    "a": 1,
        \\    // about b
        \\    "c": 3
        \\}
        \\
    );
    try expectRemove(src, null, "c",
        \\{
        \\    "a": 1,
        \\    // about b
        \\    "b": 2
        \\}
        \\
    );
    try expectRemove("{\n    \"a\": 1\n}\n", null, "a", "{\n}\n");
    try expectRemove("{ \"a\": 1, \"b\": 2 }", null, "a", "{ \"b\": 2 }");
    try expectRemove("{ \"a\": 1, \"b\": 2 }", null, "b", "{ \"a\": 1 }");
    try expectRemove("{ \"a\": 1 }", null, "zzz", "{ \"a\": 1 }");
}

test "json_edit: invalid files are refused" {
    try testing.expectError(error.Invalid, set(testing.allocator, "{ \"a\": ", null, "a", .{ .int = 1 }));
    try testing.expectError(error.NotAnObject, set(testing.allocator, "[1]", null, "a", .{ .int = 1 }));
}

test "json_edit: writeAtomic creates parents" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeAtomic(testing.io, tmp.dir, "a/b/settings.json", "{}\n");
    const got = try tmp.dir.readFileAlloc(testing.io, "a/b/settings.json", testing.allocator, .limited(64));
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("{}\n", got);
}
