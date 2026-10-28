//! The workflow progress view in a headless zg_gui window over a real
//! engine with scripted workers: a running map with drill-down, filter,
//! detail and stop agent; a pending gate answered from its card; a failed
//! step; save as workflow; the mini-map of a branching plan.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");
const view = @import("workflow_view.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const TestApp = zg_gui.testing.TestApp;
const runs = zg_agents.runs;
const wf = zg_agents.workflow;
const fake = wf.fake_workers;
const RunId = runs.RunId;

fn script(_: *fake.Fake, j: fake.Job) fake.Reply {
    if (std.mem.eql(u8, j.step, "each")) {
        if (std.mem.eql(u8, j.pos, "each#0")) return .{ .text = "{\"ok\":true,\"n\":1}" };
        return .hang;
    }
    if (std.mem.eql(u8, j.step, "bad")) return .{ .fail = "the model refused" };
    return .{ .text = "done" };
}

const Saver = struct {
    name: ?[]u8 = null,
    fn save(ctx: *anyopaque, _: RunId, name: []const u8) anyerror!?u64 {
        const s: *Saver = @ptrCast(@alignCast(ctx));
        s.name = try gpa.dupe(u8, name);
        return 42;
    }
};

const Fx = struct {
    reg: *runs.RunRegistry,
    eng: *wf.WorkflowEngine,
    fake: fake.Fake,
    parsed: ?wf.parse.Parsed = null,
    v: ?*view.WorkflowView = null,
    t: *TestApp,
    saver: Saver = .{},

    pub fn build(f: *Fx, ui: *zg_gui.Ui) void {
        if (f.v) |v| view.workflowView(ui, v);
    }

    fn init(f: *Fx) !void {
        f.* = .{ .reg = undefined, .eng = undefined, .fake = undefined, .t = undefined };
        f.reg = try runs.RunRegistry.init(gpa, io, null, .{});
        try f.fake.init(gpa, io, script);
        f.eng = try wf.WorkflowEngine.init(gpa, io, f.reg, .{ .workers = f.fake.port(), .stall_poll_ms = 10 });
        f.fake.eng = f.eng;
        f.t = try TestApp.init(gpa, .{ .root = .of(f), .size = .{ .w = 1000, .h = 1200 } });
    }

    fn start(f: *Fx, src: [:0]const u8, args: []const u8) !RunId {
        var diags: wf.Diagnostics = .init(gpa);
        defer diags.deinit();
        f.parsed = try wf.parse.parseOnly(gpa, src, &diags);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), args, .{});
        const id = try f.eng.start(&f.parsed.?.def, a, .{});
        f.v = try view.WorkflowView.init(gpa, .{ .eng = f.eng, .run = id, .save = .{ .ctx = &f.saver, .f = Saver.save } });
        return id;
    }

    fn deinit(f: *Fx) void {
        if (f.v) |v| v.detach();
        f.t.app.joinWork();
        _ = f.t.app.drainMessages();
        const v = f.v;
        f.v = null;
        // The mini-map's textures belong to the window.
        if (v) |x| x.deinit();
        f.t.deinit();
        f.eng.deinit();
        f.fake.deinit();
        f.reg.deinit();
        if (f.parsed) |*p| p.deinit();
        if (f.saver.name) |n| gpa.free(n);
    }

    fn settle(f: *Fx) void {
        f.t.win.markAllDirty();
        _ = f.t.settle();
    }

    fn focus(f: *Fx) !void {
        const n = f.t.find(.{ .role = .list, .name = "Workflow steps" }) orelse return error.NoList;
        f.t.win.setFocus(n, true);
        _ = f.t.settle();
    }

    /// Re-renders until `pred` holds (the engine runs on other threads).
    fn until(f: *Fx, comptime pred: fn (*Fx) bool) !void {
        var i: u32 = 0;
        while (i < 2_000) : (i += 1) {
            f.settle();
            if (pred(f)) return;
            io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
        return error.Timeout;
    }

    fn has(f: *Fx, s: []const u8) bool {
        return f.t.find(.{ .name_contains = s }) != null;
    }
};

const map_src =
    \\.{ .version = 1, .name = "audit", .limits = .{ .max_cost_micros = 1000000 },
    \\  .steps = .{
    \\    .{ .id = "each", .phase = "Audit", .map = .{ .over = "$args.items", .agent = .{ .label = "Audit", .prompt = "audit {{$item}}\nline two\nline three\nline four" } } },
    \\    .{ .id = "sum", .phase = "Report", .reduce = .{ .prompt = "sum {{$.each}}" } },
    \\  },
    \\}
;

test "running map: drill down, filter, detail, stop agent" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.start(map_src, "{\"items\":[1,2,3]}");
    try f.until(struct {
        fn p(x: *Fx) bool {
            return x.v.?.vm.totals.running == 2 and x.v.?.vm.totals.done == 1;
        }
    }.p);
    try testing.expect(f.t.find(.{ .test_id = "workflow-budget" }) != null);
    try testing.expect(f.has("audit, working"));
    try testing.expect(f.has("1 of 3 agents done"));
    try testing.expect(f.has("Audit, map, running, 1 done, 0 failed, 2 running, 0 queued"));
    try testing.expect(f.has("Report (0/1 steps)"));

    // Phase row, then the map step: Enter lists its agents.
    try f.focus();
    f.t.press(.arrow_down, .{});
    f.t.press(.enter, .{});
    f.settle();
    try testing.expect(f.t.find(.{ .test_id = "workflow-agents" }) != null);
    try testing.expectEqual(@as(usize, 3), f.t.count(.{ .role = .listitem, .name_contains = "each#" }));
    f.t.press(.key_f, .{}); // running
    f.settle();
    try testing.expectEqual(@as(usize, 2), f.t.count(.{ .role = .listitem, .name_contains = "each#" }));
    f.t.press(.key_f, .{}); // failed
    f.t.press(.key_f, .{}); // done
    f.settle();
    try testing.expectEqual(@as(usize, 1), f.t.count(.{ .role = .listitem, .name_contains = "each#" }));
    // Detail of the finished agent: pretty JSON, the prompt cut to 3 lines.
    f.t.press(.space, .{});
    f.settle();
    try testing.expect(f.t.find(.{ .test_id = "workflow-agent-detail" }) != null);
    try testing.expect(f.t.find(.{ .kind = "text", .name = "{\n  \"ok\": true,\n  \"n\": 1\n}" }) != null);
    try testing.expect(f.t.find(.{ .kind = "text", .name = "audit 1\nline two\nline three" }) != null);
    f.t.press(.key_e, .{});
    f.settle();
    try testing.expect(f.t.find(.{ .kind = "text", .name = "audit 1\nline two\nline three\nline four" }) != null);

    // Back to all, stop a running agent: its item fails.
    f.t.press(.escape, .{});
    f.t.press(.key_f, .{}); // all
    f.t.press(.arrow_down, .{});
    f.t.press(.key_x, .{});
    try f.until(struct {
        fn p(x: *Fx) bool {
            return x.v.?.vm.totals.failed == 1;
        }
    }.p);
    // Ctrl+X twice stops the workflow.
    f.t.press(.escape, .{});
    f.t.press(.key_x, .{ .ctrl = true });
    f.settle();
    try testing.expect(f.has("Press Ctrl+X again"));
    f.t.press(.key_x, .{ .ctrl = true });
    try testing.expectEqual(runs.RunStatus.stopped, try f.eng.wait(id));
    f.settle();
    try testing.expect(f.has("audit, stopped"));
}

test "gate pending: the card approves" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.start(
        \\.{ .version = 1, .name = "gated", .steps = .{
        \\  .{ .id = "draft", .agent = .{ .prompt = "write" } },
        \\  .{ .id = "ok", .gate = .{ .title = "Ship the draft?", .show = "$.draft" } },
        \\} }
    , "{}");
    try f.until(struct {
        fn p(x: *Fx) bool {
            return x.v.?.vm.gate != null;
        }
    }.p);
    try testing.expect(f.t.find(.{ .test_id = "workflow-gate" }) != null);
    try testing.expect(f.t.find(.{ .kind = "text", .name = "done" }) != null);
    try f.t.click(.{ .role = .button, .name = "Approve" });
    try testing.expectEqual(runs.RunStatus.completed, try f.eng.wait(id));
    f.settle();
    try testing.expect(f.t.find(.{ .test_id = "workflow-gate" }) == null);

    // Save as workflow (the run has ended).
    try f.t.click(.{ .role = .button, .name = "Save as workflow…" });
    try testing.expect(f.t.find(.{ .test_id = "workflow-save" }) != null);
    f.v.?.save("my-gate");
    f.settle();
    try testing.expectEqualStrings("my-gate", f.saver.name.?);
    try testing.expect(f.has("changeset 42"));
}

test "failed step shows its error" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.start(
        \\.{ .version = 1, .name = "broken", .steps = .{ .{ .id = "bad", .agent = .{ .prompt = "x", .max_retries = 0 } } } }
    , "{}");
    try testing.expectEqual(runs.RunStatus.failed, try f.eng.wait(id));
    f.settle();
    try testing.expect(f.has("bad, agent, failed"));
    try testing.expect(f.t.find(.{ .kind = "text", .name_contains = "the model refused" }) != null);
}

test "branching plans get a mini-map" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    const id = try f.start(
        \\.{ .version = 1, .name = "fan", .steps = .{
        \\  .{ .id = "both", .parallel = .{ .{ .id = "x", .agent = .{ .prompt = "x" } }, .{ .id = "y", .agent = .{ .prompt = "y" } } } },
        \\  .{ .id = "end", .reduce = .{ .prompt = "z" } },
        \\} }
    , "{}");
    _ = try f.eng.wait(id);
    f.settle();
    f.t.app.joinWork();
    _ = f.t.app.drainMessages();
    f.settle();
    try testing.expect(f.t.find(.{ .test_id = "workflow-minimap" }) != null);
    try testing.expectEqual(@as(u32, 1), f.v.?.minimap.?.builds);
}

test "fmtDuration and prettyResult" {
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("4s", view.fmtDuration(&buf, 4_200));
    try testing.expectEqualStrings("2m 05s", view.fmtDuration(&buf, 125_000));
    try testing.expectEqualStrings("1h 03m", view.fmtDuration(&buf, 3_780_000));
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try testing.expectEqualStrings("plain", view.prettyResult(arena.allocator(), "plain"));
    try testing.expectEqualStrings("[\n  1\n]", view.prettyResult(arena.allocator(), "```json\n[1]\n```"));
}
