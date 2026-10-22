const std = @import("std");
const scheduler = @import("scheduler.zig");
const cache_mod = @import("cache.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Scheduler = scheduler.Scheduler;
const ms = std.time.ns_per_ms;

fn userKey(version: u64) scheduler.Edit {
    return .{ .origin = .user, .inserted = 1, .version = version };
}

test "scheduler: gating table" {
    const G = scheduler.GateInput;
    const cases = [_]struct { in: G, want: scheduler.Gate }{
        .{ .in = .{}, .want = .ok },
        .{ .in = .{ .excluded = true, .snoozed = true }, .want = .excluded_by_policy },
        .{ .in = .{ .language_disabled = true }, .want = .disabled_language },
        .{ .in = .{ .glob_disabled = true }, .want = .disabled_glob },
        .{ .in = .{ .snoozed = true }, .want = .snoozed },
        .{ .in = .{ .carets = 2 }, .want = .multi_cursor },
        .{ .in = .{ .carets = 2, .multi_cursor_allowed = true }, .want = .ok },
        .{ .in = .{ .selection = true }, .want = .selection_active },
        .{ .in = .{ .ime_composing = true }, .want = .ime_composing },
        .{ .in = .{ .popup_open = true }, .want = .popup_open },
        .{ .in = .{ .popup_open = true, .ghost_wins = true }, .want = .ok },
        .{ .in = .{ .read_only = true }, .want = .read_only },
        .{ .in = .{ .doc_bytes = scheduler.max_doc_bytes + 1 }, .want = .too_large },
        .{ .in = .{ .after = "foo)" }, .want = .mid_word_no_fim },
        .{ .in = .{ .after = "foo)", .explicit = true }, .want = .ok },
        .{ .in = .{ .after = ");\n" }, .want = .ok },
        .{ .in = .{ .after = " + b;", .fim = true }, .want = .ok },
        .{ .in = .{ .after = " + b;", .fim = false }, .want = .mid_word_no_fim },
        .{ .in = .{ .after = ")", .fim = false }, .want = .ok },
    };
    for (cases, 0..) |c, i| {
        testing.expectEqual(c.want, scheduler.gate(c.in)) catch |e| {
            std.debug.print("case {d}\n", .{i});
            return e;
        };
    }
}

test "scheduler: adaptive debounce shortens for fast typists, fires immediately on pause" {
    var s: Scheduler = .init(gpa, .{ .debounce_ms = 60 });
    defer s.deinit();
    try s.open(1, 0);
    var out: [4]scheduler.Trigger = undefined;

    // The first key waits the full debounce.
    var now: u64 = 1000 * ms;
    _ = s.onEdit(1, userKey(1), now);
    try testing.expectEqual(now + 60 * ms, s.nextDeadline().?);
    try testing.expectEqual(@as(usize, 0), s.poll(now + 59 * ms, &out));

    // Keys 30 ms apart: the debounce drops to 0.8 x 30 = 24 ms.
    for (2..10) |v| {
        now += 30 * ms;
        _ = s.onEdit(1, userKey(v), now);
    }
    try testing.expectEqual(@as(u64, 24 * ms), s.debounceNs(1));
    // The pause after the last key fires at the deadline, once.
    try testing.expectEqual(@as(usize, 1), s.poll(now + 24 * ms, &out));
    try testing.expectEqual(@as(u64, 9), out[0].version);
    try testing.expect(!out[0].explicit);
    try testing.expect(s.nextDeadline() == null);
    try testing.expectEqual(@as(usize, 0), s.poll(now + 1000 * ms, &out));

    // min_debounce floors a very fast typist (10 ms gaps).
    var slow: Scheduler = .init(gpa, .{ .debounce_ms = 60, .min_debounce_ms = 30 });
    defer slow.deinit();
    try slow.open(1, 0);
    now = 0;
    for (0..5) |v| {
        now += 10 * ms;
        _ = slow.onEdit(1, userKey(v), now);
    }
    try testing.expectEqual(@as(u64, 30 * ms), slow.debounceNs(1));

    // Invoke fires now, marked explicit.
    s.invoke(1, now);
    try testing.expectEqual(@as(usize, 1), s.poll(now, &out));
    try testing.expect(out[0].explicit);
}

test "scheduler: undo, agent, LSP edits, pastes and multi-cursor edits never trigger" {
    var s: Scheduler = .init(gpa, .{});
    defer s.deinit();
    try s.open(1, 0);
    var out: [4]scheduler.Trigger = undefined;
    const never = [_]scheduler.Edit{
        .{ .origin = .undo, .inserted = 1, .version = 1 },
        .{ .origin = .redo, .inserted = 1, .version = 2 },
        .{ .origin = .agent, .inserted = 1, .version = 3 },
        .{ .origin = .lsp, .inserted = 1, .version = 4 },
        .{ .origin = .user, .inserted = 300, .version = 5 },
        .{ .origin = .user, .inserted = 1, .carets = 3, .version = 6 },
    };
    for (never) |e| {
        // A key first, then the edit: the pending trigger is dropped.
        _ = s.onEdit(1, userKey(e.version), 0);
        _ = s.onEdit(1, e, 1);
        try testing.expect(s.nextDeadline() == null);
        try testing.expectEqual(@as(usize, 0), s.poll(std.math.maxInt(u64), &out));
    }
    // And they cancel the request in flight.
    _ = s.started(.{ .doc = 1, .version = 6 }, 41);
    try testing.expectEqual(scheduler.InflightAction{ .cancel = 41 }, s.onEdit(1, .{ .origin = .undo, .inserted = 0, .version = 7 }, 2));
    try testing.expect(s.inflight(1) == null);

    // Cursor moves trigger only on the same line, within 1 s of an edit.
    _ = s.onEdit(1, userKey(8), 0);
    s.disarm(1);
    s.onCursorMove(1, true, 500 * ms);
    try testing.expect(s.nextDeadline() != null);
    s.onCursorMove(1, false, 600 * ms);
    try testing.expect(s.nextDeadline() == null);
    s.onCursorMove(1, true, 1500 * ms);
    try testing.expect(s.nextDeadline() == null);
}

test "scheduler: consistent keystroke keeps the request and trims; inconsistent cancels" {
    var s: Scheduler = .init(gpa, .{});
    defer s.deinit();
    try s.open(1, 0);
    try testing.expect(s.started(.{ .doc = 1, .version = 1 }, 7) == null);

    try testing.expectEqual(scheduler.InflightAction{ .keep = 1 }, s.typed(1, "r", "return x;"));
    try testing.expectEqual(scheduler.InflightAction{ .keep = 3 }, s.typed(1, "et", "return x;"));
    // The result still counts, with the typed bytes hidden.
    try testing.expectEqual(@as(?u32, 3), s.finished(1, 7));

    _ = s.started(.{ .doc = 1, .version = 2 }, 8);
    try testing.expectEqual(scheduler.InflightAction{ .cancel = 8 }, s.typed(1, "x", "return x;"));
    try testing.expect(s.inflight(1) == null);
    // Typing past what has streamed cancels too.
    _ = s.started(.{ .doc = 1, .version = 3 }, 9);
    try testing.expectEqual(scheduler.InflightAction{ .cancel = 9 }, s.typed(1, "ret", "re"));
}

test "scheduler: speculative after accept, cancelled by a keystroke" {
    var s: Scheduler = .init(gpa, .{});
    defer s.deinit();
    try s.open(1, 0);
    var out: [2]scheduler.Trigger = undefined;
    s.accepted(1, 5, 100);
    try testing.expectEqual(@as(usize, 1), s.poll(100, &out));
    try testing.expect(out[0].speculative);
    try testing.expectEqual(@as(u64, 5), out[0].version);
    _ = s.started(out[0], 12);
    try testing.expectEqual(scheduler.InflightAction{ .cancel = 12 }, s.typed(1, "a", "abc"));

    var off: Scheduler = .init(gpa, .{ .speculative = false });
    defer off.deinit();
    try off.open(1, 0);
    off.accepted(1, 5, 100);
    try testing.expect(off.nextDeadline() == null);
}

test "scheduler: stale results are dropped" {
    var s: Scheduler = .init(gpa, .{});
    defer s.deinit();
    try s.open(1, 0);
    _ = s.started(.{ .doc = 1, .version = 1 }, 1);
    // A newer request replaces it; the caller cancels the old one.
    try testing.expectEqual(@as(?u64, 1), s.started(.{ .doc = 1, .version = 2 }, 2));
    try testing.expect(s.finished(1, 1) == null);
    try testing.expectEqual(@as(?u32, 0), s.finished(1, 2));
    try testing.expect(s.finished(1, 2) == null);
    try testing.expect(s.finished(9, 2) == null);
}

test "scheduler: no allocation per keystroke once the document is open" {
    var fa: std.testing.FailingAllocator = .init(gpa, .{});
    var s: Scheduler = .init(fa.allocator(), .{});
    defer s.deinit();
    try s.open(1, 0);
    fa.fail_index = fa.alloc_index;
    var out: [2]scheduler.Trigger = undefined;
    var now: u64 = 0;
    for (0..1000) |v| {
        now += 40 * ms;
        _ = s.onEdit(1, userKey(v), now);
        if (v % 10 == 0) {
            _ = s.poll(now + 60 * ms, &out);
            _ = s.started(.{ .doc = 1, .version = v }, v);
            _ = s.typed(1, "a", "abc");
        }
    }
    try testing.expectEqual(fa.alloc_index, fa.fail_index);
}

test "scheduler: cache hit paints without a request; extend after a dismiss" {
    var c: cache_mod.Cache = .init(gpa, 2, 1 << 20);
    defer c.deinit();
    const k1: cache_mod.CacheKey = .of(1, "fn f() {\n    re", "\n}", 7);
    try testing.expect(c.get(k1) == null);
    try c.put(k1, "turn x;");
    try testing.expectEqualStrings("turn x;", c.get(k1).?);
    // Another model, another document: other keys.
    try testing.expect(c.get(.of(1, "fn f() {\n    re", "\n}", 8)) == null);
    try testing.expect(c.get(.of(2, "fn f() {\n    re", "\n}", 7)) == null);
    // Only the last 2 KiB of prefix count.
    const long_a = "a" ** 3000 ++ "tail";
    const long_b = "b" ** 3000 ++ "tail";
    const ka: cache_mod.CacheKey = .of(1, long_a[long_a.len - 2048 ..], "", 7);
    try testing.expectEqual(ka, cache_mod.CacheKey.of(1, "c" ++ long_a, "", 7));
    try testing.expect(!std.meta.eql(ka, cache_mod.CacheKey.of(1, long_b, "", 7)));

    // Typed "tu" after dismissing: the rest is served at the new spot.
    const k2: cache_mod.CacheKey = .of(1, "fn f() {\n    retu", "\n}", 7);
    try testing.expectEqualStrings("rn x;", (try c.extend(k1, "tu", k2)).?);
    try testing.expectEqualStrings("rn x;", c.get(k2).?);
    try testing.expect((try c.extend(k1, "x", k2)) == null);
    try testing.expect((try c.extend(k1, "turn x;", k2)) == null);

    // LRU: a third entry evicts the least recently used.
    _ = c.get(k2);
    const k3: cache_mod.CacheKey = .of(1, "z", "", 7);
    try c.put(k3, "z");
    try testing.expect(c.get(k1) == null);
    try testing.expect(c.get(k2) != null);
    try testing.expectEqual(@as(usize, 2), c.count());

    // A byte cap evicts too, and invalidateDoc clears a document.
    var small: cache_mod.Cache = .init(gpa, 100, 10);
    defer small.deinit();
    try small.put(k1, "123456");
    try small.put(k2, "123456");
    try testing.expectEqual(@as(usize, 1), small.count());
    try small.put(.of(2, "q", "", 7), "1");
    small.invalidateDoc(1);
    try testing.expectEqual(@as(usize, 1), small.count());
    try testing.expectEqual(@as(usize, 1), small.bytes);
}
