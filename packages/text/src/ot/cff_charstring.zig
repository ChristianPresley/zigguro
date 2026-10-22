//! The Type 2 charstring interpreter for CFF and CFF2: path operators,
//! hints (counted and skipped), subroutines, the arithmetic and storage
//! operators, `seac`-style `endchar` accents (CFF1) and `vsindex`/`blend`
//! (CFF2). Contours are emitted as fontTools' T2 outline extractor emits
//! them, so its pens give exact goldens.

const std = @import("std");
const Allocator = std.mem.Allocator;
const reader = @import("reader.zig");
const cff = @import("cff.zig");
const ivs = @import("var/ivs.zig");
const Path = @import("../outline/path.zig").Path;

const GlyphId = reader.GlyphId;

/// Maximum subroutine nesting.
pub const max_depth = 10;
/// Maximum operators executed per glyph.
pub const max_ops = 50_000;
/// Maximum bytes in one charstring.
pub const max_len = 65535;

const Error = error{ Malformed, OutOfMemory, LimitExceeded };

const Interp = struct {
    c: *const cff.Cff,
    gpa: Allocator,
    out: *Path,
    blend: ?cff.BlendCtx,
    private: cff.Private,
    stack: [513]f32 = undefined,
    sp: usize = 0,
    limit: usize,
    x: f32 = 0,
    y: f32 = 0,
    open: bool = false,
    stems: usize = 0,
    seen_width: bool = false,
    ops: u32 = 0,
    transient: [32]f32 = @splat(0),
    vsindex: u16,
    /// Set by `endchar` with 4 operands (CFF1 seac).
    seac: ?[4]f32 = null,

    fn push(it: *Interp, v: f32) Error!void {
        if (it.sp >= it.limit) return error.LimitExceeded;
        it.stack[it.sp] = v;
        it.sp += 1;
    }

    fn pop(it: *Interp) Error!f32 {
        if (it.sp == 0) return error.Malformed;
        it.sp -= 1;
        return it.stack[it.sp];
    }

    /// Drops a leading width operand (CFF1) when the argument count of the
    /// first stack-clearing operator says one is there: an odd count for
    /// most operators, an even one for hmoveto/vmoveto.
    fn takeWidth(it: *Interp, width_if_odd: bool) []f32 {
        var args = it.stack[0..it.sp];
        if (!it.seen_width) {
            it.seen_width = true;
            if (it.c.version == .cff1 and args.len > 0 and (args.len % 2 == 1) == width_if_odd) args = args[1..];
        }
        return args;
    }

    fn moveTo(it: *Interp, dx: f32, dy: f32) Error!void {
        try it.closePath();
        it.x += dx;
        it.y += dy;
        try it.out.moveTo(it.gpa, it.x, it.y);
        it.open = true;
    }

    fn ensureOpen(it: *Interp) Error!void {
        if (!it.open) try it.moveTo(0, 0);
    }

    fn lineTo(it: *Interp, dx: f32, dy: f32) Error!void {
        try it.ensureOpen();
        it.x += dx;
        it.y += dy;
        try it.out.lineTo(it.gpa, it.x, it.y);
    }

    fn curveTo(it: *Interp, dx1: f32, dy1: f32, dx2: f32, dy2: f32, dx3: f32, dy3: f32) Error!void {
        try it.ensureOpen();
        const x1 = it.x + dx1;
        const y1 = it.y + dy1;
        const x2 = x1 + dx2;
        const y2 = y1 + dy2;
        it.x = x2 + dx3;
        it.y = y2 + dy3;
        try it.out.cubicTo(it.gpa, x1, y1, x2, y2, it.x, it.y);
    }

    fn closePath(it: *Interp) Error!void {
        if (!it.open) return;
        try it.out.close(it.gpa);
        it.open = false;
    }

    fn countStems(it: *Interp) void {
        const args = it.takeWidth(true);
        it.stems += args.len / 2;
        it.sp = 0;
    }

    /// Runs `code`; returns true when the glyph ended (endchar).
    fn exec(it: *Interp, code: []const u8, depth: u8) Error!bool {
        if (depth > max_depth) return error.LimitExceeded;
        if (code.len > max_len) return error.LimitExceeded;
        var r: reader.Reader = .{ .data = code };
        while (r.remaining() > 0) {
            it.ops += 1;
            if (it.ops > max_ops) return error.LimitExceeded;
            const b0 = try r.u8_();
            switch (b0) {
                32...246 => try it.push(@floatFromInt(@as(i32, b0) - 139)),
                247...250 => try it.push(@floatFromInt((@as(i32, b0) - 247) * 256 + try r.u8_() + 108)),
                251...254 => try it.push(@floatFromInt(-(@as(i32, b0) - 251) * 256 - @as(i32, try r.u8_()) - 108)),
                28 => try it.push(@floatFromInt(try r.i16_())),
                255 => try it.push(@as(f32, @floatFromInt(try r.i32_())) / 65536.0),
                1, 3, 18, 23 => it.countStems(), // hstem, vstem, hstemhm, vstemhm
                19, 20 => { // hintmask, cntrmask: pending args are implicit vstems
                    it.countStems();
                    try r.skip((it.stems + 7) / 8);
                },
                21 => { // rmoveto
                    const a = it.takeWidth(true);
                    if (a.len < 2) return error.Malformed;
                    try it.moveTo(a[a.len - 2], a[a.len - 1]);
                    it.sp = 0;
                },
                22, 4 => { // hmoveto, vmoveto
                    const a = it.takeWidth(false);
                    if (a.len < 1) return error.Malformed;
                    if (b0 == 22) try it.moveTo(a[a.len - 1], 0) else try it.moveTo(0, a[a.len - 1]);
                    it.sp = 0;
                },
                5 => { // rlineto
                    const a = it.stack[0..it.sp];
                    var i: usize = 0;
                    while (i + 2 <= a.len) : (i += 2) try it.lineTo(a[i], a[i + 1]);
                    it.sp = 0;
                },
                6, 7 => { // hlineto, vlineto: alternating
                    var horiz = b0 == 6;
                    for (it.stack[0..it.sp]) |d| {
                        if (horiz) try it.lineTo(d, 0) else try it.lineTo(0, d);
                        horiz = !horiz;
                    }
                    it.sp = 0;
                },
                8 => { // rrcurveto
                    const a = it.stack[0..it.sp];
                    var i: usize = 0;
                    while (i + 6 <= a.len) : (i += 6) try it.curveTo(a[i], a[i + 1], a[i + 2], a[i + 3], a[i + 4], a[i + 5]);
                    it.sp = 0;
                },
                24 => { // rcurveline
                    const a = it.stack[0..it.sp];
                    if (a.len < 8) return error.Malformed;
                    var i: usize = 0;
                    while (i + 6 <= a.len - 2) : (i += 6) try it.curveTo(a[i], a[i + 1], a[i + 2], a[i + 3], a[i + 4], a[i + 5]);
                    try it.lineTo(a[a.len - 2], a[a.len - 1]);
                    it.sp = 0;
                },
                25 => { // rlinecurve
                    const a = it.stack[0..it.sp];
                    if (a.len < 8) return error.Malformed;
                    var i: usize = 0;
                    while (i + 2 <= a.len - 6) : (i += 2) try it.lineTo(a[i], a[i + 1]);
                    const c = a[a.len - 6 ..];
                    try it.curveTo(c[0], c[1], c[2], c[3], c[4], c[5]);
                    it.sp = 0;
                },
                26 => { // vvcurveto: [dx1] {dya dxb dyb dyc}+
                    var a = it.stack[0..it.sp];
                    var dx1: f32 = 0;
                    if (a.len % 4 == 1) {
                        dx1 = a[0];
                        a = a[1..];
                    }
                    var i: usize = 0;
                    while (i + 4 <= a.len) : (i += 4) {
                        try it.curveTo(dx1, a[i], a[i + 1], a[i + 2], 0, a[i + 3]);
                        dx1 = 0;
                    }
                    it.sp = 0;
                },
                27 => { // hhcurveto: [dy1] {dxa dxb dyb dxc}+
                    var a = it.stack[0..it.sp];
                    var dy1: f32 = 0;
                    if (a.len % 4 == 1) {
                        dy1 = a[0];
                        a = a[1..];
                    }
                    var i: usize = 0;
                    while (i + 4 <= a.len) : (i += 4) {
                        try it.curveTo(a[i], dy1, a[i + 1], a[i + 2], a[i + 3], 0);
                        dy1 = 0;
                    }
                    it.sp = 0;
                },
                30, 31 => { // vhcurveto, hvcurveto: alternating, optional final df
                    const a = it.stack[0..it.sp];
                    var horiz = b0 == 31;
                    var i: usize = 0;
                    while (i + 4 <= a.len) : (i += 4) {
                        const last = a.len - i == 5;
                        const f: f32 = if (last) a[i + 4] else 0;
                        if (horiz) {
                            try it.curveTo(a[i], 0, a[i + 1], a[i + 2], f, a[i + 3]);
                        } else {
                            try it.curveTo(0, a[i], a[i + 1], a[i + 2], a[i + 3], f);
                        }
                        horiz = !horiz;
                    }
                    it.sp = 0;
                },
                10, 29 => { // callsubr, callgsubr
                    const local = b0 == 10;
                    const ix = if (local) &it.private.subrs else &it.c.gsubrs;
                    const n = @as(i32, @intFromFloat(std.math.clamp(try it.pop(), -1e9, 1e9))) + cff.subrBias(ix.count);
                    if (n < 0) return error.Malformed;
                    if (try it.exec(try ix.get(@intCast(n)), depth + 1)) return true;
                },
                11 => return false, // return
                14 => { // endchar
                    if (it.c.version == .cff2) return error.Malformed;
                    const a = it.takeWidth(true);
                    if (a.len >= 4) it.seac = a[a.len - 4 ..][0..4].*;
                    try it.closePath();
                    it.sp = 0;
                    return true;
                },
                15 => { // vsindex (CFF2)
                    if (it.c.version != .cff2) return error.Malformed;
                    it.vsindex = @intFromFloat(std.math.clamp(try it.pop(), 0, 65535));
                    it.sp = 0;
                },
                16 => try it.doBlend(), // blend (CFF2)
                12 => try it.escape(try r.u8_()),
                else => return error.Malformed,
            }
        }
        return false;
    }

    fn doBlend(it: *Interp) Error!void {
        if (it.c.version != .cff2) return error.Malformed;
        const store = &(it.c.store orelse return error.Malformed);
        const data = try store.itemData(it.vsindex);
        const k: usize = data.regionCount();
        const nv: usize = @intFromFloat(std.math.clamp(try it.pop(), 0, 513));
        const used = nv * (k + 1);
        if (used > it.sp) return error.Malformed;
        const base = it.sp - used;
        if (it.blend) |b| {
            for (0..nv) |i| {
                var v = it.stack[base + i];
                const deltas = it.stack[base + nv + i * k ..][0..k];
                for (deltas, 0..) |d, j| {
                    const ri = data.region(j);
                    if (ri < b.scalars.len) v += b.scalars[ri] * d;
                }
                it.stack[base + i] = v;
            }
        }
        it.sp = base + nv;
    }

    fn escape(it: *Interp, b1: u8) Error!void {
        switch (b1) {
            35 => { // flex
                const a = try it.lastArgs(13);
                try it.curveTo(a[0], a[1], a[2], a[3], a[4], a[5]);
                try it.curveTo(a[6], a[7], a[8], a[9], a[10], a[11]);
            },
            34 => { // hflex
                const a = try it.lastArgs(7);
                try it.curveTo(a[0], 0, a[1], a[2], a[3], 0);
                try it.curveTo(a[4], 0, a[5], -a[2], a[6], 0);
            },
            36 => { // hflex1
                const a = try it.lastArgs(9);
                try it.curveTo(a[0], a[1], a[2], a[3], a[4], 0);
                try it.curveTo(a[5], 0, a[6], a[7], a[8], -(a[1] + a[3] + a[7]));
            },
            37 => { // flex1
                const a = try it.lastArgs(11);
                const dx = a[0] + a[2] + a[4] + a[6] + a[8];
                const dy = a[1] + a[3] + a[5] + a[7] + a[9];
                try it.curveTo(a[0], a[1], a[2], a[3], a[4], a[5]);
                if (@abs(dx) > @abs(dy)) {
                    try it.curveTo(a[6], a[7], a[8], a[9], a[10], -dy);
                } else {
                    try it.curveTo(a[6], a[7], a[8], a[9], -dx, a[10]);
                }
            },
            else => return it.arith(b1),
        }
        it.sp = 0;
    }

    fn lastArgs(it: *Interp, n: usize) Error![]f32 {
        if (it.sp < n) return error.Malformed;
        return it.stack[it.sp - n .. it.sp];
    }

    fn arith(it: *Interp, b1: u8) Error!void {
        switch (b1) {
            3, 4 => { // and, or
                const b = try it.pop();
                const a = try it.pop();
                const v = if (b1 == 3) (a != 0 and b != 0) else (a != 0 or b != 0);
                try it.push(if (v) 1 else 0);
            },
            5 => try it.push(if (try it.pop() == 0) 1 else 0), // not
            9 => try it.push(@abs(try it.pop())),
            10, 11, 24 => { // add, sub, mul
                const b = try it.pop();
                const a = try it.pop();
                try it.push(switch (b1) {
                    10 => a + b,
                    11 => a - b,
                    else => a * b,
                });
            },
            12 => { // div
                const b = try it.pop();
                const a = try it.pop();
                try it.push(if (b == 0) 0 else a / b);
            },
            14 => try it.push(-(try it.pop())),
            15 => try it.push(if (try it.pop() == try it.pop()) 1 else 0),
            18 => _ = try it.pop(), // drop
            20 => { // put
                const i = try it.pop();
                const v = try it.pop();
                if (i >= 0 and i < 32) it.transient[@intFromFloat(i)] = v;
            },
            21 => { // get
                const i = try it.pop();
                try it.push(if (i >= 0 and i < 32) it.transient[@intFromFloat(i)] else 0);
            },
            22 => { // ifelse
                const v2 = try it.pop();
                const v1 = try it.pop();
                const s2 = try it.pop();
                const s1 = try it.pop();
                try it.push(if (v1 <= v2) s1 else s2);
            },
            23 => try it.push(0.5), // random: deterministic
            26 => try it.push(@sqrt(@abs(try it.pop()))),
            27 => { // dup
                const v = try it.pop();
                try it.push(v);
                try it.push(v);
            },
            28 => { // exch
                const b = try it.pop();
                const a = try it.pop();
                try it.push(b);
                try it.push(a);
            },
            29 => { // index
                const i = try it.pop();
                if (it.sp == 0) return error.Malformed;
                const k: usize = if (i < 0) 0 else @intFromFloat(@min(i, @as(f32, @floatFromInt(it.sp - 1))));
                try it.push(it.stack[it.sp - 1 - k]);
            },
            30 => { // roll
                const j = try it.pop();
                const n = try it.pop();
                if (n <= 0 or n > @as(f32, @floatFromInt(it.sp)) or @abs(j) > 1e6) return error.Malformed;
                const nn: usize = @intFromFloat(n);
                const s = it.stack[it.sp - nn .. it.sp];
                const shift: usize = @intCast(@mod(@as(i64, @intFromFloat(j)), @as(i64, @intCast(nn))));
                std.mem.rotate(f32, s, nn - shift);
            },
            else => return error.Malformed,
        }
    }
};

fn runGlyph(c: *const cff.Cff, gid: GlyphId, blend: ?cff.BlendCtx, out: *Path, gpa: Allocator, seac_ok: bool) Error!?[4]f32 {
    const code = try c.char_strings.get(gid);
    const priv = try c.privateFor(gid);
    var it: Interp = .{
        .c = c,
        .gpa = gpa,
        .out = out,
        .blend = blend,
        .private = priv,
        .limit = if (c.version == .cff1) 48 else 513,
        .vsindex = priv.vsindex,
    };
    _ = try it.exec(code, 0);
    try it.closePath();
    if (it.seac != null and !seac_ok) return error.Malformed;
    return it.seac;
}

/// Runs glyph `gid`'s charstring, appending its contours to `out`.
pub fn run(c: *const cff.Cff, gid: GlyphId, blend: ?cff.BlendCtx, out: *Path, gpa: Allocator) Error!void {
    const seac = try runGlyph(c, gid, blend, out, gpa, true) orelse return;
    // endchar adx ady bchar achar: base glyph, then the accent offset.
    const sids = [2]u16{ cff.standard_encoding[stdCode(seac[2])], cff.standard_encoding[stdCode(seac[3])] };
    for (sids, 0..) |sid, k| {
        if (sid == 0) return error.Malformed;
        const g = try c.glyphForSid(sid) orelse return error.Malformed;
        const start = out.points.items.len;
        _ = try runGlyph(c, g, blend, out, gpa, false);
        if (k == 1) {
            for (out.points.items[start..]) |*p| {
                p[0] += seac[0];
                p[1] += seac[1];
            }
            out.transform(.identity); // recompute the bounds
        }
    }
}

fn stdCode(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v, 0, 255));
}
