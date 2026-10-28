//! Code actions (E07.F04.S02.T02): `request` asks every routed server
//! for the actions over a byte range, with the diagnostics overlapping it
//! (their `data` sent back as the server gave it), the `only` kinds and
//! the trigger (invoked from Ctrl+. or automatic, from a resting caret,
//! for the lightbulb). Answers merge in routing order; `items` lists
//! them preferred first, then by kind group (Quick Fix, Refactor, Extract,
//! Inline, Rewrite, Move, Source, Other), disabled ones last.
//!
//! `run` performs an action: a bare `Command` is executed; an action with
//! no edit is resolved first (`codeAction/resolve`) when its server can;
//! then its edit goes through the workspace edit engine and its command
//! runs after it.

const CodeActionService = @This();
const std = @import("std");
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Manager = @import("../Manager.zig");
const requester = @import("request.zig");
const oneshot = @import("oneshot.zig");
const position = @import("position.zig");
const Store = @import("../diagnostics/Store.zig");
const Engine = @import("../edits/Engine.zig");
const plan_mod = @import("../edits/plan.zig");
const CommandService = @import("commands.zig");

const Allocator = std.mem.Allocator;
const protocol = zg_lsp.protocol;
const Client = zg_lsp.client.Client;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const ByteRange = position.ByteRange;
const Req = requester.Requester(.@"textDocument/codeAction", .code_action);
const Resolve = oneshot.Oneshot(.@"codeAction/resolve", ResolveTag);
const ResolveTag = struct { round: u64, origin: Engine.Origin };

pub const Trigger = enum { invoked, automatic };

pub const Group = enum {
    quickfix,
    refactor,
    extract,
    inline_,
    rewrite,
    move,
    source,
    other,

    pub fn label(g: Group) []const u8 {
        return switch (g) {
            .quickfix => "Quick Fix",
            .refactor => "Refactor",
            .extract => "Extract",
            .inline_ => "Inline",
            .rewrite => "Rewrite",
            .move => "Move",
            .source => "Source Action",
            .other => "More Actions",
        };
    }

    pub fn of(kind: []const u8) Group {
        const prefixes = [_]struct { []const u8, Group }{
            .{ "quickfix", .quickfix },
            .{ "refactor.extract", .extract },
            .{ "refactor.inline", .inline_ },
            .{ "refactor.rewrite", .rewrite },
            .{ "refactor.move", .move },
            .{ "refactor", .refactor },
            .{ "source", .source },
        };
        for (prefixes) |p| {
            if (std.mem.startsWith(u8, kind, p[0]) and (kind.len == p[0].len or kind[p[0].len] == '.')) return p[1];
        }
        return .other;
    }
};

pub const Item = struct {
    title: []const u8,
    /// The action's kind ("" when none).
    kind: []const u8,
    group: Group,
    preferred: bool,
    disabled: ?[]const u8,
    /// A bare `Command` (not a `CodeAction`).
    is_command: bool,
    /// Borrowed from the answer.
    value: protocol.TextDocumentCodeActionResultItem,
    client: *Client,
    /// Routing order, then the server's order.
    order: u32,
};

gpa: Allocator,
mgr: *Manager,
engine: *Engine,
commands: *CommandService,
diags: ?*Store,
req: Req,
resolve: Resolve,
/// The answers `items` borrow from.
answers: std.ArrayList(*Req.Answer) = .empty,
list: std.ArrayList(Item) = .empty,
asked: ?struct { h: DocHandle, range: ByteRange, trigger: Trigger } = null,
round: u64 = 0,
/// Bumped when `items` changes.
generation: u64 = 0,
/// The last failure's message, until the next `tick`.
failure: std.ArrayList(u8) = .empty,
scratch: std.heap.ArenaAllocator,

pub fn init(mgr: *Manager, engine: *Engine, commands: *CommandService, diags: ?*Store, waker: zg_core.runtime.Waker) CodeActionService {
    return .{
        .gpa = mgr.gpa,
        .mgr = mgr,
        .engine = engine,
        .commands = commands,
        .diags = diags,
        .req = .init(mgr, waker),
        .resolve = .init(mgr.gpa, mgr.rt.io, waker),
        .scratch = .init(mgr.gpa),
    };
}

/// Call after `Manager.deinit`.
pub fn deinit(s: *CodeActionService) void {
    s.clear();
    s.answers.deinit(s.gpa);
    s.list.deinit(s.gpa);
    s.req.deinit();
    s.resolve.deinit();
    s.failure.deinit(s.gpa);
    s.scratch.deinit();
}

fn clear(s: *CodeActionService) void {
    for (s.answers.items) |a| s.req.free(a);
    s.answers.clearRetainingCapacity();
    if (s.list.items.len > 0) s.generation += 1;
    s.list.clearRetainingCapacity();
}

/// Whether a server offers code actions for `h`.
pub fn available(s: *CodeActionService, h: DocHandle) bool {
    return s.req.available(h);
}

/// Asks for the actions over `range` of `h`.
pub fn request(s: *CodeActionService, h: DocHandle, range: ByteRange, trigger: Trigger, only: ?[]const []const u8) !void {
    s.cancel();
    _ = s.scratch.reset(.retain_capacity);
    const a = s.scratch.allocator();
    const kinds: ?[]const protocol.CodeActionKind = if (only) |o| blk: {
        const ks = try a.alloc(protocol.CodeActionKind, o.len);
        for (ks, o) |*k, name| k.* = .fromString(name);
        break :blk ks;
    } else null;
    const diags = try s.contextDiagnostics(a, h, range);
    const n = try s.req.askRange(h, range, .{ .context = protocol.CodeActionContext{
        .diagnostics = diags,
        .only = kinds,
        .triggerKind = if (trigger == .invoked) .Invoked else .Automatic,
    } });
    if (n > 0) s.asked = .{ .h = h, .range = range, .trigger = trigger };
}

/// The diagnostics overlapping `range`, as the servers sent them.
fn contextDiagnostics(s: *CodeActionService, a: Allocator, h: DocHandle, range: ByteRange) ![]const protocol.Diagnostic {
    const st = s.diags orelse return &.{};
    const doc = s.mgr.docs.get(h) orelse return &.{};
    const uri = s.mgr.docs.uri(h) orelse return &.{};
    const key = try st.keyOf(a, uri);
    const snap = st.acquire();
    defer snap.release();
    const b = snap.bucket(key) orelse return &.{};
    var out: std.ArrayList(protocol.Diagnostic) = .empty;
    for (b.sets) |set| {
        const ver = set.version orelse continue;
        for (set.diags) |d| {
            const br = d.bytes orelse continue;
            const r = doc.mapForward(ver, .{ .start = br.start, .end = br.end }, .right) orelse continue;
            // Overlapping, or touching an empty range.
            if (r.start > range.end or r.end < range.start) continue;
            try out.append(a, .{
                .range = .{ .start = .{ .line = d.start.line, .character = d.start.character }, .end = .{ .line = d.end.line, .character = d.end.character } },
                .severity = @enumFromInt(@intFromEnum(d.severity)),
                .code = if (d.code.len == 0) null else if (std.fmt.parseInt(i32, d.code, 10)) |n| .{ .integer = n } else |_| .{ .string = try a.dupe(u8, d.code) },
                .source = if (d.source.len == 0) null else try a.dupe(u8, d.source),
                .message = .{ .string = try a.dupe(u8, d.message) },
                .data = if (d.data) |js| try std.json.parseFromSliceLeaky(std.json.Value, a, js, .{}) else null,
            });
        }
    }
    return out.items;
}

/// Forgets the request and its actions.
pub fn cancel(s: *CodeActionService) void {
    s.req.cancel();
    s.asked = null;
    s.round += 1;
    s.clear();
}

/// The actions so far, sorted.
pub fn items(s: *const CodeActionService) []const Item {
    return s.list.items;
}

/// Whether every server answered the request.
pub fn complete(s: *const CodeActionService) bool {
    return s.asked == null or s.req.done();
}

/// Whether any action is a quick fix, and whether one is preferred (the
/// lightbulb and its colour).
pub fn bulb(s: *const CodeActionService) struct { any: bool, preferred: bool } {
    var any = false;
    var pref = false;
    for (s.list.items) |it| if (it.disabled == null) {
        any = true;
        pref = pref or it.preferred;
    };
    return .{ .any = any, .preferred = pref };
}

/// The request's document and range, if any.
pub fn target(s: *const CodeActionService) ?struct { h: DocHandle, range: ByteRange, trigger: Trigger } {
    const a = s.asked orelse return null;
    return .{ .h = a.h, .range = a.range, .trigger = a.trigger };
}

/// Takes answers, finishes resolved actions; true when `items` changed.
/// `failure` (if set afterwards) holds a message to show.
pub fn tick(s: *CodeActionService) bool {
    const g = s.generation;
    s.failure.clearRetainingCapacity();
    for (s.req.take()) |a| {
        const v = switch (a.result) {
            .ok => |o| o.value orelse continue,
            else => continue,
        };
        s.req.retain(a);
        s.answers.append(s.gpa, a) catch {
            s.req.free(a);
            continue;
        };
        for (v, 0..) |it, i| {
            const order: u32 = @as(u32, a.index) << 16 | @as(u32, @intCast(@min(i, 0xffff)));
            const item: Item = switch (it) {
                .command => |c| .{ .title = c.title, .kind = "", .group = .other, .preferred = false, .disabled = null, .is_command = true, .value = it, .client = a.client, .order = order },
                .code_action => |ca| blk: {
                    const kind = if (ca.kind) |k| k.toString() else "";
                    break :blk .{
                        .title = ca.title,
                        .kind = kind,
                        .group = Group.of(kind),
                        .preferred = ca.isPreferred orelse false,
                        .disabled = if (ca.disabled) |d| d.reason else null,
                        .is_command = false,
                        .value = it,
                        .client = a.client,
                        .order = order,
                    };
                },
            };
            s.list.append(s.gpa, item) catch break;
        }
        std.sort.block(Item, s.list.items, {}, lessThan);
        s.generation += 1;
    }
    for (s.resolve.take()) |a| {
        if (a.tag.round != s.round) continue;
        switch (a.result) {
            .ok => |o| s.perform(o.value, a.client, a.tag.origin),
            .lsp_error => |e| s.fail("{s}", .{e.message}),
            else => s.fail("The action could not be resolved ({s}).", .{@tagName(a.result)}),
        }
    }
    return s.generation != g;
}

fn lessThan(_: void, a: Item, b: Item) bool {
    const ad = a.disabled != null;
    const bd = b.disabled != null;
    if (ad != bd) return bd;
    if (a.preferred != b.preferred) return a.preferred;
    if (a.group != b.group) return @intFromEnum(a.group) < @intFromEnum(b.group);
    return a.order < b.order;
}

fn fail(s: *CodeActionService, comptime fmt: []const u8, args: anytype) void {
    s.failure.clearRetainingCapacity();
    s.failure.print(s.gpa, fmt, args) catch {};
}

fn serverOf(s: *CodeActionService, c: *Client) ?*Manager.Server {
    for (s.mgr.serverList()) |sv| if (sv.client == c) return sv;
    return null;
}

fn canResolve(c: *Client) bool {
    const caps = c.caps() orelse return false;
    const p = caps.raw.codeActionProvider orelse return false;
    return switch (p) {
        .boolean => false,
        .code_action_options => |o| o.resolveProvider orelse false,
    };
}

/// Runs action `i` of `items`. Errors and refusals land in `failure`.
pub fn run(s: *CodeActionService, i: usize, origin: Engine.Origin) !void {
    s.failure.clearRetainingCapacity();
    const it = s.list.items[i];
    if (it.disabled) |why| return s.fail("{s}", .{why});
    switch (it.value) {
        .command => |c| return s.command(it.client, c, origin),
        .code_action => |ca| {
            if (ca.edit == null and ca.command == null and canResolve(it.client)) {
                s.mgr.flush();
                try s.resolve.send(it.client, ca, .{}, .{ .round = s.round, .origin = origin });
                return;
            }
            s.perform(ca, it.client, origin);
        },
    }
}

fn command(s: *CodeActionService, c: *Client, cmd: protocol.Command, origin: Engine.Origin) void {
    const sv = s.serverOf(c) orelse return s.fail("The language server stopped.", .{});
    const agent: ?u32 = switch (origin) {
        .agent => |x| x,
        .server => |x| x,
        .user => null,
    };
    s.commands.execute(sv, cmd, agent) catch |e| s.fail("The command failed: {t}.", .{e});
}

/// The edit first, then the command.
fn perform(s: *CodeActionService, ca: protocol.CodeAction, c: *Client, origin: Engine.Origin) void {
    if (ca.edit) |*edit| {
        const sv = s.serverOf(c) orelse return s.fail("The language server stopped.", .{});
        var why: plan_mod.Failure = .{ .index = 0, .err = error.Unknown };
        var p = s.engine.plan(edit, Engine.sourceOf(sv), ca.title, &why) catch
            return s.fail("{s}: {s}.", .{ ca.title, plan_mod.reason(why.err) });
        defer p.deinit();
        const out = s.engine.apply(&p, origin, .auto) catch |e| return s.fail("{s}: {s}.", .{ ca.title, plan_mod.reason(e) });
        switch (out) {
            .failed => |f| return s.fail("{s}: {s}.", .{ ca.title, f.reason }),
            .queued => return,
            .applied => {},
        }
    }
    if (ca.command) |cmd| s.command(c, cmd, origin);
}
