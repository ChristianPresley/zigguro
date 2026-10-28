//! One agent invocation in a workflow (E13.F08.S01.T03): render the
//! prompt (interpolation or a prompt library entry), compute the replay
//! key, reuse a journaled result or start a child run, wait for it with
//! stall detection, and check structured output.
//!
//! With a `schema`, the prompt ends with the schema and an instruction to
//! answer with only a matching JSON value; the answer is parsed (code
//! fences and surrounding prose are tolerated) and validated. A rejected
//! answer starts the agent again with the errors appended, up to
//! `max_retries` times; so does a stall (no activity for `stall_ms`).
//! A worker that fails, or every attempt used up, fails the agent.

const std = @import("std");
const zg_ai = @import("zg_ai");
const exec = @import("exec.zig");
const def = @import("def.zig");
const path_mod = @import("path.zig");
const interp = @import("interpolate.zig");
const validate_mod = @import("validate.zig");
const JournalStore = @import("journal.zig");
const PromptLibrary = @import("../library/index.zig");
const RunId = @import("../runs/run.zig").RunId;

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Value = std.json.Value;
const Exec = exec.Exec;
const Abort = exec.Abort;
const Outcome = exec.Outcome;
const ErrorList = zg_ai.schema.validate.ErrorList;

pub const schema_instruction = "\n\nWhen you are done, answer with only a JSON value that matches this JSON Schema (no prose, no code fences):\n";
pub const retry_instruction = "\n\nYour previous answer was rejected:\n";
pub const citation_instruction = "\n\nCite the source of every claim as [id], using only the source ids below.\n";

pub const Prepared = struct {
    step: []const u8,
    pos: []const u8,
    ag: *const def.AgentStep,
    item: ?u32,
    seed: u64,
    prompt: []const u8,
    /// Schema text when the step has one.
    schema: ?[]const u8,
    key: JournalStore.ReplayKey,
    /// The journaled result (resume).
    hit: ?Value = null,
};

pub const Prep = union(enum) { ready: Prepared, failed: []const u8 };

/// Renders the prompt and looks the agent up in the previous journal.
pub fn prepare(x: *Exec, step: []const u8, ag: *const def.AgentStep, scope: Value, pos: []const u8, item: ?u32, seed: u64) Abort!Prep {
    const a = x.allocator();
    var lib_hash: ?u64 = null;
    var text: []const u8 = undefined;
    if (ag.prompt.len > 0 and ag.prompt[0] == '@') {
        const id = ag.prompt[1..];
        const lib = x.eng.svc.library orelse return fail(a, "no prompt library for {s}", .{ag.prompt});
        const entry = lib.get(id) orelse return fail(a, "unknown library prompt {s}", .{ag.prompt});
        const body = lib.body(id, a) catch |e| return failErr(a, e, "cannot read {s}", .{ag.prompt});
        const vars = try a.alloc(@import("../library/template.zig").Var, ag.with.len);
        for (ag.with, vars) |b, *v| {
            const val = if (path_mod.isPath(b.value)) blk: {
                const p = path_mod.Path.compile(a, b.value) catch return fail(a, "invalid path {s}", .{b.value});
                break :blk try interp.render(a, try p.value(scope, a));
            } else b.value;
            v.* = .{ .name = b.name, .value = val };
        }
        const r = PromptLibrary.render(a, body, entry.variables, vars, .{}) catch |e| return failErr(a, e, "cannot render {s}", .{ag.prompt});
        if (r.missing.len > 0) return fail(a, "{s}: no value for {s}", .{ ag.prompt, r.missing[0] });
        if (r.invalid.len > 0) return fail(a, "{s}: {s} is {s}", .{ ag.prompt, r.invalid[0].name, r.invalid[0].reason });
        text = r.text;
        lib_hash = lib.bodyHash(id) catch null;
    } else {
        const r = interp.interpolate(a, ag.prompt, scope, .{ .spill = x.spillPort(), .untrusted = x.untrusted }) catch |e| return failErr(a, e, "cannot fill in the prompt", .{});
        text = r.text;
    }
    if (ag.citations) {
        var srcs: []const u8 = "";
        if (ag.sources) |sp| {
            const p = path_mod.Path.compile(a, sp) catch return fail(a, "invalid path {s}", .{sp});
            srcs = try interp.render(a, try p.value(scope, a));
        }
        text = try std.mem.concat(a, u8, &.{ text, citation_instruction, srcs });
    }
    var schema: ?[]const u8 = null;
    if (ag.schema) |sch| {
        schema = validate_mod.schemaText(a, x.schema_files, sch) orelse return fail(a, "cannot read schema {s}", .{sch});
        text = try std.mem.concat(a, u8, &.{ text, schema_instruction, schema.? });
    }
    const key = JournalStore.replayKey(pos, item, text, ag.tools orelse &.{}, ag.model_role, schema, lib_hash);
    return .{ .ready = .{
        .step = step,
        .pos = pos,
        .ag = ag,
        .item = item,
        .seed = seed,
        .prompt = text,
        .schema = schema,
        .key = key,
        .hit = try x.lookup(pos, key),
    } };
}

fn fail(a: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!Prep {
    return .{ .failed = try std.fmt.allocPrint(a, fmt, args) };
}

fn failErr(a: Allocator, e: anyerror, comptime fmt: []const u8, args: anytype) Allocator.Error!Prep {
    if (e == error.OutOfMemory) return error.OutOfMemory;
    return .{ .failed = try std.fmt.allocPrint(a, fmt ++ ": {t}", args ++ .{e}) };
}

/// `prepare` then `execute`.
pub fn runOne(x: *Exec, step: []const u8, ag: *const def.AgentStep, scope: Value, pos: []const u8, item: ?u32, seed: u64) Abort!Outcome {
    return switch (try prepare(x, step, ag, scope, pos, item, seed)) {
        .ready => |p| execute(x, &p),
        .failed => |m| .{ .failed = m },
    };
}

/// Runs a prepared agent (or returns its journaled result).
pub fn execute(x: *Exec, prep: *const Prepared) Abort!Outcome {
    const a = x.allocator();
    if (prep.hit) |v| {
        x.tracker.agent(prep.step, .reused);
        return .{ .ok = v };
    }
    const ag = prep.ag;
    var prompt = prep.prompt;
    var last_err: []const u8 = "";
    var attempt: u8 = 0;
    while (attempt <= ag.max_retries) : (attempt += 1) {
        const r = try attemptOnce(x, prep, prompt, attempt);
        switch (r) {
            .ok => |v| {
                x.tracker.agent(prep.step, .ok);
                return .{ .ok = v };
            },
            .fatal => |m| {
                x.tracker.agent(prep.step, .failed);
                return .{ .failed = m };
            },
            .rejected => |m| {
                last_err = m;
                prompt = try std.mem.concat(a, u8, &.{ prep.prompt, retry_instruction, m, "\nAnswer again with only the JSON value." });
            },
            .stalled => last_err = try std.fmt.allocPrint(a, "no activity for {d} ms", .{ag.stall_ms}),
            .restart => {},
        }
    }
    x.tracker.agent(prep.step, .failed);
    return .{ .failed = try std.fmt.allocPrint(a, "gave up after {d} attempts: {s}", .{ @as(u32, ag.max_retries) + 1, last_err }) };
}

const Attempt = union(enum) {
    ok: Value,
    /// Failed for good.
    fatal: []const u8,
    /// Schema validation failed: retry with this message.
    rejected: []const u8,
    stalled,
    /// Restarted on request.
    restart,
};

/// One attempt, recorded in the progress's worker list.
fn attemptOnce(x: *Exec, prep: *const Prepared, prompt: []const u8, attempt: u8) Abort!Attempt {
    var child: ?RunId = null;
    const r = attemptRun(x, prep, prompt, attempt, &child);
    const c = child orelse return r;
    const now = x.eng.nowMs();
    const t = &x.tracker;
    const out = r catch |err| {
        t.workerEnded(c, .stopped, "stopped", now);
        return err;
    };
    switch (out) {
        .ok => |v| switch (v) {
            .string => |str| t.workerEnded(c, .done, str, now),
            else => t.workerEnded(c, .done, std.json.Stringify.valueAlloc(x.allocator(), v, .{}) catch "", now),
        },
        .fatal => |m| t.workerEnded(c, .failed, m, now),
        .rejected => |m| t.workerEnded(c, .failed, m, now),
        .stalled => t.workerEnded(c, .failed, "stalled", now),
        .restart => t.workerEnded(c, .stopped, "restarted", now),
    }
    return out;
}

fn attemptRun(x: *Exec, prep: *const Prepared, prompt: []const u8, attempt: u8, child: *?RunId) Abort!Attempt {
    const e = x.eng;
    const io = e.io;
    const a = x.allocator();
    const ag = prep.ag;
    try x.acquire(attempt == 0);
    defer x.release();
    if (attempt > 0) x.tracker.agent(prep.step, .retried) else x.tracker.agent(prep.step, .started);
    const p = try a.create(exec.Pending);
    p.* = .{ .x = x, .child = e.newId(), .step = prep.step, .pos = prep.pos, .last_activity_ms = .init(e.nowMs()) };
    x.tracker.workerStarted(.{ .child = p.child, .step = prep.step, .pos = prep.pos, .attempt = attempt, .prompt = prompt, .started_ms = e.nowMs() });
    child.* = p.child;
    try x.track(p);
    defer x.untrack(p);
    const seq = x.nextSeq();
    x.journal.recordStart(seq, prep.pos, prep.key, p.child) catch |err| return exec.mapErr(err);
    const req: exec.WorkerRequest = .{
        .child = p.child,
        .parent = x.id,
        .step = prep.step,
        .pos = prep.pos,
        .title = ag.label orelse prep.pos,
        .prompt = prompt,
        .agent_def = ag.agent_def,
        .tools = ag.tools,
        .model_role = ag.model_role,
        .isolation = switch (ag.isolation) {
            .shared => .shared,
            .lane => .lane,
        },
        .profile = x.def.profile orelse "default",
        .budgets = x.childBudgets(),
        .attempt = attempt,
        .seed = prep.seed,
    };
    e.svc.workers.start(e.svc.workers.ctx, &req) catch |err| {
        const m = try std.fmt.allocPrint(a, "cannot start the agent: {t}", .{err});
        x.journal.recordResult(seq, .{ .failed = m }) catch {};
        return .{ .fatal = m };
    };
    // Wait for an outcome, a stall or a stop.
    while (!p.ev.isSet()) {
        if (x.stopped()) {
            x.journal.recordResult(seq, .stopped) catch {};
            return error.Stopped;
        }
        const idle = e.nowMs() - p.last_activity_ms.load(.acquire);
        if (idle >= ag.stall_ms) {
            e.svc.workers.stop(e.svc.workers.ctx, p.child);
            x.journal.recordResult(seq, .{ .failed = "stalled" }) catch {};
            return .stalled;
        }
        const ms: i64 = @min(@as(i64, ag.stall_ms) - idle, e.svc.stall_poll_ms);
        p.ev.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(@max(ms, 1)), .clock = .awake } }) catch |err| switch (err) {
            error.Timeout => {},
            error.Canceled => return error.Canceled,
        };
    }
    switch (p.take().?) {
        .failed => |m| {
            x.journal.recordResult(seq, .{ .failed = m }) catch |err| return exec.mapErr(err);
            return .{ .fatal = m };
        },
        .stopped => {
            x.journal.recordResult(seq, .stopped) catch |err| return exec.mapErr(err);
            if (x.stopped()) return error.Stopped;
            if (p.restart_req.load(.acquire)) return .restart;
            return .{ .fatal = "the agent was stopped" };
        },
        .result => |text| {
            const v: Value = if (prep.schema) |sch| switch (try structured(x, a, text, sch)) {
                .ok => |v| v,
                .rejected => |m| {
                    x.journal.recordResult(seq, .{ .failed = m }) catch |err| return exec.mapErr(err);
                    return .{ .rejected = m };
                },
            } else .{ .string = text };
            x.journal.recordResult(seq, .{ .ok = v }) catch |err| return exec.mapErr(err);
            return .{ .ok = v };
        },
    }
}

const Checked = union(enum) { ok: Value, rejected: []const u8 };

/// Parses and validates a structured answer.
fn structured(x: *Exec, a: Allocator, text: []const u8, schema: []const u8) Allocator.Error!Checked {
    const v = parseAnswer(a, text) orelse return .{ .rejected = "the answer is not valid JSON" };
    const val = x.eng.svc.validator orelse return .{ .ok = v };
    const compiled = val.compile(val.ctx, a, schema) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .rejected = "the output schema does not compile" },
    };
    var errs: ErrorList = .{};
    if (val.validate(val.ctx, compiled, a, v, &errs)) return .{ .ok = v };
    var w: Io.Writer.Allocating = .init(a);
    for (errs.slice()) |er| w.writer.print("- {s}: {s}\n", .{ if (er.pointer.len == 0) "/" else er.pointer, er.message }) catch return error.OutOfMemory;
    if (errs.overflow > 0) w.writer.print("- and {d} more\n", .{errs.overflow}) catch return error.OutOfMemory;
    return .{ .rejected = std.mem.trimEnd(u8, w.written(), "\n") };
}

/// The JSON value in an answer: the whole text, a fenced block, or the
/// outermost `{…}` / `[…]`.
pub fn parseAnswer(a: Allocator, text: []const u8) ?Value {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (tryParse(a, t)) |v| return v;
    if (std.mem.indexOf(u8, t, "```")) |o| {
        const nl = std.mem.indexOfScalarPos(u8, t, o, '\n') orelse return null;
        const close = std.mem.indexOfPos(u8, t, nl, "```") orelse t.len;
        if (tryParse(a, t[nl + 1 .. close])) |v| return v;
    }
    const open = std.mem.indexOfAny(u8, t, "{[") orelse return null;
    const want: u8 = if (t[open] == '{') '}' else ']';
    const close = std.mem.lastIndexOfScalar(u8, t, want) orelse return null;
    if (close <= open) return null;
    return tryParse(a, t[open .. close + 1]);
}

fn tryParse(a: Allocator, s: []const u8) ?Value {
    return std.json.parseFromSliceLeaky(Value, a, s, .{ .allocate = .alloc_always }) catch null;
}
