//! A headless weston on a private runtime dir, for integration tests.
//! `start` fails when weston is not installed; callers skip then.

const std = @import("std");
const Io = std.Io;
const testing = std.testing;

/// A running weston.
pub const WestonForTest = struct {
    tmp: testing.TmpDir,
    path_buf: [Io.Dir.max_path_bytes]u8,
    path_len: usize,
    child: std.process.Child,

    /// The socket name inside `dirPath()`.
    pub const socket_name = "zg-test";

    /// Starts weston and waits up to 2 s for its socket.
    pub fn start() !WestonForTest {
        var w: WestonForTest = undefined;
        w.tmp = testing.tmpDir(.{});
        errdefer w.tmp.cleanup();
        w.path_len = try w.tmp.dir.realPath(testing.io, &w.path_buf);
        var env: std.process.Environ.Map = .init(testing.allocator);
        defer env.deinit();
        try env.put("XDG_RUNTIME_DIR", w.path_buf[0..w.path_len]);
        w.child = try std.process.spawn(testing.io, .{
            .argv = &.{ "weston", "--backend=headless", "--socket=" ++ socket_name, "--idle-time=0", "--no-config" },
            .environ_map = &env,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        errdefer w.child.kill(testing.io);
        var tries: usize = 0;
        while (tries < 200) : (tries += 1) {
            if (w.tmp.dir.access(testing.io, socket_name, .{})) |_| return w else |_| {}
            try testing.io.sleep(.fromMilliseconds(10), .awake);
        }
        return error.WestonDidNotStart;
    }

    /// The runtime directory holding the socket.
    pub fn dirPath(w: *const WestonForTest) []const u8 {
        return w.path_buf[0..w.path_len];
    }

    /// Fills `env` so `Connection.connect` reaches this weston.
    pub fn environ(w: *const WestonForTest, env: *std.process.Environ.Map) !void {
        try env.put("XDG_RUNTIME_DIR", w.dirPath());
        try env.put("WAYLAND_DISPLAY", socket_name);
    }

    /// Stops weston and removes the directory.
    pub fn stop(w: *WestonForTest) void {
        w.child.kill(testing.io);
        w.tmp.cleanup();
    }
};
