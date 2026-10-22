//! `ToolScheduler`: runs one response's tool calls with as much
//! parallelism as is safe. A call starts once every earlier call it
//! conflicts with has finished, so dependent operations keep the model's
//! order and independent ones overlap:
//! - read-only calls conflict only with writers of the same resource;
//! - writes lock their paths exclusively;
//! - commands are serialized (per terminal, and globally unless
//!   `parallel_commands`);
//! - `workspace_global` (and any mutating call without declared
//!   resources) excludes everything.
//! `out[i]` always answers `calls[i]`, even for skipped or canceled calls.

const std = @import("std");
const proto = @import("zg_ai_proto");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const ToolOutput = proto.tool.ToolOutput;

pub const Resource = union(enum) {
    path: []const u8,
    terminal: u64,
    scm,
    workspace_global,
    /// Host; never conflicts.
    network: []const u8,
};

pub const Call = struct {
    id: []const u8,
    spec: *const proto.tool.ToolSpec,
    input: std.json.Value = .null,
    input_json: []const u8 = "{}",
    resources: []const Resource = &.{},

    fn mutating(c: *const Call) bool {
        return !c.spec.effectiveEffects().read_only;
    }

    fn global(c: *const Call) bool {
        if (c.mutating() and c.resources.len == 0) return true;
        for (c.resources) |r| if (r == .workspace_global) return true;
        return false;
    }
};

pub const Policy = struct {
    max_parallel: u8 = 8,
    sequential_after_failure: bool = true,
    /// `ai.parallelCommands`: commands on different terminals may overlap.
    parallel_commands: bool = false,
};

/// Runs one call. Must not fail: tool errors become `is_error` outputs.
/// Should return promptly once `io` is canceled.
pub const Invoke = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, io: Io, index: usize, c: *const Call) ToolOutput,
};

pub const Outcome = enum { pending, running, done, skipped, canceled };

/// True when `a` and `b` must not run at the same time.
pub fn conflicts(p: Policy, a: *const Call, b: *const Call) bool {
    if (a.global() or b.global()) return true;
    const ea = a.spec.effectiveEffects();
    const eb = b.spec.effectiveEffects();
    if (ea.executes and eb.executes and !p.parallel_commands) return true;
    const either_mut = a.mutating() or b.mutating();
    for (a.resources) |ra| for (b.resources) |rb| switch (ra) {
        .path => |pa| if (rb == .path and either_mut and std.mem.eql(u8, pa, rb.path)) return true,
        .terminal => |ta| if (rb == .terminal and ta == rb.terminal) return true,
        .scm => if (rb == .scm and either_mut) return true,
        .workspace_global => return true,
        .network => {},
    };
    return false;
}

pub const not_executed_fmt = "Not executed: the preceding {s} call failed.";
pub const canceled_text = "Canceled by user";

const Run = struct {
    io: Io,
    policy: Policy,
    calls: []const Call,
    invoke: Invoke,
    out: []ToolOutput,
    state: []Outcome,
    arena: Allocator,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    running: u32 = 0,
    oom: bool = false,

    fn task(r: *Run, i: usize) void {
        const o = r.invoke.call(r.invoke.ctx, r.io, i, &r.calls[i]);
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        r.finishLocked(i, o);
    }

    fn finishLocked(r: *Run, i: usize, o: ToolOutput) void {
        r.running -= 1;
        if (r.state[i] == .canceled) return;
        r.out[i] = o;
        r.state[i] = .done;
        if (o.is_error and r.policy.sequential_after_failure and r.calls[i].mutating()) {
            for (r.calls[i + 1 ..], i + 1..) |*c, j| {
                if (r.state[j] != .pending or !c.mutating()) continue;
                const msg = std.fmt.allocPrint(r.arena, not_executed_fmt, .{r.calls[i].spec.name}) catch "Not executed: a preceding call failed.";
                r.out[j] = ToolOutput.text(r.arena, msg, true) catch .{ .parts = &.{}, .is_error = true };
                r.state[j] = .skipped;
            }
        }
        r.cond.broadcast(r.io);
    }

    fn ready(r: *Run, i: usize) bool {
        for (r.calls[0..i], 0..) |*c, j| {
            if ((r.state[j] == .pending or r.state[j] == .running) and conflicts(r.policy, c, &r.calls[i])) return false;
        }
        return true;
    }
};

/// Runs `calls`, filling `out` and `outcome` (same length). On cancel every
/// unfinished call gets an `is_error` "Canceled by user" result and
/// `error.Canceled` is returned. `arena` backs synthesized results.
pub fn run(io: Io, arena: Allocator, policy: Policy, calls: []const Call, invoke: Invoke, out: []ToolOutput, outcome: []Outcome) Io.Cancelable!void {
    std.debug.assert(out.len == calls.len and outcome.len == calls.len);
    @memset(outcome, .pending);
    var r: Run = .{ .io = io, .policy = policy, .calls = calls, .invoke = invoke, .out = out, .state = outcome, .arena = arena };
    var group: Io.Group = .init;
    const max: u32 = @max(policy.max_parallel, 1);

    r.mutex.lockUncancelable(io);
    var canceled = false;
    outer: while (true) {
        var all_done = true;
        for (calls, 0..) |_, i| {
            if (r.state[i] == .pending or r.state[i] == .running) all_done = false;
            if (r.state[i] != .pending or r.running >= max or !r.ready(i)) continue;
            r.state[i] = .running;
            r.running += 1;
            group.concurrent(io, Run.task, .{ &r, i }) catch {
                // No spare concurrency: run it here.
                r.mutex.unlock(io);
                const o = invoke.call(invoke.ctx, io, i, &calls[i]);
                r.mutex.lockUncancelable(io);
                r.finishLocked(i, o);
            };
        }
        if (all_done) break;
        r.cond.wait(io, &r.mutex) catch {
            canceled = true;
            // Calls running now are interrupted, whatever they return.
            for (r.state) |*s| if (s.* == .running) {
                s.* = .canceled;
            };
            break :outer;
        };
    }
    r.mutex.unlock(io);

    if (canceled) {
        group.cancel(io);
        for (outcome, out) |*s, *o| if (s.* != .done and s.* != .skipped) {
            o.* = ToolOutput.text(arena, canceled_text, true) catch .{ .parts = &.{}, .is_error = true };
            s.* = .canceled;
        };
        return error.Canceled;
    }
    group.await(io) catch {
        // Everything already finished; a cancel arriving now changes nothing.
    };
}
