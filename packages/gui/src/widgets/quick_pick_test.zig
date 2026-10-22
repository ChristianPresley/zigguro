//! QuickPick (E04.F05.S04.T01): providers, matching, streaming, MRU,
//! multi-select and the keyboard.

const std = @import("std");
const zg_core = @import("zg_core");
const ui_mod = @import("../core/ui.zig");
const controls = @import("controls.zig");
const qp_mod = @import("quick_pick.zig");
const matcher_mod = @import("quick_pick/matcher.zig");
const TestApp = @import("../testing/test_app.zig").TestApp;

const Ui = ui_mod.Ui;
const QpItem = qp_mod.QpItem;
const Provider = qp_mod.Provider;
const ResultSink = qp_mod.ResultSink;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const Page = struct {
    pub fn build(_: *Page, ui: *Ui) void {
        ui.open(.{ .style = .{ .padding = .all(10) } });
        _ = controls.button(ui, .{ .label = "Behind" });
        ui.close();
    }
};

const commands = [_]QpItem{
    .{ .id = 1, .label = "Open File", .keybinding = "Ctrl+O", .group = "File" },
    .{ .id = 2, .label = "Save", .keybinding = "Ctrl+S", .group = "File" },
    .{ .id = 3, .label = "Go to Definition", .description = "editor", .keybinding = "F12", .group = "Go" },
    .{ .id = 4, .label = "Toggle Word Wrap", .detail = "Wraps long lines", .group = "View" },
};

const symbols = [_]QpItem{
    .{ .id = 100, .label = "main" },
    .{ .id = 101, .label = "Window" },
};

const files = [_][]const u8{ "src/main.zig", "src/window.zig", "build.zig", "docs/overview.md", "src/widgets/menu.zig" };

/// Records what was accepted and what the async provider saw.
const Harness = struct {
    accepted: [8]u64 = undefined,
    accepted_n: usize = 0,
    free_text: [64]u8 = undefined,
    free_len: usize = 0,
    alt: bool = false,
    accepts: u32 = 0,
    queries: u32 = 0,

    fn accept(ptr: ?*anyopaque, items: []const QpItem, free: ?[]const u8, alt: bool) void {
        const h: *Harness = @ptrCast(@alignCast(ptr.?));
        h.accepts += 1;
        h.accepted_n = @min(items.len, 8);
        for (items[0..h.accepted_n], 0..) |it, i| h.accepted[i] = it.id;
        const f = free orelse "";
        @memcpy(h.free_text[0..f.len], f);
        h.free_len = f.len;
        h.alt = alt;
    }

    fn commandItems(_: ?*anyopaque) []const QpItem {
        return &commands;
    }

    fn symbolItems(_: ?*anyopaque) []const QpItem {
        return &symbols;
    }

    /// Scores the file list on the worker and pushes one file per batch.
    fn fileQuery(ptr: ?*anyopaque, q: []const u8, sink: *ResultSink, cancel: *const std.atomic.Value(bool)) void {
        const h: *Harness = @ptrCast(@alignCast(ptr.?));
        _ = @atomicRmw(u32, &h.queries, .Add, 1, .monotonic);
        var hl: std.ArrayList([2]u32) = .empty;
        defer hl.deinit(std.testing.allocator);
        for (files, 0..) |f, i| {
            if (cancel.load(.acquire)) return;
            hl.clearRetainingCapacity();
            const sc = matcher_mod.scoreOf(q, f, &hl, std.testing.allocator) orelse continue;
            sink.push(&.{.{ .id = 200 + i, .label = f, .score = sc, .highlights = hl.items }});
        }
    }

    const cmd_vt: Provider.VTable = .{ .prefix = ">", .placeholder = "Type a command", .items = commandItems, .accept = accept };
    const sym_vt: Provider.VTable = .{ .prefix = "@", .items = symbolItems, .accept = accept };
    const file_vt: Provider.VTable = .{ .placeholder = "Search files", .query = fileQuery, .accept = accept };

    fn providers(h: *Harness) [3]Provider {
        return .{
            .{ .ptr = h, .vtable = &file_vt },
            .{ .ptr = h, .vtable = &cmd_vt },
            .{ .ptr = h, .vtable = &sym_vt },
        };
    }
};

const Fixture = struct {
    page: Page = .{},
    h: Harness = .{},
    provs: [3]Provider = undefined,
    t: *TestApp = undefined,
    handle: qp_mod.QuickPickHandle = .{},

    fn init(f: *Fixture) !void {
        f.t = try TestApp.init(std.testing.allocator, .{ .root = .of(&f.page), .size = .{ .w = 800, .h = 600 } });
        f.provs = f.h.providers();
        _ = f.t.settle();
    }

    fn open(f: *Fixture, p: qp_mod.QuickPickProps) !void {
        var props = p;
        props.providers = &f.provs;
        f.handle = try qp_mod.openQuickPick(f.t.win, props);
        _ = f.t.settle();
    }

    fn qp(f: *Fixture) *qp_mod.QuickPick {
        return f.handle.qp.?;
    }

    fn labels(f: *Fixture, out: *[16][]const u8) [][]const u8 {
        const items = f.qp().results.items;
        const n = @min(items.len, 16);
        for (items[0..n], 0..) |it, i| out[i] = it.label;
        return out[0..n];
    }

    fn activeLabel(f: *Fixture) []const u8 {
        const q = f.qp();
        return q.results.items[q.active].label;
    }

    fn deinit(f: *Fixture) void {
        f.t.deinit();
    }
};

fn expectLabels(f: *Fixture, want: []const []const u8) !void {
    var buf: [16][]const u8 = undefined;
    const got = f.labels(&buf);
    try expectEqual(want.len, got.len);
    for (want, got) |w, g| try expectEqualStrings(w, g);
}

test "sync path for small lists" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try f.open(.{ .initial = ">" });
    try expect(f.t.find(.{ .test_id = "quick_pick" }) != null);
    try expectLabels(&f, &.{ "Open File", "Save", "Go to Definition", "Toggle Word Wrap" });
    // Rows show (Toggle Word Wrap has a detail line: 44 px rows).
    try expectEqual(@as(usize, 4), f.t.count(.{ .role = .listitem }));
    try expectEqual(qp_mod.row_h_detail, f.qp().rowHeight());
    f.t.typeText("of");
    try expectLabels(&f, &.{ "Open File", "Go to Definition" });
    try expectEqualSlices(&.{ .{ 0, 1 }, .{ 5, 6 } }, f.qp().results.items[0].highlights);
    try expectEqual(@as(u32, 0), f.h.queries);
}

fn expectEqualSlices(want: []const [2]u32, got: []const [2]u32) !void {
    try std.testing.expectEqualSlices([2]u32, want, got);
}

test "prefix routing switches provider" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try f.open(.{});
    // The default provider streams the files.
    try expectEqual(@as(usize, files.len), f.qp().results.items.len);
    try expectEqual(@as(?usize, 0), f.qp().provider);
    f.t.typeText(">");
    try expectEqual(@as(?usize, 1), f.qp().provider);
    try expectEqual(@as(usize, commands.len), f.qp().results.items.len);
    f.t.press(.backspace, .{});
    f.t.typeText("@");
    try expectEqual(@as(?usize, 2), f.qp().provider);
    try expectLabels(&f, &.{ "main", "Window" });
    f.t.typeText("w");
    try expectLabels(&f, &.{"Window"});
    // Still open, text kept.
    try expect(f.handle.isOpen(f.t.win));
    try expectEqualStrings("@w", f.qp().buffer.slice());
}

test "keyboard: move, accept, alternate accept and escape" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try f.open(.{ .initial = ">" });
    f.t.press(.arrow_down, .{});
    try expectEqualStrings("Save", f.activeLabel());
    f.t.press(.arrow_up, .{});
    f.t.press(.arrow_up, .{});
    try expectEqualStrings("Toggle Word Wrap", f.activeLabel());
    f.t.press(.home, .{ .ctrl = true });
    try expectEqualStrings("Open File", f.activeLabel());
    f.t.press(.end, .{ .ctrl = true });
    try expectEqualStrings("Toggle Word Wrap", f.activeLabel());
    // Home without Ctrl goes to the input.
    f.t.press(.home, .{});
    try expectEqualStrings("Toggle Word Wrap", f.activeLabel());
    f.t.press(.enter, .{ .ctrl = true });
    try expectEqual(@as(u32, 1), f.h.accepts);
    try expectEqual(@as(u64, 4), f.h.accepted[0]);
    try expect(f.h.alt);
    try expect(!f.handle.isOpen(f.t.win));
    try expect(f.t.find(.{ .test_id = "quick_pick" }) == null);
    try f.open(.{ .initial = ">" });
    f.t.press(.escape, .{});
    try expect(!f.handle.isOpen(f.t.win));
    try expectEqual(@as(u32, 1), f.h.accepts);
}

test "click accepts a row" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try f.open(.{ .initial = ">" });
    try f.t.click(.{ .name = "Go to Definition" });
    try expectEqual(@as(u64, 3), f.h.accepted[0]);
    try expect(!f.handle.isOpen(f.t.win));
}

test "free text accept" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try f.open(.{ .initial = ">", .allow_free_text = true });
    f.t.typeText("zzz");
    try expectEqual(@as(usize, 0), f.qp().results.items.len);
    f.t.press(.enter, .{});
    try expectEqual(@as(u32, 1), f.h.accepts);
    try expectEqual(@as(usize, 0), f.h.accepted_n);
    try expectEqualStrings("zzz", f.h.free_text[0..f.h.free_len]);
}

test "MRU boost on empty query" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    var mru: qp_mod.Mru = .{};
    mru.touch(3);
    try f.open(.{ .initial = ">", .mru = &mru });
    try expectEqualStrings("Go to Definition", f.activeLabel());
    // Accepting moves the item to the front.
    f.t.press(.arrow_down, .{});
    f.t.press(.enter, .{});
    try expectEqual(@as(?u8, 0), mru.rank(1));
    try f.open(.{ .initial = ">", .mru = &mru });
    try expectLabels(&f, &.{ "Open File", "Go to Definition", "Save", "Toggle Word Wrap" });
}

test "multi select space" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try f.open(.{ .initial = "@", .multi = true });
    // Space toggles while the query is empty: here the input holds "@",
    // so Ctrl+Space is needed.
    f.t.press(.space, .{ .ctrl = true });
    f.t.press(.arrow_down, .{});
    f.t.press(.space, .{ .ctrl = true });
    try expectEqual(@as(usize, 2), f.qp().picked.count());
    try expect(f.t.find(.{ .name = "main", .role = .listitem }) != null);
    f.t.press(.space, .{ .ctrl = true });
    try expectEqual(@as(usize, 1), f.qp().picked.count());
    f.t.press(.enter, .{});
    try expectEqual(@as(usize, 1), f.h.accepted_n);
    try expectEqual(@as(u64, 100), f.h.accepted[0]);
}

test "multi select: space in an empty input toggles" {
    const Only = struct {
        fn items(_: ?*anyopaque) []const QpItem {
            return &symbols;
        }
        const vt: Provider.VTable = .{ .items = items, .accept = Harness.accept };
    };
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.provs[0] = .{ .ptr = &f.h, .vtable = &Only.vt };
    try f.open(.{ .multi = true });
    f.t.press(.space, .{});
    try expectEqual(@as(usize, 1), f.qp().picked.count());
    try expectEqualStrings("", f.qp().buffer.slice());
}

test "streaming batches merged sorted" {
    const Scores = struct {
        fn query(_: ?*anyopaque, _: []const u8, sink: *ResultSink, _: *const std.atomic.Value(bool)) void {
            sink.push(&.{ .{ .id = 1, .label = "one", .score = 1 }, .{ .id = 5, .label = "five", .score = 5 } });
            sink.push(&.{.{ .id = 3, .label = "three", .score = 3 }});
            sink.push(&.{ .{ .id = 9, .label = "nine", .score = 9 }, .{ .id = 2, .label = "two", .score = 2 } });
        }
        const vt: Provider.VTable = .{ .query = query, .accept = Harness.accept };
    };
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.provs[0] = .{ .vtable = &Scores.vt };
    try f.open(.{});
    try expectLabels(&f, &.{ "nine", "five", "three", "two", "one" });
    try expect(!f.qp().streaming);
}

test "previous results kept until first batch; dimmed after 150 ms" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try f.open(.{});
    try expectEqual(@as(usize, files.len), f.qp().results.items.len);
    // A keystroke starts a new query; its results are posted but not yet
    // delivered.
    f.t.win.dispatch(.{ .text = "menu" });
    _ = f.t.frame();
    try expect(f.qp().stale);
    try expectEqual(@as(usize, files.len), f.qp().results.items.len);
    try expect(f.qp().streaming);
    // 150 ms later the stale rows dim.
    f.t.app.now_ms += 200;
    f.t.win.tick(f.t.app.now_ms);
    try expect(f.qp().dim);
    // Delivery replaces them.
    _ = f.t.settle();
    try expectLabels(&f, &.{"src/widgets/menu.zig"});
    try expect(!f.qp().stale and !f.qp().dim and !f.qp().streaming);
}

test "cancel previous query on keystroke" {
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    try f.open(.{});
    f.t.win.dispatch(.{ .text = "s" });
    _ = f.t.frame();
    f.t.win.dispatch(.{ .text = "r" });
    _ = f.t.frame();
    try expectEqual(@as(u32, 1), f.qp().cancelled);
    _ = f.t.settle();
    // Only "sr" results arrived.
    for (f.qp().results.items) |it| try expect(std.mem.indexOf(u8, it.label, "s") != null);
    try expectEqualStrings("src/main.zig", f.qp().results.items[0].label);
}

test "async provider on worker threads" {
    const Many = struct {
        fn query(_: ?*anyopaque, _: []const u8, sink: *ResultSink, cancel: *const std.atomic.Value(bool)) void {
            var buf: [8]u8 = undefined;
            var i: u32 = 0;
            while (i < 200) : (i += 1) {
                if (cancel.load(.acquire)) return;
                const label = std.fmt.bufPrint(&buf, "item{d}", .{i}) catch unreachable;
                sink.push(&.{.{ .id = i, .label = label, .score = @intCast(i % 17) }});
            }
        }
        const vt: Provider.VTable = .{ .query = query, .accept = Harness.accept };
    };
    var rt: zg_core.Runtime = undefined;
    rt.initTesting();
    defer _ = rt.deinit();
    rt.bindUiThread(.noop);
    var f: Fixture = .{};
    try f.init();
    defer f.deinit();
    f.t.app.attachRuntime(&rt);
    f.provs[0] = .{ .vtable = &Many.vt };
    try f.open(.{});
    f.t.app.joinWork();
    _ = f.t.settle();
    const items = f.qp().results.items;
    try expectEqual(@as(usize, 200), items.len);
    for (items[1..], items[0 .. items.len - 1]) |b, a| try expect(a.score >= b.score);
    try expect(!f.qp().streaming);
    // Typing again while the window closes cancels cleanly.
    f.t.typeText("x");
}

test "quick pick left open is freed with its window" {
    var f: Fixture = .{};
    try f.init();
    try f.open(.{});
    f.t.win.dispatch(.{ .text = "s" });
    _ = f.t.frame();
    f.deinit();
}
