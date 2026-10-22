//! check-supply-chain: fails the build when anything introduces third-party
//! code (E16.F01.S02.T01). zigguro's strongest supply-chain property is that
//! there is no third-party code to compromise; this tool enforces it.
//!
//!   zig build check-supply-chain     # exit 0 clean, 1 findings, 2 usage error
//!
//! Checks, all done by tokenizing with `std.zig.Tokenizer` so comments and
//! string contents never cause false positives:
//! - `build.zig.zon`: any `.url` or `.hash` field (only `.path` dependencies
//!   are allowed);
//! - `.zig` files: `@cImport`, `@cInclude`, `@cDefine`, `linkLibC`,
//!   `addCSourceFile(s)`, `addObjectFile`, `addTranslateC`, and
//!   `linkSystemLibrary` with a library outside the allowlist.
//!
//! Directories skipped: `.git`, `.zig-cache`, `zig-out` and `.zg`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Tokenizer = std.zig.Tokenizer;

/// One violation.
pub const Finding = struct {
    file: []const u8,
    line: u32,
    kind: Kind,
    detail: []const u8,

    /// What was found.
    pub const Kind = enum { url_dependency, hash_dependency, cimport, link_libc, system_library, c_source, object_file, translate_c };

    /// `path:line: kind: detail`.
    pub fn format(f: Finding, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}:{d}: {t}: {s}", .{ f.file, f.line, f.kind, f.detail });
    }
};

/// OS import libraries the build may link by name.
pub const default_system_libs = [_][]const u8{ "kernel32", "user32", "gdi32", "advapi32", "userenv", "crypt32", "ntdll", "ole32", "oleaut32", "shell32", "imm32", "dwmapi", "uxtheme", "shcore", "ws2_32" };

/// What the scan accepts.
pub const Allowlist = struct {
    system_libraries: []const []const u8 = &default_system_libs,

    fn allows(a: Allowlist, lib: []const u8) bool {
        for (a.system_libraries) |s| if (std.mem.eql(u8, s, lib)) return true;
        return false;
    }
};

const skip_dirs = [_][]const u8{ ".git", ".zig-cache", "zig-out", ".zg" };

/// Scans every `build.zig.zon` and `.zig` file under `root`. Strings in
/// the findings are allocated with `gpa` (use an arena).
pub fn scan(gpa: Allocator, io: std.Io, root: std.Io.Dir, allow: Allowlist) ![]Finding {
    var out: std.ArrayList(Finding) = .empty;
    var walker = try root.walkSelectively(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                if (!skipped(entry.path)) try walker.enter(io, entry);
            },
            .file => {
                const is_zon = std.mem.eql(u8, entry.basename, "build.zig.zon");
                if (!is_zon and !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
                const src = try entry.dir.readFileAllocOptions(io, entry.basename, gpa, .limited(16 << 20), .of(u8), 0);
                const rel = try normalize(gpa, entry.path);
                if (is_zon) try scanZon(gpa, rel, src, &out) else try scanZig(gpa, rel, src, allow, &out);
            },
            else => {},
        }
    }
    return out.toOwnedSlice(gpa);
}

fn skipped(path: []const u8) bool {
    for (skip_dirs) |s| {
        if (std.mem.indexOfScalar(u8, s, '/') == null) {
            if (std.mem.eql(u8, std.fs.path.basename(path), s)) return true;
        } else if (pathEql(path, s)) return true;
    }
    return false;
}

fn pathEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const xs = if (x == '\\') '/' else x;
        if (xs != y) return false;
    }
    return true;
}

fn normalize(gpa: Allocator, path: []const u8) ![]const u8 {
    const p = try gpa.dupe(u8, path);
    std.mem.replaceScalar(u8, p, '\\', '/');
    return p;
}

fn lineOf(src: []const u8, offset: usize) u32 {
    return @intCast(std.mem.countScalar(u8, src[0..offset], '\n') + 1);
}

/// Flags `.url = ...` and `.hash = ...` fields in a manifest.
pub fn scanZon(gpa: Allocator, file: []const u8, src: [:0]const u8, out: *std.ArrayList(Finding)) !void {
    var t: Tokenizer = .init(src);
    var prev: std.zig.Token.Tag = .invalid;
    while (true) {
        const tok = t.next();
        if (tok.tag == .eof) break;
        defer prev = tok.tag;
        if (tok.tag != .identifier or prev != .period) continue;
        const name = src[tok.loc.start..tok.loc.end];
        const kind: Finding.Kind = if (std.mem.eql(u8, name, "url"))
            .url_dependency
        else if (std.mem.eql(u8, name, "hash"))
            .hash_dependency
        else
            continue;
        var look = t;
        if (look.next().tag != .equal) continue;
        const val = look.next();
        const detail = if (val.tag == .string_literal) src[val.loc.start..val.loc.end] else name;
        try out.append(gpa, .{ .file = file, .line = lineOf(src, tok.loc.start), .kind = kind, .detail = try gpa.dupe(u8, detail) });
    }
}

/// Flags C interop and native linking in Zig source.
pub fn scanZig(gpa: Allocator, file: []const u8, src: [:0]const u8, allow: Allowlist, out: *std.ArrayList(Finding)) !void {
    var t: Tokenizer = .init(src);
    while (true) {
        const tok = t.next();
        if (tok.tag == .eof) break;
        const text = src[tok.loc.start..tok.loc.end];
        const line = lineOf(src, tok.loc.start);
        switch (tok.tag) {
            .builtin => {
                if (eqlAny(text, &.{ "@cImport", "@cInclude", "@cDefine", "@cUndef" }))
                    try out.append(gpa, .{ .file = file, .line = line, .kind = .cimport, .detail = text });
            },
            .identifier => {
                const kind: ?Finding.Kind = if (std.mem.eql(u8, text, "linkLibC"))
                    .link_libc
                else if (eqlAny(text, &.{ "addCSourceFile", "addCSourceFiles", "addCSourceFileStep" }))
                    .c_source
                else if (std.mem.eql(u8, text, "addObjectFile"))
                    .object_file
                else if (std.mem.eql(u8, text, "addTranslateC"))
                    .translate_c
                else
                    null;
                if (kind) |k| {
                    try out.append(gpa, .{ .file = file, .line = line, .kind = k, .detail = text });
                } else if (std.mem.eql(u8, text, "linkSystemLibrary") or std.mem.eql(u8, text, "linkSystemLibrary2")) {
                    // linkSystemLibrary("name", ...): check the literal.
                    var look = t;
                    if (look.next().tag != .l_paren) continue;
                    const arg = look.next();
                    if (arg.tag == .string_literal) {
                        const lit = src[arg.loc.start + 1 .. arg.loc.end - 1];
                        if (allow.allows(lit)) continue;
                        try out.append(gpa, .{ .file = file, .line = line, .kind = .system_library, .detail = try gpa.dupe(u8, lit) });
                    } else {
                        try out.append(gpa, .{ .file = file, .line = line, .kind = .system_library, .detail = "non-literal library name" });
                    }
                }
            },
            else => {},
        }
    }
}

fn eqlAny(s: []const u8, set: []const []const u8) bool {
    for (set) |x| if (std.mem.eql(u8, s, x)) return true;
    return false;
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    var root_path: []const u8 = ".";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--root") and i + 1 < args.len) {
            i += 1;
            root_path = args[i];
        } else {
            std.debug.print("usage: check-supply-chain [--root DIR]\n", .{});
            return 2;
        }
    }
    var root = std.Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch |err| {
        std.debug.print("check-supply-chain: cannot open {s}: {t}\n", .{ root_path, err });
        return 2;
    };
    defer root.close(io);
    const findings = try scan(gpa, io, root, .{});
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stderr().writer(io, &buf);
    const w = &fw.interface;
    for (findings) |f| try w.print("{f}\n", .{f});
    if (findings.len == 0) try w.writeAll("check-supply-chain: zero third-party code\n");
    try w.flush();
    return if (findings.len == 0) 0 else 1;
}

fn scanSrc(comptime src: [:0]const u8, zon: bool) ![]Finding {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(Finding) = .empty;
    errdefer out.deinit(gpa);
    if (zon) try scanZon(gpa, "f", src, &out) else try scanZig(gpa, "f", src, .{}, &out);
    return out.toOwnedSlice(gpa);
}

fn freeFindings(fs: []Finding) void {
    const gpa = std.testing.allocator;
    for (fs) |f| switch (f.kind) {
        .url_dependency, .hash_dependency => gpa.free(f.detail),
        .system_library => if (!std.mem.eql(u8, f.detail, "non-literal library name")) gpa.free(f.detail),
        else => {},
    };
    gpa.free(fs);
}

test "supply_chain: ok fixture clean" {
    const fs = try scanSrc(
        \\.{ .name = .zg_x, .version = "0.0.0", .dependencies = .{ .zg_core = .{ .path = "../core" } }, .paths = .{""} }
    , true);
    defer freeFindings(fs);
    try std.testing.expectEqual(0, fs.len);
}

test "supply_chain: url dependency flagged" {
    const fs = try scanSrc(
        \\.{
        \\    .name = .x,
        \\    .dependencies = .{
        \\        .evil = .{ .url = "https://example.com/evil.tar.gz", .hash = "1220abcd" },
        \\    },
        \\}
    , true);
    defer freeFindings(fs);
    try std.testing.expectEqual(2, fs.len);
    try std.testing.expectEqual(Finding.Kind.url_dependency, fs[0].kind);
    try std.testing.expectEqual(4, fs[0].line);
    try std.testing.expectEqual(Finding.Kind.hash_dependency, fs[1].kind);
}

test "supply_chain: cimport flagged with line" {
    const fs = try scanSrc(
        \\const std = @import("std");
        \\const c = @cImport(@cInclude("stdio.h"));
    , false);
    defer freeFindings(fs);
    try std.testing.expectEqual(2, fs.len);
    try std.testing.expectEqual(Finding.Kind.cimport, fs[0].kind);
    try std.testing.expectEqual(2, fs[0].line);
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("f:2: cimport: @cImport", try std.fmt.bufPrint(&buf, "{f}", .{fs[0]}));
}

test "supply_chain: cimport inside comment ignored" {
    const fs = try scanSrc(
        \\// never use @cImport here; linkLibC is banned
        \\const s = "@cImport linkLibC addCSourceFile";
    , false);
    defer freeFindings(fs);
    try std.testing.expectEqual(0, fs.len);
}

test "supply_chain: linkSystemLibrary advapi32 allowed, libssl flagged" {
    const fs = try scanSrc(
        \\pub fn build(m: anytype) void {
        \\    m.linkSystemLibrary("advapi32", .{});
        \\    m.linkSystemLibrary("ssl", .{});
        \\}
    , false);
    defer freeFindings(fs);
    try std.testing.expectEqual(1, fs.len);
    try std.testing.expectEqual(Finding.Kind.system_library, fs[0].kind);
    try std.testing.expectEqualStrings("ssl", fs[0].detail);
}

test "supply_chain: linkLibC flagged" {
    const fs = try scanSrc(
        \\pub fn build(m: anytype) void {
        \\    m.linkLibC();
        \\    m.addCSourceFile(.{});
        \\    m.addObjectFile(.{});
        \\}
    , false);
    defer freeFindings(fs);
    try std.testing.expectEqual(3, fs.len);
    try std.testing.expectEqual(Finding.Kind.link_libc, fs[0].kind);
    try std.testing.expectEqual(Finding.Kind.c_source, fs[1].kind);
    try std.testing.expectEqual(Finding.Kind.object_file, fs[2].kind);
}

test "supply_chain: directory scan finds fixture violations and skips caches" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "pkg/src");
    try tmp.dir.createDirPath(io, ".zig-cache/o");
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/build.zig.zon", .data = ".{ .dependencies = .{ .x = .{ .url = \"https://e\" } } }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pkg/src/a.zig", .data = "const c = @cImport({});\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".zig-cache/o/b.zig", .data = "const c = @cImport({});\n" });
    const fs = try scan(arena.allocator(), io, tmp.dir, .{});
    try std.testing.expectEqual(2, fs.len);
}
