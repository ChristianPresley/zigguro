//! ZEP (zigguro extension protocol) message types, shared by the host
//! (`zg_config.zep`) and the extension SDK. Field names are camelCase to
//! match the JSON on the wire; parse with `ignore_unknown_fields = true` so
//! newer peers stay compatible. The normative description is
//! `packages/config/docs/zep.md`.

const std = @import("std");

/// The protocol version this build speaks (a date string).
pub const protocol_version = "2026-10";
/// Older versions the host still accepts.
pub const supported_versions = [_][]const u8{ protocol_version, "2026-07" };

/// Size limits every peer enforces.
pub const limits = struct {
    pub const max_message_bytes: usize = 16 << 20;
    pub const max_view_nodes: usize = 10_000;
    pub const max_decorations_per_document: usize = 5_000;
};

/// Method names, grouped by direction.
pub const methods = struct {
    // Lifecycle (either side may see these as in LSP).
    pub const initialize = "initialize";
    pub const initialized = "initialized";
    pub const shutdown = "shutdown";
    pub const exit = "exit";
    pub const cancel_request = "$/cancelRequest";
    pub const progress = "$/progress";

    // Host → extension.
    pub const activate = "activate";
    pub const command_execute = "command/execute";
    pub const view_resolve = "view/resolve";
    pub const view_resolve_children = "view/resolveChildren";
    pub const view_event = "view/event";
    pub const decorations_provide = "decorations/provide";
    pub const settings_did_change = "settings/didChange";
    pub const workspace_did_change_folders = "workspace/didChangeFolders";
    pub const document_did_open = "document/didOpen";
    pub const document_did_change = "document/didChange";
    pub const document_did_close = "document/didClose";

    // Extension → host.
    pub const commands_register = "commands/register";
    pub const commands_execute = "commands/execute";
    pub const window_show_message = "window/showMessage";
    pub const window_show_quick_pick = "window/showQuickPick";
    pub const window_show_input = "window/showInput";
    pub const window_set_status_item = "window/setStatusItem";
    pub const view_update = "view/update";
    pub const decorations_refresh = "decorations/refresh";
    pub const workspace_read_file = "workspace/readFile";
    pub const workspace_find_files = "workspace/findFiles";
    pub const workspace_apply_edit = "workspace/applyEdit";
    pub const settings_get = "settings/get";
    pub const storage_get = "storage/get";
    pub const storage_set = "storage/set";
    pub const ai_sample = "ai/sample";
    pub const secrets_get = "secrets/get";
    pub const log = "log";
};

/// Error codes: JSON-RPC reserved codes plus ZEP codes in −32000..−32099
/// and the LSP cancellation codes.
pub const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal = -32603,
    /// The extension lacks the permission the method needs (E16 grants).
    permission_denied = -32001,
    request_timeout = -32002,
    /// A request arrived before `initialized` or before `activate`.
    not_activated = -32003,
    content_modified = -32801,
    request_cancelled = -32800,
    _,

    /// The code as sent on the wire.
    pub fn int(c: ErrorCode) i32 {
        return @intFromEnum(c);
    }
};

/// A workspace folder.
pub const Folder = struct { uri: []const u8, name: []const u8 };

/// Permissions the user granted at install time (E16).
pub const Permissions = struct {
    /// Glob patterns the extension may read (`workspace/readFile`, `findFiles`).
    fsRead: []const []const u8 = &.{},
    /// Glob patterns the extension may edit (`workspace/applyEdit`).
    fsWrite: []const []const u8 = &.{},
    network: []const []const u8 = &.{},
    process: bool = false,
    aiSample: bool = false,
    secrets: []const []const u8 = &.{},
};

/// What the host offers.
pub const HostCapabilities = struct {
    views: bool = true,
    decorations: bool = true,
    quickPick: bool = true,
    statusItems: bool = true,
    aiSample: bool = false,
    positionEncodings: []const []const u8 = &.{ "utf-8", "utf-16" },
};

/// Params of `initialize` (host → extension).
pub const InitializeParams = struct {
    protocolVersion: []const u8,
    host: struct { name: []const u8, version: []const u8 },
    extension: struct { id: []const u8, root: []const u8, storageDir: []const u8, globalStorageDir: []const u8 },
    workspaceFolders: []const Folder = &.{},
    locale: []const u8 = "en",
    /// "utf-8" or "utf-16".
    positionEncoding: []const u8 = "utf-8",
    capabilities: HostCapabilities = .{},
    grantedPermissions: Permissions = .{},
};

/// What the extension implements.
pub const ExtCapabilities = struct {
    /// Receive `document/*` notifications.
    documentSync: bool = false,
    decorations: bool = false,
    /// View ids the extension resolves.
    views: []const []const u8 = &.{},
    /// Settings sections `settings/didChange` reports.
    configurationSections: []const []const u8 = &.{},
};

/// Result of `initialize`.
pub const InitializeResult = struct {
    protocolVersion: []const u8 = protocol_version,
    capabilities: ExtCapabilities = .{},
};

/// `activate` (notification): why the extension was started.
pub const ActivateParams = struct { event: []const u8 };

/// `command/execute` (host → ext) and `commands/execute` (ext → host).
pub const ExecuteCommandParams = struct { id: []const u8, args: ?std.json.Value = null };

/// One command an extension registers at runtime.
pub const CommandDecl = struct {
    id: []const u8,
    title: []const u8,
    category: ?[]const u8 = null,
    enablement: ?[]const u8 = null,
};

/// `commands/register`.
pub const RegisterCommandsParams = struct { commands: []const CommandDecl };

/// Message severity.
pub const Severity = enum { info, warning, @"error" };

/// `window/showMessage`; the result is the chosen action title or null.
pub const ShowMessageParams = struct {
    severity: Severity = .info,
    message: []const u8,
    actions: []const []const u8 = &.{},
};

/// One quick-pick item.
pub const QuickPickItem = struct { label: []const u8, description: ?[]const u8 = null, detail: ?[]const u8 = null };

/// `window/showQuickPick`; the result is the picked indices or null.
pub const ShowQuickPickParams = struct {
    items: []const QuickPickItem,
    options: struct { placeholder: ?[]const u8 = null, canPickMany: bool = false } = .{},
};

/// `window/showInput`; the result is the text or null.
pub const ShowInputParams = struct { prompt: []const u8, value: ?[]const u8 = null, password: bool = false };

/// `window/setStatusItem` (notification).
pub const StatusItemParams = struct {
    id: []const u8,
    text: []const u8,
    tooltip: ?[]const u8 = null,
    command: ?[]const u8 = null,
    priority: i32 = 0,
};

/// A position; `character` counts in the negotiated encoding.
pub const Position = struct { line: u32, character: u32 };
/// A half-open range.
pub const Range = struct { start: Position, end: Position };
/// One text replacement.
pub const TextEdit = struct { range: Range, newText: []const u8 };
/// Edits of one file.
pub const FileEdit = struct { uri: []const u8, edits: []const TextEdit };

/// `workspace/applyEdit`. Edits go through E13 changesets, so the user can
/// review and undo them as one step.
pub const ApplyEditParams = struct { label: []const u8, edits: []const FileEdit };
/// Result of `workspace/applyEdit`.
pub const ApplyEditResult = struct { changesetId: ?[]const u8 = null, applied: bool };

/// `workspace/readFile`; the result has `text` or `base64`.
pub const ReadFileParams = struct { uri: []const u8 };
/// Result of `workspace/readFile`.
pub const ReadFileResult = struct { text: ?[]const u8 = null, base64: ?[]const u8 = null };

/// `workspace/findFiles`; the result is a list of URIs.
pub const FindFilesParams = struct { glob: []const u8, exclude: ?[]const u8 = null, max: ?u32 = null };

/// `settings/get`; the result is the effective value (any JSON).
pub const SettingsGetParams = struct { section: []const u8, scopeUri: ?[]const u8 = null };
/// `settings/didChange` (notification).
pub const SettingsDidChangeParams = struct { sections: []const []const u8 };

/// Storage scope.
pub const StorageScope = enum { workspace, global };
/// `storage/get` / `storage/set`.
pub const StorageParams = struct { key: []const u8, value: ?std.json.Value = null, scope: StorageScope = .workspace };

/// One chat message for `ai/sample` (MCP sampling semantics).
pub const SampleMessage = struct { role: enum { user, assistant }, content: []const u8 };
/// `ai/sample`; needs the `aiSample` permission.
pub const SampleParams = struct {
    messages: []const SampleMessage,
    systemPrompt: ?[]const u8 = null,
    maxTokens: u32,
    modelHint: ?[]const u8 = null,
};
/// Result of `ai/sample`.
pub const SampleResult = struct { text: []const u8, stopReason: []const u8 };

/// `secrets/get`; the result is the secret or null.
pub const SecretParams = struct { name: []const u8 };

/// Log level of `log`.
pub const LogLevel = enum { trace, debug, info, warn, @"error" };
/// `log` (notification).
pub const LogParams = struct { level: LogLevel = .info, message: []const u8 };

/// `$/progress` (notification).
pub const ProgressParams = struct { token: std.json.Value, value: std.json.Value };

/// `view/resolve` / `view/resolveChildren`.
pub const ViewResolveParams = struct { viewId: []const u8, nodeId: ?[]const u8 = null };
/// One node of a view tree (vocabulary defined by E15.F06.S03).
pub const ViewNode = struct {
    id: []const u8,
    kind: []const u8 = "item",
    label: []const u8 = "",
    description: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    command: ?[]const u8 = null,
    collapsible: bool = false,
    children: []const ViewNode = &.{},
};
/// Result of `view/resolve`.
pub const ViewTree = struct { root: ViewNode };
/// `view/event` (notification).
pub const ViewEventParams = struct {
    viewId: []const u8,
    nodeId: []const u8,
    kind: enum { click, toggle, input, submit },
    value: ?std.json.Value = null,
};
/// `view/update` (notification).
pub const ViewUpdateParams = struct { viewId: []const u8, patch: std.json.Value };

/// `decorations/provide`.
pub const DecorationsParams = struct { uri: []const u8, version: i64, range: ?Range = null };
/// One decoration.
pub const Decoration = struct {
    range: Range,
    kind: enum { highlight, underline, gutter, inline_text } = .highlight,
    color: ?[]const u8 = null,
    text: ?[]const u8 = null,
    hover: ?[]const u8 = null,
};
/// `decorations/refresh` (notification).
pub const DecorationsRefreshParams = struct { uri: ?[]const u8 = null };

/// `document/didOpen`.
pub const DidOpenParams = struct { uri: []const u8, languageId: []const u8, version: i64, text: []const u8 };
/// `document/didChange` (full or ranged changes).
pub const DidChangeParams = struct {
    uri: []const u8,
    version: i64,
    changes: []const struct { range: ?Range = null, text: []const u8 },
};
/// `document/didClose`.
pub const DidCloseParams = struct { uri: []const u8 };

/// Whether `v` is a version the host accepts.
pub fn isSupported(v: []const u8) bool {
    for (supported_versions) |s| if (std.mem.eql(u8, s, v)) return true;
    return false;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn roundTrip(comptime T: type, json: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(T, arena.allocator(), json, .{ .ignore_unknown_fields = true });
    const out = try std.json.Stringify.valueAlloc(arena.allocator(), v, .{ .emit_null_optional_fields = false });
    const again = try std.json.parseFromSliceLeaky(T, arena.allocator(), out, .{});
    const out2 = try std.json.Stringify.valueAlloc(arena.allocator(), again, .{ .emit_null_optional_fields = false });
    try testing.expectEqualStrings(out, out2);
}

test "protocol: initialize params parse with defaults and unknown fields" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const json =
        \\{"protocolVersion":"2026-10","host":{"name":"zigguro","version":"0.1.0"},
        \\ "extension":{"id":"acme.hello","root":"/x","storageDir":"/s","globalStorageDir":"/g"},
        \\ "positionEncoding":"utf-16","future":42}
    ;
    const p = try std.json.parseFromSliceLeaky(InitializeParams, arena.allocator(), json, .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings("acme.hello", p.extension.id);
    try testing.expectEqualStrings("utf-16", p.positionEncoding);
    try testing.expect(!p.grantedPermissions.process);
    try testing.expect(isSupported(p.protocolVersion));
    try testing.expect(!isSupported("2025-01"));
}

test "protocol: round trips" {
    try roundTrip(ShowMessageParams,
        \\{"severity":"warning","message":"hi","actions":["Retry","Cancel"]}
    );
    try roundTrip(ApplyEditParams,
        \\{"label":"Fix","edits":[{"uri":"file:///a.zig","edits":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":3}},"newText":"pub"}]}]}
    );
    try roundTrip(ViewTree,
        \\{"root":{"id":"r","label":"Root","collapsible":true,"children":[{"id":"a","label":"A","command":"hello.say"}]}}
    );
    try roundTrip(ExecuteCommandParams,
        \\{"id":"hello.say","args":{"name":"x","n":[1,2]}}
    );
    try roundTrip(ViewEventParams,
        \\{"viewId":"v","nodeId":"n","kind":"submit","value":"text"}
    );
    try roundTrip(SampleParams,
        \\{"messages":[{"role":"user","content":"hi"}],"maxTokens":64}
    );
}

test "protocol: error codes" {
    try testing.expectEqual(@as(i32, -32601), ErrorCode.method_not_found.int());
    try testing.expectEqual(@as(i32, -32001), ErrorCode.permission_denied.int());
    try testing.expectEqual(@as(i32, -32800), ErrorCode.request_cancelled.int());
}
