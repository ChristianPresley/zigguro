//! Test helpers for the checked-in git fixtures in `testdata/` (see
//! `testdata/gen.sh`). Only referenced from tests.

const std = @import("std");
const options = @import("zg_options");
const oid_mod = @import("oid.zig");
const ObjectType = @import("object.zig").ObjectType;
const Pack = @import("pack/pack.zig").Pack;
const Oid = oid_mod.Oid;
const ObjectFormat = oid_mod.ObjectFormat;
const Allocator = std.mem.Allocator;

/// Expected type and size of a fixture object.
pub const Expected = struct { type: ObjectType, size: u64 };

/// Opens `testdata/<sub>` of this package.
pub fn openDir(io: std.Io, sub: []const u8) !std.Io.Dir {
    var root = try std.Io.Dir.openDirAbsolute(io, options.package_root, .{});
    defer root.close(io);
    var buf: [256]u8 = undefined;
    return root.openDir(io, try std.fmt.bufPrint(&buf, "testdata/{s}", .{sub}), .{ .iterate = true });
}

/// One fixture repository: its objects directory, opened packs and the
/// `objects.txt` listing.
pub const Fixture = struct {
    gpa: Allocator,
    io: std.Io,
    format: ObjectFormat,
    root: std.Io.Dir,
    objects: std.Io.Dir,
    packs: std.ArrayList(*Pack) = .empty,
    expected: std.AutoHashMapUnmanaged(Oid, Expected) = .empty,
    listing: []u8,

    /// Opens `testdata/sha1` or `testdata/sha256`.
    pub fn open(gpa: Allocator, io: std.Io, fmt: ObjectFormat) !Fixture {
        var root = try openDir(io, fmt.name());
        errdefer root.close(io);
        const objects = try root.openDir(io, "objects", .{ .iterate = true });
        const listing = try root.readFileAlloc(io, "objects.txt", gpa, .limited(1 << 20));
        var fx: Fixture = .{ .gpa = gpa, .io = io, .format = fmt, .root = root, .objects = objects, .listing = listing };
        errdefer fx.close();
        var lines = std.mem.tokenizeScalar(u8, listing, '\n');
        while (lines.next()) |line| {
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            const id = try Oid.parseHex(fmt, f.next().?);
            const t = ObjectType.fromName(f.next().?).?;
            const size = try std.fmt.parseInt(u64, f.next().?, 10);
            try fx.expected.put(gpa, id, .{ .type = t, .size = size });
        }
        var pd = try fx.packDir();
        defer pd.close(io);
        var it = pd.iterate();
        while (try it.next(io)) |e| {
            if (!std.mem.endsWith(u8, e.name, ".idx")) continue;
            const stem = e.name[0 .. e.name.len - 4];
            const p = try Pack.open(gpa, io, pd, stem, fmt, @intCast(fx.packs.items.len));
            try fx.packs.append(gpa, p);
        }
        return fx;
    }

    /// The `objects/pack` directory (caller closes).
    pub fn packDir(fx: *Fixture) !std.Io.Dir {
        return fx.objects.openDir(fx.io, "pack", .{ .iterate = true });
    }

    /// Closes everything.
    pub fn close(fx: *Fixture) void {
        for (fx.packs.items) |p| p.close(fx.gpa, fx.io);
        fx.packs.deinit(fx.gpa);
        fx.expected.deinit(fx.gpa);
        fx.gpa.free(fx.listing);
        fx.objects.close(fx.io);
        fx.root.close(fx.io);
    }
};
