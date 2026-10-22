//! Vim macros (`q{reg}` ... `q`, `@{reg}`, `@@`): keys are recorded into
//! a register as Vim stores them (control characters, `<Esc>` as 0x1B,
//! `<CR>` as 0x0D and Vim's `K_SPECIAL` codes for the named keys), so a
//! recorded macro can be put, edited and yanked back like any register.
//! Replay feeds the keys through `handleKey`; the Vim state stops at the
//! first command that fails, as Vim does.

const std = @import("std");
const key_mod = @import("../key.zig");

const Allocator = std.mem.Allocator;
const Key = key_mod.Key;
const Special = key_mod.Special;

/// Vim's `K_SPECIAL` byte, followed by two bytes naming the key.
const k_special: u8 = 0x80;

const special_codes = [_]struct { Special, *const [2]u8 }{
    .{ .backspace, "kb" }, .{ .delete, "kD" },    .{ .up, "ku" },     .{ .down, "kd" },
    .{ .left, "kl" },      .{ .right, "kr" },     .{ .home, "kh" },   .{ .end, "@7" },
    .{ .page_up, "kP" },   .{ .page_down, "kN" }, .{ .insert, "kI" },
};

/// Appends the bytes Vim records for `k`.
pub fn encode(k: Key, gpa: Allocator, out: *std.ArrayList(u8)) Allocator.Error!void {
    if (k.code >= 0x11_0000) {
        const s: Special = @enumFromInt(k.code);
        switch (s) {
            .esc => return out.append(gpa, 0x1B),
            .enter => return out.append(gpa, '\r'),
            .tab => return out.append(gpa, '\t'),
            else => {},
        }
        for (special_codes) |e| if (e[0] == s) {
            try out.append(gpa, k_special);
            return out.appendSlice(gpa, e[1]);
        };
        return;
    }
    if (k.ctrl and k.code < 0x80) {
        const c: u8 = @intCast(k.code);
        if (c == '@' or c == ' ') return out.append(gpa, 0);
        return out.append(gpa, std.ascii.toUpper(c) & 0x1F);
    }
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(k.code, &buf) catch return;
    try out.appendSlice(gpa, buf[0..n]);
}

/// The keys of recorded bytes (the inverse of `encode`).
pub fn decode(bytes: []const u8, gpa: Allocator, out: *std.ArrayList(Key)) Allocator.Error!void {
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b == k_special and i + 2 < bytes.len) {
            const code = bytes[i + 1 .. i + 3];
            i += 3;
            for (special_codes) |e| if (std.mem.eql(u8, e[1], code)) {
                try out.append(gpa, .named(e[0]));
                break;
            };
            continue;
        }
        if (b < 0x20) {
            i += 1;
            try out.append(gpa, switch (b) {
                0x1B => .named(.esc),
                '\r' => .named(.enter),
                '\t' => .named(.tab),
                0 => .ctrlOf('@'),
                else => .ctrlOf(b | 0x60),
            });
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(b) catch 1;
        const end = @min(i + n, bytes.len);
        const cp = std.unicode.utf8Decode(bytes[i..end]) catch b;
        i = end;
        try out.append(gpa, .char(cp));
    }
}

/// A recording in progress (`q{reg}`).
pub const Recording = struct {
    register: u8,
    bytes: std.ArrayList(u8) = .empty,
    /// Length before the latest key, so the closing `q` can be dropped.
    before_last: usize = 0,

    pub fn deinit(r: *Recording, gpa: Allocator) void {
        r.bytes.deinit(gpa);
    }

    pub fn add(r: *Recording, gpa: Allocator, k: Key) !void {
        r.before_last = r.bytes.items.len;
        try encode(k, gpa, &r.bytes);
    }

    /// The keys recorded, without the `q` that ended the recording.
    pub fn finished(r: *Recording) []const u8 {
        return r.bytes.items[0..r.before_last];
    }
};

test "vim: macro key encoding round trip" {
    const gpa = std.testing.allocator;
    var keys: [32]Key = undefined;
    const n = try key_mod.parse("ifoo<Esc>0<C-v>j<CR><BS><Left><Del>é", &keys);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    for (keys[0..n]) |k| try encode(k, gpa, &bytes);
    try std.testing.expectEqualStrings("ifoo\x1b0\x16j\r\x80kb\x80kl\x80kDé", bytes.items);
    var back: std.ArrayList(Key) = .empty;
    defer back.deinit(gpa);
    try decode(bytes.items, gpa, &back);
    try std.testing.expectEqual(n, back.items.len);
    for (keys[0..n], back.items) |a, b| try std.testing.expect(a.eql(b));
}
