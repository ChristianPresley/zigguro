//! Provenance records (E09.F05): who wrote a set of lines. A record names
//! an actor (a human, an agent with its model, session, turn and tool
//! call, a deterministic tool, or an import), when it was first seen, the
//! prompt under the configured privacy level, the review decision that
//! let it in, and for mixed lines the record it modified. Records are
//! store objects (`Kind.prov_record`); attribution maps point at them.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const enc = @import("../store/encode.zig");
const ObjectId = id_mod.ObjectId;
const Kind = id_mod.Kind;
const Allocator = std.mem.Allocator;

/// A record's ID.
pub const ProvenanceId = ObjectId;

pub const ActorKind = enum(u8) { human = 0, agent = 1, tool = 2, imported = 3, unknown = 4 };

/// Where an `imported` actor came from.
pub const ImportSource = enum(u8) { none = 0, git_unknown = 1, agent_trace = 2, git_ai = 3 };

/// Who wrote lines. Fields not used by `kind` stay empty.
pub const Actor = struct {
    kind: ActorKind,
    /// human: display name; agent: agent name; tool: "lsp.rename",
    /// "formatter:zig fmt"; imported: the original author.
    name: []const u8 = "",
    /// human and imported: e-mail.
    email: []const u8 = "",
    /// agent: "provider/model" (models.dev convention, as Agent Trace).
    model_id: []const u8 = "",
    session_id: []const u8 = "",
    turn_id: []const u8 = "",
    tool_call_id: []const u8 = "",
    /// tool: the record of whoever ran the tool.
    triggered_by: ?ProvenanceId = null,
    imported: ImportSource = .none,

    pub const unknown: Actor = .{ .kind = .unknown };

    pub fn human(name: []const u8, email: []const u8) Actor {
        return .{ .kind = .human, .name = name, .email = email };
    }

    pub fn agent(name: []const u8, model_id: []const u8, session_id: []const u8) Actor {
        return .{ .kind = .agent, .name = name, .model_id = model_id, .session_id = session_id };
    }

    pub fn tool(name: []const u8) Actor {
        return .{ .kind = .tool, .name = name };
    }

    pub fn eql(a: Actor, b: Actor) bool {
        inline for (@typeInfo(Actor).@"struct".fields) |f| {
            const x = @field(a, f.name);
            const y = @field(b, f.name);
            const same = switch (f.type) {
                []const u8 => std.mem.eql(u8, x, y),
                ?ProvenanceId => if (x) |xx| (if (y) |yy| xx.eql(yy) else false) else y == null,
                else => x == y,
            };
            if (!same) return false;
        }
        return true;
    }

    /// Copies the strings into `gpa`; free with `free`.
    pub fn dupe(a: Actor, gpa: Allocator) Allocator.Error!Actor {
        var out = a;
        inline for (@typeInfo(Actor).@"struct".fields) |f| {
            if (f.type == []const u8) @field(out, f.name) = try gpa.dupe(u8, @field(a, f.name));
        }
        return out;
    }

    pub fn free(a: Actor, gpa: Allocator) void {
        inline for (@typeInfo(Actor).@"struct".fields) |f| {
            if (f.type == []const u8) gpa.free(@field(a, f.name));
        }
    }
};

/// How much of a prompt is kept (setting `scm.provenance.prompt_privacy`).
pub const PromptPrivacy = enum(u8) {
    /// Nothing.
    none = 0,
    /// The BLAKE3 hash only.
    hash = 1,
    /// The first bytes, redacted.
    excerpt = 2,
    /// The whole prompt as a separate `text` object (not exported unless
    /// `scm.provenance.export_prompts`).
    full = 3,
};

pub const PromptRef = struct {
    privacy: PromptPrivacy,
    /// BLAKE3-256 of the prompt (`hash`, `excerpt`, `full`).
    hash: ?ObjectId = null,
    /// `excerpt`: the redacted first bytes.
    excerpt: []const u8 = "",
    /// `full`: the `text` object holding the prompt.
    text: ?ObjectId = null,
};

/// The E12 decision that accepted the lines.
pub const ReviewRef = struct {
    review_id: u64,
    /// False when a human edited the proposal before accepting it.
    verbatim: bool = true,
};

pub const ProvenanceRecord = struct {
    pub const kind: Kind = .prov_record;

    actor: Actor,
    created_ms: i64,
    prompt: ?PromptRef = null,
    review: ?ReviewRef = null,
    /// For mixed lines: the record of the lines this one modified.
    parent: ?ProvenanceId = null,
    extra: []const object.Extra = &.{},

    pub fn validate(r: ProvenanceRecord) object.ValidateError!void {
        try object.validateExtra(r.extra);
        if (r.prompt) |p| switch (p.privacy) {
            .none => if (p.hash != null or p.excerpt.len > 0 or p.text != null) return error.InvalidProvenance,
            .hash => if (p.hash == null or p.excerpt.len > 0 or p.text != null) return error.InvalidProvenance,
            .excerpt => if (p.text != null) return error.InvalidProvenance,
            .full => if (p.text == null) return error.InvalidProvenance,
        };
    }
};

/// The record's ID (without writing it).
pub fn idOf(gpa: Allocator, r: ProvenanceRecord) !ProvenanceId {
    return enc.idOf(gpa, ProvenanceRecord, r);
}

/// BLAKE3-256 of `text`, as stored in `PromptRef.hash`.
pub fn promptHash(text: []const u8) ObjectId {
    var out: ObjectId = undefined;
    std.crypto.hash.Blake3.hash(text, &out.bytes, .{});
    return out;
}

/// The objects a record keeps alive (for GC).
pub fn edges(r: ProvenanceRecord, ctx: anytype, add: anytype) !void {
    if (r.parent) |p| try add(ctx, p);
    if (r.actor.triggered_by) |p| try add(ctx, p);
    if (r.prompt) |p| if (p.text) |t| try add(ctx, t);
}

const testing = std.testing;

test "record: encoding roundtrip and validation" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var ag = Actor.agent("claude", "anthropic/claude-x", "s-1");
    ag.turn_id = "t-3";
    const r: ProvenanceRecord = .{
        .actor = ag,
        .created_ms = 1234,
        .prompt = .{ .privacy = .excerpt, .hash = promptHash("fix it"), .excerpt = "fix it" },
        .review = .{ .review_id = 7 },
    };
    const bytes = try enc.encodeAlloc(a, ProvenanceRecord, r);
    const back = try enc.decode(ProvenanceRecord, a, bytes);
    try testing.expect(back.actor.eql(ag));
    try testing.expectEqualStrings("fix it", back.prompt.?.excerpt);
    try testing.expectEqual(@as(u64, 7), back.review.?.review_id);
    try testing.expect((try idOf(a, r)).eql(id_mod.hashObject(.prov_record, bytes)));

    const bad: ProvenanceRecord = .{ .actor = .unknown, .created_ms = 0, .prompt = .{ .privacy = .full } };
    try testing.expectError(error.InvalidProvenance, enc.encodeAlloc(a, ProvenanceRecord, bad));
}
