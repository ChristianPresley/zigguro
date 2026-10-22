//! Tests for the document registry, path normalization and file URIs.

const std = @import("std");
const registry = @import("registry.zig");

const testing = std.testing;
const DocumentRegistry = registry.DocumentRegistry;
const DocHandle = registry.DocHandle;
const RegistryEvent = registry.RegistryEvent;

test "registry: same path opens same doc" {
    var reg: DocumentRegistry = .init(testing.allocator, .posix);
    defer reg.deinit();
    const a = try reg.openFile("/src/./lib//a.zig", "first");
    const b = try reg.openFile("/src/x/../lib/a.zig", "ignored");
    try testing.expectEqual(a, b);
    try testing.expectEqual(@as(usize, 1), reg.count());
    try testing.expectEqualStrings("/src/lib/a.zig", reg.name(a).?);
    try testing.expectEqualStrings("file:///src/lib/a.zig", reg.uri(a).?);
    try testing.expectEqual(@as(u64, 5), reg.get(a).?.len());
    // POSIX is case-sensitive.
    const c = try reg.openFile("/src/lib/A.zig", "");
    try testing.expect(c.id != a.id);
    try testing.expectError(error.NotAbsolute, reg.openFile("src/a.zig", ""));
    try testing.expectEqual(a, (try reg.findFile("/src/lib/a.zig")).?);
    reg.release(a);
    try testing.expect(reg.isValid(a));
    reg.release(b);
    try testing.expect(!reg.isValid(a));
    try testing.expect(try reg.findFile("/src/lib/a.zig") == null);
    reg.release(c);
    try testing.expectEqual(@as(usize, 0), reg.count());
}

test "registry: windows case-insensitive" {
    var reg: DocumentRegistry = .init(testing.allocator, .windows);
    defer reg.deinit();
    const a = try reg.openFile("c:/Users/Ann/Ünïcode.txt", "x");
    defer reg.release(a);
    const b = try reg.openFile("C:\\USERS\\ann\\.\\ÜNÏCODE.TXT", "y");
    defer reg.release(b);
    try testing.expectEqual(a, b);
    // The first spelling is kept for display, with an upper-case drive.
    try testing.expectEqualStrings("C:\\Users\\Ann\\Ünïcode.txt", reg.name(a).?);
    try testing.expectEqualStrings("file:///c%3A/Users/Ann/%C3%9Cn%C3%AFcode.txt", reg.uri(a).?);
    const unc = try reg.openFile("\\\\Server\\Share\\dir\\f.c", "");
    defer reg.release(unc);
    try testing.expectEqual(unc, (try reg.findFile("//server/SHARE/dir/F.C")).?);
    try testing.expectEqualStrings("file://Server/Share/dir/f.c", reg.uri(unc).?);
    try testing.expectError(error.NotAbsolute, reg.openFile("\\rooted\\no-drive", ""));
}

test "registry: stale handle rejected" {
    var reg: DocumentRegistry = .init(testing.allocator, .posix);
    defer reg.deinit();
    const a = try reg.openFile("/a", "a");
    reg.release(a);
    // The slot is reused with a new generation.
    const b = try reg.openFile("/b", "b");
    defer reg.release(b);
    try testing.expectEqual(a.id, b.id);
    try testing.expect(a.gen != b.gen);
    try testing.expect(reg.get(a) == null);
    try testing.expect(reg.uri(a) == null);
    try testing.expectError(error.StaleHandle, reg.retain(a));
    try testing.expectError(error.StaleHandle, reg.rename(a, "/c"));
    reg.release(a); // ignored
    try testing.expect(reg.isValid(b));
}

const Recorder = struct {
    events: std.ArrayList(u8) = .empty,

    fn onEvent(ctx: *anyopaque, reg: *DocumentRegistry, ev: *const RegistryEvent) void {
        const r: *Recorder = @ptrCast(@alignCast(ctx));
        const gpa = testing.allocator;
        switch (ev.*) {
            .opened => |h| r.events.print(gpa, "open {s};", .{reg.uri(h).?}) catch unreachable,
            .closed => |h| r.events.print(gpa, "close {s} {d};", .{ reg.uri(h).?, reg.get(h).?.len() }) catch unreachable,
            .renamed => |x| r.events.print(gpa, "rename {s} {s};", .{ x.old_uri, x.new_uri }) catch unreachable,
        }
    }
};

test "registry: rename event" {
    var reg: DocumentRegistry = .init(testing.allocator, .posix);
    defer reg.deinit();
    var rec: Recorder = .{};
    defer rec.events.deinit(testing.allocator);
    _ = try reg.subscribe(.{ .ctx = &rec, .onEvent = Recorder.onEvent });
    const a = try reg.openFile("/old name.txt", "abc");
    const other = try reg.openFile("/taken", "");
    try reg.rename(a, "/dir/new#1.txt");
    try testing.expectError(error.AlreadyOpen, reg.rename(a, "/taken"));
    try testing.expectEqualStrings("/dir/new#1.txt", reg.name(a).?);
    try testing.expect(try reg.findFile("/old name.txt") == null);
    try testing.expectEqual(a, (try reg.findFile("/dir/new#1.txt")).?);
    // Save-as of an untitled document.
    const u = try reg.openUntitled("draft");
    try testing.expectEqualStrings("untitled:Untitled-1", reg.uri(u).?);
    try reg.rename(u, "/saved.txt");
    try testing.expect(reg.kind(u).? == .file);
    reg.release(a);
    reg.release(other);
    reg.release(u);
    try testing.expectEqualStrings(
        "open file:///old%20name.txt;open file:///taken;" ++
            "rename file:///old%20name.txt file:///dir/new%231.txt;" ++
            "open untitled:Untitled-1;rename untitled:Untitled-1 file:///saved.txt;" ++
            "close file:///dir/new%231.txt 3;close file:///taken 0;close file:///saved.txt 5;",
        rec.events.items,
    );
}

test "registry: untitled and agent documents" {
    var reg: DocumentRegistry = .init(testing.allocator, .posix);
    defer reg.deinit();
    const first = try reg.openUntitled("");
    defer reg.release(first);
    const second = try reg.openUntitled("");
    defer reg.release(second);
    try testing.expectEqualStrings("Untitled-2", reg.name(second).?);
    const a = try reg.openAgent(7, "plan notes.md", "x");
    defer reg.release(a);
    const a2 = try reg.openAgent(7, "plan notes.md", "y");
    defer reg.release(a2);
    const b = try reg.openAgent(8, "plan notes.md", "z");
    defer reg.release(b);
    try testing.expectEqual(a, a2);
    try testing.expect(a.id != b.id);
    try testing.expectEqualStrings("zigguro-agent://7/plan%20notes.md", reg.uri(a).?);
    try testing.expect(!reg.isReadOnly(a));
    try reg.setReadOnly(a, true);
    try testing.expect(reg.isReadOnly(a));
}

test "fileUri: table" {
    // VS Code's URI.file(...).toString() and LSP clients agree on these.
    const cases = [_][2][]const u8{
        .{ "/home/user/file.zig", "file:///home/user/file.zig" },
        .{ "/home/user/my file.zig", "file:///home/user/my%20file.zig" },
        .{ "/a/#hash?q", "file:///a/%23hash%3Fq" },
        .{ "/a/100%", "file:///a/100%25" },
        .{ "/tmp/ünï/日本.txt", "file:///tmp/%C3%BCn%C3%AF/%E6%97%A5%E6%9C%AC.txt" },
        .{ "/a/b-c_d.e~f", "file:///a/b-c_d.e~f" },
        .{ "/a/[x]@y:z", "file:///a/%5Bx%5D%40y%3Az" },
        .{ "C:\\Users\\x\\a.c", "file:///c%3A/Users/x/a.c" },
        .{ "d:/Projects/A B", "file:///d%3A/Projects/A%20B" },
        .{ "C:\\", "file:///c%3A/" },
        .{ "\\\\server\\share\\dir\\f.c", "file://server/share/dir/f.c" },
        .{ "//server/share", "file://server/share" },
        .{ "/", "file:///" },
    };
    for (cases) |c| {
        const got = try registry.fileUri(testing.allocator, c[0]);
        defer testing.allocator.free(got);
        testing.expectEqualStrings(c[1], got) catch |e| {
            std.debug.print("path: {s}\n", .{c[0]});
            return e;
        };
    }
}

test "normalizePath: table" {
    const cases = [_]struct { style: registry.PathStyle, in: []const u8, out: []const u8 }{
        .{ .style = .posix, .in = "/a/b/../c/./d//", .out = "/a/c/d" },
        .{ .style = .posix, .in = "/../..", .out = "/" },
        .{ .style = .posix, .in = "/a\\b", .out = "/a\\b" },
        .{ .style = .windows, .in = "c:/a/b/../c", .out = "C:\\a\\c" },
        .{ .style = .windows, .in = "C:\\..\\..", .out = "C:\\" },
        .{ .style = .windows, .in = "\\\\srv\\share\\x\\..", .out = "\\\\srv\\share" },
        .{ .style = .windows, .in = "//srv/share/a//b", .out = "\\\\srv\\share\\a\\b" },
    };
    for (cases) |c| {
        const got = try registry.normalizePath(testing.allocator, c.in, c.style);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.out, got);
    }
}
