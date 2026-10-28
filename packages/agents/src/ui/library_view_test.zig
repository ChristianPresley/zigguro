//! The prompt library picker in a headless window over a real library in
//! a temporary workspace.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_agents = @import("zg_agents");
const view_mod = @import("library_view.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const TestApp = zg_gui.testing.TestApp;
const PromptLibrary = zg_agents.library.PromptLibrary;

const Composer = struct {
    text: std.ArrayList(u8) = .empty,
    fn insert(ctx: *anyopaque, text: []const u8) void {
        const c: *Composer = @ptrCast(@alignCast(ctx));
        c.text.appendSlice(gpa, text) catch {};
    }
};

const Writer = struct {
    dir: std.Io.Dir,
    fn write(ctx: *anyopaque, _: PromptLibrary.Scope, rel: []const u8, bytes: []const u8) anyerror!?u64 {
        const w: *Writer = @ptrCast(@alignCast(ctx));
        if (std.fs.path.dirname(rel)) |d| try w.dir.createDirPath(io, d);
        try w.dir.writeFile(io, .{ .sub_path = rel, .data = bytes });
        return 7;
    }
};

const Fx = struct {
    tmp: testing.TmpDir,
    prompts: std.Io.Dir,
    lib: *PromptLibrary,
    composer: Composer = .{},
    writer: Writer = undefined,
    v: *view_mod.LibraryPicker,
    t: *TestApp,

    fn init(f: *Fx) !void {
        f.* = .{ .tmp = testing.tmpDir(.{ .iterate = true }), .prompts = undefined, .lib = undefined, .v = undefined, .t = undefined };
        f.prompts = try f.tmp.dir.createDirPathOpen(io, ".zigguro/prompts", .{ .open_options = .{ .iterate = true } });
        try f.prompts.createDirPath(io, "writing");
        try f.prompts.writeFile(io, .{ .sub_path = "writing/explain.md", .data = "---\ntitle: Explain for an audience\ntags: [writing]\nvariables:\n  - {name: audience, type: text, required: true}\n---\nExplain {{selection}} to {{audience}} in a {{length|choice:short,medium,long}} answer.\n" });
        try f.prompts.writeFile(io, .{ .sub_path = "writing/thanks.md", .data = "---\ntitle: Thank-you note\n---\nWrite a short thank-you note.\n" });
        f.writer = .{ .dir = f.prompts };
        f.lib = try PromptLibrary.open(gpa, io, .{ .project = f.prompts }, null);
        f.lib.writer = .{ .ctx = &f.writer, .write = Writer.write };
        f.v = try view_mod.LibraryPicker.init(gpa, .{
            .lib = f.lib,
            .target = .{ .ctx = &f.composer, .name = "Agent pane", .insert = Composer.insert },
            .ctx = .{ .selection = "the borrow checker" },
        });
        f.t = try TestApp.init(gpa, .{ .root = .of(f.v), .size = .{ .w = 900, .h = 900 } });
        _ = f.t.settle();
    }

    fn deinit(f: *Fx) void {
        f.t.deinit();
        f.v.deinit();
        f.lib.deinit();
        f.composer.text.deinit(gpa);
        f.prompts.close(io);
        f.tmp.cleanup();
    }

    fn settle(f: *Fx) void {
        f.t.win.markAllDirty();
        _ = f.t.settle();
    }
};

test "library_view: search, preview, form and insert" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    f.v.query.setText("explain") catch {};
    f.settle();
    try testing.expect(f.t.find(.{ .role = .listitem, .name_contains = "writing/explain" }) != null);
    try testing.expect(f.t.find(.{ .role = .listitem, .name_contains = "writing/thanks" }) == null);
    try testing.expect(f.t.find(.{ .test_id = "library-preview" }) != null);
    // Enter opens the form; the selection is filled in from the editor.
    try f.t.click(.{ .role = .button, .name = "Fill in…" });
    f.settle();
    try testing.expect(f.t.find(.{ .test_id = "library-form" }) != null);
    // Insert without the required value says what is missing.
    try f.t.click(.{ .role = .button, .name = "Insert into Agent pane" });
    f.settle();
    try testing.expect(f.t.find(.{ .role = .status, .name = "Fill in audience" }) != null);
    f.v.fields.items[0].setText("new Rust users") catch {};
    try f.t.click(.{ .role = .button, .name = "long" });
    f.settle();
    try f.t.click(.{ .role = .button, .name = "Insert into Agent pane" });
    f.settle();
    try testing.expectEqualStrings("Explain the borrow checker to new Rust users in a long answer.\n", f.composer.text.items);
    try testing.expect(f.v.done);
    try testing.expectEqual(@as(u32, 1), f.lib.usage.get("writing/explain").?);
}

test "library_view: an entry without variables inserts at once" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    f.v.query.setText("thank") catch {};
    f.settle();
    try f.t.click(.{ .role = .button, .name = "Insert" });
    f.settle();
    try testing.expectEqualStrings("Write a short thank-you note.\n", f.composer.text.items);
}

test "library_view: save prompt from a message" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var why: []const u8 = "";
    const id = view_mod.saveFromMessage(f.lib, arena.allocator(), "Review {{file}} for security issues\nFocus on {{area}}.", &why).?;
    try testing.expectEqualStrings("saved/review-file-for-security-issues", id);
    try f.lib.reload();
    const e = f.lib.get(id).?;
    try testing.expectEqual(@as(usize, 1), e.variables.len);
    try testing.expectEqualStrings("area", e.variables[0].name);
}
