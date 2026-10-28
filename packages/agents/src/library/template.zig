//! The prompt template language (E13.F08.S02.T01), deliberately small
//! (docs/formats/prompts.md): `{{name}}`, `{{name|default:"x"}}`, inline
//! hints `{{name|choice:a,b,c}}`, `{{#if name}}…{{/if}}`,
//! `{{#if name == "x"}}…{{else}}…{{/if}}`, the context values
//! `{{selection}}`, `{{file}}`, `{{date}}`, `{{clipboard}}`, and `\{{` for
//! a literal `{{`. No loops, no code. Std only.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const VarKind = enum { text, multiline, choice, number, bool, path, selection };

pub const VarDecl = struct {
    name: []const u8,
    kind: VarKind = .text,
    options: []const []const u8 = &.{},
    default: ?[]const u8 = null,
    required: bool = false,
};

pub const Var = struct { name: []const u8, value: []const u8 };

/// Values the editor fills in; `clipboard` is only read after the user
/// agreed (the picker asks first).
pub const RenderCtx = struct {
    selection: ?[]const u8 = null,
    file: ?[]const u8 = null,
    date: ?[]const u8 = null,
    clipboard: ?[]const u8 = null,
};

pub const context_names = [_][]const u8{ "selection", "file", "date", "clipboard" };

pub fn isContextName(name: []const u8) bool {
    for (context_names) |c| if (std.mem.eql(u8, c, name)) return true;
    return false;
}

pub const ParseError = error{ UnclosedTag, UnclosedIf, UnexpectedTag, BadTag, OutOfMemory };

pub const Cond = struct {
    name: []const u8,
    /// `== "x"`; null tests truthiness.
    equals: ?[]const u8,
    then: []const Node,
    else_: []const Node,
};

pub const VarRef = struct {
    name: []const u8,
    default: ?[]const u8 = null,
    /// An inline `|choice:a,b` hint.
    choices: []const []const u8 = &.{},
};

pub const Node = union(enum) {
    text: []const u8,
    var_: VarRef,
    cond: Cond,
};

pub const Template = struct {
    nodes: []const Node,
};

/// Where parsing stopped, for diagnostics.
pub const ParseDiag = struct { offset: usize = 0 };

pub fn parse(arena: Allocator, src: []const u8, diag: ?*ParseDiag) ParseError!Template {
    var p: Parser = .{ .arena = arena, .src = src, .diag = diag };
    const r = try p.nodes(false);
    if (r.end != .eof) return p.fail(error.UnexpectedTag);
    return .{ .nodes = r.nodes };
}

const End = enum { eof, else_, endif };

const Parser = struct {
    arena: Allocator,
    src: []const u8,
    pos: usize = 0,
    diag: ?*ParseDiag,

    fn fail(p: *Parser, e: ParseError) ParseError {
        if (p.diag) |d| d.offset = p.pos;
        return e;
    }

    fn nodes(p: *Parser, in_if: bool) ParseError!struct { nodes: []const Node, end: End } {
        var out: std.ArrayList(Node) = .empty;
        var text: std.ArrayList(u8) = .empty;
        while (p.pos < p.src.len) {
            const rest = p.src[p.pos..];
            if (std.mem.startsWith(u8, rest, "\\{{")) {
                try text.appendSlice(p.arena, "{{");
                p.pos += 3;
                continue;
            }
            if (!std.mem.startsWith(u8, rest, "{{")) {
                try text.append(p.arena, rest[0]);
                p.pos += 1;
                continue;
            }
            const close = std.mem.indexOfPos(u8, p.src, p.pos + 2, "}}") orelse return p.fail(error.UnclosedTag);
            const tag = std.mem.trim(u8, p.src[p.pos + 2 .. close], " \t");
            const tag_start = p.pos;
            p.pos = close + 2;
            if (text.items.len > 0) {
                try out.append(p.arena, .{ .text = text.items });
                text = .empty;
            }
            if (std.mem.startsWith(u8, tag, "#if")) {
                try out.append(p.arena, .{ .cond = try p.cond(tag[3..], tag_start) });
            } else if (std.mem.eql(u8, tag, "else")) {
                if (!in_if) return p.failAt(error.UnexpectedTag, tag_start);
                return .{ .nodes = out.items, .end = .else_ };
            } else if (std.mem.eql(u8, tag, "/if")) {
                if (!in_if) return p.failAt(error.UnexpectedTag, tag_start);
                return .{ .nodes = out.items, .end = .endif };
            } else {
                try out.append(p.arena, .{ .var_ = try p.varRef(tag, tag_start) });
            }
        }
        if (text.items.len > 0) try out.append(p.arena, .{ .text = text.items });
        if (in_if) return p.fail(error.UnclosedIf);
        return .{ .nodes = out.items, .end = .eof };
    }

    fn failAt(p: *Parser, e: ParseError, at: usize) ParseError {
        p.pos = at;
        return p.fail(e);
    }

    fn cond(p: *Parser, rest0: []const u8, at: usize) ParseError!Cond {
        const rest = std.mem.trim(u8, rest0, " \t");
        var name = rest;
        var equals: ?[]const u8 = null;
        if (std.mem.indexOf(u8, rest, "==")) |eq| {
            name = std.mem.trim(u8, rest[0..eq], " \t");
            equals = unquote(std.mem.trim(u8, rest[eq + 2 ..], " \t")) orelse return p.failAt(error.BadTag, at);
        }
        if (!validName(name)) return p.failAt(error.BadTag, at);
        const then = try p.nodes(true);
        var else_: []const Node = &.{};
        if (then.end == .else_) {
            const e = try p.nodes(true);
            if (e.end != .endif) return p.failAt(error.UnexpectedTag, at);
            else_ = e.nodes;
        }
        return .{ .name = name, .equals = equals, .then = then.nodes, .else_ = else_ };
    }

    fn varRef(p: *Parser, tag: []const u8, at: usize) ParseError!VarRef {
        const bar = std.mem.indexOfScalar(u8, tag, '|');
        const name = std.mem.trim(u8, tag[0 .. bar orelse tag.len], " \t");
        if (!validName(name)) return p.failAt(error.BadTag, at);
        var r: VarRef = .{ .name = name };
        if (bar) |b| {
            const filter = std.mem.trim(u8, tag[b + 1 ..], " \t");
            if (std.mem.startsWith(u8, filter, "default:")) {
                r.default = unquote(std.mem.trim(u8, filter["default:".len..], " \t")) orelse return p.failAt(error.BadTag, at);
            } else if (std.mem.startsWith(u8, filter, "choice:")) {
                var list: std.ArrayList([]const u8) = .empty;
                var it = std.mem.splitScalar(u8, filter["choice:".len..], ',');
                while (it.next()) |c| {
                    const t = std.mem.trim(u8, c, " \t");
                    if (t.len > 0) try list.append(p.arena, t);
                }
                if (list.items.len == 0) return p.failAt(error.BadTag, at);
                r.choices = list.items;
            } else return p.failAt(error.BadTag, at);
        }
        return r;
    }
};

/// `"x"` or a bare word.
fn unquote(s: []const u8) ?[]const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') return s[1 .. s.len - 1];
    if (s.len == 0) return null;
    for (s) |c| if (c == '"' or c == ' ') return null;
    return s;
}

fn validName(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-' and c != '.') return false;
    return true;
}

/// The variables a template asks for: `declared` (frontmatter) first, then
/// names only the body uses, in order of first use. An inline choice hint
/// declares a choice variable (or adds options to a declared one without
/// any); an undeclared `{{x}}` is a required text variable, unless it has a
/// default or names a context value.
pub fn variables(arena: Allocator, t: Template, declared: []const VarDecl) Allocator.Error![]const VarDecl {
    var out: std.ArrayList(VarDecl) = .empty;
    try out.appendSlice(arena, declared);
    try collect(arena, t.nodes, &out);
    return out.items;
}

fn collect(arena: Allocator, nodes: []const Node, out: *std.ArrayList(VarDecl)) Allocator.Error!void {
    for (nodes) |n| switch (n) {
        .text => {},
        .var_ => |v| {
            if (indexOf(out.items, v.name)) |i| {
                const d = &out.items[i];
                if (v.choices.len > 0 and d.options.len == 0) {
                    d.options = v.choices;
                    if (d.kind == .text) d.kind = .choice;
                }
                if (d.default == null) d.default = v.default;
                continue;
            }
            if (isContextName(v.name)) continue;
            try out.append(arena, .{
                .name = v.name,
                .kind = if (v.choices.len > 0) .choice else .text,
                .options = v.choices,
                .default = v.default,
                .required = v.default == null,
            });
        },
        .cond => |c| {
            if (indexOf(out.items, c.name) == null and !isContextName(c.name)) {
                try out.append(arena, .{ .name = c.name, .kind = if (c.equals == null) .bool else .text });
            }
            try collect(arena, c.then, out);
            try collect(arena, c.else_, out);
        },
    };
}

fn indexOf(decls: []const VarDecl, name: []const u8) ?usize {
    for (decls, 0..) |d, i| if (std.mem.eql(u8, d.name, name)) return i;
    return null;
}

pub const Invalid = struct { name: []const u8, reason: []const u8 };

pub const Rendered = struct {
    text: []const u8,
    /// Required variables with no value.
    missing: []const []const u8,
    /// Values that do not fit their declaration (choice, number, bool).
    invalid: []const Invalid,

    pub fn ok(r: Rendered) bool {
        return r.missing.len == 0 and r.invalid.len == 0;
    }
};

/// Renders `src` with `decls` (frontmatter declarations), `values` and the
/// editor context. Missing or invalid values are reported, and render as
/// their default (or empty).
pub fn render(arena: Allocator, src: []const u8, decls: []const VarDecl, values: []const Var, ctx: RenderCtx) ParseError!Rendered {
    const t = try parse(arena, src, null);
    const vars = try variables(arena, t, decls);
    var missing: std.ArrayList([]const u8) = .empty;
    var invalid: std.ArrayList(Invalid) = .empty;
    for (vars) |d| {
        const v = lookupVar(values, d.name);
        if (v == null or v.?.len == 0) {
            if (d.required and d.default == null and !(d.kind == .selection and ctx.selection != null)) try missing.append(arena, d.name);
            continue;
        }
        if (check(d, v.?)) |reason| try invalid.append(arena, .{ .name = d.name, .reason = reason });
    }
    var out: std.Io.Writer.Allocating = .init(arena);
    const e: Env = .{ .decls = vars, .values = values, .ctx = ctx };
    e.emit(&out.writer, t.nodes) catch return error.OutOfMemory;
    return .{ .text = out.written(), .missing = missing.items, .invalid = invalid.items };
}

fn check(d: VarDecl, v: []const u8) ?[]const u8 {
    return switch (d.kind) {
        .choice => blk: {
            if (d.options.len == 0) break :blk null;
            for (d.options) |o| if (std.mem.eql(u8, o, v)) break :blk null;
            break :blk "not one of the choices";
        },
        .number => if (std.fmt.parseFloat(f64, v)) |_| null else |_| "not a number",
        .bool => if (parseBool(v) == null) "not true or false" else null,
        else => null,
    };
}

fn parseBool(v: []const u8) ?bool {
    for ([_][]const u8{ "true", "yes", "on", "1" }) |t| if (std.ascii.eqlIgnoreCase(v, t)) return true;
    for ([_][]const u8{ "false", "no", "off", "0" }) |f| if (std.ascii.eqlIgnoreCase(v, f)) return false;
    return null;
}

fn lookupVar(values: []const Var, name: []const u8) ?[]const u8 {
    for (values) |v| if (std.mem.eql(u8, v.name, name)) return v.value;
    return null;
}

const Env = struct {
    decls: []const VarDecl,
    values: []const Var,
    ctx: RenderCtx,

    fn value(e: Env, name: []const u8, inline_default: ?[]const u8) []const u8 {
        if (lookupVar(e.values, name)) |v| if (v.len > 0) return v;
        if (std.mem.eql(u8, name, "selection")) if (e.ctx.selection) |s| return s;
        if (std.mem.eql(u8, name, "file")) if (e.ctx.file) |s| return s;
        if (std.mem.eql(u8, name, "date")) if (e.ctx.date) |s| return s;
        if (std.mem.eql(u8, name, "clipboard")) if (e.ctx.clipboard) |s| return s;
        if (inline_default) |d| return d;
        if (indexOf(e.decls, name)) |i| if (e.decls[i].default) |d| return d;
        return "";
    }

    fn emit(e: Env, w: *std.Io.Writer, nodes: []const Node) std.Io.Writer.Error!void {
        for (nodes) |n| switch (n) {
            .text => |s| try w.writeAll(s),
            .var_ => |v| try w.writeAll(e.value(v.name, v.default)),
            .cond => |c| {
                const v = e.value(c.name, null);
                const yes = if (c.equals) |x| std.mem.eql(u8, v, x) else truthy(v);
                try e.emit(w, if (yes) c.then else c.else_);
            },
        };
    }
};

fn truthy(v: []const u8) bool {
    if (v.len == 0) return false;
    return parseBool(v) orelse true;
}

/// The `{{…}}` names `text` uses, for "Save prompt" (a transcript message
/// becomes an entry with these as its variables). Invalid templates give
/// none.
pub fn detectVariables(arena: Allocator, text: []const u8) Allocator.Error![]const VarDecl {
    const t = parse(arena, text, null) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    return variables(arena, t, &.{});
}
