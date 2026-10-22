//! Consumer adapters over `Engine` (E16.F02.S01.T04): the exact shapes E06
//! (terminals), E08 (file operations), E09 (SCM lanes) and E11 (MCP server
//! SDK) call. Each builds a `ToolRequest` and returns the engine's
//! decision, so every consumer goes through `Engine.decide` (INV-01).
//!
//! zg_mcp (layer 4) cannot import zg_security (also layer 4); the layer-5
//! host that builds zigguro's MCP servers wraps `mcpServerAuthorizer` into
//! zg_mcp's `Server.Authorizer` (identical field layout: a context and a
//! `decide(ctx, principal, operation, target)` returning allow or deny).

const std = @import("std");
const contracts = @import("../contracts.zig");
const Engine = @import("engine.zig").Engine;

/// A command an agent wants to run in a terminal.
pub const CommandRequest = struct {
    cmd: []const u8,
    cwd: []const u8,
    terminal: ?u64 = null,
    agent_id: []const u8,
    session: []const u8 = "",
    shell: contracts.Shell = .posix,
    mode: contracts.PermissionMode = .default,
    workspace: ?[]const u8 = null,
    kind: Kind = .shell_run,

    /// How the command reaches the terminal.
    pub const Kind = enum { shell_run, exec, input };
};

/// Decides a terminal command (E06.F07 TerminalService). Raw `input`
/// without a trailing newline is not a command yet: E06 buffers it and
/// calls again; this returns allow for the partial line.
pub fn checkCommand(e: *Engine, req: CommandRequest) contracts.Decision {
    var text = req.cmd;
    if (req.kind == .input) {
        if (text.len == 0 or text[text.len - 1] != '\n') return .allow;
        text = std.mem.trimEnd(u8, text, "\r\n");
    }
    const res = [_]contracts.Resource{.{ .command = .{ .text = text, .cwd = req.cwd, .shell = req.shell } }};
    const tr: contracts.ToolRequest = .{
        .actor = .{ .agent = .{ .session = if (req.session.len > 0) req.session else req.agent_id, .agent = req.agent_id } },
        .tool = "run_command",
        .input_json = text,
        .effects = .{ .executes = true },
        .resources = &res,
        .mode = req.mode,
        .workspace = req.workspace,
    };
    return e.decide(&tr);
}

/// SCM lane actions (E09.F03).
pub const ScmAction = enum { rewrite, push, land, write_path, op_restore, sign, rewrite_immutable };

/// An SCM decision: asks become a review.
pub const ScmDecision = union(enum) { allow, deny: []const u8, needs_review: contracts.ApprovalTicket };

/// E09.F03's lane `PolicyHook` shape.
pub const ScmPolicyHook = struct {
    ctx: *anyopaque,
    check: *const fn (*anyopaque, actor: contracts.Actor, action: ScmAction, paths: []const []const u8) ScmDecision,
};

/// Most paths one SCM or file-ops check carries in a single request.
pub const max_paths = 256;

/// The SCM hook: `scm(<action>)` plus one `edit_file` resource per touched
/// path, so protected paths in SCM writes ask too.
pub fn scmPolicyHook(e: *Engine) ScmPolicyHook {
    return .{ .ctx = e, .check = struct {
        fn f(ctx: *anyopaque, actor: contracts.Actor, action: ScmAction, paths: []const []const u8) ScmDecision {
            const self: *Engine = @ptrCast(@alignCast(ctx));
            if (paths.len + 1 > max_paths) return .{ .deny = "too many paths in one SCM operation" };
            var res: [max_paths]contracts.Resource = undefined;
            res[0] = .{ .scm = .{ .action = @tagName(action) } };
            for (paths, 1..) |p, i| res[i] = .{ .path = .{ .path = p, .access = .{ .write = true } } };
            const req: contracts.ToolRequest = .{
                .actor = actor,
                .tool = "scm",
                .input_json = @tagName(action),
                .effects = .{ .mutates_workspace = true, .destructive = action == .rewrite_immutable or action == .op_restore },
                .resources = res[0 .. paths.len + 1],
                .mode = .default,
            };
            return toScm(self.decide(&req));
        }
    }.f };
}

fn toScm(d: contracts.Decision) ScmDecision {
    return switch (d) {
        .allow => .allow,
        .deny => |m| .{ .deny = m },
        .ask => |t| .{ .needs_review = t },
    };
}

/// E11.F05's server-side principal check.
pub const McpAuthorizer = struct {
    ctx: *anyopaque,
    authorize: *const fn (*anyopaque, principal: contracts.Actor, method: []const u8, tool: ?[]const u8) contracts.Decision,
};

/// Methods of zigguro's own MCP servers that only read.
const read_methods = [_][]const u8{ "tools/list", "resources/list", "resources/read", "resources/templates/list", "prompts/list", "prompts/get", "ping", "server/discover" };

/// Maps `tools/call` on zigguro's own MCP servers to
/// `mcp__zigguro__<tool>`; listing and reading methods are read-only. An
/// `mcp_server` principal (an external client) is never trusted, so its
/// hints cannot relax a decision.
pub fn mcpAuthorizer(e: *Engine) McpAuthorizer {
    return .{ .ctx = e, .authorize = struct {
        fn f(ctx: *anyopaque, principal: contracts.Actor, method: []const u8, tool: ?[]const u8) contracts.Decision {
            const self: *Engine = @ptrCast(@alignCast(ctx));
            return authorizeMcp(self, principal, method, tool);
        }
    }.f };
}

fn authorizeMcp(e: *Engine, principal: contracts.Actor, method: []const u8, tool: ?[]const u8) contracts.Decision {
    for (read_methods) |m| if (std.mem.eql(u8, m, method)) return .allow;
    if (!std.mem.eql(u8, method, "tools/call")) {
        const req: contracts.ToolRequest = .{ .actor = principal, .tool = method, .input_json = method, .effects = .{}, .resources = &.{}, .mode = .default };
        return e.decide(&req);
    }
    const t = tool orelse return .{ .deny = "tools/call without a tool name" };
    var buf: [256]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "mcp__zigguro__{s}", .{t}) catch return .{ .deny = "tool name too long" };
    const res = [_]contracts.Resource{.{ .mcp_tool = .{ .server = "zigguro", .tool = t, .server_trusted = principal != .mcp_server } }};
    const req: contracts.ToolRequest = .{ .actor = principal, .tool = name, .input_json = t, .effects = .{}, .resources = &res, .mode = .default };
    return e.decide(&req);
}

/// zg_mcp's `Server.Decision` layout.
pub const McpServerDecision = union(enum) { allow, deny: []const u8 };

/// zg_mcp's `Server.Authorizer` layout, for the layer-5 host to wrap.
/// Principals are client identities (`mcp_server` actors). A server cannot
/// hold a request open for a human, so `ask` maps to deny with a message.
pub const McpServerAuthorizer = struct {
    ctx: ?*anyopaque,
    decide: *const fn (ctx: ?*anyopaque, principal: ?[]const u8, operation: []const u8, target: []const u8) McpServerDecision,
};

/// The engine as a zg_mcp-shaped authorizer.
pub fn mcpServerAuthorizer(e: *Engine) McpServerAuthorizer {
    return .{ .ctx = e, .decide = struct {
        fn f(ctx: ?*anyopaque, principal: ?[]const u8, operation: []const u8, target: []const u8) McpServerDecision {
            const self: *Engine = @ptrCast(@alignCast(ctx.?));
            const actor: contracts.Actor = .{ .mcp_server = principal orelse "anonymous" };
            const d = authorizeMcp(self, actor, operation, if (target.len > 0) target else null);
            return switch (d) {
                .allow => .allow,
                .deny => |m| .{ .deny = m },
                .ask => |t| blk: {
                    t.cancel();
                    break :blk .{ .deny = "requires approval in zigguro" };
                },
            };
        }
    }.f };
}

/// One file operation (E08.F03).
pub const FileOp = struct {
    kind: Kind,
    path: []const u8,
    /// Destination of a rename.
    to: ?[]const u8 = null,

    /// Operation kinds.
    pub const Kind = enum { create, write, rename, delete, read };
};

/// E08.F03's `FileOps.authorize` shape.
pub const FileOpsAuthorizer = struct {
    ctx: *anyopaque,
    authorize: *const fn (*anyopaque, actor: contracts.Actor, ops: []const FileOp) ScmDecision,
};

/// File operations as path resources; a rename is delete on `path` plus
/// create on `to`. The most restrictive result wins.
pub fn fileOpsAuthorizer(e: *Engine) FileOpsAuthorizer {
    return .{ .ctx = e, .authorize = struct {
        fn f(ctx: *anyopaque, actor: contracts.Actor, ops: []const FileOp) ScmDecision {
            const self: *Engine = @ptrCast(@alignCast(ctx));
            var res: [max_paths]contracts.Resource = undefined;
            var n: usize = 0;
            var mutates = false;
            for (ops) |op| {
                if (n + 2 > max_paths) return .{ .deny = "too many file operations in one request" };
                switch (op.kind) {
                    .read => res[n] = .{ .path = .{ .path = op.path, .access = .{ .read = true } } },
                    .create => res[n] = .{ .path = .{ .path = op.path, .access = .{ .create = true } } },
                    .write => res[n] = .{ .path = .{ .path = op.path, .access = .{ .write = true } } },
                    .delete => res[n] = .{ .path = .{ .path = op.path, .access = .{ .delete = true } } },
                    .rename => {
                        res[n] = .{ .path = .{ .path = op.path, .access = .{ .delete = true } } };
                        n += 1;
                        res[n] = .{ .path = .{ .path = op.to orelse return .{ .deny = "rename without a destination" }, .access = .{ .create = true } } };
                    },
                }
                mutates = mutates or op.kind != .read;
                n += 1;
            }
            const req: contracts.ToolRequest = .{
                .actor = actor,
                .tool = if (mutates) "edit_file" else "read_file",
                .input_json = "file_ops",
                .effects = .{ .mutates_workspace = mutates, .read_only = !mutates },
                .resources = res[0..n],
                .mode = .default,
            };
            return toScm(self.decide(&req));
        }
    }.f };
}

const eng = @import("engine.zig");
const fakes = @import("../testing/fakes.zig");

const H = struct {
    settings: eng.TestSettings = .{},
    port: fakes.FakeApprovalPort = .{ .gpa = std.testing.allocator },
    trust: fakes.StaticTrust = .{ .state = .trusted },
    e: *Engine = undefined,

    fn start(h: *H) !void {
        h.e = try Engine.init(std.testing.allocator, std.testing.io, .{
            .approvals = h.port.port(),
            .trust = h.trust.query(),
            .settings = h.settings.source(),
            .workspace_root = "/w",
            .home = "/home/u",
            .windows = false,
            .resolve_symlinks = false,
        });
    }

    fn stop(h: *H) void {
        h.e.deinit();
        h.port.deinit();
        h.settings.deinit();
    }
};

test "adapters: checkCommand compound command per-subcommand" {
    var h: H = .{};
    h.settings.layers[@intFromEnum(@import("rules.zig").Layer.user)] = &.{
        .{ .kind = .allow, .text = "run_command(git *)", .file = "u", .index = 0 },
        .{ .kind = .deny, .text = "run_command(git push --force*)", .file = "u", .index = 1 },
    };
    try h.start();
    defer h.stop();
    try std.testing.expect(checkCommand(h.e, .{ .cmd = "git status && git log", .cwd = "/w", .agent_id = "a" }) == .allow);
    try std.testing.expect(checkCommand(h.e, .{ .cmd = "git add . && git push --force origin", .cwd = "/w", .agent_id = "a" }).kind() == .deny);
    // Typed input decides only at the newline.
    try std.testing.expect(checkCommand(h.e, .{ .cmd = "rm -rf ", .cwd = "/w", .agent_id = "a", .kind = .input }) == .allow);
    try std.testing.expect(checkCommand(h.e, .{ .cmd = "rm -rf x\n", .cwd = "/w", .agent_id = "a", .kind = .input }) == .ask);
}

test "adapters: scm push to protected path asks → needs_review" {
    var h: H = .{};
    h.settings.layers[@intFromEnum(@import("rules.zig").Layer.user)] = &.{
        .{ .kind = .allow, .text = "scm", .file = "u", .index = 0 },
        .{ .kind = .allow, .text = "edit_file", .file = "u", .index = 1 },
    };
    try h.start();
    defer h.stop();
    const hook = scmPolicyHook(h.e);
    const actor: contracts.Actor = .{ .agent = .{ .session = "s", .agent = "a" } };
    try std.testing.expect(hook.check(hook.ctx, actor, .push, &.{"src/main.zig"}) == .allow);
    try std.testing.expect(hook.check(hook.ctx, actor, .write_path, &.{ "src/a.zig", ".git/hooks/post-merge" }) == .needs_review);
}

test "adapters: mcp authorizer untrusted principal" {
    var h: H = .{};
    try h.start();
    defer h.stop();
    const auth = mcpAuthorizer(h.e);
    try std.testing.expect(auth.authorize(auth.ctx, .{ .mcp_server = "client" }, "tools/list", null) == .allow);
    try std.testing.expect(auth.authorize(auth.ctx, .{ .mcp_server = "client" }, "tools/call", "search") == .ask);
    try std.testing.expectEqualStrings("mcp__zigguro__search", h.port.presented.items[0].rule_suggestion.?);
    const srv = mcpServerAuthorizer(h.e);
    try std.testing.expectEqualStrings("requires approval in zigguro", srv.decide(srv.ctx, "client", "tools/call", "search").deny);
    try std.testing.expect(srv.decide(srv.ctx, null, "resources/read", "file:///x") == .allow);
}

test "adapters: rename across workspace boundary asks" {
    var h: H = .{};
    h.settings.layers[@intFromEnum(@import("rules.zig").Layer.user)] = &.{.{ .kind = .allow, .text = "edit_file(./**)", .file = "u", .index = 0 }};
    try h.start();
    defer h.stop();
    const fo = fileOpsAuthorizer(h.e);
    const actor: contracts.Actor = .{ .agent = .{ .session = "s", .agent = "a" } };
    try std.testing.expect(fo.authorize(fo.ctx, actor, &.{.{ .kind = .rename, .path = "a.txt", .to = "b.txt" }}) == .allow);
    try std.testing.expect(fo.authorize(fo.ctx, actor, &.{.{ .kind = .rename, .path = "a.txt", .to = "/tmp/a.txt" }}) == .needs_review);
    try std.testing.expect(fo.authorize(fo.ctx, actor, &.{.{ .kind = .read, .path = "a.txt" }}) == .allow);
}
