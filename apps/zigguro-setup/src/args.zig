//! zigguro-setup's command line (E17.F02.S01.T03):
//!
//! ```
//! zigguro-setup.exe [--silent] [--dir <path>] [--no-path] [--no-start-menu]
//!                   [--desktop-shortcut] [--no-open-with] [--no-folder-menu] [--no-launch]
//! zigguro-setup.exe --uninstall [--silent] [--remove-user-data]
//!                   (internal: --stage2 --root <root> [--parent-pid <pid>])
//! zigguro-setup.exe --apply --root <root> --wait-pid <pid> [--relaunch <args>]
//! ```

const std = @import("std");
const InstallOptions = @import("zg_install").InstallOptions;

/// Process exit codes.
pub const Exit = enum(u8) {
    ok = 0,
    cancelled = 1,
    /// The app is running and setup is silent.
    app_running = 2,
    io_failure = 3,
    payload_corrupt = 4,
    bad_arguments = 5,
};

pub const Install = struct {
    silent: bool = false,
    dir: ?[]const u8 = null,
    opts: InstallOptions = .{},
    launch: bool = true,
};

pub const Uninstall = struct {
    silent: bool = false,
    remove_user_data: bool = false,
    /// Set by the first stage when it relaunches the temporary copy.
    stage2: bool = false,
    /// The install root; the first stage derives it from its own path.
    root: ?[]const u8 = null,
    /// The first stage's process, which the second waits for.
    parent_pid: ?u32 = null,
};

pub const Apply = struct {
    root: []const u8,
    wait_pid: u32,
    /// Arguments for the relaunched app, as one string.
    relaunch: ?[]const u8 = null,
};

pub const Command = union(enum) {
    install: Install,
    uninstall: Uninstall,
    apply: Apply,
};

pub const Error = error{
    UnknownFlag,
    MissingValue,
    /// A flag that the mode does not take.
    WrongMode,
    BadPid,
    MissingRoot,
};

const Mode = enum { install, uninstall, apply };

/// Parses `args` (without the program name). Slices point into `args`.
pub fn parse(args: []const []const u8) Error!Command {
    var mode: Mode = .install;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--uninstall")) mode = .uninstall;
        if (std.mem.eql(u8, a, "--apply")) mode = .apply;
    }
    var inst: Install = .{};
    var un: Uninstall = .{};
    var root: ?[]const u8 = null;
    var pid: ?u32 = null;
    var relaunch: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const eql = struct {
            fn f(x: []const u8, y: []const u8) bool {
                return std.mem.eql(u8, x, y);
            }
        }.f;
        const value = struct {
            fn f(list: []const []const u8, at: *usize) Error![]const u8 {
                at.* += 1;
                if (at.* >= list.len) return error.MissingValue;
                return list[at.*];
            }
        }.f;
        if (eql(a, "--uninstall") or eql(a, "--apply")) continue;
        if (eql(a, "--silent")) {
            if (mode == .apply) return error.WrongMode;
            inst.silent = true;
            un.silent = true;
            continue;
        }
        switch (mode) {
            .install => {
                if (eql(a, "--dir")) {
                    inst.dir = try value(args, &i);
                } else if (eql(a, "--no-path")) {
                    inst.opts.add_to_path = false;
                } else if (eql(a, "--no-start-menu")) {
                    inst.opts.start_menu = false;
                } else if (eql(a, "--desktop-shortcut")) {
                    inst.opts.desktop_shortcut = true;
                } else if (eql(a, "--no-open-with")) {
                    inst.opts.open_with = false;
                } else if (eql(a, "--no-folder-menu")) {
                    inst.opts.folder_context_menu = false;
                } else if (eql(a, "--no-launch")) {
                    inst.launch = false;
                } else return unknown(a);
            },
            .uninstall => {
                if (eql(a, "--remove-user-data")) {
                    un.remove_user_data = true;
                } else if (eql(a, "--stage2")) {
                    un.stage2 = true;
                } else if (eql(a, "--root")) {
                    un.root = try value(args, &i);
                } else if (eql(a, "--parent-pid")) {
                    un.parent_pid = std.fmt.parseInt(u32, try value(args, &i), 10) catch return error.BadPid;
                } else return unknown(a);
            },
            .apply => {
                if (eql(a, "--root")) {
                    root = try value(args, &i);
                } else if (eql(a, "--wait-pid")) {
                    pid = std.fmt.parseInt(u32, try value(args, &i), 10) catch return error.BadPid;
                } else if (eql(a, "--relaunch")) {
                    relaunch = try value(args, &i);
                } else return unknown(a);
            },
        }
    }
    return switch (mode) {
        .install => .{ .install = inst },
        .uninstall => .{ .uninstall = un },
        .apply => .{ .apply = .{ .root = root orelse return error.MissingRoot, .wait_pid = pid orelse return error.BadPid, .relaunch = relaunch } },
    };
}

/// A flag of another mode is `WrongMode`; anything else `UnknownFlag`.
fn unknown(a: []const u8) Error {
    const all = [_][]const u8{ "--dir", "--no-path", "--no-start-menu", "--desktop-shortcut", "--no-open-with", "--no-folder-menu", "--no-launch", "--remove-user-data", "--stage2", "--parent-pid", "--root", "--wait-pid", "--relaunch" };
    for (all) |f| if (std.mem.eql(u8, a, f)) return error.WrongMode;
    return error.UnknownFlag;
}

const testing = std.testing;

test "args: parse all flags" {
    const i = (try parse(&.{ "--silent", "--dir", "C:\\zïg", "--no-path", "--no-start-menu", "--desktop-shortcut", "--no-open-with", "--no-folder-menu", "--no-launch" })).install;
    try testing.expect(i.silent);
    try testing.expectEqualStrings("C:\\zïg", i.dir.?);
    try testing.expect(!i.opts.add_to_path and !i.opts.start_menu and i.opts.desktop_shortcut and !i.opts.open_with and !i.opts.folder_context_menu and !i.launch);

    const d = (try parse(&.{})).install;
    try testing.expect(!d.silent and d.dir == null and d.opts.add_to_path and d.opts.start_menu and !d.opts.desktop_shortcut and d.launch);

    const u = (try parse(&.{ "--uninstall", "--silent", "--remove-user-data" })).uninstall;
    try testing.expect(u.silent and u.remove_user_data and !u.stage2 and u.root == null);
    const st2 = (try parse(&.{ "--uninstall", "--stage2", "--root", "C:\\zg", "--parent-pid", "77" })).uninstall;
    try testing.expect(st2.stage2 and !st2.silent);
    try testing.expectEqualStrings("C:\\zg", st2.root.?);
    try testing.expectEqual(@as(u32, 77), st2.parent_pid.?);

    const ap = (try parse(&.{ "--apply", "--root", "C:\\zg", "--wait-pid", "4242", "--relaunch", "--new-window x.zig" })).apply;
    try testing.expectEqualStrings("C:\\zg", ap.root);
    try testing.expectEqual(@as(u32, 4242), ap.wait_pid);
    try testing.expectEqualStrings("--new-window x.zig", ap.relaunch.?);
}

test "args: unknown flag, missing values, wrong mode" {
    try testing.expectError(error.UnknownFlag, parse(&.{"--frobnicate"}));
    try testing.expectError(error.MissingValue, parse(&.{"--dir"}));
    try testing.expectError(error.WrongMode, parse(&.{ "--uninstall", "--dir", "x" }));
    try testing.expectError(error.WrongMode, parse(&.{"--remove-user-data"}));
    try testing.expectError(error.WrongMode, parse(&.{ "--apply", "--silent", "--root", "r", "--wait-pid", "1" }));
    try testing.expectError(error.MissingRoot, parse(&.{ "--apply", "--wait-pid", "1" }));
    try testing.expectError(error.BadPid, parse(&.{ "--apply", "--root", "r", "--wait-pid", "x" }));
    try testing.expectError(error.BadPid, parse(&.{ "--apply", "--root", "r" }));
}
