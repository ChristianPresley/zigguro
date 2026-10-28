//! Loading workflow files (E13.F08.S01.T01): `std.zon.parse` into the
//! `def.zig` structs (unknown fields are errors), then `validate.zig`.
//! Problems are collected as `Diagnostics` with a line and column for
//! syntax errors and the step for validation errors.

const std = @import("std");
const def = @import("def.zig");
const validate_mod = @import("validate.zig");

const Allocator = std.mem.Allocator;

pub const Diag = struct {
    /// 1-based; 0 when the problem has no position (validation).
    line: u32 = 0,
    column: u32 = 0,
    /// The step id the problem is about ("" for the workflow itself).
    step: []const u8 = "",
    message: []const u8,
};

pub const Diagnostics = struct {
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Diag) = .empty,

    pub fn init(gpa: Allocator) Diagnostics {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(d: *Diagnostics) void {
        d.arena.deinit();
    }

    pub fn add(d: *Diagnostics, step: []const u8, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const a = d.arena.allocator();
        try d.items.append(a, .{ .step = try a.dupe(u8, step), .message = try std.fmt.allocPrint(a, fmt, args) });
    }

    pub fn addAt(d: *Diagnostics, line: u32, column: u32, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const a = d.arena.allocator();
        try d.items.append(a, .{ .line = line, .column = column, .message = try std.fmt.allocPrint(a, fmt, args) });
    }

    pub fn count(d: *const Diagnostics) usize {
        return d.items.items.len;
    }

    /// `file:line:col: message` or `file: step "x": message`, one per line.
    pub fn format(d: *const Diagnostics, file: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (d.items.items) |x| {
            if (x.line != 0) {
                try w.print("{s}:{d}:{d}: {s}\n", .{ file, x.line, x.column, x.message });
            } else if (x.step.len > 0) {
                try w.print("{s}: step \"{s}\": {s}\n", .{ file, x.step, x.message });
            } else try w.print("{s}: {s}\n", .{ file, x.message });
        }
    }
};

/// A parsed definition and the memory that holds it.
pub const Parsed = struct {
    arena: *std.heap.ArenaAllocator,
    def: def.WorkflowDef,

    pub fn deinit(p: *Parsed) void {
        const gpa = p.arena.child_allocator;
        p.arena.deinit();
        gpa.destroy(p.arena);
    }
};

pub const Error = error{ ParseZon, Invalid } || Allocator.Error;

/// Parses `src` without validating it.
pub fn parseOnly(gpa: Allocator, src: [:0]const u8, diags: *Diagnostics) Error!Parsed {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = .init(gpa);
    errdefer {
        arena.deinit();
        gpa.destroy(arena);
    }
    var zd: std.zon.parse.Diagnostics = .{};
    defer zd.deinit(arena.allocator());
    const d = std.zon.parse.fromSliceAlloc(def.WorkflowDef, arena.allocator(), src, &zd, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            var it = zd.iterateErrors();
            while (it.next()) |err| {
                const loc = err.getLocation(&zd);
                var msg: std.Io.Writer.Allocating = .init(diags.arena.allocator());
                msg.writer.print("{f}", .{err.fmtMessage(&zd)}) catch return error.OutOfMemory;
                try diags.addAt(@intCast(loc.line + 1), @intCast(loc.column + 1), "{s}", .{msg.written()});
            }
            return error.ParseZon;
        },
    };
    return .{ .arena = arena, .def = d };
}

/// Parses and validates `src`. On `error.Invalid` the diagnostics say why.
pub fn parseDef(gpa: Allocator, src: [:0]const u8, env: validate_mod.ValidateEnv, diags: *Diagnostics) Error!Parsed {
    var p = try parseOnly(gpa, src, diags);
    errdefer p.deinit();
    const before = diags.count();
    try validate_mod.validate(&p.def, env, diags);
    if (diags.count() > before) return error.Invalid;
    return p;
}
