const std = @import("std");
const ZlsSupport = @import("zls_support.zig");
const Manager = @import("../Manager.zig");
const Registry = @import("../registry/Registry.zig");
const testing = std.testing;

test "zls_support: settings become the zls section, other servers get none" {
    var z = ZlsSupport.init(testing.allocator, testing.io, null);
    defer z.deinit();
    try testing.expect(try z.setSettings(.{ .zig_path = "/nonexistent/zig", .zls = &.{.{ .name = "semantic_tokens", .value = .{ .string = "none" } }} }));
    try testing.expect(!try z.setSettings(.{ .zig_path = "/nonexistent/zig", .zls = &.{.{ .name = "semantic_tokens", .value = .{ .string = "none" } }} }));

    const zls_def: Registry.ServerDef = .{ .id = "zls", .command = &.{"zls"}, .languages = &.{"zig"}, .settings_section = "zls" };
    const other_def: Registry.ServerDef = .{ .id = "clangd", .command = &.{"clangd"}, .languages = &.{"c"} };
    var s: Manager.Server = .{ .mgr = undefined, .id = 0, .def = &zls_def, .root = &.{}, .exe = &.{}, .status = .running, .arena = undefined };
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = z.provider();
    const v = p.get(p.ctx, &s, a);
    try testing.expectEqualStrings(
        \\{"zig_exe_path":"/nonexistent/zig","semantic_tokens":"none"}
    , try std.json.Stringify.valueAlloc(a, v, .{}));
    // The toolchain at zig.path does not run: the details say so.
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try z.writeDetails(&s, &w);
    try testing.expectEqualStrings("Zig: not found (set zig.path)\n", w.buffered());
    try testing.expect(!z.needsCheckStep(&s));
    var mb: [256]u8 = undefined;
    try testing.expect(z.takePairingWarning(&s, &mb) == null);

    s.def = &other_def;
    try testing.expect(p.get(p.ctx, &s, a) == .null);
}
