//! Typed MCP requests, results and notifications for every supported
//! revision (2024-11-05 to 2026-07-28).
//!
//! One model covers all eras: members that exist only in some revisions are
//! optional, and members no revision of ours knows land in `extra`. Encoding
//! and decoding go through `codec` (camelCase, `_meta`, nulls omitted).
//! Results never carry `resultType` here: `codec.decodeResult` consumes it
//! and `codec.withResultType` writes it for modern peers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Stringify = std.json.Stringify;
const zg_jsonrpc = @import("zg_jsonrpc");
const codec = @import("codec.zig");
const ids = @import("ids.zig");
const meta = @import("meta.zig");
const content = @import("content.zig");
const capabilities = @import("capabilities.zig");

const RequestId = ids.RequestId;
const ProgressToken = ids.ProgressToken;
const RequestMeta = meta.RequestMeta;
const ResultMeta = meta.ResultMeta;
const NotificationMeta = meta.NotificationMeta;
const Capabilities = capabilities.Capabilities;
const ContentBlock = content.ContentBlock;
const Annotations = content.Annotations;
const Role = content.Role;

// ---------------------------------------------------------------- methods

/// Every request method of every supported revision.
pub const Method = enum {
    server_discover,
    initialize,
    ping,
    tools_list,
    tools_call,
    resources_list,
    resources_read,
    resources_templates_list,
    resources_subscribe,
    resources_unsubscribe,
    prompts_list,
    prompts_get,
    completion_complete,
    logging_set_level,
    subscriptions_listen,
    tasks_get,
    tasks_update,
    tasks_cancel,
    tasks_result,
    tasks_list,
    // Client-side methods: legacy server-to-client requests, modern `inputRequests`.
    sampling_create_message,
    elicitation_create,
    roots_list,

    const names = [_][]const u8{
        "server/discover",       "initialize",               "ping",
        "tools/list",            "tools/call",               "resources/list",
        "resources/read",        "resources/templates/list", "resources/subscribe",
        "resources/unsubscribe", "prompts/list",             "prompts/get",
        "completion/complete",   "logging/setLevel",         "subscriptions/listen",
        "tasks/get",             "tasks/update",             "tasks/cancel",
        "tasks/result",          "tasks/list",               "sampling/createMessage",
        "elicitation/create",    "roots/list",
    };

    comptime {
        std.debug.assert(names.len == @typeInfo(Method).@"enum".fields.len);
    }

    /// The method for a wire name, or null.
    pub fn fromString(s: []const u8) ?Method {
        for (names, 0..) |n, i| if (std.mem.eql(u8, n, s)) return @enumFromInt(i);
        return null;
    }

    /// The wire name, e.g. `"tools/call"`.
    pub fn string(m: Method) []const u8 {
        return names[@intFromEnum(m)];
    }

    /// Methods whose params carry `name` (`Mcp-Name` header, 2026-07-28).
    pub fn nameMember(m: Method) ?[]const u8 {
        return switch (m) {
            .tools_call, .prompts_get => "name",
            .resources_read, .resources_subscribe, .resources_unsubscribe => "uri",
            else => null,
        };
    }
};

// ---------------------------------------------------------------- common

/// Log severity (RFC 5424 levels).
pub const LoggingLevel = enum { debug, info, notice, warning, @"error", critical, alert, emergency };

/// Whether shared intermediaries may cache a result (2026-07-28).
pub const CacheScope = enum { public, private };

/// An icon for display. Decoded only; fetching and sanitizing is the UI's job.
pub const Icon = struct {
    /// Stored verbatim (URL or data: URI).
    src: []const u8,
    mime_type: ?[]const u8 = null,
    sizes: []const []const u8 = &.{},
    theme: ?Theme = null,
    extra: ?Value = null,

    /// The background an icon is designed for.
    pub const Theme = enum { light, dark };
};

/// Name and version of a client or server.
pub const Implementation = struct {
    name: []const u8,
    version: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    icons: []const Icon = &.{},
    website_url: ?[]const u8 = null,
    extra: ?Value = null,
};

/// A `{ "key": V, ... }` object kept in wire order.
pub fn Map(comptime V: type) type {
    return struct {
        const Self = @This();
        entries: []const Entry = &.{},

        /// One member.
        pub const Entry = struct { key: []const u8, value: V };

        /// The value for `key`, or null.
        pub fn get(m: Self, key: []const u8) ?V {
            for (m.entries) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
            return null;
        }

        /// Codec hook.
        pub fn jsonDecode(ctx: *codec.Ctx, v: Value) codec.DecodeError!Self {
            if (v != .object) return ctx.fail(error.TypeMismatch);
            const out = try ctx.arena.alloc(Entry, v.object.count());
            var it = v.object.iterator();
            var i: usize = 0;
            while (it.next()) |e| : (i += 1) {
                out[i] = .{ .key = e.key_ptr.*, .value = (try ctx.member(V, v.object, e.key_ptr.*)).? };
            }
            return .{ .entries = out };
        }

        /// Codec hook.
        pub fn jsonEncode(m: Self, s: *Stringify) Stringify.Error!void {
            try s.beginObject();
            for (m.entries) |e| {
                try s.objectField(e.key);
                try codec.encodeValue(s, e.value);
            }
            try s.endObject();
        }
    };
}

// ---------------------------------------------------------------- tools

/// Untrusted behaviour hints for a tool.
pub const ToolAnnotations = struct {
    title: ?[]const u8 = null,
    read_only_hint: ?bool = null,
    destructive_hint: ?bool = null,
    idempotent_hint: ?bool = null,
    open_world_hint: ?bool = null,
    extra: ?Value = null,
};

/// Task support of a tool (2025-11-25).
pub const ToolExecution = struct {
    task_support: ?TaskSupport = null,
    extra: ?Value = null,

    /// Whether a tool may, must or must not run as a task.
    pub const TaskSupport = enum { forbidden, optional, required };
};

/// A tool definition. `input_schema` / `output_schema` are raw JSON Schema,
/// compiled by `zg_mcp.schema`.
pub const Tool = struct {
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    input_schema: Value,
    output_schema: ?Value = null,
    annotations: ?ToolAnnotations = null,
    execution: ?ToolExecution = null,
    icons: []const Icon = &.{},
    meta: ?Value = null,
    extra: ?Value = null,
};

// ---------------------------------------------------------------- resources

/// A resource the server can read.
pub const Resource = struct {
    uri: []const u8,
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
    annotations: ?Annotations = null,
    size: ?i64 = null,
    icons: []const Icon = &.{},
    meta: ?Value = null,
    extra: ?Value = null,
};

/// A family of resources described by an RFC 6570 URI template.
pub const ResourceTemplate = struct {
    uri_template: []const u8,
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,
    annotations: ?Annotations = null,
    icons: []const Icon = &.{},
    meta: ?Value = null,
    extra: ?Value = null,
};

// ---------------------------------------------------------------- prompts

/// An argument a prompt accepts.
pub const PromptArgument = struct {
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    required: ?bool = null,
    extra: ?Value = null,
};

/// A prompt template.
pub const Prompt = struct {
    name: []const u8,
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,
    arguments: ?[]const PromptArgument = null,
    icons: []const Icon = &.{},
    meta: ?Value = null,
    extra: ?Value = null,
};

/// One message of a rendered prompt.
pub const PromptMessage = struct {
    role: Role,
    content: ContentBlock,
    extra: ?Value = null,
};

// ---------------------------------------------------------------- client features

/// A root directory or file the client exposes (deprecated in 2026-07-28).
pub const Root = struct {
    uri: []const u8,
    name: ?[]const u8 = null,
    meta: ?Value = null,
    extra: ?Value = null,
};

/// A model name hint for sampling.
pub const ModelHint = struct {
    name: ?[]const u8 = null,
    extra: ?Value = null,
};

/// The server's model preferences for sampling.
pub const ModelPreferences = struct {
    hints: ?[]const ModelHint = null,
    cost_priority: ?f64 = null,
    speed_priority: ?f64 = null,
    intelligence_priority: ?f64 = null,
    extra: ?Value = null,
};

/// How the model may use the tools offered in sampling.
pub const ToolChoice = struct {
    mode: ?Mode = null,
    extra: ?Value = null,

    /// `auto`, `required` or `none`.
    pub const Mode = enum { auto, required, none };
};

/// One message in a sampling conversation.
pub const SamplingMessage = struct {
    role: Role,
    content: content.SamplingContent,
    meta: ?Value = null,
    extra: ?Value = null,
};

/// `sampling/createMessage` params (deprecated in 2026-07-28).
pub const CreateMessageParams = struct {
    messages: []const SamplingMessage,
    model_preferences: ?ModelPreferences = null,
    system_prompt: ?[]const u8 = null,
    /// `none`, or the deprecated `thisServer` / `allServers`.
    include_context: ?[]const u8 = null,
    temperature: ?f64 = null,
    max_tokens: i64,
    stop_sequences: ?[]const []const u8 = null,
    metadata: ?Value = null,
    tools: ?[]const Tool = null,
    tool_choice: ?ToolChoice = null,
    meta: ?RequestMeta = null,
    extra: ?Value = null,
};

/// The client's answer to `sampling/createMessage`.
pub const CreateMessageResult = struct {
    role: Role,
    content: content.SamplingContent,
    model: []const u8,
    /// `endTurn`, `stopSequence`, `maxTokens`, `toolUse` or any other string.
    stop_reason: ?[]const u8 = null,
    meta: ?Value = null,
    extra: ?Value = null,
};

/// `roots/list` params.
pub const ListRootsParams = struct {
    meta: ?Value = null,
    extra: ?Value = null,
};

/// The client's answer to `roots/list`.
pub const ListRootsResult = struct {
    roots: []const Root,
    meta: ?Value = null,
    extra: ?Value = null,
};

/// The two kinds of elicitation.
pub const ElicitMode = enum { form, url };

/// `elicitation/create` params. `mode` absent means `form`.
pub const ElicitParams = struct {
    mode: ?ElicitMode = null,
    message: []const u8,
    /// Form mode: a restricted object schema of primitive properties.
    requested_schema: ?Value = null,
    /// URL mode: the page to open after consent.
    url: ?[]const u8 = null,
    /// URL mode, 2025-11-25 only (removed in 2026-07-28).
    elicitation_id: ?[]const u8 = null,
    meta: ?Value = null,
    extra: ?Value = null,

    /// The effective mode.
    pub fn kind(p: ElicitParams) ElicitMode {
        return p.mode orelse .form;
    }
};

/// The user's answer to an elicitation.
pub const ElicitResult = struct {
    action: Action,
    /// Form mode with `accept`: the submitted values.
    content: ?Value = null,
    meta: ?Value = null,
    extra: ?Value = null,

    /// What the user did.
    pub const Action = enum { accept, decline, cancel };
};

/// One entry of `inputRequests` (MRTR) or a legacy server-to-client request.
pub const InputRequest = union(enum) {
    sampling: CreateMessageParams,
    elicitation: ElicitParams,
    roots: ListRootsParams,
    unknown: struct { method: []const u8, params: ?Value },

    /// The request's method.
    pub fn method(r: InputRequest) []const u8 {
        return switch (r) {
            .sampling => Method.sampling_create_message.string(),
            .elicitation => Method.elicitation_create.string(),
            .roots => Method.roots_list.string(),
            .unknown => |u| u.method,
        };
    }

    /// Decodes from a method and its params.
    pub fn fromParts(ctx: *codec.Ctx, m: []const u8, params: ?Value) codec.DecodeError!InputRequest {
        const empty: Value = .{ .object = .empty };
        const p = params orelse empty;
        return switch (Method.fromString(m) orelse return .{ .unknown = .{ .method = m, .params = params } }) {
            .sampling_create_message => .{ .sampling = try ctx.decode(CreateMessageParams, p) },
            .elicitation_create => .{ .elicitation = try ctx.decode(ElicitParams, p) },
            .roots_list => .{ .roots = try ctx.decode(ListRootsParams, p) },
            else => .{ .unknown = .{ .method = m, .params = params } },
        };
    }

    /// Codec hook: `{ "method": ..., "params": ... }`.
    pub fn jsonDecode(ctx: *codec.Ctx, v: Value) codec.DecodeError!InputRequest {
        if (v != .object) return ctx.fail(error.TypeMismatch);
        const m = (try ctx.member([]const u8, v.object, "method")) orelse return ctx.missing("method");
        return fromParts(ctx, m, v.object.get("params"));
    }

    /// Codec hook.
    pub fn jsonEncode(r: InputRequest, s: *Stringify) Stringify.Error!void {
        try s.beginObject();
        try s.objectField("method");
        try s.write(r.method());
        switch (r) {
            .unknown => |u| if (u.params) |p| {
                try s.objectField("params");
                try s.write(p);
            },
            inline else => |p| {
                try s.objectField("params");
                try codec.encodeValue(s, p);
            },
        }
        try s.endObject();
    }
};

/// One entry of `inputResponses`. The wire shape is untagged; it is
/// classified by its members (`action`, `roots`, `model`).
pub const InputResponse = union(enum) {
    sampling: CreateMessageResult,
    elicitation: ElicitResult,
    roots: ListRootsResult,
    unknown: Value,

    /// Codec hook.
    pub fn jsonDecode(ctx: *codec.Ctx, v: Value) codec.DecodeError!InputResponse {
        if (v != .object) return ctx.fail(error.TypeMismatch);
        if (v.object.contains("action")) return .{ .elicitation = try ctx.decode(ElicitResult, v) };
        if (v.object.contains("roots")) return .{ .roots = try ctx.decode(ListRootsResult, v) };
        if (v.object.contains("model")) return .{ .sampling = try ctx.decode(CreateMessageResult, v) };
        return .{ .unknown = v };
    }

    /// Codec hook.
    pub fn jsonEncode(r: InputResponse, s: *Stringify) Stringify.Error!void {
        switch (r) {
            inline else => |p| try codec.encodeValue(s, p),
        }
    }
};

/// `inputRequests`: requests keyed by server-chosen ids.
pub const InputRequests = Map(InputRequest);
/// `inputResponses`: answers keyed by the same ids.
pub const InputResponses = Map(InputResponse);

// ---------------------------------------------------------------- tasks

/// Lifecycle states of a task.
pub const TaskStatus = enum { working, input_required, completed, failed, cancelled };

/// A task: 2025-11-25 core tasks and the 2026-07-28 tasks extension.
pub const Task = struct {
    task_id: []const u8,
    status: TaskStatus,
    status_message: ?[]const u8 = null,
    created_at: ?[]const u8 = null,
    last_updated_at: ?[]const u8 = null,
    /// Milliseconds, or JSON `null` for unlimited; kept raw to tell the two apart.
    ttl: ?Value = null,
    /// 2025-11-25.
    poll_interval: ?i64 = null,
    /// Tasks extension.
    poll_interval_ms: ?i64 = null,
    /// Tasks extension: input needed while `input_required`.
    input_requests: ?InputRequests = null,
    /// Tasks extension: the final result once `completed`.
    result: ?Value = null,
    /// Tasks extension: the JSON-RPC error once `failed`.
    @"error": ?Value = null,
    meta: ?Value = null,
    extra: ?Value = null,

    /// Whether the task can no longer change.
    pub fn isTerminal(t: Task) bool {
        return switch (t.status) {
            .completed, .failed, .cancelled => true,
            else => false,
        };
    }
};

/// `task` in task-augmented request params (2025-11-25).
pub const TaskMetadata = struct {
    ttl: ?i64 = null,
    extra: ?Value = null,
};

/// `io.modelcontextprotocol/related-task` in `_meta`.
pub const RelatedTask = struct {
    task_id: []const u8,
    extra: ?Value = null,
};

/// A task handle returned instead of a result. 2025-11-25 nests it as
/// `{ task: {...} }`; the 2026-07-28 extension sends the task members flat
/// with `resultType: "task"`. Both decode; `nested` keeps the wire shape.
pub const CreateTaskResult = struct {
    task: Task,
    nested: bool = true,
    meta: ?Value = null,

    /// Codec hook.
    pub fn jsonDecode(ctx: *codec.Ctx, v: Value) codec.DecodeError!CreateTaskResult {
        if (v != .object) return ctx.fail(error.TypeMismatch);
        if (v.object.get("task")) |t| {
            return .{
                .task = (try ctx.member(Task, v.object, "task")) orelse unreachable,
                .meta = if (v.object.get("_meta")) |m| m else null,
                .nested = t == .object,
            };
        }
        return .{ .task = try ctx.decodeSkipping(Task, v, "resultType"), .nested = false };
    }

    /// Codec hook.
    pub fn jsonEncode(r: CreateTaskResult, s: *Stringify) Stringify.Error!void {
        if (!r.nested) return codec.encodeTagged(s, r.task, "resultType", "task");
        try s.beginObject();
        try s.objectField("task");
        try codec.encodeValue(s, r.task);
        if (r.meta) |m| {
            try s.objectField("_meta");
            try s.write(m);
        }
        try s.endObject();
    }
};

// ---------------------------------------------------------------- request params

/// Params of requests with no members of their own (`server/discover`,
/// `ping`, ...).
pub const BaseParams = struct {
    meta: ?RequestMeta = null,
    extra: ?Value = null,
};

/// `initialize` params (legacy eras).
pub const InitializeParams = struct {
    protocol_version: []const u8,
    capabilities: Capabilities,
    client_info: Implementation,
    meta: ?RequestMeta = null,
    extra: ?Value = null,
};

/// Params of `*/list` requests.
pub const PaginatedParams = struct {
    cursor: ?[]const u8 = null,
    meta: ?RequestMeta = null,
    extra: ?Value = null,
};

/// `tools/call` params.
pub const CallToolParams = struct {
    name: []const u8,
    arguments: ?Value = null,
    input_responses: ?InputResponses = null,
    request_state: ?[]const u8 = null,
    /// 2025-11-25 task augmentation.
    task: ?TaskMetadata = null,
    meta: ?RequestMeta = null,
    extra: ?Value = null,
};

/// `resources/read` params.
pub const ReadResourceParams = struct {
    uri: []const u8,
    input_responses: ?InputResponses = null,
    request_state: ?[]const u8 = null,
    meta: ?RequestMeta = null,
    extra: ?Value = null,
};

/// `resources/subscribe` / `resources/unsubscribe` params (legacy eras).
pub const SubscribeParams = struct {
    uri: []const u8,
    meta: ?RequestMeta = null,
    extra: ?Value = null,
};

/// `prompts/get` params.
pub const GetPromptParams = struct {
    name: []const u8,
    /// String values only (PROMPTS).
    arguments: ?Value = null,
    input_responses: ?InputResponses = null,
    request_state: ?[]const u8 = null,
    meta: ?RequestMeta = null,
    extra: ?Value = null,
};

/// The prompt or resource template a completion is for.
pub const CompletionRef = struct {
    /// `ref/prompt` or `ref/resource`.
    type: []const u8,
    name: ?[]const u8 = null,
    title: ?[]const u8 = null,
    uri: ?[]const u8 = null,
    extra: ?Value = null,
};

/// `completion/complete` params.
pub const CompleteParams = struct {
    ref: CompletionRef,
    argument: struct { name: []const u8, value: []const u8, extra: ?Value = null },
    context: ?struct { arguments: ?Value = null, extra: ?Value = null } = null,
    meta: ?RequestMeta = null,
    extra: ?Value = null,
};

/// Which change notifications a `subscriptions/listen` stream carries.
pub const SubscriptionFilter = struct {
    tools_list_changed: ?bool = null,
    prompts_list_changed: ?bool = null,
    resources_list_changed: ?bool = null,
    resource_subscriptions: ?[]const []const u8 = null,
    extra: ?Value = null,
};

/// `subscriptions/listen` params (2026-07-28).
pub const SubscriptionsListenParams = struct {
    notifications: SubscriptionFilter,
    meta: ?RequestMeta = null,
    extra: ?Value = null,
};

/// `logging/setLevel` params (legacy eras).
pub const SetLevelParams = struct {
    level: LoggingLevel,
    meta: ?RequestMeta = null,
    extra: ?Value = null,
};

/// Params naming one task (`tasks/get`, `tasks/cancel`, `tasks/result`).
pub const TaskIdParams = struct {
    task_id: []const u8,
    meta: ?RequestMeta = null,
    extra: ?Value = null,
};

/// `tasks/update` params (tasks extension).
pub const TasksUpdateParams = struct {
    task_id: []const u8,
    input_responses: ?InputResponses = null,
    meta: ?RequestMeta = null,
    extra: ?Value = null,
};

// ---------------------------------------------------------------- results

/// A result with no members of its own.
pub const EmptyResult = struct {
    meta: ?ResultMeta = null,
    extra: ?Value = null,
};

/// `server/discover` result (2026-07-28).
pub const DiscoverResult = struct {
    supported_versions: []const []const u8,
    capabilities: Capabilities,
    instructions: ?[]const u8 = null,
    ttl_ms: ?i64 = null,
    cache_scope: ?CacheScope = null,
    meta: ?ResultMeta = null,
    extra: ?Value = null,
};

/// `initialize` result (legacy eras).
pub const InitializeResult = struct {
    protocol_version: []const u8,
    capabilities: Capabilities,
    server_info: Implementation,
    instructions: ?[]const u8 = null,
    meta: ?ResultMeta = null,
    extra: ?Value = null,
};

/// `tools/list` result.
pub const ListToolsResult = struct {
    tools: []const Tool,
    next_cursor: ?[]const u8 = null,
    ttl_ms: ?i64 = null,
    cache_scope: ?CacheScope = null,
    meta: ?ResultMeta = null,
    extra: ?Value = null,
};

/// `tools/call` result.
pub const CallToolResult = struct {
    content: []const ContentBlock,
    structured_content: ?Value = null,
    is_error: ?bool = null,
    meta: ?ResultMeta = null,
    extra: ?Value = null,
};

/// `resources/list` result.
pub const ListResourcesResult = struct {
    resources: []const Resource,
    next_cursor: ?[]const u8 = null,
    ttl_ms: ?i64 = null,
    cache_scope: ?CacheScope = null,
    meta: ?ResultMeta = null,
    extra: ?Value = null,
};

/// `resources/templates/list` result.
pub const ListResourceTemplatesResult = struct {
    resource_templates: []const ResourceTemplate,
    next_cursor: ?[]const u8 = null,
    ttl_ms: ?i64 = null,
    cache_scope: ?CacheScope = null,
    meta: ?ResultMeta = null,
    extra: ?Value = null,
};

/// `resources/read` result.
pub const ReadResourceResult = struct {
    contents: []const content.ResourceContents,
    ttl_ms: ?i64 = null,
    cache_scope: ?CacheScope = null,
    meta: ?ResultMeta = null,
    extra: ?Value = null,
};

/// `prompts/list` result.
pub const ListPromptsResult = struct {
    prompts: []const Prompt,
    next_cursor: ?[]const u8 = null,
    ttl_ms: ?i64 = null,
    cache_scope: ?CacheScope = null,
    meta: ?ResultMeta = null,
    extra: ?Value = null,
};

/// `prompts/get` result.
pub const GetPromptResult = struct {
    description: ?[]const u8 = null,
    messages: []const PromptMessage,
    meta: ?ResultMeta = null,
    extra: ?Value = null,
};

/// `completion/complete` result.
pub const CompleteResult = struct {
    completion: struct {
        values: []const []const u8,
        total: ?i64 = null,
        has_more: ?bool = null,
        extra: ?Value = null,
    },
    meta: ?ResultMeta = null,
    extra: ?Value = null,
};

/// `subscriptions/listen` final result; the subscription id is in `_meta`.
pub const SubscriptionsListenResult = struct {
    meta: ?ResultMeta = null,
    extra: ?Value = null,
};

/// An interim MRTR result: answer `input_requests` and retry the original
/// request with `inputResponses` and `requestState`.
pub const InputRequiredResult = struct {
    input_requests: ?InputRequests = null,
    /// Opaque, server-sealed; echoed verbatim.
    request_state: ?[]const u8 = null,
    meta: ?ResultMeta = null,
    extra: ?Value = null,
};

/// `tasks/list` result (2025-11-25).
pub const ListTasksResult = struct {
    tasks: []const Task,
    next_cursor: ?[]const u8 = null,
    meta: ?ResultMeta = null,
    extra: ?Value = null,
};

// ---------------------------------------------------------------- method table

/// The params type of request method `m`.
pub fn ParamsType(comptime m: Method) type {
    return switch (m) {
        .server_discover, .ping => BaseParams,
        .initialize => InitializeParams,
        .tools_list, .resources_list, .resources_templates_list, .prompts_list, .tasks_list => PaginatedParams,
        .tools_call => CallToolParams,
        .resources_read => ReadResourceParams,
        .resources_subscribe, .resources_unsubscribe => SubscribeParams,
        .prompts_get => GetPromptParams,
        .completion_complete => CompleteParams,
        .logging_set_level => SetLevelParams,
        .subscriptions_listen => SubscriptionsListenParams,
        .tasks_get, .tasks_cancel, .tasks_result => TaskIdParams,
        .tasks_update => TasksUpdateParams,
        .sampling_create_message => CreateMessageParams,
        .elicitation_create => ElicitParams,
        .roots_list => ListRootsParams,
    };
}

/// The (complete) result type of request method `m`.
pub fn ResultType(comptime m: Method) type {
    return switch (m) {
        .server_discover => DiscoverResult,
        .initialize => InitializeResult,
        .ping, .resources_subscribe, .resources_unsubscribe, .logging_set_level, .tasks_update => EmptyResult,
        .tools_list => ListToolsResult,
        .tools_call => CallToolResult,
        .resources_list => ListResourcesResult,
        .resources_read => ReadResourceResult,
        .resources_templates_list => ListResourceTemplatesResult,
        .prompts_list => ListPromptsResult,
        .prompts_get => GetPromptResult,
        .completion_complete => CompleteResult,
        .subscriptions_listen => SubscriptionsListenResult,
        .tasks_get, .tasks_cancel => Task,
        // `tasks/result` returns whatever the original request returns; every
        // member lands in `extra`.
        .tasks_result => EmptyResult,
        .tasks_list => ListTasksResult,
        .sampling_create_message => CreateMessageResult,
        .elicitation_create => ElicitResult,
        .roots_list => ListRootsResult,
    };
}

// ---------------------------------------------------------------- notifications

/// `notifications/cancelled` params.
pub const Cancelled = struct {
    /// Absent only for task cancellations in 2025-11-25.
    request_id: ?RequestId = null,
    reason: ?[]const u8 = null,
    meta: ?NotificationMeta = null,
    extra: ?Value = null,
};

/// `notifications/progress` params.
pub const Progress = struct {
    progress_token: ProgressToken,
    progress: f64,
    total: ?f64 = null,
    message: ?[]const u8 = null,
    meta: ?NotificationMeta = null,
    extra: ?Value = null,
};

/// `notifications/message` params.
pub const LogMessage = struct {
    level: LoggingLevel,
    logger: ?[]const u8 = null,
    data: Value,
    meta: ?NotificationMeta = null,
    extra: ?Value = null,
};

/// Params of notifications without members of their own (`*/list_changed`).
pub const NotificationParams = struct {
    meta: ?NotificationMeta = null,
    extra: ?Value = null,
};

/// `notifications/resources/updated` params.
pub const ResourceUpdated = struct {
    uri: []const u8,
    meta: ?NotificationMeta = null,
    extra: ?Value = null,
};

/// `notifications/subscriptions/acknowledged` params.
pub const SubscriptionsAcknowledged = struct {
    notifications: SubscriptionFilter,
    meta: ?NotificationMeta = null,
    extra: ?Value = null,
};

/// `notifications/elicitation/complete` params (2025-11-25 only).
pub const ElicitationComplete = struct {
    elicitation_id: []const u8,
    meta: ?NotificationMeta = null,
    extra: ?Value = null,
};

/// Any MCP notification. Unknown methods are preserved verbatim.
pub const Notification = union(enum) {
    initialized: NotificationParams,
    cancelled: Cancelled,
    progress: Progress,
    message: LogMessage,
    tools_list_changed: NotificationParams,
    prompts_list_changed: NotificationParams,
    resources_list_changed: NotificationParams,
    resources_updated: ResourceUpdated,
    subscriptions_acknowledged: SubscriptionsAcknowledged,
    roots_list_changed: NotificationParams,
    elicitation_complete: ElicitationComplete,
    /// `notifications/tasks/status` (2025-11-25).
    tasks_status: Task,
    /// `notifications/tasks` (tasks extension).
    tasks: Task,
    unknown: struct { method: []const u8, params: ?Value },

    const Tag = std.meta.Tag(Notification);
    const methods = std.enums.EnumArray(Tag, []const u8).init(.{
        .initialized = "notifications/initialized",
        .cancelled = "notifications/cancelled",
        .progress = "notifications/progress",
        .message = "notifications/message",
        .tools_list_changed = "notifications/tools/list_changed",
        .prompts_list_changed = "notifications/prompts/list_changed",
        .resources_list_changed = "notifications/resources/list_changed",
        .resources_updated = "notifications/resources/updated",
        .subscriptions_acknowledged = "notifications/subscriptions/acknowledged",
        .roots_list_changed = "notifications/roots/list_changed",
        .elicitation_complete = "notifications/elicitation/complete",
        .tasks_status = "notifications/tasks/status",
        .tasks = "notifications/tasks",
        .unknown = "",
    });

    /// The wire method.
    pub fn method(n: Notification) []const u8 {
        return switch (n) {
            .unknown => |u| u.method,
            else => methods.get(n),
        };
    }

    /// Decodes a notification from its method and params. Memory belongs
    /// to `arena`; `params` may be freed afterwards.
    pub fn decode(arena: Allocator, m: []const u8, params: ?zg_jsonrpc.message.RawJson, opts: codec.DecodeOptions) codec.DecodeError!Notification {
        const pv: ?Value = if (params) |p| try codec.parseValue(arena, p.bytes) else null;
        var ctx: codec.Ctx = .{ .arena = arena, .diag = opts.diag };
        return fromValue(&ctx, m, pv);
    }

    /// `decode` on parsed params.
    pub fn fromValue(ctx: *codec.Ctx, m: []const u8, params: ?Value) codec.DecodeError!Notification {
        const empty: Value = .{ .object = .empty };
        inline for (@typeInfo(Notification).@"union".fields) |f| {
            if (comptime std.mem.eql(u8, f.name, "unknown")) continue;
            if (std.mem.eql(u8, m, comptime methods.get(@field(Tag, f.name))))
                return @unionInit(Notification, f.name, try ctx.decode(f.type, params orelse empty));
        }
        return .{ .unknown = .{ .method = m, .params = params } };
    }

    /// Writes the notification as a JSON-RPC message.
    pub fn write(n: Notification, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (n) {
            .unknown => |u| try zg_jsonrpc.message.writeNotification(w, u.method, u.params),
            inline else => |p| try zg_jsonrpc.message.writeNotification(w, n.method(), codec.json(p)),
        }
    }
};

const testing = std.testing;

test "protocol: method names round trip" {
    for (std.enums.values(Method)) |m| try testing.expectEqual(m, Method.fromString(m.string()).?);
    try testing.expect(Method.fromString("tools/bogus") == null);
}

test "protocol: unknown notification preserved" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n = try Notification.decode(a, "notifications/com.example/thing", .{ .bytes = "{\"x\":[1,2]}" }, .{});
    try testing.expect(n == .unknown);
    var aw: std.Io.Writer.Allocating = .init(a);
    try n.write(&aw.writer);
    try testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/com.example/thing\",\"params\":{\"x\":[1,2]}}",
        aw.written(),
    );

    const p = try Notification.decode(a, "notifications/progress", .{ .bytes = "{\"progressToken\":\"t\",\"progress\":50,\"total\":100}" }, .{});
    try testing.expectEqual(@as(f64, 50), p.progress.progress);
    const l = try Notification.decode(a, "notifications/tools/list_changed", null, .{});
    try testing.expect(l == .tools_list_changed);
}

test "protocol: resultType absent => complete, unknown resultType => error" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try codec.decodeResult(CallToolResult, a, .{ .bytes = "{\"content\":[]}" }, .{});
    try testing.expect(r == .complete);
    const m = try codec.decodeResult(CallToolResult, a, .{ .bytes = "{\"resultType\":\"input_required\",\"requestState\":\"s\"}" }, .{});
    try testing.expectEqualStrings("s", m.input_required.request_state.?);
    try testing.expectError(error.InvalidResultType, codec.decodeResult(CallToolResult, a, .{ .bytes = "{\"resultType\":\"later\",\"content\":[]}" }, .{}));
    try testing.expectError(error.InvalidResultType, codec.decodeResult(CallToolResult, a, .{ .bytes = "{\"resultType\":\"task\",\"taskId\":\"t\",\"status\":\"working\"}" }, .{}));
    const t = try codec.decodeResult(CallToolResult, a, .{ .bytes = "{\"resultType\":\"task\",\"taskId\":\"t\",\"status\":\"working\"}" }, .{ .allow_task = true });
    try testing.expectEqualStrings("t", t.task.task.task_id);
    const legacy = try codec.decodeResult(CallToolResult, a, .{ .bytes = "{\"task\":{\"taskId\":\"u\",\"status\":\"working\",\"ttl\":null}}" }, .{ .allow_task = true });
    _ = legacy;
}

test "protocol: number_string preserved" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 2^64 + 1 does not fit i64 or f64 exactly.
    const src = "{\"content\":[],\"structuredContent\":{\"n\":18446744073709551617}}";
    const r = (try codec.decodeResult(CallToolResult, a, .{ .bytes = src }, .{})).complete;
    try testing.expectEqualStrings("18446744073709551617", r.structured_content.?.object.get("n").?.number_string);
    try testing.expectEqualStrings(src, try codec.encodeAlloc(a, r));
}

test "protocol: batch rejected" {
    try testing.expect(codec.isBatch("  [{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}]"));
    try testing.expect(!codec.isBatch("{\"jsonrpc\":\"2.0\"}"));
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try codec.writeBatchRejection(&w);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "-32600") != null);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\"id\":null") != null);
}

test "protocol: modern result carries resultType" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const r: CallToolResult = .{ .content = &.{ContentBlock.textBlock("ok")} };
    const s = try codec.encodeAlloc(arena.allocator(), codec.withResultType(.complete, r));
    try testing.expectEqualStrings("{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}", s);
}
