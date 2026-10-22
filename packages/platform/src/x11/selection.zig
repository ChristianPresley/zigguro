//! X11 selections (ICCCM): CLIPBOARD and PRIMARY as owner and requestor,
//! with TARGETS, MULTIPLE, TIMESTAMP and INCR in both directions, and
//! XFIXES owner-change notification. Everything runs on a hidden window
//! from the thread that dispatches X events; the backend calls in with
//! its mutex held and drains `done` and `changed` into events.
//!
//! Requests from `own` and `read` never wait for a reply, so `submit`
//! from any thread is safe. Event handling reads properties with
//! `GetProperty` round trips on the dispatching thread.
//!
//! XDND (E01.F05.S03.T03) uses a third selection, `XdndSelection`:
//! `ownXdnd` while we drag, `readXdnd` to fetch a drop (its `Done` has
//! `xdnd` set).

const std = @import("std");
const Allocator = std.mem.Allocator;
const clipboard = @import("../api/clipboard.zig");
const MimeId = clipboard.MimeId;
const Selection = clipboard.Selection;
const Conn = @import("conn.zig").Conn;
const proto = @import("proto.zig");

const log = std.log.scoped(.x11_selection);

/// Atoms the selections need.
pub const atom_names = [_][]const u8{
    "CLIPBOARD",
    "TARGETS",
    "MULTIPLE",
    "TIMESTAMP",
    "INCR",
    "ATOM_PAIR",
    "UTF8_STRING",
    "TEXT",
    "text/plain;charset=utf-8",
    "text/plain",
    "text/html",
    "text/uri-list",
    "image/png",
    "application/x-zigguro-internal",
    "_ZG_SEL",
    "XdndSelection",
};
/// The interned `atom_names`.
pub const Atoms = @import("atoms.zig").AtomTable(&atom_names);

/// PropertyNotify states.
const property_new_value = 0;
const property_deleted = 1;

/// A finished `read`.
pub const Done = struct {
    request: u32,
    mime: MimeId,
    /// The bytes (owned by the receiver); empty on failure.
    data: []u8,
    ok: bool,
    /// A `readXdnd` answer.
    xdnd: bool = false,
};

/// The selections we handle: the api's two and XDND's.
const Slot = enum(u2) {
    clipboard,
    primary,
    xdnd,

    fn of(which: Selection) Slot {
        return @enumFromInt(@intFromEnum(which));
    }
};

const Item = struct { mime: MimeId, data: []u8 };

/// A conversion we asked an owner for.
const Read = struct {
    request: u32,
    mime: MimeId,
    which: Slot,
    time: u32,
    stage: enum { queued, targets, data, incr } = .queued,
    target: u32 = 0,
    buf: std.ArrayList(u8) = .empty,
    deadline_ns: u64,
};

/// An INCR transfer we are sending.
const Send = struct {
    requestor: u32,
    property: u32,
    type: u32,
    data: []u8,
    offset: usize = 0,
    deadline_ns: u64,
};

/// The selection state of one connection.
pub const Selections = struct {
    gpa: Allocator,
    conn: *Conn,
    atoms: Atoms,
    /// The hidden owner and requestor window.
    win: u32,
    /// The XFIXES event base, when the extension is usable.
    xfixes_event: ?u8 = null,
    items: [3][]Item = .{ &.{}, &.{}, &.{} },
    owned: [3]bool = .{ false, false, false },
    own_time: [3]u32 = .{ 0, 0, 0 },
    /// Reads in order; the first one is in progress.
    reads: std.ArrayList(Read) = .empty,
    sends: std.ArrayList(Send) = .empty,
    /// Finished reads, for the backend to turn into `clipboard_data`.
    done: std.ArrayList(Done) = .empty,
    /// Set when another client took a selection.
    changed: [2]bool = .{ false, false },
    timeout_ns: u64 = 5 * std.time.ns_per_s,
    /// Data larger than this goes by INCR, in chunks of this size.
    chunk: usize,

    /// Interns the atoms, creates the hidden window and asks XFIXES for
    /// owner changes.
    pub fn init(gpa: Allocator, conn: *Conn) !Selections {
        const s = conn.screen();
        const win = try conn.newXid();
        _ = try conn.request(proto.CreateWindow, .{
            .data = 0,
            .wid = win,
            .parent = s.root,
            .x = -10,
            .y = -10,
            .width = 1,
            .height = 1,
            .class = .input_only,
            .visual = 0,
            .values = .{ .values = .{ .event_mask = proto.EventMask.property_change } },
        }, &.{});
        var sel: Selections = .{
            .gpa = gpa,
            .conn = conn,
            .atoms = try conn.internAtoms(&atom_names),
            .win = win,
            .chunk = @min(@as(usize, conn.max_request_words), 256 * 1024),
        };
        if (conn.extension("XFIXES")) |x| {
            if (conn.reply(try conn.request(proto.XFixesQueryVersion, .{}, &.{}))) |v| {
                if (v.major >= 1) {
                    sel.xfixes_event = x.first_event;
                    for ([_]u32{ sel.atoms.get("CLIPBOARD"), proto.Atom.primary }) |a| {
                        _ = try conn.request(proto.XFixesSelectSelectionInput, .{ .window = win, .selection = a, .event_mask = 1 }, &.{});
                    }
                }
            } else |_| {}
        }
        try conn.flush();
        return sel;
    }

    /// Frees everything and destroys the window.
    pub fn deinit(s: *Selections) void {
        for (&s.items) |*it| s.freeItems(it);
        for (s.reads.items) |*r| r.buf.deinit(s.gpa);
        s.reads.deinit(s.gpa);
        for (s.sends.items) |x| s.gpa.free(x.data);
        s.sends.deinit(s.gpa);
        for (s.done.items) |d| s.gpa.free(d.data);
        s.done.deinit(s.gpa);
        _ = s.conn.request(proto.DestroyWindow, .{ .window = s.win }, &.{}) catch {};
    }

    fn freeItems(s: *Selections, items: *[]Item) void {
        for (items.*) |it| s.gpa.free(it.data);
        s.gpa.free(items.*);
        items.* = &.{};
    }

    fn selAtom(s: *const Selections, which: Slot) u32 {
        return switch (which) {
            .clipboard => s.atoms.get("CLIPBOARD"),
            .primary => proto.Atom.primary,
            .xdnd => s.atoms.get("XdndSelection"),
        };
    }

    fn whichOf(s: *const Selections, atom: u32) ?Slot {
        if (atom == s.atoms.get("CLIPBOARD")) return .clipboard;
        if (atom == proto.Atom.primary) return .primary;
        if (atom == s.atoms.get("XdndSelection")) return .xdnd;
        return null;
    }

    /// Takes `which` with copies of `items` (none gives it up).
    pub fn own(s: *Selections, which: Selection, items: []const clipboard.ClipItem, time: u32) !void {
        return s.ownSlot(.of(which), items, time);
    }

    /// Takes `XdndSelection` for a drag (no items gives it up).
    pub fn ownXdnd(s: *Selections, items: []const clipboard.ClipItem, time: u32) !void {
        return s.ownSlot(.xdnd, items, time);
    }

    fn ownSlot(s: *Selections, which: Slot, items: []const clipboard.ClipItem, time: u32) !void {
        const copy = try s.gpa.alloc(Item, items.len);
        var n: usize = 0;
        errdefer {
            for (copy[0..n]) |it| s.gpa.free(it.data);
            s.gpa.free(copy);
        }
        for (items) |it| {
            copy[n] = .{ .mime = it.mime, .data = try s.gpa.dupe(u8, it.data) };
            n += 1;
        }
        const i = @intFromEnum(which);
        s.freeItems(&s.items[i]);
        s.items[i] = copy;
        const take = items.len > 0;
        if (!take and !s.owned[i]) return;
        _ = try s.conn.request(proto.SetSelectionOwner, .{ .owner = if (take) s.win else 0, .selection = s.selAtom(which), .time = time }, &.{});
        // SelectionClear tells us if another client took it in between.
        s.owned[i] = take;
        s.own_time[i] = time;
    }

    /// Reads `which` as `mime`; the answer arrives in `done`. While we own
    /// the selection it is answered from our copy at once.
    pub fn read(s: *Selections, which: Selection, mime: MimeId, request: u32, time: u32, now_ns: u64) !void {
        return s.readSlot(.of(which), mime, request, time, now_ns);
    }

    /// Reads a drop from `XdndSelection` as `mime` at the drop's `time`;
    /// the answer arrives in `done` with `xdnd` set.
    pub fn readXdnd(s: *Selections, mime: MimeId, time: u32, now_ns: u64) !void {
        return s.readSlot(.xdnd, mime, 0, time, now_ns);
    }

    fn readSlot(s: *Selections, which: Slot, mime: MimeId, request: u32, time: u32, now_ns: u64) !void {
        const i = @intFromEnum(which);
        const xdnd = which == .xdnd;
        if (s.owned[i]) {
            try s.done.ensureUnusedCapacity(s.gpa, 1);
            for (s.items[i]) |it| if (it.mime == mime) {
                s.done.appendAssumeCapacity(.{ .request = request, .mime = mime, .data = try s.gpa.dupe(u8, it.data), .ok = true, .xdnd = xdnd });
                return;
            };
            s.done.appendAssumeCapacity(.{ .request = request, .mime = mime, .data = &.{}, .ok = false, .xdnd = xdnd });
            return;
        }
        try s.reads.append(s.gpa, .{ .request = request, .mime = mime, .which = which, .time = time, .deadline_ns = now_ns + s.timeout_ns });
        if (s.reads.items.len == 1) try s.startRead(now_ns);
    }

    fn startRead(s: *Selections, now_ns: u64) !void {
        const r = &s.reads.items[0];
        r.stage = .targets;
        r.deadline_ns = now_ns + s.timeout_ns;
        try s.convert(r, s.atoms.get("TARGETS"));
    }

    fn convert(s: *Selections, r: *Read, target: u32) !void {
        r.target = target;
        _ = try s.conn.request(proto.ConvertSelection, .{ .requestor = s.win, .selection = s.selAtom(r.which), .target = target, .property = s.atoms.get("_ZG_SEL"), .time = r.time }, &.{});
        try s.conn.flush();
    }

    /// Ends the current read and starts the next.
    fn finishRead(s: *Selections, ok: bool, now_ns: u64) void {
        var r = s.reads.orderedRemove(0);
        var data: []u8 = &.{};
        var good = ok;
        if (ok) {
            const converted = if (r.target == proto.Atom.string and r.mime == .text_utf8)
                latin1ToUtf8(s.gpa, r.buf.items)
            else
                r.buf.toOwnedSlice(s.gpa);
            data = converted catch blk: {
                good = false;
                break :blk &.{};
            };
        }
        r.buf.deinit(s.gpa);
        s.done.append(s.gpa, .{ .request = r.request, .mime = r.mime, .data = data, .ok = good, .xdnd = r.which == .xdnd }) catch {
            s.gpa.free(data);
            log.warn("selection answer dropped: out of memory", .{});
        };
        while (s.reads.items.len > 0) {
            s.startRead(now_ns) catch {
                var x = s.reads.orderedRemove(0);
                x.buf.deinit(s.gpa);
                s.done.append(s.gpa, .{ .request = x.request, .mime = x.mime, .data = &.{}, .ok = false, .xdnd = x.which == .xdnd }) catch {};
                continue;
            };
            break;
        }
    }

    /// Handles a selection-related event; false if `ev` is not one.
    pub fn handleEvent(s: *Selections, ev: []const u8, now_ns: u64) bool {
        const code = ev[0] & 0x7f;
        if (s.xfixes_event) |base| if (code == base) {
            // XFixesSelectionNotify: subtype, window, owner, selection.
            const owner = u32At(ev, 8);
            if (s.whichOf(u32At(ev, 12))) |w| if (owner != s.win and w != .xdnd) {
                s.changed[@intFromEnum(w)] = true;
            };
            return true;
        };
        switch (code) {
            proto.EventCode.selection_request => {
                s.onRequest(ev, now_ns) catch |err| log.warn("answering a selection request: {t}", .{err});
                return true;
            },
            proto.EventCode.selection_notify => {
                if (u32At(ev, 8) != s.win) return false;
                s.onNotify(u32At(ev, 20), now_ns) catch |err| {
                    log.warn("reading a selection: {t}", .{err});
                    if (s.reads.items.len > 0) s.finishRead(false, now_ns);
                };
                return true;
            },
            proto.EventCode.selection_clear => {
                if (u32At(ev, 8) != s.win) return false;
                const w = s.whichOf(u32At(ev, 12)) orelse return true;
                s.owned[@intFromEnum(w)] = false;
                s.freeItems(&s.items[@intFromEnum(w)]);
                return true;
            },
            proto.EventCode.property_notify => {
                const win = u32At(ev, 4);
                const atom = u32At(ev, 8);
                const state = ev[16];
                if (win == s.win) {
                    if (atom == s.atoms.get("_ZG_SEL") and state == property_new_value) s.onIncrChunk(now_ns) catch |err| {
                        log.warn("INCR read: {t}", .{err});
                        if (s.reads.items.len > 0) s.finishRead(false, now_ns);
                    };
                    return true;
                }
                if (state != property_deleted) return false;
                for (s.sends.items, 0..) |*x, i| if (x.requestor == win and x.property == atom) {
                    s.sendChunk(x, now_ns) catch |err| {
                        log.warn("INCR send: {t}", .{err});
                        s.dropSend(i);
                        return true;
                    };
                    if (x.offset > x.data.len) s.dropSend(i);
                    return true;
                };
                return false;
            },
            else => return false,
        }
    }

    // ---- requestor ----

    fn onNotify(s: *Selections, property: u32, now_ns: u64) !void {
        if (s.reads.items.len == 0) return;
        const r = &s.reads.items[0];
        if (r.stage == .queued or r.stage == .incr) return;
        if (property == 0) {
            // No TARGETS: try the best target blindly.
            if (r.stage == .targets) {
                const cands = s.targetsFor(r.mime);
                if (cands.len == 0) return s.finishRead(false, now_ns);
                r.stage = .data;
                return s.convert(r, cands.get(0));
            }
            return s.finishRead(false, now_ns);
        }
        const p = try s.conn.reply(try s.conn.request(proto.GetProperty, .{ .data = true, .window = s.win, .property = property }, &.{}));
        if (p.type == s.atoms.get("INCR")) {
            // Deleting the property (above) started the transfer.
            r.stage = .incr;
            r.buf.clearRetainingCapacity();
            r.deadline_ns = now_ns + s.timeout_ns;
            return;
        }
        switch (r.stage) {
            .targets => {
                const offered = if (p.format == 32) p.value else &.{};
                const target = s.pickTarget(r.mime, offered) orelse return s.finishRead(false, now_ns);
                r.stage = .data;
                try s.convert(r, target);
            },
            .data => {
                try r.buf.appendSlice(s.gpa, p.value);
                s.finishRead(true, now_ns);
            },
            .queued, .incr => {},
        }
    }

    fn onIncrChunk(s: *Selections, now_ns: u64) !void {
        if (s.reads.items.len == 0) return;
        const r = &s.reads.items[0];
        if (r.stage != .incr) return;
        const p = try s.conn.reply(try s.conn.request(proto.GetProperty, .{ .data = true, .window = s.win, .property = s.atoms.get("_ZG_SEL") }, &.{}));
        if (p.value.len == 0) return s.finishRead(true, now_ns);
        try r.buf.appendSlice(s.gpa, p.value);
        r.deadline_ns = now_ns + s.timeout_ns;
    }

    /// The format target `atom` carries, if we know it.
    pub fn mimeOfTarget(s: *const Selections, atom: u32) ?MimeId {
        inline for (.{ MimeId.text_utf8, .uri_list, .html, .png, .zigguro_internal }) |m| {
            if (s.targetsFor(m).has(atom)) return m;
        }
        return null;
    }

    /// Target atoms for `mime`, best first.
    pub fn targetsFor(s: *const Selections, mime: MimeId) Targets {
        var t: Targets = .{};
        const a = &s.atoms;
        switch (mime) {
            .text_utf8 => {
                t.add(a.get("UTF8_STRING"));
                t.add(a.get("text/plain;charset=utf-8"));
                t.add(a.get("text/plain"));
                t.add(proto.Atom.string);
                t.add(a.get("TEXT"));
            },
            .uri_list => t.add(a.get("text/uri-list")),
            .html => t.add(a.get("text/html")),
            .png => t.add(a.get("image/png")),
            .zigguro_internal => t.add(a.get("application/x-zigguro-internal")),
            _ => {},
        }
        return t;
    }

    /// The best of `offered` (a TARGETS reply, 32-bit atoms) for `mime`.
    fn pickTarget(s: *const Selections, mime: MimeId, offered: []const u8) ?u32 {
        const cands = s.targetsFor(mime);
        for (cands.slice()) |c| {
            var i: usize = 0;
            while (i + 4 <= offered.len) : (i += 4) if (u32At(offered, i) == c) return c;
        }
        return null;
    }

    // ---- owner ----

    fn onRequest(s: *Selections, ev: []const u8, now_ns: u64) !void {
        const time = u32At(ev, 4);
        const requestor = u32At(ev, 12);
        const selection = u32At(ev, 16);
        const target = u32At(ev, 20);
        // Obsolete clients pass None: use the target as the property.
        const property = if (u32At(ev, 24) == 0) target else u32At(ev, 24);
        var ok = false;
        // Requests are not checked against the acquisition time: many
        // requestors pass a stale event time.
        if (s.whichOf(selection)) |which| if (s.owned[@intFromEnum(which)]) {
            ok = if (target == s.atoms.get("MULTIPLE"))
                try s.convertMultiple(which, requestor, property, now_ns)
            else
                try s.convertInto(which, requestor, target, property, now_ns);
        };
        var out: [32]u8 = @splat(0);
        out[0] = proto.EventCode.selection_notify;
        std.mem.writeInt(u32, out[4..8], time, .little);
        std.mem.writeInt(u32, out[8..12], requestor, .little);
        std.mem.writeInt(u32, out[12..16], selection, .little);
        std.mem.writeInt(u32, out[16..20], target, .little);
        std.mem.writeInt(u32, out[20..24], if (ok) property else 0, .little);
        _ = try s.conn.request(proto.SendEvent, .{ .destination = requestor, .event_mask = 0, .event = out }, &.{});
        try s.conn.flush();
    }

    /// MULTIPLE: converts each (target, property) pair in order and
    /// writes the list back with failed properties set to None.
    fn convertMultiple(s: *Selections, which: Slot, requestor: u32, property: u32, now_ns: u64) !bool {
        const p = try s.conn.reply(try s.conn.request(proto.GetProperty, .{ .window = requestor, .property = property }, &.{}));
        if (p.format != 32 or p.value.len % 8 != 0) return false;
        const pairs = try s.gpa.dupe(u8, p.value);
        defer s.gpa.free(pairs);
        var i: usize = 0;
        while (i < pairs.len) : (i += 8) {
            const t = u32At(pairs, i);
            const prop = u32At(pairs, i + 4);
            const done = prop != 0 and t != s.atoms.get("MULTIPLE") and try s.convertInto(which, requestor, t, prop, now_ns);
            if (!done) std.mem.writeInt(u32, pairs[i + 4 ..][0..4], 0, .little);
        }
        try s.setProp(requestor, property, s.atoms.get("ATOM_PAIR"), 32, pairs);
        return true;
    }

    /// Stores `target` in `property` on `requestor`; false if we cannot.
    fn convertInto(s: *Selections, which: Slot, requestor: u32, target: u32, property: u32, now_ns: u64) !bool {
        const a = &s.atoms;
        const items = s.items[@intFromEnum(which)];
        if (target == a.get("TARGETS")) {
            var list: [32]u32 = undefined;
            var n: usize = 0;
            for ([_]u32{ a.get("TARGETS"), a.get("MULTIPLE"), a.get("TIMESTAMP") }) |x| {
                list[n] = x;
                n += 1;
            }
            for (items) |it| for (s.targetsFor(it.mime).slice()) |x| if (n < list.len) {
                list[n] = x;
                n += 1;
            };
            var bytes: [32 * 4]u8 = undefined;
            for (list[0..n], 0..) |x, k| std.mem.writeInt(u32, bytes[k * 4 ..][0..4], x, .little);
            try s.setProp(requestor, property, proto.Atom.atom, 32, bytes[0 .. n * 4]);
            return true;
        }
        if (target == a.get("TIMESTAMP")) {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, s.own_time[@intFromEnum(which)], .little);
            try s.setProp(requestor, property, proto.Atom.integer, 32, &bytes);
            return true;
        }
        const item = for (items) |it| {
            if (s.targetsFor(it.mime).has(target)) break it;
        } else return false;
        // TEXT lets the owner pick the type; STRING is Latin-1.
        const ty = if (target == a.get("TEXT")) a.get("UTF8_STRING") else target;
        var latin: ?[]u8 = null;
        defer if (latin) |l| s.gpa.free(l);
        if (target == proto.Atom.string) latin = try utf8ToLatin1(s.gpa, item.data);
        const bytes = latin orelse item.data;
        if (bytes.len <= s.chunk) {
            try s.setProp(requestor, property, ty, 8, bytes);
            return true;
        }
        // INCR: announce the size, then send chunks as the requestor
        // deletes the property.
        try s.sends.ensureUnusedCapacity(s.gpa, 1);
        const copy = try s.gpa.dupe(u8, bytes);
        errdefer s.gpa.free(copy);
        _ = try s.conn.request(proto.ChangeWindowAttributes, .{ .window = requestor, .values = .{ .values = .{ .event_mask = proto.EventMask.property_change } } }, &.{});
        var size: [4]u8 = undefined;
        std.mem.writeInt(u32, &size, @intCast(@min(bytes.len, std.math.maxInt(u32))), .little);
        try s.setProp(requestor, property, a.get("INCR"), 32, &size);
        s.sends.appendAssumeCapacity(.{ .requestor = requestor, .property = property, .type = ty, .data = copy, .deadline_ns = now_ns + s.timeout_ns });
        return true;
    }

    /// The next INCR chunk; after the last, a zero-length write, and
    /// `offset` moves past the end.
    fn sendChunk(s: *Selections, x: *Send, now_ns: u64) !void {
        const n = @min(s.chunk, x.data.len - x.offset);
        try s.setProp(x.requestor, x.property, x.type, 8, x.data[x.offset..][0..n]);
        try s.conn.flush();
        x.offset += if (n == 0) 1 else n;
        x.deadline_ns = now_ns + s.timeout_ns;
    }

    fn dropSend(s: *Selections, i: usize) void {
        const x = s.sends.swapRemove(i);
        s.gpa.free(x.data);
        for (s.sends.items) |o| if (o.requestor == x.requestor) return;
        _ = s.conn.request(proto.ChangeWindowAttributes, .{ .window = x.requestor, .values = .{ .values = .{ .event_mask = 0 } } }, &.{}) catch {};
    }

    fn setProp(s: *Selections, window: u32, property: u32, ty: u32, format: u8, bytes: []const u8) !void {
        _ = try s.conn.request(proto.ChangeProperty, .{ .window = window, .property = property, .type = ty, .format = format, .length = @intCast(bytes.len / (format / 8)), .bytes = bytes }, &.{});
    }

    // ---- time ----

    /// Fails reads and drops sends whose deadline has passed.
    pub fn expire(s: *Selections, now_ns: u64) void {
        if (s.reads.items.len > 0 and s.reads.items[0].stage != .queued and now_ns >= s.reads.items[0].deadline_ns) {
            log.warn("selection read timed out", .{});
            s.finishRead(false, now_ns);
        }
        var i: usize = 0;
        while (i < s.sends.items.len) {
            if (now_ns >= s.sends.items[i].deadline_ns) s.dropSend(i) else i += 1;
        }
    }

    /// The earliest deadline, if anything is in flight.
    pub fn nextDeadline(s: *const Selections) ?u64 {
        var next: ?u64 = if (s.reads.items.len > 0) s.reads.items[0].deadline_ns else null;
        for (s.sends.items) |x| next = if (next) |n| @min(n, x.deadline_ns) else x.deadline_ns;
        return next;
    }
};

/// Target atoms for one format, best first.
pub const Targets = struct {
    atoms: [5]u32 = undefined,
    len: usize = 0,

    fn add(t: *Targets, a: u32) void {
        t.atoms[t.len] = a;
        t.len += 1;
    }
    /// The atoms.
    pub fn slice(t: *const Targets) []const u32 {
        return t.atoms[0..t.len];
    }
    fn get(t: *const Targets, i: usize) u32 {
        return t.atoms[i];
    }
    fn has(t: *const Targets, a: u32) bool {
        return std.mem.indexOfScalar(u32, t.slice(), a) != null;
    }
};

/// UTF-8 → Latin-1 for the STRING target; other characters become `?`.
pub fn utf8ToLatin1(gpa: Allocator, utf8: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var it = std.unicode.Utf8Iterator{ .bytes = utf8, .i = 0 };
    while (it.i < utf8.len) {
        const len = std.unicode.utf8ByteSequenceLength(utf8[it.i]) catch {
            it.i += 1;
            try out.append(gpa, '?');
            continue;
        };
        const end = @min(it.i + len, utf8.len);
        const cp = std.unicode.utf8Decode(utf8[it.i..end]) catch '?';
        it.i = end;
        try out.append(gpa, if (cp <= 0xff) @intCast(cp) else '?');
    }
    return out.toOwnedSlice(gpa);
}

/// Latin-1 (a STRING answer) → UTF-8.
pub fn latin1ToUtf8(gpa: Allocator, latin: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (latin) |c| {
        if (c < 0x80) {
            try out.append(gpa, c);
        } else try out.appendSlice(gpa, &.{ 0xc0 | (c >> 6), 0x80 | (c & 0x3f) });
    }
    return out.toOwnedSlice(gpa);
}

fn u32At(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

const testing = std.testing;

test "Latin-1 conversions for STRING" {
    const l = try utf8ToLatin1(testing.allocator, "café ✓");
    defer testing.allocator.free(l);
    try testing.expectEqualSlices(u8, "caf\xe9 ?", l);
    const u = try latin1ToUtf8(testing.allocator, l);
    defer testing.allocator.free(u);
    try testing.expectEqualStrings("café ?", u);
}
