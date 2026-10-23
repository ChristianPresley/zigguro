//! The artifact pane in a headless window over a real store in a
//! temporary directory, one snapshot per kind.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");
const pane_mod = @import("artifact_pane.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const TestApp = zg_gui.testing.TestApp;
const artifacts = zg_agents.artifacts;
const ArtifactPane = pane_mod.ArtifactPane;

const Host = struct {
    pane: ?*ArtifactPane = null,

    pub fn build(h: *Host, ui: *zg_gui.Ui) void {
        if (h.pane) |p| p.build(ui);
    }
};

const Ext = struct {
    saves: u32 = 0,
    last_save: [128]u8 = undefined,
    last_len: usize = 0,
    copied: u32 = 0,
    opened: u32 = 0,
    exported: u32 = 0,

    fn save(ctx: *anyopaque, req: artifacts.save.SaveRequest) anyerror!u64 {
        const e: *Ext = @ptrCast(@alignCast(ctx));
        e.saves += 1;
        @memcpy(e.last_save[0..req.path.len], req.path);
        e.last_len = req.path.len;
        return 77;
    }
    fn copy(ctx: *anyopaque, _: []const u8) void {
        const e: *Ext = @ptrCast(@alignCast(ctx));
        e.copied += 1;
    }
    fn open(ctx: *anyopaque, _: []const u8, _: []const u8) anyerror!void {
        const e: *Ext = @ptrCast(@alignCast(ctx));
        e.opened += 1;
    }
    fn exp(ctx: *anyopaque, _: artifacts.ArtifactKind, _: []const u8, _: []const u8) anyerror!void {
        const e: *Ext = @ptrCast(@alignCast(ctx));
        e.exported += 1;
    }
};

const Fx = struct {
    tmp: testing.TmpDir,
    store: *artifacts.ArtifactStore,
    host: Host = .{},
    ext: Ext = .{},
    t: *TestApp,
    pane: *ArtifactPane,

    fn init(f: *Fx, ports: pane_mod.Ports) !void {
        f.* = .{ .tmp = testing.tmpDir(.{ .iterate = true }), .store = undefined, .t = undefined, .pane = undefined };
        f.store = try artifacts.ArtifactStore.open(gpa, io, f.tmp.dir, .{});
        f.t = try TestApp.init(gpa, .{ .root = .of(&f.host), .size = .{ .w = 900, .h = 700 } });
        var p = ports;
        p.store = f.store;
        f.pane = try ArtifactPane.init(gpa, &f.t.app, p);
        f.host.pane = f.pane;
    }

    fn initFull(f: *Fx) !void {
        try f.init(.{ .store = undefined });
        f.pane.p.save = .{ .ctx = &f.ext, .save = Ext.save };
        f.pane.p.copy = .{ .ctx = &f.ext, .f = Ext.copy };
        f.pane.p.open_external = .{ .ctx = &f.ext, .f = Ext.open };
        f.pane.p.export_ = .{ .ctx = &f.ext, .f = Ext.exp };
    }

    fn deinit(f: *Fx) void {
        f.host.pane = null;
        f.pane.deinit();
        f.t.deinit();
        f.store.close();
        f.tmp.cleanup();
    }

    fn settle(f: *Fx) void {
        f.t.win.markAllDirty();
        _ = f.t.settle();
        f.t.win.markAllDirty();
        _ = f.t.settle();
    }

    fn sem(f: *Fx) ![]u8 {
        return f.t.semanticsSnapshot(gpa);
    }

    fn expectHas(f: *Fx, needle: []const u8) !void {
        const s = try f.sem();
        defer gpa.free(s);
        if (std.mem.indexOf(u8, s, needle) == null) {
            std.debug.print("missing {s} in\n{s}\n", .{ needle, s });
            return error.TestUnexpectedResult;
        }
    }

    fn expectLacks(f: *Fx, needle: []const u8) !void {
        const s = try f.sem();
        defer gpa.free(s);
        if (std.mem.indexOf(u8, s, needle) != null) {
            std.debug.print("unexpected {s} in\n{s}\n", .{ needle, s });
            return error.TestUnexpectedResult;
        }
    }
};

test "artifact_pane: placeholder first, then markdown, version stepping" {
    var f: Fx = undefined;
    try f.initFull();
    defer f.deinit();
    f.settle();
    try f.expectHas("No artifact open.");
    const id = try f.store.create(.{ .kind = .markdown, .title = "Findings", .content = "# Findings\n\nGrowth was **flat**.\n" });
    _ = try f.store.update(id, "# Findings\n\nGrowth was 4%.\n", "with numbers");
    f.pane.open(id, null);
    // Before the worker's result is delivered, a placeholder.
    try testing.expectEqual(pane_mod.Phase.loading, f.pane.phase);
    f.t.win.markAllDirty();
    _ = f.t.frame();
    try testing.expect(f.t.find(.{ .test_id = "artifact-loading" }) != null);
    f.settle();
    try testing.expectEqual(pane_mod.Phase.ready, f.pane.phase);
    try f.expectHas("Findings");
    try f.expectHas("Growth was 4%.");
    try f.expectHas("group \"Version 2 of 2\"");
    // Step back to v1.
    try f.t.click(.{ .role = .button, .name = "‹" });
    f.settle();
    try f.expectHas("group \"Version 1 of 2\"");
    try f.expectHas("flat");
    // A new version arrives: v1 stays shown (the user picked it) ...
    _ = try f.store.update(id, "# Findings\n\nGrowth was 5%.\n", null);
    f.settle();
    try f.expectHas("group \"Version 1 of 3\"");
    // ... until stepping forward to the latest, which then follows updates.
    try f.t.click(.{ .role = .button, .name = "›" });
    f.settle();
    try f.t.click(.{ .role = .button, .name = "›" });
    f.settle();
    try f.expectHas("Growth was 5%.");
    _ = try f.store.update(id, "# Findings\n\nGrowth was 6%.\n", null);
    f.settle();
    try f.expectHas("group \"Version 4 of 4\"");
    try f.expectHas("Growth was 6%.");
    // Save proposes a path by kind and reports the changeset.
    try f.t.click(.{ .role = .button, .name = "Save" });
    f.settle();
    try testing.expectEqualStrings("docs/findings.md", f.ext.last_save[0..f.ext.last_len]);
    try f.expectHas("Saved to docs/findings.md (changeset 77");
    try f.t.click(.{ .role = .button, .name = "Copy" });
    try testing.expectEqual(@as(u32, 1), f.ext.copied);
}

test "artifact_pane: table" {
    var f: Fx = undefined;
    try f.init(.{ .store = undefined });
    defer f.deinit();
    const id = try f.store.create(.{ .kind = .table, .title = "Sales", .content = "region,amount\nnorth,12\nsouth,7\n" });
    f.pane.open(id, null);
    f.settle();
    try f.expectHas("Table");
    try f.expectHas("columnheader \"region\"");
    try f.expectHas("gridcell \"south\"");
    try f.expectHas("gridcell \"12\"");
    // No save or copy port: no buttons for them.
    try f.expectLacks("button \"Save\"");
}

test "artifact_pane: code, html confirmation, image, chart and diagram" {
    var f: Fx = undefined;
    try f.initFull();
    defer f.deinit();

    const code = try f.store.create(.{ .kind = .code, .title = "fit", .content = "def fit():\n    return ```x```\n", .source_lang = "python" });
    f.pane.open(code, null);
    f.settle();
    try f.expectHas("def fit():");
    try f.expectHas("return ```x```");

    // HTML only opens outside after a confirmation.
    const html = try f.store.create(.{ .kind = .html_source, .title = "page", .content = "<script>alert(1)</script>" });
    f.pane.open(html, null);
    f.settle();
    try f.expectHas("<script>alert(1)</script>");
    try f.t.click(.{ .role = .button, .name = "Open externally" });
    f.settle();
    try testing.expectEqual(@as(u32, 0), f.ext.opened);
    try f.expectHas("dialog \"Open HTML outside zigguro\"");
    try f.t.click(.{ .role = .button, .name = "Cancel" });
    f.settle();
    try f.expectLacks("dialog \"Open HTML outside zigguro\"");
    try f.t.click(.{ .role = .button, .name = "Open externally" });
    f.settle();
    try f.t.click(.{ .role = .button, .name = "Open in browser" });
    f.settle();
    try testing.expectEqual(@as(u32, 1), f.ext.opened);

    // Without an image cache: the size.
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x00\x10\x00\x00\x00\x08\x08\x02\x00\x00\x00";
    const img = try f.store.create(.{ .kind = .image, .title = "plot", .content = png });
    f.pane.open(img, null);
    f.settle();
    try f.expectHas("img \"plot\"");
    try f.expectHas("png image, 16×8");
    try f.expectLacks("button \"Copy\"");

    // Without renderers, charts and diagrams show their source.
    const chart = try f.store.create(.{ .kind = .chart, .title = "trend", .content = "{\"mark\":\"line\"}" });
    f.pane.open(chart, null);
    f.settle();
    try f.expectHas("Chart preview needs the chart renderer");
    try f.expectHas("{\"mark\":\"line\"}");
    try f.t.click(.{ .role = .button, .name = "Export SVG" });
    try testing.expectEqual(@as(u32, 1), f.ext.exported);
    const dia = try f.store.create(.{ .kind = .diagram, .title = "flow", .content = "graph TD; A-->B" });
    f.pane.open(dia, null);
    f.settle();
    try f.expectHas("Diagram preview needs the diagram renderer");
}

const Fake = struct {
    fn chart(_: *anyopaque, ui: *zg_gui.Ui, content: []const u8) void {
        ui.textf("rendered {d} bytes", .{content.len}, .{});
    }
};

test "artifact_pane: renderer, auto-open policy, gone artifacts" {
    var f: Fx = undefined;
    var dummy: u8 = 0;
    try f.init(.{ .store = undefined, .chart = .{ .ctx = &dummy, .build = Fake.chart }, .auto_open = .interactive });
    defer f.deinit();
    const chart = try f.store.create(.{ .kind = .chart, .title = "trend", .content = "{\"mark\":\"line\"}" });
    // A background run's artifact isn't opened.
    f.pane.artifactCreated(chart, false);
    try testing.expect(f.pane.current == null);
    f.pane.artifactCreated(chart, true);
    f.settle();
    try f.expectHas("rendered 15 bytes");
    try f.expectLacks("renderer; showing");
    f.pane.p.auto_open = .never;
    f.pane.artifactCreated(chart, true);
    try testing.expectEqual(@as(u32, 1), f.pane.opened_by_policy);
    f.pane.open(.{ .n = 12345 }, null);
    f.settle();
    try f.expectHas("This artifact is gone.");
    f.pane.close();
    f.settle();
    try f.expectHas("No artifact open.");
}
