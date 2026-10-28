//! The kitty graphics protocol (E06.F08.S01.T01): `APC G <control> ;
//! <base64 payload> ST`. Images are transmitted directly (in one APC or
//! chunked with `m=1`), or read from a file, a temporary file or a POSIX
//! shared-memory object when the session is local and
//! `Options.allow_file_media` is set; raw RGB/RGBA (`f=24`/`f=32`) and PNG
//! (`f=100`, through `Options.decode`) are understood, optionally
//! zlib-compressed (`o=z`). Actions: transmit (`t`), transmit and place
//! (`T`), place (`p`), query (`q`) and delete (`d`), with responses
//! (`APC G i=<id>[,I=<n>][,p=<pid>];OK|<ECODE>:<message> ST`) unless
//! quieted (`q=1` OK, `q=2` all) or no `i`/`I` was given.
//!
//! Not yet: animation frames (`a=f`, `a=a`, `a=c`), relative placements
//! (`P`/`Q`/`H`/`V`), and drawing Unicode-placeholder placements (`U=1`
//! placements are kept but not shown).

const std = @import("std");
const Allocator = std.mem.Allocator;
const flate = std.compress.flate;
const Terminal = @import("../term/Terminal.zig");
const PageList = @import("../screen/PageList.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const Pixels = store_mod.Pixels;

/// A decoded image (premultiplied RGBA8, allocated with the given `gpa`).
pub const Decoded = struct { w: u32, h: u32, rgba: []u8 };

/// Decodes PNG bytes (`f=100`); installed by the owner (the view uses
/// the GUI's PNG decoder). Returns premultiplied RGBA.
pub const Decoder = struct {
    ctx: ?*anyopaque = null,
    f: *const fn (ctx: ?*anyopaque, gpa: Allocator, bytes: []const u8, max_pixels: u64) anyerror!Decoded,
};

pub const Options = struct {
    /// `terminal.graphics.allowFileMedia`: `t=f`, `t=t` and `t=s` may be
    /// read (only meaningful with `io`, and only for local sessions).
    allow_file_media: bool = false,
    /// The session runs on this machine (not over ssh, not in WSL).
    local: bool = true,
    io: ?std.Io = null,
    /// Pixel bytes kept per terminal.
    quota: usize = 256 << 20,
    /// Largest image, as `w * h * 4` bytes.
    max_image_bytes: usize = 100 << 20,
    decode: ?Decoder = null,
    /// `terminal.graphics.sixel`: sixel images are decoded and DA1
    /// advertises them.
    sixel: bool = true,
    /// `$TMPDIR`, a temporary folder besides /tmp and /dev/shm.
    tmpdir: []const u8 = "",
};

pub const Command = struct {
    action: u8 = 't',
    format: u16 = 32,
    medium: u8 = 'd',
    compression: u8 = 0,
    more: bool = false,
    id: u32 = 0,
    number: u32 = 0,
    placement: u32 = 0,
    /// `s` and `v`: the image's size in pixels (raw formats).
    width: u32 = 0,
    height: u32 = 0,
    /// `S` and `O`: bytes to read from a file and where.
    size: u32 = 0,
    offset: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    X: u32 = 0,
    Y: u32 = 0,
    cols: u32 = 0,
    rows: u32 = 0,
    z: i32 = 0,
    /// `C=1`: the cursor stays where it is.
    cursor_policy: u8 = 0,
    unicode_placeholder: bool = false,
    delete: u8 = 'a',
    quiet: u2 = 0,
};

/// Parses `key=value` pairs separated by commas; unknown keys and
/// malformed numbers are ignored.
pub fn parseControl(data: []const u8) Command {
    var c: Command = .{};
    var it = std.mem.splitScalar(u8, data, ',');
    while (it.next()) |kv| {
        if (kv.len < 3 or kv[1] != '=') continue;
        const v = kv[2..];
        const ch = v[0];
        const n = std.fmt.parseInt(u32, v, 10) catch 0;
        switch (kv[0]) {
            'a' => c.action = ch,
            'f' => c.format = @truncate(n),
            't' => c.medium = ch,
            'o' => c.compression = ch,
            'm' => c.more = n == 1,
            'i' => c.id = n,
            'I' => c.number = n,
            'p' => c.placement = n,
            's' => c.width = n,
            'v' => c.height = n,
            'S' => c.size = n,
            'O' => c.offset = n,
            'x' => c.x = n,
            'y' => c.y = n,
            'w' => c.w = n,
            'h' => c.h = n,
            'X' => c.X = n,
            'Y' => c.Y = n,
            'c' => c.cols = n,
            'r' => c.rows = n,
            'z' => c.z = std.fmt.parseInt(i32, v, 10) catch 0,
            'C' => c.cursor_policy = @truncate(n),
            'U' => c.unicode_placeholder = n == 1,
            'd' => c.delete = ch,
            'q' => c.quiet = @truncate(@min(n, 2)),
            else => {},
        }
    }
    return c;
}

/// The APC being received and a chunked transfer in progress.
pub const Kitty = struct {
    /// This APC's bytes (up to `max_apc`).
    apc: std.ArrayList(u8) = .empty,
    apc_overflow: bool = false,
    /// A chunked transfer: its first chunk's command and the payload so far.
    pending: ?Command = null,
    data: std.ArrayList(u8) = .empty,
    /// Base64 characters carried to the next chunk (not a multiple of 4).
    carry: [4]u8 = undefined,
    carry_len: u8 = 0,
    failed: ?Error = null,

    pub fn deinit(k: *Kitty, gpa: Allocator) void {
        k.apc.deinit(gpa);
        k.data.deinit(gpa);
    }

    fn resetTransfer(k: *Kitty) void {
        k.pending = null;
        k.data.clearRetainingCapacity();
        k.carry_len = 0;
        k.failed = null;
    }
};

/// The largest APC kept (a chunk; whole transfers are bounded by
/// `Options.max_image_bytes`).
const max_apc = 64 << 20;

pub fn apcStart(t: *Terminal) bool {
    t.kitty.apc.clearRetainingCapacity();
    t.kitty.apc_overflow = false;
    return true;
}

pub fn apcPut(t: *Terminal, bytes: []const u8) void {
    const k = &t.kitty;
    if (k.apc.items.len == 0 and bytes.len > 0 and bytes[0] != 'G') k.apc_overflow = true;
    if (k.apc_overflow) return;
    if (k.apc.items.len + bytes.len > max_apc) {
        k.apc_overflow = true;
        return;
    }
    k.apc.appendSlice(t.gpa, bytes) catch {
        k.apc_overflow = true;
    };
}

pub fn apcEnd(t: *Terminal) void {
    const k = &t.kitty;
    if (k.apc_overflow or k.apc.items.len == 0 or k.apc.items[0] != 'G') return;
    const body = k.apc.items[1..];
    const semi = std.mem.indexOfScalar(u8, body, ';');
    const ctl = parseControl(if (semi) |i| body[0..i] else body);
    const payload = if (semi) |i| body[i + 1 ..] else "";
    if (k.pending) |*p| {
        // A continuation chunk: only `m` (and `q`) count.
        if (ctl.quiet != 0) p.quiet = ctl.quiet;
        k.pending.?.more = ctl.more;
    } else {
        k.resetTransfer();
        k.pending = ctl;
        // A transmission without `i` and `I` and a quiet level of 0 gets an
        // id of its own only when it asked for a number; otherwise none.
    }
    const cmd = &k.pending.?;
    const carries = cmd.action != 'd' and cmd.action != 'p';
    if (carries and k.failed == null) decodeChunk(t, payload, !ctl.more) catch |e| {
        k.failed = e;
    };
    if (ctl.more and carries) return;
    const c = cmd.*;
    const failed = k.failed;
    defer k.resetTransfer();
    if (failed) |e| return respond(t, &c, e);
    run(t, &c, k.data.items);
}

fn decodeChunk(t: *Terminal, payload: []const u8, last: bool) Error!void {
    const k = &t.kitty;
    const d = std.base64.standard.Decoder;
    var rest = payload;
    // Complete the carried quad first.
    if (k.carry_len > 0) {
        const need = @min(4 - k.carry_len, rest.len);
        @memcpy(k.carry[k.carry_len..][0..need], rest[0..need]);
        k.carry_len += @intCast(need);
        rest = rest[need..];
        if (k.carry_len == 4) {
            try appendDecoded(t, d, &k.carry);
            k.carry_len = 0;
        }
    }
    const whole = rest.len - rest.len % 4;
    try appendDecoded(t, d, rest[0..whole]);
    const tail = rest[whole..];
    @memcpy(k.carry[k.carry_len..][0..tail.len], tail);
    k.carry_len += @intCast(tail.len);
    if (last and k.carry_len > 0) {
        // The final chunk may lack its padding.
        try appendDecoded(t, std.base64.standard_no_pad.Decoder, k.carry[0..k.carry_len]);
        k.carry_len = 0;
    }
}

fn appendDecoded(t: *Terminal, d: std.base64.Base64Decoder, src: []const u8) Error!void {
    if (src.len == 0) return;
    const k = &t.kitty;
    const n = d.calcSizeForSlice(src) catch return error.BadBase64;
    if (k.data.items.len + n > t.opts.graphics.max_image_bytes) return error.TooLarge;
    const dst = k.data.addManyAsSlice(t.gpa, n) catch return error.OutOfMemory;
    d.decode(dst, src) catch return error.BadBase64;
}

pub const Error = error{ BadBase64, TooLarge, OutOfMemory, BadFormat, BadSize, NoImage, BadMedium, BadFile, BadCompression, Refused };

fn code(e: Error) []const u8 {
    return switch (e) {
        error.BadBase64 => "EINVAL:invalid base64 data",
        error.TooLarge => "EFBIG:image too large",
        error.OutOfMemory => "ENOMEM:out of memory",
        error.BadFormat => "EBADPNG:could not decode the image data",
        error.BadSize => "EINVAL:the data does not match the image size",
        error.NoImage => "ENOENT:no image with that id or number",
        error.BadMedium => "EINVAL:unknown transmission medium",
        error.BadFile => "EBADF:could not read the image file",
        error.BadCompression => "EINVAL:could not inflate the data",
        error.Refused => "EPERM:file transmission is not allowed",
    };
}

fn pls(t: *Terminal) [2]*PageList {
    return .{ &t.primary.pages, &t.alternate.pages };
}

fn run(t: *Terminal, c: *const Command, data: []const u8) void {
    t.images.prune(pls(t));
    switch (c.action) {
        't', 'T', 'q' => transmit(t, c, data) catch |e| respond(t, c, e),
        'p' => {
            const img = (if (c.id != 0) t.images.get(c.id) else if (c.number != 0) t.images.byNumber(c.number) else null) orelse
                return respond(t, c, error.NoImage);
            var c2 = c.*;
            c2.id = img.id;
            placeImage(t, &c2, img) catch |e| return respond(t, &c2, e);
            respondOk(t, &c2);
        },
        'd' => delete(t, c),
        else => {},
    }
}

fn transmit(t: *Terminal, c: *const Command, data: []const u8) Error!void {
    const g = &t.opts.graphics;
    var file_buf: ?[]u8 = null;
    defer if (file_buf) |b| t.gpa.free(b);
    const bytes = switch (c.medium) {
        'd' => data,
        'f', 't', 's' => blk: {
            if (!g.allow_file_media or !g.local or g.io == null) return error.Refused;
            file_buf = try readMedium(t.gpa, g.io.?, c, data, g);
            break :blk file_buf.?;
        },
        else => return error.BadMedium,
    };
    var inflated: ?[]u8 = null;
    defer if (inflated) |b| t.gpa.free(b);
    const raw = if (c.compression == 'z') blk: {
        inflated = try inflate(t.gpa, bytes, g.max_image_bytes);
        break :blk inflated.?;
    } else if (c.compression != 0) return error.BadCompression else bytes;
    const dec = try decodeImage(t.gpa, c, raw, g);
    if (c.action == 'q') {
        t.gpa.free(dec.rgba);
        return respondOk(t, c);
    }
    var c2 = c.*;
    if (c2.id == 0) c2.id = t.images.autoId();
    const px = Pixels.create(t.gpa, dec.w, dec.h, dec.rgba) catch {
        t.gpa.free(dec.rgba);
        return error.OutOfMemory;
    };
    t.images.quota = g.quota;
    t.images.put(pls(t), c2.id, c2.number, px) catch {
        px.release();
        return error.OutOfMemory;
    };
    if (c.action == 'T') try placeImage(t, &c2, t.images.get(c2.id).?);
    // Replies only to clients that named the image.
    if (c.id != 0 or c.number != 0) respondOk(t, &c2);
}

fn decodeImage(gpa: Allocator, c: *const Command, raw: []const u8, g: *const Options) Error!Decoded {
    switch (c.format) {
        24, 32 => {
            const bpp: usize = if (c.format == 24) 3 else 4;
            if (c.width == 0 or c.height == 0) return error.BadSize;
            const n = @as(u64, c.width) * c.height;
            if (n * 4 > g.max_image_bytes) return error.TooLarge;
            if (raw.len < n * bpp) return error.BadSize;
            const out = gpa.alloc(u8, @intCast(n * 4)) catch return error.OutOfMemory;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const s = raw[i * bpp ..];
                const a: u16 = if (bpp == 4) s[3] else 255;
                out[i * 4 + 0] = @intCast((@as(u16, s[0]) * a + 127) / 255);
                out[i * 4 + 1] = @intCast((@as(u16, s[1]) * a + 127) / 255);
                out[i * 4 + 2] = @intCast((@as(u16, s[2]) * a + 127) / 255);
                out[i * 4 + 3] = @intCast(a);
            }
            return .{ .w = c.width, .h = c.height, .rgba = out };
        },
        100 => {
            const d = g.decode orelse return error.BadFormat;
            const img = d.f(d.ctx, gpa, raw, g.max_image_bytes / 4) catch |e| return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                error.TooLarge => error.TooLarge,
                else => error.BadFormat,
            };
            if (@as(u64, img.w) * img.h * 4 > g.max_image_bytes) {
                gpa.free(img.rgba);
                return error.TooLarge;
            }
            return img;
        },
        else => return error.BadFormat,
    }
}

fn inflate(gpa: Allocator, z: []const u8, limit: usize) Error![]u8 {
    var in: std.Io.Reader = .fixed(z);
    const window = gpa.alloc(u8, flate.max_window_len) catch return error.OutOfMemory;
    defer gpa.free(window);
    var d: flate.Decompress = .init(&in, .zlib, window);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    _ = d.reader.streamRemaining(&out.writer) catch return error.BadCompression;
    if (out.written().len > limit) return error.TooLarge;
    return out.toOwnedSlice() catch error.OutOfMemory;
}

/// Reads a file, temporary file or shared-memory medium. `name` is the
/// decoded payload: a path, or a shared-memory object's name.
fn readMedium(gpa: Allocator, io: std.Io, c: *const Command, name: []const u8, g: *const Options) Error![]u8 {
    if (name.len == 0 or name.len > 4096 or std.mem.indexOfScalar(u8, name, 0) != null) return error.BadFile;
    var path_buf: [4096 + 16]u8 = undefined;
    const path = if (c.medium == 's') blk: {
        if (@import("builtin").os.tag == .windows) return error.Refused;
        if (std.mem.indexOfScalar(u8, name, '/') != null and !(name[0] == '/' and std.mem.indexOfScalarPos(u8, name, 1, '/') == null)) return error.BadFile;
        const base = if (name[0] == '/') name[1..] else name;
        break :blk std.fmt.bufPrint(&path_buf, "/dev/shm/{s}", .{base}) catch return error.BadFile;
    } else name;
    if (!std.fs.path.isAbsolute(path)) return error.BadFile;
    // Symlinks are followed; where they lead is what is checked.
    var real_buf: [4096]u8 = undefined;
    const n = std.Io.Dir.cwd().realPathFile(io, path, &real_buf) catch return error.BadFile;
    const real = real_buf[0..n];
    const shm = std.mem.startsWith(u8, real, "/dev/shm/");
    for ([_][]const u8{ "/proc", "/sys", "/dev" }) |p| {
        if (std.mem.startsWith(u8, real, p) and (real.len == p.len or real[p.len] == '/') and !(c.medium == 's' and shm)) return error.BadFile;
    }
    const file = std.Io.Dir.cwd().openFile(io, real, .{}) catch return error.BadFile;
    const out = blk: {
        defer file.close(io);
        const st = file.stat(io) catch return error.BadFile;
        if (st.kind != .file) return error.BadFile;
        if (c.offset > st.size) return error.BadFile;
        const avail = st.size - c.offset;
        const want = if (c.size != 0) @min(c.size, avail) else avail;
        if (want > g.max_image_bytes) return error.TooLarge;
        const buf = gpa.alloc(u8, @intCast(want)) catch return error.OutOfMemory;
        errdefer gpa.free(buf);
        const got = file.readPositionalAll(io, buf, c.offset) catch return error.BadFile;
        if (got != buf.len) return error.BadFile;
        break :blk buf;
    };
    switch (c.medium) {
        's' => std.Io.Dir.cwd().deleteFile(io, real) catch {},
        't' => if (isTempPath(real, g.tmpdir) and std.mem.indexOf(u8, real, "tty-graphics-protocol") != null)
            std.Io.Dir.cwd().deleteFile(io, real) catch {},
        else => {},
    }
    return out;
}

/// Whether `path` is inside /tmp, /dev/shm or `tmpdir`.
pub fn isTempPath(path: []const u8, tmpdir: []const u8) bool {
    for ([_][]const u8{ "/tmp", "/dev/shm", tmpdir }) |dir| {
        const d = std.mem.trimEnd(u8, dir, "/");
        if (d.len == 0) continue;
        if (path.len > d.len and std.mem.startsWith(u8, path, d) and path[d.len] == '/') return true;
    }
    return false;
}

/// The cell size used to size placements (the view's, else 10x20).
fn cellSize(t: *const Terminal) [2]u32 {
    return .{ if (t.cell_px.w > 0) t.cell_px.w else 10, if (t.cell_px.h > 0) t.cell_px.h else 20 };
}

fn placeImage(t: *Terminal, c: *const Command, img: *store_mod.Image) Error!void {
    const s = t.screen();
    const cell = cellSize(t);
    const iw = img.pixels.w;
    const ih = img.pixels.h;
    const sx = @min(c.x, iw);
    const sy = @min(c.y, ih);
    const sw = if (c.w != 0) @min(c.w, iw - sx) else iw - sx;
    const sh = if (c.h != 0) @min(c.h, ih - sy) else ih - sy;
    // The drawn size: the source's own, or `c`/`r` cells (the other side
    // keeping the aspect ratio when only one is given).
    var pw: u64 = sw;
    var ph: u64 = sh;
    if (c.cols != 0) pw = @as(u64, c.cols) * cell[0];
    if (c.rows != 0) ph = @as(u64, c.rows) * cell[1];
    if (c.cols != 0 and c.rows == 0 and sw > 0) ph = pw * sh / sw;
    if (c.rows != 0 and c.cols == 0 and sh > 0) pw = ph * sw / sh;
    pw = @min(pw, 1 << 20);
    ph = @min(ph, 1 << 20);
    const cols: u32 = if (c.cols != 0) c.cols else @intCast(@max(1, (pw + c.X + cell[0] - 1) / cell[0]));
    const rows: u32 = if (c.rows != 0) c.rows else @intCast(@max(1, (ph + c.Y + cell[1] - 1) / cell[1]));
    const screen_id: store_mod.ScreenId = if (t.alt_active) .alternate else .primary;
    var pin = s.rowPin(s.cursor.y);
    pin.x = s.cursor.x;
    const tp = s.pages.track(pin) catch return error.OutOfMemory;
    t.images.place(pls(t), .{
        .image_id = img.id,
        .id = c.placement,
        .screen = screen_id,
        .pin = tp,
        .cols = @intCast(@min(cols, std.math.maxInt(u16))),
        .rows = @intCast(@min(rows, std.math.maxInt(u16))),
        .src_x = sx,
        .src_y = sy,
        .src_w = sw,
        .src_h = sh,
        .px_w = @intCast(pw),
        .px_h = @intCast(ph),
        .off_x = @min(c.X, cell[0] - 1),
        .off_y = @min(c.Y, cell[1] - 1),
        .z = c.z,
        .virtual = c.unicode_placeholder,
    }) catch return error.OutOfMemory;
    if (c.cursor_policy == 1 or c.unicode_placeholder) return;
    // The cursor moves to the cell right of the image's last row.
    var n = @min(rows, std.math.maxInt(u16)) - 1;
    while (n > 0) : (n -= 1) t.lineFeedNoCr();
    const x = @as(u32, s.cursor.x) + cols;
    if (x >= s.width()) {
        s.cursor.x = s.width() - 1;
        s.cursor.pending_wrap = true;
    } else s.cursor.x = @intCast(x);
}

/// The row of a placement's anchor on its screen's active area (may be
/// negative: above it).
fn activeRow(t: *Terminal, p: *const store_mod.Placement) ?i64 {
    if (p.pin.garbage) return null;
    const s = if (p.screen == .alternate) &t.alternate else &t.primary;
    const top = s.pages.rowIndex(s.rowPin(0));
    return @as(i64, @intCast(s.pages.rowIndex(p.pin.pin))) - @as(i64, @intCast(top));
}

fn delete(t: *Terminal, c: *const Command) void {
    const st = &t.images;
    const lists = pls(t);
    const free = std.ascii.isUpper(c.delete);
    const sel = std.ascii.toLower(c.delete);
    const cur = t.screen().cursor;
    const screen_id: store_mod.ScreenId = if (t.alt_active) .alternate else .primary;
    const rows: i64 = t.rows();
    // Images whose placements were removed (freed after, when uppercase).
    var touched: std.ArrayList(u32) = .empty;
    defer touched.deinit(t.gpa);
    const number_id: ?u32 = if (sel == 'n') (if (st.byNumber(c.number)) |img| img.id else null) else null;
    var i: usize = 0;
    while (i < st.placements.items.len) {
        const p = &st.placements.items[i];
        const r = activeRow(t, p);
        const col: i64 = p.pin.pin.x;
        const hit = switch (sel) {
            'a' => p.screen == screen_id and r != null and r.? + p.rows > 0 and r.? < rows,
            'i' => p.image_id == c.id and (c.placement == 0 or p.id == c.placement),
            'n' => number_id != null and p.image_id == number_id.? and (c.placement == 0 or p.id == c.placement),
            'c' => covers(p, screen_id, r, col, cur.x, cur.y),
            'p' => c.x > 0 and c.y > 0 and covers(p, screen_id, r, col, c.x - 1, c.y - 1),
            'q' => c.x > 0 and c.y > 0 and p.z == c.z and covers(p, screen_id, r, col, c.x - 1, c.y - 1),
            'x' => c.x > 0 and p.screen == screen_id and r != null and col <= c.x - 1 and c.x - 1 < col + p.cols,
            'y' => c.y > 0 and p.screen == screen_id and r != null and r.? <= c.y - 1 and c.y - 1 < r.? + p.rows,
            'z' => p.z == c.z,
            'r' => c.x <= p.image_id and p.image_id <= c.y,
            else => false,
        };
        if (hit) {
            touched.append(t.gpa, p.image_id) catch {};
            st.removePlacement(lists, i);
        } else i += 1;
    }
    if (!free) return;
    // `I`/`N`/`R` free the named images even without placements.
    switch (sel) {
        'i' => if (c.placement == 0) touched.append(t.gpa, c.id) catch {},
        'n' => if (number_id) |id| touched.append(t.gpa, id) catch {},
        'r' => for (st.images.keys()) |id| if (c.x <= id and id <= c.y) touched.append(t.gpa, id) catch {},
        else => {},
    }
    for (touched.items) |id| if (!st.hasPlacements(id)) st.removeImage(lists, id);
}

fn covers(p: *const store_mod.Placement, screen: store_mod.ScreenId, r: ?i64, col: i64, x: u32, y: u32) bool {
    if (p.screen != screen) return false;
    const row = r orelse return false;
    return row <= y and y < row + p.rows and col <= x and x < col + p.cols;
}

fn respondOk(t: *Terminal, c: *const Command) void {
    if (c.quiet >= 1) return;
    reply(t, c, "OK");
}

fn respond(t: *Terminal, c: *const Command, e: Error) void {
    if (c.quiet >= 2) return;
    reply(t, c, code(e));
}

fn reply(t: *Terminal, c: *const Command, msg: []const u8) void {
    if (c.id == 0 and c.number == 0) return;
    var buf: [160]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.writeAll("\x1b_G") catch return;
    var first = true;
    if (c.id != 0) {
        w.print("i={d}", .{c.id}) catch return;
        first = false;
    }
    if (c.number != 0) {
        w.print("{s}I={d}", .{ if (first) "" else ",", c.number }) catch return;
        first = false;
    }
    if (c.placement != 0) w.print(",p={d}", .{c.placement}) catch return;
    w.print(";{s}\x1b\\", .{msg}) catch return;
    t.reply(w.buffered());
}
