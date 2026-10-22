//! `zg-release sign`: signs a file in the minisign `ED` format.
//!
//! The key comes from the environment (`--seed-env`, default
//! `ZIGGURO_RELEASE_SEED`: 64 hex; `--key-id-env`, default
//! `ZIGGURO_RELEASE_KEY_ID`: 16 hex), never from a file argument, so CI
//! secrets never touch disk. The default trusted comment is
//! `timestamp:<now>\tfile:<basename>`; update manifests pass
//! `--trusted "timestamp:<unix>\tfile:<name>\tchannel:<c>\tserial:<n>"`.
//! The signature is written to `<file>.minisig` (or `--out`).

const std = @import("std");
const zg_release = @import("zg_release");
const minisign = zg_release.minisign;
const args = @import("args.zig");
const Blake2b512 = std.crypto.hash.blake2.Blake2b512;

/// Loads the signing key from the environment variables `seed_env` and `key_id_env`.
pub fn keyFromEnv(env: *const std.process.Environ.Map, seed_env: []const u8, key_id_env: []const u8) !minisign.KeyPair {
    const seed_hex = env.get(seed_env) orelse return error.MissingSeed;
    const id_hex = env.get(key_id_env) orelse return error.MissingKeyId;
    var seed: minisign.SecretSeed = undefined;
    var id: minisign.KeyId = undefined;
    try args.hexExact(&seed, seed_hex);
    try args.hexExact(&id, id_hex);
    return minisign.keyPairFromSeed(seed, id);
}

/// Streams `path` into a BLAKE2b-512 state.
pub fn hashFile(io: std.Io, path: []const u8) !Blake2b512 {
    var f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var r = f.reader(io, &buf);
    var h: Blake2b512 = .init(.{});
    while (true) {
        const chunk = r.interface.peekGreedy(1) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        h.update(chunk);
        r.interface.toss(chunk.len);
    }
    return h;
}

/// The command.
pub fn run(ctx: *const args.Context) !u8 {
    const file = try ctx.opts.need("file");
    const kp = try keyFromEnv(ctx.env, ctx.opts.get("seed-env") orelse "ZIGGURO_RELEASE_SEED", ctx.opts.get("key-id-env") orelse "ZIGGURO_RELEASE_KEY_ID");
    const h = try hashFile(ctx.io, file);
    const trusted = ctx.opts.get("trusted") orelse try std.fmt.allocPrint(ctx.gpa, "timestamp:{d}\tfile:{s}", .{
        std.Io.Clock.real.now(ctx.io).toSeconds(), std.fs.path.basename(file),
    });
    const text = try minisign.signStreaming(ctx.gpa, kp.kp, kp.pk.key_id, &h, "signature from zg-release secret key", trusted);
    const out = ctx.opts.get("out") orelse try std.fmt.allocPrint(ctx.gpa, "{s}.minisig", .{file});
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = out, .data = text });
    return 0;
}
