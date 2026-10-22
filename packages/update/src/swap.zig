//! The journaled swap (E17.F04.S02.T01): `staged/` becomes `app/`, the
//! old `app/` becomes `app.prev/`, each step a directory rename on the
//! install volume, recorded in `swap.journal` before the next one.
//!
//! 1. `begin{from, to}`.
//! 2. An older `app.prev/` moves aside to `app.old-<rand>/` (deleted only
//!    at the end: it is the rollback target until then).
//! 3. `app` → `app.prev`, then `app_to_prev`.
//! 4. `staged` → `app`, then `staged_to_app`.
//! 5. Clean up `staged.zon` and `app.old-*`, `done`, delete the journal.
//!
//! `recover` repairs any interrupted state from what is on disk, guided by
//! the journal, so that `app/` always ends up holding one complete
//! version: the new one when `staged/` survived intact (forward), else the
//! old one (backward). The same repair covers an interrupted `rollback`.
//! The failpoint matrix test crashes after every step and rename.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const names = @import("layout.zig").names;
const journal = @import("journal.zig");
const stage = @import("stage.zig");

pub const Outcome = enum { applied, nothing_staged, recovered_forward, recovered_backward };

/// The previous version's directory.
pub const prev = names.prev;
/// Where `rollback` moves a failed version.
pub const failed = names.failed;
/// Prefix of a superseded `app.prev` awaiting deletion.
pub const old_prefix = "app.old-";

/// Points where tests simulate a crash.
pub const Failpoint = enum {
    after_begin,
    after_prev_aside,
    after_app_renamed,
    after_app_to_prev,
    after_staged_renamed,
    after_staged_to_app,
    after_cleanup,
};

/// Tests only: `applyStaged` fails with `error.Failpoint` here.
pub var test_failpoint: ?Failpoint = null;

fn failpoint(p: Failpoint) error{Failpoint}!void {
    if (builtin.is_test and test_failpoint == p) return error.Failpoint;
}

/// Swaps `staged/` in as `app/`. Recovers an interrupted swap first.
pub fn applyStaged(arena: Allocator, io: Io, root: Io.Dir, current_version: []const u8, now_unix: i64) !Outcome {
    if (try journal.last(arena, io, root) != null) _ = try recover(arena, io, root);
    const staged = stage.readStaged(arena, io, root) orelse return .nothing_staged;
    const entry: journal.Entry = .{ .step = .begin, .from = current_version, .to = staged.version, .ts = now_unix };

    try journal.append(io, root, entry);
    try failpoint(.after_begin);
    if (exists(io, root, prev)) {
        var r: [8]u8 = undefined;
        io.random(&r);
        const aside = try std.fmt.allocPrint(arena, "{s}{x}", .{ old_prefix, &r });
        try rename(io, root, prev, aside);
    }
    try failpoint(.after_prev_aside);
    if (exists(io, root, names.app)) try rename(io, root, names.app, prev);
    try failpoint(.after_app_renamed);
    try journal.append(io, root, withStep(entry, .app_to_prev));
    try failpoint(.after_app_to_prev);
    try rename(io, root, names.staged, names.app);
    try failpoint(.after_staged_renamed);
    try journal.append(io, root, withStep(entry, .staged_to_app));
    try failpoint(.after_staged_to_app);
    try cleanup(io, root);
    try failpoint(.after_cleanup);
    try journal.append(io, root, withStep(entry, .done));
    try journal.remove(io, root);
    return .applied;
}

fn withStep(e: journal.Entry, step: journal.Step) journal.Entry {
    var out = e;
    out.step = step;
    return out;
}

/// Repairs an interrupted swap or rollback. Null when there was nothing
/// to repair.
pub fn recover(arena: Allocator, io: Io, root: Io.Dir) !?Outcome {
    const entry = try journal.last(arena, io, root);
    const have_app = exists(io, root, names.app);
    if (entry == null and have_app) return null;

    var outcome: Outcome = .recovered_backward;
    if (!have_app) {
        // Prefer the new version when `staged/` survived intact.
        if (entry != null and stage.readStaged(arena, io, root) != null) {
            try rename(io, root, names.staged, names.app);
            outcome = .recovered_forward;
        } else if (exists(io, root, prev)) {
            try rename(io, root, prev, names.app);
        } else if (exists(io, root, failed)) {
            // Interrupted rollback with no previous version left.
            try rename(io, root, failed, names.app);
        } else return error.NoVersionLeft;
    } else if (entry) |e| {
        // `app/` exists: either nothing moved yet, or `staged` → `app`
        // already happened (staged/ gone, its staged.zon still there).
        if (e.step == .staged_to_app or e.step == .done or !exists(io, root, names.staged)) outcome = .recovered_forward;
    }
    // A superseded app.prev that never got deleted becomes app.prev again
    // when the swap went backward and app.prev is gone.
    if (!exists(io, root, prev)) {
        if (try findOld(arena, io, root)) |old| {
            if (outcome == .recovered_backward) try rename(io, root, old, prev);
        }
    }
    if (outcome == .recovered_forward) try cleanup(io, root);
    try journal.remove(io, root);
    return outcome;
}

/// Puts the previous version back: `app` → `app.failed`, `app.prev` →
/// `app`.
pub fn rollback(io: Io, root: Io.Dir) !void {
    if (!exists(io, root, prev)) return error.NoPreviousVersion;
    root.deleteTree(io, failed) catch {};
    if (exists(io, root, names.app)) try rename(io, root, names.app, failed);
    try rename(io, root, prev, names.app);
}

/// Removes `staged.zon` and every `app.old-*`.
fn cleanup(io: Io, root: Io.Dir) !void {
    root.deleteFile(io, names.staged_zon) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    var it_dir = try root.openDir(io, ".", .{ .iterate = true });
    defer it_dir.close(io);
    var buf: [16][64]u8 = undefined;
    var n: usize = 0;
    var it = it_dir.iterate();
    while (try it.next(io)) |e| {
        if (n < buf.len and std.mem.startsWith(u8, e.name, old_prefix) and e.name.len <= 64) {
            @memcpy(buf[n][0..e.name.len], e.name);
            buf[n][e.name.len] = 0;
            n += 1;
        }
    }
    for (buf[0..n]) |*b| try root.deleteTree(io, std.mem.sliceTo(b, 0));
}

fn findOld(arena: Allocator, io: Io, root: Io.Dir) !?[]const u8 {
    var d = try root.openDir(io, ".", .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |e| {
        if (std.mem.startsWith(u8, e.name, old_prefix)) return try arena.dupe(u8, e.name);
    }
    return null;
}

fn exists(io: Io, root: Io.Dir, name: []const u8) bool {
    _ = root.statFile(io, name, .{}) catch return false;
    return true;
}

/// A directory rename. On Windows a scanner or indexer may hold a new
/// executable open for a moment: retry 20 times, 250 ms apart.
fn rename(io: Io, root: Io.Dir, from: []const u8, to: []const u8) !void {
    var attempt: u32 = 0;
    while (true) : (attempt += 1) {
        root.rename(from, root, to, io) catch |err| switch (err) {
            error.AccessDenied, error.FileBusy => if (builtin.os.tag == .windows and attempt < 20) {
                try io.sleep(.fromMilliseconds(250), .awake);
                continue;
            } else return err,
            else => return err,
        };
        return;
    }
}

// ---------------------------------------------------------------------------
// Tests

const testing = std.testing;

/// `<name>/version` holding `v`.
fn makeVersion(io: Io, root: Io.Dir, name: []const u8, v: []const u8) !void {
    try root.createDirPath(io, name);
    var d = try root.openDir(io, name, .{});
    defer d.close(io);
    try d.writeFile(io, .{ .sub_path = "version", .data = v });
}

fn versionOf(io: Io, root: Io.Dir, name: []const u8, buf: []u8) ?[]const u8 {
    var d = root.openDir(io, name, .{}) catch return null;
    defer d.close(io);
    return d.readFile(io, "version", buf) catch null;
}

fn writeStagedZon(io: Io, root: Io.Dir, v: []const u8) !void {
    var buf: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, ".{{ .version = \"{s}\", .sha256 = \"00\", .serial = 1, .staged_at = 1 }}\n", .{v});
    try root.writeFile(io, .{ .sub_path = names.staged_zon, .data = text });
}

fn fixture(io: Io, root: Io.Dir, with_prev: bool) !void {
    if (with_prev) try makeVersion(io, root, prev, "0.3.0");
    try makeVersion(io, root, names.app, "0.4.0");
    try makeVersion(io, root, names.staged, "0.5.0");
    try writeStagedZon(io, root, "0.5.0");
}

test "swap: fresh apply, and apply with an existing app.prev" {
    const io = testing.io;
    for ([_]bool{ false, true }) |with_prev| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        try fixture(io, tmp.dir, with_prev);
        try testing.expectEqual(Outcome.applied, try applyStaged(arena.allocator(), io, tmp.dir, "0.4.0", 1));
        var b: [16]u8 = undefined;
        try testing.expectEqualStrings("0.5.0", versionOf(io, tmp.dir, names.app, &b).?);
        try testing.expectEqualStrings("0.4.0", versionOf(io, tmp.dir, prev, &b).?);
        try testing.expect(!exists(io, tmp.dir, names.staged) and !exists(io, tmp.dir, names.staged_zon) and !exists(io, tmp.dir, names.journal));
        try testing.expect(try findOld(arena.allocator(), io, tmp.dir) == null);
        // Nothing staged now.
        try testing.expectEqual(Outcome.nothing_staged, try applyStaged(arena.allocator(), io, tmp.dir, "0.5.0", 2));
        // Rollback puts 0.4.0 back and keeps 0.5.0 aside.
        try rollback(io, tmp.dir);
        try testing.expectEqualStrings("0.4.0", versionOf(io, tmp.dir, names.app, &b).?);
        try testing.expectEqualStrings("0.5.0", versionOf(io, tmp.dir, failed, &b).?);
        try testing.expectError(error.NoPreviousVersion, rollback(io, tmp.dir));
    }
}

test "swap: a crash after every step recovers to a runnable app" {
    const io = testing.io;
    defer test_failpoint = null;
    for ([_]bool{ false, true }) |with_prev| {
        for (std.enums.values(Failpoint)) |fp| {
            var tmp = testing.tmpDir(.{ .iterate = true });
            defer tmp.cleanup();
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();
            try fixture(io, tmp.dir, with_prev);
            test_failpoint = fp;
            try testing.expectError(error.Failpoint, applyStaged(a, io, tmp.dir, "0.4.0", 1));
            test_failpoint = null;

            const outcome = (try recover(a, io, tmp.dir)) orelse .applied;
            var b: [16]u8 = undefined;
            var b2: [16]u8 = undefined;
            const now = versionOf(io, tmp.dir, names.app, &b) orelse {
                std.debug.print("failpoint {t} (prev {}): no app\n", .{ fp, with_prev });
                return error.NoApp;
            };
            const back = versionOf(io, tmp.dir, prev, &b2);
            errdefer std.debug.print("failpoint {t} (prev {}): app {s}, prev {?s}, outcome {t}\n", .{ fp, with_prev, now, back, outcome });
            if (std.mem.eql(u8, now, "0.5.0")) {
                // Forward: the old version is the rollback target.
                try testing.expectEqualStrings("0.4.0", back.?);
                try testing.expect(outcome == .recovered_forward or outcome == .applied);
                try testing.expect(!exists(io, tmp.dir, names.staged_zon));
            } else {
                try testing.expectEqualStrings("0.4.0", now);
                try testing.expectEqual(Outcome.recovered_backward, outcome);
                if (with_prev) try testing.expectEqualStrings("0.3.0", back.?);
                // The update is still staged and applies next time.
                try testing.expectEqual(Outcome.applied, try applyStaged(a, io, tmp.dir, "0.4.0", 2));
                try testing.expectEqualStrings("0.5.0", versionOf(io, tmp.dir, names.app, &b).?);
            }
            try testing.expect(try findOld(a, io, tmp.dir) == null);
            try testing.expect(!exists(io, tmp.dir, names.journal));
        }
    }
}

test "swap: an interrupted rollback recovers" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try makeVersion(io, tmp.dir, prev, "0.4.0");
    try makeVersion(io, tmp.dir, failed, "0.5.0");
    // app → app.failed happened, app.prev → app did not.
    try testing.expectEqual(Outcome.recovered_backward, (try recover(arena.allocator(), io, tmp.dir)).?);
    var b: [16]u8 = undefined;
    try testing.expectEqualStrings("0.4.0", versionOf(io, tmp.dir, names.app, &b).?);
    try testing.expect(try recover(arena.allocator(), io, tmp.dir) == null);
}
