//! Tests for the agent edit API: reads, the four proposal forms, rebasing
//! over user edits, conflicts, policies and pending changes.

const std = @import("std");
const agent = @import("agent_edit.zig");
const registry = @import("registry.zig");
const pt = @import("../buffer/piece_tree.zig");
const ChangeSet = @import("../edit/change_set.zig").ChangeSet;
const Selection = @import("../edit/selection.zig").Selection;
const document = @import("../document.zig");
const store_mod = @import("../decorations/store.zig");
const pending_mod = @import("../decorations/pending.zig");

const testing = std.testing;
const gpa = testing.allocator;
const DocHandle = registry.DocHandle;
const DocumentRegistry = registry.DocumentRegistry;
const AgentEditSession = agent.AgentEditSession;

const Policy = struct {
    decision: agent.Decision = .apply,
    seen: ?agent.ProposalSummary = null,

    fn decide(ctx: *anyopaque, _: u64, _: DocHandle, summary: agent.ProposalSummary) agent.Decision {
        const p: *Policy = @ptrCast(@alignCast(ctx));
        p.seen = summary;
        return p.decision;
    }
};

const Fixture = struct {
    reg: DocumentRegistry,
    policy: Policy,
    session: AgentEditSession,
    h: DocHandle,
    applied: u32,

    fn init(f: *Fixture, text: []const u8) !void {
        f.reg = .init(gpa, .posix);
        f.policy = .{};
        f.applied = 0;
        f.session = .init(gpa, &f.reg, 3, .{ .ctx = &f.policy, .decide = Policy.decide });
        try f.session.subscribe(.{ .ctx = f, .onApplied = onApplied });
        f.h = try f.reg.openFile("/src/main.zig", text);
    }

    fn deinit(f: *Fixture) void {
        f.session.deinit();
        f.reg.deinit();
    }

    fn onApplied(ctx: *anyopaque, ev: *const agent.AgentEditApplied) void {
        const f: *Fixture = @ptrCast(@alignCast(ctx));
        f.applied += 1;
        std.debug.assert(std.mem.startsWith(u8, ev.label, "Agent 3 "));
    }

    fn doc(f: *Fixture) *document.Document {
        return f.reg.get(f.h).?;
    }

    fn userEdit(f: *Fixture, edits: []const pt.Edit) !void {
        var cs = try ChangeSet.fromEdits(gpa, f.doc().len(), edits);
        defer cs.deinit();
        try f.doc().applyChangeSet(&cs, .{ .user = 0 });
    }

    fn expectText(f: *Fixture, want: []const u8) !void {
        const t = try f.doc().tree.copyRange(gpa, .{ .start = 0, .end = f.doc().len() });
        defer gpa.free(t);
        try testing.expectEqualStrings(want, t);
    }

    fn propose(f: *Fixture, p: agent.Proposal) !agent.Outcome {
        return f.session.propose(f.h, p, "edit_file");
    }
};

const src = "const a = 1;\nconst b = 2;\nconst c = 3;\n";

test "agent: rebase non-conflicting after user typing" {
    var f: Fixture = undefined;
    try f.init(src);
    defer f.deinit();
    const v0 = f.doc().version;
    var cs = try ChangeSet.fromEdits(gpa, f.doc().len(), &.{.{ .range = .{ .start = 26, .end = 31 }, .text = "var" }}); // "const c" -> "var c"
    defer cs.deinit();
    // The user types at the top meanwhile.
    try f.userEdit(&.{.{ .range = .{ .start = 0, .end = 0 }, .text = "// hi\n" }});
    try f.userEdit(&.{.{ .range = .{ .start = 16, .end = 17 }, .text = "42" }});
    var out = try f.propose(.{ .change_set = .{ .cs = &cs, .base_version = v0 } });
    defer out.deinit(gpa);
    try testing.expect(out == .applied);
    try f.expectText("// hi\nconst a = 42;\nconst b = 2;\nvar c = 3;\n");
    try testing.expectEqual(@as(u32, 1), f.applied);
    try testing.expectEqual(@as(usize, 1), out.applied.ranges.len);
    try testing.expectEqual(pt.Range{ .start = 33, .end = 36 }, out.applied.ranges[0]);
    try testing.expectEqualStrings("edit_file", f.policy.seen.?.tool);
}

test "agent: conflict ranges reported" {
    var f: Fixture = undefined;
    try f.init(src);
    defer f.deinit();
    const v0 = f.doc().version;
    var cs = try ChangeSet.fromEdits(gpa, f.doc().len(), &.{
        .{ .range = .{ .start = 10, .end = 11 }, .text = "10" }, // a's value
        .{ .range = .{ .start = 23, .end = 24 }, .text = "20" }, // b's value
    });
    defer cs.deinit();
    try f.userEdit(&.{.{ .range = .{ .start = 0, .end = 0 }, .text = "x" }});
    try f.userEdit(&.{.{ .range = .{ .start = 24, .end = 25 }, .text = "9" }}); // the user changed b's value
    var out = try f.propose(.{ .change_set = .{ .cs = &cs, .base_version = v0 } });
    defer out.deinit(gpa);
    try testing.expect(out == .rejected);
    const ranges = out.rejected.conflict.ranges;
    try testing.expectEqual(@as(usize, 1), ranges.len);
    try testing.expectEqual(pt.Range{ .start = 24, .end = 25 }, ranges[0]);
    try f.expectText("xconst a = 1;\nconst b = 9;\nconst c = 3;\n");
    // Adjacent edits do not conflict.
    try f.userEdit(&.{.{ .range = .{ .start = 25, .end = 25 }, .text = "9" }});
    const v1 = f.doc().version;
    var cs2 = try ChangeSet.fromEdits(gpa, f.doc().len(), &.{.{ .range = .{ .start = 24, .end = 26 }, .text = "7" }});
    defer cs2.deinit();
    try f.userEdit(&.{.{ .range = .{ .start = 26, .end = 26 }, .text = "0" }});
    var out2 = try f.propose(.{ .change_set = .{ .cs = &cs2, .base_version = v1 } });
    defer out2.deinit(gpa);
    try testing.expect(out2 == .applied);
    // The user's text wins the tie at the collapsed point.
    try f.expectText("xconst a = 1;\nconst b = 07;\nconst c = 3;\n");
}

test "agent: str_replace unique/not_unique/not_found/all/nth" {
    var f: Fixture = undefined;
    try f.init(src);
    defer f.deinit();
    var o1 = try f.propose(.{ .str_replace = .{ .old = "const", .new = "var" } });
    defer o1.deinit(gpa);
    try testing.expectEqual(@as(u64, 3), o1.rejected.not_unique.count);
    var o2 = try f.propose(.{ .str_replace = .{ .old = "const d", .new = "x" } });
    defer o2.deinit(gpa);
    try testing.expect(o2.rejected == .not_found);
    var o3 = try f.propose(.{ .str_replace = .{ .old = "b = 2", .new = "b = 22" } });
    defer o3.deinit(gpa);
    try testing.expect(o3 == .applied);
    var o4 = try f.propose(.{ .str_replace = .{ .old = "const", .new = "var", .occurrence = .{ .nth = 2 } } });
    defer o4.deinit(gpa);
    try f.expectText("const a = 1;\nconst b = 22;\nvar c = 3;\n");
    var o5 = try f.propose(.{ .str_replace = .{ .old = "const", .new = "var", .occurrence = .{ .nth = 5 } } });
    defer o5.deinit(gpa);
    try testing.expectEqual(@as(u64, 2), o5.rejected.no_such_occurrence.count);
    var o6 = try f.propose(.{ .str_replace = .{ .old = "const ", .new = "", .occurrence = .all } });
    defer o6.deinit(gpa);
    try f.expectText("a = 1;\nb = 22;\nvar c = 3;\n");
    // Multi-line snippets.
    var o7 = try f.propose(.{ .str_replace = .{ .old = "1;\nb", .new = "1;\n\nb" } });
    defer o7.deinit(gpa);
    try f.expectText("a = 1;\n\nb = 22;\nvar c = 3;\n");
}

test "agent: CRLF retry" {
    var f: Fixture = undefined;
    try f.init("fn a() void {\r\n    x();\r\n}\r\n");
    defer f.deinit();
    var o = try f.propose(.{ .str_replace = .{ .old = "{\n    x();\n}", .new = "{\n    y();\n}" } });
    defer o.deinit(gpa);
    try testing.expect(o == .applied);
    try testing.expect(o.applied.crlf_adjusted);
    try f.expectText("fn a() void {\r\n    y();\r\n}\r\n");
    // And CRLF snippets against an LF file.
    var g: Fixture = undefined;
    try g.init("a\nb\n");
    defer g.deinit();
    var o2 = try g.propose(.{ .str_replace = .{ .old = "a\r\nb", .new = "A\r\nB" } });
    defer o2.deinit(gpa);
    try testing.expect(o2.applied.crlf_adjusted);
    try g.expectText("A\nB\n");
}

test "agent: whole_file becomes minimal diff" {
    var f: Fixture = undefined;
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(gpa);
    for (0..200) |i| try big.print(gpa, "line {d}\n", .{i});
    try f.init(big.items);
    defer f.deinit();
    var new = try big.clone(gpa);
    defer new.deinit(gpa);
    // Change two lines far apart.
    const at1 = std.mem.indexOf(u8, new.items, "line 10\n").?;
    try new.replaceRange(gpa, at1, 7, "LINE 10");
    const at2 = std.mem.indexOf(u8, new.items, "line 150\n").?;
    try new.replaceRange(gpa, at2, 8, "line 150\nextra");
    var o = try f.propose(.{ .whole_file = .{ .text = new.items } });
    defer o.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), o.applied.ranges.len);
    try testing.expectEqual(@as(usize, 2), f.policy.seen.?.hunks);
    try f.expectText(new.items);
    // A missing final newline is handled exactly.
    var o2 = try f.propose(.{ .whole_file = .{ .text = "only\nthis" } });
    defer o2.deinit(gpa);
    try f.expectText("only\nthis");
    var o3 = try f.propose(.{ .whole_file = .{ .text = "only\nthis\nand more\n" } });
    defer o3.deinit(gpa);
    try f.expectText("only\nthis\nand more\n");
}

const Host = struct {
    store: store_mod.DecorationStore,
    owner: store_mod.OwnerId,
    change: ?*pending_mod.PendingChange = null,

    fn place(ctx: *anyopaque, _: DocHandle) ?agent.PendingPlace {
        const h: *Host = @ptrCast(@alignCast(ctx));
        return .{ .store = &h.store, .owner = h.owner };
    }

    fn created(ctx: *anyopaque, _: DocHandle, change: *pending_mod.PendingChange) void {
        const h: *Host = @ptrCast(@alignCast(ctx));
        h.change = change;
    }
};

test "agent: pending policy creates PendingChange" {
    var f: Fixture = undefined;
    try f.init(src);
    defer f.deinit();
    var host: Host = .{ .store = .init(gpa, f.doc()), .owner = undefined };
    defer host.store.deinit();
    host.owner = try host.store.registerOwner("ai.pending", 0);
    _ = try f.doc().subscribe(host.store.listener());
    f.policy.decision = .pending;
    var o0 = try f.propose(.{ .str_replace = .{ .old = "b = 2", .new = "b = 5" } });
    defer o0.deinit(gpa);
    try testing.expect(o0.rejected == .no_pending_host);
    f.session.pending_host = .{ .ctx = &host, .place = Host.place, .created = Host.created };
    var o = try f.propose(.{ .str_replace = .{ .old = "b = 2", .new = "b = 5" } });
    defer o.deinit(gpa);
    try testing.expect(o == .pending);
    try testing.expectEqual(o.pending.change, host.change.?);
    defer host.change.?.destroy();
    try f.expectText(src); // not applied yet
    try testing.expectEqual(@as(usize, 1), host.change.?.hunks().len);
    try host.change.?.acceptAll();
    try f.expectText("const a = 1;\nconst b = 5;\nconst c = 3;\n");
    f.policy.decision = .deny;
    var o2 = try f.propose(.{ .str_replace = .{ .old = "a = 1", .new = "a = 0" } });
    defer o2.deinit(gpa);
    try testing.expect(o2.rejected == .denied);
}

test "agent: user cursors unaffected by agent apply" {
    var f: Fixture = undefined;
    try f.init(src);
    defer f.deinit();
    const Cursor = struct {
        sel: Selection,
        fn onChange(ctx: *anyopaque, ev: *const document.ChangeEvent) void {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.sel = c.sel.map(ev.changes);
        }
    };
    // The user's caret sits right where the agent inserts.
    var cur: Cursor = .{ .sel = .caret(13) };
    _ = try f.doc().subscribe(.{ .ctx = &cur, .onChange = Cursor.onChange });
    var o = try f.propose(.{ .line_edits = .{ .edits = &.{.{ .start_line = 1, .end_line = 1, .new_text = "// inserted\n" }}, .base_version = f.doc().version } });
    defer o.deinit(gpa);
    try f.expectText("const a = 1;\n// inserted\nconst b = 2;\nconst c = 3;\n");
    // The caret follows the text it was in front of, it is not moved to
    // the end of the agent's edit or selected.
    try testing.expect(cur.sel.isCaret());
    try testing.expect(cur.sel.head == 13 or cur.sel.head == 25);
}

test "agent: line edits against the last read version" {
    var f: Fixture = undefined;
    try f.init(src);
    defer f.deinit();
    var r = try f.session.readLines(f.h, null, .{}, gpa);
    defer r.deinit(gpa);
    try f.userEdit(&.{.{ .range = .{ .start = 0, .end = 0 }, .text = "// top\n" }});
    var o = try f.propose(.{ .line_edits = .{ .edits = &.{.{ .start_line = 2, .end_line = 3, .new_text = "const c = 33;\n" }}, .base_version = r.version } });
    defer o.deinit(gpa);
    try testing.expect(o == .applied);
    try f.expectText("// top\nconst a = 1;\nconst b = 2;\nconst c = 33;\n");
    // An unknown version must be re-read.
    var o2 = try f.propose(.{ .line_edits = .{ .edits = &.{}, .base_version = 99 } });
    defer o2.deinit(gpa);
    try testing.expectEqual(@as(u64, 99), o2.rejected.stale_version_evicted.base_version);
    try f.reg.setReadOnly(f.h, true);
    var o3 = try f.propose(.{ .str_replace = .{ .old = "top", .new = "x" } });
    defer o3.deinit(gpa);
    try testing.expect(o3.rejected == .read_only);
}

test "agent: read truncation and line numbers" {
    var f: Fixture = undefined;
    try f.init(src);
    defer f.deinit();
    var r = try f.session.readLines(f.h, .{ .start = 1, .end = 3 }, .{ .line_numbers = true }, gpa);
    defer r.deinit(gpa);
    try testing.expectEqualStrings("     2\tconst b = 2;\n     3\tconst c = 3;\n", r.text);
    try testing.expectEqual(@as(u64, 3), r.total_lines);
    try testing.expectEqual(@as(u64, 1), r.start_line);
    try testing.expect(!r.truncated);
    var r2 = try f.session.readLines(f.h, null, .{ .max_bytes = 30 }, gpa);
    defer r2.deinit(gpa);
    try testing.expectEqualStrings("const a = 1;\nconst b = 2;\n", r2.text);
    try testing.expect(r2.truncated);
    try testing.expectEqual(@as(u64, 2), r2.lines);
}

test "fuzz: agent proposals vs concurrent user edits" {
    var prng: std.Random.DefaultPrng = .init(0xa9e);
    const r = prng.random();
    const alphabet = "abc\n";
    for (0..300) |_| {
        var f: Fixture = undefined;
        var base: [40]u8 = undefined;
        for (&base) |*c| c.* = alphabet[r.uintLessThan(usize, alphabet.len)];
        try f.init(&base);
        defer f.deinit();
        const v0 = f.doc().version;
        var agent_cs = try randomCs(r, base.len);
        defer agent_cs.deinit();
        var user_total = try ChangeSet.fromEdits(gpa, base.len, &.{});
        defer user_total.deinit();
        for (0..r.uintLessThan(usize, 4)) |_| {
            var u = try randomCs(r, f.doc().len());
            defer u.deinit();
            try f.doc().applyChangeSet(&u, .{ .user = 0 });
            const next = try user_total.compose(&u, gpa);
            user_total.deinit();
            user_total = next;
        }
        const before = try f.doc().tree.copyRange(gpa, .{ .start = 0, .end = f.doc().len() });
        defer gpa.free(before);
        var o = try f.propose(.{ .change_set = .{ .cs = &agent_cs, .base_version = v0 } });
        defer o.deinit(gpa);
        const got = try f.doc().tree.copyRange(gpa, .{ .start = 0, .end = f.doc().len() });
        defer gpa.free(got);
        switch (o) {
            .applied => {
                // TP1: user then rebased agent == agent then rebased user.
                const after_agent = try agent_cs.applyToSlice(gpa, &base);
                defer gpa.free(after_agent);
                var user_rebased = try user_total.transform(&agent_cs, true, gpa);
                defer user_rebased.deinit();
                const want = try user_rebased.applyToSlice(gpa, after_agent);
                defer gpa.free(want);
                try testing.expectEqualStrings(want, got);
            },
            .rejected => |rej| {
                try testing.expect(rej == .conflict);
                try testing.expectEqualStrings(before, got);
                for (rej.conflict.ranges) |cr| try testing.expect(cr.end <= f.doc().len());
            },
            .pending => unreachable,
        }
    }
}

fn randomCs(r: std.Random, len: u64) !ChangeSet {
    var edits: [3]pt.Edit = undefined;
    const texts = [_][]const u8{ "", "X", "YZ", "\n" };
    var n: usize = 0;
    var pos: u64 = 0;
    while (n < edits.len and pos <= len and r.boolean()) : (n += 1) {
        const a = r.intRangeAtMost(u64, pos, len);
        const b = @min(len, a + r.uintLessThan(u64, 4));
        edits[n] = .{ .range = .{ .start = a, .end = b }, .text = texts[r.uintLessThan(usize, texts.len)] };
        pos = b + 1;
    }
    return ChangeSet.fromEdits(gpa, len, edits[0..n]);
}
