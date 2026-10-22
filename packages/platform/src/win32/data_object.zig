//! The `IDataObject` a drag we start offers (E01.F02.S04.T02), the
//! `MimeId` ↔ clipboard format table drag and drop shares, and `Memory`,
//! the HGLOBAL operations behind both (kernel32 and ole32 on Windows, a
//! heap stand-in for the tests, which run on every OS).
//!
//! The object owns copies of the dragged items. `GetData` converts the
//! requested one with the clipboard encoders (CF_UNICODETEXT, CF_HDROP,
//! "HTML Format", raw bytes otherwise) into a fresh HGLOBAL each call,
//! which the caller frees with `ReleaseStgMedium`. Only `TYMED_HGLOBAL`
//! and `DVASPECT_CONTENT` are offered; `SetData` and advise sinks are not
//! supported.

const std = @import("std");
const Allocator = std.mem.Allocator;
const t = @import("bindings/types.zig");
const com = @import("com.zig");
const enum_fmt = @import("enum_formatetc.zig");
const clip = @import("clipboard.zig");
const MimeId = @import("../api/clipboard.zig").MimeId;
const ClipItem = @import("../api/clipboard.zig").ClipItem;
const is_windows = @import("builtin").os.tag == .windows;

/// `TYMED_HGLOBAL`.
pub const TYMED_HGLOBAL: t.DWORD = 1;
/// `DVASPECT_CONTENT`.
pub const DVASPECT_CONTENT: t.DWORD = 1;
/// `DATADIR_GET`.
pub const DATADIR_GET: t.DWORD = 1;
/// `DV_E_TYMED`.
pub const DV_E_TYMED: t.HRESULT = @bitCast(@as(u32, 0x80040069));
/// `DV_E_DVASPECT`.
pub const DV_E_DVASPECT: t.HRESULT = @bitCast(@as(u32, 0x8004006B));
/// `DATA_S_SAMEFORMATETC`.
pub const DATA_S_SAMEFORMATETC: t.HRESULT = 0x00040130;
/// `OLE_E_ADVISENOTSUPPORTED`.
pub const OLE_E_ADVISENOTSUPPORTED: t.HRESULT = @bitCast(@as(u32, 0x80040003));

/// The clipboard formats of the known `MimeId`s. Registered formats
/// come from `ClipState`; runtime-registered ids have none.
pub const Formats = struct {
    html: t.CLIPFORMAT,
    png: t.CLIPFORMAT,
    internal: t.CLIPFORMAT,

    /// The known ids, most specific first (the order offered).
    pub const known = [_]MimeId{ .zigguro_internal, .uri_list, .html, .png, .text_utf8 };

    /// The format for `mime`, or null.
    pub fn cfOf(f: Formats, mime: MimeId) ?t.CLIPFORMAT {
        const cf: t.CLIPFORMAT = switch (mime) {
            .text_utf8 => @intCast(clip.CF_UNICODETEXT),
            .uri_list => @intCast(clip.CF_HDROP),
            .html => f.html,
            .png => f.png,
            .zigguro_internal => f.internal,
            _ => 0,
        };
        return if (cf == 0) null else cf;
    }
};

/// HGLOBAL operations.
pub const Memory = struct {
    /// A new HGLOBAL holding a copy of `bytes`, or null.
    alloc: *const fn ([]const u8) ?t.HGLOBAL,
    /// Locks `h` and returns its bytes, or null.
    lock: *const fn (t.HGLOBAL) ?[]const u8,
    /// Ends a `lock`.
    unlock: *const fn (t.HGLOBAL) void,
    /// `ReleaseStgMedium`.
    releaseMedium: *const fn (*t.STGMEDIUM) void,

    /// The decoded bytes (UTF-8 or raw) of an HGLOBAL medium in `mime`,
    /// owned by the caller; null when undecodable.
    pub fn readMedium(m: *const Memory, gpa: Allocator, mime: MimeId, med: *t.STGMEDIUM) !?[]u8 {
        defer m.releaseMedium(med);
        if (med.tymed != TYMED_HGLOBAL) return null;
        const h = med.u.hGlobal orelse return null;
        const bytes = m.lock(h) orelse return null;
        defer m.unlock(h);
        return clip.decodeFrom(gpa, mime, bytes);
    }
};

/// kernel32's HGLOBALs and ole32's `ReleaseStgMedium`.
pub const windows_memory: Memory = if (is_windows) .{
    .alloc = struct {
        fn f(bytes: []const u8) ?t.HGLOBAL {
            const k = @import("bindings/kernel32.zig");
            const h = k.GlobalAlloc(k.GMEM_MOVEABLE, @max(bytes.len, 1)) orelse return null;
            const p = k.GlobalLock(h) orelse {
                _ = k.GlobalFree(h);
                return null;
            };
            @memcpy(@as([*]u8, @ptrCast(p))[0..bytes.len], bytes);
            _ = k.GlobalUnlock(h);
            return h;
        }
    }.f,
    .lock = struct {
        fn f(h: t.HGLOBAL) ?[]const u8 {
            const k = @import("bindings/kernel32.zig");
            const size = k.GlobalSize(h);
            const p = k.GlobalLock(h) orelse return null;
            return @as([*]const u8, @ptrCast(p))[0..size];
        }
    }.f,
    .unlock = struct {
        fn f(h: t.HGLOBAL) void {
            _ = @import("bindings/kernel32.zig").GlobalUnlock(h);
        }
    }.f,
    .releaseMedium = struct {
        fn f(med: *t.STGMEDIUM) void {
            @import("bindings/ole32.zig").ReleaseStgMedium(med);
        }
    }.f,
} else undefined;

/// Heap-backed HGLOBALs for the tests; `live` counts unfreed blocks.
pub const test_memory = struct {
    var live: std.atomic.Value(i32) = .init(0);
    const gpa = std.heap.page_allocator;

    fn alloc(bytes: []const u8) ?t.HGLOBAL {
        const b = gpa.alloc(u8, @sizeOf(usize) + bytes.len) catch return null;
        std.mem.writeInt(usize, b[0..@sizeOf(usize)], bytes.len, .little);
        @memcpy(b[@sizeOf(usize)..], bytes);
        _ = live.fetchAdd(1, .monotonic);
        return @ptrCast(b.ptr);
    }
    fn block(h: t.HGLOBAL) []u8 {
        const p: [*]u8 = @ptrCast(h);
        const n = std.mem.readInt(usize, p[0..@sizeOf(usize)], .little);
        return p[0 .. @sizeOf(usize) + n];
    }
    fn lock(h: t.HGLOBAL) ?[]const u8 {
        return block(h)[@sizeOf(usize)..];
    }
    fn unlock(_: t.HGLOBAL) void {}
    fn releaseMedium(med: *t.STGMEDIUM) void {
        if (med.pUnkForRelease == null) if (med.u.hGlobal) |h| {
            gpa.free(block(h));
            _ = live.fetchSub(1, .monotonic);
        };
        med.u.hGlobal = null;
    }

    /// The table.
    pub const memory: Memory = .{ .alloc = alloc, .lock = lock, .unlock = unlock, .releaseMedium = releaseMedium };

    /// Blocks allocated and not released.
    pub fn liveBlocks() i32 {
        return live.load(.monotonic);
    }
};

/// One owned representation.
pub const Item = struct { mime: MimeId, cf: t.CLIPFORMAT, data: []u8 };

/// The implementation behind the COM object.
pub const Impl = struct {
    gpa: Allocator,
    items: []Item,
    mem: *const Memory,

    fn find(s: *Impl, fe: *const t.FORMATETC) error{ Format, Tymed, Aspect }!*Item {
        for (s.items) |*it| if (it.cf == fe.cfFormat) {
            if (fe.tymed & TYMED_HGLOBAL == 0) return error.Tymed;
            if (fe.dwAspect != DVASPECT_CONTENT) return error.Aspect;
            return it;
        };
        return error.Format;
    }

    fn hr(err: error{ Format, Tymed, Aspect }) t.HRESULT {
        return switch (err) {
            error.Format => t.DV_E_FORMATETC,
            error.Tymed => DV_E_TYMED,
            error.Aspect => DV_E_DVASPECT,
        };
    }

    /// The item in `fe`'s format, encoded into a fresh HGLOBAL.
    pub fn GetData(s: *Impl, fe: *const t.FORMATETC, med: *t.STGMEDIUM) t.HRESULT {
        const it = s.find(fe) catch |err| return hr(err);
        const bytes = clip.encodeFor(s.gpa, it.mime, it.data) catch return t.E_OUTOFMEMORY;
        defer s.gpa.free(bytes);
        const h = s.mem.alloc(bytes) orelse return t.E_OUTOFMEMORY;
        med.* = .{ .tymed = TYMED_HGLOBAL, .u = .{ .hGlobal = h }, .pUnkForRelease = null };
        return t.S_OK;
    }

    /// Not supported.
    pub fn GetDataHere(_: *Impl, _: *const t.FORMATETC, _: *t.STGMEDIUM) t.HRESULT {
        return t.E_NOTIMPL;
    }

    /// S_OK when `GetData` would succeed for `fe`.
    pub fn QueryGetData(s: *Impl, fe: *const t.FORMATETC) t.HRESULT {
        _ = s.find(fe) catch |err| return hr(err);
        return t.S_OK;
    }

    /// Every format renders the same on every device.
    pub fn GetCanonicalFormatEtc(_: *Impl, in: *const t.FORMATETC, out: *t.FORMATETC) t.HRESULT {
        out.* = in.*;
        out.ptd = null;
        return DATA_S_SAMEFORMATETC;
    }

    /// Not supported: the data is fixed when the drag starts.
    pub fn SetData(_: *Impl, _: *const t.FORMATETC, _: *t.STGMEDIUM, _: t.BOOL) t.HRESULT {
        return t.E_NOTIMPL;
    }

    /// The formats, for `DATADIR_GET` only.
    pub fn EnumFormatEtc(s: *Impl, direction: t.DWORD, out: *?*com.IEnumFORMATETC) t.HRESULT {
        out.* = null;
        if (direction != DATADIR_GET) return t.E_NOTIMPL;
        var fmts: [Formats.known.len]t.FORMATETC = undefined;
        for (s.items, 0..) |it, i| fmts[i] = .{ .cfFormat = it.cf, .tymed = TYMED_HGLOBAL };
        const e = enum_fmt.create(s.gpa, fmts[0..s.items.len]) catch return t.E_OUTOFMEMORY;
        out.* = @ptrCast(@alignCast(e.iface()));
        return t.S_OK;
    }

    /// Not supported.
    pub fn DAdvise(_: *Impl, _: *const t.FORMATETC, _: t.DWORD, _: ?*anyopaque, _: *t.DWORD) t.HRESULT {
        return OLE_E_ADVISENOTSUPPORTED;
    }

    /// Not supported.
    pub fn DUnadvise(_: *Impl, _: t.DWORD) t.HRESULT {
        return OLE_E_ADVISENOTSUPPORTED;
    }

    /// Not supported.
    pub fn EnumDAdvise(_: *Impl, _: *?*anyopaque) t.HRESULT {
        return OLE_E_ADVISENOTSUPPORTED;
    }

    /// Frees the items.
    pub fn deinit(s: *Impl) void {
        for (s.items) |it| s.gpa.free(it.data);
        s.gpa.free(s.items);
    }
};

/// The COM object.
pub const Object = com.ComObject(com.IDataObject.Vtbl, Impl);

/// A data object with copies of `items` that have a clipboard format
/// (the first of each format wins), with one reference.
pub fn create(gpa: Allocator, items: []const ClipItem, formats: Formats, mem: *const Memory) error{OutOfMemory}!*Object {
    var list: std.ArrayList(Item) = .empty;
    errdefer {
        for (list.items) |it| gpa.free(it.data);
        list.deinit(gpa);
    }
    for (items) |ci| {
        const cf = formats.cfOf(ci.mime) orelse continue;
        for (list.items) |it| {
            if (it.cf == cf) break;
        } else {
            try list.ensureUnusedCapacity(gpa, 1);
            list.appendAssumeCapacity(.{ .mime = ci.mime, .cf = cf, .data = try gpa.dupe(u8, ci.data) });
        }
    }
    const owned = try list.toOwnedSlice(gpa);
    errdefer {
        for (owned) |it| gpa.free(it.data);
        gpa.free(owned);
    }
    return Object.create(gpa, .{ .gpa = gpa, .items = owned, .mem = mem });
}

const testing = std.testing;

/// Format numbers for the tests (registered formats start at 0xC000).
pub const test_formats: Formats = .{ .html = 0xc001, .png = 0xc002, .internal = 0xc003 };

test "DataObject: QueryGetData, GetData per format, EnumFormatEtc" {
    const mem = &test_memory.memory;
    const before = test_memory.liveBlocks();
    const o = try create(testing.allocator, &.{
        .{ .mime = .text_utf8, .data = "a\nb" },
        .{ .mime = .uri_list, .data = "file:///C:/x%20y.txt\r\n" },
        .{ .mime = .html, .data = "<b>x</b>" },
        .{ .mime = .text_utf8, .data = "dropped: same format twice" },
        .{ .mime = @enumFromInt(200), .data = "no format" },
    }, test_formats, mem);
    const d: *com.IDataObject = @ptrCast(@alignCast(o.iface()));
    try testing.expectEqual(3, o.impl.items.len);

    try testing.expectEqual(t.S_OK, d.vtbl.QueryGetData(d, &.{ .cfFormat = 13, .tymed = TYMED_HGLOBAL }));
    try testing.expectEqual(t.S_OK, d.vtbl.QueryGetData(d, &.{ .cfFormat = 15, .tymed = TYMED_HGLOBAL | 4 }));
    try testing.expectEqual(t.DV_E_FORMATETC, d.vtbl.QueryGetData(d, &.{ .cfFormat = test_formats.png, .tymed = TYMED_HGLOBAL }));
    try testing.expectEqual(DV_E_TYMED, d.vtbl.QueryGetData(d, &.{ .cfFormat = 13, .tymed = 4 }));
    try testing.expectEqual(DV_E_DVASPECT, d.vtbl.QueryGetData(d, &.{ .cfFormat = 13, .dwAspect = 4, .tymed = TYMED_HGLOBAL }));

    var med: t.STGMEDIUM = undefined;
    // Text: CRLF UTF-16 with a NUL; read back through the decoder.
    try testing.expectEqual(t.S_OK, d.vtbl.GetData(d, &.{ .cfFormat = 13, .tymed = TYMED_HGLOBAL }, &med));
    try testing.expectEqualSlices(u8, &.{ 'a', 0, '\r', 0, '\n', 0, 'b', 0, 0, 0 }, mem.lock(med.u.hGlobal.?).?);
    const text = (try mem.readMedium(testing.allocator, .text_utf8, &med)).?;
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("a\r\nb", text);
    // uri-list: a DROPFILES block; html: CF_HTML.
    try testing.expectEqual(t.S_OK, d.vtbl.GetData(d, &.{ .cfFormat = 15, .tymed = TYMED_HGLOBAL }, &med));
    try testing.expectEqual(20, std.mem.readInt(u32, mem.lock(med.u.hGlobal.?).?[0..4], .little));
    const uris = (try mem.readMedium(testing.allocator, .uri_list, &med)).?;
    defer testing.allocator.free(uris);
    try testing.expectEqualStrings("file:///C:/x%20y.txt\r\n", uris);
    try testing.expectEqual(t.S_OK, d.vtbl.GetData(d, &.{ .cfFormat = test_formats.html, .tymed = TYMED_HGLOBAL }, &med));
    const html = (try mem.readMedium(testing.allocator, .html, &med)).?;
    defer testing.allocator.free(html);
    try testing.expectEqualStrings("<b>x</b>", html);
    try testing.expectEqual(t.DV_E_FORMATETC, d.vtbl.GetData(d, &.{ .cfFormat = 2, .tymed = TYMED_HGLOBAL }, &med));
    try testing.expectEqual(before, test_memory.liveBlocks());

    var e: ?*com.IEnumFORMATETC = null;
    try testing.expectEqual(t.E_NOTIMPL, d.vtbl.EnumFormatEtc(d, 2, &e));
    try testing.expectEqual(t.S_OK, d.vtbl.EnumFormatEtc(d, DATADIR_GET, &e));
    var fmts: [8]t.FORMATETC = undefined;
    var n: t.ULONG = 0;
    try testing.expectEqual(t.S_FALSE, e.?.vtbl.Next(e.?, 8, &fmts, &n));
    try testing.expectEqual(3, n);
    try testing.expectEqual(13, fmts[0].cfFormat);
    try testing.expectEqual(15, fmts[1].cfFormat);
    try testing.expectEqual(test_formats.html, fmts[2].cfFormat);
    _ = com.IUnknown.release(e.?);

    try testing.expectEqual(t.E_NOTIMPL, d.vtbl.SetData(d, &.{ .cfFormat = 13, .tymed = 1 }, &med, 0));
    var conn: t.DWORD = 0;
    try testing.expectEqual(OLE_E_ADVISENOTSUPPORTED, d.vtbl.DAdvise(d, &.{ .cfFormat = 13, .tymed = 1 }, 0, null, &conn));
    // The last release frees the items (the testing allocator checks).
    try testing.expectEqual(0, com.IUnknown.release(d));
}
