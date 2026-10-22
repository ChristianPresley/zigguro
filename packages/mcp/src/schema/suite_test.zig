//! `schema: JSON-Schema-Test-Suite`: runs the vendored official suite
//! (`testdata/json-schema-test-suite`, see its README) for draft 2020-12 and
//! draft-07, plus the elicitation formats with format assertion on. Remote
//! references are served from `remotes/` as `http://localhost:1234/`.
//! Cases listed in `expected-failures.txt` may fail; any other failure, or
//! a listed case that now passes, fails the test.

const std = @import("std");
const options = @import("zg_options");
const schema = @import("root.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const remote_prefix = "http://localhost:1234/";

const Remotes = struct {
    io: std.Io,
    dir: std.Io.Dir,

    fn fetch(ctx: ?*anyopaque, arena: Allocator, uri: []const u8) anyerror!?Value {
        const self: *Remotes = @ptrCast(@alignCast(ctx.?));
        if (!std.mem.startsWith(u8, uri, remote_prefix)) return null;
        const path = uri[remote_prefix.len..];
        const bytes = self.dir.readFileAlloc(self.io, path, arena, .limited(1 << 20)) catch return null;
        return try std.json.parseFromSliceLeaky(Value, arena, bytes, .{ .allocate = .alloc_always });
    }
};

const Run = struct {
    gpa: Allocator,
    io: std.Io,
    remotes: *Remotes,
    expected: std.StringHashMapUnmanaged(void) = .empty,
    seen_expected: std.StringHashMapUnmanaged(void) = .empty,
    failures: std.ArrayList([]const u8) = .empty,
    arena: std.heap.ArenaAllocator,
    cases: usize = 0,

    fn file(r: *Run, dir: std.Io.Dir, sub: []const u8, name: []const u8, dialect: schema.Dialect, fmt: schema.FormatAssertion) !void {
        const a = r.arena.allocator();
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ sub, name });
        const bytes = try dir.readFileAlloc(r.io, path, a, .limited(4 << 20));
        const groups = try std.json.parseFromSliceLeaky(Value, a, bytes, .{ .allocate = .alloc_always });
        for (groups.array.items) |g| {
            const gdesc = g.object.get("description").?.string;
            const compiled = schema.compile(r.gpa, g.object.get("schema").?, .{
                .default_dialect = dialect,
                .remote = .{ .ctx = r.remotes, .fetch = Remotes.fetch },
                .format_assertion = fmt,
            });
            defer if (compiled) |s| s.deinit() else |_| {};
            for (g.object.get("tests").?.array.items) |t| {
                r.cases += 1;
                const key = try std.fmt.allocPrint(a, "{s}: {s} / {s}", .{ path, gdesc, t.object.get("description").?.string });
                const want = t.object.get("valid").?.bool;
                const got: ?bool = if (compiled) |s| (schema.validate(s, r.gpa, t.object.get("data").?, null) catch null) else |_| null;
                const ok = got != null and got.? == want;
                if (r.expected.contains(key)) {
                    try r.seen_expected.put(a, key, {});
                    if (ok) try r.failures.append(a, try std.fmt.allocPrint(a, "unexpectedly passes (remove from expected-failures.txt): {s}", .{key}));
                    continue;
                }
                if (ok) continue;
                const why = if (compiled) |_| "wrong result" else |e| @errorName(e);
                try r.failures.append(a, try std.fmt.allocPrint(a, "{s} [{s}]", .{ key, why }));
            }
        }
    }

    fn directory(r: *Run, root: std.Io.Dir, sub: []const u8, dialect: schema.Dialect, fmt: schema.FormatAssertion, only: ?[]const []const u8) !void {
        var d = try root.openDir(r.io, sub, .{ .iterate = true });
        defer d.close(r.io);
        var names: std.ArrayList([]const u8) = .empty;
        var it = d.iterate();
        while (try it.next(r.io)) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".json")) continue;
            if (only) |list| {
                const keep = for (list) |n| {
                    if (std.mem.eql(u8, n, e.name)) break true;
                } else false;
                if (!keep) continue;
            }
            try names.append(r.arena.allocator(), try r.arena.allocator().dupe(u8, e.name));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        for (names.items) |n| try r.file(root, sub, n, dialect, fmt);
    }
};

test "schema: JSON-Schema-Test-Suite" {
    const io = testing.io;
    const gpa = testing.allocator;
    var pkg = try std.Io.Dir.openDirAbsolute(io, options.package_root, .{});
    defer pkg.close(io);
    var root = try pkg.openDir(io, "testdata/json-schema-test-suite", .{});
    defer root.close(io);
    var remotes: Remotes = .{ .io = io, .dir = try root.openDir(io, "remotes", .{}) };
    defer remotes.dir.close(io);

    var r: Run = .{ .gpa = gpa, .io = io, .remotes = &remotes, .arena = .init(gpa) };
    defer r.arena.deinit();
    const a = r.arena.allocator();
    const listed = try root.readFileAlloc(io, "expected-failures.txt", a, .limited(1 << 20));
    var lines = std.mem.splitScalar(u8, listed, '\n');
    while (lines.next()) |line| {
        const l = std.mem.trim(u8, line, " \r\t");
        if (l.len == 0 or l[0] == '#') continue;
        try r.expected.put(a, l, {});
    }

    const elicitation = &[_][]const u8{ "email.json", "uri.json", "date.json", "date-time.json" };
    try r.directory(root, "tests/draft2020-12", .draft2020_12, .none, null);
    try r.directory(root, "tests/draft2020-12/optional/format", .draft2020_12, .elicitation_only, elicitation);
    try r.directory(root, "tests/draft7", .draft7, .none, null);
    try r.directory(root, "tests/draft7/optional/format", .draft7, .elicitation_only, elicitation);

    var it = r.expected.keyIterator();
    while (it.next()) |k| if (!r.seen_expected.contains(k.*))
        try r.failures.append(a, try std.fmt.allocPrint(a, "listed but not found: {s}", .{k.*}));
    if (r.failures.items.len > 0) {
        for (r.failures.items) |f| std.debug.print("{s}\n", .{f});
        std.debug.print("{d} of {d} suite cases failed\n", .{ r.failures.items.len, r.cases });
        return error.SuiteFailures;
    }
    try testing.expect(r.cases > 2000);
}
