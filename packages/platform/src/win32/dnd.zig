//! OLE drag and drop (E01.F02.S04.T02): the `IDropTarget` each window
//! registers, the `IDropSource` of drags we start, and the effect rules
//! shared by both. Pure Zig apart from the HGLOBAL table: the tests run on
//! every OS.
//!
//! The target turns OLE's callbacks into `DropEvent`s through a `Sink`
//! (the backend's window). OLE wants each effect answered synchronously,
//! so `DragOver` and `Drop` answer from the app's latest
//! `set_drop_effect`, which the sink caches; `DragEnter` clears it, so a
//! drag starts refused until the app has seen `enter`. On `Drop` the
//! accepted format is read and decoded (UTF-8 text, `text/uri-list`
//! from CF_HDROP, the CF_HTML fragment).
//!
//! Effects: Ctrl picks copy, Shift move, Ctrl+Shift link, when the app
//! and the source both allow it; otherwise the first of copy, move and
//! link that both allow.

const std = @import("std");
const Allocator = std.mem.Allocator;
const t = @import("bindings/types.zig");
const com = @import("com.zig");
const data_object = @import("data_object.zig");
const api = @import("../api/clipboard.zig");
const MimeId = api.MimeId;
const DragActions = api.DragActions;
const DropPhase = api.DropPhase;

/// Key-state bits passed to the drop callbacks.
pub const MK = struct {
    /// Left button.
    pub const LBUTTON: t.DWORD = 0x1;
    /// Right button.
    pub const RBUTTON: t.DWORD = 0x2;
    /// Shift.
    pub const SHIFT: t.DWORD = 0x4;
    /// Control.
    pub const CONTROL: t.DWORD = 0x8;
    /// Middle button.
    pub const MBUTTON: t.DWORD = 0x10;
    /// Alt.
    pub const ALT: t.DWORD = 0x20;
};

/// `DROPEFFECT_*` bits for `a` (they match `DragActions`' first three).
pub fn toEffect(a: DragActions) t.DWORD {
    return @as(u8, @bitCast(a)) & 7;
}

/// `DragActions` for `DROPEFFECT_*` bits (scroll and others dropped).
pub fn fromEffect(e: t.DWORD) DragActions {
    return @bitCast(@as(u8, @truncate(e & 7)));
}

/// The one effect to report for the app's `answer`, the source's
/// `allowed` effects and the modifier keys; 0 refuses.
pub fn chooseEffect(answer: DragActions, allowed: t.DWORD, key_state: t.DWORD) t.DWORD {
    const both = toEffect(answer) & allowed & 7;
    if (both == 0) return 0;
    const ctrl = key_state & MK.CONTROL != 0;
    const shift = key_state & MK.SHIFT != 0;
    const want: t.DWORD = if (ctrl and shift) 4 else if (ctrl) 1 else if (shift) 2 else 0;
    if (want & both != 0) return want;
    inline for (.{ 1, 2, 4 }) |e| if (both & e != 0) return e;
    unreachable;
}

/// The app's latest answer to `enter`/`over`.
pub const Answer = struct {
    /// The accepted format; null refuses.
    accept: ?MimeId = null,
    /// The effects the app allows.
    effect: DragActions = .{},
};

/// Where the target's events go.
pub const Sink = struct {
    ctx: *anyopaque,
    /// Stages an event. `mimes` is for `enter`; `data` (owned, taken) for
    /// `drop`. `enter` also clears the cached answer.
    emit: *const fn (ctx: *anyopaque, phase: DropPhase, allowed: DragActions, pos: [2]f32, mimes: []const MimeId, data: ?[]u8) void,
    /// The cached answer.
    answer: *const fn (ctx: *anyopaque) Answer,
    /// A screen point in client pixels.
    toClient: *const fn (ctx: *anyopaque, pt: t.POINTL) [2]f32,
};

/// The drop target behind the COM object.
pub const TargetImpl = struct {
    gpa: Allocator,
    /// Null once `detach`ed: OLE may still hold the object after
    /// `RevokeDragDrop`, and then every callback refuses.
    sink: ?Sink,
    formats: data_object.Formats,
    mem: *const data_object.Memory,
    /// The data of the drag over us (one reference), between enter and
    /// leave/drop.
    data: ?*com.IDataObject = null,
    last_pos: [2]f32 = .{ -1, -1 },
    last_keys: t.DWORD = 0,

    fn setData(s: *TargetImpl, d: ?*com.IDataObject) void {
        if (d) |x| _ = x.vtbl.AddRef(x);
        if (s.data) |old| _ = com.IUnknown.release(old);
        s.data = d;
    }

    /// The known formats `d` offers as HGLOBALs.
    fn offered(s: *TargetImpl, d: *com.IDataObject, out: *[data_object.Formats.known.len]MimeId) []MimeId {
        var n: usize = 0;
        for (data_object.Formats.known) |m| {
            const cf = s.formats.cfOf(m) orelse continue;
            const fe: t.FORMATETC = .{ .cfFormat = cf, .tymed = data_object.TYMED_HGLOBAL };
            if (d.vtbl.QueryGetData(d, &fe) == t.S_OK) {
                out[n] = m;
                n += 1;
            }
        }
        return out[0..n];
    }

    /// A drag entered: `enter` with the offered formats.
    pub fn DragEnter(s: *TargetImpl, d: *com.IDataObject, key_state: t.DWORD, pt: t.POINTL, effect: *t.DWORD) t.HRESULT {
        const sink = s.sink orelse return refuse(effect);
        s.setData(d);
        var buf: [data_object.Formats.known.len]MimeId = undefined;
        const mimes = s.offered(d, &buf);
        const pos = sink.toClient(sink.ctx, pt);
        s.last_pos = pos;
        s.last_keys = key_state;
        sink.emit(sink.ctx, .enter, fromEffect(effect.*), pos, mimes, null);
        effect.* = chooseEffect(sink.answer(sink.ctx).effect, effect.*, key_state);
        return t.S_OK;
    }

    /// The pointer moved (or the keys changed): `over` when something
    /// changed; the effect from the cached answer.
    pub fn DragOver(s: *TargetImpl, key_state: t.DWORD, pt: t.POINTL, effect: *t.DWORD) t.HRESULT {
        const sink = s.sink orelse return refuse(effect);
        const pos = sink.toClient(sink.ctx, pt);
        if (pos[0] != s.last_pos[0] or pos[1] != s.last_pos[1] or key_state != s.last_keys) {
            s.last_pos = pos;
            s.last_keys = key_state;
            sink.emit(sink.ctx, .over, fromEffect(effect.*), pos, &.{}, null);
        }
        const a = sink.answer(sink.ctx);
        effect.* = if (a.accept == null) 0 else chooseEffect(a.effect, effect.*, key_state);
        return t.S_OK;
    }

    /// The drag left or was cancelled.
    pub fn DragLeave(s: *TargetImpl) t.HRESULT {
        if (s.sink) |sink| sink.emit(sink.ctx, .leave, .{}, s.last_pos, &.{}, null);
        s.setData(null);
        return t.S_OK;
    }

    /// The user dropped: `drop` with the accepted format's bytes, or
    /// `leave` when the app refused or the data could not be read.
    pub fn Drop(s: *TargetImpl, d: *com.IDataObject, key_state: t.DWORD, pt: t.POINTL, effect: *t.DWORD) t.HRESULT {
        defer s.setData(null);
        const sink = s.sink orelse return refuse(effect);
        const pos = sink.toClient(sink.ctx, pt);
        const a = sink.answer(sink.ctx);
        var eff = chooseEffect(a.effect, effect.*, key_state);
        const bytes: ?[]u8 = if (eff == 0) null else if (a.accept) |m| s.read(d, m) else null;
        if (bytes) |b| {
            sink.emit(sink.ctx, .drop, fromEffect(eff), pos, &.{}, b);
        } else {
            eff = 0;
            sink.emit(sink.ctx, .leave, .{}, pos, &.{}, null);
        }
        effect.* = eff;
        return t.S_OK;
    }

    fn read(s: *TargetImpl, d: *com.IDataObject, mime: MimeId) ?[]u8 {
        const cf = s.formats.cfOf(mime) orelse return null;
        const fe: t.FORMATETC = .{ .cfFormat = cf, .tymed = data_object.TYMED_HGLOBAL };
        var med: t.STGMEDIUM = .{ .tymed = 0, .u = .{ .hGlobal = null }, .pUnkForRelease = null };
        if (d.vtbl.GetData(d, &fe, &med) < 0) return null;
        return s.mem.readMedium(s.gpa, mime, &med) catch null;
    }

    fn refuse(effect: *t.DWORD) t.HRESULT {
        effect.* = 0;
        return t.S_OK;
    }

    /// Stops emitting (the window is going away) and drops the data.
    pub fn detach(s: *TargetImpl) void {
        s.sink = null;
        s.setData(null);
    }

    /// Drops the data of an unfinished drag.
    pub fn deinit(s: *TargetImpl) void {
        s.setData(null);
    }
};

/// The drop target COM object.
pub const Target = com.ComObject(com.IDropTarget.Vtbl, TargetImpl);

/// The drop source behind the COM object: Esc cancels, releasing every
/// button drops.
pub const SourceImpl = struct {
    /// Continue, drop or cancel.
    pub fn QueryContinueDrag(_: *SourceImpl, escape: t.BOOL, key_state: t.DWORD) t.HRESULT {
        if (escape != 0) return t.DRAGDROP_S_CANCEL;
        if (key_state & (MK.LBUTTON | MK.RBUTTON | MK.MBUTTON) == 0) return t.DRAGDROP_S_DROP;
        return t.S_OK;
    }

    /// OLE's default drag cursors.
    pub fn GiveFeedback(_: *SourceImpl, _: t.DWORD) t.HRESULT {
        return t.DRAGDROP_S_USEDEFAULTCURSORS;
    }
};

/// The drop source COM object.
pub const Source = com.ComObject(com.IDropSource.Vtbl, SourceImpl);

const testing = std.testing;

test "effects: modifiers, masks and refusal" {
    const copy_move: DragActions = .{ .copy = true, .move = true };
    try testing.expectEqual(3, toEffect(copy_move));
    try testing.expectEqual(DragActions{ .link = true }, fromEffect(4 | 0x8000_0000));
    // No modifiers: the first both allow.
    try testing.expectEqual(1, chooseEffect(copy_move, 7, 0));
    try testing.expectEqual(2, chooseEffect(copy_move, 2, 0));
    // Shift moves, Ctrl copies, both link when allowed.
    try testing.expectEqual(2, chooseEffect(copy_move, 7, MK.SHIFT));
    try testing.expectEqual(1, chooseEffect(copy_move, 7, MK.CONTROL));
    try testing.expectEqual(4, chooseEffect(.{ .copy = true, .link = true }, 7, MK.CONTROL | MK.SHIFT));
    // A modifier asking for what is not allowed falls back.
    try testing.expectEqual(1, chooseEffect(copy_move, 1, MK.SHIFT));
    // Nothing in common refuses.
    try testing.expectEqual(0, chooseEffect(.{ .move = true }, 1, 0));
    try testing.expectEqual(0, chooseEffect(.{}, 7, 0));
}

test "drop source: escape, buttons" {
    const o = try Source.create(testing.allocator, .{});
    const s: *com.IDropSource = @ptrCast(@alignCast(o.iface()));
    try testing.expectEqual(t.S_OK, s.vtbl.QueryContinueDrag(s, 0, MK.LBUTTON | MK.CONTROL));
    try testing.expectEqual(t.DRAGDROP_S_CANCEL, s.vtbl.QueryContinueDrag(s, 1, MK.LBUTTON));
    try testing.expectEqual(t.DRAGDROP_S_DROP, s.vtbl.QueryContinueDrag(s, 0, MK.SHIFT));
    try testing.expectEqual(t.DRAGDROP_S_USEDEFAULTCURSORS, s.vtbl.GiveFeedback(s, 1));
    try testing.expectEqual(0, com.IUnknown.release(s));
}

const TestSink = struct {
    events: std.ArrayList(struct { phase: DropPhase, allowed: DragActions, pos: [2]f32, mimes: []MimeId, data: ?[]u8 }) = .empty,
    ans: Answer = .{},

    fn sink(ts: *TestSink) Sink {
        return .{ .ctx = ts, .emit = emit, .answer = answer, .toClient = toClient };
    }
    fn emit(ctx: *anyopaque, phase: DropPhase, allowed: DragActions, pos: [2]f32, mimes: []const MimeId, data: ?[]u8) void {
        const ts: *TestSink = @ptrCast(@alignCast(ctx));
        if (phase == .enter) ts.ans = .{};
        ts.events.append(testing.allocator, .{ .phase = phase, .allowed = allowed, .pos = pos, .mimes = testing.allocator.dupe(MimeId, mimes) catch unreachable, .data = data }) catch unreachable;
    }
    fn answer(ctx: *anyopaque) Answer {
        const ts: *TestSink = @ptrCast(@alignCast(ctx));
        return ts.ans;
    }
    fn toClient(_: *anyopaque, pt: t.POINTL) [2]f32 {
        return .{ @floatFromInt(pt.x - 100), @floatFromInt(pt.y - 50) };
    }
    fn deinit(ts: *TestSink) void {
        for (ts.events.items) |e| {
            testing.allocator.free(e.mimes);
            if (e.data) |d| testing.allocator.free(d);
        }
        ts.events.deinit(testing.allocator);
    }
};

test "drop target: enter, over, drop with our data object; refcounts balance" {
    const gpa = testing.allocator;
    const mem = &data_object.test_memory.memory;
    const before = data_object.test_memory.liveBlocks();
    var ts: TestSink = .{};
    defer ts.deinit();
    const tobj = try Target.create(gpa, .{ .gpa = gpa, .sink = ts.sink(), .formats = data_object.test_formats, .mem = mem });
    const tgt: *com.IDropTarget = @ptrCast(@alignCast(tobj.iface()));
    const dobj = try data_object.create(gpa, &.{ .{ .mime = .text_utf8, .data = "héllo" }, .{ .mime = .uri_list, .data = "file:///C:/a.txt\r\n" } }, data_object.test_formats, mem);
    const d: *com.IDataObject = @ptrCast(@alignCast(dobj.iface()));

    // Enter: refused until the app answers; the data is held.
    var eff: t.DWORD = 3;
    try testing.expectEqual(t.S_OK, tgt.vtbl.DragEnter(tgt, d, MK.LBUTTON, .{ .x = 110, .y = 60 }, &eff));
    try testing.expectEqual(0, eff);
    try testing.expectEqual(2, dobj.refCount());
    const enter = ts.events.items[0];
    try testing.expectEqual(DropPhase.enter, enter.phase);
    try testing.expectEqual(DragActions{ .copy = true, .move = true }, enter.allowed);
    try testing.expectEqual([2]f32{ 10, 10 }, enter.pos);
    try testing.expectEqualSlices(MimeId, &.{ .uri_list, .text_utf8 }, enter.mimes);

    // The app accepts text with copy or move; Shift picks move.
    ts.ans = .{ .accept = .text_utf8, .effect = .{ .copy = true, .move = true } };
    eff = 3;
    try testing.expectEqual(t.S_OK, tgt.vtbl.DragOver(tgt, MK.LBUTTON | MK.SHIFT, .{ .x = 120, .y = 60 }, &eff));
    try testing.expectEqual(2, eff);
    try testing.expectEqual(DropPhase.over, ts.events.items[1].phase);
    // The same position and keys: no new event, same answer.
    eff = 3;
    _ = tgt.vtbl.DragOver(tgt, MK.LBUTTON | MK.SHIFT, .{ .x = 120, .y = 60 }, &eff);
    try testing.expectEqual(2, ts.events.items.len);
    try testing.expectEqual(2, eff);

    // Drop: the text, decoded; copy without modifiers.
    eff = 3;
    try testing.expectEqual(t.S_OK, tgt.vtbl.Drop(tgt, d, 0, .{ .x = 130, .y = 70 }, &eff));
    try testing.expectEqual(1, eff);
    const drop = ts.events.items[2];
    try testing.expectEqual(DropPhase.drop, drop.phase);
    try testing.expectEqual(DragActions{ .copy = true }, drop.allowed);
    try testing.expectEqualStrings("héllo", drop.data.?);
    try testing.expectEqual(1, dobj.refCount());
    try testing.expectEqual(before, data_object.test_memory.liveBlocks());

    // A refused drop is a leave.
    eff = 1;
    _ = tgt.vtbl.DragEnter(tgt, d, MK.LBUTTON, .{ .x = 100, .y = 50 }, &eff);
    eff = 1;
    _ = tgt.vtbl.Drop(tgt, d, 0, .{ .x = 100, .y = 50 }, &eff);
    try testing.expectEqual(0, eff);
    try testing.expectEqual(DropPhase.leave, ts.events.items[4].phase);
    // Enter then leave releases the data too.
    eff = 1;
    _ = tgt.vtbl.DragEnter(tgt, d, MK.LBUTTON, .{ .x = 100, .y = 50 }, &eff);
    try testing.expectEqual(2, dobj.refCount());
    _ = tgt.vtbl.DragLeave(tgt);
    try testing.expectEqual(DropPhase.leave, ts.events.items[6].phase);
    try testing.expectEqual(1, dobj.refCount());

    // A detached target refuses and emits nothing.
    tobj.impl.detach();
    eff = 1;
    _ = tgt.vtbl.DragEnter(tgt, d, MK.LBUTTON, .{ .x = 100, .y = 50 }, &eff);
    try testing.expectEqual(0, eff);
    _ = tgt.vtbl.DragLeave(tgt);
    try testing.expectEqual(7, ts.events.items.len);
    try testing.expectEqual(1, dobj.refCount());
    tobj.impl.sink = ts.sink();

    // An unfinished drag's data goes with the target.
    eff = 1;
    _ = tgt.vtbl.DragEnter(tgt, d, MK.LBUTTON, .{ .x = 100, .y = 50 }, &eff);
    try testing.expectEqual(0, com.IUnknown.release(tgt));
    try testing.expectEqual(0, com.IUnknown.release(d));
}
