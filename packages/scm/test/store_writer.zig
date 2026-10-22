//! Multi-process store test helper:
//! `store_writer <store dir> <worker> <milliseconds>` commits batches of
//! deterministic objects into the shared store (compacting now and then)
//! until the time is up, reading each batch back, then writes how many
//! objects it committed to `<store dir>/worker-<n>.done`.

const std = @import("std");
const zg_scm = @import("zg_scm");
const Store = zg_scm.store.Store;

/// The bytes of object `i` of `worker`; the test recomputes them.
pub fn object(buf: []u8, worker: u32, i: u64) []const u8 {
    var prng: std.Random.DefaultPrng = .init((@as(u64, worker) << 40) ^ i);
    const r = prng.random();
    const b = buf[0..r.uintAtMost(usize, buf.len)];
    r.bytes(b);
    return b;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    const dir_path = args.next() orelse return 2;
    const worker = try std.fmt.parseInt(u32, args.next() orelse return 2, 10);
    const ms = try std.fmt.parseInt(u32, args.next() orelse return 2, 10);

    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    const s = try Store.open(gpa, io, dir, .{ .fsync = false, .rescan_interval_ms = 0 });
    defer s.close();

    const deadline = std.Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(ms));
    var buf: [4096]u8 = undefined;
    var next: u64 = 0;
    var batches: usize = 0;
    while (std.Io.Timestamp.now(io, .awake).nanoseconds < deadline.nanoseconds) {
        const first = next;
        var b = s.batch();
        defer b.abort();
        for (0..50) |_| {
            _ = try b.put(.blob, object(&buf, worker, next));
            next += 1;
        }
        try b.commit();
        batches += 1;
        for (first..next) |i| {
            const want = object(&buf, worker, i);
            const id = zg_scm.id.hashObject(.blob, want);
            const r = try s.read(id);
            defer r.release();
            if (!std.mem.eql(u8, r.bytes, want)) return 1;
        }
        if (batches % 8 == 0) _ = try zg_scm.compaction.compact(s, .{ .deflate = false });
    }

    var name: [32]u8 = undefined;
    var text: [32]u8 = undefined;
    try dir.writeFile(io, .{
        .sub_path = try std.fmt.bufPrint(&name, "worker-{d}.done", .{worker}),
        .data = try std.fmt.bufPrint(&text, "{d}", .{next}),
    });
    return 0;
}
