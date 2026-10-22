//! The `ask_user` tool (E10.F09.S02.T02): multiple-choice questions to
//! the user while the agent works.
//!
//! The tool publishes `approval_needed{kind=question}` and blocks on the
//! `Asker`: an `AskQueue` whose tickets the UI answers with a card
//! (option buttons plus "Other…"), or the `CliAsker`, which prints
//! numbered options. With no asker (`zg agent -p` without streamed
//! prompts) the tool is left out of the toolset, and a call made anyway
//! gets an error telling the model to assume and say so. A subagent's
//! question carries the subagent's name.

const std = @import("std");
const proto = @import("zg_ai_proto");
const AgentManager = @import("../loop/Manager.zig");
const ratelimit = @import("../provider/ratelimit.zig");
const registry = @import("../tools/registry.zig");
const runner = @import("../subagent/runner.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const json = proto.json;

pub const schema =
    \\{"type":"object","properties":{"questions":{"type":"array","minItems":1,"maxItems":4,"items":{"type":"object","properties":{"question":{"type":"string"},"header":{"type":"string","maxLength":24},"options":{"type":"array","minItems":2,"maxItems":4,"items":{"type":"object","properties":{"label":{"type":"string"},"description":{"type":"string"}},"required":["label"],"additionalProperties":false}},"multi_select":{"type":"boolean"}},"required":["question","options"],"additionalProperties":false}}},"required":["questions"],"additionalProperties":false}
;

pub const description = "Asks the user up to four multiple-choice questions and waits for the answers. Use it when a choice is the user's to make or the request is ambiguous; do not use it for things you can find out yourself. The user can always answer in their own words instead.";

pub const no_user = "No user is available to answer; make a reasonable assumption and state it.";
pub const timed_out = "The user did not answer in time; make a reasonable assumption and state it.";

pub const Option = struct {
    label: []const u8,
    description: ?[]const u8 = null,
};

pub const Question = struct {
    question: []const u8,
    header: ?[]const u8 = null,
    options: []const Option,
    multi_select: bool = false,
};

pub const Answer = struct {
    question: []const u8,
    /// Labels of the chosen options.
    selected: []const []const u8 = &.{},
    /// "Other…" text.
    other: ?[]const u8 = null,
};

pub const Request = struct {
    /// The tool call id.
    id: []const u8,
    agent: proto.AgentRef,
    /// Empty for the main agent, else the subagent's name.
    label: []const u8 = "",
    questions: []const Question,
};

pub const Reply = union(enum) {
    answered: []const Answer,
    /// Nobody can answer (input ended, or no UI).
    unavailable,
    timed_out,
};

/// Asks the user. Slices in the reply live in `arena`.
pub const Asker = struct {
    ctx: *anyopaque,
    ask: *const fn (ctx: *anyopaque, io: Io, arena: Allocator, req: Request) Io.Cancelable!Reply,
};

/// Names the agent asking (a subagent's definition name).
pub const Labeler = struct {
    ctx: *anyopaque,
    label: *const fn (ctx: *anyopaque, ref: proto.AgentRef) ?[]const u8,
};

/// Labels subagents by their definition name.
pub fn subagentLabeler(r: *runner.SubagentRunner) Labeler {
    return .{ .ctx = r, .label = struct {
        fn f(ctx: *anyopaque, ref: proto.AgentRef) ?[]const u8 {
            const sr: *runner.SubagentRunner = @ptrCast(@alignCast(ctx));
            return sr.nameOf(ref);
        }
    }.f };
}

/// Questions waiting for the UI. `ask` opens a ticket and waits; the UI
/// lists `pending` tickets and calls `answer` (or `dismiss`).
pub const AskQueue = struct {
    gpa: Allocator,
    io: Io,
    clock: ratelimit.Clock = .real,
    /// `ai.askUser.timeoutMs`; null waits until answered or cancelled.
    timeout_ms: ?u64 = null,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    tickets: std.ArrayList(*AskTicket) = .empty,
    closed: bool = false,

    pub fn init(gpa: Allocator, io: Io) AskQueue {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(q: *AskQueue) void {
        q.tickets.deinit(q.gpa);
    }

    pub fn asker(q: *AskQueue) Asker {
        return .{ .ctx = q, .ask = askFn };
    }

    /// The open tickets, oldest first (copies in `arena`).
    pub fn pending(q: *AskQueue, arena: Allocator) Allocator.Error![]const Request {
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        const out = try arena.alloc(Request, q.tickets.items.len);
        for (q.tickets.items, out) |t, *o| o.* = t.req;
        return out;
    }

    /// Answers ticket `id`; false when no such ticket is open. The
    /// answers are copied.
    pub fn answer(q: *AskQueue, id: []const u8, answers: []const Answer) Allocator.Error!bool {
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        const t = q.find(id) orelse return false;
        t.reply = .{ .answered = try dupeAnswers(t.arena, answers) };
        q.cond.broadcast(q.io);
        return true;
    }

    /// Closes ticket `id` unanswered (the user dismissed the card).
    pub fn dismiss(q: *AskQueue, id: []const u8) bool {
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        const t = q.find(id) orelse return false;
        t.reply = .unavailable;
        q.cond.broadcast(q.io);
        return true;
    }

    /// Nobody will answer any more: open and later tickets are refused.
    pub fn close(q: *AskQueue) void {
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        q.closed = true;
        q.cond.broadcast(q.io);
    }

    fn find(q: *AskQueue, id: []const u8) ?*AskTicket {
        for (q.tickets.items) |t| if (t.reply == null and std.mem.eql(u8, t.req.id, id)) return t;
        return null;
    }

    fn askFn(ctx: *anyopaque, io: Io, arena: Allocator, req: Request) Io.Cancelable!Reply {
        const q: *AskQueue = @ptrCast(@alignCast(ctx));
        var t: AskTicket = .{ .queue = q, .req = req, .arena = arena };
        {
            q.mutex.lockUncancelable(q.io);
            defer q.mutex.unlock(q.io);
            if (q.closed) return .unavailable;
            q.tickets.append(q.gpa, &t) catch return .unavailable;
        }
        return t.wait(io);
    }
};

/// One open question set; lives on the asking tool call's stack.
pub const AskTicket = struct {
    queue: *AskQueue,
    req: Request,
    /// The tool call's arena; answers are copied here.
    arena: Allocator,
    reply: ?Reply = null,
    expired: bool = false,

    /// Waits for the answer, the timeout or a cancel (the ticket is then
    /// withdrawn and `error.Canceled` returned).
    pub fn wait(t: *AskTicket, io: Io) Io.Cancelable!Reply {
        const q = t.queue;
        var timer = if (q.timeout_ms) |_| io.concurrent(expire, .{t}) catch null else null;
        defer if (timer) |*f| f.cancel(io);
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        defer for (q.tickets.items, 0..) |x, i| if (x == t) {
            _ = q.tickets.orderedRemove(i);
            break;
        };
        while (true) {
            if (t.reply) |r| return r;
            if (t.expired) return .timed_out;
            if (q.closed) return .unavailable;
            try q.cond.wait(io, &q.mutex);
        }
    }

    fn expire(t: *AskTicket) void {
        const q = t.queue;
        q.clock.sleep(q.io, q.timeout_ms.?) catch return;
        q.mutex.lockUncancelable(q.io);
        defer q.mutex.unlock(q.io);
        t.expired = true;
        q.cond.broadcast(q.io);
    }
};

pub const AskUserTool = struct {
    /// Null: no user can answer; the tool is not declared.
    asker: ?Asker,
    /// Publishes `approval_needed` on the asking agent, when set.
    mgr: ?*AgentManager = null,
    labeler: ?Labeler = null,
    spec_list: [1]proto.ToolSpec = undefined,

    pub fn specs(t: *AskUserTool) []const proto.ToolSpec {
        t.spec_list = .{.{
            .name = "ask_user",
            .description = description,
            .input_schema_json = schema,
            .read_only = true,
            .permission = .control,
            .handler = .{ .ctx = t, .call = call },
        }};
        return &t.spec_list;
    }

    pub fn source(t: *AskUserTool) registry.ToolSource {
        return .{ .name = "ask_user", .ctx = t, .list = list, .kind = .builtin };
    }

    fn list(ctx: *anyopaque, gpa: Allocator, out: *std.ArrayList(proto.ToolSpec)) anyerror!void {
        const t: *AskUserTool = @ptrCast(@alignCast(ctx));
        if (t.asker == null) return;
        try out.appendSlice(gpa, t.specs());
    }

    fn call(ctx: *anyopaque, c: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
        const t: *AskUserTool = @ptrCast(@alignCast(ctx));
        const a = c.arena;
        const asker = t.asker orelse return errOut(a, no_user);
        const obj = json.asObject(c.input) orelse return errOut(a, "ask_user needs {\"questions\": [...]}.");
        const questions = json.decodeValue([]const Question, a, obj.get("questions") orelse return errOut(a, "ask_user needs \"questions\".")) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return errOut(a, "Each question needs \"question\" and two to four \"options\" with a \"label\"."),
        };
        if (questions.len == 0 or questions.len > 4) return errOut(a, "Ask one to four questions.");
        for (questions) |q| if (q.options.len < 2 or q.options.len > 4) return errOut(a, "Each question needs two to four options.");

        const label = if (c.agent.agent == 0) "" else if (t.labeler) |l| l.label(l.ctx, c.agent) orelse "subagent" else "subagent";
        const req: Request = .{ .id = c.id, .agent = c.agent, .label = label, .questions = questions };
        t.announce(req, c.input_json);
        const reply = asker.ask(asker.ctx, c.io, a, req) catch return error.Canceled;
        return switch (reply) {
            .unavailable => errOut(a, no_user),
            .timed_out => errOut(a, timed_out),
            .answered => |ans| proto.ToolOutput.text(a, formatAnswers(a, ans) catch return error.OutOfMemory, false) catch error.OutOfMemory,
        };
    }

    fn announce(t: *AskUserTool, req: Request, input_json: []const u8) void {
        const m = t.mgr orelse return;
        const agent = m.get(req.agent) orelse return;
        agent.alloc_mutex.lockUncancelable(agent.io);
        defer agent.alloc_mutex.unlock(agent.io);
        const ar = agent.arena.allocator();
        agent.publish(.{ .approval_needed = .{
            .kind = .question,
            .id = ar.dupe(u8, req.id) catch return,
            .label = ar.dupe(u8, req.label) catch return,
            .json = ar.dupe(u8, input_json) catch return,
        } });
    }
};

/// The tool result: one line per question.
pub fn formatAnswers(a: Allocator, answers: []const Answer) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "The user answered:\n");
    for (answers) |ans| {
        try out.print(a, "- {s} → ", .{ans.question});
        for (ans.selected, 0..) |s, i| {
            if (i > 0) try out.appendSlice(a, ", ");
            try out.appendSlice(a, s);
        }
        if (ans.other) |o| {
            if (ans.selected.len > 0) try out.appendSlice(a, "; ");
            try out.print(a, "in their own words: {s}", .{o});
        }
        if (ans.selected.len == 0 and ans.other == null) try out.appendSlice(a, "(no answer)");
        try out.append(a, '\n');
    }
    return std.mem.trimEnd(u8, out.items, "\n");
}

/// The terminal asker: numbered options, the last one "Other".
pub const CliAsker = struct {
    in: *Io.Reader,
    out: *Io.Writer,

    pub fn asker(c: *CliAsker) Asker {
        return .{ .ctx = c, .ask = ask };
    }

    fn ask(ctx: *anyopaque, _: Io, arena: Allocator, req: Request) Io.Cancelable!Reply {
        const c: *CliAsker = @ptrCast(@alignCast(ctx));
        const answers = arena.alloc(Answer, req.questions.len) catch return .unavailable;
        for (req.questions, answers) |q, *ans| {
            render(c.out, req.label, q) catch {};
            ans.* = c.read(arena, q) orelse return .unavailable;
        }
        return .{ .answered = answers };
    }

    pub fn render(w: *Io.Writer, label: []const u8, q: Question) Io.Writer.Error!void {
        try w.writeByte('\n');
        if (label.len > 0) try w.print("({s}) ", .{label});
        if (q.header) |h| try w.print("[{s}] ", .{h});
        try w.print("{s}\n", .{q.question});
        for (q.options, 1..) |o, i| {
            try w.print("  {d}. {s}", .{ i, o.label });
            if (o.description) |d| try w.print(" - {s}", .{d});
            try w.writeByte('\n');
        }
        try w.print("  {d}. Other (type your answer)\n", .{q.options.len + 1});
    }

    fn read(c: *CliAsker, arena: Allocator, q: Question) ?Answer {
        const other_n = q.options.len + 1;
        while (true) {
            c.out.writeAll(if (q.multi_select) "Choose one or more (e.g. 1,3): " else "Choose: ") catch {};
            c.out.flush() catch {};
            const line = c.in.takeDelimiter('\n') catch return null;
            const text = std.mem.trim(u8, line orelse return null, " \t\r");
            var selected: std.ArrayList([]const u8) = .empty;
            var other = false;
            var ok = text.len > 0;
            var parts = std.mem.tokenizeAny(u8, text, ", ");
            while (parts.next()) |p| {
                const n = std.fmt.parseInt(usize, p, 10) catch {
                    ok = false;
                    break;
                };
                if (n == other_n) {
                    other = true;
                } else if (n >= 1 and n <= q.options.len) {
                    selected.append(arena, q.options[n - 1].label) catch return null;
                } else ok = false;
            }
            if (!ok or (!q.multi_select and selected.items.len + @intFromBool(other) != 1)) continue;
            var ans: Answer = .{ .question = q.question, .selected = selected.items };
            if (other) {
                c.out.writeAll("Your answer: ") catch {};
                c.out.flush() catch {};
                const o = c.in.takeDelimiter('\n') catch return null;
                ans.other = arena.dupe(u8, std.mem.trim(u8, o orelse return null, " \t\r")) catch return null;
            }
            return ans;
        }
    }
};

fn dupeAnswers(a: Allocator, answers: []const Answer) Allocator.Error![]const Answer {
    const out = try a.alloc(Answer, answers.len);
    for (answers, out) |x, *o| {
        const sel = try a.alloc([]const u8, x.selected.len);
        for (x.selected, sel) |s, *d| d.* = try a.dupe(u8, s);
        o.* = .{ .question = try a.dupe(u8, x.question), .selected = sel, .other = if (x.other) |t| try a.dupe(u8, t) else null };
    }
    return out;
}

fn errOut(a: Allocator, s: []const u8) proto.ToolError!proto.ToolOutput {
    return proto.ToolOutput.text(a, s, true) catch error.OutOfMemory;
}
