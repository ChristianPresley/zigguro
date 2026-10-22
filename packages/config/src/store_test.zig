//! SettingsStore tests: the precedence matrix (layers × languages × merge
//! modes × scopes), snapshots, diffs, subscriptions and concurrency.

const std = @import("std");
const store = @import("store.zig");
const schema = @import("schema.zig");
const zon_load = @import("zon_load.zig");
const diag = @import("diag.zig");

const SettingsStore = store.SettingsStore;
const LayerKind = store.LayerKind;
const FolderId = store.FolderId;
const Value = store.Value;
const gpa = std.testing.allocator;
const io = std.testing.io;

const test_schema = .{ .package = "test", .settings = .{
    .{ .key = "a.int", .type = .int, .default = 1, .scope = .language_overridable },
    .{ .key = "a.win", .type = .int, .default = 0, .scope = .window },
    .{ .key = "a.app", .type = .int, .default = 0, .scope = .application },
    .{ .key = "a.mach", .type = .int, .default = 0, .scope = .machine },
    .{ .key = "a.mo", .type = .int, .default = 0, .scope = .machine_overridable },
    .{ .key = "a.res", .type = .int, .default = 0, .scope = .resource },
    .{ .key = "a.obj", .type = .object, .additional_properties = .any, .merge = .merge_object, .default = .{ .x = 1 }, .scope = .language_overridable },
    .{ .key = "a.list", .type = .array, .items = .string, .merge = .concat_unique, .default = .{"d"}, .scope = .language_overridable },
    .{ .key = "a.secret", .type = .bool, .default = false, .restricted = true, .scope = .resource },
    .{ .key = "lsp.servers.zls.path", .type = .string, .default = "zls" },
    .{ .key = "lsp.servers.zls.args", .type = .array, .items = .string, .default = .{} },
    .{ .key = "lsp.trace", .type = .bool, .default = false },
} };
const reg = schema.SchemaRegistry.comptimeInit(.{test_schema});

const L = struct { kind: LayerKind, folder: ?u32 = null, src: [:0]const u8 };
const Case = struct { layers: []const L, key: []const u8, folder: ?u32 = null, lang: ?[]const u8 = null, want: []const u8 };

const U = LayerKind.user;
const W = LayerKind.workspace;
const WL = LayerKind.workspace_local;
const F = LayerKind.folder;
const E = LayerKind.editorconfig;
const C = LayerKind.cli;
const P = LayerKind.policy;

const cases = [_]Case{
    // Plain precedence for a language-overridable key.
    .{ .layers = &.{}, .key = "a.int", .want = "1" },
    .{ .layers = &.{.{ .kind = U, .src = ".{ .a = .{ .int = 2 } }" }}, .key = "a.int", .want = "2" },
    .{ .layers = &.{ .{ .kind = U, .src = ".{ .@\"a.int\" = 2 }" }, .{ .kind = W, .src = ".{ .@\"a.int\" = 3 }" } }, .key = "a.int", .want = "3" },
    .{ .layers = &.{ .{ .kind = W, .src = ".{ .@\"a.int\" = 3 }" }, .{ .kind = WL, .src = ".{ .@\"a.int\" = 4 }" } }, .key = "a.int", .want = "4" },
    .{ .layers = &.{ .{ .kind = WL, .src = ".{ .@\"a.int\" = 4 }" }, .{ .kind = C, .src = ".{ .@\"a.int\" = 5 }" } }, .key = "a.int", .want = "5" },
    .{ .layers = &.{ .{ .kind = C, .src = ".{ .@\"a.int\" = 5 }" }, .{ .kind = P, .src = ".{ .@\"a.int\" = 6 }" } }, .key = "a.int", .want = "6" },
    .{ .layers = &.{ .{ .kind = U, .src = ".{ .@\"a.int\" = 2 }" }, .{ .kind = P, .src = ".{ .@\"a.int\" = 6 }" } }, .key = "a.int", .want = "6" },
    // Folder and editorconfig never affect window scope.
    .{ .layers = &.{.{ .kind = F, .folder = 0, .src = ".{ .@\"a.int\" = 7 }" }}, .key = "a.int", .want = "1" },
    .{ .layers = &.{.{ .kind = F, .folder = 0, .src = ".{ .@\"a.int\" = 7 }" }}, .key = "a.int", .folder = 0, .want = "7" },
    .{ .layers = &.{.{ .kind = F, .folder = 0, .src = ".{ .@\"a.int\" = 7 }" }}, .key = "a.int", .folder = 1, .want = "1" },
    .{ .layers = &.{ .{ .kind = F, .folder = 0, .src = ".{ .@\"a.int\" = 7 }" }, .{ .kind = F, .folder = 1, .src = ".{ .@\"a.int\" = 8 }" } }, .key = "a.int", .folder = 1, .want = "8" },
    .{ .layers = &.{ .{ .kind = W, .src = ".{ .@\"a.int\" = 3 }" }, .{ .kind = F, .folder = 0, .src = ".{ .@\"a.int\" = 7 }" } }, .key = "a.int", .folder = 0, .want = "7" },
    .{ .layers = &.{ .{ .kind = F, .folder = 0, .src = ".{ .@\"a.int\" = 7 }" }, .{ .kind = C, .src = ".{ .@\"a.int\" = 5 }" } }, .key = "a.int", .folder = 0, .want = "5" },
    .{ .layers = &.{ .{ .kind = F, .folder = 0, .src = ".{ .@\"a.int\" = 7 }" }, .{ .kind = E, .folder = 0, .src = ".{ .@\"a.int\" = 9 }" } }, .key = "a.int", .folder = 0, .want = "9" },
    .{ .layers = &.{.{ .kind = E, .folder = 0, .src = ".{ .@\"a.int\" = 9 }" }}, .key = "a.int", .want = "1" },
    .{ .layers = &.{ .{ .kind = E, .folder = 0, .src = ".{ .@\"a.int\" = 9 }" }, .{ .kind = P, .src = ".{ .@\"a.int\" = 6 }" } }, .key = "a.int", .folder = 0, .want = "6" },
    // Language overrides beat non-language values at any layer.
    .{ .layers = &.{.{ .kind = U, .src = ".{ .@\"[zig]\" = .{ .@\"a.int\" = 10 } }" }}, .key = "a.int", .lang = "zig", .want = "10" },
    .{ .layers = &.{.{ .kind = U, .src = ".{ .@\"[zig]\" = .{ .@\"a.int\" = 10 } }" }}, .key = "a.int", .lang = "c", .want = "1" },
    .{ .layers = &.{.{ .kind = U, .src = ".{ .@\"[zig]\" = .{ .@\"a.int\" = 10 } }" }}, .key = "a.int", .want = "1" },
    .{ .layers = &.{ .{ .kind = U, .src = ".{ .@\"[zig]\" = .{ .@\"a.int\" = 10 } }" }, .{ .kind = W, .src = ".{ .@\"a.int\" = 3 }" } }, .key = "a.int", .lang = "zig", .want = "10" },
    .{ .layers = &.{ .{ .kind = U, .src = ".{ .@\"[zig]\" = .{ .@\"a.int\" = 10 } }" }, .{ .kind = C, .src = ".{ .@\"a.int\" = 5 }" } }, .key = "a.int", .lang = "zig", .want = "10" },
    .{ .layers = &.{ .{ .kind = U, .src = ".{ .@\"[zig]\" = .{ .@\"a.int\" = 10 } }" }, .{ .kind = W, .src = ".{ .@\"[zig]\" = .{ .@\"a.int\" = 11 } }" } }, .key = "a.int", .lang = "zig", .want = "11" },
    .{ .layers = &.{ .{ .kind = U, .src = ".{ .@\"[zig]\" = .{ .@\"a.int\" = 10 } }" }, .{ .kind = F, .folder = 0, .src = ".{ .@\"[zig]\" = .{ .@\"a.int\" = 12 } }" } }, .key = "a.int", .folder = 0, .lang = "zig", .want = "12" },
    .{ .layers = &.{ .{ .kind = U, .src = ".{ .@\"[zig]\" = .{ .@\"a.int\" = 10 } }" }, .{ .kind = F, .folder = 0, .src = ".{ .@\"a.int\" = 7 }" } }, .key = "a.int", .folder = 0, .lang = "zig", .want = "10" },
    .{ .layers = &.{ .{ .kind = U, .src = ".{ .@\"[zig]\" = .{ .@\"a.int\" = 10 } }" }, .{ .kind = E, .folder = 0, .src = ".{ .@\"a.int\" = 9 }" } }, .key = "a.int", .folder = 0, .lang = "zig", .want = "10" },
    .{ .layers = &.{ .{ .kind = C, .src = ".{ .@\"[zig]\" = .{ .@\"a.int\" = 13 } }" }, .{ .kind = W, .src = ".{ .@\"[zig]\" = .{ .@\"a.int\" = 11 } }" } }, .key = "a.int", .lang = "zig", .want = "13" },
    .{ .layers = &.{ .{ .kind = U, .src = ".{ .@\"[zig]\" = .{ .@\"a.int\" = 10 } }" }, .{ .kind = P, .src = ".{ .@\"a.int\" = 6 }" } }, .key = "a.int", .lang = "zig", .want = "6" },
    .{ .layers = &.{ .{ .kind = P, .src = ".{ .@\"a.int\" = 6, .@\"[zig]\" = .{ .@\"a.int\" = 14 } }" }, .{ .kind = C, .src = ".{ .@\"[zig]\" = .{ .@\"a.int\" = 13 } }" } }, .key = "a.int", .lang = "zig", .want = "14" },
    .{ .layers = &.{.{ .kind = P, .src = ".{ .@\"[zig]\" = .{ .@\"a.int\" = 14 } }" }}, .key = "a.int", .lang = "c", .want = "1" },
    // Multi-language blocks.
    .{ .layers = &.{.{ .kind = U, .src = ".{ .@\"[zig][zon]\" = .{ .@\"a.int\" = 20 } }" }}, .key = "a.int", .lang = "zon", .want = "20" },
    .{ .layers = &.{.{ .kind = U, .src = ".{ .@\"[zig][zon]\" = .{ .@\"a.int\" = 20 } }" }}, .key = "a.int", .lang = "zig", .want = "20" },
    .{ .layers = &.{.{ .kind = U, .src = ".{ .@\"[zig][zon]\" = .{ .@\"a.int\" = 20 }, .@\"[zig]\" = .{ .@\"a.int\" = 21 } }" }}, .key = "a.int", .lang = "zig", .want = "21" },
    .{ .layers = &.{.{ .kind = U, .src = ".{ .@\"[zig]\" = .{ .@\"a.int\" = 21 }, .@\"[zig][zon]\" = .{ .@\"a.int\" = 20 } }" }}, .key = "a.int", .lang = "zig", .want = "21" },
    .{ .layers = &.{.{ .kind = U, .src = ".{ .@\"[zig][zon]\" = .{ .@\"a.int\" = 20 }, .@\"[zig]\" = .{ .@\"a.int\" = 21 } }" }}, .key = "a.int", .lang = "zon", .want = "20" },
    .{ .layers = &.{ .{ .kind = U, .src = ".{ .@\"[zig]\" = .{ .@\"a.int\" = 21 } }" }, .{ .kind = W, .src = ".{ .@\"[zon][zig]\" = .{ .@\"a.int\" = 22 } }" } }, .key = "a.int", .lang = "zig", .want = "21" },
    .{ .layers = &.{ .{ .kind = U, .src = ".{ .@\"[zig]\" = .{ .@\"a.int\" = 21 } }" }, .{ .kind = W, .src = ".{ .@\"[zon][zig]\" = .{ .@\"a.int\" = 22 } }" } }, .key = "a.int", .lang = "zon", .want = "22" },
    .{ .layers = &.{ .{ .kind = U, .src = ".{ .@\"[zig][zon]\" = .{ .@\"a.int\" = 20 } }" }, .{ .kind = W, .src = ".{ .@\"[zon][zig]\" = .{ .@\"a.int\" = 22 } }" } }, .key = "a.int", .lang = "zig", .want = "22" },
    // Scope enforcement.
    .{ .layers = &.{.{ .kind = U, .src = ".{ .@\"a.app\" = 1 }" }}, .key = "a.app", .want = "1" },
    .{ .layers = &.{.{ .kind = W, .src = ".{ .@\"a.app\" = 1 }" }}, .key = "a.app", .want = "0" },
    .{ .layers = &.{.{ .kind = WL, .src = ".{ .@\"a.app\" = 1 }" }}, .key = "a.app", .want = "0" },
    .{ .layers = &.{.{ .kind = F, .folder = 0, .src = ".{ .@\"a.app\" = 1 }" }}, .key = "a.app", .folder = 0, .want = "0" },
    .{ .layers = &.{.{ .kind = C, .src = ".{ .@\"a.app\" = 1 }" }}, .key = "a.app", .want = "1" },
    .{ .layers = &.{.{ .kind = P, .src = ".{ .@\"a.app\" = 1 }" }}, .key = "a.app", .want = "1" },
    .{ .layers = &.{.{ .kind = W, .src = ".{ .@\"a.mach\" = 1 }" }}, .key = "a.mach", .want = "0" },
    .{ .layers = &.{.{ .kind = U, .src = ".{ .@\"a.mach\" = 1 }" }}, .key = "a.mach", .want = "1" },
    .{ .layers = &.{.{ .kind = W, .src = ".{ .@\"a.mo\" = 1 }" }}, .key = "a.mo", .want = "1" },
    .{ .layers = &.{.{ .kind = F, .folder = 0, .src = ".{ .@\"a.mo\" = 2 }" }}, .key = "a.mo", .folder = 0, .want = "2" },
    .{ .layers = &.{.{ .kind = W, .src = ".{ .@\"a.win\" = 1 }" }}, .key = "a.win", .want = "1" },
    .{ .layers = &.{.{ .kind = F, .folder = 0, .src = ".{ .@\"a.win\" = 1 }" }}, .key = "a.win", .folder = 0, .want = "0" },
    .{ .layers = &.{.{ .kind = F, .folder = 0, .src = ".{ .@\"a.res\" = 1 }" }}, .key = "a.res", .folder = 0, .want = "1" },
    .{ .layers = &.{.{ .kind = U, .src = ".{ .@\"[zig]\" = .{ .@\"a.res\" = 1 } }" }}, .key = "a.res", .lang = "zig", .want = "0" },
    // merge_object.
    .{ .layers = &.{.{ .kind = U, .src = ".{ .@\"a.obj\" = .{ .y = 2 } }" }}, .key = "a.obj", .want = ".{ .x = 1, .y = 2 }" },
    .{ .layers = &.{ .{ .kind = U, .src = ".{ .@\"a.obj\" = .{ .y = 2 } }" }, .{ .kind = W, .src = ".{ .@\"a.obj\" = .{ .y = 3, .z = 4 } }" } }, .key = "a.obj", .want = ".{ .x = 1, .y = 3, .z = 4 }" },
    .{ .layers = &.{.{ .kind = U, .src = ".{ .@\"a.obj\" = .{ .x = \"default\" } }" }}, .key = "a.obj", .want = ".{}" },
    .{ .layers = &.{.{ .kind = U, .src = ".{ .@\"a.obj\" = .{ .n = .{ .p = 1 } } }" }}, .key = "a.obj", .want = ".{ .n = .{ .p = 1 }, .x = 1 }" },
    .{ .layers = &.{ .{ .kind = U, .src = ".{ .@\"a.obj\" = .{ .n = .{ .p = 1 } } }" }, .{ .kind = W, .src = ".{ .@\"a.obj\" = .{ .n = .{ .q = 2 } } }" } }, .key = "a.obj", .want = ".{ .n = .{ .p = 1, .q = 2 }, .x = 1 }" },
    .{ .layers = &.{ .{ .kind = U, .src = ".{ .@\"a.obj\" = .{ .y = 2 } }" }, .{ .kind = F, .folder = 0, .src = ".{ .@\"a.obj\" = .{ .f = 5 } }" } }, .key = "a.obj", .folder = 0, .want = ".{ .f = 5, .x = 1, .y = 2 }" },
    .{ .layers = &.{ .{ .kind = U, .src = ".{ .@\"a.obj\" = .{ .y = 2 } }" }, .{ .kind = F, .folder = 0, .src = ".{ .@\"a.obj\" = .{ .f = 5 } }" } }, .key = "a.obj", .want = ".{ .x = 1, .y = 2 }" },
    .{ .layers = &.{.{ .kind = U, .src = ".{ .@\"a.obj\" = .{ .y = 2 }, .@\"[zig]\" = .{ .@\"a.obj\" = .{ .l = 6 } } }" }}, .key = "a.obj", .lang = "zig", .want = ".{ .l = 6, .x = 1, .y = 2 }" },
    .{ .layers = &.{ .{ .kind = U, .src = ".{ .@\"a.obj\" = .{ .y = 2 } }" }, .{ .kind = P, .src = ".{ .@\"a.obj\" = .{ .y = 9 } }" } }, .key = "a.obj", .want = ".{ .x = 1, .y = 9 }" },
    // concat_unique.
    .{ .layers = &.{.{ .kind = U, .src = ".{ .@\"a.list\" = .{\"u\"} }" }}, .key = "a.list", .want = ".{ \"d\", \"u\" }" },
    .{ .layers = &.{ .{ .kind = U, .src = ".{ .@\"a.list\" = .{\"u\"} }" }, .{ .kind = W, .src = ".{ .@\"a.list\" = .{ \"w\", \"u\" } }" } }, .key = "a.list", .want = ".{ \"d\", \"u\", \"w\" }" },
    .{ .layers = &.{ .{ .kind = U, .src = ".{ .@\"a.list\" = .{\"u\"} }" }, .{ .kind = P, .src = ".{ .@\"a.list\" = .{\"p\"} }" } }, .key = "a.list", .want = ".{ \"d\", \"u\", \"p\" }" },
    .{ .layers = &.{ .{ .kind = U, .src = ".{ .@\"a.list\" = .{\"u\"} }" }, .{ .kind = F, .folder = 2, .src = ".{ .@\"a.list\" = .{\"f\"} }" } }, .key = "a.list", .folder = 2, .want = ".{ \"d\", \"u\", \"f\" }" },
    .{ .layers = &.{.{ .kind = U, .src = ".{ .@\"a.list\" = .{\"u\"}, .@\"[zig]\" = .{ .@\"a.list\" = .{\"z\"} } }" }}, .key = "a.list", .lang = "zig", .want = ".{ \"d\", \"u\", \"z\" }" },
    .{ .layers = &.{.{ .kind = U, .src = ".{ .@\"a.list\" = .{\"u\"}, .@\"[zig]\" = .{ .@\"a.list\" = .{\"z\"} } }" }}, .key = "a.list", .lang = "c", .want = ".{ \"d\", \"u\" }" },
    // Invalid values fall back to the next lower layer.
    .{ .layers = &.{ .{ .kind = U, .src = ".{ .@\"a.int\" = 2 }" }, .{ .kind = W, .src = ".{ .@\"a.int\" = \"three\" }" } }, .key = "a.int", .want = "2" },
    .{ .layers = &.{ .{ .kind = U, .src = ".{ .@\"a.list\" = .{\"u\"} }" }, .{ .kind = W, .src = ".{ .@\"a.list\" = .{ 1 } }" } }, .key = "a.list", .want = ".{ \"d\", \"u\" }" },
    // Nested keys under a prefix that is not itself a setting.
    .{ .layers = &.{.{ .kind = U, .src = ".{ .lsp = .{ .servers = .{ .zls = .{ .path = \"/bin/zls\" } } } }" }}, .key = "lsp.servers.zls.path", .want = "\"/bin/zls\"" },
};

fn applyLayers(s: *SettingsStore, layers: []const L) !void {
    for (layers) |l| {
        var d = diag.Diags.init(gpa);
        defer d.deinit();
        var doc = try zon_load.loadZon(gpa, l.src, &d);
        defer doc.deinit();
        _ = try s.setLayerSource(.{ .kind = l.kind, .folder = if (l.folder) |f| @enumFromInt(f) else null, .doc = &doc });
    }
    _ = try s.publish();
}

test "store: matrix golden" {
    try std.testing.expect(cases.len >= 60);
    for (cases, 0..) |c, i| {
        const s = try SettingsStore.init(gpa, io, &reg, .{ .trust = .trusted });
        defer s.deinit();
        try applyLayers(s, c.layers);
        const id = reg.lookup(c.key).?;
        const v = s.current().resolve(id, .{ .folder = if (c.folder) |f| @enumFromInt(f) else null, .lang = c.lang });
        var buf: [256]u8 = undefined;
        const got = try std.fmt.bufPrint(&buf, "{f}", .{v});
        if (!std.mem.eql(u8, got, c.want)) {
            std.debug.print("matrix case {d} ({s} folder={?d} lang={?s}): want {s}, got {s}\n", .{ i, c.key, c.folder, c.lang, c.want, got });
            return error.TestUnexpectedResult;
        }
    }
}

fn storeWith(layers: []const L, trust: store.TrustPort) !*SettingsStore {
    const s = try SettingsStore.init(gpa, io, &reg, .{ .trust = trust });
    errdefer s.deinit();
    try applyLayers(s, layers);
    return s;
}

test "store: application scope ignored in workspace" {
    const s = try storeWith(&.{.{ .kind = W, .src = ".{ .@\"a.app\" = 1 }" }}, .trusted);
    defer s.deinit();
    try std.testing.expect(s.layerDiags(.workspace, null).?.contains("application scope"));
}

test "store: restricted ignored when untrusted then applied when trusted" {
    const s = try storeWith(&.{.{ .kind = F, .folder = 0, .src = ".{ .@\"a.secret\" = true }" }}, .untrusted);
    defer s.deinit();
    const id = reg.lookup("a.secret").?;
    try std.testing.expect(!s.current().resolve(id, .{ .folder = @enumFromInt(0) }).bool);
    try s.setTrust(.trusted);
    const ch = (try s.publish()).?;
    try std.testing.expectEqual(@as(usize, 1), ch.ids.len);
    try std.testing.expect(s.current().resolve(id, .{ .folder = @enumFromInt(0) }).bool);
}

test "store: policy beats cli and is locked" {
    const s = try storeWith(&.{ .{ .kind = C, .src = ".{ .@\"a.int\" = 5 }" }, .{ .kind = P, .src = ".{ .@\"a.int\" = 6 }" } }, .trusted);
    defer s.deinit();
    const ins = s.current().inspect(reg.lookup("a.int").?, .{});
    try std.testing.expectEqual(@as(i64, 6), ins.effective.int);
    try std.testing.expect(ins.locked);
    try std.testing.expectEqual(LayerKind.policy, ins.origin);
    try std.testing.expectEqual(@as(i64, 5), ins.layers[@intFromEnum(LayerKind.cli)].?.int);
}

const Recorder = struct {
    calls: u32 = 0,
    last: std.ArrayList(u32) = .empty,

    fn cb(ctx: ?*anyopaque, ch: *const store.Change) void {
        const r: *Recorder = @ptrCast(@alignCast(ctx.?));
        r.calls += 1;
        r.last.clearRetainingCapacity();
        for (ch.ids) |id| r.last.append(gpa, id.index()) catch {};
    }
};

test "store: diff reports only changed ids; subscription prefix matching" {
    const s = try storeWith(&.{.{ .kind = U, .src = ".{ .@\"a.int\" = 2, .@\"lsp.trace\" = true }" }}, .trusted);
    defer s.deinit();
    var all: Recorder = .{};
    defer all.last.deinit(gpa);
    var lsp: Recorder = .{};
    defer lsp.last.deinit(gpa);
    _ = try s.subscribe("", Recorder.cb, &all);
    const sub = try s.subscribe("lsp.", Recorder.cb, &lsp);
    try applyLayers(s, &.{.{ .kind = U, .src = ".{ .@\"a.int\" = 3, .@\"lsp.trace\" = true }" }});
    try std.testing.expectEqual(@as(u32, 1), all.calls);
    try std.testing.expectEqualSlices(u32, &.{reg.lookup("a.int").?.index()}, all.last.items);
    try std.testing.expectEqual(@as(u32, 0), lsp.calls);
    try applyLayers(s, &.{.{ .kind = U, .src = ".{ .@\"a.int\" = 3 }" }});
    try std.testing.expectEqual(@as(u32, 1), lsp.calls);
    // No-op reload: nothing changes, nobody is called.
    try applyLayers(s, &.{.{ .kind = U, .src = ".{ .@\"a.int\" = 3 }" }});
    try std.testing.expectEqual(@as(u32, 2), all.calls);
    try std.testing.expectEqual(@as(u32, 1), lsp.calls);
    s.unsubscribe(sub);
    // Language-only change is reported too.
    try applyLayers(s, &.{.{ .kind = U, .src = ".{ .@\"a.int\" = 3, .@\"[zig]\" = .{ .@\"a.int\" = 4 } }" }});
    try std.testing.expectEqualSlices(u32, &.{reg.lookup("a.int").?.index()}, all.last.items);
}

test "store: section() builds object for lsp.servers.zls" {
    const s = try storeWith(&.{.{ .kind = U, .src = ".{ .@\"lsp.servers.zls.args\" = .{\"--x\"} }" }}, .trusted);
    defer s.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const v = try s.current().section(arena.allocator(), "lsp.servers.zls", .{});
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(".{ .args = .{ \"--x\" }, .path = \"zls\" }", try std.fmt.bufPrint(&buf, "{f}", .{v}));
    const lsp = try s.current().section(arena.allocator(), "lsp", .{});
    try std.testing.expect(!lsp.get("trace").?.bool);
    try std.testing.expectEqualStrings("zls", lsp.get("servers").?.get("zls").?.get("path").?.string);
    try std.testing.expectEqualStrings("zls", s.current().getByKey("lsp.servers.zls.path", .{}).?.string);
}

test "store: snapshot refcount frees old" {
    const s = try storeWith(&.{}, .trusted);
    defer s.deinit();
    const pinned = s.acquire();
    try applyLayers(s, &.{.{ .kind = U, .src = ".{ .@\"a.int\" = 2 }" }});
    try std.testing.expectEqual(@as(usize, 1), s.retired.items.len);
    try std.testing.expectEqual(@as(i64, 1), pinned.window[reg.lookup("a.int").?.index()].int);
    s.release(pinned);
    s.collect();
    try std.testing.expectEqual(@as(usize, 0), s.retired.items.len);
}

test "store: worker acquire/release while UI publishes" {
    const s = try storeWith(&.{}, .trusted);
    defer s.deinit();
    var stop: std.atomic.Value(bool) = .init(false);
    const Worker = struct {
        fn run(st: *SettingsStore, flag: *std.atomic.Value(bool)) void {
            const id = reg.lookup("a.int").?;
            while (!flag.load(.acquire)) {
                const snap = st.acquire();
                const v = snap.window[id.index()].int;
                std.debug.assert(v >= 1);
                st.release(snap);
            }
        }
    };
    var threads: [8]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{ s, &stop });
    var i: i64 = 0;
    var buf: [64]u8 = undefined;
    while (i < 200) : (i += 1) {
        const src = try std.fmt.bufPrintZ(&buf, ".{{ .@\"a.int\" = {d} }}", .{i + 1});
        try applyLayers(s, &.{.{ .kind = U, .src = src }});
    }
    stop.store(true, .release);
    for (threads) |t| t.join();
    s.collect();
    try std.testing.expectEqual(@as(usize, 0), s.retired.items.len);
}

test "store: typed handles" {
    const Own = store.Settings(test_schema);
    var tab = Own.handle(i64, "a.int");
    var lst = Own.handle(Value, "a.list");
    tab.bind(&reg);
    lst.bind(&reg);
    const s = try storeWith(&.{.{ .kind = U, .src = ".{ .@\"a.int\" = 2, .@\"[zig]\" = .{ .@\"a.int\" = 8 } }" }}, .trusted);
    defer s.deinit();
    try std.testing.expectEqual(@as(i64, 2), tab.get(s.current()));
    try std.testing.expectEqual(@as(i64, 8), tab.getFor(s.current(), .{ .lang = "zig" }));
    try std.testing.expectEqual(@as(usize, 1), lst.get(s.current()).array.len);
}

test "store: expand variables" {
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("TOOL", "/opt/tool");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const out = try store.expand(arena.allocator(), "${workspaceFolder}/x:${env:TOOL}:${userHome}:${secret:k}:${nope}", .{ .workspace_folder = "/ws", .user_home = "/h", .env = &env });
    try std.testing.expectEqualStrings("/ws/x:/opt/tool:/h:${secret:k}:${nope}", out);
}
