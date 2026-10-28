//! The workflow view model over hand-made snapshots (aggregation,
//! incremental updates, phases, drill-down and filters, the mini-map) and
//! over a real engine run (the worker list the tracker keeps).

const std = @import("std");
const t = @import("test_env.zig");
const run = @import("../runs/run.zig");
const progress = @import("progress.zig");
const vm_mod = @import("vm.zig");

const testing = std.testing;
const gpa = t.gpa;
const RunId = run.RunId;
const WorkflowVM = vm_mod.WorkflowVM;
const Worker = progress.Worker;
const StepProgress = progress.StepProgress;

fn id(n: u128) RunId {
    return .fromInt(n + 1);
}

/// A 3-step run: `files` done, `audit` mapping 250 items with 200 running
/// and 30 done / 20 failed, `report` pending.
const Snap = struct {
    steps: [3]StepProgress,
    workers: [250]Worker,
    version: u64 = 1,

    fn init(s: *Snap) void {
        s.steps = .{
            .{ .id = "files", .phase = "Collect", .kind = .builtin, .label = null, .state = .done, .total = 1, .done = 1 },
            .{ .id = "audit", .phase = "Audit", .kind = .map, .label = "Audit", .state = .running, .total = 300, .running = 200, .done = 30, .failed = 20, .retries = 3 },
            .{ .id = "report", .phase = "Audit", .kind = .reduce, .label = null },
        };
        for (&s.workers, 0..) |*w, i| w.* = .{
            .child = id(i),
            .step = "audit",
            .pos = "audit#x",
            .attempt = 0,
            .prompt = "audit a file",
            .started_ms = 1000,
            .state = if (i < 200) .running else if (i < 230) .done else .failed,
            .cost = .{ .micros = 10, .input_tokens = 5, .output_tokens = 1 },
        };
    }

    fn progressOf(s: *const Snap) progress.WorkflowProgress {
        return .{
            .run = id(999),
            .name = "audit-files",
            .status = .working,
            .steps = &s.steps,
            .agents = 250,
            .cost = .{ .micros = 2500, .input_tokens = 1250, .output_tokens = 250 },
            .workers = &s.workers,
            .started_ms = 1000,
            .budget_micros = 10_000,
            .version = s.version,
        };
    }
};

test "vm_aggregates_children" {
    var s: Snap = undefined;
    s.init();
    var vm: WorkflowVM = .init(gpa);
    defer vm.deinit();
    try testing.expect(try vm.apply(&s.progressOf()));
    try testing.expectEqual(@as(u32, 250), vm.totals.agents);
    try testing.expectEqual(@as(u32, 200), vm.totals.running);
    try testing.expectEqual(@as(u32, 30), vm.totals.done);
    try testing.expectEqual(@as(u32, 20), vm.totals.failed);
    try testing.expectEqual(@as(u64, 1500), vm.totals.tokens);
    try testing.expectApproxEqAbs(@as(f32, 0.25), vm.totals.budgetUsed().?, 0.001);
    const audit = vm.steps[vm.stepIndex("audit").?];
    try testing.expectEqual(@as(usize, 250), audit.workers.len);
    try testing.expectEqual(@as(u32, 50), audit.queued);
    try testing.expectEqual(@as(usize, 0), vm.steps[0].workers.len);
    // Two phases with headers: Collect (files), Audit (audit, report).
    try testing.expectEqual(@as(usize, 2), vm.phases.len);
    try testing.expectEqual(@as(usize, 5), vm.items.items.len);
}

test "vm_incremental_updates" {
    var s: Snap = undefined;
    s.init();
    var vm: WorkflowVM = .init(gpa);
    defer vm.deinit();
    _ = try vm.apply(&s.progressOf());
    // The same version is skipped.
    try testing.expect(!try vm.apply(&s.progressOf()));
    try testing.expectEqual(@as(u32, 1), vm.applies);
    // The cursor stays on its step across updates.
    vm.cursor = 4; // report
    try testing.expectEqualStrings("report", vm.steps[vm.cursorStep().?].p.id);
    s.workers[0].state = .done;
    s.steps[1].done += 1;
    s.steps[1].running -= 1;
    s.version += 1;
    try testing.expect(try vm.apply(&s.progressOf()));
    try testing.expectEqual(@as(u32, 31), vm.totals.done);
    try testing.expectEqualStrings("report", vm.steps[vm.cursorStep().?].p.id);
}

test "phases fold and the cursor follows" {
    var s: Snap = undefined;
    s.init();
    var vm: WorkflowVM = .init(gpa);
    defer vm.deinit();
    _ = try vm.apply(&s.progressOf());
    vm.cursor = 3; // audit
    try vm.togglePhase();
    try testing.expectEqual(@as(usize, 3), vm.items.items.len);
    try testing.expectEqual(vm_mod.Item{ .phase = 1 }, vm.items.items[vm.cursor]);
    // Folding survives a new snapshot.
    s.version += 1;
    _ = try vm.apply(&s.progressOf());
    try testing.expectEqual(@as(usize, 3), vm.items.items.len);
    try vm.drill(); // Enter on a phase row unfolds it.
    try testing.expectEqual(@as(usize, 5), vm.items.items.len);
}

test "filter_cycle" {
    var s: Snap = undefined;
    s.init();
    var vm: WorkflowVM = .init(gpa);
    defer vm.deinit();
    _ = try vm.apply(&s.progressOf());
    vm.cursor = 3;
    try vm.drill();
    try testing.expectEqual(@as(?u32, 1), vm.open_step);
    try testing.expectEqual(vm_mod.Filter.all, vm.filter);
    try testing.expectEqual(@as(usize, 250), vm.agents.items.len);
    try vm.cycleFilter();
    try testing.expectEqual(vm_mod.Filter.running, vm.filter);
    try testing.expectEqual(@as(usize, 200), vm.agents.items.len);
    try vm.cycleFilter();
    try testing.expectEqual(@as(usize, 20), vm.agents.items.len);
    try vm.cycleFilter();
    try testing.expectEqual(@as(usize, 30), vm.agents.items.len);
    try vm.cycleFilter();
    try testing.expectEqual(vm_mod.Filter.all, vm.filter);
    // Agent cursor and detail.
    vm.move(5);
    vm.showDetail();
    try testing.expect(vm.detail.?.eql(id(5)));
    try testing.expectEqual(@as(u32, 250), vm.attemptsAt(vm.worker(vm.detail.?).?));
    try testing.expect(vm.back());
    try testing.expect(vm.detail == null);
    try testing.expect(vm.back());
    try testing.expect(vm.open_step == null);
    try testing.expect(!vm.back());
}

test "mini-map fans parallel branches out and in" {
    const steps = [_]StepProgress{
        .{ .id = "plan", .phase = null, .kind = .agent, .label = null, .state = .done },
        .{ .id = "both", .phase = null, .kind = .parallel, .label = null, .state = .running },
        .{ .id = "x", .phase = null, .kind = .agent, .label = "Find \"x\"", .parent = "both", .state = .running },
        .{ .id = "y", .phase = null, .kind = .agent, .label = null, .parent = "both", .state = .failed },
        .{ .id = "pick", .phase = null, .kind = .vote, .label = null, .total = 3, .done = 1 },
    };
    const p: progress.WorkflowProgress = .{ .run = id(1), .name = "w", .status = .working, .steps = &steps, .agents = 0, .cost = .{}, .version = 1 };
    var vm: WorkflowVM = .init(gpa);
    defer vm.deinit();
    _ = try vm.apply(&p);
    try testing.expect(vm.branches());
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    try vm_mod.miniMap(&vm, &w.writer, .{});
    const src = w.written();
    for ([_][]const u8{
        "flowchart TB\n",
        "  s0[\"plan\"]:::done\n",
        "  s0 --> s1\n",
        "  s2[\"Find  x \"]:::running\n",
        "  s1 --> s2\n",
        "  s1 --> s3\n",
        "  s3[\"y\"]:::failed\n",
        "  s2 --> s4\n",
        "  s3 --> s4\n",
        "  s4[\"pick 1/3\"]:::pending\n",
    }) |line| {
        if (std.mem.indexOf(u8, src, line) == null) {
            std.debug.print("missing {s} in:\n{s}", .{ line, src });
            return error.TestUnexpectedResult;
        }
    }
    // It parses as a flowchart.
    const zg_diagram = @import("zg_diagram");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diags: std.ArrayList(zg_diagram.Diagnostic) = .empty;
    const d = (try zg_diagram.parse(arena.allocator(), src, &diags)).?;
    for (diags.items) |dg| try testing.expect(dg.severity != .err);
    try testing.expectEqual(@as(usize, 5), d.nodes.len);
}

test "every action has a workflow.* command" {
    for (vm_mod.actions, 0..) |e, i| {
        try testing.expectEqual(i, @intFromEnum(e.action));
        try testing.expect(std.mem.startsWith(u8, e.command, "workflow."));
    }
}

fn answers(_: *t.Fake, j: t.Job) t.Reply {
    if (std.mem.eql(u8, j.pos, "each#1") and j.attempt == 0) return .{ .fail = "boom" };
    return .{ .cost_then_text = .{ .cost = .{ .micros = 7, .input_tokens = 3 }, .text = "ok" } };
}

test "the engine records every attempt for the view" {
    var e: t.Env = undefined;
    try e.init(answers, .{});
    defer e.deinit();
    const rid = try e.runToEnd(
        \\.{ .version = 1, .name = "w", .steps = .{
        \\  .{ .id = "each", .phase = "Work", .map = .{ .over = "$args.items", .max_fail_ratio = 1.0, .agent = .{ .prompt = "do {{$item}}" } } },
        \\} }
    , "{\"items\":[1,2,3]}");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const p = (try e.eng.progress(rid, arena.allocator())).?;
    try testing.expectEqual(@as(usize, 3), p.workers.len);
    try testing.expect(p.started_ms > 0);
    var vm: WorkflowVM = .init(gpa);
    defer vm.deinit();
    _ = try vm.apply(&p);
    try testing.expectEqual(@as(u32, 2), vm.totals.done);
    try testing.expectEqual(@as(u32, 1), vm.totals.failed);
    for (p.workers) |w| {
        try testing.expect(w.ended_ms != null);
        if (w.state == .failed) try testing.expectEqualStrings("boom", w.text) else {
            try testing.expectEqualStrings("ok", w.text);
            try testing.expectEqual(@as(u64, 7), w.cost.micros);
        }
    }
}
