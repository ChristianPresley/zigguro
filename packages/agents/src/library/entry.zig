//! Prompt library entries (E13.F08.S02.T01): a Markdown file whose
//! frontmatter names it and declares its variables, e.g.
//! `.zigguro/prompts/research/lead.md`:
//!
//! ```
//! ---
//! title: Research lead planner
//! description: Decompose a research question into sub-questions
//! tags: [research, planning]
//! variables:
//!   - {name: question, type: text, required: true}
//!   - {name: effort, type: choice, options: [quick, standard, deep], default: standard}
//! ---
//! You are the lead researcher... {{question}}
//! ```
//!
//! Only the frontmatter is read when indexing; bodies load on demand.

const std = @import("std");
const zg_frontmatter = @import("zg_frontmatter");
const template = @import("template.zig");

const Allocator = std.mem.Allocator;
const fm = zg_frontmatter.frontmatter;

pub const VarDecl = template.VarDecl;

/// Precedence when ids collide: project > user > builtin. Skills are
/// listed separately (they run as `/name args`, never inlined).
pub const EntrySource = enum { project, user, builtin, skill };

pub const Entry = struct {
    /// The path below the prompts folder without `.md`: "research/lead".
    id: []const u8,
    source: EntrySource,
    title: []const u8,
    description: []const u8 = "",
    tags: []const []const u8 = &.{},
    variables: []const VarDecl = &.{},
    /// The file; empty for built-ins and skills.
    path: []const u8 = "",
    /// Hash of the body text (workflow replay keys include it). 0 until the
    /// body was read for files.
    body_hash: u64 = 0,
    /// Skills: `disable-model-invocation` (the model may not call it).
    disable_model_invocation: bool = false,
    /// Skills: the `argument-hint`.
    argument_hint: ?[]const u8 = null,
};

pub const Header = struct {
    title: ?[]const u8 = null,
    description: []const u8 = "",
    tags: []const []const u8 = &.{},
    variables: []const VarDecl = &.{},
    /// Where the body starts in the file.
    body_start: usize = 0,
    /// A problem with the frontmatter; the entry still loads.
    problem: ?[]const u8 = null,
};

/// Reads the frontmatter of `bytes` (which may be only the head of a file;
/// a header cut off is reported as a problem).
pub fn parseHeader(arena: Allocator, bytes: []const u8) Allocator.Error!Header {
    var h: Header = .{};
    const loc = fm.findFrontmatter(bytes) orelse return h;
    h.body_start = loc.block[1];
    const root = try fm.parseRange(arena, bytes, loc.body, null);
    if (fm.get(&root, "title")) |n| h.title = scalar(bytes, n);
    if (fm.get(&root, "description")) |n| h.description = scalar(bytes, n) orelse "";
    if (fm.get(&root, "tags")) |n| h.tags = try stringList(arena, n);
    if (fm.get(&root, "variables")) |n| {
        if (n.value == .list) {
            var vars: std.ArrayList(VarDecl) = .empty;
            for (n.value.list) |*item| {
                if (try varDecl(arena, bytes, item)) |d| try vars.append(arena, d) else h.problem = "a variable has no name or an unknown type";
            }
            h.variables = vars.items;
        } else h.problem = "variables must be a list";
    }
    return h;
}

fn varDecl(arena: Allocator, bytes: []const u8, n: *const fm.Node) Allocator.Error!?VarDecl {
    if (n.value != .map) return null;
    const name = if (fm.get(n, "name")) |x| scalar(bytes, x) orelse return null else return null;
    var d: VarDecl = .{ .name = name };
    if (fm.get(n, "type")) |x| {
        const t = scalar(bytes, x) orelse return null;
        d.kind = std.meta.stringToEnum(template.VarKind, t) orelse return null;
    }
    if (fm.get(n, "options")) |x| d.options = try stringList(arena, x);
    if (fm.get(n, "default")) |x| d.default = scalar(bytes, x);
    if (fm.get(n, "required")) |x| d.required = x.value == .bool and x.value.bool;
    return d;
}

fn scalar(bytes: []const u8, n: *const fm.Node) ?[]const u8 {
    return switch (n.value) {
        .string => |s| s,
        .null, .list, .map => null,
        .raw => |r| r,
        else => bytes[n.src[0]..n.src[1]],
    };
}

fn stringList(arena: Allocator, n: *const fm.Node) Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    switch (n.value) {
        .list => |items| for (items) |it| switch (it.value) {
            .string => |s| if (s.len > 0) try out.append(arena, s),
            .int => |i| try out.append(arena, try std.fmt.allocPrint(arena, "{d}", .{i})),
            else => {},
        },
        .string => |s| {
            var it = std.mem.tokenizeAny(u8, s, ", ");
            while (it.next()) |x| try out.append(arena, x);
        },
        // A flow list inside a flow map (`{options: [a, b]}`) stays raw.
        .raw => |r| if (r.len >= 2 and r[0] == '[' and r[r.len - 1] == ']') {
            var it = std.mem.splitScalar(u8, r[1 .. r.len - 1], ',');
            while (it.next()) |x| {
                const t = std.mem.trim(u8, x, " \t\"'");
                if (t.len > 0) try out.append(arena, t);
            }
        },
        else => {},
    }
    return out.items;
}

/// The body hash recorded for replay keys.
pub fn hashBody(body: []const u8) u64 {
    return std.hash.Wyhash.hash(0x6c69627261727921, body);
}

/// "research/lead" from a path relative to a prompts folder, `\` or `/`
/// separated; null unless it ends in `.md`.
pub fn idFromRelPath(arena: Allocator, rel: []const u8) Allocator.Error!?[]const u8 {
    if (!std.mem.endsWith(u8, rel, ".md") or rel.len <= 3) return null;
    const id = try arena.dupe(u8, rel[0 .. rel.len - 3]);
    for (id) |*c| if (c.* == '\\') {
        c.* = '/';
    };
    return id;
}

/// A title from an id when the file has none: its last segment with
/// dashes and underscores as spaces.
pub fn titleFromId(arena: Allocator, id: []const u8) Allocator.Error![]const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, id, '/')) |s| id[s + 1 ..] else id;
    const t = try arena.dupe(u8, base);
    for (t) |*c| if (c.* == '-' or c.* == '_') {
        c.* = ' ';
    };
    if (t.len > 0) t[0] = std.ascii.toUpper(t[0]);
    return t;
}
