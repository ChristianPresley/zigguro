//! Catalog tests over a scripted fetcher: pagination, caching,
//! invalidation, privacy, deltas and snapshots.

const std = @import("std");
const protocol = @import("../protocol/root.zig");
const catalog = @import("catalog.zig");
const snapshot = @import("snapshot.zig");

const testing = std.testing;
const io = testing.io;
const Allocator = std.mem.Allocator;
const M = protocol.messages;
const CatalogStore = catalog.CatalogStore;

/// Serves `pages` of tools; cursors are the page index as text.
const Script = struct {
    pages: []const []const u8,
    ttl_ms: ?i64 = 60_000,
    scope: ?M.CacheScope = null,
    used_input: bool = false,
    /// Fail the cursor of this page once with `-32602`.
    invalid_once: ?usize = null,
    /// Every fetch fails.
    fail: bool = false,
    /// Cursor strings; default "1", "2", ...
    cursors: ?[]const []const u8 = null,
    fetches: std.atomic.Value(u32) = .init(0),
    walks: std.atomic.Value(u32) = .init(0),

    fn fetcher(s: *Script) catalog.Fetcher {
        return .{ .ctx = s, .fetch = fetch };
    }

    fn cursorFor(s: *Script, i: usize) []const u8 {
        if (s.cursors) |cs| return cs[i - 1];
        return switch (i) {
            1 => "1",
            2 => "2",
            3 => "3",
            else => "9",
        };
    }

    fn fetch(ctx: ?*anyopaque, arena: Allocator, kind: catalog.CatalogKind, cursor: ?[]const u8) catalog.FetchError!catalog.Page {
        const s: *Script = @ptrCast(@alignCast(ctx.?));
        std.debug.assert(kind == .tools);
        _ = s.fetches.fetchAdd(1, .monotonic);
        if (s.fail) return error.Failed;
        var i: usize = 0;
        if (cursor) |cur| {
            i = for (1..s.pages.len) |j| {
                if (std.mem.eql(u8, s.cursorFor(j), cur)) break j;
            } else return error.InvalidCursor;
            if (s.invalid_once == i) {
                s.invalid_once = null;
                return error.InvalidCursor;
            }
        } else _ = s.walks.fetchAdd(1, .monotonic);
        const r = protocol.codec.decodeBytes(M.ListToolsResult, arena, s.pages[i], .{}) catch return error.Failed;
        return .{
            .items = .{ .tools = r.tools },
            .next_cursor = if (i + 1 < s.pages.len) s.cursorFor(i + 1) else null,
            .ttl_ms = s.ttl_ms,
            .cache_scope = s.scope,
            .used_input = s.used_input,
        };
    }
};

const page_a =
    \\{"tools":[{"name":"a","inputSchema":{"type":"object"}},{"name":"b","inputSchema":{"type":"object"}}]}
;
const page_b =
    \\{"tools":[{"name":"c","inputSchema":{"type":"object"}}]}
;
const page_c =
    \\{"tools":[{"name":"d","inputSchema":{"type":"object"}},{"name":"a","inputSchema":{"type":"string"}}]}
;

fn names(c: *const catalog.Catalog) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (c.keys) |k| {
        try buf.appendSlice(testing.allocator, k);
    }
    return buf.toOwnedSlice(testing.allocator);
}

test "catalog: 3 pages concatenated" {
    var s: Script = .{ .pages = &.{ page_a, page_b, page_c } };
    var store: CatalogStore = .init(testing.allocator, io, s.fetcher(), .{});
    defer store.deinit();
    const c = try store.get(.tools);
    defer c.release();
    const got = try names(c);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("abcd", got);
    try testing.expect(c.complete);
    // The second "a" is a duplicate.
    try testing.expectEqual(1, c.excluded.len);
    try testing.expectEqualStrings("a", c.excluded[0].name);
    try testing.expect(c.find("c") != null);
    try testing.expect(c.find("zzz") == null);
    try testing.expectEqual(3, s.fetches.load(.monotonic));
}

test "catalog: empty-string cursor is not end" {
    var s: Script = .{ .pages = &.{ page_a, page_b }, .cursors = &.{""} };
    var store: CatalogStore = .init(testing.allocator, io, s.fetcher(), .{});
    defer store.deinit();
    const c = try store.get(.tools);
    defer c.release();
    try testing.expectEqual(3, c.entries.len);
}

test "catalog: invalid cursor restarts once" {
    var s: Script = .{ .pages = &.{ page_a, page_b, page_c }, .invalid_once = 2 };
    var store: CatalogStore = .init(testing.allocator, io, s.fetcher(), .{});
    defer store.deinit();
    const c = try store.get(.tools);
    defer c.release();
    try testing.expectEqual(4, c.entries.len);
    try testing.expectEqual(2, s.walks.load(.monotonic));
}

test "catalog: page and entry caps mark the catalog incomplete" {
    var s: Script = .{ .pages = &.{ page_a, page_b, page_c } };
    var store: CatalogStore = .init(testing.allocator, io, s.fetcher(), .{ .max_pages = 2 });
    defer store.deinit();
    const c = try store.get(.tools);
    defer c.release();
    try testing.expect(!c.complete);
    try testing.expectEqual(3, c.entries.len);
    try testing.expectEqual(1, c.warnings.len);

    var s2: Script = .{ .pages = &.{ page_a, page_b, page_c } };
    var store2: CatalogStore = .init(testing.allocator, io, s2.fetcher(), .{ .max_entries = 1 });
    defer store2.deinit();
    const c2 = try store2.get(.tools);
    defer c2.release();
    try testing.expect(!c2.complete);
    try testing.expectEqual(1, c2.entries.len);
}

test "catalog: ttl fresh/stale" {
    var s: Script = .{ .pages = &.{page_a}, .ttl_ms = 60_000 };
    var store: CatalogStore = .init(testing.allocator, io, s.fetcher(), .{});
    defer store.deinit();
    (try store.get(.tools)).release();
    (try store.get(.tools)).release();
    try testing.expectEqual(1, s.fetches.load(.monotonic));
    const c = store.acquire(.tools).?;
    defer c.release();
    try testing.expect(c.isFresh(c.fetched_at_ms + 59_000));
    try testing.expect(!c.isFresh(c.fetched_at_ms + 61_000));

    // ttl 0: every get walks again.
    var s0: Script = .{ .pages = &.{page_a}, .ttl_ms = 0 };
    var store0: CatalogStore = .init(testing.allocator, io, s0.fetcher(), .{});
    defer store0.deinit();
    (try store0.get(.tools)).release();
    (try store0.get(.tools)).release();
    try testing.expectEqual(2, s0.fetches.load(.monotonic));
}

test "catalog: negative ttl => 0" {
    var s: Script = .{ .pages = &.{page_a}, .ttl_ms = -5 };
    var store: CatalogStore = .init(testing.allocator, io, s.fetcher(), .{});
    defer store.deinit();
    const c = try store.get(.tools);
    defer c.release();
    try testing.expect(c.fresh_until_ms.? - c.fetched_at_ms < 1000);
    try testing.expect(!c.isFresh(c.fresh_until_ms.?));
}

test "catalog: legacy servers without ttl use listChanged or the heuristic" {
    var s: Script = .{ .pages = &.{page_a}, .ttl_ms = null };
    var with: CatalogStore = .init(testing.allocator, io, s.fetcher(), .{ .legacy = true, .list_changed = .init(.{ .tools = true, .resources = false, .templates = false, .prompts = false }) });
    defer with.deinit();
    const c = try with.get(.tools);
    defer c.release();
    try testing.expect(c.fresh_until_ms == null);

    var without: CatalogStore = .init(testing.allocator, io, s.fetcher(), .{ .legacy = true, .heuristic_ttl_ms = 1234 });
    defer without.deinit();
    const c2 = try without.get(.tools);
    defer c2.release();
    try testing.expectEqual(1234, c2.fresh_until_ms.? - c2.fetched_at_ms);
}

test "catalog: list_changed invalidates and debounces 5 notifications into 1 fetch" {
    var s: Script = .{ .pages = &.{page_a} };
    var store: CatalogStore = .init(testing.allocator, io, s.fetcher(), .{ .debounce = .fromMilliseconds(50) });
    defer store.deinit();
    (try store.get(.tools)).release();
    try testing.expectEqual(1, s.fetches.load(.monotonic));
    for (0..5) |_| store.onNotification(.{ .tools_list_changed = .{} });
    // Prompts were never fetched: nothing to refresh.
    store.onNotification(.{ .prompts_list_changed = .{} });
    var waited: u32 = 0;
    while (s.fetches.load(.monotonic) < 2 and waited < 200) : (waited += 1) try io.sleep(.fromMilliseconds(10), .awake);
    try io.sleep(.fromMilliseconds(150), .awake);
    try testing.expectEqual(2, s.fetches.load(.monotonic));
    // The refresh published a fresh catalog: no walk on get.
    (try store.get(.tools)).release();
    try testing.expectEqual(2, s.fetches.load(.monotonic));
}

test "catalog: header mismatch and unknown tool invalidate" {
    var s: Script = .{ .pages = &.{page_a} };
    var store: CatalogStore = .init(testing.allocator, io, s.fetcher(), .{});
    defer store.deinit();
    (try store.get(.tools)).release();
    store.noteCallError(error.Timeout, null);
    (try store.get(.tools)).release();
    try testing.expectEqual(1, s.fetches.load(.monotonic));
    store.noteCallError(error.HeaderMismatch, null);
    (try store.get(.tools)).release();
    try testing.expectEqual(2, s.fetches.load(.monotonic));
    var info: @import("Client.zig").ErrorInfo = .{ .code = protocol.errors.invalid_params };
    store.noteCallError(error.ServerError, &info);
    (try store.get(.tools)).release();
    try testing.expectEqual(3, s.fetches.load(.monotonic));
}

test "catalog: private scope keyed by auth context" {
    var s: Script = .{ .pages = &.{page_a}, .scope = .private };
    var store: CatalogStore = .init(testing.allocator, io, s.fetcher(), .{});
    defer store.deinit();
    store.setAuthContext(0xa11ce);
    const c = try store.get(.tools);
    try testing.expectEqual(.private, c.scope);
    try testing.expectEqual(0xa11ce, c.auth_context.?);
    c.release();
    (try store.get(.tools)).release();
    try testing.expectEqual(1, s.fetches.load(.monotonic));
    // Another user: never served the first one's catalog, even stale.
    store.setAuthContext(0xb0b);
    s.fail = true;
    try testing.expectError(error.Failed, store.get(.tools));
    s.fail = false;
    const c2 = try store.get(.tools);
    defer c2.release();
    try testing.expectEqual(0xb0b, c2.auth_context.?);
}

test "catalog: MRTR results not cached" {
    var s: Script = .{ .pages = &.{page_a}, .used_input = true };
    var store: CatalogStore = .init(testing.allocator, io, s.fetcher(), .{});
    defer store.deinit();
    (try store.get(.tools)).release();
    (try store.get(.tools)).release();
    try testing.expectEqual(2, s.fetches.load(.monotonic));
}

test "catalog: a failed refresh serves the old catalog marked stale" {
    var s: Script = .{ .pages = &.{page_a} };
    var store: CatalogStore = .init(testing.allocator, io, s.fetcher(), .{});
    defer store.deinit();
    (try store.get(.tools)).release();
    store.invalidate(.tools);
    s.fail = true;
    const c = try store.get(.tools);
    defer c.release();
    try testing.expect(store.isStale(.tools));
    try testing.expectEqual(2, c.entries.len);
    s.fail = false;
    (try store.get(.tools)).release();
    try testing.expect(!store.isStale(.tools));
}

const Recorder = struct {
    deltas: u32 = 0,
    last: [3]usize = .{ 0, 0, 0 },
    changed: [8]u8 = undefined,

    fn listener(r: *Recorder) catalog.ChangeListener {
        return .{ .ctx = r, .func = on };
    }

    fn on(ctx: ?*anyopaque, d: catalog.Delta, _: *catalog.Catalog) void {
        const r: *Recorder = @ptrCast(@alignCast(ctx.?));
        r.deltas += 1;
        r.last = .{ d.added.len, d.removed.len, d.changed.len };
        if (d.changed.len > 0) r.changed[0] = d.changed[0][0];
    }
};

test "catalog: listeners get added, removed and changed names" {
    var s: Script = .{ .pages = &.{page_a} };
    var store: CatalogStore = .init(testing.allocator, io, s.fetcher(), .{});
    defer store.deinit();
    var rec: Recorder = .{};
    try store.onChange(rec.listener());
    try store.refresh(.tools);
    try testing.expectEqual(1, rec.deltas);
    try testing.expectEqual([3]usize{ 2, 0, 0 }, rec.last);
    // Same definitions: no delta.
    try store.refresh(.tools);
    try testing.expectEqual(1, rec.deltas);
    // "b" gone, "a" changed, "x" added.
    s.pages = &.{
        \\{"tools":[{"name":"a","description":"now different","inputSchema":{"type":"object"}},{"name":"x","inputSchema":{"type":"object"}}]}
    };
    try store.refresh(.tools);
    try testing.expectEqual(2, rec.deltas);
    try testing.expectEqual([3]usize{ 1, 1, 1 }, rec.last);
    try testing.expectEqual('a', rec.changed[0]);
}

test "catalog: readers keep an old catalog alive across a publish" {
    var s: Script = .{ .pages = &.{page_a} };
    var store: CatalogStore = .init(testing.allocator, io, s.fetcher(), .{});
    defer store.deinit();
    try store.refresh(.tools);
    const old = store.acquire(.tools).?;
    try store.refresh(.tools);
    const new = store.acquire(.tools).?;
    defer new.release();
    try testing.expect(old != new);
    try testing.expect(new.version > old.version);
    try testing.expect(old.find("a") != null);
    old.release();
}

test "catalog: sortedByName" {
    var s: Script = .{ .pages = &.{
        \\{"tools":[{"name":"zeta","inputSchema":{}},{"name":"alpha","inputSchema":{}},{"name":"mid","inputSchema":{}}]}
    } };
    var store: CatalogStore = .init(testing.allocator, io, s.fetcher(), .{});
    defer store.deinit();
    const c = try store.get(.tools);
    defer c.release();
    const order = try c.sortedByName(testing.allocator);
    defer testing.allocator.free(order);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 0 }, order);
    // Server order is kept.
    try testing.expectEqualStrings("zeta", c.entries[0].def.name);
}

test "snapshot: round-trip 500 tools; lazy compile" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"tools\":[");
    for (0..500) |i| {
        if (i != 0) try aw.writer.writeByte(',');
        try aw.writer.print(
            \\{{"name":"tool_{d}","description":"Tool {d}.","inputSchema":{{"type":"object","properties":{{"path":{{"type":"string"}}}},"required":["path"]}}}}
        , .{ i, i });
    }
    try aw.writer.writeAll("]}");
    var s: Script = .{ .pages = &.{aw.written()} };
    var store: CatalogStore = .init(testing.allocator, io, s.fetcher(), .{});
    defer store.deinit();
    const c = try store.get(.tools);
    defer c.release();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try snapshot.encodeSnapshot(&out.writer, c, .{ .revision = "2026-07-28" });
    var r: std.Io.Reader = .fixed(out.written());
    const back = try snapshot.decodeSnapshot(testing.allocator, io, &r);
    defer back.release();
    try testing.expectEqual(500, back.entries.len);
    try testing.expectEqualSlices(u64, c.prints, back.prints);
    try testing.expectEqual(c.fetched_at_ms, back.fetched_at_ms);
    const e = back.find("tool_42").?;
    try testing.expectEqual(.pending, e.input.state);
    try testing.expect(back.inputSchema(e) != null);
    try testing.expectEqual(.ready, e.input.state);
    try testing.expectEqual(.pending, back.find("tool_43").?.input.state);

    var name_buf: [64]u8 = undefined;
    try testing.expectEqualStrings("srv.tools.jsonl", try snapshot.fileName(&name_buf, "srv", back));
    back.scope = .private;
    back.auth_context = 0xab;
    try testing.expectEqualStrings("srv.tools.00000000000000ab.jsonl", try snapshot.fileName(&name_buf, "srv", back));

    var bad: std.Io.Reader = .fixed("{\"zgCatalog\":99}\n");
    try testing.expectError(error.UnsupportedVersion, snapshot.decodeSnapshot(testing.allocator, io, &bad));
}
