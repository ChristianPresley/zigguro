//! ZON with open-ended parts (a launch configuration's adapter `args`)
//! as a `std.json.Value`, and back (E07.F06.S01.T02). Typed
//! `std.zon.parse` cannot describe an object whose keys are the
//! adapter's, so the text goes through `std.zig.Ast` (mode `.zon`) and
//! `std.zig.ZonGen` to ZOIR, which is walked into a dynamic value:
//! structs are objects, tuples arrays, `.{}` an empty object (readers
//! take it as an empty array where one is expected), enum literals
//! strings, characters integers. Errors carry a 1-based line and column.

const std = @import("std");
const Ast = std.zig.Ast;
const Zoir = std.zig.Zoir;

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Where and why a ZON text is not valid.
pub const ZonError = struct {
    line: u32,
    column: u32,
    message: []const u8,
};

/// `src` as a dynamic value, in `arena`; on a syntax or ZON error, null
/// with `err` set.
pub fn parse(arena: Allocator, src: [:0]const u8, err: *ZonError) Allocator.Error!?Value {
    var tree = try Ast.parse(arena, src, .zon);
    defer tree.deinit(arena);
    const zoir = try std.zig.ZonGen.generate(arena, tree, .{});
    defer zoir.deinit(arena);
    if (zoir.hasCompileErrors()) {
        const e = zoir.compile_errors[0];
        const loc = if (e.token.unwrap()) |tok|
            tree.tokenLocation(0, tok)
        else
            tree.tokenLocation(0, tree.firstToken(@enumFromInt(e.node_or_offset)));
        const extra: u32 = if (e.token != .none) e.node_or_offset else 0;
        err.* = .{ .line = @intCast(loc.line + 1), .column = @intCast(loc.column + 1 + extra), .message = try arena.dupe(u8, e.msg.get(zoir)) };
        return null;
    }
    return try walk(arena, zoir, .root);
}

/// The same as `parse`, for callers that only want a value (the
/// interface of E07.F06.S01.T02): `error.InvalidZon` on errors.
pub fn zonToJson(arena: Allocator, src: [:0]const u8) error{ OutOfMemory, InvalidZon }!Value {
    var e: ZonError = undefined;
    return (try parse(arena, src, &e)) orelse error.InvalidZon;
}

fn walk(a: Allocator, zoir: Zoir, idx: Zoir.Node.Index) Allocator.Error!Value {
    return switch (idx.get(zoir)) {
        .true => .{ .bool = true },
        .false => .{ .bool = false },
        .null => .null,
        .pos_inf => .{ .float = std.math.inf(f64) },
        .neg_inf => .{ .float = -std.math.inf(f64) },
        .nan => .{ .float = std.math.nan(f64) },
        .int_literal => |i| switch (i) {
            .small => |x| .{ .integer = x },
            .big => |big| if (big.toInt(i64)) |x| .{ .integer = x } else |_| .{ .number_string = try big.toStringAlloc(a, 10, .lower) },
        },
        .float_literal => |f| .{ .float = @floatCast(f) },
        .char_literal => |c| .{ .integer = c },
        .enum_literal => |s| .{ .string = try a.dupe(u8, s.get(zoir)) },
        .string_literal => |s| .{ .string = try a.dupe(u8, s) },
        .empty_literal => .{ .object = .empty },
        .array_literal => |r| blk: {
            var arr: std.json.Array = try .initCapacity(a, r.len);
            for (0..r.len) |i| arr.appendAssumeCapacity(try walk(a, zoir, r.at(@intCast(i))));
            break :blk .{ .array = arr };
        },
        .struct_literal => |st| blk: {
            var m: std.json.ObjectMap = .empty;
            try m.ensureTotalCapacity(a, st.names.len);
            for (st.names, 0..) |n, i| m.putAssumeCapacity(try a.dupe(u8, n.get(zoir)), try walk(a, zoir, st.vals.at(@intCast(i))));
            break :blk .{ .object = m };
        },
    };
}

/// Writes `v` as ZON at `indent` levels (four spaces each). Object keys
/// that are not identifiers are written `.@"key"`; `enum_keys` lists keys
/// whose string values are written as enum literals (`.request = .launch`).
pub fn write(w: *std.Io.Writer, v: Value, indent: usize, enum_keys: []const []const u8) std.Io.Writer.Error!void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| {
            if (std.math.isNan(f)) return w.writeAll("nan");
            if (std.math.isInf(f)) return w.writeAll(if (f > 0) "inf" else "-inf");
            if (@floor(f) == f and @abs(f) < 1e15) return w.print("{d}.0", .{f});
            try w.print("{d}", .{f});
        },
        .number_string => |s| try w.writeAll(s),
        .string => |s| try w.print("\"{f}\"", .{std.zig.fmtString(s)}),
        .array => |arr| {
            if (arr.items.len == 0) return w.writeAll(".{}");
            try w.writeAll(".{\n");
            for (arr.items) |item| {
                try w.splatByteAll(' ', (indent + 1) * 4);
                try write(w, item, indent + 1, enum_keys);
                try w.writeAll(",\n");
            }
            try w.splatByteAll(' ', indent * 4);
            try w.writeAll("}");
        },
        .object => |m| {
            if (m.count() == 0) return w.writeAll(".{}");
            try w.writeAll(".{\n");
            var it = m.iterator();
            while (it.next()) |kv| {
                try w.splatByteAll(' ', (indent + 1) * 4);
                try w.print(".{f} = ", .{std.zig.fmtIdPU(kv.key_ptr.*)});
                const as_enum = kv.value_ptr.* == .string and std.zig.isValidId(kv.value_ptr.string) and for (enum_keys) |k| {
                    if (std.mem.eql(u8, k, kv.key_ptr.*)) break true;
                } else false;
                if (as_enum) {
                    try w.print(".{s}", .{kv.value_ptr.string});
                } else try write(w, kv.value_ptr.*, indent + 1, enum_keys);
                try w.writeAll(",\n");
            }
            try w.splatByteAll(' ', indent * 4);
            try w.writeAll("}");
        },
    }
}
