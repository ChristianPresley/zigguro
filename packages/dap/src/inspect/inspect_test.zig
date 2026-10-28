//! The inspection model against `fake_dap_adapter` scripts
//! (testdata/sessions/inspect_*.txt): stack paging and selection, sources
//! without a path, buckets, expansion across stops, changed values,
//! expensive scopes, lazy values, generations, setting values,
//! `invalidated` and the hex format. A few model-only cases feed results
//! by hand.

const std = @import("std");
const Inspector = @import("Inspector.zig");
const VariablesModel = @import("VariablesModel.zig");
const Channel = @import("Channel.zig");
const DebugSession = @import("../session/DebugSession.zig");
const test_harness = @import("../session/test_harness.zig");

const testing = std.testing;
const gpa = testing.allocator;
const Io = std.Io;
const Harness = test_harness.Harness;
const NodeId = VariablesModel.NodeId;

/// Forwards the session's changes to the inspector and counts them.
pub const Fwd = struct {
    insp: *Inspector,
    counts: [@typeInfo(DebugSession.Change).@"enum".fields.len]std.atomic.Value(u32) = @splat(.init(0)),

    fn on(ctx: ?*anyopaque, s: *DebugSession, change: DebugSession.Change) void {
        const f: *Fwd = @ptrCast(@alignCast(ctx.?));
        f.insp.onChange(s, change);
        _ = f.counts[@intFromEnum(change)].fetchAdd(1, .acq_rel);
    }

    /// Waits until `change` was forwarded `n` times, then for the model.
    pub fn settleAfter(f: *Fwd, change: DebugSession.Change, n: u32) !void {
        const deadline = Io.Timestamp.now(testing.io, .awake).addDuration(.fromSeconds(10));
        while (f.counts[@intFromEnum(change)].load(.acquire) < n) {
            if (Io.Timestamp.now(testing.io, .awake).nanoseconds > deadline.nanoseconds) return error.Timeout;
            _ = f.insp.pump();
            f.insp.ch.wait(.fromMilliseconds(20));
        }
        try f.insp.settle(.fromSeconds(10));
    }
};

pub const Fixture = struct {
    h: Harness,
    s: *DebugSession,
    insp: Inspector,
    fwd: Fwd,
    revealed: ?i64 = null,
    opened_uri: std.ArrayList(u8) = .empty,
    opened_text: std.ArrayList(u8) = .empty,

    /// Starts `script`, attaches the model and pauses thread 1.
    pub fn init(f: *Fixture, script: []const u8, opts: Inspector.Options) !void {
        return f.initWith(script, opts, null);
    }

    /// `init`, running `setup` on the model before the pause.
    pub fn initWith(f: *Fixture, script: []const u8, opts: Inspector.Options, setup: ?*const fn (*Inspector) void) !void {
        f.* = .{ .h = undefined, .s = undefined, .insp = undefined, .fwd = undefined };
        try f.h.init(&.{script}, .{});
        errdefer f.h.deinit();
        f.s = try f.h.start(.launch);
        try f.h.waitFor(f.s, running);
        var o = opts;
        o.host = .{ .ctx = f, .reveal = reveal, .open_source = openSource };
        try f.insp.initSession(gpa, testing.io, f.s, o);
        f.fwd = .{ .insp = &f.insp };
        try f.h.m.subscribe(.{ .ctx = &f.fwd, .func = Fwd.on });
        if (setup) |g| g(&f.insp);
        f.s.pause(1);
        try f.fwd.settleAfter(.stack, 1);
    }

    /// Stops the session and checks the script ran to its end.
    pub fn finish(f: *Fixture) !void {
        try f.insp.settle(.fromSeconds(10));
        f.s.stop();
        try f.h.waitFor(f.s, Harness.ended);
        try f.h.expectScriptPassed(f.s);
    }

    pub fn deinit(f: *Fixture) void {
        f.h.deinit();
        f.insp.deinit();
        f.opened_uri.deinit(gpa);
        f.opened_text.deinit(gpa);
    }

    fn reveal(ctx: ?*anyopaque, row: *const Inspector.FrameRow) void {
        const f: *Fixture = @ptrCast(@alignCast(ctx.?));
        f.revealed = row.id;
    }

    fn openSource(ctx: ?*anyopaque, uri: []const u8, text: []const u8, _: ?[]const u8) void {
        const f: *Fixture = @ptrCast(@alignCast(ctx.?));
        f.opened_uri.appendSlice(gpa, uri) catch {};
        f.opened_text.appendSlice(gpa, text) catch {};
    }

    pub fn vars(f: *Fixture) *VariablesModel {
        return &f.insp.vars;
    }

    /// The child of `parent` named `name` (its children must be ready).
    pub fn child(f: *Fixture, parent: NodeId, name: []const u8) !NodeId {
        return childOf(f.vars(), parent, name);
    }

    pub fn root(f: *Fixture, name: []const u8) !NodeId {
        for (f.vars().roots()) |r| if (std.mem.eql(u8, f.vars().node(r).?.name, name)) return r;
        return error.NoScope;
    }
};

pub fn childOf(m: *VariablesModel, parent: NodeId, name: []const u8) !NodeId {
    const list = switch (m.children(parent, null)) {
        .ready => |l| l,
        else => return error.NotReady,
    };
    for (list) |c| if (std.mem.eql(u8, m.node(c).?.name, name)) return c;
    return error.NoChild;
}

fn running(_: *Harness, s: *DebugSession) bool {
    return s.state() == .running;
}

test "stack: paging and totalFrames" {
    var f: Fixture = undefined;
    try f.init("inspect_stack_paging.txt", .{});
    defer f.deinit();
    const st = &f.insp.stack;
    // The first page from the session, the second fetched with the scopes.
    try testing.expectEqual(@as(usize, 40), st.frames(1).len);
    try testing.expectEqual(@as(?u32, 45), st.total(1));
    try testing.expect(!st.complete(1));
    try testing.expectEqual(@as(i64, 1), st.selected().?.frame);
    try testing.expectEqual(@as(?i64, 1), f.revealed);
    st.loadMore(1, 20);
    try f.insp.settle(.fromSeconds(10));
    try testing.expectEqual(@as(usize, 45), st.frames(1).len);
    try testing.expect(st.complete(1));
    try testing.expectEqualStrings("f45", st.frames(1)[44].name);
    st.loadMore(1, 20); // nothing more to fetch
    try f.finish();
}

test "stack: subtle frames skipped for auto-selection" {
    var f: Fixture = undefined;
    try f.init("inspect_stack_subtle.txt", .{});
    defer f.deinit();
    const st = &f.insp.stack;
    try testing.expectEqual(@as(i64, 4), st.selected().?.frame);
    try testing.expectEqual(@as(?i64, 4), f.revealed);
    try testing.expectEqual(.subtle, st.frames(1)[0].hint);
    try testing.expectEqual(.label, st.frames(1)[2].hint);
    try testing.expect(st.complete(1));
    try f.finish();
}

test "stack: sourceReference fetch opens dap-source document" {
    var f: Fixture = undefined;
    try f.init("inspect_stack_source.txt", .{});
    defer f.deinit();
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "dap-source:{d}/77", .{f.s.id}), f.opened_uri.items);
    try testing.expectEqualStrings("mov rax, 1\n", f.opened_text.items);
    // Selecting it again opens it from the cache.
    f.insp.stack.select(1, 1);
    try testing.expectEqual(@as(usize, 2 * "mov rax, 1\n".len), f.opened_text.items.len);
    try f.finish();
}

test "vars: buckets for 1M indexed (golden request ranges)" {
    var f: Fixture = undefined;
    try f.init("inspect_vars_buckets.txt", .{});
    defer f.deinit();
    const m = f.vars();
    const locals = try f.root("Locals");
    try testing.expect(m.isExpanded(locals));
    const arr = try f.child(locals, "arr");
    // Buckets need no request: 100 of 10,000, then 100 of 100.
    m.expand(arr, true);
    const top = switch (m.children(arr, null)) {
        .ready => |l| l,
        else => return error.NotReady,
    };
    try testing.expectEqual(@as(usize, 100), top.len);
    try testing.expectEqualStrings("[0..9999]", m.node(top[0]).?.name);
    try testing.expectEqualStrings("[990000..999999]", m.node(top[99]).?.name);
    try testing.expectEqual(VariablesModel.Kind.bucket, m.node(top[0]).?.kind);
    m.expand(top[0], true);
    const leaf = try childOf(m, top[0], "[0..99]");
    // One request for the first visible page.
    m.expand(leaf, true);
    try f.insp.settle(.fromSeconds(10));
    const page = m.children(leaf, null).ready;
    try testing.expectEqual(@as(usize, 100), page.len);
    try testing.expectEqualStrings("[99]", m.node(page[99]).?.name);
    // The last element's page.
    m.expand(top[99], true);
    const last = try childOf(m, top[99], "[999900..999999]");
    m.expand(last, true);
    try f.insp.settle(.fromSeconds(10));
    try testing.expectEqualStrings("999999", m.node(m.children(last, null).ready[99]).?.value);
    try f.finish();
}

test "vars: expansion restored across stops by key path; changed flag" {
    var f: Fixture = undefined;
    try f.init("inspect_vars_restore.txt", .{});
    defer f.deinit();
    const m = f.vars();
    const locals = try f.root("Locals");
    const s_id = try f.child(locals, "s");
    m.expand(s_id, true);
    try f.insp.settle(.fromSeconds(10));
    const a1 = try f.child(s_id, "a");
    try testing.expect(!m.node(try f.child(locals, "x")).?.changed);
    // A step: same ids, `s` fetched again without asking.
    f.s.continue_(1);
    try f.fwd.settleAfter(.stack, 2);
    try testing.expectEqual(locals, try f.root("Locals"));
    try testing.expectEqual(s_id, try f.child(locals, "s"));
    try testing.expect(m.isExpanded(s_id));
    const a2 = try f.child(s_id, "a");
    try testing.expectEqual(a1, a2);
    const x = m.node(try f.child(locals, "x")).?;
    try testing.expectEqualStrings("2", x.value);
    try testing.expect(x.changed);
    try testing.expect(!m.node(a2).?.changed);
    try f.finish();
}

test "vars: expensive scope not fetched until expanded; lazy values" {
    var f: Fixture = undefined;
    try f.init("inspect_vars_expensive.txt", .{});
    defer f.deinit();
    const m = f.vars();
    const regs = try f.root("Registers");
    try testing.expect(m.node(regs).?.expensive);
    try testing.expect(!m.isExpanded(regs));
    // The script fails if Registers were fetched before this.
    m.expand(regs, true);
    try f.insp.settle(.fromSeconds(10));
    _ = try f.child(regs, "rax");
    const getter = try f.child(try f.root("Locals"), "getter");
    try testing.expect(m.node(getter).?.lazy);
    try testing.expectEqualStrings(VariablesModel.lazy_label, m.node(getter).?.value);
    m.expand(getter, true);
    try f.insp.settle(.fromSeconds(10));
    try testing.expect(!m.node(getter).?.lazy);
    try testing.expectEqualStrings("42", m.node(getter).?.value);
    try testing.expectEqualStrings("i32", m.node(getter).?.type.?);
    try f.finish();
}

test "vars: stale generation rejected" {
    var f: Fixture = undefined;
    try f.init("inspect_vars_stale.txt", .{});
    defer f.deinit();
    const m = f.vars();
    const locals = try f.root("Locals");
    const s_id = try f.child(locals, "s");
    const gen = f.insp.gen;
    f.s.continue_(1);
    try f.fwd.settleAfter(.continued, 1);
    try testing.expect(!f.insp.stopped());
    // No request with the old reference: the script would fail.
    try testing.expect(m.children(s_id, null) == .stale);
    m.expand(s_id, true);
    try testing.expectEqual(@as(usize, 1), m.children(locals, null).stale.len);
    // A result of the old stop arriving now is dropped.
    try f.insp.deliver(.{ .kind = .variables, .a = @intFromEnum(s_id) }, gen, true, "{\"variables\":[{\"name\":\"late\",\"value\":\"1\"}]}");
    try testing.expectEqual(@as(usize, 0), m.children(s_id, null).stale.len);
    try f.finish();
}

const SetLog = struct {
    calls: u32 = 0,
    last_ok: bool = false,

    fn cb(l: *SetLog) VariablesModel.SetCb {
        return .{ .ctx = l, .func = on };
    }

    fn on(ctx: ?*anyopaque, ok: bool, _: ?[]const u8) void {
        const l: *SetLog = @ptrCast(@alignCast(ctx.?));
        l.calls += 1;
        l.last_ok = ok;
    }
};

test "vars: setVariable vs setExpression path; scope refetch" {
    var f: Fixture = undefined;
    try f.init("inspect_vars_set.txt", .{});
    defer f.deinit();
    const m = f.vars();
    const locals = try f.root("Locals");
    var log: SetLog = .{};
    m.setValue(try f.child(locals, "x"), "5", log.cb());
    try f.insp.settle(.fromSeconds(10));
    try testing.expectEqual(@as(u32, 1), log.calls);
    try testing.expect(log.last_ok);
    try testing.expectEqualStrings("5", m.node(try f.child(locals, "x")).?.value);
    m.setValue(try f.child(locals, "y"), "7", log.cb());
    try f.insp.settle(.fromSeconds(10));
    try testing.expectEqual(@as(u32, 2), log.calls);
    try testing.expectEqualStrings("7", m.node(try f.child(locals, "y")).?.value);
    try f.finish();
}

test "vars: invalidated keeps expansion" {
    var f: Fixture = undefined;
    try f.init("inspect_vars_invalidated.txt", .{});
    defer f.deinit();
    const m = f.vars();
    const s_id = try f.child(try f.root("Locals"), "s");
    m.expand(s_id, true);
    try f.fwd.settleAfter(.invalidated, 1);
    try testing.expect(m.isExpanded(s_id));
    try testing.expectEqualStrings("6", m.node(try f.child(s_id, "a")).?.value);
    try f.finish();
}

test "vars: hex format toggle" {
    var f: Fixture = undefined;
    try f.init("inspect_vars_hex.txt", .{});
    defer f.deinit();
    const m = f.vars();
    m.setHex(true);
    try f.insp.settle(.fromSeconds(10));
    try testing.expectEqualStrings("0xa", m.node(try f.child(try f.root("Locals"), "n")).?.value);
    try f.finish();
}

// ---------------------------------------------------------------------
// The model alone, results fed by hand.

const one_frame = "{\"stackFrames\":[{\"id\":1,\"name\":\"main\",\"line\":1,\"column\":1,\"source\":{\"path\":\"/w/a.zig\"}}],\"totalFrames\":1}";

fn bare(opts: Inspector.Options) !*Inspector {
    const i = try gpa.create(Inspector);
    try i.init(gpa, testing.io, null, .none, opts);
    try i.applyStop(.{ .gen = 2, .thread = 1, .stack = one_frame, .scopes = "{\"scopes\":[{\"name\":\"Locals\",\"variablesReference\":10}]}" });
    return i;
}

fn free(i: *Inspector) void {
    i.deinit();
    gpa.destroy(i);
}

test "vars: without paging, children capped with a more row" {
    const i = try bare(.{ .paging = false, .max_children = 10 });
    defer free(i);
    const m = &i.vars;
    const locals = m.roots()[0];
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.appendSlice(gpa, "{\"variables\":[");
    for (0..25) |k| try body.print(gpa, "{s}{{\"name\":\"[{d}]\",\"value\":\"{d}\"}}", .{ if (k == 0) "" else ",", k, k });
    try body.appendSlice(gpa, "]}");
    try i.deliver(.{ .kind = .variables, .a = @intFromEnum(locals) }, 2, true, body.items);
    const list = m.children(locals, null).ready;
    try testing.expectEqual(@as(usize, 11), list.len);
    try testing.expectEqualStrings("15 more not shown", m.node(list[10]).?.name);
    try testing.expectEqual(VariablesModel.Kind.more, m.node(list[10]).?.kind);
    try testing.expectEqual(@as(usize, 3), m.children(locals, .{ 2, 5 }).ready.len);
}

test "vars: shadowed names get distinct ids; errors become a row" {
    const i = try bare(.{});
    defer free(i);
    const m = &i.vars;
    const locals = m.roots()[0];
    try i.deliver(.{ .kind = .variables, .a = @intFromEnum(locals) }, 2, true, "{\"variables\":[{\"name\":\"x\",\"value\":\"1\"},{\"name\":\"x\",\"value\":\"2\",\"variablesReference\":5}]}");
    const list = m.children(locals, null).ready;
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expect(list[0] != list[1]);
    try i.deliver(.{ .kind = .variables, .a = @intFromEnum(list[1]) }, 2, false, "cannot read memory");
    const err = m.children(list[1], null).ready;
    try testing.expect(m.node(err[0]).?.err);
    try testing.expectEqualStrings("cannot read memory", m.node(err[0]).?.value);
    // Much later, nodes not seen since are dropped.
    try i.applyStop(.{ .gen = 40, .thread = 1, .stack = one_frame, .scopes = "{\"scopes\":[{\"name\":\"Locals\",\"variablesReference\":10}]}" });
    try testing.expectEqual(@as(usize, 1), m.nodeCount());
}
