//! Loading `.zigguro/automations/*.zon` (E13.F02.S01.T03). Every file is
//! parsed and validated on its own: a broken file is reported with its
//! line and column and left out, never fatal. Automations that came with
//! the repository run only after the user approved their exact content
//! once (`TrustPort`, E16 pinned approvals): until then they are loaded
//! disabled and marked `needs_approval`, so a `git pull` cannot schedule
//! agents.

const std = @import("std");
const auto = @import("automation.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Automation = auto.Automation;

pub const dir_path = ".zigguro/automations";
pub const max_file_bytes = 256 << 10;

pub const Hash = [32]u8;

/// Whether the user approved this content of this automation (E16
/// `PinKind.automation`).
pub const TrustPort = struct {
    ctx: *anyopaque,
    isApproved: *const fn (ctx: *anyopaque, name: []const u8, hash: Hash) bool,
};

pub const Loaded = struct {
    /// `daily-digest.zon`.
    file: []const u8,
    /// The file stem.
    name: []const u8,
    /// Null when the file is invalid.
    automation: ?Automation = null,
    problem: ?auto.Problem = null,
    /// SHA-256 of the file's bytes.
    hash: Hash = @splat(0),
    /// Valid but not yet approved: loaded disabled.
    needs_approval: bool = false,
    /// The file's text.
    source: []const u8 = "",
};

pub const LoadResult = struct {
    arena: std.heap.ArenaAllocator,
    /// Sorted by file name.
    items: []Loaded,

    pub fn deinit(r: *LoadResult) void {
        r.arena.deinit();
    }

    /// The valid automations, approval applied (`enabled = false` until
    /// approved), in the result's arena.
    pub fn automations(r: *LoadResult) Allocator.Error![]const Automation {
        const a = r.arena.allocator();
        var out: std.ArrayList(Automation) = .empty;
        for (r.items) |it| if (it.automation) |x| {
            var copy = x;
            if (it.needs_approval) copy.enabled = false;
            try out.append(a, copy);
        };
        return out.items;
    }

    pub fn find(r: *const LoadResult, name: []const u8) ?*const Loaded {
        for (r.items) |*it| if (std.mem.eql(u8, it.name, name)) return it;
        return null;
    }

    /// Files with problems.
    pub fn problems(r: *const LoadResult) usize {
        var n: usize = 0;
        for (r.items) |it| {
            if (it.problem != null) n += 1;
        }
        return n;
    }
};

/// Loads every `*.zon` in `dir`. `trust` null trusts everything (the CLI
/// validating a checkout, tests).
pub fn loadAll(io: Io, gpa: Allocator, dir: Io.Dir, trust: ?TrustPort) !LoadResult {
    var res: LoadResult = .{ .arena = .init(gpa), .items = &.{} };
    errdefer res.arena.deinit();
    const a = res.arena.allocator();
    var list: std.ArrayList(Loaded) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zon")) continue;
        try list.append(a, try loadOne(io, a, dir, entry.name, trust));
    }
    std.mem.sort(Loaded, list.items, {}, struct {
        fn lt(_: void, x: Loaded, y: Loaded) bool {
            return std.mem.lessThan(u8, x.file, y.file);
        }
    }.lt);
    res.items = list.items;
    return res;
}

/// Loads one file (its name relative to `dir`) into `arena`.
pub fn loadOne(io: Io, arena: Allocator, dir: Io.Dir, file: []const u8, trust: ?TrustPort) !Loaded {
    var l: Loaded = .{ .file = try arena.dupe(u8, file), .name = undefined };
    l.name = l.file[0 .. l.file.len - ".zon".len];
    const bytes = dir.readFileAllocOptions(io, file, arena, .limited(max_file_bytes), .of(u8), 0) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => {
            l.problem = .{ .message = "file is larger than 256 KiB" };
            return l;
        },
        else => {
            l.problem = .{ .message = try std.fmt.allocPrint(arena, "cannot read: {t}", .{e}) };
            return l;
        },
    };
    l.source = bytes;
    std.crypto.hash.sha2.Sha256.hash(bytes, &l.hash, .{});
    return check(arena, l, bytes, trust);
}

/// Parses and validates `source` as the automation in `file`.
pub fn loadSource(arena: Allocator, file: []const u8, source: [:0]const u8, trust: ?TrustPort) !Loaded {
    var l: Loaded = .{ .file = try arena.dupe(u8, file), .name = undefined, .source = source };
    l.name = l.file[0 .. l.file.len - ".zon".len];
    std.crypto.hash.sha2.Sha256.hash(source, &l.hash, .{});
    return check(arena, l, source, trust);
}

fn check(arena: Allocator, l0: Loaded, source: [:0]const u8, trust: ?TrustPort) !Loaded {
    var l = l0;
    var problem: auto.Problem = .{ .message = "" };
    const a = auto.parse(arena, source, &problem) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => {
            l.problem = problem;
            return l;
        },
    };
    if (auto.validate(&a, l.name)) |msg| {
        l.problem = .{ .message = msg };
        return l;
    }
    l.automation = a;
    if (trust) |t| l.needs_approval = !t.isApproved(t.ctx, a.name, l.hash);
    return l;
}
