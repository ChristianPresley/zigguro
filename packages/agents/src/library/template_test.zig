const std = @import("std");
const template = @import("template.zig");

const testing = std.testing;
const Var = template.Var;
const VarDecl = template.VarDecl;

const Case = struct {
    src: []const u8,
    vars: []const Var = &.{},
    decls: []const VarDecl = &.{},
    ctx: template.RenderCtx = .{},
    want: []const u8,
    missing: []const []const u8 = &.{},
    invalid: []const []const u8 = &.{},
};

const cases = [_]Case{
    .{ .src = "plain text", .want = "plain text" },
    .{ .src = "", .want = "" },
    .{ .src = "Hi {{name}}!", .vars = &.{.{ .name = "name", .value = "Ada" }}, .want = "Hi Ada!" },
    .{ .src = "Hi {{ name }}!", .vars = &.{.{ .name = "name", .value = "Ada" }}, .want = "Hi Ada!" },
    .{ .src = "Hi {{name}}!", .want = "Hi !", .missing = &.{"name"} },
    .{ .src = "{{a}}{{b}}", .vars = &.{ .{ .name = "a", .value = "1" }, .{ .name = "b", .value = "2" } }, .want = "12" },
    .{ .src = "{{a}} and {{a}}", .vars = &.{.{ .name = "a", .value = "x" }}, .want = "x and x" },
    .{ .src = "{{n|default:\"three\"}}", .want = "three" },
    .{ .src = "{{n|default:three}}", .want = "three" },
    .{ .src = "{{n|default:\"three\"}}", .vars = &.{.{ .name = "n", .value = "4" }}, .want = "4" },
    .{ .src = "{{n|default:\"a b\"}}", .want = "a b" },
    .{ .src = "{{len|choice:short,medium,long}}", .vars = &.{.{ .name = "len", .value = "short" }}, .want = "short" },
    .{ .src = "{{len|choice:short,medium,long}}", .vars = &.{.{ .name = "len", .value = "huge" }}, .want = "huge", .invalid = &.{"len"} },
    .{ .src = "{{len|choice:short,medium,long}}", .want = "", .missing = &.{"len"} },
    .{ .src = "\\{{literal}}", .want = "{{literal}}" },
    .{ .src = "a \\{{b}} {{c}}", .vars = &.{.{ .name = "c", .value = "C" }}, .want = "a {{b}} C" },
    .{ .src = "{{selection}}", .ctx = .{ .selection = "sel" }, .want = "sel" },
    .{ .src = "{{selection}}", .want = "" },
    .{ .src = "{{file}} on {{date}}", .ctx = .{ .file = "a.md", .date = "2026-10-28" }, .want = "a.md on 2026-10-28" },
    .{ .src = "{{clipboard}}", .ctx = .{ .clipboard = "clip" }, .want = "clip" },
    .{ .src = "{{#if x}}yes{{/if}}", .vars = &.{.{ .name = "x", .value = "1" }}, .want = "yes" },
    .{ .src = "{{#if x}}yes{{/if}}", .want = "" },
    .{ .src = "{{#if x}}yes{{/if}}", .vars = &.{.{ .name = "x", .value = "false" }}, .want = "" },
    .{ .src = "{{#if x}}yes{{/if}}", .vars = &.{.{ .name = "x", .value = "yes" }}, .want = "yes" },
    .{ .src = "{{#if x}}yes{{else}}no{{/if}}", .want = "no" },
    .{ .src = "{{#if e == \"deep\"}}D{{else}}S{{/if}}", .vars = &.{.{ .name = "e", .value = "deep" }}, .want = "D" },
    .{ .src = "{{#if e == \"deep\"}}D{{else}}S{{/if}}", .vars = &.{.{ .name = "e", .value = "quick" }}, .want = "S" },
    .{ .src = "{{#if e == deep}}D{{/if}}", .vars = &.{.{ .name = "e", .value = "deep" }}, .want = "D" },
    .{ .src = "{{#if a}}{{#if b}}AB{{else}}A{{/if}}{{/if}}", .vars = &.{.{ .name = "a", .value = "1" }}, .want = "A" },
    .{ .src = "{{#if a}}{{#if b}}AB{{else}}A{{/if}}{{/if}}", .vars = &.{ .{ .name = "a", .value = "1" }, .{ .name = "b", .value = "1" } }, .want = "AB" },
    .{ .src = "{{#if a}}{{v}}{{/if}}", .vars = &.{ .{ .name = "a", .value = "1" }, .{ .name = "v", .value = "V" } }, .want = "V" },
    .{ .src = "{{#if a}}{{v}}{{/if}}", .want = "", .missing = &.{"v"} },
    .{ .src = "{{effort}}", .decls = &.{.{ .name = "effort", .kind = .choice, .options = &.{ "quick", "deep" }, .default = "quick" }}, .want = "quick" },
    .{ .src = "{{q}}", .decls = &.{.{ .name = "q", .required = true }}, .want = "", .missing = &.{"q"} },
    .{ .src = "{{q}}", .decls = &.{.{ .name = "q" }}, .want = "" },
    .{ .src = "{{n}}", .decls = &.{.{ .name = "n", .kind = .number }}, .vars = &.{.{ .name = "n", .value = "x" }}, .want = "x", .invalid = &.{"n"} },
    .{ .src = "{{n}}", .decls = &.{.{ .name = "n", .kind = .number }}, .vars = &.{.{ .name = "n", .value = "2.5" }}, .want = "2.5" },
    .{ .src = "{{b}}", .decls = &.{.{ .name = "b", .kind = .bool }}, .vars = &.{.{ .name = "b", .value = "maybe" }}, .want = "maybe", .invalid = &.{"b"} },
    .{ .src = "{{s}}", .decls = &.{.{ .name = "s", .kind = .selection, .required = true }}, .ctx = .{ .selection = "x" }, .want = "" },
    .{ .src = "a { b } c", .want = "a { b } c" },
    .{ .src = "{{audience}} {{length|choice:short,medium,long}}", .vars = &.{ .{ .name = "audience", .value = "devs" }, .{ .name = "length", .value = "long" } }, .want = "devs long" },
};

test "template_render_table" {
    for (cases, 0..) |c, i| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const r = try template.render(arena.allocator(), c.src, c.decls, c.vars, c.ctx);
        errdefer std.debug.print("case {d}: {s}\n", .{ i, c.src });
        try testing.expectEqualStrings(c.want, r.text);
        try testing.expectEqual(c.missing.len, r.missing.len);
        for (c.missing, r.missing) |w, g| try testing.expectEqualStrings(w, g);
        try testing.expectEqual(c.invalid.len, r.invalid.len);
        for (c.invalid, r.invalid) |w, g| try testing.expectEqualStrings(w, g.name);
    }
}

test "template_parse_errors" {
    const bad = [_]struct { src: []const u8, err: template.ParseError, at: usize }{
        .{ .src = "{{name", .err = error.UnclosedTag, .at = 0 },
        .{ .src = "ok {{#if x}}never closed", .err = error.UnclosedIf, .at = 24 },
        .{ .src = "{{/if}}", .err = error.UnexpectedTag, .at = 0 },
        .{ .src = "a {{else}}", .err = error.UnexpectedTag, .at = 2 },
        .{ .src = "{{9bad}}", .err = error.BadTag, .at = 0 },
        .{ .src = "{{x|upper}}", .err = error.BadTag, .at = 0 },
        .{ .src = "{{x|choice:}}", .err = error.BadTag, .at = 0 },
    };
    for (bad) |b| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var d: template.ParseDiag = .{};
        try testing.expectError(b.err, template.parse(arena.allocator(), b.src, &d));
        try testing.expectEqual(b.at, d.offset);
    }
}

test "frontmatter_vars_merge_inline_hints" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try template.parse(a, "{{audience}} {{length|choice:short,medium,long}} {{tone|default:\"warm\"}} {{selection}} {{#if formal}}F{{/if}}", null);
    const vars = try template.variables(a, t, &.{.{ .name = "length", .kind = .text, .default = "medium" }});
    try testing.expectEqual(@as(usize, 4), vars.len);
    try testing.expectEqualStrings("length", vars[0].name);
    try testing.expectEqual(template.VarKind.choice, vars[0].kind);
    try testing.expectEqual(@as(usize, 3), vars[0].options.len);
    try testing.expectEqualStrings("medium", vars[0].default.?);
    try testing.expectEqualStrings("audience", vars[1].name);
    try testing.expect(vars[1].required);
    try testing.expectEqualStrings("tone", vars[2].name);
    try testing.expect(!vars[2].required);
    try testing.expectEqualStrings("formal", vars[3].name);
    try testing.expectEqual(template.VarKind.bool, vars[3].kind);
}

test "detect_variables_for_save_prompt" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const vs = try template.detectVariables(arena.allocator(), "Summarize {{topic}} for {{audience|choice:execs,devs}}");
    try testing.expectEqual(@as(usize, 2), vs.len);
    try testing.expectEqualStrings("topic", vs[0].name);
    try testing.expectEqual(template.VarKind.choice, vs[1].kind);
    try testing.expectEqual(@as(usize, 0), (try template.detectVariables(arena.allocator(), "broken {{")).len);
}
