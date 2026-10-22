//! All-or-nothing multi-ref updates: lock every ref (sorted, so concurrent
//! transactions cannot deadlock), verify the expected old values, write the
//! new values into the locks, then rename them into place. Any failure
//! before the rename phase removes every lock and changes nothing.

const std = @import("std");
const oid_mod = @import("../oid.zig");
const Ident = @import("../commit.zig").Ident;
const refs_mod = @import("refs.zig");
const refname = @import("refname.zig");
const lock_mod = @import("lock.zig");
const packed_mod = @import("packed.zig");
const reflog = @import("reflog.zig");
const Oid = oid_mod.Oid;
const RefValue = refs_mod.RefValue;
const RefStore = refs_mod.RefStore;
const Lock = lock_mod.Lock;
const Allocator = std.mem.Allocator;

/// What the ref must hold before the update.
pub const Expect = union(enum) {
    /// This object.
    oid: Oid,
    /// The ref must not exist.
    absent,
    /// Anything (same as passing null).
    any,
};

const Update = struct {
    name: []u8,
    /// null deletes.
    new: ?RefValue,
    expect: Expect,
    msg: []u8,
    who: ?Ident,
    lock: ?Lock = null,
    old: ?Oid = null,
};

/// See the file comment. Create with `RefStore.transaction`.
pub const RefTransaction = struct {
    rs: *RefStore,
    updates: std.ArrayList(Update) = .empty,
    arena: std.heap.ArenaAllocator,
    /// Test hook: fail after all locks are taken and verified.
    fail_before_commit: bool = false,

    /// An empty transaction on `rs`.
    pub fn init(rs: *RefStore) RefTransaction {
        return .{ .rs = rs, .arena = .init(rs.gpa) };
    }

    /// Frees the transaction (and drops any locks still held).
    pub fn deinit(t: *RefTransaction) void {
        for (t.updates.items) |*u| if (u.lock) |*l| {
            l.rollback(t.rs.io);
            l.deinit(t.rs.gpa);
        };
        t.updates.deinit(t.rs.gpa);
        t.arena.deinit();
        t.* = undefined;
    }

    fn validName(name: []const u8) bool {
        if (std.mem.startsWith(u8, name, "refs/")) return refname.checkRefFormat(name, .{});
        // Pseudo-refs: all caps and underscores ("HEAD", "ORIG_HEAD").
        if (name.len == 0) return false;
        for (name) |c| if (!(std.ascii.isUpper(c) or c == '_')) return false;
        return true;
    }

    /// Queues setting `name` to `new`.
    pub fn update(t: *RefTransaction, name: []const u8, new: RefValue, expect_old: ?Expect, reflog_msg: []const u8, who: Ident) !void {
        if (!validName(name)) return error.InvalidRefName;
        const a = t.arena.allocator();
        const v: RefValue = switch (new) {
            .direct => new,
            .symbolic => |s| blk: {
                if (!validName(s)) return error.InvalidRefName;
                break :blk .{ .symbolic = try a.dupe(u8, s) };
            },
        };
        try t.push(name, v, expect_old, reflog_msg, who);
    }

    /// Queues deleting `name` (loose file, packed entry and reflog).
    pub fn delete(t: *RefTransaction, name: []const u8, expect_old: ?Expect, reflog_msg: []const u8) !void {
        if (!validName(name)) return error.InvalidRefName;
        try t.push(name, null, expect_old, reflog_msg, null);
    }

    fn push(t: *RefTransaction, name: []const u8, new: ?RefValue, expect_old: ?Expect, msg: []const u8, who: ?Ident) !void {
        const a = t.arena.allocator();
        for (t.updates.items) |u| if (std.mem.eql(u8, u.name, name)) return error.DuplicateRefUpdate;
        try t.updates.append(t.rs.gpa, .{
            .name = try a.dupe(u8, name),
            .new = new,
            .expect = expect_old orelse .any,
            .msg = try a.dupe(u8, msg),
            .who = who,
        });
    }

    fn currentOid(t: *RefTransaction, packed_refs: *const packed_mod.PackedRefs, name: []const u8) !?Oid {
        const rs = t.rs;
        const text = rs.dirFor(name).readFileAlloc(rs.io, name, rs.gpa, .limited(4096)) catch |e| switch (e) {
            error.FileNotFound, error.IsDir, error.NotDir => {
                if (packed_refs.find(name)) |r| return r.oid;
                return null;
            },
            else => |x| return x,
        };
        defer rs.gpa.free(text);
        const v = try RefStore.parseLoose(rs.gpa, rs.format, text);
        switch (v) {
            .direct => |id| return id,
            .symbolic => |s| {
                // Compare against what the symref points at.
                defer rs.gpa.free(s);
                return rs.resolve(s);
            },
        }
    }

    fn rollbackAll(t: *RefTransaction) void {
        for (t.updates.items) |*u| if (u.lock) |*l| {
            l.rollback(t.rs.io);
            l.deinit(t.rs.gpa);
            u.lock = null;
        };
    }

    /// Applies every queued update or none.
    pub fn commit(t: *RefTransaction) !void {
        const rs = t.rs;
        const gpa = rs.gpa;
        const io = rs.io;
        std.mem.sort(Update, t.updates.items, {}, struct {
            fn lt(_: void, x: Update, y: Update) bool {
                return std.mem.order(u8, x.name, y.name) == .lt;
            }
        }.lt);
        errdefer t.rollbackAll();

        // 1. Lock.
        for (t.updates.items) |*u| u.lock = try Lock.acquire(gpa, io, rs.dirFor(u.name), u.name, rs.opts.lock_timeout_ms);
        var packed_lock: ?Lock = null;
        defer if (packed_lock) |*l| {
            l.rollback(io);
            l.deinit(gpa);
        };
        var packed_refs = try packed_mod.PackedRefs.load(gpa, io, rs.common_dir, rs.format);
        defer packed_refs.deinit(gpa);
        var deletes_packed = false;
        for (t.updates.items) |u| {
            if (u.new == null and !refs_mod.isPerWorktree(u.name) and packed_refs.find(u.name) != null) deletes_packed = true;
        }
        if (deletes_packed) {
            packed_lock = try Lock.acquire(gpa, io, rs.common_dir, "packed-refs", rs.opts.lock_timeout_ms);
            // Re-read under the lock.
            packed_refs.deinit(gpa);
            packed_refs = try packed_mod.PackedRefs.load(gpa, io, rs.common_dir, rs.format);
        }

        // 2. Verify.
        for (t.updates.items) |*u| {
            u.old = try t.currentOid(&packed_refs, u.name);
            switch (u.expect) {
                .any => {},
                .absent => if (u.old != null) return error.RefExists,
                .oid => |want| if (u.old == null or !u.old.?.eql(want)) return error.RefMismatch,
            }
        }

        // 3. Write the new values into the locks.
        var lbuf: [300]u8 = undefined;
        for (t.updates.items) |*u| {
            const v = u.new orelse continue;
            var hb: [64]u8 = undefined;
            const text = switch (v) {
                .direct => |id| try std.fmt.bufPrint(&lbuf, "{s}\n", .{id.hex(&hb)}),
                .symbolic => |s| try std.fmt.bufPrint(&lbuf, "ref: {s}\n", .{s}),
            };
            try u.lock.?.write(io, text, rs.opts.fsync);
        }
        if (packed_lock) |*pl| {
            var aw: std.Io.Writer.Allocating = .init(gpa);
            defer aw.deinit();
            try packed_refs.write(&aw.writer, Skip{ .updates = t.updates.items });
            try pl.write(io, aw.written(), rs.opts.fsync);
        }
        if (t.fail_before_commit) return error.InjectedFailure;

        // 4. Commit: packed-refs first so a deleted ref never reappears from
        // it, then the loose files.
        if (packed_lock) |*pl| {
            try pl.commit(io);
            pl.deinit(gpa);
            packed_lock = null;
        }
        const head_target: ?[]u8 = rs.resolveName(gpa, "HEAD") catch null;
        defer if (head_target) |h| gpa.free(h);
        for (t.updates.items) |*u| {
            var l = u.lock.?;
            if (u.new == null) {
                rs.dirFor(u.name).deleteFile(io, u.name) catch {};
                l.rollback(io);
                var pb: [std.fs.max_path_bytes]u8 = undefined;
                rs.dirFor(u.name).deleteFile(io, try std.fmt.bufPrint(&pb, "logs/{s}", .{u.name})) catch {};
            } else {
                try l.commit(io);
                try t.logUpdate(u, head_target);
            }
            l.deinit(gpa);
            u.lock = null;
        }
    }

    fn logUpdate(t: *RefTransaction, u: *const Update, head_target: ?[]const u8) !void {
        const rs = t.rs;
        const who = u.who orelse return;
        const new = switch (u.new.?) {
            .direct => |id| id,
            .symbolic => return, // git logs symref changes only through the target
        };
        const old = u.old orelse Oid.zero(rs.format);
        var aw: std.Io.Writer.Allocating = .init(rs.gpa);
        defer aw.deinit();
        try reflog.formatLine(&aw.writer, old, new, who, u.msg);
        if (shouldLog(rs, u.name)) try reflog.append(rs.io, rs.dirFor(u.name), u.name, aw.written());
        // Updating the branch HEAD points at also logs HEAD.
        if (head_target) |h| if (std.mem.eql(u8, h, u.name) and !std.mem.eql(u8, u.name, "HEAD")) {
            if (shouldLog(rs, "HEAD")) try reflog.append(rs.io, rs.git_dir, "HEAD", aw.written());
        };
    }

    fn shouldLog(rs: *RefStore, name: []const u8) bool {
        var pb: [std.fs.max_path_bytes]u8 = undefined;
        const p = std.fmt.bufPrint(&pb, "logs/{s}", .{name}) catch return false;
        if (rs.dirFor(name).access(rs.io, p, .{})) |_| return true else |_| {}
        if (!rs.opts.log_all_ref_updates) return false;
        if (std.mem.eql(u8, name, "HEAD")) return true;
        for ([_][]const u8{ "refs/heads/", "refs/remotes/", "refs/notes/" }) |pre| {
            if (std.mem.startsWith(u8, name, pre)) return true;
        }
        return false;
    }

    const Skip = struct {
        updates: []const Update,
        pub fn skip(s: Skip, name: []const u8) bool {
            for (s.updates) |u| if (u.new == null and std.mem.eql(u8, u.name, name)) return true;
            return false;
        }
    };
};
