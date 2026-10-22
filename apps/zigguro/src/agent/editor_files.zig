//! `EditorFiles`: the agents' `Files` in the IDE (E10 ↔ E05). A file open
//! in the editor is read and edited through E05's `AgentEditSession` on
//! the UI thread: reads see the unsaved buffer, and edits are rebased over
//! the user's typing and land as one undo step. Every other path goes to
//! disk through zg_ai's `DiskFiles`, or through `outside` when set.
//!
//! Tools call in from agent tasks; editor work is posted to the UI thread
//! (`App.post`) while the task waits on an `Io.Event`, so the documents
//! are only ever touched there. The tool already passed the user's
//! approval, so the edit session applies every valid proposal.
//!
//! Rejections map onto the `Files` ones: a conflict with the user's
//! typing, an evicted base version and an out-of-bounds edit all ask the
//! model to re-read (`stale`).

const std = @import("std");
const zg_ai = @import("zg_ai");
const zg_gui = @import("zg_gui");
const zg_editor = @import("zg_editor");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const zfiles = zg_ai.tools.builtin.files;
const DiskFiles = zg_ai.tools.builtin.disk_files.DiskFiles;
const api = zg_editor.model.api;
const DocumentRegistry = api.registry.DocumentRegistry;
const DocHandle = api.registry.DocHandle;
const agent_edit = api.agent_edit;

/// See the module doc.
pub const EditorFiles = struct {
    app: *zg_gui.App,
    disk: DiskFiles,
    reg: *DocumentRegistry,
    edits: agent_edit.AgentEditSession,
    /// Runs on the UI thread after an agent edit landed in an open
    /// document.
    on_edit: ?Hook = null,
    /// The `Files` for paths not open in the editor (E12's recording
    /// `ReviewGlue`); the plain disk when null.
    outside: ?zfiles.Files = null,

    pub const Hook = struct { ctx: *anyopaque, f: *const fn (ctx: *anyopaque, doc: DocHandle, tool: []const u8) void };

    /// Files under `root` (absolute, normalized), with the documents of
    /// `reg`; `session` names the agent session in undo labels.
    pub fn init(gpa: Allocator, app: *zg_gui.App, root: []const u8, reg: *DocumentRegistry, session: u64) EditorFiles {
        return .{ .app = app, .disk = .{ .root = root }, .reg = reg, .edits = .init(gpa, reg, session, .{ .ctx = undefined, .decide = applyAll }) };
    }

    /// UI thread; no tool may still be running.
    pub fn deinit(self: *EditorFiles) void {
        self.edits.deinit();
    }

    /// The `Files` for zg_ai's `FileTools`.
    pub fn files(self: *EditorFiles) zfiles.Files {
        return .{ .ctx = self, .vtable = &.{ .resolve = resolve, .kind = kind, .read = read, .propose = propose, .end_turn = endTurn, .kind_as = kindAs, .read_as = readAs } };
    }

    /// The turn's changes are `outside`'s to close (E12's review queue).
    fn endTurn(ctx: *anyopaque, io: Io, agent: zg_ai.proto.AgentRef, turn: u32) anyerror!?u64 {
        const o = cast(ctx).outside orelse return null;
        return o.endTurn(io, agent, turn);
    }

    fn applyAll(_: *anyopaque, _: u64, _: DocHandle, _: agent_edit.ProposalSummary) agent_edit.Decision {
        return .apply;
    }

    fn cast(ctx: *anyopaque) *EditorFiles {
        return @ptrCast(@alignCast(ctx));
    }

    fn diskFiles(self: *EditorFiles) zfiles.Files {
        return self.outside orelse self.disk.asFiles();
    }

    /// Editor work for the UI thread.
    const Job = struct {
        self: *EditorFiles,
        abs: []const u8,
        arena: Allocator,
        op: union(enum) {
            kind,
            read: usize,
            propose: struct { p: zfiles.Proposal, tool: []const u8 },
        },
        /// The path is open in the editor (else: use the disk).
        open: bool = false,
        kind_out: zfiles.Kind = .missing,
        read_out: zfiles.Read = undefined,
        outcome: zfiles.Outcome = undefined,
        err: ?anyerror = null,
        done: Io.Event = .unset,
    };

    /// Runs `job` on the UI thread and waits for it.
    fn onUi(self: *EditorFiles, io: Io, job: *Job) !void {
        try self.app.post(.{ .ctx = job, .f = runJob });
        job.done.waitUncancelable(io);
        if (job.err) |e| return e;
    }

    fn runJob(ctx: *anyopaque, _: *zg_gui.App) void {
        const job: *Job = @ptrCast(@alignCast(ctx));
        defer job.done.set(job.self.app.rt.?.io);
        doJob(job) catch |e| {
            job.err = e;
        };
    }

    fn resolve(ctx: *anyopaque, io: Io, arena: Allocator, path: []const u8) Allocator.Error!zfiles.Resolved {
        const d = cast(ctx).diskFiles();
        return d.vtable.resolve(d.ctx, io, arena, path);
    }

    fn kind(ctx: *anyopaque, io: Io, abs: []const u8) zfiles.Kind {
        const self = cast(ctx);
        var job: Job = .{ .self = self, .abs = abs, .arena = undefined, .op = .kind };
        self.onUi(io, &job) catch {};
        if (job.open) return job.kind_out;
        const d = self.diskFiles();
        return d.vtable.kind(d.ctx, io, abs);
    }

    fn read(ctx: *anyopaque, io: Io, arena: Allocator, abs: []const u8, max_bytes: usize) anyerror!zfiles.Read {
        const self = cast(ctx);
        var job: Job = .{ .self = self, .abs = abs, .arena = arena, .op = .{ .read = max_bytes } };
        try self.onUi(io, &job);
        if (job.open) return job.read_out;
        const d = self.diskFiles();
        return d.vtable.read(d.ctx, io, arena, abs, max_bytes);
    }

    /// Open documents as in `kind`; other paths in `agent`'s view
    /// (`outside` may hold changes for review).
    fn kindAs(ctx: *anyopaque, io: Io, abs: []const u8, agent: zg_ai.proto.AgentRef) zfiles.Kind {
        const self = cast(ctx);
        var job: Job = .{ .self = self, .abs = abs, .arena = undefined, .op = .kind };
        self.onUi(io, &job) catch {};
        if (job.open) return job.kind_out;
        return self.diskFiles().kindAs(io, abs, agent);
    }

    fn readAs(ctx: *anyopaque, io: Io, arena: Allocator, abs: []const u8, max_bytes: usize, agent: zg_ai.proto.AgentRef) anyerror!zfiles.Read {
        const self = cast(ctx);
        var job: Job = .{ .self = self, .abs = abs, .arena = arena, .op = .{ .read = max_bytes } };
        try self.onUi(io, &job);
        if (job.open) return job.read_out;
        return self.diskFiles().readAs(io, arena, abs, max_bytes, agent);
    }

    fn propose(ctx: *anyopaque, io: Io, arena: Allocator, abs: []const u8, p: zfiles.Proposal, origin: zfiles.Origin) anyerror!zfiles.Outcome {
        const self = cast(ctx);
        var job: Job = .{ .self = self, .abs = abs, .arena = arena, .op = .{ .propose = .{ .p = p, .tool = origin.tool } } };
        try self.onUi(io, &job);
        if (job.open) return job.outcome;
        const d = self.diskFiles();
        return d.vtable.propose(d.ctx, io, arena, abs, p, origin);
    }

    fn doJob(job: *Job) !void {
        const self = job.self;
        const h = (try self.reg.findFile(job.abs)) orelse return;
        const doc = self.reg.get(h) orelse return;
        job.open = true;
        switch (job.op) {
            .kind => job.kind_out = .file,
            .read => |max| {
                const n = @min(doc.len(), max);
                job.read_out = .{
                    .version = doc.version,
                    .bytes = try doc.tree.copyRange(job.arena, .{ .start = 0, .end = n }),
                    .size = doc.len(),
                    .from_buffer = doc.isDirty(),
                };
            },
            .propose => |pr| {
                const p: agent_edit.Proposal = switch (pr.p) {
                    .str_replace => |s| .{ .str_replace = .{ .old = s.old, .new = s.new, .occurrence = switch (s.occurrence) {
                        .unique => .unique,
                        .all => .all,
                    } } },
                    .whole_file => |w| .{ .whole_file = .{ .text = w.text, .base_version = w.base_version } },
                    .create => {
                        job.outcome = .{ .rejected = .already_exists };
                        return;
                    },
                };
                var out = try self.edits.propose(h, p, pr.tool);
                defer out.deinit(self.edits.gpa);
                job.outcome = mapOutcome(out);
                if (out == .applied) if (self.on_edit) |hook| hook.f(hook.ctx, h, pr.tool);
            },
        }
    }
};

fn mapOutcome(o: agent_edit.Outcome) zfiles.Outcome {
    return switch (o) {
        .applied => |a| .{ .applied = .{ .version = a.version } },
        // The policy applies everything; a pending change has no id here.
        .pending => .{ .pending = .{ .changeset = 0 } },
        .rejected => |r| .{ .rejected = switch (r) {
            .stale_handle => .{ .io = "the document was closed" },
            .read_only => .read_only,
            .stale_version_evicted, .out_of_bounds, .conflict => .stale,
            .too_large => .too_large,
            .overlapping_edits => .{ .io = "the edits overlap" },
            .not_found, .no_such_occurrence => .not_found,
            .not_unique => |n| .{ .not_unique = n.count },
            .denied, .no_pending_host => .{ .denied = "the editor did not accept the edit" },
        } },
    };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const zg_core = @import("zg_core");

/// An app with a runtime bound to the test thread, a registry with one
/// open document and files on disk under a temporary root.
const Fx = struct {
    rt: zg_core.Runtime,
    app: zg_gui.App,
    reg: DocumentRegistry,
    tmp: testing.TmpDir,
    root: [:0]u8,
    ef: EditorFiles,
    edited: u32,

    fn init(f: *Fx) !void {
        f.edited = 0;
        f.rt.initTesting();
        f.rt.bindUiThread(.noop);
        f.app = zg_gui.App.init(testing.allocator);
        f.app.attachRuntime(&f.rt);
        f.reg = .init(testing.allocator, .native);
        f.tmp = testing.tmpDir(.{});
        f.root = try f.tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "open.txt", .data = "on disk\n" });
        try f.tmp.dir.writeFile(testing.io, .{ .sub_path = "closed.txt", .data = "alpha beta\n" });
        const open = try std.fs.path.join(testing.allocator, &.{ f.root, "open.txt" });
        defer testing.allocator.free(open);
        // The buffer differs from the disk: it has unsaved typing.
        _ = try f.reg.openFile(open, "in the buffer\n");
        f.ef = .init(testing.allocator, &f.app, f.root, &f.reg, 1);
        f.ef.on_edit = .{ .ctx = f, .f = onEdit };
    }

    fn deinit(f: *Fx) void {
        f.ef.deinit();
        f.reg.deinit();
        testing.allocator.free(f.root);
        f.tmp.cleanup();
        f.app.deinit();
        _ = f.rt.deinit();
    }

    fn onEdit(ctx: *anyopaque, _: DocHandle, _: []const u8) void {
        const f: *Fx = @ptrCast(@alignCast(ctx));
        f.edited += 1;
    }

    /// Runs `func` on a task while this (UI) thread drains posted work.
    fn call(f: *Fx, comptime func: anytype, args: anytype) !@typeInfo(@TypeOf(func)).@"fn".return_type.? {
        const R = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
        const Box = struct {
            out: R = undefined,
            done: std.atomic.Value(bool) = .init(false),
            fn go(b: *@This(), a: @TypeOf(args)) void {
                b.out = @call(.auto, func, a);
                b.done.store(true, .release);
            }
        };
        var box: Box = .{};
        var fut = try testing.io.concurrent(Box.go, .{ &box, args });
        while (!box.done.load(.acquire)) {
            _ = f.app.drainMessages();
            testing.io.sleep(.fromMicroseconds(100), .awake) catch {};
        }
        fut.await(testing.io);
        return box.out;
    }
};

fn readPath(fs: zfiles.Files, arena: Allocator, abs: []const u8) anyerror!zfiles.Read {
    return fs.read(testing.io, arena, abs, 1 << 20);
}

fn proposePath(fs: zfiles.Files, arena: Allocator, abs: []const u8, p: zfiles.Proposal) anyerror!zfiles.Outcome {
    return fs.propose(testing.io, arena, abs, p, .{ .agent = .{ .session = 1 }, .tool = "edit_file", .tool_call_id = "t1" });
}

test "editor files: open documents through the editor, the rest on disk" {
    var f: Fx = undefined;
    try f.init();
    defer f.deinit();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fs = f.ef.files();

    const open = (try fs.resolve(testing.io, arena, "open.txt")).abs;
    const closed = (try fs.resolve(testing.io, arena, "closed.txt")).abs;

    // The open file reads from its buffer, not the disk.
    const r = try (try f.call(readPath, .{ fs, arena, open }));
    try testing.expectEqualStrings("in the buffer\n", r.bytes);
    try testing.expect(!r.from_buffer);

    // An edit lands in the document, not on disk.
    const o = try (try f.call(proposePath, .{ fs, arena, open, @as(zfiles.Proposal, .{ .str_replace = .{ .old = "buffer", .new = "editor" } }) }));
    try testing.expect(o == .applied);
    const doc = f.reg.get((try f.reg.findFile(open)).?).?;
    const now = try doc.tree.copyRange(arena, .{ .start = 0, .end = doc.len() });
    try testing.expectEqualStrings("in the editor\n", now);
    try testing.expectEqual(@as(u32, 1), f.edited);
    const disk = try f.tmp.dir.readFileAlloc(testing.io, "open.txt", arena, .limited(64));
    try testing.expectEqualStrings("on disk\n", disk);
    // Now the buffer has unsaved changes, and the model is told so.
    const r2 = try (try f.call(readPath, .{ fs, arena, open }));
    try testing.expect(r2.from_buffer);
    try testing.expect(r2.version != r.version);

    // Rejections come back in the tools' terms.
    const miss = try (try f.call(proposePath, .{ fs, arena, open, @as(zfiles.Proposal, .{ .str_replace = .{ .old = "nowhere", .new = "x" } }) }));
    try testing.expect(miss.rejected == .not_found);
    // A whole-file write based on the first read is rebased over the edit
    // since: it touches the same line, so the model must re-read.
    const stale = try (try f.call(proposePath, .{ fs, arena, open, @as(zfiles.Proposal, .{ .whole_file = .{ .text = "x\n", .base_version = r.version } }) }));
    try testing.expect(stale.rejected == .stale);
    const exists = try (try f.call(proposePath, .{ fs, arena, open, @as(zfiles.Proposal, .{ .create = .{ .text = "x" } }) }));
    try testing.expect(exists.rejected == .already_exists);

    // A file that is not open goes to disk.
    const c = try (try f.call(readPath, .{ fs, arena, closed }));
    try testing.expectEqualStrings("alpha beta\n", c.bytes);
    try testing.expect(!c.from_buffer);
    const co = try (try f.call(proposePath, .{ fs, arena, closed, @as(zfiles.Proposal, .{ .str_replace = .{ .old = "beta", .new = "gamma" } }) }));
    try testing.expect(co == .applied);
    const written = try f.tmp.dir.readFileAlloc(testing.io, "closed.txt", arena, .limited(64));
    try testing.expectEqualStrings("alpha gamma\n", written);
    try testing.expectEqual(@as(u32, 1), f.edited);
}
