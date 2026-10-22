//! Registers every subsystem's exporter with the tool registry
//! (E10.F06.S03.T01). The app passes the exporters it has: a CLI run
//! without language servers leaves `lsp` null, and nothing is registered
//! for it. Debug tools are off unless the workspace enables them (E07's
//! untrusted-workspace default).

const std = @import("std");
const registry = @import("../registry.zig");
const foreign = @import("foreign.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.ai_tools);

/// The exporters the app has. Names are contracts with their packages:
/// `zg_lsp.agent`, `zg_dap.agent`, the task runner, `zg_workspace.ai`,
/// `zg_notes.ai`, `zg_scm.agent` and one per configured MCP server.
pub const Services = struct {
    lsp: ?foreign.Exporter = null,
    debug: ?foreign.Exporter = null,
    tasks: ?foreign.Exporter = null,
    workspace: ?foreign.Exporter = null,
    notes: ?foreign.Exporter = null,
    scm: ?foreign.Exporter = null,
    mcp: []const foreign.Exporter = &.{},
};

pub const AdapterFlags = struct {
    lsp: bool = true,
    /// Per workspace; off by default.
    debug: bool = false,
    tasks: bool = true,
    workspace: bool = true,
    notes: bool = true,
    scm: bool = true,
    mcp: bool = true,
};

/// Owns the adapters; lives as long as the registry.
pub const Adapters = struct {
    gpa: Allocator,
    io: Io,
    list: std.ArrayList(*foreign.Adapter) = .empty,

    pub fn init(gpa: Allocator, io: Io) Adapters {
        return .{ .gpa = gpa, .io = io };
    }

    pub fn deinit(a: *Adapters) void {
        for (a.list.items) |x| {
            x.deinit();
            a.gpa.destroy(x);
        }
        a.list.deinit(a.gpa);
    }

    pub fn registerAll(a: *Adapters, r: *registry.ToolRegistry, s: *const Services, enabled: AdapterFlags, cfg: foreign.Config) Allocator.Error!void {
        const one = [_]struct { e: ?foreign.Exporter, on: bool, what: []const u8 }{
            .{ .e = s.lsp, .on = enabled.lsp, .what = "lsp" },
            .{ .e = s.debug, .on = enabled.debug, .what = "debug" },
            .{ .e = s.tasks, .on = enabled.tasks, .what = "tasks" },
            .{ .e = s.workspace, .on = enabled.workspace, .what = "workspace" },
            .{ .e = s.notes, .on = enabled.notes, .what = "notes" },
            .{ .e = s.scm, .on = enabled.scm, .what = "scm" },
        };
        for (one) |x| {
            if (!x.on) continue;
            const e = x.e orelse {
                log.info("no {s} tools: the subsystem is not available", .{x.what});
                continue;
            };
            try a.add(r, e, cfg);
        }
        if (enabled.mcp) for (s.mcp) |e| try a.add(r, e, cfg);
    }

    fn add(a: *Adapters, r: *registry.ToolRegistry, e: foreign.Exporter, cfg: foreign.Config) Allocator.Error!void {
        const x = try a.gpa.create(foreign.Adapter);
        errdefer a.gpa.destroy(x);
        x.* = .init(a.gpa, a.io, e, cfg);
        errdefer x.deinit();
        try a.list.append(a.gpa, x);
        errdefer _ = a.list.pop();
        try r.addSource(x.source());
    }
};
