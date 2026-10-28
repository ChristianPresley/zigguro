//! The debugger tools for agents (E07.F05.S02.T01), exported like the
//! task tools through `zg_ai.tools.adapters.foreign`:
//!
//! - read: `debug_list_configs`, `debug_threads`, `debug_stack`,
//!   `debug_scopes`, `debug_variables`, `debug_output_tail`,
//!   `debug_wait_for_stop`;
//! - control: `debug_continue`, `debug_step`, `debug_pause`, `debug_stop`,
//!   `debug_set_breakpoints`, `debug_clear_breakpoints`;
//! - execute: `debug_start`, `debug_evaluate`.
//!
//! The gate (E16) decides each call by the tool's class; untrusted
//! workspaces deny them all. Control tools act only on a session the
//! agent drives (`Controller.agent`): once the user takes control they
//! answer `user_took_control` until it is handed back. Every control call
//! is noted in the session's console as `[agent] …`.
//!
//! Calls run on agent workers and may block (requests, waiting for a
//! stop). Renderings are compact and deterministic: stacks as
//! `#0 name (src/a.zig:17)`, variables as indented `name: type = value`
//! with depth and child limits, strings cut at 200 bytes with a
//! `…(len N)` marker.
//!
//! ```zig
//! const X = zg_dap.agent.debug_tools.ToolExporter(zg_ai.tools.adapters.foreign);
//! ```

const std = @import("std");
const zg_perf = @import("zg_perf");
const DebugSession = @import("../session/DebugSession.zig");
const BreakpointManager = @import("../breakpoints/BreakpointManager.zig");
const console_events = @import("../session/console_events.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const PermissionClass = enum { read, control, execute };

pub const Spec = struct {
    name: []const u8,
    description: []const u8,
    input_schema_json: []const u8,
    permission: PermissionClass,
};

/// Under the adapter's 30 s deadline for debug tools.
pub const max_wait_ms = 25_000;
pub const default_wait_ms = 20_000;
/// One request's wait.
pub const request_timeout: Io.Duration = .fromSeconds(10);
pub const max_string = 200;

pub const ConfigInfo = struct {
    name: []const u8,
    type: []const u8,
    request: []const u8,
    /// Why it cannot start (null: it can).
    disabled: ?[]const u8 = null,
};

/// What the tools need from their owner (the app's debug service).
pub const Host = struct {
    ctx: *anyopaque,
    /// The launch configurations, in `arena`.
    configs: *const fn (ctx: *anyopaque, arena: Allocator) anyerror![]const ConfigInfo,
    /// Starts configuration `name` with the agent in control; the session
    /// is acquired (`release` it).
    start: *const fn (ctx: *anyopaque, name: []const u8) anyerror!*DebugSession,
    /// The session the agent works on (the active one), kept alive until
    /// `release`; null without one.
    acquire: *const fn (ctx: *anyopaque) ?*DebugSession,
    release: *const fn (ctx: *anyopaque, s: *DebugSession) void,
    breakpoints: *BreakpointManager,
    /// The workspace folder: paths are shown and taken relative to it.
    root: []const u8,
    io: Io,
};

const obj_schema_none =
    \\{"type":"object","properties":{},"additionalProperties":false}
;

pub const specs = [_]Spec{
    .{
        .name = "debug_list_configs",
        .permission = .read,
        .description = "The workspace's debug launch configurations (.zigguro/launch.zon, .vscode/launch.json and the generated Zig ones): name, adapter type, launch or attach, and why one cannot start.",
        .input_schema_json = obj_schema_none,
    },
    .{
        .name = "debug_start",
        .permission = .execute,
        .description = "Starts debugging a launch configuration (see debug_list_configs) with you in control. Breakpoints set with debug_set_breakpoints apply. Then call debug_wait_for_stop.",
        .input_schema_json =
        \\{"type":"object","properties":{"name":{"type":"string","description":"The configuration's name."}},"required":["name"],"additionalProperties":false}
        ,
    },
    .{
        .name = "debug_stop",
        .permission = .control,
        .description = "Ends the debug session you control (the debuggee is terminated, or detached from for an attach).",
        .input_schema_json = obj_schema_none,
    },
    .{
        .name = "debug_set_breakpoints",
        .permission = .control,
        .description = "Replaces the breakpoints in one file. Each line may have a condition (break when true), a hit condition (e.g. \">= 3\") or a log message ({expr} interpolated; logs instead of stopping). The editor shows them. Answers whether running sessions verified each one.",
        .input_schema_json =
        \\{"type":"object","properties":{"path":{"type":"string","description":"The file, relative to the workspace or absolute."},"lines":{"type":"array","items":{"type":"object","properties":{"line":{"type":"integer","minimum":1},"condition":{"type":"string"},"hit_condition":{"type":"string"},"log_message":{"type":"string"}},"required":["line"],"additionalProperties":false}}},"required":["path","lines"],"additionalProperties":false}
        ,
    },
    .{
        .name = "debug_clear_breakpoints",
        .permission = .control,
        .description = "Removes the breakpoints in one file, or every breakpoint without a path.",
        .input_schema_json =
        \\{"type":"object","properties":{"path":{"type":"string","description":"The file (omit: all breakpoints)."}},"additionalProperties":false}
        ,
    },
    .{
        .name = "debug_continue",
        .permission = .control,
        .description = "Resumes the program. Then call debug_wait_for_stop.",
        .input_schema_json =
        \\{"type":"object","properties":{"thread_id":{"type":"integer","description":"Omit: the current thread."}},"additionalProperties":false}
        ,
    },
    .{
        .name = "debug_step",
        .permission = .control,
        .description = "Steps one statement: over calls, into them, or out of the current function. Then call debug_wait_for_stop.",
        .input_schema_json =
        \\{"type":"object","properties":{"kind":{"type":"string","enum":["over","in","out"]},"thread_id":{"type":"integer","description":"Omit: the current thread."}},"required":["kind"],"additionalProperties":false}
        ,
    },
    .{
        .name = "debug_pause",
        .permission = .control,
        .description = "Pauses the running program. Then call debug_wait_for_stop.",
        .input_schema_json =
        \\{"type":"object","properties":{"thread_id":{"type":"integer","description":"Omit: the current thread."}},"additionalProperties":false}
        ,
    },
    .{
        .name = "debug_threads",
        .permission = .read,
        .description = "The debuggee's threads: id, name, and whether and why each is stopped.",
        .input_schema_json = obj_schema_none,
    },
    .{
        .name = "debug_stack",
        .permission = .read,
        .description = "A stopped thread's call stack, innermost first, as #N function (file:line) with each frame's id (for debug_scopes, debug_variables and debug_evaluate).",
        .input_schema_json =
        \\{"type":"object","properties":{"thread_id":{"type":"integer","description":"Omit: the current thread."},"levels":{"type":"integer","minimum":1,"maximum":200,"description":"Frames to show (default 20)."}},"additionalProperties":false}
        ,
    },
    .{
        .name = "debug_scopes",
        .permission = .read,
        .description = "A frame's variable scopes (locals, arguments, registers…) with their references for debug_variables.",
        .input_schema_json =
        \\{"type":"object","properties":{"frame_id":{"type":"integer","description":"Omit: the top frame of the current thread."}},"additionalProperties":false}
        ,
    },
    .{
        .name = "debug_variables",
        .permission = .read,
        .description = "Variables as indented name: type = value lines, expanded to a depth (default 2). Give a reference from debug_scopes or an earlier answer, or a scope name (default: the frame's first scope).",
        .input_schema_json =
        \\{"type":"object","properties":{"reference":{"type":"integer","minimum":1},"scope":{"type":"string"},"frame_id":{"type":"integer"},"depth":{"type":"integer","minimum":1,"maximum":5},"max_children":{"type":"integer","minimum":1,"maximum":500,"description":"Children shown per variable (default 50)."}},"additionalProperties":false}
        ,
    },
    .{
        .name = "debug_evaluate",
        .permission = .execute,
        .description = "Evaluates an expression in a frame (default: the top frame). Context \"watch\" (default) for values; \"repl\" runs debugger commands, e.g. GDB's.",
        .input_schema_json =
        \\{"type":"object","properties":{"expression":{"type":"string"},"frame_id":{"type":"integer"},"context":{"type":"string","enum":["watch","repl"]}},"required":["expression"],"additionalProperties":false}
        ,
    },
    .{
        .name = "debug_output_tail",
        .permission = .read,
        .description = "The last lines the debuggee printed (stdout and stderr) and the debugger's important messages.",
        .input_schema_json =
        \\{"type":"object","properties":{"lines":{"type":"integer","minimum":1,"maximum":500,"description":"Default 50."}},"additionalProperties":false}
        ,
    },
    .{
        .name = "debug_wait_for_stop",
        .permission = .read,
        .description = "Waits until the program stops (breakpoint, step, exception, pause) or ends, and answers why, where (with the source lines around it) and, for an exception, what was thrown. Answers at once when it is already stopped.",
        .input_schema_json =
        \\{"type":"object","properties":{"timeout_ms":{"type":"integer","minimum":1,"maximum":25000,"description":"Default 20000."}},"additionalProperties":false}
        ,
    },
};

pub fn specOf(name: []const u8) ?*const Spec {
    for (&specs) |*s| if (std.mem.eql(u8, s.name, name)) return s;
    return null;
}

pub fn ToolExporter(comptime Foreign: type) type {
    return struct {
        const Self = @This();

        host: Host,

        pub fn exporter(self: *Self) Foreign.Exporter {
            return .{ .name = "debug", .kind = .debug, .ctx = self, .list = list, .call = call };
        }

        fn list(_: *anyopaque, arena: Allocator) anyerror![]const Foreign.ForeignTool {
            const out = try arena.alloc(Foreign.ForeignTool, specs.len);
            for (specs, out) |s, *t| t.* = .{
                .name = s.name,
                .description = s.description,
                .input_schema_json = s.input_schema_json,
                .read_only = s.permission == .read,
                .annotations = .{ .destructive_hint = s.permission != .read },
            };
            return out;
        }

        fn call(ctx: *anyopaque, _: Io, arena: Allocator, tool: []const u8, input_json: []const u8) anyerror!Foreign.Result {
            const self: *Self = @ptrCast(@alignCast(ctx));
            var text: Io.Writer.Allocating = .init(arena);
            const out = runTool(self.host, arena, tool, input_json, &text.writer) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => blk: {
                    text.clearRetainingCapacity();
                    try text.writer.print("{s} failed: {t}", .{ tool, e });
                    break :blk Outcome{ .ok = false };
                },
            };
            return .{ .json = try resultJson(arena, text.written(), !out.ok, out.code) };
        }
    };
}

pub const Outcome = struct {
    ok: bool,
    /// A machine-readable reason with a failure (`structuredContent`):
    /// `no_session`, `user_took_control`, `not_stopped`, ….
    code: ?[]const u8 = null,
};

const BpLine = struct {
    line: u32,
    condition: ?[]const u8 = null,
    hit_condition: ?[]const u8 = null,
    log_message: ?[]const u8 = null,
};

const Input = struct {
    name: ?[]const u8 = null,
    path: ?[]const u8 = null,
    lines: ?std.json.Value = null,
    thread_id: ?i64 = null,
    frame_id: ?i64 = null,
    kind: ?[]const u8 = null,
    levels: ?u32 = null,
    reference: ?i64 = null,
    scope: ?[]const u8 = null,
    depth: ?u8 = null,
    max_children: ?u32 = null,
    expression: ?[]const u8 = null,
    context: ?[]const u8 = null,
    timeout_ms: ?u32 = null,
};

/// Runs `tool`, writing its answer to `w`.
pub fn runTool(h: Host, arena: Allocator, tool: []const u8, input_json: []const u8, w: *Io.Writer) !Outcome {
    const spec = specOf(tool) orelse return error.UnknownTool;
    const in = std.json.parseFromSliceLeaky(Input, arena, if (input_json.len == 0) "{}" else input_json, .{ .ignore_unknown_fields = true }) catch {
        try w.writeAll("The arguments are not valid for this tool (check names and types against its schema).");
        return .{ .ok = false, .code = "bad_arguments" };
    };
    // Tools without a session.
    if (std.mem.eql(u8, tool, "debug_list_configs")) return listConfigs(h, arena, w);
    if (std.mem.eql(u8, tool, "debug_start")) return start(h, in, w);
    if (std.mem.eql(u8, tool, "debug_set_breakpoints")) return setBreakpoints(h, arena, in, w);
    if (std.mem.eql(u8, tool, "debug_clear_breakpoints")) return clearBreakpoints(h, arena, in, w);

    const s = h.acquire(h.ctx) orelse {
        try w.writeAll("No debug session is running. Start one with debug_start (see debug_list_configs).");
        return .{ .ok = false, .code = "no_session" };
    };
    defer h.release(h.ctx, s);
    if (spec.permission == .control and s.controller() != .agent) {
        try w.writeAll("The user controls this debug session: control tools are refused until they hand it back to you (the debug toolbar's \"Hand Back to Agent\"). Read tools still work.");
        return .{ .ok = false, .code = "user_took_control" };
    }
    const T = enum { debug_stop, debug_continue, debug_step, debug_pause, debug_threads, debug_stack, debug_scopes, debug_variables, debug_evaluate, debug_output_tail, debug_wait_for_stop };
    switch (std.meta.stringToEnum(T, tool) orelse return error.UnknownTool) {
        .debug_stop => {
            s.note("[agent] stop", .{});
            if (s.cfg.request == .attach) s.detach(false) else s.stop();
            try w.print("Stopping '{s}'.", .{s.cfg.name});
            return .{ .ok = true };
        },
        .debug_continue => return resumeTool(s, in, w, .@"continue"),
        .debug_pause => return resumeTool(s, in, w, .pause),
        .debug_step => {
            const kind = in.kind orelse "";
            const k: DebugSession.StepKind = if (std.mem.eql(u8, kind, "over")) .over else if (std.mem.eql(u8, kind, "in")) .into else if (std.mem.eql(u8, kind, "out")) .out else {
                try w.writeAll("kind must be over, in or out.");
                return .{ .ok = false, .code = "bad_arguments" };
            };
            return resumeTool(s, in, w, .{ .step = k });
        },
        .debug_threads => return threads(s, arena, w),
        .debug_stack => return stack(h, s, arena, in, w),
        .debug_scopes => return scopes(s, arena, in, w),
        .debug_variables => return variables(s, arena, in, w),
        .debug_evaluate => return evaluate(s, arena, in, w),
        .debug_output_tail => return outputTail(s, arena, in, w),
        .debug_wait_for_stop => return waitForStop(h, s, arena, in, w),
    }
}

// -- configurations and sessions ----------------------------------------------------

fn listConfigs(h: Host, arena: Allocator, w: *Io.Writer) !Outcome {
    const cs = try h.configs(h.ctx, arena);
    if (cs.len == 0) {
        try w.writeAll("No debug configurations: add one to .zigguro/launch.zon (or .vscode/launch.json).\n");
        return .{ .ok = true };
    }
    for (cs) |c| {
        try w.print("{s} [{s}, {s}]", .{ c.name, c.type, c.request });
        if (c.disabled) |why| try w.print(" (cannot start: {s})", .{why});
        try w.writeByte('\n');
    }
    return .{ .ok = true };
}

fn start(h: Host, in: Input, w: *Io.Writer) !Outcome {
    const name = in.name orelse {
        try w.writeAll("debug_start needs the name of a configuration (see debug_list_configs).");
        return .{ .ok = false, .code = "bad_arguments" };
    };
    const s = h.start(h.ctx, name) catch |e| {
        try w.print("'{s}' did not start: {t}", .{ name, e });
        return .{ .ok = false, .code = "start_failed" };
    };
    defer h.release(h.ctx, s);
    s.note("[agent] start {s}", .{name});
    try w.print("Started '{s}'. Call debug_wait_for_stop to wait for a breakpoint or the end.", .{name});
    return .{ .ok = true };
}

const Resume = union(enum) { @"continue", pause, step: DebugSession.StepKind };

fn resumeTool(s: *DebugSession, in: Input, w: *Io.Writer, what: Resume) !Outcome {
    const st = s.state();
    if (st == .terminated or st == .failed or st == .terminating) {
        try w.writeAll("The session has ended.");
        return .{ .ok = false, .code = "ended" };
    }
    switch (what) {
        .pause => {
            if (st == .stopped) {
                try w.writeAll("The program is already stopped.");
                return .{ .ok = true };
            }
            s.note("[agent] pause", .{});
            s.pauseBy(.agent, in.thread_id);
            try w.writeAll("Pausing. Call debug_wait_for_stop.");
        },
        .@"continue" => {
            if (st != .stopped) return notStopped(w);
            s.note("[agent] continue", .{});
            s.continueBy(.agent, in.thread_id);
            try w.writeAll("Continued. Call debug_wait_for_stop.");
        },
        .step => |k| {
            if (st != .stopped) return notStopped(w);
            const t = in.thread_id orelse s.currentThread() orelse return notStopped(w);
            const word = switch (k) {
                .over => "over",
                .into => "in",
                .out => "out",
                .back => "back",
            };
            s.note("[agent] step {s}", .{word});
            s.stepBy(.agent, k, t, .statement);
            try w.print("Stepping {s}. Call debug_wait_for_stop.", .{word});
        },
    }
    return .{ .ok = true };
}

fn notStopped(w: *Io.Writer) !Outcome {
    try w.writeAll("The program is running: call debug_pause or debug_wait_for_stop first.");
    return .{ .ok = false, .code = "not_stopped" };
}

// -- breakpoints --------------------------------------------------------------------

fn absPath(h: Host, arena: Allocator, path: []const u8) Allocator.Error![]const u8 {
    if (std.fs.path.isAbsolute(path) or h.root.len == 0) return path;
    return std.fs.path.join(arena, &.{ h.root, path });
}

fn setBreakpoints(h: Host, arena: Allocator, in: Input, w: *Io.Writer) !Outcome {
    const rel = in.path orelse {
        try w.writeAll("debug_set_breakpoints needs a path.");
        return .{ .ok = false, .code = "bad_arguments" };
    };
    const lines_v = in.lines orelse std.json.Value{ .array = .init(arena) };
    const lines = std.json.parseFromValueLeaky([]const BpLine, arena, lines_v, .{ .ignore_unknown_fields = true }) catch {
        try w.writeAll("lines must be a list of {line, condition?, hit_condition?, log_message?}.");
        return .{ .ok = false, .code = "bad_arguments" };
    };
    const path = try absPath(h, arena, rel);
    const m = h.breakpoints;
    for (try m.inSource(arena, path)) |v| m.remove(v.bp.id);
    const ids = try arena.alloc(BreakpointManager.BpId, lines.len);
    for (lines, ids) |l, *id| id.* = try m.add(.{ .kind = .{ .source = .{
        .path = path,
        .line = l.line,
        .condition = l.condition,
        .hit_condition = l.hit_condition,
        .log_message = l.log_message,
    } } });
    if (lines.len == 0) {
        try w.print("Removed the breakpoints in {s}.\n", .{rel});
        return .{ .ok = true };
    }
    // Running sessions answer within moments; wait a little for them.
    var views = try viewsOf(m, arena, ids);
    var tries: u32 = 0;
    while (tries < 50 and pending(views)) : (tries += 1) {
        h.io.sleep(.fromMilliseconds(20), .awake) catch break;
        zg_perf.idle.noteWake("dap.agent.bp_verify", .timer);
        views = try viewsOf(m, arena, ids);
    }
    for (lines, views) |l, v| {
        try w.print("{s}:{d}", .{ rel, l.line });
        if (l.log_message != null) try w.writeAll(" (logpoint)");
        const view = v orelse {
            try w.writeAll(": removed\n");
            continue;
        };
        if (view.bp.kind.source.line != l.line) try w.print(": moved to line {d}", .{view.bp.kind.source.line});
        if (!view.sessions) {
            try w.writeAll(": set (verified when a session starts)\n");
        } else if (view.verified) {
            try w.writeAll(": verified\n");
        } else {
            try w.print(": not verified{s}{s}\n", .{ if (view.message != null) ": " else "", view.message orelse "" });
        }
    }
    return .{ .ok = true };
}

fn viewsOf(m: *BreakpointManager, arena: Allocator, ids: []const BreakpointManager.BpId) Allocator.Error![]?BreakpointManager.View {
    const out = try arena.alloc(?BreakpointManager.View, ids.len);
    for (ids, out) |id, *o| o.* = try m.get(arena, id);
    return out;
}

fn pending(views: []const ?BreakpointManager.View) bool {
    for (views) |v| if (v) |x| if (x.sessions and !x.verified and x.message == null) return true;
    return false;
}

fn clearBreakpoints(h: Host, arena: Allocator, in: Input, w: *Io.Writer) !Outcome {
    const m = h.breakpoints;
    var n: usize = 0;
    if (in.path) |rel| {
        for (try m.inSource(arena, try absPath(h, arena, rel))) |v| {
            m.remove(v.bp.id);
            n += 1;
        }
    } else for (try m.list(arena)) |v| {
        m.remove(v.bp.id);
        n += 1;
    }
    try w.print("Removed {d} breakpoint{s}.\n", .{ n, if (n == 1) "" else "s" });
    return .{ .ok = true };
}

// -- reading ------------------------------------------------------------------------

fn threads(s: *DebugSession, arena: Allocator, w: *Io.Writer) !Outcome {
    const ts = try s.threads(arena);
    if (ts.len == 0) {
        try w.writeAll("No threads yet.\n");
        return .{ .ok = true };
    }
    const cur = s.currentThread();
    for (ts) |t| {
        try w.print("Thread {d} \"{s}\": ", .{ t.id, t.name });
        if (t.stopped) {
            try w.writeAll("stopped");
            if (t.stop_reason) |r| try w.print(" ({s})", .{r.reason});
        } else try w.writeAll("running");
        if (cur == t.id) try w.writeAll(" [current]");
        try w.writeByte('\n');
    }
    return .{ .ok = true };
}

const FrameJson = struct {
    id: i64,
    name: []const u8 = "",
    line: i64 = 0,
    column: i64 = 0,
    source: ?struct { path: ?[]const u8 = null, name: ?[]const u8 = null } = null,
    presentationHint: ?[]const u8 = null,
};

fn requestOk(s: *DebugSession, arena: Allocator, command: []const u8, args: []const u8, w: *Io.Writer) !?[]const u8 {
    switch (try s.request(arena, command, args, request_timeout)) {
        .ok => |b| return b orelse "{}",
        .failed => |msg| try w.print("The debugger refused {s}: {s}", .{ command, msg }),
        .timeout => try w.print("The debugger did not answer {s} in time.", .{command}),
        .closed => try w.writeAll("The debug session has ended."),
    }
    return null;
}

fn parse(comptime T: type, arena: Allocator, body: []const u8) ?T {
    return std.json.parseFromSliceLeaky(T, arena, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
}

fn stack(h: Host, s: *DebugSession, arena: Allocator, in: Input, w: *Io.Writer) !Outcome {
    if (s.state() != .stopped) return notStopped(w);
    const t = in.thread_id orelse s.currentThread() orelse return notStopped(w);
    const levels = in.levels orelse 20;
    const args = try std.fmt.allocPrint(arena, "{{\"threadId\":{d},\"startFrame\":0,\"levels\":{d}}}", .{ t, levels });
    const body = try requestOk(s, arena, "stackTrace", args, w) orelse return .{ .ok = false, .code = "request_failed" };
    const B = struct { stackFrames: []const FrameJson = &.{}, totalFrames: ?i64 = null };
    const b = parse(B, arena, body) orelse return error.BadResponse;
    for (b.stackFrames, 0..) |f, i| {
        try w.print("#{d} {s}", .{ i, f.name });
        if (f.source) |src| if (src.path orelse src.name) |p| {
            try w.writeAll(" (");
            try writeRel(w, h.root, p);
            if (f.line > 0) try w.print(":{d}", .{f.line});
            try w.writeByte(')');
        };
        try w.print(" frame={d}\n", .{f.id});
    }
    if (b.totalFrames) |n| if (n > b.stackFrames.len) try w.print("… {d} more frames (raise levels)\n", .{n - @as(i64, @intCast(b.stackFrames.len))});
    return .{ .ok = true };
}

/// The top frame of the current thread (null: not stopped).
fn topFrameId(s: *DebugSession, arena: Allocator) ?i64 {
    const top = (s.topFrame(arena) catch return null) orelse return null;
    return top.frame.id;
}

const ScopeJson = struct { name: []const u8 = "", variablesReference: i64 = 0, expensive: bool = false };

fn scopesOf(s: *DebugSession, arena: Allocator, frame: i64, w: *Io.Writer) !?[]const ScopeJson {
    const args = try std.fmt.allocPrint(arena, "{{\"frameId\":{d}}}", .{frame});
    const body = try requestOk(s, arena, "scopes", args, w) orelse return null;
    const B = struct { scopes: []const ScopeJson = &.{} };
    const b = parse(B, arena, body) orelse return error.BadResponse;
    return b.scopes;
}

fn scopes(s: *DebugSession, arena: Allocator, in: Input, w: *Io.Writer) !Outcome {
    if (s.state() != .stopped) return notStopped(w);
    const frame = in.frame_id orelse topFrameId(s, arena) orelse return notStopped(w);
    const list = try scopesOf(s, arena, frame, w) orelse return .{ .ok = false, .code = "request_failed" };
    if (list.len == 0) try w.writeAll("No scopes in this frame.\n");
    for (list) |sc| {
        try w.print("{s} reference={d}", .{ sc.name, sc.variablesReference });
        if (sc.expensive) try w.writeAll(" (expensive)");
        try w.writeByte('\n');
    }
    return .{ .ok = true };
}

const VarJson = struct {
    name: []const u8 = "",
    value: []const u8 = "",
    type: ?[]const u8 = null,
    variablesReference: i64 = 0,
    namedVariables: ?i64 = null,
    indexedVariables: ?i64 = null,
};

fn variables(s: *DebugSession, arena: Allocator, in: Input, w: *Io.Writer) !Outcome {
    if (s.state() != .stopped) return notStopped(w);
    const ref = in.reference orelse blk: {
        const frame = in.frame_id orelse topFrameId(s, arena) orelse return notStopped(w);
        const list = try scopesOf(s, arena, frame, w) orelse return .{ .ok = false, .code = "request_failed" };
        if (in.scope) |want| {
            for (list) |sc| if (std.ascii.eqlIgnoreCase(sc.name, want)) break :blk sc.variablesReference;
            try w.print("No scope \"{s}\" in this frame; it has:", .{want});
            for (list) |sc| try w.print(" {s}", .{sc.name});
            return .{ .ok = false, .code = "no_scope" };
        }
        if (list.len == 0) {
            try w.writeAll("No scopes in this frame.\n");
            return .{ .ok = true };
        }
        break :blk list[0].variablesReference;
    };
    var r: VarRender = .{ .s = s, .arena = arena, .w = w, .max_children = in.max_children orelse 50 };
    if (!try r.children(ref, in.depth orelse 2, 0)) return .{ .ok = false, .code = "request_failed" };
    if (r.shown == 0) try w.writeAll("(no variables)\n");
    return .{ .ok = true };
}

const VarRender = struct {
    s: *DebugSession,
    arena: Allocator,
    w: *Io.Writer,
    max_children: u32,
    shown: u32 = 0,

    /// Writes the children of `ref`, `depth` levels down; false when the
    /// first request failed (the reason is written).
    fn children(r: *VarRender, ref: i64, depth: u8, indent: u8) !bool {
        const args = try std.fmt.allocPrint(r.arena, "{{\"variablesReference\":{d},\"start\":0,\"count\":{d}}}", .{ ref, r.max_children + 1 });
        const body = try requestOk(r.s, r.arena, "variables", args, r.w) orelse return false;
        const B = struct { variables: []const VarJson = &.{} };
        const b = parse(B, r.arena, body) orelse return error.BadResponse;
        for (b.variables, 0..) |v, i| {
            if (i == r.max_children) {
                try r.w.splatByteAll(' ', @as(usize, indent) * 2);
                try r.w.print("… more (raise max_children, or ask for reference={d})\n", .{ref});
                break;
            }
            try r.w.splatByteAll(' ', @as(usize, indent) * 2);
            try r.w.writeAll(v.name);
            if (v.type) |t| if (t.len > 0) try r.w.print(": {s}", .{t});
            try r.w.writeAll(" = ");
            try writeValue(r.w, v.value);
            r.shown += 1;
            if (v.variablesReference > 0) {
                if (depth > 1) {
                    try r.w.writeByte('\n');
                    if (!try r.children(v.variablesReference, depth - 1, indent + 1)) try r.w.writeByte('\n');
                    continue;
                }
                const n = (v.namedVariables orelse 0) + (v.indexedVariables orelse 0);
                if (n > 0) try r.w.print(" [+{d} children, reference={d}]", .{ n, v.variablesReference }) else try r.w.print(" [+children, reference={d}]", .{v.variablesReference});
            }
            try r.w.writeByte('\n');
        }
        return true;
    }
};

/// `value` on one line, cut at `max_string` bytes.
fn writeValue(w: *Io.Writer, value: []const u8) Io.Writer.Error!void {
    const cut = value.len > max_string;
    var end = if (cut) max_string else value.len;
    // Not inside a UTF-8 sequence.
    while (cut and end > 0 and (value[end] & 0xC0) == 0x80) end -= 1;
    for (value[0..end]) |c| switch (c) {
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        else => try w.writeByte(c),
    };
    if (cut) try w.print("\u{2026}(len {d})", .{value.len});
}

fn evaluate(s: *DebugSession, arena: Allocator, in: Input, w: *Io.Writer) !Outcome {
    const expr = in.expression orelse {
        try w.writeAll("debug_evaluate needs an expression.");
        return .{ .ok = false, .code = "bad_arguments" };
    };
    const context = in.context orelse "watch";
    if (!std.mem.eql(u8, context, "watch") and !std.mem.eql(u8, context, "repl")) {
        try w.writeAll("context must be watch or repl.");
        return .{ .ok = false, .code = "bad_arguments" };
    }
    const frame = in.frame_id orelse topFrameId(s, arena);
    var args: std.ArrayList(u8) = .empty;
    try args.print(arena, "{{\"expression\":{f},\"context\":\"{s}\"", .{ std.json.fmt(expr, .{}), context });
    if (frame) |f| try args.print(arena, ",\"frameId\":{d}", .{f});
    try args.append(arena, '}');
    if (std.mem.eql(u8, context, "repl")) s.note("[agent] {s}", .{expr});
    const body = switch (try s.request(arena, "evaluate", args.items, request_timeout)) {
        .ok => |b| b orelse "{}",
        .failed => |msg| {
            try w.print("{s}: {s}", .{ expr, msg });
            return .{ .ok = false, .code = "evaluate_failed" };
        },
        .timeout => {
            try w.writeAll("The debugger did not answer in time.");
            return .{ .ok = false, .code = "timeout" };
        },
        .closed => {
            try w.writeAll("The debug session has ended.");
            return .{ .ok = false, .code = "ended" };
        },
    };
    const B = struct { result: []const u8 = "", type: ?[]const u8 = null, variablesReference: i64 = 0, namedVariables: ?i64 = null, indexedVariables: ?i64 = null };
    const b = parse(B, arena, body) orelse return error.BadResponse;
    try w.writeAll(expr);
    if (b.type) |t| if (t.len > 0) try w.print(": {s}", .{t});
    try w.writeAll(" = ");
    try writeValue(w, b.result);
    if (b.variablesReference > 0) try w.print(" [children: debug_variables reference={d}]", .{b.variablesReference});
    try w.writeByte('\n');
    return .{ .ok = true };
}

fn outputTail(s: *DebugSession, arena: Allocator, in: Input, w: *Io.Writer) !Outcome {
    const Collect = struct {
        arena: Allocator,
        out: std.ArrayList(u8) = .empty,
        failed: bool = false,
        fn run(c: *@This(), con: *const console_events.Console) void {
            for (con.entries.items) |e| switch (e.category) {
                .stdout, .stderr, .important => c.out.appendSlice(c.arena, e.text) catch {
                    c.failed = true;
                    return;
                },
                else => {},
            };
        }
    };
    var c: Collect = .{ .arena = arena };
    s.withConsole(&c, Collect.run);
    if (c.failed) return error.OutOfMemory;
    const text = std.mem.trimEnd(u8, c.out.items, "\n");
    if (text.len == 0) {
        try w.writeAll("No output yet.\n");
        return .{ .ok = true };
    }
    const lines = linesArg(in);
    var start_i: usize = text.len;
    var count: u32 = 0;
    while (start_i > 0 and count < lines) {
        start_i -= 1;
        if (text[start_i] == '\n') count += 1;
    }
    if (count == lines) start_i += 1;
    try w.writeAll(text[start_i..]);
    try w.writeByte('\n');
    return .{ .ok = true };
}

fn linesArg(in: Input) u32 {
    // `lines` is shared with debug_set_breakpoints' list.
    const v = in.lines orelse return 50;
    return switch (v) {
        .integer => |i| @intCast(std.math.clamp(i, 1, 500)),
        else => 50,
    };
}

fn waitForStop(h: Host, s: *DebugSession, arena: Allocator, in: Input, w: *Io.Writer) !Outcome {
    const timeout_ms = @min(in.timeout_ms orelse default_wait_ms, max_wait_ms);
    const deadline = Io.Timestamp.now(h.io, .awake).addDuration(.fromMilliseconds(timeout_ms));
    while (true) {
        switch (s.state()) {
            .terminated, .failed => return ended(s, arena, w),
            .stopped => if (try s.topFrame(arena)) |top| return stopped(h, s, arena, top.frame, w),
            else => {},
        }
        if (Io.Timestamp.now(h.io, .awake).nanoseconds >= deadline.nanoseconds) break;
        h.io.sleep(.fromMilliseconds(20), .awake) catch break;
        zg_perf.idle.noteWake("dap.agent.wait_for_stop", .timer);
    }
    if (s.state() == .stopped) {
        // Stopped, but the frames did not arrive.
        try w.writeAll("Stopped; the call stack did not arrive in time (try debug_stack).\n");
        return .{ .ok = true };
    }
    try w.print("Still running after {d} ms. Call debug_wait_for_stop again, or debug_pause.\n", .{timeout_ms});
    return .{ .ok = false, .code = "timeout" };
}

fn ended(s: *DebugSession, arena: Allocator, w: *Io.Writer) !Outcome {
    if (s.state() == .failed) {
        const msg = try s.failureMessage(arena);
        try w.print("The session failed: {s}\n", .{msg orelse "no reason given"});
    } else if (s.exitCode()) |c| {
        try w.print("The program exited with code {d}.\n", .{c});
    } else try w.writeAll("The session ended.\n");
    try outputHint(s, arena, w);
    return .{ .ok = true };
}

fn outputHint(s: *DebugSession, arena: Allocator, w: *Io.Writer) !void {
    var tail: Io.Writer.Allocating = .init(arena);
    _ = try outputTail(s, arena, .{ .lines = .{ .integer = 10 } }, &tail.writer);
    const t = tail.written();
    if (std.mem.startsWith(u8, t, "No output")) return;
    try w.writeAll("Last output:\n");
    try w.writeAll(t);
}

fn stopped(h: Host, s: *DebugSession, arena: Allocator, top: DebugSession.FrameInfo, w: *Io.Writer) !Outcome {
    const ts = try s.threads(arena);
    const cur = s.currentThread();
    var reason: ?DebugSession.StopReason = null;
    var tname: []const u8 = "";
    for (ts) |t| if (t.id == cur) {
        reason = t.stop_reason;
        tname = t.name;
    };
    try w.print("Stopped: {s}", .{if (reason) |r| r.reason else "unknown"});
    if (reason) |r| if (r.description orelse r.text) |d| if (!std.mem.eql(u8, d, r.reason)) try w.print(" ({s})", .{d});
    if (cur) |t| try w.print(", thread {d} \"{s}\"", .{ t, tname });
    try w.writeByte('\n');
    try w.print("#0 {s}", .{top.name});
    if (top.path) |p| {
        try w.writeAll(" at ");
        try writeRel(w, h.root, p);
        try w.print(":{d}", .{top.line});
    }
    try w.print(" frame={d}\n", .{top.id});
    if (top.path) |p| excerpt(h, arena, p, top.line, w) catch {};
    if (reason) |r| if (std.mem.eql(u8, r.reason, "exception") and (s.caps().supportsExceptionInfoRequest orelse false)) {
        if (cur) |t| try exceptionInfo(s, arena, t, w);
    };
    return .{ .ok = true };
}

fn exceptionInfo(s: *DebugSession, arena: Allocator, thread: i64, w: *Io.Writer) !void {
    const args = try std.fmt.allocPrint(arena, "{{\"threadId\":{d}}}", .{thread});
    const body = switch (try s.request(arena, "exceptionInfo", args, request_timeout)) {
        .ok => |b| b orelse return,
        else => return,
    };
    const B = struct { exceptionId: []const u8 = "", description: ?[]const u8 = null, breakMode: []const u8 = "", details: ?struct { message: ?[]const u8 = null, typeName: ?[]const u8 = null, stackTrace: ?[]const u8 = null } = null };
    const b = parse(B, arena, body) orelse return;
    try w.print("Exception: {s}", .{b.exceptionId});
    if (b.description) |d| try w.print(": {s}", .{d});
    try w.writeByte('\n');
    if (b.details) |d| {
        if (d.typeName) |t| try w.print("Type: {s}\n", .{t});
        if (d.message) |m| if (b.description == null or !std.mem.eql(u8, m, b.description.?)) try w.print("Message: {s}\n", .{m});
    }
}

/// Lines `line - 2 … line + 2` of `path`, the stop's marked.
fn excerpt(h: Host, arena: Allocator, path: []const u8, line: u32, w: *Io.Writer) !void {
    if (line == 0) return;
    const data = try Io.Dir.cwd().readFileAlloc(h.io, path, arena, .limited(8 << 20));
    var it = std.mem.splitScalar(u8, data, '\n');
    var n: u32 = 1;
    const first = if (line > 2) line - 2 else 1;
    while (it.next()) |text| : (n += 1) {
        if (n < first) continue;
        if (n > line + 2) break;
        try w.print("{s}{d: >5} | ", .{ if (n == line) ">" else " ", n });
        try writeValue(w, std.mem.trimEnd(u8, text, "\r"));
        try w.writeByte('\n');
    }
}

fn writeRel(w: *Io.Writer, root: []const u8, path: []const u8) Io.Writer.Error!void {
    var p = path;
    if (root.len > 0 and p.len > root.len + 1 and std.mem.startsWith(u8, p, root) and (p[root.len] == '/' or p[root.len] == '\\')) p = p[root.len + 1 ..];
    for (p) |c| try w.writeByte(if (c == '\\') '/' else c);
}

fn resultJson(arena: Allocator, text: []const u8, is_error: bool, code: ?[]const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const Content = struct { content: []const struct { type: []const u8 = "text", text: []const u8 } };
    const head = try std.json.Stringify.valueAlloc(arena, Content{ .content = &.{.{ .text = text }} }, .{});
    try out.appendSlice(arena, head[0 .. head.len - 1]);
    if (code) |c| try out.print(arena, ",\"structuredContent\":{{\"code\":\"{s}\"}}", .{c});
    try out.print(arena, ",\"isError\":{}}}", .{is_error});
    return out.items;
}
