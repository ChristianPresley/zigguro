//! The workflow progress view model (E13.F08.S01.T02): a run's progress
//! snapshot turned into phases, step rows with done/failed/running/queued
//! counts, totals for the header, and the drill-down state (the open
//! step's agents with a status filter, the agent in detail). Pure and
//! headless; `zg_agents_ui.workflow_view` draws it.
//!
//! `apply` skips a snapshot whose version it has seen, so a frame with no
//! change costs one comparison. Arrays are copied into the VM's arena;
//! strings stay shared with the engine's tracker and live until the
//! engine forgets the run.

const std = @import("std");
const run = @import("../runs/run.zig");
const def = @import("def.zig");
const progress = @import("progress.zig");

const Allocator = std.mem.Allocator;
const RunId = run.RunId;
const WorkflowProgress = progress.WorkflowProgress;
const StepProgress = progress.StepProgress;
const Worker = progress.Worker;

/// Which agents the open step lists (`f` cycles).
pub const Filter = enum {
    all,
    running,
    failed,
    done,

    pub fn next(f: Filter) Filter {
        return @enumFromInt((@as(usize, @intFromEnum(f)) + 1) % std.meta.fields(Filter).len);
    }

    pub fn matches(f: Filter, s: progress.WorkerState) bool {
        return switch (f) {
            .all => true,
            .running => s == .running,
            .failed => s == .failed or s == .stopped,
            .done => s == .done,
        };
    }

    pub fn name(f: Filter) []const u8 {
        return @tagName(f);
    }
};

pub const StepRow = struct {
    p: StepProgress,
    /// Items not started yet.
    queued: u32,
    /// Indices into `WorkflowVM.workers` of this step's attempts.
    workers: []const u32,
};

pub const Phase = struct {
    /// Null for steps without a phase.
    title: ?[]const u8,
    /// Indices into `WorkflowVM.steps`.
    steps: []const u32,
    collapsed: bool,
};

/// A visible row of the step list.
pub const Item = union(enum) { phase: u32, step: u32 };

pub const Totals = struct {
    /// Agent attempts started.
    agents: u32 = 0,
    running: u32 = 0,
    done: u32 = 0,
    failed: u32 = 0,
    tokens: u64 = 0,
    cost_micros: u64 = 0,
    budget_micros: ?u64 = null,

    /// 0..1 of the cost budget spent (null without a budget).
    pub fn budgetUsed(t: Totals) ?f32 {
        const b = t.budget_micros orelse return null;
        if (b == 0) return 1;
        return @min(1, @as(f32, @floatFromInt(t.cost_micros)) / @as(f32, @floatFromInt(b)));
    }
};

pub const WorkflowVM = struct {
    gpa: Allocator,
    /// The arrays of the last snapshot; reset by every `apply`.
    arena: std.heap.ArenaAllocator,
    version: u64 = 0,
    run: RunId = .zero,
    name: []const u8 = "",
    status: run.RunStatus = .queued,
    gate: ?progress.Gate = null,
    error_: ?[]const u8 = null,
    started_ms: i64 = 0,
    steps: []StepRow = &.{},
    phases: []Phase = &.{},
    workers: []const Worker = &.{},
    totals: Totals = .{},
    /// Phase titles the user collapsed (gpa-owned keys).
    collapsed: std.StringHashMapUnmanaged(void) = .empty,
    items: std.ArrayList(Item) = .empty,
    /// The focused row of `items`.
    cursor: usize = 0,
    /// The step whose agents are listed (index into `steps`).
    open_step: ?u32 = null,
    filter: Filter = .all,
    /// The open step's agents after the filter (indices into `workers`).
    agents: std.ArrayList(u32) = .empty,
    agent_cursor: usize = 0,
    /// The agent shown in detail.
    detail: ?RunId = null,
    prompt_expanded: bool = false,
    /// Applies that changed something (tests).
    applies: u32 = 0,

    pub fn init(gpa: Allocator) WorkflowVM {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(vm: *WorkflowVM) void {
        var it = vm.collapsed.keyIterator();
        while (it.next()) |k| vm.gpa.free(k.*);
        vm.collapsed.deinit(vm.gpa);
        vm.items.deinit(vm.gpa);
        vm.agents.deinit(vm.gpa);
        vm.arena.deinit();
    }

    /// Takes a new snapshot; false (and nothing done) when its version
    /// was already applied.
    pub fn apply(vm: *WorkflowVM, p: *const WorkflowProgress) Allocator.Error!bool {
        if (p.version == vm.version and p.run.eql(vm.run)) return false;
        const keep_detail = vm.detail;
        const open_id: ?[]const u8 = if (vm.open_step) |i| vm.steps[i].p.id else null;
        const cursor_item: ?Item = if (vm.cursor < vm.items.items.len) vm.items.items[vm.cursor] else null;
        const cursor_step: ?[]const u8 = if (cursor_item) |it| switch (it) {
            .step => |i| vm.steps[i].p.id,
            .phase => null,
        } else null;

        _ = vm.arena.reset(.retain_capacity);
        const a = vm.arena.allocator();
        vm.version = p.version;
        vm.run = p.run;
        vm.name = p.name;
        vm.status = p.status;
        vm.gate = p.gate;
        vm.error_ = p.error_;
        vm.started_ms = p.started_ms;
        vm.workers = try a.dupe(Worker, p.workers);
        vm.applies += 1;

        // Step rows and each step's attempts.
        const steps = try a.alloc(StepRow, p.steps.len);
        const counts = try a.alloc(u32, p.steps.len);
        @memset(counts, 0);
        var by_id: std.StringHashMapUnmanaged(u32) = .empty;
        try by_id.ensureTotalCapacity(a, @intCast(p.steps.len));
        for (p.steps, 0..) |s, i| by_id.putAssumeCapacity(s.id, @intCast(i));
        var t: Totals = .{ .cost_micros = p.cost.micros, .tokens = p.cost.input_tokens + p.cost.output_tokens, .budget_micros = p.budget_micros };
        for (vm.workers) |w| {
            if (by_id.get(w.step)) |i| counts[i] += 1;
            t.agents += 1;
            switch (w.state) {
                .running => t.running += 1,
                .done => t.done += 1,
                .failed, .stopped => t.failed += 1,
            }
        }
        // Each step's attempts as a slice of one array, in start order.
        const slots = try a.alloc(u32, vm.workers.len);
        const fill = try a.alloc(u32, p.steps.len);
        var off: u32 = 0;
        for (p.steps, steps, counts, fill) |s, *r, n, *f| {
            r.* = .{ .p = s, .queued = s.total -| (s.done + s.failed + s.running), .workers = slots[off..][0..n] };
            f.* = off;
            off += n;
        }
        for (vm.workers, 0..) |w, wi| {
            const i = by_id.get(w.step) orelse continue;
            slots[fill[i]] = @intCast(wi);
            fill[i] += 1;
        }
        vm.steps = steps;
        vm.totals = t;

        // Phases: runs of steps with the same phase, in plan order.
        var phases: std.ArrayList(Phase) = .empty;
        var cur: std.ArrayList(u32) = .empty;
        var title: ?[]const u8 = null;
        for (steps, 0..) |r, i| {
            const ph = r.p.phase;
            if (i > 0 and !samePhase(ph, title)) {
                try phases.append(a, .{ .title = title, .steps = try cur.toOwnedSlice(a), .collapsed = vm.isCollapsed(title) });
            }
            title = ph;
            try cur.append(a, @intCast(i));
        }
        if (cur.items.len > 0) try phases.append(a, .{ .title = title, .steps = try cur.toOwnedSlice(a), .collapsed = vm.isCollapsed(title) });
        vm.phases = phases.items;

        try vm.rebuildItems();
        // Keep the cursor, the open step and the detail on the same ids.
        if (cursor_step) |id| if (vm.findItemStep(id)) |c| {
            vm.cursor = c;
        };
        vm.cursor = @min(vm.cursor, vm.items.items.len -| 1);
        vm.open_step = if (open_id) |id| vm.stepIndex(id) else null;
        try vm.refreshAgents();
        if (keep_detail) |d| if (vm.workerIndex(d) == null) {
            vm.detail = null;
        };
        return true;
    }

    fn samePhase(a: ?[]const u8, b: ?[]const u8) bool {
        if (a == null or b == null) return a == null and b == null;
        return std.mem.eql(u8, a.?, b.?);
    }

    fn isCollapsed(vm: *const WorkflowVM, title: ?[]const u8) bool {
        return vm.collapsed.contains(title orelse "");
    }

    /// Only phases with a title get a header row; their steps are hidden
    /// while collapsed.
    fn rebuildItems(vm: *WorkflowVM) Allocator.Error!void {
        vm.items.clearRetainingCapacity();
        for (vm.phases, 0..) |ph, pi| {
            if (ph.title != null) try vm.items.append(vm.gpa, .{ .phase = @intCast(pi) });
            if (ph.collapsed) continue;
            for (ph.steps) |si| try vm.items.append(vm.gpa, .{ .step = si });
        }
    }

    pub fn stepIndex(vm: *const WorkflowVM, id: []const u8) ?u32 {
        for (vm.steps, 0..) |r, i| if (std.mem.eql(u8, r.p.id, id)) return @intCast(i);
        return null;
    }

    fn findItemStep(vm: *const WorkflowVM, id: []const u8) ?usize {
        for (vm.items.items, 0..) |it, i| switch (it) {
            .step => |s| if (std.mem.eql(u8, vm.steps[s].p.id, id)) return i,
            .phase => {},
        };
        return null;
    }

    pub fn workerIndex(vm: *const WorkflowVM, child: RunId) ?usize {
        var i = vm.workers.len;
        while (i > 0) {
            i -= 1;
            if (vm.workers[i].child.eql(child)) return i;
        }
        return null;
    }

    pub fn worker(vm: *const WorkflowVM, child: RunId) ?*const Worker {
        return &vm.workers[vm.workerIndex(child) orelse return null];
    }

    /// The step under the cursor.
    pub fn cursorStep(vm: *const WorkflowVM) ?u32 {
        if (vm.cursor >= vm.items.items.len) return null;
        return switch (vm.items.items[vm.cursor]) {
            .step => |s| s,
            .phase => null,
        };
    }

    pub fn move(vm: *WorkflowVM, delta: i32) void {
        if (vm.open_step != null) {
            const n = vm.agents.items.len;
            if (n == 0) return;
            vm.agent_cursor = clampMove(vm.agent_cursor, delta, n);
            return;
        }
        const n = vm.items.items.len;
        if (n == 0) return;
        vm.cursor = clampMove(vm.cursor, delta, n);
    }

    fn clampMove(at: usize, delta: i32, n: usize) usize {
        const v = @as(i64, @intCast(at)) + delta;
        return @intCast(std.math.clamp(v, 0, @as(i64, @intCast(n - 1))));
    }

    /// Collapses or expands the phase under the cursor (or the cursor
    /// step's phase).
    pub fn togglePhase(vm: *WorkflowVM) Allocator.Error!void {
        if (vm.cursor >= vm.items.items.len) return;
        const pi: u32 = switch (vm.items.items[vm.cursor]) {
            .phase => |p| p,
            .step => |s| vm.phaseOf(s) orelse return,
        };
        const ph = &vm.phases[pi];
        const key = ph.title orelse return;
        if (vm.collapsed.fetchRemove(key)) |kv| {
            vm.gpa.free(kv.key);
            ph.collapsed = false;
        } else {
            const k = try vm.gpa.dupe(u8, key);
            errdefer vm.gpa.free(k);
            try vm.collapsed.put(vm.gpa, k, {});
            ph.collapsed = true;
        }
        try vm.rebuildItems();
        for (vm.items.items, 0..) |it, i| if (it == .phase and it.phase == pi) {
            vm.cursor = i;
        };
        vm.cursor = @min(vm.cursor, vm.items.items.len -| 1);
    }

    fn phaseOf(vm: *const WorkflowVM, step: u32) ?u32 {
        for (vm.phases, 0..) |ph, pi| for (ph.steps) |s| if (s == step) return @intCast(pi);
        return null;
    }

    /// Enter: opens the cursor step's agent list; on a phase row, folds it.
    pub fn drill(vm: *WorkflowVM) Allocator.Error!void {
        const s = vm.cursorStep() orelse return vm.togglePhase();
        vm.open_step = s;
        vm.agent_cursor = 0;
        vm.detail = null;
        try vm.refreshAgents();
    }

    /// Escape: closes the detail, then the agent list.
    pub fn back(vm: *WorkflowVM) bool {
        if (vm.detail != null) {
            vm.detail = null;
            vm.prompt_expanded = false;
            return true;
        }
        if (vm.open_step != null) {
            vm.open_step = null;
            vm.agents.clearRetainingCapacity();
            return true;
        }
        return false;
    }

    pub fn cycleFilter(vm: *WorkflowVM) Allocator.Error!void {
        vm.filter = vm.filter.next();
        vm.agent_cursor = 0;
        try vm.refreshAgents();
    }

    fn refreshAgents(vm: *WorkflowVM) Allocator.Error!void {
        vm.agents.clearRetainingCapacity();
        const s = vm.open_step orelse return;
        for (vm.steps[s].workers) |wi| if (vm.filter.matches(vm.workers[wi].state)) try vm.agents.append(vm.gpa, wi);
        vm.agent_cursor = @min(vm.agent_cursor, vm.agents.items.len -| 1);
    }

    /// The agent under the agent-list cursor.
    pub fn cursorAgent(vm: *const WorkflowVM) ?*const Worker {
        if (vm.open_step == null or vm.agent_cursor >= vm.agents.items.len) return null;
        return &vm.workers[vm.agents.items[vm.agent_cursor]];
    }

    /// Opens the cursor agent's detail.
    pub fn showDetail(vm: *WorkflowVM) void {
        const w = vm.cursorAgent() orelse return;
        vm.detail = w.child;
        vm.prompt_expanded = false;
    }

    /// Attempts made at `w.pos` up to and including `w`.
    pub fn attemptsAt(vm: *const WorkflowVM, w: *const Worker) u32 {
        var n: u32 = 0;
        for (vm.workers) |o| if (std.mem.eql(u8, o.step, w.step) and std.mem.eql(u8, o.pos, w.pos)) {
            n += 1;
        };
        return n;
    }

    /// Whether the mini-map is worth showing: the plan branches.
    pub fn branches(vm: *const WorkflowVM) bool {
        for (vm.steps) |r| if (r.p.kind == .parallel or r.p.kind == .vote) return true;
        return false;
    }
};

/// Colours of the mini-map's step states (`#rrggbb`).
pub const MiniMapColors = struct {
    pending: []const u8 = "#8c959f",
    running: []const u8 = "#0969da",
    waiting: []const u8 = "#bf8700",
    done: []const u8 = "#1a7f37",
    failed: []const u8 = "#cf222e",
    skipped: []const u8 = "#d0d7de",
};

/// A Mermaid flowchart (top to bottom) of the steps: one node per step,
/// parallel branches fanning out and back in, vote steps showing their
/// copies, each node coloured by its state. The view lays it out with
/// zg_diagram when the source changes.
pub fn miniMap(vm: *const WorkflowVM, w: *std.Io.Writer, colors: MiniMapColors) std.Io.Writer.Error!void {
    try w.writeAll("flowchart TB\n");
    inline for (std.meta.fields(progress.StepState)) |f| {
        try w.print("  classDef {s} fill:{s},stroke:{s},color:#ffffff\n", .{ f.name, @field(colors, f.name), @field(colors, f.name) });
    }
    // The ends of the previous top-level step (its branches after a
    // parallel).
    var ends: [64]u32 = undefined;
    var n_ends: usize = 0;
    var i: usize = 0;
    while (i < vm.steps.len) {
        const r = vm.steps[i];
        try node(w, @intCast(i), r);
        for (ends[0..n_ends]) |e| try w.print("  s{d} --> s{d}\n", .{ e, i });
        n_ends = 0;
        var j = i + 1;
        if (r.p.kind == .parallel) {
            // Branches follow their parallel step.
            while (j < vm.steps.len and vm.steps[j].p.parent != null and std.mem.eql(u8, vm.steps[j].p.parent.?, r.p.id)) : (j += 1) {
                try node(w, @intCast(j), vm.steps[j]);
                try w.print("  s{d} --> s{d}\n", .{ i, j });
                if (n_ends < ends.len) {
                    ends[n_ends] = @intCast(j);
                    n_ends += 1;
                }
            }
        }
        if (n_ends == 0) {
            ends[0] = @intCast(i);
            n_ends = 1;
        }
        i = j;
    }
}

fn node(w: *std.Io.Writer, i: u32, r: StepRow) std.Io.Writer.Error!void {
    try w.print("  s{d}[\"", .{i});
    try label(w, r.p.label orelse r.p.id);
    if (r.p.total > 1) try w.print(" {d}/{d}", .{ r.p.done, r.p.total });
    try w.print("\"]:::{s}\n", .{@tagName(r.p.state)});
}

/// Quotes and brackets would end the label.
fn label(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    const cut = s[0..@min(s.len, 40)];
    for (cut) |c| try w.writeByte(switch (c) {
        '"', '[', ']', '\n', '\r' => ' ',
        else => c,
    });
}

/// The view's actions: each is a palette command (`workflow.*`) with a
/// default key, and the `zg workflow` subcommand doing the same where
/// one exists.
pub const Action = enum { pause, stop, @"resume", drill, back, filter, show_agent, stop_agent, restart_agent, open_transcript, approve, reject, save_as, toggle_prompt, toggle_phase };

pub const ActionEntry = struct {
    action: Action,
    command: []const u8,
    title: []const u8,
    key: []const u8,
    cli: ?[]const u8 = null,
};

pub const actions = blk: {
    var t: [std.meta.fields(Action).len]ActionEntry = undefined;
    for (&t, std.meta.fields(Action)) |*e, f| e.* = entryOf(@enumFromInt(f.value));
    break :blk t;
};

fn entryOf(a: Action) ActionEntry {
    return switch (a) {
        .pause => .{ .action = a, .command = "workflow.pause", .title = "Workflow: Pause or Continue", .key = "p" },
        .stop => .{ .action = a, .command = "workflow.stop", .title = "Workflow: Stop", .key = "ctrl+x", .cli = "stop" },
        .@"resume" => .{ .action = a, .command = "workflow.resume", .title = "Workflow: Resume (Reuse Finished Agents)", .key = "shift+r", .cli = "resume" },
        .drill => .{ .action = a, .command = "workflow.openStep", .title = "Workflow: Show Step Agents", .key = "enter", .cli = "status" },
        .back => .{ .action = a, .command = "workflow.back", .title = "Workflow: Back", .key = "escape" },
        .filter => .{ .action = a, .command = "workflow.filterAgents", .title = "Workflow: Cycle Agent Filter", .key = "f" },
        .show_agent => .{ .action = a, .command = "workflow.showAgent", .title = "Workflow: Show Agent Detail", .key = "space" },
        .stop_agent => .{ .action = a, .command = "workflow.stopAgent", .title = "Workflow: Stop Agent", .key = "x" },
        .restart_agent => .{ .action = a, .command = "workflow.restartAgent", .title = "Workflow: Restart Agent", .key = "r" },
        .open_transcript => .{ .action = a, .command = "workflow.openTranscript", .title = "Workflow: Open Agent Transcript", .key = "enter" },
        .approve => .{ .action = a, .command = "workflow.approveGate", .title = "Workflow: Approve Gate", .key = "ctrl+enter" },
        .reject => .{ .action = a, .command = "workflow.rejectGate", .title = "Workflow: Reject Gate", .key = "ctrl+backspace" },
        .save_as => .{ .action = a, .command = "workflow.saveAs", .title = "Workflow: Save as Workflow", .key = "ctrl+s", .cli = "save" },
        .toggle_prompt => .{ .action = a, .command = "workflow.togglePrompt", .title = "Workflow: Expand Agent Prompt", .key = "e" },
        .toggle_phase => .{ .action = a, .command = "workflow.togglePhase", .title = "Workflow: Fold Phase", .key = "space" },
    };
}

pub fn entry(a: Action) ActionEntry {
    return actions[@intFromEnum(a)];
}
