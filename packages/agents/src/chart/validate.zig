//! Strict JSON reading for chart specs (E13.F07.S01.T03): every error
//! names the JSON path it is about (`encoding.y.type: expected one of
//! quantitative|nominal|ordinal|temporal`), and unknown keys list the
//! allowed ones, so a model can correct its spec from the message alone.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const SpecError = error{ InvalidSpec, OutOfMemory };

/// Where a spec went wrong; `message` starts with the JSON path.
pub const Diagnostic = struct {
    message: []const u8 = "",
};

/// A JSON path under construction: keys joined by `.`, indexes as `[i]`.
pub const Path = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,

    pub fn text(p: *const Path) []const u8 {
        return if (p.len == 0) "(root)" else p.buf[0..p.len];
    }

    /// Appends a key; returns the length to restore.
    pub fn key(p: *Path, k: []const u8) usize {
        const old = p.len;
        const sep: []const u8 = if (p.len == 0) "" else ".";
        p.append(sep);
        p.append(k);
        return old;
    }

    pub fn index(p: *Path, i: usize) usize {
        const old = p.len;
        var tmp: [24]u8 = undefined;
        p.append(std.fmt.bufPrint(&tmp, "[{d}]", .{i}) catch unreachable);
        return old;
    }

    pub fn restore(p: *Path, old: usize) void {
        p.len = old;
    }

    fn append(p: *Path, s: []const u8) void {
        const n = @min(s.len, p.buf.len - p.len);
        @memcpy(p.buf[p.len..][0..n], s[0..n]);
        p.len += n;
    }
};

/// The reading context.
pub const Ctx = struct {
    arena: Allocator,
    diag: *Diagnostic,
    path: Path = .{},

    pub fn fail(c: *Ctx, comptime fmt: []const u8, args: anytype) SpecError {
        c.diag.message = std.fmt.allocPrint(c.arena, "{s}: " ++ fmt, .{c.path.text()} ++ args) catch return error.OutOfMemory;
        return error.InvalidSpec;
    }

    /// Fails at `path.k` instead of the current path.
    pub fn failAt(c: *Ctx, k: []const u8, comptime fmt: []const u8, args: anytype) SpecError {
        const old = c.path.key(k);
        defer c.path.restore(old);
        return c.fail(fmt, args);
    }

    /// `v` as an object whose keys are all in `allowed`.
    pub fn object(c: *Ctx, v: Value, comptime allowed: []const []const u8) SpecError!std.json.ObjectMap {
        if (v != .object) return c.fail("expected an object, found {s}", .{kind(v)});
        var it = v.object.iterator();
        while (it.next()) |e| {
            const k = e.key_ptr.*;
            for (allowed) |a| {
                if (std.mem.eql(u8, a, k)) break;
            } else return c.failAt(k, "unknown key; allowed: {s}", .{comptime join(allowed, ", ")});
        }
        return v.object;
    }

    pub fn string(c: *Ctx, v: Value) SpecError![]const u8 {
        return switch (v) {
            .string => |s| s,
            else => c.fail("expected a string, found {s}", .{kind(v)}),
        };
    }

    pub fn number(c: *Ctx, v: Value) SpecError!f64 {
        const x: f64 = switch (v) {
            .integer => |i| @floatFromInt(i),
            .float => |f| f,
            .number_string => |s| std.fmt.parseFloat(f64, s) catch return c.fail("expected a number", .{}),
            else => return c.fail("expected a number, found {s}", .{kind(v)}),
        };
        if (!std.math.isFinite(x)) return c.fail("expected a finite number", .{});
        return x;
    }

    /// A number in `[lo, hi]`.
    pub fn range(c: *Ctx, v: Value, lo: f64, hi: f64) SpecError!f64 {
        const x = try c.number(v);
        if (x < lo or x > hi) return c.fail("expected a number from {d} to {d}, found {d}", .{ lo, hi, x });
        return x;
    }

    pub fn boolean(c: *Ctx, v: Value) SpecError!bool {
        return switch (v) {
            .bool => |b| b,
            else => c.fail("expected true or false, found {s}", .{kind(v)}),
        };
    }

    /// A string naming one of `E`'s tags (`E.json_names` may rename tags).
    pub fn enumOf(c: *Ctx, comptime E: type, v: Value) SpecError!E {
        const names = comptime enumNames(E);
        if (v == .string) {
            inline for (names, 0..) |n, i| {
                if (std.mem.eql(u8, n, v.string)) return @enumFromInt(@typeInfo(E).@"enum".fields[i].value);
            }
        }
        return c.fail("expected one of {s}", .{comptime join(&names, "|")});
    }

    pub fn array(c: *Ctx, v: Value) SpecError![]const Value {
        return switch (v) {
            .array => |a| a.items,
            else => c.fail("expected an array, found {s}", .{kind(v)}),
        };
    }
};

/// JSON names of an enum's tags.
pub fn enumNames(comptime E: type) [@typeInfo(E).@"enum".fields.len][]const u8 {
    const fields = @typeInfo(E).@"enum".fields;
    var out: [fields.len][]const u8 = undefined;
    for (fields, 0..) |f, i| out[i] = if (@hasDecl(E, "json_names")) E.json_names[i] else f.name;
    return out;
}

pub fn join(comptime items: []const []const u8, comptime sep: []const u8) []const u8 {
    comptime {
        var s: []const u8 = "";
        for (items, 0..) |it, i| s = s ++ (if (i > 0) sep else "") ++ it;
        return s;
    }
}

pub fn kind(v: Value) []const u8 {
    return switch (v) {
        .null => "null",
        .bool => "a boolean",
        .integer, .float, .number_string => "a number",
        .string => "a string",
        .array => "an array",
        .object => "an object",
    };
}

/// Parses JSON text, reporting syntax errors with line and column.
pub fn parseJson(arena: Allocator, json: []const u8, diag: *Diagnostic) SpecError!Value {
    var scanner: std.json.Scanner = .initCompleteInput(arena, json);
    var jd: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&jd);
    return std.json.parseFromTokenSourceLeaky(Value, arena, &scanner, .{ .duplicate_field_behavior = .@"error" }) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.DuplicateField => {
            diag.message = try std.fmt.allocPrint(arena, "(root): duplicate key at line {d}, column {d}", .{ jd.getLine(), jd.getColumn() });
            return error.InvalidSpec;
        },
        else => {
            diag.message = try std.fmt.allocPrint(arena, "(root): invalid JSON at line {d}, column {d}", .{ jd.getLine(), jd.getColumn() });
            return error.InvalidSpec;
        },
    };
}
