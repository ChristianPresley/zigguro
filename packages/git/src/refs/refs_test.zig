//! Ref store tests on scratch repositories.

const std = @import("std");
const oid_mod = @import("../oid.zig");
const commit = @import("../commit.zig");
const refs = @import("refs.zig");
const RefStore = refs.RefStore;
const Oid = oid_mod.Oid;

const who: commit.Ident = .{ .name = "T", .email = "t@example.com", .time = 1700000000, .tz = "+0000" };
const a_id = Oid.parseHex(.sha1, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") catch unreachable;
const b_id = Oid.parseHex(.sha1, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb") catch unreachable;
const c_id = Oid.parseHex(.sha1, "cccccccccccccccccccccccccccccccccccccccc") catch unreachable;

fn hex(id: Oid) [40]u8 {
    var buf: [64]u8 = undefined;
    return id.hex(&buf)[0..40].*;
}

fn setup(io: std.Io, dir: std.Io.Dir) !void {
    try dir.createDirPath(io, "refs/heads/feature");
    try dir.writeFile(io, .{ .sub_path = "HEAD", .data = "ref: refs/heads/main\n" });
    try dir.writeFile(io, .{ .sub_path = "refs/heads/main", .data = &(hex(a_id) ++ "\n".*) });
    try dir.writeFile(io, .{ .sub_path = "refs/heads/feature/x", .data = &(hex(b_id) ++ "\n".*) });
    try dir.writeFile(io, .{ .sub_path = "packed-refs", .data = "# pack-refs with: peeled fully-peeled sorted \n" ++
        hex(c_id) ++ " refs/heads/main\n" ++
        hex(c_id) ++ " refs/heads/old\n" ++
        hex(c_id) ++ " refs/tags/v1\n" ++
        "^" ++ hex(a_id) ++ "\n" });
}

test "refs: loose+packed merge iteration" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try setup(t.io, tmp.dir);
    var rs = try RefStore.open(t.allocator, t.io, tmp.dir, .sha1, .{});
    defer rs.close();
    var l = try rs.iterate(t.allocator, "");
    defer l.deinit();
    const want = [_][]const u8{ "refs/heads/feature/x", "refs/heads/main", "refs/heads/old", "refs/tags/v1" };
    try t.expectEqual(want.len, l.refs.len);
    for (want, l.refs) |w, r| try t.expectEqualStrings(w, r.name);
    // Loose main shadows the packed one.
    try t.expect(l.refs[1].value.direct.eql(a_id));
    try t.expect(l.refs[3].peeled.?.eql(a_id));
    var heads = try rs.iterate(t.allocator, "refs/heads/");
    defer heads.deinit();
    try t.expectEqual(@as(usize, 3), heads.refs.len);
}

test "refs: symref resolution and loops" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try setup(t.io, tmp.dir);
    var rs = try RefStore.open(t.allocator, t.io, tmp.dir, .sha1, .{});
    defer rs.close();
    try t.expect((try rs.resolve("HEAD")).?.eql(a_id));
    try t.expect((try rs.resolve("refs/heads/old")).?.eql(c_id));
    const v = (try rs.read(t.allocator, "HEAD")).?;
    defer v.deinit(t.allocator);
    try t.expectEqualStrings("refs/heads/main", v.symbolic);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "refs/heads/loop1", .data = "ref: refs/heads/loop2\n" });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "refs/heads/loop2", .data = "ref: refs/heads/loop1\n" });
    try t.expectError(error.SymrefLoop, rs.resolve("refs/heads/loop1"));
    // Unborn branch.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "HEAD", .data = "ref: refs/heads/unborn\n" });
    try t.expect((try rs.resolve("HEAD")) == null);
    const name = try rs.resolveName(t.allocator, "HEAD");
    defer t.allocator.free(name);
    try t.expectEqualStrings("refs/heads/unborn", name);
}

test "refs: transaction atomicity under injected failure" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try setup(t.io, tmp.dir);
    var rs = try RefStore.open(t.allocator, t.io, tmp.dir, .sha1, .{});
    defer rs.close();
    {
        var tx = rs.transaction();
        defer tx.deinit();
        try tx.update("refs/heads/main", .{ .direct = b_id }, .{ .oid = a_id }, "move", who);
        try tx.update("refs/heads/new", .{ .direct = b_id }, .absent, "create", who);
        try tx.delete("refs/heads/old", null, "drop");
        tx.fail_before_commit = true;
        try t.expectError(error.InjectedFailure, tx.commit());
    }
    try t.expect((try rs.resolve("refs/heads/main")).?.eql(a_id));
    try t.expect((try rs.resolve("refs/heads/new")) == null);
    try t.expect((try rs.resolve("refs/heads/old")).?.eql(c_id));
    try tmp.dir.access(t.io, "packed-refs", .{});
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "refs/heads/main.lock", .{}));
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "packed-refs.lock", .{}));
    {
        // A failed expectation aborts everything too.
        var tx = rs.transaction();
        defer tx.deinit();
        try tx.update("refs/heads/new", .{ .direct = b_id }, .absent, "create", who);
        try tx.update("refs/heads/main", .{ .direct = b_id }, .{ .oid = c_id }, "move", who);
        try t.expectError(error.RefMismatch, tx.commit());
    }
    try t.expect((try rs.resolve("refs/heads/new")) == null);
    {
        var tx = rs.transaction();
        defer tx.deinit();
        try tx.update("refs/heads/main", .{ .direct = b_id }, .{ .oid = a_id }, "move", who);
        try tx.update("refs/heads/new", .{ .direct = b_id }, .absent, "create", who);
        try tx.commit();
    }
    try t.expect((try rs.resolve("HEAD")).?.eql(b_id));
    try t.expect((try rs.resolve("refs/heads/new")).?.eql(b_id));
    var buf: [512]u8 = undefined;
    const head_log = try tmp.dir.readFile(t.io, "logs/HEAD", &buf);
    try t.expect(std.mem.endsWith(u8, head_log, "\tmove\n"));
    var bad = rs.transaction();
    defer bad.deinit();
    try t.expectError(error.InvalidRefName, bad.delete("refs/heads/a..b", null, ""));
}

test "refs: delete packed ref" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try setup(t.io, tmp.dir);
    var rs = try RefStore.open(t.allocator, t.io, tmp.dir, .sha1, .{});
    defer rs.close();
    var tx = rs.transaction();
    defer tx.deinit();
    try tx.delete("refs/heads/old", .{ .oid = c_id }, "drop");
    try tx.delete("refs/heads/main", null, "drop");
    try tx.commit();
    try t.expect((try rs.resolve("refs/heads/old")) == null);
    try t.expect((try rs.resolve("refs/heads/main")) == null);
    var l = try rs.iterate(t.allocator, "");
    defer l.deinit();
    try t.expectEqual(@as(usize, 2), l.refs.len);
}

test "refs: worktree split (commondir)" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try setup(t.io, tmp.dir);
    try tmp.dir.createDirPath(t.io, "worktrees/wt");
    var wt = try tmp.dir.openDir(t.io, "worktrees/wt", .{});
    defer wt.close(t.io);
    try wt.writeFile(t.io, .{ .sub_path = "commondir", .data = "../..\n" });
    try wt.writeFile(t.io, .{ .sub_path = "HEAD", .data = &(hex(b_id) ++ "\n".*) });
    var rs = try RefStore.open(t.allocator, t.io, wt, .sha1, .{});
    defer rs.close();
    try t.expect((try rs.resolve("HEAD")).?.eql(b_id));
    try t.expect((try rs.resolve("refs/heads/main")).?.eql(a_id));
    var tx = rs.transaction();
    defer tx.deinit();
    try tx.update("refs/worktree/mine", .{ .direct = c_id }, .absent, "wt", who);
    try tx.update("refs/heads/shared", .{ .direct = c_id }, .absent, "shared", who);
    try tx.commit();
    try wt.access(t.io, "refs/worktree/mine", .{});
    try tmp.dir.access(t.io, "refs/heads/shared", .{});
    try t.expectError(error.FileNotFound, tmp.dir.access(t.io, "refs/worktree/mine", .{}));
    var l = try rs.iterate(t.allocator, "refs/");
    defer l.deinit();
    var names: usize = 0;
    for (l.refs) |r| {
        if (std.mem.eql(u8, r.name, "refs/worktree/mine") or std.mem.eql(u8, r.name, "refs/heads/shared")) names += 1;
    }
    try t.expectEqual(@as(usize, 2), names);
}

test "refs: reftable is reported unsupported" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(t.io, "reftable");
    try t.expectError(error.UnsupportedRefStorage, RefStore.open(t.allocator, t.io, tmp.dir, .sha1, .{}));
}
