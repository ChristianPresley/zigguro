//! The Win32 clipboard (E01.F02.S04.T01): `MimeId` ↔ clipboard formats,
//! the conversions (UTF-8 ↔ CRLF UTF-16 text, CF_HTML, CF_HDROP), writes
//! with delayed rendering for large payloads, reads, and the change
//! listener. Everything that touches the clipboard runs on the platform
//! thread, which owns the message window the clipboard is opened with.
//!
//! Formats: text ↔ `CF_UNICODETEXT`, `html` ↔ "HTML Format", `uri_list`
//! ↔ `CF_HDROP`, `png` ↔ the registered "PNG" format, `zigguro_internal`
//! ↔ a format registered under its MIME type. Runtime-registered MIME ids
//! have no clipboard format yet.

const std = @import("std");
const Allocator = std.mem.Allocator;
const clipboard = @import("../api/clipboard.zig");
const MimeId = clipboard.MimeId;
const ClipItem = clipboard.ClipItem;
const cf_html = @import("cf_html.zig");
const hdrop = @import("hdrop.zig");
const is_windows = @import("builtin").os.tag == .windows;

/// `CF_UNICODETEXT`.
pub const CF_UNICODETEXT: u32 = 13;
/// `CF_HDROP`.
pub const CF_HDROP: u32 = 15;

/// Payloads above this many bytes are rendered on demand.
pub const delayed_threshold: usize = 4 * 1024 * 1024;

/// Clipboard messages the message window forwards here.
pub const WM_RENDERFORMAT: u32 = 0x0305;
/// See `WM_RENDERFORMAT`.
pub const WM_RENDERALLFORMATS: u32 = 0x0306;
/// See `WM_RENDERFORMAT`.
pub const WM_DESTROYCLIPBOARD: u32 = 0x0307;
/// See `WM_RENDERFORMAT`.
pub const WM_CLIPBOARDUPDATE: u32 = 0x031D;

/// The bytes to put on the clipboard for `data` in format `mime`.
pub fn encodeFor(gpa: Allocator, mime: MimeId, data: []const u8) ![]u8 {
    return switch (mime) {
        .text_utf8 => encodeText(gpa, data),
        .html => cf_html.encode(gpa, data),
        .uri_list => hdrop.encode(gpa, data),
        else => gpa.dupe(u8, data),
    };
}

/// The UTF-8 (or raw) bytes of clipboard block `block` in format
/// `mime`, or null when it cannot be decoded.
pub fn decodeFrom(gpa: Allocator, mime: MimeId, block: []const u8) !?[]u8 {
    return switch (mime) {
        .text_utf8 => decodeText(gpa, block),
        .html => if (cf_html.decode(block)) |f| try gpa.dupe(u8, f) else null,
        .uri_list => hdrop.decode(gpa, block),
        else => try gpa.dupe(u8, block),
    };
}

/// UTF-8 → NUL-terminated UTF-16LE with CRLF line ends.
pub fn encodeText(gpa: Allocator, utf8: []const u8) ![]u8 {
    var crlf: std.ArrayList(u8) = .empty;
    defer crlf.deinit(gpa);
    for (utf8, 0..) |c, i| {
        if (c == '\n' and (i == 0 or utf8[i - 1] != '\r')) try crlf.append(gpa, '\r');
        try crlf.append(gpa, c);
    }
    const w = try std.unicode.utf8ToUtf16LeAlloc(gpa, crlf.items);
    defer gpa.free(w);
    const out = try gpa.alloc(u8, (w.len + 1) * 2);
    @memcpy(out[0 .. w.len * 2], std.mem.sliceAsBytes(w));
    out[w.len * 2] = 0;
    out[w.len * 2 + 1] = 0;
    return out;
}

/// UTF-16LE up to the first NUL → UTF-8 (line ends unchanged), or null
/// when the text is not valid UTF-16.
pub fn decodeText(gpa: Allocator, block: []const u8) !?[]u8 {
    var n: usize = 0;
    while (n + 2 <= block.len and (block[n] != 0 or block[n + 1] != 0)) n += 2;
    const units = try gpa.alloc(u16, n / 2);
    defer gpa.free(units);
    for (units, 0..) |*u, i| u.* = std.mem.readInt(u16, block[i * 2 ..][0..2], .little);
    return std.unicode.utf16LeToUtf8Alloc(gpa, units) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

/// The platform thread's clipboard state (Windows only).
pub const ClipState = if (is_windows) struct {
    const t = @import("bindings/types.zig");
    const user32 = @import("bindings/user32.zig");
    const kernel32 = @import("bindings/kernel32.zig");
    const L = @import("wide.zig").L;

    gpa: Allocator,
    hwnd: t.HWND,
    cf_html: u32 = 0,
    cf_png: u32 = 0,
    cf_internal: u32 = 0,
    /// Items waiting for `WM_RENDERFORMAT` (delayed rendering).
    retained: []Retained = &.{},
    /// Whether AddClipboardFormatListener succeeded.
    listening: bool = false,

    const Self = @This();
    const Retained = struct { mime: MimeId, data: []u8 };

    /// Registers the formats and starts listening for changes.
    pub fn init(gpa: Allocator, hwnd: t.HWND) Self {
        var s: Self = .{ .gpa = gpa, .hwnd = hwnd };
        s.cf_html = user32.RegisterClipboardFormatW(L("HTML Format"));
        s.cf_png = user32.RegisterClipboardFormatW(L("PNG"));
        s.cf_internal = user32.RegisterClipboardFormatW(L("application/x-zigguro-internal"));
        s.listening = user32.AddClipboardFormatListener(hwnd) != 0;
        return s;
    }

    /// Stops listening and frees retained items.
    pub fn deinit(s: *Self) void {
        if (s.listening) _ = user32.RemoveClipboardFormatListener(s.hwnd);
        s.freeRetained();
    }

    fn freeRetained(s: *Self) void {
        for (s.retained) |r| s.gpa.free(r.data);
        s.gpa.free(s.retained);
        s.retained = &.{};
    }

    /// The clipboard format for `mime`, or null.
    pub fn formatOf(s: *const Self, mime: MimeId) ?u32 {
        const f: u32 = switch (mime) {
            .text_utf8 => CF_UNICODETEXT,
            .uri_list => CF_HDROP,
            .html => s.cf_html,
            .png => s.cf_png,
            .zigguro_internal => s.cf_internal,
            _ => 0,
        };
        return if (f == 0) null else f;
    }

    fn open(s: *Self) bool {
        // Another application may hold the clipboard for a moment.
        var tries: u32 = 0;
        while (tries < 5) : (tries += 1) {
            if (user32.OpenClipboard(s.hwnd) != 0) return true;
            kernel32.Sleep(10);
        }
        return false;
    }

    /// Converts `data` and hands it to the clipboard (which takes the
    /// HGLOBAL). Clipboard open.
    fn render(s: *Self, fmt: u32, mime: MimeId, data: []const u8) bool {
        const bytes = encodeFor(s.gpa, mime, data) catch return false;
        defer s.gpa.free(bytes);
        const h = kernel32.GlobalAlloc(kernel32.GMEM_MOVEABLE, @max(bytes.len, 1)) orelse return false;
        const p = kernel32.GlobalLock(h) orelse {
            _ = kernel32.GlobalFree(h);
            return false;
        };
        @memcpy(@as([*]u8, @ptrCast(p))[0..bytes.len], bytes);
        _ = kernel32.GlobalUnlock(h);
        if (user32.SetClipboardData(fmt, @ptrCast(h)) == null) {
            _ = kernel32.GlobalFree(h);
            return false;
        }
        return true;
    }

    /// Replaces the clipboard with `items`. Large payloads are rendered
    /// when another application asks for them.
    pub fn write(s: *Self, items: []const ClipItem) !void {
        if (!s.open()) return error.ClipboardBusy;
        defer _ = user32.CloseClipboard();
        // Ends our previous ownership: WM_DESTROYCLIPBOARD frees retained
        // items first.
        _ = user32.EmptyClipboard();
        s.freeRetained();
        var total: usize = 0;
        for (items) |it| total += it.data.len;
        if (total > delayed_threshold) {
            const kept = try s.gpa.alloc(Retained, items.len);
            var n: usize = 0;
            errdefer {
                for (kept[0..n]) |r| s.gpa.free(r.data);
                s.gpa.free(kept);
            }
            for (items) |it| {
                const fmt = s.formatOf(it.mime) orelse continue;
                kept[n] = .{ .mime = it.mime, .data = try s.gpa.dupe(u8, it.data) };
                n += 1;
                _ = user32.SetClipboardData(fmt, null);
            }
            s.retained = kept[0..n];
        } else for (items) |it| {
            const fmt = s.formatOf(it.mime) orelse continue;
            _ = s.render(fmt, it.mime, it.data);
        }
    }

    /// The clipboard's data in `mime` as UTF-8 (or raw) bytes owned by
    /// the caller; null when absent or undecodable.
    pub fn read(s: *Self, mime: MimeId) !?[]u8 {
        const fmt = s.formatOf(mime) orelse return null;
        if (!s.open()) return null;
        defer _ = user32.CloseClipboard();
        if (user32.IsClipboardFormatAvailable(fmt) == 0) return null;
        const h = user32.GetClipboardData(fmt) orelse return null;
        const hg: t.HGLOBAL = @ptrCast(h);
        const size = kernel32.GlobalSize(hg);
        const p = kernel32.GlobalLock(hg) orelse return null;
        defer _ = kernel32.GlobalUnlock(hg);
        return decodeFrom(s.gpa, mime, @as([*]const u8, @ptrCast(p))[0..size]);
    }

    /// Handles a clipboard message sent to the message window. Returns
    /// whether it was one; `changed` is set for another application's
    /// change.
    pub fn onMessage(s: *Self, msg: u32, wp: usize, changed: *bool) bool {
        switch (msg) {
            WM_RENDERFORMAT => {
                const fmt: u32 = @truncate(wp);
                // The clipboard is already open for us here.
                for (s.retained) |r| if (s.formatOf(r.mime) == fmt) {
                    _ = s.render(fmt, r.mime, r.data);
                };
            },
            WM_RENDERALLFORMATS => {
                if (user32.OpenClipboard(s.hwnd) == 0) return true;
                defer _ = user32.CloseClipboard();
                if (user32.GetClipboardOwner() != s.hwnd) return true;
                for (s.retained) |r| if (s.formatOf(r.mime)) |fmt| {
                    _ = s.render(fmt, r.mime, r.data);
                };
            },
            WM_DESTROYCLIPBOARD => s.freeRetained(),
            // Another writer's EmptyClipboard takes ownership away from
            // us; our own writes and delayed renders keep it.
            WM_CLIPBOARDUPDATE => changed.* = user32.GetClipboardOwner() != s.hwnd,
            else => return false,
        }
        return true;
    }
} else void;

const testing = std.testing;

test "LF→CRLF on write, unchanged on read" {
    const gpa = testing.allocator;
    const enc = try encodeText(gpa, "a\nb\r\nü\n");
    defer gpa.free(enc);
    // a CR LF b CR LF ü CR LF NUL, two bytes each.
    try testing.expectEqual(@as(usize, 10 * 2), enc.len);
    try testing.expectEqual(@as(u8, '\r'), enc[2]);
    const dec = (try decodeText(gpa, enc)).?;
    defer gpa.free(dec);
    try testing.expectEqualStrings("a\r\nb\r\nü\r\n", dec);
    // Blocks are rounded up past the NUL; a lone surrogate is rejected.
    const hi = (try decodeFrom(gpa, .text_utf8, &.{ 'h', 0, 'i', 0, 0, 0, 'x', 0 })).?;
    defer gpa.free(hi);
    try testing.expectEqualStrings("hi", hi);
    try testing.expectEqual(@as(?[]u8, null), try decodeText(gpa, &.{ 0x00, 0xd8, 0, 0 }));
}

test "encodeFor/decodeFrom roundtrip html and uri-list" {
    const gpa = testing.allocator;
    const h = try encodeFor(gpa, .html, "<i>x</i>");
    defer gpa.free(h);
    const hb = (try decodeFrom(gpa, .html, h)).?;
    defer gpa.free(hb);
    try testing.expectEqualStrings("<i>x</i>", hb);
    const u = try encodeFor(gpa, .uri_list, "file:///C:/x.txt\r\n");
    defer gpa.free(u);
    const ub = (try decodeFrom(gpa, .uri_list, u)).?;
    defer gpa.free(ub);
    try testing.expectEqualStrings("file:///C:/x.txt\r\n", ub);
}
