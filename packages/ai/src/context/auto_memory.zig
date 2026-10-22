//! Auto memory (E10.F07.S01.T03): durable, per-repository learnings the
//! agent writes as plain Markdown under `<data_dir>/memory/<repo_key>/`.
//! `MEMORY.md` is the index (one line per memory) and is loaded at session
//! start up to 200 lines or 25 KiB, whichever comes first; topic files are
//! read on demand. When disabled, nothing under the directory is read or
//! written.

const std = @import("std");
const key = @import("../session/key.zig");
const fm = @import("frontmatter.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The `type:` of a topic file.
pub const MemoryKind = enum { user, feedback, project, reference };

/// Index load limits.
pub const max_index_lines: u32 = 200;
pub const max_index_bytes: u32 = 25 * 1024;

/// The prompt addendum included when auto memory is enabled.
pub const prompt = @embedFile("auto_memory_prompt.md");

/// The loaded index.
pub const IndexText = struct {
    text: []const u8,
    truncated: bool,
    lines: u32,
    bytes: u32,
};

/// How the harness was started (decides the default).
pub const RunMode = enum { gui, print, background };

/// `ai.autoMemory.*` settings.
pub const Config = struct {
    /// `ai.autoMemory.enabled`; null takes the run-mode default.
    enabled: ?bool = null,
    /// `--auto-memory` on a `-p` or `--bare` run.
    force_flag: bool = false,
    /// `ai.autoMemory.directory` (absolute).
    directory: ?[]const u8 = null,
    /// The directory setting came from the project's settings, which are
    /// honoured only in trusted workspaces (E16.F07).
    directory_from_project: bool = false,
    workspace_trusted: bool = true,
};

/// Feedback after the agent writes `MEMORY.md`.
pub const WriteCheck = union(enum) {
    /// Within 10% of a limit: a system reminder for the next request.
    reminder: []const u8,
    /// Over a limit: the tool result becomes `is_error` with this text.
    over_limit: []const u8,
};

pub const AutoMemory = struct {
    /// Absolute directory (owned by the arena passed to `init`).
    dir: []const u8,
    on: bool,

    /// Resolves the directory and the enabled state. `repo_root` is the
    /// repository root from E09 (or the workspace root outside a repo).
    pub fn init(arena: Allocator, data_dir: []const u8, repo_root: []const u8, cfg: Config, mode: RunMode) Allocator.Error!AutoMemory {
        const custom = if (cfg.directory) |d| (if (cfg.directory_from_project and !cfg.workspace_trusted) null else d) else null;
        return .{
            .dir = if (custom) |d| try arena.dupe(u8, d) else try dirFor(arena, data_dir, repo_root),
            .on = cfg.enabled orelse defaultEnabled(mode, cfg.force_flag),
        };
    }

    /// `<data_dir>/memory/<repo_key>`.
    pub fn dirFor(gpa: Allocator, data_dir: []const u8, repo_root: []const u8) Allocator.Error![]const u8 {
        var buf: [key.max_len]u8 = undefined;
        return std.fs.path.join(gpa, &.{ data_dir, "memory", key.workspaceKey(&buf, repo_root) });
    }

    /// Enabled by default in the GUI; off for `-p` and background agents
    /// unless `--auto-memory` is passed.
    pub fn defaultEnabled(mode: RunMode, flag: bool) bool {
        return mode == .gui or flag;
    }

    pub fn enabled(am: *const AutoMemory) bool {
        return am.on;
    }

    /// The first 200 lines or 25 KiB of `MEMORY.md` (cut at a line end).
    /// Empty when disabled or missing; never touches the disk when disabled.
    pub fn loadIndex(am: *const AutoMemory, io: Io, arena: Allocator) !IndexText {
        if (!am.on) return .{ .text = "", .truncated = false, .lines = 0, .bytes = 0 };
        const path = try std.fs.path.join(arena, &.{ am.dir, "MEMORY.md" });
        const f = Io.Dir.cwd().openFile(io, path, .{}) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return .{ .text = "", .truncated = false, .lines = 0, .bytes = 0 },
            else => return e,
        };
        defer f.close(io);
        const len = try f.length(io);
        const buf = try arena.alloc(u8, @intCast(@min(len, max_index_bytes + 1)));
        const n = try f.readPositionalAll(io, buf, 0);
        return cut(buf[0..n], len > n or n > max_index_bytes);
    }

    /// Measures `MEMORY.md` after the agent wrote `path`; null when `path`
    /// is not the index or it is comfortably within the limits.
    pub fn afterWrite(am: *const AutoMemory, io: Io, arena: Allocator, path: []const u8) !?WriteCheck {
        if (!am.on or !am.isIndex(path)) return null;
        const data = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(16 << 20)) catch return null;
        const lines = countLines(data);
        if (lines > max_index_lines or data.len > max_index_bytes)
            return .{ .over_limit = try std.fmt.allocPrint(arena, "MEMORY.md is {d} lines and {d} bytes, over the {d}-line / {d} KiB load limit; content past the limit is dropped next session. Rewrite the index with one short line per entry and move detail into topic files.", .{ lines, data.len, max_index_lines, max_index_bytes / 1024 }) };
        if (lines * 10 >= max_index_lines * 9 or data.len * 10 >= @as(usize, max_index_bytes) * 9)
            return .{ .reminder = try std.fmt.allocPrint(arena, "MEMORY.md is close to its load limit ({d}/{d} lines, {d}/{d} bytes). Keep one line per entry and move detail into topic files.", .{ lines, max_index_lines, data.len, max_index_bytes }) };
        return null;
    }

    /// True for `MEMORY.md` in the memory directory.
    pub fn isIndex(am: *const AutoMemory, path: []const u8) bool {
        const d = std.fs.path.dirname(path) orelse return false;
        return samePath(d, am.dir) and std.mem.eql(u8, std.fs.path.basename(path), "MEMORY.md");
    }

    /// The one built-in direct-write exception: `write_file`/`edit_file`
    /// on a path inside the memory directory skips the E12 changeset (the
    /// call is still shown and recorded). `path` must be absolute; `..` is
    /// resolved first, so an escape is never inside.
    pub fn allowsDirectWrite(am: *const AutoMemory, gpa: Allocator, tool: []const u8, path: []const u8) Allocator.Error!bool {
        if (!am.on) return false;
        if (!std.mem.eql(u8, tool, "write_file") and !std.mem.eql(u8, tool, "edit_file")) return false;
        if (!std.fs.path.isAbsolute(path)) return false;
        const resolved = try std.fs.path.resolve(gpa, &.{path});
        defer gpa.free(resolved);
        if (resolved.len <= am.dir.len) return false;
        const sep = resolved[am.dir.len];
        return samePath(resolved[0..am.dir.len], am.dir) and (sep == '/' or sep == '\\');
    }

    /// Reads a topic file's `type:` (null when missing or invalid).
    pub fn kindOf(arena: Allocator, text: []const u8) ?MemoryKind {
        const doc = fm.parse(arena, text, null) catch return null;
        const t = (doc.meta orelse return null).get("type") orelse return null;
        if (t != .scalar) return null;
        return std.meta.stringToEnum(MemoryKind, t.scalar);
    }
};

/// Applies the line and byte limits to index text.
fn cut(data: []const u8, over_bytes: bool) IndexText {
    var end: usize = 0;
    var lines: u32 = 0;
    var truncated = false;
    while (end < data.len) {
        const nl = std.mem.indexOfScalarPos(u8, data, end, '\n');
        const next = if (nl) |i| i + 1 else data.len;
        if (lines == max_index_lines or next > max_index_bytes) {
            truncated = true;
            break;
        }
        end = next;
        lines += 1;
    }
    // A file longer than what was read always ends past a limit.
    truncated = truncated or (over_bytes and end < data.len);
    return .{ .text = data[0..end], .truncated = truncated, .lines = lines, .bytes = @intCast(end) };
}

fn countLines(data: []const u8) usize {
    return std.mem.count(u8, data, "\n") + @intFromBool(data.len > 0 and data[data.len - 1] != '\n');
}

fn samePath(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const nx = if (x == '\\') '/' else x;
        const ny = if (y == '\\') '/' else y;
        if (@import("builtin").os.tag == .windows) {
            if (std.ascii.toLower(nx) != std.ascii.toLower(ny)) return false;
        } else if (nx != ny) return false;
    }
    return true;
}
