//! Capability lists.
//!
//! - Protocol v0/v1: the first ref advertisement line is
//!   `<oid> SP <refname> NUL <cap> SP <cap> ...` (or, for an empty repo,
//!   `<zero-oid> SP capabilities^{} NUL ...`). Capabilities are `name` or
//!   `name=value`, and some (`symref`) repeat.
//! - Protocol v2: one capability per line, `key[=value]`, after
//!   `version 2`; values such as `fetch=shallow wait-for-done` hold a
//!   space-separated feature list.
//!
//! `Caps` keeps slices of the input and parses on lookup, so the input
//! must outlive it. Nothing is allocated.

const std = @import("std");
const pktline = @import("pktline.zig");

pub const Caps = struct {
    src: union(enum) {
        /// The space-separated list after the NUL.
        v0: []const u8,
        v2: []const []const u8,
    },

    /// Parses the first ref line of a v0 advertisement (with or without
    /// its LF). A line without a NUL has no capabilities.
    pub fn parseV0(first_ref_line: []const u8) Caps {
        const line = pktline.trimLf(first_ref_line);
        const nul = std.mem.indexOfScalar(u8, line, 0) orelse return .{ .src = .{ .v0 = "" } };
        return .{ .src = .{ .v0 = line[nul + 1 ..] } };
    }

    /// The part of a v0 first line before the NUL (`<oid> SP <refname>`).
    pub fn refPartV0(first_ref_line: []const u8) []const u8 {
        const line = pktline.trimLf(first_ref_line);
        const nul = std.mem.indexOfScalar(u8, line, 0) orelse return line;
        return line[0..nul];
    }

    /// The capability lines of a v2 advertisement (a leading
    /// `version 2` line is skipped). Lines may keep their LF.
    pub fn parseV2(lines: []const []const u8) Caps {
        var l = lines;
        if (l.len > 0 and std.mem.eql(u8, pktline.trimLf(l[0]), "version 2")) l = l[1..];
        return .{ .src = .{ .v2 = l } };
    }

    pub const Entry = struct {
        name: []const u8,
        value: ?[]const u8,
    };

    pub const Iterator = struct {
        caps: *const Caps,
        i: usize = 0,
        words: std.mem.TokenIterator(u8, .scalar) = undefined,

        pub fn next(it: *Iterator) ?Entry {
            const raw = switch (it.caps.src) {
                .v0 => blk: {
                    if (it.i == 0) {
                        it.words = std.mem.tokenizeScalar(u8, it.caps.src.v0, ' ');
                        it.i = 1;
                    }
                    break :blk it.words.next() orelse return null;
                },
                .v2 => |lines| blk: {
                    while (it.i < lines.len) {
                        const line = pktline.trimLf(lines[it.i]);
                        it.i += 1;
                        if (line.len > 0) break :blk line;
                    }
                    return null;
                },
            };
            const eq = std.mem.indexOfScalar(u8, raw, '=') orelse return .{ .name = raw, .value = null };
            return .{ .name = raw[0..eq], .value = raw[eq + 1 ..] };
        }
    };

    pub fn iterator(c: *const Caps) Iterator {
        return .{ .caps = c };
    }

    pub fn has(c: *const Caps, name: []const u8) bool {
        var it = c.iterator();
        while (it.next()) |e| if (std.mem.eql(u8, e.name, name)) return true;
        return false;
    }

    /// The value of the first `name=value` (`""` for `name=`); null when
    /// absent or valueless.
    pub fn value(c: *const Caps, name: []const u8) ?[]const u8 {
        var it = c.iterator();
        while (it.next()) |e| if (std.mem.eql(u8, e.name, name)) return e.value;
        return null;
    }

    /// Whether `name`'s value lists `feature` (v2 `fetch=shallow
    /// wait-for-done`).
    pub fn hasFeature(c: *const Caps, name: []const u8, feature: []const u8) bool {
        const v = c.value(name) orelse return false;
        var it = std.mem.tokenizeScalar(u8, v, ' ');
        while (it.next()) |f| if (std.mem.eql(u8, f, feature)) return true;
        return false;
    }

    /// Calls `f` for every value of a repeated capability (v0 `symref`).
    pub fn eachValue(c: *const Caps, name: []const u8, ctx: anytype, comptime f: fn (@TypeOf(ctx), []const u8) void) void {
        var it = c.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.name, name)) if (e.value) |v| f(ctx, v);
        }
    }
};
