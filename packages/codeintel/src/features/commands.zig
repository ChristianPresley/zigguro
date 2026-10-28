//! `workspace/executeCommand` (E07.F04.S02.T02). A command goes to the
//! server that listed it in `executeCommandProvider.commands` (or the one
//! that returned it, for code action commands). While an agent's command
//! is in flight the server is marked (`Server.agent_command`), so the
//! `workspace/applyEdit` it sends meanwhile goes to review like the
//! agent's own edits: servers apply their edit, wait for our answer, then
//! answer the command, so the mark is cleared only after its edits.
//!
//! Commands some servers send for the client to run (`editor.action.*`)
//! map to zigguro commands (`clientCommand`).

const CommandService = @This();
const std = @import("std");
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Manager = @import("../Manager.zig");
const oneshot = @import("oneshot.zig");

const Allocator = std.mem.Allocator;
const protocol = zg_lsp.protocol;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const log = std.log.scoped(.lsp_command);

const Tag = struct { server: *Manager.Server, agent: ?u32 };
const Req = oneshot.Oneshot(.@"workspace/executeCommand", Tag);

gpa: Allocator,
mgr: *Manager,
req: Req,
/// The last failure's message, until the next `tick`.
failure: std.ArrayList(u8) = .empty,

pub fn init(mgr: *Manager, waker: zg_core.runtime.Waker) CommandService {
    return .{ .gpa = mgr.gpa, .mgr = mgr, .req = .init(mgr.gpa, mgr.rt.io, waker) };
}

/// Call after `Manager.deinit`.
pub fn deinit(c: *CommandService) void {
    for (c.req.take()) |a| c.done(a.tag);
    c.req.deinit();
    c.failure.deinit(c.gpa);
}

/// Whether running server `s` lists `command`.
pub fn lists(s: *const Manager.Server, command: []const u8) bool {
    if (s.status != .running) return false;
    const cl = s.client orelse return false;
    const caps = cl.caps() orelse return false;
    const p = caps.raw.executeCommandProvider orelse return false;
    for (p.commands) |name| if (std.mem.eql(u8, name, command)) return true;
    return false;
}

/// The server to run `command`: one attached to `h` first, then any.
pub fn serverFor(c: *CommandService, h: ?DocHandle, command: []const u8) ?*Manager.Server {
    if (h) |d| for (c.mgr.serverList()) |s| {
        if (lists(s, command) and for (s.docs.items) |x| {
            if (std.meta.eql(x, d)) break true;
        } else false) return s;
    };
    for (c.mgr.serverList()) |s| if (lists(s, command)) return s;
    return null;
}

/// The zigguro command a client-side command stands for, if known.
pub fn clientCommand(command: []const u8) ?[]const u8 {
    const map = [_][2][]const u8{
        .{ "editor.action.triggerSuggest", "editor.triggerSuggest" },
        .{ "editor.action.triggerParameterHints", "editor.triggerParameterHints" },
        .{ "editor.action.showReferences", "editor.findReferences" },
        .{ "editor.action.rename", "editor.rename" },
    };
    for (map) |m| if (std.mem.eql(u8, m[0], command)) return m[1];
    return null;
}

/// Runs `cmd` on `s`. `agent` is the agent session asking, if any.
pub fn execute(c: *CommandService, s: *Manager.Server, cmd: protocol.Command, agent: ?u32) !void {
    const cl = s.client orelse return error.ServerStopped;
    if (agent) |a| {
        s.agent_commands += 1;
        s.agent_command = a;
    }
    errdefer if (agent != null) c.done(.{ .server = s, .agent = agent });
    c.mgr.flush();
    try c.req.send(cl, .{ .command = cmd.command, .arguments = cmd.arguments }, .{}, .{ .server = s, .agent = agent });
}

fn done(_: *CommandService, t: Tag) void {
    if (t.agent == null) return;
    t.server.agent_commands -|= 1;
    if (t.server.agent_commands == 0) t.server.agent_command = null;
}

/// Finishes answered commands; returns a failure to show, if any (valid
/// until the next call).
pub fn tick(c: *CommandService) ?[]const u8 {
    c.failure.clearRetainingCapacity();
    for (c.req.take()) |a| {
        c.done(a.tag);
        switch (a.result) {
            .ok => {},
            .lsp_error => |e| {
                c.failure.clearRetainingCapacity();
                c.failure.appendSlice(c.gpa, e.message) catch {};
            },
            .canceled, .content_modified => {},
            else => {
                c.failure.clearRetainingCapacity();
                c.failure.print(c.gpa, "The command failed ({s}).", .{@tagName(a.result)}) catch {};
            },
        }
    }
    return if (c.failure.items.len > 0) c.failure.items else null;
}

/// Whether a command is still running.
pub fn busy(c: *const CommandService) bool {
    return c.req.busy();
}
