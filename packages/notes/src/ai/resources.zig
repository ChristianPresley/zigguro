//! MCP resources over a notes vault (E08.F08.S02.T01), mounted by E11 on
//! zg_mcp_notes: every note is `note://<vault>/<path>` (`text/markdown`,
//! path percent-encoded). `list` pages through notes in id order with an
//! opaque cursor naming the last id returned, so pages stay stable while
//! notes come and go. `watch` reports changes to one note; `list_changed`
//! fires once per index commit that added or removed notes (E11 debounces
//! it to 500 ms). Results are allocated in the caller's `gpa` (pass an
//! arena).

const std = @import("std");
const note_index = @import("../index/note_index.zig");
const names = @import("../index/names.zig");
const vault_mod = @import("../vault/vault.zig");
const commands = @import("../daily/commands.zig");
const tools = @import("tools.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const FileId = @import("../vault/note.zig").FileId;

pub const Resource = struct {
    uri: []const u8,
    name: []const u8,
    title: []const u8,
    mime_type: []const u8 = "text/markdown",
};

pub const ResourcePage = struct {
    resources: []const Resource,
    next_cursor: ?[]const u8 = null,
};

pub const ResourceContents = struct {
    uri: []const u8,
    mime_type: []const u8 = "text/markdown",
    text: []const u8,
};

pub const ResourceTemplate = struct {
    uri_template: []const u8,
    name: []const u8,
    description: []const u8,
    mime_type: []const u8 = "text/markdown",
};

pub const Notifier = struct {
    ctx: *anyopaque,
    /// Called on the indexer's thread after a commit.
    on_event: *const fn (ctx: *anyopaque, uri: []const u8) void,
};

pub const WatchId = enum(u32) { _ };

pub const ReadError = error{ NotFound, Denied, OutOfMemory, Io };

const Watch = struct { id: WatchId, note: u64, uri: []u8, notify: Notifier };

pub const ResourceAdapter = struct {
    gpa: Allocator,
    io: Io,
    ix: *note_index.NoteIndex,
    vault: *const vault_mod.Vault,
    files: commands.FilePort,
    policy: ?tools.PathPolicy = null,
    page_size: usize = 100,
    /// Told (with an empty uri) when notes were added or removed.
    list_changed: ?Notifier = null,
    mutex: Io.Mutex = .init,
    watches: std.ArrayList(Watch) = .empty,
    next_watch: u32 = 1,
    known: std.AutoHashMapUnmanaged(u64, void) = .empty,
    list_dirty: bool = false,

    /// Subscribes to `a.ix`; `a` must not move until `deinit`.
    pub fn start(a: *ResourceAdapter) !void {
        const view = try a.ix.reader();
        defer view.release();
        for (view.order) |id| try a.known.put(a.gpa, names.idKey(id), {});
        try a.ix.subscribe(.{ .ctx = a, .on_event = onEvent });
    }

    pub fn deinit(a: *ResourceAdapter) void {
        a.ix.unsubscribe(a);
        for (a.watches.items) |w| a.gpa.free(w.uri);
        a.watches.deinit(a.gpa);
        a.known.deinit(a.gpa);
    }

    pub fn templates(_: *ResourceAdapter) []const ResourceTemplate {
        return &.{.{ .uri_template = "note://{vault}/{path}", .name = "note", .description = "A note of the vault, by vault-relative path." }};
    }

    pub fn list(a: *ResourceAdapter, cursor: ?[]const u8, gpa: Allocator) !ResourcePage {
        const after: ?u64 = if (cursor) |c| decodeCursor(c) orelse return error.BadCursor else null;
        const view = try a.ix.reader();
        defer view.release();
        var out: std.ArrayList(Resource) = .empty;
        var last: u64 = 0;
        var more = false;
        for (view.order) |id| {
            const key = names.idKey(id);
            if (after) |x| if (key <= x) continue;
            const e = view.entry(id) orelse continue;
            if (e.vault != a.vault.id) continue;
            if (a.policy) |p| if (p.check(p.ctx, e.path, false) != null) continue;
            if (out.items.len == a.page_size) {
                more = true;
                break;
            }
            try out.append(gpa, .{ .uri = try uriOf(gpa, a.vault.id, e.path), .name = names.basename(e.path), .title = e.meta.title });
            last = key;
        }
        return .{ .resources = out.items, .next_cursor = if (more) try encodeCursor(gpa, last) else null };
    }

    pub fn read(a: *ResourceAdapter, uri: []const u8, gpa: Allocator) ReadError!ResourceContents {
        const path = try a.pathOfUri(gpa, uri);
        if (a.policy) |p| if (p.check(p.ctx, path, false) != null) return error.Denied;
        {
            const view = a.ix.reader() catch return error.OutOfMemory;
            defer view.release();
            const id = (try view.idOfPath(gpa, a.vault.id, path)) orelse return error.NotFound;
            if (view.note(id) == null) return error.NotFound;
        }
        const text = (a.files.read(a.files.ctx, gpa, path) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Io,
        }) orelse return error.NotFound;
        return .{ .uri = uri, .text = text };
    }

    pub fn watch(a: *ResourceAdapter, uri: []const u8, notify: Notifier) !WatchId {
        const path = try a.pathOfUri(a.gpa, uri);
        defer a.gpa.free(path);
        const view = try a.ix.reader();
        defer view.release();
        const id = (try view.idOfPath(a.gpa, a.vault.id, path)) orelse return error.NotFound;
        a.mutex.lockUncancelable(a.io);
        defer a.mutex.unlock(a.io);
        const w: WatchId = @enumFromInt(a.next_watch);
        a.next_watch += 1;
        const owned = try a.gpa.dupe(u8, uri);
        errdefer a.gpa.free(owned);
        try a.watches.append(a.gpa, .{ .id = w, .note = names.idKey(id), .uri = owned, .notify = notify });
        return w;
    }

    pub fn unwatch(a: *ResourceAdapter, id: WatchId) void {
        a.mutex.lockUncancelable(a.io);
        defer a.mutex.unlock(a.io);
        for (a.watches.items, 0..) |w, i| if (w.id == id) {
            a.gpa.free(w.uri);
            _ = a.watches.orderedRemove(i);
            return;
        };
    }

    fn pathOfUri(a: *ResourceAdapter, gpa: Allocator, uri: []const u8) ReadError![]u8 {
        const prefix = "note://";
        if (!std.mem.startsWith(u8, uri, prefix)) return error.NotFound;
        const rest = uri[prefix.len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return error.NotFound;
        const v = std.fmt.parseInt(u16, rest[0..slash], 10) catch return error.NotFound;
        if (v != @intFromEnum(a.vault.id)) return error.NotFound;
        return percentDecode(gpa, rest[slash + 1 ..]) catch |e| switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.BadEncoding => error.NotFound,
        };
    }

    fn onEvent(ctx: *anyopaque, ev: note_index.Event) void {
        const a: *ResourceAdapter = @ptrCast(@alignCast(ctx));
        a.mutex.lockUncancelable(a.io);
        var flush = false;
        switch (ev) {
            .note_changed, .note_removed => |id| {
                const key = names.idKey(id);
                if (ev == .note_removed) {
                    if (a.known.remove(key)) a.list_dirty = true;
                } else if (!a.known.contains(key)) {
                    a.known.put(a.gpa, key, {}) catch {};
                    a.list_dirty = true;
                }
                for (a.watches.items) |w| if (w.note == key) w.notify.on_event(w.notify.ctx, w.uri);
            },
            // The end of each commit's batch.
            .links_changed => {
                flush = a.list_dirty;
                a.list_dirty = false;
            },
            .tags_changed => {},
        }
        a.mutex.unlock(a.io);
        if (flush) if (a.list_changed) |n| n.on_event(n.ctx, "");
    }
};

/// `note://<vault>/<path>`, keeping `/` and unreserved bytes.
pub fn uriOf(gpa: Allocator, vault: vault_mod.VaultId, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.print(gpa, "note://{d}/", .{@intFromEnum(vault)});
    for (path) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~', '/' => try out.append(gpa, c),
        else => try out.print(gpa, "%{X:0>2}", .{c}),
    };
    return out.toOwnedSlice(gpa);
}

fn percentDecode(gpa: Allocator, s: []const u8) error{ OutOfMemory, BadEncoding }![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '%') {
            try out.append(gpa, s[i]);
            continue;
        }
        if (i + 2 >= s.len) return error.BadEncoding;
        const b = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return error.BadEncoding;
        try out.append(gpa, b);
        i += 2;
    }
    return out.toOwnedSlice(gpa);
}

const b64 = std.base64.url_safe_no_pad;

fn encodeCursor(gpa: Allocator, last: u64) ![]u8 {
    var raw: [10]u8 = undefined;
    raw[0] = 'n';
    raw[1] = 1;
    std.mem.writeInt(u64, raw[2..10], last, .little);
    const out = try gpa.alloc(u8, b64.Encoder.calcSize(raw.len));
    _ = b64.Encoder.encode(out, &raw);
    return out;
}

fn decodeCursor(c: []const u8) ?u64 {
    var raw: [10]u8 = undefined;
    const n = b64.Decoder.calcSizeForSlice(c) catch return null;
    if (n != raw.len) return null;
    b64.Decoder.decode(&raw, c) catch return null;
    if (raw[0] != 'n' or raw[1] != 1) return null;
    return std.mem.readInt(u64, raw[2..10], .little);
}
