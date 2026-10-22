//! Fuzz target `git-pktline`: arbitrary bytes through the packet reader,
//! the sideband demultiplexer and capability parsing must end in a value
//! or an error, never a crash, and stay within bounds.

const std = @import("std");
const pktline = @import("pktline.zig");
const sideband = @import("sideband.zig");
const caps_mod = @import("caps.zig");

fn ignore(_: ?*anyopaque, ev: sideband.ProgressEvent) void {
    switch (ev) {
        .progress => |p| std.debug.assert(p.phase.len > 0),
        .message => |m| std.debug.assert(m.len > 0),
    }
}

fn one(_: void, s: *std.testing.Smith) anyerror!void {
    var in: [4096]u8 = undefined;
    const input = in[0..s.slice(&in)];
    var buf: [pktline.max_pkt]u8 = undefined;

    // Plain packets, lines and capability parsing of each line.
    {
        // The packet reader asserts a buffer that holds a whole packet.
        @memcpy(buf[0..input.len], input);
        var r: std.Io.Reader = .fixed(buf[0..input.len]);
        r.buffer = &buf;
        var pr = pktline.PktReader.init(&r);
        var lines: [8][]const u8 = undefined;
        var n: usize = 0;
        while (true) {
            const p = pr.next() catch break orelse break;
            switch (p) {
                .data => |d| {
                    std.debug.assert(d.len <= pktline.max_payload);
                    const c = caps_mod.Caps.parseV0(d);
                    _ = c.has("side-band-64k");
                    _ = c.value("agent");
                    if (n < lines.len) {
                        lines[n] = d;
                        n += 1;
                    }
                },
                else => {},
            }
        }
        const v2 = caps_mod.Caps.parseV2(lines[0..n]);
        _ = v2.hasFeature("fetch", "shallow");
    }

    // The same bytes as a sideband stream.
    {
        @memcpy(buf[0..input.len], input);
        var r: std.Io.Reader = .fixed(buf[0..input.len]);
        r.buffer = &buf;
        var pr = pktline.PktReader.init(&r);
        var sb = sideband.Sideband.init(&pr, .all);
        sb.on_progress = ignore;
        var out_buf: [64]u8 = undefined;
        const rd = sb.reader(&out_buf);
        var total: usize = 0;
        while (true) {
            const n = rd.discard(.unlimited) catch break;
            total += n;
            if (n == 0) break;
        }
        std.debug.assert(total <= input.len);
    }
}

test "fuzz: git-pktline" {
    try std.testing.fuzz({}, one, .{ .corpus = @import("zg_core").testkit.fuzz.corpus(@import("zg_corpus"), "git-pktline") });
}
