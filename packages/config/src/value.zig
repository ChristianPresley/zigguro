//! The span-free dynamic value used by the settings store, command args and
//! keybinding args. Objects keep their fields sorted by key so equality and
//! lookup are deterministic. Values never own memory: whoever built one (an
//! arena, or comptime data) keeps the bytes alive.

const std = @import("std");

/// A dynamic ZON/JSON value.
pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    /// An enum literal such as `.on`, stored without the dot.
    enum_lit: []const u8,
    array: []const Value,
    /// Fields sorted by key, no duplicates.
    object: []const Field,

    /// One object member.
    pub const Field = struct {
        key: []const u8,
        value: Value,
    };

    /// Deep equality. An `int` never equals a `float`; strings and enum
    /// literals compare by bytes and never equal each other.
    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .null => true,
            .bool => |x| x == b.bool,
            .int => |x| x == b.int,
            .float => |x| x == b.float or (std.math.isNan(x) and std.math.isNan(b.float)),
            .string => |x| std.mem.eql(u8, x, b.string),
            .enum_lit => |x| std.mem.eql(u8, x, b.enum_lit),
            .array => |xs| {
                if (xs.len != b.array.len) return false;
                for (xs, b.array) |x, y| if (!x.eql(y)) return false;
                return true;
            },
            .object => |fs| {
                if (fs.len != b.object.len) return false;
                for (fs, b.object) |x, y| {
                    if (!std.mem.eql(u8, x.key, y.key) or !x.value.eql(y.value)) return false;
                }
                return true;
            },
        };
    }

    /// A structural hash consistent with `eql`.
    pub fn hash(v: Value) u64 {
        var h = std.hash.Wyhash.init(0);
        v.hashInto(&h);
        return h.final();
    }

    fn hashInto(v: Value, h: *std.hash.Wyhash) void {
        h.update(&.{@intFromEnum(std.meta.activeTag(v))});
        switch (v) {
            .null => {},
            .bool => |x| h.update(&.{@intFromBool(x)}),
            .int => |x| h.update(std.mem.asBytes(&x)),
            .float => |x| h.update(std.mem.asBytes(&x)),
            .string, .enum_lit => |s| {
                h.update(std.mem.asBytes(&s.len));
                h.update(s);
            },
            .array => |xs| {
                h.update(std.mem.asBytes(&xs.len));
                for (xs) |x| x.hashInto(h);
            },
            .object => |fs| {
                h.update(std.mem.asBytes(&fs.len));
                for (fs) |f| {
                    h.update(f.key);
                    h.update(&.{0});
                    f.value.hashInto(h);
                }
            },
        }
    }

    /// The member `key` of an object, or null (also for non-objects).
    pub fn get(v: Value, key: []const u8) ?Value {
        const fs = switch (v) {
            .object => |o| o,
            else => return null,
        };
        const i = std.sort.binarySearch(Field, fs, key, struct {
            fn cmp(k: []const u8, f: Field) std.math.Order {
                return std.mem.order(u8, k, f.key);
            }
        }.cmp) orelse return null;
        return fs[i].value;
    }

    /// Deep copy into `arena`.
    pub fn clone(v: Value, arena: std.mem.Allocator) error{OutOfMemory}!Value {
        return switch (v) {
            .null, .bool, .int, .float => v,
            .string => |s| .{ .string = try arena.dupe(u8, s) },
            .enum_lit => |s| .{ .enum_lit = try arena.dupe(u8, s) },
            .array => |xs| blk: {
                const out = try arena.alloc(Value, xs.len);
                for (xs, out) |x, *o| o.* = try x.clone(arena);
                break :blk .{ .array = out };
            },
            .object => |fs| blk: {
                const out = try arena.alloc(Field, fs.len);
                for (fs, out) |f, *o| o.* = .{ .key = try arena.dupe(u8, f.key), .value = try f.value.clone(arena) };
                break :blk .{ .object = out };
            },
        };
    }

    /// The string form used by when-clause equality: strings and enum
    /// literals as-is, `true`/`false`, numbers in decimal. Returns null for
    /// arrays, objects and null.
    pub fn scalarText(v: Value, buf: []u8) ?[]const u8 {
        return switch (v) {
            .string, .enum_lit => |s| s,
            .bool => |b| if (b) "true" else "false",
            .int => |i| std.fmt.bufPrint(buf, "{d}", .{i}) catch null,
            .float => |f| std.fmt.bufPrint(buf, "{d}", .{f}) catch null,
            else => null,
        };
    }

    /// Writes canonical single-line ZON: `.{ .a = 1, .b = "x" }`, tuples as
    /// `.{ 1, 2 }`, keys quoted with `@"..."` when they are not identifiers.
    /// Equal values always produce equal text, so the text can key caches.
    pub fn writeZon(v: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (v) {
            .null => try w.writeAll("null"),
            .bool => |b| try w.writeAll(if (b) "true" else "false"),
            .int => |i| try w.print("{d}", .{i}),
            .float => |f| {
                if (std.math.isNan(f)) return w.writeAll("nan");
                if (std.math.isInf(f)) return w.writeAll(if (f > 0) "inf" else "-inf");
                if (f == @trunc(f) and @abs(f) < 1e15) return w.print("{d}.0", .{f});
                try w.print("{d}", .{f});
            },
            .string => |s| try w.print("\"{f}\"", .{std.zig.fmtString(s)}),
            .enum_lit => |s| try writeIdent(w, s),
            .array => |xs| {
                if (xs.len == 0) return w.writeAll(".{}");
                try w.writeAll(".{ ");
                for (xs, 0..) |x, i| {
                    if (i != 0) try w.writeAll(", ");
                    try x.writeZon(w);
                }
                try w.writeAll(" }");
            },
            .object => |fs| {
                if (fs.len == 0) return w.writeAll(".{}");
                try w.writeAll(".{ ");
                for (fs, 0..) |f, i| {
                    if (i != 0) try w.writeAll(", ");
                    try writeIdent(w, f.key);
                    try w.writeAll(" = ");
                    try f.value.writeZon(w);
                }
                try w.writeAll(" }");
            },
        }
    }

    /// Writes JSON (for agents, ZEP and MCP). Enum literals become strings.
    pub fn writeJson(v: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (v) {
            .null => try w.writeAll("null"),
            .bool => |b| try w.writeAll(if (b) "true" else "false"),
            .int => |i| try w.print("{d}", .{i}),
            .float => |f| if (std.math.isFinite(f)) try w.print("{d}", .{f}) else try w.writeAll("null"),
            .string, .enum_lit => |s| try writeJsonString(w, s),
            .array => |xs| {
                try w.writeByte('[');
                for (xs, 0..) |x, i| {
                    if (i != 0) try w.writeByte(',');
                    try x.writeJson(w);
                }
                try w.writeByte(']');
            },
            .object => |fs| {
                try w.writeByte('{');
                for (fs, 0..) |f, i| {
                    if (i != 0) try w.writeByte(',');
                    try writeJsonString(w, f.key);
                    try w.writeByte(':');
                    try f.value.writeJson(w);
                }
                try w.writeByte('}');
            },
        }
    }

    /// `std.fmt` hook: `{f}` prints canonical ZON.
    pub fn format(v: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
        return v.writeZon(w);
    }
};

/// Writes `s` as a ZON identifier: `.name` or `.@"quoted name"`.
fn writeIdent(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    if (isIdent(s)) return w.print(".{s}", .{s});
    try w.print(".@\"{f}\"", .{std.zig.fmtString(s)});
}

/// Whether `s` can be written as a bare Zig identifier.
pub fn isIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!(std.ascii.isAlphabetic(s[0]) or s[0] == '_')) return false;
    for (s[1..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return !std.zig.Token.keywords.has(s) and !std.zig.isPrimitive(s);
}

/// Writes a JSON string literal with escapes.
pub fn writeJsonString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11, 12, 14...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// Sorts `fields` by key in place (stable, so the first duplicate stays first).
pub fn sortFields(fields: []Value.Field) void {
    std.sort.insertion(Value.Field, fields, {}, struct {
        fn lt(_: void, a: Value.Field, b: Value.Field) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.lt);
}

test "value: eql and hash" {
    const a: Value = .{ .object = &.{ .{ .key = "a", .value = .{ .int = 1 } }, .{ .key = "b", .value = .{ .array = &.{ .{ .string = "x" }, .null } } } } };
    const b: Value = .{ .object = &.{ .{ .key = "a", .value = .{ .int = 1 } }, .{ .key = "b", .value = .{ .array = &.{ .{ .string = "x" }, .null } } } } };
    const c: Value = .{ .object = &.{.{ .key = "a", .value = .{ .float = 1 } }} };
    try std.testing.expect(a.eql(b));
    try std.testing.expectEqual(a.hash(), b.hash());
    try std.testing.expect(!a.eql(c));
    try std.testing.expect(!(Value{ .string = "on" }).eql(.{ .enum_lit = "on" }));
    try std.testing.expectEqual(@as(i64, 1), a.get("a").?.int);
    try std.testing.expect(a.get("zz") == null);
}

test "value: canonical zon and json" {
    const v: Value = .{ .object = &.{
        .{ .key = "a.b", .value = .{ .enum_lit = "on" } },
        .{ .key = "n", .value = .{ .float = 2 } },
        .{ .key = "s", .value = .{ .array = &.{ .{ .string = "q\"" }, .{ .bool = true } } } },
    } };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try v.writeZon(&w);
    try std.testing.expectEqualStrings(".{ .@\"a.b\" = .on, .n = 2.0, .s = .{ \"q\\\"\", true } }", w.buffered());
    w = .fixed(&buf);
    try v.writeJson(&w);
    try std.testing.expectEqualStrings("{\"a.b\":\"on\",\"n\":2,\"s\":[\"q\\\"\",true]}", w.buffered());
}
