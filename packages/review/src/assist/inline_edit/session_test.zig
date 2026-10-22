const std = @import("std");
const model = @import("../../model/root.zig");
const apply = @import("../../apply/root.zig");
const session = @import("session.zig");

const testing = std.testing;
const gpa = testing.allocator;
const InlineEditSession = session.InlineEditSession;

const Fake = struct {
    predicted: bool = false,
    next: u64 = 1,
    sink: ?session.Sink = null,
    users: std.ArrayList([]u8) = .empty,
    predictions: std.ArrayList(?[]u8) = .empty,
    cancelled: std.ArrayList(u64) = .empty,

    fn port(f: *Fake) session.ModelPort {
        return .{ .ctx = f, .start = startFn, .cancel = cancelFn, .predicted_outputs = f.predicted };
    }

    fn deinit(f: *Fake) void {
        for (f.users.items) |u| gpa.free(u);
        f.users.deinit(gpa);
        for (f.predictions.items) |p| if (p) |x| gpa.free(x);
        f.predictions.deinit(gpa);
        f.cancelled.deinit(gpa);
    }

    fn startFn(ctx: *anyopaque, req: *const session.Request, sink: session.Sink) anyerror!u64 {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        try f.users.append(gpa, try gpa.dupe(u8, req.user));
        try f.predictions.append(gpa, if (req.prediction) |p| try gpa.dupe(u8, p) else null);
        f.sink = sink;
        f.next += 1;
        return f.next - 1;
    }

    fn cancelFn(ctx: *anyopaque, id: u64) void {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.cancelled.append(gpa, id) catch {};
    }

    /// Streams `chunks` on the last stream, then ends it.
    fn stream(f: *Fake, chunks: []const []const u8, end: bool) void {
        const s = f.sink.?;
        for (chunks) |c| s.chunk(s.ctx, f.next - 1, c);
        if (end) s.end(s.ctx, f.next - 1, null);
    }
};

const Fx = struct {
    blobs: model.MemBlobs,
    disk: apply.MemFiles,
    history: model.History,
    q: *model.Queue,
    ap: apply.Applier,
    fake: Fake = .{},

    fn init(fx: *Fx) !void {
        fx.* = .{ .blobs = .init(gpa), .disk = .init(gpa), .history = .init(gpa, null), .q = undefined, .ap = undefined };
        fx.q = try model.Queue.init(gpa, testing.io, .{ .root = "/w", .blobs = fx.blobs.blobs() });
        fx.ap = .init(gpa, testing.io, fx.q, fx.disk.files(), &fx.history);
    }

    fn deinit(fx: *Fx) void {
        fx.fake.deinit();
        fx.q.deinit();
        fx.history.deinit();
        fx.disk.deinit();
        fx.blobs.deinit();
    }

    fn start(fx: *Fx, text: []const u8, region: [2]usize, o: struct { question: bool = false, secrets: ?session.Secrets = null }) !*InlineEditSession {
        if (fx.disk.get("a.ts") == null) try fx.disk.put("a.ts", text, false);
        return InlineEditSession.start(gpa, fx.q, &fx.ap, fx.fake.port(), .{
            .path = "a.ts",
            .language = "typescript",
            .text = text,
            .region = region,
            .instruction = "make it const",
            .question = o.question,
            .secrets = o.secrets,
            .ref = .{ .session = 7 },
            .workspace = "/w",
        });
    }
};

const file = "function f() {\n  let x = 1;\n  return x;\n}\n";
const line2 = [2]usize{ 15, 28 };

test "inline: edit streams into region edits, lands in the queue, accept writes it" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const s = try fx.start(file, line2, .{});
    defer s.deinit();
    try testing.expectEqualStrings("  let x = 1;\n", s.original());
    try testing.expect(std.mem.indexOf(u8, fx.fake.users.items[0], "<selection>  let x = 1;\n</selection>") != null);
    // No predicted outputs: no prediction sent.
    try testing.expect(fx.fake.predictions.items[0] == null);

    fx.fake.stream(&.{ "<rewrite>\n  const", " x = 1;\n" }, false);
    try testing.expectEqual(session.State.streaming, s.state);
    var fe = (try s.fileEdits(gpa)).?;
    const mid = try fe.applyToSlice(gpa, file);
    fe.deinit();
    defer gpa.free(mid);
    // The original line is not reached yet (nothing matched): it stays.
    try testing.expectEqualStrings("function f() {\n  const x = 1;\n  let x = 1;\n  return x;\n}\n", mid);

    fx.fake.stream(&.{"</rewrite>"}, true);
    try testing.expectEqual(session.State.ready, s.state);
    const cs = fx.q.get(s.changeset.?).?;
    try testing.expectEqual(model.Presentation.inline_, cs.presentation);
    try testing.expectEqualStrings("make it const", cs.prov.origin.inline_edit.instruction);

    const r = try s.accept();
    try testing.expect(r == .ok);
    try testing.expectEqual(session.State.accepted, s.state);
    try testing.expectEqualStrings("function f() {\n  const x = 1;\n  return x;\n}\n", fx.disk.get("a.ts").?);
}

test "inline: predicted outputs sent only when the model supports them" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    fx.fake.predicted = true;
    const s = try fx.start(file, line2, .{});
    defer s.deinit();
    try testing.expectEqualStrings("  let x = 1;\n", fx.fake.predictions.items[0].?);
}

test "inline: secret selection refused" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const Sec = struct {
        fn isSecret(_: *anyopaque, t: []const u8) bool {
            return std.mem.indexOf(u8, t, "let x") != null;
        }
    };
    var dummy: u8 = 0;
    try testing.expectError(error.SecretSelection, fx.start(file, line2, .{ .secrets = .{ .ctx = &dummy, .isSecret = Sec.isSecret } }));
    try testing.expectEqual(@as(usize, 0), fx.fake.users.items.len);
}

test "inline: cancel stops the stream and ignores late chunks" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const s = try fx.start(file, line2, .{});
    defer s.deinit();
    fx.fake.stream(&.{"<rewrite>\n  const x"}, false);
    try s.cancel("Cancelled");
    try testing.expectEqual(session.State.cancelled, s.state);
    try testing.expectEqualSlices(u64, &.{1}, fx.fake.cancelled.items);
    fx.fake.stream(&.{" = 1;\n</rewrite>"}, true);
    try testing.expectEqual(session.State.cancelled, s.state);
    try testing.expect(s.changeset == null);
}

test "inline: follow-up discards the earlier changeset and diffs against the original" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const s = try fx.start(file, line2, .{});
    defer s.deinit();
    fx.fake.stream(&.{"<rewrite>  const x = 1;\n</rewrite>"}, true);
    const first = s.changeset.?;
    try s.followUp("and call it count");
    try testing.expectEqual(model.State.discarded, fx.q.get(first).?.state);
    const user = fx.fake.users.items[1];
    try testing.expect(std.mem.indexOf(u8, user, "<selection>  const x = 1;\n</selection>") != null);
    try testing.expect(std.mem.indexOf(u8, user, "1. make it const\n") != null);
    try testing.expect(std.mem.endsWith(u8, user, "Instruction: and call it count\n"));
    fx.fake.stream(&.{"<rewrite>  const count = 1;\n</rewrite>"}, true);
    var fe = (try s.fileEdits(gpa)).?;
    defer fe.deinit();
    const out = try fe.applyToSlice(gpa, file);
    defer gpa.free(out);
    try testing.expectEqualStrings("function f() {\n  const count = 1;\n  return x;\n}\n", out);
    try s.reject();
    try testing.expectEqualStrings(file, fx.disk.get("a.ts").?);
}

test "inline: user edit inside region cancels; before it shifts the region" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const s = try fx.start(file, line2, .{});
    defer s.deinit();
    // Two bytes typed on line 1 move the region.
    try s.documentEdited(3, 3, 2);
    try testing.expectEqual([2]usize{ 17, 30 }, s.o.region);
    // An edit after it changes nothing.
    try s.documentEdited(40, 41, 0);
    try testing.expectEqual(session.State.streaming, s.state);
    // One inside cancels.
    try s.documentEdited(20, 21, 1);
    try testing.expectEqual(session.State.cancelled, s.state);
    try testing.expectEqualStrings("Selection changed: cancelled", s.reason);
}

test "inline: a question streams an answer and makes no changeset" {
    var fx: Fx = undefined;
    try fx.init();
    defer fx.deinit();
    const s = try fx.start(file, line2, .{ .question = true });
    defer s.deinit();
    try testing.expect(std.mem.indexOf(u8, fx.fake.users.items[0], "Question: make it const") != null);
    fx.fake.stream(&.{ "Because `x` ", "is never reassigned." }, true);
    try testing.expectEqual(session.State.answered, s.state);
    try testing.expectEqualStrings("Because `x` is never reassigned.", s.output());
    try testing.expect(s.changeset == null);
}
