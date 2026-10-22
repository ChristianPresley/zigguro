//! The approval and trust dialogs in a headless zg_gui window.

const std = @import("std");
const zg_gui = @import("zg_gui");
const zg_security = @import("zg_security");
const approval = @import("approval_dialog.zig");
const trust = @import("trust_dialog.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;
const TestApp = zg_gui.testing.TestApp;
const contracts = zg_security.contracts;

const Blank = struct {
    pub fn build(_: *Blank, ui: *zg_gui.Ui) void {
        ui.open(.{ .style = .{ .w = .{ .pct = 100 }, .h = .{ .pct = 100 } } });
        ui.close();
    }
};

const Fx = struct {
    blank: Blank = .{},
    t: *TestApp,
    port: approval.DialogApprovalPort,

    fn init(f: *Fx) !void {
        f.blank = .{};
        f.t = try TestApp.init(gpa, .{ .root = .of(&f.blank), .size = .{ .w = 800, .h = 600 } });
        f.port = .init(gpa, io, f.t.win);
        _ = f.t.settle();
    }

    fn deinit(f: *Fx) void {
        f.port.deinit();
        _ = f.t.settle();
        f.t.deinit();
    }

    fn present(f: *Fx, req: contracts.ApprovalRequest) !contracts.ApprovalTicket {
        const t = try f.port.port().present(req);
        _ = f.t.settle();
        return t;
    }
};

fn request(command: ?[]const u8, editable: bool, rule: ?[]const u8) contracts.ApprovalRequest {
    return .{
        .kind = .command,
        .actor = .{ .agent = .{ .session = "s1", .agent = "coder" } },
        .title = "Run a command?",
        .detail_json = "{}",
        .command = command,
        .risk = &.{"Deletes files"},
        .rule_suggestion = rule,
        .editable = editable,
        .created_ms = 0,
    };
}

test "approval: the dialog shows the request and Allow once answers" {
    var f: Fx = .{ .t = undefined, .port = undefined };
    try f.init();
    defer f.deinit();
    const tk = try f.present(request("rm -rf build", false, "Bash(rm -rf build)"));
    try testing.expect(f.t.find(.{ .test_id = "approval" }) != null);
    try testing.expect(f.t.find(.{ .name = "Always allow" }) != null);
    try testing.expectEqual(@as(usize, 1), f.port.openCount());
    try f.t.click(.{ .role = .button, .name = "Allow once" });
    try testing.expect(f.t.find(.{ .test_id = "approval" }) == null);
    try testing.expectEqual(contracts.Answer.allow_once, try tk.await(io));
    try testing.expectEqual(@as(usize, 0), f.port.openCount());
}

test "approval: session and always answers carry the rule" {
    var f: Fx = .{ .t = undefined, .port = undefined };
    try f.init();
    defer f.deinit();
    var tk = try f.present(request("ls", false, "Bash(ls)"));
    try f.t.click(.{ .role = .button, .name = "Always allow" });
    try testing.expectEqualStrings("Bash(ls)", (try tk.await(io)).allow_always);
    tk = try f.present(request("make", false, null));
    try testing.expect(f.t.find(.{ .name = "Always allow" }) == null);
    try f.t.click(.{ .role = .button, .name = "Allow for session" });
    try testing.expectEqualStrings("make", (try tk.await(io)).allow_session);
}

test "approval: deny sends the reason, Escape denies, edits run edited" {
    var f: Fx = .{ .t = undefined, .port = undefined };
    try f.init();
    defer f.deinit();
    var tk = try f.present(request("curl x", false, null));
    try f.t.click(.{ .role = .textbox, .name = "Reason" });
    f.t.typeText("not now");
    try f.t.click(.{ .role = .button, .name = "Deny" });
    try testing.expectEqualStrings("not now", (try tk.await(io)).deny);

    tk = try f.present(request("curl x", false, null));
    f.t.press(.escape, .{});
    try testing.expectEqualStrings("dismissed", (try tk.await(io)).deny);

    tk = try f.present(request("rm -rf /", true, null));
    try f.t.click(.{ .role = .textbox, .name = "Command" });
    f.t.press(.end, .{ .ctrl = true });
    f.t.press(.backspace, .{});
    f.t.typeText("/tmp/x");
    try f.t.click(.{ .role = .button, .name = "Run edited" });
    try testing.expectEqualStrings("rm -rf /tmp/x", (try tk.await(io)).edit);
}

test "approval: cancel closes the dialog with a denial" {
    var f: Fx = .{ .t = undefined, .port = undefined };
    try f.init();
    defer f.deinit();
    const tk = try f.present(request(null, false, null));
    tk.cancel();
    _ = f.t.settle();
    try testing.expect(f.t.find(.{ .test_id = "approval" }) == null);
    try testing.expectEqualStrings("cancelled", (try tk.await(io)).deny);
}

const Got = struct {
    choice: ?trust.TrustChoice = null,
    fn cb(ctx: ?*anyopaque, c: trust.TrustChoice) void {
        const g: *Got = @ptrCast(@alignCast(ctx.?));
        g.choice = c;
    }
};

test "trust: the prompt answers trust, parent, or stays restricted" {
    var f: Fx = .{ .t = undefined, .port = undefined };
    try f.init();
    defer f.deinit();
    var got: Got = .{};
    _ = try trust.askTrust(f.t.win, .{ .folder = "/src/work/app", .parent = "/src/work" }, .{ .ctx = &got, .f = Got.cb });
    _ = f.t.settle();
    try testing.expect(f.t.find(.{ .name = "Trust parent folder 'work'" }) != null);
    try f.t.click(.{ .role = .button, .name = "Trust parent folder 'work'" });
    try testing.expectEqual(trust.TrustChoice.trust_parent, got.choice.?);

    got = .{};
    _ = try trust.askTrust(f.t.win, .{ .folder = "/app" }, .{ .ctx = &got, .f = Got.cb });
    _ = f.t.settle();
    try testing.expect(f.t.find(.{ .name = "Trust parent folder" }) == null);
    try f.t.click(.{ .role = .button, .name = "Trust folder" });
    try testing.expectEqual(trust.TrustChoice.trust, got.choice.?);

    got = .{};
    _ = try trust.askTrust(f.t.win, .{ .folder = "/app" }, .{ .ctx = &got, .f = Got.cb });
    _ = f.t.settle();
    f.t.press(.escape, .{});
    try testing.expectEqual(trust.TrustChoice.restricted, got.choice.?);
}
