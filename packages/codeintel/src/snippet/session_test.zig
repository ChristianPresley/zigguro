const std = @import("std");
const testing = std.testing;
const gpa = testing.allocator;
const zg_editor = @import("zg_editor");
const Snippet = @import("Snippet.zig");
const Session = @import("Session.zig");

const Document = zg_editor.model.document.Document;
const EditorView = zg_editor.view.EditorView;
const Range = zg_editor.model.buffer.piece_tree.Range;

const Fx = struct {
    doc: *Document,
    view: *EditorView,
    snip: ?Snippet = null,
    exp: Snippet.Expansion = .{},

    fn init(initial: []const u8) !Fx {
        const doc = try Document.initBytes(gpa, @enumFromInt(1), initial);
        errdefer doc.deinit();
        return .{ .doc = doc, .view = try EditorView.init(gpa, doc, .{}) };
    }

    fn deinit(f: *Fx) void {
        f.exp.deinit(gpa);
        if (f.snip) |*s| s.deinit();
        f.view.deinit();
        f.doc.deinit();
    }

    fn expand(f: *Fx, src: []const u8) !*const Snippet.Expansion {
        if (f.snip) |*s| s.deinit();
        f.snip = try Snippet.parse(gpa, src);
        try f.snip.?.expand(gpa, .none, .{}, &f.exp);
        return &f.exp;
    }

    fn text(f: *Fx) ![]u8 {
        return f.view.allText(gpa);
    }

    fn expectText(f: *Fx, want: []const u8) !void {
        const t = try f.text();
        defer gpa.free(t);
        try testing.expectEqualStrings(want, t);
    }

    /// The selections as "start-end" pairs.
    fn expectSels(f: *Fx, want: []const u8) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(gpa);
        for (f.view.selections(), 0..) |s, i| {
            if (i > 0) try buf.append(gpa, ' ');
            try buf.print(gpa, "{d}-{d}", .{ s.start(), s.end() });
        }
        try testing.expectEqualStrings(want, buf.items);
    }

    fn typeText(f: *Fx, t: []const u8) !void {
        try f.view.insertText(t);
    }
};

test "snippet_session: tab order with nested placeholders" {
    var f = try Fx.init("x");
    defer f.deinit();
    f.view.setSelection(.caret(1));
    const s = try Session.begin(gpa, f.view, &.{.{ .start = 1, .end = 1 }}, try f.expand("f(${1:a, ${2:b}}, $3)$0"));
    defer s.destroy();
    try f.expectText("xf(a, b, )");
    try f.expectSels("3-7");
    try testing.expect(try s.next());
    try f.expectSels("6-7");
    try testing.expect(try s.next());
    try f.expectSels("9-9");
    try testing.expect(try s.prev());
    try f.expectSels("6-7");
    try testing.expect(try s.prev());
    try f.expectSels("3-7");
    try testing.expect(!try s.prev());
    // Typing over the outer placeholder drops the inner one.
    try f.typeText("q");
    try f.expectText("xf(q, )");
    try testing.expect(try s.next());
    try f.expectSels("6-6");
    try testing.expect(!try s.next());
    try f.expectSels("7-7");
    try testing.expect(s.done);
}

test "snippet_session: mirrors edited simultaneously, one undo step" {
    var f = try Fx.init("");
    defer f.deinit();
    const s = try Session.begin(gpa, f.view, &.{.{ .start = 0, .end = 0 }}, try f.expand("${1:foo} = $1 + $1;$2"));
    defer s.destroy();
    try f.expectText("foo = foo + foo;");
    try f.expectSels("0-3 6-9 12-15");
    try f.typeText("ab");
    try f.expectText("ab = ab + ab;");
    try f.typeText("c");
    try f.expectText("abc = abc + abc;");
    try testing.expect(try s.next());
    try f.expectSels("16-16");
    // Typing coalesced into one step: one undo brings "foo" back
    // everywhere, the next undoes the insertion.
    try testing.expect(try f.view.undoStep());
    try f.expectText("foo = foo + foo;");
    try testing.expect(s.done);
    try testing.expect(try f.view.undoStep());
    try f.expectText("");
}

test "snippet_session: transform applied on leave" {
    var f = try Fx.init("");
    defer f.deinit();
    const s = try Session.begin(gpa, f.view, &.{.{ .start = 0, .end = 0 }}, try f.expand("${1:name}: ${1/(.*)/${1:/upcase}/}$0"));
    defer s.destroy();
    try f.expectText("name: NAME");
    try f.expectSels("0-4");
    try f.typeText("id");
    try f.expectText("id: NAME");
    try testing.expect(!try s.next());
    try f.expectText("id: ID");
    try f.expectSels("6-6");
}

test "snippet_session: choice stop publishes options" {
    var f = try Fx.init("");
    defer f.deinit();
    const s = try Session.begin(gpa, f.view, &.{.{ .start = 0, .end = 0 }}, try f.expand("let x: ${1|u8,u16,u32|} = $2;"));
    defer s.destroy();
    const a = s.active().?;
    try testing.expectEqual(@as(u32, 1), a.index);
    try testing.expectEqual(@as(usize, 3), a.choice.?.len);
    try testing.expectEqualStrings("u16", a.choice.?[1]);
    try s.choose("u32");
    try f.expectText("let x: u32 = ;");
    try f.expectSels("7-10");
    try testing.expect(try s.next());
    try f.expectSels("13-13");
    try testing.expect(s.active().?.choice == null);
}

test "snippet_session: multi-cursor expansion selects stops together" {
    var f = try Fx.init("a\nb\n");
    defer f.deinit();
    const s = try Session.begin(gpa, f.view, &.{ .{ .start = 1, .end = 1 }, .{ .start = 3, .end = 3 } }, try f.expand("(${1:x}, $2)"));
    defer s.destroy();
    try f.expectText("a(x, )\nb(x, )\n");
    try f.expectSels("2-3 9-10");
    try testing.expectEqual(@as(usize, 2), s.active().?.ranges.len);
    try f.typeText("yy");
    try f.expectText("a(yy, )\nb(yy, )\n");
    try testing.expect(try s.next());
    try f.expectSels("6-6 14-14");
    try f.typeText("z");
    try f.expectText("a(yy, z)\nb(yy, z)\n");
}

test "snippet_session: ends on $0, Esc, cursor escape, edit outside, undo" {
    {
        // Only $0: done at once, the caret there.
        var f = try Fx.init("");
        defer f.deinit();
        const s = try Session.begin(gpa, f.view, &.{.{ .start = 0, .end = 0 }}, try f.expand("ab$0cd"));
        defer s.destroy();
        try testing.expect(s.done);
        try f.expectSels("2-2");
    }
    {
        var f = try Fx.init("");
        defer f.deinit();
        const s = try Session.begin(gpa, f.view, &.{.{ .start = 0, .end = 0 }}, try f.expand("${1:a} $2"));
        defer s.destroy();
        s.end();
        try testing.expect(s.done);
        try testing.expect(!try s.next());
    }
    {
        var f = try Fx.init("zz");
        defer f.deinit();
        const s = try Session.begin(gpa, f.view, &.{.{ .start = 2, .end = 2 }}, try f.expand("${1:a} $2"));
        defer s.destroy();
        f.view.setSelection(.caret(0));
        s.cursorMoved();
        try testing.expect(s.done);
    }
    {
        var f = try Fx.init("zz");
        defer f.deinit();
        const s = try Session.begin(gpa, f.view, &.{.{ .start = 2, .end = 2 }}, try f.expand("${1:a} $2"));
        defer s.destroy();
        f.view.setSelection(.caret(0));
        try f.typeText("q");
        try testing.expect(s.done);
    }
    {
        var f = try Fx.init("zz");
        defer f.deinit();
        const s = try Session.begin(gpa, f.view, &.{.{ .start = 1, .end = 1 }}, try f.expand("${1:a} $2"));
        defer s.destroy();
        try testing.expect(try f.view.undoStep());
        try testing.expect(s.done);
        // Undo restores the text before the insertion byte for byte.
        try f.expectText("zz");
    }
}

test "snippet_session: nested session push/pop" {
    var f = try Fx.init("");
    defer f.deinit();
    var stack: Session.Stack = .init(gpa);
    defer stack.deinit();
    var outer = try Snippet.parse(gpa, "if ($1) { $2 }$0");
    defer outer.deinit();
    var oe: Snippet.Expansion = .{};
    defer oe.deinit(gpa);
    try outer.expand(gpa, .none, .{}, &oe);
    try stack.begin(f.view, &.{.{ .start = 0, .end = 0 }}, &oe);
    try f.expectText("if () {  }");
    try f.expectSels("4-4");
    // A snippet inside the first stop runs first.
    var inner = try Snippet.parse(gpa, "${1:a} == ${2:b}");
    defer inner.deinit();
    var ie: Snippet.Expansion = .{};
    defer ie.deinit(gpa);
    try inner.expand(gpa, .none, .{}, &ie);
    try stack.begin(f.view, &.{.{ .start = 4, .end = 4 }}, &ie);
    try f.expectText("if (a == b) {  }");
    try f.expectSels("4-5");
    try testing.expectEqual(@as(usize, 2), stack.items.items.len);
    try testing.expect(try stack.next());
    try f.expectSels("9-10");
    // Past the inner snippet's end: back in the outer one.
    try testing.expect(try stack.next());
    try testing.expectEqual(@as(usize, 1), stack.items.items.len);
    try f.expectSels("10-10");
    try testing.expect(try stack.next());
    try f.expectSels("14-14");
    try testing.expect(try stack.next());
    try f.expectSels("16-16");
    try testing.expect(stack.top() == null);
    try testing.expect(!try stack.next());
}
