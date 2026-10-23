//! Automation files: the ZON format, validation diagnostics and the
//! repository trust gate.

const std = @import("std");
const auto = @import("automation.zig");
const loader = @import("loader.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;

const digest_src =
    \\.{
    \\    .version = 1,
    \\    .name = "daily-digest",
    \\    .description = "Summarize yesterday's merged changes into today's daily note",
    \\    .enabled = true,
    \\    .triggers = .{.{ .schedule = .{ .cron = "0 9 * * 1-5", .jitter_s = 120 } }},
    \\    .action = .{ .agent = .{ .prompt = "Summarize what merged since {{last_run_at}}.", .agent_def = "writer", .model = "sonnet" } },
    \\    .profile = "unattended-notes-write",
    \\    .isolation = .shared,
    \\    .overlap = .skip,
    \\    .catch_up = .latest,
    \\    .budgets = .{ .max_cost_micro_usd = 500000, .max_wall_ms = 900000 },
    \\}
;

test "zon_roundtrip_golden" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var p: auto.Problem = .{ .message = "" };
    const d = try auto.parse(a, digest_src, &p);
    try testing.expectEqualStrings("daily-digest", d.name);
    try testing.expectEqual(@as(?u32, 120), d.schedule().?.jitter_s);
    try testing.expectEqualStrings("writer", d.action.agent.agent_def.?);
    try testing.expectEqual(@as(?u64, 500_000), d.budgets.max_cost_micro_usd);
    try testing.expect(auto.validate(&d, "daily-digest") == null);
    // Serialized and parsed again: the same automation, and a stable text.
    const text = try auto.toZon(a, &d);
    const golden = @embedFile("testdata/daily-digest.golden.zon");
    try testing.expectEqualStrings(golden, text);
    const again = try auto.parse(a, try a.dupeZ(u8, text), &p);
    try testing.expectEqualStrings(try auto.toZon(a, &again), text);
    // Every trigger kind round-trips.
    const all: auto.Automation = .{
        .name = "all",
        .triggers = &.{
            .{ .schedule = .{ .cron = "@hourly" } },
            .{ .once = .{ .at = "2026-12-24 18:00" } },
            .{ .files = .{ .globs = &.{ "src/**/*.zig", "!src/gen/**" }, .events = .{ .deleted = false } } },
            .{ .scm = .{ .events = &.{ .lane_landed, .op_committed }, .revset = "mine()" } },
            .{ .task = .{ .events = &.{.created}, .query = "status:ready label:agent" } },
        },
        .action = .{ .workflow = .{ .workflow = "triage", .args = "{\"max\":3}" } },
        .budgets = .{ .max_cost_micro_usd = 1 },
    };
    const t2 = try auto.toZon(a, &all);
    const b = try auto.parse(a, try a.dupeZ(u8, t2), &p);
    try testing.expectEqualStrings(t2, try auto.toZon(a, &b));
    try testing.expect(auto.validate(&b, "all") == null);
    try testing.expect(!b.triggers[2].files.events.deleted);
}

const Bad = struct { file: []const u8, src: [:0]const u8, line: u32 = 0, contains: []const u8 };

const bad_files = [_]Bad{
    .{ .file = "syntax.zon", .src = ".{ .name = \"syntax\",, }", .line = 1, .contains = "" },
    .{ .file = "unknown.zon", .src = ".{\n  .name = \"unknown\",\n  .colour = 3,\n}", .line = 3, .contains = "colour" },
    .{ .file = "type.zon", .src = ".{ .name = 5, .triggers = .{}, .action = .{ .agent = .{ .prompt = \"x\" } } }", .line = 1, .contains = "" },
    .{ .file = "missing.zon", .src = ".{ .name = \"missing\" }", .line = 1, .contains = "triggers" },
    .{ .file = "Bad-Name.zon", .src = ".{ .name = \"Bad-Name\", .triggers = .{.{ .schedule = .{ .cron = \"@daily\" } }}, .action = .{ .agent = .{ .prompt = \"x\" } }, .budgets = .{ .max_cost_micro_usd = 1 } }", .contains = "name must match [a-z0-9]" },
    .{ .file = "stem.zon", .src = ".{ .name = \"other\", .triggers = .{.{ .schedule = .{ .cron = \"@daily\" } }}, .action = .{ .agent = .{ .prompt = \"x\" } }, .budgets = .{ .max_cost_micro_usd = 1 } }", .contains = "file name" },
    .{ .file = "cron.zon", .src = ".{ .name = \"cron\", .triggers = .{.{ .schedule = .{ .cron = \"0 0 L * *\" } }}, .action = .{ .agent = .{ .prompt = \"x\" } }, .budgets = .{ .max_cost_micro_usd = 1 } }", .contains = "cron" },
    .{ .file = "once.zon", .src = ".{ .name = \"once\", .triggers = .{.{ .once = .{ .at = \"tomorrow\" } }}, .action = .{ .agent = .{ .prompt = \"x\" } }, .budgets = .{ .max_cost_micro_usd = 1 } }", .contains = "once.at" },
    .{ .file = "empty.zon", .src = ".{ .name = \"empty\", .triggers = .{}, .action = .{ .agent = .{ .prompt = \"x\" } }, .budgets = .{ .max_cost_micro_usd = 1 } }", .contains = "trigger" },
    .{ .file = "prompt.zon", .src = ".{ .name = \"prompt\", .triggers = .{.{ .schedule = .{ .cron = \"@daily\" } }}, .action = .{ .agent = .{ .prompt = \"  \" } }, .budgets = .{ .max_cost_micro_usd = 1 } }", .contains = "prompt" },
    .{ .file = "version.zon", .src = ".{ .version = 2, .name = \"version\", .triggers = .{.{ .schedule = .{ .cron = \"@daily\" } }}, .action = .{ .agent = .{ .prompt = \"x\" } }, .budgets = .{ .max_cost_micro_usd = 1 } }", .contains = "version" },
};

test "diagnostics_for_bad_files" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    for (bad_files) |b| {
        const l = try loader.loadSource(arena.allocator(), b.file, b.src, null);
        const p = l.problem orelse {
            std.debug.print("{s}: no problem reported\n", .{b.file});
            return error.TestExpectedProblem;
        };
        try testing.expect(l.automation == null);
        if (b.line != 0) try testing.expectEqual(b.line, p.line);
        if (std.mem.indexOf(u8, p.message, b.contains) == null) {
            std.debug.print("{s}: \"{s}\" lacks \"{s}\"\n", .{ b.file, p.message, b.contains });
            return error.TestUnexpectedMessage;
        }
    }
}

test "missing_budget_rejected_for_unattended" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const src = ".{ .name = \"spendy\", .triggers = .{.{ .schedule = .{ .cron = \"@daily\" } }}, .action = .{ .agent = .{ .prompt = \"x\" } } }";
    const l = try loader.loadSource(arena.allocator(), "spendy.zon", src, null);
    try testing.expect(std.mem.indexOf(u8, l.problem.?.message, "max_cost_micro_usd") != null);
}

const Trust = struct {
    approved: ?loader.Hash = null,

    fn port(t: *Trust) loader.TrustPort {
        return .{ .ctx = t, .isApproved = isApproved };
    }

    fn isApproved(ctx: *anyopaque, name: []const u8, hash: loader.Hash) bool {
        const t: *Trust = @ptrCast(@alignCast(ctx));
        _ = name;
        return if (t.approved) |h| std.mem.eql(u8, &h, &hash) else false;
    }
};

test "repo_automation_requires_trust" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "daily-digest.zon", .data = digest_src });
    try tmp.dir.writeFile(io, .{ .sub_path = "broken.zon", .data = ".{" });
    try tmp.dir.writeFile(io, .{ .sub_path = "notes.txt", .data = "ignored" });
    var trust: Trust = .{};
    var r = try loader.loadAll(io, gpa, tmp.dir, trust.port());
    defer r.deinit();
    try testing.expectEqual(@as(usize, 2), r.items.len);
    try testing.expectEqualStrings("broken", r.items[0].name);
    try testing.expectEqual(@as(usize, 1), r.problems());
    const d = r.find("daily-digest").?;
    try testing.expect(d.needs_approval);
    // Loaded, but disabled until approved.
    const list = try r.automations();
    try testing.expectEqual(@as(usize, 1), list.len);
    try testing.expect(!list[0].enabled);
    // Approving this content enables it.
    trust.approved = d.hash;
    var r2 = try loader.loadAll(io, gpa, tmp.dir, trust.port());
    defer r2.deinit();
    try testing.expect(!r2.find("daily-digest").?.needs_approval);
    try testing.expect((try r2.automations())[0].enabled);
    // A changed file needs approval again.
    try tmp.dir.writeFile(io, .{ .sub_path = "daily-digest.zon", .data = digest_src ++ "\n" });
    var r3 = try loader.loadAll(io, gpa, tmp.dir, trust.port());
    defer r3.deinit();
    try testing.expect(r3.find("daily-digest").?.needs_approval);
}

test "parse local times" {
    const l = auto.parseLocal("2026-03-29T02:30").?;
    try testing.expectEqual(@as(u5, 2), l.hour);
    try testing.expectEqual(@as(u6, 15), auto.parseLocal("2026-03-29 02:30:15").?.second);
    try testing.expect(auto.parseLocal("2026-02-30 00:00") == null);
    try testing.expect(auto.parseLocal("2026-1-1 00:00") == null);
    try testing.expect(auto.validName("a-1"));
    try testing.expect(!auto.validName("-a"));
    try testing.expect(!auto.validName("A"));
}
