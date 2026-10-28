//! Credentials for HTTPS remotes (E09.F08.S02): the `git credential`
//! fill/approve/reject cycle. Sources, in order: the URL's own userinfo,
//! the caller's provider (zigguro's secret store, a prompt or a GitHub
//! sign-in), then `credential.helper` programs speaking git's helper
//! protocol. The `store` helper is built in (it reads and writes
//! `~/.git-credentials`), so no git install is needed for it.

const std = @import("std");
const builtin = @import("builtin");
const Repository = @import("../repository.zig").Repository;
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Credential = struct {
    protocol: []const u8,
    host: []const u8,
    path: []const u8 = "",
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,

    /// The `key=value` lines of git's credential protocol.
    pub fn write(c: Credential, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("protocol={s}\nhost={s}\n", .{ c.protocol, c.host });
        if (c.path.len > 0) try w.print("path={s}\n", .{c.path});
        if (c.username) |u| try w.print("username={s}\n", .{u});
        if (c.password) |p| try w.print("password={s}\n", .{p});
        try w.writeAll("\n");
    }

    /// Reads a helper's answer into `c` (strings in `a`).
    pub fn read(c: *Credential, a: Allocator, text: []const u8) !void {
        var it = std.mem.tokenizeScalar(u8, text, '\n');
        while (it.next()) |line0| {
            const line = std.mem.trimEnd(u8, line0, "\r");
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const k = line[0..eq];
            const v = try a.dupe(u8, line[eq + 1 ..]);
            if (std.mem.eql(u8, k, "username")) c.username = v else if (std.mem.eql(u8, k, "password")) c.password = v;
        }
    }

    pub fn complete(c: Credential) bool {
        return c.username != null and c.password != null;
    }
};

/// A source the caller adds (zigguro's secret store, a password prompt).
pub const Provider = struct {
    ctx: ?*anyopaque = null,
    /// Fills username/password; false when it has nothing.
    fill: *const fn (ctx: ?*anyopaque, a: Allocator, c: *Credential) anyerror!bool,
    approve: ?*const fn (ctx: ?*anyopaque, c: *const Credential) void = null,
    reject: ?*const fn (ctx: ?*anyopaque, c: *const Credential) void = null,
};

pub const Operation = enum { get, store, erase };

/// The credential pipeline for one repository.
pub const Pipeline = struct {
    repo: *Repository,
    provider: ?Provider = null,
    /// Which helper (or the provider, index = helpers.len) filled the
    /// current credential.
    filled_by: ?usize = null,

    /// Fills `c`; false when no source had a credential.
    pub fn fill(p: *Pipeline, a: Allocator, c: *Credential) !bool {
        if (c.complete()) return true;
        if (p.provider) |pr| if (try pr.fill(pr.ctx, a, c)) {
            p.filled_by = std.math.maxInt(usize);
            return true;
        };
        const helpers = try p.repo.config.getAll(a, "credential.helper");
        for (helpers, 0..) |h, i| {
            if (h.len == 0) continue;
            if (try runHelper(p.repo, a, h, .get, c) and c.complete()) {
                p.filled_by = i;
                return true;
            }
        }
        return false;
    }

    /// The server accepted `c`: helpers may store it.
    pub fn approve(p: *Pipeline, a: Allocator, c: *const Credential) void {
        if (p.filled_by == std.math.maxInt(usize)) {
            if (p.provider) |pr| if (pr.approve) |f| f(pr.ctx, c);
        }
        const helpers = p.repo.config.getAll(a, "credential.helper") catch return;
        for (helpers) |h| {
            if (h.len == 0) continue;
            var copy = c.*;
            _ = runHelper(p.repo, a, h, .store, &copy) catch {};
        }
    }

    /// The server refused `c`: helpers forget it.
    pub fn reject(p: *Pipeline, a: Allocator, c: *const Credential) void {
        if (p.provider) |pr| if (pr.reject) |f| f(pr.ctx, c);
        const helpers = p.repo.config.getAll(a, "credential.helper") catch return;
        for (helpers) |h| {
            if (h.len == 0) continue;
            var copy = c.*;
            _ = runHelper(p.repo, a, h, .erase, &copy) catch {};
        }
    }
};

/// Runs one helper: `store` natively, others as `git-credential-<name>`,
/// an absolute path, or a `!shell command`. True when it answered.
fn runHelper(repo: *Repository, a: Allocator, helper: []const u8, op: Operation, c: *Credential) !bool {
    var words = std.mem.tokenizeAny(u8, helper, " \t");
    const first = words.next() orelse return false;
    if (std.mem.eql(u8, first, "store")) {
        var file: ?[]const u8 = null;
        while (words.next()) |w| if (std.mem.startsWith(u8, w, "--file=")) {
            file = w["--file=".len..];
        };
        return storeHelper(repo, a, file, op, c);
    }
    var argv: std.ArrayList([]const u8) = .empty;
    if (first[0] == '!') {
        try argv.appendSlice(a, &.{ "sh", "-c", try std.fmt.allocPrint(a, "{s} \"$@\"", .{helper[1..]}), helper[1..] });
    } else {
        try argv.append(a, if (std.fs.path.isAbsolute(first)) first else try std.fmt.allocPrint(a, "git-credential-{s}", .{first}));
        while (words.next()) |w| try argv.append(a, w);
    }
    try argv.append(a, @tagName(op));
    var input: Io.Writer.Allocating = .init(a);
    try c.write(&input.writer);
    var child = std.process.spawn(repo.io, .{
        .argv = argv.items,
        .environ_map = repo.envMap(),
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
        .create_no_window = true,
    }) catch return false;
    defer _ = child.wait(repo.io) catch {};
    {
        var wbuf: [256]u8 = undefined;
        var fw = child.stdin.?.writerStreaming(repo.io, &wbuf);
        fw.interface.writeAll(input.written()) catch {};
        fw.interface.flush() catch {};
        child.stdin.?.close(repo.io);
        child.stdin = null;
    }
    var rbuf: [4096]u8 = undefined;
    var fr = child.stdout.?.readerStreaming(repo.io, &rbuf);
    const out = fr.interface.allocRemaining(a, .limited(64 << 10)) catch return false;
    if (op != .get) return true;
    try c.read(a, out);
    return c.username != null or c.password != null;
}

/// `git credential-store`: lines of `https://user:pass@host[/path]` in
/// `~/.git-credentials` (or `--file`).
fn storeHelper(repo: *Repository, a: Allocator, file_opt: ?[]const u8, op: Operation, c: *Credential) !bool {
    const home = repo.home orelse return false;
    const file = file_opt orelse try std.fs.path.join(a, &.{ home, ".git-credentials" });
    const text = Io.Dir.cwd().readFileAlloc(repo.io, file, a, .limited(1 << 20)) catch |e| switch (e) {
        error.FileNotFound => "",
        else => return e,
    };
    var keep: std.ArrayList(u8) = .empty;
    var found = false;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |line| {
        const uri = std.Uri.parse(std.mem.trim(u8, line, " \r")) catch {
            try keep.appendSlice(a, line);
            try keep.append(a, '\n');
            continue;
        };
        var hb: [256]u8 = undefined;
        const bare_host = (uri.host orelse continue).toRaw(&hb) catch continue;
        const host = if (uri.port) |port| try std.fmt.allocPrint(a, "{s}:{d}", .{ bare_host, port }) else bare_host;
        const matches = std.mem.eql(u8, uri.scheme, c.protocol) and std.ascii.eqlIgnoreCase(host, c.host) and
            (c.username == null or (uri.user != null and std.mem.eql(u8, try uri.user.?.toRawMaybeAlloc(a), c.username.?)));
        if (matches and op == .get and !found) {
            if (uri.user) |u| c.username = try a.dupe(u8, try u.toRawMaybeAlloc(a));
            if (uri.password) |pw| c.password = try a.dupe(u8, try pw.toRawMaybeAlloc(a));
            found = true;
        }
        if (matches and op != .get) continue;
        try keep.appendSlice(a, line);
        try keep.append(a, '\n');
    }
    switch (op) {
        .get => return found,
        .erase => {},
        .store => {
            if (!c.complete()) return false;
            var w: Io.Writer.Allocating = .init(a);
            try w.writer.print("{s}://", .{c.protocol});
            try (std.Uri.Component{ .raw = c.username.? }).formatUser(&w.writer);
            try w.writer.writeByte(':');
            try (std.Uri.Component{ .raw = c.password.? }).formatPassword(&w.writer);
            try w.writer.print("@{s}\n", .{c.host});
            try keep.appendSlice(a, w.written());
        },
    }
    try Io.Dir.cwd().writeFile(repo.io, .{ .sub_path = file, .data = keep.items, .flags = .{ .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600) } });
    return true;
}
