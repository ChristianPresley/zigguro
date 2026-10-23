//! The default mapping from run events to notifications (E13.F01.S03.T01):
//! a run that needs input, completes, fails or was interrupted. Workflow
//! workers share the group `wf:<workflow run id>`; interrupted runs share
//! `interrupted`. Every notification of a run has the key `run:<id>`, so
//! "needs input" then "done" within the rate-limit interval update one
//! notification. Pure.

const std = @import("std");
const run = @import("../runs/run.zig");
const n_mod = @import("notification.zig");

const Allocator = std.mem.Allocator;
const Notification = n_mod.Notification;
const NotifyAction = n_mod.NotifyAction;

const open: NotifyAction = .{ .id = "open", .label = "Open" };
const deny: NotifyAction = .{ .id = "deny", .label = "Deny" };
const needs_input_actions = [_]NotifyAction{open};
const approval_actions = [_]NotifyAction{ open, deny };
const open_actions = [_]NotifyAction{open};

/// The notification for `ev` on `rec` (its state after the event), or
/// null when the event is not worth one. Strings are in `arena`.
pub fn fromRunEvent(arena: Allocator, ev: run.RunEvent, rec: *const run.RunRecord) Allocator.Error!?Notification {
    if (ev.kind != .status) return null;
    const title = if (rec.spec.title.len > 0) rec.spec.title else firstLine(rec.spec.prompt);
    var n: Notification = .{
        .key = try std.fmt.allocPrint(arena, "run:{f}", .{rec.id}),
        .run = rec.id,
        .severity = .info,
        .title = title,
    };
    if (rec.spec.kind == .workflow_worker) if (rec.spec.parent) |p| {
        n.group = try std.fmt.allocPrint(arena, "wf:{f}", .{p});
    };
    switch (rec.status) {
        .needs_input => {
            const q = rec.question orelse "";
            n.severity = .needs_input;
            n.title = try std.fmt.allocPrint(arena, "{s} needs input", .{title});
            n.body = q;
            n.actions = if (isApproval(q)) &approval_actions else &needs_input_actions;
            // A question needs its own notification, not a group summary.
            n.group = null;
        },
        .completed => {
            n.severity = .success;
            n.title = try std.fmt.allocPrint(arena, "Done: {s}", .{title});
            const first = firstLine(rec.summary);
            n.body = if (rec.outputs.len == 0)
                first
            else
                try std.fmt.allocPrint(arena, "{s}{s}{d} output{s}", .{ first, if (first.len > 0) " \u{00B7} " else "", rec.outputs.len, if (rec.outputs.len == 1) "" else "s" });
            n.actions = &open_actions;
        },
        .failed => {
            n.severity = .error_;
            n.title = try std.fmt.allocPrint(arena, "Failed: {s}", .{title});
            n.body = rec.error_ orelse firstLine(rec.summary);
            n.actions = &open_actions;
        },
        .interrupted => {
            n.severity = .warning;
            n.title = try std.fmt.allocPrint(arena, "Interrupted: {s}", .{title});
            n.body = rec.error_ orelse "";
            n.group = "interrupted";
            n.actions = &open_actions;
        },
        else => return null,
    }
    return n;
}

/// A permission question (E16 asks "Allow ...?").
fn isApproval(q: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(q, "allow ") or std.ascii.startsWithIgnoreCase(q, "approve");
}

fn firstLine(s: []const u8) []const u8 {
    const line = s[0 .. std.mem.indexOfScalar(u8, s, '\n') orelse s.len];
    return line[0..@min(line.len, 200)];
}

const testing = std.testing;

test "from_run_event_mapping_golden" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const id: run.RunId = .fromInt(0x0123456789abcdef);
    const parent: run.RunId = .fromInt(0x42);
    const outs = [_]run.Output{ .{ .changeset = 3 }, .{ .file = "notes.md" } };
    const Case = struct { rec: run.RunRecord, want: []const u8 };
    const base: run.RunSpec = .{ .kind = .background, .title = "Fix build", .prompt = "p" };
    const worker: run.RunSpec = .{ .kind = .workflow_worker, .title = "step 2", .prompt = "p", .parent = parent };
    const cases = [_]Case{
        .{ .rec = .{ .id = id, .spec = base, .status = .needs_input, .question = "Allow `rm -rf build`?", .created_ms = 0 }, .want =
        \\needs_input run:0000000000000028T5CY4TQKFF "Fix build needs input" "Allow `rm -rf build`?" [open,deny]
        },
        .{ .rec = .{ .id = id, .spec = base, .status = .needs_input, .question = "Which branch?", .created_ms = 0 }, .want =
        \\needs_input run:0000000000000028T5CY4TQKFF "Fix build needs input" "Which branch?" [open]
        },
        .{ .rec = .{ .id = id, .spec = base, .status = .completed, .summary = "Fixed it\nmore", .outputs = &outs, .created_ms = 0 }, .want =
        \\success run:0000000000000028T5CY4TQKFF "Done: Fix build" "Fixed it · 2 outputs" [open]
        },
        .{ .rec = .{ .id = id, .spec = base, .status = .failed, .error_ = "provider error 529", .created_ms = 0 }, .want =
        \\error_ run:0000000000000028T5CY4TQKFF "Failed: Fix build" "provider error 529" [open]
        },
        .{ .rec = .{ .id = id, .spec = base, .status = .interrupted, .error_ = "host exited unexpectedly", .created_ms = 0 }, .want =
        \\warning run:0000000000000028T5CY4TQKFF group=interrupted "Interrupted: Fix build" "host exited unexpectedly" [open]
        },
        .{ .rec = .{ .id = id, .spec = worker, .status = .completed, .created_ms = 0 }, .want =
        \\success run:0000000000000028T5CY4TQKFF group=wf:00000000000000000000000022 "Done: step 2" "" [open]
        },
    };
    for (cases) |c| {
        const n = (try fromRunEvent(a, .{ .run = id, .revision = 2, .kind = .status }, &c.rec)).?;
        var buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try w.print("{t} {s}", .{ n.severity, n.key });
        if (n.group) |g| try w.print(" group={s}", .{g});
        try w.print(" \"{s}\" \"{s}\" [", .{ n.title, n.body });
        for (n.actions, 0..) |act, i| try w.print("{s}{s}", .{ if (i > 0) "," else "", act.id });
        try w.writeAll("]");
        try testing.expectEqualStrings(c.want, w.buffered());
    }
    // Not worth a notification.
    const quiet: run.RunRecord = .{ .id = id, .spec = base, .status = .working, .created_ms = 0 };
    try testing.expect(try fromRunEvent(a, .{ .run = id, .revision = 2, .kind = .status }, &quiet) == null);
    try testing.expect(try fromRunEvent(a, .{ .run = id, .revision = 2, .kind = .summary }, &doneRec(id, base)) == null);
}

fn doneRec(id: run.RunId, spec: run.RunSpec) run.RunRecord {
    return .{ .id = id, .spec = spec, .status = .completed, .created_ms = 0 };
}
