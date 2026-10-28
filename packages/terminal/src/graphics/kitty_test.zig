const std = @import("std");
const testing = std.testing;
const gpa = testing.allocator;
const Terminal = @import("../term/Terminal.zig");
const kitty = @import("kitty.zig");

fn term(o: Terminal.Options) !Terminal {
    var opts = o;
    if (opts.cols == 80) opts.cols = 20;
    if (opts.rows == 24) opts.rows = 10;
    var t: Terminal = try .init(gpa, opts);
    t.cell_px = .{ .w = 10, .h = 20 };
    return t;
}

/// `APC G <ctl> ; <base64 of data> ST`.
fn apc(buf: []u8, ctl: []const u8, data: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("\x1b_G{s}", .{ctl}) catch unreachable;
    if (data.len > 0) {
        w.writeByte(';') catch unreachable;
        var enc: [16384]u8 = undefined;
        w.writeAll(std.base64.standard.Encoder.encode(&enc, data)) catch unreachable;
    }
    w.writeAll("\x1b\\") catch unreachable;
    return w.buffered();
}

fn replies(t: *Terminal) []const u8 {
    return t.replies.items;
}

const red2x2 = [_]u8{ 255, 0, 0, 255 } ** 4;

test "kitty: parseControl reads keys, ignores unknown ones and bad numbers" {
    const c = kitty.parseControl("a=T,f=100,i=31,s=10,v=20,c=4,r=2,z=-5,C=1,q=2,X=3,Y=4,o=z,m=1,U=1,d=I,zz=9,s=x");
    try testing.expectEqual(@as(u8, 'T'), c.action);
    try testing.expectEqual(@as(u16, 100), c.format);
    try testing.expectEqual(@as(u32, 31), c.id);
    try testing.expectEqual(@as(u32, 0), c.width); // s=x came last
    try testing.expectEqual(@as(u32, 20), c.height);
    try testing.expectEqual(@as(u32, 4), c.cols);
    try testing.expectEqual(@as(u32, 2), c.rows);
    try testing.expectEqual(@as(i32, -5), c.z);
    try testing.expectEqual(@as(u8, 1), c.cursor_policy);
    try testing.expectEqual(@as(u2, 2), c.quiet);
    try testing.expectEqual(@as(u8, 'z'), c.compression);
    try testing.expect(c.more and c.unicode_placeholder);
    try testing.expectEqual(@as(u8, 'I'), c.delete);
    const d = kitty.parseControl("");
    try testing.expectEqual(@as(u8, 't'), d.action);
    try testing.expectEqual(@as(u16, 32), d.format);
}

test "kitty: transmit and place RGBA, reply OK, cursor moves past the image" {
    var t = try term(.{});
    defer t.deinit();
    var buf: [16384]u8 = undefined;
    // 20x40 px = 2x2 cells.
    var px: [20 * 40 * 4]u8 = undefined;
    @memset(&px, 128);
    t.feed("ab");
    t.feed(apc(&buf, "a=T,f=32,s=20,v=40,i=7", &px));
    try testing.expectEqualStrings("\x1b_Gi=7;OK\x1b\\", replies(&t));
    const img = t.images.get(7).?;
    try testing.expectEqual(@as(u32, 20), img.pixels.w);
    // Premultiplied: 128 * 128 / 255.
    try testing.expectEqual(@as(u8, 64), img.pixels.rgba[0]);
    try testing.expectEqual(@as(usize, 1), t.images.placements.items.len);
    const p = t.images.placements.items[0];
    try testing.expectEqual(@as(u16, 2), p.cols);
    try testing.expectEqual(@as(u16, 2), p.rows);
    try testing.expectEqual(@as(u16, 2), p.pin.pin.x);
    try testing.expectEqual(@as(u16, 1), t.primary.cursor.y);
    try testing.expectEqual(@as(u16, 4), t.primary.cursor.x);
}

test "kitty: C=1 keeps the cursor; no reply without i or I; q=1 and q=2" {
    var t = try term(.{});
    defer t.deinit();
    var buf: [256]u8 = undefined;
    t.feed(apc(&buf, "a=T,f=32,s=2,v=2,C=1", &red2x2));
    try testing.expectEqual(@as(usize, 0), replies(&t).len);
    try testing.expectEqual(@as(u16, 0), t.primary.cursor.x);
    try testing.expectEqual(@as(usize, 1), t.images.images.count());
    t.feed(apc(&buf, "a=t,f=32,s=2,v=2,i=3,q=1", &red2x2));
    try testing.expectEqual(@as(usize, 0), replies(&t).len);
    t.feed(apc(&buf, "a=p,i=99,q=1", ""));
    try testing.expectEqualStrings("\x1b_Gi=99;ENOENT:no image with that id or number\x1b\\", replies(&t));
    t.replies.clearRetainingCapacity();
    t.feed(apc(&buf, "a=p,i=99,q=2", ""));
    try testing.expectEqual(@as(usize, 0), replies(&t).len);
}

test "kitty: chunked transfer with a misaligned, unpadded last chunk" {
    var t = try term(.{});
    defer t.deinit();
    const data = [_]u8{ 1, 2, 3, 255 } ** 3; // 3x1 px
    var enc: [64]u8 = undefined;
    const b64 = std.base64.standard_no_pad.Encoder.encode(&enc, &data); // 16 chars
    var buf: [256]u8 = undefined;
    // Chunks of 6, 5 and 5 characters.
    t.feed(std.fmt.bufPrint(&buf, "\x1b_Ga=t,f=32,s=3,v=1,i=5,m=1;{s}\x1b\\", .{b64[0..6]}) catch unreachable);
    try testing.expect(t.images.get(5) == null);
    t.feed(std.fmt.bufPrint(&buf, "\x1b_Gm=1;{s}\x1b\\", .{b64[6..11]}) catch unreachable);
    t.feed(std.fmt.bufPrint(&buf, "\x1b_Gm=0;{s}\x1b\\", .{b64[11..]}) catch unreachable);
    try testing.expectEqualStrings("\x1b_Gi=5;OK\x1b\\", replies(&t));
    try testing.expectEqual(@as(u32, 3), t.images.get(5).?.pixels.w);
    try testing.expectEqual(@as(u8, 3), t.images.get(5).?.pixels.rgba[2]);
}

test "kitty: bad base64, wrong sizes and unknown formats are errors" {
    var t = try term(.{});
    defer t.deinit();
    t.feed("\x1b_Ga=t,f=32,s=1,v=1,i=1;!!!!\x1b\\");
    try testing.expect(std.mem.indexOf(u8, replies(&t), "EINVAL:invalid base64") != null);
    t.replies.clearRetainingCapacity();
    var buf: [256]u8 = undefined;
    t.feed(apc(&buf, "a=t,f=32,s=4,v=4,i=2", &red2x2));
    try testing.expect(std.mem.indexOf(u8, replies(&t), "i=2;EINVAL:the data does not match") != null);
    t.replies.clearRetainingCapacity();
    t.feed(apc(&buf, "a=t,f=100,i=4", "not a png"));
    try testing.expect(std.mem.indexOf(u8, replies(&t), "i=4;EBADPNG") != null);
    try testing.expectEqual(@as(usize, 0), t.images.images.count());
}

test "kitty: a=q answers before a following DA1 and stores nothing" {
    var t = try term(.{});
    defer t.deinit();
    var buf: [256]u8 = undefined;
    t.feed(apc(&buf, "a=q,f=32,s=2,v=2,i=31", &red2x2));
    t.feed("\x1b[c");
    try testing.expect(std.mem.startsWith(u8, replies(&t), "\x1b_Gi=31;OK\x1b\\\x1b[?"));
    try testing.expectEqual(@as(usize, 0), t.images.images.count());
}

test "kitty: I numbers get ids and replies name both; p places by number" {
    var t = try term(.{});
    defer t.deinit();
    var buf: [256]u8 = undefined;
    t.feed(apc(&buf, "a=t,f=32,s=2,v=2,I=13", &red2x2));
    const id = t.images.byNumber(13).?.id;
    var want: [64]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&want, "\x1b_Gi={d},I=13;OK\x1b\\", .{id}), replies(&t));
    t.replies.clearRetainingCapacity();
    t.feed(apc(&buf, "a=p,I=13,p=4", ""));
    try testing.expectEqualStrings(try std.fmt.bufPrint(&want, "\x1b_Gi={d},I=13,p=4;OK\x1b\\", .{id}), replies(&t));
    try testing.expectEqual(@as(usize, 1), t.images.placements.items.len);
    // The same placement id replaces it.
    t.feed(apc(&buf, "a=p,I=13,p=4,q=1", ""));
    try testing.expectEqual(@as(usize, 1), t.images.placements.items.len);
}

test "kitty: zlib-compressed RGB" {
    var t = try term(.{});
    defer t.deinit();
    const raw = [_]u8{ 10, 20, 30 } ** 4;
    var zbuf: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&zbuf);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var c = try std.compress.flate.Compress.init(&out, &window, .zlib, .default);
    try c.writer.writeAll(&raw);
    try c.finish();
    var buf: [512]u8 = undefined;
    t.feed(apc(&buf, "a=t,f=24,s=2,v=2,o=z,i=9", out.buffered()));
    try testing.expectEqualStrings("\x1b_Gi=9;OK\x1b\\", replies(&t));
    try testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255 }, t.images.get(9).?.pixels.rgba[0..4]);
}

test "kitty: delete selectors" {
    var t = try term(.{});
    defer t.deinit();
    var buf: [256]u8 = undefined;
    // Image 1 at (0,0) and (5,3); image 2 at (10,0) with z=3.
    t.feed(apc(&buf, "a=T,f=32,s=2,v=2,i=1,q=2,C=1", &red2x2));
    t.feed("\x1b[4;6H");
    t.feed(apc(&buf, "a=p,i=1,p=2,q=2,C=1", ""));
    t.feed("\x1b[1;11H");
    t.feed(apc(&buf, "a=T,f=32,s=2,v=2,i=2,z=3,q=2,C=1", &red2x2));
    try testing.expectEqual(@as(usize, 3), t.images.placements.items.len);

    t.feed(apc(&buf, "a=d,d=p,x=6,y=4", ""));
    try testing.expectEqual(@as(usize, 2), t.images.placements.items.len);
    t.feed(apc(&buf, "a=d,d=z,z=3", ""));
    try testing.expectEqual(@as(usize, 1), t.images.placements.items.len);
    // Lowercase keeps the data, uppercase frees it.
    try testing.expect(t.images.get(2) != null);
    t.feed(apc(&buf, "a=d,d=I,i=2", ""));
    try testing.expect(t.images.get(2) == null);
    t.feed("\x1b[1;1H");
    t.feed(apc(&buf, "a=d,d=C", ""));
    try testing.expectEqual(@as(usize, 0), t.images.placements.items.len);
    try testing.expect(t.images.get(1) == null);
}

test "kitty: placements scroll with their rows; RIS, ED 2 and leaving the alt screen delete them" {
    var t = try term(.{ .clear_pushes_to_scrollback = false });
    defer t.deinit();
    var buf: [256]u8 = undefined;
    t.feed("\x1b[3;1H");
    t.feed(apc(&buf, "a=T,f=32,s=2,v=2,i=1,q=2,C=1", &red2x2));
    const pin = t.images.placements.items[0].pin;
    const before = t.primary.pages.rowIndex(pin.pin);
    t.feed("\x1b[10;1H\n\n");
    try testing.expectEqual(before, t.primary.pages.rowIndex(pin.pin));
    try testing.expectEqual(@as(u16, 0), t.primary.cursor.x);
    t.feed("\x1b[2J");
    try testing.expectEqual(@as(usize, 0), t.images.placements.items.len);
    try testing.expect(t.images.get(1) != null);

    t.feed("\x1b[?1049h");
    t.feed(apc(&buf, "a=T,f=32,s=2,v=2,i=2,q=2", &red2x2));
    try testing.expectEqual(@as(usize, 1), t.images.placements.items.len);
    t.feed("\x1b[?1049l");
    try testing.expectEqual(@as(usize, 0), t.images.placements.items.len);
    try testing.expect(t.images.get(2) == null);
    t.feed("\x1bc");
    try testing.expectEqual(@as(usize, 0), t.images.images.count());
}

test "kitty: the quota evicts unplaced images first" {
    var t = try term(.{ .graphics = .{ .quota = 40 } });
    defer t.deinit();
    var buf: [256]u8 = undefined;
    t.feed(apc(&buf, "a=T,f=32,s=2,v=2,i=1,q=2", &red2x2)); // placed, 16 B
    t.feed(apc(&buf, "a=t,f=32,s=2,v=2,i=2,q=2", &red2x2));
    t.feed(apc(&buf, "a=t,f=32,s=2,v=2,i=3,q=2", &red2x2)); // 48 B > 40
    try testing.expect(t.images.get(1) != null);
    try testing.expect(t.images.get(2) == null);
    try testing.expect(t.images.get(3) != null);
}

test "kitty: other APCs are ignored" {
    var t = try term(.{});
    defer t.deinit();
    t.feed("\x1b_Xhello\x1b\\ok");
    try testing.expectEqual(@as(usize, 0), replies(&t).len);
    try testing.expectEqual(@as(u16, 2), t.primary.cursor.x);
}

test "kitty: file media is refused unless allowed, and checked when allowed" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "img.rgba", .data = &red2x2 });
    try tmp.dir.writeFile(io, .{ .sub_path = "tty-graphics-protocol-x.rgba", .data = &red2x2 });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var img_buf: [512]u8 = undefined;
    var pbuf: [512]u8 = undefined;
    var buf: [2048]u8 = undefined;
    const img = try std.fmt.bufPrint(&img_buf, "{s}/img.rgba", .{root});

    {
        var t = try term(.{});
        defer t.deinit();
        t.feed(apc(&buf, "a=t,t=f,f=32,s=2,v=2,i=1", img));
        try testing.expect(std.mem.indexOf(u8, replies(&t), "EPERM") != null);
    }
    {
        var t = try term(.{ .graphics = .{ .allow_file_media = true, .io = io, .local = false } });
        defer t.deinit();
        t.feed(apc(&buf, "a=t,t=f,f=32,s=2,v=2,i=1", img));
        try testing.expect(std.mem.indexOf(u8, replies(&t), "EPERM") != null);
    }
    var t = try term(.{ .graphics = .{ .allow_file_media = true, .io = io } });
    defer t.deinit();
    t.feed(apc(&buf, "a=t,t=f,f=32,s=2,v=2,i=1", img));
    try testing.expectEqualStrings("\x1b_Gi=1;OK\x1b\\", replies(&t));
    // A symlink to /dev/zero gets the generic error.
    tmp.dir.symLink(io, "/dev/zero", "zero", .{}) catch return error.SkipZigTest;
    t.replies.clearRetainingCapacity();
    t.feed(apc(&buf, "a=t,t=f,f=32,s=2,v=2,i=2", try std.fmt.bufPrint(&pbuf, "{s}/zero", .{root})));
    try testing.expectEqualStrings("\x1b_Gi=2;EBADF:could not read the image file\x1b\\", replies(&t));
    // t=t outside the temp folders (or without the marker) is read, not deleted.
    t.replies.clearRetainingCapacity();
    t.feed(apc(&buf, "a=t,t=t,f=32,s=2,v=2,i=3", img));
    try testing.expectEqualStrings("\x1b_Gi=3;OK\x1b\\", replies(&t));
    try tmp.dir.access(io, "img.rgba", .{});
    // Inside a temp folder with the marker: deleted after reading.
    t.opts.graphics.tmpdir = root;
    t.feed(apc(&buf, "a=t,t=t,f=32,s=2,v=2,i=4,q=1", try std.fmt.bufPrint(&pbuf, "{s}/tty-graphics-protocol-x.rgba", .{root})));
    try testing.expect(t.images.get(4) != null);
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "tty-graphics-protocol-x.rgba", .{}));
    try testing.expect(kitty.isTempPath("/tmp/a", ""));
    try testing.expect(!kitty.isTempPath("/tmpx/a", ""));
}
