//! GitHub REST shapes for issues (E13.F03.S03.T01): what the client
//! returns and sends. Responses are decoded leniently (unknown fields
//! ignored, missing ones defaulted); requests carry only the fields set.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Repo = struct {
    owner: []const u8,
    name: []const u8,

    /// GitHub owner and repository names: letters, digits, `-`, `_` and
    /// `.`, never `.` or `..` (anything else could escape the URL path).
    pub fn isValid(r: Repo) bool {
        return validName(r.owner) and validName(r.name);
    }

    fn validName(s: []const u8) bool {
        if (s.len == 0 or s.len > 100) return false;
        if (std.mem.eql(u8, s, ".") or std.mem.eql(u8, s, "..")) return false;
        for (s) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.')) return false;
        return true;
    }
};

pub const State = enum { open, closed };

pub const Issue = struct {
    number: u32,
    title: []const u8,
    body: ?[]const u8,
    state: State,
    /// `completed`, `not_planned`, `reopened` or `duplicate`.
    state_reason: ?[]const u8,
    labels: []const []const u8,
    /// Logins.
    assignees: []const []const u8,
    updated_at: []const u8,
    created_at: []const u8 = "",
    html_url: []const u8 = "",
    is_pull_request: bool,
};

/// A create or a partial update; null fields are left out.
pub const IssueWrite = struct {
    title: ?[]const u8 = null,
    body: ?[]const u8 = null,
    /// `open` or `closed`.
    state: ?[]const u8 = null,
    state_reason: ?[]const u8 = null,
    labels: ?[]const []const u8 = null,
    assignees: ?[]const []const u8 = null,

    /// The JSON request body.
    pub fn encode(w: IssueWrite, a: Allocator) Allocator.Error![]u8 {
        return std.json.Stringify.valueAlloc(a, w, .{ .emit_null_optional_fields = false });
    }
};

pub const ListQuery = struct {
    state: enum { open, closed, all } = .all,
    /// ISO 8601: only issues updated at or after it (incremental pulls).
    since: ?[]const u8 = null,
    /// Comma-separated label names an issue must all have.
    labels: ?[]const u8 = null,
    /// At most 100.
    per_page: u8 = 100,
};

/// The wire form of an issue.
const RawIssue = struct {
    number: u32,
    title: []const u8 = "",
    body: ?[]const u8 = null,
    state: []const u8 = "open",
    state_reason: ?[]const u8 = null,
    labels: []const RawLabel = &.{},
    assignees: []const RawUser = &.{},
    updated_at: []const u8 = "",
    created_at: []const u8 = "",
    html_url: []const u8 = "",
    /// Present (an object) on pull requests only.
    pull_request: ?std.json.Value = null,
};
const RawLabel = struct { name: []const u8 = "" };
const RawUser = struct { login: []const u8 = "" };

const parse_opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true, .allocate = .alloc_always };

pub const DecodeError = error{InvalidResponse} || Allocator.Error;

/// One issue; strings in `a`.
pub fn decodeIssue(a: Allocator, json: []const u8) DecodeError!Issue {
    const raw = std.json.parseFromSliceLeaky(RawIssue, a, json, parse_opts) catch |e| return mapErr(e);
    return convert(a, raw);
}

/// A list of issues; strings in `a`.
pub fn decodeIssues(a: Allocator, json: []const u8) DecodeError![]Issue {
    const raws = std.json.parseFromSliceLeaky([]const RawIssue, a, json, parse_opts) catch |e| return mapErr(e);
    const out = try a.alloc(Issue, raws.len);
    for (raws, out) |r, *o| o.* = try convert(a, r);
    return out;
}

/// GitHub's error `message`, if the body has one.
pub fn errorMessage(a: Allocator, json: []const u8) ?[]const u8 {
    const E = struct { message: []const u8 = "" };
    const e = std.json.parseFromSliceLeaky(E, a, json, parse_opts) catch return null;
    return if (e.message.len > 0) e.message else null;
}

fn mapErr(e: anyerror) DecodeError {
    return if (e == error.OutOfMemory) error.OutOfMemory else error.InvalidResponse;
}

fn convert(a: Allocator, r: RawIssue) Allocator.Error!Issue {
    const labels = try a.alloc([]const u8, r.labels.len);
    for (r.labels, labels) |l, *o| o.* = l.name;
    const assignees = try a.alloc([]const u8, r.assignees.len);
    for (r.assignees, assignees) |u, *o| o.* = u.login;
    return .{
        .number = r.number,
        .title = r.title,
        .body = r.body,
        .state = if (std.mem.eql(u8, r.state, "closed")) .closed else .open,
        .state_reason = r.state_reason,
        .labels = labels,
        .assignees = assignees,
        .updated_at = r.updated_at,
        .created_at = r.created_at,
        .html_url = r.html_url,
        .is_pull_request = if (r.pull_request) |p| p != .null else false,
    };
}

test "decode an issue and a pull request" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const list = try decodeIssues(a,
        \\[{"number":7,"title":"Crash","body":null,"state":"closed","state_reason":"completed",
        \\  "labels":[{"id":1,"name":"bug"},{"name":"P1"}],"assignees":[{"login":"octo"}],
        \\  "updated_at":"2026-10-01T00:00:00Z","user":{"login":"x"},"reactions":{"+1":0}},
        \\ {"number":8,"title":"PR","state":"open","pull_request":{"url":"u"}}]
    );
    try std.testing.expectEqual(2, list.len);
    try std.testing.expectEqual(State.closed, list[0].state);
    try std.testing.expectEqualStrings("P1", list[0].labels[1]);
    try std.testing.expectEqualStrings("octo", list[0].assignees[0]);
    try std.testing.expect(list[0].body == null and !list[0].is_pull_request);
    try std.testing.expect(list[1].is_pull_request);
    try std.testing.expectError(error.InvalidResponse, decodeIssue(a, "{\"title\":\"no number\"}"));
    try std.testing.expectEqualStrings("Bad credentials", errorMessage(a, "{\"message\":\"Bad credentials\",\"status\":\"401\"}").?);
}

test "write bodies leave out unset fields" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const w: IssueWrite = .{ .state = "closed", .labels = &.{ "a", "b" } };
    try std.testing.expectEqualStrings("{\"state\":\"closed\",\"labels\":[\"a\",\"b\"]}", try w.encode(arena.allocator()));
}

test "repo names" {
    try std.testing.expect((Repo{ .owner = "ChristianPresley", .name = "zig-guro.v2_x" }).isValid());
    for ([_][]const u8{ "", ".", "..", "a/b", "a?b", "a b", "a%2f" }) |bad|
        try std.testing.expect(!(Repo{ .owner = "o", .name = bad }).isValid());
}
