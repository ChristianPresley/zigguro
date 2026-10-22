//! DocumentRegistry: the open documents of the process, keyed by
//! normalized path (files) or by name (untitled and agent documents).
//!
//! Handles are refcounted and carry a generation, so a handle kept past
//! its document's close fails safely instead of reaching a reused slot.
//! The registry does no I/O: E08 reads files (resolving symlinks with
//! `std.Io.Dir.realPathFileAlloc` first, so two links to one file share a
//! document) and passes the bytes in.

const std = @import("std");
const builtin = @import("builtin");
const zg_text = @import("zg_text");
const document = @import("../document.zig");

const Allocator = std.mem.Allocator;
const Document = document.Document;
const DocId = document.DocId;

/// A reference to an open document. `gen` changes when the slot is reused.
pub const DocHandle = struct { id: DocId, gen: u32 };

/// How paths compare and print.
pub const PathStyle = enum {
    /// Byte-exact, `/` separated.
    posix,
    /// Case-insensitive, `\` separated, drive letters and UNC prefixes.
    windows,

    pub const native: PathStyle = if (builtin.os.tag == .windows) .windows else .posix;
};

/// What a document is backed by.
pub const DocKind = union(enum) {
    file,
    /// "Untitled-N".
    untitled: u32,
    /// A scratch buffer of an agent session.
    agent: u64,
};

/// Registry-wide events. Strings are valid during the callback only.
pub const RegistryEvent = union(enum) {
    opened: DocHandle,
    /// Sent before the document is freed, so listeners can still read it.
    closed: DocHandle,
    renamed: struct { handle: DocHandle, old_uri: []const u8, new_uri: []const u8 },
};

/// A registry event callback (UI thread).
pub const RegistryListener = struct {
    ctx: *anyopaque,
    onEvent: *const fn (ctx: *anyopaque, reg: *DocumentRegistry, ev: *const RegistryEvent) void,
};

pub const Error = Allocator.Error || error{ StaleHandle, NotAbsolute, AlreadyOpen };

const Slot = struct {
    doc: ?*Document = null,
    gen: u32 = 0,
    refs: u32 = 0,
    kind: DocKind = .file,
    /// Display path (files) or name (untitled and agent documents).
    name: []u8 = &.{},
    /// Lookup key: the folded, normalized path or a namespaced name.
    key: []u8 = &.{},
    uri: []u8 = &.{},
    read_only: bool = false,
};

/// The open documents. Single-threaded (UI thread); other threads read
/// documents through snapshots.
pub const DocumentRegistry = struct {
    gpa: Allocator,
    style: PathStyle,
    slots: std.ArrayList(Slot) = .empty,
    free: std.ArrayList(u32) = .empty,
    by_key: std.StringHashMapUnmanaged(u32) = .empty,
    listeners: std.ArrayList(struct { id: u32, l: RegistryListener }) = .empty,
    next_listener: u32 = 0,
    next_untitled: u32 = 1,

    pub fn init(gpa: Allocator, style: PathStyle) DocumentRegistry {
        return .{ .gpa = gpa, .style = style };
    }

    /// Frees every document regardless of references (no events).
    pub fn deinit(r: *DocumentRegistry) void {
        for (r.slots.items) |*s| if (s.doc) |d| {
            d.deinit();
            r.freeStrings(s);
        };
        r.slots.deinit(r.gpa);
        r.free.deinit(r.gpa);
        r.by_key.deinit(r.gpa);
        r.listeners.deinit(r.gpa);
    }

    /// Opens the file at absolute `path` with contents `bytes`, or adds a
    /// reference to the document already open for it (then `bytes` is
    /// ignored). Release the handle with `release`.
    pub fn openFile(r: *DocumentRegistry, path: []const u8, bytes: []const u8) Error!DocHandle {
        if (!isAbsolute(path, r.style)) return error.NotAbsolute;
        const disp = try normalizePath(r.gpa, path, r.style);
        errdefer r.gpa.free(disp);
        const key = try pathKey(r.gpa, disp, r.style);
        errdefer r.gpa.free(key);
        if (r.by_key.get(key)) |i| {
            r.gpa.free(key);
            r.gpa.free(disp);
            r.slots.items[i].refs += 1;
            return r.handleOf(i);
        }
        const uri_s = try fileUri(r.gpa, disp);
        errdefer r.gpa.free(uri_s);
        return r.add(.file, disp, key, uri_s, bytes);
    }

    /// The document open for `path`, if any (no reference added).
    pub fn findFile(r: *DocumentRegistry, path: []const u8) Allocator.Error!?DocHandle {
        const disp = try normalizePath(r.gpa, path, r.style);
        defer r.gpa.free(disp);
        const key = try pathKey(r.gpa, disp, r.style);
        defer r.gpa.free(key);
        const i = r.by_key.get(key) orelse return null;
        return r.handleOf(i);
    }

    /// A new untitled document ("Untitled-N", `untitled:Untitled-N`).
    pub fn openUntitled(r: *DocumentRegistry, bytes: []const u8) Error!DocHandle {
        const n = r.next_untitled;
        r.next_untitled += 1;
        const disp = try std.fmt.allocPrint(r.gpa, "Untitled-{d}", .{n});
        errdefer r.gpa.free(disp);
        const key = try std.fmt.allocPrint(r.gpa, "untitled:{s}", .{disp});
        errdefer r.gpa.free(key);
        const uri_s = try r.gpa.dupe(u8, key);
        errdefer r.gpa.free(uri_s);
        return r.add(.{ .untitled = n }, disp, key, uri_s, bytes);
    }

    /// A scratch document of agent `session` named `name_in`
    /// (`zigguro-agent://<session>/<name>`), or another reference to it.
    pub fn openAgent(r: *DocumentRegistry, session: u64, name_in: []const u8, bytes: []const u8) Error!DocHandle {
        const key = try std.fmt.allocPrint(r.gpa, "agent:{d}/{s}", .{ session, name_in });
        errdefer r.gpa.free(key);
        if (r.by_key.get(key)) |i| {
            r.gpa.free(key);
            r.slots.items[i].refs += 1;
            return r.handleOf(i);
        }
        const disp = try r.gpa.dupe(u8, name_in);
        errdefer r.gpa.free(disp);
        var uri_s: std.ArrayList(u8) = .empty;
        errdefer uri_s.deinit(r.gpa);
        try uri_s.print(r.gpa, "zigguro-agent://{d}/", .{session});
        try percentEncode(&uri_s, r.gpa, name_in, true);
        return r.add(.{ .agent = session }, disp, key, try uri_s.toOwnedSlice(r.gpa), bytes);
    }

    fn add(r: *DocumentRegistry, k: DocKind, disp: []u8, key: []u8, uri_s: []u8, bytes: []const u8) Error!DocHandle {
        try r.free.ensureTotalCapacity(r.gpa, r.slots.items.len + 1);
        try r.by_key.ensureUnusedCapacity(r.gpa, 1);
        const i: u32 = if (r.free.pop()) |f| f else blk: {
            try r.slots.append(r.gpa, .{});
            break :blk @intCast(r.slots.items.len - 1);
        };
        errdefer r.free.appendAssumeCapacity(i);
        const doc = try Document.initBytes(r.gpa, @enumFromInt(i), bytes);
        const s = &r.slots.items[i];
        s.* = .{ .doc = doc, .gen = s.gen, .refs = 1, .kind = k, .name = disp, .key = key, .uri = uri_s };
        r.by_key.putAssumeCapacity(key, i);
        const h = r.handleOf(i);
        r.emit(&.{ .opened = h });
        return h;
    }

    fn handleOf(r: *const DocumentRegistry, i: u32) DocHandle {
        return .{ .id = @enumFromInt(i), .gen = r.slots.items[i].gen };
    }

    fn slot(r: *const DocumentRegistry, h: DocHandle) ?*Slot {
        const i = @intFromEnum(h.id);
        if (i >= r.slots.items.len) return null;
        const s = &r.slots.items[i];
        if (s.doc == null or s.gen != h.gen) return null;
        return s;
    }

    /// The document, or null for a stale handle.
    pub fn get(r: *const DocumentRegistry, h: DocHandle) ?*Document {
        return (r.slot(h) orelse return null).doc;
    }

    /// Whether `h` names an open document.
    pub fn isValid(r: *const DocumentRegistry, h: DocHandle) bool {
        return r.slot(h) != null;
    }

    /// The document's URI (valid until it is renamed or closed).
    pub fn uri(r: *const DocumentRegistry, h: DocHandle) ?[]const u8 {
        return (r.slot(h) orelse return null).uri;
    }

    /// The display path or name.
    pub fn name(r: *const DocumentRegistry, h: DocHandle) ?[]const u8 {
        return (r.slot(h) orelse return null).name;
    }

    pub fn kind(r: *const DocumentRegistry, h: DocHandle) ?DocKind {
        return (r.slot(h) orelse return null).kind;
    }

    pub fn isReadOnly(r: *const DocumentRegistry, h: DocHandle) bool {
        return (r.slot(h) orelse return true).read_only;
    }

    pub fn setReadOnly(r: *DocumentRegistry, h: DocHandle, ro: bool) error{StaleHandle}!void {
        (r.slot(h) orelse return error.StaleHandle).read_only = ro;
    }

    /// Adds a reference.
    pub fn retain(r: *DocumentRegistry, h: DocHandle) error{StaleHandle}!void {
        (r.slot(h) orelse return error.StaleHandle).refs += 1;
    }

    /// Drops a reference; the last one closes the document (after a
    /// `closed` event). Stale handles are ignored.
    pub fn release(r: *DocumentRegistry, h: DocHandle) void {
        const s = r.slot(h) orelse return;
        s.refs -= 1;
        if (s.refs > 0) return;
        r.emit(&.{ .closed = h });
        // Listeners may not open or close documents, so `s` is still valid.
        _ = r.by_key.remove(s.key);
        s.doc.?.deinit();
        r.freeStrings(s);
        s.* = .{ .gen = s.gen +% 1 };
        r.free.appendAssumeCapacity(@intFromEnum(h.id));
    }

    /// Moves a file document to `new_path` (after E08 renamed the file),
    /// or gives an untitled document its first path (save as).
    pub fn rename(r: *DocumentRegistry, h: DocHandle, new_path: []const u8) Error!void {
        const s = r.slot(h) orelse return error.StaleHandle;
        if (!isAbsolute(new_path, r.style)) return error.NotAbsolute;
        const new_name = try normalizePath(r.gpa, new_path, r.style);
        errdefer r.gpa.free(new_name);
        const new_key = try pathKey(r.gpa, new_name, r.style);
        errdefer r.gpa.free(new_key);
        if (r.by_key.get(new_key)) |other| if (other != @intFromEnum(h.id)) return error.AlreadyOpen;
        const new_uri = try fileUri(r.gpa, new_name);
        errdefer r.gpa.free(new_uri);
        try r.by_key.ensureUnusedCapacity(r.gpa, 1);
        _ = r.by_key.remove(s.key);
        const old_uri = s.uri;
        r.gpa.free(s.name);
        r.gpa.free(s.key);
        s.* = .{ .doc = s.doc, .gen = s.gen, .refs = s.refs, .kind = .file, .name = new_name, .key = new_key, .uri = new_uri, .read_only = s.read_only };
        r.by_key.putAssumeCapacity(new_key, @intFromEnum(h.id));
        r.emit(&.{ .renamed = .{ .handle = h, .old_uri = old_uri, .new_uri = new_uri } });
        r.gpa.free(old_uri);
    }

    /// Number of open documents.
    pub fn count(r: *const DocumentRegistry) usize {
        return r.slots.items.len - r.free.items.len;
    }

    /// Registers a listener for registry events.
    pub fn subscribe(r: *DocumentRegistry, l: RegistryListener) Allocator.Error!u32 {
        const id = r.next_listener;
        r.next_listener += 1;
        try r.listeners.append(r.gpa, .{ .id = id, .l = l });
        return id;
    }

    pub fn unsubscribe(r: *DocumentRegistry, id: u32) void {
        for (r.listeners.items, 0..) |e, i| if (e.id == id) {
            _ = r.listeners.orderedRemove(i);
            return;
        };
    }

    fn emit(r: *DocumentRegistry, ev: *const RegistryEvent) void {
        for (r.listeners.items) |e| e.l.onEvent(e.l.ctx, r, ev);
    }

    fn freeStrings(r: *DocumentRegistry, s: *Slot) void {
        r.gpa.free(s.name);
        r.gpa.free(s.key);
        r.gpa.free(s.uri);
    }
};

// -- paths and URIs ---------------------------------------------------------

/// Whether `path` is absolute in `style`.
pub fn isAbsolute(path: []const u8, style: PathStyle) bool {
    return switch (style) {
        .posix => path.len > 0 and path[0] == '/',
        .windows => windowsRoot(path) != null,
    };
}

/// Length of a Windows root: `C:\` (3), or `\\server\share` up to the
/// separator after the share.
fn windowsRoot(path: []const u8) ?usize {
    const sep = struct {
        fn is(c: u8) bool {
            return c == '\\' or c == '/';
        }
    }.is;
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and sep(path[2])) return 3;
    if (path.len >= 2 and sep(path[0]) and sep(path[1])) {
        // \\server\share
        var i: usize = 2;
        var parts: u2 = 0;
        while (i < path.len) : (i += 1) {
            if (sep(path[i])) {
                parts += 1;
                if (parts == 2) return i;
            }
        }
        return if (parts == 1) path.len else null;
    }
    return null;
}

/// `path` with separators unified (`/` or `\`), repeated separators and
/// `.` dropped and `..` resolved (never above the root). Case is kept.
pub fn normalizePath(gpa: Allocator, path: []const u8, style: PathStyle) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const sep: u8 = if (style == .windows) '\\' else '/';
    var rest = path;
    switch (style) {
        .posix => if (path.len > 0 and path[0] == '/') {
            try out.append(gpa, '/');
            rest = path[1..];
        },
        .windows => if (windowsRoot(path)) |n| {
            for (path[0..n]) |c| try out.append(gpa, if (c == '/') '\\' else c);
            // Upper-case drive letters, as Windows prints them.
            if (n == 3) out.items[0] = std.ascii.toUpper(out.items[0]);
            if (out.items[out.items.len - 1] != '\\') try out.append(gpa, '\\');
            rest = path[n..];
        },
    }
    const root_len = out.items.len;
    var it = std.mem.tokenizeAny(u8, rest, if (style == .windows) "\\/" else "/");
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            // Drop the last component.
            if (out.items.len > root_len) {
                const cut = std.mem.lastIndexOfScalar(u8, out.items[root_len..], sep);
                out.items.len = if (cut) |c| root_len + c else root_len;
            }
            continue;
        }
        if (out.items.len > root_len) try out.append(gpa, sep);
        try out.appendSlice(gpa, part);
    }
    // A root alone keeps its separator; a UNC root drops the extra one.
    if (style == .windows and out.items.len == root_len and root_len > 3 and out.items[root_len - 1] == '\\') out.items.len -= 1;
    return out.toOwnedSlice(gpa);
}

/// The lookup key of a normalized path: itself on POSIX, case-folded
/// (Unicode simple folding, like NTFS's upcase table) on Windows.
pub fn pathKey(gpa: Allocator, normalized: []const u8, style: PathStyle) Allocator.Error![]u8 {
    if (style == .posix) return gpa.dupe(u8, normalized);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try zg_text.unicode.casefold.foldAppend(&out, gpa, normalized, .simple);
    return out.toOwnedSlice(gpa);
}

/// A `file:` URI for an absolute path, as VS Code and LSP clients write
/// them: `file:///home/a%20b`, `file:///c%3A/Users/x` (lower-case drive,
/// colon encoded) and `file://server/share/x` for UNC paths. Everything
/// but unreserved characters and `/` is percent-encoded as UTF-8.
pub fn fileUri(gpa: Allocator, abs_path: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "file://");
    const isSep = struct {
        fn is(c: u8) bool {
            return c == '\\' or c == '/';
        }
    }.is;
    var path = abs_path;
    if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') {
        try out.append(gpa, '/');
        try out.append(gpa, std.ascii.toLower(path[0]));
        try out.appendSlice(gpa, "%3A");
        path = path[2..];
    } else if (path.len >= 2 and isSep(path[0]) and isSep(path[1])) {
        // UNC: the server becomes the authority.
        path = path[2..];
        const end = std.mem.indexOfAny(u8, path, "\\/") orelse path.len;
        try percentEncode(&out, gpa, path[0..end], false);
        path = path[end..];
    }
    var tmp: std.ArrayList(u8) = .empty;
    defer tmp.deinit(gpa);
    try tmp.appendSlice(gpa, path);
    for (tmp.items) |*c| if (c.* == '\\') {
        c.* = '/';
    };
    if (tmp.items.len == 0 or tmp.items[0] != '/') try out.append(gpa, '/');
    try percentEncode(&out, gpa, tmp.items, true);
    return out.toOwnedSlice(gpa);
}

fn percentEncode(out: *std.ArrayList(u8), gpa: Allocator, s: []const u8, keep_slash: bool) Allocator.Error!void {
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        const keep = std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~' or (keep_slash and c == '/');
        if (keep) {
            try out.append(gpa, c);
        } else {
            try out.appendSlice(gpa, &.{ '%', hex[c >> 4], hex[c & 15] });
        }
    }
}
