//! Transcript tooling behind `zg-transcript`: the NDJSON trace file that
//! `Trace.dump` writes, normalization (ids renumbered from 1, timestamps
//! dropped, the workspace root replaced by `${workspace}`), conversion to a
//! `fake_lsp_server` script, and a line diff of two normalized traces.
//!
//! One trace line per message:
//!
//! ```
//! {"dir":"send","kind":"request","method":"textDocument/hover","id":2,"at_ns":120,"body":{...}}
//! {"dir":"recv","kind":"response","method":"textDocument/hover","id":2,"at_ns":180,"latency_ns":60,"body":{...}}
//! ```
//!
//! `body` is the params (requests, notifications), the result (responses)
//! or the error object (`error_response`); it is left out when the trace
//! kept no body or the kept body was cut short.
//!
//! Std-only: the tool under tools/transcript imports this file directly.

const std = @import("std");
const trace = @import("trace.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Direction = trace.Direction;
pub const Kind = trace.Kind;

/// The placeholder `fake_lsp_server` replaces with `--workspace`.
pub const workspace_var = "${workspace}";

/// One parsed trace line.
pub const Line = struct {
    dir: Direction,
    kind: Kind,
    method: []const u8,
    id: ?i64 = null,
    at_ns: ?i64 = null,
    latency_ns: ?u64 = null,
    body: ?Value = null,
};

/// Writes `e` as one trace line. `scratch` checks that the body is whole
/// JSON (a body cut at `Trace.max_body` is left out).
pub fn writeEntry(scratch: Allocator, w: *std.Io.Writer, e: trace.Entry) !void {
    try w.print("{{\"dir\":\"{t}\",\"kind\":\"{t}\",\"method\":", .{ e.dir, e.kind });
    try std.json.Stringify.encodeJsonString(e.method, .{}, w);
    if (e.id) |id| try w.print(",\"id\":{d}", .{id});
    try w.print(",\"at_ns\":{d}", .{std.math.lossyCast(i64, e.at_ns)});
    if (e.latency_ns) |l| try w.print(",\"latency_ns\":{d}", .{l});
    if (e.body) |b| if (try std.json.validate(scratch, b)) {
        try w.writeAll(",\"body\":");
        try w.writeAll(b);
    };
    try w.writeAll("}\n");
}

/// Writes `l` as one trace line.
pub fn writeLine(w: *std.Io.Writer, l: Line) !void {
    try std.json.Stringify.value(l, .{ .emit_null_optional_fields = false }, w);
    try w.writeByte('\n');
}

pub const ParseError = error{ InvalidTrace, OutOfMemory };

/// Parses a trace file. On error, `bad_line` (1-based) names the line.
pub fn parse(arena: Allocator, text: []const u8, bad_line: *usize) ParseError![]Line {
    var out: std.ArrayList(Line) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (it.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const l = std.json.parseFromSliceLeaky(Line, arena, line, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch |err| {
            bad_line.* = n;
            return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidTrace;
        };
        try out.append(arena, l);
    }
    return out.items;
}

/// The workspace root of a trace: the path of the `rootUri` (or first
/// workspace folder) of its `initialize` request, if it is a `file://` URI.
pub fn findWorkspace(lines: []const Line) ?[]const u8 {
    for (lines) |l| {
        if (l.dir != .send or l.kind != .request or !std.mem.eql(u8, l.method, "initialize")) continue;
        const params = switch (l.body orelse return null) {
            .object => |o| o,
            else => return null,
        };
        if (params.get("rootUri")) |v| if (v == .string) return filePath(v.string);
        if (params.get("workspaceFolders")) |v| if (v == .array and v.array.items.len > 0) {
            const f = v.array.items[0];
            if (f == .object) if (f.object.get("uri")) |u| if (u == .string) return filePath(u.string);
        };
        return null;
    }
    return null;
}

fn filePath(uri: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return null;
    const p = std.mem.trimEnd(u8, uri["file://".len..], "/");
    return if (p.len == 0) null else p;
}

/// Returns the normalized trace: ids renumbered from 1 in order of use
/// (client and server ids separately), timestamps and latencies dropped,
/// and `workspace` (default: `findWorkspace`) replaced by `${workspace}`
/// in every string and object key of every body.
pub fn normalize(arena: Allocator, lines: []const Line, workspace: ?[]const u8) Allocator.Error![]Line {
    const ws = workspace orelse findWorkspace(lines);
    const out = try arena.alloc(Line, lines.len);
    var client: Ids = .{};
    var server: Ids = .{};
    for (lines, out) |l, *o| {
        o.* = .{ .dir = l.dir, .kind = l.kind, .method = l.method };
        if (l.body) |b| o.body = if (ws) |p| try replaceWorkspace(arena, b, p) else b;
        o.id = switch (l.kind) {
            .request => if (l.dir == .send)
                try client.open(arena, l.method, l.id)
            else
                try server.open(arena, l.method, l.id),
            .response, .error_response => if (l.dir == .recv)
                client.close(l.method, l.id)
            else
                server.close(l.method, l.id),
            .notification => null,
        };
    }
    return out;
}

/// Renumbering of one id space. A response without an id (the trace does
/// not always know it) answers the oldest open request of its method.
const Ids = struct {
    next: i64 = 1,
    map: std.AutoHashMapUnmanaged(i64, i64) = .empty,
    open_reqs: std.ArrayList(struct { method: []const u8, id: i64 }) = .empty,

    fn open(ids: *Ids, arena: Allocator, method: []const u8, old: ?i64) !i64 {
        const id = ids.next;
        ids.next += 1;
        if (old) |o| try ids.map.put(arena, o, id);
        try ids.open_reqs.append(arena, .{ .method = method, .id = id });
        return id;
    }

    fn close(ids: *Ids, method: []const u8, old: ?i64) ?i64 {
        const want: ?i64 = if (old) |o| ids.map.get(o) else null;
        for (ids.open_reqs.items, 0..) |r, i| {
            const hit = if (want) |w| r.id == w else std.mem.eql(u8, r.method, method);
            if (hit) {
                _ = ids.open_reqs.orderedRemove(i);
                return r.id;
            }
        }
        return want;
    }
};

fn replaceWorkspace(arena: Allocator, v: Value, ws: []const u8) Allocator.Error!Value {
    switch (v) {
        .string => |s| return .{ .string = try replaceIn(arena, s, ws) },
        .array => |a| {
            var out: std.json.Array = .init(arena);
            try out.ensureTotalCapacity(a.items.len);
            for (a.items) |x| out.appendAssumeCapacity(try replaceWorkspace(arena, x, ws));
            return .{ .array = out };
        },
        .object => |o| {
            var out: std.json.ObjectMap = .empty;
            var it = o.iterator();
            while (it.next()) |kv|
                try out.put(arena, try replaceIn(arena, kv.key_ptr.*, ws), try replaceWorkspace(arena, kv.value_ptr.*, ws));
            return .{ .object = out };
        },
        else => return v,
    }
}

/// Replaces each whole-component occurrence of `ws` in `s` (followed by
/// the end, `/`, `\`, `?` or `#`).
fn replaceIn(arena: Allocator, s: []const u8, ws: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOf(u8, s, ws) == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, s, i, ws)) |at| {
        const end = at + ws.len;
        const whole = end == s.len or std.mem.indexOfScalar(u8, "/\\?#", s[end]) != null;
        try out.appendSlice(arena, s[i..at]);
        try out.appendSlice(arena, if (whole) workspace_var else ws);
        i = end;
    }
    try out.appendSlice(arena, s[i..]);
    return out.items;
}

/// Params keys dropped from `>` lines: they differ from run to run.
const volatile_params = [_][]const u8{ "workDoneToken", "partialResultToken" };
/// The only `initialize` params kept: the rest is client configuration.
const initialize_params = [_][]const u8{ "rootUri", "workspaceFolders" };

/// Writes a `fake_lsp_server` script for a normalized trace. Client
/// messages become `>` lines with pruned params, server messages `<` lines;
/// a response to the request just matched uses `$1`.
pub fn toScript(arena: Allocator, lines: []const Line, w: *std.Io.Writer) !void {
    try w.writeAll("# Generated by zg-transcript to-script.\n");
    var last_req: ?i64 = null;
    for (lines) |l| switch (l.dir) {
        .send => switch (l.kind) {
            .request, .notification => {
                if (l.kind == .request) last_req = l.id;
                try w.print("> {s}", .{l.method});
                if (try pruneParams(arena, l.method, l.body)) |p| {
                    try w.writeByte(' ');
                    try std.json.Stringify.value(p, .{}, w);
                }
                try w.writeByte('\n');
            },
            .response, .error_response => {
                try w.print("> response {{\"id\": {?d}, ", .{l.id});
                try writeOutcome(w, l);
                try w.writeAll("}\n");
            },
        },
        .recv => switch (l.kind) {
            .response, .error_response => {
                try w.writeAll("< {\"id\": ");
                if (l.id != null and l.id == last_req) try w.writeAll("$1") else try w.print("{?d}", .{l.id});
                try w.writeAll(", ");
                try writeOutcome(w, l);
                try w.writeAll("}\n");
            },
            .request, .notification => {
                try w.writeAll("< {");
                if (l.kind == .request) try w.print("\"id\": {?d}, ", .{l.id});
                try w.writeAll("\"method\": ");
                try std.json.Stringify.encodeJsonString(l.method, .{}, w);
                if (l.body) |b| {
                    try w.writeAll(", \"params\": ");
                    try std.json.Stringify.value(b, .{}, w);
                }
                try w.writeAll("}\n");
            },
        },
    };
}

fn writeOutcome(w: *std.Io.Writer, l: Line) !void {
    try w.writeAll(if (l.kind == .error_response) "\"error\": " else "\"result\": ");
    try std.json.Stringify.value(l.body orelse .null, .{}, w);
}

fn pruneParams(arena: Allocator, method: []const u8, body: ?Value) !?Value {
    const b = body orelse return null;
    const o = switch (b) {
        .object => |o| o,
        .null => return null,
        else => return b,
    };
    var out: std.json.ObjectMap = .empty;
    const init = std.mem.eql(u8, method, "initialize");
    var it = o.iterator();
    while (it.next()) |kv| {
        const k = kv.key_ptr.*;
        if (contains(&volatile_params, k)) continue;
        if (init and !contains(&initialize_params, k)) continue;
        if (init and kv.value_ptr.* == .null) continue;
        try out.put(arena, k, kv.value_ptr.*);
    }
    if (out.count() == 0) return null;
    return .{ .object = out };
}

fn contains(set: []const []const u8, s: []const u8) bool {
    for (set) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// Writes the normalized lines of `a` and `b` that differ (`-` from `a`,
/// `+` from `b`, with 1-based message numbers). Returns whether they match.
pub fn diff(arena: Allocator, a: []const Line, b: []const Line, w: *std.Io.Writer) !bool {
    var same = true;
    for (0..@max(a.len, b.len)) |i| {
        const la = if (i < a.len) try lineText(arena, a[i]) else null;
        const lb = if (i < b.len) try lineText(arena, b[i]) else null;
        if (la != null and lb != null and std.mem.eql(u8, la.?, lb.?)) continue;
        same = false;
        if (la) |t| try w.print("-{d}: {s}", .{ i + 1, t });
        if (lb) |t| try w.print("+{d}: {s}", .{ i + 1, t });
    }
    return same;
}

fn lineText(arena: Allocator, l: Line) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    writeLine(&aw.writer, l) catch return error.OutOfMemory;
    return aw.written();
}

const sample =
    \\{"dir":"send","kind":"request","method":"initialize","id":7,"at_ns":10,"body":{"processId":42,"rootUri":"file:///home/u/proj","capabilities":{},"workDoneToken":"t"}}
    \\{"dir":"recv","kind":"response","method":"initialize","at_ns":20,"latency_ns":10,"body":{"capabilities":{"hoverProvider":true}}}
    \\{"dir":"send","kind":"notification","method":"initialized","at_ns":21,"body":{}}
    \\{"dir":"send","kind":"request","method":"textDocument/hover","id":8,"at_ns":30,"body":{"textDocument":{"uri":"file:///home/u/proj/a.zig"},"position":{"line":0,"character":1},"workDoneToken":"w"}}
    \\{"dir":"send","kind":"request","method":"textDocument/definition","id":9,"at_ns":31,"body":{"textDocument":{"uri":"file:///home/u/projx/b.zig"},"position":{"line":2,"character":0}}}
    \\{"dir":"recv","kind":"response","method":"textDocument/hover","id":8,"at_ns":40,"body":null}
    \\{"dir":"recv","kind":"error_response","method":"textDocument/definition","id":9,"at_ns":41,"body":{"code":-32801,"message":"modified"}}
    \\{"dir":"recv","kind":"notification","method":"window/logMessage","at_ns":42,"body":{"type":3,"message":"/home/u/proj/a.zig"}}
    \\
;

test "transcript: normalize ids/paths golden" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bad: usize = 0;
    const lines = try parse(a, sample, &bad);
    try std.testing.expectEqualStrings("/home/u/proj", findWorkspace(lines).?);
    const norm = try normalize(a, lines, null);
    var aw: std.Io.Writer.Allocating = .init(a);
    for (norm) |l| try writeLine(&aw.writer, l);
    try std.testing.expectEqualStrings(
        \\{"dir":"send","kind":"request","method":"initialize","id":1,"body":{"processId":42,"rootUri":"file://${workspace}","capabilities":{},"workDoneToken":"t"}}
        \\{"dir":"recv","kind":"response","method":"initialize","id":1,"body":{"capabilities":{"hoverProvider":true}}}
        \\{"dir":"send","kind":"notification","method":"initialized","body":{}}
        \\{"dir":"send","kind":"request","method":"textDocument/hover","id":2,"body":{"textDocument":{"uri":"file://${workspace}/a.zig"},"position":{"line":0,"character":1},"workDoneToken":"w"}}
        \\{"dir":"send","kind":"request","method":"textDocument/definition","id":3,"body":{"textDocument":{"uri":"file:///home/u/projx/b.zig"},"position":{"line":2,"character":0}}}
        \\{"dir":"recv","kind":"response","method":"textDocument/hover","id":2}
        \\{"dir":"recv","kind":"error_response","method":"textDocument/definition","id":3,"body":{"code":-32801,"message":"modified"}}
        \\{"dir":"recv","kind":"notification","method":"window/logMessage","body":{"type":3,"message":"${workspace}/a.zig"}}
        \\
    , aw.written());

    var sw: std.Io.Writer.Allocating = .init(a);
    try toScript(a, norm, &sw.writer);
    try std.testing.expectEqualStrings(
        \\# Generated by zg-transcript to-script.
        \\> initialize {"rootUri":"file://${workspace}"}
        \\< {"id": $1, "result": {"capabilities":{"hoverProvider":true}}}
        \\> initialized
        \\> textDocument/hover {"textDocument":{"uri":"file://${workspace}/a.zig"},"position":{"line":0,"character":1}}
        \\> textDocument/definition {"textDocument":{"uri":"file:///home/u/projx/b.zig"},"position":{"line":2,"character":0}}
        \\< {"id": 2, "result": null}
        \\< {"id": $1, "error": {"code":-32801,"message":"modified"}}
        \\< {"method": "window/logMessage", "params": {"type":3,"message":"${workspace}/a.zig"}}
        \\
    , sw.written());
}

test "transcript: parse errors and diff" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bad: usize = 0;
    try std.testing.expectError(error.InvalidTrace, parse(a, "{\"dir\":\"send\",\"kind\":\"request\",\"method\":\"x\"}\n\n{\"dir\":\"up\"}\n", &bad));
    try std.testing.expectEqual(@as(usize, 3), bad);

    const x = try normalize(a, try parse(a, sample, &bad), null);
    var y = try a.dupe(Line, x);
    y[5].body = .{ .integer = 1 };
    var aw: std.Io.Writer.Allocating = .init(a);
    try std.testing.expect(try diff(a, x, x, &aw.writer));
    try std.testing.expectEqual(@as(usize, 0), aw.written().len);
    try std.testing.expect(!try diff(a, x, y[0..7], &aw.writer));
    try std.testing.expect(std.mem.startsWith(u8, aw.written(), "-6: "));
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "+6: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "-8: ") != null);
}

test "transcript: dump entries round trip" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var aw: std.Io.Writer.Allocating = .init(a);
    try writeEntry(a, &aw.writer, .{ .dir = .recv, .kind = .response, .method = "m", .id = 3, .latency_ns = 5, .at_ns = 9, .body = "{\"a\":[1]}" });
    try writeEntry(a, &aw.writer, .{ .dir = .send, .kind = .request, .method = "cut", .at_ns = 10, .body = "{\"a\":[1" });
    var bad: usize = 0;
    const lines = try parse(a, aw.written(), &bad);
    try std.testing.expectEqual(@as(?u64, 5), lines[0].latency_ns);
    try std.testing.expectEqual(@as(?i64, 3), lines[0].id);
    try std.testing.expectEqual(@as(i64, 1), lines[0].body.?.object.get("a").?.array.items[0].integer);
    try std.testing.expect(lines[1].body == null);
}
