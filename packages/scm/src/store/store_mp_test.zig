//! Multi-process store test (E09.F01.S01.T02): four `store_writer`
//! processes commit and compact in one store at once; afterwards every
//! object each reports is readable, verified, and fsck is clean.

const std = @import("std");
const id_mod = @import("id.zig");
const store_mod = @import("store.zig");
const fsck_mod = @import("fsck.zig");
const test_exes = @import("zg_test_exes");
const Store = store_mod.Store;
const testing = std.testing;

/// Must match `object` in test/store_writer.zig.
fn object(buf: []u8, worker: u32, i: u64) []const u8 {
    var prng: std.Random.DefaultPrng = .init((@as(u64, worker) << 40) ^ i);
    const r = prng.random();
    const b = buf[0..r.uintAtMost(usize, buf.len)];
    r.bytes(b);
    return b;
}

test "store: multi-process writers" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = path_buf[0..try tmp.dir.realPath(io, &path_buf)];

    const procs = 4;
    var children: [procs]std.process.Child = undefined;
    var args: [procs][8]u8 = undefined;
    for (&children, &args, 0..) |*c, *a, k| {
        c.* = try std.process.spawn(io, .{
            .argv = &.{ test_exes.store_writer, dir_path, try std.fmt.bufPrint(a, "{d}", .{k}), "1500" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .inherit,
        });
    }
    for (&children) |*c| try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try c.wait(io));

    const s = try Store.open(gpa, io, tmp.dir, .{ .rescan_interval_ms = 0 });
    defer s.close();
    var buf: [4096]u8 = undefined;
    var total: u64 = 0;
    for (0..procs) |k| {
        var nb: [32]u8 = undefined;
        var tb: [32]u8 = undefined;
        const text = try tmp.dir.readFile(io, try std.fmt.bufPrint(&nb, "worker-{d}.done", .{k}), &tb);
        const n = try std.fmt.parseInt(u64, text, 10);
        try testing.expect(n > 0);
        total += n;
        for (0..n) |i| {
            const want = object(&buf, @intCast(k), i);
            const r = try s.readVerified(id_mod.hashObject(.blob, want));
            defer r.release();
            try testing.expectEqualSlices(u8, want, r.bytes);
        }
    }
    try testing.expect(total >= 4 * 50);
    var report = try fsck_mod.fsck(s, .{});
    defer report.deinit();
    try testing.expect(report.clean());
}
