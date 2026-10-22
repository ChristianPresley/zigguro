//! The GPU-init crash marker (E02.F01.S02.T01, #279). `gpu-init.lock` is
//! written to the cache directory (`~/.cache/zigguro`) before the loader
//! is opened and removed once the device exists. If a start finds it, the
//! previous start crashed inside the driver: that start uses the software
//! renderer and removes the marker, so the one after it tries Vulkan again.

const std = @import("std");

const log = std.log.scoped(.vk);

pub const file_name = "gpu-init.lock";

pub const CrashMarker = struct {
    dir: std.Io.Dir,

    /// Writes the marker, or fails with `error.PreviousInitCrashed` (and
    /// removes the stale marker) when it already exists.
    pub fn begin(io: std.Io, dir: std.Io.Dir) error{PreviousInitCrashed}!CrashMarker {
        if (dir.access(io, file_name, .{})) |_| {
            log.info("the previous start crashed during GPU initialisation ({s} exists); using the software renderer", .{file_name});
            dir.deleteFile(io, file_name) catch {};
            return error.PreviousInitCrashed;
        } else |_| {}
        dir.writeFile(io, .{ .sub_path = file_name, .data = "zigguro GPU initialisation in progress\n" }) catch |err|
            log.debug("cannot write {s}: {s}", .{ file_name, @errorName(err) });
        return .{ .dir = dir };
    }

    /// Removes the marker after a successful initialisation.
    pub fn end(self: CrashMarker, io: std.Io) void {
        self.dir.deleteFile(io, file_name) catch {};
    }
};

test "marker: a leftover marker forces software once" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A clean start writes and removes the marker.
    const m = try CrashMarker.begin(io, tmp.dir);
    try tmp.dir.access(io, file_name, .{});
    m.end(io);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, file_name, .{}));
    // A crash leaves it behind: the next start falls back, the one after retries.
    _ = try CrashMarker.begin(io, tmp.dir);
    try std.testing.expectError(error.PreviousInitCrashed, CrashMarker.begin(io, tmp.dir));
    const again = try CrashMarker.begin(io, tmp.dir);
    again.end(io);
}
