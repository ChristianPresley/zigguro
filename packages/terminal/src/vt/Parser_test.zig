//! Parser tests: the full transition table against an independent reference,
//! sequence parsing, string handling, chunking and fast-path equivalence, and
//! the `vt_parser` / `fastpath_equivalence` fuzz targets.

const std = @import("std");
const testing = std.testing;
const zg_core = @import("zg_core");
const Parser = @import("Parser.zig");
const tables = @import("table.zig");
const RecordingHandler = @import("handlers.zig").RecordingHandler;
const State = tables.State;
const A = tables.ActionTag;

/// The diagram, re-encoded independently of `buildTable` as one decision per
/// (state, byte): first the "anywhere" rules, then each state's own arrows.
fn reference(s: State, b: u8, c1: bool) tables.Transition {
    const T = tables.Transition;
    const in = struct {
        fn r(x: u8, lo: u8, hi: u8) bool {
            return x >= lo and x <= hi;
        }
    }.r;
    if (b == 0x18 or b == 0x1A) return T{ .action = .execute, .next = .ground };
    if (b == 0x1B) return T{ .action = .reenter, .next = .escape };
    if (c1 and in(b, 0x80, 0x9F)) {
        return switch (b) {
            0x90 => T{ .action = .reenter, .next = .dcs_entry },
            0x9B => T{ .action = .reenter, .next = .csi_entry },
            0x9D => T{ .action = .reenter, .next = .osc_string },
            0x98, 0x9E, 0x9F => T{ .action = .reenter, .next = .sos_pm_apc_string },
            0x9C => T{ .action = .ignore, .next = .ground },
            else => T{ .action = .execute, .next = .ground },
        };
    }
    const c0 = b <= 0x17 or b == 0x19 or in(b, 0x1C, 0x1F);
    const high = b >= 0x80;
    const same = T{ .action = .ignore, .next = s };
    return switch (s) {
        .ground => if (c0) T{ .action = .execute, .next = s } else if (b == 0x7F) same else T{ .action = .print, .next = s },
        .escape => if (c0) T{ .action = .execute, .next = s } else if (b == 0x7F) same else if (high) T{ .action = .ignore, .next = .csi_ignore } else switch (b) {
            0x20...0x2F => T{ .action = .collect, .next = .escape_intermediate },
            'P' => T{ .action = .ignore, .next = .dcs_entry },
            '[' => T{ .action = .ignore, .next = .csi_entry },
            ']' => T{ .action = .ignore, .next = .osc_string },
            'X', '^', '_' => T{ .action = .ignore, .next = .sos_pm_apc_string },
            else => T{ .action = .esc_dispatch, .next = .ground },
        },
        .escape_intermediate => if (c0) T{ .action = .execute, .next = s } else if (b == 0x7F) same else if (high) T{ .action = .ignore, .next = .csi_ignore } else if (b <= 0x2F) T{ .action = .collect, .next = s } else T{ .action = .esc_dispatch, .next = .ground },
        .csi_entry => if (c0) T{ .action = .execute, .next = s } else if (b == 0x7F) same else if (high) T{ .action = .ignore, .next = .csi_ignore } else switch (b) {
            0x20...0x2F => T{ .action = .collect, .next = .csi_intermediate },
            0x30...0x3B => T{ .action = .param, .next = .csi_param }, // incl. ':' deviation
            0x3C...0x3F => T{ .action = .collect, .next = .csi_param },
            else => T{ .action = .csi_dispatch, .next = .ground },
        },
        .csi_param => if (c0) T{ .action = .execute, .next = s } else if (b == 0x7F) same else if (high) T{ .action = .ignore, .next = .csi_ignore } else switch (b) {
            0x20...0x2F => T{ .action = .collect, .next = .csi_intermediate },
            0x30...0x3B => T{ .action = .param, .next = s },
            0x3C...0x3F => T{ .action = .ignore, .next = .csi_ignore },
            else => T{ .action = .csi_dispatch, .next = .ground },
        },
        .csi_intermediate => if (c0) T{ .action = .execute, .next = s } else if (b == 0x7F) same else if (high) T{ .action = .ignore, .next = .csi_ignore } else switch (b) {
            0x20...0x2F => T{ .action = .collect, .next = s },
            0x30...0x3F => T{ .action = .ignore, .next = .csi_ignore },
            else => T{ .action = .csi_dispatch, .next = .ground },
        },
        .csi_ignore => if (c0) T{ .action = .execute, .next = s } else if (in(b, 0x40, 0x7E)) T{ .action = .ignore, .next = .ground } else same,
        .dcs_entry => if (c0 or b == 0x7F) same else if (high) T{ .action = .ignore, .next = .dcs_ignore } else switch (b) {
            0x20...0x2F => T{ .action = .collect, .next = .dcs_intermediate },
            0x3A => T{ .action = .ignore, .next = .dcs_ignore },
            0x30...0x39, 0x3B => T{ .action = .param, .next = .dcs_param },
            0x3C...0x3F => T{ .action = .collect, .next = .dcs_param },
            else => T{ .action = .hook, .next = .dcs_passthrough },
        },
        .dcs_param => if (c0 or b == 0x7F) same else if (high) T{ .action = .ignore, .next = .dcs_ignore } else switch (b) {
            0x20...0x2F => T{ .action = .collect, .next = .dcs_intermediate },
            0x30...0x39, 0x3B => T{ .action = .param, .next = s },
            0x3A, 0x3C...0x3F => T{ .action = .ignore, .next = .dcs_ignore },
            else => T{ .action = .hook, .next = .dcs_passthrough },
        },
        .dcs_intermediate => if (c0 or b == 0x7F) same else if (high) T{ .action = .ignore, .next = .dcs_ignore } else switch (b) {
            0x20...0x2F => T{ .action = .collect, .next = s },
            0x30...0x3F => T{ .action = .ignore, .next = .dcs_ignore },
            else => T{ .action = .hook, .next = .dcs_passthrough },
        },
        .dcs_passthrough => if (b == 0x7F) same else T{ .action = .put, .next = s },
        .dcs_ignore => same,
        .osc_string => if (b == 0x07) T{ .action = .ignore, .next = .ground } else if (b >= 0x20) T{ .action = .put, .next = s } else same,
        .sos_pm_apc_string => if (b >= 0x20) T{ .action = .put, .next = s } else same,
    };
}

test "every (state, byte) transition matches reference" {
    for ([_]bool{ false, true }) |c1| {
        const tab = if (c1) &tables.table_c1 else &tables.table;
        for (0..14) |si| {
            const s: State = @enumFromInt(si);
            for (0..256) |bi| {
                const b: u8 = @intCast(bi);
                const want = reference(s, b, c1);
                const got = tab[si][bi];
                if (want.action != got.action or want.next != got.next) {
                    std.debug.print("c1={} state={t} byte=0x{x:0>2}: want {t}->{t}, got {t}->{t}\n", .{ c1, s, b, want.action, want.next, got.action, got.next });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}

fn run(input: []const u8, o: Parser.Options) ![]u8 {
    var p: Parser = .init(testing.allocator, o);
    defer p.deinit();
    var h: RecordingHandler = .init(testing.allocator);
    defer h.deinit();
    p.feed(input, &h);
    return testing.allocator.dupe(u8, h.text());
}

fn expectLog(input: []const u8, want: []const u8) !void {
    const got = try run(input, .{});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "CSI params" {
    try expectLog("\x1b[1;2;3m", "csi 1;2;3m\n");
    try expectLog("\x1b[;5H", "csi ;5H\n");
    try expectLog("\x1b[38:2::10:20:30m", "csi 38:2::10:20:30m\n");
    try expectLog("\x1b[999999A", "csi 65535A\n");
    try expectLog("\x1b[m", "csi m\n");
    var buf: [200]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeAll("\x1b[");
    for (0..40) |i| try w.print("{d};", .{i});
    try w.writeAll("m");
    const got = try run(w.buffered(), .{});
    defer testing.allocator.free(got);
    try testing.expect(std.mem.endsWith(u8, got, "29;30;31m overflow\n"));
    var p: Parser = .init(testing.allocator, .{});
    defer p.deinit();
    var probe: struct {
        csi: Parser.Csi = .{},
        pub fn csiDispatch(s: *@This(), c: *const Parser.Csi) void {
            s.csi = c.*;
        }
        pub fn printAscii(_: *@This(), _: []const u8) void {}
        pub fn printCodepoints(_: *@This(), _: []const u21) void {}
        pub fn execute(_: *@This(), _: u8) void {}
        pub fn escDispatch(_: *@This(), _: Parser.Esc) void {}
        pub fn oscDispatch(_: *@This(), _: []const u8, _: Parser.StringTerm) void {}
        pub fn dcsHook(_: *@This(), _: *const Parser.Csi) bool {
            return false;
        }
        pub fn dcsPut(_: *@This(), _: []const u8) void {}
        pub fn dcsUnhook(_: *@This()) void {}
        pub fn apcStart(_: *@This()) bool {
            return false;
        }
        pub fn apcPut(_: *@This(), _: []const u8) void {}
        pub fn apcEnd(_: *@This()) void {}
    } = .{};
    p.feed("\x1b[38:2::10:20:30m", &probe);
    try testing.expectEqual(@as(u8, 6), probe.csi.count);
    try testing.expect(probe.csi.isSub(1) and probe.csi.isSub(5) and !probe.csi.isSub(0));
    try testing.expectEqual(@as(u16, 99), probe.csi.get(2, 99));
    try testing.expectEqual(@as(u16, 30), probe.csi.get(5, 0));
}

test "private markers and intermediates" {
    try expectLog("\x1b[?1049h", "csi ?1049h\n");
    try expectLog("\x1b[>0q", "csi >0q\n");
    try expectLog("\x1b[ q", "csi  q\n");
    try expectLog("\x1b[!p", "csi !p\n");
    try expectLog("\x1b[1 !\"pX", "print X\n"); // 3 intermediates → ignored
    try expectLog("\x1b[1?hX", "print X\n"); // private marker after a param → csi_ignore
    try expectLog("\x1b(B\x1b#8", "esc (B\nesc #8\n");
    try expectLog("\x1b ##8X", "print X\n");
}

test "C0 inside CSI is executed without leaving the sequence" {
    try expectLog("\x1b[1\n;2H", "exec 0x0a\ncsi 1;2H\n");
}

test "OSC BEL vs ST terminators recorded" {
    try expectLog("\x1b]0;title\x07", "osc bel 0;title\n");
    try expectLog("\x1b]2;t\x1b\\x", "osc st 2;t\nprint x\n");
    try expectLog("\x1b]8;;http://a\x7f\x1b\\", "osc st 8;;http://a\\x7f\n");
}

test "ESC inside OSC not followed by backslash terminates and restarts escape" {
    try expectLog("\x1b]0;abc\x1b[1mX", "osc st 0;abc\ncsi 1m\nprint X\n");
    try expectLog("\x1b]0;abc\x1b\x1b\\", "osc st 0;abc\nesc \\x5c\n");
}

test "OSC cap discard" {
    var big: [100]u8 = @splat('a');
    big[0] = '0';
    big[1] = ';';
    const input = try std.mem.concat(testing.allocator, u8, &.{ "\x1b]", &big, "\x07ok" });
    defer testing.allocator.free(input);
    const got = try run(input, .{ .osc_max = 64 });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("print ok\n", got);
}

test "OSC 52 raised cap" {
    var big: [100]u8 = @splat('Q');
    const input = try std.mem.concat(testing.allocator, u8, &.{ "\x1b]52;c;", &big, "\x07" });
    defer testing.allocator.free(input);
    const got = try run(input, .{ .osc_max = 64, .osc52_max = 200 });
    defer testing.allocator.free(got);
    try testing.expect(std.mem.startsWith(u8, got, "osc bel 52;c;QQQ"));
    const got2 = try run(input, .{ .osc_max = 64, .osc52_max = 80 });
    defer testing.allocator.free(got2);
    try testing.expectEqualStrings("", got2);
}

const SliceCounter = struct {
    puts: usize = 0,
    bytes: usize = 0,
    unhooks: usize = 0,
    max_slice: usize = 0,
    hooked: ?u8 = null,
    pub fn printAscii(_: *@This(), _: []const u8) void {}
    pub fn printCodepoints(_: *@This(), _: []const u21) void {}
    pub fn execute(_: *@This(), _: u8) void {}
    pub fn escDispatch(_: *@This(), _: Parser.Esc) void {}
    pub fn csiDispatch(_: *@This(), _: *const Parser.Csi) void {}
    pub fn oscDispatch(_: *@This(), _: []const u8, _: Parser.StringTerm) void {}
    pub fn dcsHook(s: *@This(), c: *const Parser.Csi) bool {
        s.hooked = c.final;
        return true;
    }
    pub fn dcsPut(s: *@This(), b: []const u8) void {
        s.puts += 1;
        s.bytes += b.len;
        s.max_slice = @max(s.max_slice, b.len);
    }
    pub fn dcsUnhook(s: *@This()) void {
        s.unhooks += 1;
    }
    pub fn apcStart(_: *@This()) bool {
        return true;
    }
    pub fn apcPut(_: *@This(), _: []const u8) void {}
    pub fn apcEnd(_: *@This()) void {}
};

test "DCS hook/put/unhook streaming, 1 MiB payload in 4 KiB slices" {
    const payload = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(payload);
    @memset(payload, '#');
    var p: Parser = .init(testing.allocator, .{ .dcs_max = 2 << 20 });
    defer p.deinit();
    var h: SliceCounter = .{};
    p.feed("\x1bP1;2q", &h);
    p.feed(payload, &h);
    p.feed("\x1b\\", &h);
    try testing.expectEqual(@as(?u8, 'q'), h.hooked);
    try testing.expectEqual(@as(usize, 1 << 20), h.bytes);
    try testing.expect(h.max_slice <= Parser.put_slice_max);
    try testing.expectEqual(@as(usize, 1), h.unhooks);
    try testing.expectEqual(State.ground, p.state);

    // Over the cap: unhooked early, the rest discarded until ST.
    var q: Parser = .init(testing.allocator, .{ .dcs_max = 1000 });
    defer q.deinit();
    var h2: SliceCounter = .{};
    q.feed("\x1bPq", &h2);
    q.feed(payload[0..5000], &h2);
    try testing.expectEqual(@as(usize, 1000), h2.bytes);
    try testing.expectEqual(@as(usize, 1), h2.unhooks);
    q.feed("\x1b\\", &h2);
    try testing.expectEqual(@as(usize, 1), h2.unhooks);
}

test "DCS hook rejected → ignore until ST" {
    var p: Parser = .init(testing.allocator, .{});
    defer p.deinit();
    var h: RecordingHandler = .init(testing.allocator);
    defer h.deinit();
    h.reject_dcs = true;
    p.feed("\x1bP$qm\x1b\\after", &h);
    try testing.expectEqualStrings("dcs_hook $q\nprint after\n", h.text());
    try expectLog("\x1bP$qm\x1b\\", "dcs_hook $q\ndcs_put m\ndcs_unhook\n");
}

test "APC forwarded, SOS/PM swallowed" {
    try expectLog("\x1b_Gf=24;AAAA\x1b\\", "apc_start\napc_put Gf=24;AAAA\napc_end\n");
    try expectLog("\x1bXsos\x1b\\\x1b^pm\x1b\\z", "print z\n");
}

test "CAN/SUB abort sequences mid-CSI" {
    try expectLog("\x1b[1;2\x18X", "exec 0x18\nprint X\n");
    try expectLog("\x1b[1\x1aX", "exec 0x1a\nprint X\n");
    try expectLog("\x1b]0;t\x18X", "exec 0x18\nprint X\n");
}

test "8-bit C1 only when enabled" {
    const a = try run("\x9b1m", .{});
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("print \u{FFFD}1m\n", a);
    const b = try run("\x9b1m\x9d0;t\x9c\x85", .{ .c1_8bit = true });
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("csi 1m\nosc st 0;t\nexec 0x85\n", b);
}

test "UTF-8 and controls interleave" {
    try expectLog("a\xc3\xa9b\r\n日\x1b[m", "print aéb\nexec 0x0d\nexec 0x0a\nprint 日\ncsi m\n");
    try expectLog("\xe6\x97\x1b[m", "print \u{FFFD}\ncsi m\n");
}

/// Seed corpus for split-feed and equivalence properties.
const seeds = [_][]const u8{
    "hello world\r\n\x1b[1;31mred\x1b[0m \x1b[38:2::1:2:3mtc\x1b[m",
    "\x1b]0;title\x07\x1b]8;id=1;http://x\x1b\\link\x1b]8;;\x1b\\",
    "日本語 🧑‍🌾 \xf0\x9f\x98 broken \xed\xa0\x80 \x1b[?1049h\x1b[2J\x1b[H",
    "\x1bP$qm\x1b\\\x1b_Ga=T;AAAA\x1b\\\x1bXsos\x1b\\\x1b[>1u\x1b[?2026h",
    "\x1b(0lqqk\x1b(B\x1b7\x1b8\x1b#8\x1b[5;10r\x1b[?6h\x1b[3;3H\x18\x1b[1\x1aZ",
    "\x7f\x00\x05\x1b[1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17;18;19;20;21;22;23;24;25;26;27;28;29;30;31;32;33;34m",
};

test "split feed equivalence" {
    var prng: std.Random.DefaultPrng = .init(42);
    const r = prng.random();
    for (seeds) |s| {
        const whole = try run(s, .{});
        defer testing.allocator.free(whole);
        for (0..50) |_| {
            var p: Parser = .init(testing.allocator, .{});
            defer p.deinit();
            var h: RecordingHandler = .init(testing.allocator);
            defer h.deinit();
            var i: usize = 0;
            while (i < s.len) {
                const n = r.uintAtMost(usize, s.len - i);
                p.feed(s[i..][0..n], &h);
                i += n;
            }
            try testing.expectEqualStrings(whole, h.text());
        }
    }
}

test "fast path equals slow path on seeds" {
    for (seeds) |s| {
        const fast = try run(s, .{});
        defer testing.allocator.free(fast);
        var p: Parser = .init(testing.allocator, .{});
        defer p.deinit();
        var h: RecordingHandler = .init(testing.allocator);
        defer h.deinit();
        p.feedSlow(s, &h);
        try testing.expectEqualStrings(fast, h.text());
    }
}

test "no allocations in feed after warm-up" {
    var p: Parser = .init(testing.allocator, .{});
    defer p.deinit();
    var h: @import("handlers.zig").NullHandler = .{};
    for (seeds) |s| p.feed(s, &h);
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    p.gpa = failing.allocator();
    for (0..3) |_| for (seeds) |s| p.feed(s, &h);
    try testing.expectEqual(@as(usize, 0), failing.allocations);
    p.gpa = testing.allocator;
}

fn fuzzParser(_: void, s: *std.testing.Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const input = buf[0..s.slice(&buf)];
    var chunks: [8][]const u8 = undefined;
    const parts = zg_core.testkit.fuzz.chunked(s, input, 8, &chunks);
    const o: Parser.Options = .{ .osc_max = 512, .osc52_max = 1024, .dcs_max = 1024, .apc_max = 1024, .c1_8bit = s.value(bool) };
    var p: Parser = .init(testing.allocator, o);
    defer p.deinit();
    var h: RecordingHandler = .init(testing.allocator);
    defer h.deinit();
    for (parts) |c| p.feed(c, &h);
    try testing.expect(p.osc.capacity <= o.osc52_max + 64 * 1024);
}

test "fuzz: vt_parser" {
    try std.testing.fuzz({}, fuzzParser, .{ .corpus = zg_core.testkit.fuzz.corpus(@import("zg_corpus"), "vt_parser") });
}

fn fuzzEquivalence(_: void, s: *std.testing.Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const input = buf[0..s.slice(&buf)];
    var chunks: [8][]const u8 = undefined;
    const parts = zg_core.testkit.fuzz.chunked(s, input, 8, &chunks);
    const o: Parser.Options = .{ .osc_max = 512, .osc52_max = 1024, .dcs_max = 1024, .apc_max = 1024 };
    var fast: Parser = .init(testing.allocator, o);
    defer fast.deinit();
    var slow: Parser = .init(testing.allocator, o);
    defer slow.deinit();
    var hf: RecordingHandler = .init(testing.allocator);
    defer hf.deinit();
    var hs: RecordingHandler = .init(testing.allocator);
    defer hs.deinit();
    for (parts) |c| fast.feed(c, &hf);
    slow.feedSlow(input, &hs);
    try testing.expectEqualStrings(hs.text(), hf.text());
}

test "fuzz: fastpath_equivalence" {
    try std.testing.fuzz({}, fuzzEquivalence, .{ .corpus = zg_core.testkit.fuzz.corpus(@import("zg_corpus"), "vt_parser") });
}
