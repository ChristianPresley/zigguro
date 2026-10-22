//! `DiskFiles`: the `Files` of `zg agent`. Reads and writes files under a
//! workspace root directly; there is no editor, so every proposal is
//! applied at once. A file's version is the hash of its bytes, so a write
//! based on an older read is rejected as stale.

const std = @import("std");
const files = @import("files.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;

pub const DiskFiles = struct {
    /// Absolute and normalized.
    root: []const u8,
    max_bytes: usize = 256 << 20,

    pub fn asFiles(d: *DiskFiles) files.Files {
        return .{ .ctx = d, .vtable = &.{ .resolve = resolve, .kind = kind, .read = read, .propose = propose } };
    }

    pub fn version(bytes: []const u8) u64 {
        return std.hash.Wyhash.hash(0, bytes);
    }

    fn resolve(ctx: *anyopaque, io: Io, arena: Allocator, path: []const u8) Allocator.Error!files.Resolved {
        const d: *DiskFiles = @ptrCast(@alignCast(ctx));
        var abs = try std.fs.path.resolve(arena, &.{ d.root, path });
        // Follow symlinks for files that exist.
        if (Dir.cwd().realPathFileAlloc(io, abs, arena)) |real| abs = real else |_| {}
        const inside = std.mem.eql(u8, abs, d.root) or
            (std.mem.startsWith(u8, abs, d.root) and abs.len > d.root.len and std.fs.path.isSep(abs[d.root.len]));
        const rel = if (!inside) abs else if (abs.len == d.root.len) "." else abs[d.root.len + 1 ..];
        return .{ .abs = abs, .rel = rel, .inside_workspace = inside };
    }

    fn kind(_: *anyopaque, io: Io, abs: []const u8) files.Kind {
        const st = Dir.cwd().statFile(io, abs, .{}) catch return .missing;
        return if (st.kind == .directory) .directory else .file;
    }

    fn read(ctx: *anyopaque, io: Io, arena: Allocator, abs: []const u8, max_bytes: usize) anyerror!files.Read {
        const d: *DiskFiles = @ptrCast(@alignCast(ctx));
        const st = try Dir.cwd().statFile(io, abs, .{});
        const bytes = Dir.cwd().readFileAlloc(io, abs, arena, .limited(@min(max_bytes, d.max_bytes) +| 1)) catch |e| switch (e) {
            error.StreamTooLong => return .{ .version = 0, .bytes = &.{}, .size = st.size },
            else => return e,
        };
        return .{ .version = version(bytes), .bytes = bytes, .size = st.size };
    }

    fn propose(ctx: *anyopaque, io: Io, arena: Allocator, abs: []const u8, p: files.Proposal, _: files.Origin) anyerror!files.Outcome {
        const d: *DiskFiles = @ptrCast(@alignCast(ctx));
        const text: []const u8 = switch (p) {
            .create => |cr| blk: {
                if (kind(ctx, io, abs) != .missing) return .{ .rejected = .already_exists };
                if (std.fs.path.dirname(abs)) |parent| Dir.cwd().createDirPath(io, parent) catch |e|
                    return .{ .rejected = .{ .io = @errorName(e) } };
                break :blk cr.text;
            },
            .str_replace => |sr| blk: {
                const cur = try Dir.cwd().readFileAlloc(io, abs, arena, .limited(d.max_bytes));
                break :blk switch (try files.strReplace(arena, cur, sr.old, sr.new, sr.occurrence)) {
                    .ok => |ok| ok.text,
                    .not_found => return .{ .rejected = .not_found },
                    .not_unique => |n| return .{ .rejected = .{ .not_unique = n } },
                };
            },
            .whole_file => |wf| blk: {
                const cur = try Dir.cwd().readFileAlloc(io, abs, arena, .limited(d.max_bytes));
                if (wf.base_version) |b| if (b != version(cur)) return .{ .rejected = .stale };
                break :blk wf.text;
            },
        };
        Dir.cwd().writeFile(io, .{ .sub_path = abs, .data = text }) catch |e| return switch (e) {
            error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => .{ .rejected = .read_only },
            else => .{ .rejected = .{ .io = @errorName(e) } },
        };
        return .{ .applied = .{ .version = version(text) } };
    }
};
