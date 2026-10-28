//! Command lines for `shell` tasks: the task's command as written, then
//! each argument quoted for the shell that runs it, and the argv that
//! hands the line to that shell.
//!
//! - POSIX shells (`sh`, `bash`, `zsh`, `fish`...): an argument with
//!   anything but `[A-Za-z0-9_@%+=:,./-]` goes in single quotes, a `'`
//!   inside as `'\''`. Run as `<shell> -c <line>`.
//! - cmd.exe: an argument with whitespace or `&|<>^()"` goes in double
//!   quotes, a `"` inside doubled. Run as `cmd.exe /d /s /c <line>`:
//!   `std.process.spawn` wraps the line in quotes and `/s` strips them.
//!   It also backslash-escapes quotes inside the line, which cmd.exe
//!   does not read; that needs a raw command line (E01's Windows spawn)
//!   and is not supported yet.
//! - PowerShell (`pwsh`, `powershell`): single quotes, `'` doubled. Run
//!   as `<shell> -NoProfile -Command <line>`.
//!
//! The command itself is not quoted: it is a shell command line already
//! (`make -j8`, `zig build test`).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Style = enum { posix, cmd, pwsh };

/// The style of `executable` (a path or a name); null: the platform's
/// default shell.
pub fn styleOf(executable: ?[]const u8, os: std.Target.Os.Tag) Style {
    const exe = executable orelse return if (os == .windows) .cmd else .posix;
    var base = exe;
    if (std.mem.lastIndexOfAny(u8, base, "/\\")) |i| base = base[i + 1 ..];
    if (std.ascii.endsWithIgnoreCase(base, ".exe")) base = base[0 .. base.len - 4];
    if (std.ascii.eqlIgnoreCase(base, "cmd")) return .cmd;
    if (std.ascii.eqlIgnoreCase(base, "pwsh") or std.ascii.eqlIgnoreCase(base, "powershell")) return .pwsh;
    return .posix;
}

pub fn quote(w: *std.Io.Writer, arg: []const u8, style: Style) std.Io.Writer.Error!void {
    switch (style) {
        .posix => {
            if (arg.len > 0 and for (arg) |c| {
                if (!posixSafe(c)) break false;
            } else true) return w.writeAll(arg);
            try w.writeByte('\'');
            for (arg) |c| {
                if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
            }
            try w.writeByte('\'');
        },
        .cmd => {
            if (arg.len > 0 and std.mem.indexOfAny(u8, arg, " \t\n&|<>^()\"") == null) return w.writeAll(arg);
            try w.writeByte('"');
            for (arg) |c| {
                if (c == '"') try w.writeAll("\"\"") else try w.writeByte(c);
            }
            try w.writeByte('"');
        },
        .pwsh => {
            if (arg.len > 0 and for (arg) |c| {
                if (!posixSafe(c)) break false;
            } else true) return w.writeAll(arg);
            try w.writeByte('\'');
            for (arg) |c| {
                if (c == '\'') try w.writeAll("''") else try w.writeByte(c);
            }
            try w.writeByte('\'');
        },
    }
}

fn posixSafe(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "_@%+=:,./-", c) != null;
}

/// `command` followed by the quoted `args`.
pub fn commandLine(arena: Allocator, command: []const u8, args: []const []const u8, style: Style) Allocator.Error![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    w.writeAll(command) catch return error.OutOfMemory;
    for (args) |a| {
        w.writeByte(' ') catch return error.OutOfMemory;
        quote(w, a, style) catch return error.OutOfMemory;
    }
    return out.written();
}

/// The argv running `line` in `executable` (null: `/bin/sh`, or cmd.exe
/// on Windows), with `shell_args` in place of the style's usual flags
/// when given.
pub fn shellArgv(arena: Allocator, line: []const u8, executable: ?[]const u8, shell_args: ?[]const []const u8, os: std.Target.Os.Tag) Allocator.Error![]const []const u8 {
    const style = styleOf(executable, os);
    const exe = executable orelse if (os == .windows) "cmd.exe" else "/bin/sh";
    const flags: []const []const u8 = shell_args orelse switch (style) {
        .posix => &.{"-c"},
        .cmd => &.{ "/d", "/s", "/c" },
        .pwsh => &.{ "-NoProfile", "-Command" },
    };
    const out = try arena.alloc([]const u8, flags.len + 2);
    out[0] = exe;
    @memcpy(out[1 .. 1 + flags.len], flags);
    out[out.len - 1] = line;
    return out;
}
