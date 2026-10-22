//! Screen-model benchmarks: page clone, full-screen scroll and the ASCII
//! print path (E06.F03 budgets).

const std = @import("std");
const zg_core = @import("zg_core");
const screen = @import("zg_terminal").screen;
const bench = zg_core.bench;

fn pageClone(_: void, s: *bench.State) void {
    const gpa = s.allocator();
    var pool: screen.Page.PagePool = .init(gpa);
    defer pool.deinit();
    const a = pool.alloc(screen.Page.default_bytes) catch unreachable;
    defer pool.free(a);
    const b = pool.alloc(screen.Page.default_bytes) catch unreachable;
    defer pool.free(b);
    const src = screen.Page.init(a, 200);
    var dst = screen.Page.init(b, 200);
    s.setBytes(src.layout.total);
    for (0..s.iterations()) |_| {
        src.cloneInto(&dst);
        bench.doNotOptimizeAway(dst.buf.ptr);
    }
}

fn scroll(scr: *screen.Screen, s: *bench.State) void {
    scr.cursor.y = 49;
    for (0..s.iterations()) |_| scr.index(.{}) catch unreachable;
}

fn growOnly(pl: *screen.PageList, s: *bench.State) void {
    for (0..s.iterations()) |_| _ = pl.grow() catch unreachable;
}

const PrintCtx = struct { scr: *screen.Screen, line: []const u8 };

fn printAscii(ctx: PrintCtx, s: *bench.State) void {
    const scr = ctx.scr;
    const line = ctx.line;
    s.setBytes(line.len);
    for (0..s.iterations()) |_| {
        scr.cursor.x = 0;
        scr.cursor.pending_wrap = false;
        scr.printAscii(line);
    }
    bench.doNotOptimizeAway(scr.cursor.x);
}

/// Registers the screen benchmarks.
pub fn register(b: *bench.Bench) !void {
    try b.run("terminal.page.clone 256 KiB", {}, pageClone);
    // Steady state: the screen persists across calls and its scrollback is
    // already at the byte cap, so pages are recycled (no first-touch faults).
    var scr = try screen.Screen.init(b.gpa, 200, 50, .{ .max_bytes = 16 << 20 });
    defer scr.deinit();
    scr.cursor.y = 49;
    for (0..200_000) |_| try scr.index(.{});
    try b.run("terminal.scroll (LF at bottom, 200x50)", &scr, scroll);
    var pl = try screen.PageList.init(b.gpa, 200, 50, .{ .max_bytes = 16 << 20 });
    defer pl.deinit();
    for (0..200_000) |_| _ = try pl.grow();
    try b.run("terminal.pagelist.grow (200 cols)", &pl, growOnly);
    const line: []const u8 = "x" ** 200;
    try b.run("terminal.print.ascii 200 cols", PrintCtx{ .scr = &scr, .line = line }, printAscii);
}
