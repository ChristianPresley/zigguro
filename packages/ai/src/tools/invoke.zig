//! The tool invoke pipeline (E10.F06.S01.T02): the one path every tool
//! call takes.
//!
//! 1. Validate the input against the tool's schema. Invalid input is an
//!    `is_error` result and no hook runs.
//! 2. `PreToolUse` hooks: deny ends the call, allow skips the prompt (deny
//!    rules still apply), ask forces one, and an updated input is
//!    validated again.
//! 3. The permission decision (E16 in the app). An input the user edited
//!    in the approval is validated again.
//! 4. The handler. A Zig error becomes an instructive `is_error` text.
//! 5. `PostToolUse` (or `PostToolUseFailure`) hooks: extra context is
//!    appended, an updated output replaces the result.
//! 6. Bounding: text over `max_output_chars` is saved whole under
//!    `spill_dir` and the model gets the head, the tail and a pointer.
//!
//! Every decision goes to the audit sink and the observer.

const std = @import("std");
const proto = @import("zg_ai_proto");
const deps = @import("../loop/deps.zig");
const validate = @import("../schema/validate.zig");
const schema_errors = @import("../schema/errors.zig");
const scheduler = @import("../loop/scheduler.zig");
const readonly = @import("../plan/readonly.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const canceled_text = scheduler.canceled_text;
pub const plan_denied = "plan mode is read-only";

pub const Bounds = struct {
    /// Text beyond this many bytes is cut.
    max_output_chars: u32 = 30_000,
    /// The head kept from cut text.
    preview_chars: u32 = 2_000,
    /// The tail kept from cut text.
    tail_chars: u32 = 2_000,
    /// Where cut output is saved whole, as `<call id>.txt`; null keeps no copy.
    spill_dir: ?[]const u8 = null,
};

/// Compiled input schemas, one per schema text, shared by an agent's calls.
pub const Schemas = struct {
    gpa: Allocator,
    io: Io,
    validator: validate.Validator,
    mutex: Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    map: std.StringHashMapUnmanaged(?validate.Compiled) = .empty,

    pub fn init(gpa: Allocator, io: Io, v: validate.Validator) Schemas {
        return .{ .gpa = gpa, .io = io, .validator = v, .arena = .init(gpa) };
    }

    pub fn deinit(s: *Schemas) void {
        s.map.deinit(s.gpa);
        s.arena.deinit();
    }

    /// The compiled schema of `spec`; null when it does not compile (the
    /// registry reports those, the call is not blocked by them).
    pub fn get(s: *Schemas, spec: *const proto.ToolSpec) Allocator.Error!?validate.Compiled {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const gop = try s.map.getOrPut(s.gpa, spec.input_schema_json);
        if (gop.found_existing) return gop.value_ptr.*;
        const a = s.arena.allocator();
        gop.key_ptr.* = a.dupe(u8, spec.input_schema_json) catch |e| {
            s.map.removeByPtr(gop.key_ptr);
            return e;
        };
        gop.value_ptr.* = validate.Compiled.init(s.validator, a, spec.input_schema_json) catch |e| switch (e) {
            error.OutOfMemory => {
                s.map.removeByPtr(gop.key_ptr);
                return error.OutOfMemory;
            },
            error.InvalidSchema, error.SchemaTooLarge => null,
        };
        return gop.value_ptr.*;
    }
};

/// Hears about calls as they move through the pipeline (the agent's bus).
pub const Observer = struct {
    ctx: *anyopaque,
    /// The handler is about to run.
    started: *const fn (ctx: *anyopaque, id: []const u8) void,
    decision: *const fn (ctx: *anyopaque, d: deps.ToolDecision) void,
};

pub const Pipeline = struct {
    permission: deps.Permission = .allow_all,
    hooks: ?deps.Hooks = null,
    audit: ?deps.Audit = null,
    /// Null skips validation.
    schemas: ?*Schemas = null,
    bounds: Bounds = .{},
    observer: ?Observer = null,
    /// Plan mode: only what `readonly.planAllows` runs, whatever the
    /// toolset declared.
    plan_mode: bool = false,
};

pub const Call = struct {
    id: []const u8,
    spec: *const proto.ToolSpec,
    input_json: []const u8,
    agent: proto.AgentRef = .{ .session = 0 },
    turn: u32 = 0,
    progress: ?proto.tool.ProgressSink = null,
};

/// Runs one call; the output is allocated in `ar`. Cancelation becomes a
/// canceled result.
pub fn invoke(p: *const Pipeline, io: Io, ar: Allocator, c: Call) proto.ToolOutput {
    return run(p, io, ar, c) catch |e| switch (e) {
        error.Canceled => errText(ar, canceled_text),
        error.OutOfMemory => errText(ar, "The harness ran out of memory."),
    };
}

const Error = Io.Cancelable || Allocator.Error;

fn run(p: *const Pipeline, io: Io, ar: Allocator, c: Call) Error!proto.ToolOutput {
    var input_json = c.input_json;
    var input = switch (try check(p, io, ar, c, input_json)) {
        .ok => |v| v,
        .invalid => |out| return out,
    };

    if (p.plan_mode and !readonly.planAllows(c.spec, input_json)) {
        note(p, io, c, .{ .id = c.id, .tool = c.spec.name, .stage = .permission, .outcome = .deny, .reason = plan_denied });
        return errText(ar, try std.fmt.allocPrint(ar, "Plan mode is read-only: {s} was not run. Present your plan with exit_plan_mode first.", .{c.spec.name}));
    }

    var hint: deps.Hint = .none;
    if (p.hooks) |h| if (h.pre_tool_use) |f| pre: {
        const d = f(h.ctx, io, ar, c.agent, c.spec, input_json) catch |e| switch (e) {
            error.Canceled => return error.Canceled,
            else => break :pre,
        };
        if (d.updated_input_json) |u| {
            note(p, io, c, .{ .id = c.id, .tool = c.spec.name, .stage = .pre_hook, .outcome = .edit, .reason = d.reason });
            input_json = u;
            input = switch (try check(p, io, ar, c, input_json)) {
                .ok => |v| v,
                .invalid => |out| return out,
            };
        }
        switch (d.decision) {
            .none => {},
            .deny => {
                note(p, io, c, .{ .id = c.id, .tool = c.spec.name, .stage = .pre_hook, .outcome = .deny, .reason = d.reason });
                return errText(ar, try std.fmt.allocPrint(ar, "Blocked by a PreToolUse hook: {s}", .{if (d.reason.len > 0) d.reason else "no reason given"}));
            },
            .allow => {
                note(p, io, c, .{ .id = c.id, .tool = c.spec.name, .stage = .pre_hook, .outcome = .allow, .reason = d.reason });
                hint = .hook_allow;
            },
            .ask => {
                note(p, io, c, .{ .id = c.id, .tool = c.spec.name, .stage = .pre_hook, .outcome = .ask, .reason = d.reason });
                hint = .hook_ask;
            },
        }
    };

    switch (try p.permission.decide(io, c.agent, c.spec, input_json, hint)) {
        .allow => note(p, io, c, .{ .id = c.id, .tool = c.spec.name, .stage = .permission, .outcome = .allow }),
        .deny => |why| {
            note(p, io, c, .{ .id = c.id, .tool = c.spec.name, .stage = .permission, .outcome = .deny, .reason = why });
            return errText(ar, try std.fmt.allocPrint(ar, "Permission denied: {s}", .{why}));
        },
        .allow_edited => |u| {
            note(p, io, c, .{ .id = c.id, .tool = c.spec.name, .stage = .permission, .outcome = .edit });
            input_json = try ar.dupe(u8, u);
            input = switch (try check(p, io, ar, c, input_json)) {
                .ok => |v| v,
                .invalid => |out| return out,
            };
        },
    }

    if (p.observer) |o| o.started(o.ctx, c.id);
    var call: proto.ToolCall = .{
        .id = c.id,
        .name = c.spec.name,
        .input_json = input_json,
        .input = input,
        .arena = ar,
        .io = io,
        .agent = c.agent,
        .turn = c.turn,
        .progress = c.progress,
    };
    var out = c.spec.handler.call(c.spec.handler.ctx, &call) catch |e| switch (e) {
        error.Canceled => return error.Canceled,
        else => errText(ar, handlerErrorText(e)),
    };

    if (p.hooks) |h| if (h.post_tool_use) |f| post: {
        const d = f(h.ctx, io, ar, c.agent, c.spec, input_json, &out, out.is_error) catch |e| switch (e) {
            error.Canceled => return error.Canceled,
            else => break :post,
        };
        if (d.updated_output) |u| {
            note(p, io, c, .{ .id = c.id, .tool = c.spec.name, .stage = .post_hook, .outcome = .replace });
            out = u;
        }
        if (d.additional_context) |text| {
            note(p, io, c, .{ .id = c.id, .tool = c.spec.name, .stage = .post_hook, .outcome = .context });
            const parts = try ar.alloc(proto.ResultPart, out.parts.len + 1);
            @memcpy(parts[0..out.parts.len], out.parts);
            parts[out.parts.len] = .{ .text = text };
            out.parts = parts;
        }
    };

    return bound(p, io, ar, c, out);
}

const Checked = union(enum) { ok: std.json.Value, invalid: proto.ToolOutput };

fn check(p: *const Pipeline, io: Io, ar: Allocator, c: Call, input_json: []const u8) Allocator.Error!Checked {
    const s = p.schemas orelse return .{ .ok = std.json.parseFromSliceLeaky(std.json.Value, ar, input_json, .{}) catch .null };
    const compiled = try s.get(c.spec) orelse return .{ .ok = std.json.parseFromSliceLeaky(std.json.Value, ar, input_json, .{}) catch .null };
    const r = try compiled.check(ar, input_json);
    if (r.ok) return .{ .ok = r.value };
    var w: std.Io.Writer.Allocating = .init(ar);
    schema_errors.formatForModel(c.spec.name, &r.errors, &w.writer) catch return error.OutOfMemory;
    const text = w.written();
    note(p, io, c, .{ .id = c.id, .tool = c.spec.name, .stage = .validation, .outcome = .deny, .reason = text });
    return .{ .invalid = errText(ar, text) };
}

/// What the model is told when a handler fails without a result.
pub fn handlerErrorText(e: proto.ToolError) []const u8 {
    return switch (e) {
        error.Canceled => canceled_text,
        error.Timeout => "The tool timed out. Try a smaller request, or run it in the background if the tool allows that.",
        error.Unavailable => "The tool is not available right now. Try again later or use another tool.",
        error.OutOfMemory => "The tool ran out of memory. Try a smaller request.",
        error.Failed => "The tool failed without a message. Check the input and try again, or use another tool.",
    };
}

/// Cuts text parts longer than the bounds. All text parts count together;
/// other parts are kept as they are.
fn bound(p: *const Pipeline, io: Io, ar: Allocator, c: Call, out: proto.ToolOutput) Allocator.Error!proto.ToolOutput {
    const b = p.bounds;
    var total: usize = 0;
    var texts: usize = 0;
    for (out.parts) |part| if (part == .text) {
        total += part.text.len;
        texts += 1;
    };
    if (total <= b.max_output_chars) return out;

    const full = if (texts == 1) for (out.parts) |part| {
        if (part == .text) break part.text;
    } else unreachable else blk: {
        var all: std.ArrayList(u8) = .empty;
        var first = true;
        for (out.parts) |part| if (part == .text) {
            if (!first) try all.append(ar, '\n');
            first = false;
            try all.appendSlice(ar, part.text);
        };
        break :blk all.items;
    };
    const saved = if (b.spill_dir) |dir| spill(io, ar, dir, c.id, full) else null;
    // Cut at line ends where the kept parts have one.
    var head_end = utf8Floor(full, @min(b.preview_chars, full.len));
    if (std.mem.lastIndexOfScalar(u8, full[0..head_end], '\n')) |nl| head_end = nl + 1;
    const head = full[0..head_end];
    var tail_start = utf8Ceil(full, full.len - @min(b.tail_chars, full.len - head.len));
    if (tail_start > head_end and full[tail_start - 1] != '\n') {
        if (std.mem.indexOfScalarPos(u8, full, tail_start, '\n')) |nl| if (nl + 1 < full.len) {
            tail_start = nl + 1;
        };
    }
    const tail = std.mem.trimEnd(u8, full[tail_start..], "\n");
    const notice = if (saved) |path|
        try std.fmt.allocPrint(ar, "[output truncated: {d} chars total; full output saved to {s}; use read_file with offset/limit to see more]", .{ full.len, path })
    else
        try std.fmt.allocPrint(ar, "[output truncated: {d} chars total; {d} chars omitted]", .{ full.len, full.len - head.len - (full.len - tail_start) });
    const text = try std.fmt.allocPrint(ar, "{s}{s}…\n{s}\n{s}", .{ head, if (std.mem.endsWith(u8, head, "\n") or head.len == 0) "" else "\n", tail, notice });
    note(p, io, c, .{ .id = c.id, .tool = c.spec.name, .stage = .bound, .outcome = .truncate, .reason = notice });

    const parts = try ar.alloc(proto.ResultPart, out.parts.len - texts + 1);
    parts[0] = .{ .text = text };
    var i: usize = 1;
    for (out.parts) |part| if (part != .text) {
        parts[i] = part;
        i += 1;
    };
    var r = out;
    r.parts = parts;
    r.truncated = true;
    return r;
}

/// Writes `text` to `dir/<id>.txt`; the path, or null when it failed.
fn spill(io: Io, ar: Allocator, dir: []const u8, id: []const u8, text: []const u8) ?[]const u8 {
    const name = ar.alloc(u8, id.len) catch return null;
    for (id, name) |ch, *o| o.* = if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_') ch else '_';
    const path = std.fmt.allocPrint(ar, "{s}/{s}.txt", .{ dir, name }) catch return null;
    Io.Dir.cwd().createDirPath(io, dir) catch return null;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text }) catch return null;
    return path;
}

fn utf8Floor(s: []const u8, i: usize) usize {
    var j = i;
    while (j > 0 and j < s.len and s[j] & 0xC0 == 0x80) j -= 1;
    return j;
}

fn utf8Ceil(s: []const u8, i: usize) usize {
    var j = i;
    while (j < s.len and s[j] & 0xC0 == 0x80) j += 1;
    return j;
}

/// Audits every decision; the observer hears all but plain permission
/// allows, which every ordinary call has.
fn note(p: *const Pipeline, io: Io, c: Call, d: deps.ToolDecision) void {
    if (p.audit) |a| a.record(a.ctx, io, c.agent, d);
    if (d.stage == .permission and d.outcome == .allow) return;
    if (p.observer) |o| o.decision(o.ctx, d);
}

fn errText(ar: Allocator, text: []const u8) proto.ToolOutput {
    return proto.ToolOutput.text(ar, text, true) catch .{ .parts = &.{}, .is_error = true };
}
