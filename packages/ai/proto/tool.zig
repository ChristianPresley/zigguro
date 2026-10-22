//! Tool contract shared by every tool exporter (E05–E09, E11) and the E10
//! tool system. `ToolSpec` keeps the E07/E08 field prefix (`name`,
//! `description`, `input_schema_json`, `read_only`, `handler`); every later
//! field has a default so their struct literals keep compiling.

const std = @import("std");
const message = @import("message.zig");
const agent_ref = @import("agent_ref.zig");

/// Tool result content part (same type as in messages).
pub const ResultPart = message.ResultPart;

/// What a tool may do to the world; drives scheduling and permissions.
pub const Effects = packed struct(u8) {
    read_only: bool = false,
    writes_workspace: bool = false,
    executes: bool = false,
    network: bool = false,
    open_world: bool = false,
    idempotent: bool = false,
    _pad: u2 = 0,
};

/// Coarse permission class used by E07 exporters.
pub const PermissionClass = enum { read, control, execute };

/// Where a tool comes from.
pub const Origin = union(enum) {
    builtin,
    /// An MCP server, by configured name.
    mcp: []const u8,
    /// A plugin or extension, by id.
    extension: []const u8,
};

/// How the UI should render a tool's output.
pub const UiHint = enum { plain, code, diff, terminal, markdown, json };

/// Reference to an E12 changeset produced by a tool.
pub const ChangeSetRef = struct { id: u64 };

/// Errors a handler may return. Anything a model can fix should instead be
/// an `is_error` output.
pub const ToolError = error{ Canceled, OutOfMemory, Timeout, Unavailable, Failed };

/// Streams partial output (e.g. a command's live tail) while a tool runs.
pub const ProgressSink = struct {
    ctx: *anyopaque,
    emit: *const fn (ctx: *anyopaque, text: []const u8) void,
};

/// One invocation of a tool.
pub const ToolCall = struct {
    /// Provider tool_use id.
    id: []const u8,
    name: []const u8,
    /// Canonical JSON text of the input object.
    input_json: []const u8,
    /// The parsed input; valid for the call.
    input: std.json.Value,
    /// Arena that lives until the tool result is recorded.
    arena: std.mem.Allocator,
    io: std.Io,
    agent: agent_ref.AgentRef = .{ .session = 0 },
    progress: ?ProgressSink = null,
};

/// Calls a tool. `ctx` is the exporter's state.
pub const ToolHandler = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, c: *ToolCall) ToolError!ToolOutput,
};

/// A provider's own (server) tool, such as Anthropic `web_search`.
pub const Native = struct {
    provider: message.ProviderId,
    /// The tool's declaration, sent to that provider verbatim.
    json: []const u8,
};

/// Declares one tool.
pub const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    input_schema_json: []const u8,
    read_only: bool,
    handler: ToolHandler,
    effects: Effects = .{},
    permission: PermissionClass = .read,
    output_schema_json: ?[]const u8 = null,
    /// Loaded only when found through `tool_search`.
    defer_loading: bool = false,
    origin: Origin = .builtin,
    /// Set for a provider's own tool: declared only to models of that
    /// provider, run by the provider, never by the handler.
    native: ?Native = null,

    /// Effects with `read_only` folded in.
    pub fn effectiveEffects(s: ToolSpec) Effects {
        var e = s.effects;
        if (s.read_only) e.read_only = true;
        return e;
    }
};

/// What a tool returns.
pub const ToolOutput = struct {
    parts: []const ResultPart,
    is_error: bool = false,
    structured_json: ?[]const u8 = null,
    changeset: ?ChangeSetRef = null,
    truncated: bool = false,
    ui_hint: UiHint = .plain,

    /// A single-text-part output.
    pub fn text(arena: std.mem.Allocator, s: []const u8, is_error: bool) !ToolOutput {
        const parts = try arena.alloc(ResultPart, 1);
        parts[0] = .{ .text = s };
        return .{ .parts = parts, .is_error = is_error };
    }
};

test "E07-style ToolSpec literal compiles unchanged" {
    const S = struct {
        fn call(_: *anyopaque, c: *ToolCall) ToolError!ToolOutput {
            return ToolOutput.text(c.arena, "ok", false) catch error.OutOfMemory;
        }
    };
    var dummy: u8 = 0;
    // Copied from E07.F05.S01.T03 (lsp tool specs).
    const spec: ToolSpec = .{
        .name = "lsp_definition",
        .description = "Go to definition",
        .input_schema_json = "{\"type\":\"object\"}",
        .read_only = true,
        .permission = .read,
        .handler = .{ .ctx = &dummy, .call = S.call },
    };
    try std.testing.expect(spec.effectiveEffects().read_only);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var c: ToolCall = .{ .id = "1", .name = spec.name, .input_json = "{}", .input = .null, .arena = arena.allocator(), .io = std.testing.io };
    const out = try spec.handler.call(spec.handler.ctx, &c);
    try std.testing.expectEqualStrings("ok", out.parts[0].text);
}
