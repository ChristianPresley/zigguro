//! What the LSP client needs from the application around it: toasts and
//! dialogs, opening documents, the server output log and settings. The GUI
//! (apps/zigguro) and the headless host (E07.F05.S01.T04) implement
//! `ClientHost`; `server_requests.zig` calls it.
//!
//! Every function is called on a worker and must not block: reach the UI
//! through `Runtime.post` and answer through the callback later.

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("../gen/protocol.zig");

/// Identifies one language server (one Client) to the host.
pub const ServerId = u32;

/// The answer to `showMessageRequest`: the index of the chosen action, or
/// null when the toast was dismissed. Call at most once; late calls (after
/// the client's timeout) are ignored.
pub const ReplyCb = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, choice: ?usize) void,

    pub fn call(cb: ReplyCb, choice: ?usize) void {
        cb.func(cb.ctx, choice);
    }
};

/// The answer to `showDocument`: whether the document was shown.
pub const BoolCb = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, ok: bool) void,

    pub fn call(cb: BoolCb, ok: bool) void {
        cb.func(cb.ctx, ok);
    }
};

pub const ClientHost = struct {
    ctx: ?*anyopaque,
    /// A toast (`window/showMessage`).
    showMessage: *const fn (ctx: ?*anyopaque, server: ServerId, kind: protocol.MessageType, text: []const u8) void,
    /// A toast with action buttons (`window/showMessageRequest`).
    showMessageRequest: *const fn (ctx: ?*anyopaque, server: ServerId, kind: protocol.MessageType, text: []const u8, actions: []const []const u8, reply: ReplyCb) void,
    /// Opens `uri` in the editor, or with the system handler when
    /// `external` (`window/showDocument`).
    showDocument: *const fn (ctx: ?*anyopaque, uri: []const u8, external: bool, take_focus: bool, selection: ?protocol.Range, reply: BoolCb) void,
    /// A line for the server output log (`window/logMessage`).
    logMessage: *const fn (ctx: ?*anyopaque, server: ServerId, kind: protocol.MessageType, text: []const u8) void,
    /// The settings value of `section` (all settings when null) for
    /// `scope_uri`, resolved folder > workspace > user; `.null` when
    /// unknown. Allocate from `arena`.
    getConfiguration: *const fn (ctx: ?*anyopaque, section: ?[]const u8, scope_uri: ?[]const u8, arena: Allocator) std.json.Value,
};

/// A host that shows nothing, opens nothing and knows no settings.
pub const null_host: ClientHost = .{
    .ctx = null,
    .showMessage = struct {
        fn f(_: ?*anyopaque, _: ServerId, _: protocol.MessageType, _: []const u8) void {}
    }.f,
    .showMessageRequest = struct {
        fn f(_: ?*anyopaque, _: ServerId, _: protocol.MessageType, _: []const u8, _: []const []const u8, reply: ReplyCb) void {
            reply.call(null);
        }
    }.f,
    .showDocument = struct {
        fn f(_: ?*anyopaque, _: []const u8, _: bool, _: bool, _: ?protocol.Range, reply: BoolCb) void {
            reply.call(false);
        }
    }.f,
    .logMessage = struct {
        fn f(_: ?*anyopaque, _: ServerId, _: protocol.MessageType, _: []const u8) void {}
    }.f,
    .getConfiguration = struct {
        fn f(_: ?*anyopaque, _: ?[]const u8, _: ?[]const u8, _: Allocator) std.json.Value {
            return .null;
        }
    }.f,
};

/// A feature whose results the server asked the client to refetch.
pub const RefreshFeature = enum { semantic_tokens, inlay_hint, inline_value, diagnostic, code_lens, folding_range };

pub const RefreshEvent = struct { server: ServerId, feature: RefreshFeature };

/// Receives refresh events (the F02 to F04 services). Runs on a worker.
pub const RefreshListener = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, e: RefreshEvent) void,
};

/// Receives the file watchers a server registers for
/// `workspace/didChangeWatchedFiles` (the watch bridge, E07.F01.S02.T07).
/// `watchers` is valid only during the call. Runs on a worker.
pub const WatchBridge = struct {
    ctx: ?*anyopaque,
    set: *const fn (ctx: ?*anyopaque, server: ServerId, registration_id: []const u8, watchers: []const protocol.FileSystemWatcher) void,
    clear: *const fn (ctx: ?*anyopaque, server: ServerId, registration_id: []const u8) void,
};

test "host: null host answers at once" {
    const Got = struct {
        var choice: ?usize = 7;
        var ok: bool = true;
        fn onChoice(_: ?*anyopaque, c: ?usize) void {
            choice = c;
        }
        fn onOk(_: ?*anyopaque, b: bool) void {
            ok = b;
        }
    };
    null_host.showMessageRequest(null, 1, .Info, "x", &.{"a"}, .{ .ctx = null, .func = Got.onChoice });
    null_host.showDocument(null, "file:///a", false, true, null, .{ .ctx = null, .func = Got.onOk });
    try std.testing.expectEqual(@as(?usize, null), Got.choice);
    try std.testing.expect(!Got.ok);
    try std.testing.expect(null_host.getConfiguration(null, "zls", null, std.testing.allocator) == .null);
}
