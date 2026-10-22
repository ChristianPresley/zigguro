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
const AgentRef = proto.AgentRef;
const pull = @import("pull.zig");
const Pull = pull.Pull;

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

pub const ParseError = pull.Error;

/// Reads a provenance object off `p`, copying strings into `arena`.
/// Keys may come in any order; `null` values count as absent.
pub fn readProvenance(arena: Allocator, p: *Pull) ParseError!Provenance {
    var origin: ?Origin = null;
    var label: ?[]const u8 = null;
    var rationale: ?[]const u8 = null;
    var calls: std.ArrayList([]const u8) = .empty;
    var workspace: ?[]const u8 = null;
    var lane: ?[]const u8 = null;
    var created_ms: ?i64 = null;
    try p.expect(.object_begin);
    while (try p.key()) |k| {
        if (try p.isNull()) continue;
        if (eql(k, "origin")) {
            origin = try readOrigin(arena, p);
        } else if (eql(k, "label")) {
            label = try arena.dupe(u8, try p.str());
        } else if (eql(k, "rationale")) {
            rationale = try arena.dupe(u8, try p.str());
        } else if (eql(k, "tool_calls")) {
            try p.expect(.array_begin);
            while (try p.more()) try calls.append(arena, try arena.dupe(u8, try p.str()));
        } else if (eql(k, "workspace")) {
            workspace = try arena.dupe(u8, try p.str());
        } else if (eql(k, "lane")) {
            lane = try arena.dupe(u8, try p.str());
        } else if (eql(k, "created_ms")) {
            created_ms = try p.int(i64);
        } else try p.skip();
    }
    return .{
        .origin = origin orelse return error.InvalidRecord,
        .label = label orelse return error.InvalidRecord,
        .rationale = rationale,
        .tool_calls = calls.items,
        .workspace = workspace orelse return error.InvalidRecord,
        .lane = lane,
        .created_ms = created_ms orelse return error.InvalidRecord,
    };
}

/// Parses one provenance object's JSON text (see `readProvenance`).
pub fn parseProvenanceJson(arena: Allocator, json: []const u8) ParseError!Provenance {
    var p: Pull = .init(arena, json);
    const out = try readProvenance(arena, &p);
    try p.expect(.end);
    return out;
}

/// The variant's fields follow its `"type"`, which may come anywhere in
/// the object: the type is found first, then the object read again.
fn readOrigin(arena: Allocator, p: *Pull) ParseError!Origin {
    const text = try p.raw();
    var scan: Pull = .init(p.a, text);
    const tag = blk: {
        try scan.expect(.object_begin);
        while (try scan.key()) |k| {
            if (eql(k, "type")) break :blk try scan.enumOf(std.meta.Tag(Origin));
            try scan.skip();
        }
        return error.InvalidRecord;
    };
    switch (tag) {
        inline else => |t| {
            const P = @FieldType(Origin, @tagName(t));
            const fields = std.meta.fields(P);
            var out: P = undefined;
            var seen: [fields.len]bool = @splat(false);
            var r: Pull = .init(p.a, text);
            try r.expect(.object_begin);
            keys: while (try r.key()) |k| {
                if (try r.isNull()) continue;
                inline for (fields, 0..) |f, i| if (eql(k, f.name)) {
                    @field(out, f.name) = switch (f.type) {
                        AgentRef, ?AgentRef => try readRef(arena, &r),
                        ScmKind => try r.enumOf(ScmKind),
                        []const u8 => try arena.dupe(u8, try r.str()),
                        u32, u64 => try r.int(f.type),
                        else => @compileError("unhandled origin field " ++ f.name),
                    };
                    seen[i] = true;
                    continue :keys;
                };
                try r.skip();
            }
            inline for (fields, 0..) |f, i| if (!seen[i]) {
                if (f.type != ?AgentRef) return error.InvalidRecord;
                @field(out, f.name) = null;
            };
            return @unionInit(Origin, @tagName(t), out);
        },
    }
}

fn readRef(arena: Allocator, p: *Pull) ParseError!AgentRef {
    var session: ?@FieldType(AgentRef, "session") = null;
    var agent: u32 = 0;
    var tool_call: ?[]const u8 = null;
    try p.expect(.object_begin);
    while (try p.key()) |k| {
        if (try p.isNull()) continue;
        if (eql(k, "session")) {
            session = proto.agent_ref.parse(try p.str()) catch return error.InvalidRecord;
        } else if (eql(k, "agent")) {
            agent = try p.int(u32);
        } else if (eql(k, "tool_call")) {
            tool_call = try arena.dupe(u8, try p.str());
        } else try p.skip();
    }
    return .{ .session = session orelse return error.InvalidRecord, .agent = agent, .tool_call = tool_call };
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
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
    const back = try parseProvenanceJson(arena.allocator(), want);
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
    const p = try parseProvenanceJson(a,
        \\{"origin":{"x":[1],"finding":3,"type":"code_review"},"label":"L","workspace":"/w","created_ms":1,"future":{"y":null},"lane":null}
    );
    try testing.expectEqual(@as(u64, 3), p.origin.code_review.finding);
    try testing.expectEqual(@as(usize, 0), p.tool_calls.len);
    try testing.expectEqual(@as(?[]const u8, null), p.lane);
    for ([_][]const u8{
        \\{"origin":{"type":"nope"},"label":"L","workspace":"/w","created_ms":1}
        ,
        \\{"origin":{"type":"code_review"},"label":"L","workspace":"/w","created_ms":1}
        ,
        \\{"origin":{"type":"lsp","server":"s"},"workspace":"/w","created_ms":1}
        ,
        \\{"origin":{"type":"agent","ref":{"agent":1},"turn":1,"model":"m"},"label":"L","workspace":"/w","created_ms":1}
    }) |bad| try testing.expectError(error.InvalidRecord, parseProvenanceJson(a, bad));
    const lsp = try parseProvenanceJson(a,
        \\{"origin":{"server":"s","type":"lsp"},"label":"L","workspace":"/w","created_ms":1}
    );
    try testing.expectEqual(@as(?AgentRef, null), lsp.origin.lsp.agent);
}

test "provenance: turn label" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("Turn 7: Fix it", try turnLabel(arena.allocator(), 7, "  Fix it\nmore", 80));
    try testing.expectEqualStrings("Turn 1: ab", try turnLabel(arena.allocator(), 1, "ab\u{e9}", 10));
}
