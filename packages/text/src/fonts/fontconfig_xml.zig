//! The part of fontconfig's configuration format (fonts-conf(5)) font
//! discovery needs: `<dir>`, `<include>` and `<alias>`, in document
//! order. Everything else (`<match>`, `<selectfont>`, `<cachedir>`, ...)
//! is ignored, with one exception: the common distro pattern
//!
//!     <match target="pattern">
//!       <test name="family"><string>monospace</string></test>
//!       <edit name="family" mode="prepend"><string>X</string></edit>
//!     </match>
//!
//! is read as an alias of the tested family (`prepend`/`prepend_first`
//! → prefer, `append` → accept, `append_last` → default). Matches with
//! any other test, target or edit are ignored; fontconfig's general
//! rule engine is out of scope.

const std = @import("std");
const Allocator = std.mem.Allocator;
const xml = @import("xml.zig");

pub const Prefix = enum { none, xdg, default, cwd, relative };

pub const Dir = struct { path: []const u8, prefix: Prefix };
pub const Include = struct { path: []const u8, prefix: Prefix, ignore_missing: bool };
pub const Alias = @import("discovery.zig").Alias;

pub const Item = union(enum) { dir: Dir, include: Include, alias: Alias };

pub const Error = xml.Error || Allocator.Error;

/// The items of one configuration file, allocated in `arena`.
pub fn parse(arena: Allocator, src: []const u8) Error![]const Item {
    var p: Parser = .{ .arena = arena, .tok = .init(src) };
    return p.document();
}

const Parser = struct {
    arena: Allocator,
    tok: xml.Tokenizer,
    items: std.ArrayList(Item) = .empty,

    fn document(p: *Parser) Error![]const Item {
        // Skip to <fontconfig>.
        while (try p.tok.next()) |t| switch (t) {
            .start => |s| if (std.mem.eql(u8, s.name, "fontconfig")) {
                try p.body();
                return p.items.items;
            } else try p.skip(s.name),
            .empty => |e| if (std.mem.eql(u8, e.name, "fontconfig")) return p.items.items,
            .end => return error.Malformed,
            .text => {},
        };
        return p.items.items;
    }

    fn body(p: *Parser) Error!void {
        while (try p.tok.next()) |t| switch (t) {
            .start => |s| {
                if (std.mem.eql(u8, s.name, "dir")) {
                    const path = try p.textOf(s.name);
                    if (path.len > 0) try p.items.append(p.arena, .{ .dir = .{ .path = path, .prefix = prefixOf(s.attrs) } });
                } else if (std.mem.eql(u8, s.name, "include")) {
                    const path = try p.textOf(s.name);
                    const im = s.attrs.get("ignore_missing");
                    if (path.len > 0) try p.items.append(p.arena, .{ .include = .{
                        .path = path,
                        .prefix = prefixOf(s.attrs),
                        .ignore_missing = im != null and std.mem.eql(u8, im.?, "yes"),
                    } });
                } else if (std.mem.eql(u8, s.name, "alias")) {
                    try p.alias();
                } else if (std.mem.eql(u8, s.name, "match")) {
                    try p.match(s.attrs);
                } else try p.skip(s.name);
            },
            .end => |n| return if (std.mem.eql(u8, n, "fontconfig")) {} else error.Malformed,
            .empty, .text => {},
        };
        return error.Malformed;
    }

    /// Consumes through the end tag of `name`, checking nesting.
    fn skip(p: *Parser, name: []const u8) Error!void {
        var stack: std.ArrayList([]const u8) = .empty;
        try stack.append(p.arena, name);
        while (try p.tok.next()) |t| switch (t) {
            .start => |s| try stack.append(p.arena, s.name),
            .end => |n| {
                if (!std.mem.eql(u8, stack.pop().?, n)) return error.Malformed;
                if (stack.items.len == 0) return;
            },
            .empty, .text => {},
        };
        return error.Malformed;
    }

    /// The trimmed, unescaped text content of element `name` (child
    /// elements are skipped).
    fn textOf(p: *Parser, name: []const u8) Error![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        while (try p.tok.next()) |t| switch (t) {
            .text => |raw| try buf.appendSlice(p.arena, try xml.unescape(p.arena, raw)),
            .start => |s| try p.skip(s.name),
            .empty => {},
            .end => |n| {
                if (!std.mem.eql(u8, n, name)) return error.Malformed;
                return std.mem.trim(u8, buf.items, " \t\r\n");
            },
        };
        return error.Malformed;
    }

    /// The `<family>` texts directly inside the current element `name`.
    fn families(p: *Parser, name: []const u8) Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        while (try p.tok.next()) |t| switch (t) {
            .start => |s| if (std.mem.eql(u8, s.name, "family")) {
                const f = try p.textOf("family");
                if (f.len > 0) try out.append(p.arena, f);
            } else try p.skip(s.name),
            .end => |n| return if (std.mem.eql(u8, n, name)) out.items else error.Malformed,
            .empty, .text => {},
        };
        return error.Malformed;
    }

    fn alias(p: *Parser) Error!void {
        var targets: std.ArrayList([]const u8) = .empty;
        var a: Alias = .{ .family = "" };
        while (try p.tok.next()) |t| switch (t) {
            .start => |s| {
                if (std.mem.eql(u8, s.name, "family")) {
                    const f = try p.textOf("family");
                    if (f.len > 0) try targets.append(p.arena, f);
                } else if (std.mem.eql(u8, s.name, "prefer")) {
                    a.prefer = try concat(p.arena, a.prefer, try p.families("prefer"));
                } else if (std.mem.eql(u8, s.name, "accept")) {
                    a.accept = try concat(p.arena, a.accept, try p.families("accept"));
                } else if (std.mem.eql(u8, s.name, "default")) {
                    a.default = try concat(p.arena, a.default, try p.families("default"));
                } else try p.skip(s.name);
            },
            .end => |n| {
                if (!std.mem.eql(u8, n, "alias")) return error.Malformed;
                for (targets.items) |f| {
                    var one = a;
                    one.family = f;
                    try p.items.append(p.arena, .{ .alias = one });
                }
                return;
            },
            .empty, .text => {},
        };
        return error.Malformed;
    }

    /// The match-edit-family pattern described in the module comment.
    fn match(p: *Parser, attrs: xml.AttrIter) Error!void {
        var ok = if (attrs.get("target")) |tg| std.mem.eql(u8, tg, "pattern") else true;
        var tested: ?[]const u8 = null;
        var tests: usize = 0;
        var a: Alias = .{ .family = "" };
        var edits: usize = 0;
        while (try p.tok.next()) |t| switch (t) {
            .start => |s| {
                if (std.mem.eql(u8, s.name, "test")) {
                    tests += 1;
                    const name_ok = if (s.attrs.get("name")) |n| std.mem.eql(u8, n, "family") else false;
                    const cmp_ok = if (s.attrs.get("compare")) |c| std.mem.eql(u8, c, "eq") else true;
                    const strs = try p.strings("test");
                    if (!name_ok or !cmp_ok or strs.len != 1) ok = false else tested = strs[0];
                } else if (std.mem.eql(u8, s.name, "edit")) {
                    edits += 1;
                    const name_ok = if (s.attrs.get("name")) |n| std.mem.eql(u8, n, "family") else false;
                    const mode = s.attrs.get("mode") orelse "assign";
                    const strs = try p.strings("edit");
                    if (!name_ok) {
                        ok = false;
                    } else if (std.mem.eql(u8, mode, "prepend") or std.mem.eql(u8, mode, "prepend_first")) {
                        a.prefer = try concat(p.arena, a.prefer, strs);
                    } else if (std.mem.eql(u8, mode, "append")) {
                        a.accept = try concat(p.arena, a.accept, strs);
                    } else if (std.mem.eql(u8, mode, "append_last")) {
                        a.default = try concat(p.arena, a.default, strs);
                    } else ok = false;
                } else {
                    ok = false;
                    try p.skip(s.name);
                }
            },
            .end => |n| {
                if (!std.mem.eql(u8, n, "match")) return error.Malformed;
                if (ok and tests == 1 and edits > 0) if (tested) |f| {
                    a.family = f;
                    try p.items.append(p.arena, .{ .alias = a });
                };
                return;
            },
            .empty => ok = false,
            .text => {},
        };
        return error.Malformed;
    }

    /// The `<string>` texts inside element `name`; any other child makes
    /// the result empty.
    fn strings(p: *Parser, name: []const u8) Error![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var other = false;
        while (try p.tok.next()) |t| switch (t) {
            .start => |s| if (std.mem.eql(u8, s.name, "string")) {
                try out.append(p.arena, try p.textOf("string"));
            } else {
                other = true;
                try p.skip(s.name);
            },
            .empty => other = true,
            .end => |n| {
                if (!std.mem.eql(u8, n, name)) return error.Malformed;
                return if (other) &.{} else out.items;
            },
            .text => {},
        };
        return error.Malformed;
    }
};

fn concat(arena: Allocator, a: []const []const u8, b: []const []const u8) Allocator.Error![]const []const u8 {
    if (a.len == 0) return b;
    return std.mem.concat(arena, []const u8, &.{ a, b });
}

fn prefixOf(attrs: xml.AttrIter) Prefix {
    const v = attrs.get("prefix") orelse return .none;
    return std.meta.stringToEnum(Prefix, v) orelse .none;
}
