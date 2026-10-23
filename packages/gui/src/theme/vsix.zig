//! Themes from a `.vsix` (E04.F08.S02.T01). A `.vsix` is a zip: its
//! `extension/package.json` lists `contributes.themes[]` (`label`,
//! `uiTheme`, `path`), and the theme JSON and its includes are extracted
//! to memory (stored or deflated entries) and imported like files.

const std = @import("std");
const vscode = @import("vscode.zig");
const jsonc = @import("jsonc.zig");

const Allocator = std.mem.Allocator;
const flate = std.compress.flate;

/// One theme an extension contributes.
pub const VsixTheme = struct {
    label: []const u8,
    ui_theme: []const u8,
    /// Inside the zip (`extension/...`).
    path: []const u8,
};

/// `listVsixThemes`' result.
pub const VsixThemes = struct {
    arena: std.heap.ArenaAllocator,
    items: []const VsixTheme,

    pub fn deinit(l: *VsixThemes) void {
        l.arena.deinit();
        l.* = undefined;
    }
};

pub const VsixError = error{ InvalidVsix, ThemeNotFound } || Allocator.Error;

/// The largest `.vsix` read.
pub const max_vsix_bytes = 64 << 20;
/// The largest entry extracted.
pub const max_entry_bytes = 16 << 20;

/// A zip archive in memory: its central directory.
pub const Zip = struct {
    bytes: []const u8,
    entries: []const Entry,

    pub const Entry = struct {
        name: []const u8,
        method: u16,
        compressed: u32,
        size: u32,
        local_offset: u32,
    };

    /// Reads the central directory (no zip64, no encryption).
    pub fn parse(arena: Allocator, bytes: []const u8) VsixError!Zip {
        const eocd = std.mem.lastIndexOf(u8, bytes, "PK\x05\x06") orelse return error.InvalidVsix;
        if (eocd + 22 > bytes.len) return error.InvalidVsix;
        const count = std.mem.readInt(u16, bytes[eocd + 10 ..][0..2], .little);
        const cd_off = std.mem.readInt(u32, bytes[eocd + 16 ..][0..4], .little);
        const entries = try arena.alloc(Entry, count);
        var p: usize = cd_off;
        for (entries) |*e| {
            if (p + 46 > bytes.len or !std.mem.eql(u8, bytes[p..][0..4], "PK\x01\x02")) return error.InvalidVsix;
            const h = bytes[p..];
            const name_len = std.mem.readInt(u16, h[28..30], .little);
            const extra_len = std.mem.readInt(u16, h[30..32], .little);
            const comment_len = std.mem.readInt(u16, h[32..34], .little);
            if (p + 46 + name_len > bytes.len) return error.InvalidVsix;
            e.* = .{
                .name = h[46..][0..name_len],
                .method = std.mem.readInt(u16, h[10..12], .little),
                .compressed = std.mem.readInt(u32, h[20..24], .little),
                .size = std.mem.readInt(u32, h[24..28], .little),
                .local_offset = std.mem.readInt(u32, h[42..46], .little),
            };
            p += 46 + @as(usize, name_len) + extra_len + comment_len;
        }
        return .{ .bytes = bytes, .entries = entries };
    }

    /// The entry named `name`.
    pub fn find(z: Zip, name: []const u8) ?Entry {
        for (z.entries) |e| if (std.mem.eql(u8, e.name, name)) return e;
        return null;
    }

    /// An entry's bytes (allocated in `arena`).
    pub fn extract(z: Zip, arena: Allocator, e: Entry) VsixError![]u8 {
        if (e.size > max_entry_bytes) return error.InvalidVsix;
        const lo = e.local_offset;
        if (@as(usize, lo) + 30 > z.bytes.len or !std.mem.eql(u8, z.bytes[lo..][0..4], "PK\x03\x04")) return error.InvalidVsix;
        const name_len = std.mem.readInt(u16, z.bytes[lo + 26 ..][0..2], .little);
        const extra_len = std.mem.readInt(u16, z.bytes[lo + 28 ..][0..2], .little);
        const start = @as(usize, lo) + 30 + name_len + extra_len;
        if (start + e.compressed > z.bytes.len) return error.InvalidVsix;
        const data = z.bytes[start..][0..e.compressed];
        const out = try arena.alloc(u8, e.size);
        switch (e.method) {
            0 => {
                if (data.len != out.len) return error.InvalidVsix;
                @memcpy(out, data);
            },
            8 => {
                const window = try arena.alloc(u8, flate.max_window_len);
                var in: std.Io.Reader = .fixed(data);
                var dec: flate.Decompress = .init(&in, .raw, window);
                dec.reader.readSliceAll(out) catch return error.InvalidVsix;
            },
            else => return error.InvalidVsix,
        }
        return out;
    }
};

/// `rel` against the directory of `from`, with `.` and `..` removed
/// (zip paths use `/`).
pub fn joinPosix(arena: Allocator, from: []const u8, rel: []const u8) Allocator.Error![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    const dir = if (std.mem.lastIndexOfScalar(u8, from, '/')) |i| from[0..i] else "";
    var it = std.mem.splitScalar(u8, dir, '/');
    while (it.next()) |p| if (p.len > 0) try parts.append(arena, p);
    var rt = std.mem.splitAny(u8, rel, "/\\");
    while (rt.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            _ = parts.pop();
            continue;
        }
        try parts.append(arena, p);
    }
    return std.mem.join(arena, "/", parts.items);
}

fn readVsix(arena: Allocator, io: std.Io, path: []const u8) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_vsix_bytes));
}

/// The themes in the extension's `package.json`.
pub fn listInZip(arena: Allocator, z: Zip) VsixError![]const VsixTheme {
    const pkg_entry = z.find("extension/package.json") orelse return error.InvalidVsix;
    const pkg = try jsonc.stripJsonc(arena, try z.extract(arena, pkg_entry));
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, pkg, .{}) catch return error.InvalidVsix;
    if (v != .object) return error.InvalidVsix;
    const contributes = v.object.get("contributes") orelse return &.{};
    if (contributes != .object) return &.{};
    const themes = contributes.object.get("themes") orelse return &.{};
    if (themes != .array) return &.{};
    var out: std.ArrayList(VsixTheme) = .empty;
    for (themes.array.items) |t| {
        if (t != .object) continue;
        const label = t.object.get("label") orelse continue;
        const p = t.object.get("path") orelse continue;
        if (label != .string or p != .string) continue;
        const ui = if (t.object.get("uiTheme")) |u| (if (u == .string) u.string else "vs-dark") else "vs-dark";
        try out.append(arena, .{ .label = label.string, .ui_theme = ui, .path = try joinPosix(arena, "extension/package.json", p.string) });
    }
    return out.items;
}

/// The themes a `.vsix` contributes.
pub fn listVsixThemes(gpa: Allocator, io: std.Io, vsix_path: []const u8) !VsixThemes {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    const z = try Zip.parse(a, try readVsix(a, io, vsix_path));
    const items = try listInZip(a, z);
    return .{ .arena = arena, .items = items };
}

/// Imports the theme labelled `theme_label` from a `.vsix`.
pub fn importVsix(gpa: Allocator, io: std.Io, vsix_path: []const u8, theme_label: []const u8) !vscode.ImportResult {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    return importZipBytes(gpa, try readVsix(a, io, vsix_path), theme_label);
}

/// `importVsix` on the archive's bytes.
pub fn importZipBytes(gpa: Allocator, bytes: []const u8, theme_label: []const u8) !vscode.ImportResult {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const z = try Zip.parse(a, bytes);
    const themes = try listInZip(a, z);
    const t = for (themes) |t| {
        if (std.mem.eql(u8, t.label, theme_label)) break t;
    } else return error.ThemeNotFound;
    const Files = struct {
        z: Zip,
        fn load(ctx: *anyopaque, ar: Allocator, p: []const u8) anyerror![]const u8 {
            const f: *@This() = @ptrCast(@alignCast(ctx));
            const e = f.z.find(p) orelse return error.FileNotFound;
            return f.z.extract(ar, e);
        }
        fn resolve(_: *anyopaque, ar: Allocator, from: []const u8, rel: []const u8) Allocator.Error![]const u8 {
            return joinPosix(ar, from, rel);
        }
    };
    var files: Files = .{ .z = z };
    return vscode.importWith(gpa, .{ .ctx = &files, .load = Files.load, .resolve = Files.resolve }, t.path, t.ui_theme);
}
