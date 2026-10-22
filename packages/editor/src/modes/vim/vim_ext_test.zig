//! Vim registers, dot repeat, macros, marks and the jumplist, searches
//! and the Ex subset: scenario tables recorded from real Vim
//! (testdata/vim/oracle.py), plus macro failure, undo grouping and host
//! action cases the tables cannot show.

const std = @import("std");
const golden = @import("../../model/edit/golden_testing.zig");
const mode_mod = @import("../mode.zig");
const core = @import("vim_core_test.zig");

const gpa = std.testing.allocator;
const Harness = core.Harness;

test "vim: ext conformance table" {
    // Expectations recorded from Vim 9.1; at least 100 scenarios in all.
    var failed = false;
    inline for (.{ .{ "registers", 30 }, .{ "repeat", 30 }, .{ "macros", 12 }, .{ "marks", 18 }, .{ "search", 22 }, .{ "ex", 50 } }) |f| {
        golden.runGolden("testdata/vim/ext/" ++ f[0] ++ ".txt", f[1], {}, core.runScenario) catch {
            failed = true;
        };
    }
    try std.testing.expect(!failed);
}

const expectAfter = core.expectAfter;

test "vim: dot repeat" {
    try expectAfter("¦foo bar baz", "ciwX<Esc>w.w.", "X X ¦X");
    // A count on "." replaces the command's own.
    try expectAfter("¦abcdefgh", "2x.", "¦efgh");
    try expectAfter("¦abcdefgh", "x3.", "¦efgh");
    // The insert session is replayed as keys.
    try expectAfter("¦a\nb", "A;<Esc>j.", "a;\nb¦;");
    // Yanks and motions do not replace the change.
    try expectAfter("¦abc abc", "xwyw.", "bc ¦bc");
}

test "vim: macros" {
    // A count runs the macro again until a command fails ("j" on the
    // last line), as in Vim.
    try expectAfter("¦a1\na2\na3", "qa0xjq10@a", "1\n2\n¦3");
    try expectAfter("¦abcd", "qaxq@a@@", "¦d");
    // A recursive macro stops at the first failure too.
    try expectAfter("¦a1\na2\na3\na4", "qaqqa0xj@aq@a", "1\n2\n3\n¦4");
    // The register holds Vim's bytes; editing it changes what runs.
    var h: Harness = undefined;
    try h.init("¦abc");
    defer h.deinit();
    try h.keys("qaiX<Esc>q");
    const r = h.vs.sh().regs.get('a').?;
    const text = try r.joined(gpa);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("iX\x1b", text);
}

test "vim: ex substitute is one undo step" {
    var h: Harness = undefined;
    try h.init("¦a a\na a\na a");
    defer h.deinit();
    try h.keys(":%s/a/b/g<CR>");
    try std.testing.expectEqual(@as(usize, 1), h.undo.nodes().len - 1);
    {
        const got = try h.render("");
        defer gpa.free(got);
        try std.testing.expectEqualStrings("b b\nb b\n¦b b", got);
        try std.testing.expectEqualStrings("6 substitutions on 3 lines", h.vs.statusText());
    }
    try h.keys("u");
    const got = try h.render("");
    defer gpa.free(got);
    try std.testing.expectEqualStrings("¦a a\na a\na a", got);
}

/// Records the actions `:w`, `:q` and friends ask the host for.
const FakeActions = struct {
    log: std.ArrayList(u8) = .empty,

    fn run(ctx: *anyopaque, a: mode_mod.Action) anyerror!void {
        const f: *FakeActions = @ptrCast(@alignCast(ctx));
        switch (a) {
            .write => |w| try f.log.print(gpa, "write {s}{s};", .{ w.path orelse "-", if (w.force) "!" else "" }),
            .quit => |q| try f.log.print(gpa, "quit{s};", .{if (q.force) "!" else ""}),
            .exit => try f.log.appendSlice(gpa, "exit;"),
            .command => |c| try f.log.print(gpa, "command {s};", .{c}),
            .edit => |ed| {
                if (ed.path != null and std.mem.eql(u8, ed.path.?, "locked")) return error.AccessDenied;
                try f.log.print(gpa, "edit {s}{s};", .{ ed.path orelse "-", if (ed.force) "!" else "" });
            },
        }
    }
};

test "vim: ex :w and :q go to the host" {
    var h: Harness = undefined;
    try h.init("¦abc");
    defer h.deinit();
    // Without host actions they fail with a message.
    try h.keys(":w<CR>");
    try std.testing.expect(std.mem.startsWith(u8, h.vs.statusText(), "E492"));
    var fake: FakeActions = .{};
    defer fake.log.deinit(gpa);
    h.host.actions = .{ .ctx = &fake, .runFn = FakeActions.run };
    try h.keys(":w<CR>:w! other.txt<CR>:q!<CR>:wq<CR>:x<CR>:e notes.md<CR>:e locked<CR>");
    try std.testing.expectEqualStrings("write -;write other.txt!;quit!;write -;quit;exit;edit notes.md;", fake.log.items);
    try std.testing.expect(std.mem.startsWith(u8, h.vs.statusText(), "E: AccessDenied"));
}

test "vim: marks follow edits" {
    // Lines added above move the mark with its line.
    try expectAfter("one\n¦two\nthree", "maggOnew<Esc>`a", "new\none\n¦two\nthree");
    try expectAfter("one\nt¦wo\nthree", "mbggdd'b", "¦two\nthree");
    // A file mark in the shared state.
    try expectAfter("one\n¦two", "mAggiX<Esc>`A", "Xone\n¦two");
}
