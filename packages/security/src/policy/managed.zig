//! Organisation-managed policy (E16.F02.S03.T01). A ZON file at a fixed,
//! administrator-owned path; never read from the environment or the
//! workspace. Its deny/ask rules are step 1 of the evaluation order and no
//! layer or mode can weaken them.
//!
//! Location trust: on Linux the file and every parent directory must be
//! owned by root and not group- or other-writable; otherwise the file is
//! reported as `untrusted_location` and the caller treats it as a user
//! layer. Windows owner/DACL checks join with the Win32 declarations of
//! E16.F04; until then Windows files are `untrusted_location`.
//!
//! Parsing fails closed: unknown fields are a parse error.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// The managed policy document.
pub const ManagedPolicy = struct {
    deny: []const []const u8 = &.{},
    ask: []const []const u8 = &.{},
    allow: []const []const u8 = &.{},
    disable_bypass_mode: bool = false,
    disable_dont_ask_mode: bool = false,
    /// Egress: only these hosts; user and project allowlists are ignored.
    allowed_domains_only: ?[]const []const u8 = null,
    /// `run_command` must run sandboxed; denied when no sandbox exists.
    require_sandbox: bool = false,
    telemetry_forbidden: bool = true,
    /// MCP server config keys allowed; null = any.
    allowed_mcp_servers: ?[]const []const u8 = null,
    min_trust_prompt: bool = true,
    /// Folder globs pre-trusted by the organisation (E16.F07.S01.T01).
    trusted_folders: []const []const u8 = &.{},
};

/// The outcome of `load`.
pub const LoadResult = union(enum) {
    /// No managed policy file.
    none,
    ok: ManagedPolicy,
    /// The file exists but is writable by non-administrators; the path or
    /// directory at fault.
    untrusted_location: []const u8,
    /// Diagnostics text.
    parse_error: []const u8,
};

/// The fixed per-OS location.
pub fn path() []const u8 {
    return if (builtin.os.tag == .windows) "C:\\ProgramData\\zigguro\\managed.zon" else "/etc/zigguro/managed.zon";
}

/// Says whether `p` is owned by an administrator and not writable by
/// others. Injected in tests.
pub const OwnerCheck = *const fn (p: [:0]const u8) error{ NotFound, Untrusted }!void;

/// Loads the managed policy from `path()`.
pub fn load(arena: Allocator, io: std.Io) LoadResult {
    return loadFrom(arena, io, path(), defaultOwnerCheck);
}

/// Loads from `file_path`, checking the file and every parent directory
/// with `check`.
pub fn loadFrom(arena: Allocator, io: std.Io, file_path: []const u8, check: OwnerCheck) LoadResult {
    // Trust the location before reading a byte.
    var p: []const u8 = file_path;
    while (true) {
        const z = arena.dupeZ(u8, p) catch return .{ .parse_error = "out of memory" };
        check(z) catch |e| switch (e) {
            error.NotFound => if (p.ptr == file_path.ptr and p.len == file_path.len) return .none else return .{ .untrusted_location = p },
            error.Untrusted => return .{ .untrusted_location = p },
        };
        p = std.fs.path.dirname(p) orelse break;
    }
    const src = std.Io.Dir.cwd().readFileAllocOptions(io, file_path, arena, .limited(1 << 20), .of(u8), 0) catch |e| switch (e) {
        error.FileNotFound => return .none,
        else => return .{ .parse_error = @errorName(e) },
    };
    return parseSource(arena, src);
}

/// Parses a managed policy document.
pub fn parseSource(arena: Allocator, src: [:0]const u8) LoadResult {
    var diag: std.zon.parse.Diagnostics = .{};
    const pol = std.zon.parse.fromSliceAlloc(ManagedPolicy, arena, src, &diag, .{}) catch |e| switch (e) {
        error.OutOfMemory => return .{ .parse_error = "out of memory" },
        error.ParseZon => return .{ .parse_error = std.fmt.allocPrint(arena, "{f}", .{&diag}) catch "invalid managed policy" },
    };
    return .{ .ok = pol };
}

fn defaultOwnerCheck(p: [:0]const u8) error{ NotFound, Untrusted }!void {
    if (builtin.os.tag != .linux) return error.Untrusted;
    const linux = std.os.linux;
    var st: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, p.ptr, linux.AT.SYMLINK_NOFOLLOW, .{ .UID = true, .MODE = true }, &st);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        .NOENT => return error.NotFound,
        else => return error.Untrusted,
    }
    if (st.uid != 0) return error.Untrusted;
    if (st.mode & 0o022 != 0) return error.Untrusted;
}

fn trustAll(_: [:0]const u8) error{ NotFound, Untrusted }!void {}

test "managed: root-owned 0644 file loads" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "managed.zon", .data =
        \\.{ .deny = .{ "web_fetch", "run_command(curl *)" }, .disable_bypass_mode = true }
    });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena.allocator());
    const file = try std.fs.path.join(arena.allocator(), &.{ dir, "managed.zon" });
    const r = loadFrom(arena.allocator(), io, file, trustAll);
    try std.testing.expect(r.ok.disable_bypass_mode);
    try std.testing.expectEqualStrings("run_command(curl *)", r.ok.deny[1]);
    // The real check refuses a temp dir (not root-owned).
    if (builtin.os.tag == .linux) try std.testing.expect(loadFrom(arena.allocator(), io, file, defaultOwnerCheck) == .untrusted_location);
}

test "managed: user-writable file downgraded" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const check = struct {
        fn f(p: [:0]const u8) error{ NotFound, Untrusted }!void {
            if (std.mem.eql(u8, p, "/etc/zigguro")) return error.Untrusted;
        }
    }.f;
    const r = loadFrom(arena.allocator(), std.testing.io, "/etc/zigguro/managed.zon", check);
    try std.testing.expectEqualStrings("/etc/zigguro", r.untrusted_location);
    const missing = struct {
        fn f(p: [:0]const u8) error{ NotFound, Untrusted }!void {
            if (std.mem.endsWith(u8, p, ".zon")) return error.NotFound;
        }
    }.f;
    try std.testing.expect(loadFrom(arena.allocator(), std.testing.io, "/etc/zigguro/managed.zon", missing) == .none);
}

test "managed: unknown field fails closed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const r = parseSource(arena.allocator(), ".{ .deny = .{\"x\"}, .allow_everything = true }");
    try std.testing.expect(r == .parse_error);
    try std.testing.expect(std.mem.indexOf(u8, r.parse_error, "allow_everything") != null);
}
