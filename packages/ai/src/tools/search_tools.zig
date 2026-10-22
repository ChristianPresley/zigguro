//! The `tool_search` built-in (E10.F06.S01.T01): finds deferred tools by
//! name or description and declares them from the next request on.
//!
//! A query matches a name as a substring (best), then as a subsequence
//! ("cri" finds `create_issue`), then a description as a substring; all
//! case-insensitive. Ties keep registry order.

const std = @import("std");
const proto = @import("zg_ai_proto");
const toolset = @import("toolset.zig");

const Allocator = std.mem.Allocator;

pub const name = "tool_search";

pub const schema =
    \\{"type":"object","properties":{"query":{"type":"string","description":"Words from the tool's name or purpose."},"limit":{"type":"integer","minimum":1,"maximum":20,"default":5}},"required":["query"],"additionalProperties":false}
;

pub const description =
    \\Searches tools that are available but not loaded yet, by name or description. The tools found are returned with their input schemas and can be called from the next step on.
;

/// The spec, calling into `at`.
pub fn spec(at: *toolset.AgentTools) proto.ToolSpec {
    return .{
        .name = name,
        .description = description,
        .input_schema_json = schema,
        .read_only = true,
        .effects = .{ .read_only = true, .idempotent = true },
        .handler = .{ .ctx = at, .call = call },
    };
}

/// How well `query` matches `s`; 0 is no match.
pub fn score(query: []const u8, s: *const proto.ToolSpec) u8 {
    if (query.len == 0) return 0;
    if (std.ascii.indexOfIgnoreCase(s.name, query) != null) return 3;
    if (subsequence(query, s.name)) return 2;
    if (std.ascii.indexOfIgnoreCase(s.description, query) != null) return 1;
    return 0;
}

fn subsequence(q: []const u8, text: []const u8) bool {
    var i: usize = 0;
    for (text) |c| {
        if (i < q.len and std.ascii.toLower(c) == std.ascii.toLower(q[i])) i += 1;
    }
    return i == q.len;
}

/// The best `limit` deferred tools for `query`.
pub fn search(arena: Allocator, deferred: []const proto.ToolSpec, query: []const u8, limit: usize) Allocator.Error![]const *const proto.ToolSpec {
    const Hit = struct { s: *const proto.ToolSpec, score: u8, pos: usize };
    var hits: std.ArrayList(Hit) = .empty;
    const q = std.mem.trim(u8, query, " \t");
    for (deferred, 0..) |*s, i| {
        const sc = score(q, s);
        if (sc > 0) try hits.append(arena, .{ .s = s, .score = sc, .pos = i });
    }
    std.mem.sort(Hit, hits.items, {}, struct {
        fn less(_: void, x: Hit, y: Hit) bool {
            return if (x.score != y.score) x.score > y.score else x.pos < y.pos;
        }
    }.less);
    const n = @min(limit, hits.items.len);
    const out = try arena.alloc(*const proto.ToolSpec, n);
    for (out, hits.items[0..n]) |*o, h| o.* = h.s;
    return out;
}

fn call(ctx: *anyopaque, c: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
    const at: *toolset.AgentTools = @ptrCast(@alignCast(ctx));
    const a = c.arena;
    const query = if (c.input == .object) if (c.input.object.get("query")) |v| if (v == .string) v.string else null else null else null;
    const q = query orelse return proto.ToolOutput.text(a, "tool_search needs a \"query\" string.", true);
    var limit: usize = 5;
    if (c.input.object.get("limit")) |v| if (v == .integer) {
        limit = @intCast(std.math.clamp(v.integer, 1, 20));
    };
    const cur = at.current() orelse return proto.ToolOutput.text(a, "No tools are deferred.", false);
    const found = try search(a, cur.deferred, q, limit);
    if (found.len == 0) return proto.ToolOutput.text(a, try std.fmt.allocPrint(a, "No deferred tool matches \"{s}\".", .{q}), false);

    const names = try a.alloc([]const u8, found.len);
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    write: {
        w.writeAll("[") catch break :write;
        for (found, names, 0..) |s, *n, i| {
            n.* = s.name;
            if (i > 0) w.writeAll(",") catch break :write;
            w.print("{{\"name\":{f},\"description\":{f},\"input_schema\":{s}}}", .{
                std.json.fmt(s.name, .{}), std.json.fmt(s.description, .{}), s.input_schema_json,
            }) catch break :write;
        }
        w.writeAll("]") catch break :write;
    }
    try at.promote(names);
    var o = try proto.ToolOutput.text(a, out.written(), false);
    o.ui_hint = .json;
    return o;
}
