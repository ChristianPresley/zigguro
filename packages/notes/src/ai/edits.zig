//! Note edits for the `update_note` agent tool (E08.F08.S02.T01): append,
//! section append/replace (a section runs to the next heading of the same
//! or a higher level), unique `str_replace`, and property edits through
//! the byte-preserving frontmatter writer. Pure: text in, text out.

const std = @import("std");
const extract_mod = @import("../vault/extract.zig");
const fm_writer = @import("zg_frontmatter").fm_writer;
const frontmatter = @import("zg_frontmatter").frontmatter;
const vault_mod = @import("../vault/vault.zig");

const Allocator = std.mem.Allocator;

pub const Edit = union(enum) {
    append: []const u8,
    append_section: struct { heading: []const u8, text: []const u8 },
    replace_section: struct { heading: []const u8, text: []const u8 },
    str_replace: struct { old: []const u8, new: []const u8 },
    set_property: struct { name: []const u8, value: frontmatter.Value },
    remove_property: []const u8,
    add_tag: []const u8,
};

pub const Outcome = union(enum) {
    ok: []u8,
    /// Why the edit cannot apply (for the model).
    err: []const u8,
};

/// Applies `edits` in order (all in `a`, an arena).
pub fn apply(a: Allocator, text: []const u8, edits: []const Edit, cfg: *const vault_mod.VaultConfig) !Outcome {
    var cur: []u8 = try a.dupe(u8, text);
    for (edits, 0..) |e, i| {
        switch (try applyOne(a, cur, e, cfg)) {
            .ok => |t| cur = t,
            .err => |m| return .{ .err = try std.fmt.allocPrint(a, "edit {d}: {s}", .{ i, m }) },
        }
    }
    return .{ .ok = cur };
}

fn applyOne(a: Allocator, text: []const u8, e: Edit, cfg: *const vault_mod.VaultConfig) !Outcome {
    switch (e) {
        .append => |t| return .{ .ok = try appendBlock(a, text, text.len, t) },
        .append_section, .replace_section => {
            const heading, const body = switch (e) {
                .append_section => |s| .{ s.heading, s.text },
                .replace_section => |s| .{ s.heading, s.text },
                else => unreachable,
            };
            const meta = try extract_mod.extract(a, text, "note.md", cfg);
            const want = std.mem.trim(u8, std.mem.trimStart(u8, heading, "#"), " ");
            var found: ?usize = null;
            var count: usize = 0;
            for (meta.headings, 0..) |h, hi| if (std.ascii.eqlIgnoreCase(h.text, want)) {
                if (found == null) found = hi;
                count += 1;
            };
            const hi = found orelse return .{ .err = try std.fmt.allocPrint(a, "no heading \"{s}\"", .{want}) };
            if (count > 1) return .{ .err = try std.fmt.allocPrint(a, "{d} headings named \"{s}\"; make it unique first", .{ count, want }) };
            const r = meta.sectionRange(hi, @intCast(text.len));
            // Content starts after the heading line.
            const head_end = meta.headings[hi].src[1];
            const content_start = if (head_end < text.len and text[head_end] == '\r') head_end + 2 else head_end + 1;
            const cs = @min(content_start, text.len);
            if (e == .append_section) {
                // Before the trailing blank lines of the section.
                var end = r[1];
                while (end > cs and (text[end - 1] == '\n' or text[end - 1] == '\r')) end -= 1;
                const at = if (end < r[1]) end + 1 else end;
                return .{ .ok = try appendBlock(a, text, @min(at, text.len), body) };
            }
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(a, text[0..cs]);
            try out.appendSlice(a, body);
            if (body.len > 0 and body[body.len - 1] != '\n') try out.append(a, '\n');
            if (r[1] < text.len) try out.append(a, '\n');
            try out.appendSlice(a, text[r[1]..]);
            return .{ .ok = out.items };
        },
        .str_replace => |s| {
            if (s.old.len == 0) return .{ .err = "old is empty" };
            const n = std.mem.count(u8, text, s.old);
            if (n != 1) return .{ .err = try std.fmt.allocPrint(a, "old matches {d} times; it must match exactly once (add surrounding text)", .{n}) };
            const at = std.mem.indexOf(u8, text, s.old).?;
            return .{ .ok = try std.mem.concat(a, u8, &.{ text[0..at], s.new, text[at + s.old.len ..] }) };
        },
        .set_property => |p| return .{ .ok = try fm_writer.applyPropEdits(a, text, &.{.{ .set = .{ .name = p.name, .value = p.value } }}) },
        .remove_property => |n| return .{ .ok = try fm_writer.applyPropEdits(a, text, &.{.{ .remove = n }}) },
        .add_tag => |raw| {
            const tag = std.mem.trimStart(u8, std.mem.trim(u8, raw, " "), "#");
            if (tag.len == 0) return .{ .err = "empty tag" };
            const meta = try extract_mod.extract(a, text, "note.md", cfg);
            var items: std.ArrayList(frontmatter.Node) = .empty;
            if (meta.prop("tags")) |p| switch (p.node.value) {
                .list => |l| for (l) |n| try items.append(a, n),
                .string => |s| if (s.len > 0) try items.append(a, .{ .value = .{ .string = s }, .src = .{ 0, 0 }, .style = .plain }),
                else => {},
            };
            for (items.items) |n| if (n.value == .string and std.ascii.eqlIgnoreCase(std.mem.trimStart(u8, n.value.string, "#"), tag)) return .{ .ok = try a.dupe(u8, text) };
            try items.append(a, .{ .value = .{ .string = tag }, .src = .{ 0, 0 }, .style = .plain });
            return .{ .ok = try fm_writer.applyPropEdits(a, text, &.{.{ .set = .{ .name = "tags", .value = .{ .list = items.items } } }}) };
        },
    }
}

/// `text` with `block` inserted at `at` as its own lines.
fn appendBlock(a: Allocator, text: []const u8, at: usize, block: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, text[0..at]);
    if (at > 0 and text[at - 1] != '\n') try out.append(a, '\n');
    try out.appendSlice(a, block);
    if (block.len > 0 and block[block.len - 1] != '\n') try out.append(a, '\n');
    try out.appendSlice(a, text[at..]);
    return out.items;
}

/// A JSON value as a frontmatter value (scalars and lists of scalars).
pub fn valueFromJson(a: Allocator, v: std.json.Value) !?frontmatter.Value {
    return switch (v) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |n| .{ .int = n },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .string = s },
        .string => |s| if (frontmatter.parseDate(s)) |d| (if (s.len == 10) .{ .date = d } else .{ .string = s }) else .{ .string = s },
        .array => |arr| blk: {
            const nodes = try a.alloc(frontmatter.Node, arr.items.len);
            for (arr.items, nodes) |x, *n| {
                const sv = (try valueFromJson(a, x)) orelse return null;
                if (sv == .list or sv == .map) return null;
                n.* = .{ .value = sv, .src = .{ 0, 0 }, .style = .plain };
            }
            break :blk .{ .list = nodes };
        },
        .object => null,
    };
}

const testing = std.testing;

fn expectEdits(before: []const u8, es: []const Edit, after: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cfg: vault_mod.VaultConfig = .{};
    switch (try apply(arena.allocator(), before, es, &cfg)) {
        .ok => |t| try testing.expectEqualStrings(after, t),
        .err => |m| {
            std.debug.print("edit failed: {s}\n", .{m});
            return error.TestUnexpectedResult;
        },
    }
}

test "edits: sections, append, str_replace and properties" {
    const note = "---\ntitle: X\n---\n# Top\nintro\n## Tasks\n- a\n\n## Notes\nold notes\n# Next\nend\n";
    try expectEdits(note, &.{.{ .append_section = .{ .heading = "Tasks", .text = "- b" } }}, "---\ntitle: X\n---\n# Top\nintro\n## Tasks\n- a\n- b\n\n## Notes\nold notes\n# Next\nend\n");
    try expectEdits(note, &.{.{ .replace_section = .{ .heading = "## notes", .text = "new notes" } }}, "---\ntitle: X\n---\n# Top\nintro\n## Tasks\n- a\n\n## Notes\nnew notes\n\n# Next\nend\n");
    try expectEdits(note, &.{.{ .append_section = .{ .heading = "Next", .text = "more" } }}, "---\ntitle: X\n---\n# Top\nintro\n## Tasks\n- a\n\n## Notes\nold notes\n# Next\nend\nmore\n");
    try expectEdits("no newline", &.{.{ .append = "tail" }}, "no newline\ntail\n");
    try expectEdits(note, &.{
        .{ .str_replace = .{ .old = "intro", .new = "hello" } },
        .{ .set_property = .{ .name = "status", .value = .{ .string = "done" } } },
        .{ .remove_property = "title" },
        .{ .add_tag = "#proj/x" },
        .{ .add_tag = "proj/x" },
    }, "---\nstatus: done\ntags:\n  - proj/x\n---\n# Top\nhello\n## Tasks\n- a\n\n## Notes\nold notes\n# Next\nend\n");
}

test "edits: str_replace not unique -> error with count" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const cfg: vault_mod.VaultConfig = .{};
    const r = try apply(arena.allocator(), "a x a x", &.{.{ .str_replace = .{ .old = "x", .new = "y" } }}, &cfg);
    try testing.expectEqualStrings("edit 0: old matches 2 times; it must match exactly once (add surrounding text)", r.err);
    const r2 = try apply(arena.allocator(), "# H\n# H\n", &.{.{ .append_section = .{ .heading = "H", .text = "t" } }}, &cfg);
    try testing.expect(r2 == .err);
    const r3 = try apply(arena.allocator(), "x", &.{.{ .replace_section = .{ .heading = "Missing", .text = "t" } }}, &cfg);
    try testing.expectEqualStrings("edit 0: no heading \"Missing\"", r3.err);
}
