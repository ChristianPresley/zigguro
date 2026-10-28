//! `ScmPanel`: the Git tab (E09 IDE integration, the Source Control view):
//! every git function of a working tree, through zigguro's own git
//! (`git.zig`: zg_git and the zg_scm git bridge; no git program).
//!
//! The header shows the branch with its ahead/behind counts, and has
//! Refresh, Fetch, Pull, Push and Sync, and a box that runs any git
//! command line ("rebase -i" excepted: nothing can answer an editor).
//! A banner offers Continue, Skip and Abort while a merge, rebase,
//! cherry-pick or revert is half done. The pages:
//! - Changes: the commit message (Commit, Commit All, Amend), conflicts
//!   (take ours or theirs, mark resolved), staged, changed and untracked
//!   files with Stage, Unstage, Discard; a click shows the diff, a double
//!   click opens the file.
//! - History: the log (`git.logLimit`, this branch or all); a commit's
//!   patch, and Checkout, New Branch, New Tag, Cherry-Pick, Revert,
//!   Rebase After This (interactive) and Reset (soft, mixed, hard) at it.
//! - Branches: local and remote branches: New, Checkout, Merge, Rebase
//!   onto (plain or interactive), Rename, Delete, Publish, delete on the
//!   remote.
//! - An interactive rebase writes a plan and opens it in the editor; the
//!   banner offers Edit Plan, Start and Cancel, and while a rebase is
//!   stopped, Edit Todo, Continue, Skip and Abort.
//! - Stashes: Stash (with untracked files), Apply, Pop, Drop, the patch.
//! - Tags: New, Delete, Push, Push All, delete on the remote, Checkout.
//! - Remotes: Add, Rename, Set URL, Fetch, Prune, Remove.
//! - Submodules: Add, Update (init, recursive), Sync, Run in Each
//!   (`submodule foreach`).
//! - Output: every command run and what it printed.
//! Outside a repository it offers Initialize Repository and Clone.
//!
//! Git runs on worker threads; results come back through the UI mailbox
//! (`msg_kind`, handled by `handleMessage`), or at once without a
//! runtime (tests). Commands that change the repository refresh the view
//! and tell the host (open editors, the explorer).

const std = @import("std");
const zg_core = @import("zg_core");
const zg_gui = @import("zg_gui");
const git_mod = @import("git.zig");

const Allocator = std.mem.Allocator;
const Ui = zg_gui.Ui;
const Window = zg_gui.Window;
const Git = git_mod.Git;

/// The mailbox kind of a finished git job (`a` = the job).
pub const msg_kind: u32 = 0x0509_0b01;

/// What the panel asks of its host.
pub const Hooks = struct {
    ctx: *anyopaque,
    /// Opens `abs` in an editor.
    open: *const fn (ctx: *anyopaque, abs: []const u8) void,
    /// A command changed the repository or the working tree.
    changed: ?*const fn (ctx: *anyopaque) void = null,
};

/// The pages.
pub const Tab = enum {
    changes,
    history,
    branches,
    stashes,
    tags,
    remotes,
    submodules,
    output,

    fn title(t: Tab) []const u8 {
        return switch (t) {
            .changes => "Changes",
            .history => "History",
            .branches => "Branches",
            .stashes => "Stashes",
            .tags => "Tags",
            .remotes => "Remotes",
            .submodules => "Submodules",
            .output => "Output",
        };
    }
};

/// Everything a refresh read, in one arena.
const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    repo: bool = false,
    status: git_mod.Status = .{},
    op: git_mod.Op = .none,
    log: []git_mod.Commit = &.{},
    branches: []git_mod.Branch = &.{},
    tags: []git_mod.Tag = &.{},
    stashes: []git_mod.Stash = &.{},
    remotes: []git_mod.Remote = &.{},
    submodules: []git_mod.Submodule = &.{},
    /// Why a read failed ("" when none did).
    problem: []const u8 = "",

    fn destroy(s: *Snapshot, gpa: Allocator) void {
        s.arena.deinit();
        gpa.destroy(s);
    }

    fn count(s: *const Snapshot, comptime pred: fn (git_mod.Entry) bool) usize {
        var n: usize = 0;
        for (s.status.entries) |e| if (pred(e)) {
            n += 1;
        };
        return n;
    }
};

fn isConflict(e: git_mod.Entry) bool {
    return e.kind == .conflict;
}
fn isStaged(e: git_mod.Entry) bool {
    return e.staged();
}
fn isUnstaged(e: git_mod.Entry) bool {
    return e.unstaged();
}
fn isUntracked(e: git_mod.Entry) bool {
    return e.kind == .untracked;
}

/// Work for a thread.
const Job = struct {
    panel: *ScmPanel,
    kind: Kind,
    arena: std.heap.ArenaAllocator,
    /// Commands run in order (stopping at the first failure).
    cmds: []const []const []const u8 = &.{},
    label: []const u8 = "",
    /// What to do when the commands succeed.
    after: After = .none,
    /// The detail request this answers (stale ones are dropped).
    gen: u64 = 0,
    log_limit: u32 = 500,
    log_all: bool = false,
    thread: ?std.Thread = null,
    // Results.
    snap: ?*Snapshot = null,
    code: u8 = 0,
    out: std.ArrayList(u8) = .empty,
    failed_cmd: usize = 0,

    const Kind = enum { refresh, op, detail };
    const After = enum { none, clear_message, relocate };

    fn run(job: *Job) void {
        const p = job.panel;
        switch (job.kind) {
            .refresh => job.snap = readSnapshot(p.gpa, &p.git, job.log_limit, job.log_all) catch null,
            .op, .detail => job.runCmds(),
        }
        if (p.rt) |rt| rt.post(.{ .kind = msg_kind, .a = @intFromPtr(job) }) catch {};
    }

    fn runCmds(job: *Job) void {
        const p = job.panel;
        const a = job.arena.allocator();
        for (job.cmds, 0..) |args, i| {
            const r = p.git.run(p.gpa, args) catch {
                job.code = 255;
                job.failed_cmd = i;
                return;
            };
            defer r.deinit(p.gpa);
            if (job.kind == .op) {
                job.out.appendSlice(a, "$ git") catch {};
                for (args) |x| {
                    job.out.append(a, ' ') catch {};
                    job.out.appendSlice(a, x) catch {};
                }
                job.out.append(a, '\n') catch {};
            }
            job.out.appendSlice(a, r.out) catch {};
            job.out.appendSlice(a, r.err) catch {};
            job.code = r.code;
            // `git diff --no-index` exits 1 when the files differ.
            if (r.code != 0 and job.kind == .op) {
                job.failed_cmd = i;
                return;
            }
        }
    }
};

/// Reads everything the pages show (worker thread).
fn readSnapshot(gpa: Allocator, g: *const Git, log_limit: u32, log_all: bool) !*Snapshot {
    const s = try gpa.create(Snapshot);
    s.* = .{ .arena = .init(gpa) };
    errdefer s.destroy(gpa);
    const a = s.arena.allocator();
    s.repo = g.isRepo();
    if (!s.repo) return s;
    s.op = g.operation();
    s.status = g.status(a) catch |e| {
        s.problem = @errorName(e);
        return s;
    };
    if (s.status.oid != null) s.log = g.log(a, log_limit, log_all) catch &.{};
    s.branches = g.branches(a) catch &.{};
    s.tags = g.tags(a) catch &.{};
    s.stashes = g.stashes(a) catch &.{};
    s.remotes = g.remotes(a) catch &.{};
    s.submodules = g.submodules(a) catch &.{};
    return s;
}

/// See the module doc.
pub const ScmPanel = struct {
    gpa: Allocator,
    io: std.Io,
    rt: ?*zg_core.Runtime,
    win: ?*Window = null,
    git: Git,
    hooks: Hooks,
    snap: ?*Snapshot = null,
    tab: Tab = .changes,
    /// Jobs on threads (joined when their message arrives, or at deinit).
    jobs: std.ArrayList(*Job) = .empty,
    /// Jobs waiting for the next build (no runtime: tests).
    queued: std.ArrayList(*Job) = .empty,
    refreshing: bool = false,
    refresh_again: bool = false,
    /// The running command's label (one at a time).
    busy: ?[]u8 = null,
    relocate_pending: bool = false,
    // Selection: a path (Changes, with `sel_staged`), a hash or a name.
    sel: std.ArrayList(u8) = .empty,
    sel_staged: bool = false,
    // The detail pane.
    detail: std.ArrayList(u8) = .empty,
    detail_lines: std.ArrayList([2]u32) = .empty,
    detail_title: std.ArrayList(u8) = .empty,
    detail_gen: u64 = 0,
    // Inputs.
    message: zg_gui.w.TextBuffer,
    amend: bool = false,
    command: zg_gui.w.TextBuffer,
    prompt: ?Prompt = null,
    prompt_buf: zg_gui.w.TextBuffer,
    prompt_node: zg_gui.core.NodeId = .none,
    focus_prompt: bool = false,
    /// A command waiting for its confirmation.
    confirming: ?*Job = null,
    output: std.ArrayList(u8) = .empty,
    /// The last outcome under the header.
    note: std.ArrayList(u8) = .empty,
    note_bad: bool = false,
    // Settings.
    log_limit: u32 = 500,
    log_all: bool = false,
    confirm_sync: bool = true,
    /// When the last refresh started (`poll`).
    last_refresh_ms: u64 = 0,

    const Prompt = struct {
        arena: std.heap.ArenaAllocator,
        label: []const u8,
        /// The command; "{}" takes the typed text, "{*}" its words.
        template: []const []const u8,
        after: Job.After = .none,
    };

    pub fn create(gpa: Allocator, io: std.Io, rt: ?*zg_core.Runtime, env: ?*const std.process.Environ.Map, dir: []const u8, hooks: Hooks) !*ScmPanel {
        const p = try gpa.create(ScmPanel);
        errdefer gpa.destroy(p);
        var g = try Git.init(gpa, io, rt, env, dir);
        errdefer g.deinit();
        p.* = .{
            .gpa = gpa,
            .io = io,
            .rt = rt,
            .git = g,
            .hooks = hooks,
            .message = try .init(gpa, ""),
            .command = try .init(gpa, ""),
            .prompt_buf = try .init(gpa, ""),
        };
        return p;
    }

    pub fn destroy(p: *ScmPanel) void {
        for (p.jobs.items) |j| {
            if (j.thread) |t| t.join();
            p.freeJob(j);
        }
        p.jobs.deinit(p.gpa);
        p.queued.deinit(p.gpa);
        if (p.confirming) |j| p.freeJob(j);
        if (p.snap) |s| s.destroy(p.gpa);
        if (p.busy) |b| p.gpa.free(b);
        p.closePromptState();
        p.sel.deinit(p.gpa);
        p.detail.deinit(p.gpa);
        p.detail_lines.deinit(p.gpa);
        p.detail_title.deinit(p.gpa);
        p.message.deinit();
        p.command.deinit();
        p.prompt_buf.deinit();
        p.output.deinit(p.gpa);
        p.note.deinit(p.gpa);
        p.git.deinit();
        p.gpa.destroy(p);
    }

    fn freeJob(p: *ScmPanel, j: *Job) void {
        if (j.snap) |s| s.destroy(p.gpa);
        j.arena.deinit();
        p.gpa.destroy(j);
    }

    fn markDirty(p: *ScmPanel) void {
        if (p.win) |w| w.markAllDirty();
    }

    fn say(p: *ScmPanel, bad: bool, comptime fmt: []const u8, args: anytype) void {
        p.note.clearRetainingCapacity();
        p.note.print(p.gpa, fmt, args) catch {};
        p.note_bad = bad;
        p.markDirty();
    }

    // -- jobs ---------------------------------------------------------------

    fn newJob(p: *ScmPanel, kind: Job.Kind) !*Job {
        const j = try p.gpa.create(Job);
        j.* = .{ .panel = p, .kind = kind, .arena = .init(p.gpa), .log_limit = p.log_limit, .log_all = p.log_all };
        return j;
    }

    /// Copies `cmds` into `j`.
    fn setCmds(j: *Job, cmds: []const []const []const u8) !void {
        const a = j.arena.allocator();
        const out = try a.alloc([]const []const u8, cmds.len);
        for (cmds, out) |c, *o| {
            const args = try a.alloc([]const u8, c.len);
            for (c, args) |x, *y| y.* = try a.dupe(u8, x);
            o.* = args;
        }
        j.cmds = out;
    }

    fn start(p: *ScmPanel, j: *Job) void {
        p.jobs.append(p.gpa, j) catch {
            p.freeJob(j);
            return;
        };
        if (p.rt == null) {
            // No mailbox (tests): run at the next build, before it reads
            // the snapshot (a job run in the middle of a build would free
            // the snapshot the build is drawing).
            p.queued.append(p.gpa, j) catch {
                j.run();
                p.finish(j);
                return;
            };
            p.markDirty();
            return;
        }
        j.thread = std.Thread.spawn(.{}, Job.run, .{j}) catch {
            j.run();
            p.finish(j);
            return;
        };
    }

    /// A job's mailbox message (UI thread).
    pub fn handleMessage(p: *ScmPanel, msg: zg_core.runtime.UiMsg) bool {
        if (msg.kind != msg_kind) return false;
        for (p.jobs.items) |j| if (@intFromPtr(j) == msg.a) {
            if (j.thread) |t| t.join();
            j.thread = null;
            p.finish(j);
            return true;
        };
        return false;
    }

    fn finish(p: *ScmPanel, j: *Job) void {
        for (p.jobs.items, 0..) |x, i| if (x == j) {
            _ = p.jobs.swapRemove(i);
            break;
        };
        defer p.freeJob(j);
        switch (j.kind) {
            .refresh => {
                p.refreshing = false;
                if (j.snap) |s| {
                    if (p.snap) |old| old.destroy(p.gpa);
                    p.snap = s;
                    j.snap = null;
                }
                if (p.refresh_again) {
                    p.refresh_again = false;
                    p.refresh();
                }
            },
            .detail => {
                if (j.gen != p.detail_gen) return;
                p.setDetail(j.out.items);
            },
            .op => {
                if (p.busy) |b| p.gpa.free(b);
                p.busy = null;
                p.appendOutput(j.out.items);
                if (j.code == 0) {
                    p.say(false, "{s}: done", .{j.label});
                    p.openAfter(j.cmds);
                    switch (j.after) {
                        .none => {},
                        .clear_message => {
                            p.message.setText("") catch {};
                            p.amend = false;
                        },
                        .relocate => p.relocate_pending = true,
                    }
                } else {
                    const text = std.mem.trim(u8, lastLines(j.out.items, 3), " \r\n");
                    p.say(true, "{s} failed: {s}", .{ j.label, text });
                }
                // Command output also shows in the detail pane.
                if (p.tab == .output or j.code != 0) p.setDetailTitled("Output", j.out.items);
                if (p.relocate_pending and p.jobs.items.len == 0) {
                    p.relocate_pending = false;
                    p.git.locate();
                }
                p.refresh();
                if (p.hooks.changed) |f| f(p.hooks.ctx);
            },
        }
        p.markDirty();
    }

    /// Opens a file in the repository folder in the editor.
    fn openGitFile(p: *ScmPanel, name: []const u8) void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = p.git.gitPath(&buf, name) orelse return;
        p.hooks.open(p.hooks.ctx, path);
    }

    /// `rebase -i <upstream>` and `rebase --edit-todo` open what they
    /// leave to edit, as git opens its editor.
    fn openAfter(p: *ScmPanel, cmds: []const []const []const u8) void {
        for (cmds) |words| {
            if (words.len == 0 or !std.mem.eql(u8, words[0], "rebase")) continue;
            var interactive = false;
            var other = false;
            for (words[1..]) |w| {
                if (std.mem.eql(u8, w, "--edit-todo")) return p.openGitFile("rebase-merge" ++ std.fs.path.sep_str ++ "git-rebase-todo");
                if (std.mem.eql(u8, w, "-i") or std.mem.eql(u8, w, "--interactive")) interactive = true;
                if (std.mem.eql(u8, w, "--start") or std.mem.eql(u8, w, "--cancel")) other = true;
            }
            if (interactive and !other) return p.openGitFile(git_mod.plan_file);
        }
    }

    fn appendOutput(p: *ScmPanel, text: []const u8) void {
        p.output.appendSlice(p.gpa, text) catch {};
        if (text.len > 0 and text[text.len - 1] != '\n') p.output.append(p.gpa, '\n') catch {};
        // Keep the last 256 KiB.
        const cap = 256 << 10;
        if (p.output.items.len > cap) {
            const cut = p.output.items.len - cap;
            const nl = std.mem.indexOfScalarPos(u8, p.output.items, cut, '\n') orelse cut;
            p.output.replaceRangeAssumeCapacity(0, nl + 1, &.{});
        }
    }

    /// Reads status, history and refs again (coalesced).
    pub fn refresh(p: *ScmPanel) void {
        if (p.refreshing) {
            p.refresh_again = true;
            return;
        }
        const j = p.newJob(.refresh) catch return;
        p.refreshing = true;
        p.last_refresh_ms = if (p.win) |w| w.app.now_ms else 0;
        p.start(j);
    }

    /// Refreshes every `interval_ms` (`git.autoRefresh`; the host's poll).
    pub fn poll(p: *ScmPanel, now_ms: u64, interval_ms: u64) void {
        if (now_ms -| p.last_refresh_ms < interval_ms) return;
        if (p.busy != null) return;
        p.refresh();
    }

    /// Fetches every remote (`git.autofetch`, or the command); nothing
    /// while another command runs or without remotes.
    pub fn fetch(p: *ScmPanel) void {
        const s = p.snap orelse return;
        if (p.busy != null or s.remotes.len == 0) return;
        p.run("Fetch", &.{&.{ "fetch", "--all", "--prune" }});
    }

    /// Runs `cmds` (one command at a time), then refreshes.
    pub fn run(p: *ScmPanel, label: []const u8, cmds: []const []const []const u8) void {
        p.runAfter(label, cmds, .none);
    }

    fn runAfter(p: *ScmPanel, label: []const u8, cmds: []const []const []const u8, after: Job.After) void {
        const j = p.opJob(label, cmds, after) orelse return;
        p.startOp(j);
    }

    fn opJob(p: *ScmPanel, label: []const u8, cmds: []const []const []const u8, after: Job.After) ?*Job {
        const j = p.newJob(.op) catch return null;
        setCmds(j, cmds) catch {
            p.freeJob(j);
            return null;
        };
        j.label = j.arena.allocator().dupe(u8, label) catch "git";
        j.after = after;
        return j;
    }

    fn startOp(p: *ScmPanel, j: *Job) void {
        if (p.busy != null) {
            p.say(true, "Wait for {s} to finish", .{p.busy.?});
            p.freeJob(j);
            return;
        }
        p.busy = p.gpa.dupe(u8, j.label) catch null;
        p.say(false, "Running {s}\u{2026}", .{j.label});
        p.start(j);
    }

    /// Runs `cmds` after the user confirms `message`.
    fn confirmRun(p: *ScmPanel, title: []const u8, message: []const u8, ok: []const u8, danger: bool, label: []const u8, cmds: []const []const []const u8) void {
        const w = p.win orelse return;
        const j = p.opJob(label, cmds, .none) orelse return;
        if (p.confirming) |old| p.freeJob(old);
        p.confirming = j;
        _ = zg_gui.w.confirm(w, .{ .title = title, .message = message, .ok_label = ok, .danger = danger }, .{ .ctx = p, .f = onConfirm }) catch {
            p.confirming = null;
            p.freeJob(j);
        };
    }

    fn onConfirm(ctx: ?*anyopaque, r: zg_gui.w.dialog.Result) void {
        const p: *ScmPanel = @ptrCast(@alignCast(ctx.?));
        const j = p.confirming orelse return;
        p.confirming = null;
        if (r == .ok) p.startOp(j) else p.freeJob(j);
        p.markDirty();
    }

    /// Shows `git <args>`'s output in the detail pane.
    fn showDetail(p: *ScmPanel, title: []const u8, args: []const []const u8) void {
        p.detail_gen +%= 1;
        p.detail_title.clearRetainingCapacity();
        p.detail_title.appendSlice(p.gpa, title) catch {};
        p.setDetail("Loading\u{2026}");
        const j = p.newJob(.detail) catch return;
        setCmds(j, &.{args}) catch {
            p.freeJob(j);
            return;
        };
        j.gen = p.detail_gen;
        p.start(j);
    }

    fn setDetailTitled(p: *ScmPanel, title: []const u8, text: []const u8) void {
        p.detail_gen +%= 1;
        p.detail_title.clearRetainingCapacity();
        p.detail_title.appendSlice(p.gpa, title) catch {};
        p.setDetail(text);
    }

    fn setDetail(p: *ScmPanel, text: []const u8) void {
        p.detail.clearRetainingCapacity();
        p.detail_lines.clearRetainingCapacity();
        // At most 1 MiB and 20 000 lines.
        const t = text[0..@min(text.len, 1 << 20)];
        p.detail.appendSlice(p.gpa, t) catch return;
        var start_i: usize = 0;
        while (start_i < p.detail.items.len and p.detail_lines.items.len < 20_000) {
            const end = std.mem.indexOfScalarPos(u8, p.detail.items, start_i, '\n') orelse p.detail.items.len;
            p.detail_lines.append(p.gpa, .{ @intCast(start_i), @intCast(end) }) catch return;
            start_i = end + 1;
        }
        p.markDirty();
    }

    fn select(p: *ScmPanel, key: []const u8, staged: bool) void {
        p.sel.clearRetainingCapacity();
        p.sel.appendSlice(p.gpa, key) catch {};
        p.sel_staged = staged;
        p.markDirty();
    }

    fn isSel(p: *const ScmPanel, key: []const u8, staged: bool) bool {
        return std.mem.eql(u8, p.sel.items, key) and p.sel_staged == staged;
    }

    fn absPath(p: *ScmPanel, rel: []const u8) ?[]u8 {
        return std.fs.path.join(p.gpa, &.{ p.git.root, rel }) catch null;
    }

    // -- prompts --------------------------------------------------------------

    fn ask(p: *ScmPanel, label: []const u8, initial: []const u8, template: []const []const u8, after: Job.After) void {
        p.closePromptState();
        var arena: std.heap.ArenaAllocator = .init(p.gpa);
        const a = arena.allocator();
        const t = a.alloc([]const u8, template.len) catch {
            arena.deinit();
            return;
        };
        for (template, t) |x, *y| y.* = a.dupe(u8, x) catch "";
        p.prompt = .{ .arena = arena, .label = a.dupe(u8, label) catch "", .template = t, .after = after };
        p.prompt_buf.setText(initial) catch {};
        p.focus_prompt = true;
        p.markDirty();
    }

    fn closePromptState(p: *ScmPanel) void {
        if (p.prompt) |*pr| pr.arena.deinit();
        p.prompt = null;
    }

    fn submitPrompt(p: *ScmPanel) void {
        const pr = p.prompt orelse return;
        const text = std.mem.trim(u8, p.prompt_buf.slice(), " \t\r\n");
        if (text.len == 0) return;
        var arena: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var args: std.ArrayList([]const u8) = .empty;
        for (pr.template) |t| {
            if (std.mem.eql(u8, t, "{}")) {
                args.append(a, text) catch return;
            } else if (std.mem.eql(u8, t, "{*}")) {
                const words = git_mod.splitArgs(a, text) catch return;
                args.appendSlice(a, words) catch return;
            } else args.append(a, t) catch return;
        }
        const label = std.fmt.allocPrint(a, "git {s}", .{pr.template[0]}) catch "git";
        p.runAfter(label, &.{args.items}, pr.after);
        p.closePromptState();
        p.markDirty();
    }

    // -- building ---------------------------------------------------------------

    pub fn build(p: *ScmPanel, ui: *Ui) void {
        p.win = ui.window();
        while (p.queued.items.len > 0) {
            const j = p.queued.orderedRemove(0);
            j.run();
            p.finish(j);
        }
        if (p.snap == null and !p.refreshing) p.refresh();
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } }, .role = .group, .label = "Git" });
        defer ui.close();
        p.header(ui);
        const snap = p.snap orelse {
            ui.open(.{ .style = .{ .padding = .xy(16, 12) } });
            ui.text("Reading the repository\u{2026}", .{ .color = .fg_muted });
            ui.close();
            return;
        };
        if (!snap.repo) return p.noRepo(ui);
        if (snap.op != .none) p.opBanner(ui, snap);
        if (p.prompt != null) p.promptRow(ui);
        p.tabs(ui, snap);
        ui.open(.{ .style = .{ .dir = .row, .grow = 1, .basis = .{ .px = 0 }, .align_items = .stretch } });
        defer ui.close();
        ui.open(.{ .style = .{ .dir = .column, .w = .{ .pct = 45 }, .shrink = 0, .border = .{ .token = .border }, .border_w = 1 } });
        switch (p.tab) {
            .changes => p.changesPage(ui, snap),
            .history => p.historyPage(ui, snap),
            .branches => p.branchesPage(ui, snap),
            .stashes => p.stashesPage(ui, snap),
            .tags => p.tagsPage(ui, snap),
            .remotes => p.remotesPage(ui, snap),
            .submodules => p.submodulesPage(ui, snap),
            .output => p.outputPage(ui),
        }
        ui.close();
        p.detailPane(ui);
    }

    fn header(p: *ScmPanel, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .column, .gap = 4, .padding = .xy(12, 6), .shrink = 0, .bg = .{ .token = .bg_elevated } } });
        defer ui.close();
        ui.open(.{ .style = .{ .dir = .row, .align_items = .center, .gap = 6, .wrap = true } });
        ui.text("Git", .{ .style = .{ .size = 16, .weight = 600 }, .theme_size = false, .wrap = false });
        var bb: [256]u8 = undefined;
        if (p.snap) |s| if (s.repo) {
            const st = s.status;
            const head = if (st.branch) |b| b else if (st.oid) |o| o[0..@min(8, o.len)] else "(no commits)";
            const txt = if (st.upstream) |u|
                std.fmt.bufPrint(&bb, "\u{2387} {s}{s}  \u{2192} {s}  \u{2191}{d} \u{2193}{d}", .{ if (st.branch == null) "detached at " else "", head, u, st.ahead, st.behind }) catch head
            else
                std.fmt.bufPrint(&bb, "\u{2387} {s}{s}  (no upstream)", .{ if (st.branch == null) "detached at " else "", head }) catch head;
            ui.text(txt, .{ .wrap = false });
        };
        ui.text(p.git.root, .{ .color = .fg_muted, .wrap = false });
        ui.open(.{ .style = .{ .grow = 1 } });
        ui.close();
        const repo = if (p.snap) |s| s.repo else false;
        if (zg_gui.w.button(ui, .{ .label = "Refresh", .variant = .ghost }).clicked) p.refresh();
        if (repo) {
            if (zg_gui.w.button(ui, .{ .label = "Fetch", .variant = .ghost }).clicked) p.run("Fetch", &.{&.{ "fetch", "--all", "--prune" }});
            if (zg_gui.w.button(ui, .{ .label = "Pull", .variant = .ghost }).clicked) p.syncCmd(.pull);
            if (zg_gui.w.button(ui, .{ .label = "Push", .variant = .ghost }).clicked) p.syncCmd(.push);
            if (zg_gui.w.button(ui, .{ .label = "Sync", .variant = .ghost }).clicked) p.syncCmd(.sync);
        }
        ui.close();
        // Any command line.
        ui.open(.{ .style = .{ .dir = .row, .align_items = .center, .gap = 6 } });
        ui.text("git", .{ .color = .fg_muted, .wrap = false, .style = .{ .font = .mono } });
        ui.open(.{ .style = .{ .grow = 1 } });
        const r = zg_gui.w.textField(ui, .{ .buffer = &p.command, .font = .mono, .placeholder = "any git command, e.g. log --graph --oneline, bisect start, worktree add ../wt", .a11y_label = "Git command" });
        ui.close();
        const go = zg_gui.w.button(ui, .{ .label = "Run" }).clicked;
        if (r.submitted or go) p.runTyped();
        ui.close();
        if (p.busy) |b| {
            var lb: [160]u8 = undefined;
            ui.text(std.fmt.bufPrint(&lb, "Running {s}\u{2026}", .{b}) catch "Running\u{2026}", .{ .color = .info, .wrap = false });
        } else if (p.note.items.len > 0) ui.text(p.note.items, .{ .color = if (p.note_bad) .danger else .fg_muted });
        if (p.snap) |s| if (s.problem.len > 0) ui.text(s.problem, .{ .color = .danger });
    }

    /// Runs the command box's line.
    fn runTyped(p: *ScmPanel) void {
        var arena: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena.deinit();
        const args = git_mod.splitArgs(arena.allocator(), p.command.slice()) catch return;
        if (args.len == 0) return;
        const label = std.fmt.allocPrint(arena.allocator(), "git {s}", .{args[0]}) catch "git";
        const after: Job.After = if (std.mem.eql(u8, args[0], "init") or std.mem.eql(u8, args[0], "clone")) .relocate else .none;
        p.runAfter(label, &.{args}, after);
        p.command.setText("") catch {};
        // Its output shows next to the list.
        p.tab = .output;
    }

    pub const Sync = enum { pull, push, sync };

    /// Pull, push (publish without an upstream) or both, confirmed when
    /// `confirm_sync` is set.
    pub fn syncCmd(p: *ScmPanel, which: Sync) void {
        const s = p.snap orelse return;
        const st = s.status;
        // A branch without an upstream is published to the first remote.
        const publish = st.upstream == null and st.branch != null and s.remotes.len > 0;
        const push_args: []const []const u8 = if (publish) &.{ "push", "-u", s.remotes[0].name, st.branch.? } else &.{"push"};
        const label, const cmds: []const []const []const u8 = switch (which) {
            .pull => .{ "Pull", &.{&.{"pull"}} },
            .push => .{ if (publish) "Publish" else "Push", &.{push_args} },
            .sync => .{ "Sync", &.{ &.{"pull"}, push_args } },
        };
        if (!p.confirm_sync) return p.run(label, cmds);
        var mb: [300]u8 = undefined;
        const target = st.upstream orelse if (s.remotes.len > 0) s.remotes[0].name else "the remote";
        const msg = switch (which) {
            .pull => std.fmt.bufPrint(&mb, "Pull commits from {s} into {s}?", .{ target, st.branch orelse "HEAD" }),
            .push => std.fmt.bufPrint(&mb, "Push {s} to {s}?", .{ st.branch orelse "HEAD", target }),
            .sync => std.fmt.bufPrint(&mb, "Pull from and push to {s}?", .{target}),
        } catch "Continue?";
        p.confirmRun(label, msg, label, false, label, cmds);
    }

    fn noRepo(p: *ScmPanel, ui: *Ui) void {
        if (p.prompt != null) p.promptRow(ui);
        ui.open(.{ .style = .{ .dir = .column, .gap = 8, .padding = .xy(16, 12) } });
        defer ui.close();
        ui.text("This folder is not in a git repository.", .{});
        ui.open(.{ .style = .{ .dir = .row, .gap = 6 } });
        if (zg_gui.w.button(ui, .{ .label = "Initialize Repository", .variant = .primary }).clicked)
            p.runAfter("git init", &.{&.{"init"}}, .relocate);
        if (zg_gui.w.button(ui, .{ .label = "Clone Repository\u{2026}" }).clicked)
            p.ask("Clone: a URL, then optionally a folder (default: a new folder here)", "", &.{ "clone", "{*}" }, .none);
        ui.close();
        if (p.output.items.len > 0) ui.text(lastLines(p.output.items, 8), .{ .color = .fg_muted, .style = .{ .font = .mono } });
    }

    fn opBanner(p: *ScmPanel, ui: *Ui, s: *const Snapshot) void {
        ui.open(.{ .style = .{ .dir = .row, .align_items = .center, .gap = 8, .padding = .xy(12, 6), .shrink = 0, .bg = .{ .token = .bg_sunken } } });
        defer ui.close();
        const conflicts = s.count(isConflict);
        var bb: [200]u8 = undefined;
        const text = if (s.op == .rebase_plan)
            "Interactive rebase planned: edit the plan, save it, then Start."
        else if (s.op == .rebase and conflicts == 0)
            "Rebasing: stopped. Amend or commit what you need, then Continue."
        else
            std.fmt.bufPrint(&bb, "{s}: {d} conflict{s} left. Resolve them, stage the files, then Continue.", .{ s.op.label(), conflicts, if (conflicts == 1) "" else "s" }) catch s.op.label();
        ui.text(text, .{ .color = .warning });
        ui.open(.{ .style = .{ .grow = 1 } });
        ui.close();
        const cmd = s.op.command();
        if (s.op == .rebase_plan) {
            ui.id(4);
            if (zg_gui.w.button(ui, .{ .label = "Edit Plan" }).clicked) p.openGitFile(git_mod.plan_file);
            ui.id(5);
            if (zg_gui.w.button(ui, .{ .label = "Start", .variant = .primary }).clicked) p.run("Rebase", &.{&.{ "rebase", "-i", "--start" }});
            ui.id(6);
            if (zg_gui.w.button(ui, .{ .label = "Cancel", .variant = .ghost }).clicked) p.run("Cancel rebase plan", &.{&.{ "rebase", "-i", "--cancel" }});
            return;
        }
        if (s.op == .rebase) {
            ui.id(7);
            if (zg_gui.w.button(ui, .{ .label = "Edit Todo" }).clicked) p.openGitFile("rebase-merge" ++ std.fs.path.sep_str ++ "git-rebase-todo");
        }
        if (s.op == .bisect) {
            ui.id(1);
            if (zg_gui.w.button(ui, .{ .label = "Good" }).clicked) p.run("Bisect good", &.{&.{ "bisect", "good" }});
            ui.id(2);
            if (zg_gui.w.button(ui, .{ .label = "Bad" }).clicked) p.run("Bisect bad", &.{&.{ "bisect", "bad" }});
            ui.id(4);
            if (zg_gui.w.button(ui, .{ .label = "Run Command\u{2026}" }).clicked) p.ask("Command to test each commit (exit 0 good, 125 skip, 1-127 bad)", "", &.{ "bisect", "run", "{}" }, .none);
            ui.id(3);
            if (zg_gui.w.button(ui, .{ .label = "End Bisect" }).clicked) p.run("Bisect reset", &.{&.{ "bisect", "reset" }});
            return;
        }
        ui.id(1);
        if (zg_gui.w.button(ui, .{ .label = "Continue", .variant = .primary }).clicked) {
            // A merge continues by committing.
            if (s.op == .merge) p.run("Merge", &.{&.{ "commit", "--no-edit" }}) else p.run("Continue", &.{&.{ "-c", "core.editor=true", cmd, "--continue" }});
        }
        if (s.op == .rebase or s.op == .cherry_pick or s.op == .revert) {
            ui.id(2);
            if (zg_gui.w.button(ui, .{ .label = "Skip" }).clicked) p.run("Skip", &.{&.{ cmd, "--skip" }});
        }
        ui.id(3);
        if (zg_gui.w.button(ui, .{ .label = "Abort", .variant = .danger }).clicked) p.run("Abort", &.{&.{ cmd, "--abort" }});
    }

    fn promptRow(p: *ScmPanel, ui: *Ui) void {
        const pr = &p.prompt.?;
        ui.open(.{ .style = .{ .dir = .column, .gap = 4, .padding = .xy(12, 6), .shrink = 0, .bg = .{ .token = .bg_sunken } } });
        defer ui.close();
        ui.text(pr.label, .{ .color = .fg_muted });
        ui.open(.{ .style = .{ .dir = .row, .gap = 6, .align_items = .center } });
        defer ui.close();
        ui.open(.{ .style = .{ .grow = 1 } });
        const r = zg_gui.w.textField(ui, .{ .buffer = &p.prompt_buf, .a11y_label = pr.label });
        p.prompt_node = ui.lastNode();
        ui.close();
        if (p.focus_prompt) {
            p.focus_prompt = false;
            ui.window().afterNextFrame(.{ .ctx = p, .f = focusPrompt });
        }
        const ok = zg_gui.w.button(ui, .{ .label = "OK", .variant = .primary }).clicked;
        const cancel = zg_gui.w.button(ui, .{ .label = "Cancel", .variant = .ghost }).clicked;
        if (r.submitted or ok) p.submitPrompt() else if (r.cancelled or cancel) {
            p.closePromptState();
            p.markDirty();
        }
    }

    fn focusPrompt(ctx: *anyopaque, w: *Window) void {
        const p: *ScmPanel = @ptrCast(@alignCast(ctx));
        if (!p.prompt_node.isNone() and w.store.valid(p.prompt_node)) w.setFocus(p.prompt_node, true);
    }

    fn tabs(p: *ScmPanel, ui: *Ui, s: *const Snapshot) void {
        ui.open(.{ .style = .{ .dir = .row, .gap = 2, .padding = .xy(8, 4), .shrink = 0, .wrap = true }, .role = .tablist, .label = "Git pages" });
        defer ui.close();
        inline for (std.meta.fields(Tab)) |f| {
            const t: Tab = @enumFromInt(f.value);
            var lb: [48]u8 = undefined;
            const n: usize = switch (t) {
                .changes => s.status.entries.len,
                .stashes => s.stashes.len,
                .tags => s.tags.len,
                .remotes => s.remotes.len,
                .submodules => s.submodules.len,
                else => 0,
            };
            const label = if (n > 0) std.fmt.bufPrint(&lb, "{s} ({d})", .{ t.title(), n }) catch t.title() else t.title();
            ui.id(f.value);
            if (zg_gui.w.button(ui, .{ .label = label, .variant = if (p.tab == t) .primary else .ghost }).clicked) {
                p.tab = t;
                if (t == .output) p.setDetailTitled("Output", p.output.items);
                p.markDirty();
            }
        }
    }

    /// A row of small action buttons.
    fn actions(ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .row, .gap = 4, .padding = .xy(8, 4), .wrap = true, .shrink = 0 } });
    }

    fn sectionTitle(ui: *Ui, text: []const u8) void {
        ui.open(.{ .style = .{ .dir = .row, .align_items = .center, .padding = .{ .l = 8, .t = 8, .b = 2 }, .gap = 6, .shrink = 0 } });
        ui.text(text, .{ .color = .fg_muted, .wrap = false, .style = .{ .weight = 600 } });
    }

    /// A selectable row; returns its response.
    fn rowOpen(ui: *Ui, selected: bool, label: []const u8) zg_gui.Response {
        ui.open(.{ .style = .{ .dir = .row, .w = .{ .pct = 100 }, .align_items = .center, .gap = 6, .padding = .xy(8, 2), .h = .{ .px = 24 }, .shrink = 0, .bg = if (selected) .{ .token = .selection_bg } else .none }, .hit = true, .role = .listitem, .label = label });
        return ui.response();
    }

    // -- Changes ----------------------------------------------------------------

    fn changesPage(p: *ScmPanel, ui: *Ui, s: *const Snapshot) void {
        // The commit box.
        ui.open(.{ .style = .{ .dir = .column, .gap = 4, .padding = .xy(8, 6), .shrink = 0 } });
        _ = zg_gui.w.textField(ui, .{ .buffer = &p.message, .multiline = true, .min_rows = 2, .max_rows = 6, .submit_on_enter = false, .placeholder = "Commit message (Ctrl+Enter commits)", .a11y_label = "Commit message" });
        const submitted = ui.response().submitted;
        ui.open(.{ .style = .{ .dir = .row, .gap = 6, .align_items = .center } });
        const staged = s.count(isStaged);
        const changed = s.count(isUnstaged);
        const commit = zg_gui.w.button(ui, .{ .label = if (p.amend) "Amend Commit" else "Commit", .variant = .primary, .disabled = staged == 0 and !p.amend }).clicked;
        const commit_all = zg_gui.w.button(ui, .{ .label = "Commit All", .disabled = staged + changed == 0 }).clicked;
        _ = zg_gui.w.checkbox(ui, "Amend", &p.amend);
        ui.close();
        ui.close();
        if (commit or commit_all or submitted) p.commitNow(commit_all or (submitted and staged == 0));

        _ = zg_gui.w.scrollArea(ui, .{ .style = .{ .grow = 1, .basis = .{ .px = 0 }, .dir = .column } });
        defer ui.close();
        const conflicts = s.count(isConflict);
        if (conflicts > 0) {
            sectionTitle(ui, "Merge Conflicts");
            ui.close();
            for (s.status.entries, 0..) |e, i| if (e.kind == .conflict) {
                ui.id(0x10000 + i);
                p.changeRow(ui, e, false);
            };
        }
        sectionTitle(ui, "Staged Changes");
        if (staged > 0) {
            ui.id(1);
            if (zg_gui.w.button(ui, .{ .label = "Unstage All", .variant = .ghost }).clicked) p.unstageAll(s);
        }
        ui.close();
        for (s.status.entries, 0..) |e, i| if (e.staged()) {
            ui.id(0x20000 + i);
            p.changeRow(ui, e, true);
        };
        sectionTitle(ui, "Changes");
        if (changed > 0) {
            ui.id(2);
            if (zg_gui.w.button(ui, .{ .label = "Stage All", .variant = .ghost }).clicked) p.run("Stage all", &.{&.{ "add", "-u" }});
            ui.id(3);
            if (zg_gui.w.button(ui, .{ .label = "Discard All", .variant = .ghost }).clicked)
                p.confirmRun("Discard All Changes", "Discard every change to tracked files? This cannot be undone.", "Discard", true, "Discard all", &.{&.{ "checkout", "--", "." }});
        }
        ui.close();
        for (s.status.entries, 0..) |e, i| if (e.unstaged()) {
            ui.id(0x30000 + i);
            p.changeRow(ui, e, false);
        };
        const untracked = s.count(isUntracked);
        sectionTitle(ui, "Untracked Files");
        if (untracked > 0) {
            ui.id(4);
            if (zg_gui.w.button(ui, .{ .label = "Stage All", .variant = .ghost }).clicked) p.run("Stage untracked", &.{&.{ "add", "-A", "--", "." }});
            ui.id(5);
            if (zg_gui.w.button(ui, .{ .label = "Delete All", .variant = .ghost }).clicked)
                p.confirmRun("Delete Untracked Files", "Delete every untracked file (git clean -fd)? This cannot be undone.", "Delete", true, "Clean", &.{&.{ "clean", "-fd" }});
        }
        ui.close();
        for (s.status.entries, 0..) |e, i| if (e.kind == .untracked) {
            ui.id(0x40000 + i);
            p.changeRow(ui, e, false);
        };
        if (s.status.entries.len == 0) {
            ui.open(.{ .style = .{ .padding = .xy(8, 8) } });
            ui.text("No changes: the working tree matches HEAD.", .{ .color = .fg_muted });
            ui.close();
        }
    }

    /// Commits the staged changes (`all`: every tracked change) with the
    /// message box's text, amending when Amend is ticked.
    pub fn commitNow(p: *ScmPanel, all: bool) void {
        const msg = std.mem.trim(u8, p.message.slice(), " \t\r\n");
        if (msg.len == 0 and !p.amend) return p.say(true, "Write a commit message first", .{});
        var args: [6][]const u8 = undefined;
        var n: usize = 0;
        args[n] = "commit";
        n += 1;
        if (all) {
            args[n] = "-a";
            n += 1;
        }
        if (p.amend) {
            args[n] = "--amend";
            n += 1;
        }
        if (msg.len > 0) {
            args[n] = "-m";
            args[n + 1] = msg;
            n += 2;
        } else {
            args[n] = "--no-edit";
            n += 1;
        }
        p.runAfter(if (p.amend) "Amend" else "Commit", &.{args[0..n]}, .clear_message);
    }

    fn unstageAll(p: *ScmPanel, s: *const Snapshot) void {
        // Before the first commit there is no HEAD to reset to.
        if (s.status.oid == null) p.run("Unstage all", &.{&.{ "rm", "-r", "-q", "--cached", "--", "." }}) else p.run("Unstage all", &.{&.{ "reset", "-q" }});
    }

    fn changeRow(p: *ScmPanel, ui: *Ui, e: git_mod.Entry, staged: bool) void {
        const sel = p.isSel(e.path, staged);
        const r = rowOpen(ui, sel, e.path);
        defer ui.close();
        const letter: u8 = switch (e.kind) {
            .untracked => 'U',
            .conflict => '!',
            else => if (staged) e.x else e.y,
        };
        const color: zg_gui.theme.tokens.Token = switch (letter) {
            'A', 'U' => .success,
            'D', '!' => .danger,
            'M', 'R', 'C', 'T' => .warning,
            else => .fg_muted,
        };
        var lb: [2]u8 = .{ letter, 0 };
        ui.open(.{ .style = .{ .w = .{ .px = 14 }, .shrink = 0 } });
        ui.text(lb[0..1], .{ .color = color, .wrap = false, .style = .{ .font = .mono, .weight = 600 } });
        ui.close();
        const base = std.fs.path.basename(e.path);
        ui.text(base, .{ .wrap = false });
        const dir = std.fs.path.dirname(e.path) orelse "";
        var db: [512]u8 = undefined;
        if (e.orig) |o| {
            ui.text(std.fmt.bufPrint(&db, "\u{2190} {s}", .{o}) catch o, .{ .color = .fg_muted, .wrap = false });
        } else if (dir.len > 0) ui.text(dir, .{ .color = .fg_muted, .wrap = false });
        ui.open(.{ .style = .{ .grow = 1 } });
        ui.close();
        if (r.clicked) {
            p.select(e.path, staged);
            p.showChange(e, staged);
        }
        if (r.double_clicked) if (p.absPath(e.path)) |abs| {
            defer p.gpa.free(abs);
            p.hooks.open(p.hooks.ctx, abs);
        };
        const path = e.path;
        switch (e.kind) {
            .conflict => {
                ui.id(1);
                if (zg_gui.w.button(ui, .{ .label = "Ours", .variant = .ghost }).clicked)
                    p.run("Take ours", &.{ &.{ "checkout", "--ours", "--", path }, &.{ "add", "--", path } });
                ui.id(2);
                if (zg_gui.w.button(ui, .{ .label = "Theirs", .variant = .ghost }).clicked)
                    p.run("Take theirs", &.{ &.{ "checkout", "--theirs", "--", path }, &.{ "add", "--", path } });
                ui.id(3);
                if (zg_gui.w.button(ui, .{ .label = "Resolved", .variant = .ghost }).clicked) p.run("Mark resolved", &.{&.{ "add", "--", path }});
            },
            .untracked => {
                ui.id(4);
                if (zg_gui.w.button(ui, .{ .label = "Delete", .variant = .ghost }).clicked) {
                    var mb: [600]u8 = undefined;
                    p.confirmRun("Delete File", std.fmt.bufPrint(&mb, "Delete untracked {s}? This cannot be undone.", .{path}) catch "Delete it?", "Delete", true, "Delete", &.{&.{ "clean", "-f", "--", path }});
                }
                ui.id(5);
                if (zg_gui.w.button(ui, .{ .label = "Stage", .variant = .ghost }).clicked) p.run("Stage", &.{&.{ "add", "--", path }});
            },
            else => if (staged) {
                ui.id(6);
                if (zg_gui.w.button(ui, .{ .label = "Unstage", .variant = .ghost }).clicked) {
                    if (p.snap != null and p.snap.?.status.oid == null)
                        p.run("Unstage", &.{&.{ "rm", "-q", "--cached", "--", path }})
                    else
                        p.run("Unstage", &.{&.{ "reset", "-q", "--", path }});
                }
            } else {
                ui.id(7);
                if (zg_gui.w.button(ui, .{ .label = "Discard", .variant = .ghost }).clicked) {
                    var mb: [600]u8 = undefined;
                    p.confirmRun("Discard Changes", std.fmt.bufPrint(&mb, "Discard your changes to {s}? This cannot be undone.", .{path}) catch "Discard?", "Discard", true, "Discard", &.{&.{ "checkout", "--", path }});
                }
                ui.id(8);
                if (zg_gui.w.button(ui, .{ .label = "Stage", .variant = .ghost }).clicked) p.run("Stage", &.{&.{ "add", "--", path }});
            },
        }
    }

    fn showChange(p: *ScmPanel, e: git_mod.Entry, staged: bool) void {
        if (e.kind == .untracked) {
            // The whole file is new.
            const abs = p.absPath(e.path) orelse return;
            defer p.gpa.free(abs);
            const bytes = std.Io.Dir.cwd().readFileAlloc(p.io, abs, p.gpa, .limited(1 << 20)) catch |err| {
                var b: [128]u8 = undefined;
                return p.setDetailTitled(e.path, std.fmt.bufPrint(&b, "Cannot read it: {t}", .{err}) catch "");
            };
            defer p.gpa.free(bytes);
            var text: std.ArrayList(u8) = .empty;
            defer text.deinit(p.gpa);
            text.print(p.gpa, "new file {s}\n", .{e.path}) catch return;
            var lines = std.mem.splitScalar(u8, bytes, '\n');
            while (lines.next()) |l| {
                text.append(p.gpa, '+') catch return;
                text.appendSlice(p.gpa, l) catch return;
                text.append(p.gpa, '\n') catch return;
            }
            return p.setDetailTitled(e.path, text.items);
        }
        if (staged) p.showDetail(e.path, &.{ "diff", "--cached", "--", e.path }) else p.showDetail(e.path, &.{ "diff", "--", e.path });
    }

    // -- History ----------------------------------------------------------------

    fn historyPage(p: *ScmPanel, ui: *Ui, s: *const Snapshot) void {
        actions(ui);
        var all = p.log_all;
        if (zg_gui.w.checkbox(ui, "All branches", &all).changed) {
            p.log_all = all;
            p.refresh();
        }
        const commit = p.selectedCommit(s);
        if (commit) |c| {
            ui.id(1);
            if (zg_gui.w.button(ui, .{ .label = "Checkout", .variant = .ghost }).clicked) {
                var mb: [200]u8 = undefined;
                p.confirmRun("Checkout Commit", std.fmt.bufPrint(&mb, "Check out {s}? HEAD will be detached.", .{c.short}) catch "", "Checkout", false, "Checkout", &.{&.{ "checkout", c.hash }});
            }
            ui.id(2);
            if (zg_gui.w.button(ui, .{ .label = "New Branch\u{2026}", .variant = .ghost }).clicked) p.ask("New branch at this commit (name)", "", &.{ "checkout", "-b", "{}", c.hash }, .none);
            ui.id(3);
            if (zg_gui.w.button(ui, .{ .label = "New Tag\u{2026}", .variant = .ghost }).clicked) p.ask("New tag at this commit (name)", "", &.{ "tag", "{}", c.hash }, .none);
            ui.id(4);
            if (zg_gui.w.button(ui, .{ .label = "Cherry-Pick", .variant = .ghost }).clicked) p.run("Cherry-pick", &.{&.{ "cherry-pick", c.hash }});
            ui.id(5);
            if (zg_gui.w.button(ui, .{ .label = "Revert", .variant = .ghost }).clicked) p.run("Revert", &.{&.{ "revert", "--no-edit", c.hash }});
            ui.id(10);
            if (zg_gui.w.button(ui, .{ .label = "Rebase After This\u{2026}", .variant = .ghost }).clicked) p.run("Plan rebase", &.{&.{ "rebase", "-i", c.hash }});
            ui.id(6);
            if (zg_gui.w.button(ui, .{ .label = "Reset Soft", .variant = .ghost }).clicked) p.run("Reset", &.{&.{ "reset", "--soft", c.hash }});
            ui.id(7);
            if (zg_gui.w.button(ui, .{ .label = "Reset Mixed", .variant = .ghost }).clicked) p.run("Reset", &.{&.{ "reset", "--mixed", c.hash }});
            ui.id(8);
            if (zg_gui.w.button(ui, .{ .label = "Reset Hard", .variant = .danger }).clicked) {
                var mb: [200]u8 = undefined;
                p.confirmRun("Reset Hard", std.fmt.bufPrint(&mb, "Reset the branch and working tree to {s}? Uncommitted changes are lost.", .{c.short}) catch "", "Reset", true, "Reset", &.{&.{ "reset", "--hard", c.hash }});
            }
            ui.id(9);
            if (zg_gui.w.button(ui, .{ .label = "Copy Hash", .variant = .ghost }).clicked) ui.window().app.clipboard.set(ui.window().gpa, c.hash);
        }
        ui.close();
        if (s.log.len == 0) {
            ui.text("No commits yet.", .{ .color = .fg_muted });
            return;
        }
        _ = zg_gui.w.virtualList(ui, .{ .count = s.log.len, .row_h = 24, .style = .{ .grow = 1, .basis = .{ .px = 0 } }, .test_id = "git-log" }, p, logRow);
    }

    fn selectedCommit(p: *ScmPanel, s: *const Snapshot) ?git_mod.Commit {
        for (s.log) |c| if (std.mem.eql(u8, c.hash, p.sel.items)) return c;
        return null;
    }

    fn logRow(p: *ScmPanel, ui: *Ui, i: usize) void {
        const s = p.snap orelse return;
        if (i >= s.log.len) return;
        const c = s.log[i];
        const r = rowOpen(ui, std.mem.eql(u8, p.sel.items, c.hash), c.subject);
        defer ui.close();
        ui.text(c.short, .{ .color = .fg_link, .wrap = false, .style = .{ .font = .mono } });
        if (c.refs.len > 0) {
            var rb: [200]u8 = undefined;
            ui.text(std.fmt.bufPrint(&rb, "({s})", .{c.refs}) catch c.refs, .{ .color = .warning, .wrap = false });
        }
        ui.open(.{ .style = .{ .grow = 1, .basis = .{ .px = 0 }, .clip = true } });
        ui.text(c.subject, .{ .wrap = false });
        ui.close();
        ui.text(c.author, .{ .color = .fg_muted, .wrap = false });
        ui.text(c.date, .{ .color = .fg_muted, .wrap = false });
        if (r.clicked) {
            p.select(c.hash, false);
            p.showDetail(c.short, &.{ "show", "--stat", "--patch", "--format=fuller", c.hash });
        }
    }

    // -- Branches ---------------------------------------------------------------

    fn branchesPage(p: *ScmPanel, ui: *Ui, s: *const Snapshot) void {
        const cur = s.status.branch;
        actions(ui);
        ui.id(1);
        if (zg_gui.w.button(ui, .{ .label = "New Branch\u{2026}", .variant = .ghost }).clicked) p.ask("New branch from HEAD (name); it is checked out", "", &.{ "checkout", "-b", "{}" }, .none);
        var sel_branch: ?git_mod.Branch = null;
        for (s.branches) |b| if (std.mem.eql(u8, b.name, p.sel.items)) {
            sel_branch = b;
        };
        if (sel_branch) |b| {
            ui.id(2);
            if (!b.head and zg_gui.w.button(ui, .{ .label = "Checkout", .variant = .ghost }).clicked) {
                if (b.remote) p.run("Checkout", &.{&.{ "checkout", "--track", b.name }}) else p.run("Checkout", &.{&.{ "checkout", b.name }});
            }
            if (!b.head and cur != null) {
                var lb: [160]u8 = undefined;
                ui.id(3);
                if (zg_gui.w.button(ui, .{ .label = std.fmt.bufPrint(&lb, "Merge into {s}", .{cur.?}) catch "Merge", .variant = .ghost }).clicked) p.run("Merge", &.{&.{ "merge", "--no-edit", b.name }});
                ui.id(4);
                if (zg_gui.w.button(ui, .{ .label = std.fmt.bufPrint(&lb, "Rebase {s} onto it", .{cur.?}) catch "Rebase", .variant = .ghost }).clicked) p.run("Rebase", &.{&.{ "rebase", b.name }});
                ui.id(10);
                if (zg_gui.w.button(ui, .{ .label = "Rebase Interactively\u{2026}", .variant = .ghost }).clicked) p.run("Plan rebase", &.{&.{ "rebase", "-i", b.name }});
            }
            if (!b.remote) {
                ui.id(5);
                if (zg_gui.w.button(ui, .{ .label = "Rename\u{2026}", .variant = .ghost }).clicked) p.ask("Rename the branch to", b.name, &.{ "branch", "-m", b.name, "{}" }, .none);
                if (s.remotes.len > 0) {
                    ui.id(6);
                    if (zg_gui.w.button(ui, .{ .label = if (b.upstream.len > 0) "Push" else "Publish", .variant = .ghost }).clicked)
                        p.run("Push", &.{&.{ "push", "-u", s.remotes[0].name, b.name }});
                }
                if (!b.head) {
                    var mb: [300]u8 = undefined;
                    ui.id(7);
                    if (zg_gui.w.button(ui, .{ .label = "Delete", .variant = .ghost }).clicked)
                        p.confirmRun("Delete Branch", std.fmt.bufPrint(&mb, "Delete branch {s}?", .{b.name}) catch "", "Delete", true, "Delete branch", &.{&.{ "branch", "-d", b.name }});
                    ui.id(8);
                    if (zg_gui.w.button(ui, .{ .label = "Force Delete", .variant = .danger }).clicked)
                        p.confirmRun("Force Delete Branch", std.fmt.bufPrint(&mb, "Delete branch {s} even though it is not merged? Its commits may be lost.", .{b.name}) catch "", "Delete", true, "Delete branch", &.{&.{ "branch", "-D", b.name }});
                }
            } else if (std.mem.indexOfScalar(u8, b.name, '/')) |slash| {
                var mb: [300]u8 = undefined;
                ui.id(9);
                if (zg_gui.w.button(ui, .{ .label = "Delete on Remote", .variant = .danger }).clicked)
                    p.confirmRun("Delete Remote Branch", std.fmt.bufPrint(&mb, "Delete {s} on the remote {s}?", .{ b.name[slash + 1 ..], b.name[0..slash] }) catch "", "Delete", true, "Delete remote branch", &.{&.{ "push", b.name[0..slash], "--delete", b.name[slash + 1 ..] }});
            }
        }
        ui.close();
        _ = zg_gui.w.scrollArea(ui, .{ .style = .{ .grow = 1, .basis = .{ .px = 0 }, .dir = .column } });
        defer ui.close();
        for ([_]bool{ false, true }) |remote| {
            sectionTitle(ui, if (remote) "Remote Branches" else "Local Branches");
            ui.close();
            for (s.branches, 0..) |b, i| if (b.remote == remote) {
                ui.id(0x1000 + i);
                const r = rowOpen(ui, std.mem.eql(u8, p.sel.items, b.name), b.name);
                ui.text(if (b.head) "\u{25cf}" else " ", .{ .color = .success, .wrap = false });
                ui.text(b.name, .{ .wrap = false, .style = .{ .weight = if (b.head) 600 else 400 } });
                if (b.track.len > 0) ui.text(b.track, .{ .color = .warning, .wrap = false });
                ui.text(b.subject, .{ .color = .fg_muted, .wrap = false });
                ui.close();
                if (r.clicked) {
                    p.select(b.name, false);
                    p.showDetail(b.name, &.{ "log", "--format=%h %ad %an%n    %s", "--date=short", "-n", "100", b.name });
                }
                if (r.double_clicked and !b.head and !b.remote) p.run("Checkout", &.{&.{ "checkout", b.name }});
            };
        }
    }

    // -- Stashes, tags, remotes, submodules -------------------------------------

    fn stashesPage(p: *ScmPanel, ui: *Ui, s: *const Snapshot) void {
        actions(ui);
        ui.id(1);
        if (zg_gui.w.button(ui, .{ .label = "Stash\u{2026}", .variant = .ghost }).clicked) p.ask("Stash the changes (message)", "WIP", &.{ "stash", "push", "-m", "{}" }, .none);
        ui.id(2);
        if (zg_gui.w.button(ui, .{ .label = "Stash With Untracked\u{2026}", .variant = .ghost }).clicked) p.ask("Stash the changes and untracked files (message)", "WIP", &.{ "stash", "push", "-u", "-m", "{}" }, .none);
        for (s.stashes) |st| if (std.mem.eql(u8, st.name, p.sel.items)) {
            ui.id(3);
            if (zg_gui.w.button(ui, .{ .label = "Apply", .variant = .ghost }).clicked) p.run("Stash apply", &.{&.{ "stash", "apply", st.name }});
            ui.id(4);
            if (zg_gui.w.button(ui, .{ .label = "Pop", .variant = .ghost }).clicked) p.run("Stash pop", &.{&.{ "stash", "pop", st.name }});
            ui.id(5);
            if (zg_gui.w.button(ui, .{ .label = "Drop", .variant = .danger }).clicked) {
                var mb: [300]u8 = undefined;
                p.confirmRun("Drop Stash", std.fmt.bufPrint(&mb, "Drop {s} ({s})? It cannot be recovered easily.", .{ st.name, st.subject }) catch "", "Drop", true, "Stash drop", &.{&.{ "stash", "drop", st.name }});
            }
            ui.id(6);
            if (zg_gui.w.button(ui, .{ .label = "Branch\u{2026}", .variant = .ghost }).clicked) p.ask("New branch from the stash (name)", "", &.{ "stash", "branch", "{}", st.name }, .none);
        };
        ui.close();
        p.simpleList(ui, s.stashes.len, s, stashRow);
    }

    fn stashRow(p: *ScmPanel, ui: *Ui, s: *const Snapshot, i: usize) void {
        const st = s.stashes[i];
        const r = rowOpen(ui, std.mem.eql(u8, p.sel.items, st.name), st.name);
        ui.text(st.name, .{ .color = .fg_link, .wrap = false, .style = .{ .font = .mono } });
        ui.text(st.subject, .{ .wrap = false });
        ui.close();
        if (r.clicked) {
            p.select(st.name, false);
            p.showDetail(st.name, &.{ "stash", "show", "--stat", "-p", st.name });
        }
    }

    fn tagsPage(p: *ScmPanel, ui: *Ui, s: *const Snapshot) void {
        actions(ui);
        ui.id(1);
        if (zg_gui.w.button(ui, .{ .label = "New Tag\u{2026}", .variant = .ghost }).clicked) p.ask("New tag at HEAD (name)", "", &.{ "tag", "{}" }, .none);
        ui.id(2);
        if (zg_gui.w.button(ui, .{ .label = "New Annotated Tag\u{2026}", .variant = .ghost }).clicked) p.ask("New annotated tag at HEAD: name, then the message in quotes", "v1.0 \"Release 1.0\"", &.{ "tag", "-a", "{*}" }, .none);
        if (s.remotes.len > 0) {
            ui.id(3);
            if (zg_gui.w.button(ui, .{ .label = "Push All Tags", .variant = .ghost }).clicked) p.run("Push tags", &.{&.{ "push", s.remotes[0].name, "--tags" }});
        }
        for (s.tags) |t| if (std.mem.eql(u8, t.name, p.sel.items)) {
            ui.id(4);
            if (zg_gui.w.button(ui, .{ .label = "Checkout", .variant = .ghost }).clicked) p.run("Checkout", &.{&.{ "checkout", t.name }});
            if (s.remotes.len > 0) {
                ui.id(5);
                if (zg_gui.w.button(ui, .{ .label = "Push", .variant = .ghost }).clicked) p.run("Push tag", &.{&.{ "push", s.remotes[0].name, t.name }});
                ui.id(6);
                if (zg_gui.w.button(ui, .{ .label = "Delete on Remote", .variant = .ghost }).clicked) {
                    var mb: [300]u8 = undefined;
                    p.confirmRun("Delete Remote Tag", std.fmt.bufPrint(&mb, "Delete tag {s} on {s}?", .{ t.name, s.remotes[0].name }) catch "", "Delete", true, "Delete remote tag", &.{&.{ "push", s.remotes[0].name, "--delete", t.name }});
                }
            }
            ui.id(7);
            if (zg_gui.w.button(ui, .{ .label = "Delete", .variant = .danger }).clicked) {
                var mb: [300]u8 = undefined;
                p.confirmRun("Delete Tag", std.fmt.bufPrint(&mb, "Delete tag {s}?", .{t.name}) catch "", "Delete", true, "Delete tag", &.{&.{ "tag", "-d", t.name }});
            }
        };
        ui.close();
        p.simpleList(ui, s.tags.len, s, tagRow);
    }

    fn tagRow(p: *ScmPanel, ui: *Ui, s: *const Snapshot, i: usize) void {
        const t = s.tags[i];
        const r = rowOpen(ui, std.mem.eql(u8, p.sel.items, t.name), t.name);
        ui.text(t.name, .{ .wrap = false, .style = .{ .weight = 600 } });
        ui.text(t.short, .{ .color = .fg_link, .wrap = false, .style = .{ .font = .mono } });
        ui.text(t.subject, .{ .color = .fg_muted, .wrap = false });
        ui.close();
        if (r.clicked) {
            p.select(t.name, false);
            p.showDetail(t.name, &.{ "show", "--stat", t.name });
        }
    }

    fn remotesPage(p: *ScmPanel, ui: *Ui, s: *const Snapshot) void {
        actions(ui);
        ui.id(1);
        if (zg_gui.w.button(ui, .{ .label = "Add Remote\u{2026}", .variant = .ghost }).clicked) p.ask("Add a remote: name and URL", "origin ", &.{ "remote", "add", "{*}" }, .none);
        for (s.remotes) |rm| if (std.mem.eql(u8, rm.name, p.sel.items)) {
            ui.id(2);
            if (zg_gui.w.button(ui, .{ .label = "Fetch", .variant = .ghost }).clicked) p.run("Fetch", &.{&.{ "fetch", "--prune", rm.name }});
            ui.id(3);
            if (zg_gui.w.button(ui, .{ .label = "Prune", .variant = .ghost }).clicked) p.run("Prune", &.{&.{ "remote", "prune", rm.name }});
            ui.id(4);
            if (zg_gui.w.button(ui, .{ .label = "Rename\u{2026}", .variant = .ghost }).clicked) p.ask("Rename the remote to", rm.name, &.{ "remote", "rename", rm.name, "{}" }, .none);
            ui.id(5);
            if (zg_gui.w.button(ui, .{ .label = "Set URL\u{2026}", .variant = .ghost }).clicked) p.ask("The remote's new URL", rm.fetch, &.{ "remote", "set-url", rm.name, "{}" }, .none);
            ui.id(6);
            if (zg_gui.w.button(ui, .{ .label = "Remove", .variant = .danger }).clicked) {
                var mb: [300]u8 = undefined;
                p.confirmRun("Remove Remote", std.fmt.bufPrint(&mb, "Remove the remote {s} and its remote-tracking branches?", .{rm.name}) catch "", "Remove", true, "Remove remote", &.{&.{ "remote", "remove", rm.name }});
            }
        };
        ui.close();
        p.simpleList(ui, s.remotes.len, s, remoteRow);
    }

    fn remoteRow(p: *ScmPanel, ui: *Ui, s: *const Snapshot, i: usize) void {
        const rm = s.remotes[i];
        const r = rowOpen(ui, std.mem.eql(u8, p.sel.items, rm.name), rm.name);
        ui.text(rm.name, .{ .wrap = false, .style = .{ .weight = 600 } });
        ui.text(rm.fetch, .{ .color = .fg_muted, .wrap = false });
        ui.close();
        if (r.clicked) {
            p.select(rm.name, false);
            p.showDetail(rm.name, &.{ "remote", "show", "-n", rm.name });
        }
    }

    fn submodulesPage(p: *ScmPanel, ui: *Ui, s: *const Snapshot) void {
        actions(ui);
        ui.id(1);
        if (zg_gui.w.button(ui, .{ .label = "Add Submodule\u{2026}", .variant = .ghost }).clicked) p.ask("Add a submodule: URL, then optionally its path", "", &.{ "submodule", "add", "{*}" }, .none);
        ui.id(2);
        if (zg_gui.w.button(ui, .{ .label = "Update All", .variant = .ghost }).clicked) p.run("Submodule update", &.{&.{ "submodule", "update", "--init", "--recursive" }});
        ui.id(3);
        if (zg_gui.w.button(ui, .{ .label = "Sync URLs", .variant = .ghost }).clicked) p.run("Submodule sync", &.{&.{ "submodule", "sync", "--recursive" }});
        ui.id(5);
        if (zg_gui.w.button(ui, .{ .label = "Run in Each\u{2026}", .variant = .ghost }).clicked) p.ask("Command to run in each submodule ($name, $sm_path, $sha1, $toplevel)", "", &.{ "submodule", "foreach", "--recursive", "{}" }, .none);
        for (s.submodules) |m| if (std.mem.eql(u8, m.path, p.sel.items)) {
            ui.id(4);
            if (zg_gui.w.button(ui, .{ .label = "Update", .variant = .ghost }).clicked) p.run("Submodule update", &.{&.{ "submodule", "update", "--init", "--recursive", "--", m.path }});
        };
        ui.close();
        if (s.submodules.len == 0) {
            ui.text("No submodules.", .{ .color = .fg_muted });
            return;
        }
        p.simpleList(ui, s.submodules.len, s, submoduleRow);
    }

    fn submoduleRow(p: *ScmPanel, ui: *Ui, s: *const Snapshot, i: usize) void {
        const m = s.submodules[i];
        const r = rowOpen(ui, std.mem.eql(u8, p.sel.items, m.path), m.path);
        const state = switch (m.state) {
            '-' => "not initialized",
            '+' => "other commit checked out",
            'U' => "conflicts",
            else => "up to date",
        };
        ui.text(m.path, .{ .wrap = false, .style = .{ .weight = 600 } });
        ui.text(m.sha[0..@min(8, m.sha.len)], .{ .color = .fg_link, .wrap = false, .style = .{ .font = .mono } });
        ui.text(state, .{ .color = if (m.state == ' ') .fg_muted else .warning, .wrap = false });
        ui.close();
        if (r.clicked) {
            p.select(m.path, false);
            p.showDetail(m.path, &.{ "submodule", "status", "--recursive", "--", m.path });
        }
        if (r.double_clicked) if (p.absPath(m.path)) |abs| {
            defer p.gpa.free(abs);
            p.hooks.open(p.hooks.ctx, abs);
        };
    }

    fn outputPage(p: *ScmPanel, ui: *Ui) void {
        actions(ui);
        if (zg_gui.w.button(ui, .{ .label = "Clear", .variant = .ghost }).clicked) {
            p.output.clearRetainingCapacity();
            p.setDetailTitled("Output", "");
        }
        ui.close();
        ui.open(.{ .style = .{ .padding = .xy(8, 4) } });
        ui.text("Every git command the tab runs, with what it printed, shows on the right. The box at the top runs any git command.", .{ .color = .fg_muted });
        ui.close();
    }

    fn simpleList(p: *ScmPanel, ui: *Ui, n: usize, s: *const Snapshot, comptime row: fn (*ScmPanel, *Ui, *const Snapshot, usize) void) void {
        _ = zg_gui.w.scrollArea(ui, .{ .style = .{ .grow = 1, .basis = .{ .px = 0 }, .dir = .column } });
        defer ui.close();
        for (0..n) |i| {
            ui.id(i);
            row(p, ui, s, i);
        }
    }

    // -- the detail pane ------------------------------------------------------

    fn detailPane(p: *ScmPanel, ui: *Ui) void {
        ui.open(.{ .style = .{ .dir = .column, .grow = 1, .basis = .{ .px = 0 } } });
        defer ui.close();
        if (p.detail_title.items.len > 0) {
            ui.open(.{ .style = .{ .padding = .xy(10, 4), .shrink = 0 } });
            ui.text(p.detail_title.items, .{ .color = .fg_muted, .wrap = false, .style = .{ .weight = 600 } });
            ui.close();
        }
        if (p.detail_lines.items.len == 0) {
            ui.open(.{ .style = .{ .padding = .xy(10, 8) } });
            ui.text("Select a file, commit, branch, stash or tag to see it here.", .{ .color = .fg_muted });
            ui.close();
            return;
        }
        _ = zg_gui.w.virtualList(ui, .{ .count = p.detail_lines.items.len, .row_h = 18, .style = .{ .grow = 1, .basis = .{ .px = 0 } }, .test_id = "git-detail" }, p, detailRow);
    }

    fn detailRow(p: *ScmPanel, ui: *Ui, i: usize) void {
        if (i >= p.detail_lines.items.len) return;
        const r = p.detail_lines.items[i];
        const line = std.mem.trimEnd(u8, p.detail.items[r[0]..r[1]], "\r");
        const color: zg_gui.theme.tokens.Token = if (std.mem.startsWith(u8, line, "+++") or std.mem.startsWith(u8, line, "---"))
            .fg_muted
        else if (std.mem.startsWith(u8, line, "+"))
            .success
        else if (std.mem.startsWith(u8, line, "-"))
            .danger
        else if (std.mem.startsWith(u8, line, "@@"))
            .info
        else if (std.mem.startsWith(u8, line, "diff ") or std.mem.startsWith(u8, line, "commit ") or std.mem.startsWith(u8, line, "$ git"))
            .warning
        else
            .fg;
        ui.open(.{ .style = .{ .h = .{ .px = 18 }, .padding = .xy(10, 0), .shrink = 0 } });
        ui.text(if (line.len > 0) line[0..@min(line.len, 2000)] else " ", .{ .color = color, .wrap = false, .style = .{ .font = .mono } });
        ui.close();
    }
};

/// The last `n` lines of `text`.
fn lastLines(text: []const u8, n: usize) []const u8 {
    const t = std.mem.trimEnd(u8, text, "\r\n ");
    var k: usize = 0;
    var i = t.len;
    while (i > 0) {
        i -= 1;
        if (t[i] == '\n') {
            k += 1;
            if (k == n) return t[i + 1 ..];
        }
    }
    return t;
}

// -- tests ------------------------------------------------------------------

const testing = std.testing;

const TestHost = struct {
    opened: u32 = 0,
    changed: u32 = 0,
    fn open(ctx: *anyopaque, _: []const u8) void {
        const h: *TestHost = @ptrCast(@alignCast(ctx));
        h.opened += 1;
    }
    fn onChanged(ctx: *anyopaque) void {
        const h: *TestHost = @ptrCast(@alignCast(ctx));
        h.changed += 1;
    }
};

const TestPage = struct {
    p: *ScmPanel,
    pub fn build(pg: *TestPage, ui: *Ui) void {
        ui.open(.{ .style = .{ .w = .{ .px = 1200 }, .h = .{ .px = 800 }, .dir = .column } });
        defer ui.close();
        pg.p.build(ui);
    }
};

test "git tab: init, stage, commit, branch and stash through the tab" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    // Never find the repository the test folder sits in.
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("GIT_CEILING_DIRECTORIES", std.fs.path.dirname(root).?);
    try env.put("GIT_AUTHOR_NAME", "Test");
    try env.put("GIT_AUTHOR_EMAIL", "t@example.com");
    try env.put("GIT_COMMITTER_NAME", "Test");
    try env.put("GIT_COMMITTER_EMAIL", "t@example.com");
    try env.put("GIT_CONFIG_GLOBAL", "/dev/null");
    try env.put("GIT_CONFIG_NOSYSTEM", "1");

    var host: TestHost = .{};
    const p = try ScmPanel.create(gpa, io, null, &env, root, .{ .ctx = &host, .open = TestHost.open, .changed = TestHost.onChanged });
    defer p.destroy();
    if (p.git.isRepo()) return error.SkipZigTest;
    p.confirm_sync = false;
    var page: TestPage = .{ .p = p };
    const t = try zg_gui.testing.TestApp.init(gpa, .{ .size = .{ .w = 1200, .h = 800 }, .root = zg_gui.AnyView.of(&page) });
    defer t.deinit();
    _ = t.settle();
    // git may be missing (wine).
    if (p.snap == null) return error.SkipZigTest;
    try testing.expect(t.find(.{ .role = .button, .name = "Initialize Repository" }) != null);
    try t.click(.{ .role = .button, .name = "Initialize Repository" });
    _ = t.settle();
    if (!p.git.isRepo()) return error.SkipZigTest;
    try testing.expect(p.snap.?.repo);

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "one\n" });
    p.refresh();
    _ = t.settle();
    try testing.expect(t.find(.{ .role = .listitem, .name = "a.txt" }) != null);
    // Stage it, then commit with a message.
    p.run("Stage", &.{&.{ "add", "--", "a.txt" }});
    _ = t.settle();
    try testing.expect(p.snap.?.status.entries[0].staged());
    try p.message.setText("First commit");
    try t.click(.{ .role = .button, .name = "Commit" });
    _ = t.settle();
    try testing.expectEqual(@as(usize, 0), p.snap.?.status.entries.len);
    try testing.expectEqual(@as(usize, 1), p.snap.?.log.len);
    try testing.expectEqualStrings("First commit", p.snap.?.log[0].subject);
    try testing.expectEqualStrings("", p.message.slice());
    try testing.expect(host.changed > 0);

    // A change shows its diff.
    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "two\n" });
    p.refresh();
    _ = t.settle();
    try t.click(.{ .role = .listitem, .name = "a.txt" });
    _ = t.settle();
    try testing.expect(std.mem.indexOf(u8, p.detail.items, "+two") != null);

    // Stash it, then a branch through the prompt.
    p.run("Stash", &.{&.{ "stash", "push", "-m", "wip" }});
    _ = t.settle();
    try testing.expectEqual(@as(usize, 1), p.snap.?.stashes.len);
    try t.click(.{ .role = .button, .name = "Branches" });
    _ = t.settle();
    try testing.expectEqual(Tab.branches, p.tab);
    try t.click(.{ .role = .button, .name = "New Branch\u{2026}" });
    _ = t.settle();
    _ = t.settle();
    t.typeText("topic");
    t.press(.enter, .{});
    _ = t.settle();
    try testing.expectEqualStrings("topic", p.snap.?.status.branch.?);
    try testing.expectEqual(@as(usize, 2), p.snap.?.branches.len);

    // A failing command says why.
    p.run("Checkout", &.{&.{ "checkout", "nope" }});
    _ = t.settle();
    try testing.expect(p.note_bad);
    try testing.expect(std.mem.indexOf(u8, p.output.items, "$ git checkout nope") != null);

    // The command box runs anything.
    try p.command.setText("tag v1");
    p.runTyped();
    _ = t.settle();
    try testing.expectEqual(@as(usize, 1), p.snap.?.tags.len);
}
