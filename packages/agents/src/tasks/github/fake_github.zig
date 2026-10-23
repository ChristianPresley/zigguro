//! An in-memory GitHub issues API behind a `zg_ai.Transport`, for the
//! sync tests: list (with `since`, `labels`, `state`, pagination and
//! ETags), get, create and update. Each write advances a fake clock so
//! `updated_at` orders changes.

const std = @import("std");
const zg_ai = @import("zg_ai");

const Allocator = std.mem.Allocator;
const tp = zg_ai.transport;

pub const FakeIssue = struct {
    number: u32 = 0,
    title: []const u8,
    body: ?[]const u8 = null,
    closed: bool = false,
    state_reason: ?[]const u8 = null,
    labels: []const []const u8 = &.{},
    assignees: []const []const u8 = &.{},
    updated_at: []const u8 = "",
    pull_request: bool = false,
    deleted: bool = false,
};

pub const Seen = struct { method: tp.Method, url: []const u8, body: []const u8 };

pub const FakeGitHub = struct {
    arena: std.heap.ArenaAllocator,
    issues: std.ArrayList(FakeIssue) = .empty,
    seen: std.ArrayList(Seen) = .empty,
    /// Seconds after 2026-10-22T10:00:00Z.
    tick: u32 = 0,
    per_page: u32 = 100,

    pub fn init(gpa: Allocator) FakeGitHub {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(f: *FakeGitHub) void {
        f.arena.deinit();
    }

    pub fn transport(f: *FakeGitHub) tp.Transport {
        return .{ .ptr = f, .vtable = &.{ .send = send } };
    }

    fn now(f: *FakeGitHub) []const u8 {
        f.tick += 1;
        return std.fmt.allocPrint(f.arena.allocator(), "2026-10-22T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ 10 + f.tick / 3600, f.tick / 60 % 60, f.tick % 60 }) catch unreachable;
    }

    /// Adds an issue as if someone opened it on GitHub.
    pub fn add(f: *FakeGitHub, i: FakeIssue) *FakeIssue {
        const a = f.arena.allocator();
        var x = i;
        x.number = if (i.number != 0) i.number else @intCast(f.issues.items.len + 1);
        x.title = a.dupe(u8, i.title) catch unreachable;
        x.labels = a.dupe([]const u8, i.labels) catch unreachable;
        x.assignees = a.dupe([]const u8, i.assignees) catch unreachable;
        x.updated_at = f.now();
        f.issues.append(a, x) catch unreachable;
        return &f.issues.items[f.issues.items.len - 1];
    }

    pub fn get(f: *FakeGitHub, n: u32) *FakeIssue {
        for (f.issues.items) |*i| if (i.number == n) return i;
        unreachable;
    }

    /// Marks issue `n` changed (after a test edits it).
    pub fn touch(f: *FakeGitHub, n: u32) void {
        f.get(n).updated_at = f.now();
    }

    pub fn count(f: *const FakeGitHub, method: tp.Method) usize {
        var c: usize = 0;
        for (f.seen.items) |s| c += @intFromBool(s.method == method);
        return c;
    }

    fn send(ptr: *anyopaque, _: std.Io, arena: Allocator, req: tp.HttpRequest, sink: tp.ChunkSink) tp.TransportError!tp.Head {
        const f: *FakeGitHub = @ptrCast(@alignCast(ptr));
        return f.serve(arena, req, sink) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.Network,
        };
    }

    fn serve(f: *FakeGitHub, arena: Allocator, req: tp.HttpRequest, sink: tp.ChunkSink) !tp.Head {
        const a = f.arena.allocator();
        try f.seen.append(a, .{ .method = req.method, .url = try a.dupe(u8, req.url), .body = try a.dupe(u8, req.body) });
        const path_start = std.mem.indexOf(u8, req.url, "/repos/") orelse std.mem.indexOf(u8, req.url, "/repositories/") orelse return error.Bad;
        const full = req.url[path_start..];
        const q = std.mem.indexOfScalar(u8, full, '?');
        const path = full[0 .. q orelse full.len];
        const query = if (q) |k| full[k + 1 ..] else "";
        var out: std.Io.Writer.Allocating = .init(arena);
        var headers: std.ArrayList(tp.Header) = .empty;
        var status: u16 = 200;
        const issues_at = std.mem.lastIndexOf(u8, path, "/issues") orelse return error.Bad;
        const rest = path[issues_at + "/issues".len ..];
        if (rest.len == 0 and req.method == .GET) {
            const since = param(query, "since");
            const labels = param(query, "labels");
            const page = if (param(query, "page")) |p| try std.fmt.parseInt(u32, p, 10) else 1;
            var matching: std.ArrayList(*const FakeIssue) = .empty;
            for (f.issues.items) |*i| {
                if (i.deleted) continue;
                if (since) |s| if (std.mem.order(u8, i.updated_at, try decode(arena, s)) == .lt) continue;
                if (labels) |ls| {
                    var it = std.mem.splitSequence(u8, try decode(arena, ls), ",");
                    const all = while (it.next()) |want| {
                        if (!hasLabel(i.labels, want)) break false;
                    } else true;
                    if (!all) continue;
                }
                try matching.append(arena, i);
            }
            std.mem.sort(*const FakeIssue, matching.items, {}, olderFirst);
            const from = @min((page - 1) * f.per_page, matching.items.len);
            const to = @min(from + f.per_page, matching.items.len);
            try out.writer.writeByte('[');
            for (matching.items[from..to], 0..) |i, k| {
                if (k > 0) try out.writer.writeByte(',');
                try writeIssue(&out.writer, i);
            }
            try out.writer.writeByte(']');
            const etag = try std.fmt.allocPrint(arena, "W/\"{x}\"", .{std.hash.XxHash3.hash(0, out.written())});
            if (headerValue(req.headers, "if-none-match")) |inm| if (std.mem.eql(u8, inm, etag)) return .{ .status = 304, .headers = try arena.dupe(tp.Header, &.{.{ .name = "ETag", .value = etag }}) };
            try headers.append(arena, .{ .name = "ETag", .value = etag });
            if (to < matching.items.len) try headers.append(arena, .{
                .name = "Link",
                .value = try std.fmt.allocPrint(arena, "<https://api.github.com/repositories/1/issues?{s}&page={d}>; rel=\"next\"", .{ stripPage(query), page + 1 }),
            });
        } else if (rest.len == 0 and req.method == .POST) {
            const w = try std.json.parseFromSliceLeaky(Write, a, req.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
            const i = f.add(.{ .number = 0, .title = w.title orelse "", .labels = w.labels orelse &.{}, .assignees = w.assignees orelse &.{} });
            i.body = w.body;
            try writeIssue(&out.writer, i);
            status = 201;
        } else {
            const n = try std.fmt.parseInt(u32, rest[1..], 10);
            const i = for (f.issues.items) |*x| {
                if (x.number == n) break x;
            } else return .{ .status = 404 };
            if (i.deleted) return .{ .status = 410 };
            if (req.method == .PATCH) {
                const w = try std.json.parseFromSliceLeaky(Write, a, req.body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
                if (w.title) |t| i.title = t;
                if (w.body) |b| i.body = b;
                if (w.state) |s| i.closed = std.mem.eql(u8, s, "closed");
                if (w.state_reason) |r| i.state_reason = if (std.mem.eql(u8, r, "reopened")) null else r;
                if (w.labels) |l| i.labels = l;
                if (w.assignees) |x| i.assignees = x;
                i.updated_at = f.now();
            }
            try writeIssue(&out.writer, i);
            try headers.append(arena, .{ .name = "ETag", .value = try std.fmt.allocPrint(arena, "\"{s}\"", .{i.updated_at}) });
        }
        sink.on_chunk(sink.ctx, out.written()) catch return error.Bad;
        return .{ .status = status, .headers = headers.items };
    }

    const Write = struct {
        title: ?[]const u8 = null,
        body: ?[]const u8 = null,
        state: ?[]const u8 = null,
        state_reason: ?[]const u8 = null,
        labels: ?[]const []const u8 = null,
        assignees: ?[]const []const u8 = null,
    };
};

fn olderFirst(_: void, x: *const FakeIssue, y: *const FakeIssue) bool {
    return switch (std.mem.order(u8, x.updated_at, y.updated_at)) {
        .lt => true,
        .gt => false,
        .eq => x.number < y.number,
    };
}

fn hasLabel(ls: []const []const u8, l: []const u8) bool {
    for (ls) |x| if (std.ascii.eqlIgnoreCase(x, l)) return true;
    return false;
}

fn writeIssue(w: *std.Io.Writer, i: *const FakeIssue) !void {
    var s: std.json.Stringify = .{ .writer = w };
    try s.beginObject();
    try s.objectField("number");
    try s.write(i.number);
    try s.objectField("title");
    try s.write(i.title);
    try s.objectField("body");
    try s.write(i.body);
    try s.objectField("state");
    try s.write(if (i.closed) "closed" else "open");
    try s.objectField("state_reason");
    try s.write(i.state_reason);
    try s.objectField("labels");
    try s.beginArray();
    for (i.labels) |l| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(l);
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("assignees");
    try s.beginArray();
    for (i.assignees) |l| {
        try s.beginObject();
        try s.objectField("login");
        try s.write(l);
        try s.endObject();
    }
    try s.endArray();
    try s.objectField("updated_at");
    try s.write(i.updated_at);
    if (i.pull_request) {
        try s.objectField("pull_request");
        try s.write(.{ .url = "https://api.github.com/pulls/1" });
    }
    try s.endObject();
}

fn param(query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        if (std.mem.eql(u8, kv[0..eq], name)) return kv[eq + 1 ..];
    }
    return null;
}

fn stripPage(query: []const u8) []const u8 {
    const k = std.mem.indexOf(u8, query, "&page=") orelse return query;
    return query[0..k];
}

fn decode(a: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            try out.append(a, try std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16));
            i += 2;
        } else try out.append(a, s[i]);
    }
    return out.items;
}

fn headerValue(hs: []const tp.Header, name: []const u8) ?[]const u8 {
    for (hs) |h| if (std.ascii.eqlIgnoreCase(h.name, name)) return h.value;
    return null;
}
