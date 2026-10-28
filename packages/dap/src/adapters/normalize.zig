//! Launch and attach argument fixes per adapter (E07.F06.S01.T04):
//! configurations written for one adapter often carry another's shapes.
//! `env` is an object for gdb, debugpy and js-debug and a `["K=V"]` array
//! for lldb-dap; `args` is an array everywhere (a string is split like a
//! POSIX shell would, quotes and backslashes included).

const std = @import("std");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

pub const Request = @import("../config/LaunchConfig.zig").Request;

pub const EnvShape = enum { object, array };

/// Rewrites `env` to `shape` and a string `args` to an array.
pub fn common(a: Allocator, args: *ObjectMap, shape: EnvShape) Allocator.Error!void {
    if (args.getPtr("env")) |env| {
        const v = try envAs(a, env.*, shape);
        env.* = v;
    }
    if (args.getPtr("args")) |v| if (v.* == .string) {
        const words = try splitArgs(a, v.string);
        v.* = .{ .array = words };
    };
}

/// `env` as an object (`{"K": "V"}`) or array (`["K=V"]`); other values
/// are left alone. Null values in an object (unset) are dropped from the
/// array form.
pub fn envAs(a: Allocator, env: Value, shape: EnvShape) Allocator.Error!Value {
    switch (shape) {
        .object => {
            if (env != .array) return env;
            var m: ObjectMap = .empty;
            for (env.array.items) |e| {
                if (e != .string) continue;
                const eq = std.mem.indexOfScalar(u8, e.string, '=') orelse {
                    try m.put(a, e.string, .{ .string = "" });
                    continue;
                };
                try m.put(a, e.string[0..eq], .{ .string = e.string[eq + 1 ..] });
            }
            return .{ .object = m };
        },
        .array => {
            if (env != .object) return env;
            var arr: std.json.Array = .init(a);
            var it = env.object.iterator();
            while (it.next()) |kv| {
                const val: []const u8 = switch (kv.value_ptr.*) {
                    .string => |s| s,
                    .null => continue,
                    .integer => |i| try std.fmt.allocPrint(a, "{d}", .{i}),
                    .bool => |b| if (b) "true" else "false",
                    else => continue,
                };
                try arr.append(.{ .string = try std.mem.concat(a, u8, &.{ kv.key_ptr.*, "=", val }) });
            }
            return .{ .array = arr };
        },
    }
}

/// Splits a command line into words: whitespace separates, single
/// quotes keep everything, double quotes keep all but `\"` and `\\`, a
/// backslash outside quotes escapes the next character.
pub fn splitArgs(a: Allocator, line: []const u8) Allocator.Error!std.json.Array {
    var out: std.json.Array = .init(a);
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        switch (c) {
            ' ', '\t', '\n', '\r' => {
                if (in_word) {
                    try out.append(.{ .string = try word.toOwnedSlice(a) });
                    in_word = false;
                }
            },
            '\'' => {
                in_word = true;
                const end = std.mem.indexOfScalarPos(u8, line, i + 1, '\'') orelse line.len;
                try word.appendSlice(a, line[i + 1 .. end]);
                i = end;
            },
            '"' => {
                in_word = true;
                i += 1;
                while (i < line.len and line[i] != '"') : (i += 1) {
                    if (line[i] == '\\' and i + 1 < line.len and (line[i + 1] == '"' or line[i + 1] == '\\')) i += 1;
                    try word.append(a, line[i]);
                }
            },
            '\\' => {
                in_word = true;
                if (i + 1 < line.len) {
                    i += 1;
                    try word.append(a, line[i]);
                }
            },
            else => {
                in_word = true;
                try word.append(a, c);
            },
        }
    }
    if (in_word) try out.append(.{ .string = try word.toOwnedSlice(a) });
    return out;
}

pub fn lldbDap(a: Allocator, _: Request, args: *ObjectMap) anyerror!void {
    try common(a, args, .array);
}

pub fn gdb(a: Allocator, _: Request, args: *ObjectMap) anyerror!void {
    try common(a, args, .object);
}

pub fn debugpy(a: Allocator, _: Request, args: *ObjectMap) anyerror!void {
    try common(a, args, .object);
}

pub fn jsDebug(a: Allocator, _: Request, args: *ObjectMap) anyerror!void {
    try common(a, args, .object);
}
