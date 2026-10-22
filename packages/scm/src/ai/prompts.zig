//! A tiny Mustache-like renderer for the F06 prompt templates
//! (`prompts/*.md`): `{{name}}` is replaced by the variable's value (empty
//! when unknown) and `{{#name}}...{{/name}}` keeps its body only when the
//! variable is non-empty (`{{^name}}...{{/name}}` only when it is empty).
//! Sections nest; values are inserted as they are, never re-rendered.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Var = struct { name: []const u8, value: []const u8 };

pub const Error = Allocator.Error || error{UnclosedSection};

/// Renders `template` with `vars`, allocated in `arena`.
pub fn render(arena: Allocator, template: []const u8, vars: []const Var) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try renderInto(arena, &out, template, vars);
    return out.items;
}

fn lookup(vars: []const Var, name: []const u8) []const u8 {
    for (vars) |v| if (std.mem.eql(u8, v.name, name)) return v.value;
    return "";
}

fn renderInto(arena: Allocator, out: *std.ArrayList(u8), template: []const u8, vars: []const Var) Error!void {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, template, i, "{{")) |open| {
        try out.appendSlice(arena, template[i..open]);
        const close = std.mem.indexOfPos(u8, template, open + 2, "}}") orelse {
            try out.appendSlice(arena, template[open..]);
            return;
        };
        const tag = std.mem.trim(u8, template[open + 2 .. close], " ");
        i = close + 2;
        if (tag.len > 0 and (tag[0] == '#' or tag[0] == '^')) {
            const name = tag[1..];
            const end = try sectionEnd(template, i, name);
            const body = template[i..end.body_end];
            const filled = lookup(vars, name).len > 0;
            if (filled == (tag[0] == '#')) try renderInto(arena, out, skipNewline(body), vars);
            i = end.after;
        } else {
            try out.appendSlice(arena, lookup(vars, tag));
        }
    }
    try out.appendSlice(arena, template[i..]);
}

/// A section's body drops the newline right after its opening tag, so
/// tags on their own lines leave no blank lines.
fn skipNewline(body: []const u8) []const u8 {
    return if (body.len > 0 and body[0] == '\n') body[1..] else body;
}

const End = struct { body_end: usize, after: usize };

/// Finds the `{{/name}}` closing the section whose body starts at `from`,
/// skipping nested sections of the same name.
fn sectionEnd(template: []const u8, from: usize, name: []const u8) Error!End {
    var depth: usize = 0;
    var i = from;
    while (std.mem.indexOfPos(u8, template, i, "{{")) |open| {
        const close = std.mem.indexOfPos(u8, template, open + 2, "}}") orelse break;
        const tag = std.mem.trim(u8, template[open + 2 .. close], " ");
        i = close + 2;
        if (tag.len < 2 or !std.mem.eql(u8, tag[1..], name)) continue;
        switch (tag[0]) {
            '#', '^' => depth += 1,
            '/' => {
                if (depth == 0) {
                    const after = if (i < template.len and template[i] == '\n') i + 1 else i;
                    return .{ .body_end = open, .after = after };
                }
                depth -= 1;
            },
            else => {},
        }
    }
    return error.UnclosedSection;
}

const t = std.testing;

test "prompts: variables, sections, inverted sections and nesting" {
    var a: std.heap.ArenaAllocator = .init(t.allocator);
    defer a.deinit();
    const tpl =
        \\Hello {{ name }}!
        \\{{#items}}
        \\Items:
        \\{{items}}
        \\{{#extra}}Extra: {{extra}}
        \\{{/extra}}
        \\{{/items}}
        \\{{^items}}
        \\No items.
        \\{{/items}}
        \\{{unknown}}end {{ not closed
    ;
    const got = try render(a.allocator(), tpl, &.{ .{ .name = "name", .value = "you" }, .{ .name = "items", .value = "- a\n- b" }, .{ .name = "extra", .value = "{{name}}" } });
    try t.expectEqualStrings("Hello you!\nItems:\n- a\n- b\nExtra: {{name}}\nend {{ not closed", got);
    const none = try render(a.allocator(), tpl, &.{.{ .name = "name", .value = "x" }});
    try t.expectEqualStrings("Hello x!\nNo items.\nend {{ not closed", none);
    try t.expectError(error.UnclosedSection, render(a.allocator(), "{{#a}}x", &.{}));
}
