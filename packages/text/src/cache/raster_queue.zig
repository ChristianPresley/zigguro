//! `RasterQueue`: rasterizes glyphs on worker threads and hands the
//! bitmaps back to the UI thread through `Runtime.post`.
//!
//! Each worker owns a `Rasterizer`. Jobs travel through a bounded
//! `std.Io.Queue`; `submit` never blocks. A finished glyph is copied into
//! a `RasterResult` (owned by the message) and posted as `ui_msg_kind`
//! with the key in `a` and the result pointer in `b`. The receiver must
//! pass every such message to `GlyphCache.onRasterDone` (or
//! `releaseResult`), which frees it.

const std = @import("std");
const zg_core = @import("zg_core");
const Allocator = std.mem.Allocator;
const Runtime = zg_core.runtime.Runtime;
const rasterizer = @import("../raster/rasterizer.zig");
const Rasterizer = rasterizer.Rasterizer;
const Bitmap = rasterizer.Bitmap;
const RasterParams = rasterizer.RasterParams;
const FaceInstance = @import("../ot/var/instance.zig").FaceInstance;
const GlyphKey = @import("glyph_key.zig").GlyphKey;

/// `UiMsg.kind` of a finished raster job (zg_text's range is 0x0300_xxxx).
pub const ui_msg_kind: u32 = 0x0300_0001;

/// Jobs the queue holds before `submit` fails with `Full`.
pub const capacity = 4096;

/// What to rasterize for a key. `instance` must outlive the job.
pub const RasterJob = struct {
    instance: *const FaceInstance,
    params: RasterParams,
};

/// A finished glyph: the bitmap (with its own copy of the pixels) or a
/// failure. Owned by the posted message until released.
pub const RasterResult = struct {
    key: GlyphKey,
    bitmap: Bitmap,
    /// Rasterization failed; the cache stores an empty entry.
    failed: bool,
};

const Msg = struct { key: GlyphKey, job: RasterJob };

const Worker = struct {
    rast: Rasterizer,
};

/// The worker pool. Must not move after `init`.
pub const RasterQueue = struct {
    gpa: Allocator,
    io: std.Io,
    rt: *Runtime,
    buffer: []Msg,
    queue: std.Io.Queue(Msg),
    workers: []Worker,
    group: std.Io.Group = .init,
    /// Jobs accepted by `submit` (for tests and stats).
    submitted: std.atomic.Value(u64) = .init(0),
    /// Jobs whose result was posted.
    completed: std.atomic.Value(u64) = .init(0),

    /// Starts `workers` (at least 1) worker loops on `io`.
    pub fn init(q: *RasterQueue, gpa: Allocator, io: std.Io, rt: *Runtime, workers: u8) !void {
        const n = @max(1, workers);
        const buffer = try gpa.alloc(Msg, capacity);
        errdefer gpa.free(buffer);
        const ws = try gpa.alloc(Worker, n);
        errdefer gpa.free(ws);
        for (ws) |*w| w.* = .{ .rast = Rasterizer.init(gpa) };
        q.* = .{ .gpa = gpa, .io = io, .rt = rt, .buffer = buffer, .queue = .init(buffer), .workers = ws };
        var started: usize = 0;
        errdefer {
            q.queue.close(io);
            q.group.cancel(io);
        }
        while (started < n) : (started += 1) try q.group.concurrent(io, workerLoop, .{ q, &ws[started] });
    }

    /// The default worker count: min(4, cpu_count - 1), at least 1.
    pub fn defaultWorkers() u8 {
        const cpus = std.Thread.getCpuCount() catch 2;
        return @intCast(std.math.clamp(cpus -| 1, 1, 4));
    }

    /// Queues `job` for `key` without blocking.
    pub fn submit(q: *RasterQueue, key: GlyphKey, job: RasterJob) error{Full}!void {
        const n = q.queue.putUncancelable(q.io, &.{.{ .key = key, .job = job }}, 0) catch return error.Full;
        if (n == 0) return error.Full;
        _ = q.submitted.fetchAdd(1, .monotonic);
    }

    /// Closes the queue, cancels and joins the workers and frees them.
    /// Results already posted stay owned by their messages.
    pub fn deinit(q: *RasterQueue) void {
        q.queue.close(q.io);
        q.group.cancel(q.io);
        for (q.workers) |*w| w.rast.deinit();
        q.gpa.free(q.workers);
        q.gpa.free(q.buffer);
        q.* = undefined;
    }

    fn workerLoop(q: *RasterQueue, w: *Worker) std.Io.Cancelable!void {
        while (true) {
            const msg = q.queue.getOne(q.io) catch |e| switch (e) {
                error.Closed => return,
                error.Canceled => |c| return c,
            };
            const res = q.run(w, msg) catch continue; // out of memory: the key stays pending
            q.deliver(res) catch |e| {
                destroyResult(q.gpa, res);
                return e;
            };
        }
    }

    fn run(q: *RasterQueue, w: *Worker, msg: Msg) Allocator.Error!*RasterResult {
        const res = try q.gpa.create(RasterResult);
        errdefer q.gpa.destroy(res);
        res.* = .{ .key = msg.key, .bitmap = .{}, .failed = false };
        const bm = w.rast.rasterizeGlyph(msg.job.instance, msg.key.glyph, msg.job.params) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                res.failed = true;
                return res;
            },
        };
        res.bitmap = try copyBitmap(q.gpa, bm);
        return res;
    }

    /// Posts `res`, retrying while the mailbox is full; a closed mailbox
    /// drops it.
    fn deliver(q: *RasterQueue, res: *RasterResult) std.Io.Cancelable!void {
        const msg: zg_core.runtime.UiMsg = .{ .kind = ui_msg_kind, .a = res.key.bits(), .b = @intFromPtr(res) };
        while (true) {
            if (q.rt.post(msg)) |_| {
                _ = q.completed.fetchAdd(1, .monotonic);
                return;
            } else |e| switch (e) {
                error.Closed => {
                    destroyResult(q.gpa, res);
                    return;
                },
                error.Full => try q.io.sleep(.fromMilliseconds(1), .awake),
            }
        }
    }
};

/// A copy of `bm` with tightly packed rows, owned by `gpa`.
fn copyBitmap(gpa: Allocator, bm: Bitmap) Allocator.Error!Bitmap {
    if (bm.isEmpty()) return .{ .left = bm.left, .top = bm.top, .format = bm.format };
    const row_len = bm.row(0).len;
    const px = try gpa.alloc(u8, row_len * bm.height);
    for (0..bm.height) |y| @memcpy(px[y * row_len ..][0..row_len], bm.row(y));
    var out = bm;
    out.stride = @intCast(row_len);
    out.pixels = px;
    return out;
}

/// The result carried by a `ui_msg_kind` message.
pub fn resultOf(msg: zg_core.runtime.UiMsg) *RasterResult {
    std.debug.assert(msg.kind == ui_msg_kind);
    return @ptrFromInt(@as(usize, @intCast(msg.b)));
}

/// Frees `res` and its pixels.
pub fn destroyResult(gpa: Allocator, res: *RasterResult) void {
    gpa.free(res.bitmap.pixels);
    gpa.destroy(res);
}
