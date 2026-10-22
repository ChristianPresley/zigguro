//! `zg-release verify`: verifies a file against a minisign signature.
//! `--pub` is an `RW...` line or a `.pub` file path; `--sig` defaults to
//! `<file>.minisig`. Prints the trusted comment and exits 0 on success, 1 on
//! any failure.

const std = @import("std");
const zg_release = @import("zg_release");
const minisign = zg_release.minisign;
const args = @import("args.zig");
const sign = @import("sign.zig");

/// Resolves `--pub`: a key line, or a path to a `.pub` file.
pub fn loadPublicKey(ctx: *const args.Context, value: []const u8) !minisign.PublicKey {
    if (minisign.PublicKey.parse(value)) |pk| return pk else |_| {}
    const text = try std.Io.Dir.cwd().readFileAlloc(ctx.io, value, ctx.gpa, .limited(4096));
    return minisign.PublicKey.parse(text);
}

/// The command.
pub fn run(ctx: *const args.Context) !u8 {
    const file = try ctx.opts.need("file");
    const pk = try loadPublicKey(ctx, try ctx.opts.need("pub"));
    const sig_path = ctx.opts.get("sig") orelse try std.fmt.allocPrint(ctx.gpa, "{s}.minisig", .{file});
    const sig_text = try std.Io.Dir.cwd().readFileAlloc(ctx.io, sig_path, ctx.gpa, .limited(64 * 1024));
    const sig = try minisign.Signature.parse(sig_text);
    const h = try sign.hashFile(ctx.io, file);
    _ = try minisign.verifyStreaming(&sig, &.{pk}, &h);
    var buf: [1024]u8 = undefined;
    var out: std.Io.File.Writer = .init(.stdout(), ctx.io, &buf);
    try out.interface.print("Signature and comment signature verified\nTrusted comment: {s}\n", .{sig.trusted_comment});
    try out.interface.flush();
    return 0;
}

test "verify: sign then verify a temp file; tampering fails" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "payload\n" });
    const kp = try minisign.keyPairFromSeed(@splat(5), @splat(6));

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPathFile(io, "f.txt", &path_buf);
    const path = path_buf[0..n];
    const h = try sign.hashFile(io, path);
    const text = try minisign.signStreaming(std.testing.allocator, kp.kp, kp.pk.key_id, &h, "u", "file:f.txt");
    defer std.testing.allocator.free(text);
    const sig = try minisign.Signature.parse(text);
    _ = try minisign.verifyStreaming(&sig, &.{kp.pk}, &(try sign.hashFile(io, path)));

    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "payload!\n" });
    try std.testing.expectError(error.BadSignature, minisign.verifyStreaming(&sig, &.{kp.pk}, &(try sign.hashFile(io, path))));
}
