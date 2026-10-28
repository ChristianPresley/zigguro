//! Virtual documents (E07.F04.S01.T04): locations a language server
//! reports outside the file system (rust-analyzer macro expansions, jdt
//! decompiled classes) open as read-only documents whose text comes from
//! `workspace/textDocumentContent` (LSP 3.18).
//!
//! A server claims URI schemes in its capabilities
//! (`workspace.textDocumentContent.schemes`) or by registering the method
//! later; `canOpen` asks whether some running server claims a URI's
//! scheme. `open` returns a document at once (empty while the text
//! loads); a URI no server claims opens with a placeholder line so
//! navigation still lands somewhere. Documents are counted per `open`
//! and closed by the last `release`.
//!
//! `workspace/textDocumentContent/refresh` fetches every open document of
//! that server again; new text replaces the old as a line diff, so views
//! keep their place. The documents are never sent to servers (`didOpen`):
//! the app does not attach them. UI thread only.

const VirtualDocs = @This();
const std = @import("std");
const zg_core = @import("zg_core");
const zg_lsp = @import("zg_lsp");
const zg_editor = @import("zg_editor");
const Manager = @import("../Manager.zig");
const oneshot = @import("oneshot.zig");

const Allocator = std.mem.Allocator;
const DocHandle = zg_editor.model.api.registry.DocHandle;
const Document = zg_editor.model.document.Document;
const Client = zg_lsp.client.Client;
const Content = oneshot.Oneshot(.@"workspace/textDocumentContent", Tag);

const log = std.log.scoped(.virtual_docs);

const Tag = struct { id: u64, round: u64 };

pub const State = enum {
    /// Waiting for the server.
    loading,
    ready,
    /// No server claims the scheme: the placeholder shows.
    unavailable,
    /// The server failed to answer; the last text stays.
    failed,
};

pub const Entry = struct {
    id: u64,
    uri: []u8,
    h: DocHandle,
    /// `open` calls not yet released.
    refs: u32,
    /// The server asked (its `Manager.Server.id`).
    server: ?u32,
    state: State,
    /// Bumped by every fetch: older answers are dropped.
    round: u64 = 0,
};

gpa: Allocator,
mgr: *Manager,
req: Content,
entries: std.ArrayList(Entry) = .empty,
next_id: u64 = 1,
/// Bumped whenever a document's text or state changes.
generation: u64 = 0,

/// `v` must not move afterwards (it listens for refreshes).
pub fn init(v: *VirtualDocs, mgr: *Manager, waker: zg_core.runtime.Waker) !void {
    v.* = .{ .gpa = mgr.gpa, .mgr = mgr, .req = .init(mgr.gpa, mgr.rt.io, waker) };
    try mgr.onRefresh(.{ .ctx = v, .func = onRefresh });
}

/// Call after `Manager.deinit` and before the document registry goes.
pub fn deinit(v: *VirtualDocs) void {
    v.req.deinit();
    for (v.entries.items) |e| {
        for (0..e.refs) |_| v.mgr.docs.release(e.h);
        v.gpa.free(e.uri);
    }
    v.entries.deinit(v.gpa);
}

/// The scheme of `uri` (before the first `:`).
pub fn schemeOf(uri: []const u8) []const u8 {
    const i = std.mem.indexOfScalar(u8, uri, ':') orelse return "";
    return uri[0..i];
}

/// The running server claiming `scheme`, if any.
pub fn serverFor(v: *const VirtualDocs, scheme: []const u8) ?*Manager.Server {
    if (scheme.len == 0 or std.mem.eql(u8, scheme, "file")) return null;
    for (v.mgr.serverList()) |s| {
        if (s.status != .running) continue;
        const caps = (s.client orelse continue).caps() orelse continue;
        if (caps.options(.text_document_content)) |o| for (o.schemes) |x| if (std.mem.eql(u8, x, scheme)) return s;
        for (caps.registrations.items) |*reg| {
            if (!reg.features.contains(.text_document_content)) continue;
            if (claims(reg.options, scheme)) return s;
        }
    }
    return null;
}

/// Whether the dynamic registration options `opts` list `scheme`.
fn claims(opts: ?std.json.Value, scheme: []const u8) bool {
    const o = opts orelse return false;
    if (o != .object) return false;
    const list = o.object.get("schemes") orelse return false;
    if (list != .array) return false;
    for (list.array.items) |x| if (x == .string and std.mem.eql(u8, x.string, scheme)) return true;
    return false;
}

/// Whether a running server provides the text of `uri`.
pub fn canOpen(v: *const VirtualDocs, uri: []const u8) bool {
    return v.serverFor(schemeOf(uri)) != null;
}

/// A name for the tab: the URI's last path segment.
pub fn nameOf(uri: []const u8) []const u8 {
    var u = uri;
    if (std.mem.indexOfAny(u8, u, "?#")) |i| u = u[0..i];
    while (u.len > 0 and u[u.len - 1] == '/') u = u[0 .. u.len - 1];
    const i = std.mem.lastIndexOfAny(u8, u, "/:") orelse return u;
    return if (i + 1 < u.len) u[i + 1 ..] else u;
}

/// The document for `uri`, fetching its text the first time (read-only;
/// pair with `release`).
pub fn open(v: *VirtualDocs, uri: []const u8) !DocHandle {
    for (v.entries.items) |*e| if (std.mem.eql(u8, e.uri, uri)) {
        try v.mgr.docs.retain(e.h);
        e.refs += 1;
        return e.h;
    };
    const server = v.serverFor(schemeOf(uri));
    var placeholder: std.ArrayList(u8) = .empty;
    defer placeholder.deinit(v.gpa);
    if (server == null) try placeholder.print(v.gpa, "Content unavailable for {s}:\n", .{schemeOf(uri)});
    const h = try v.mgr.docs.openVirtual(uri, nameOf(uri), placeholder.items);
    errdefer v.mgr.docs.release(h);
    const copy = try v.gpa.dupe(u8, uri);
    errdefer v.gpa.free(copy);
    try v.entries.append(v.gpa, .{
        .id = v.next_id,
        .uri = copy,
        .h = h,
        .refs = 1,
        .server = if (server) |s| s.id else null,
        .state = if (server == null) .unavailable else .loading,
    });
    v.next_id += 1;
    v.generation += 1;
    if (server) |s| v.fetch(&v.entries.items[v.entries.items.len - 1], s.client.?);
    return h;
}

/// Drops one `open` of `h`.
pub fn release(v: *VirtualDocs, h: DocHandle) void {
    for (v.entries.items, 0..) |*e, i| if (std.meta.eql(e.h, h)) {
        v.mgr.docs.release(h);
        e.refs -= 1;
        if (e.refs == 0) {
            v.gpa.free(e.uri);
            _ = v.entries.orderedRemove(i);
        }
        return;
    };
}

/// The entry for `h`, if it is a virtual document opened here.
pub fn entryOf(v: *const VirtualDocs, h: DocHandle) ?*const Entry {
    for (v.entries.items) |*e| if (std.meta.eql(e.h, h)) return e;
    return null;
}

fn fetch(v: *VirtualDocs, e: *Entry, c: *Client) void {
    e.round += 1;
    v.req.send(c, .{ .uri = e.uri }, .{}, .{ .id = e.id, .round = e.round }) catch |err| {
        log.warn("textDocumentContent {s}: {t}", .{ e.uri, err });
        e.state = .failed;
        v.generation += 1;
    };
}

fn onRefresh(ctx: *anyopaque, server: *Manager.Server, f: Manager.RefreshFeature) void {
    if (f != .text_document_content) return;
    const v: *VirtualDocs = @ptrCast(@alignCast(ctx));
    const c = server.client orelse return;
    for (v.entries.items) |*e| if (e.server == server.id) v.fetch(e, c);
}

/// Takes answers; true when a document changed.
pub fn tick(v: *VirtualDocs) bool {
    const g = v.generation;
    for (v.req.take()) |a| {
        const e = for (v.entries.items) |*x| {
            if (x.id == a.tag.id) break x;
        } else continue;
        if (a.tag.round != e.round) continue;
        switch (a.result) {
            .ok => |o| v.setText(e, o.value.text) catch |err| {
                log.warn("virtual document {s}: {t}", .{ e.uri, err });
                e.state = .failed;
            },
            else => |r| {
                log.info("textDocumentContent {s}: {t}", .{ e.uri, r });
                e.state = .failed;
            },
        }
        v.generation += 1;
    }
    return v.generation != g;
}

/// Replaces the text, touching only the lines that changed. The document
/// stays clean (nothing to save).
fn setText(v: *VirtualDocs, e: *Entry, text: []const u8) !void {
    const doc = v.mgr.docs.get(e.h) orelse return;
    var cs = try zg_editor.model.buffer.external.reloadChanges(v.gpa, doc.tree, text) orelse {
        e.state = .ready;
        return;
    };
    defer cs.deinit();
    try doc.applyChangeSet(&cs, .reload);
    doc.saved_version = doc.version;
    e.state = .ready;
}
