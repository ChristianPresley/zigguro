//! ServerStatus against the scripted fake server (server_status.script).

const std = @import("std");
const Harness = @import("../Manager_test.zig").Harness;
const ServerStatus = @import("server_status.zig");
const Manager = @import("../Manager.zig");

const testing = std.testing;

var fx_st: *ServerStatus = undefined;
var label_buf: [128]u8 = undefined;

fn labelIs(h: *Harness, comptime want: []const u8) bool {
    const s = h.server("fake") orelse return false;
    return std.mem.eql(u8, fx_st.label(s, &label_buf), want);
}

fn waitLabel(h: *Harness, comptime want: []const u8) !void {
    for (0..2000) |_| {
        h.mgr.tick();
        if (labelIs(h, want)) return;
        try h.rt.io.sleep(.fromMilliseconds(5), .awake);
    }
    std.debug.print("label: {s}\n", .{fx_st.label(h.server("fake").?, &label_buf)});
    return error.Timeout;
}

test "server_status: labels follow start-up and progress; cancel; details and logs" {
    var h: Harness = undefined;
    try h.init("server_status.script", &.{});
    var st: ServerStatus = undefined;
    try st.init(&h.mgr, .noop);
    fx_st = &st;
    defer {
        h.deinit();
        st.deinit();
    }
    const d = try h.open("main.zig", "x");
    defer h.docs.release(d);
    try waitLabel(&h, "fake: indexing  42%");
    const s = h.server("fake").?;
    var out: [4]*Manager.Server = undefined;
    try testing.expectEqual(@as(usize, 1), st.serversOf(d, &out));
    try testing.expect(out[0] == s);
    var pb: [64]u8 = undefined;
    try testing.expect(st.progressOf(s.id, &pb).?.cancellable);

    var w: std.Io.Writer.Allocating = .init(testing.allocator);
    defer w.deinit();
    try st.details(s, &w.writer);
    try testing.expect(std.mem.indexOf(u8, w.written(), "Server: fake 1.2") != null);
    try testing.expect(std.mem.indexOf(u8, w.written(), "Position encoding: utf16") != null);

    // Cancel: the server ends the progress.
    try testing.expect(st.cancelProgress(s.id));
    try waitLabel(&h, "fake \u{2713}");
    try testing.expect(!st.cancelProgress(s.id));

    w.clearRetainingCapacity();
    try st.logs(s, &w.writer);
    try testing.expect(std.mem.indexOf(u8, w.written(), "fake: protocol trace") != null);
    try testing.expect(std.mem.indexOf(u8, w.written(), "window/workDoneProgress/cancel") != null);

    // Stopped by hand.
    h.mgr.closeDoc(d);
    h.mgr.stop(s);
    try testing.expectEqualStrings("fake: stopped", st.label(s, &label_buf));
}
