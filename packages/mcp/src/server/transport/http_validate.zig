//! Request checks for the Streamable HTTP server (E11.F05.S02.T01), all
//! pure functions over header values:
//!
//! - security, before the body is read: `Host` (DNS-rebinding defense),
//!   `Origin` and the bearer token;
//! - modern header consistency, after it is parsed: `MCP-Protocol-Version`,
//!   `Mcp-Method`, `Mcp-Name` and the tool's `Mcp-Param-*` headers must
//!   match the body (SHTTP "Header validation"; `-32020` otherwise).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const protocol = @import("../../protocol/root.zig");
const headers = @import("../../transport/headers.zig");

/// Request headers, copied (names compare case-insensitively).
pub const Headers = struct {
    list: []const std.http.Header = &.{},

    /// The first value of `name`.
    pub fn get(h: Headers, name: []const u8) ?[]const u8 {
        for (h.list) |x| if (std.ascii.eqlIgnoreCase(x.name, name)) return x.value;
        return null;
    }
};

/// `Host` must name this loopback listener unless remote access is on.
pub fn hostAllowed(host: ?[]const u8, port: u16, allow_remote: bool) bool {
    if (allow_remote) return true;
    const h = host orelse return false;
    var buf: [32]u8 = undefined;
    for ([_][]const u8{ "127.0.0.1", "localhost", "[::1]" }) |name| {
        const want = std.fmt.bufPrint(&buf, "{s}:{d}", .{ name, port }) catch continue;
        if (std.ascii.eqlIgnoreCase(h, want)) return true;
    }
    return false;
}

/// A request with an `Origin` must come from an allowed one.
pub fn originAllowed(origin: ?[]const u8, allowed: []const []const u8) bool {
    const o = origin orelse return true;
    for (allowed) |a| if (std.mem.eql(u8, a, o)) return true;
    return false;
}

/// `Authorization: Bearer <hex token>`, compared in constant time.
pub fn bearerAllowed(authorization: ?[]const u8, token: ?[32]u8) bool {
    const want = token orelse return true;
    const v = authorization orelse return false;
    const prefix = "Bearer ";
    if (v.len != prefix.len + 64 or !std.ascii.eqlIgnoreCase(v[0..prefix.len], prefix)) return false;
    var got: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&got, v[prefix.len..]) catch return false;
    return std.crypto.timing_safe.eql([32]u8, got, want);
}

/// Why a modern request's headers disagree with its body.
pub const Mismatch = []const u8;

/// Checks the modern routing headers against the body. `tool_schema` is
/// the called tool's input schema (`tools/call`), for `Mcp-Param-*`.
pub fn checkModern(a: Allocator, h: Headers, method: []const u8, params: Value, tool_schema: ?Value) Allocator.Error!?Mismatch {
    const meta = if (params == .object) params.object.get("_meta") else null;
    const pv_body: ?[]const u8 = if (meta) |m| (if (m == .object) (if (m.object.get(protocol.meta_keys.protocol_version)) |v| (if (v == .string) v.string else null) else null) else null) else null;
    const pv = h.get("mcp-protocol-version") orelse return "missing MCP-Protocol-Version header";
    if (pv_body == null or !std.mem.eql(u8, pv, pv_body.?)) return "MCP-Protocol-Version does not match _meta";
    const mm = h.get("mcp-method") orelse return "missing Mcp-Method header";
    if (!std.mem.eql(u8, mm, method)) return "Mcp-Method does not match method";

    const name_key: ?[]const u8 = if (std.mem.eql(u8, method, "tools/call") or std.mem.eql(u8, method, "prompts/get"))
        "name"
    else if (std.mem.eql(u8, method, "resources/read")) "uri" else null;
    if (name_key) |k| {
        const want = if (params == .object) params.object.get(k) else null;
        const raw = h.get("mcp-name") orelse return "missing Mcp-Name header";
        const got = headers.decodeHeaderValue(a, raw) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidEncoding => return "Mcp-Name is not valid base64",
        };
        if (want == null or want.? != .string or !std.mem.eql(u8, got, want.?.string)) return "Mcp-Name does not match params";
    }

    const schema = tool_schema orelse return null;
    const map = headers.buildXMcpHeaderMap(a, schema) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // An invalid map excludes the tool from listings; no headers to check.
        else => return null,
    };
    const args: Value = if (params == .object) params.object.get("arguments") orelse .null else .null;
    for (map.entries) |e| {
        var name_buf: [128]u8 = undefined;
        const hname = std.fmt.bufPrint(&name_buf, "Mcp-Param-{s}", .{e.header_name}) catch return "Mcp-Param header name too long";
        var cur = args;
        const present = for (e.path) |seg| {
            if (cur != .object) break false;
            cur = cur.object.get(seg) orelse break false;
        } else cur != .null;
        const raw = h.get(hname);
        if (!present) {
            if (raw != null) return "Mcp-Param header for an absent argument";
            continue;
        }
        const r = raw orelse return "missing Mcp-Param header";
        const got = headers.decodeHeaderValue(a, r) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidEncoding => return "Mcp-Param header is not valid base64",
        };
        const ok = switch (e.kind) {
            .string => cur == .string and std.mem.eql(u8, got, cur.string),
            .boolean => cur == .bool and std.mem.eql(u8, got, if (cur.bool) "true" else "false"),
            .integer => numericEqual(got, cur),
        };
        if (!ok) return "Mcp-Param header does not match arguments";
    }
    return null;
}

/// Integers compare by value: `42` in a header equals `42.0` in JSON.
fn numericEqual(text: []const u8, v: Value) bool {
    const h = std.fmt.parseFloat(f64, text) catch return false;
    const want: f64 = switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => return false,
    };
    return h == want;
}

const testing = std.testing;

test "http validate: host, origin, bearer" {
    try testing.expect(hostAllowed("127.0.0.1:8080", 8080, false));
    try testing.expect(hostAllowed("LOCALHOST:8080", 8080, false));
    try testing.expect(hostAllowed("[::1]:8080", 8080, false));
    try testing.expect(!hostAllowed("evil.example:8080", 8080, false));
    try testing.expect(!hostAllowed("127.0.0.1:9090", 8080, false));
    try testing.expect(!hostAllowed(null, 8080, false));
    try testing.expect(hostAllowed("evil.example", 8080, true));
    try testing.expect(originAllowed(null, &.{}));
    try testing.expect(!originAllowed("https://evil.example", &.{}));
    try testing.expect(originAllowed("vscode-webview://x", &.{"vscode-webview://x"}));
    const tok: [32]u8 = @splat(0xab);
    try testing.expect(bearerAllowed(null, null));
    try testing.expect(!bearerAllowed(null, tok));
    try testing.expect(bearerAllowed("Bearer " ++ "ab" ** 32, tok));
    try testing.expect(!bearerAllowed("Bearer " ++ "ac" ** 32, tok));
    try testing.expect(!bearerAllowed("Basic " ++ "ab" ** 32, tok));
}
