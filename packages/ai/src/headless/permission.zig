//! Tool permissions for headless runs (E10.F10.S01.T01/T02): the
//! `--allowed-tools`/`--disallowed-tools` rules and `--permission-mode`,
//! and what happens to a call that needs an approval. With
//! `--permission-prompts none` it is denied and counted (exit code 4);
//! with `stream` a `permission_request` line goes out and the call waits
//! for the matching `permission_response`, or denies after the timeout.
//!
//! zg_ai cannot import zg_security (same layer), so this evaluates the
//! rule subset the flags use: `Tool` and `Tool(pattern)`, where the
//! pattern globs (`*`) the call's main argument (`command`, `path`,
//! `file_path`, `url` or `pattern`) and a trailing `:*` matches a prefix.
//! The app may put the E16 engine in front through `base`.

const std = @import("std");
const proto = @import("zg_ai_proto");
const deps = @import("../loop/deps.zig");
const readonly = @import("../plan/readonly.zig");
const ratelimit = @import("../provider/ratelimit.zig");
const args_mod = @import("args.zig");
const sj = @import("stream_json.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Rule = struct {
    tool: []const u8,
    pattern: ?[]const u8 = null,

    pub fn parse(text: []const u8) Rule {
        const open = std.mem.indexOfScalar(u8, text, '(') orelse return .{ .tool = text };
        if (text[text.len - 1] != ')') return .{ .tool = text };
        return .{ .tool = text[0..open], .pattern = text[open + 1 .. text.len - 1] };
    }

    /// Whether the rule covers a call of `tool` with `input_json`.
    pub fn matches(r: Rule, arena: Allocator, tool: []const u8, input_json: []const u8) bool {
        if (!std.mem.eql(u8, r.tool, tool) and !std.mem.eql(u8, r.tool, "*")) return false;
        const p = r.pattern orelse return true;
        if (p.len == 0 or std.mem.eql(u8, p, "*")) return true;
        const arg = mainArgument(arena, input_json) orelse return false;
        if (std.mem.endsWith(u8, p, ":*")) return std.mem.startsWith(u8, arg, p[0 .. p.len - 2]);
        return glob(p, arg);
    }
};

/// The input value a rule pattern is matched against.
pub fn mainArgument(arena: Allocator, input_json: []const u8) ?[]const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, input_json, .{}) catch return null;
    if (v != .object) return null;
    for ([_][]const u8{ "command", "path", "file_path", "url", "pattern" }) |k| if (v.object.get(k)) |x| if (x == .string) return x.string;
    return null;
}

/// `*` matches any run of characters (`/` included).
pub fn glob(pattern: []const u8, s: []const u8) bool {
    var p: usize = 0;
    var i: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (i < s.len) {
        if (p < pattern.len and pattern[p] == '*') {
            while (p < pattern.len and pattern[p] == '*') p += 1;
            star = p;
            mark = i;
        } else if (p < pattern.len and pattern[p] == s[i]) {
            p += 1;
            i += 1;
        } else if (star) |st| {
            p = st;
            mark += 1;
            i = mark;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

pub const Answer = struct {
    allow: bool,
    message: ?[]const u8 = null,
    /// The input the user edited (JSON).
    updated_input: ?[]const u8 = null,
};

/// Streamed approvals: writes `permission_request` lines through `emit`
/// and pairs them with `permission_response` lines delivered to `answer`.
/// A response may arrive before its request is asked (pipes are fast).
pub const Broker = struct {
    gpa: Allocator,
    io: Io,
    emit_ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, line: sj.OutLine) void,
    clock: ratelimit.Clock = .real,
    timeout_ms: u64 = default_timeout_ms,
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    arena: std.heap.ArenaAllocator,
    answers: std.StringHashMapUnmanaged(Answer) = .empty,
    expired: std.StringHashMapUnmanaged(void) = .empty,
    next_id: u32 = 1,
    /// Input ended: nobody can answer any more.
    closed: bool = false,

    /// `ai.headless.permissionTimeout`.
    pub const default_timeout_ms: u64 = 5 * 60 * 1000;

    pub fn init(gpa: Allocator, io: Io, emit_ctx: *anyopaque, emit: *const fn (ctx: *anyopaque, line: sj.OutLine) void) Broker {
        return .{ .gpa = gpa, .io = io, .emit_ctx = emit_ctx, .emit = emit, .arena = .init(gpa) };
    }

    pub fn deinit(b: *Broker) void {
        b.answers.deinit(b.gpa);
        b.expired.deinit(b.gpa);
        b.arena.deinit();
    }

    /// Asks and waits. A cancel (the turn was interrupted) returns
    /// `error.Canceled`.
    pub fn ask(b: *Broker, tool: []const u8, input_json: []const u8, reason: []const u8) Io.Cancelable!Answer {
        var id_buf: [24]u8 = undefined;
        const id = blk: {
            b.mutex.lockUncancelable(b.io);
            defer b.mutex.unlock(b.io);
            defer b.next_id += 1;
            break :blk std.fmt.bufPrint(&id_buf, "perm_{d}", .{b.next_id}) catch unreachable;
        };
        b.emit(b.emit_ctx, .{ .permission_request = .{ .request_id = id, .tool = tool, .input_json = input_json, .reason = reason } });
        var timer = b.io.concurrent(expire, .{ b, id }) catch null;
        defer if (timer) |*t| t.cancel(b.io);
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        while (true) {
            if (b.answers.fetchRemove(id)) |kv| return kv.value;
            if (b.expired.remove(id)) return .{ .allow = false, .message = "the approval timed out" };
            if (b.closed) return .{ .allow = false, .message = "input ended before an answer" };
            try b.cond.wait(b.io, &b.mutex);
        }
    }

    fn expire(b: *Broker, id: []const u8) void {
        b.clock.sleep(b.io, b.timeout_ms) catch return;
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        const key = b.arena.allocator().dupe(u8, id) catch return;
        b.expired.put(b.gpa, key, {}) catch return;
        b.cond.broadcast(b.io);
    }

    /// Delivers a `permission_response`.
    pub fn answer(b: *Broker, request_id: []const u8, a: Answer) Allocator.Error!void {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        const ar = b.arena.allocator();
        const key = try ar.dupe(u8, request_id);
        try b.answers.put(b.gpa, key, .{
            .allow = a.allow,
            .message = if (a.message) |m| try ar.dupe(u8, m) else null,
            .updated_input = if (a.updated_input) |u| try ar.dupe(u8, u) else null,
        });
        b.cond.broadcast(b.io);
    }

    /// Input ended: pending and later requests are denied.
    pub fn close(b: *Broker) void {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        b.closed = true;
        b.cond.broadcast(b.io);
    }
};

pub const Options = struct {
    allowed: []const []const u8 = &.{},
    disallowed: []const []const u8 = &.{},
    mode: args_mod.PermissionMode = .default,
    /// Streamed approvals; null denies what needs one.
    broker: ?*Broker = null,
    /// Consulted first (the E16 engine in the app); `deny` is final.
    base: ?deps.Permission = null,
};

pub const HeadlessPermission = struct {
    gpa: Allocator,
    opts: Options,
    allowed: []Rule,
    disallowed: []Rule,
    mutex: Io.Mutex = .init,
    arena: std.heap.ArenaAllocator,
    /// Calls refused for want of an approval.
    denials: std.ArrayList(sj.Denial) = .empty,

    pub fn init(gpa: Allocator, opts: Options) Allocator.Error!HeadlessPermission {
        const allowed = try gpa.alloc(Rule, opts.allowed.len);
        errdefer gpa.free(allowed);
        const disallowed = try gpa.alloc(Rule, opts.disallowed.len);
        for (opts.allowed, allowed) |t, *r| r.* = .parse(t);
        for (opts.disallowed, disallowed) |t, *r| r.* = .parse(t);
        return .{ .gpa = gpa, .opts = opts, .allowed = allowed, .disallowed = disallowed, .arena = .init(gpa) };
    }

    pub fn deinit(h: *HeadlessPermission) void {
        h.gpa.free(h.allowed);
        h.gpa.free(h.disallowed);
        h.denials.deinit(h.gpa);
        h.arena.deinit();
    }

    /// Switches the mode, as plan approval does mid-turn.
    pub fn setMode(h: *HeadlessPermission, mode: args_mod.PermissionMode) void {
        @atomicStore(args_mod.PermissionMode, &h.opts.mode, mode, .release);
    }

    pub fn permission(h: *HeadlessPermission) deps.Permission {
        return .{ .ctx = h, .check = check, .check_hinted = checkHinted };
    }

    /// The number of denials so far.
    pub fn denialCount(h: *HeadlessPermission, io: Io) usize {
        h.mutex.lockUncancelable(io);
        defer h.mutex.unlock(io);
        return h.denials.items.len;
    }

    fn check(ctx: *anyopaque, io: Io, agent: proto.AgentRef, spec: *const proto.ToolSpec, input_json: []const u8) Io.Cancelable!deps.Decision {
        return checkHinted(ctx, io, agent, spec, input_json, .none);
    }

    /// Deny rules, the base engine and plan mode apply whatever the hooks
    /// said; a hook allow then skips the prompt, and a hook ask skips the
    /// allow rules and modes that would have avoided one.
    fn checkHinted(ctx: *anyopaque, io: Io, agent: proto.AgentRef, spec: *const proto.ToolSpec, input_json: []const u8, hint: deps.Hint) Io.Cancelable!deps.Decision {
        const h: *HeadlessPermission = @ptrCast(@alignCast(ctx));
        var scratch: std.heap.ArenaAllocator = .init(h.gpa);
        defer scratch.deinit();
        const sa = scratch.allocator();
        for (h.disallowed, h.opts.disallowed) |r, text| if (r.matches(sa, spec.name, input_json))
            return .{ .deny = h.keep(io, "denied by --disallowed-tools rule {s}", .{text}) };
        if (h.opts.base) |b| return b.decide(io, agent, spec, input_json, hint);
        const mode = @atomicLoad(args_mod.PermissionMode, &h.opts.mode, .acquire);
        const e = spec.effectiveEffects();
        const read_only = e.read_only and !e.writes_workspace and !e.executes and !e.network;
        if (mode == .plan) {
            // Plan mode outranks allow rules: read-only commands and the
            // plan-mode tools run, everything else is refused.
            if (!readonly.planAllows(spec, input_json)) return .{ .deny = "plan mode is read-only" };
            if (hint != .hook_ask) return .allow;
        }
        if (hint != .hook_ask) {
            if (mode == .bypass_permissions) return .allow;
            for (h.allowed) |r| if (r.matches(sa, spec.name, input_json)) return .allow;
            if (read_only) return .allow;
        }
        if (hint == .hook_allow) return .allow;
        if (hint != .hook_ask and mode == .accept_edits and !e.executes and !e.network and !e.open_world) return .allow;
        if (mode != .dont_ask) if (h.opts.broker) |b| {
            const reason = h.keep(io, "{s} needs approval", .{spec.name});
            const a = try b.ask(spec.name, input_json, reason);
            if (a.allow) return if (a.updated_input) |u| .{ .allow_edited = u } else .allow;
            const why = a.message orelse "the user denied the call";
            return .{ .deny = h.deny(io, spec.name, input_json, why) };
        };
        const why = h.keep(io, "{s} needs approval and this run cannot ask; allow it with --allowed-tools {s} or use --permission-prompts stream", .{ spec.name, spec.name });
        return .{ .deny = h.deny(io, spec.name, input_json, why) };
    }

    /// Formats into the long-lived arena.
    fn keep(h: *HeadlessPermission, io: Io, comptime fmt: []const u8, a: anytype) []const u8 {
        h.mutex.lockUncancelable(io);
        defer h.mutex.unlock(io);
        return std.fmt.allocPrint(h.arena.allocator(), fmt, a) catch "permission denied";
    }

    fn deny(h: *HeadlessPermission, io: Io, tool: []const u8, input_json: []const u8, why: []const u8) []const u8 {
        h.mutex.lockUncancelable(io);
        defer h.mutex.unlock(io);
        const ar = h.arena.allocator();
        const d: sj.Denial = .{
            .tool_name = ar.dupe(u8, tool) catch return why,
            .tool_input = ar.dupe(u8, input_json) catch return why,
            .reason = ar.dupe(u8, why) catch return why,
        };
        h.denials.append(h.gpa, d) catch {};
        return d.reason;
    }
};

test "rules" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect(Rule.parse("read_file").matches(a, "read_file", "{}"));
    try t.expect(!Rule.parse("read_file").matches(a, "write_file", "{}"));
    const git = Rule.parse("run_command(git diff:*)");
    try t.expectEqualStrings("run_command", git.tool);
    try t.expect(git.matches(a, "run_command", "{\"command\":\"git diff --stat\"}"));
    try t.expect(!git.matches(a, "run_command", "{\"command\":\"git push\"}"));
    try t.expect(Rule.parse("edit_file(src/*.zig)").matches(a, "edit_file", "{\"path\":\"src/a/b.zig\"}"));
    try t.expect(!Rule.parse("edit_file(src/*.zig)").matches(a, "edit_file", "{\"path\":\"docs/a.md\"}"));
    try t.expect(glob("*", ""));
    try t.expect(glob("a*b*c", "aXbYc"));
    try t.expect(!glob("a*b", "aXc"));
}

test "hook hints" {
    const t = std.testing;
    var d: u8 = 0;
    const spec = struct {
        fn call(_: *anyopaque, _: *proto.ToolCall) proto.ToolError!proto.ToolOutput {
            return error.Failed;
        }
        fn make(ctx: *anyopaque, read_only: bool) proto.ToolSpec {
            return .{ .name = "write_file", .description = "", .input_schema_json = "{}", .read_only = read_only, .handler = .{ .ctx = ctx, .call = call } };
        }
    };
    const write = spec.make(&d, false);
    const read = spec.make(&d, true);
    const agent: proto.AgentRef = .{ .session = 1 };
    const io = t.io;

    // No way to ask: a hook allow skips the prompt, a hook ask cannot be met.
    var h: HeadlessPermission = try .init(t.allocator, .{ .disallowed = &.{"write_file(.env)"} });
    defer h.deinit();
    const p = h.permission();
    try t.expect(try p.decide(io, agent, &write, "{\"path\":\"a\"}", .none) == .deny);
    try t.expect(try p.decide(io, agent, &write, "{\"path\":\"a\"}", .hook_allow) == .allow);
    // Deny rules win over a hook allow.
    try t.expect(try p.decide(io, agent, &write, "{\"path\":\".env\"}", .hook_allow) == .deny);
    // A read-only tool is allowed, unless a hook asks.
    try t.expect(try p.decide(io, agent, &read, "{}", .none) == .allow);
    try t.expect(try p.decide(io, agent, &read, "{}", .hook_ask) == .deny);

    // Plan mode is not overridden by a hook allow.
    var plan: HeadlessPermission = try .init(t.allocator, .{ .mode = .plan });
    defer plan.deinit();
    try t.expectEqualStrings("plan mode is read-only", (try plan.permission().decide(io, agent, &write, "{}", .hook_allow)).deny);
}
