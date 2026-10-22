//! What font discovery produces on every OS: font directories, the
//! generic-family preference lists, and the recursive listing of font
//! files. Discovery touches the file system, so callers run it on a
//! worker (`io.concurrent`), never on the UI thread.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// A generic family (or any family) and the families to try for it, as
/// fontconfig's `<alias>`.
pub const Alias = struct {
    family: []const u8,
    prefer: []const []const u8 = &.{},
    accept: []const []const u8 = &.{},
    default: []const []const u8 = &.{},
};

pub const Discovery = struct {
    /// Absolute, deduplicated, existing directories, in priority order.
    dirs: []const []const u8,
    /// Aliases in document order.
    aliases: []const Alias,
    /// Owns every string above.
    arena: std.heap.ArenaAllocator.State = .{},

    pub fn deinit(d: *Discovery, gpa: Allocator) void {
        d.arena.promote(gpa).deinit();
        d.* = undefined;
    }

    /// The families to try for `family`, best first, deduplicated (case
    /// insensitive), applying the aliases in order as fontconfig's edit
    /// modes do: each `prefer` is inserted just before the family (so
    /// earlier rules come first), each `accept` just after it (so later
    /// rules come first), and each `default` at the end. Only aliases
    /// of `family` itself are applied; the family is not in the result.
    pub fn preferences(d: *const Discovery, arena: Allocator, family: []const u8) Allocator.Error![]const []const u8 {
        var prefer: std.ArrayList([]const u8) = .empty;
        var accept: std.ArrayList([]const u8) = .empty;
        var default: std.ArrayList([]const u8) = .empty;
        for (d.aliases) |a| {
            if (!std.ascii.eqlIgnoreCase(a.family, family)) continue;
            try prefer.appendSlice(arena, a.prefer);
            try accept.insertSlice(arena, 0, a.accept);
            try default.appendSlice(arena, a.default);
        }
        var out: std.ArrayList([]const u8) = .empty;
        for ([_][]const []const u8{ prefer.items, accept.items, default.items }) |list| for (list) |f| {
            if (std.ascii.eqlIgnoreCase(f, family)) continue;
            for (out.items) |o| {
                if (std.ascii.eqlIgnoreCase(o, f)) break;
            } else try out.append(arena, f);
        };
        return out.items;
    }
};

pub const FileEntry = struct {
    /// Owned by the caller's allocator (see `freeFileEntries`).
    path: []const u8,
    size: u64,
    mtime: Io.Timestamp,
};

/// Frees the paths of `listFontFiles` and the list.
pub fn freeFileEntries(gpa: Allocator, list: *std.ArrayList(FileEntry)) void {
    for (list.items) |e| gpa.free(e.path);
    list.deinit(gpa);
}

/// Directory nesting `listFontFiles` follows.
pub const max_depth = 8;

/// True for `.ttf .otf .ttc .otc` (any case).
pub fn isFontFile(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    for ([_][]const u8{ ".ttf", ".otf", ".ttc", ".otc" }) |e| if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    return false;
}

/// Appends every font file under `dirs` (recursively, symlinks
/// followed) to `out`. Directories reached twice (through symlinks or
/// nested entries of `dirs`) are listed once; loops end there too.
/// Unreadable directories and entries are skipped.
pub fn listFontFiles(gpa: Allocator, io: Io, dirs: []const []const u8, out: *std.ArrayList(FileEntry)) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        seen.deinit(gpa);
    }
    for (dirs) |d| try walkDir(gpa, io, d, 0, &seen, out);
}

fn walkDir(gpa: Allocator, io: Io, path: []const u8, depth: usize, seen: *std.StringHashMapUnmanaged(void), out: *std.ArrayList(FileEntry)) !void {
    if (depth > max_depth) return;
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const n = dir.realPathFile(io, ".", &buf) catch null;
    const real = try gpa.dupe(u8, if (n) |len| buf[0..len] else path);
    const gop = seen.getOrPut(gpa, real) catch |e| {
        gpa.free(real);
        return e;
    };
    if (gop.found_existing) {
        gpa.free(real);
        return;
    }
    var subdirs: std.ArrayList([]const u8) = .empty;
    defer {
        for (subdirs.items) |s| gpa.free(s);
        subdirs.deinit(gpa);
    }
    const first_file = out.items.len;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        var kind = e.kind;
        if (kind == .sym_link or kind == .unknown) {
            const st = dir.statFile(io, e.name, .{}) catch continue;
            kind = st.kind;
        }
        switch (kind) {
            .directory => try subdirs.append(gpa, try std.fs.path.join(gpa, &.{ path, e.name })),
            .file => if (isFontFile(e.name)) {
                const st = dir.statFile(io, e.name, .{}) catch continue;
                const p = try std.fs.path.join(gpa, &.{ path, e.name });
                errdefer gpa.free(p);
                try out.append(gpa, .{ .path = p, .size = st.size, .mtime = st.mtime });
            },
            else => {},
        }
    }
    // Sorted so the listing is deterministic.
    std.mem.sort(FileEntry, out.items[first_file..], {}, byPath);
    std.mem.sort([]const u8, subdirs.items, {}, lessThan);
    for (subdirs.items) |s| try walkDir(gpa, io, s, depth + 1, seen, out);
}

fn byPath(_: void, a: FileEntry, b: FileEntry) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
