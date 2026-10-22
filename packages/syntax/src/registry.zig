//! The language registry: lookup by id and name, and detection.

const std = @import("std");
const language = @import("language.zig");
const detect_mod = @import("detect.zig");

const Allocator = std.mem.Allocator;
const Language = language.Language;
const LanguageId = language.LanguageId;

/// Registered languages. Definitions are borrowed and must outlive it.
pub const Registry = struct {
    langs: std.ArrayList(*const Language) = .empty,

    /// A registry holding only `language.plain`.
    pub fn init(gpa: Allocator) Allocator.Error!Registry {
        var r: Registry = .{};
        try r.register(gpa, &language.plain);
        return r;
    }

    /// Frees the registry.
    pub fn deinit(r: *Registry, gpa: Allocator) void {
        r.langs.deinit(gpa);
    }

    /// Adds `l`, replacing a language with the same id.
    pub fn register(r: *Registry, gpa: Allocator, l: *const Language) Allocator.Error!void {
        for (r.langs.items) |*x| if (x.*.id == l.id) {
            x.* = l;
            return;
        };
        try r.langs.append(gpa, l);
    }

    /// The language with id `id`.
    pub fn get(r: *const Registry, id: LanguageId) ?*const Language {
        for (r.langs.items) |l| if (l.id == id) return l;
        return null;
    }

    /// The language with id `id`, or plain text.
    pub fn getOrPlain(r: *const Registry, id: LanguageId) *const Language {
        return r.get(id) orelse &language.plain;
    }

    /// The language called `name` (case-insensitive name or alias).
    pub fn byName(r: *const Registry, name: []const u8) ?LanguageId {
        for (r.langs.items) |l| {
            if (std.ascii.eqlIgnoreCase(l.name, name)) return l.id;
            for (l.aliases) |a| if (std.ascii.eqlIgnoreCase(a, name)) return l.id;
        }
        return null;
    }

    /// Detects the language of a file from its path (may be null for
    /// unsaved buffers) and the first bytes of its content. In order: a
    /// modeline, the exact file name, the longest matching extension, a
    /// shebang interpreter, then content sniffing. User associations (E15)
    /// are applied by the caller before this.
    pub fn detect(r: *const Registry, path: ?[]const u8, head: []const u8) ?LanguageId {
        if (detect_mod.modeline(head)) |n| if (r.byName(n)) |id| return id;
        if (path) |p| {
            const base = basename(p);
            for (r.langs.items) |l| for (l.filenames) |f| if (std.mem.eql(u8, f, base)) return l.id;
            // Longest extension, exact case first.
            inline for (.{ true, false }) |exact| {
                var best: ?LanguageId = null;
                var best_len: usize = 0;
                for (r.langs.items) |l| for (l.extensions) |e| {
                    if (e.len > best_len and e.len < base.len and endsWithExt(base, e, exact)) {
                        best = l.id;
                        best_len = e.len;
                    }
                };
                if (best) |id| return id;
            }
        }
        if (detect_mod.shebang(head)) |prog| {
            if (r.byShebang(prog)) |id| return id;
            if (detect_mod.stripVersion(prog)) |p| if (r.byShebang(p)) |id| return id;
        }
        if (detect_mod.sniff(head)) |s| switch (s) {
            .json => return r.byName("json"),
            .html, .xml => return r.byName("html"),
        };
        return null;
    }

    fn byShebang(r: *const Registry, prog: []const u8) ?LanguageId {
        for (r.langs.items) |l| for (l.shebangs) |s| if (std.mem.eql(u8, s, prog)) return l.id;
        return null;
    }
};

fn basename(p: []const u8) []const u8 {
    const i = std.mem.lastIndexOfAny(u8, p, "/\\") orelse return p;
    return p[i + 1 ..];
}

/// An exact-case match, or (when `exact` is false) an all-lower-case
/// extension matching an upper-case file name (`README.MD`).
fn endsWithExt(base: []const u8, ext: []const u8, exact: bool) bool {
    const tail = base[base.len - ext.len ..];
    if (exact) return std.mem.eql(u8, tail, ext);
    for (ext) |c| if (std.ascii.isUpper(c)) return false;
    return std.ascii.eqlIgnoreCase(tail, ext);
}

fn nopLex(_: *@import("lex/state.zig").LexState, s: *@import("lex/scanner.zig").Scanner, _: *@import("lex/scanner.zig").TokenSink) void {
    s.skipToEnd();
}

test "detect: table of paths and heads" {
    const gpa = std.testing.allocator;
    const lex: language.Lexer = .{ .lexLineFn = nopLex };
    const defs = [_]Language{
        .{ .id = .zig, .name = "zig", .extensions = &.{ ".zig", ".zon" }, .lexer = lex },
        .{ .id = .c, .name = "c", .extensions = &.{ ".c", ".h" }, .lexer = lex },
        .{ .id = .cpp, .name = "cpp", .aliases = &.{"c++"}, .extensions = &.{ ".cpp", ".cc", ".hpp", ".C" }, .lexer = lex },
        .{ .id = .python, .name = "python", .aliases = &.{"py"}, .extensions = &.{ ".py", ".pyi" }, .shebangs = &.{"python"}, .lexer = lex },
        .{ .id = .typescript, .name = "typescript", .aliases = &.{"ts"}, .extensions = &.{ ".ts", ".d.ts", ".mts" }, .shebangs = &.{"deno"}, .lexer = lex },
        .{ .id = .javascript, .name = "javascript", .aliases = &.{"js"}, .extensions = &.{ ".js", ".mjs" }, .shebangs = &.{"node"}, .lexer = lex },
        .{ .id = .json, .name = "json", .extensions = &.{".json"}, .lexer = lex },
        .{ .id = .yaml, .name = "yaml", .aliases = &.{"yml"}, .extensions = &.{ ".yaml", ".yml" }, .lexer = lex },
        .{ .id = .markdown, .name = "markdown", .aliases = &.{"md"}, .extensions = &.{ ".md", ".markdown" }, .lexer = lex },
        .{ .id = .html, .name = "html", .extensions = &.{ ".html", ".htm" }, .lexer = lex },
        .{ .id = .shell, .name = "shell", .aliases = &.{ "sh", "bash" }, .extensions = &.{ ".sh", ".bash" }, .filenames = &.{ ".bashrc", ".profile" }, .shebangs = &.{ "sh", "bash", "zsh", "dash" }, .lexer = lex },
        .{ .id = .dockerfile, .name = "dockerfile", .filenames = &.{ "Dockerfile", "Containerfile" }, .extensions = &.{".dockerfile"}, .lexer = lex },
        .{ .id = .make, .name = "make", .aliases = &.{"makefile"}, .filenames = &.{ "Makefile", "GNUmakefile", "makefile" }, .extensions = &.{".mk"}, .lexer = lex },
        .{ .id = .toml, .name = "toml", .extensions = &.{".toml"}, .filenames = &.{ "Cargo.lock", "uv.lock" }, .lexer = lex },
        .{ .id = .rust, .name = "rust", .aliases = &.{"rs"}, .extensions = &.{".rs"}, .lexer = lex },
        .{ .id = .go, .name = "go", .extensions = &.{".go"}, .filenames = &.{"go.mod"}, .lexer = lex },
    };
    var r: Registry = try .init(gpa);
    defer r.deinit(gpa);
    for (&defs) |*d| try r.register(gpa, d);

    const Case = struct { ?[]const u8, []const u8, ?LanguageId };
    const cases = [_]Case{
        .{ "src/main.zig", "", .zig },
        .{ "build.zig.zon", "", .zig },
        .{ "C:\\repo\\lib.c", "", .c },
        .{ "include/x.h", "", .c },
        .{ "a/b.cpp", "", .cpp },
        .{ "Legacy.C", "", .cpp },
        .{ "tool.py", "", .python },
        .{ "types.d.ts", "", .typescript },
        .{ "index.mjs", "", .javascript },
        .{ "package.json", "", .json },
        .{ "ci.yml", "", .yaml },
        .{ "README.md", "", .markdown },
        .{ "NOTES.MD", "", .markdown },
        .{ "index.html", "", .html },
        .{ "run.sh", "", .shell },
        .{ "/home/u/.bashrc", "", .shell },
        .{ "Dockerfile", "FROM alpine\n", .dockerfile },
        .{ "docker/Containerfile", "", .dockerfile },
        .{ "Makefile", "all:\n", .make },
        .{ "rules.mk", "", .make },
        .{ "Cargo.lock", "", .toml },
        .{ "pyproject.toml", "", .toml },
        .{ "lib.rs", "", .rust },
        .{ "go.mod", "module x\n", .go },
        .{ "script", "#!/usr/bin/env python3\n", .python },
        .{ "script", "#!/usr/bin/python3.12\n", .python },
        .{ "deploy", "#!/bin/bash\nset -e\n", .shell },
        .{ "tool", "#!/usr/bin/env -S deno run\n", .typescript },
        .{ "srv", "#!/usr/bin/env node\n", .javascript },
        .{ null, "# vim: set ft=yaml:\nkey: 1\n", .yaml },
        .{ "conf.txt", "# vim: set ft=yaml:\n", .yaml },
        .{ "x.c", "// -*- mode: c++ -*-\n", .cpp },
        .{ "x", "# -*- python -*-\n", .python },
        .{ null, "{\"a\": 1}", .json },
        .{ null, "  [1, 2, 3]", .json },
        .{ null, "<!DOCTYPE html>\n<html>", .html },
        .{ null, "hello world", null },
        .{ "unknown.xyz", "", null },
        .{ ".zig", "", null },
        .{ "notes.txt", "", .plain },
    };
    for (cases) |c| {
        const got = r.detect(c[0], c[1]);
        if (got != c[2]) {
            std.debug.print("detect({?s}, {s}): got {?t}, want {?t}\n", .{ c[0], c[1], got, c[2] });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(LanguageId.shell, r.byName("Bash").?);
    try std.testing.expectEqual(&language.plain, r.getOrPlain(@enumFromInt(999)));
}
