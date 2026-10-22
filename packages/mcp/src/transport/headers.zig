//! Streamable HTTP request metadata headers (2026-07-28 "Request Metadata"):
//! value encoding with the `=?base64?...?=` sentinel, and `x-mcp-header`
//! tool parameters mirrored into `Mcp-Param-{Name}` headers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const b64 = std.base64.standard;

const prefix = "=?base64?";
const suffix = "?=";

/// Whether `v` must be carried Base64-encoded: it has a byte outside visible
/// ASCII and space (non-ASCII or a control character, tab included), leading
/// or trailing whitespace, or looks like the sentinel itself.
pub fn needsBase64(v: []const u8) bool {
    for (v) |c| if (c < 0x20 or c > 0x7E) return true;
    if (v.len > 0 and (v[0] == ' ' or v[v.len - 1] == ' ')) return true;
    return looksEncoded(v);
}

fn looksEncoded(v: []const u8) bool {
    return v.len >= prefix.len + suffix.len and std.mem.startsWith(u8, v, prefix) and std.mem.endsWith(u8, v, suffix);
}

/// `v` as a header value: verbatim when safe, else `=?base64?<b64>?=`.
/// Always returns a new slice owned by `gpa`.
pub fn encodeHeaderValue(gpa: Allocator, v: []const u8) Allocator.Error![]const u8 {
    if (!needsBase64(v)) return gpa.dupe(u8, v);
    const n = b64.Encoder.calcSize(v.len);
    const out = try gpa.alloc(u8, prefix.len + n + suffix.len);
    @memcpy(out[0..prefix.len], prefix);
    _ = b64.Encoder.encode(out[prefix.len..][0..n], v);
    @memcpy(out[prefix.len + n ..], suffix);
    return out;
}

/// Inverse of `encodeHeaderValue` (servers use it before comparing a header
/// with the body). Caller owns the result.
pub fn decodeHeaderValue(gpa: Allocator, v: []const u8) error{ OutOfMemory, InvalidEncoding }![]u8 {
    if (!looksEncoded(v)) return gpa.dupe(u8, v);
    const inner = v[prefix.len .. v.len - suffix.len];
    const n = b64.Decoder.calcSizeForSlice(inner) catch return error.InvalidEncoding;
    const out = try gpa.alloc(u8, n);
    errdefer gpa.free(out);
    b64.Decoder.decode(out, inner) catch return error.InvalidEncoding;
    return out;
}

/// One `Mcp-Param-*` header (name includes the prefix).
pub const ParamHeader = struct { name: []const u8, value: []const u8 };

/// The JSON type of an `x-mcp-header` parameter.
pub const ParamKind = enum { string, integer, boolean };

/// The `x-mcp-header` annotations of one tool's `inputSchema`.
pub const XMcpHeaderMap = struct {
    entries: []const Entry = &.{},

    /// One annotated property: its `properties` path and header name.
    pub const Entry = struct {
        path: []const []const u8,
        header_name: []const u8,
        kind: ParamKind,
    };

    /// An empty map (no annotations).
    pub const empty: XMcpHeaderMap = .{};
};

/// Why a tool definition's `x-mcp-header` annotations are invalid.
pub const XMcpError = error{
    EmptyName,
    InvalidToken,
    DuplicateName,
    NonPrimitiveType,
    NumberTypeNotAllowed,
    NotStaticallyReachable,
    OutOfMemory,
};

/// Collects the `x-mcp-header` annotations of `input_schema`, validating
/// the constraints of TOOLS "x-mcp-header": non-empty RFC 9110 token names,
/// unique case-insensitively, on `string`/`integer`/`boolean` properties
/// reachable from the root through `properties` keys only. A tool for which
/// this fails must be excluded from `tools/list`. Memory belongs to `gpa`
/// (use an arena).
pub fn buildXMcpHeaderMap(gpa: Allocator, input_schema: Value) XMcpError!XMcpHeaderMap {
    var list: std.ArrayList(XMcpHeaderMap.Entry) = .empty;
    var path: std.ArrayList([]const u8) = .empty;
    defer path.deinit(gpa);
    try walk(gpa, input_schema, &path, true, &list);
    for (list.items, 0..) |a, i| for (list.items[i + 1 ..]) |b| {
        if (std.ascii.eqlIgnoreCase(a.header_name, b.header_name)) return error.DuplicateName;
    };
    return .{ .entries = try list.toOwnedSlice(gpa) };
}

/// Keywords whose values are instance data, never subschemas.
const data_keywords = [_][]const u8{ "const", "enum", "default", "examples", "x-mcp-header" };

fn walk(gpa: Allocator, node: Value, path: *std.ArrayList([]const u8), reachable: bool, out: *std.ArrayList(XMcpHeaderMap.Entry)) XMcpError!void {
    switch (node) {
        .array => |a| for (a.items) |item| try walk(gpa, item, path, false, out),
        .object => |o| {
            if (o.get("x-mcp-header")) |name_v| {
                // The root is the arguments object, not a parameter.
                if (!reachable or path.items.len == 0) return error.NotStaticallyReachable;
                if (name_v != .string or name_v.string.len == 0) return error.EmptyName;
                if (!isToken(name_v.string)) return error.InvalidToken;
                try out.append(gpa, .{
                    .path = try gpa.dupe([]const u8, path.items),
                    .header_name = name_v.string,
                    .kind = try primitiveKind(o.get("type")),
                });
            }
            var it = o.iterator();
            while (it.next()) |e| {
                const key = e.key_ptr.*;
                if (isDataKeyword(key)) continue;
                if (std.mem.eql(u8, key, "properties") and e.value_ptr.* == .object) {
                    var pit = e.value_ptr.object.iterator();
                    while (pit.next()) |p| {
                        try path.append(gpa, p.key_ptr.*);
                        defer _ = path.pop();
                        try walk(gpa, p.value_ptr.*, path, reachable, out);
                    }
                } else {
                    try walk(gpa, e.value_ptr.*, path, false, out);
                }
            }
        },
        else => {},
    }
}

fn isDataKeyword(k: []const u8) bool {
    for (data_keywords) |d| if (std.mem.eql(u8, d, k)) return true;
    return false;
}

fn primitiveKind(t: ?Value) XMcpError!ParamKind {
    const v = t orelse return error.NonPrimitiveType;
    if (v != .string) return error.NonPrimitiveType;
    if (std.mem.eql(u8, v.string, "string")) return .string;
    if (std.mem.eql(u8, v.string, "integer")) return .integer;
    if (std.mem.eql(u8, v.string, "boolean")) return .boolean;
    if (std.mem.eql(u8, v.string, "number")) return error.NumberTypeNotAllowed;
    return error.NonPrimitiveType;
}

/// RFC 9110 `token = 1*tchar`.
pub fn isToken(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => {},
        else => return false,
    };
    return true;
}

/// Largest integer allowed in an `Mcp-Param-*` header (2^53 - 1).
pub const max_safe_integer: i64 = (1 << 53) - 1;

/// Errors from `paramHeadersFor`.
pub const ParamError = error{ OutOfMemory, IntegerOutOfRange, TypeMismatch };

/// The `Mcp-Param-*` headers for a `tools/call` with `args`. Absent and
/// null values are omitted. Memory belongs to `gpa` (use an arena).
pub fn paramHeadersFor(gpa: Allocator, header_map: *const XMcpHeaderMap, args: Value) ParamError![]ParamHeader {
    var out: std.ArrayList(ParamHeader) = .empty;
    for (header_map.entries) |e| {
        var cur = args;
        const found = for (e.path) |seg| {
            if (cur != .object) break false;
            cur = cur.object.get(seg) orelse break false;
        } else true;
        if (!found or cur == .null) continue;
        var buf: [24]u8 = undefined;
        const text: []const u8 = switch (e.kind) {
            .string => if (cur == .string) cur.string else return error.TypeMismatch,
            .boolean => if (cur == .bool) (if (cur.bool) "true" else "false") else return error.TypeMismatch,
            .integer => blk: {
                const i: i64 = switch (cur) {
                    .integer => |i| i,
                    .float => |f| if (@floor(f) == f and @abs(f) <= @as(f64, @floatFromInt(max_safe_integer)))
                        @intFromFloat(f)
                    else
                        return error.IntegerOutOfRange,
                    .number_string => return error.IntegerOutOfRange,
                    else => return error.TypeMismatch,
                };
                if (i > max_safe_integer or i < -max_safe_integer) return error.IntegerOutOfRange;
                break :blk std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
            },
        };
        try out.append(gpa, .{
            .name = try std.fmt.allocPrint(gpa, "Mcp-Param-{s}", .{e.header_name}),
            .value = try encodeHeaderValue(gpa, text),
        });
    }
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

test "encodeHeaderValue spec table" {
    // https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http#value-encoding
    const rows = [_][2][]const u8{
        .{ "us-west1", "us-west1" },
        .{ "Hello, 世界", "=?base64?SGVsbG8sIOS4lueVjA==?=" },
        .{ " padded ", "=?base64?IHBhZGRlZCA=?=" },
        .{ "line1\nline2", "=?base64?bGluZTEKbGluZTI=?=" },
        .{ "=?base64?literal?=", "=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=" },
    };
    for (rows) |r| {
        const enc = try encodeHeaderValue(testing.allocator, r[0]);
        defer testing.allocator.free(enc);
        try testing.expectEqualStrings(r[1], enc);
        const dec = try decodeHeaderValue(testing.allocator, enc);
        defer testing.allocator.free(dec);
        try testing.expectEqualStrings(r[0], dec);
    }
}

fn parse(arena: Allocator, s: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, s, .{});
}

test "x-mcp-header: nested properties path ok" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const schema = try parse(a,
        \\{"type":"object","properties":{
        \\  "region":{"type":"string","x-mcp-header":"Region"},
        \\  "opts":{"type":"object","properties":{"limit":{"type":"integer","x-mcp-header":"Limit"},
        \\                                        "dry":{"type":"boolean","x-mcp-header":"Dry"}}},
        \\  "q":{"type":"string","default":{"x-mcp-header":"NotASchema"}}}}
    );
    const map = try buildXMcpHeaderMap(a, schema);
    try testing.expectEqual(@as(usize, 3), map.entries.len);
    const args = try parse(a, "{\"region\":\"us-west1\",\"opts\":{\"limit\":42,\"dry\":null},\"q\":\"x\"}");
    const hs = try paramHeadersFor(a, &map, args);
    try testing.expectEqual(@as(usize, 2), hs.len);
    try testing.expectEqualStrings("Mcp-Param-Region", hs[0].name);
    try testing.expectEqualStrings("us-west1", hs[0].value);
    try testing.expectEqualStrings("Mcp-Param-Limit", hs[1].name);
    try testing.expectEqualStrings("42", hs[1].value);
    const big = try parse(a, "{\"region\":\"r\",\"opts\":{\"limit\":9007199254740992}}");
    try testing.expectError(error.IntegerOutOfRange, paramHeadersFor(a, &map, big));
}

test "x-mcp-header: reject under items/anyOf/$ref; reject number type; reject duplicate case-insensitive" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { []const u8, XMcpError }{
        .{ "{\"type\":\"object\",\"properties\":{\"l\":{\"type\":\"array\",\"items\":{\"type\":\"string\",\"x-mcp-header\":\"L\"}}}}", error.NotStaticallyReachable },
        .{ "{\"type\":\"object\",\"properties\":{\"l\":{\"anyOf\":[{\"type\":\"string\",\"x-mcp-header\":\"L\"}]}}}", error.NotStaticallyReachable },
        .{ "{\"type\":\"object\",\"$defs\":{\"r\":{\"type\":\"string\",\"x-mcp-header\":\"R\"}},\"properties\":{\"l\":{\"$ref\":\"#/$defs/r\"}}}", error.NotStaticallyReachable },
        .{ "{\"type\":\"object\",\"if\":{\"properties\":{\"a\":{\"type\":\"string\",\"x-mcp-header\":\"A\"}}}}", error.NotStaticallyReachable },
        .{ "{\"type\":\"object\",\"x-mcp-header\":\"Root\"}", error.NotStaticallyReachable },
        .{ "{\"type\":\"object\",\"properties\":{\"n\":{\"type\":\"number\",\"x-mcp-header\":\"N\"}}}", error.NumberTypeNotAllowed },
        .{ "{\"type\":\"object\",\"properties\":{\"o\":{\"type\":\"object\",\"x-mcp-header\":\"O\"}}}", error.NonPrimitiveType },
        .{ "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"string\",\"x-mcp-header\":\"Name\"},\"b\":{\"type\":\"string\",\"x-mcp-header\":\"NAME\"}}}", error.DuplicateName },
        .{ "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"string\",\"x-mcp-header\":\"\"}}}", error.EmptyName },
        .{ "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"string\",\"x-mcp-header\":\"Bad Name\"}}}", error.InvalidToken },
        .{ "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"string\",\"x-mcp-header\":\"X\\r\\nY\"}}}", error.InvalidToken },
    };
    for (cases) |c| try testing.expectError(c[1], buildXMcpHeaderMap(a, try parse(a, c[0])));
}

test "fuzz: mcp header encode" {
    try testing.fuzz({}, struct {
        fn one(_: void, s: *testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const v = buf[0..s.slice(&buf)];
            const enc = try encodeHeaderValue(testing.allocator, v);
            defer testing.allocator.free(enc);
            // Always an RFC 9110 field value with no surrounding whitespace.
            for (enc) |c| try testing.expect(c >= 0x20 and c <= 0x7E);
            if (enc.len > 0) try testing.expect(enc[0] != ' ' and enc[enc.len - 1] != ' ');
            const dec = try decodeHeaderValue(testing.allocator, enc);
            defer testing.allocator.free(dec);
            try testing.expectEqualSlices(u8, v, dec);
        }
    }.one, .{});
}
