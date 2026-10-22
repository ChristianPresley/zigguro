//! `IEnumFORMATETC` over a fixed list of formats (E01.F02.S04.T02): what
//! `IDataObject.EnumFormatEtc` hands to a drop target. Each enumerator
//! owns a copy of the list; `Clone` copies the list and the position.
//! Pure Zig: the tests run on every OS.

const std = @import("std");
const Allocator = std.mem.Allocator;
const t = @import("bindings/types.zig");
const com = @import("com.zig");

/// The implementation behind the COM object.
pub const Impl = struct {
    gpa: Allocator,
    fmts: []t.FORMATETC,
    pos: usize = 0,

    /// Copies up to `n` formats into `out`; S_FALSE when fewer remained.
    pub fn Next(s: *Impl, n: t.ULONG, out: [*]t.FORMATETC, fetched: ?*t.ULONG) t.HRESULT {
        const k = @min(n, s.fmts.len - s.pos);
        @memcpy(out[0..k], s.fmts[s.pos..][0..k]);
        s.pos += k;
        if (fetched) |f| f.* = @intCast(k);
        return if (k == n) t.S_OK else t.S_FALSE;
    }

    /// Skips `n` formats; S_FALSE when fewer remained.
    pub fn Skip(s: *Impl, n: t.ULONG) t.HRESULT {
        const k = @min(n, s.fmts.len - s.pos);
        s.pos += k;
        return if (k == n) t.S_OK else t.S_FALSE;
    }

    /// Back to the first format.
    pub fn Reset(s: *Impl) t.HRESULT {
        s.pos = 0;
        return t.S_OK;
    }

    /// A new enumerator at the same position.
    pub fn Clone(s: *Impl, out: *?*com.IEnumFORMATETC) t.HRESULT {
        out.* = null;
        const e = create(s.gpa, s.fmts) catch return t.E_OUTOFMEMORY;
        e.impl.pos = s.pos;
        out.* = @ptrCast(@alignCast(e.iface()));
        return t.S_OK;
    }

    /// Frees the list.
    pub fn deinit(s: *Impl) void {
        s.gpa.free(s.fmts);
    }
};

/// The COM object.
pub const Object = com.ComObject(com.IEnumFORMATETC.Vtbl, Impl);

/// An enumerator over a copy of `fmts`, with one reference.
pub fn create(gpa: Allocator, fmts: []const t.FORMATETC) error{OutOfMemory}!*Object {
    const copy = try gpa.dupe(t.FORMATETC, fmts);
    errdefer gpa.free(copy);
    return Object.create(gpa, .{ .gpa = gpa, .fmts = copy });
}

const testing = std.testing;

test "IEnumFORMATETC: Next, Skip, Reset and Clone" {
    const fmts = [_]t.FORMATETC{ .{ .cfFormat = 13, .tymed = 1 }, .{ .cfFormat = 15, .tymed = 1 }, .{ .cfFormat = 0xc001, .tymed = 1 } };
    const o = try create(testing.allocator, &fmts);
    const e: *com.IEnumFORMATETC = @ptrCast(@alignCast(o.iface()));
    var out: [4]t.FORMATETC = undefined;
    var got: t.ULONG = 0;
    try testing.expectEqual(t.S_OK, e.vtbl.Next(e, 2, &out, &got));
    try testing.expectEqual(2, got);
    try testing.expectEqual(15, out[1].cfFormat);

    var clone: ?*com.IEnumFORMATETC = null;
    try testing.expectEqual(t.S_OK, e.vtbl.Clone(e, &clone));
    // Asking past the end: S_FALSE with what remained.
    try testing.expectEqual(t.S_FALSE, e.vtbl.Next(e, 4, &out, &got));
    try testing.expectEqual(1, got);
    try testing.expectEqual(0xc001, out[0].cfFormat);
    try testing.expectEqual(t.S_FALSE, e.vtbl.Next(e, 1, &out, null));

    // The clone kept its own position.
    const c = clone.?;
    try testing.expectEqual(t.S_OK, c.vtbl.Next(c, 1, &out, null));
    try testing.expectEqual(0xc001, out[0].cfFormat);
    _ = com.IUnknown.release(c);

    try testing.expectEqual(t.S_OK, e.vtbl.Reset(e));
    try testing.expectEqual(t.S_OK, e.vtbl.Skip(e, 2));
    try testing.expectEqual(t.S_FALSE, e.vtbl.Skip(e, 2));
    try testing.expectEqual(t.S_OK, e.vtbl.Reset(e));
    try testing.expectEqual(t.S_OK, e.vtbl.Next(e, 1, &out, null));
    try testing.expectEqual(13, out[0].cfFormat);
    try testing.expectEqual(0, com.IUnknown.release(e));
}
