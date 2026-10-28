//! The language servers' host without a GUI (E07.F05.S01.T04): nobody can
//! be asked, so `window/showMessageRequest` gets no choice (null) and
//! `window/showDocument` is refused (`success: false`). Messages
//! (`window/showMessage`) go to `sink` as `language server: <kind>: <text>`
//! lines, errors and warnings always, the rest with `verbose`;
//! `window/logMessage` only with `verbose`. Settings come from the
//! manager's config provider, so `getConfiguration` here knows none.
//!
//! Called on the clients' workers; `sink` is written under a lock and
//! flushed after every line.

const HeadlessHost = @This();
const std = @import("std");
const zg_lsp = @import("zg_lsp");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const host = zg_lsp.client.host;
const MessageType = zg_lsp.protocol.MessageType;

pub const ClientHost = host.ClientHost;

pub const Options = struct {
    /// Info and log messages too.
    verbose: bool = false,
};

io: Io,
sink: ?*Io.Writer,
opts: Options,
mutex: Io.Mutex = .init,
/// Lines written to `sink`.
shown: u32 = 0,
/// Questions answered with no choice, documents not shown.
refused: u32 = 0,

pub fn init(io: Io, sink: ?*Io.Writer, opts: Options) HeadlessHost {
    return .{ .io = io, .sink = sink, .opts = opts };
}

/// For `Manager.ui_host`. `h` must outlive the servers.
pub fn clientHost(h: *HeadlessHost) ClientHost {
    var c = host.null_host;
    c.ctx = h;
    c.showMessage = showMessage;
    c.showMessageRequest = showMessageRequest;
    c.showDocument = showDocument;
    c.logMessage = logMessage;
    return c;
}

fn showMessage(ctx: ?*anyopaque, _: host.ServerId, kind: MessageType, text: []const u8) void {
    const h: *HeadlessHost = @ptrCast(@alignCast(ctx.?));
    h.say(kind, text, false);
}

fn showMessageRequest(ctx: ?*anyopaque, _: host.ServerId, kind: MessageType, text: []const u8, _: []const []const u8, reply: host.ReplyCb) void {
    const h: *HeadlessHost = @ptrCast(@alignCast(ctx.?));
    h.say(kind, text, false);
    h.count();
    reply.call(null);
}

fn showDocument(ctx: ?*anyopaque, _: []const u8, _: bool, _: bool, _: ?zg_lsp.protocol.Range, reply: host.BoolCb) void {
    const h: *HeadlessHost = @ptrCast(@alignCast(ctx.?));
    h.count();
    reply.call(false);
}

fn logMessage(ctx: ?*anyopaque, _: host.ServerId, kind: MessageType, text: []const u8) void {
    const h: *HeadlessHost = @ptrCast(@alignCast(ctx.?));
    h.say(kind, text, true);
}

fn count(h: *HeadlessHost) void {
    h.mutex.lockUncancelable(h.io);
    defer h.mutex.unlock(h.io);
    h.refused += 1;
}

fn say(h: *HeadlessHost, kind: MessageType, text: []const u8, log_line: bool) void {
    const important = kind == .Error or kind == .Warning;
    if (!h.opts.verbose and (log_line or !important)) return;
    h.mutex.lockUncancelable(h.io);
    defer h.mutex.unlock(h.io);
    const w = h.sink orelse return;
    const label = switch (kind) {
        .Error => "error",
        .Warning => "warning",
        .Info => "info",
        else => "log",
    };
    w.print("language server: {s}: {s}\n", .{ label, std.mem.trimEnd(u8, text, "\r\n") }) catch return;
    w.flush() catch {};
    h.shown += 1;
}
