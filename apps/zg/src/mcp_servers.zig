//! `zg agent --mcp-config <file>`: connects the MCP servers a config file
//! lists and registers their tools with the agent (E10.F10.S01.T01, E11).
//!
//! The file uses Claude Code's `.mcp.json` shape (`mcpServers`) or VS
//! Code's (`servers`):
//!
//! ```json
//! {"mcpServers": {
//!   "github": {"type": "http", "url": "https://api.example.com/mcp", "headers": {"Authorization": "Bearer ${GITHUB_TOKEN}"}},
//!   "files": {"command": "npx", "args": ["-y", "some-server"], "env": {"ROOT": "${HOME:-/tmp}"}}
//! }}
//! ```
//!
//! `${VAR}` and `${VAR:-default}` expand from the environment, once (an
//! expanded value is not scanned again). An unknown `type` (such as
//! `ws`) is skipped with a warning. A server that fails to connect is
//! reported as `failed` in the stream-json `init` event, and the run goes
//! on without it. Only explicit files load here; the full config loader
//! with scopes, trust and reload is E11.F07.S01.T01.

const std = @import("std");
const zg_core = @import("zg_core");
const zg_net = @import("zg_net");
const zg_mcp = @import("zg_mcp");
const zg_ai = @import("zg_ai");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Exporter = zg_mcp.client.agent_tools.ToolExporter(zg_ai.tools.adapters.foreign);

/// One server entry, unexpanded values already expanded.
pub const Spec = struct {
    name: []const u8,
    transport: union(enum) {
        stdio: struct { command: []const u8, args: []const []const u8, env: []const [2][]const u8, cwd: ?[]const u8 },
        http: struct { url: []const u8, headers: []const std.http.Header },
    },
};

pub const ParseError = error{ OutOfMemory, InvalidConfig };

/// The servers in one config file. Problems that only skip one entry are
/// written to `warn`.
pub fn parse(arena: Allocator, json: []const u8, env: *const std.process.Environ.Map, warn: *Io.Writer) ParseError![]const Spec {
    const root = std.json.parseFromSliceLeaky(Value, arena, json, .{}) catch return error.InvalidConfig;
    if (root != .object) return error.InvalidConfig;
    const servers = root.object.get("mcpServers") orelse root.object.get("servers") orelse return &.{};
    if (servers != .object) return error.InvalidConfig;
    var out: std.ArrayList(Spec) = .empty;
    var it = servers.object.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        const v = e.value_ptr.*;
        if (v != .object) {
            warn.print("zg agent: MCP server {s}: not an object; skipped\n", .{name}) catch {};
            continue;
        }
        const spec = entry(arena, name, v, env) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Skip => continue,
            else => {
                warn.print("zg agent: MCP server {s}: {s}; skipped\n", .{ name, switch (err) {
                    error.MissingCommand => "needs a command or a url",
                    error.UnsupportedType => "unsupported type",
                    error.BadField => "a field has the wrong type",
                    error.BadExpansion => "an unclosed ${...}",
                    error.MissingVariable => "uses an unset variable without a default",
                    error.OutOfMemory, error.Skip => unreachable,
                } }) catch {};
                continue;
            },
        };
        try out.append(arena, spec);
    }
    return out.items;
}

const EntryError = error{ OutOfMemory, MissingCommand, UnsupportedType, BadField, BadExpansion, MissingVariable, Skip };

fn entry(arena: Allocator, name: []const u8, v: Value, env: *const std.process.Environ.Map) EntryError!Spec {
    if (v.object.get("disabled")) |d| if (d == .bool and d.bool) return error.Skip;
    if (v.object.get("enabled")) |d| if (d == .bool and !d.bool) return error.Skip;
    const ty: []const u8 = if (v.object.get("type")) |t| (if (t == .string) t.string else return error.BadField) else if (v.object.get("url") != null) "http" else "stdio";
    if (std.mem.eql(u8, ty, "stdio")) {
        const command = try strField(arena, v, "command", env) orelse return error.MissingCommand;
        var args: std.ArrayList([]const u8) = .empty;
        if (v.object.get("args")) |a| {
            if (a != .array) return error.BadField;
            for (a.array.items) |x| {
                if (x != .string) return error.BadField;
                try args.append(arena, try expand(arena, x.string, env));
            }
        }
        var vars: std.ArrayList([2][]const u8) = .empty;
        if (v.object.get("env")) |m| {
            if (m != .object) return error.BadField;
            var mi = m.object.iterator();
            while (mi.next()) |x| {
                if (x.value_ptr.* != .string) return error.BadField;
                try vars.append(arena, .{ x.key_ptr.*, try expand(arena, x.value_ptr.string, env) });
            }
        }
        return .{ .name = name, .transport = .{ .stdio = .{ .command = command, .args = args.items, .env = vars.items, .cwd = try strField(arena, v, "cwd", env) } } };
    }
    if (std.mem.eql(u8, ty, "http") or std.mem.eql(u8, ty, "streamable-http") or std.mem.eql(u8, ty, "sse")) {
        const url = try strField(arena, v, "url", env) orelse return error.MissingCommand;
        var hs: std.ArrayList(std.http.Header) = .empty;
        if (v.object.get("headers")) |m| {
            if (m != .object) return error.BadField;
            var mi = m.object.iterator();
            while (mi.next()) |x| {
                if (x.value_ptr.* != .string) return error.BadField;
                try hs.append(arena, .{ .name = x.key_ptr.*, .value = try expand(arena, x.value_ptr.string, env) });
            }
        }
        return .{ .name = name, .transport = .{ .http = .{ .url = url, .headers = hs.items } } };
    }
    return error.UnsupportedType;
}

fn strField(arena: Allocator, v: Value, key: []const u8, env: *const std.process.Environ.Map) EntryError!?[]const u8 {
    const f = v.object.get(key) orelse return null;
    if (f != .string) return error.BadField;
    return try expand(arena, f.string, env);
}

/// Expands `${VAR}` and `${VAR:-default}` once. `$` alone stays.
pub fn expand(arena: Allocator, s: []const u8, env: *const std.process.Environ.Map) error{ OutOfMemory, BadExpansion, MissingVariable }![]const u8 {
    if (std.mem.indexOf(u8, s, "${") == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '$' and i + 1 < s.len and s[i + 1] == '{') {
            const end = std.mem.indexOfScalarPos(u8, s, i + 2, '}') orelse return error.BadExpansion;
            const body = s[i + 2 .. end];
            const sep = std.mem.indexOf(u8, body, ":-");
            const var_name = if (sep) |p| body[0..p] else body;
            const value = env.get(var_name) orelse if (sep) |p| body[p + 2 ..] else return error.MissingVariable;
            try out.appendSlice(arena, value);
            i = end + 1;
        } else {
            try out.append(arena, s[i]);
            i += 1;
        }
    }
    return out.items;
}

/// The connected servers of one run.
pub const Servers = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(*Entry) = .empty,
    statuses: std.ArrayList(zg_ai.headless.stream_json.McpStatus) = .empty,
    exporters: std.ArrayList(zg_ai.tools.adapters.foreign.Exporter) = .empty,

    const Entry = struct {
        x: Exporter,
        client: ?*zg_mcp.client.Client = null,
        env: ?std.process.Environ.Map = null,
    };

    pub fn init(gpa: Allocator) Servers {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(s: *Servers) void {
        for (s.entries.items) |e| {
            e.x.deinit();
            if (e.client) |c| c.close();
            if (e.env) |*m| m.deinit();
            s.gpa.destroy(e);
        }
        s.entries.deinit(s.gpa);
        s.statuses.deinit(s.gpa);
        s.exporters.deinit(s.gpa);
        s.arena.deinit();
    }

    /// Reads `paths`, connects each server and keeps an exporter for each
    /// one that connected. A later file's entry replaces an earlier one
    /// of the same name.
    pub fn load(s: *Servers, rt: *zg_core.Runtime, http: *zg_net.http.Client, paths: []const []const u8, env: *const std.process.Environ.Map, cwd: []const u8, warn: *Io.Writer) !void {
        const a = s.arena.allocator();
        const io = rt.io;
        var specs: std.ArrayList(Spec) = .empty;
        for (paths) |p| {
            const text = Io.Dir.cwd().readFileAlloc(io, p, a, .limited(4 << 20)) catch |e| {
                try warn.print("zg agent: cannot read MCP config {s}: {s}\n", .{ p, @errorName(e) });
                continue;
            };
            const got = parse(a, text, env, warn) catch {
                try warn.print("zg agent: {s} is not an MCP config (expected an object with mcpServers)\n", .{p});
                continue;
            };
            for (got) |g| {
                for (specs.items) |*old| {
                    if (std.mem.eql(u8, old.name, g.name)) {
                        old.* = g;
                        break;
                    }
                } else try specs.append(a, g);
            }
        }
        for (specs.items) |spec| {
            const e = try s.gpa.create(Entry);
            e.* = .{ .x = undefined };
            try s.entries.append(s.gpa, e);
            e.x.init(s.gpa, io, spec.name, .{});
            const factory: zg_mcp.client.Client.TransportFactory = switch (spec.transport) {
                .stdio => |t| blk: {
                    var m = try env.clone(s.gpa);
                    for (t.env) |kv| try m.put(kv[0], kv[1]);
                    e.env = m;
                    break :blk .{ .stdio = .{ .command = t.command, .args = t.args, .cwd = t.cwd orelse cwd, .env = &e.env.? } };
                },
                .http => |t| .{ .http = .{ .client = http, .opts = .{ .url = t.url, .static_headers = t.headers } } },
            };
            const c = zg_mcp.client.Client.connect(rt, s.gpa, factory, .{
                .client_info = .{ .name = "zigguro", .version = "0" },
                .on_notification = e.x.notificationHandler(),
            }) catch |err| {
                try warn.print("zg agent: MCP server {s} did not start: {s}\n", .{ spec.name, @errorName(err) });
                try s.statuses.append(s.gpa, .{ .name = spec.name, .status = "failed" });
                continue;
            };
            e.client = c;
            e.x.attach(c);
            try s.exporters.append(s.gpa, e.x.exporter());
            try s.statuses.append(s.gpa, .{ .name = spec.name, .status = "connected" });
        }
    }
};

const testing = std.testing;

test "mcp config: Claude Code and VS Code shapes, expansion, skips" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("TOKEN", "s3cret");
    var warn: Io.Writer.Allocating = .init(a);
    const specs = try parse(a,
        \\{"mcpServers":{
        \\  "files":{"command":"srv","args":["--root","${ROOT:-/tmp}"],"env":{"T":"${TOKEN}"}},
        \\  "gh":{"type":"http","url":"https://x.test/mcp","headers":{"Authorization":"Bearer ${TOKEN}"}},
        \\  "ws":{"type":"ws","url":"wss://x.test"},
        \\  "off":{"command":"x","disabled":true},
        \\  "bad":{"command":"x","args":["${NOPE}"]}
        \\}}
    , &env, &warn.writer);
    try testing.expectEqual(2, specs.len);
    try testing.expectEqualStrings("files", specs[0].name);
    try testing.expectEqualStrings("/tmp", specs[0].transport.stdio.args[1]);
    try testing.expectEqualStrings("s3cret", specs[0].transport.stdio.env[0][1]);
    try testing.expectEqualStrings("Bearer s3cret", specs[1].transport.http.headers[0].value);
    try testing.expect(std.mem.indexOf(u8, warn.written(), "ws: unsupported type") != null);
    try testing.expect(std.mem.indexOf(u8, warn.written(), "bad: uses an unset variable") != null);
    // Warnings never quote expanded values.
    try testing.expect(std.mem.indexOf(u8, warn.written(), "s3cret") == null);

    const vs = try parse(a, "{\"servers\":{\"v\":{\"type\":\"stdio\",\"command\":\"c\"}}}", &env, &warn.writer);
    try testing.expectEqual(1, vs.len);
    try testing.expectError(error.InvalidConfig, parse(a, "[1]", &env, &warn.writer));
}

test "mcp config: expansion is single pass" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var env: std.process.Environ.Map = .init(testing.allocator);
    defer env.deinit();
    try env.put("A", "${B}");
    try env.put("B", "boom");
    try testing.expectEqualStrings("x${B}y", try expand(arena.allocator(), "x${A}y", &env));
    try testing.expectEqualStrings("$HOME stays", try expand(arena.allocator(), "$HOME stays", &env));
    try testing.expectError(error.BadExpansion, expand(arena.allocator(), "${A", &env));
}
