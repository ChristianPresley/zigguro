//! JSONPath-lite (E13.F08.S01.T01): how workflow steps read earlier
//! results. Grammar:
//!
//! ```
//! path    = root seg*
//! root    = "$" | "$." key | "$args" | "$item" | "$index" | "$" name
//! seg     = "." key | "[" digits "]" | "[*]"
//! key     = [A-Za-z_][A-Za-z0-9_-]*
//! ```
//!
//! `$.plan.subquestions[0].q` reads step `plan`'s result; `$args.name` an
//! argument; `$item`/`$index` (or the map's `as` name) the current map
//! item. `[*]` iterates an array and flattens: `$.research[*].findings[*]`
//! is every finding of every researcher. A missing key or index yields
//! nothing (never an error). Std only.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Root = union(enum) {
    /// `$` alone: the whole scope (every step result).
    all,
    /// `$.id`: step `id`'s result.
    step: []const u8,
    args,
    item,
    index,
    /// `$name`: a map's `as` binding (same as `$item` inside that map).
    binding: []const u8,
};

pub const Seg = union(enum) {
    key: []const u8,
    index: u32,
    wildcard,
};

pub const Error = error{ InvalidPath, OutOfMemory };

/// The scope keys the engine puts next to step results.
pub const args_key = "$args";
pub const item_key = "$item";
pub const index_key = "$index";

pub const Path = struct {
    root: Root,
    segs: []const Seg,
    text: []const u8,

    /// Parses `s`; `diag_at` gets the byte offset of the problem.
    pub fn compile(arena: Allocator, s: []const u8) Error!Path {
        return compileDiag(arena, s, null);
    }

    pub fn compileDiag(arena: Allocator, s: []const u8, diag_at: ?*usize) Error!Path {
        var p: Parser = .{ .s = s, .diag = diag_at };
        if (s.len == 0 or s[0] != '$') return p.fail(0);
        var i: usize = 1;
        var root: Root = .all;
        if (i < s.len and s[i] == '.') {
            i += 1;
            const k = p.key(&i) orelse return p.fail(i);
            root = .{ .step = k };
        } else if (i < s.len and isKeyStart(s[i])) {
            const k = p.key(&i) orelse return p.fail(i);
            root = if (std.mem.eql(u8, k, "args")) .args else if (std.mem.eql(u8, k, "item")) .item else if (std.mem.eql(u8, k, "index")) .index else .{ .binding = k };
        }
        var segs: std.ArrayList(Seg) = .empty;
        while (i < s.len) {
            switch (s[i]) {
                '.' => {
                    i += 1;
                    const k = p.key(&i) orelse return p.fail(i);
                    try segs.append(arena, .{ .key = k });
                },
                '[' => {
                    i += 1;
                    if (i < s.len and s[i] == '*') {
                        i += 1;
                        try segs.append(arena, .wildcard);
                    } else {
                        const st = i;
                        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
                        if (i == st or i - st > 9) return p.fail(st);
                        try segs.append(arena, .{ .index = std.fmt.parseInt(u32, s[st..i], 10) catch return p.fail(st) });
                    }
                    if (i >= s.len or s[i] != ']') return p.fail(i);
                    i += 1;
                },
                else => return p.fail(i),
            }
        }
        if (root == .index and segs.items.len > 0) return p.fail(s.len);
        return .{ .root = root, .segs = segs.items, .text = s };
    }

    /// Whether evaluation can give more than one value.
    pub fn multi(p: *const Path) bool {
        for (p.segs) |sg| if (sg == .wildcard) return true;
        return false;
    }

    /// The step this path reads, if any.
    pub fn stepId(p: *const Path) ?[]const u8 {
        return switch (p.root) {
            .step => |s| s,
            else => null,
        };
    }

    /// Appends the values at this path in `scope` (an object holding step
    /// results by id plus `$args`, `$item`, `$index` and bindings) to
    /// `out`. Values are borrowed from `scope`.
    pub fn eval(p: *const Path, scope: Value, out: *std.ArrayList(Value), gpa: Allocator) Allocator.Error!void {
        const start: Value = switch (p.root) {
            .all => scope,
            .step => |id| lookup(scope, id) orelse return,
            .args => lookup(scope, args_key) orelse return,
            .item => lookup(scope, item_key) orelse return,
            .index => lookup(scope, index_key) orelse return,
            .binding => |b| lookup(scope, b) orelse lookup(scope, item_key) orelse return,
        };
        try walk(start, p.segs, out, gpa);
    }

    /// The single value at this path, or null (first match for wildcards).
    pub fn first(p: *const Path, scope: Value, gpa: Allocator) Allocator.Error!?Value {
        var out: std.ArrayList(Value) = .empty;
        defer out.deinit(gpa);
        try p.eval(scope, &out, gpa);
        return if (out.items.len > 0) out.items[0] else null;
    }

    /// The value as one JSON value: the single match, an array of all
    /// matches for wildcard paths, or null when nothing matched.
    pub fn value(p: *const Path, scope: Value, arena: Allocator) Allocator.Error!Value {
        var out: std.ArrayList(Value) = .empty;
        try p.eval(scope, &out, arena);
        if (p.multi()) {
            var arr: std.json.Array = .init(arena);
            try arr.appendSlice(out.items);
            return .{ .array = arr };
        }
        return if (out.items.len > 0) out.items[0] else .null;
    }
};

fn lookup(v: Value, key: []const u8) ?Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn walk(v: Value, segs: []const Seg, out: *std.ArrayList(Value), gpa: Allocator) Allocator.Error!void {
    if (segs.len == 0) return out.append(gpa, v);
    switch (segs[0]) {
        .key => |k| if (lookup(v, k)) |x| try walk(x, segs[1..], out, gpa),
        .index => |i| switch (v) {
            .array => |a| if (i < a.items.len) try walk(a.items[i], segs[1..], out, gpa),
            else => {},
        },
        .wildcard => switch (v) {
            .array => |a| for (a.items) |x| try walk(x, segs[1..], out, gpa),
            .object => |o| {
                var it = o.iterator();
                while (it.next()) |e| try walk(e.value_ptr.*, segs[1..], out, gpa);
            },
            else => {},
        },
    }
}

const Parser = struct {
    s: []const u8,
    diag: ?*usize,

    fn fail(p: *Parser, at: usize) Error {
        if (p.diag) |d| d.* = at;
        return error.InvalidPath;
    }

    fn key(p: *Parser, i: *usize) ?[]const u8 {
        const st = i.*;
        if (st >= p.s.len or !isKeyStart(p.s[st])) return null;
        var j = st + 1;
        while (j < p.s.len and (std.ascii.isAlphanumeric(p.s[j]) or p.s[j] == '_' or p.s[j] == '-')) j += 1;
        i.* = j;
        return p.s[st..j];
    }
};

fn isKeyStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

/// Whether `s` looks like a path (starts with `$`).
pub fn isPath(s: []const u8) bool {
    return s.len > 0 and s[0] == '$';
}

/// JavaScript-like truthiness for `when` conditions: null, false, 0, ""
/// and empty arrays/objects are false.
pub fn truthy(v: Value) bool {
    return switch (v) {
        .null => false,
        .bool => |b| b,
        .integer => |i| i != 0,
        .float => |f| f != 0,
        .number_string => |s| !std.mem.eql(u8, s, "0"),
        .string => |s| s.len > 0,
        .array => |a| a.items.len > 0,
        .object => |o| o.count() > 0,
    };
}
