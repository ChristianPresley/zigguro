//! zg-release: release engineering tool (E17).
//!
//!   zg-release keygen  --out <dir> [--channel stable|insiders]
//!   zg-release sign    --file <f> [--seed-env ZIGGURO_RELEASE_SEED]
//!                      [--key-id-env ZIGGURO_RELEASE_KEY_ID] [--trusted "<comment>"]
//!   zg-release verify  --pub <RW...|file> --file <f> [--sig <f.minisig>]
//!
//! Exit codes: 0 success, 1 verification or operation failure, 2 usage.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// `keygen` subcommand.
pub const keygen = @import("keygen.zig");
/// `sign` subcommand.
pub const sign = @import("sign.zig");
/// `verify` subcommand.
pub const verify = @import("verify.zig");
/// Shared argument parsing.
pub const args = @import("args.zig");

const usage =
    \\usage: zg-release <command> [--option value]...
    \\  keygen  --out <dir> [--channel stable|insiders]
    \\  sign    --file <f> [--seed-env NAME] [--key-id-env NAME] [--trusted <comment>] [--out <f.minisig>]
    \\  verify  --pub <RW...|file> --file <f> [--sig <f.minisig>]
    \\
;

/// A subcommand entry point.
pub const Command = *const fn (ctx: *const args.Context) anyerror!u8;

const commands = [_]struct { []const u8, Command }{
    .{ "keygen", keygen.run },
    .{ "sign", sign.run },
    .{ "verify", verify.run },
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(gpa);
    if (argv.len < 2) {
        std.debug.print(usage, .{});
        return 2;
    }
    const opts = args.parse(gpa, argv[2..]) catch {
        std.debug.print(usage, .{});
        return 2;
    };
    const ctx: args.Context = .{ .gpa = gpa, .io = init.io, .env = init.environ_map, .opts = opts };
    for (commands) |c| {
        if (std.mem.eql(u8, argv[1], c[0])) return c[1](&ctx) catch |err| switch (err) {
            error.Usage => {
                std.debug.print(usage, .{});
                return 2;
            },
            else => {
                std.debug.print("zg-release {s}: {t}\n", .{ c[0], err });
                return 1;
            },
        };
    }
    std.debug.print(usage, .{});
    return 2;
}

test {
    _ = keygen;
    _ = sign;
    _ = verify;
    _ = args;
}
