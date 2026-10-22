//! `zg-release keygen`: creates a release signing key.
//!
//! Writes `<dir>/<channel>.pub` (minisign public key file) and
//! `<dir>/<channel>.seed` (mode 0600: `seed=<64 hex>` and `key_id=<16 hex>`
//! lines), and prints the `RW...` line for `packaging/product.zon`. The seed
//! and key id go into the release environment's secrets as
//! `ZIGGURO_RELEASE_SEED` and `ZIGGURO_RELEASE_KEY_ID` (docs/release.md).

const std = @import("std");
const zg_release = @import("zg_release");
const minisign = zg_release.minisign;
const args = @import("args.zig");

/// Generated key material.
pub const Generated = struct {
    pair: minisign.KeyPair,
    seed: minisign.SecretSeed,
};

/// Generates a key from secure randomness.
pub fn generate(io: std.Io) !Generated {
    var seed: minisign.SecretSeed = undefined;
    var id: minisign.KeyId = undefined;
    try io.randomSecure(&seed);
    try io.randomSecure(&id);
    return .{ .pair = try minisign.keyPairFromSeed(seed, id), .seed = seed };
}

/// Writes the seed file contents.
pub fn writeSeedFile(w: *std.Io.Writer, g: Generated) std.Io.Writer.Error!void {
    try w.print("seed={x}\nkey_id={x}\n", .{ &g.seed, &g.pair.pk.key_id });
}

/// The command.
pub fn run(ctx: *const args.Context) !u8 {
    const out = try ctx.opts.need("out");
    const channel = ctx.opts.get("channel") orelse "stable";
    if (!(std.mem.eql(u8, channel, "stable") or std.mem.eql(u8, channel, "insiders"))) return error.Usage;
    const io = ctx.io;
    const g = try generate(io);

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, out, .{});
    defer dir.close(io);

    var pub_buf: [256]u8 = undefined;
    var pw: std.Io.Writer = .fixed(&pub_buf);
    try g.pair.pk.writeFile(&pw);
    try dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(ctx.gpa, "{s}.pub", .{channel}), .data = pw.buffered() });

    var seed_buf: [128]u8 = undefined;
    var sw: std.Io.Writer = .fixed(&seed_buf);
    try writeSeedFile(&sw, g);
    try dir.writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(ctx.gpa, "{s}.seed", .{channel}),
        .data = sw.buffered(),
        .flags = .{ .exclusive = true, .permissions = secretPermissions() },
    });

    var line: [minisign.PublicKey.encoded_len]u8 = undefined;
    var obuf: [256]u8 = undefined;
    var stdout: std.Io.File.Writer = .init(.stdout(), io, &obuf);
    try stdout.interface.print("{s}\n", .{g.pair.pk.format(&line)});
    try stdout.interface.flush();
    return 0;
}

/// 0600 where the OS has mode bits.
pub fn secretPermissions() std.Io.File.Permissions {
    const P = std.Io.File.Permissions;
    if (@hasDecl(P, "toMode") and P.has_executable_bit) return @enumFromInt(0o600);
    return .default_file;
}

test "keygen: seed file roundtrip" {
    const g: Generated = .{ .pair = try minisign.keyPairFromSeed(@splat(3), .{ 1, 2, 3, 4, 5, 6, 7, 8 }), .seed = @splat(3) };
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeSeedFile(&w, g);
    try std.testing.expectEqualStrings(
        "seed=0303030303030303030303030303030303030303030303030303030303030303\nkey_id=0102030405060708\n",
        w.buffered(),
    );
}
