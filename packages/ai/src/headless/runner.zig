//! The engine behind `zg agent` (E10.F10.S01): creates or resumes the
//! agent, turns its events into text, json or `zg.stream/1` output,
//! answers signals, checks `--json-schema` answers and works out the exit
//! code. `print.zig` and `repl.zig` drive it.

const std = @import("std");
const proto = @import("zg_ai_proto");
const Agent = @import("../loop/Agent.zig");
const AgentManager = @import("../loop/Manager.zig");
const ev = @import("../loop/events.zig");
const busm = @import("../loop/bus.zig");
const writer_mod = @import("../session/writer.zig");
const resume_mod = @import("../session/resume.zig");
const index_mod = @import("../session/index.zig");
const validate = @import("../schema/validate.zig");
const args_mod = @import("args.zig");
const exit_codes = @import("exit_codes.zig");
const permission = @import("permission.zig");
const signals = @import("signals.zig");
const sj = @import("stream_json.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const ExitCode = exit_codes.ExitCode;
const HeadlessOptions = args_mod.HeadlessOptions;

/// Problems found before the first turn; they exit with `usage`.
pub const SetupError = error{ UnknownModel, SessionNotFound, NoSessionStore, SchemaNotFound, InvalidSchema, NoPrompt };

pub const Runner = struct {
    io: Io,
    gpa: Allocator,
    mgr: *AgentManager,
    opts: HeadlessOptions,
    out: *Io.Writer,
    out_mutex: Io.Mutex = .init,
    err_mutex: Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    broker: ?permission.Broker = null,
    perm: permission.HeadlessPermission,
    agent: *Agent = undefined,
    model_id: []const u8 = "",
    writer: ?*writer_mod.SessionWriter = null,
    resumed: ?resume_mod.Resumed = null,
    session_text: [26]u8 = undefined,
    sub: ?busm.SubscriptionId = null,
    start_ms: i64 = 0,
    repl: bool = false,
    /// The setup problem, for the usage message.
    diag: []const u8 = "",

    // Guarded by `mutex`.
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    seen_seq: u64 = 0,
    finish: ?ev.FinishReason = null,
    budget_kind: @FieldType(ev.TurnFinished, "budget_kind") = null,
    turns_finished: u32 = 0,
    /// Text of the latest assistant message.
    last_text: std.ArrayList(u8) = .empty,
    /// The latest turn's error.
    error_text: ?[]const u8 = null,
    signal: ?signals.Kind = null,
    reader_done: bool = false,
    stop_input: bool = false,
    /// A turn is running (signals outside a turn end the process at once).
    in_turn: std.atomic.Value(bool) = .init(false),

    /// Text mode: the last byte written to `out`.
    last_byte: u8 = '\n',
    watcher: ?signals.Watcher = null,
    watch_future: ?Io.Future(void) = null,
    schema: ?validate.Compiled = null,
    structured: ?[]const u8 = null,
    invalid_output: bool = false,

    /// Sets up the run. `r` must not move afterwards. On a `SetupError`,
    /// `r.diag` says why and `deinit` must still be called.
    pub fn init(r: *Runner, io: Io, gpa: Allocator, mgr: *AgentManager, opts: HeadlessOptions, out: *Io.Writer) !void {
        r.* = .{ .io = io, .gpa = gpa, .mgr = mgr, .opts = opts, .out = out, .arena = .init(gpa), .perm = .{ .gpa = gpa, .opts = .{}, .allowed = &.{}, .disallowed = &.{}, .arena = .init(gpa) } };
        const env = opts.env;
        r.start_ms = env.clock.now(io);
        if (opts.permission_prompts == .stream) {
            r.broker = .init(gpa, io, r, emitFromBroker);
            r.broker.?.clock = env.permission_clock orelse env.clock;
            r.broker.?.timeout_ms = env.permission_timeout_ms;
        }
        r.perm.deinit();
        r.perm = .{ .gpa = gpa, .opts = .{}, .allowed = &.{}, .disallowed = &.{}, .arena = .init(gpa) };
        r.perm = try .init(gpa, .{
            .allowed = opts.allowed_tools,
            .disallowed = opts.disallowed_tools,
            .mode = opts.permission_mode,
            .broker = if (r.broker) |*b| b else null,
            .base = env.base_permission,
        });
        mgr.deps.permission = r.perm.permission();
        // --bare: no memory files or other assembled context, no hooks.
        if (opts.bare) {
            mgr.deps.context = .basic;
            mgr.deps.hooks = null;
        }
        r.agent = undefined;
        try r.setup();
    }

    fn setup(r: *Runner) !void {
        const env = r.opts.env;
        const a = r.arena.allocator();
        const name = r.opts.model orelse env.default_model;
        const info = r.mgr.deps.registry.resolve(name) orelse return r.fail(error.UnknownModel, "unknown model {s}", .{name});
        r.model_id = try a.dupe(u8, info.id);

        var system: std.ArrayList(u8) = .empty;
        if (r.opts.append_system_prompt) |t| try system.appendSlice(a, t);
        if (r.opts.json_schema) |s| {
            const t = std.mem.trim(u8, s, " \t\r\n");
            const text = if (t[0] == '{' or t[0] == '[') t else Io.Dir.cwd().readFileAlloc(r.io, s, a, .limited(1 << 20)) catch
                return r.fail(error.SchemaNotFound, "cannot read --json-schema file {s}", .{s});
            r.schema = validate.Compiled.init(env.validator orelse validate.permissive(), a, text) catch
                return r.fail(error.InvalidSchema, "--json-schema is not a valid JSON Schema", .{});
            if (system.items.len > 0) try system.appendSlice(a, "\n\n");
            try system.print(a, "Your final answer must be a single JSON value that validates against this JSON Schema, with no other text:\n{s}", .{text});
        }
        var cfg: Agent.Config = .{
            .model = r.model_id,
            .system_append = if (system.items.len > 0) system.items else null,
            .cwd = env.cwd,
            .budgets = .{ .max_turns = r.opts.max_turns, .max_wall_ms = r.opts.max_time_ms, .max_cost_micros = r.opts.max_budget_micros },
            // Cut tool output is saved next to spilled stdin.
            .tool_output = .{ .spill_dir = try std.fmt.allocPrint(a, "{s}{c}tool-output", .{ env.spill_dir, std.fs.path.sep }) },
        };

        if (r.opts.resume_session != null or r.opts.continue_session) {
            const store = env.store orelse return r.fail(error.NoSessionStore, "sessions are not saved here, so there is nothing to resume", .{});
            const id = try r.findSession();
            r.resumed = try resume_mod.resumeAgent(r.mgr, r.io, id, .{
                .fork = r.opts.fork_session,
                .model_override = if (r.opts.model != null) r.model_id else null,
            }, .{ .store = store, .config = cfg });
            r.agent = r.resumed.?.agent;
        } else if (env.store != null and !r.opts.no_session_persistence) {
            const w = try env.store.?.create(r.io, .{ .id = env.session, .cwd = env.cwd, .model = r.model_id, .origin = .cli });
            r.writer = w;
            var d = r.mgr.deps;
            d.session = w.sessionLog();
            cfg.session = w.id;
            r.agent = try r.mgr.createWith(cfg, d);
            _ = try r.agent.subscribe(w.subscriber());
        } else {
            cfg.session = env.session;
            r.agent = try r.mgr.create(cfg);
        }
        r.session_text = proto.agent_ref.format(r.agent.ref.session);
        r.agent.setPlanMode(r.opts.permission_mode == .plan);

        r.seen_seq = r.agent.bus.lastSeq();
        // Inline: output keeps event order with permission prompts written
        // from tool tasks, and a slow reader holds the agent back.
        r.sub = try r.agent.subscribe(.{ .ctx = r, .on_events = onEvents, .mode = .inline_ });
        if (env.signals) |s| {
            r.watcher = .{ .signals = s, .ctx = r, .on_signal = onSignal };
            r.watch_future = r.io.concurrent(signals.Watcher.run, .{ &r.watcher.?, r.io }) catch null;
        }
        if (r.opts.output_format == .stream_json) {
            var names: std.ArrayList([]const u8) = .empty;
            for (r.mgr.deps.tools.list()) |t| try names.append(a, t.name);
            r.emit(.{ .system = .{
                .subtype = .init,
                .session_id = &r.session_text,
                .model = r.model_id,
                .cwd = env.cwd,
                .tools = names.items,
                .mcp_servers = env.mcp_servers,
                .permission_mode = modeName(r.opts.permission_mode),
            } });
        }
    }

    fn fail(r: *Runner, e: SetupError, comptime fmt: []const u8, a: anytype) SetupError {
        r.diag = std.fmt.allocPrint(r.arena.allocator(), fmt, a) catch "invalid arguments";
        return e;
    }

    fn findSession(r: *Runner) !proto.SessionId {
        const env = r.opts.env;
        if (r.opts.resume_session) |s| if (proto.agent_ref.parse(s)) |id| return id else |_| {};
        const ix = env.index orelse return r.fail(error.SessionNotFound, "no session index to look up {s}", .{r.opts.resume_session orelse "the latest session"});
        var list: std.ArrayList(*const index_mod.SessionMeta) = .empty;
        defer list.deinit(r.gpa);
        try ix.list(r.gpa, .{}, &list);
        if (r.opts.continue_session) {
            if (list.items.len == 0) return r.fail(error.SessionNotFound, "no saved session to continue", .{});
            return list.items[0].id;
        }
        const want = r.opts.resume_session.?;
        for (list.items) |m| if (std.mem.eql(u8, m.label(), want)) return m.id;
        return r.fail(error.SessionNotFound, "no session named {s}", .{want});
    }

    /// Stops the watcher, closes the session and frees everything.
    pub fn deinit(r: *Runner) void {
        if (r.watcher) |*w| w.stop.store(true, .release);
        if (r.watch_future) |*f| f.cancel(r.io);
        const started = r.sub != null;
        if (r.sub) |id| r.agent.unsubscribe(id);
        if (started) {
            const snap = r.agent.snapshot();
            const sid = r.agent.ref.session;
            const persisted = r.resumed != null or r.writer != null;
            const session = if (r.resumed) |res| res.session else sid;
            r.mgr.dispose(r.agent);
            if (r.resumed) |*res| res.deinit();
            if (r.writer) |w| w.close();
            if (persisted) if (r.opts.env.index) |ix| r.updateIndex(ix, session, snap);
        } else {
            if (r.resumed) |*res| {
                r.mgr.dispose(res.agent);
                res.deinit();
            }
            if (r.writer) |w| w.close();
        }
        r.perm.deinit();
        if (r.broker) |*b| b.deinit();
        r.last_text.deinit(r.gpa);
        r.arena.deinit();
    }

    fn updateIndex(r: *Runner, ix: *index_mod.SessionIndex, id: proto.SessionId, snap: Agent.Snapshot) void {
        const now = r.opts.env.clock.now(r.io);
        var m: index_mod.SessionMeta = ix.get(id) orelse .{ .id = id, .created_ms = @intCast(proto.agent_ref.timestampMs(id)), .updated_ms = now, .origin = .cli };
        m.updated_ms = @max(now, m.created_ms);
        m.model = r.model_id;
        m.messages = @intCast(snap.messages);
        m.cost_micros += snap.cost_micros;
        ix.upsert(m) catch return;
        ix.save() catch |e| r.note("could not save the session index: {s}", .{@errorName(e)});
    }

    // Output.

    fn emit(r: *Runner, line: sj.OutLine) void {
        r.out_mutex.lockUncancelable(r.io);
        defer r.out_mutex.unlock(r.io);
        sj.writeLine(r.out, line) catch {};
    }

    fn emitFromBroker(ctx: *anyopaque, line: sj.OutLine) void {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        r.emit(line);
    }

    fn writeText(r: *Runner, text: []const u8) void {
        if (text.len == 0) return;
        r.out_mutex.lockUncancelable(r.io);
        defer r.out_mutex.unlock(r.io);
        r.out.writeAll(text) catch return;
        r.out.flush() catch {};
        r.last_byte = text[text.len - 1];
    }

    /// Writes the REPL prompt.
    pub fn writePrompt(r: *Runner, p: []const u8) void {
        r.writeText(p);
    }

    /// Ends the current output line.
    pub fn endLine(r: *Runner) void {
        r.endText();
    }

    /// Ends the text of a message with a newline.
    fn endText(r: *Runner) void {
        if (r.last_byte != '\n') r.writeText("\n");
    }

    /// A line on stderr.
    pub fn note(r: *Runner, comptime fmt: []const u8, a: anytype) void {
        const w = r.opts.env.err orelse return;
        r.err_mutex.lockUncancelable(r.io);
        defer r.err_mutex.unlock(r.io);
        w.print("zg agent: " ++ fmt ++ "\n", a) catch return;
        w.flush() catch {};
    }

    // Events.

    fn onEvents(ctx: *anyopaque, batch: []const ev.Envelope) void {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        for (batch) |e| r.handle(e.ev);
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        r.seen_seq = batch[batch.len - 1].seq;
        r.cond.broadcast(r.io);
    }

    fn handle(r: *Runner, e: ev.AgentEvent) void {
        const fmt = r.opts.output_format;
        const sid: []const u8 = &r.session_text;
        switch (e) {
            .stream => |se| {
                if (fmt == .text and se == .text_delta) r.writeText(se.text_delta.text);
                if (fmt == .stream_json and r.opts.include_partial) r.emit(.{ .stream_event = .{ .event = se, .session_id = sid } });
            },
            .message_committed => |ref| {
                var m = r.agent.messageAt(ref.index) orelse return;
                m.meta = .{};
                if (m.role == .assistant) {
                    r.setLastText(m);
                    switch (fmt) {
                        .text => r.endText(),
                        .stream_json => r.emit(.{ .assistant = .{ .message = m, .session_id = sid } }),
                        .json => {},
                    }
                } else if (fmt == .stream_json and hasToolResult(m)) {
                    r.emit(.{ .user = .{ .message = m, .session_id = sid } });
                }
            },
            .retrying => |x| {
                if (fmt == .stream_json) r.emit(.{ .system = .{
                    .subtype = .api_retry,
                    .session_id = sid,
                    .model = r.model_id,
                    .cwd = r.opts.env.cwd,
                    .permission_mode = modeName(r.opts.permission_mode),
                    .attempt = x.attempt,
                    .retry_delay_ms = x.delay_ms,
                } }) else if (r.opts.verbose) r.note("retrying in {d} ms ({s})", .{ x.delay_ms, x.err });
            },
            .tool_queued => |t| if (r.opts.verbose and fmt != .stream_json) r.note("tool {s} {s}", .{ t.name, t.input_json }),
            .tool_finished => |t| if (r.opts.verbose and fmt != .stream_json) r.note("tool {s} {s}", .{ t.name, if (t.skipped) "skipped" else if (t.is_error) "failed" else "done" }),
            .warning => |w| if (r.opts.verbose) r.note("warning: {s}", .{w}),
            .error_ => |x| {
                r.mutex.lockUncancelable(r.io);
                defer r.mutex.unlock(r.io);
                r.error_text = r.arena.allocator().dupe(u8, x.message) catch "error";
            },
            .turn_finished => |t| {
                r.mutex.lockUncancelable(r.io);
                defer r.mutex.unlock(r.io);
                r.finish = t.reason;
                r.budget_kind = t.budget_kind;
                r.turns_finished += 1;
            },
            else => {},
        }
    }

    fn setLastText(r: *Runner, m: proto.Message) void {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        r.last_text.clearRetainingCapacity();
        for (m.content) |b| if (b == .text) r.last_text.appendSlice(r.gpa, b.text.text) catch return;
    }

    fn onSignal(ctx: *anyopaque, k: signals.Kind) void {
        const r: *Runner = @ptrCast(@alignCast(ctx));
        const ends_run = k == .terminate or !r.repl;
        {
            r.mutex.lockUncancelable(r.io);
            defer r.mutex.unlock(r.io);
            if (ends_run) {
                if (r.signal == null) r.signal = k;
                r.stop_input = true;
            }
            r.cond.broadcast(r.io);
        }
        if (ends_run) if (r.broker) |*b| b.close();
        // Blocked on input with no turn to cancel: nothing to flush.
        if (ends_run and !r.in_turn.load(.acquire) and !r.opts.streamInput()) {
            r.note("{s}", .{if (k == .interrupt) "interrupted" else "terminated"});
            std.process.exit(exit_codes.of(.{ .finish = null, .signal = k }).code());
        }
        r.agent.cancel(.turn);
    }

    /// Waits until this subscriber has seen every event published so far.
    fn sync(r: *Runner) void {
        const target = r.agent.bus.lastSeq();
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        while (r.seen_seq < target) r.cond.waitUncancelable(r.io, &r.mutex);
    }

    /// The signal that ends the run, if any.
    pub fn signalled(r: *Runner) ?signals.Kind {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        return r.signal;
    }

    // Turns.

    /// Runs one prompt to the end of its turn.
    pub fn runTurn(r: *Runner, text: []const u8) !void {
        {
            r.mutex.lockUncancelable(r.io);
            defer r.mutex.unlock(r.io);
            r.error_text = null;
        }
        r.in_turn.store(true, .release);
        defer r.in_turn.store(false, .release);
        _ = try r.agent.submit(.{ .text = text, .source = .cli });
        r.agent.waitIdle();
        r.sync();
    }

    /// Checks the answer against `--json-schema`, with one repair turn.
    pub fn checkStructured(r: *Runner) !void {
        const schema = r.schema orelse return;
        var repaired = false;
        while (true) {
            if (r.finish != .end_turn) return;
            var scratch: std.heap.ArenaAllocator = .init(r.gpa);
            defer scratch.deinit();
            const sa = scratch.allocator();
            const answer = extractJson(try sa.dupe(u8, r.last_text.items));
            const res = try schema.check(sa, answer);
            if (res.ok) {
                r.structured = try r.arena.allocator().dupe(u8, try proto.json.stringifyValue(sa, res.value));
                return;
            }
            var why: std.ArrayList(u8) = .empty;
            for (res.errors.slice(), 0..) |e, i| try why.print(sa, "{s}{s}: {s}", .{ if (i > 0) "; " else "", if (e.pointer.len == 0) "/" else e.pointer, e.message });
            if (why.items.len == 0) try why.appendSlice(sa, "not valid JSON");
            if (repaired) {
                r.invalid_output = true;
                r.error_text = try std.fmt.allocPrint(r.arena.allocator(), "the final answer does not match --json-schema: {s}", .{why.items});
                return;
            }
            repaired = true;
            try r.runTurn(try std.fmt.allocPrint(sa, "Your last answer does not match the required JSON Schema ({s}). Reply again with only the JSON value and nothing else.", .{why.items}));
        }
    }

    /// The prompt of a print run: `-p`, piped stdin, or both.
    pub fn promptFrom(r: *Runner, in: *Io.Reader) ![]const u8 {
        const a = r.arena.allocator();
        const env = r.opts.env;
        var attachment: ?[]const u8 = null;
        if (env.stdin_piped) {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(r.gpa);
            const over = blk: {
                in.appendRemaining(r.gpa, &buf, .limited(env.stdin_cap + 1)) catch |e| switch (e) {
                    error.StreamTooLong => break :blk true,
                    else => return e,
                };
                break :blk buf.items.len > env.stdin_cap;
            };
            if (over) {
                const path = try r.spill(buf.items, in);
                attachment = try std.fmt.allocPrint(a, "<stdin path=\"{s}\" bytes=\"{d}\">\nThe piped input was larger than {d} bytes, so it was saved to this file. Read it from there.\n</stdin>", .{ path.name, path.bytes, env.stdin_cap });
            } else if (buf.items.len > 0) {
                attachment = try std.fmt.allocPrint(a, "<stdin>\n{s}{s}</stdin>", .{ buf.items, if (buf.items[buf.items.len - 1] == '\n') "" else "\n" });
            }
        }
        if (r.opts.prompt) |p| {
            if (attachment) |att| return std.fmt.allocPrint(a, "{s}\n\n{s}", .{ p, att });
            return p;
        }
        return attachment orelse r.fail(error.NoPrompt, "no prompt: pass -p <prompt> or pipe the input in", .{});
    }

    fn spill(r: *Runner, head: []const u8, in: *Io.Reader) !struct { name: []const u8, bytes: u64 } {
        const env = r.opts.env;
        const name = try std.fmt.allocPrint(r.arena.allocator(), "{s}{c}zg-stdin-{s}.txt", .{ env.spill_dir, std.fs.path.sep, &r.session_text });
        var f = try Io.Dir.cwd().createFile(r.io, name, .{});
        defer f.close(r.io);
        var wbuf: [64 * 1024]u8 = undefined;
        var fw = f.writer(r.io, &wbuf);
        try fw.interface.writeAll(head);
        const rest = try in.streamRemaining(&fw.interface);
        try fw.interface.flush();
        return .{ .name = name, .bytes = head.len + rest };
    }

    /// Reads `zg.stream/1` input until it ends (or a signal), then waits
    /// for the queued turns.
    pub fn streamInput(r: *Runner, in: *Io.Reader) !void {
        var fut = r.io.concurrent(readInput, .{ r, in }) catch null;
        if (fut == null) readInput(r, in);
        {
            r.mutex.lockUncancelable(r.io);
            defer r.mutex.unlock(r.io);
            while (!r.reader_done and !r.stop_input) r.cond.waitUncancelable(r.io, &r.mutex);
        }
        if (fut) |*f| {
            if (r.stop_input) f.cancel(r.io) else f.await(r.io);
        }
        r.agent.waitIdle();
        r.sync();
    }

    fn readInput(r: *Runner, in: *Io.Reader) void {
        defer {
            if (r.broker) |*b| b.close();
            r.mutex.lockUncancelable(r.io);
            r.reader_done = true;
            r.cond.broadcast(r.io);
            r.mutex.unlock(r.io);
        }
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        defer arena.deinit();
        while (true) {
            _ = arena.reset(.retain_capacity);
            const a = arena.allocator();
            const line = sj.readLine(a, in) catch |e| switch (e) {
                error.InvalidLine => {
                    r.note("skipped an input line that is not a valid zg.stream/1 message", .{});
                    continue;
                },
                else => {
                    r.note("stopped reading input: {s}", .{@errorName(e)});
                    return;
                },
            } orelse return;
            switch (line) {
                .user => |u| {
                    const text = sj.promptText(a, u.message) catch return;
                    _ = r.agent.submit(.{ .text = text, .source = .cli }) catch |e| r.note("input dropped: {s}", .{@errorName(e)});
                },
                .interrupt => r.agent.cancel(.turn),
                .permission_response => |p| if (r.broker) |*b| {
                    b.answer(p.request_id, .{ .allow = p.behavior == .allow, .message = p.message, .updated_input = p.updated_input }) catch {};
                } else r.note("permission_response ignored: run with --permission-prompts stream", .{}),
                .unknown => |t| r.note("skipped an input line of unknown type {s}", .{t}),
            }
        }
    }

    // The end.

    /// The outcome of the run so far.
    pub fn outcome(r: *Runner) exit_codes.Outcome {
        r.mutex.lockUncancelable(r.io);
        defer r.mutex.unlock(r.io);
        const finish = if (r.turns_finished == 0 and r.opts.streamInput()) .end_turn else r.finish;
        return .{ .finish = finish, .denials = r.perm.denialCount(r.io), .signal = r.signal, .invalid_output = r.invalid_output };
    }

    /// Writes the result (json, stream-json) or the error (text) and
    /// returns the exit code.
    pub fn finishRun(r: *Runner) ExitCode {
        const o = r.outcome();
        const code = exit_codes.of(o);
        const snap = r.agent.snapshot();
        const subtype: sj.ResultSubtype = if (o.signal != null or o.finish == .canceled) .error_interrupted else switch (code) {
            .ok => .success,
            .budget => if (turnBudget(o, r.budget_kind)) .error_max_turns else .error_budget,
            .permission_required => .error_permission,
            else => .error_during_execution,
        };
        r.mutex.lockUncancelable(r.io);
        const text: ?[]const u8 = if (r.last_text.items.len > 0) r.last_text.items else null;
        const err_text = r.error_text orelse if (code == .budget) budgetText(o, r.budget_kind) else null;
        r.mutex.unlock(r.io);
        r.perm.mutex.lockUncancelable(r.io);
        const denials = r.perm.denials.items;
        r.perm.mutex.unlock(r.io);
        switch (r.opts.output_format) {
            .json, .stream_json => r.emit(.{ .result = .{
                .subtype = subtype,
                .result = if (code == .ok) text else err_text orelse text,
                .structured_output = r.structured,
                .session_id = &r.session_text,
                .num_turns = snap.turns,
                .duration_ms = @intCast(@max(0, r.opts.env.clock.now(r.io) - r.start_ms)),
                .usage = snap.usage,
                .total_cost_usd = @as(f64, @floatFromInt(snap.cost_micros)) / 1_000_000,
                .is_error = code != .ok,
                .permission_denials = denials,
            } }),
            .text => {
                r.endText();
                if (r.structured) |s| {
                    if (!std.mem.eql(u8, std.mem.trim(u8, r.last_text.items, " \n"), s)) r.writeText(s);
                    r.endText();
                }
                switch (code) {
                    .ok => {},
                    .budget => r.note("{s}", .{err_text.?}),
                    .permission_required => for (denials) |d| r.note("{s}", .{d.reason}),
                    .interrupted => r.note("interrupted", .{}),
                    .terminated => r.note("terminated", .{}),
                    else => r.note("{s}", .{err_text orelse "the run failed"}),
                }
            },
        }
        return code;
    }
};

fn turnBudget(o: exit_codes.Outcome, kind: anytype) bool {
    return o.finish == .max_turns or (kind != null and kind.? == .turns);
}

fn budgetText(o: exit_codes.Outcome, kind: anytype) []const u8 {
    if (turnBudget(o, kind)) return "stopped: --max-turns reached";
    const k = kind orelse return "stopped: a budget ran out";
    return switch (k) {
        .cost => "stopped: --max-budget-usd reached",
        .wall_time => "stopped: --max-time reached",
        else => "stopped: a budget ran out",
    };
}

pub fn modeName(m: args_mod.PermissionMode) []const u8 {
    return switch (m) {
        .default => "default",
        .accept_edits => "acceptEdits",
        .plan => "plan",
        .dont_ask => "dontAsk",
        .bypass_permissions => "bypassPermissions",
    };
}

fn hasToolResult(m: proto.Message) bool {
    for (m.content) |b| if (b == .tool_result) return true;
    return false;
}

/// The JSON in an answer: trimmed, without a Markdown code fence.
pub fn extractJson(text: []const u8) []const u8 {
    var t = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, t, "```")) {
        const nl = std.mem.indexOfScalar(u8, t, '\n') orelse return t;
        t = t[nl + 1 ..];
        if (std.mem.lastIndexOf(u8, t, "```")) |end| t = t[0..end];
        t = std.mem.trim(u8, t, " \t\r\n");
    }
    return t;
}

/// Prints a setup problem and the usage hint; returns `usage`.
pub fn usageExit(opts: HeadlessOptions, msg: []const u8) ExitCode {
    if (opts.env.err) |w| {
        w.print("zg agent: {s}\nRun 'zg agent --help' for usage.\n", .{msg}) catch {};
        w.flush() catch {};
    }
    return .usage;
}
