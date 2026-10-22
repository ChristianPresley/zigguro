//! An in-memory `Files` for tests: a workspace at `/ws`, files that can be
//! marked as open in an editor with unsaved text, and a policy that
//! applies, keeps pending or rejects proposals. Never touches the disk.

const std = @import("std");
const files = @import("files.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const root = "/ws";

const Doc = struct {
    text: []const u8,
    version: u64,
    /// An unsaved editor buffer.
    buffer: bool = false,
};

pub const Mode = union(enum) {
    apply,
    pending,
    /// Pending in the turn's changeset, committed by `end_turn`.
    batched,
    reject: files.Rejection,
};

pub const FakeFiles = struct {
    arena: std.heap.ArenaAllocator,
    docs: std.StringHashMapUnmanaged(Doc) = .empty,
    dirs: std.StringHashMapUnmanaged(void) = .empty,
    mode: Mode = .apply,
    next_version: u64 = 1,
    next_changeset: u64 = 1,
    /// Recorded proposals.
    proposals: std.ArrayList(struct { abs: []const u8, p: files.Proposal, origin: files.Origin }) = .empty,
    /// `.batched`: proposals of the open turn, then the committed turns.
    open_changes: u32 = 0,
    committed: std.ArrayList(struct { turn: u32, changes: u32, changeset: u64 }) = .empty,
    mutex: Io.Mutex = .init,

    pub fn init(gpa: Allocator) FakeFiles {
        return .{ .arena = .init(gpa) };
    }

    pub fn deinit(f: *FakeFiles) void {
        f.arena.deinit();
    }

    pub fn asFiles(f: *FakeFiles) files.Files {
        return .{ .ctx = f, .vtable = &.{ .resolve = resolve, .kind = kind, .read = read, .propose = propose, .end_turn = endTurn } };
    }

    /// Sets the text of `rel` (on disk, or an unsaved buffer).
    pub fn put(f: *FakeFiles, rel: []const u8, content: []const u8, buffer: bool) !void {
        const a = f.arena.allocator();
        const abs = try std.fmt.allocPrint(a, root ++ "/{s}", .{rel});
        try f.docs.put(a, abs, .{ .text = try a.dupe(u8, content), .version = f.bump(), .buffer = buffer });
    }

    pub fn dir(f: *FakeFiles, rel: []const u8) !void {
        const a = f.arena.allocator();
        try f.dirs.put(a, try std.fmt.allocPrint(a, root ++ "/{s}", .{rel}), {});
    }

    pub fn text(f: *FakeFiles, rel: []const u8) ?[]const u8 {
        var buf: [256]u8 = undefined;
        const abs = std.fmt.bufPrint(&buf, root ++ "/{s}", .{rel}) catch return null;
        return if (f.docs.get(abs)) |d| d.text else null;
    }

    fn bump(f: *FakeFiles) u64 {
        defer f.next_version += 1;
        return f.next_version;
    }

    fn resolve(_: *anyopaque, _: Io, arena: Allocator, path: []const u8) Allocator.Error!files.Resolved {
        const abs = try std.fs.path.resolvePosix(arena, &.{ root, path });
        const inside = std.mem.startsWith(u8, abs, root ++ "/");
        return .{ .abs = abs, .rel = if (inside) abs[root.len + 1 ..] else abs, .inside_workspace = inside };
    }

    fn kind(ctx: *anyopaque, _: Io, abs: []const u8) files.Kind {
        const f: *FakeFiles = @ptrCast(@alignCast(ctx));
        if (f.docs.contains(abs)) return .file;
        if (f.dirs.contains(abs)) return .directory;
        return .missing;
    }

    fn read(ctx: *anyopaque, _: Io, arena: Allocator, abs: []const u8, max_bytes: usize) anyerror!files.Read {
        const f: *FakeFiles = @ptrCast(@alignCast(ctx));
        const d = f.docs.get(abs) orelse return error.FileNotFound;
        return .{ .version = d.version, .bytes = try arena.dupe(u8, d.text[0..@min(d.text.len, max_bytes)]), .size = d.text.len, .from_buffer = d.buffer };
    }

    fn endTurn(ctx: *anyopaque, io: Io, _: @import("zg_ai_proto").AgentRef, turn: u32) anyerror!?u64 {
        const f: *FakeFiles = @ptrCast(@alignCast(ctx));
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        if (f.open_changes == 0) return null;
        defer f.next_changeset += 1;
        try f.committed.append(f.arena.allocator(), .{ .turn = turn, .changes = f.open_changes, .changeset = f.next_changeset });
        f.open_changes = 0;
        return f.next_changeset;
    }

    fn propose(ctx: *anyopaque, io: Io, _: Allocator, abs: []const u8, p: files.Proposal, origin: files.Origin) anyerror!files.Outcome {
        const f: *FakeFiles = @ptrCast(@alignCast(ctx));
        f.mutex.lockUncancelable(io);
        defer f.mutex.unlock(io);
        const a = f.arena.allocator();
        try f.proposals.append(a, .{ .abs = try a.dupe(u8, abs), .p = p, .origin = origin });
        switch (f.mode) {
            .reject => |r| return .{ .rejected = r },
            else => {},
        }
        const cur = f.docs.get(abs);
        const new: []const u8 = switch (p) {
            .create => |cr| if (cur != null) return .{ .rejected = .already_exists } else cr.text,
            .str_replace => |sr| switch (try files.strReplace(a, cur.?.text, sr.old, sr.new, sr.occurrence)) {
                .ok => |ok| ok.text,
                .not_found => return .{ .rejected = .not_found },
                .not_unique => |n| return .{ .rejected = .{ .not_unique = n } },
            },
            .whole_file => |wf| blk: {
                if (wf.base_version) |b| if (b != cur.?.version) return .{ .rejected = .stale };
                break :blk wf.text;
            },
        };
        if (f.mode == .pending) {
            defer f.next_changeset += 1;
            return .{ .pending = .{ .changeset = f.next_changeset } };
        }
        if (f.mode == .batched) {
            f.open_changes += 1;
            return .{ .pending = .{} };
        }
        const v = f.bump();
        try f.docs.put(a, try a.dupe(u8, abs), .{ .text = try a.dupe(u8, new), .version = v, .buffer = if (cur) |c| c.buffer else false });
        return .{ .applied = .{ .version = v } };
    }
};
