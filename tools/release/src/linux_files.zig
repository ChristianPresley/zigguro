//! Generated Linux desktop-integration files, all derived from
//! `zg_release.product` so the app id, WM_CLASS and MIME list live only in
//! `packaging/product.zon`: the `.desktop` entry (freedesktop Desktop
//! Entry 1.5), the AppStream metainfo and the shared-mime-info package for
//! the types the system database may lack.

const std = @import("std");
const Allocator = std.mem.Allocator;
const product = @import("zg_release").product;

/// Desktop entry options.
pub const DesktopOptions = struct {
    /// `Exec=` program: "AppRun" in the tarball, an absolute path when installed.
    exec: []const u8,
};

/// MIME types zigguro defines itself (the rest come from shared-mime-info).
pub const own_types = [_][]const u8{ "text/x-zig", "text/x-zon", "text/x-log", "application/jsonc", "text/x-tsx" };

/// The `.desktop` file text.
pub fn desktopEntry(gpa: Allocator, o: DesktopOptions) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w = &aw.writer;
    try w.print(
        \\[Desktop Entry]
        \\Type=Application
        \\Version=1.5
        \\Name={s}
        \\GenericName=Code Editor
        \\Comment=AI-native code editor
        \\Exec={s} %F
        \\Icon={s}
        \\Terminal=false
        \\StartupNotify=true
        \\StartupWMClass={s}
        \\Categories=Development;TextEditor;IDE;
        \\Keywords=zig;editor;ide;ai;code;
        \\MimeType=
    , .{ product.display_name, o.exec, product.app_id, product.wm_class });
    var seen: [64][]const u8 = undefined;
    var n: usize = 0;
    outer: for (product.file_associations) |a| {
        for (seen[0..n]) |s| if (std.mem.eql(u8, s, a.mime)) continue :outer;
        seen[n] = a.mime;
        n += 1;
        try w.print("{s};", .{a.mime});
    }
    try w.writeAll("\nActions=new-window;\n\n[Desktop Action new-window]\nName=New Window\n");
    try w.print("Exec={s} --new-window\n", .{o.exec});
    return aw.toOwnedSlice();
}

/// AppStream metainfo XML.
pub fn metainfo(gpa: Allocator) ![]u8 {
    return std.fmt.allocPrint(gpa,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<component type="desktop-application">
        \\  <id>{s}</id>
        \\  <metadata_license>CC0-1.0</metadata_license>
        \\  <project_license>Apache-2.0</project_license>
        \\  <name>{s}</name>
        \\  <summary>AI-native code editor</summary>
        \\  <description>
        \\    <p>An AI-native code editor built in pure Zig: fast, local-first, and every AI change reviewed before it lands.</p>
        \\  </description>
        \\  <launchable type="desktop-id">{s}.desktop</launchable>
        \\  <url type="homepage">{s}</url>
        \\  <url type="bugtracker">{s}</url>
        \\  <developer id="{s}"><name>{s}</name></developer>
        \\  <content_rating type="oars-1.1"/>
        \\</component>
        \\
    , .{ product.app_id, product.display_name, product.app_id, product.homepage, product.issues_url, product.app_id, product.publisher });
}

/// shared-mime-info package XML for `own_types`.
pub fn mimePackage(gpa: Allocator) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w = &aw.writer;
    try w.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<mime-info xmlns=\"http://www.freedesktop.org/standards/shared-mime-info\">\n");
    for (own_types) |t| {
        try w.print("  <mime-type type=\"{s}\">\n", .{t});
        for (product.file_associations) |a| if (std.mem.eql(u8, a.mime, t)) {
            try w.print("    <comment>{s}</comment>\n", .{a.description});
            break;
        };
        try w.writeAll("    <sub-class-of type=\"text/plain\"/>\n");
        for (product.file_associations) |a| if (std.mem.eql(u8, a.mime, t)) try w.print("    <glob pattern=\"*{s}\"/>\n", .{a.ext});
        try w.writeAll("  </mime-type>\n");
    }
    try w.writeAll("</mime-info>\n");
    return aw.toOwnedSlice();
}

test "linux_files: desktop entry" {
    const d = try desktopEntry(std.testing.allocator, .{ .exec = "AppRun" });
    defer std.testing.allocator.free(d);
    try std.testing.expect(std.mem.startsWith(u8, d, "[Desktop Entry]\n"));
    try std.testing.expect(std.mem.indexOf(u8, d, "Exec=AppRun %F\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "StartupWMClass=Zigguro\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, d, "text/x-zig;") != null);
    // application/yaml appears once although two extensions map to it.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, d, "application/yaml;"));
    const m = try mimePackage(std.testing.allocator);
    defer std.testing.allocator.free(m);
    try std.testing.expect(std.mem.indexOf(u8, m, "<glob pattern=\"*.zig\"/>") != null);
    const x = try metainfo(std.testing.allocator);
    defer std.testing.allocator.free(x);
    try std.testing.expect(std.mem.indexOf(u8, x, "<id>dev.zigguro.zigguro</id>") != null);
}
