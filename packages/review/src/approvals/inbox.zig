//! The approvals inbox model (E12.F05.S02.T01): the items the broker
//! hosts, as every view sees them (E10's agent cards, the review panel's
//! inbox, toasts, `zg review approvals`). Pure.
//!
//! Requests and answers are E16's `zg_security.contracts` types; E12 has no
//! copy of them.

const std = @import("std");
const zg_security = @import("zg_security");

const Allocator = std.mem.Allocator;
const contracts = zg_security.contracts;
pub const ApprovalRequest = contracts.ApprovalRequest;
pub const Answer = contracts.Answer;

pub const ApprovalId = enum(u64) {
    _,

    /// Writes `!<n>` (changesets are `#<n>`).
    pub fn format(id: ApprovalId, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("!{d}", .{@intFromEnum(id)});
    }
};

pub const ApprovalState = enum {
    pending,
    allowed_once,
    allowed_session,
    allowed_always,
    denied,
    edited_allowed,
    cancelled,
    /// Timed out, or left pending by a process that is gone.
    expired,

    /// The state an answer leads to.
    pub fn of(a: Answer) ApprovalState {
        return switch (a) {
            .allow_once => .allowed_once,
            .allow_session => .allowed_session,
            .allow_always => .allowed_always,
            .deny => .denied,
            .edit => .edited_allowed,
        };
    }

    /// Hidden from views (the card disappears).
    pub fn isClosed(s: ApprovalState) bool {
        return s == .cancelled;
    }

    /// "Allowed once", "Denied", ... for cards ("… by you").
    pub fn label(s: ApprovalState) []const u8 {
        return switch (s) {
            .pending => "Waiting",
            .allowed_once => "Allowed once",
            .allowed_session => "Allowed for the session",
            .allowed_always => "Always allowed",
            .denied => "Denied",
            .edited_allowed => "Edited and allowed",
            .cancelled => "Cancelled",
            .expired => "Expired",
        };
    }
};

/// One request as views show it. Strings live as long as the item (see
/// `ApprovalBroker.prune`).
pub const InboxItem = struct {
    id: ApprovalId,
    req: ApprovalRequest,
    state: ApprovalState,
    /// The view that answered (for example "inbox", "agent-pane", "cli").
    answered_by: ?[]const u8 = null,
    answered_ms: ?i64 = null,
    /// The answer, once there is one.
    answer: ?Answer = null,
    /// The request this one re-asks (an edited input that still needed
    /// approval).
    previous: ?ApprovalId = null,

    /// The agent's session, for per-agent filters.
    pub fn session(it: *const InboxItem) ?[]const u8 {
        return switch (it.req.actor) {
            .agent => |a| a.session,
            else => null,
        };
    }
};

/// Called after an item is added or changes state, outside the broker's
/// lock, on the thread that made the change. Views post a redraw.
pub const InboxListener = struct {
    ctx: *anyopaque,
    changed: *const fn (*anyopaque, id: ApprovalId, state: ApprovalState) void,
};

/// Which items a view lists.
pub const Filter = struct {
    /// Only this agent session's requests (an agent pane).
    session: ?[]const u8 = null,
    /// Also answered and expired ones (history); cancelled ones never.
    answered: bool = true,
};

pub fn matches(f: Filter, it: *const InboxItem) bool {
    if (it.state.isClosed()) return false;
    if (!f.answered and it.state != .pending) return false;
    if (f.session) |s| return std.mem.eql(u8, it.session() orelse return false, s);
    return true;
}

/// Inbox order: pending first, then oldest first, then by id.
pub fn lessThan(_: void, a: InboxItem, b: InboxItem) bool {
    const pa = a.state == .pending;
    const pb = b.state == .pending;
    if (pa != pb) return pa;
    if (a.req.created_ms != b.req.created_ms) return a.req.created_ms < b.req.created_ms;
    return @intFromEnum(a.id) < @intFromEnum(b.id);
}

/// A command request, for display.
pub const CommandView = struct {
    line: []const u8,
    cwd: ?[]const u8 = null,
    /// E06 terminal id.
    terminal: ?u64 = null,
    shell: ?[]const u8 = null,
};

/// `req.command` with `cwd`, `terminal` and `shell` taken from
/// `req.detail_json` when present; null for requests without a command.
/// Malformed detail JSON only drops those fields.
pub fn commandView(req: *const ApprovalRequest, arena: Allocator) Allocator.Error!?CommandView {
    const line = req.command orelse return null;
    var v: CommandView = .{ .line = line };
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, req.detail_json, .{}) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return v,
    };
    if (parsed != .object) return v;
    const o = parsed.object;
    if (o.get("cwd")) |c| if (c == .string) {
        v.cwd = c.string;
    };
    if (o.get("shell")) |c| if (c == .string) {
        v.shell = c.string;
    };
    if (o.get("terminal")) |c| switch (c) {
        .integer => |i| v.terminal = std.math.cast(u64, i),
        else => {},
    };
    return v;
}

test "inbox: command view from detail json" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var req: ApprovalRequest = .{
        .kind = .command,
        .actor = .system,
        .title = "Run command",
        .detail_json = "{\"cwd\":\"/ws\",\"terminal\":3,\"shell\":\"bash\",\"x\":[1]}",
        .command = "cargo test --release",
        .created_ms = 0,
    };
    const v = (try commandView(&req, a)).?;
    try std.testing.expectEqualStrings("cargo test --release", v.line);
    try std.testing.expectEqualStrings("/ws", v.cwd.?);
    try std.testing.expectEqual(@as(?u64, 3), v.terminal);
    try std.testing.expectEqualStrings("bash", v.shell.?);
    req.detail_json = "not json";
    try std.testing.expectEqual(@as(?[]const u8, null), (try commandView(&req, a)).?.cwd);
    req.command = null;
    try std.testing.expectEqual(@as(?CommandView, null), try commandView(&req, a));
}
