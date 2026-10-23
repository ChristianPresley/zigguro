//! The run model (E13.F01.S01.T01): one durable record per unit of agent
//! work, above E10's `Agent`. Ids, kinds, the status state machine, the
//! spec a run was started with, and what it cost and produced. Pure: no
//! I/O, std only.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// 48-bit Unix-ms timestamp (big-endian) followed by 80 random bits, so ids
/// sort by creation time both as bytes and as their 26-char text form.
pub const RunId = struct {
    bytes: [16]u8,

    pub const zero: RunId = .{ .bytes = @splat(0) };

    /// An id for timestamp `ms` with 80 bits from `random`.
    pub fn generateAt(ms: u64, random: std.Random) RunId {
        var id: RunId = undefined;
        std.mem.writeInt(u48, id.bytes[0..6], @truncate(ms), .big);
        random.bytes(id.bytes[6..]);
        return id;
    }

    /// An id for now (`Clock.real`), with random bits from `io.random`.
    pub fn generate(io: std.Io) RunId {
        const now = std.Io.Clock.real.now(io);
        const ms: u64 = @intCast(@max(0, @divFloor(now.nanoseconds, std.time.ns_per_ms)));
        var seed: [8]u8 = undefined;
        io.random(&seed);
        var prng: std.Random.DefaultPrng = .init(std.mem.readInt(u64, &seed, .little));
        return generateAt(ms, prng.random());
    }

    pub fn timestampMs(id: RunId) u64 {
        return std.mem.readInt(u48, id.bytes[0..6], .big);
    }

    pub fn toInt(id: RunId) u128 {
        return std.mem.readInt(u128, &id.bytes, .big);
    }

    pub fn fromInt(v: u128) RunId {
        var id: RunId = undefined;
        std.mem.writeInt(u128, &id.bytes, v, .big);
        return id;
    }

    pub fn eql(a: RunId, b: RunId) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    pub fn order(a: RunId, b: RunId) std.math.Order {
        return std.mem.order(u8, &a.bytes, &b.bytes);
    }

    /// The 26-char Crockford base32 text form.
    pub fn text(id: RunId) [26]u8 {
        var out: [26]u8 = undefined;
        var v = id.toInt();
        var i: usize = 26;
        while (i > 0) {
            i -= 1;
            out[i] = crockford[@intCast(v & 31)];
            v >>= 5;
        }
        return out;
    }

    /// The last 8 chars of the text form (lane names, short labels).
    pub fn short(id: RunId) [8]u8 {
        return id.text()[18..26].*;
    }

    pub fn format(id: RunId, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(&id.text());
    }

    /// Parses the text form (case-insensitive; I/L read as 1, O as 0).
    pub fn parse(s: []const u8) error{InvalidRunId}!RunId {
        if (s.len != 26) return error.InvalidRunId;
        var v: u128 = 0;
        for (s, 0..) |c0, i| {
            const c = std.ascii.toUpper(c0);
            const d: u8 = switch (c) {
                '0'...'9' => c - '0',
                'O' => 0,
                'I', 'L' => 1,
                else => @intCast(std.mem.indexOfScalar(u8, crockford, c) orelse return error.InvalidRunId),
            };
            if (i == 0 and d > 7) return error.InvalidRunId;
            v = (v << 5) | d;
        }
        return fromInt(v);
    }

    /// JSON: the text form.
    pub fn jsonStringify(id: RunId, jw: anytype) !void {
        try jw.write(&id.text());
    }

    pub fn jsonParse(a: Allocator, source: anytype, options: std.json.ParseOptions) !RunId {
        const s = try std.json.innerParse([]const u8, a, source, options);
        return parse(s) catch error.UnexpectedToken;
    }

    pub fn jsonParseFromValue(a: Allocator, source: std.json.Value, options: std.json.ParseOptions) !RunId {
        _ = a;
        _ = options;
        return switch (source) {
            .string => |s| parse(s) catch error.UnexpectedToken,
            else => error.UnexpectedToken,
        };
    }
};

const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

/// Why a run exists. Order is also the queue priority (lower first), see
/// `queue.zig`.
pub const RunKind = enum(u8) { interactive, background, scheduled, triggered, workflow, workflow_worker, task };

pub const RunStatus = enum(u8) {
    queued,
    starting,
    working,
    needs_input,
    paused,
    completed,
    failed,
    stopped,
    interrupted,

    pub fn isTerminal(s: RunStatus) bool {
        return switch (s) {
            .completed, .failed, .stopped, .interrupted => true,
            else => false,
        };
    }

    /// Whether the run holds a host slot (`queue.zig`).
    pub fn holdsSlot(s: RunStatus) bool {
        return switch (s) {
            .starting, .working, .needs_input => true,
            else => false,
        };
    }
};

const n_status = @typeInfo(RunStatus).@"enum".fields.len;

/// `allowed[from][to]`. Terminal states are final except
/// `interrupted -> starting` (resume); any non-terminal state may become
/// `interrupted` (crash recovery only).
pub const allowed: [n_status][n_status]bool = blk: {
    var t: [n_status][n_status]bool = @splat(@splat(false));
    const S = RunStatus;
    const edges = [_][2]S{
        .{ .queued, .starting },     .{ .queued, .stopped },
        .{ .starting, .working },    .{ .starting, .failed },
        .{ .starting, .stopped },    .{ .working, .needs_input },
        .{ .working, .paused },      .{ .working, .completed },
        .{ .working, .failed },      .{ .working, .stopped },
        .{ .needs_input, .working }, .{ .needs_input, .stopped },
        .{ .needs_input, .failed },  .{ .paused, .working },
        .{ .paused, .stopped },      .{ .interrupted, .starting },
        // A paused run resumes through `starting` when its agent is gone.
        .{ .paused, .starting },
    };
    for (edges) |e| t[@intFromEnum(e[0])][@intFromEnum(e[1])] = true;
    for (std.enums.values(S)) |s| {
        if (!s.isTerminal()) t[@intFromEnum(s)][@intFromEnum(S.interrupted)] = true;
    }
    break :blk t;
};

pub fn canTransition(from: RunStatus, to: RunStatus) bool {
    return allowed[@intFromEnum(from)][@intFromEnum(to)];
}

/// Who or what started a run.
pub const Origin = union(enum) {
    user,
    cli,
    automation: struct { name: []const u8, fire_id: []const u8 = "" },
    workflow: struct { run: RunId, step: []const u8 },
    task: struct { id: []const u8 },
};

pub const Isolation = enum { shared, lane };

/// Spend limits, mirroring E10's `Budgets` (kept here so the registry stays
/// independent of the agent loop).
pub const Budgets = struct {
    max_turns: ?u32 = null,
    max_wall_ms: ?u64 = null,
    max_cost_micros: ?u64 = null,
};

/// How a run was asked for. Strings are borrowed by `RunHost.start`; the
/// registry stores its own copy.
pub const RunSpec = struct {
    kind: RunKind,
    title: []const u8,
    /// The user prompt (E10 `UserInput.text`).
    prompt: []const u8,
    /// E10 agent definition name.
    agent_def: ?[]const u8 = null,
    model: ?[]const u8 = null,
    /// E16 permission profile.
    profile: []const u8 = "default",
    isolation: Isolation = .shared,
    origin: Origin = .user,
    budgets: Budgets = .{},
    parent: ?RunId = null,
    tags: []const []const u8 = &.{},
    /// Trigger data (webhooks, issues): sent to the model as data, never as
    /// instructions (`untrusted.zig`).
    untrusted_payload: ?[]const u8 = null,
    /// E09 workspace/project id (E13.F09 groups runs by project).
    project: ?[]const u8 = null,
};

pub const Cost = struct {
    micros: u64 = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
};

/// Something a run produced.
pub const Output = union(enum) {
    /// An E12 changeset id.
    changeset: u64,
    /// An E13.F07 artifact id.
    artifact: []const u8,
    file: []const u8,
    /// An E13.F03 task id.
    task: []const u8,
    pr: struct { url: []const u8, number: u32 },
    note: []const u8,
};

pub const RunRecord = struct {
    id: RunId,
    spec: RunSpec,
    status: RunStatus = .queued,
    /// E10 session id (ULID) once the agent exists.
    session: ?u128 = null,
    /// E09 lane name when `isolation == .lane`.
    lane: ?[]const u8 = null,
    created_ms: i64,
    started_ms: ?i64 = null,
    ended_ms: ?i64 = null,
    /// One line: the last assistant text, at most 200 bytes.
    summary: []const u8 = "",
    /// Set while `needs_input`.
    question: ?[]const u8 = null,
    cost: Cost = .{},
    outputs: []const Output = &.{},
    error_: ?[]const u8 = null,
    /// Bumped by every change; the journal line sequence number.
    /// Pinned to the top of Mission Control.
    pinned: bool = false,
    revision: u64 = 1,
};

/// What `RunRegistry.update` changes.
pub const Update = union(enum) {
    status: RunStatus,
    summary: []const u8,
    question: ?[]const u8,
    cost: Cost,
    output: Output,
    session: u128,
    lane: []const u8,
    error_: []const u8,
    started: i64,
    ended: i64,
    /// Renames the run (`spec.title`).
    title: []const u8,
    pinned: bool,
};

pub const EventKind = enum { created, status, summary, cost, output, question, removed, changed };

pub const RunEvent = struct { run: RunId, revision: u64, kind: EventKind };

/// Deep copy of `v` into `a`: every slice is duplicated. For the run model's
/// plain data (structs, unions, optionals, slices, scalars).
pub fn deepClone(comptime T: type, a: Allocator, v: T) Allocator.Error!T {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size != .slice) @compileError("deepClone: only slices");
            const out = try a.alloc(p.child, v.len);
            if (comptime isPlain(p.child)) {
                @memcpy(out, v);
            } else for (v, out) |x, *o| {
                o.* = try deepClone(p.child, a, x);
            }
            return if (p.sentinel_ptr != null) @compileError("deepClone: no sentinels") else out;
        },
        .optional => |o| return if (v) |x| try deepClone(o.child, a, x) else null,
        .@"struct" => |s| {
            var out: T = v;
            inline for (s.fields) |f| {
                if (comptime !isPlain(f.type)) @field(out, f.name) = try deepClone(f.type, a, @field(v, f.name));
            }
            return out;
        },
        .@"union" => |u| {
            if (u.tag_type == null) @compileError("deepClone: untagged union");
            switch (v) {
                inline else => |payload, tag| {
                    const P = @TypeOf(payload);
                    return @unionInit(T, @tagName(tag), try deepClone(P, a, payload));
                },
            }
        },
        else => return v,
    }
}

fn isPlain(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => false,
        .optional => |o| isPlain(o.child),
        .@"struct" => |s| {
            inline for (s.fields) |f| if (!isPlain(f.type)) return false;
            return true;
        },
        .@"union" => |u| {
            inline for (u.fields) |f| if (!isPlain(f.type)) return false;
            return true;
        },
        else => true,
    };
}

/// One line, at most `max` bytes, cut on a UTF-8 boundary: the summary
/// form of an assistant message.
pub fn summarize(out: []u8, s: []const u8) []const u8 {
    var n: usize = 0;
    var last_space = false;
    var i: usize = 0;
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    while (i < trimmed.len and n < out.len) {
        const c = trimmed[i];
        const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        if (c == '\n' or c == '\r' or c == '\t' or c == ' ') {
            if (!last_space) {
                out[n] = ' ';
                n += 1;
            }
            last_space = true;
            i += 1;
            continue;
        }
        if (n + len > out.len or i + len > trimmed.len) break;
        @memcpy(out[n..][0..len], trimmed[i..][0..len]);
        n += len;
        i += len;
        last_space = false;
    }
    return out[0..n];
}

const testing = std.testing;

test "runid_sortable_and_roundtrip" {
    var prng: std.Random.DefaultPrng = .init(7);
    const n = 100_000;
    const ids = try testing.allocator.alloc(RunId, n);
    defer testing.allocator.free(ids);
    var ms: u64 = 1_700_000_000_000;
    for (ids) |*id| {
        ms += prng.random().uintAtMost(u64, 2);
        id.* = RunId.generateAt(ms, prng.random());
    }
    // Stable sort by text equals sort by bytes.
    const texts = try testing.allocator.alloc([26]u8, n);
    defer testing.allocator.free(texts);
    for (ids, texts) |id, *t| {
        t.* = id.text();
        try testing.expect((try RunId.parse(&t.*)).eql(id));
    }
    for (1..n) |i| {
        const by_bytes = ids[i - 1].order(ids[i]);
        const by_text = std.mem.order(u8, &texts[i - 1], &texts[i]);
        try testing.expectEqual(by_bytes, by_text);
        try testing.expect(ids[i - 1].timestampMs() <= ids[i].timestampMs());
    }
    try testing.expectError(error.InvalidRunId, RunId.parse("8ZZZZZZZZZZZZZZZZZZZZZZZZZ"));
    try testing.expectError(error.InvalidRunId, RunId.parse("short"));
}

test "transition_table_exhaustive" {
    const S = RunStatus;
    var count: usize = 0;
    for (std.enums.values(S)) |from| for (std.enums.values(S)) |to| {
        const ok = canTransition(from, to);
        if (ok) count += 1;
        if (from.isTerminal() and ok) {
            try testing.expect(from == .interrupted and to == .starting);
        }
        if (to == .interrupted) try testing.expectEqual(!from.isTerminal(), ok);
        if (from == to) try testing.expect(!ok);
    };
    try testing.expectEqual(@as(usize, 22), count);
    try testing.expect(canTransition(.working, .needs_input));
    try testing.expect(canTransition(.needs_input, .working));
    try testing.expect(!canTransition(.queued, .working));
    try testing.expect(!canTransition(.completed, .working));
}

test "deepClone copies every slice" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var title = "t".*;
    const tags = [_][]const u8{"a"};
    const outs = [_]Output{ .{ .file = "f" }, .{ .changeset = 3 } };
    const r: RunRecord = .{
        .id = .zero,
        .spec = .{ .kind = .background, .title = &title, .prompt = "p", .tags = &tags, .origin = .{ .automation = .{ .name = "n" } } },
        .created_ms = 1,
        .outputs = &outs,
    };
    const c = try deepClone(RunRecord, arena.allocator(), r);
    title[0] = 'x';
    try testing.expectEqualStrings("t", c.spec.title);
    try testing.expect(c.spec.tags[0].ptr != tags[0].ptr);
    try testing.expectEqualStrings("n", c.spec.origin.automation.name);
    try testing.expectEqual(@as(u64, 3), c.outputs[1].changeset);
}

test "summarize keeps one line and cuts on a char boundary" {
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("a b c", summarize(&buf, "  a\n\nb\tc  "));
    try testing.expectEqualStrings("1234567", summarize(&buf, "1234567é"));
}
