//! Language detection helpers: modelines, shebang interpreters and content
//! sniffing. `Registry.detect` combines them with file names and extensions.

const std = @import("std");

/// How many lines at each end of the head are searched for a modeline.
pub const modeline_lines = 5;

/// The language named by a Vim (`vim: set ft=yaml:`, `vi: filetype=c`) or
/// Emacs (`-*- mode: python -*-`, `-*- python -*-`) modeline in the first
/// or last `modeline_lines` lines of `head`.
pub fn modeline(head: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, head, '\n');
    var i: usize = 0;
    while (it.next()) |line| : (i += 1) {
        if (i >= modeline_lines) break;
        if (modelineIn(line)) |n| return n;
    }
    // The last lines (when the head is the whole file).
    var end = std.mem.trimEnd(u8, head, "\r\n").len;
    var k: usize = 0;
    while (k < modeline_lines and end > 0) : (k += 1) {
        const start = if (std.mem.lastIndexOfScalar(u8, head[0..end], '\n')) |p| p + 1 else 0;
        if (modelineIn(head[start..end])) |n| return n;
        if (start == 0) break;
        end = start - 1;
    }
    return null;
}

fn modelineIn(line_in: []const u8) ?[]const u8 {
    const line = std.mem.trimEnd(u8, line_in, "\r");
    if (std.mem.indexOf(u8, line, "-*-")) |a| {
        const rest = line[a + 3 ..];
        const b = std.mem.indexOf(u8, rest, "-*-") orelse rest.len;
        const body = std.mem.trim(u8, rest[0..b], " \t");
        if (std.mem.indexOf(u8, body, ":") == null) return nonEmpty(body);
        var fields = std.mem.splitScalar(u8, body, ';');
        while (fields.next()) |f| {
            const colon = std.mem.indexOfScalar(u8, f, ':') orelse continue;
            const key = std.mem.trim(u8, f[0..colon], " \t");
            if (std.ascii.eqlIgnoreCase(key, "mode")) return nonEmpty(std.mem.trim(u8, f[colon + 1 ..], " \t"));
        }
        return null;
    }
    inline for (.{ "vim:", "vi:", "ex:" }) |tag| {
        if (std.mem.indexOf(u8, line, tag)) |a| {
            // The tag must start the line or follow whitespace.
            if (a == 0 or line[a - 1] == ' ' or line[a - 1] == '\t') {
                var opts = line[a + tag.len ..];
                opts = std.mem.trimStart(u8, opts, " \t");
                if (std.mem.startsWith(u8, opts, "set ")) opts = opts[4..];
                var words = std.mem.tokenizeAny(u8, opts, " \t:");
                while (words.next()) |w| {
                    inline for (.{ "ft=", "filetype=", "syntax=", "syn=" }) |key| {
                        if (std.mem.startsWith(u8, w, key)) return nonEmpty(w[key.len..]);
                    }
                }
            }
        }
    }
    return null;
}

fn nonEmpty(s: []const u8) ?[]const u8 {
    return if (s.len == 0) null else s;
}

/// The interpreter named by a `#!` first line: the program's base name, or
/// for `env` the first argument that is not an option or assignment.
pub fn shebang(head: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, head, "#!")) return null;
    const nl = std.mem.indexOfScalar(u8, head, '\n') orelse head.len;
    const line = std.mem.trimEnd(u8, head[2..nl], "\r");
    var words = std.mem.tokenizeAny(u8, line, " \t");
    const prog = words.next() orelse return null;
    const base = std.fs.path.basenamePosix(prog);
    if (!std.mem.eql(u8, base, "env")) return base;
    while (words.next()) |w| {
        if (w[0] == '-') continue;
        if (std.mem.indexOfScalar(u8, w, '=') != null) continue;
        return std.fs.path.basenamePosix(w);
    }
    return null;
}

/// `name` without a trailing version (`python3.12` -> `python`), or null
/// when there is none to strip.
pub fn stripVersion(name: []const u8) ?[]const u8 {
    const t = std.mem.trimEnd(u8, name, "0123456789.");
    return if (t.len == name.len or t.len == 0) null else t;
}

/// What the content looks like, for files without a name match.
pub const Sniff = enum { json, html, xml };

/// Sniffs the head: `{`/`[` starting a plausible JSON value, `<!DOCTYPE
/// html`/`<html`, or `<?xml`.
pub fn sniff(head: []const u8) ?Sniff {
    const t = std.mem.trimStart(u8, head, " \t\r\n\xEF\xBB\xBF");
    if (t.len == 0) return null;
    if (startsWithIgnoreCase(t, "<!doctype html") or startsWithIgnoreCase(t, "<html")) return .html;
    if (std.mem.startsWith(u8, t, "<?xml")) return .xml;
    if (t[0] == '{' or t[0] == '[') {
        // The next significant byte must be able to continue a JSON value.
        const u = std.mem.trimStart(u8, t[1..], " \t\r\n");
        if (u.len == 0) return .json;
        return switch (u[0]) {
            '"', '{', '[', ']', '}', '-', '0'...'9', 't', 'f', 'n' => .json,
            else => null,
        };
    }
    return null;
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

test "detect: modelines, shebangs and sniffing" {
    const t = std.testing;
    try t.expectEqualStrings("yaml", modeline("# vim: set ft=yaml:\nkey: 1\n").?);
    try t.expectEqualStrings("c", modeline("/* vi: filetype=c */").?);
    try t.expectEqualStrings("python", modeline("# -*- mode: python; coding: utf-8 -*-\n").?);
    try t.expectEqualStrings("ruby", modeline("# -*- ruby -*-\n").?);
    try t.expectEqualStrings("sh", modeline("a\nb\nc\nd\ne\nf\ng\n# vim: ft=sh\n").?);
    try t.expect(modeline("let vim: x = 1") == null);
    try t.expect(modeline("a\nb\nc\nd\ne\n# vim: ft=sh\nf\ng\nh\ni\nj\nk\n") == null);

    try t.expectEqualStrings("python3", shebang("#!/usr/bin/env python3\nprint(1)\n").?);
    try t.expectEqualStrings("deno", shebang("#!/usr/bin/env -S deno run --allow-net\n").?);
    try t.expectEqualStrings("bash", shebang("#! /bin/bash\r\n").?);
    try t.expectEqualStrings("node", shebang("#!/usr/bin/env NODE_ENV=prod node\n").?);
    try t.expect(shebang("# not a shebang") == null);
    try t.expectEqualStrings("python", stripVersion("python3.12").?);
    try t.expect(stripVersion("bash") == null);

    try t.expectEqual(Sniff.json, sniff("  {\n  \"a\": 1}").?);
    try t.expectEqual(Sniff.json, sniff("[1, 2]").?);
    try t.expect(sniff("{% block %}") == null);
    try t.expectEqual(Sniff.html, sniff("<!DOCTYPE html><html>").?);
    try t.expectEqual(Sniff.xml, sniff("<?xml version=\"1.0\"?>").?);
}
