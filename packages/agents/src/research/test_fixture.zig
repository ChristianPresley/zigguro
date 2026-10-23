//! Shared test fixture: a temporary vault with a source library holding
//! two captured sources, an E12 stand-in that applies writes, and a fake
//! web.

const std = @import("std");
const zg_ai = @import("zg_ai");
const sources = @import("sources.zig");

const testing = std.testing;
const gpa = testing.allocator;
const io = testing.io;

pub const alpha_url = "https://alpha.example/zig-build";
pub const alpha_md =
    \\# Zig build cache
    \\
    \\The Zig build system caches every step by content hash. Unchanged steps are skipped.
    \\
    \\Incremental compilation is still experimental in Zig 0.16.
    \\
    \\- The cache lives in .zig-cache
    \\- The global cache lives in ~/.cache/zig
    \\
    \\```sh
    \\zig build --summary all
    \\```
    \\
;

pub const beta_url = "https://beta.example/release";
pub const beta_md =
    \\# Release notes
    \\
    \\Zig 0.16 moved I/O behind the std.Io interface.
    \\
    \\The new interface supports async and threaded backends.
    \\
;

pub const gamma_url = "https://gamma.example/news";
const gamma_html = "<html><head><title>Gamma news</title></head><body><main><h1>Gamma news</h1><p>The 0.16 release shipped in October.</p></main></body></html>";

/// E12 stand-in: every write lands in the vault.
pub const Notes = struct {
    dir: std.Io.Dir,
    writes: std.ArrayList([]const u8) = .empty,
    arena: std.heap.ArenaAllocator,

    fn write(ctx: *anyopaque, w: sources.NoteWrite) anyerror!sources.WriteOutcome {
        const n: *Notes = @ptrCast(@alignCast(ctx));
        try n.writes.append(n.arena.allocator(), try n.arena.allocator().dupe(u8, w.path));
        if (std.fs.path.dirname(w.path)) |d| try n.dir.createDirPath(io, d);
        try n.dir.writeFile(io, .{ .sub_path = w.path, .data = w.content });
        return .{ .applied = true, .changeset = n.writes.items.len };
    }
};

pub const Web = struct {
    fetches: u32 = 0,

    fn fetch(ctx: *anyopaque, a: std.mem.Allocator, url: []const u8) anyerror!sources.Fetched {
        const w: *Web = @ptrCast(@alignCast(ctx));
        w.fetches += 1;
        if (std.mem.eql(u8, url, gamma_url)) return .{ .body = try a.dupe(u8, gamma_html) };
        return error.NotFound;
    }
};

pub const Fx = struct {
    tmp: testing.TmpDir,
    clock: zg_ai.ratelimit.FakeClock,
    notes: Notes,
    web: Web = .{},
    lib: *sources.SourceLibrary,
    alpha: sources.SourceId,
    beta: sources.SourceId,

    pub fn init(f: *Fx) !void {
        f.* = .{ .tmp = testing.tmpDir(.{ .iterate = true }), .clock = .init(1_792_756_800_000), .notes = undefined, .lib = undefined, .alpha = undefined, .beta = undefined };
        f.notes = .{ .dir = f.tmp.dir, .arena = .init(gpa) };
        f.lib = try sources.SourceLibrary.open(gpa, io, f.tmp.dir, .{
            .clock = f.clock.clock(),
            .fetch = .{ .ctx = &f.web, .fetch = Web.fetch },
            .notes = .{ .ctx = &f.notes, .write = Notes.write },
        });
        f.alpha = (try f.lib.capture(alpha_url, .{ .markdown = alpha_md, .title = "Zig build cache" })).id.?;
        f.beta = (try f.lib.capture(beta_url, .{ .markdown = beta_md, .title = "Release notes" })).id.?;
    }

    pub fn deinit(f: *Fx) void {
        f.lib.close();
        f.notes.arena.deinit();
        f.tmp.cleanup();
    }

    pub fn read(f: *Fx, a: std.mem.Allocator, path: []const u8) ![]u8 {
        return f.tmp.dir.readFileAlloc(io, path, a, .limited(1 << 20));
    }
};
