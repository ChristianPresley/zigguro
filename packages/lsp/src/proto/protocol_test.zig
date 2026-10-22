//! Tests for the generated protocol types (`gen/protocol.zig`) and their
//! JSON support (`json.zig`).

const std = @import("std");
const testing = std.testing;
const options = @import("zg_options");
const protocol = @import("../gen/protocol.zig");
const json = @import("json.zig");
const Value = std.json.Value;

/// Deep JSON equality; numbers compare by value.
fn valueEql(a: Value, b: Value) bool {
    const na = number(a);
    const nb = number(b);
    if (na != null or nb != null) return na != null and nb != null and na.? == nb.?;
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |x| x == b.bool,
        .string => |x| std.mem.eql(u8, x, b.string),
        .array => |x| blk: {
            if (x.items.len != b.array.items.len) break :blk false;
            for (x.items, b.array.items) |p, q| if (!valueEql(p, q)) break :blk false;
            break :blk true;
        },
        .object => |x| blk: {
            if (x.count() != b.object.count()) break :blk false;
            var it = x.iterator();
            while (it.next()) |e| {
                const other = b.object.get(e.key_ptr.*) orelse break :blk false;
                if (!valueEql(e.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
        else => unreachable,
    };
}

fn number(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// Parses `bytes` as `T`, re-encodes it and checks the result is
/// semantically equal to the input.
fn roundTrip(comptime T: type, gpa: std.mem.Allocator, name: []const u8, bytes: []const u8) !void {
    if (T == void) {
        std.debug.print("{s}: this message has no such payload\n", .{name});
        return error.BadName;
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const typed = json.parse(T, a, bytes) catch |err| {
        std.debug.print("{s}: decode as {s} failed: {t}\n", .{ name, @typeName(T), err });
        return err;
    };
    const out = try std.json.Stringify.valueAlloc(a, typed, .{});
    const want = try std.json.parseFromSliceLeaky(Value, a, bytes, .{});
    const got = try std.json.parseFromSliceLeaky(Value, a, out, .{});
    if (!valueEql(want, got)) {
        std.debug.print("{s}: round trip differs\n  in:  {s}\n  out: {s}\n", .{ name, std.mem.trim(u8, bytes, "\n"), out });
        return error.TestUnexpectedResult;
    }
}

const Kind = enum { params, result };

/// Decodes and round-trips one golden payload named
/// `<method with / as __>.<params|result>[.<variant>].json`.
fn checkFile(gpa: std.mem.Allocator, file: []const u8, bytes: []const u8) !void {
    var parts = std.mem.splitScalar(u8, file, '.');
    const method_part = parts.next().?;
    const kind = std.meta.stringToEnum(Kind, parts.next() orelse return error.BadName) orelse return error.BadName;
    var buf: [128]u8 = undefined;
    var method: std.ArrayList(u8) = .initBuffer(&buf);
    var rest = method_part;
    if (std.mem.startsWith(u8, rest, "dollar__")) {
        method.appendAssumeCapacity('$');
        method.appendAssumeCapacity('/');
        rest = rest["dollar__".len..];
    }
    var it = std.mem.splitSequence(u8, rest, "__");
    var first = true;
    while (it.next()) |seg| {
        if (!first) method.appendAssumeCapacity('/');
        method.appendSliceAssumeCapacity(seg);
        first = false;
    }
    if (protocol.method_names.get(method.items)) |m| {
        switch (m) {
            inline else => |cm| {
                const Info = protocol.RequestInfo(cm);
                return switch (kind) {
                    .params => roundTrip(Info.Params, gpa, file, bytes),
                    .result => roundTrip(Info.Result, gpa, file, bytes),
                };
            },
        }
    }
    if (protocol.notification_names.get(method.items)) |m| {
        if (kind != .params) return error.BadName;
        switch (m) {
            inline else => |cm| return roundTrip(protocol.NotificationInfo(cm).Params, gpa, file, bytes),
        }
    }
    std.debug.print("{s}: unknown method {s}\n", .{ file, method.items });
    return error.BadName;
}

test "protocol: roundtrip golden" {
    const io = testing.io;
    var root = try std.Io.Dir.openDirAbsolute(io, options.package_root, .{});
    defer root.close(io);
    var dir = try root.openDir(io, "testdata/protocol", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".json")) continue;
        const bytes = try dir.readFileAlloc(io, e.name, testing.allocator, .limited(1 << 20));
        defer testing.allocator.free(bytes);
        try checkFile(testing.allocator, e.name, bytes);
        n += 1;
    }
    try testing.expect(n >= 20);
}

test "protocol: unknown fields are ignored" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const item = try json.parse(protocol.CompletionItem, arena.allocator(),
        \\{"label":"printf","score":0.9,"kind":3,"x-vendor":{"a":[1,2]}}
    );
    try testing.expectEqualStrings("printf", item.label);
    try testing.expectEqual(protocol.CompletionItemKind.Function, item.kind.?);
}

test "protocol: or-union discriminator table" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // HoverContents: object, string or array.
    const H = protocol.HoverContents;
    try testing.expect(try json.parse(H, a, "{\"kind\":\"plaintext\",\"value\":\"x\"}") == .markup_content);
    try testing.expect(try json.parse(H, a, "\"x\"") == .marked_string);
    try testing.expect(try json.parse(H, a, "{\"language\":\"c\",\"value\":\"x\"}") == .marked_string);
    try testing.expect(try json.parse(H, a, "[\"x\",{\"language\":\"c\",\"value\":\"y\"}]") == .marked_string_array);

    // CompletionItem[] | CompletionList | null.
    const C = protocol.RequestInfo(.@"textDocument/completion").Result;
    try testing.expect((try json.parse(C, a, "null")) == null);
    try testing.expect((try json.parse(C, a, "[]")).? == .completion_item_array);
    try testing.expect((try json.parse(C, a, "{\"isIncomplete\":false,\"items\":[]}")).? == .completion_list);

    // Definition | LocationLink[] | null, where Definition = Location | Location[].
    const D = protocol.RequestInfo(.@"textDocument/definition").Result;
    const loc = "{\"uri\":\"file:///a\",\"range\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}}}";
    const link = "{\"targetUri\":\"file:///a\",\"targetRange\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}},\"targetSelectionRange\":{\"start\":{\"line\":0,\"character\":0},\"end\":{\"line\":0,\"character\":1}}}";
    const d1 = (try json.parse(D, a, loc)).?;
    try testing.expect(d1 == .definition and d1.definition == .location);
    const d2 = (try json.parse(D, a, "[" ++ loc ++ "]")).?;
    try testing.expect(d2 == .definition and d2.definition == .location_array);
    const d3 = (try json.parse(D, a, "[" ++ link ++ "]")).?;
    try testing.expect(d3 == .definition_link_array);

    // TextDocumentEdit | CreateFile | RenameFile | DeleteFile: CreateFile and
    // DeleteFile have the same required keys and differ only in `kind`.
    const W = protocol.WorkspaceEditDocumentChangesItem;
    try testing.expect(try json.parse(W, a, "{\"kind\":\"create\",\"uri\":\"file:///n\"}") == .create_file);
    try testing.expect(try json.parse(W, a, "{\"kind\":\"delete\",\"uri\":\"file:///n\"}") == .delete_file);
    try testing.expect(try json.parse(W, a, "{\"kind\":\"rename\",\"oldUri\":\"file:///a\",\"newUri\":\"file:///b\"}") == .rename_file);
    try testing.expect(try json.parse(W, a, "{\"textDocument\":{\"uri\":\"file:///a\",\"version\":null},\"edits\":[]}") == .text_document_edit);
    try testing.expectError(error.UnexpectedToken, json.parse(W, a, "{\"kind\":\"move\",\"uri\":\"file:///n\"}"));
}

test "protocol: optional fields omitted, required nullable written" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const params: protocol.InitializeParams = .{ .processId = null, .rootUri = null, .capabilities = .{} };
    const out = try std.json.Stringify.valueAlloc(a, params, .{});
    try testing.expectEqualStrings("{\"processId\":null,\"rootUri\":null,\"capabilities\":{}}", out);
    const out2 = try json.stringifyAlloc(a, protocol.Position{ .line = 1, .character = 2 });
    try testing.expectEqualStrings("{\"line\":1,\"character\":2}", out2);
}

test "protocol: enums" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Integer enums are open and written as numbers.
    const k = try json.parse(protocol.CompletionItemKind, a, "99");
    try testing.expectEqual(@as(u32, 99), @intFromEnum(k));
    try testing.expectEqualStrings("99", try json.stringifyAlloc(a, k));
    try testing.expectEqualStrings("3", try json.stringifyAlloc(a, protocol.CompletionItemKind.Function));
    // Closed string enums map member names to wire values.
    try testing.expectEqual(protocol.MarkupKind.PlainText, try json.parse(protocol.MarkupKind, a, "\"plaintext\""));
    try testing.expectEqualStrings("\"markdown\"", try json.stringifyAlloc(a, protocol.MarkupKind.Markdown));
    try testing.expectError(error.InvalidEnumTag, json.parse(protocol.MarkupKind, a, "\"html\""));
    // Open string enums keep unknown values, including empty ones.
    const ck = try json.parse(protocol.CodeActionKind, a, "\"refactor.extract\"");
    try testing.expect(ck.is(.RefactorExtract));
    const other = try json.parse(protocol.CodeActionKind, a, "\"vendor.fix\"");
    try testing.expectEqualStrings("vendor.fix", other.other);
    try testing.expectEqualStrings("\"vendor.fix\"", try json.stringifyAlloc(a, other));
    try testing.expect((try json.parse(protocol.CodeActionKind, a, "\"\"")).is(.Empty));
}

test "protocol: method tables" {
    const Init = protocol.RequestInfo(.initialize);
    try testing.expect(Init.Params == protocol.InitializeParams);
    try testing.expect(Init.Result == protocol.InitializeResult);
    try testing.expectEqual(protocol.Direction.client_to_server, Init.direction);
    try testing.expectEqual(protocol.Method.@"textDocument/hover", protocol.method_names.get("textDocument/hover").?);
    try testing.expectEqual(protocol.NotificationMethod.@"textDocument/didOpen", protocol.notification_names.get("textDocument/didOpen").?);
    try testing.expectEqualStrings("3.18.0", protocol.meta_version);
    try testing.expectEqualStrings("3.16.0", protocol.RequestInfo(.@"textDocument/semanticTokens/full").since.?);
    try testing.expect(protocol.RequestInfo(.shutdown).Result == void);
    try testing.expect(protocol.RequestInfo(.@"workspace/configuration").direction == .server_to_client);
}

test "fuzz: lsp protocol decode" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [512]u8 = undefined;
            const input = buf[0..s.slice(&buf)];
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            inline for (@typeInfo(protocol.Method).@"enum".fields) |f| {
                const R = protocol.RequestInfo(@field(protocol.Method, f.name)).Result;
                if (R != void) {
                    // Must never crash; errors are fine.
                    _ = json.parse(R, arena.allocator(), input) catch {};
                    _ = arena.reset(.retain_capacity);
                }
            }
        }
    }.one, .{});
}
