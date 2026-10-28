const std = @import("std");
const run = @import("../runs/run.zig");
const filter = @import("filter.zig");

const testing = std.testing;
const Filter = filter.Filter;
const Subject = filter.Subject;

/// A run every case is checked against.
const subject: Subject = .{
    .status = .working,
    .group = .working,
    .kind = .scheduled,
    .title = "Nightly Triage",
    .prompt = "Label the new issues",
    .summary = "Labelled 3 issues",
    .outputs = "changeset 7\nPR #12 https://example.test/pr/12\n",
    .cost_micro = 750_000,
    .tags = &.{ "ops", "nightly" },
    .origin = "triage-bot",
    .project = "ops-book",
};

test "filter_grammar_table" {
    const Case = struct { q: []const u8, match: bool, check: ?*const fn (f: Filter) anyerror!void = null };
    const C = struct {
        fn twoNames(f: Filter) !void {
            try testing.expectEqual(@as(usize, 2), f.names.len);
        }
        fn quoted(f: Filter) !void {
            try testing.expectEqualStrings("nightly triage", f.names[0]);
        }
        fn unknownPrefix(f: Filter) !void {
            try testing.expectEqualStrings("x:foo", f.names[0]);
        }
        fn costs(f: Filter) !void {
            try testing.expectEqual(@as(?u64, 500_000), f.min_cost_micro);
            try testing.expectEqual(@as(?u64, 1_000_000), f.max_cost_micro);
        }
        fn statusSet(f: Filter) !void {
            try testing.expect(f.states.contains(.failed));
            try testing.expect(f.groups.contains(.working));
        }
        fn empty(f: Filter) !void {
            try testing.expect(f.isEmpty());
        }
        fn worker(f: Filter) !void {
            try testing.expect(f.kinds.contains(.workflow_worker));
        }
    };
    const cases = [_]Case{
        .{ .q = "", .match = true, .check = C.empty },
        .{ .q = "   ", .match = true, .check = C.empty },
        // Status and group.
        .{ .q = "s:working", .match = true },
        .{ .q = "s:running", .match = true },
        .{ .q = "s:queued", .match = false },
        .{ .q = "s:needs-input", .match = false },
        .{ .q = "s:failed s:working", .match = true, .check = C.statusSet },
        .{ .q = "s:review", .match = false },
        .{ .q = "s:Working", .match = true },
        // Kind.
        .{ .q = "k:scheduled", .match = true },
        .{ .q = "k:background", .match = false },
        .{ .q = "k:worker", .match = false, .check = C.worker },
        .{ .q = "k:scheduled k:task", .match = true },
        // Name (title or prompt), case-insensitive.
        .{ .q = "n:triage", .match = true },
        .{ .q = "triage", .match = true },
        .{ .q = "TRIAGE label", .match = true, .check = C.twoNames },
        .{ .q = "triage deploy", .match = false },
        .{ .q = "n:\"nightly triage\"", .match = true, .check = C.quoted },
        .{ .q = "new issues", .match = true },
        // Output and summary.
        .{ .q = "o:labelled", .match = true },
        .{ .q = "o:#12", .match = true },
        .{ .q = "o:deploy", .match = false },
        // Cost in USD.
        .{ .q = "cost>0.5", .match = true },
        .{ .q = "cost>$0.75", .match = false },
        .{ .q = "cost<1", .match = true },
        .{ .q = "cost>0.5 cost<1", .match = true, .check = C.costs },
        .{ .q = "cost>abc", .match = false },
        // Tags and origin.
        .{ .q = "#ops", .match = true },
        .{ .q = "#Nightly #ops", .match = true },
        .{ .q = "#deploy", .match = false },
        .{ .q = "a:triage", .match = true },
        .{ .q = "a:release", .match = false },
        // Project (exact slug, any of several; p:none is no project).
        .{ .q = "p:ops-book", .match = true },
        .{ .q = "p:OPS-BOOK", .match = true },
        .{ .q = "p:ops", .match = false },
        .{ .q = "p:q4 p:ops-book", .match = true },
        .{ .q = "p:none", .match = false },
        .{ .q = "p:none p:ops-book", .match = true },
        // Unknown prefixes and values are words.
        .{ .q = "x:foo", .match = false, .check = C.unknownPrefix },
        .{ .q = "s:bogus", .match = false },
        .{ .q = "n:", .match = false },
        // Everything ANDed.
        .{ .q = "s:working k:scheduled triage o:labelled cost>0.1 #ops a:bot", .match = true },
        .{ .q = "s:working k:scheduled triage o:labelled cost>0.1 #ops a:nope", .match = false },
    };
    for (cases) |c| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        errdefer std.debug.print("filter: '{s}'\n", .{c.q});
        const f = try filter.parseFilter(c.q, arena.allocator());
        try testing.expectEqual(c.match, f.matches(subject));
        if (c.check) |chk| try chk(f);
    }
}

test "filter_grammar_p_prefix: p:none matches runs outside projects" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var outside = subject;
    outside.project = null;
    const none = try filter.parseFilter("p:none", arena.allocator());
    try testing.expect(!none.isEmpty());
    try testing.expect(none.matches(outside));
    const book = try filter.parseFilter("p:ops-book", arena.allocator());
    try testing.expect(!book.matches(outside));
}
