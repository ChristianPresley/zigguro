//! Who made a changeset and why (E12.F01.S01.T01), with its stable JSON
//! form (used by the store and `zg review`).
//!
//! JSON: snake_case keys in declaration order; the origin is an object
//! whose `"type"` names the variant. `AgentRef.session` is the 26-char
//! Crockford base32 ULID. Unknown keys are ignored when parsing.

const std = @import("std");
const proto = @import("zg_ai_proto");

const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const Value = std.json.Value;
const AgentRef = proto.AgentRef;

pub const ScmKind = enum { describe, split, resolve, land };

/// What produced the change.
pub const Origin = union(enum) {
    /// An agent's edit tools during one turn.
    agent: struct { ref: AgentRef, turn: u32, model: []const u8 },
    /// Ctrl/Cmd+K (F06).
    inline_edit: struct { ref: AgentRef, instruction: []const u8 },
    /// An LSP WorkspaceEdit (E07), agent-triggered or previewed.
    lsp: struct { server: []const u8, agent: ?AgentRef = null },
    /// Replace across files (E08.F05).
    search_replace: struct { query: []const u8, agent: ?AgentRef = null },
    /// Note link updates (E08.F06/F08).
    notes: struct { tx: u64, agent: ?AgentRef = null },
    /// An AI SCM proposal (E09.F06).
    scm_proposal: struct { kind: ScmKind, review: u64 },
    /// An accepted code-review suggestion (F08).
    code_review: struct { finding: u64 },
    /// A user command that asks for a preview.
    user_bulk: struct { command: []const u8 },

    /// The agent behind the change, if any.
    pub fn agentRef(o: Origin) ?AgentRef {
        return switch (o) {
            .agent => |a| a.ref,
            .inline_edit => |a| a.ref,
            .lsp => |a| a.agent,
            .search_replace => |a| a.agent,
            .notes => |a| a.agent,
            .scm_proposal, .code_review, .user_bulk => null,
        };
    }
};

pub const Provenance = struct {
    origin: Origin,
    /// One line for lists, e.g. "Turn 7: Fix the parser".
    label: []const u8,
    rationale: ?[]const u8 = null,
    /// Ids of the tool calls whose edits are in the changeset.
    tool_calls: []const []const u8 = &.{},
    /// The workspace root.
    workspace: []const u8,
    /// E09 lane, if the change targets one.
    lane: ?[]const u8 = null,
    created_ms: i64,
};

/// The label for an agent turn: "Turn <n>: <first line of `message`>",
/// cut to `max` bytes on a UTF-8 boundary.
pub fn turnLabel(arena: Allocator, turn: u32, message: []const u8, max: usize) Allocator.Error![]const u8 {
    const first = std.mem.trim(u8, message[0 .. std.mem.indexOfAny(u8, message, "\r\n") orelse message.len], " \t");
    var s = try std.fmt.allocPrint(arena, "Turn {d}: {s}", .{ turn, first });
    if (s.len > max) {
        var n = max;
        while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
        s = s[0..n];
    }
    return s;
}

/// Writes `p` as one compact JSON object.
pub fn writeProvenanceJson(w: *std.Io.Writer, p: Provenance) Stringify.Error!void {
    var s: Stringify = .{ .writer = w };
    try writeProvenance(&s, p);
}

/// `writeProvenanceJson` into an existing `Stringify`.
pub fn writeProvenance(s: *Stringify, p: Provenance) Stringify.Error!void {
    try s.beginObject();
    try s.objectField("origin");
    try writeOrigin(s, p.origin);
    try s.objectField("label");
    try s.write(p.label);
    if (p.rationale) |r| {
        try s.objectField("rationale");
        try s.write(r);
    }
    try s.objectField("tool_calls");
    try s.write(p.tool_calls);
    try s.objectField("workspace");
    try s.write(p.workspace);
    if (p.lane) |l| {
        try s.objectField("lane");
        try s.write(l);
    }
    try s.objectField("created_ms");
    try s.write(p.created_ms);
    try s.endObject();
}

fn writeOrigin(s: *Stringify, o: Origin) Stringify.Error!void {
    try s.beginObject();
    try s.objectField("type");
    try s.write(@tagName(o));
    switch (o) {
        inline else => |v| inline for (std.meta.fields(@TypeOf(v))) |f| {
            const x = @field(v, f.name);
            switch (f.type) {
                AgentRef => {
                    try s.objectField(f.name);
                    try writeRef(s, x);
                },
                ?AgentRef => if (x) |r| {
                    try s.objectField(f.name);
                    try writeRef(s, r);
                },
                ScmKind => {
                    try s.objectField(f.name);
                    try s.write(@tagName(x));
                },
                else => {
                    try s.objectField(f.name);
                    try s.write(x);
                },
            }
        },
    }
    try s.endObject();
}

fn writeRef(s: *Stringify, r: AgentRef) Stringify.Error!void {
    try s.beginObject();
    try s.objectField("session");
    try s.write(&proto.agent_ref.format(r.session));
    try s.objectField("agent");
    try s.write(r.agent);
    if (r.tool_call) |t| {
        try s.objectField("tool_call");
        try s.write(t);
    }
    try s.endObject();
}

pub const ParseError = error{ InvalidProvenance, OutOfMemory };

/// Parses the object `v` (from `std.json`), copying strings into `arena`.
pub fn parseProvenanceJson(arena: Allocator, v: Value) ParseError!Provenance {
    const o = try object(v);
    const calls_v = try array(o.get("tool_calls") orelse Value{ .array = .init(arena) });
    const calls = try arena.alloc([]const u8, calls_v.items.len);
    for (calls, calls_v.items) |*c, x| c.* = try dupe(arena, x);
    return .{
        .origin = try parseOrigin(arena, o.get("origin") orelse return error.InvalidProvenance),
        .label = try dupe(arena, o.get("label") orelse return error.InvalidProvenance),
        .rationale = try optStr(arena, o.get("rationale")),
        .tool_calls = calls,
        .workspace = try dupe(arena, o.get("workspace") orelse return error.InvalidProvenance),
        .lane = try optStr(arena, o.get("lane")),
        .created_ms = try int(i64, o.get("created_ms") orelse return error.InvalidProvenance),
    };
}

fn parseOrigin(arena: Allocator, v: Value) ParseError!Origin {
    const o = try object(v);
    const tag_name = try str(o.get("type") orelse return error.InvalidProvenance);
    const tag = std.meta.stringToEnum(std.meta.Tag(Origin), tag_name) orelse return error.InvalidProvenance;
    switch (tag) {
        inline else => |t| {
            const P = @FieldType(Origin, @tagName(t));
            var out: P = undefined;
            inline for (std.meta.fields(P)) |f| {
                const x = o.get(f.name);
                @field(out, f.name) = switch (f.type) {
                    AgentRef => try parseRef(arena, x orelse return error.InvalidProvenance),
                    ?AgentRef => if (x) |r| try parseRef(arena, r) else null,
                    ScmKind => std.meta.stringToEnum(ScmKind, try str(x orelse return error.InvalidProvenance)) orelse return error.InvalidProvenance,
                    []const u8 => try dupe(arena, x orelse return error.InvalidProvenance),
                    u32, u64 => try int(f.type, x orelse return error.InvalidProvenance),
                    else => @compileError("unhandled origin field " ++ f.name),
                };
            }
            return @unionInit(Origin, @tagName(t), out);
        },
    }
}

fn parseRef(arena: Allocator, v: Value) ParseError!AgentRef {
    const o = try object(v);
    return .{
        .session = proto.agent_ref.parse(try str(o.get("session") orelse return error.InvalidProvenance)) catch return error.InvalidProvenance,
        .agent = if (o.get("agent")) |a| try int(u32, a) else 0,
        .tool_call = try optStr(arena, o.get("tool_call")),
    };
}

fn object(v: Value) ParseError!std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => error.InvalidProvenance,
    };
}

fn array(v: Value) ParseError!std.json.Array {
    return switch (v) {
        .array => |a| a,
        else => error.InvalidProvenance,
    };
}

fn str(v: Value) ParseError![]const u8 {
    return switch (v) {
        .string => |s| s,
        else => error.InvalidProvenance,
    };
}

fn dupe(arena: Allocator, v: Value) ParseError![]const u8 {
    return arena.dupe(u8, try str(v));
}

fn optStr(arena: Allocator, v: ?Value) ParseError!?[]const u8 {
    const x = v orelse return null;
    if (x == .null) return null;
    return try dupe(arena, x);
}

fn int(comptime T: type, v: Value) ParseError!T {
    return switch (v) {
        .integer => |i| std.math.cast(T, i) orelse error.InvalidProvenance,
        .number_string => |s| std.fmt.parseInt(T, s, 10) catch error.InvalidProvenance,
        else => error.InvalidProvenance,
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn roundTrip(p: Provenance, want: []const u8) !void {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try writeProvenanceJson(&aw.writer, p);
    try testing.expectEqualStrings(want, aw.written());

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const v = try std.json.parseFromSliceLeaky(Value, arena.allocator(), want, .{});
    const back = try parseProvenanceJson(arena.allocator(), v);
    var aw2: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw2.deinit();
    try writeProvenanceJson(&aw2.writer, back);
    try testing.expectEqualStrings(want, aw2.written());
}

test "provenance: json golden round trip" {
    const session = try proto.agent_ref.parse("01JABCDEFGHJKMNPQRSTVWXYZ0");
    try roundTrip(.{
        .origin = .{ .agent = .{ .ref = .{ .session = session, .agent = 2, .tool_call = "toolu_1" }, .turn = 7, .model = "claude-x" } },
        .label = "Turn 7: Fix the parser",
        .tool_calls = &.{ "toolu_1", "toolu_2" },
        .workspace = "/w",
        .created_ms = 1_700_000_000_000,
    },
        \\{"origin":{"type":"agent","ref":{"session":"01JABCDEFGHJKMNPQRSTVWXYZ0","agent":2,"tool_call":"toolu_1"},"turn":7,"model":"claude-x"},"label":"Turn 7: Fix the parser","tool_calls":["toolu_1","toolu_2"],"workspace":"/w","created_ms":1700000000000}
    );
    try roundTrip(.{
        .origin = .{ .scm_proposal = .{ .kind = .split, .review = 9 } },
        .label = "Split",
        .rationale = "too big",
        .workspace = "/w",
        .lane = "main",
        .created_ms = 5,
    },
        \\{"origin":{"type":"scm_proposal","kind":"split","review":9},"label":"Split","rationale":"too big","tool_calls":[],"workspace":"/w","lane":"main","created_ms":5}
    );
    try roundTrip(.{ .origin = .{ .search_replace = .{ .query = "foo" } }, .label = "Replace", .workspace = "/w", .created_ms = 0 },
        \\{"origin":{"type":"search_replace","query":"foo"},"label":"Replace","tool_calls":[],"workspace":"/w","created_ms":0}
    );
}

test "provenance: unknown keys ignored, bad input rejected" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = try std.json.parseFromSliceLeaky(Value, a,
        \\{"origin":{"type":"code_review","finding":3,"x":1},"label":"L","workspace":"/w","created_ms":1,"future":true}
    , .{});
    const p = try parseProvenanceJson(a, ok);
    try testing.expectEqual(@as(u64, 3), p.origin.code_review.finding);
    try testing.expectEqual(@as(usize, 0), p.tool_calls.len);
    const bad = try std.json.parseFromSliceLeaky(Value, a,
        \\{"origin":{"type":"nope"},"label":"L","workspace":"/w","created_ms":1}
    , .{});
    try testing.expectError(error.InvalidProvenance, parseProvenanceJson(a, bad));
}

test "provenance: turn label" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("Turn 7: Fix it", try turnLabel(arena.allocator(), 7, "  Fix it\nmore", 80));
    try testing.expectEqualStrings("Turn 1: ab", try turnLabel(arena.allocator(), 1, "ab\u{e9}", 10));
}
