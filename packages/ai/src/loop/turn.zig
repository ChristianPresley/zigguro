//! The turn loop. For each queued input:
//! 1. commit the user message (after `UserPromptSubmit` hooks);
//! 2. per model request: budget check, context assembly, `provider.stream`
//!    with every event forwarded to the bus, then commit the assistant
//!    message and record usage;
//! 3. branch on the stop reason and recovery: run tools and loop,
//!    resend on `pause_turn`, continue after an interrupted answer, fall
//!    back on refusal, let `Stop` hooks keep the turn going, or finish.
//!
//! Cancellation surfaces as `error.Canceled` from any step. Cleanup that
//! must finish (partial commit, synthesized tool results) runs with
//! cancelation blocked, so the transcript always stays protocol-valid:
//! every tool_use gets a tool_result.

const std = @import("std");
const proto = @import("zg_ai_proto");
const Agent = @import("Agent.zig");
const ev = @import("events.zig");
const budget = @import("budget.zig");
const scheduler = @import("scheduler.zig");
const deps = @import("deps.zig");
const invoke = @import("../tools/invoke.zig");
const iq = @import("input_queue.zig");
const Provider = @import("../provider/Provider.zig");
const pevents = @import("../provider/events.zig");
const request = @import("../provider/request.zig");
const MessageAssembler = @import("../provider/assembler.zig").MessageAssembler;
const recovery = @import("../provider/anthropic/recovery.zig");
const guarded = @import("../provider/guarded.zig");
const registry = @import("../models/registry.zig");
const pricing = @import("../models/pricing.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const json = proto.json;

/// Default output cap when neither the config nor the profile sets one.
pub const default_max_output: u32 = 16_384;

/// The turn task: processes queued inputs until none are left.
pub fn runTurns(a: *Agent) Io.Cancelable!void {
    while (true) {
        const input = blk: {
            a.mutex.lockUncancelable(a.io);
            defer a.mutex.unlock(a.io);
            if (a.queue.pop()) |in| break :blk in;
            a.running = false;
            break :blk null;
        };
        const in = input orelse {
            a.setStatus(.idle);
            a.finished.set(a.io);
            return;
        };
        defer in.free(a.gpa);
        const reason = runTurn(a, in) catch |e| switch (e) {
            error.Canceled => {
                finishTurn(a, .canceled, null);
                a.setStatus(.canceled);
                {
                    a.mutex.lockUncancelable(a.io);
                    defer a.mutex.unlock(a.io);
                    a.running = false;
                }
                a.setStatus(.idle);
                a.finished.set(a.io);
                return error.Canceled;
            },
        };
        _ = reason;
        // Steering that never met a tool batch becomes the next input.
        a.mutex.lockUncancelable(a.io);
        a.queue.takeAll(a.gpa, &a.steer) catch {};
        a.mutex.unlock(a.io);
    }
}

fn finishTurn(a: *Agent, reason: ev.FinishReason, kind: ?budget.Kind) void {
    {
        a.mutex.lockUncancelable(a.io);
        defer a.mutex.unlock(a.io);
        a.last_finish = reason;
    }
    a.publish(.{ .turn_finished = .{ .turn = a.turn_id, .reason = reason, .budget_kind = kind } });
}

fn fail(a: *Agent, kind: []const u8, message: []const u8, request_id: ?[]const u8) ev.FinishReason {
    const ar = a.arena.allocator();
    a.publish(.{ .error_ = .{ .kind = kind, .message = ar.dupe(u8, message) catch "", .request_id = if (request_id) |r| ar.dupe(u8, r) catch null else null } });
    finishTurn(a, .failed, null);
    a.setStatus(.failed);
    return .failed;
}

/// One turn. Returns how it ended; `error.Canceled` after a cancel.
fn runTurn(a: *Agent, in: iq.Owned) Io.Cancelable!ev.FinishReason {
    const ar = a.arena.allocator();
    a.turn_id += 1;
    a.publish(.{ .turn_started = a.turn_id });

    var scratch_state: std.heap.ArenaAllocator = .init(a.gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    var text: []const u8 = in.text;
    if (a.deps.hooks) |h| if (h.prompt_submit) |f| {
        const d = f(h.ctx, a.io, scratch, in.text) catch |e| switch (e) {
            error.Canceled => return error.Canceled,
            else => return fail(a, "hook_error", @errorName(e), null),
        };
        switch (d) {
            .allow => {},
            .block => |reason| {
                a.publish(.{ .warning = ar.dupe(u8, reason) catch "" });
                finishTurn(a, .blocked, null);
                return .blocked;
            },
            .add_context => |extra| text = std.mem.concat(scratch, u8, &.{ in.text, "\n\n", extra }) catch in.text,
        }
    };
    if (a.deps.checkpoints) |c| {
        // E12 checkpoint for rewind; the session log records it.
        const label = labelPrefix(in.text, 80);
        const id = c.create(c.ctx, a.io, a.ref, a.turn_id, label);
        const seq = a.bus.lastSeq() + 1;
        {
            a.mutex.lockUncancelable(a.io);
            defer a.mutex.unlock(a.io);
            a.checkpoints.append(ar, .{ .seq = seq, .id = id }) catch {};
        }
        a.publish(.{ .checkpoint = .{ .id = id, .turn = a.turn_id, .label = ar.dupe(u8, label) catch "" } });
    }
    commitText(a, .user, text, false) catch return fail(a, "out_of_memory", "could not record the input", null);

    var stop_continuations: u8 = 0;
    var recovery_attempt: u8 = 0;
    var compactions: u8 = 0;
    var model_override: ?[]const u8 = null;
    var max_override: ?u32 = null;

    while (true) {
        _ = scratch_state.reset(.retain_capacity);
        try a.io.checkCancel();
        if (a.takeClear()) |history| {
            defer a.gpa.free(history);
            clearHistory(a, scratch, history);
        }
        const model = a.deps.registry.resolve(model_override orelse a.cfg.model) orelse
            return fail(a, "unknown_model", model_override orelse a.cfg.model, null);
        const provider = a.deps.providers.get(model) orelse
            return fail(a, "no_provider", "no provider is configured for this model", null);
        const profile = a.deps.registry.profile(model.id, a.cfg.role);
        const max_out = @min(max_override orelse a.cfg.max_output_tokens orelse profile.max_output orelse default_max_output, model.max_output);
        const view: deps.ContextView = .{
            .agent = a.ref,
            .model = model,
            .profile = profile,
            .system_append = a.cfg.system_append,
            .cwd = a.cfg.cwd,
            .transcript = a.messages(),
            .tools = a.deps.tools.list(),
            .max_output_tokens = max_out,
        };
        const req = a.deps.context.build(a.deps.context.ctx, a.io, scratch, &view) catch |e| switch (e) {
            error.Canceled => return error.Canceled,
            error.ContextOverflow => {
                // Too big even to assemble: compact from the plain request.
                const base = deps.ContextBuilder.basic.build(deps.ContextBuilder.basic.ctx, a.io, scratch, &view) catch
                    return fail(a, "out_of_memory", "", null);
                if (compactions < max_compactions_per_turn and try compactHistory(a, scratch, &base, true)) {
                    compactions += 1;
                    continue;
                }
                return fail(a, "context_overflow", "the conversation no longer fits the model's context window", null);
            },
            else => return fail(a, "context_error", @errorName(e), null),
        };
        const est_input = guarded.estimateInputTokens(&req);
        if (a.deps.compaction) |c| if (compactions < max_compactions_per_turn and c.should_compact(c.ctx, est_input, model.context_window)) {
            if (try compactHistory(a, scratch, &req, false)) {
                compactions += 1;
                continue;
            }
        };

        a.used.wall_ms = a.wall.elapsedMs(a.io);
        switch (budget.beforeRequest(&a.cfg.budgets, a.usedSnapshot(), .{ .est_input = est_input, .max_output = max_out, .expected_cache_read = a.last_cache_read, .price = model.price })) {
            .ok => {},
            .warn => |k| warnBudget(a, k),
            .stop => |k| return stopBudget(a, k),
        }

        a.setStatus(.thinking);
        a.publish(.{ .request_sent = .{ .turn = a.turn_id, .model = ar.dupe(u8, model.id) catch "", .messages = @intCast(req.messages.len), .tools = @intCast(req.tools.len), .est_input_tokens = est_input } });

        var sink: StreamSink = .{ .a = a, .asm_ = .init(scratch) };
        sink.asm_.origin = provider.id;
        const result = provider.stream(a.io, scratch, &req, sink.eventSink());
        {
            a.mutex.lockUncancelable(a.io);
            defer a.mutex.unlock(a.io);
            a.used.turns += 1;
        }
        const resp = result catch |err| switch (err) {
            error.Canceled => {
                commitPartial(a, &sink.asm_);
                return error.Canceled;
            },
            error.ContextOverflow => {
                commitPartial(a, &sink.asm_);
                if (compactions < max_compactions_per_turn and try compactHistory(a, scratch, &req, true)) {
                    compactions += 1;
                    continue;
                }
                return fail(a, "context_overflow", "the conversation no longer fits the model's context window", null);
            },
            else => {
                commitPartial(a, &sink.asm_);
                const info = sink.asm_.error_info;
                return fail(a, @errorName(err), if (info) |i| i.message else "the model call failed", if (info) |i| i.request_id else null);
            },
        };

        const facts: recovery.ModelFacts = .{ .max_output = model.max_output, .continue_strategy = model.continue_strategy, .refusal_fallback = a.cfg.refusal_fallback, .auto_continue = a.cfg.auto_continue };
        const decision = recovery.decide(&resp, null, null, facts, max_out, recovery_attempt);
        recordUsage(a, model, &req, resp);

        switch (decision) {
            .retry_with_max_tokens => |n| {
                recovery_attempt += 1;
                a.publish(.{ .recovery = .{ .action = "retry_with_max_tokens" } });
                max_override = n;
                continue;
            },
            .fallback_model => |m| {
                recovery_attempt += 1;
                a.publish(.{ .recovery = .{ .action = "fallback_model", .detail = ar.dupe(u8, m) catch "" } });
                model_override = ar.dupe(u8, m) catch m;
                continue;
            },
            .compact_then_retry => if (compactions < max_compactions_per_turn and try compactHistory(a, scratch, &req, true)) {
                // The provider rejected the request as too long.
                compactions += 1;
                continue;
            },
            else => {},
        }

        var msg = resp.message;
        msg.meta.model = model.id;
        msg.meta.stop = resp.stop;
        msg.meta.usage = resp.usage;
        const committed = commit(a, msg) catch return fail(a, "out_of_memory", "could not record the response", null);

        switch (decision) {
            .continue_text => |strategy| {
                recovery_attempt += 1;
                a.publish(.{ .recovery = .{ .action = "continue_text" } });
                if (strategy == .user_continue_message) {
                    const hist = recovery.buildContinuation(scratch, &.{}, committed.*, strategy) catch return fail(a, "out_of_memory", "", null);
                    _ = commit(a, hist[0]) catch return fail(a, "out_of_memory", "", null);
                    continue;
                }
                a.publish(.{ .warning = "the answer hit the output limit" });
                finishTurn(a, .max_tokens, null);
                a.setStatus(.done);
                return .max_tokens;
            },
            .surface_to_user => |m| {
                a.publish(.{ .warning = ar.dupe(u8, m) catch "" });
                const reason: ev.FinishReason = if (resp.stop == .refusal) .refusal else .max_tokens;
                finishTurn(a, reason, null);
                a.setStatus(.done);
                return reason;
            },
            .compact_then_retry => return fail(a, "context_overflow", "the conversation no longer fits the model's context window", null),
            .resend_assistant_as_is => {
                recovery_attempt += 1;
                continue;
            },
            else => {},
        }

        switch (resp.stop) {
            .tool_use => {
                if (committed.toolUseCount() == 0) {
                    finishTurn(a, .end_turn, null);
                    a.setStatus(.done);
                    return .end_turn;
                }
                a.used.wall_ms = a.wall.elapsedMs(a.io);
                switch (budget.beforeTools(&a.cfg.budgets, a.usedSnapshot())) {
                    .ok => {},
                    .warn => |k| warnBudget(a, k),
                    .stop => |k| {
                        synthesizeResults(a, committed, "Not executed: the agent's budget is exhausted.");
                        return stopBudget(a, k);
                    },
                }
                try runTools(a, committed);
                recovery_attempt = 0;
            },
            .pause_turn => continue,
            .end_turn, .stop_sequence => {
                if (a.deps.hooks) |h| if (h.stop) |f| if (stop_continuations < a.cfg.max_stop_hook_continuations) {
                    const d = f(h.ctx, a.io, scratch, committed) catch |e| switch (e) {
                        error.Canceled => return error.Canceled,
                        else => return fail(a, "hook_error", @errorName(e), null),
                    };
                    if (d == .block) {
                        stop_continuations += 1;
                        commitText(a, .user, d.block, true) catch return fail(a, "out_of_memory", "", null);
                        continue;
                    }
                };
                finishTurn(a, .end_turn, null);
                a.setStatus(.done);
                syncSession(a);
                return .end_turn;
            },
            .refusal => {
                finishTurn(a, .refusal, null);
                a.setStatus(.done);
                return .refusal;
            },
            .max_tokens => {
                finishTurn(a, .max_tokens, null);
                a.setStatus(.done);
                return .max_tokens;
            },
            else => {
                finishTurn(a, .end_turn, null);
                a.setStatus(.done);
                return .end_turn;
            },
        }
    }
}

fn warnBudget(a: *Agent, k: budget.Kind) void {
    if (a.warned.first(k)) a.publish(.{ .budget = .{ .kind = k, .level = .warn } });
}

fn stopBudget(a: *Agent, k: budget.Kind) ev.FinishReason {
    a.publish(.{ .budget = .{ .kind = k, .level = .stop } });
    finishTurn(a, .budget, k);
    a.setStatus(.done);
    syncSession(a);
    return .budget;
}

/// Compactions one turn may run before giving up on an overflow.
pub const max_compactions_per_turn = 2;

/// Replaces the transcript with a compacted one and logs it: a
/// `compaction` record, then the new history with fresh sequence numbers.
/// Returns false when no compaction is configured or it failed.
fn compactHistory(a: *Agent, scratch: Allocator, base: *const request.Request, overflow: bool) Io.Cancelable!bool {
    const c = a.deps.compaction orelse return false;
    a.setStatus(.compacting);
    const res = c.compact(c.ctx, a.io, scratch, base, a.messages(), overflow) catch |e| switch (e) {
        error.Canceled => return error.Canceled,
        else => {
            a.publish(.{ .warning = "compaction failed" });
            return false;
        },
    };
    const trigger = if (overflow) "window_overflow" else "auto_threshold";
    a.publish(.{ .recovery = .{ .action = "compacted", .detail = trigger } });
    // Cleanup that must not be torn: transcript and log stay consistent.
    const prev = a.io.swapCancelProtection(.blocked);
    defer _ = a.io.swapCancelProtection(prev);
    const seq = a.bus.lastSeq() + 1;
    const head = seq + 1;
    const seqs = scratch.alloc(u64, res.messages.len) catch return false;
    for (seqs, 0..) |*s, i| s.* = head + i;
    a.swapTranscript(res.messages, seqs, if (seqs.len > 0) seqs[seqs.len - 1] else seq) catch return false;
    if (a.deps.session) |s| {
        if (s.vtable.compaction) |f| f(s.ctx, a.io, a.ref, seq, .{ .head_seq = head, .trigger = trigger, .tokens_before = res.tokens_before, .tokens_after = res.tokens_after, .model = res.model }) catch |e| a.publish(.{ .warning = @errorName(e) });
        for (a.messages(), seqs) |*m, q| s.vtable.message(s.ctx, a.io, a.ref, q, m) catch |e| a.publish(.{ .warning = @errorName(e) });
        s.vtable.sync(s.ctx, a.io) catch {};
    }
    if (res.fallback) a.publish(.{ .warning = "compaction failed; old tool results were cleared instead" });
    a.setStatus(.thinking);
    return true;
}

/// Replaces the history with one user message (plan approval with a
/// cleared context), recorded like a compaction.
fn clearHistory(a: *Agent, scratch: Allocator, text: []const u8) void {
    const prev = a.io.swapCancelProtection(.blocked);
    defer _ = a.io.swapCancelProtection(prev);
    const blocks = scratch.alloc(proto.ContentBlock, 1) catch return;
    blocks[0] = .{ .text = .{ .text = text } };
    const msgs = scratch.alloc(proto.Message, 1) catch return;
    msgs[0] = .{ .role = .user, .content = blocks };
    const seq = a.bus.lastSeq() + 1;
    const head = seq + 1;
    const seqs = [_]u64{head};
    a.swapTranscript(msgs, &seqs, head) catch return;
    a.publish(.{ .recovery = .{ .action = "context_cleared", .detail = "plan_approved" } });
    if (a.deps.session) |s| {
        if (s.vtable.compaction) |f| f(s.ctx, a.io, a.ref, seq, .{ .head_seq = head, .trigger = "plan_approved", .tokens_before = 0, .tokens_after = text.len / 4, .model = "" }) catch |e| a.publish(.{ .warning = @errorName(e) });
        for (a.messages(), &seqs) |*m, q| s.vtable.message(s.ctx, a.io, a.ref, q, m) catch |e| a.publish(.{ .warning = @errorName(e) });
        s.vtable.sync(s.ctx, a.io) catch {};
    }
}

fn syncSession(a: *Agent) void {
    const s = a.deps.session orelse return;
    s.vtable.sync(s.ctx, a.io) catch |e| a.publish(.{ .warning = @errorName(e) });
}

fn recordUsage(a: *Agent, model: *const registry.ModelInfo, req: *const request.Request, resp: request.Response) void {
    var u = resp.usage;
    var estimated = false;
    const req_bytes = guarded.estimateInputTokens(req) * 4;
    if (u.totalInput() == 0 and u.output == 0) {
        // Some local servers report nothing: estimate.
        if (a.deps.estimator) |e| {
            u.input = e.estimateBytes(model.family, req_bytes);
            var out_bytes: u64 = 0;
            for (resp.message.content) |b| out_bytes += switch (b) {
                .text => |t| t.text.len,
                .tool_use => |t| t.input_json.len,
                else => 0,
            };
            u.output = e.estimateBytes(model.family, out_bytes);
            estimated = true;
        }
    } else if (a.deps.estimator) |e| e.calibrate(model.family, req_bytes, u.totalInput());
    const cost: pricing.Cost = if (a.deps.ledger) |l|
        l.record(a.ref, model, u, estimated) catch .{ .micros = 0 }
    else if (model.price) |p| pricing.costOf(p, u) else .{ .micros = 0 };
    const totals = blk: {
        a.mutex.lockUncancelable(a.io);
        defer a.mutex.unlock(a.io);
        a.used.usage.add(u);
        a.used.cost_micros += cost.micros;
        a.estimated = a.estimated or estimated;
        break :blk ev.UsageTotals{ .last = u, .total = a.used.usage, .cost_micros = a.used.cost_micros, .estimated = a.estimated };
    };
    a.last_cache_read = u.cache_read;
    a.publish(.{ .usage = totals });
}

/// Deep-copies `m` into the transcript, logs it and publishes it.
fn commit(a: *Agent, m: proto.Message) Allocator.Error!*const proto.Message {
    var c = try json.cloneMessage(a.arena.allocator(), m);
    if (c.meta.time_ms == null) c.meta.time_ms = Io.Timestamp.now(a.io, .real).toMilliseconds();
    const seq = a.bus.lastSeq() + 1;
    const index = blk: {
        a.mutex.lockUncancelable(a.io);
        defer a.mutex.unlock(a.io);
        try a.transcript.ensureUnusedCapacity(a.arena.allocator(), 1);
        try a.seqs.append(a.arena.allocator(), seq);
        a.transcript.appendAssumeCapacity(c);
        break :blk a.transcript.items.len - 1;
    };
    const stored = &a.transcript.items[index];
    if (a.deps.session) |s| s.vtable.message(s.ctx, a.io, a.ref, seq, stored) catch |e| a.publish(.{ .warning = @errorName(e) });
    a.publish(.{ .message_committed = .{ .index = @intCast(index), .role = c.role, .interrupted = c.meta.interrupted } });
    return stored;
}

/// At most `max` bytes of the first line of `text`, cut at a UTF-8 boundary.
fn labelPrefix(text: []const u8, max: usize) []const u8 {
    const line = std.mem.trim(u8, text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len], " \t\r");
    if (line.len <= max) return line;
    var cut = max;
    while (cut > 0 and line[cut] & 0xC0 == 0x80) cut -= 1;
    return line[0..cut];
}

fn commitText(a: *Agent, role: proto.Role, text: []const u8, synthetic: bool) Allocator.Error!void {
    const blocks = [_]proto.ContentBlock{.{ .text = .{ .text = text } }};
    _ = try commit(a, .{ .role = role, .content = &blocks, .meta = .{ .synthetic = synthetic } });
}

/// Commits what streamed before a cancel or error, plus a canceled result
/// for every complete tool call in it. Runs with cancelation blocked.
fn commitPartial(a: *Agent, asm_: *MessageAssembler) void {
    const prev = a.io.swapCancelProtection(.blocked);
    defer _ = a.io.swapCancelProtection(prev);
    var p = asm_.partial() catch return;
    if (p.content.len == 0) return;
    p.meta.interrupted = true;
    const m = commit(a, p) catch return;
    synthesizeResults(a, m, scheduler.canceled_text);
}

/// Answers every tool_use in `m` with an `is_error` result.
fn synthesizeResults(a: *Agent, m: *const proto.Message, text: []const u8) void {
    const n = m.toolUseCount();
    if (n == 0) return;
    var tmp: std.heap.ArenaAllocator = .init(a.gpa);
    defer tmp.deinit();
    const blocks = tmp.allocator().alloc(proto.ContentBlock, n) catch return;
    const parts = [_]proto.ResultPart{.{ .text = text }};
    var i: usize = 0;
    for (m.content) |b| if (b == .tool_use) {
        blocks[i] = .{ .tool_result = .{ .tool_use_id = b.tool_use.id, .parts = &parts, .is_error = true } };
        a.publish(.{ .tool_finished = .{ .id = b.tool_use.id, .name = b.tool_use.name, .is_error = true, .skipped = true } });
        i += 1;
    };
    _ = commit(a, .{ .role = .user, .content = blocks, .meta = .{ .synthetic = true } }) catch {};
}

/// Forwards provider events to the bus, copying their slices into the
/// transcript arena (provider slices only live during `emit`).
const StreamSink = struct {
    a: *Agent,
    asm_: MessageAssembler,
    streaming: bool = false,
    feed_failed: bool = false,

    fn eventSink(s: *StreamSink) pevents.EventSink {
        return .{ .ctx = s, .emit = emit };
    }

    fn emit(ctx: *anyopaque, e: pevents.StreamEvent) void {
        const s: *StreamSink = @ptrCast(@alignCast(ctx));
        s.asm_.feed(e) catch {
            s.feed_failed = true;
        };
        switch (e) {
            .ping, .rate_limit => return,
            .retrying => |r| {
                // Backoff: the wait is interrupted by a cancel.
                s.a.setStatus(.retrying);
                s.a.publish(.{ .retrying = .{ .attempt = r.attempt, .delay_ms = r.delay_ms, .status = r.status, .err = s.a.arena.allocator().dupe(u8, r.err) catch "" } });
                return;
            },
            else => {},
        }
        if (!s.streaming and (e == .text_delta or e == .thinking_delta or e == .tool_input_delta)) {
            s.streaming = true;
            s.a.setStatus(.streaming);
        }
        const c = copyEvent(s.a.arena.allocator(), e) catch return;
        s.a.publish(.{ .stream = c });
    }
};

fn copyEvent(ar: Allocator, e: pevents.StreamEvent) Allocator.Error!pevents.StreamEvent {
    return switch (e) {
        .message_start => |m| .{ .message_start = .{ .id = try ar.dupe(u8, m.id), .model = try ar.dupe(u8, m.model) } },
        .block_start => |b| .{ .block_start = .{
            .index = b.index,
            .kind = b.kind,
            .tool_id = if (b.tool_id) |x| try ar.dupe(u8, x) else null,
            .tool_name = if (b.tool_name) |x| try ar.dupe(u8, x) else null,
            .raw_json = if (b.raw_json) |x| try ar.dupe(u8, x) else null,
            .origin = b.origin,
            .opaque_kind = if (b.opaque_kind) |x| try ar.dupe(u8, x) else null,
        } },
        .text_delta => |d| .{ .text_delta = .{ .index = d.index, .text = try ar.dupe(u8, d.text) } },
        .thinking_delta => |d| .{ .thinking_delta = .{ .index = d.index, .text = try ar.dupe(u8, d.text) } },
        .signature => |d| .{ .signature = .{ .index = d.index, .value = try ar.dupe(u8, d.value) } },
        .tool_input_delta => |d| .{ .tool_input_delta = .{ .index = d.index, .partial_json = try ar.dupe(u8, d.partial_json) } },
        .citation => |d| .{ .citation = .{ .index = d.index, .json = try ar.dupe(u8, d.json) } },
        .warning => |w| .{ .warning = try ar.dupe(u8, w) },
        .provider_error => |p| .{ .provider_error = .{
            .status = p.status,
            .kind = try ar.dupe(u8, p.kind),
            .message = try ar.dupe(u8, p.message),
            .retry_after_ms = p.retry_after_ms,
            .request_id = if (p.request_id) |x| try ar.dupe(u8, x) else null,
        } },
        else => e,
    };
}

/// Runs one tool call (on a scheduler task) through the invoke pipeline,
/// with output allocated in `ar`.
fn invokeOne(a: *Agent, ar: Allocator, io: Io, c: *const scheduler.Call) proto.ToolOutput {
    var prog: Progress = .{ .a = a, .id = c.id };
    var obs: Observe = .{ .a = a };
    const p: invoke.Pipeline = .{
        .permission = a.deps.permission,
        .hooks = a.deps.hooks,
        .audit = a.deps.audit,
        .schemas = &a.schemas,
        .bounds = a.cfg.tool_output,
        .observer = .{ .ctx = &obs, .started = Observe.started, .decision = Observe.decision },
        .plan_mode = a.plan_mode.load(.acquire),
    };
    return invoke.invoke(&p, io, ar, .{
        .id = c.id,
        .spec = c.spec,
        .input_json = c.input_json,
        .agent = a.ref,
        .progress = .{ .ctx = &prog, .emit = Progress.emit },
    });
}

/// Publishes the pipeline's events; decisions are copied into the agent
/// arena under `alloc_mutex` (they outlive the call's arena).
const Observe = struct {
    a: *Agent,

    fn started(ctx: *anyopaque, id: []const u8) void {
        const o: *Observe = @ptrCast(@alignCast(ctx));
        o.a.publish(.{ .tool_started = id });
    }

    fn decision(ctx: *anyopaque, d: deps.ToolDecision) void {
        const o: *Observe = @ptrCast(@alignCast(ctx));
        const reason = blk: {
            o.a.alloc_mutex.lockUncancelable(o.a.io);
            defer o.a.alloc_mutex.unlock(o.a.io);
            break :blk o.a.arena.allocator().dupe(u8, d.reason) catch "";
        };
        var copy = d;
        copy.reason = reason;
        o.a.publish(.{ .tool_decision = copy });
    }
};

/// Tool output chunks. They outlive the call (queued subscribers hold
/// them), so they are copied into the agent arena under `alloc_mutex`;
/// the turn task does not allocate while tools run.
const Progress = struct {
    a: *Agent,
    id: []const u8,

    fn emit(ctx: *anyopaque, chunk: []const u8) void {
        const p: *Progress = @ptrCast(@alignCast(ctx));
        const copy = blk: {
            p.a.alloc_mutex.lockUncancelable(p.a.io);
            defer p.a.alloc_mutex.unlock(p.a.io);
            break :blk p.a.arena.allocator().dupe(u8, chunk) catch return;
        };
        p.a.publish(.{ .tool_progress = .{ .id = p.id, .chunk = copy } });
    }
};

fn errText(ar: Allocator, text: []const u8) proto.ToolOutput {
    return proto.ToolOutput.text(ar, text, true) catch .{ .parts = &.{}, .is_error = true };
}

/// Runs the tool calls of `m` and commits the results message (with any
/// steering input appended after the results).
fn runTools(a: *Agent, m: *const proto.Message) Io.Cancelable!void {
    const gpa = a.gpa;
    var scratch_state: std.heap.ArenaAllocator = .init(gpa);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();

    const Use = @FieldType(proto.ContentBlock, "tool_use");
    var uses: std.ArrayList(Use) = .empty;
    for (m.content) |b| if (b == .tool_use and !b.tool_use.server) uses.append(scratch, b.tool_use) catch {
        synthesizeResults(a, m, "The harness ran out of memory.");
        return;
    };
    const n = uses.items.len;
    if (n == 0) return;

    const arenas = scratch.alloc(std.heap.ArenaAllocator, n) catch return synthesizeResults(a, m, "The harness ran out of memory.");
    for (arenas) |*x| x.* = .init(gpa);
    defer for (arenas) |*x| x.deinit();
    const out = scratch.alloc(proto.ToolOutput, n) catch return synthesizeResults(a, m, "The harness ran out of memory.");
    const outcome = scratch.alloc(scheduler.Outcome, n) catch return synthesizeResults(a, m, "The harness ran out of memory.");
    @memset(outcome, .pending);
    var calls: std.ArrayList(scheduler.Call) = .empty;
    var call_index: std.ArrayList(usize) = .empty;
    for (uses.items, 0..) |u, i| {
        a.publish(.{ .tool_queued = .{ .id = u.id, .name = u.name, .input_json = u.input_json } });
        const ar = arenas[i].allocator();
        const spec = a.deps.tools.find(u.name) orelse {
            out[i] = errText(ar, std.fmt.allocPrint(ar, "Unknown tool: {s}", .{u.name}) catch "Unknown tool");
            outcome[i] = .done;
            continue;
        };
        const input = std.json.parseFromSliceLeaky(std.json.Value, ar, u.input_json, .{}) catch .null;
        calls.append(scratch, .{ .id = u.id, .spec = spec, .input = input, .input_json = u.input_json, .resources = a.deps.tools.resources(spec, input, ar) }) catch
            return synthesizeResults(a, m, "The harness ran out of memory.");
        call_index.append(scratch, i) catch return synthesizeResults(a, m, "The harness ran out of memory.");
    }

    a.setStatus(.running_tools);
    var canceled = false;
    if (calls.items.len > 0) {
        const sub_out = scratch.alloc(proto.ToolOutput, calls.items.len) catch return synthesizeResults(a, m, "The harness ran out of memory.");
        const sub_state = scratch.alloc(scheduler.Outcome, calls.items.len) catch return synthesizeResults(a, m, "The harness ran out of memory.");
        // Map call positions back to tool_use positions for the arenas.
        var mapped: MappedBatch = .{ .a = a, .arenas = arenas, .index = call_index.items };
        scheduler.run(a.io, scratch, a.cfg.policy, calls.items, mapped.invoke(), sub_out, sub_state) catch {
            canceled = true;
        };
        for (call_index.items, sub_out, sub_state) |i, o, st| {
            out[i] = o;
            outcome[i] = st;
        }
    }

    const prev = a.io.swapCancelProtection(.blocked);
    defer _ = a.io.swapCancelProtection(prev);

    var steer: iq.InputQueue = .{};
    defer steer.deinit(gpa);
    if (!canceled) {
        a.mutex.lockUncancelable(a.io);
        steer.takeAll(gpa, &a.steer) catch {};
        a.mutex.unlock(a.io);
    }
    const blocks = scratch.alloc(proto.ContentBlock, n + steer.len()) catch return synthesizeResults(a, m, "The harness ran out of memory.");
    for (uses.items, out, outcome, 0..) |u, o, st, i| {
        blocks[i] = .{ .tool_result = .{ .tool_use_id = u.id, .parts = o.parts, .is_error = o.is_error } };
        a.publish(.{ .tool_finished = .{ .id = u.id, .name = u.name, .is_error = o.is_error, .skipped = st == .skipped or st == .canceled } });
    }
    for (steer.items.items, n..) |s, i| blocks[i] = .{ .text = .{ .text = s.text } };
    _ = commit(a, .{ .role = .user, .content = blocks }) catch {};
    if (canceled) return error.Canceled;
}

/// The scheduled subset of a response's tool calls; call `i` uses the
/// arena of tool_use `index[i]`.
const MappedBatch = struct {
    a: *Agent,
    arenas: []std.heap.ArenaAllocator,
    index: []const usize,

    fn invoke(m: *MappedBatch) scheduler.Invoke {
        return .{ .ctx = m, .call = call };
    }

    fn call(ctx: *anyopaque, io: Io, i: usize, c: *const scheduler.Call) proto.ToolOutput {
        const m: *MappedBatch = @ptrCast(@alignCast(ctx));
        return invokeOne(m.a, m.arenas[m.index[i]].allocator(), io, c);
    }
};
