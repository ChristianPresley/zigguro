//! The claim verifier: votes, errors, budgets and cost.

const std = @import("std");
const zg_ai = @import("zg_ai");
const citations = @import("citations.zig");
const verify = @import("verify.zig");
const fixture = @import("test_fixture.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const script = zg_ai.scripted.script;
const Step = zg_ai.ScriptedProvider.Step;

const sup = script.text("{\"verdict\":\"supported\",\"reason\":\"Stated directly.\"}");
const part = script.text("Here you go: {\"verdict\":\"partially_supported\",\"reason\":\"Only half.\"}");
const unsup = script.text("{\"verdict\":\"unsupported\",\"reason\":\"Contradicted.\"}");
const garbage = script.text("{\"verdict\":\"maybe\",\"reason\":\"?\"}");
const timeout = &[_]Step{.{ .fail = error.Timeout }};
const broken = &[_]Step{.{ .fail = error.ServerError }};

fn claims(f: *fixture.Fx, a: std.mem.Allocator, n: usize) ![]citations.Claim {
    const out = try a.alloc(citations.Claim, n);
    for (out, 0..) |*c, i| {
        const cs = try a.alloc(citations.Citation, 1);
        cs[0] = .{ .source = if (i % 2 == 0) f.alpha else f.beta, .start_block = 1, .end_block = 1 };
        c.* = .{ .id = @intCast(i + 1), .text = try std.fmt.allocPrint(a, "Claim number {d}.", .{i + 1}), .range = .{ .start = 0, .end = 0 }, .citations = cs };
    }
    return out;
}

fn kinds(vs: []const verify.Verdict) [8]?verify.Kind {
    var out: [8]?verify.Kind = @splat(null);
    for (vs, 0..) |v, i| out[i] = v.kind;
    return out;
}

test "verifier_votes_and_errors" {
    var f: fixture.Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // One vote each, in order.
    {
        const turns = [_][]const Step{ sup, unsup, timeout, garbage, broken, part };
        const sp = try zg_ai.ScriptedProvider.init(gpa, &turns, .all);
        defer sp.destroy();
        var v: verify.Verifier = .{ .gpa = gpa, .provider = sp.provider(), .concurrency = 1 };
        const vs = try v.verify(io, a, try claims(&f, a, 6), f.lib, "claude-haiku-5-5", .{});
        try testing.expectEqual([8]?verify.Kind{ .supported, .unsupported, .unverifiable, .unverifiable, .unverifiable, .partially_supported, null, null }, kinds(vs));
        try testing.expectEqualStrings("Contradicted.", vs[1].reason);
        try testing.expectEqualStrings("verification timed out", vs[2].reason);
        try testing.expectEqualStrings("malformed verdict", vs[3].reason);
        try testing.expectEqualStrings("verification request failed", vs[4].reason);
        try testing.expectEqual(@as(u32, 6), vs[5].claim);

        // The request: the claim and only its cited passage, as data.
        const req = sp.requests()[0];
        try testing.expectEqualStrings("claude-haiku-5-5", req.model);
        try testing.expect(req.output_schema_json != null);
        const prompt = req.messages[0].content[0].text.text;
        try testing.expect(std.mem.indexOf(u8, prompt, "Claim number 1.") != null);
        try testing.expect(std.mem.indexOf(u8, prompt, "[b1] The Zig build system caches every step by content hash.") != null);
        try testing.expect(std.mem.indexOf(u8, prompt, "Incremental compilation") == null);
    }

    // Three votes each at deep effort: majority, tie, nothing usable.
    {
        const turns = [_][]const Step{ sup, sup, unsup, sup, unsup, timeout, timeout, broken, garbage, unsup, part, unsup };
        const sp = try zg_ai.ScriptedProvider.init(gpa, &turns, .all);
        defer sp.destroy();
        var v: verify.Verifier = .{ .gpa = gpa, .provider = sp.provider(), .concurrency = 1, .effort = .deep };
        const vs = try v.verify(io, a, try claims(&f, a, 4), f.lib, "m", .{});
        try testing.expectEqual([8]?verify.Kind{ .supported, .partially_supported, .unverifiable, .unsupported, null, null, null, null }, kinds(vs));
        try testing.expectEqualStrings("the checks disagreed", vs[1].reason);
        try testing.expectEqual(@as(usize, 0), sp.remaining());
    }
}

test "verifier runs concurrently" {
    var f: fixture.Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var turns: [20][]const Step = undefined;
    for (&turns) |*t| t.* = sup;
    const sp = try zg_ai.ScriptedProvider.init(gpa, &turns, .all);
    defer sp.destroy();
    var v: verify.Verifier = .{ .gpa = gpa, .provider = sp.provider() };
    const vs = try v.verify(io, a, try claims(&f, a, 20), f.lib, "m", .{});
    for (vs, 1..) |x, i| {
        try testing.expectEqual(verify.Kind.supported, x.kind);
        try testing.expectEqual(@as(u32, @intCast(i)), x.claim);
    }
    try testing.expectEqual(@as(u32, 20), v.used.turns);
}

test "verification cost goes to the ledger and stops at the budget" {
    var f: fixture.Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const turns = [_][]const Step{ sup, sup, sup };
    const sp = try zg_ai.ScriptedProvider.init(gpa, &turns, .all);
    defer sp.destroy();
    var ledger: zg_ai.models.ledger.CostLedger = .init(gpa, io);
    defer ledger.deinit();
    const info: zg_ai.models.registry.ModelInfo = .{
        .id = "cheap",
        .provider = .scripted,
        .display = "Cheap",
        .family = "test",
        .context_window = 100_000,
        .max_output = 4096,
        .caps = .all,
        .price = .{ .input_per_mtok_micros = 1_000_000, .output_per_mtok_micros = 5_000_000 },
    };
    const who: zg_ai.proto.AgentRef = .{ .session = 42, .agent = 3 };
    var v: verify.Verifier = .{ .gpa = gpa, .provider = sp.provider(), .concurrency = 1, .ledger = &ledger, .model_info = &info, .who = who };
    const vs = try v.verify(io, a, try claims(&f, a, 3), f.lib, "cheap", .{ .max_turns = 2 });
    try testing.expectEqual([8]?verify.Kind{ .supported, .supported, .unverifiable, null, null, null, null, null }, kinds(vs));
    try testing.expectEqualStrings("verification budget exhausted", vs[2].reason);
    // Two requests of 10 in / 5 out: 2 × (10 × 1 + 5 × 5) micros.
    const t = ledger.total(.{ .agent = who });
    try testing.expectEqual(@as(u64, 2), t.requests);
    try testing.expectEqual(@as(u64, 70), t.micros);
    try testing.expectEqual(@as(u64, 70), v.used.cost_micros);
    try testing.expectEqual(@as(usize, 1), sp.remaining());
}
