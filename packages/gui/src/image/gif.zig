//! GIF87a/89a (E04.F06.S02.T03): global and local colour tables, the
//! Graphic Control Extension (disposal, delay, transparency), NETSCAPE2.0
//! loop counts, interlacing, and frames composed onto the logical screen
//! as browsers do (disposal 2 clears to transparent; delays under 20 ms
//! play as 100 ms). Every read is bounds-checked; a file that ends after
//! some frames keeps them (`Image.truncated`).

const std = @import("std");
const image = @import("image.zig");
const lzw = @import("lzw.zig");

const Allocator = std.mem.Allocator;
const Image = image.Image;
const Frame = image.Frame;
const Limits = image.Limits;
const DecodeError = image.DecodeError;

/// Animation facts without decoding pixels.
pub const AnimInfo = struct { loop_count: u16, frame_count: u32 };

const Reader = struct {
    b: []const u8,
    i: usize = 0,

    fn byte(r: *Reader) error{Eof}!u8 {
        if (r.i >= r.b.len) return error.Eof;
        r.i += 1;
        return r.b[r.i - 1];
    }

    fn u16le(r: *Reader) error{Eof}!u16 {
        const s = try r.take(2);
        return std.mem.readInt(u16, s[0..2], .little);
    }

    fn take(r: *Reader, n: usize) error{Eof}![]const u8 {
        if (r.b.len - r.i < n) return error.Eof;
        r.i += n;
        return r.b[r.i - n .. r.i];
    }

    /// Skips data sub-blocks up to the terminator.
    fn skipBlocks(r: *Reader) error{Eof}!void {
        while (true) {
            const n = try r.byte();
            if (n == 0) return;
            _ = try r.take(n);
        }
    }

    /// Appends the data of the sub-blocks to `out`.
    fn readBlocks(r: *Reader, gpa: Allocator, out: *std.ArrayList(u8)) (error{Eof} || Allocator.Error)!void {
        while (true) {
            const n = try r.byte();
            if (n == 0) return;
            try out.appendSlice(gpa, try r.take(n));
        }
    }
};

const Gce = struct {
    disposal: Frame.Disposal = .none,
    delay_cs: u16 = 0,
    transparent: ?u8 = null,
};

fn isGif(bytes: []const u8) bool {
    return bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"));
}

/// Decodes every frame. One frame: `Image.frames` is empty.
pub fn decodeGif(gpa: Allocator, bytes: []const u8, limits: Limits) DecodeError!Image {
    if (bytes.len > limits.max_bytes) return error.TooLarge;
    if (!isGif(bytes)) return error.Malformed;
    var r: Reader = .{ .b = bytes, .i = 6 };
    const sw = r.u16le() catch return error.Malformed;
    const sh = r.u16le() catch return error.Malformed;
    const flags = r.byte() catch return error.Malformed;
    _ = r.byte() catch return error.Malformed; // background index (drawn transparent)
    _ = r.byte() catch return error.Malformed; // aspect
    if (sw == 0 or sh == 0) return error.Malformed;
    const canvas_len = try image.pixelBytes(sw, sh, limits);
    var global: []const u8 = &.{};
    if (flags & 0x80 != 0) global = r.take(@as(usize, 3) << @intCast((flags & 7) + 1)) catch return error.Malformed;

    const canvas = try gpa.alloc(u8, canvas_len);
    defer gpa.free(canvas);
    @memset(canvas, 0);
    var saved: []u8 = &.{};
    defer gpa.free(saved);

    var frames: std.ArrayList(Frame) = .empty;
    errdefer {
        for (frames.items) |f| gpa.free(f.rgba);
        frames.deinit(gpa);
    }
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    var indices: std.ArrayList(u8) = .empty;
    defer indices.deinit(gpa);

    var loop_count: u16 = 0;
    var gce: Gce = .{};
    var truncated = false;
    // The previous frame's rect and disposal, applied before the next.
    var prev: ?struct { x: u32, y: u32, w: u32, h: u32, disposal: Frame.Disposal } = null;
    var total_bytes: u64 = 0;

    blocks: while (true) {
        const intro = r.byte() catch {
            truncated = true;
            break;
        };
        switch (intro) {
            0x3B => break,
            0x21 => {
                const label = r.byte() catch {
                    truncated = true;
                    break;
                };
                switch (label) {
                    0xF9 => {
                        const n = r.byte() catch {
                            truncated = true;
                            break :blocks;
                        };
                        const body = r.take(n) catch {
                            truncated = true;
                            break :blocks;
                        };
                        if (n >= 4) {
                            const pk = body[0];
                            gce.disposal = switch ((pk >> 2) & 7) {
                                1 => .keep,
                                2 => .background,
                                3 => .previous,
                                else => .none,
                            };
                            gce.delay_cs = std.mem.readInt(u16, body[1..3], .little);
                            gce.transparent = if (pk & 1 != 0) body[3] else null;
                        }
                        r.skipBlocks() catch {
                            truncated = true;
                            break :blocks;
                        };
                    },
                    0xFF => {
                        const n = r.byte() catch {
                            truncated = true;
                            break :blocks;
                        };
                        const id = r.take(n) catch {
                            truncated = true;
                            break :blocks;
                        };
                        const netscape = std.mem.eql(u8, id, "NETSCAPE2.0") or std.mem.eql(u8, id, "ANIMEXTS1.0");
                        while (true) {
                            const m = r.byte() catch {
                                truncated = true;
                                break :blocks;
                            };
                            if (m == 0) break;
                            const sub = r.take(m) catch {
                                truncated = true;
                                break :blocks;
                            };
                            if (netscape and m >= 3 and sub[0] == 1) loop_count = std.mem.readInt(u16, sub[1..3], .little);
                        }
                    },
                    else => r.skipBlocks() catch {
                        truncated = true;
                        break :blocks;
                    },
                }
            },
            0x2C => {
                if (frames.items.len >= limits.max_frames) {
                    truncated = true;
                    break;
                }
                const fr = readFrame(&r, gpa, global, &data, &indices) catch |e| switch (e) {
                    error.Eof => {
                        truncated = true;
                        break :blocks;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                    error.Malformed => if (frames.items.len > 0) {
                        truncated = true;
                        break :blocks;
                    } else return error.Malformed,
                };
                if (total_bytes + canvas_len > limits.max_bytes) {
                    truncated = true;
                    break;
                }
                // The previous frame's disposal.
                if (prev) |p| switch (p.disposal) {
                    .background => clearRect(canvas, sw, sh, p.x, p.y, p.w, p.h),
                    .previous => if (saved.len == canvas.len) @memcpy(canvas, saved),
                    .none, .keep => {},
                };
                if (gce.disposal == .previous) {
                    if (saved.len != canvas.len) {
                        gpa.free(saved);
                        saved = &.{};
                        saved = try gpa.alloc(u8, canvas.len);
                    }
                    @memcpy(saved, canvas);
                }
                draw(canvas, sw, sh, fr, indices.items, gce.transparent);
                const out = try gpa.dupe(u8, canvas);
                errdefer gpa.free(out);
                const cs: u32 = gce.delay_cs;
                try frames.append(gpa, .{
                    .rgba = out,
                    .delay_ms = if (cs * 10 < 20) 100 else cs * 10,
                    .x = fr.x,
                    .y = fr.y,
                    .w = fr.w,
                    .h = fr.h,
                    .disposal = gce.disposal,
                });
                total_bytes += canvas_len;
                prev = .{ .x = fr.x, .y = fr.y, .w = fr.w, .h = fr.h, .disposal = gce.disposal };
                gce = .{};
            },
            else => {
                if (frames.items.len == 0) return error.Malformed;
                truncated = true;
                break;
            },
        }
    }
    if (frames.items.len == 0) return error.Malformed;
    if (frames.items.len == 1) {
        const only = frames.items[0].rgba;
        frames.deinit(gpa);
        return .{ .w = sw, .h = sh, .rgba = only, .format = .gif, .loop_count = loop_count, .truncated = truncated };
    }
    const owned = try frames.toOwnedSlice(gpa);
    return .{ .w = sw, .h = sh, .rgba = owned[0].rgba, .format = .gif, .frames = owned, .loop_count = loop_count, .truncated = truncated };
}

/// Counts frames and reads the loop count without decoding pixels.
pub fn animInfo(bytes: []const u8) DecodeError!AnimInfo {
    if (!isGif(bytes)) return error.Malformed;
    var r: Reader = .{ .b = bytes, .i = 10 };
    const flags = r.byte() catch return error.Malformed;
    r.i += 2;
    if (flags & 0x80 != 0) _ = r.take(@as(usize, 3) << @intCast((flags & 7) + 1)) catch return error.Malformed;
    var info: AnimInfo = .{ .loop_count = 0, .frame_count = 0 };
    while (true) {
        const intro = r.byte() catch return info;
        switch (intro) {
            0x3B => return info,
            0x21 => {
                const label = r.byte() catch return info;
                if (label == 0xFF) {
                    const n = r.byte() catch return info;
                    const id = r.take(n) catch return info;
                    while (true) {
                        const m = r.byte() catch return info;
                        if (m == 0) break;
                        const sub = r.take(m) catch return info;
                        if (std.mem.eql(u8, id, "NETSCAPE2.0") and m >= 3 and sub[0] == 1) info.loop_count = std.mem.readInt(u16, sub[1..3], .little);
                    }
                } else r.skipBlocks() catch return info;
            },
            0x2C => {
                _ = r.take(8) catch return info;
                const pk = r.byte() catch return info;
                if (pk & 0x80 != 0) _ = r.take(@as(usize, 3) << @intCast((pk & 7) + 1)) catch return info;
                _ = r.byte() catch return info;
                r.skipBlocks() catch return info;
                info.frame_count += 1;
            },
            else => return info,
        }
    }
}

/// `decoded` indices came out of the stream (a short one leaves the rest
/// of the frame undrawn).
const FrameDesc = struct { x: u32, y: u32, w: u32, h: u32, interlaced: bool, palette: []const u8, decoded: usize };

/// Reads an image descriptor and decodes its indices into `indices`
/// (row order, deinterlaced later by `draw`).
fn readFrame(r: *Reader, gpa: Allocator, global: []const u8, data: *std.ArrayList(u8), indices: *std.ArrayList(u8)) (error{ Eof, Malformed } || Allocator.Error)!FrameDesc {
    const x = try r.u16le();
    const y = try r.u16le();
    const w = try r.u16le();
    const h = try r.u16le();
    const pk = try r.byte();
    var palette = global;
    if (pk & 0x80 != 0) palette = try r.take(@as(usize, 3) << @intCast((pk & 7) + 1));
    const min = try r.byte();
    if (min < 2 or min > 11) return error.Malformed;
    data.clearRetainingCapacity();
    try r.readBlocks(gpa, data);
    const n = @as(usize, w) * h;
    try indices.resize(gpa, n);
    var d: lzw.LzwDecoder = .init(@intCast(min));
    const got = d.feed(data.items, indices.items) catch return error.Malformed;
    return .{ .x = x, .y = y, .w = w, .h = h, .interlaced = pk & 0x40 != 0, .palette = palette, .decoded = got };
}

/// The source row of output row `i` in a frame of `h` rows.
fn interlacedRow(i: u32, h: u32) u32 {
    const passes = [_][2]u32{ .{ 0, 8 }, .{ 4, 8 }, .{ 2, 4 }, .{ 1, 2 } };
    var k = i;
    for (passes) |p| {
        const rows = if (h > p[0]) (h - p[0] + p[1] - 1) / p[1] else 0;
        if (k < rows) return p[0] + k * p[1];
        k -= rows;
    }
    return i;
}

fn draw(canvas: []u8, sw: u32, sh: u32, f: FrameDesc, idx: []const u8, transparent: ?u8) void {
    const ncolors = f.palette.len / 3;
    var i: u32 = 0;
    while (i < f.h) : (i += 1) {
        const row = if (f.interlaced) interlacedRow(i, f.h) else i;
        const cy = f.y + row;
        if (cy >= sh) continue;
        const start = @as(usize, i) * f.w;
        if (start >= f.decoded) break;
        const src = idx[start..][0..@min(f.w, f.decoded - start)];
        for (src, 0..) |c, col| {
            const cx = f.x + @as(u32, @intCast(col));
            if (cx >= sw) break;
            if (transparent) |t| if (c == t) continue;
            const o = (@as(usize, cy) * sw + cx) * 4;
            if (c < ncolors) {
                canvas[o] = f.palette[@as(usize, c) * 3];
                canvas[o + 1] = f.palette[@as(usize, c) * 3 + 1];
                canvas[o + 2] = f.palette[@as(usize, c) * 3 + 2];
            } else {
                canvas[o] = 0;
                canvas[o + 1] = 0;
                canvas[o + 2] = 0;
            }
            canvas[o + 3] = 255;
        }
    }
}

fn clearRect(canvas: []u8, sw: u32, sh: u32, x: u32, y: u32, w: u32, h: u32) void {
    var row = y;
    while (row < @min(sh, y + h)) : (row += 1) {
        if (x >= sw) return;
        const x1 = @min(sw, x + w);
        @memset(canvas[(@as(usize, row) * sw + x) * 4 .. (@as(usize, row) * sw + x1) * 4], 0);
    }
}

test "interlaced row order" {
    // 10 rows: pass 1 rows 0 8, pass 2 row 4, pass 3 rows 2 6, pass 4 odd.
    const want = [_]u32{ 0, 8, 4, 2, 6, 1, 3, 5, 7, 9 };
    for (want, 0..) |w, i| try std.testing.expectEqual(w, interlacedRow(@intCast(i), 10));
}
