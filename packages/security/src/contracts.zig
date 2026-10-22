//! Shared security contracts (E16.F01): the small set of types every
//! consumer epic (E01, E06–E12) builds against. This file imports only
//! `std`, so depending on it never compiles the engine, sandbox or secrets
//! code. Every slice is borrowed from the caller for the duration of a call;
//! nothing here allocates.

const std = @import("std");

/// How much the human has delegated for a session (E16.F02.S01.T03).
pub const PermissionMode = enum {
    /// Ask for anything without an allow rule.
    default,
    /// Workspace edits are allowed; commands and network still follow rules.
    accept_edits,
    /// Read-only: anything with effects is denied.
    plan,
    /// Never prompt: every final `ask` becomes `deny`.
    dont_ask,
    /// Allow everything that is not denied by a rule or managed policy.
    bypass,
};

/// An agent identity inside a harness session.
pub const AgentRef = struct {
    session: []const u8,
    agent: []const u8,
    parent: ?[]const u8 = null,
};

/// Who asked for an action.
pub const Actor = union(enum) {
    /// A human, by user name.
    human: []const u8,
    agent: AgentRef,
    /// A connected MCP server, by configured name.
    mcp_server: []const u8,
    system,

    /// Writes `human:<name>`, `agent:<session>/<agent>`, `mcp:<name>` or `system`.
    pub fn format(a: Actor, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (a) {
            .human => |h| try w.print("human:{s}", .{h}),
            .agent => |g| try w.print("agent:{s}/{s}", .{ g.session, g.agent }),
            .mcp_server => |s| try w.print("mcp:{s}", .{s}),
            .system => try w.writeAll("system"),
        }
    }
};

/// File access wanted on a path resource.
pub const Access = packed struct(u8) {
    read: bool = false,
    write: bool = false,
    create: bool = false,
    delete: bool = false,
    exec: bool = false,
    _pad: u3 = 0,

    /// True when any of write, create or delete is set.
    pub fn mutates(a: Access) bool {
        return a.write or a.create or a.delete;
    }
};

/// What a tool call may do, declared by the tool's handler.
pub const Effects = packed struct(u8) {
    read_only: bool = false,
    mutates_workspace: bool = false,
    executes: bool = false,
    network: bool = false,
    destructive: bool = false,
    _pad: u3 = 0,

    /// True when the call has no effect beyond reading.
    pub fn isReadOnly(e: Effects) bool {
        return !e.mutates_workspace and !e.executes and !e.network and !e.destructive;
    }
};

/// A UI side effect requested by untrusted content or an agent.
pub const UiAction = union(enum) {
    open_uri: []const u8,
    clipboard_read,
    /// Bytes about to be written to the clipboard.
    clipboard_write: usize,
    /// Count of control characters in a paste.
    paste_control_chars: usize,
};

/// The shell dialect a command is written in.
pub const Shell = enum { posix, bash, zsh, fish, pwsh, cmd };

/// One thing a tool call touches. A request lists every resource it uses.
pub const Resource = union(enum) {
    path: struct { path: []const u8, access: Access },
    command: struct { text: []const u8, cwd: []const u8, shell: Shell = .posix },
    url: struct { url: []const u8, method: []const u8 = "GET" },
    mcp_tool: struct {
        server: []const u8,
        tool: []const u8,
        read_only_hint: ?bool = null,
        destructive_hint: ?bool = null,
        server_trusted: bool = false,
    },
    scm: struct { action: []const u8, lane: ?[]const u8 = null },
    ui: UiAction,
    /// A secret's name, never its value.
    secret: []const u8,
};

/// A tool call to authorize.
pub const ToolRequest = struct {
    actor: Actor,
    tool: []const u8,
    input_json: []const u8,
    effects: Effects,
    resources: []const Resource,
    mode: PermissionMode,
    /// Absolute workspace root, when the call is scoped to one.
    workspace: ?[]const u8 = null,
};

/// The engine's answer for a request.
pub const Decision = union(enum) {
    allow,
    /// A human- and model-readable reason naming the rule and its layer.
    deny: []const u8,
    /// The request waits on a human; await the ticket.
    ask: ApprovalTicket,

    /// Writes `allow`, `deny: <reason>` or `ask #<id>`.
    pub fn format(d: Decision, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (d) {
            .allow => try w.writeAll("allow"),
            .deny => |r| try w.print("deny: {s}", .{r}),
            .ask => |t| try w.print("ask #{d}", .{t.id}),
        }
    }

    /// The decision without its payload.
    pub fn kind(d: Decision) Kind {
        return switch (d) {
            .allow => .allow,
            .deny => .deny,
            .ask => .ask,
        };
    }

    /// A decision tag.
    pub const Kind = enum { allow, ask, deny };
};

/// A human's answer to an approval request.
pub const Answer = union(enum) {
    allow_once,
    /// Allow for the rest of the session; payload is the rule to add.
    allow_session: []const u8,
    /// Allow from now on; payload is the rule to persist.
    allow_always: []const u8,
    /// Reject, with feedback for the model.
    deny: []const u8,
    /// Approve an edited input (e.g. a rewritten command).
    edit: []const u8,

    /// The simplified view used by E06 terminals.
    pub const Simple = enum { approved, rejected, edited };

    /// Collapses the answer into approved, rejected or edited.
    pub fn simple(a: Answer) Simple {
        return switch (a) {
            .allow_once, .allow_session, .allow_always => .approved,
            .deny => .rejected,
            .edit => .edited,
        };
    }
};

/// What kind of approval card to show.
pub const ApprovalKind = enum { command, tool_call, mcp_tool, network, file_outside_workspace, scm_action, plan, ui, other };

/// Everything an approval surface needs to render a request.
pub const ApprovalRequest = struct {
    kind: ApprovalKind,
    actor: Actor,
    title: []const u8,
    detail_json: []const u8,
    command: ?[]const u8 = null,
    risk: []const []const u8 = &.{},
    rule_suggestion: ?[]const u8 = null,
    editable: bool = false,
    created_ms: i64,
};

/// Where approvals are presented and answered. E12.F05's `ApprovalBroker`
/// implements it; tests use `testing.FakeApprovalPort`.
pub const ApprovalPort = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    /// The port's operations.
    pub const VTable = struct {
        /// Shows the request; returns its id.
        present: *const fn (*anyopaque, ApprovalRequest) anyerror!u64,
        /// Blocks the calling task until the human answers.
        await: *const fn (*anyopaque, id: u64, io: std.Io) std.Io.Cancelable!Answer,
        /// Withdraws a pending request.
        cancel: *const fn (*anyopaque, id: u64) void,
    };

    /// Presents `req` and returns a ticket for its answer.
    pub fn present(p: ApprovalPort, req: ApprovalRequest) anyerror!ApprovalTicket {
        return .{ .id = try p.vtable.present(p.ctx, req), .port = p };
    }
};

/// A pending approval.
pub const ApprovalTicket = struct {
    id: u64,
    port: ApprovalPort,

    /// Waits for the human's answer.
    pub fn await(t: ApprovalTicket, io: std.Io) std.Io.Cancelable!Answer {
        return t.port.vtable.await(t.port.ctx, t.id, io);
    }

    /// Withdraws the request.
    pub fn cancel(t: ApprovalTicket) void {
        t.port.vtable.cancel(t.port.ctx, t.id);
    }
};

/// Replaces secrets in `text` (in place or by appending to `out`) and
/// returns the number of replacements. E06 shape.
pub const Redactor = struct {
    ctx: *anyopaque,
    redact: *const fn (*anyopaque, text: []u8, out: *std.ArrayList(u8)) u32,
};

/// Says whether a path is a secret file and why (E08 shape). Null means
/// not denied.
pub const DenyPolicy = struct {
    ctx: *anyopaque,
    isDenied: *const fn (*anyopaque, path: []const u8) ?[]const u8,
};

/// A folder's workspace-trust state (E16.F07).
pub const TrustState = enum { trusted, restricted, unknown };

/// Looks up the trust state of an absolute path.
pub const TrustQuery = struct {
    ctx: *anyopaque,
    stateOf: *const fn (*anyopaque, abs_path: []const u8) TrustState,
};

/// The record type written to the audit log.
pub const AuditRecord = @import("audit/record.zig").AuditRecord;

/// Receives audit records; must not block (the log buffers).
pub const AuditSink = struct {
    ctx: *anyopaque,
    append: *const fn (*anyopaque, rec: *const AuditRecord) void,
};

/// The verdict of the URI policy.
pub const UriVerdict = enum { allow, ask, deny };

/// Where an "open link" request came from.
pub const UriOrigin = enum { user_click, agent_tool, terminal_osc8, markdown_render, mcp_content, notification };

/// Decides whether a URI may be opened (E16.F05.S02.T01).
pub const UriPolicy = struct {
    ctx: *anyopaque,
    check: *const fn (*anyopaque, uri: []const u8, origin: UriOrigin) UriVerdict,
};

/// Kinds of untrusted content that taint a session (E16.F02.S04.T01).
pub const TaintSource = enum { web, mcp_untrusted, untrusted_file, terminal_output, lsp_text };

test "contracts: decision formatting golden" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print("{f}|{f}", .{ @as(Decision, .allow), Decision{ .deny = "Access to .env is denied by policy rule `Read(.env*)` (user settings)" } });
    try std.testing.expectEqualStrings("allow|deny: Access to .env is denied by policy rule `Read(.env*)` (user settings)", w.buffered());
}

test "contracts: actor formatting" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.print("{f} {f}", .{ Actor{ .agent = .{ .session = "s1", .agent = "main" } }, Actor{ .mcp_server = "fs" } });
    try std.testing.expectEqualStrings("agent:s1/main mcp:fs", w.buffered());
}

test "contracts: answer simple view" {
    try std.testing.expectEqual(Answer.Simple.approved, (Answer{ .allow_session = "Bash(ls)" }).simple());
    try std.testing.expectEqual(Answer.Simple.rejected, (Answer{ .deny = "no" }).simple());
    try std.testing.expectEqual(Answer.Simple.edited, (Answer{ .edit = "ls -a" }).simple());
}

test "contracts: effects read-only" {
    try std.testing.expect((Effects{ .read_only = true }).isReadOnly());
    try std.testing.expect(!(Effects{ .network = true }).isReadOnly());
    try std.testing.expect((Access{ .delete = true }).mutates());
}

test "INV-01 compile-time: importing contracts does not import sandbox" {
    // contracts.zig and audit/record.zig may import only std and each other,
    // so a consumer that imports contracts never compiles engine, sandbox or
    // secrets code.
    const sources = [_]struct { src: []const u8, allowed: []const []const u8 }{
        .{ .src = @embedFile("contracts.zig"), .allowed = &.{ "std", "audit/record.zig" } },
        .{ .src = @embedFile("audit/record.zig"), .allowed = &.{"../contracts.zig"} },
    };
    const needle = "@" ++ "import(\"";
    for (sources) |s| {
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, s.src, i, needle)) |at| {
            const start = at + needle.len;
            const end = std.mem.indexOfScalarPos(u8, s.src, start, '"').?;
            const name = s.src[start..end];
            var ok = false;
            for (s.allowed) |a| ok = ok or std.mem.eql(u8, a, name);
            if (!ok) {
                std.debug.print("unexpected import {s}\n", .{name});
                return error.TestUnexpectedResult;
            }
            i = end;
        }
    }
}
