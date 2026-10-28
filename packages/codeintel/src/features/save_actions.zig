//! The save pipeline (E07.F04.S02.T03): before a document is written,
//! `beforeSave` runs, within one deadline (1 s by default):
//!
//! 1. `textDocument/willSaveWaitUntil` on every server that asked for it
//!    (`textDocumentSync.willSaveWaitUntil`);
//! 2. the code actions on save (`editor.codeActionsOnSave` kinds such as
//!    `source.organizeImports`), one kind at a time, the first enabled
//!    action of the kind, resolved when it has no edit;
//! 3. format on save (`textDocument/formatting`).
//!
//! Each step's edits go through the workspace edit engine before the next
//! step asks, so every server sees the text the previous step left. When
//! the deadline passes the remaining steps are skipped and the document
//! is saved as it is; the caller warns once per document (`Result.warn`).
//!
//! It blocks the UI thread (as editors do on save), ticking the manager
//! while it waits, so servers' own requests (`workspace/applyEdit`) are
//! still answered. Commands of code actions run after, without waiting.

const SaveActions = @This();
const std = @import("std");
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Manager = @import("../Manager.zig");
const oneshot = @import("oneshot.zig");
const position = @import("position.zig");
const Engine = @import("../edits/Engine.zig");
const plan_mod = @import("../edits/plan.zig");
const FormatService = @import("format.zig");
const CodeActionService = @import("code_action.zig");
const CommandService = @import("commands.zig");

const Allocator = std.mem.Allocator;
const protocol = zg_lsp.protocol;
const Client = zg_lsp.client.Client;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const log = std.log.scoped(.save_actions);

const WaitReq = oneshot.Oneshot(.@"textDocument/willSaveWaitUntil", u64);
const ActionReq = oneshot.Oneshot(.@"textDocument/codeAction", u64);
const ResolveReq = oneshot.Oneshot(.@"codeAction/resolve", u64);
const FormatReq = oneshot.Oneshot(.@"textDocument/formatting", u64);

pub const Plan = struct {
    /// Code action kinds to run, in order.
    code_actions: []const []const u8 = &.{},
    format: bool = false,
    reason: protocol.TextDocumentSaveReason = .Manual,
    budget_ms: u64 = 1000,
};

/// Milliseconds on some monotonic clock (tests inject one).
pub const Clock = struct {
    ctx: ?*anyopaque = null,
    now_ms: *const fn (ctx: ?*anyopaque) u64,
};

pub const Step = enum { will_save, code_action, format };

pub const Result = struct {
    /// Steps that changed the document.
    edited: u8 = 0,
    timed_out: bool = false,
    /// Timed out, and the first time for this document.
    warn: bool = false,
};

gpa: Allocator,
mgr: *Manager,
engine: *Engine,
commands: ?*CommandService,
options: ?FormatService.OptionsLookup = null,
wait_req: WaitReq,
action_req: ActionReq,
resolve_req: ResolveReq,
format_req: FormatReq,
/// Tags requests: an answer to an earlier call that timed out is skipped.
serial: u64 = 0,
warned: std.AutoHashMapUnmanaged(DocHandle, void) = .empty,
/// The steps the last call ran, in order (tests).
trace: std.ArrayList(Step) = .empty,

pub fn init(mgr: *Manager, engine: *Engine, commands: ?*CommandService) SaveActions {
    const io = mgr.rt.io;
    return .{
        .gpa = mgr.gpa,
        .mgr = mgr,
        .engine = engine,
        .commands = commands,
        .wait_req = .init(mgr.gpa, io, .noop),
        .action_req = .init(mgr.gpa, io, .noop),
        .resolve_req = .init(mgr.gpa, io, .noop),
        .format_req = .init(mgr.gpa, io, .noop),
    };
}

/// Call after `Manager.deinit`.
pub fn deinit(s: *SaveActions) void {
    s.wait_req.deinit();
    s.action_req.deinit();
    s.resolve_req.deinit();
    s.format_req.deinit();
    s.warned.deinit(s.gpa);
    s.trace.deinit(s.gpa);
}

/// The runtime's monotonic clock.
pub fn clock(s: *SaveActions) Clock {
    return .{ .ctx = s, .now_ms = struct {
        fn f(ctx: ?*anyopaque) u64 {
            const self: *SaveActions = @ptrCast(@alignCast(ctx.?));
            return @intCast(@divFloor(std.Io.Clock.Timestamp.now(self.mgr.rt.io, .awake).raw.nanoseconds, std.time.ns_per_ms));
        }
    }.f };
}

/// Forgets the warning state of `h` (it closed).
pub fn forget(s: *SaveActions, h: DocHandle) void {
    _ = s.warned.remove(h);
}

/// Runs the pipeline for `h`; see the module doc.
pub fn beforeSave(s: *SaveActions, h: DocHandle, plan: Plan, clk: Clock) Result {
    var res: Result = .{};
    s.trace.clearRetainingCapacity();
    const deadline = clk.now_ms(clk.ctx) + plan.budget_ms;
    var w: Waiter = .{ .s = s, .clock = clk, .deadline = deadline };
    s.willSave(h, plan.reason, &w, &res);
    for (plan.code_actions) |kind| {
        if (w.expired) break;
        s.codeAction(h, kind, &w, &res);
    }
    if (plan.format and !w.expired) s.format(h, &w, &res);
    if (w.expired) {
        res.timed_out = true;
        const gop = s.warned.getOrPut(s.gpa, h) catch return res;
        res.warn = !gop.found_existing;
    }
    return res;
}

const Waiter = struct {
    s: *SaveActions,
    clock: Clock,
    deadline: u64,
    expired: bool = false,

    /// The answer tagged `serial`, or null when the deadline passed.
    fn wait(w: *Waiter, req: anytype, serial: u64) ?*const @TypeOf(req.*).Answer {
        while (true) {
            w.s.mgr.tick();
            for (req.take()) |a| if (a.tag == serial) return a;
            if (w.clock.now_ms(w.clock.ctx) >= w.deadline) {
                w.expired = true;
                return null;
            }
            w.s.mgr.rt.io.sleep(.fromMilliseconds(1), .awake) catch {};
        }
    }
};

fn uriOf(s: *SaveActions, h: DocHandle) ?[]const u8 {
    return s.mgr.docs.uri(h);
}

fn syncOptions(sv: *const Manager.Server) ?protocol.TextDocumentSyncOptions {
    const cl = sv.client orelse return null;
    const caps = cl.caps() orelse return null;
    const sync = caps.raw.textDocumentSync orelse return null;
    return switch (sync) {
        .text_document_sync_options => |o| o,
        .text_document_sync_kind => null,
    };
}

fn wantsWillSave(sv: *const Manager.Server) bool {
    const o = syncOptions(sv) orelse return false;
    return o.willSaveWaitUntil orelse false;
}

/// The server asked for the `willSave` notification.
fn wantsWillSaveNote(sv: *const Manager.Server) bool {
    const o = syncOptions(sv) orelse return false;
    return o.willSave orelse false;
}

fn willSave(s: *SaveActions, h: DocHandle, reason: protocol.TextDocumentSaveReason, w: *Waiter, res: *Result) void {
    const uri = s.uriOf(h) orelse return;
    // The notification first, to every server that wants it, after the
    // edits it has not seen.
    s.mgr.flush();
    for (s.mgr.serverList()) |sv| {
        if (sv.status != .running or !sv.hasDoc(h) or !wantsWillSaveNote(sv)) continue;
        sv.client.?.notify(.@"textDocument/willSave", .{ .textDocument = .{ .uri = uri }, .reason = reason }) catch {};
    }
    for (s.mgr.serverList()) |sv| {
        if (w.expired) return;
        if (sv.status != .running or !sv.hasDoc(h) or !wantsWillSave(sv)) continue;
        s.mgr.flush();
        s.serial += 1;
        s.wait_req.send(sv.client.?, .{ .textDocument = .{ .uri = uri }, .reason = reason }, .{}, s.serial) catch continue;
        try_append(s, .will_save);
        const a = w.wait(&s.wait_req, s.serial) orelse return;
        const edits = okValue(a.result) orelse continue;
        if (s.apply(h, sv, edits, "Will Save")) res.edited += 1;
    }
}

fn try_append(s: *SaveActions, st: Step) void {
    s.trace.append(s.gpa, st) catch {};
}

fn okValue(result: anytype) ?@TypeOf(result.ok.value) {
    return switch (result) {
        .ok => |o| o.value,
        .lsp_error => |e| {
            log.info("save step failed: {s}", .{e.message});
            return null;
        },
        else => null,
    };
}

fn apply(s: *SaveActions, h: DocHandle, sv: *Manager.Server, edits: ?[]const protocol.TextEdit, label: []const u8) bool {
    const es = edits orelse return false;
    if (es.len == 0) return false;
    const out = FormatService.applyTextEdits(s.engine, s.mgr, h, sv, es, label, .user) catch |e| {
        log.info("{s}: {s}", .{ label, plan_mod.reason(e) });
        return false;
    };
    return switch (out) {
        .applied => true,
        else => false,
    };
}

fn wholeRange(s: *SaveActions, h: DocHandle, c: *Client) ?protocol.Range {
    const doc = s.mgr.docs.get(h) orelse return null;
    var m: position.Mapper = .{ .gpa = s.gpa, .tree = &doc.tree, .enc = position.encodingOf(c.encoding()) };
    defer m.deinit();
    return m.fromRange(.{ .start = 0, .end = doc.len() }) catch null;
}

fn codeAction(s: *SaveActions, h: DocHandle, kind: []const u8, w: *Waiter, res: *Result) void {
    const uri = s.uriOf(h) orelse return;
    var servers: [4]*Manager.Server = undefined;
    const n = s.mgr.serversFor(h, .code_action, &servers);
    for (servers[0..n]) |sv| {
        if (w.expired) return;
        const c = sv.client.?;
        s.mgr.flush();
        const range = s.wholeRange(h, c) orelse return;
        const only = [_]protocol.CodeActionKind{.fromString(kind)};
        s.serial += 1;
        s.action_req.send(c, .{
            .textDocument = .{ .uri = uri },
            .range = range,
            .context = .{ .diagnostics = &.{}, .only = &only, .triggerKind = .Automatic },
        }, .{}, s.serial) catch continue;
        try_append(s, .code_action);
        const a = w.wait(&s.action_req, s.serial) orelse return;
        const list = (okValue(a.result) orelse continue) orelse continue;
        const pick = for (list) |it| switch (it) {
            .code_action => |ca| {
                if (ca.disabled != null) continue;
                const k = if (ca.kind) |x| x.toString() else "";
                if (std.mem.startsWith(u8, k, kind) and (k.len == kind.len or k[kind.len] == '.')) break ca;
            },
            .command => {},
        } else continue;
        var ca = pick;
        if (ca.edit == null and ca.command == null and resolvable(c)) {
            s.serial += 1;
            s.resolve_req.send(c, ca, .{}, s.serial) catch continue;
            const r = w.wait(&s.resolve_req, s.serial) orelse return;
            ca = okValue(r.result) orelse continue;
        }
        if (ca.edit) |*edit| {
            var why: plan_mod.Failure = .{ .index = 0, .err = error.Unknown };
            if (s.engine.plan(edit, Engine.sourceOf(sv), ca.title, &why)) |p_| {
                var p = p_;
                defer p.deinit();
                if (s.engine.apply(&p, .user, .auto)) |out| {
                    if (out == .applied) res.edited += 1;
                } else |e| log.info("{s}: {s}", .{ ca.title, plan_mod.reason(e) });
            } else |_| log.info("{s}: {s}", .{ ca.title, plan_mod.reason(why.err) });
        }
        if (ca.command) |cmd| if (s.commands) |cs| cs.execute(sv, cmd, null) catch {};
        return;
    }
}

fn resolvable(c: *Client) bool {
    const caps = c.caps() orelse return false;
    const p = caps.raw.codeActionProvider orelse return false;
    return switch (p) {
        .boolean => false,
        .code_action_options => |o| o.resolveProvider orelse false,
    };
}

fn format(s: *SaveActions, h: DocHandle, w: *Waiter, res: *Result) void {
    const uri = s.uriOf(h) orelse return;
    var servers: [1]*Manager.Server = undefined;
    if (s.mgr.serversFor(h, .formatting, &servers) == 0) return;
    const sv = servers[0];
    s.mgr.flush();
    const opts = if (s.options) |o| o.f(o.ctx, h) else FormatService.default_options;
    s.serial += 1;
    s.format_req.send(sv.client.?, .{ .textDocument = .{ .uri = uri }, .options = opts }, .{}, s.serial) catch return;
    try_append(s, .format);
    const a = w.wait(&s.format_req, s.serial) orelse return;
    if (s.apply(h, sv, okValue(a.result) orelse return, "Format on Save")) res.edited += 1;
}
