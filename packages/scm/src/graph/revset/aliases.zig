//! Revset aliases: `name` (a symbol alias) or `name(params)` (a function
//! alias) mapped to a revset. They come from settings
//! (`scm.revset_aliases`, E15) and the repo's `config.zon`; callers `put`
//! them. User aliases replace the defaults (`immutable()`, `mutable()`,
//! `stack()`...). `expand` substitutes them, at most 32 levels deep, and
//! checks every remaining call against the built-in function table.

const std = @import("std");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const functions = @import("functions.zig");
const Node = ast.Node;
const ParseError = parser.ParseError;
const Allocator = std.mem.Allocator;

pub const max_expansion_depth = 32;

/// The default aliases, in `put` form.
pub const defaults = [_][2][]const u8{
    .{ "immutable_heads()", "trunk() | tags() | untracked_remote_bookmarks()" },
    .{ "immutable()", "::immutable_heads()" },
    .{ "mutable()", "~immutable()" },
    .{ "stack()", "stack(@)" },
    .{ "stack(x)", "(trunk()..x)::" },
};

pub const Alias = struct {
    name: []const u8,
    /// Null for a symbol alias.
    params: ?[]const []const u8,
    body: *Node,
    /// The source text, for messages.
    source: []const u8,
};

pub const Aliases = struct {
    arena_state: std.heap.ArenaAllocator,
    list: std.ArrayList(Alias) = .empty,

    pub fn init(gpa: Allocator) Aliases {
        return .{ .arena_state = .init(gpa) };
    }

    /// The defaults plus nothing else.
    pub fn withDefaults(gpa: Allocator) !Aliases {
        var a: Aliases = .init(gpa);
        errdefer a.deinit();
        var diag: ParseError = .{};
        for (defaults) |d| a.put(d[0], d[1], &diag) catch unreachable;
        return a;
    }

    pub fn deinit(a: *Aliases) void {
        a.arena_state.deinit();
    }

    /// Adds or replaces the alias declared by `decl` ("name" or
    /// "name(a, b)") with body `body`.
    pub fn put(a: *Aliases, decl: []const u8, body: []const u8, diag: *ParseError) parser.Error!void {
        const arena = a.arena_state.allocator();
        const d = std.mem.trim(u8, decl, " \t");
        var name = d;
        var params: ?[]const []const u8 = null;
        if (std.mem.indexOfScalar(u8, d, '(')) |lp| {
            if (d[d.len - 1] != ')') return declError(arena, diag, decl, "expected `)` at the end of the alias declaration");
            name = std.mem.trim(u8, d[0..lp], " \t");
            var ps: std.ArrayList([]const u8) = .empty;
            const inner = std.mem.trim(u8, d[lp + 1 .. d.len - 1], " \t");
            if (inner.len > 0) {
                var it = std.mem.splitScalar(u8, inner, ',');
                while (it.next()) |raw| {
                    const p = std.mem.trim(u8, raw, " \t");
                    if (!ast.isPlainSymbol(p)) return declError(arena, diag, decl, "alias parameters must be plain names");
                    for (ps.items) |q| if (std.mem.eql(u8, p, q)) return declError(arena, diag, decl, "repeated alias parameter");
                    try ps.append(arena, try arena.dupe(u8, p));
                }
            }
            params = ps.items;
        }
        if (!ast.isPlainSymbol(name)) return declError(arena, diag, decl, "alias names must be plain names");
        const src = try arena.dupe(u8, body);
        const tree = try parser.parse(arena, src, diag);
        const alias: Alias = .{ .name = try arena.dupe(u8, name), .params = params, .body = tree, .source = src };
        for (a.list.items) |*x| {
            if (sameDecl(x.*, alias)) {
                x.* = alias;
                return;
            }
        }
        try a.list.append(arena, alias);
    }

    fn sameDecl(x: Alias, y: Alias) bool {
        if (!std.mem.eql(u8, x.name, y.name)) return false;
        if ((x.params == null) != (y.params == null)) return false;
        return x.params == null or x.params.?.len == y.params.?.len;
    }

    fn findFunction(a: *const Aliases, name: []const u8, arity: usize) ?Alias {
        for (a.list.items) |x| {
            if (x.params) |ps| if (ps.len == arity and std.mem.eql(u8, x.name, name)) return x;
        }
        return null;
    }

    fn findSymbol(a: *const Aliases, name: []const u8) ?Alias {
        for (a.list.items) |x| if (x.params == null and std.mem.eql(u8, x.name, name)) return x;
        return null;
    }

    fn hasFunctionName(a: *const Aliases, name: []const u8) bool {
        for (a.list.items) |x| if (x.params != null and std.mem.eql(u8, x.name, name)) return true;
        return false;
    }

    /// Expands aliases in `n` (allocating in `arena`) and checks calls
    /// against the function table.
    pub fn expand(a: *const Aliases, arena: Allocator, n: *Node, diag: *ParseError) parser.Error!*Node {
        return a.expandIn(arena, n, &.{}, &.{}, 0, diag);
    }

    fn expandIn(
        a: *const Aliases,
        arena: Allocator,
        n: *Node,
        params: []const []const u8,
        args: []const *Node,
        depth: u32,
        diag: *ParseError,
    ) parser.Error!*Node {
        switch (n.kind) {
            .symbol => |s| {
                for (params, args) |p, arg| if (std.mem.eql(u8, p, s)) return arg;
                if (a.findSymbol(s)) |al| return a.substitute(arena, n, al, &.{}, depth, diag);
                return n;
            },
            .working_copy, .remote_symbol, .pattern, .all => return n,
            .call => |c| {
                const new_args = try arena.alloc(*Node, c.args.len);
                for (c.args, new_args) |x, *y| y.* = try a.expandIn(arena, x, params, args, depth, diag);
                if (a.findFunction(c.name, c.args.len)) |al| return a.substitute(arena, n, al, new_args, depth, diag);
                if (functions.find(c.name)) |b| {
                    if (c.args.len < b.min_args or c.args.len > b.max_args) {
                        diag.* = .{ .span = n.span, .message = try arityMessage(arena, b) };
                        return error.ParseFailed;
                    }
                } else if (a.hasFunctionName(c.name)) {
                    diag.* = .{ .span = n.span, .message = try std.fmt.allocPrint(arena, "alias `{s}` takes a different number of arguments", .{c.name}) };
                    return error.ParseFailed;
                } else {
                    var cands: std.ArrayList([]const u8) = .empty;
                    try cands.appendSlice(arena, &functions.names);
                    for (a.list.items) |x| if (x.params != null) try cands.append(arena, x.name);
                    diag.* = .{
                        .span = c.name_span,
                        .message = try std.fmt.allocPrint(arena, "unknown function `{s}`", .{c.name}),
                        .suggestion = parser.suggest(c.name, cands.items),
                    };
                    return error.ParseFailed;
                }
                const out = try arena.create(Node);
                out.* = .{ .span = n.span, .kind = .{ .call = .{ .name = c.name, .name_span = c.name_span, .args = new_args } } };
                return out;
            },
            .prefix => |p| return a.rebuild(arena, n, .{ .prefix = .{ .op = p.op, .operand = try a.expandIn(arena, p.operand, params, args, depth, diag) } }),
            .postfix => |p| return a.rebuild(arena, n, .{ .postfix = .{ .op = p.op, .operand = try a.expandIn(arena, p.operand, params, args, depth, diag) } }),
            .binary => |b| return a.rebuild(arena, n, .{ .binary = .{
                .op = b.op,
                .lhs = try a.expandIn(arena, b.lhs, params, args, depth, diag),
                .rhs = try a.expandIn(arena, b.rhs, params, args, depth, diag),
            } }),
        }
    }

    fn rebuild(_: *const Aliases, arena: Allocator, n: *Node, kind: Node.Kind) parser.Error!*Node {
        const out = try arena.create(Node);
        out.* = .{ .span = n.span, .kind = kind };
        return out;
    }

    fn substitute(a: *const Aliases, arena: Allocator, at: *Node, al: Alias, args: []const *Node, depth: u32, diag: *ParseError) parser.Error!*Node {
        if (depth + 1 > max_expansion_depth) {
            diag.* = .{ .span = at.span, .message = try std.fmt.allocPrint(arena, "alias expansion is more than {d} levels deep (is `{s}` recursive?)", .{ max_expansion_depth, al.name }) };
            return error.ParseFailed;
        }
        // The alias body sees only its own parameters; errors inside it
        // point at the use site.
        const out = a.expandIn(arena, al.body, al.params orelse &.{}, args, depth + 1, diag) catch |e| {
            if (e == error.ParseFailed) {
                if (!std.mem.startsWith(u8, diag.message, "in alias") and !std.mem.startsWith(u8, diag.message, "alias expansion"))
                    diag.message = try std.fmt.allocPrint(arena, "in alias `{s}`: {s}", .{ al.name, diag.message });
                diag.span = at.span;
            }
            return e;
        };
        return out;
    }
};

fn declError(arena: Allocator, diag: *ParseError, decl: []const u8, msg: []const u8) parser.Error {
    diag.* = .{ .span = .{ 0, @intCast(decl.len) }, .message = try arena.dupe(u8, msg) };
    return error.ParseFailed;
}

fn arityMessage(arena: Allocator, b: functions.Builtin) ![]const u8 {
    if (b.min_args == b.max_args) return std.fmt.allocPrint(arena, "`{s}` takes {d} argument{s}", .{ b.name, b.min_args, if (b.min_args == 1) "" else "s" });
    return std.fmt.allocPrint(arena, "`{s}` takes {d} to {d} arguments", .{ b.name, b.min_args, b.max_args });
}
