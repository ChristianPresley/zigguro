//! The provider-neutral request and response, and capability-driven
//! degradation (`adaptForCaps`).

const std = @import("std");
const proto = @import("zg_ai_proto");
const Capabilities = @import("capabilities.zig").Capabilities;
const RateLimitSnapshot = @import("events.zig").RateLimitSnapshot;

const Message = proto.Message;

/// An HTTP header (name, value).
pub const Header = std.http.Header;

/// One section of the system prompt.
pub const SystemPart = struct {
    text: []const u8,
    /// Place a cache breakpoint after this part.
    cache_break: bool = false,
    /// False for parts that change every turn (environment, reminders).
    stable: bool = true,
};

/// Extended thinking settings.
pub const Thinking = union(enum) { off, budget: u32, adaptive };

/// Reasoning effort hint.
pub const Effort = enum { low, medium, high, max };

/// How the model must use tools.
pub const ToolChoice = union(enum) { auto, any, none, tool: []const u8 };

/// A tool as declared to the provider.
pub const ToolDecl = struct {
    name: []const u8,
    description: []const u8,
    input_schema_json: []const u8,
    /// Place a cache breakpoint after this tool (normally the last one).
    cache_break: bool = false,
    strict: bool = false,
    defer_loading: bool = false,
    /// `provider_native` tools (e.g. Anthropic `web_search`) are passed
    /// through verbatim from `raw_json` by the provider that owns them.
    kind: enum { function, provider_native } = .function,
    raw_json: ?[]const u8 = null,
};

/// How `t` is declared to a model of `provider`: its native declaration
/// for its own provider, nothing for other providers, else a function.
pub fn declFor(t: *const proto.ToolSpec, provider: proto.ProviderId) ?ToolDecl {
    if (t.native) |n| {
        if (n.provider != provider) return null;
        return .{ .name = t.name, .description = t.description, .input_schema_json = t.input_schema_json, .kind = .provider_native, .raw_json = n.json };
    }
    return .{ .name = t.name, .description = t.description, .input_schema_json = t.input_schema_json, .defer_loading = t.defer_loading };
}

/// Cache time-to-live of explicit breakpoints.
pub const CacheTtl = enum { m5, h1 };

/// Where explicit cache breakpoints go (system parts and tools carry their
/// own `cache_break`).
pub const CachePlan = struct {
    ttl: CacheTtl = .m5,
    /// Indices into `Request.messages`; the breakpoint goes on the last
    /// cacheable block of each.
    message_breaks: []const u32 = &.{},

    /// True when any breakpoint is requested.
    pub fn any(p: CachePlan, req: *const Request) bool {
        if (p.message_breaks.len > 0) return true;
        for (req.system) |s| if (s.cache_break) return true;
        for (req.tools) |t| if (t.cache_break) return true;
        return false;
    }
};

/// One model request.
pub const Request = struct {
    model: []const u8,
    system: []const SystemPart = &.{},
    messages: []const Message,
    tools: []const ToolDecl = &.{},
    tool_choice: ToolChoice = .auto,
    parallel_tools: bool = true,
    max_output_tokens: u32 = 8192,
    thinking: Thinking = .off,
    effort: ?Effort = null,
    stop_sequences: []const []const u8 = &.{},
    temperature: ?f32 = null,
    cache: CachePlan = .{},
    output_schema_json: ?[]const u8 = null,
    metadata_user_id: ?[]const u8 = null,
    extra_headers: []const Header = &.{},
    /// Merged into the top-level request body by providers that support it.
    extra_body_json: ?[]const u8 = null,
    /// Resolved API key or bearer token for this request (see `KeyRef`).
    api_key: ?[]const u8 = null,
};

/// The assembled result of one `Provider.stream` call.
pub const Response = struct {
    message: Message,
    stop: proto.StopReason,
    usage: proto.Usage,
    request_id: ?[]const u8 = null,
    rate_limit: ?RateLimitSnapshot = null,
    /// The output limit cut a tool_use block, which was dropped.
    truncated_tool_use: bool = false,
};

/// Degradation notices produced by `adaptForCaps`.
pub const Warnings = struct {
    items: [8][]const u8 = undefined,
    len: u8 = 0,

    /// Records `w` (drops it if full).
    pub fn add(ws: *Warnings, w: []const u8) void {
        if (ws.len < ws.items.len) {
            ws.items[ws.len] = w;
            ws.len += 1;
        }
    }

    /// The recorded warnings.
    pub fn slice(ws: *const Warnings) []const []const u8 {
        return ws.items[0..ws.len];
    }
};

/// Default thinking budget when adaptive thinking falls back to budgets.
pub const default_thinking_budget: u32 = 8192;

/// Placeholder that replaces images for providers without vision.
pub const image_omitted = "[image omitted: provider lacks vision]";
/// Placeholder that replaces PDFs for providers without document input.
pub const document_omitted = "[document omitted: provider lacks document input]";

/// Adjusts `req` in place for `caps`, recording what changed in `warn`.
/// Messages are rewritten into `arena` only when blocks must be replaced.
pub fn adaptForCaps(arena: std.mem.Allocator, req: *Request, caps: Capabilities, warn: *Warnings) std.mem.Allocator.Error!void {
    if (!caps.tools and req.tools.len > 0) {
        req.tools = &.{};
        req.tool_choice = .auto;
        warn.add("tools removed: provider has no tool support");
    }
    if (req.parallel_tools and !caps.parallel_tools) {
        req.parallel_tools = false;
        warn.add("parallel tool calls disabled");
    }
    if (!caps.forced_tool_choice) switch (req.tool_choice) {
        .any, .tool => {
            req.tool_choice = .auto;
            warn.add("forced tool choice downgraded to auto");
        },
        else => {},
    };
    switch (req.thinking) {
        .off => {},
        .adaptive => if (!caps.thinking_adaptive) {
            if (caps.thinking_budget) {
                req.thinking = .{ .budget = default_thinking_budget };
                warn.add("adaptive thinking mapped to a fixed budget");
            } else {
                req.thinking = .off;
                warn.add("thinking ignored: unsupported");
            }
        },
        .budget => if (!caps.thinking_budget) {
            if (caps.thinking_adaptive) {
                req.thinking = .adaptive;
                warn.add("thinking budget mapped to adaptive thinking");
            } else {
                req.thinking = .off;
                warn.add("thinking ignored: unsupported");
            }
        },
    }
    if (!caps.cache_explicit and req.cache.any(req)) {
        req.cache.message_breaks = &.{};
        if (hasBreak(req.system, req.tools)) {
            const sys = try arena.dupe(SystemPart, req.system);
            for (sys) |*s| s.cache_break = false;
            req.system = sys;
            const tools = try arena.dupe(ToolDecl, req.tools);
            for (tools) |*t| t.cache_break = false;
            req.tools = tools;
        }
        warn.add("cache breakpoints cleared: no explicit caching");
    }
    if (req.output_schema_json != null and !caps.structured_output) {
        req.output_schema_json = null;
        warn.add("structured output dropped: unsupported");
    }
    if (!caps.strict_tools) {
        var strict = false;
        for (req.tools) |t| strict = strict or t.strict;
        if (strict) {
            const tools = try arena.dupe(ToolDecl, req.tools);
            for (tools) |*t| t.strict = false;
            req.tools = tools;
            warn.add("strict tool schemas disabled");
        }
    }
    if (!caps.image_input or !caps.pdf_input) {
        if (try stripMedia(arena, req.messages, caps)) |msgs| {
            req.messages = msgs;
            warn.add(if (!caps.image_input) "images replaced with placeholders" else "documents replaced with placeholders");
        }
    }
}

fn hasBreak(sys: []const SystemPart, tools: []const ToolDecl) bool {
    for (sys) |s| if (s.cache_break) return true;
    for (tools) |t| if (t.cache_break) return true;
    return false;
}

fn needsStrip(b: proto.ContentBlock, caps: Capabilities) bool {
    return switch (b) {
        .image => !caps.image_input,
        .document => |d| !caps.pdf_input and std.mem.eql(u8, d.media_type, "application/pdf"),
        .tool_result => |t| for (t.parts) |p| {
            switch (p) {
                .image => if (!caps.image_input) break true,
                .document => |d| if (!caps.pdf_input and std.mem.eql(u8, d.media_type, "application/pdf")) break true,
                else => {},
            }
        } else false,
        else => false,
    };
}

fn stripMedia(arena: std.mem.Allocator, msgs: []const Message, caps: Capabilities) !?[]const Message {
    var any = false;
    for (msgs) |m| for (m.content) |b| {
        if (needsStrip(b, caps)) any = true;
    };
    if (!any) return null;
    const out = try arena.alloc(Message, msgs.len);
    for (msgs, out) |m, *o| {
        o.* = m;
        var changed = false;
        for (m.content) |b| changed = changed or needsStrip(b, caps);
        if (!changed) continue;
        const blocks = try arena.alloc(proto.ContentBlock, m.content.len);
        for (m.content, blocks) |b, *nb| {
            nb.* = switch (b) {
                .image => if (!caps.image_input) .{ .text = .{ .text = image_omitted } } else b,
                .document => |d| if (!caps.pdf_input and std.mem.eql(u8, d.media_type, "application/pdf")) .{ .text = .{ .text = document_omitted } } else b,
                .tool_result => |t| blk: {
                    const parts = try arena.alloc(proto.ResultPart, t.parts.len);
                    for (t.parts, parts) |p, *np| np.* = switch (p) {
                        .image => if (!caps.image_input) .{ .text = image_omitted } else p,
                        .document => |d| if (!caps.pdf_input and std.mem.eql(u8, d.media_type, "application/pdf")) .{ .text = document_omitted } else p,
                        else => p,
                    };
                    break :blk .{ .tool_result = .{ .tool_use_id = t.tool_use_id, .parts = parts, .is_error = t.is_error } };
                },
                else => b,
            };
        }
        o.content = blocks;
    }
    return out;
}

const testing = std.testing;

test "adapt_for_caps_table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const img_msg = [_]Message{.{ .role = .user, .content = &.{
        .{ .text = .{ .text = "look" } },
        .{ .image = .{ .media_type = "image/png", .data = .{ .base64 = "AA==" } } },
        .{ .document = .{ .media_type = "application/pdf", .data = .{ .base64 = "AA==" } } },
    } }};
    const tools = [_]ToolDecl{.{ .name = "t", .description = "", .input_schema_json = "{}", .cache_break = true, .strict = true }};
    const base: Request = .{ .model = "m", .messages = &img_msg, .tools = &tools };
    const Case = struct { caps: Capabilities, edit: *const fn (*Request) void, check: *const fn (Request) bool, warns: u8 };
    const noop = struct {
        fn f(_: *Request) void {}
    }.f;
    const cases = [_]Case{
        // 1. everything supported: nothing changes
        .{ .caps = Capabilities.all, .edit = noop, .check = struct {
            fn f(r: Request) bool {
                return r.parallel_tools and r.tools[0].strict and r.messages[0].content[1] == .image;
            }
        }.f, .warns = 0 },
        // 2. no parallel tools
        .{ .caps = c(.{ .parallel_tools = false }), .edit = noop, .check = struct {
            fn f(r: Request) bool {
                return !r.parallel_tools;
            }
        }.f, .warns = 1 },
        // 3. adaptive -> budget
        .{ .caps = c(.{ .thinking_adaptive = false }), .edit = struct {
            fn f(r: *Request) void {
                r.thinking = .adaptive;
            }
        }.f, .check = struct {
            fn f(r: Request) bool {
                return r.thinking == .budget and r.thinking.budget == default_thinking_budget;
            }
        }.f, .warns = 1 },
        // 4. adaptive -> off
        .{ .caps = c(.{ .thinking_adaptive = false, .thinking_budget = false }), .edit = struct {
            fn f(r: *Request) void {
                r.thinking = .adaptive;
            }
        }.f, .check = struct {
            fn f(r: Request) bool {
                return r.thinking == .off;
            }
        }.f, .warns = 1 },
        // 5. budget -> adaptive
        .{ .caps = c(.{ .thinking_budget = false }), .edit = struct {
            fn f(r: *Request) void {
                r.thinking = .{ .budget = 1024 };
            }
        }.f, .check = struct {
            fn f(r: Request) bool {
                return r.thinking == .adaptive;
            }
        }.f, .warns = 1 },
        // 6. budget -> off
        .{ .caps = c(.{ .thinking_budget = false, .thinking_adaptive = false }), .edit = struct {
            fn f(r: *Request) void {
                r.thinking = .{ .budget = 1024 };
            }
        }.f, .check = struct {
            fn f(r: Request) bool {
                return r.thinking == .off;
            }
        }.f, .warns = 1 },
        // 7. no explicit cache: breakpoints cleared
        .{ .caps = c(.{ .cache_explicit = false }), .edit = struct {
            fn f(r: *Request) void {
                r.cache.message_breaks = &.{0};
            }
        }.f, .check = struct {
            fn f(r: Request) bool {
                return r.cache.message_breaks.len == 0 and !r.tools[0].cache_break;
            }
        }.f, .warns = 1 },
        // 8. no vision: image placeholder, PDF kept
        .{ .caps = c(.{ .image_input = false }), .edit = noop, .check = struct {
            fn f(r: Request) bool {
                return r.messages[0].content[1] == .text and std.mem.eql(u8, r.messages[0].content[1].text.text, image_omitted) and r.messages[0].content[2] == .document;
            }
        }.f, .warns = 1 },
        // 9. no PDF input
        .{ .caps = c(.{ .pdf_input = false }), .edit = noop, .check = struct {
            fn f(r: Request) bool {
                return r.messages[0].content[1] == .image and r.messages[0].content[2] == .text;
            }
        }.f, .warns = 1 },
        // 10. no strict tools
        .{ .caps = c(.{ .strict_tools = false }), .edit = noop, .check = struct {
            fn f(r: Request) bool {
                return !r.tools[0].strict;
            }
        }.f, .warns = 1 },
        // 11. no forced tool choice
        .{ .caps = c(.{ .forced_tool_choice = false }), .edit = struct {
            fn f(r: *Request) void {
                r.tool_choice = .{ .tool = "t" };
            }
        }.f, .check = struct {
            fn f(r: Request) bool {
                return r.tool_choice == .auto;
            }
        }.f, .warns = 1 },
        // 12. no tools at all; structured output unsupported
        .{ .caps = c(.{ .tools = false, .structured_output = false }), .edit = struct {
            fn f(r: *Request) void {
                r.output_schema_json = "{}";
            }
        }.f, .check = struct {
            fn f(r: Request) bool {
                return r.tools.len == 0 and r.output_schema_json == null;
            }
        }.f, .warns = 2 },
    };
    for (cases, 0..) |cs, i| {
        var r = base;
        cs.edit(&r);
        var w: Warnings = .{};
        try adaptForCaps(a, &r, cs.caps, &w);
        testing.expect(cs.check(r)) catch |e| {
            std.debug.print("case {d} failed\n", .{i + 1});
            return e;
        };
        try testing.expectEqual(cs.warns, w.len);
    }
    // The input request is never mutated through shared slices.
    try testing.expect(tools[0].cache_break and img_msg[0].content[1] == .image);
}

fn c(comptime off: anytype) Capabilities {
    var caps = Capabilities.all;
    inline for (std.meta.fields(@TypeOf(off))) |f| @field(caps, f.name) = @field(off, f.name);
    return caps;
}
