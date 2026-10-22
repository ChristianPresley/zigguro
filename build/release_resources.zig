//! Windows PE resources (E17.F01.S01.T02): the application manifest,
//! VERSIONINFO and icon, compiled by Zig's own resource compiler from
//! templates in packaging/windows, with no SDK or MinGW headers.

const std = @import("std");
const Version = @import("../packages/release/src/version.zig").Version;

pub const ExeKind = enum {
    app_gui,
    app_cli,
    /// The installer: also depends on Common Controls v6 (TaskDialog).
    setup,
};

/// What the resources say about the build.
pub const Values = struct {
    /// Full version string, e.g. `0.5.0-rc.1+gabc`.
    version: []const u8,
    /// `-Dsegment-heap`: opt into the segment heap in the manifest.
    segment_heap: bool = false,
};

const Product = struct {
    app_id: []const u8,
    display_name: []const u8,
    publisher: []const u8,
};

const common_controls =
    \\  <dependency>
    \\    <dependentAssembly>
    \\      <assemblyIdentity type="win32" name="Microsoft.Windows.Common-Controls" version="6.0.0.0" processorArchitecture="*" publicKeyToken="6595b64144ccf1df" language="*"/>
    \\    </dependentAssembly>
    \\  </dependency>
    \\
;

const segment_heap_line =
    \\      <heapType xmlns="http://schemas.microsoft.com/SMI/2020/WindowsSettings">SegmentHeap</heapType>
    \\
;

/// Adds manifest, VERSIONINFO and icon to `exe`; does nothing for other
/// targets.
pub fn addWindowsResources(b: *std.Build, exe: *std.Build.Step.Compile, kind: ExeKind, v: Values) void {
    if (exe.rootModuleTarget().os.tag != .windows) return;
    const product = loadProduct(b);
    const parsed = Version.parse(v.version) catch std.debug.panic("release_resources: bad version {s}", .{v.version});
    const fv = parsed.winFileVersion();
    const v4 = b.fmt("{d}.{d}.{d}.{d}", .{ fv[0], fv[1], fv[2], fv[3] });

    const wf = b.addWriteFiles();
    const manifest = fill(b, readTemplate(b, "packaging/windows/app.manifest.in"), &.{
        .{ "@APP_ID@", product.app_id },
        .{ "@VERSION4@", v4 },
        .{ "@SEGMENT_HEAP@", if (v.segment_heap) segment_heap_line else "" },
        .{ "@DEPENDENCIES@", if (kind == .setup) common_controls else "" },
    });
    exe.win32_manifest = wf.add(b.fmt("{s}.manifest", .{exe.name}), manifest);

    const description = switch (kind) {
        .app_gui => b.fmt("{s}", .{product.display_name}),
        .app_cli => b.fmt("{s} command line", .{product.display_name}),
        .setup => b.fmt("{s} setup", .{product.display_name}),
    };
    const rc = fill(b, readTemplate(b, "packaging/windows/resources.rc.in"), &.{
        .{ "@V1@", b.fmt("{d}", .{fv[0]}) },
        .{ "@V2@", b.fmt("{d}", .{fv[1]}) },
        .{ "@V3@", b.fmt("{d}", .{fv[2]}) },
        .{ "@V4@", b.fmt("{d}", .{fv[3]}) },
        .{ "@FLAGS@", if (parsed.pre.len != 0) "0x2" else "0x0" },
        .{ "@PUBLISHER@", rcEscape(b, product.publisher) },
        .{ "@DESCRIPTION@", rcEscape(b, description) },
        .{ "@VERSION@", rcEscape(b, v.version) },
        .{ "@NAME@", exe.name },
        .{ "@PRODUCT@", rcEscape(b, product.display_name) },
    });
    _ = wf.addCopyFile(b.path("packaging/icons/out/zigguro.ico"), "zigguro.ico");
    exe.root_module.addWin32ResourceFile(.{ .file = wf.add(b.fmt("{s}.rc", .{exe.name}), rc) });
    exe.rc_includes = .none;
}

fn loadProduct(b: *std.Build) Product {
    const text = b.build_root.handle.readFileAllocOptions(b.graph.io, "packaging/product.zon", b.allocator, .limited(64 * 1024), .of(u8), 0) catch |err|
        std.debug.panic("release_resources: packaging/product.zon: {t}", .{err});
    return std.zon.parse.fromSliceAlloc(Product, b.allocator, text, null, .{ .ignore_unknown_fields = true }) catch
        std.debug.panic("release_resources: packaging/product.zon does not parse", .{});
}

fn readTemplate(b: *std.Build, path: []const u8) []const u8 {
    return b.build_root.handle.readFileAlloc(b.graph.io, path, b.allocator, .limited(64 * 1024)) catch |err|
        std.debug.panic("release_resources: {s}: {t}", .{ path, err });
}

/// Replaces every `@KEY@` in `text`.
fn fill(b: *std.Build, text: []const u8, pairs: []const [2][]const u8) []const u8 {
    var out = text;
    for (pairs) |p| out = std.mem.replaceOwned(u8, b.allocator, out, p[0], p[1]) catch @panic("OOM");
    std.debug.assert(std.mem.indexOf(u8, out, "@\n") == null);
    return out;
}

/// Escapes a string for an .rc string literal (`"` is doubled).
fn rcEscape(b: *std.Build, s: []const u8) []const u8 {
    return std.mem.replaceOwned(u8, b.allocator, s, "\"", "\"\"") catch @panic("OOM");
}
