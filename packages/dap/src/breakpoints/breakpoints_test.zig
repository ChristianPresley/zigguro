//! The breakpoint model: toggling, line tracking through edits, sync with
//! sessions of `fake_dap_adapter` scripts (testdata/sessions/bp_*.txt),
//! feature gates, exception filters, data breakpoints and persistence.

const std = @import("std");
const BreakpointManager = @import("BreakpointManager.zig");
const LineTracker = @import("LineTracker.zig");
const decorate = @import("decorate.zig");
const persist = @import("persist.zig");
const DebugSession = @import("../session/DebugSession.zig");
const test_harness = @import("../session/test_harness.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Io = std.Io;
const Harness = test_harness.Harness;

fn lineOf(m: *BreakpointManager, id: BreakpointManager.BpId) !u32 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const v = (try m.get(arena.allocator(), id)) orelse return error.Missing;
    return v.bp.kind.source.line;
}

fn src(path: []const u8, line: u32) BreakpointManager.Breakpoint {
    return .{ .kind = .{ .source = .{ .path = path, .line = line } } };
}

test "bp: toggle via gutter callback" {
    var m: BreakpointManager = .init(gpa, testing.io, .{});
    defer m.deinit();
    const id = (try m.toggleLine("/w/a.zig", 4)).?;
    try testing.expectEqual(@as(u32, 4), try lineOf(&m, id));
    _ = (try m.toggleLine("/w/a.zig", 9)).?;
    try testing.expectEqual(@as(?BreakpointManager.BpId, null), try m.toggleLine("/w/a.zig", 4));
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const left = try m.list(arena.allocator());
    try testing.expectEqual(@as(usize, 1), left.len);
    try testing.expectEqual(@as(u32, 9), left[0].bp.kind.source.line);
    // Glyphs follow the kind and state.
    const id2 = try m.add(.{ .kind = .{ .source = .{ .path = "/w/a.zig", .line = 12, .log_message = "x" } } });
    const id3 = try m.add(.{ .kind = .{ .source = .{ .path = "/w/a.zig", .line = 14, .condition = "y" } } });
    try m.update(id3, .{ .enabled = false });
    const marks = try decorate.marks(&m, arena.allocator(), "/w/a.zig");
    try testing.expectEqual(@as(usize, 3), marks.len);
    try testing.expectEqual(decorate.Glyph.breakpoint, marks[0].glyph);
    try testing.expectEqual(decorate.Glyph.logpoint, marks[1].glyph);
    try testing.expectEqual(id2, marks[1].id);
    try testing.expectEqual(decorate.Glyph.disabled, marks[2].glyph);
    try testing.expect(!marks[0].hollow);
    // The execution pointer.
    var buf: [2]decorate.ExecMark = undefined;
    const ex = decorate.execMarks("/w/a.zig", .{ .path = "/w/a.zig", .line = 9 }, .{ .path = "/w/a.zig", .line = 20 }, &buf);
    try testing.expectEqual(@as(usize, 2), ex.len);
    try testing.expectEqual(decorate.ExecStyle.top, ex[0].style);
    try testing.expectEqual(@as(u32, 20), ex[1].line);
    try testing.expectEqual(@as(usize, 0), decorate.execMarks("/w/b.zig", .{ .path = "/w/a.zig", .line = 9 }, null, &buf).len);
}

test "bp: anchor follows edits" {
    var t: LineTracker = .init(gpa);
    defer t.deinit();
    var m: BreakpointManager = .init(gpa, testing.io, .{ .host = t.host() });
    defer m.deinit();
    try t.openDoc("/w/a.zig");
    m.docOpened("/w/a.zig");
    const a = try m.add(src("/w/a.zig", 10));
    const b = try m.add(src("/w/a.zig", 20));
    t.insertLines("/w/a.zig", 5, 3); // above both
    try testing.expectEqual(@as(u32, 13), try lineOf(&m, a));
    try testing.expectEqual(@as(u32, 23), try lineOf(&m, b));
    t.insertLines("/w/a.zig", 15, 1); // between
    try testing.expectEqual(@as(u32, 13), try lineOf(&m, a));
    try testing.expectEqual(@as(u32, 24), try lineOf(&m, b));
    t.deleteLines("/w/a.zig", 1, 2); // above
    try testing.expectEqual(@as(u32, 11), try lineOf(&m, a));
    // Deleting a's line keeps it on the merged line.
    t.deleteLines("/w/a.zig", 10, 3);
    try testing.expectEqual(@as(u32, 10), try lineOf(&m, a));
    try testing.expectEqual(@as(u32, 19), try lineOf(&m, b));
    // Toggling the moved line removes the breakpoint there.
    try testing.expectEqual(@as(?BreakpointManager.BpId, null), try m.toggleLine("/w/a.zig", 19));
}

test "bp: frozen line when closed and re-anchored on open" {
    var t: LineTracker = .init(gpa);
    defer t.deinit();
    var m: BreakpointManager = .init(gpa, testing.io, .{ .host = t.host() });
    defer m.deinit();
    // Added while the document is closed: kept as a plain line.
    const a = try m.add(src("/w/a.zig", 10));
    try t.openDoc("/w/a.zig");
    m.docOpened("/w/a.zig");
    t.insertLines("/w/a.zig", 1, 5);
    try testing.expectEqual(@as(u32, 15), try lineOf(&m, a));
    m.docClosed("/w/a.zig");
    t.closeDoc("/w/a.zig");
    try testing.expectEqual(@as(u32, 15), try lineOf(&m, a));
    // Open again: tracked from the frozen line.
    try t.openDoc("/w/a.zig");
    m.docOpened("/w/a.zig");
    t.deleteLines("/w/a.zig", 1, 1);
    try testing.expectEqual(@as(u32, 14), try lineOf(&m, a));
    // A rename moves it.
    try m.renamed("/w/a.zig", "/w/b.zig");
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try testing.expectEqualStrings("/w/b.zig", (try m.get(arena.allocator(), a)).?.bp.kind.source.path);
}

fn runningOrEnded(_: *Harness, s: *DebugSession) bool {
    return s.state() == .running or s.ended_event.isSet();
}

/// A harness whose sessions use `m`.
fn startWith(h: *Harness, m: *BreakpointManager, script: []const u8) !*DebugSession {
    try h.init(&.{script}, .{ .breakpoints = m.sink() });
    const s = try h.start(.launch);
    try h.waitFor(s, runningOrEnded);
    try testing.expectEqual(.running, s.state());
    return s;
}

fn stopAndCheck(h: *Harness, s: *DebugSession) !void {
    s.stop();
    try h.waitFor(s, Harness.ended);
    try h.expectScriptPassed(s);
}

test "bp: setBreakpoints index mapping and verification" {
    var m: BreakpointManager = .init(gpa, testing.io, .{});
    defer m.deinit();
    const b1 = try m.add(src("/w/a.zig", 3));
    const b2 = try m.add(.{ .kind = .{ .source = .{ .path = "/w/a.zig", .line = 7, .condition = "i > 1" } } });
    const off = try m.add(.{ .enabled = false, .kind = .{ .source = .{ .path = "/w/a.zig", .line = 9 } } });
    const b3 = try m.add(.{ .kind = .{ .source = .{ .path = "/w/a.zig", .line = 11, .log_message = "x={x}" } } });
    var h: Harness = undefined;
    const s = try startWith(&h, &m, "bp_sync.txt");
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const st1 = (try m.stateIn(a, b1, s)).?;
    try testing.expect(st1.verified);
    try testing.expectEqual(@as(?u32, 4), st1.actual_line);
    try testing.expectEqual(@as(?i64, 1), st1.adapter_id);
    const st2 = (try m.stateIn(a, b2, s)).?;
    try testing.expect(!st2.verified);
    try testing.expectEqualStrings("no code", st2.message.?);
    try testing.expect((try m.stateIn(a, b3, s)).?.verified);
    try testing.expectEqual(@as(?BreakpointManager.SessionBpState, null), try m.stateIn(a, off, s));
    // Unverified shows hollow while the session runs.
    const marks = try decorate.marks(&m, a, "/w/a.zig");
    try testing.expect(!marks[0].hollow);
    try testing.expect(marks[1].hollow);
    try stopAndCheck(&h, s);
    // The session's states go with it.
    try testing.expectEqual(@as(?BreakpointManager.SessionBpState, null), try m.stateIn(a, b1, s));
}

fn adoptedC(m: *BreakpointManager) bool {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const vs = m.list(arena.allocator()) catch return false;
    for (vs) |v| if (v.adopted and std.mem.eql(u8, v.bp.kind.source.path, "/w/c.zig")) return true;
    return false;
}

test "bp: breakpoint event changed/new/removed" {
    var m: BreakpointManager = .init(gpa, testing.io, .{});
    defer m.deinit();
    const b1 = try m.add(src("/w/a.zig", 3));
    var h: Harness = undefined;
    const s = try startWith(&h, &m, "bp_events.txt");
    defer h.deinit();
    const deadline = Io.Timestamp.now(testing.io, .awake).addDuration(.fromSeconds(10));
    while (!adoptedC(&m)) {
        if (Io.Timestamp.now(testing.io, .awake).nanoseconds > deadline.nanoseconds) return error.Timeout;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const st = (try m.stateIn(a, b1, s)).?;
    try testing.expect(st.verified);
    try testing.expectEqual(@as(?u32, 5), st.actual_line);
    const vs = try m.list(a);
    // b.zig was adopted and removed again; c.zig stays.
    try testing.expectEqual(@as(usize, 2), vs.len);
    try testing.expectEqualStrings("/w/c.zig", vs[1].bp.kind.source.path);
    try testing.expectEqual(@as(u32, 2), vs[1].bp.kind.source.line);
    try testing.expect(vs[1].verified);
    try stopAndCheck(&h, s);
}

test "bp: unsupported attributes stripped and flagged" {
    var m: BreakpointManager = .init(gpa, testing.io, .{});
    defer m.deinit();
    const c = try m.add(.{ .kind = .{ .source = .{ .path = "/w/a.zig", .line = 3, .condition = "i > 1" } } });
    const hc = try m.add(.{ .kind = .{ .source = .{ .path = "/w/a.zig", .line = 5, .hit_condition = "3" } } });
    const lp = try m.add(.{ .kind = .{ .source = .{ .path = "/w/a.zig", .line = 7, .log_message = "x" } } });
    const f = try m.add(.{ .kind = .{ .function = .{ .name = "main" } } });
    var h: Harness = undefined;
    const s = try startWith(&h, &m, "bp_gating.txt");
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const sc = (try m.stateIn(a, c, s)).?;
    try testing.expect(sc.unsupported and sc.verified);
    try testing.expectEqualStrings("condition ignored: adapter does not support conditional breakpoints", sc.message.?);
    const sh = (try m.stateIn(a, hc, s)).?;
    try testing.expect(sh.unsupported);
    try testing.expectEqualStrings("hit count ignored: adapter does not support hit conditional breakpoints", sh.message.?);
    const sl = (try m.stateIn(a, lp, s)).?;
    try testing.expect(sl.unsupported and !sl.verified);
    const sf = (try m.stateIn(a, f, s)).?;
    try testing.expect(sf.unsupported);
    try testing.expectEqualStrings("adapter does not support function breakpoints", sf.message.?);
    try testing.expect((try decorate.marks(&m, a, "/w/a.zig"))[0].warning);
    try stopAndCheck(&h, s);
}

test "bp: function breakpoints gating" {
    var m: BreakpointManager = .init(gpa, testing.io, .{});
    defer m.deinit();
    const f = try m.add(.{ .kind = .{ .function = .{ .name = "main" } } });
    var h: Harness = undefined;
    const s = try startWith(&h, &m, "bp_function.txt");
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const st = (try m.stateIn(arena.allocator(), f, s)).?;
    try testing.expect(st.verified and !st.unsupported);
    try testing.expectEqual(@as(?i64, 4), st.adapter_id);
    try stopAndCheck(&h, s);
}

test "bp: exception filters defaults/persist/conditions" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var m: BreakpointManager = .init(gpa, testing.io, .{ .persist = .{ .dir = tmp.dir, .debounce = .fromMilliseconds(20) } });
    defer m.deinit();
    try m.load(
        \\.{ .version = 1, .exception_filters = .{ .{ .adapter_type = "fake", .filter = "raised", .enabled = true } } }
    );
    var h: Harness = undefined;
    const s = try startWith(&h, &m, "bp_exceptions.txt");
    defer h.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const fs = try m.exceptionFilters(arena.allocator(), s);
    try testing.expectEqual(@as(usize, 2), fs.len);
    try testing.expect(fs[0].enabled); // remembered
    try testing.expect(fs[1].enabled); // the default
    try testing.expect(fs[1].supports_condition);
    try m.setExceptionFilter("fake", "uncaught", true, "err == 3");
    try stopAndCheck(&h, s);
    try m.saveNow();
    const text = try tmp.dir.readFileAlloc(testing.io, persist.sub_path, gpa, .limited(1 << 20));
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, ".condition = \"err == 3\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, ".filter = \"raised\"") != null);
}

const Info = struct {
    arena: std.heap.ArenaAllocator,
    got: Io.Event = .unset,
    id: ?[]const u8 = null,
    can_persist: bool = true,
    access: usize = 0,

    fn cb(i: *Info) BreakpointManager.InfoCb {
        return .{ .ctx = i, .func = done };
    }

    fn done(ctx: ?*anyopaque, info: ?BreakpointManager.DataInfo) void {
        const i: *Info = @ptrCast(@alignCast(ctx.?));
        if (info) |x| {
            i.id = if (x.data_id) |d| i.arena.allocator().dupe(u8, d) catch null else null;
            i.can_persist = x.can_persist;
            i.access = x.access_types.len;
        }
        i.got.set(testing.io);
    }
};

fn dataVerified(m: *BreakpointManager) bool {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const vs = m.list(arena.allocator()) catch return false;
    return vs.len == 1 and vs[0].verified;
}

test "bp: data breakpoint info flow" {
    var m: BreakpointManager = .init(gpa, testing.io, .{});
    defer m.deinit();
    var h: Harness = undefined;
    const s = try startWith(&h, &m, "bp_data.txt");
    defer h.deinit();
    var info: Info = .{ .arena = .init(gpa) };
    defer info.arena.deinit();
    m.dataBreakpointInfo(s, 7, "count", info.cb());
    try info.got.waitTimeout(testing.io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    try testing.expectEqualStrings("0x1000", info.id.?);
    try testing.expectEqual(@as(usize, 2), info.access);
    try testing.expect(!info.can_persist);
    _ = try m.add(.{ .kind = .{ .data = .{ .data_id = info.id.?, .description = "count", .can_persist = false } } });
    const deadline = Io.Timestamp.now(testing.io, .awake).addDuration(.fromSeconds(10));
    while (!dataVerified(&m)) {
        if (Io.Timestamp.now(testing.io, .awake).nanoseconds > deadline.nanoseconds) return error.Timeout;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    try stopAndCheck(&h, s);
    // It cannot persist: gone with the session.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    try testing.expectEqual(@as(usize, 0), (try m.list(arena.allocator())).len);
}

test "bp: persistence roundtrip and atomic write" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = if (@import("builtin").os.tag == .windows) "C:\\w" else "/w";
    const in_ws = if (@import("builtin").os.tag == .windows) "C:\\w\\src\\a.zig" else "/w/src/a.zig";
    {
        var m: BreakpointManager = .init(gpa, testing.io, .{ .persist = .{ .dir = tmp.dir, .workspace_root = root, .debounce = .fromMilliseconds(20) } });
        defer m.deinit();
        _ = try m.add(.{ .kind = .{ .source = .{ .path = in_ws, .line = 12, .condition = "i > 3" } } });
        _ = try m.add(.{ .enabled = false, .kind = .{ .source = .{ .path = "/elsewhere/b.zig", .line = 1, .log_message = "hi {x}" } } });
        _ = try m.add(.{ .kind = .{ .function = .{ .name = "main", .hit_condition = "2" } } });
        _ = try m.add(.{ .kind = .{ .instruction = .{ .reference = "0x40", .offset = -4 } } });
        _ = try m.add(.{ .kind = .{ .data = .{ .data_id = "0x10", .description = "x", .access = .readWrite } } });
        _ = try m.add(.{ .kind = .{ .data = .{ .data_id = "0x20", .description = "tmp", .can_persist = false } } });
        // Debounced: one save once changes stop.
        const deadline = Io.Timestamp.now(testing.io, .awake).addDuration(.fromSeconds(10));
        while (true) {
            m.mutex.lockUncancelable(testing.io);
            const saves = m.saves;
            m.mutex.unlock(testing.io);
            if (saves >= 1) break;
            if (Io.Timestamp.now(testing.io, .awake).nanoseconds > deadline.nanoseconds) return error.Timeout;
            try testing.io.sleep(.fromMilliseconds(10), .awake);
        }
    }
    const text = try tmp.dir.readFileAlloc(testing.io, persist.sub_path, gpa, .limited(1 << 20));
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, ".path = \"src/a.zig\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "0x20") == null);
    // Only the file itself: the temporary file was renamed over it.
    var dir = try tmp.dir.openDir(testing.io, "debug", .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(testing.io)) |e| {
        try testing.expectEqualStrings("breakpoints.zon", e.name);
        n += 1;
    }
    try testing.expectEqual(@as(usize, 1), n);

    var m2: BreakpointManager = .init(gpa, testing.io, .{ .persist = .{ .dir = tmp.dir, .workspace_root = root } });
    defer m2.deinit();
    try m2.load(text);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const vs = try m2.list(arena.allocator());
    try testing.expectEqual(@as(usize, 5), vs.len);
    try testing.expectEqualStrings(in_ws, vs[0].bp.kind.source.path);
    try testing.expectEqualStrings("i > 3", vs[0].bp.kind.source.condition.?);
    try testing.expect(!vs[1].bp.enabled);
    try testing.expectEqualStrings("hi {x}", vs[1].bp.kind.source.log_message.?);
    try testing.expectEqualStrings("2", vs[2].bp.kind.function.hit_condition.?);
    try testing.expectEqual(@as(i64, -4), vs[3].bp.kind.instruction.offset);
    try testing.expectEqual(BreakpointManager.Access.readWrite, vs[4].bp.kind.data.access);
    try testing.expectError(error.UnsupportedVersion, m2.load(".{ .version = 9 }"));
}

test "bp: resend on save with sourceModified" {
    var t: LineTracker = .init(gpa);
    defer t.deinit();
    var m: BreakpointManager = .init(gpa, testing.io, .{ .host = t.host(), .send_on_edit = .immediate, .edit_settle = .fromMilliseconds(30) });
    defer m.deinit();
    try t.openDoc("/w/a.zig");
    m.docOpened("/w/a.zig");
    _ = try m.add(src("/w/a.zig", 3));
    var h: Harness = undefined;
    const s = try startWith(&h, &m, "bp_resend.txt");
    defer h.deinit();
    // Two lines inserted above, then saved.
    t.insertLines("/w/a.zig", 1, 2);
    t.setDirty("/w/a.zig", false);
    m.documentSaved("/w/a.zig");
    // One more, unsaved: sent once edits settle.
    t.insertLines("/w/a.zig", 1, 1);
    m.documentEdited("/w/a.zig");
    m.documentEdited("/w/a.zig");
    // Let the settled re-send go out before stopping.
    while (true) {
        m.mutex.lockUncancelable(testing.io);
        const pending = m.edit_timer;
        m.mutex.unlock(testing.io);
        if (!pending) break;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    }
    try testing.io.sleep(.fromMilliseconds(200), .awake);
    try stopAndCheck(&h, s);
}

test "bp: the fast breakpoints.zon reader matches std.zon" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\// saved by zigguro
        \\.{
        \\    .version = 1,
        \\    .breakpoints = .{
        \\        .{ .kind = .source, .path = "src/a b.zig", .line = 12, .condition = "s == \"x\\n\"" },
        \\        .{ .kind = .function, .name = "main", .enabled = false, .hit_condition = null },
        \\        .{ .kind = .instruction, .reference = "0x40", .offset = -4 },
        \\        .{ .kind = .data, .data_id = "0x10", .description = "x", .access = .readWrite },
        \\    },
        \\    .exception_filters = .{ .{ .adapter_type = "lldb-dap", .filter = "cpp_throw", .enabled = true } },
        \\}
    ;
    const fast = try persist.decodeWith(a, text, true);
    const slow = try persist.decodeWith(a, text, false);
    const fj = try std.json.Stringify.valueAlloc(a, fast, .{});
    const sj = try std.json.Stringify.valueAlloc(a, slow, .{});
    try testing.expectEqualStrings(sj, fj);
    try testing.expectEqualStrings("s == \"x\\n\"", fast.breakpoints[0].condition.?);
    // A field the reader does not know still loads (through std.zon).
    const extra = try persist.decode(a, ".{ .version = 1, .later = 3, .breakpoints = .{} }");
    try testing.expectEqual(@as(usize, 0), extra.breakpoints.len);
    try testing.expectError(error.Invalid, persist.decode(a, ".{ .version = "));
    // What encode writes reads back.
    const again = try persist.decode(a, try persist.encode(a, fast));
    try testing.expectEqualStrings(fj, try std.json.Stringify.valueAlloc(a, again, .{}));
}
