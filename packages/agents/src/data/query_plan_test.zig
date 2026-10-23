const std = @import("std");
const query = @import("query/root.zig");

const testing = std.testing;
const types = query.types;
const plan = query.plan;

const sales_cols = [_]types.SchemaCol{
    .{ .name = "region", .ty = .string },
    .{ .name = "amount", .ty = .float },
    .{ .name = "qty", .ty = .int },
    .{ .name = "day", .ty = .date },
    .{ .name = "note", .ty = .string },
    .{ .name = "id", .ty = .int },
};

const regions_cols = [_]types.SchemaCol{
    .{ .name = "name", .ty = .string },
    .{ .name = "pop", .ty = .int },
};

fn resolve(_: *anyopaque, name: []const u8) ?types.Schema {
    if (std.mem.eql(u8, name, "sales")) return .{ .columns = &sales_cols };
    if (std.mem.eql(u8, name, "regions")) return .{ .columns = &regions_cols };
    return null;
}

var catalog_ctx: u8 = 0;
const catalog: query.Catalog = .{ .ctx = &catalog_ctx, .resolve = resolve };

const Result = union(enum) { ok: query.Plan, err: []const u8 };

fn planQuery(arena: std.mem.Allocator, src: []const u8) !Result {
    var diag: query.Diagnostic = .{};
    const t = query.parse(arena, src, &diag) catch |e| switch (e) {
        error.Syntax => return .{ .err = try std.fmt.allocPrint(arena, "syntax: {f}", .{diag}) },
        else => |x| return x,
    };
    const p = plan.plan(arena, &t, catalog, &diag) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return .{ .err = try std.fmt.allocPrint(arena, "{f}", .{diag}) },
    };
    return .{ .ok = p };
}

fn mustPlan(arena: std.mem.Allocator, src: []const u8) !query.Plan {
    return switch (try planQuery(arena, src)) {
        .ok => |p| p,
        .err => |m| {
            std.debug.print("{s}: {s}\n", .{ src, m });
            return error.TestUnexpectedResult;
        },
    };
}

const typecheck_errors = [_]struct { []const u8, []const u8 }{
    .{ "from sales | where region > 3", "cannot compare string to int at 19..29" },
    .{ "from sales | sort -amount | where qty between 'a' and 'b'", "cannot compare int to string at 34..57" },
    .{ "from sales | where day > 2024-01-01 and day < 'x'", "cannot compare date to string at 40..49" },
    .{ "from sales | join regions on qty == name", "cannot compare int to string at 29..40" },
    .{ "from sales | where qty + 1", "`where` needs a bool, found int at 19..26" },
    .{ "from sales | where not qty", "`not` needs a bool, found int at 19..26" },
    .{ "from sales | where amout > 1", "unknown column `amout` (did you mean `amount`?) at 19..24" },
    .{ "from sales | where zzz > 1", "unknown column `zzz` at 19..22" },
    .{ "from sales | select region | where qty > 1", "unknown column `qty` at 35..38" },
    .{ "from nope", "unknown dataset `nope` at 0..9" },
    .{ "where qty > 1", "the query needs `from <dataset>` at 0..0" },
    .{ "from sales | derive x = sum(qty)", "`sum` is an aggregate; use it inside `group { }` at 24..32" },
    .{ "from sales | group region { n = qty }", "group values must be aggregates like sum(x) at 32..35" },
    .{ "from sales | where lower(qty) == 'a'", "`lower` takes a string, found int at 25..28" },
    .{ "from sales | derive x = region + 1", "`+` needs numbers, found string and int at 24..34" },
    .{ "from sales | derive x = case when qty > 1 then 'a' else 2 end", "case branches have different types: string and int at 56..57" },
    .{ "from sales | group region { m = p(amount, 2) }", "`p` needs a literal quantile between 0 and 1 at 42..43" },
    .{ "from sales | derive t = trunc(day, 'fortnight')", "unknown unit \"fortnight\" (year, quarter, month, week, day, hour, minute, second) at 35..46" },
    .{ "from sales | group region { n = count(), n = sum(qty) }", "duplicate column `n` in `group` at 41..42" },
    .{ "from sales | where unknown_fn(qty)", "unknown function `unknown_fn` at 19..34" },
    .{ "from sales | derive r = round(amount, 'x')", "`round` takes int digits, found string at 38..41" },
    .{ "from sales | where contains(region)", "`contains` takes 2 arguments, found 1 at 19..35" },
    .{ "from sales | join regions on qty > pop", "join needs `left_column == right_column` at 29..38" },
};

test "typecheck_errors" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var bad: usize = 0;
    for (typecheck_errors) |c| {
        const got: []const u8 = switch (try planQuery(arena.allocator(), c[0])) {
            .ok => "(planned)",
            .err => |m| m,
        };
        if (!std.mem.eql(u8, got, c[1])) {
            std.debug.print("query: {s}\n  want: {s}\n  got:  {s}\n", .{ c[0], c[1], got });
            bad += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), bad);
}

test "planner_prunes_columns" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, []const u32 }{
        .{ "from sales | where qty > 1 | group region { total = sum(amount) }", &.{ 0, 1, 2 } },
        .{ "from sales | select region, amount", &.{ 0, 1 } },
        // The output keeps every source column.
        .{ "from sales | where qty > 1", &.{ 0, 1, 2, 3, 4, 5 } },
        // Replacing one column still reads the others raw.
        .{ "from sales | derive amount = amount * 2 | select amount, qty", &.{ 1, 2 } },
        .{ "from sales | derive amount = 0 | select amount, qty", &.{2} },
        .{ "from sales | derive amount = 0", &.{ 0, 2, 3, 4, 5 } },
        .{ "from sales | join regions on region == name | select region, pop", &.{0} },
        .{ "from sales | group { n = count() }", &.{} },
        .{ "from sales | sort -amount | limit 3 | select id", &.{ 1, 5 } },
    };
    for (cases) |c| {
        const p = try mustPlan(a, c[0]);
        testing.expectEqualSlices(u32, c[1], p.needed_columns) catch |e| {
            std.debug.print("query: {s}\n", .{c[0]});
            return e;
        };
    }
}

fn countConjuncts(e: *const plan.TypedExpr) usize {
    if (e.node == .binary and e.node.binary.op == .@"and")
        return countConjuncts(e.node.binary.l) + countConjuncts(e.node.binary.r);
    return 1;
}

fn stageTags(a: std.mem.Allocator, p: query.Plan) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (p.stages, 0..) |s, i| {
        if (i > 0) try out.append(a, ' ');
        try out.appendSlice(a, @tagName(s));
    }
    return out.items;
}

test "pushdown_flags" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Raw conjuncts move ahead of a derive that adds a column; the one on
    // the derived column stays.
    var p = try mustPlan(a, "from sales | where qty > 1 and region == 'x' | derive d = amount * 2 | where d > 10 and qty < 100");
    try testing.expectEqual(@as(usize, 3), countConjuncts(p.filter.?));
    try testing.expectEqualStrings("derive where", try stageTags(a, p));
    try testing.expectEqual(@as(usize, 1), countConjuncts(p.stages[1].where));

    // A derive that replaces a source column stops pushdown.
    p = try mustPlan(a, "from sales | derive qty = qty * 2 | where qty > 1");
    try testing.expect(p.filter == null);
    try testing.expectEqualStrings("derive where", try stageTags(a, p));

    // Nothing moves past a group.
    p = try mustPlan(a, "from sales | group region { n = count() } | where n > 1");
    try testing.expect(p.filter == null);
    try testing.expectEqualStrings("group where", try stageTags(a, p));

    // Constants fold before pushdown.
    p = try mustPlan(a, "from sales | where qty > 2 * 3");
    try testing.expectEqualStrings("", try stageTags(a, p));
    const f = p.filter.?;
    try testing.expectEqual(plan.Lit{ .int = 6 }, f.node.binary.r.node.lit);
    p = try mustPlan(a, "from sales | where 1 < 2 and not false");
    try testing.expectEqual(plan.Lit{ .bool_ = true }, p.filter.?.node.lit);
}

test "topk_fusion" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p = try mustPlan(a, "from sales | sort -amount, id | limit 10");
    try testing.expectEqualStrings("topk", try stageTags(a, p));
    try testing.expectEqual(@as(u64, 10), p.stages[0].topk.k);
    try testing.expectEqualSlices(plan.PlanKey, &.{ .{ .col = 1, .desc = true }, .{ .col = 5, .desc = false } }, p.stages[0].topk.keys);

    p = try mustPlan(a, "from sales | group region { n = count() } | sort -n | limit 3");
    try testing.expectEqualStrings("group topk", try stageTags(a, p));

    p = try mustPlan(a, "from sales | sort amount | where amount > 1 | limit 10");
    try testing.expectEqualStrings("sort where limit", try stageTags(a, p));
    p = try mustPlan(a, "from sales | limit 10 | sort amount");
    try testing.expectEqualStrings("limit sort", try stageTags(a, p));
}

test "output schemas and expression types" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p = try mustPlan(a, "from sales | group region { n = count(), total = sum(amount), q = sum(qty), med = median(qty), lo = min(day) }");
    const want = [_]types.SchemaCol{
        .{ .name = "region", .ty = .string },
        .{ .name = "n", .ty = .int },
        .{ .name = "total", .ty = .float },
        .{ .name = "q", .ty = .int },
        .{ .name = "med", .ty = .float },
        .{ .name = "lo", .ty = .date },
    };
    try expectSchema(&want, p.out_schema);

    p = try mustPlan(a, "from sales | derive m = trunc(day, 'month'), y = year(day), age = day - 2024-01-01, later = day + 7, r = qty / 2, s = coalesce(note, region) | select m, y, age, later, r, s, qty * 2");
    const want2 = [_]types.SchemaCol{
        .{ .name = "m", .ty = .date },
        .{ .name = "y", .ty = .int },
        .{ .name = "age", .ty = .int },
        .{ .name = "later", .ty = .date },
        .{ .name = "r", .ty = .float },
        .{ .name = "s", .ty = .string },
        .{ .name = "expr7", .ty = .int },
    };
    try expectSchema(&want2, p.out_schema);

    // Joined columns that clash get a suffix.
    p = try mustPlan(a, "from sales | derive name = note | join regions on region == name");
    try testing.expectEqualStrings("name_2", p.out_schema.columns[7].name);
    try testing.expectEqualStrings("pop", p.out_schema.columns[8].name);
}

fn expectSchema(want: []const types.SchemaCol, got: types.Schema) !void {
    try testing.expectEqual(want.len, got.columns.len);
    for (want, got.columns) |w, g| {
        try testing.expectEqualStrings(w.name, g.name);
        try testing.expectEqual(w.ty, g.ty);
    }
}
