//! The scripted-peer engine behind `fake_lsp_server` and the fake DAP
//! adapter: a line-oriented script of what the client must send and what
//! the peer answers, a JSON subset matcher, and `runPeer`, which plays a
//! script over a Content-Length framed stream.
//!
//! Script syntax (one directive per line; CRLF is accepted; blank lines and
//! lines starting with `#` are ignored):
//!
//! ```
//! strict                               unscripted notifications become errors
//! seq-check off                        DAP: allow non-increasing client seq
//! > initialize {"processId": null}     expect a message; JSON is a params subset
//! > response {"id": 7, "result": []}   expect a response to a peer request (subset)
//! > response runInTerminal {"success": true}
//!                                      DAP: expect the response to a reverse request
//! < {"id": $1, "result": {}}           send a message ($1 = last matched id)
//! < event stopped {"reason": "step"}   send a DAP event (an LSP notification
//!                                      `{"method": "stopped", "params": ...}`)
//! < reverse runInTerminal {"args": []} DAP: send a reverse request (`arguments`)
//! ~ 50ms                               sleep
//! ! exit 3                             stop and exit with status 3
//! ```
//!
//! Sent messages may use `$1` (JSON text of the id of the last matched
//! request) and `${workspace}` (the `--workspace` path, JSON-escaped, for use
//! inside strings). With `lsp` framing a missing `"jsonrpc"` is added; with
//! `dap` framing a missing `"seq"` is numbered from 1.
//!
//! In the DAP framing a client message `{"type": "request", "command": c,
//! "arguments": a, "seq": n}` is matched as method `c` with params `a`, and
//! `$1` is `n`. A DAP client response is matched as method `response`, with
//! an optional command name; it must answer the last reverse request (its
//! `request_seq`), and the JSON is a subset of the whole message. Clients
//! send no events, so nothing is skipped in DAP.
//!
//! DAP shortcuts: a sent message without `"type"` is a response to the last
//! matched request (`type`, `request_seq`, `command` and `"success": true`
//! are filled in), so `< {"body": {...}}` is enough. The client's `seq` must
//! increase strictly (the check is off with `seq-check off`); a regression
//! is reported like a mismatch.
//!
//! An LSP script stops with status 0 once it has matched `> exit`, and a
//! DAP script once it ends after answering `disconnect`. When the
//! script runs out the peer keeps serving until end of input: LSP
//! `shutdown` gets a `null` result and `exit` ends with status 0; DAP
//! `disconnect` gets a success response and ends with status 0. Other
//! requests get an error, other notifications are ignored (or, in `strict`
//! mode, fail the run).
//!
//! A mismatch prints the JSON path of the first difference with the
//! expected and actual values to `PeerOptions.diag` and ends with status 99
//! (`mismatch_status`).

const std = @import("std");
const zg_jsonrpc = @import("zg_jsonrpc");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Exit status of a run that saw something the script did not allow.
pub const mismatch_status: u8 = 99;

/// One script directive.
pub const Step = union(enum) {
    /// `> method [json]`.
    expect: Expect,
    /// `< json`: raw template text, substituted when sent.
    reply: Template,
    /// `< event name [json]`.
    event: Event,
    /// `< reverse command [json]` (DAP).
    reverse: Event,
    /// `~ <n>ms`.
    delay_ms: u32,
    /// `! exit <n>`.
    exit: u8,

    pub const Expect = struct {
        method: []const u8,
        /// For `> response <command>`: the command the response must name.
        command: ?[]const u8 = null,
        /// Parsed with `${workspace}` empty; `runPeer` re-parses `params_text`
        /// with the real value.
        params_subset: ?Value,
        params_text: ?[]const u8,
        line: u32,
    };
    pub const Template = struct { text: []const u8, line: u32 };
    pub const Event = struct { name: []const u8, body: ?Template, line: u32 };
};

/// Where a script failed to parse.
pub const ParseDiag = struct {
    line: u32 = 0,
    msg: []const u8 = "",
};

/// A parsed script. Owns its memory.
pub const Script = struct {
    steps: []const Step,
    strict: bool,
    /// DAP: client `seq` values must increase strictly.
    seq_check: bool = true,
    arena: *std.heap.ArenaAllocator,

    pub const ParseError = error{ InvalidScript, OutOfMemory };

    /// Parses `text`. On `error.InvalidScript`, `diag` (if given) names the
    /// line and the problem.
    pub fn parse(gpa: Allocator, text: []const u8, diag: ?*ParseDiag) ParseError!Script {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        arena.* = .init(gpa);
        errdefer {
            arena.deinit();
            gpa.destroy(arena);
        }
        const a = arena.allocator();
        var steps: std.ArrayList(Step) = .empty;
        var strict = false;
        var seq_check = true;
        var lines = std.mem.splitScalar(u8, text, '\n');
        var line_no: u32 = 0;
        while (lines.next()) |raw| {
            line_no += 1;
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const fail = struct {
                fn f(d: ?*ParseDiag, n: u32, msg: []const u8) ParseError {
                    if (d) |p| p.* = .{ .line = n, .msg = msg };
                    return error.InvalidScript;
                }
            }.f;
            if (std.mem.eql(u8, line, "strict")) {
                strict = true;
                continue;
            }
            if (std.mem.eql(u8, line, "seq-check off") or std.mem.eql(u8, line, "< seq-check off")) {
                seq_check = false;
                continue;
            }
            if (line.len < 2 or line[1] != ' ') return fail(diag, line_no, "unknown directive");
            const rest = std.mem.trim(u8, line[2..], " \t");
            switch (line[0]) {
                '>' => {
                    const sp = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
                    const method = rest[0..sp];
                    if (method.len == 0) return fail(diag, line_no, "expect needs a method");
                    var json = std.mem.trim(u8, rest[sp..], " \t");
                    var command: ?[]const u8 = null;
                    if (std.mem.eql(u8, method, "response") and json.len > 0 and json[0] != '{') {
                        const csp = std.mem.indexOfAny(u8, json, " \t") orelse json.len;
                        command = try a.dupe(u8, json[0..csp]);
                        json = std.mem.trim(u8, json[csp..], " \t");
                    }
                    var subset: ?Value = null;
                    var params_text: ?[]const u8 = null;
                    if (json.len > 0) {
                        if (std.mem.indexOf(u8, json, "$1") != null) return fail(diag, line_no, "`$1` is only allowed in sent messages");
                        params_text = try a.dupe(u8, json);
                        const filled = try substitute(a, json, "null", "");
                        subset = std.json.parseFromSliceLeaky(Value, a, filled, .{}) catch
                            return fail(diag, line_no, "invalid JSON in expect");
                    }
                    try steps.append(a, .{ .expect = .{
                        .method = try a.dupe(u8, method),
                        .command = command,
                        .params_subset = subset,
                        .params_text = params_text,
                        .line = line_no,
                    } });
                },
                '<' => {
                    const is_event = std.mem.startsWith(u8, rest, "event ");
                    if (is_event or std.mem.startsWith(u8, rest, "reverse ")) {
                        const kw = if (is_event) "event " else "reverse ";
                        const ev = std.mem.trim(u8, rest[kw.len..], " \t");
                        const sp = std.mem.indexOfAny(u8, ev, " \t") orelse ev.len;
                        const name = ev[0..sp];
                        if (name.len == 0) return fail(diag, line_no, if (is_event) "event needs a name" else "reverse needs a command");
                        const body = std.mem.trim(u8, ev[sp..], " \t");
                        var tmpl: ?Step.Template = null;
                        if (body.len > 0) {
                            if (!validTemplate(a, body)) return fail(diag, line_no, "invalid JSON in event body");
                            tmpl = .{ .text = try a.dupe(u8, body), .line = line_no };
                        }
                        const e: Step.Event = .{ .name = try a.dupe(u8, name), .body = tmpl, .line = line_no };
                        try steps.append(a, if (is_event) .{ .event = e } else .{ .reverse = e });
                    } else {
                        if (!validTemplate(a, rest)) return fail(diag, line_no, "invalid JSON in reply");
                        try steps.append(a, .{ .reply = .{ .text = try a.dupe(u8, rest), .line = line_no } });
                    }
                },
                '~' => {
                    const num = std.mem.trimEnd(u8, rest, "ms");
                    if (!std.mem.endsWith(u8, rest, "ms")) return fail(diag, line_no, "delay must be in ms, e.g. `~ 50ms`");
                    const ms = std.fmt.parseInt(u32, num, 10) catch return fail(diag, line_no, "invalid delay");
                    try steps.append(a, .{ .delay_ms = ms });
                },
                '!' => {
                    if (!std.mem.startsWith(u8, rest, "exit ")) return fail(diag, line_no, "unknown `!` directive");
                    const code = std.fmt.parseInt(u8, std.mem.trim(u8, rest["exit ".len..], " \t"), 10) catch
                        return fail(diag, line_no, "invalid exit status");
                    try steps.append(a, .{ .exit = code });
                },
                else => return fail(diag, line_no, "unknown directive"),
            }
        }
        return .{ .steps = try steps.toOwnedSlice(a), .strict = strict, .seq_check = seq_check, .arena = arena };
    }

    pub fn deinit(s: *Script) void {
        const gpa = s.arena.child_allocator;
        s.arena.deinit();
        gpa.destroy(s.arena);
        s.* = undefined;
    }
};

/// Checks that a template parses once its placeholders are filled.
fn validTemplate(arena: Allocator, text: []const u8) bool {
    const filled = substitute(arena, text, "0", "") catch return false;
    _ = std.json.parseFromSliceLeaky(Value, arena, filled, .{}) catch return false;
    return true;
}

/// Replaces `$1` with `id_json` and `${workspace}` with `workspace`
/// escaped for a JSON string.
pub fn substitute(gpa: Allocator, text: []const u8, id_json: []const u8, workspace: []const u8) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], "$1")) {
            w.writeAll(id_json) catch return error.OutOfMemory;
            i += 2;
        } else if (std.mem.startsWith(u8, text[i..], "${workspace}")) {
            std.json.Stringify.encodeJsonStringChars(workspace, .{}, w) catch return error.OutOfMemory;
            i += "${workspace}".len;
        } else {
            w.writeByte(text[i]) catch return error.OutOfMemory;
            i += 1;
        }
    }
    return out.toOwnedSlice();
}

/// The first difference found by `subsetMatch`.
pub const Mismatch = struct {
    path_buf: [256]u8 = undefined,
    path_len: usize = 0,
    expected: Value,
    /// Null when the expected key or element is missing.
    actual: ?Value,

    /// JSON path of the difference, e.g. `$.capabilities.hover[0]`.
    pub fn path(m: *const Mismatch) []const u8 {
        return m.path_buf[0..m.path_len];
    }
};

/// Returns null when every key and element of `expected` is present in
/// `actual` with an equal value (objects may carry extra keys; arrays must
/// have the same length; numbers compare by value), else the first
/// difference.
pub fn subsetMatch(expected: Value, actual: Value) ?Mismatch {
    var path_buf: [256]u8 = undefined;
    path_buf[0] = '$';
    return matchAt(expected, actual, &path_buf, 1);
}

fn mismatchAt(expected: Value, actual: ?Value, path_buf: *[256]u8, len: usize) Mismatch {
    var m: Mismatch = .{ .expected = expected, .actual = actual, .path_len = len };
    @memcpy(m.path_buf[0..len], path_buf[0..len]);
    return m;
}

fn appendPath(path_buf: *[256]u8, len: usize, comptime fmt: []const u8, args: anytype) usize {
    const s = std.fmt.bufPrint(path_buf[len..], fmt, args) catch return path_buf.len;
    return len + s.len;
}

fn matchAt(expected: Value, actual: Value, path_buf: *[256]u8, len: usize) ?Mismatch {
    switch (expected) {
        .object => |eo| {
            if (actual != .object) return mismatchAt(expected, actual, path_buf, len);
            var it = eo.iterator();
            while (it.next()) |e| {
                const n = appendPath(path_buf, len, ".{s}", .{e.key_ptr.*});
                const av = actual.object.get(e.key_ptr.*) orelse return mismatchAt(e.value_ptr.*, null, path_buf, n);
                if (matchAt(e.value_ptr.*, av, path_buf, n)) |m| return m;
            }
            return null;
        },
        .array => |ea| {
            if (actual != .array or actual.array.items.len != ea.items.len) return mismatchAt(expected, actual, path_buf, len);
            for (ea.items, actual.array.items, 0..) |ev, av, i| {
                const n = appendPath(path_buf, len, "[{d}]", .{i});
                if (matchAt(ev, av, path_buf, n)) |m| return m;
            }
            return null;
        },
        else => return if (scalarEql(expected, actual)) null else mismatchAt(expected, actual, path_buf, len),
    }
}

fn asNumber(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn scalarEql(a: Value, b: Value) bool {
    if (asNumber(a)) |x| {
        const y = asNumber(b) orelse return false;
        return x == y;
    }
    return switch (a) {
        .null => b == .null,
        .bool => |x| b == .bool and b.bool == x,
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        else => false,
    };
}

/// Framing dialect of `runPeer`.
pub const Framing = enum { lsp, dap };

pub const PeerOptions = struct {
    framing: Framing,
    /// Value of `${workspace}`.
    workspace: []const u8 = "",
    /// Receives mismatch reports.
    diag: ?*std.Io.Writer = null,
    max_message_bytes: usize = 64 << 20,
};

/// An incoming message, classified.
const Incoming = struct {
    kind: enum { request, notification, response },
    /// Method or DAP command; "response" for responses.
    method: []const u8,
    params: ?Value,
    /// JSON text of the id (or DAP seq) of a request.
    id_json: []const u8,
    whole: Value,
    /// DAP responses: the command and `request_seq`.
    command: []const u8 = "",
    request_seq: ?i64 = null,
};

fn classify(arena: Allocator, framing: Framing, v: Value) !Incoming {
    if (v != .object) return error.InvalidMessage;
    const o = v.object;
    switch (framing) {
        .lsp => {
            if (o.get("method")) |m| {
                if (m != .string) return error.InvalidMessage;
                if (o.get("id")) |id| return .{
                    .kind = .request,
                    .method = m.string,
                    .params = o.get("params"),
                    .id_json = try std.json.Stringify.valueAlloc(arena, id, .{}),
                    .whole = v,
                };
                return .{ .kind = .notification, .method = m.string, .params = o.get("params"), .id_json = "", .whole = v };
            }
            return .{ .kind = .response, .method = "response", .params = v, .id_json = "", .whole = v };
        },
        .dap => {
            const t = o.get("type") orelse return error.InvalidMessage;
            if (t != .string) return error.InvalidMessage;
            if (std.mem.eql(u8, t.string, "request")) {
                const c = o.get("command") orelse return error.InvalidMessage;
                if (c != .string) return error.InvalidMessage;
                const seq = o.get("seq") orelse Value{ .integer = 0 };
                return .{
                    .kind = .request,
                    .method = c.string,
                    .params = o.get("arguments"),
                    .id_json = try std.json.Stringify.valueAlloc(arena, seq, .{}),
                    .whole = v,
                };
            }
            if (std.mem.eql(u8, t.string, "response")) {
                const c = o.get("command") orelse Value{ .string = "" };
                const rs = o.get("request_seq") orelse Value.null;
                return .{
                    .kind = .response,
                    .method = "response",
                    .params = v,
                    .id_json = "",
                    .whole = v,
                    .command = if (c == .string) c.string else "",
                    .request_seq = if (rs == .integer) rs.integer else null,
                };
            }
            return error.InvalidMessage;
        },
    }
}

const Peer = struct {
    io: std.Io,
    gpa: Allocator,
    script: *const Script,
    frames: zg_jsonrpc.framing.ContentLengthReader,
    out: *std.Io.Writer,
    opts: PeerOptions,
    arena: std.heap.ArenaAllocator,
    last_id: []u8 = &.{},
    /// DAP: command of the last matched request.
    last_command: []u8 = &.{},
    /// DAP: seq of the last reverse request sent.
    last_reverse_seq: ?i64 = null,
    /// DAP: the highest client seq seen.
    client_seq: i64 = 0,
    seq: i64 = 1,

    fn report(p: *Peer, comptime fmt: []const u8, args: anytype) void {
        const w = p.opts.diag orelse return;
        w.print(fmt ++ "\n", args) catch {};
        w.flush() catch {};
    }

    fn reportValue(p: *Peer, label: []const u8, v: ?Value) void {
        const w = p.opts.diag orelse return;
        w.print("  {s}: ", .{label}) catch {};
        if (v) |x| std.json.Stringify.value(x, .{}, w) catch {} else w.writeAll("(missing)") catch {};
        w.writeByte('\n') catch {};
        w.flush() catch {};
    }

    /// Reads one message into the per-message arena; null at end of input.
    fn read(p: *Peer) !?Incoming {
        _ = p.arena.reset(.retain_capacity);
        const body = p.frames.next(p.gpa) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };
        const a = p.arena.allocator();
        const v = try std.json.parseFromSliceLeaky(Value, a, body, .{});
        const m = try classify(a, p.opts.framing, v);
        if (p.opts.framing == .dap and p.script.seq_check) {
            const seq = v.object.get("seq") orelse Value.null;
            if (seq != .integer or seq.integer <= p.client_seq) {
                p.report("client seq regression: got {f} after {d}", .{ std.json.fmt(seq, .{}), p.client_seq });
                p.reportValue("message", v);
                return error.SeqRegression;
            }
            p.client_seq = seq.integer;
        }
        return m;
    }

    fn rememberId(p: *Peer, id_json: []const u8, command: []const u8) !void {
        p.gpa.free(p.last_id);
        p.last_id = &.{};
        p.last_id = try p.gpa.dupe(u8, id_json);
        p.gpa.free(p.last_command);
        p.last_command = &.{};
        p.last_command = try p.gpa.dupe(u8, command);
    }

    fn send(p: *Peer, v: Value) !void {
        const a = p.arena.allocator();
        var msg = v;
        if (msg == .object) switch (p.opts.framing) {
            .lsp => if (msg.object.get("jsonrpc") == null) try msg.object.put(a, "jsonrpc", .{ .string = "2.0" }),
            .dap => {
                if (msg.object.get("type") == null) {
                    // Shortcut: a response to the last matched request.
                    try msg.object.put(a, "type", .{ .string = "response" });
                    const rs = std.fmt.parseInt(i64, p.last_id, 10) catch 0;
                    if (msg.object.get("request_seq") == null) try msg.object.put(a, "request_seq", .{ .integer = rs });
                    if (msg.object.get("command") == null) try msg.object.put(a, "command", .{ .string = p.last_command });
                    if (msg.object.get("success") == null) try msg.object.put(a, "success", .{ .bool = true });
                }
                if (msg.object.get("seq") == null) {
                    try msg.object.put(a, "seq", .{ .integer = p.seq });
                    p.seq += 1;
                }
            },
        };
        const body = try std.json.Stringify.valueAlloc(a, msg, .{});
        try zg_jsonrpc.framing.writeContentLength(p.out, body);
    }

    fn sendTemplate(p: *Peer, t: Step.Template) !void {
        _ = p.arena.reset(.retain_capacity);
        const a = p.arena.allocator();
        const id = if (p.last_id.len > 0) p.last_id else "null";
        const text = try substitute(a, t.text, id, p.opts.workspace);
        try p.send(try std.json.parseFromSliceLeaky(Value, a, text, .{}));
    }

    fn sendEvent(p: *Peer, e: Step.Event) !void {
        _ = p.arena.reset(.retain_capacity);
        const a = p.arena.allocator();
        var body: ?Value = null;
        if (e.body) |t| {
            const id = if (p.last_id.len > 0) p.last_id else "null";
            body = try std.json.parseFromSliceLeaky(Value, a, try substitute(a, t.text, id, p.opts.workspace), .{});
        }
        var o: std.json.ObjectMap = .empty;
        switch (p.opts.framing) {
            .lsp => {
                try o.put(a, "method", .{ .string = e.name });
                if (body) |b| try o.put(a, "params", b);
            },
            .dap => {
                try o.put(a, "type", .{ .string = "event" });
                try o.put(a, "event", .{ .string = e.name });
                if (body) |b| try o.put(a, "body", b);
            },
        }
        try p.send(.{ .object = o });
    }

    fn sendReverse(p: *Peer, e: Step.Event) !void {
        _ = p.arena.reset(.retain_capacity);
        const a = p.arena.allocator();
        var o: std.json.ObjectMap = .empty;
        try o.put(a, "type", .{ .string = "request" });
        try o.put(a, "command", .{ .string = e.name });
        if (e.body) |t| {
            const id = if (p.last_id.len > 0) p.last_id else "null";
            try o.put(a, "arguments", try std.json.parseFromSliceLeaky(Value, a, try substitute(a, t.text, id, p.opts.workspace), .{}));
        }
        p.last_reverse_seq = p.seq;
        try p.send(.{ .object = o });
    }

    /// Returns null once `e` matched, or an exit status.
    fn expect(p: *Peer, e: Step.Expect) !?u8 {
        while (true) {
            const m = (try p.read()) orelse {
                p.report("script line {d}: expected `{s}`, got end of input", .{ e.line, e.method });
                return mismatch_status;
            };
            if (!std.mem.eql(u8, m.method, e.method)) {
                const skippable = (m.kind == .notification and !p.script.strict) or
                    (m.kind == .response and !std.mem.eql(u8, e.method, "response"));
                if (skippable) continue;
                p.report("script line {d}: expected `{s}`, got `{s}`", .{ e.line, e.method, m.method });
                p.reportValue("message", m.whole);
                return mismatch_status;
            }
            if (m.kind == .response and p.opts.framing == .dap) {
                if (e.command) |cmd| if (!std.mem.eql(u8, cmd, m.command)) {
                    p.report("script line {d}: expected a `{s}` response, got `{s}`", .{ e.line, cmd, m.command });
                    p.reportValue("message", m.whole);
                    return mismatch_status;
                };
                if (p.last_reverse_seq) |want| if (m.request_seq != want) {
                    p.report("script line {d}: response request_seq {?d} does not answer reverse request {d}", .{ e.line, m.request_seq, want });
                    return mismatch_status;
                };
            }
            if (e.params_text) |text| {
                const a = p.arena.allocator();
                const want = try std.json.parseFromSliceLeaky(Value, a, try substitute(a, text, "null", p.opts.workspace), .{});
                const got = m.params orelse Value.null;
                if (subsetMatch(want, got)) |mm| {
                    p.report("script line {d}: `{s}` differs at {s}", .{ e.line, e.method, mm.path() });
                    p.reportValue("expected", mm.expected);
                    p.reportValue("actual", mm.actual);
                    return mismatch_status;
                }
            }
            if (m.kind == .request) try p.rememberId(m.id_json, m.method);
            return null;
        }
    }

    /// Serves until end of input once the script has run out.
    fn epilogue(p: *Peer) !u8 {
        while (try p.read()) |m| {
            const a = p.arena.allocator();
            switch (p.opts.framing) {
                .lsp => switch (m.kind) {
                    .request => {
                        const id = m.whole.object.get("id").?;
                        var o: std.json.ObjectMap = .empty;
                        try o.put(a, "id", id);
                        if (std.mem.eql(u8, m.method, "shutdown")) {
                            try o.put(a, "result", .null);
                        } else {
                            var err: std.json.ObjectMap = .empty;
                            try err.put(a, "code", .{ .integer = -32601 });
                            try err.put(a, "message", .{ .string = "unscripted request" });
                            try o.put(a, "error", .{ .object = err });
                        }
                        try p.send(.{ .object = o });
                    },
                    .notification => {
                        if (std.mem.eql(u8, m.method, "exit")) return 0;
                        if (p.script.strict) {
                            p.report("unscripted notification `{s}` after the script ended", .{m.method});
                            return mismatch_status;
                        }
                    },
                    .response => {},
                },
                .dap => switch (m.kind) {
                    .request => {
                        const ok = std.mem.eql(u8, m.method, "disconnect");
                        var o: std.json.ObjectMap = .empty;
                        try o.put(a, "type", .{ .string = "response" });
                        try o.put(a, "request_seq", m.whole.object.get("seq") orelse .{ .integer = 0 });
                        try o.put(a, "success", .{ .bool = ok });
                        try o.put(a, "command", .{ .string = m.method });
                        if (!ok) try o.put(a, "message", .{ .string = "unscripted request" });
                        try p.send(.{ .object = o });
                        if (ok) return 0;
                    },
                    else => {},
                },
            }
        }
        return 0;
    }
};

/// Plays `script` as the server (LSP) or adapter (DAP) side of `in` /
/// `out` and returns the exit status the peer process should use.
pub fn runPeer(io: std.Io, gpa: Allocator, script: *const Script, in: *std.Io.Reader, out: *std.Io.Writer, opts: PeerOptions) !u8 {
    var p: Peer = .{
        .io = io,
        .gpa = gpa,
        .script = script,
        .frames = .init(in, .{ .max_message_bytes = opts.max_message_bytes }),
        .out = out,
        .opts = opts,
        .arena = .init(gpa),
    };
    defer {
        p.frames.deinit(gpa);
        p.arena.deinit();
        gpa.free(p.last_id);
        gpa.free(p.last_command);
    }
    return runSteps(&p) catch |err| switch (err) {
        error.SeqRegression => mismatch_status,
        else => err,
    };
}

fn runSteps(p: *Peer) !u8 {
    const script = p.script;
    const opts = p.opts;
    const io = p.io;
    for (script.steps) |step| switch (step) {
        .expect => |e| {
            if (try p.expect(e)) |status| return status;
            // Like a real server, stop after the `exit` notification.
            if (opts.framing == .lsp and std.mem.eql(u8, e.method, "exit")) return 0;
        },
        .reply => |t| try p.sendTemplate(t),
        .event => |e| try p.sendEvent(e),
        .reverse => |e| try p.sendReverse(e),
        .delay_ms => |ms| try io.sleep(.fromMilliseconds(ms), .awake),
        .exit => |code| return code,
    };
    // Like a real adapter, stop once a scripted `disconnect` was answered.
    if (opts.framing == .dap and std.mem.eql(u8, p.last_command, "disconnect")) return 0;
    return p.epilogue();
}
