//! `HookEngine` (E10.F09.S03.T01): Claude Code compatible command hooks.
//!
//! Hooks come from settings layers (managed, user, project, local) and
//! from skill or agent frontmatter (scoped: they run only while that
//! skill or agent is active). For an event, every handler whose matcher
//! fits runs in parallel, identical commands once; each gets the event as
//! JSON on stdin and `ZIGGURO_PROJECT_DIR` (plus `CLAUDE_PROJECT_DIR` in
//! compat mode). Exit codes and JSON output follow `hook_io.zig`.
//!
//! Project and local hooks run only in a trusted workspace (E16), and with
//! an approver set, a project or local command runs only once the user
//! approved that exact command (hash-pinned). Each run goes to the audit
//! sink. `hooks()` plugs the engine into the agent loop.

const std = @import("std");
const builtin = @import("builtin");
const proto = @import("zg_ai_proto");
const deps = @import("../loop/deps.zig");
const ratelimit = @import("../provider/ratelimit.zig");
const hook_io = @import("hook_io.zig");
const hook_match = @import("hook_match.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.zg_ai_hooks);

pub const hook_io_mod = hook_io;
pub const HookEvent = hook_io.HookEvent;
pub const Input = hook_io.Input;
pub const Outcome = hook_io.Outcome;
pub const OnFailure = hook_io.OnFailure;

/// Per stream; the rest is read and dropped.
pub const output_cap = 1 << 20;
/// Longer `additionalContext` is saved to a file and previewed.
pub const context_cap = 10_000;

pub const Handler = struct {
    type: enum { command } = .command,
    command: []const u8,
    /// Exec form: run `command` with these arguments and no shell.
    args: ?[]const []const u8 = null,
    timeout_s: u32 = 60,
    shell: enum { auto, bash, sh, powershell } = .auto,
    on_failure: OnFailure = .@"continue",
    status_message: ?[]const u8 = null,
};

pub const HookConfig = struct {
    matcher: []const u8 = "*",
    hooks: []const Handler,
};

pub const Layer = enum { managed, user, project, local, scoped };

/// Hooks for one event from one place.
pub const Source = struct {
    layer: Layer,
    event: HookEvent,
    configs: []const HookConfig,
    /// The skill or agent that carries scoped hooks.
    scope: ?[]const u8 = null,
};

/// Asks the user before a project or local command first runs.
pub const CommandApprover = struct {
    ctx: *anyopaque,
    approve: *const fn (ctx: *anyopaque, io: Io, event: HookEvent, command: []const u8) Io.Cancelable!bool,
};

/// One hook run, for the audit log and the session.
pub const HookRun = struct {
    event: HookEvent,
    handler: []const u8,
    /// Null when killed or not started.
    exit: ?u8,
    duration_ms: u64,
    decision: []const u8,
};

pub const Audit = struct {
    ctx: *anyopaque,
    record: *const fn (ctx: *anyopaque, io: Io, run: HookRun) void,
    /// Non-blocking failures and `systemMessage`s.
    notice: ?*const fn (ctx: *anyopaque, io: Io, text: []const u8) void = null,
};

pub const Options = struct {
    project_dir: []const u8 = ".",
    /// The environment hooks start from; null starts empty.
    environ: ?*const std.process.Environ.Map = null,
    /// Claude Code compatibility: `CLAUDE_PROJECT_DIR` too.
    compat: bool = false,
    /// E16 workspace trust; project and local hooks need it.
    workspace_trusted: bool = false,
    /// `disableAllHooks`: only managed hooks run.
    disable_non_managed: bool = false,
    approver: ?CommandApprover = null,
    audit: ?Audit = null,
    /// Where long `additionalContext` is saved; null cuts it instead.
    spill_dir: ?[]const u8 = null,
    clock: ratelimit.Clock = .real,
    /// Filled into every input.
    session_id: []const u8 = "",
    transcript_path: ?[]const u8 = null,
    permission_mode: []const u8 = "default",
};

const Entry = struct {
    event: HookEvent,
    layer: Layer,
    scope: ?[]const u8,
    matcher: hook_match.Matcher,
    /// The matcher as written.
    matcher_text: []const u8,
    handler: Handler,
    /// Over the command and its arguments.
    hash: u64,
};

/// One configured hook, for `/hooks`.
pub const Listed = struct {
    event: HookEvent,
    layer: Layer,
    scope: ?[]const u8,
    matcher: []const u8,
    command: []const u8,
};

pub const HookEngine = struct {
    gpa: Allocator,
    io: Io,
    opts: Options,
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry) = .empty,
    env: std.process.Environ.Map,
    mutex: Io.Mutex = .init,
    approved: std.AutoHashMapUnmanaged(u64, void) = .empty,
    active_scopes: std.ArrayList([]const u8) = .empty,
    spills: u32 = 0,

    pub fn init(gpa: Allocator, io: Io, opts: Options) Allocator.Error!HookEngine {
        var env: std.process.Environ.Map = if (opts.environ) |m| try m.clone(gpa) else .init(gpa);
        errdefer env.deinit();
        try env.put("ZIGGURO_PROJECT_DIR", opts.project_dir);
        if (opts.compat) try env.put("CLAUDE_PROJECT_DIR", opts.project_dir);
        return .{ .gpa = gpa, .io = io, .opts = opts, .arena = .init(gpa), .env = env };
    }

    pub fn deinit(e: *HookEngine) void {
        e.env.deinit();
        e.approved.deinit(e.gpa);
        e.active_scopes.deinit(e.gpa);
        e.entries.deinit(e.gpa);
        e.arena.deinit();
    }

    /// Adds hooks; matchers are compiled here (a bad regex is an error).
    pub fn add(e: *HookEngine, sources: []const Source) !void {
        const a = e.arena.allocator();
        for (sources) |s| for (s.configs) |cfg| {
            const m = try hook_match.Matcher.compile(a, cfg.matcher);
            const mt = try a.dupe(u8, cfg.matcher);
            for (cfg.hooks) |h| try e.entries.append(e.gpa, .{
                .event = s.event,
                .layer = s.layer,
                .scope = if (s.scope) |x| try a.dupe(u8, x) else null,
                .matcher = m,
                .matcher_text = mt,
                .handler = try dupeHandler(a, h),
                .hash = commandHash(h),
            });
        };
    }

    /// Every configured hook in order (strings borrowed from the engine).
    pub fn list(e: *const HookEngine, arena: Allocator) Allocator.Error![]const Listed {
        const out = try arena.alloc(Listed, e.entries.items.len);
        for (e.entries.items, out) |x, *o| o.* = .{ .event = x.event, .layer = x.layer, .scope = x.scope, .matcher = x.matcher_text, .command = x.handler.command };
        return out;
    }

    /// Scoped hooks of `scope` run from now on (a skill or agent started).
    pub fn activate(e: *HookEngine, scope: []const u8) Allocator.Error!void {
        e.mutex.lockUncancelable(e.io);
        defer e.mutex.unlock(e.io);
        try e.active_scopes.append(e.gpa, try e.arena.allocator().dupe(u8, scope));
    }

    pub fn deactivate(e: *HookEngine, scope: []const u8) void {
        e.mutex.lockUncancelable(e.io);
        defer e.mutex.unlock(e.io);
        for (e.active_scopes.items, 0..) |s, i| if (std.mem.eql(u8, s, scope)) {
            _ = e.active_scopes.orderedRemove(i);
            return;
        };
    }

    /// Commands approved earlier (persisted by the app), by `commandHash`.
    pub fn markApproved(e: *HookEngine, hash: u64) Allocator.Error!void {
        e.mutex.lockUncancelable(e.io);
        defer e.mutex.unlock(e.io);
        try e.approved.put(e.gpa, hash, {});
    }

    /// Runs the hooks of `event` that match `input` and merges their
    /// outcomes. Slices live in `arena`.
    pub fn run(e: *HookEngine, io: Io, arena: Allocator, event: HookEvent, input_in: Input) Io.Cancelable!Outcome {
        var input = input_in;
        if (input.session_id.len == 0) input.session_id = e.opts.session_id;
        if (input.transcript_path == null) input.transcript_path = e.opts.transcript_path;
        if (std.mem.eql(u8, input.cwd, ".")) input.cwd = e.opts.project_dir;
        input.permission_mode = if (std.mem.eql(u8, input.permission_mode, "default")) e.opts.permission_mode else input.permission_mode;

        var picked: std.ArrayList(*const Entry) = .empty;
        var notices: std.ArrayList([]const u8) = .empty;
        const key = matchKey(event, input);
        for (e.entries.items) |*en| {
            if (en.event != event or !e.layerAllowed(en)) continue;
            if (key) |k| if (!en.matcher.matches(arena, k)) continue;
            for (picked.items) |p| {
                if (p.hash == en.hash) break;
            } else {
                if (!try e.approvedToRun(io, en)) {
                    notices.append(arena, std.fmt.allocPrint(arena, "hook {s} was not approved and did not run", .{en.handler.command}) catch continue) catch {};
                    continue;
                }
                picked.append(arena, en) catch return .{};
            }
        }
        if (picked.items.len == 0) return .{ .notices = notices.items };

        const stdin = hook_io.encodeInput(arena, event, input) catch return .{};
        const results = arena.alloc(Timed, picked.items.len) catch return .{};
        if (picked.items.len == 1) {
            results[0] = try e.runOne(io, arena, picked.items[0].handler, stdin);
        } else {
            var group: Io.Group = .init;
            for (picked.items, results) |en, *r| group.async(io, runInto, .{ e, io, arena, en.handler, stdin, r });
            group.await(io) catch |err| {
                group.cancel(io);
                return err;
            };
        }

        const outs = arena.alloc(Outcome, picked.items.len) catch return .{};
        for (picked.items, results, outs) |en, r, *o| {
            if (r.canceled) return error.Canceled;
            o.* = hook_io.interpret(arena, event, en.handler.command, en.handler.on_failure, r.result) catch .{};
            e.audit(io, event, en.handler.command, r, o.*);
        }
        var merged = hook_io.merge(arena, outs) catch return .{};
        if (notices.items.len > 0) {
            notices.appendSlice(arena, merged.notices) catch {};
            merged.notices = notices.items;
        }
        if (merged.additional_context) |c| if (c.len > context_cap) {
            merged.additional_context = e.spill(io, arena, c) catch c[0..context_cap];
        };
        if (e.opts.audit) |au| if (au.notice) |f| {
            for (merged.notices) |n| f(au.ctx, io, n);
            if (merged.system_message) |m| f(au.ctx, io, m);
        };
        for (merged.notices) |n| log.info("{s}", .{n});
        return merged;
    }

    /// Whether any hook is configured for `event`.
    pub fn has(e: *const HookEngine, event: HookEvent) bool {
        for (e.entries.items) |en| if (en.event == event) return true;
        return false;
    }

    fn layerAllowed(e: *HookEngine, en: *const Entry) bool {
        if (en.layer == .managed) return true;
        if (e.opts.disable_non_managed) return false;
        if ((en.layer == .project or en.layer == .local) and !e.opts.workspace_trusted) return false;
        if (en.scope) |s| {
            e.mutex.lockUncancelable(e.io);
            defer e.mutex.unlock(e.io);
            for (e.active_scopes.items) |x| if (std.mem.eql(u8, x, s)) return true;
            return false;
        }
        return true;
    }

    fn approvedToRun(e: *HookEngine, io: Io, en: *const Entry) Io.Cancelable!bool {
        if (en.layer != .project and en.layer != .local) return true;
        const ap = e.opts.approver orelse return true;
        {
            e.mutex.lockUncancelable(e.io);
            defer e.mutex.unlock(e.io);
            if (e.approved.contains(en.hash)) return true;
        }
        if (!try ap.approve(ap.ctx, io, en.event, en.handler.command)) return false;
        e.markApproved(en.hash) catch {};
        return true;
    }

    fn audit(e: *HookEngine, io: Io, event: HookEvent, command: []const u8, r: Timed, o: Outcome) void {
        const au = e.opts.audit orelse return;
        const decision: []const u8 = if (o.block != null)
            "block"
        else if (o.permission) |p|
            @tagName(p)
        else if (o.stop_all != null)
            "stop"
        else if (r.result.exit == null or r.result.exit.? != 0)
            "error"
        else if (o.additional_context != null or o.updated_input_json != null or o.updated_tool_output != null)
            "modify"
        else
            "none";
        au.record(au.ctx, io, .{ .event = event, .handler = command, .exit = r.result.exit, .duration_ms = r.ms, .decision = decision });
    }

    fn spill(e: *HookEngine, io: Io, arena: Allocator, text: []const u8) ![]const u8 {
        const dir = e.opts.spill_dir orelse return error.NoSpillDir;
        const n = blk: {
            e.mutex.lockUncancelable(e.io);
            defer e.mutex.unlock(e.io);
            e.spills += 1;
            break :blk e.spills;
        };
        const name = try std.fmt.allocPrint(arena, "hook-context-{d}.txt", .{n});
        const path = try std.fs.path.join(arena, &.{ dir, name });
        try Io.Dir.cwd().createDirPath(io, dir);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text });
        return std.fmt.allocPrint(arena, "{s}\n\n[hook context cut at {d} of {d} characters; the full text is in {s}]", .{ text[0..2000], 2000, text.len, path });
    }

    const Timed = struct { result: hook_io.Result, ms: u64, canceled: bool = false };

    fn runInto(e: *HookEngine, io: Io, arena: Allocator, h: Handler, stdin: []const u8, out: *Timed) void {
        out.* = e.runOne(io, arena, h, stdin) catch .{ .result = .{ .exit = null }, .ms = 0, .canceled = true };
    }

    const Raced = union(enum) {
        done: Io.Cancelable!hook_io.Result,
        timeout: Io.Cancelable!void,
    };

    /// One handler with its timeout.
    fn runOne(e: *HookEngine, io: Io, arena: Allocator, h: Handler, stdin: []const u8) Io.Cancelable!Timed {
        const start = e.opts.clock.now(io);
        var buf: [2]Raced = undefined;
        var sel: Io.Select(Raced) = .init(io, &buf);
        defer sel.cancelDiscard();
        const result = blk: {
            sel.concurrent(.done, exec, .{ e, io, arena, h, stdin }) catch break :blk try e.exec(io, arena, h, stdin);
            sel.concurrent(.timeout, ratelimit.Clock.sleep, .{ e.opts.clock, io, @as(u64, h.timeout_s) * 1000 }) catch {};
            break :blk switch (try sel.await()) {
                .done => |r| try r,
                .timeout => |t| t: {
                    try t;
                    break :t hook_io.Result{ .exit = null, .timed_out = true };
                },
            };
        };
        return .{ .result = result, .ms = @intCast(@max(0, e.opts.clock.now(io) - start)) };
    }

    /// Spawns the hook, feeds stdin and collects its output. Cancelling
    /// kills it.
    fn exec(e: *HookEngine, io: Io, arena: Allocator, h: Handler, stdin: []const u8) Io.Cancelable!hook_io.Result {
        var child = e.spawn(io, arena, h, false) catch |err| switch (err) {
            error.FileNotFound => if (h.shell == .auto and h.args == null and builtin.os.tag != .windows)
                e.spawn(io, arena, h, true) catch |err2| return .{ .exit = null, .spawn_error = @errorName(err2) }
            else
                return .{ .exit = null, .spawn_error = @errorName(err) },
            else => return .{ .exit = null, .spawn_error = @errorName(err) },
        };
        // A hook that does not read stdin closes it early: ignore that.
        child.stdin.?.writeStreamingAll(io, stdin) catch {};
        child.stdin.?.close(io);
        child.stdin = null;

        var err_task = io.concurrent(readCapped, .{ io, arena, child.stderr.? }) catch null;
        const out = readCapped(io, arena, child.stdout.?) catch {
            if (err_task) |*t| _ = t.cancel(io) catch {};
            child.kill(io);
            return error.Canceled;
        };
        const err_out = if (err_task) |*t| t.await(io) catch {
            child.kill(io);
            return error.Canceled;
        } else readCapped(io, arena, child.stderr.?) catch {
            child.kill(io);
            return error.Canceled;
        };
        const term = child.wait(io) catch |err| {
            if (err == error.Canceled) {
                child.kill(io);
                return error.Canceled;
            }
            return .{ .exit = null, .stdout = out, .stderr = err_out, .spawn_error = @errorName(err) };
        };
        return .{ .exit = switch (term) {
            .exited => |c| c,
            else => null,
        }, .stdout = out, .stderr = err_out };
    }

    fn spawn(e: *HookEngine, io: Io, arena: Allocator, h: Handler, plain_sh: bool) !std.process.Child {
        const argv: []const []const u8 = if (h.args) |args| blk: {
            const v = try arena.alloc([]const u8, args.len + 1);
            v[0] = h.command;
            @memcpy(v[1..], args);
            break :blk v;
        } else switch (h.shell) {
            .powershell => &.{ "powershell", "-NoProfile", "-Command", h.command },
            .sh => &.{ "/bin/sh", "-c", h.command },
            .bash => &.{ "bash", "-c", h.command },
            .auto => if (builtin.os.tag == .windows)
                &.{ "powershell", "-NoProfile", "-Command", h.command }
            else if (plain_sh)
                &.{ "/bin/sh", "-c", h.command }
            else
                &.{ "bash", "-c", h.command },
        };
        return std.process.spawn(io, .{
            .argv = argv,
            .cwd = .{ .path = e.opts.project_dir },
            .environ_map = &e.env,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .create_no_window = true,
        });
    }

    // -- the agent loop ------------------------------------------------

    /// The loop's `deps.Hooks`: UserPromptSubmit, Stop, PreToolUse and
    /// PostToolUse (PostToolUseFailure for failed calls).
    pub fn hooks(e: *HookEngine) deps.Hooks {
        return .{
            .ctx = e,
            .prompt_submit = if (e.has(.UserPromptSubmit)) promptSubmit else null,
            .stop = if (e.has(.Stop)) stop else null,
            .pre_tool_use = if (e.has(.PreToolUse)) preToolUse else null,
            .post_tool_use = if (e.has(.PostToolUse) or e.has(.PostToolUseFailure)) postToolUse else null,
        };
    }

    fn promptSubmit(ctx: *anyopaque, io: Io, arena: Allocator, text: []const u8) anyerror!deps.PromptDecision {
        const e: *HookEngine = @ptrCast(@alignCast(ctx));
        const o = try e.run(io, arena, .UserPromptSubmit, .{ .prompt = text });
        if (o.stop_all orelse o.block) |r| return .{ .block = r };
        if (o.additional_context) |c| return .{ .add_context = c };
        return .allow;
    }

    fn stop(ctx: *anyopaque, io: Io, arena: Allocator, _: *const proto.Message) anyerror!deps.StopDecision {
        const e: *HookEngine = @ptrCast(@alignCast(ctx));
        const o = try e.run(io, arena, .Stop, .{ .stop_hook_active = false });
        if (o.stop_all != null) return .allow;
        if (o.block) |r| return .{ .block = r };
        return .allow;
    }

    fn preToolUse(ctx: *anyopaque, io: Io, arena: Allocator, agent: proto.AgentRef, spec: *const proto.ToolSpec, input_json: []const u8) anyerror!deps.PreToolDecision {
        const e: *HookEngine = @ptrCast(@alignCast(ctx));
        const o = try e.run(io, arena, .PreToolUse, try toolInput(arena, agent, spec.name, input_json));
        if (o.stop_all orelse o.block) |r| return .{ .decision = .deny, .reason = r };
        var d: deps.PreToolDecision = .{ .updated_input_json = o.updated_input_json };
        if (o.permission) |p| {
            d.decision = switch (p) {
                .allow => .allow,
                .deny => .deny,
                .ask => .ask,
            };
            d.reason = o.permission_reason orelse "";
        }
        return d;
    }

    fn postToolUse(ctx: *anyopaque, io: Io, arena: Allocator, agent: proto.AgentRef, spec: *const proto.ToolSpec, input_json: []const u8, output: *const proto.ToolOutput, failed: bool) anyerror!deps.PostToolDecision {
        const e: *HookEngine = @ptrCast(@alignCast(ctx));
        var in = try toolInput(arena, agent, spec.name, input_json);
        in.tool_response_json = try responseJson(arena, output);
        const o = try e.run(io, arena, if (failed) .PostToolUseFailure else .PostToolUse, in);
        var d: deps.PostToolDecision = .{};
        var ctx_text: std.ArrayList(u8) = .empty;
        if (o.block) |b| try ctx_text.appendSlice(arena, b);
        if (o.additional_context) |c| {
            if (ctx_text.items.len > 0) try ctx_text.appendSlice(arena, "\n\n");
            try ctx_text.appendSlice(arena, c);
        }
        if (ctx_text.items.len > 0) d.additional_context = ctx_text.items;
        if (o.updated_tool_output) |u| d.updated_output = try proto.ToolOutput.text(arena, u, output.is_error);
        return d;
    }
};

fn toolInput(arena: Allocator, agent: proto.AgentRef, tool: []const u8, input_json: []const u8) Allocator.Error!Input {
    const sid = proto.agent_ref.format(agent.session);
    return .{
        .session_id = if (agent.session == 0) "" else try arena.dupe(u8, &sid),
        .agent_id = if (agent.agent == 0) null else try std.fmt.allocPrint(arena, "{d}", .{agent.agent}),
        .tool_name = tool,
        .tool_input_json = input_json,
    };
}

/// `{"is_error": b, "content": "<text parts>"}`.
fn responseJson(arena: Allocator, out: *const proto.ToolOutput) Allocator.Error![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    for (out.parts) |p| if (p == .text) {
        if (text.items.len > 0) try text.append(arena, '\n');
        try text.appendSlice(arena, p.text);
    };
    return std.json.Stringify.valueAlloc(arena, .{ .is_error = out.is_error, .content = text.items }, .{}) catch error.OutOfMemory;
}

/// What the matcher of `event` is tested against; null runs every hook.
fn matchKey(event: HookEvent, in: Input) ?[]const u8 {
    return switch (event) {
        .PreToolUse, .PostToolUse, .PostToolUseFailure, .PermissionRequest => in.tool_name orelse "",
        .SessionStart => in.source orelse "startup",
        .PreCompact, .PostCompact => in.trigger orelse "auto",
        .SubagentStart, .SubagentStop => in.agent_type orelse "",
        else => null,
    };
}

pub fn commandHash(h: Handler) u64 {
    var x: std.hash.Wyhash = .init(0);
    x.update(h.command);
    if (h.args) |args| for (args) |a| {
        x.update(&.{0});
        x.update(a);
    };
    return x.final();
}

fn dupeHandler(a: Allocator, h: Handler) Allocator.Error!Handler {
    var d = h;
    d.command = try a.dupe(u8, h.command);
    if (h.args) |args| {
        const v = try a.alloc([]const u8, args.len);
        for (args, v) |s, *o| o.* = try a.dupe(u8, s);
        d.args = v;
    }
    if (h.status_message) |m| d.status_message = try a.dupe(u8, m);
    return d;
}

fn readCapped(io: Io, arena: Allocator, file: Io.File) Io.Cancelable![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{&buf}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => break,
        };
        if (n == 0) break;
        const keep = @min(n, output_cap -| out.items.len);
        out.appendSlice(arena, buf[0..keep]) catch break;
    }
    return out.items;
}

// -- settings ------------------------------------------------------------

/// Reads the `hooks` object of a settings file (Claude Code format):
/// `{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type":
/// "command", "command": "...", "timeout": 30}]}]}}`. Unknown events are
/// skipped and named in `unknown`; `disableAllHooks` is returned too.
pub fn parseSettings(arena: Allocator, json_text: []const u8, layer: Layer) !struct { sources: []const Source, disable_all: bool, unknown: []const []const u8 = &.{} } {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, json_text, .{});
    if (v != .object) return error.InvalidSettings;
    const disable_all = if (v.object.get("disableAllHooks")) |d| d == .bool and d.bool else false;
    const hooks_v = v.object.get("hooks") orelse return .{ .sources = &.{}, .disable_all = disable_all };
    if (hooks_v != .object) return error.InvalidSettings;
    var sources: std.ArrayList(Source) = .empty;
    var unknown: std.ArrayList([]const u8) = .empty;
    var it = hooks_v.object.iterator();
    while (it.next()) |kv| {
        const event = std.meta.stringToEnum(HookEvent, kv.key_ptr.*) orelse {
            try unknown.append(arena, kv.key_ptr.*);
            continue;
        };
        if (kv.value_ptr.* != .array) return error.InvalidSettings;
        var configs: std.ArrayList(HookConfig) = .empty;
        for (kv.value_ptr.array.items) |c| {
            if (c != .object) return error.InvalidSettings;
            const matcher = if (c.object.get("matcher")) |m| (if (m == .string) m.string else return error.InvalidSettings) else "*";
            const hs = c.object.get("hooks") orelse return error.InvalidSettings;
            if (hs != .array) return error.InvalidSettings;
            var handlers: std.ArrayList(Handler) = .empty;
            for (hs.array.items) |h| {
                if (h != .object) return error.InvalidSettings;
                const o = h.object;
                if (o.get("type")) |t| if (t != .string or !std.mem.eql(u8, t.string, "command")) continue;
                const cmd = o.get("command") orelse return error.InvalidSettings;
                if (cmd != .string) return error.InvalidSettings;
                var handler: Handler = .{ .command = cmd.string };
                if (o.get("args")) |args| if (args == .array) {
                    const list = try arena.alloc([]const u8, args.array.items.len);
                    for (args.array.items, list) |x, *d| d.* = if (x == .string) x.string else return error.InvalidSettings;
                    handler.args = list;
                };
                if (o.get("timeout") orelse o.get("timeout_s")) |t| if (t == .integer and t.integer > 0) {
                    handler.timeout_s = @intCast(@min(t.integer, 24 * 3600));
                };
                if (o.get("shell")) |s| if (s == .string) {
                    handler.shell = std.meta.stringToEnum(@FieldType(Handler, "shell"), s.string) orelse .auto;
                };
                if (o.get("onFailure") orelse o.get("on_failure")) |f| if (f == .string) {
                    handler.on_failure = std.meta.stringToEnum(OnFailure, f.string) orelse .@"continue";
                };
                if (o.get("statusMessage")) |m| if (m == .string) {
                    handler.status_message = m.string;
                };
                try handlers.append(arena, handler);
            }
            try configs.append(arena, .{ .matcher = matcher, .hooks = handlers.items });
        }
        try sources.append(arena, .{ .layer = layer, .event = event, .configs = configs.items });
    }
    return .{ .sources = sources.items, .disable_all = disable_all, .unknown = unknown.items };
}
