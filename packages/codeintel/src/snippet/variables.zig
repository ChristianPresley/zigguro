//! Snippet variables (E07.F03.S01.T01): `Context.resolver` answers the
//! VS Code variables from what the caller knows about the editor (the
//! selection, line, word, file, workspace, clipboard, comment tokens)
//! and from `std.Io` for time and randomness (no globals). Callers wrap
//! it to add their own variables.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Snippet = @import("Snippet.zig");

pub const Context = struct {
    /// Time and randomness; null: the fixed values below.
    io: ?Io = null,
    selected_text: []const u8 = "",
    current_line: []const u8 = "",
    current_word: []const u8 = "",
    /// Zero-based line of the caret.
    line_index: u32 = 0,
    /// Absolute path of the file, if it has one.
    file_path: ?[]const u8 = null,
    workspace_folder: ?[]const u8 = null,
    clipboard: ?[]const u8 = null,
    /// Which caret this expansion is for (multi-cursor), from 0.
    cursor_index: u32 = 0,
    line_comment: ?[]const u8 = null,
    block_comment: ?[2][]const u8 = null,
    /// Wall clock in ms since the Unix epoch (overrides `io`; tests).
    now_ms: ?i64 = null,
    /// Minutes east of UTC and the zone's name (from the platform).
    tz_offset_min: i32 = 0,
    tz_name: []const u8 = "UTC",
    /// Random bytes (overrides `io`; tests).
    random_bytes: ?[]const u8 = null,

    pub fn resolver(c: *const Context) Snippet.VariableResolver {
        return .{ .ctx = @constCast(c), .get = get };
    }

    fn get(ctx: ?*anyopaque, name: []const u8, a: Allocator) ?[]const u8 {
        const c: *const Context = @ptrCast(@alignCast(ctx.?));
        return c.value(name, a) catch null;
    }

    fn eql(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }

    fn nowMs(c: *const Context) i64 {
        if (c.now_ms) |t| return t;
        const io = c.io orelse return 0;
        return @intCast(@divFloor(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
    }

    fn random(c: *const Context, buf: []u8) void {
        if (c.random_bytes) |r| {
            for (buf, 0..) |*b, i| b.* = r[i % r.len];
            return;
        }
        if (c.io) |io| return io.random(buf);
        @memset(buf, 0);
    }

    const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };
    const day_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };

    fn value(c: *const Context, name: []const u8, a: Allocator) !?[]const u8 {
        if (eql(name, "TM_SELECTED_TEXT")) return c.selected_text;
        if (eql(name, "TM_CURRENT_LINE")) return c.current_line;
        if (eql(name, "TM_CURRENT_WORD")) return c.current_word;
        if (eql(name, "TM_LINE_INDEX")) return try std.fmt.allocPrint(a, "{d}", .{c.line_index});
        if (eql(name, "TM_LINE_NUMBER")) return try std.fmt.allocPrint(a, "{d}", .{c.line_index + 1});
        if (eql(name, "CURSOR_INDEX")) return try std.fmt.allocPrint(a, "{d}", .{c.cursor_index});
        if (eql(name, "CURSOR_NUMBER")) return try std.fmt.allocPrint(a, "{d}", .{c.cursor_index + 1});
        if (eql(name, "CLIPBOARD")) return c.clipboard orelse "";
        const path = c.file_path orelse "";
        if (eql(name, "TM_FILENAME")) return std.fs.path.basename(path);
        if (eql(name, "TM_FILENAME_BASE")) {
            const base = std.fs.path.basename(path);
            return base[0 .. std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len];
        }
        if (eql(name, "TM_DIRECTORY")) return std.fs.path.dirname(path) orelse "";
        if (eql(name, "TM_FILEPATH")) return path;
        if (eql(name, "RELATIVE_FILEPATH")) {
            const root = c.workspace_folder orelse return path;
            if (std.mem.startsWith(u8, path, root) and path.len > root.len and std.fs.path.isSep(path[root.len])) return path[root.len + 1 ..];
            return path;
        }
        if (eql(name, "WORKSPACE_FOLDER")) return c.workspace_folder orelse "";
        if (eql(name, "WORKSPACE_NAME")) return std.fs.path.basename(c.workspace_folder orelse "");
        if (eql(name, "LINE_COMMENT")) return c.line_comment orelse "";
        if (eql(name, "BLOCK_COMMENT_START")) return if (c.block_comment) |b| b[0] else "";
        if (eql(name, "BLOCK_COMMENT_END")) return if (c.block_comment) |b| b[1] else "";
        if (eql(name, "RANDOM")) {
            var b: [4]u8 = undefined;
            c.random(&b);
            return try std.fmt.allocPrint(a, "{d:0>6}", .{std.mem.readInt(u32, &b, .little) % 1_000_000});
        }
        if (eql(name, "RANDOM_HEX")) {
            var b: [3]u8 = undefined;
            c.random(&b);
            return try std.fmt.allocPrint(a, "{x}", .{&b});
        }
        if (eql(name, "UUID")) {
            var b: [16]u8 = undefined;
            c.random(&b);
            b[6] = (b[6] & 0x0f) | 0x40;
            b[8] = (b[8] & 0x3f) | 0x80;
            return try std.fmt.allocPrint(a, "{x}-{x}-{x}-{x}-{x}", .{ b[0..4], b[4..6], b[6..8], b[8..10], b[10..16] });
        }
        if (std.mem.startsWith(u8, name, "CURRENT_")) return c.timeValue(name["CURRENT_".len..], a);
        return null;
    }

    fn timeValue(c: *const Context, what: []const u8, a: Allocator) !?[]const u8 {
        const ms = c.nowMs();
        if (eql(what, "SECONDS_UNIX")) return try std.fmt.allocPrint(a, "{d}", .{@divFloor(ms, 1000)});
        if (eql(what, "MILLISECONDS_UNIX")) return try std.fmt.allocPrint(a, "{d}", .{ms});
        if (eql(what, "TIMEZONE_NAME")) return c.tz_name;
        if (eql(what, "TIMEZONE_OFFSET")) {
            const off = c.tz_offset_min;
            const abs: u32 = @abs(off);
            return try std.fmt.allocPrint(a, "{c}{d:0>2}:{d:0>2}", .{ @as(u8, if (off < 0) '-' else '+'), abs / 60, abs % 60 });
        }
        const local = ms + @as(i64, c.tz_offset_min) * 60_000;
        const secs: u64 = @intCast(@max(0, @divFloor(local, 1000)));
        const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
        const day = es.getEpochDay();
        const yd = day.calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        const month: usize = md.month.numeric() - 1;
        // 1970-01-01 was a Thursday.
        const wday: usize = @intCast((day.day + 4) % 7);
        if (eql(what, "YEAR")) return try std.fmt.allocPrint(a, "{d}", .{yd.year});
        if (eql(what, "YEAR_SHORT")) return try std.fmt.allocPrint(a, "{d:0>2}", .{yd.year % 100});
        if (eql(what, "MONTH")) return try std.fmt.allocPrint(a, "{d:0>2}", .{month + 1});
        if (eql(what, "MONTH_NAME")) return month_names[month];
        if (eql(what, "MONTH_NAME_SHORT")) return month_names[month][0..3];
        if (eql(what, "DATE")) return try std.fmt.allocPrint(a, "{d:0>2}", .{md.day_index + 1});
        if (eql(what, "DAY_NAME")) return day_names[wday];
        if (eql(what, "DAY_NAME_SHORT")) return day_names[wday][0..3];
        if (eql(what, "HOUR")) return try std.fmt.allocPrint(a, "{d:0>2}", .{ds.getHoursIntoDay()});
        if (eql(what, "MINUTE")) return try std.fmt.allocPrint(a, "{d:0>2}", .{ds.getMinutesIntoHour()});
        if (eql(what, "SECOND")) return try std.fmt.allocPrint(a, "{d:0>2}", .{ds.getSecondsIntoMinute()});
        if (eql(what, "MILLISECOND")) return try std.fmt.allocPrint(a, "{d:0>3}", .{@as(u64, @intCast(@mod(local, 1000)))});
        return null;
    }
};
