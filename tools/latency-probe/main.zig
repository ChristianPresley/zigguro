//! latency-probe (E14.F03.S02.T03): reads keystroke-to-photon samples from
//! the photodiode rig over a serial port and writes E00 bench JSON with
//! the result `probe.key_to_photon` (docs/perf/latency.md section 3).
//!
//!     latency-probe --port /dev/ttyACM0|COM5 [--baud 115200] [--samples 500] [--out probe.json]
//!     latency-probe --input session.txt [--out probe.json]
//!
//! The rig prints one ASCII line per sample, `S <seq> <press_us> <edge_us>`,
//! with times from its own microsecond counter (wrapping at 2^32). Other
//! lines are ignored, except `R <text>`, which describes the rig and is
//! copied into the JSON as `rig`. `--input` reads a recorded session
//! instead of a port.

const std = @import("std");
const builtin = @import("builtin");
const LatencyHistogram = @import("latency_histogram").LatencyHistogram;

/// One sample.
pub const Sample = struct { seq: u64, latency_ns: u64 };

/// A parsed line.
pub const Line = union(enum) {
    sample: Sample,
    rig: []const u8,
    other,
};

/// Parses one line of the rig's protocol.
pub fn parseLine(line_in: []const u8) Line {
    const line = std.mem.trim(u8, line_in, " \t\r\n");
    if (std.mem.startsWith(u8, line, "R ")) return .{ .rig = std.mem.trim(u8, line[2..], " ") };
    if (!std.mem.startsWith(u8, line, "S ")) return .other;
    var it = std.mem.tokenizeScalar(u8, line[2..], ' ');
    const seq = std.fmt.parseInt(u64, it.next() orelse return .other, 10) catch return .other;
    const press = std.fmt.parseInt(u64, it.next() orelse return .other, 10) catch return .other;
    const edge = std.fmt.parseInt(u64, it.next() orelse return .other, 10) catch return .other;
    if (it.next() != null) return .other;
    // The rig's counter wraps at 2^32 us (Arduino `micros()`); a 64-bit
    // counter never wraps in practice.
    const us = if (press <= std.math.maxInt(u32) and edge <= std.math.maxInt(u32))
        @as(u64, @as(u32, @truncate(edge)) -% @as(u32, @truncate(press)))
    else if (edge >= press) edge - press else return .other;
    return .{ .sample = .{ .seq = seq, .latency_ns = us * std.time.ns_per_us } };
}

/// Samples collected so far.
pub const Session = struct {
    hist: LatencyHistogram = .{},
    rig_buf: [128]u8 = undefined,
    rig_len: usize = 0,
    ignored: u64 = 0,

    pub fn add(s: *Session, line: []const u8) void {
        switch (parseLine(line)) {
            .sample => |x| s.hist.record(x.latency_ns),
            .rig => |r| {
                s.rig_len = @min(r.len, s.rig_buf.len);
                @memcpy(s.rig_buf[0..s.rig_len], r[0..s.rig_len]);
            },
            .other => s.ignored += 1,
        }
    }

    pub fn rig(s: *const Session) []const u8 {
        return s.rig_buf[0..s.rig_len];
    }

    /// Writes E00 bench JSON.
    pub fn writeJson(s: *const Session, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const h = &s.hist;
        const mean: f64 = if (h.total > 0) @as(f64, @floatFromInt(h.sum)) / @as(f64, @floatFromInt(h.total)) else 0;
        try w.print("{{\n  \"schema\": 1,\n  \"package\": \"probe\",\n  \"zig\": \"{s}\",\n  \"target\": \"{t}-{t}\",\n  \"quick\": false,\n  \"rig\": ", .{ builtin.zig_version_string, builtin.cpu.arch, builtin.os.tag });
        try std.json.Stringify.encodeJsonString(s.rig(), .{}, w);
        try w.print(",\n  \"results\": [\n    {{ \"name\": \"probe.key_to_photon\", \"iters\": {d}, \"ns_per_op\": {d:.1}, \"p50_ns\": {d}, \"p95_ns\": {d}, \"p99_ns\": {d}, \"p999_ns\": {d}, \"max_ns\": {d}, \"min_ns\": {d} }}\n  ]\n}}\n", .{
            h.total, mean,                          h.percentile(50), h.percentile(95), h.percentile(99), h.percentile(99.9),
            h.max,   if (h.total > 0) h.min else 0,
        });
    }

    /// Writes a one-line summary.
    pub fn writeSummary(s: *const Session, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const h = &s.hist;
        try w.print("latency-probe: {d} samples, key-to-photon p50 {d:.2} ms, p95 {d:.2} ms, p99 {d:.2} ms, max {d:.2} ms\n", .{ h.total, ms(h.percentile(50)), ms(h.percentile(95)), ms(h.percentile(99)), ms(h.max) });
    }
};

fn ms(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

/// Puts a Linux tty in raw 8N1 mode at `baud` (USB CDC ports ignore it).
fn configureLinux(fd: std.posix.fd_t, baud: u32) !void {
    const linux = std.os.linux;
    var t = try std.posix.tcgetattr(fd);
    t.iflag = @bitCast(@as(u32, 0));
    t.oflag = @bitCast(@as(u32, 0));
    t.lflag = @bitCast(@as(u32, 0));
    t.cflag = .{ .CSIZE = .CS8, .CREAD = true, .CLOCAL = true };
    const speed: linux.speed_t = switch (baud) {
        9600 => .B9600,
        57600 => .B57600,
        230400 => .B230400,
        else => .B115200,
    };
    // The speed lives in the CBAUD bits of `cflag` (and in the speed
    // fields for the kernel's newer ioctls).
    const cbaud: u32 = 0o010017;
    t.cflag = @bitCast((@as(u32, @bitCast(t.cflag)) & ~cbaud) | (@intFromEnum(speed) & cbaud));
    t.ispeed = speed;
    t.ospeed = speed;
    t.cc[@intFromEnum(linux.V.MIN)] = 1;
    t.cc[@intFromEnum(linux.V.TIME)] = 0;
    try std.posix.tcsetattr(fd, .NOW, t);
}

const win = struct {
    const DCB = extern struct {
        DCBlength: u32,
        BaudRate: u32,
        /// fBinary is bit 0; the other bit fields stay as the driver set
        /// them, except parity checking and flow control (cleared).
        flags: u32,
        wReserved: u16,
        XonLim: u16,
        XoffLim: u16,
        ByteSize: u8,
        Parity: u8,
        StopBits: u8,
        XonChar: u8,
        XoffChar: u8,
        ErrorChar: u8,
        EofChar: u8,
        EvtChar: u8,
        wReserved1: u16,
    };
    extern "kernel32" fn GetCommState(h: std.os.windows.HANDLE, dcb: *DCB) callconv(.winapi) std.os.windows.BOOL;
    extern "kernel32" fn SetCommState(h: std.os.windows.HANDLE, dcb: *const DCB) callconv(.winapi) std.os.windows.BOOL;
};

/// Sets a Windows COM port to 8N1 at `baud`, binary, no flow control.
fn configureWindows(h: std.os.windows.HANDLE, baud: u32) !void {
    var dcb: win.DCB = std.mem.zeroes(win.DCB);
    dcb.DCBlength = @sizeOf(win.DCB);
    if (win.GetCommState(h, &dcb) == .FALSE) return error.GetCommState;
    dcb.BaudRate = baud;
    dcb.flags = 1; // fBinary; no parity check, no CTS/DSR/XON flow control
    dcb.ByteSize = 8;
    dcb.Parity = 0;
    dcb.StopBits = 0;
    if (win.SetCommState(h, &dcb) == .FALSE) return error.SetCommState;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var port: ?[]const u8 = null;
    var input: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;
    var samples: u64 = 500;
    var baud: u32 = 115200;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        const next = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, a, "--port")) port = next else if (std.mem.eql(u8, a, "--input")) input = next else if (std.mem.eql(u8, a, "--out")) out_path = next else if (std.mem.eql(u8, a, "--samples")) samples = try std.fmt.parseInt(u64, next, 10) else if (std.mem.eql(u8, a, "--baud")) baud = try std.fmt.parseInt(u32, next, 10) else {
            std.log.err("usage: latency-probe (--port PORT [--baud N] [--samples N] | --input FILE) [--out FILE]", .{});
            return 2;
        }
        i += 1;
    }

    var obuf: [512]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &obuf);
    const w = &stdout.interface;
    var s: Session = .{};
    if (input) |path| {
        const f = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer f.close(io);
        var rbuf: [4096]u8 = undefined;
        var r = f.readerStreaming(io, &rbuf);
        while (try r.interface.takeDelimiter('\n')) |line| s.add(line);
    } else if (port) |p| {
        var name_buf: [64]u8 = undefined;
        const path = if (builtin.os.tag == .windows and !std.mem.startsWith(u8, p, "\\\\")) try std.fmt.bufPrint(&name_buf, "\\\\.\\{s}", .{p}) else p;
        const f = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        defer f.close(io);
        switch (builtin.os.tag) {
            .linux => try configureLinux(f.handle, baud),
            .windows => try configureWindows(f.handle, baud),
            else => {},
        }
        try w.print("latency-probe: reading {d} samples from {s}\n", .{ samples, p });
        try w.flush();
        var rbuf: [4096]u8 = undefined;
        var r = f.readerStreaming(io, &rbuf);
        while (s.hist.total < samples) {
            const line = (try r.interface.takeDelimiter('\n')) orelse break;
            s.add(line);
        }
    } else {
        std.log.err("latency-probe: give --port or --input", .{});
        return 2;
    }
    try s.writeSummary(w);
    if (out_path) |path| {
        const f = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer f.close(io);
        var fbuf: [1024]u8 = undefined;
        var fw = f.writer(io, &fbuf);
        try s.writeJson(&fw.interface);
        try fw.interface.flush();
        try w.print("latency-probe: wrote {s}\n", .{path});
    }
    try w.flush();
    return if (s.hist.total > 0) 0 else 1;
}

test "latency-probe: parse lines" {
    try std.testing.expectEqual(Line{ .sample = .{ .seq = 3, .latency_ns = 18_500_000 } }, parseLine("S 3 1000 19500\r\n"));
    // The microsecond counter wrapped between press and edge.
    try std.testing.expectEqual(@as(u64, 20_000_000), parseLine("S 4 4294957296 10000").sample.latency_ns);
    try std.testing.expectEqualStrings("teensy 4.0, BPW34", parseLine("R teensy 4.0, BPW34").rig);
    try std.testing.expect(parseLine("S 1 2") == .other);
    try std.testing.expect(parseLine("S x 1 2") == .other);
    try std.testing.expect(parseLine("S 1 2 3 4") == .other);
    try std.testing.expect(parseLine("# comment") == .other);
    try std.testing.expect(parseLine("") == .other);
}

test "latency-probe: percentiles json" {
    var s: Session = .{};
    var it = std.mem.splitScalar(u8, @embedFile("testdata/probe_session.txt"), '\n');
    while (it.next()) |line| s.add(line);
    try std.testing.expectEqual(@as(u64, 200), s.hist.total);
    try std.testing.expectEqualStrings("rig=fixture usb_poll_us=1000 panel=fixture", s.rig());
    // Fixture latencies are 18.0 .. 26.9 ms (18 000 + i * 37 mod 9 000 us).
    try std.testing.expect(s.hist.min >= 18_000_000 and s.hist.max <= 27_000_000);
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try s.writeJson(&w);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    const r = parsed.value.object.get("results").?.array.items[0].object;
    try std.testing.expectEqualStrings("probe.key_to_photon", r.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 200), r.get("iters").?.integer);
    const p50: f64 = @floatFromInt(r.get("p50_ns").?.integer);
    try std.testing.expect(p50 > 20_000_000 and p50 < 25_000_000);
    try std.testing.expect(r.get("p99_ns").?.integer >= r.get("p50_ns").?.integer);
}
