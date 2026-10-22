//! Session file records, schema v1 (E10.F08.S01.T01). One JSON object per
//! line: `{"v":1,"seq":N,"t":ms,"type":"...", ...payload}`. The first line
//! is the header. Messages reuse the `zg_ai_proto` JSON codecs; unknown
//! record types decode to `unknown` and are skipped by readers, so later
//! versions stay readable. See `docs/session-format.md`.

const std = @import("std");
const proto = @import("zg_ai_proto");

const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const json = proto.json;

/// The schema version written by this code.
pub const version: u32 = 1;

/// Where a forked session branches off its parent.
pub const Parent = struct {
    session: proto.SessionId,
    /// Records with `seq <= at_seq` come from the parent.
    seq: u64,
    /// The parent's records were copied into this file (a fork chain
    /// deeper than 32); the parent is not read.
    materialized: bool = false,
};

/// Who started the session.
pub const Origin = enum { gui, cli, subagent, schedule };

/// The first line of every session file.
pub const Header = struct {
    session: proto.SessionId,
    parent: ?Parent = null,
    created_ms: i64,
    cwd: []const u8,
    workspace_key: []const u8,
    prompt_version: []const u8 = "",
    app_version: []const u8 = "",
    origin: Origin = .gui,
    /// The model at creation.
    model: []const u8 = "",
};

/// A harness event worth keeping: mode/model changes, approvals, hook
/// outcomes. `data_json` is a JSON value (object) or empty.
pub const StoredEvent = struct {
    kind: []const u8,
    data_json: []const u8 = "",
};

/// Usage of one model request.
pub const UsageRecord = struct {
    model: []const u8,
    usage: proto.Usage,
    cost_micros: u64 = 0,
    estimated: bool = false,
};

/// A compaction: the active history restarts at `head_seq`.
pub const CompactionRecord = struct {
    head_seq: u64,
    trigger: []const u8,
    tokens_before: u64 = 0,
    tokens_after: u64 = 0,
    model: []const u8 = "",
};

/// An E12 checkpoint taken at the start of a user turn.
pub const CheckpointRef = struct {
    id: u64,
    turn: u32,
    label: []const u8 = "",
};

/// The conversation head moved back to `to_seq`.
pub const RewindRecord = struct {
    to_seq: u64,
    action: []const u8,
};

/// The session ended cleanly.
pub const EndRecord = struct {
    reason: []const u8 = "exit",
};

/// One line of a session file.
pub const Record = union(enum) {
    header: Header,
    user: proto.Message,
    assistant: proto.Message,
    /// A user-role message carrying tool results.
    tool_results: proto.Message,
    event: StoredEvent,
    usage: UsageRecord,
    compaction: CompactionRecord,
    checkpoint: CheckpointRef,
    rewind: RewindRecord,
    title: []const u8,
    end: EndRecord,
    /// A record type this version does not know (skipped).
    unknown: []const u8,

    /// The message of `user`, `assistant` and `tool_results` records.
    pub fn message(r: Record) ?proto.Message {
        return switch (r) {
            .user, .assistant, .tool_results => |m| m,
            else => null,
        };
    }

    /// The record type for a committed message.
    pub fn fromMessage(m: proto.Message) Record {
        if (m.role == .assistant) return .{ .assistant = m };
        for (m.content) |b| if (b == .tool_result) return .{ .tool_results = m };
        return .{ .user = m };
    }
};

/// A record with its sequence number and time.
pub const Line = struct {
    seq: u64,
    t: i64,
    record: Record,
};

/// The message lines still active after the `rewind` records of `lines`
/// (file order): a rewind to `to_seq` drops the messages after `to_seq`
/// written before it. Rewound records stay in the file.
pub fn activeMessages(a: Allocator, lines: []const Line) Allocator.Error![]const Line {
    var out: std.ArrayList(Line) = .empty;
    for (lines) |l| switch (l.record) {
        .user, .assistant, .tool_results => try out.append(a, l),
        .rewind => |r| {
            while (out.items.len > 0 and out.items[out.items.len - 1].seq > r.to_seq) out.items.len -= 1;
        },
        else => {},
    };
    return out.items;
}

/// Writes `l` as one JSON line (with the trailing `\n`).
pub fn encode(w: *std.Io.Writer, l: Line) std.Io.Writer.Error!void {
    var s: Stringify = .{ .writer = w, .options = .{ .emit_null_optional_fields = false } };
    try s.beginObject();
    try s.objectField("v");
    try s.write(version);
    try s.objectField("seq");
    try s.write(l.seq);
    try s.objectField("t");
    try s.write(l.t);
    try s.objectField("type");
    try s.write(@tagName(l.record));
    switch (l.record) {
        .header => |h| {
            const id = proto.agent_ref.format(h.session);
            try field(&s, "session", &id);
            if (h.parent) |p| {
                try s.objectField("parent");
                try s.beginObject();
                const pid = proto.agent_ref.format(p.session);
                try field(&s, "session", &pid);
                try field(&s, "seq", p.seq);
                if (p.materialized) try field(&s, "materialized", true);
                try s.endObject();
            }
            try field(&s, "created", h.created_ms);
            try field(&s, "cwd", h.cwd);
            try field(&s, "workspace_key", h.workspace_key);
            try field(&s, "prompt_version", h.prompt_version);
            try field(&s, "app_version", h.app_version);
            try field(&s, "origin", @tagName(h.origin));
            if (h.model.len > 0) try field(&s, "model", h.model);
        },
        .user, .assistant, .tool_results => |m| {
            try s.objectField("message");
            try json.writeMessage(&s, m);
        },
        .event => |e| {
            try field(&s, "kind", e.kind);
            if (e.data_json.len > 0) {
                try s.objectField("data");
                try json.writeRaw(&s, e.data_json);
            }
        },
        .usage => |u| {
            try field(&s, "model", u.model);
            try field(&s, "usage", u.usage);
            try field(&s, "cost_micros", u.cost_micros);
            if (u.estimated) try field(&s, "estimated", true);
        },
        .compaction => |c| inline for (std.meta.fields(CompactionRecord)) |f| try field(&s, f.name, @field(c, f.name)),
        .checkpoint => |c| inline for (std.meta.fields(CheckpointRef)) |f| try field(&s, f.name, @field(c, f.name)),
        .rewind => |r| inline for (std.meta.fields(RewindRecord)) |f| try field(&s, f.name, @field(r, f.name)),
        .end => |e| try field(&s, "reason", e.reason),
        .title => |t| try field(&s, "title", t),
        .unknown => {},
    }
    try s.endObject();
    try w.writeByte('\n');
}

fn field(s: *Stringify, name: []const u8, v: anytype) std.Io.Writer.Error!void {
    try s.objectField(name);
    try s.write(v);
}

/// Encodes into a fresh slice from `gpa`.
pub fn encodeAlloc(gpa: Allocator, l: Line) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    encode(&out.writer, l) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// Decoding failures.
pub const DecodeError = error{ InvalidRecord, OutOfMemory };

/// Decodes one line (without the `\n`). Strings point into `arena`.
pub fn decode(arena: Allocator, text: []const u8) DecodeError!Line {
    const v = json.parseValue(arena, text) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidRecord,
    };
    const o = json.asObject(v) orelse return error.InvalidRecord;
    const ty = json.str(o, "type") orelse return error.InvalidRecord;
    const seq = json.int(u64, o, "seq") orelse return error.InvalidRecord;
    const t = json.int(i64, o, "t") orelse 0;
    const Tag = std.meta.Tag(Record);
    const tag = std.meta.stringToEnum(Tag, ty) orelse return .{ .seq = seq, .t = t, .record = .{ .unknown = ty } };
    const rec: Record = switch (tag) {
        .header => blk: {
            var h: Header = .{
                .session = try ulid(o, "session"),
                .created_ms = json.int(i64, o, "created") orelse 0,
                .cwd = json.str(o, "cwd") orelse "",
                .workspace_key = json.str(o, "workspace_key") orelse "",
                .prompt_version = json.str(o, "prompt_version") orelse "",
                .app_version = json.str(o, "app_version") orelse "",
                .origin = std.meta.stringToEnum(Origin, json.str(o, "origin") orelse "gui") orelse .gui,
                .model = json.str(o, "model") orelse "",
            };
            if (o.get("parent")) |pv| if (json.asObject(pv)) |po| {
                h.parent = .{ .session = try ulid(po, "session"), .seq = json.int(u64, po, "seq") orelse return error.InvalidRecord, .materialized = json.boolean(po, "materialized") };
            };
            break :blk .{ .header = h };
        },
        .user, .assistant, .tool_results => blk: {
            const m = json.decodeMessage(arena, o.get("message") orelse return error.InvalidRecord) catch |e| return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidRecord,
            };
            break :blk switch (tag) {
                .user => .{ .user = m },
                .assistant => .{ .assistant = m },
                else => .{ .tool_results = m },
            };
        },
        .event => .{ .event = .{
            .kind = json.str(o, "kind") orelse return error.InvalidRecord,
            .data_json = if (o.get("data")) |d| try json.stringifyValue(arena, d) else "",
        } },
        .usage => .{ .usage = .{
            .model = json.str(o, "model") orelse "",
            .usage = if (o.get("usage")) |u| json.decodeValue(proto.Usage, arena, u) catch return error.InvalidRecord else .{},
            .cost_micros = json.int(u64, o, "cost_micros") orelse 0,
            .estimated = json.boolean(o, "estimated"),
        } },
        .compaction => .{ .compaction = .{
            .head_seq = json.int(u64, o, "head_seq") orelse return error.InvalidRecord,
            .trigger = json.str(o, "trigger") orelse "",
            .tokens_before = json.int(u64, o, "tokens_before") orelse 0,
            .tokens_after = json.int(u64, o, "tokens_after") orelse 0,
            .model = json.str(o, "model") orelse "",
        } },
        .checkpoint => .{ .checkpoint = .{
            .id = json.int(u64, o, "id") orelse return error.InvalidRecord,
            .turn = json.int(u32, o, "turn") orelse 0,
            .label = json.str(o, "label") orelse "",
        } },
        .rewind => .{ .rewind = .{
            .to_seq = json.int(u64, o, "to_seq") orelse return error.InvalidRecord,
            .action = json.str(o, "action") orelse "conversation",
        } },
        .title => .{ .title = json.str(o, "title") orelse return error.InvalidRecord },
        .end => .{ .end = .{ .reason = json.str(o, "reason") orelse "exit" } },
        .unknown => .{ .unknown = ty },
    };
    return .{ .seq = seq, .t = t, .record = rec };
}

fn ulid(o: std.json.ObjectMap, key: []const u8) DecodeError!proto.SessionId {
    const s = json.str(o, key) orelse return error.InvalidRecord;
    return proto.agent_ref.parse(s) catch error.InvalidRecord;
}

test "record round trip" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const lines = [_]Line{
        .{ .seq = 0, .t = 1, .record = .{ .header = .{ .session = 42, .parent = .{ .session = 7, .seq = 9 }, .created_ms = 1, .cwd = "/w", .workspace_key = "w-0123456789abcdef", .origin = .cli, .model = "m" } } },
        .{ .seq = 1, .t = 2, .record = .{ .user = .{ .role = .user, .content = &.{.{ .text = .{ .text = "hi" } }} } } },
        .{ .seq = 2, .t = 3, .record = .{ .event = .{ .kind = "mode", .data_json = "{\"mode\":\"plan\"}" } } },
        .{ .seq = 3, .t = 4, .record = .{ .usage = .{ .model = "m", .usage = .{ .input = 5, .output = 6 }, .cost_micros = 7 } } },
        .{ .seq = 4, .t = 5, .record = .{ .compaction = .{ .head_seq = 3, .trigger = "manual" } } },
        .{ .seq = 5, .t = 6, .record = .{ .title = "T" } },
        .{ .seq = 6, .t = 7, .record = .{ .rewind = .{ .to_seq = 1, .action = "conversation" } } },
        .{ .seq = 7, .t = 8, .record = .{ .checkpoint = .{ .id = 3, .turn = 1, .label = "fix" } } },
        .{ .seq = 8, .t = 9, .record = .{ .end = .{} } },
    };
    for (lines) |l| {
        const text = try encodeAlloc(a, l);
        try std.testing.expect(std.mem.endsWith(u8, text, "\n"));
        const back = try decode(a, text[0 .. text.len - 1]);
        try std.testing.expectEqualStrings(text, try encodeAlloc(a, back));
    }
    const unk = try decode(a, "{\"v\":2,\"seq\":3,\"t\":0,\"type\":\"future_thing\",\"x\":1}");
    try std.testing.expectEqualStrings("future_thing", unk.record.unknown);
    try std.testing.expectError(error.InvalidRecord, decode(a, "{\"v\":1,\"type\":\"title\"}"));
    try std.testing.expectError(error.InvalidRecord, decode(a, "{\"v\":1,\"seq\":1,"));
}
