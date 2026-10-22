//! `zg.stream/1` (E10.F10.S01.T02): the NDJSON protocol of
//! `--output-format stream-json` and `--input-format stream-json`. One
//! compact JSON object per line. The first output line is `system/init`
//! and the last is exactly one `result`. Field names follow Claude Code's
//! stream-json where the concept matches; docs/ai/stream-json.md lists
//! the differences.
//!
//! Additive fields keep `zg.stream/1`; a removal or rename makes it `/2`.

const std = @import("std");
const proto = @import("zg_ai_proto");
const pevents = @import("../provider/events.zig");

const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;

pub const protocol = "zg.stream/1";

pub const Message = proto.Message;
pub const StreamEvent = pevents.StreamEvent;
pub const Usage = proto.Usage;

pub const McpStatus = struct { name: []const u8, status: []const u8 };

/// A tool call refused for want of an approval.
pub const Denial = struct { tool_name: []const u8, tool_input: []const u8, reason: []const u8 };

pub const SystemSubtype = enum { init, compact_boundary, api_retry };
pub const ResultSubtype = enum { success, error_max_turns, error_budget, error_during_execution, error_permission, error_interrupted };

pub const System = struct {
    subtype: SystemSubtype,
    session_id: []const u8,
    model: []const u8,
    cwd: []const u8,
    tools: []const []const u8 = &.{},
    mcp_servers: []const McpStatus = &.{},
    permission_mode: []const u8,
    protocol: []const u8 = protocol,
    attempt: ?u32 = null,
    retry_delay_ms: ?u64 = null,
};

pub const Result = struct {
    subtype: ResultSubtype,
    result: ?[]const u8,
    /// JSON text of the validated answer (`--json-schema`).
    structured_output: ?[]const u8 = null,
    session_id: []const u8,
    num_turns: u32,
    duration_ms: u64,
    usage: Usage,
    total_cost_usd: f64,
    is_error: bool,
    permission_denials: []const Denial = &.{},
};

pub const OutLine = union(enum) {
    system: System,
    assistant: struct { message: Message, session_id: []const u8, parent_tool_use_id: ?[]const u8 = null },
    /// Tool results and other user-role messages.
    user: struct { message: Message, session_id: []const u8 },
    /// Only with `--include-partial`.
    stream_event: struct { event: StreamEvent, session_id: []const u8 },
    permission_request: struct { request_id: []const u8, tool: []const u8, input_json: []const u8, reason: []const u8 },
    result: Result,
};

pub const Behavior = enum { allow, deny };

pub const InLine = union(enum) {
    user: struct { message: Message },
    permission_response: struct {
        request_id: []const u8,
        behavior: Behavior,
        /// JSON text: the input the user edited; validated again.
        updated_input: ?[]const u8 = null,
        message: ?[]const u8 = null,
    },
    interrupt,
    /// A line whose `type` this version does not know (skipped with a warning).
    unknown: []const u8,
};

const options: Stringify.Options = .{ .emit_null_optional_fields = false };

/// Writes `line` followed by `\n` and flushes.
pub fn writeLine(w: *std.Io.Writer, line: OutLine) std.Io.Writer.Error!void {
    var s: Stringify = .{ .writer = w, .options = options };
    try s.beginObject();
    try s.objectField("type");
    try s.write(@tagName(line));
    switch (line) {
        .system => |x| {
            try s.objectField("subtype");
            try s.write(@tagName(x.subtype));
            try fields(&s, x, &.{"subtype"});
        },
        .assistant => |x| {
            try s.objectField("message");
            try proto.json.writeMessage(&s, x.message);
            try fields(&s, x, &.{"message"});
        },
        .user => |x| {
            try s.objectField("message");
            try proto.json.writeMessage(&s, x.message);
            try fields(&s, x, &.{"message"});
        },
        .stream_event => |x| {
            try s.objectField("event");
            try writeEvent(&s, x.event);
            try s.objectField("session_id");
            try s.write(x.session_id);
        },
        .permission_request => |x| {
            try s.objectField("request_id");
            try s.write(x.request_id);
            try s.objectField("tool");
            try s.write(x.tool);
            try s.objectField("input");
            try rawJson(&s, x.input_json);
            try s.objectField("reason");
            try s.write(x.reason);
        },
        .result => |x| {
            try s.objectField("subtype");
            try s.write(@tagName(x.subtype));
            try s.objectField("result");
            try s.write(x.result);
            if (x.structured_output) |so| {
                try s.objectField("structured_output");
                try rawJson(&s, so);
            }
            try fields(&s, x, &.{ "subtype", "result", "structured_output" });
        },
    }
    try s.endObject();
    try w.writeByte('\n');
    try w.flush();
}

/// Writes the fields of `x` not in `skip`, in declaration order.
fn fields(s: *Stringify, x: anytype, comptime skip: []const []const u8) std.Io.Writer.Error!void {
    inline for (std.meta.fields(@TypeOf(x))) |f| {
        const skipped = comptime blk: {
            for (skip) |k| if (std.mem.eql(u8, k, f.name)) break :blk true;
            break :blk false;
        };
        if (!skipped) {
            const v = @field(x, f.name);
            const is_null = if (@typeInfo(f.type) == .optional) v == null else false;
            if (!is_null or std.mem.eql(u8, f.name, "parent_tool_use_id")) {
                try s.objectField(f.name);
                try s.write(v);
            }
        }
    }
}

/// Writes JSON text as a value (`{}` when it is empty).
fn rawJson(s: *Stringify, text: []const u8) std.Io.Writer.Error!void {
    try proto.json.writeRaw(s, if (std.mem.trim(u8, text, " \t\r\n").len == 0) "{}" else text);
}

fn writeEvent(s: *Stringify, e: StreamEvent) std.Io.Writer.Error!void {
    try s.beginObject();
    try s.objectField("type");
    try s.write(@tagName(e));
    switch (e) {
        .ping => {},
        .warning => |t| {
            try s.objectField("message");
            try s.write(t);
        },
        .usage => |u| {
            try s.objectField("usage");
            try s.write(u);
        },
        .stop => |r| {
            try s.objectField("stop_reason");
            try s.write(@tagName(r));
        },
        inline else => |p| inline for (std.meta.fields(@TypeOf(p))) |f| {
            const v = @field(p, f.name);
            const is_null = if (@typeInfo(f.type) == .optional) v == null else false;
            if (!is_null) {
                try s.objectField(f.name);
                switch (@typeInfo(f.type)) {
                    .@"enum" => try s.write(@tagName(v)),
                    .optional => |o| if (@typeInfo(o.child) == .@"enum") try s.write(@tagName(v.?)) else try s.write(v),
                    else => try s.write(v),
                }
            }
        },
    }
    try s.endObject();
}

pub const ReadError = error{ InvalidLine, LineTooLong, ReadFailed, OutOfMemory };

/// Longest accepted input line.
pub const max_line = 64 << 20;

/// Reads the next non-empty line; null at end of input. Strings point
/// into `arena`.
pub fn readLine(arena: Allocator, r: *std.Io.Reader) ReadError!?InLine {
    while (true) {
        var line: std.Io.Writer.Allocating = .init(arena);
        _ = r.streamDelimiterLimit(&line.writer, '\n', .limited(max_line)) catch |e| return switch (e) {
            error.ReadFailed => error.ReadFailed,
            error.WriteFailed => error.OutOfMemory,
            error.StreamTooLong => error.LineTooLong,
        };
        const at_end = blk: {
            _ = r.takeByte() catch |e| switch (e) {
                error.EndOfStream => break :blk true,
                error.ReadFailed => return error.ReadFailed,
            };
            break :blk false;
        };
        const text = std.mem.trim(u8, line.written(), " \t\r");
        if (text.len == 0) {
            if (at_end) return null;
            continue;
        }
        return try parseLine(arena, text);
    }
}

/// Parses one input line. Unknown fields are ignored.
pub fn parseLine(arena: Allocator, text: []const u8) ReadError!InLine {
    const v = proto.json.parseValue(arena, text) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidMessage => error.InvalidLine,
    };
    if (v != .object) return error.InvalidLine;
    const o = v.object;
    const ty = str(o, "type") orelse return error.InvalidLine;
    if (std.mem.eql(u8, ty, "user")) {
        const m = o.get("message") orelse return error.InvalidLine;
        var msg = proto.json.decodeMessage(arena, m) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.InvalidMessage => error.InvalidLine,
        };
        if (msg.role != .user) return error.InvalidLine;
        msg.meta = .{};
        return .{ .user = .{ .message = msg } };
    }
    if (std.mem.eql(u8, ty, "permission_response")) {
        const b = str(o, "behavior") orelse return error.InvalidLine;
        return .{ .permission_response = .{
            .request_id = str(o, "request_id") orelse return error.InvalidLine,
            .behavior = std.meta.stringToEnum(Behavior, b) orelse return error.InvalidLine,
            .updated_input = if (o.get("updated_input")) |u| (if (u == .null) null else try proto.json.stringifyValue(arena, u)) else null,
            .message = str(o, "message"),
        } };
    }
    if (std.mem.eql(u8, ty, "interrupt")) return .interrupt;
    return .{ .unknown = ty };
}

fn str(o: std.json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = o.get(k) orelse return null;
    return if (v == .string) v.string else null;
}

/// The text of a user message's text blocks, joined by blank lines.
pub fn promptText(arena: Allocator, m: Message) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (m.content) |b| if (b == .text) {
        if (out.items.len > 0) try out.appendSlice(arena, "\n\n");
        try out.appendSlice(arena, b.text.text);
    };
    return out.items;
}
