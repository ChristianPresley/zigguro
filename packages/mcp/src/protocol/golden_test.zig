//! `protocol: golden round-trip`: every `testdata/protocol/<Type>.<name>.json`
//! (copied verbatim from the MCP specification; the sibling `.src` file
//! records where) decodes into its Zig type and re-encodes to the same JSON.

const std = @import("std");
const options = @import("zg_options");
const codec = @import("codec.zig");
const M = @import("messages.zig");
const content = @import("content.zig");
const capabilities = @import("capabilities.zig");
const errors = @import("errors.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// How a golden file is shaped.
const Shape = enum {
    /// A bare value of the given type.
    plain,
    /// A bare result (resultType dispatched).
    result,
    /// A JSON-RPC request; params typed by method.
    request,
    /// A JSON-RPC success response with a result of the given type.
    response,
    /// A JSON-RPC notification.
    notification,
    /// A JSON-RPC error response; `data` typed when given.
    error_response,
};

/// Golden type name -> (Zig type, shape). Names absent here fail the test.
const table = .{
    .{ "AudioContent", content.ContentBlock, .plain },
    .{ "ImageContent", content.ContentBlock, .plain },
    .{ "TextContent", content.ContentBlock, .plain },
    .{ "ResourceLink", content.ContentBlock, .plain },
    .{ "EmbeddedResource", content.ContentBlock, .plain },
    .{ "ToolUseContent", content.ContentBlock, .plain },
    .{ "ToolResultContent", content.ContentBlock, .plain },
    .{ "BlobResourceContents", content.ResourceContents, .plain },
    .{ "TextResourceContents", content.ResourceContents, .plain },
    .{ "BooleanSchema", Value, .plain },
    .{ "NumberSchema", Value, .plain },
    .{ "StringSchema", Value, .plain },
    .{ "TitledMultiSelectEnumSchema", Value, .plain },
    .{ "TitledSingleSelectEnumSchema", Value, .plain },
    .{ "UntitledMultiSelectEnumSchema", Value, .plain },
    .{ "UntitledSingleSelectEnumSchema", Value, .plain },
    .{ "ClientCapabilities", capabilities.Capabilities, .plain },
    .{ "ServerCapabilities", capabilities.Capabilities, .plain },
    .{ "InputRequests", M.InputRequests, .plain },
    .{ "InputResponses", M.InputResponses, .plain },
    .{ "ModelPreferences", M.ModelPreferences, .plain },
    .{ "Resource", M.Resource, .plain },
    .{ "Root", M.Root, .plain },
    .{ "SamplingMessage", M.SamplingMessage, .plain },
    .{ "Tool", M.Tool, .plain },
    .{ "CallToolRequestParams", M.CallToolParams, .plain },
    .{ "CancelledNotificationParams", M.Cancelled, .plain },
    .{ "CompleteRequestParams", M.CompleteParams, .plain },
    .{ "CreateMessageRequestParams", M.CreateMessageParams, .plain },
    .{ "ElicitRequestFormParams", M.ElicitParams, .plain },
    .{ "ElicitRequestURLParams", M.ElicitParams, .plain },
    .{ "GetPromptRequestParams", M.GetPromptParams, .plain },
    .{ "LoggingMessageNotificationParams", M.LogMessage, .plain },
    .{ "PaginatedRequestParams", M.PaginatedParams, .plain },
    .{ "ProgressNotificationParams", M.Progress, .plain },
    .{ "ResourceUpdatedNotificationParams", M.ResourceUpdated, .plain },
    .{ "CallToolResult", M.CallToolResult, .result },
    .{ "CompleteResult", M.CompleteResult, .result },
    .{ "CreateMessageResult", M.CreateMessageResult, .result },
    .{ "DiscoverResult", M.DiscoverResult, .result },
    .{ "ElicitResult", M.ElicitResult, .result },
    .{ "GetPromptResult", M.GetPromptResult, .result },
    .{ "InputRequiredResult", M.EmptyResult, .result },
    .{ "ListPromptsResult", M.ListPromptsResult, .result },
    .{ "ListResourceTemplatesResult", M.ListResourceTemplatesResult, .result },
    .{ "ListResourcesResult", M.ListResourcesResult, .result },
    .{ "ListRootsResult", M.ListRootsResult, .result },
    .{ "ListToolsResult", M.ListToolsResult, .result },
    .{ "ReadResourceResult", M.ReadResourceResult, .result },
    .{ "SubscriptionsListenResult", M.SubscriptionsListenResult, .result },
    .{ "CallToolRequest", void, .request },
    .{ "CompleteRequest", void, .request },
    .{ "CreateMessageRequest", void, .request },
    .{ "DiscoverRequest", void, .request },
    .{ "ElicitRequest", void, .request },
    .{ "GetPromptRequest", void, .request },
    .{ "ListPromptsRequest", void, .request },
    .{ "ListResourceTemplatesRequest", void, .request },
    .{ "ListResourcesRequest", void, .request },
    .{ "ListRootsRequest", void, .request },
    .{ "ListToolsRequest", void, .request },
    .{ "ReadResourceRequest", void, .request },
    .{ "SubscriptionsListenRequest", void, .request },
    .{ "CallToolResultResponse", M.CallToolResult, .response },
    .{ "CompleteResultResponse", M.CompleteResult, .response },
    .{ "DiscoverResultResponse", M.DiscoverResult, .response },
    .{ "GetPromptResultResponse", M.GetPromptResult, .response },
    .{ "ListPromptsResultResponse", M.ListPromptsResult, .response },
    .{ "ListResourceTemplatesResultResponse", M.ListResourceTemplatesResult, .response },
    .{ "ListResourcesResultResponse", M.ListResourcesResult, .response },
    .{ "ListToolsResultResponse", M.ListToolsResult, .response },
    .{ "ReadResourceResultResponse", M.ReadResourceResult, .response },
    .{ "SubscriptionsListenResultResponse", M.SubscriptionsListenResult, .response },
    .{ "CancelledNotification", void, .notification },
    .{ "LoggingMessageNotification", void, .notification },
    .{ "ProgressNotification", void, .notification },
    .{ "PromptListChangedNotification", void, .notification },
    .{ "ResourceListChangedNotification", void, .notification },
    .{ "ResourceUpdatedNotification", void, .notification },
    .{ "SubscriptionsAcknowledgedNotification", void, .notification },
    .{ "ToolListChangedNotification", void, .notification },
    .{ "HeaderMismatchError", void, .error_response },
    .{ "InternalError", void, .error_response },
    .{ "InvalidParamsError", void, .error_response },
    .{ "MethodNotFoundError", void, .error_response },
    .{ "ParseError", void, .error_response },
    .{ "MissingRequiredClientCapabilityError", errors.MissingRequiredClientCapabilityData, .error_response },
    .{ "UnsupportedProtocolVersionError", errors.UnsupportedProtocolVersionData, .error_response },
};

/// Re-encodes golden `src` of type `name`; the caller compares.
fn roundTrip(arena: Allocator, name: []const u8, src: Value) !Value {
    inline for (table) |row| {
        if (std.mem.eql(u8, name, row[0])) return roundTripAs(arena, row[1], row[2], src);
    }
    std.debug.print("golden type {s} has no entry in golden_test.zig\n", .{name});
    return error.UnknownGoldenType;
}

fn roundTripAs(arena: Allocator, comptime T: type, comptime shape: Shape, src: Value) !Value {
    var diag: codec.Diagnostic = .{};
    errdefer std.debug.print("decode failed at {s}\n", .{diag.pointer()});
    const opts: codec.DecodeOptions = .{ .diag = &diag, .allow_task = true };
    switch (shape) {
        .plain => return codec.toValue(arena, try codec.decodeFromValue(T, arena, src, opts)),
        .result => return resultValue(arena, T, src, opts),
        .request => {
            var out = try envelope(arena, src);
            const method = src.object.get("method").?.string;
            const m = M.Method.fromString(method) orelse return error.UnknownMethod;
            if (src.object.get("params")) |p| {
                const typed = switch (m) {
                    inline else => |mm| try codec.toValue(arena, try codec.decodeFromValue(M.ParamsType(mm), arena, p, opts)),
                };
                try out.object.put(arena, "params", typed);
            }
            return out;
        },
        .response => {
            var out = try envelope(arena, src);
            try out.object.put(arena, "result", try resultValue(arena, T, src.object.get("result").?, opts));
            return out;
        },
        .notification => {
            var ctx: codec.Ctx = .{ .arena = arena, .diag = &diag };
            const n = try M.Notification.fromValue(&ctx, src.object.get("method").?.string, src.object.get("params"));
            if (n == .unknown) return error.UnknownNotification;
            var aw: std.Io.Writer.Allocating = .init(arena);
            try n.write(&aw.writer);
            var v = try codec.parseValue(arena, aw.written());
            // Notifications without params re-encode `{}`; goldens omit them.
            if (src.object.get("params") == null) {
                const p = v.object.get("params").?;
                if (p.object.count() == 0) _ = v.object.orderedRemove("params");
            }
            return v;
        },
        .error_response => {
            // Some goldens are the bare `error` object.
            const err_v = src.object.get("error") orelse {
                const e = try codec.decodeFromValue(errors.ErrorObject, arena, src, opts);
                return codec.toValue(arena, e);
            };
            var out = try envelope(arena, src);
            const e = try codec.decodeFromValue(errors.ErrorObject, arena, err_v, opts);
            if (T != void) _ = try codec.decodeFromValue(T, arena, e.data.?, opts);
            try out.object.put(arena, "error", try codec.toValue(arena, e));
            return out;
        },
    }
}

/// Re-encodes a result, restoring `resultType` when the golden had it.
fn resultValue(arena: Allocator, comptime T: type, src: Value, opts: codec.DecodeOptions) !Value {
    const had_type = src.object.get("resultType") != null;
    const d = try codec.decodeResultValue(T, arena, src, opts);
    return switch (d) {
        inline else => |r, kind| if (had_type)
            codec.toValue(arena, codec.withResultType(kind, r))
        else
            codec.toValue(arena, r),
    };
}

/// A copy of the JSON-RPC envelope members other than params/result/error.
fn envelope(arena: Allocator, src: Value) !Value {
    var out: std.json.ObjectMap = .empty;
    var it = src.object.iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        if (std.mem.eql(u8, k, "params") or std.mem.eql(u8, k, "result") or std.mem.eql(u8, k, "error")) continue;
        try out.put(arena, k, e.value_ptr.*);
    }
    return .{ .object = out };
}

test "protocol: golden round-trip" {
    const io = testing.io;
    const gpa = testing.allocator;
    var root = try std.Io.Dir.openDirAbsolute(io, options.package_root, .{});
    defer root.close(io);
    var dir = try root.openDir(io, "testdata/protocol", .{ .iterate = true });
    defer dir.close(io);

    var count: usize = 0;
    var failures: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        count += 1;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const bytes = try dir.readFileAlloc(io, entry.name, a, .limited(1 << 20));
        const type_name = entry.name[0..std.mem.indexOfScalar(u8, entry.name, '.').?];
        const src_name = try std.fmt.allocPrint(a, "{s}.src", .{entry.name[0 .. entry.name.len - ".json".len]});
        _ = dir.statFile(io, src_name, .{}) catch {
            std.debug.print("{s}: missing sibling .src file\n", .{entry.name});
            failures += 1;
            continue;
        };
        const want = try codec.parseValue(a, bytes);
        const got = roundTrip(a, type_name, want) catch |err| {
            std.debug.print("{s}: {s}\n", .{ entry.name, @errorName(err) });
            failures += 1;
            continue;
        };
        if (!codec.jsonEql(want, got)) {
            std.debug.print("{s}: round trip differs\n  got: {s}\n", .{ entry.name, try std.json.Stringify.valueAlloc(a, got, .{}) });
            failures += 1;
        }
    }
    try testing.expect(count >= 60);
    try testing.expectEqual(@as(usize, 0), failures);
}
