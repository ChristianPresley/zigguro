//! pkt-line, sideband and capability tests (E09.F08.S01.T01).

const std = @import("std");
const pktline = @import("pktline.zig");
const sideband = @import("sideband.zig");
const caps_mod = @import("caps.zig");
const Pkt = pktline.Pkt;
const PktReader = pktline.PktReader;
const PktWriter = pktline.PktWriter;
const Caps = caps_mod.Caps;
const t = std.testing;

/// A reader over `bytes` with a buffer big enough for any packet. Uses
/// `std.Io.Reader.fixed` over a copy so `fill` can rebase.
const Src = struct {
    buf: [pktline.max_pkt + 64]u8 = undefined,
    inner: std.Io.Reader,
    stream: Stream,

    /// Feeds `bytes` a few at a time, so packets straddle reads.
    const Stream = struct {
        bytes: []const u8,
        step: usize,
    };

    fn init(s: *Src, bytes: []const u8, step: usize) *std.Io.Reader {
        s.stream = .{ .bytes = bytes, .step = step };
        s.inner = .{ .vtable = &.{ .stream = streamFn }, .buffer = &s.buf, .seek = 0, .end = 0 };
        return &s.inner;
    }

    fn streamFn(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const s: *Src = @alignCast(@fieldParentPtr("inner", r));
        if (s.stream.bytes.len == 0) return error.EndOfStream;
        const n = try w.write(limit.sliceConst(s.stream.bytes[0..@min(s.stream.step, s.stream.bytes.len)]));
        s.stream.bytes = s.stream.bytes[n..];
        return n;
    }
};

fn expectData(pr: *PktReader, want: []const u8) !void {
    const p = (try pr.next()).?;
    try t.expectEqualStrings(want, p.data);
}

test "pktline: doc examples" {
    for ([_]usize{ 1, 3, 1 << 20 }) |step| {
        var src: Src = undefined;
        var pr = PktReader.init(src.init("0006a\n0005a000bfoobar\n0004", step));
        try expectData(&pr, "a\n");
        try expectData(&pr, "a");
        try expectData(&pr, "foobar\n");
        try expectData(&pr, "");
        try t.expectEqual(@as(?Pkt, null), try pr.next());
    }
    var src: Src = undefined;
    var pr = PktReader.init(src.init("0006a\n0005b0000", 2));
    try t.expectEqualStrings("a", (try pr.nextLine()).?);
    try t.expectEqualStrings("b", (try pr.nextLine()).?);
    try t.expectEqual(@as(?[]const u8, null), try pr.nextLine());
    try t.expectError(error.UnexpectedEof, pr.nextLine());

    // Uppercase lengths are accepted.
    var src2: Src = undefined;
    var pr2 = PktReader.init(src2.init("000Bfoobar\n", 64));
    try expectData(&pr2, "foobar\n");
}

test "pktline: flush/delim/response-end" {
    var src: Src = undefined;
    var pr = PktReader.init(src.init("000000010009\x00\x01\x02\xff\n0002", 5));
    try t.expectEqual(Pkt.flush, (try pr.next()).?);
    try t.expectEqual(Pkt.delim, (try pr.next()).?);
    try expectData(&pr, "\x00\x01\x02\xff\n");
    try t.expectEqual(Pkt.response_end, (try pr.next()).?);
    try t.expectEqual(@as(?Pkt, null), try pr.next());

    var s2: Src = undefined;
    var pr2 = PktReader.init(s2.init("0001", 64));
    try t.expectError(error.UnexpectedPkt, pr2.nextLine());
}

test "pktline: too long rejected" {
    var src: Src = undefined;
    var pr = PktReader.init(src.init("fff1", 64));
    try t.expectError(error.PktTooLong, pr.next());

    var s2: Src = undefined;
    var pr2 = PktReader.init(s2.init("0003", 64));
    try t.expectError(error.InvalidPktLength, pr2.next());
    var s3: Src = undefined;
    var pr3 = PktReader.init(s3.init("00g0", 64));
    try t.expectError(error.InvalidPktLength, pr3.next());
    var s4: Src = undefined;
    var pr4 = PktReader.init(s4.init("0009abc", 64));
    try t.expectError(error.TruncatedPkt, pr4.next());
    var s5: Src = undefined;
    var pr5 = PktReader.init(s5.init("00", 64));
    try t.expectError(error.TruncatedPkt, pr5.next());

    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    const pw = PktWriter.init(&out.writer);
    var big: [pktline.max_payload + 1]u8 = @splat('x');
    try t.expectError(error.PktTooLong, pw.data(&big));
    try pw.data(big[0..pktline.max_payload]);
    try t.expectEqualStrings("fff0", out.written()[0..4]);

    // The largest packet reads back.
    var s6: Src = undefined;
    var pr6 = PktReader.init(s6.init(out.written(), 4096));
    try expectData(&pr6, big[0..pktline.max_payload]);
}

test "pktline: writer round trip" {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    defer out.deinit();
    const pw = PktWriter.init(&out.writer);
    try pw.line("want {s}", .{"0123"});
    try pw.data("");
    try pw.delim();
    try pw.data("raw");
    try pw.flush();
    try pw.responseEnd();
    try t.expectEqualStrings("000ewant 0123\n00010007raw00000002", out.written());

    out.clearRetainingCapacity();
    var payload: [pktline.max_payload * 2 + 10]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i);
    try pw.dataChunked(&payload);
    var src: Src = undefined;
    var pr = PktReader.init(src.init(out.written(), 777));
    try expectData(&pr, payload[0..pktline.max_payload]);
    try expectData(&pr, payload[pktline.max_payload .. 2 * pktline.max_payload]);
    try expectData(&pr, payload[2 * pktline.max_payload ..]);
    try t.expectEqual(@as(?Pkt, null), try pr.next());
}

const Events = struct {
    list: std.ArrayList(u8) = .empty,

    fn record(ctx: ?*anyopaque, ev: sideband.ProgressEvent) void {
        const e: *Events = @ptrCast(@alignCast(ctx.?));
        var w: std.Io.Writer.Allocating = .fromArrayList(t.allocator, &e.list);
        defer e.list = w.toArrayList();
        switch (ev) {
            .progress => |p| w.writer.print("[{s} {d}/{?d}{s}]", .{ p.phase, p.done, p.total, if (p.finished) " done" else "" }) catch unreachable,
            .message => |m| w.writer.print("<{s}>", .{m}) catch unreachable,
        }
    }
};

test "sideband: interleaved bands to sink + progress" {
    var stream: std.Io.Writer.Allocating = .init(t.allocator);
    defer stream.deinit();
    const pw = PktWriter.init(&stream.writer);
    var pack: [3000]u8 = undefined;
    for (&pack, 0..) |*b, i| b.* = @truncate(i *% 7);
    try pw.band(2, "Enumerating objects: 5, done.\n", 1000);
    try pw.band(2, "Receiving objects:  40% (2/5)\rReceiving obj", 1000);
    try pw.band(1, pack[0..1500], 1000);
    try pw.band(2, "ects: 100% (5/5), 1.20 KiB | 1.20 MiB/s, done.\n", 1000);
    try pw.band(2, "", 1000); // keepalive
    try pw.band(1, pack[1500..], 1000);
    try pw.band(2, "hello from the hook\n", 1000);
    try pw.flush();
    try pw.line("after", .{});

    var src: Src = undefined;
    var pr = PktReader.init(src.init(stream.written(), 333));
    var ev: Events = .{};
    defer ev.list.deinit(t.allocator);
    var sb = sideband.Sideband.init(&pr, .band);
    sb.on_progress = Events.record;
    sb.progress_ctx = &ev;
    var buf: [256]u8 = undefined;
    const r = sb.reader(&buf);
    var got: std.Io.Writer.Allocating = .init(t.allocator);
    defer got.deinit();
    _ = try r.streamRemaining(&got.writer);
    try t.expectEqualSlices(u8, &pack, got.written());
    try t.expectEqualStrings(
        "[Enumerating objects 5/null done][Receiving objects 2/5][Receiving objects 5/5 done]<hello from the hook>",
        ev.list.items,
    );
    try t.expectEqual(Pkt.flush, sb.end.?);
    // The packet reader carries on after the sideband section.
    try t.expectEqualStrings("after", (try pr.nextLine()).?);
}

test "sideband: band 3 error" {
    var stream: std.Io.Writer.Allocating = .init(t.allocator);
    defer stream.deinit();
    const pw = PktWriter.init(&stream.writer);
    try pw.band(1, "PACK", 65520);
    try pw.band(3, "upload-pack: not our ref 1234\n", 65520);
    try pw.band(1, "never", 65520);
    var src: Src = undefined;
    var pr = PktReader.init(src.init(stream.written(), 64));
    var sb = sideband.Sideband.init(&pr, .band64k);
    var buf: [64]u8 = undefined;
    const r = sb.reader(&buf);
    var got: std.Io.Writer.Allocating = .init(t.allocator);
    defer got.deinit();
    try t.expectError(error.ReadFailed, r.streamRemaining(&got.writer));
    try t.expectEqualStrings("PACK", got.written());
    try t.expectEqual(@as(?sideband.Error, error.RemoteError), sb.err);
    try t.expectEqualStrings("upload-pack: not our ref 1234", sb.remoteMessage());

    // A packet without a band byte is malformed.
    var s2: Src = undefined;
    var pr2 = PktReader.init(s2.init("0005\x07", 64));
    var sb2 = sideband.Sideband.init(&pr2, .all);
    try t.expectError(error.BadSideband, sb2.nextData());
}

test "sideband: sideband-all ends at a delimiter" {
    var src: Src = undefined;
    var pr = PktReader.init(src.init("0005\x020009\x01abcd00010000", 64));
    var sb = sideband.Sideband.init(&pr, .all);
    try t.expectEqualStrings("abcd", (try sb.nextData()).?);
    try t.expectEqual(@as(?[]const u8, null), try sb.nextData());
    try t.expectEqual(Pkt.delim, sb.end.?);
}

test "sideband: progress parsing" {
    const P = sideband.Progress;
    const cases = [_]struct { []const u8, ?P }{
        .{ "Counting objects: 1234", .{ .phase = "Counting objects", .done = 1234 } },
        .{ "Enumerating objects: 5, done.", .{ .phase = "Enumerating objects", .done = 5, .finished = true } },
        .{ "Receiving objects:  45% (450/1000), 1.2 MiB | 2 MiB/s", .{ .phase = "Receiving objects", .done = 450, .total = 1000 } },
        .{ "Resolving deltas: 100% (7/7), done.", .{ .phase = "Resolving deltas", .done = 7, .total = 7, .finished = true } },
        .{ "Total 5 (delta 0), reused 0 (delta 0), pack-reused 0", null },
        .{ "error: something", null },
        .{ "x: 12abc", null },
        .{ "", null },
    };
    for (cases) |c| {
        const got = sideband.parseProgress(c[0]);
        if (c[1]) |want| {
            const g = got.?;
            try t.expectEqualStrings(want.phase, g.phase);
            try t.expectEqual(want.done, g.done);
            try t.expectEqual(want.total, g.total);
            try t.expectEqual(want.finished, g.finished);
        } else try t.expectEqual(@as(?P, null), got);
    }
}

test "caps: v0 NUL-separated, v2 key=value" {
    const line = "7217a7c7e582c46cec22a130adf4b9d7d950fba0 HEAD\x00multi_ack thin-pack side-band side-band-64k ofs-delta shallow no-progress include-tag multi_ack_detailed symref=HEAD:refs/heads/main symref=refs/remotes/origin/HEAD:refs/remotes/origin/main object-format=sha1 agent=git/2.43.0\n";
    const c = Caps.parseV0(line);
    try t.expect(c.has("side-band-64k"));
    try t.expect(c.has("thin-pack"));
    try t.expect(!c.has("side"));
    try t.expect(!c.has("filter"));
    try t.expectEqualStrings("git/2.43.0", c.value("agent").?);
    try t.expectEqualStrings("sha1", c.value("object-format").?);
    try t.expectEqual(@as(?[]const u8, null), c.value("ofs-delta"));
    try t.expectEqualStrings("7217a7c7e582c46cec22a130adf4b9d7d950fba0 HEAD", Caps.refPartV0(line));
    var symrefs: std.ArrayList([]const u8) = .empty;
    defer symrefs.deinit(t.allocator);
    c.eachValue("symref", &symrefs, struct {
        fn add(l: *std.ArrayList([]const u8), v: []const u8) void {
            l.append(t.allocator, v) catch unreachable;
        }
    }.add);
    try t.expectEqual(@as(usize, 2), symrefs.items.len);
    try t.expectEqualStrings("HEAD:refs/heads/main", symrefs.items[0]);
    try t.expect(!Caps.parseV0("abc HEAD").has("abc"));

    const v2 = Caps.parseV2(&.{ "version 2\n", "agent=git/2.43.0\n", "ls-refs=unborn\n", "fetch=shallow wait-for-done filter\n", "server-option\n", "object-format=sha256\n", "object-info" });
    try t.expect(v2.has("server-option"));
    try t.expect(v2.has("object-info"));
    try t.expect(!v2.has("version 2"));
    try t.expectEqualStrings("sha256", v2.value("object-format").?);
    try t.expect(v2.hasFeature("fetch", "wait-for-done"));
    try t.expect(v2.hasFeature("fetch", "filter"));
    try t.expect(!v2.hasFeature("fetch", "wait"));
    try t.expect(v2.hasFeature("ls-refs", "unborn"));
    try t.expect(!v2.hasFeature("server-option", "x"));
    var n: usize = 0;
    var it = v2.iterator();
    while (it.next()) |_| n += 1;
    try t.expectEqual(@as(usize, 6), n);
}
