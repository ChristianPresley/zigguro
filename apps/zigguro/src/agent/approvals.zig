//! `ToolApprovals`: the agents' `Permission` in the IDE (E10 ↔ E16). Tool
//! calls that only read run at once; the rest are put to the user through
//! an E16 `ApprovalPort` (the workbench's `DialogApprovalPort`), and "Allow
//! for session" / "Always allow" let that tool run without asking again
//! until the workbench closes.
//!
//! Answers map as zg_ai expects: allow once, for session and always run
//! the call; a denial returns its reason to the model; an edited command
//! runs as `allow_edited` with the input's `command` replaced. The
//! `PreToolUse` hooks' hint is honoured: `hook_allow` skips the prompt,
//! `hook_ask` prompts even for reads and session-allowed tools.

const std = @import("std");
const zg_ai = @import("zg_ai");
const zg_security = @import("zg_security");

const Io = std.Io;
const proto = zg_ai.proto;
const deps = zg_ai.loop.deps;
const contracts = zg_security.contracts;

/// See the module doc.
pub const ToolApprovals = struct {
    gpa: std.mem.Allocator,
    port: contracts.ApprovalPort,
    /// Guards `allowed`.
    mutex: Io.Mutex = .init,
    /// Tools allowed for the session (owned names).
    allowed: std.StringHashMapUnmanaged(void) = .empty,
    /// Edited inputs handed to zg_ai (guarded by `mutex`; small and rare).
    edits: std.heap.ArenaAllocator,

    /// Approvals asked through `port`.
    pub fn init(gpa: std.mem.Allocator, port: contracts.ApprovalPort) ToolApprovals {
        return .{ .gpa = gpa, .port = port, .edits = .init(gpa) };
    }

    /// Frees the session's allowances.
    pub fn deinit(self: *ToolApprovals) void {
        var it = self.allowed.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.allowed.deinit(self.gpa);
        self.edits.deinit();
    }

    /// The `Permission` for `AgentManager`/`Agent.Deps`.
    pub fn permission(self: *ToolApprovals) deps.Permission {
        return .{ .ctx = self, .check = check, .check_hinted = checkHinted };
    }

    /// Whether `tool` was allowed for the session.
    pub fn isAllowed(self: *ToolApprovals, io: Io, tool: []const u8) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.allowed.contains(tool);
    }

    fn allow(self: *ToolApprovals, io: Io, tool: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.allowed.contains(tool)) return;
        const name = self.gpa.dupe(u8, tool) catch return;
        self.allowed.put(self.gpa, name, {}) catch self.gpa.free(name);
    }

    fn check(ctx: *anyopaque, io: Io, agent: proto.AgentRef, spec: *const proto.ToolSpec, input_json: []const u8) Io.Cancelable!deps.Decision {
        return checkHinted(ctx, io, agent, spec, input_json, .none);
    }

    fn checkHinted(ctx: *anyopaque, io: Io, agent: proto.AgentRef, spec: *const proto.ToolSpec, input_json: []const u8, hint: deps.Hint) Io.Cancelable!deps.Decision {
        const self: *ToolApprovals = @ptrCast(@alignCast(ctx));
        const fx = spec.effectiveEffects();
        switch (hint) {
            .hook_allow => return .allow,
            .hook_ask => {},
            .none => {
                if (fx.read_only) return .allow;
                if (self.isAllowed(io, spec.name)) return .allow;
            },
        }

        // The port copies every string before `present` returns.
        const session = proto.agent_ref.format(agent.session);
        var agent_buf: [16]u8 = undefined;
        const agent_name = if (agent.agent == 0) "main" else std.fmt.bufPrint(&agent_buf, "{d}", .{agent.agent}) catch "subagent";
        var title_buf: [160]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "Allow the agent to run {s}?", .{spec.name[0..@min(spec.name.len, 96)]}) catch "Allow this tool call?";
        var risk: [2][]const u8 = undefined;
        var nrisk: usize = 0;
        if (fx.executes) {
            risk[nrisk] = "Runs a program on this machine.";
            nrisk += 1;
        }
        if (fx.writes_workspace) {
            risk[nrisk] = "Changes files in the workspace.";
            nrisk += 1;
        }
        const command = commandOf(input_json);
        const req: contracts.ApprovalRequest = .{
            .kind = if (fx.executes) .command else .tool_call,
            .actor = .{ .agent = .{ .session = &session, .agent = agent_name } },
            .title = title,
            .detail_json = input_json,
            .command = command,
            .risk = risk[0..nrisk],
            .rule_suggestion = spec.name,
            .editable = command != null,
            .created_ms = 0,
        };
        const ticket = self.port.present(req) catch return .{ .deny = "the approval could not be shown" };
        const answer = ticket.await(io) catch |e| {
            ticket.cancel();
            return e;
        };
        return switch (answer) {
            .allow_once => .allow,
            .allow_session, .allow_always => blk: {
                self.allow(io, spec.name);
                break :blk .allow;
            },
            // The port keeps answer strings for its life.
            .deny => |reason| .{ .deny = if (reason.len > 0) reason else "the user denied this tool call" },
            .edit => |cmd| if (self.withCommand(io, input_json, cmd)) |json| .{ .allow_edited = json } else .{ .deny = "the edited input could not be used" },
        };
    }

    /// `input_json` with its `command` replaced by `cmd` (kept until
    /// `deinit`).
    fn withCommand(self: *ToolApprovals, io: Io, input_json: []const u8, cmd: []const u8) ?[]const u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const a = self.edits.allocator();
        var v = std.json.parseFromSliceLeaky(std.json.Value, a, input_json, .{}) catch return null;
        if (v != .object) return null;
        v.object.put(a, "command", .{ .string = a.dupe(u8, cmd) catch return null }) catch return null;
        return std.json.Stringify.valueAlloc(a, v, .{}) catch null;
    }
};

/// The `command` string of a run-style input, shown as the card's command.
fn commandOf(input_json: []const u8) ?[]const u8 {
    // A cheap scan: the field is a plain string in canonical JSON.
    const key = "\"command\":\"";
    const at = std.mem.indexOf(u8, input_json, key) orelse return null;
    const rest = input_json[at + key.len ..];
    var i: usize = 0;
    while (i < rest.len) : (i += 1) switch (rest[i]) {
        '\\' => return null, // escapes: show the JSON instead
        '"' => return rest[0..i],
        else => {},
    };
    return null;
}

const testing = std.testing;

fn noCall(_: *anyopaque, _: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
    return error.Unavailable;
}

fn toolSpec(name: []const u8, read_only: bool, fx: proto.Effects) proto.ToolSpec {
    return .{ .name = name, .description = "", .input_schema_json = "{}", .read_only = read_only, .effects = fx, .handler = .{ .ctx = undefined, .call = noCall } };
}

test "approvals: reads run, the rest ask; session answers stick" {
    var fp: zg_security.testing.FakeApprovalPort = .{ .gpa = testing.allocator };
    defer fp.deinit();
    var ap: ToolApprovals = .init(testing.allocator, fp.port());
    defer ap.deinit();
    const perm = ap.permission();
    const io = testing.io;
    const agent: proto.AgentRef = .{ .session = 7 };

    const read = toolSpec("read_file", true, .{});
    try testing.expectEqual(deps.Decision.allow, try perm.check(perm.ctx, io, agent, &read, "{}"));
    try testing.expectEqual(@as(usize, 0), fp.presented.items.len);

    const run = toolSpec("run", false, .{ .executes = true });
    try fp.answers.append(testing.allocator, .allow_once);
    try testing.expectEqual(deps.Decision.allow, try perm.check(perm.ctx, io, agent, &run, "{\"command\":\"make test\"}"));
    const shown = fp.presented.items[0];
    try testing.expectEqual(contracts.ApprovalKind.command, shown.kind);
    try testing.expectEqualStrings("make test", shown.command.?);
    try testing.expectEqualStrings("run", shown.rule_suggestion.?);

    // Denied with a reason, which goes back to the model.
    try fp.answers.append(testing.allocator, .{ .deny = "not now" });
    const d = try perm.check(perm.ctx, io, agent, &run, "{}");
    try testing.expectEqualStrings("not now", d.deny);

    // "Allow for session" stops the questions for that tool only.
    try fp.answers.append(testing.allocator, .{ .allow_session = "run" });
    _ = try perm.check(perm.ctx, io, agent, &run, "{}");
    const n = fp.presented.items.len;
    try testing.expectEqual(deps.Decision.allow, try perm.check(perm.ctx, io, agent, &run, "{}"));
    try testing.expectEqual(n, fp.presented.items.len);
    const edit = toolSpec("edit_file", false, .{ .writes_workspace = true });
    _ = try perm.check(perm.ctx, io, agent, &edit, "{}");
    try testing.expectEqual(n + 1, fp.presented.items.len);
}

test "approvals: hook hints and edited commands" {
    var fp: zg_security.testing.FakeApprovalPort = .{ .gpa = testing.allocator };
    defer fp.deinit();
    var ap: ToolApprovals = .init(testing.allocator, fp.port());
    defer ap.deinit();
    const perm = ap.permission();
    const io = testing.io;
    const agent: proto.AgentRef = .{ .session = 7 };
    const run = toolSpec("run", false, .{ .executes = true });
    const read = toolSpec("read_file", true, .{});

    // A hook allow skips the prompt; a hook ask prompts even for a read.
    try testing.expectEqual(deps.Decision.allow, try perm.decide(io, agent, &run, "{}", .hook_allow));
    try testing.expectEqual(@as(usize, 0), fp.presented.items.len);
    try fp.answers.append(testing.allocator, .allow_once);
    _ = try perm.decide(io, agent, &read, "{}", .hook_ask);
    try testing.expectEqual(@as(usize, 1), fp.presented.items.len);

    // The user rewrote the command: it runs with the rest of the input.
    try fp.answers.append(testing.allocator, .{ .edit = "make check" });
    const d = try perm.decide(io, agent, &run, "{\"command\":\"make test\",\"timeout\":5}", .none);
    try testing.expect(fp.presented.items[1].editable);
    const v = try std.json.parseFromSlice(std.json.Value, testing.allocator, d.allow_edited, .{});
    defer v.deinit();
    try testing.expectEqualStrings("make check", v.value.object.get("command").?.string);
    try testing.expectEqual(@as(i64, 5), v.value.object.get("timeout").?.integer);
}

test "approvals: the command is shown only when it is plain" {
    try testing.expectEqualStrings("ls -la", commandOf("{\"command\":\"ls -la\",\"x\":1}").?);
    try testing.expectEqual(@as(?[]const u8, null), commandOf("{\"command\":\"echo \\\"hi\\\"\"}"));
    try testing.expectEqual(@as(?[]const u8, null), commandOf("{\"path\":\"a\"}"));
}
