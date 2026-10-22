//! Test doubles for consumers of zg_security (E16.F01.S01.T02). They let
//! E06/E08/E10/E11/E12 write tests against the shared contracts before (and
//! independently of) the real engine, approval broker and redactor.

const std = @import("std");
const Allocator = std.mem.Allocator;
const contracts = @import("../contracts.zig");

/// The minimal engine interface consumers hold: one `decide` call.
/// `policy.Engine.iface()` returns the real one.
pub const EngineIface = struct {
    ctx: *anyopaque,
    decide: *const fn (*anyopaque, *const contracts.ToolRequest) contracts.Decision,

    /// Decides `req`.
    pub fn check(e: EngineIface, req: *const contracts.ToolRequest) contracts.Decision {
        return e.decide(e.ctx, req);
    }
};

var allow_all_ctx: u8 = 0;

/// An engine that allows everything.
///
/// ```zig
/// const e = fakes.allowAll();
/// try std.testing.expect(e.check(&req) == .allow);
/// ```
pub fn allowAll() EngineIface {
    return .{ .ctx = &allow_all_ctx, .decide = struct {
        fn f(_: *anyopaque, _: *const contracts.ToolRequest) contracts.Decision {
            return .allow;
        }
    }.f };
}

/// An engine that denies everything with `reason` (comptime, so the
/// interface needs no storage).
///
/// ```zig
/// const e = fakes.denyAll("blocked by test");
/// try std.testing.expectEqualStrings("blocked by test", e.check(&req).deny);
/// ```
pub fn denyAll(comptime reason: []const u8) EngineIface {
    return .{ .ctx = &allow_all_ctx, .decide = struct {
        fn f(_: *anyopaque, _: *const contracts.ToolRequest) contracts.Decision {
            return .{ .deny = reason };
        }
    }.f };
}

/// Decides from a table keyed by tool name; unknown tools get `fallback`.
///
/// ```zig
/// var s: fakes.ScriptedEngine = .init(gpa, &.{.{ .tool = "read_file", .decision = .allow }});
/// try std.testing.expect(s.engine().check(&req) == .allow);
/// ```
pub const ScriptedEngine = struct {
    gpa: Allocator,
    script: []const Entry,
    fallback: contracts.Decision = .{ .deny = "not in script" },
    /// Requests seen, by tool name (borrowed from the callers).
    seen: std.ArrayList([]const u8) = .empty,

    /// One scripted decision.
    pub const Entry = struct { tool: []const u8, decision: contracts.Decision };

    /// A scripted engine over `script` (borrowed).
    pub fn init(gpa: Allocator, script: []const Entry) ScriptedEngine {
        return .{ .gpa = gpa, .script = script };
    }

    /// Frees the record of seen requests.
    pub fn deinit(self: *ScriptedEngine) void {
        self.seen.deinit(self.gpa);
    }

    /// The engine interface.
    pub fn engine(self: *ScriptedEngine) EngineIface {
        return .{ .ctx = self, .decide = decide };
    }

    fn decide(ctx: *anyopaque, req: *const contracts.ToolRequest) contracts.Decision {
        const self: *ScriptedEngine = @ptrCast(@alignCast(ctx));
        self.seen.append(self.gpa, req.tool) catch {};
        for (self.script) |e| if (std.mem.eql(u8, e.tool, req.tool)) return e.decision;
        return self.fallback;
    }
};

/// An approval port that answers from a queue and records what it showed.
///
/// ```zig
/// var fp: fakes.FakeApprovalPort = .{ .gpa = gpa };
/// defer fp.deinit();
/// try fp.answers.append(gpa, .allow_once);
/// const t = try fp.port().present(req);
/// try std.testing.expect(try t.await(io) == .allow_once);
/// ```
pub const FakeApprovalPort = struct {
    gpa: Allocator,
    /// Answers handed out in order; when empty, `await` answers `deny`.
    answers: std.ArrayList(contracts.Answer) = .empty,
    presented: std.ArrayList(contracts.ApprovalRequest) = .empty,
    cancelled: std.ArrayList(u64) = .empty,
    next_id: u64 = 1,

    /// Frees the queues.
    pub fn deinit(self: *FakeApprovalPort) void {
        self.answers.deinit(self.gpa);
        self.presented.deinit(self.gpa);
        self.cancelled.deinit(self.gpa);
    }

    /// The port interface.
    pub fn port(self: *FakeApprovalPort) contracts.ApprovalPort {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: contracts.ApprovalPort.VTable = .{ .present = present, .await = await, .cancel = cancel };

    fn present(ctx: *anyopaque, req: contracts.ApprovalRequest) anyerror!u64 {
        const self: *FakeApprovalPort = @ptrCast(@alignCast(ctx));
        try self.presented.append(self.gpa, req);
        defer self.next_id += 1;
        return self.next_id;
    }

    fn await(ctx: *anyopaque, id: u64, io: std.Io) std.Io.Cancelable!contracts.Answer {
        _ = id;
        _ = io;
        const self: *FakeApprovalPort = @ptrCast(@alignCast(ctx));
        if (self.answers.items.len == 0) return .{ .deny = "no scripted answer" };
        return self.answers.orderedRemove(0);
    }

    fn cancel(ctx: *anyopaque, id: u64) void {
        const self: *FakeApprovalPort = @ptrCast(@alignCast(ctx));
        self.cancelled.append(self.gpa, id) catch {};
    }
};

/// A redactor that changes nothing.
///
/// ```zig
/// var r: fakes.IdentityRedactor = .{};
/// try std.testing.expectEqual(0, r.redactor().redact(r.redactor().ctx, text, &out));
/// ```
pub const IdentityRedactor = struct {
    _unused: u8 = 0,

    /// The redactor interface.
    pub fn redactor(self: *IdentityRedactor) contracts.Redactor {
        return .{ .ctx = self, .redact = redact };
    }

    fn redact(_: *anyopaque, _: []u8, _: *std.ArrayList(u8)) u32 {
        return 0;
    }
};

/// A redactor that overwrites every occurrence of one planted value with
/// `*` in place and returns the count.
///
/// ```zig
/// var r: fakes.MarkerRedactor = .{ .needle = "sk-planted" };
/// const n = r.redactor().redact(r.redactor().ctx, text, &out); // text now has "**********"
/// ```
pub const MarkerRedactor = struct {
    needle: []const u8,

    /// The redactor interface.
    pub fn redactor(self: *MarkerRedactor) contracts.Redactor {
        return .{ .ctx = self, .redact = redact };
    }

    fn redact(ctx: *anyopaque, text: []u8, _: *std.ArrayList(u8)) u32 {
        const self: *MarkerRedactor = @ptrCast(@alignCast(ctx));
        if (self.needle.len == 0) return 0;
        var n: u32 = 0;
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, text, i, self.needle)) |at| {
            @memset(text[at..][0..self.needle.len], '*');
            i = at + self.needle.len;
            n += 1;
        }
        return n;
    }
};

/// A trust query that answers one fixed state for every path.
///
/// ```zig
/// var t: fakes.StaticTrust = .{ .state = .restricted };
/// try std.testing.expectEqual(.restricted, t.query().stateOf(t.query().ctx, "/w"));
/// ```
pub const StaticTrust = struct {
    state: contracts.TrustState,

    /// The trust query interface.
    pub fn query(self: *StaticTrust) contracts.TrustQuery {
        return .{ .ctx = self, .stateOf = stateOf };
    }

    fn stateOf(ctx: *anyopaque, _: []const u8) contracts.TrustState {
        const self: *StaticTrust = @ptrCast(@alignCast(ctx));
        return self.state;
    }
};

/// An audit sink that keeps records in memory (tests only; slices in the
/// records are borrowed from the caller).
pub const MemoryAuditSink = struct {
    gpa: Allocator,
    records: std.ArrayList(contracts.AuditRecord) = .empty,

    /// Frees the records.
    pub fn deinit(self: *MemoryAuditSink) void {
        self.records.deinit(self.gpa);
    }

    /// The sink interface.
    pub fn sink(self: *MemoryAuditSink) contracts.AuditSink {
        return .{ .ctx = self, .append = append };
    }

    fn append(ctx: *anyopaque, rec: *const contracts.AuditRecord) void {
        const self: *MemoryAuditSink = @ptrCast(@alignCast(ctx));
        self.records.append(self.gpa, rec.*) catch {};
    }
};

fn testRequest(tool: []const u8) contracts.ToolRequest {
    return .{ .actor = .system, .tool = tool, .input_json = "{}", .effects = .{}, .resources = &.{}, .mode = .default };
}

test "fakes: denyAll blocks and returns reason" {
    const e = denyAll("blocked by test");
    const req = testRequest("bash");
    try std.testing.expectEqualStrings("blocked by test", e.check(&req).deny);
    try std.testing.expect(allowAll().check(&req) == .allow);
}

test "fakes: scripted engine table lookup" {
    var s: ScriptedEngine = .init(std.testing.allocator, &.{
        .{ .tool = "read_file", .decision = .allow },
        .{ .tool = "bash", .decision = .{ .deny = "no shell" } },
    });
    defer s.deinit();
    const e = s.engine();
    try std.testing.expect(e.check(&testRequest("read_file")) == .allow);
    try std.testing.expectEqualStrings("no shell", e.check(&testRequest("bash")).deny);
    try std.testing.expectEqualStrings("not in script", e.check(&testRequest("web_fetch")).deny);
    try std.testing.expectEqual(3, s.seen.items.len);
}

test "contracts: approval ticket forwards to port" {
    const gpa = std.testing.allocator;
    var fp: FakeApprovalPort = .{ .gpa = gpa };
    defer fp.deinit();
    try fp.answers.append(gpa, .{ .allow_session = "Bash(ls:*)" });
    const t = try fp.port().present(.{ .kind = .command, .actor = .system, .title = "Run ls", .detail_json = "{}", .created_ms = 0 });
    try std.testing.expectEqual(1, t.id);
    try std.testing.expectEqualStrings("Bash(ls:*)", (try t.await(std.testing.io)).allow_session);
    try std.testing.expectEqualStrings("no scripted answer", (try t.await(std.testing.io)).deny);
    t.cancel();
    try std.testing.expectEqualSlices(u64, &.{1}, fp.cancelled.items);
    try std.testing.expectEqualStrings("Run ls", fp.presented.items[0].title);
}

test "fakes: marker redactor replaces planted value and counts" {
    var buf = "key=sk-planted and sk-planted again".*;
    var out: std.ArrayList(u8) = .empty;
    var m: MarkerRedactor = .{ .needle = "sk-planted" };
    const r = m.redactor();
    try std.testing.expectEqual(2, r.redact(r.ctx, &buf, &out));
    try std.testing.expectEqualStrings("key=********** and ********** again", &buf);
    var id: IdentityRedactor = .{};
    try std.testing.expectEqual(0, id.redactor().redact(&id, &buf, &out));
}

test "fakes: static trust" {
    var t: StaticTrust = .{ .state = .restricted };
    const q = t.query();
    try std.testing.expectEqual(contracts.TrustState.restricted, q.stateOf(q.ctx, "/w"));
}
