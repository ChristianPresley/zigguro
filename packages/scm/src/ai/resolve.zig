//! The conflict resolution proposer (E09.F06.S02.T01): for each conflict
//! region of a change, context for the model, a structured resolution,
//! validation, and per-region proposals that review (E12) and the merge
//! editor accept, edit or reject; then `applyResolutions` turns the
//! decisions into a preview operation.
//!
//! Regions come from the change's three tree terms (side, base, side),
//! walked like `TreeMerger.merge3`: a text file changed on both sides is
//! line-merged (`content_merge`) and each conflict hunk is one region,
//! numbered from 0 within its file. Binary files, executable-bit and type
//! conflicts, delete vs modify and changed symlinks or submodules are one
//! whole-path region each, marked `needs_human` without a model call.
//!
//! Each text region gets its own model request (bounded by `parallel`,
//! each with its own cancel flag) with the base and side texts,
//! `context_lines` lines before and after (conflicts in that context show
//! side 1), and each side's change description when the change's parents
//! are its sides. The reply is JSON (`schemas/resolve.schema.json`). A
//! reply is `needs_human` when it has conflict-marker lines, claims to
//! address a side while none of that side's new identifiers survive, or,
//! when a `SyntaxCheck` knows the language, has more syntax errors
//! spliced into the file than the side with the fewest.
//!
//! Applying builds each file from the decisions (the proposal's or the
//! reviewer's text, one side, or the conflict kept as diff3 markers),
//! merges the trees with those decisions as overrides, rewrites the
//! change with the resolved tree and restacks its descendants, as one
//! detached preview operation (a `resolve` proposal).
//!
//! Only two-sided conflicts (three tree terms) are supported. Line-level
//! provenance of accepted vs edited text (`attributionForMerge`, F05) is
//! not recorded yet.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const store_mod = @import("../store/store.zig");
const chunker = @import("../store/chunker.zig");
const op_mod = @import("../oplog/operation.zig");
const repo_mod = @import("../oplog/repo.zig");
const preview = @import("../oplog/preview.zig");
const rebase = @import("../oplog/rebase.zig");
const merge_mod = @import("../merge/merge.zig");
const mat = @import("../merge/materialize.zig");
const content_merge = @import("../merge/content_merge.zig");
const tree_merge = @import("../merge/tree_merge.zig");
const ports = @import("ports.zig");
const prov_record = @import("../prov/record.zig");
const attribution = @import("../prov/attribution.zig");
const manifest_mod = @import("../prov/manifest.zig");
const remap = @import("../prov/remap.zig");
const ObjectId = id_mod.ObjectId;
const ChangeId = id_mod.ChangeId;
const Store = store_mod.Store;
const Change = object.Change;
const Tree = object.Tree;
const TreeEntry = object.TreeEntry;
const Repo = repo_mod.Repo;
const MergeHunk = mat.MergeHunk;
const Allocator = std.mem.Allocator;

/// The system prompt.
pub const system_prompt = @embedFile("prompts/resolve.md");
/// The reply's JSON schema.
pub const reply_schema = @embedFile("schemas/resolve.schema.json");

pub const ResolveOptions = struct {
    context_lines: u16 = 30,
    /// Regions past this many are `needs_human` without a model call.
    max_regions: u16 = 64,
    /// Model calls in flight at once.
    parallel: u8 = 4,
    validate_syntax: bool = true,
    /// Side descriptions are cut to this many bytes (about 400 tokens).
    max_description_bytes: usize = 1600,
    max_input_tokens: u32 = 32_000,
    max_output_tokens: u32 = 4096,
};

pub const RegionKind = enum {
    /// Overlapping line edits in a text file.
    text,
    binary,
    /// The sides disagree on the executable bit.
    mode,
    /// A file, directory, symlink or submodule on one side, another kind
    /// on the other.
    type,
    /// Deleted on one side, changed on the other.
    delete,
    /// A symlink or submodule changed on both sides.
    other,

    pub fn reason(k: RegionKind) ?[]const u8 {
        return switch (k) {
            .text => null,
            .binary => "binary file changed on both sides",
            .mode => "the sides disagree on the executable bit",
            .type => "the sides changed the path's type",
            .delete => "deleted on one side, changed on the other",
            .other => "symlink or submodule changed on both sides",
        };
    }
};

/// One conflicted path.
pub const ConflictFile = struct {
    path: []const u8,
    /// The entry per term (side 1, base, side 2); null where absent.
    entries: [3]?TreeEntry,
    /// The merged entry kind, for text files.
    kind: object.EntryKind = .file,
    /// Line-merge hunks, for text regions; empty for whole-path regions.
    hunks: []const MergeHunk = &.{},
};

pub const Region = struct {
    path: []const u8,
    /// Index among the file's regions.
    region_idx: u32,
    kind: RegionKind,
    /// The region's text per term (side 1, base, side 2); empty strings
    /// for whole-path regions.
    terms: [3][]const u8 = .{ "", "", "" },
    /// Index into `ConflictSet.files`.
    file: u32,
    /// Index of the region's hunk in the file's hunks (text regions).
    hunk: u32 = 0,
};

pub const ConflictSet = struct {
    change: ObjectId,
    commit: Change,
    /// The commits that made each side: the change's parents when it has
    /// one per side, otherwise the change itself for both.
    side_changes: [2]Change,
    files: []const ConflictFile,
    regions: []const Region,
};

pub const SideCtx = struct {
    text: []const u8,
    change_id: ChangeId,
    description: []const u8,
    /// The session's task statement, when an agent made the side.
    intent: ?[]const u8 = null,
};

pub const RegionContext = struct {
    path: []const u8,
    region_idx: u32,
    base: []const u8,
    sides: []const SideCtx,
    before: []const u8,
    after: []const u8,
    /// From the file extension (e.g. "zig", "python"), null when unknown.
    language: ?[]const u8,
};

pub const Status = enum { ok, needs_human };

pub const RegionProposal = struct {
    path: []const u8,
    region_idx: u32,
    /// The proposed text (also when `needs_human`, if the model replied).
    text: []const u8 = "",
    rationale: []const u8 = "",
    status: Status,
    reason: ?[]const u8 = null,
};

/// A reviewer's decision for one region.
pub const RegionDecision = struct {
    path: []const u8,
    region_idx: u32,
    choice: Choice,

    pub const Choice = union(enum) {
        /// The proposal's text, as accepted.
        accept: []const u8,
        /// Text the reviewer wrote or edited.
        edit: []const u8,
        /// Side k (0 or 1) as it is; for whole-path regions, that side's
        /// entry (absent: deleted).
        side: u32,
        /// Leave the conflict in the file as diff3 markers (text regions
        /// only).
        keep_conflict,
    };
};

/// Counts syntax errors, for languages it knows.
pub const SyntaxCheck = struct {
    ctx: ?*anyopaque = null,
    /// The number of syntax errors in `text` as the language of `path`,
    /// or null when the language is not supported. Called from worker
    /// threads.
    errors: *const fn (ctx: ?*anyopaque, gpa: Allocator, path: []const u8, text: []const u8) anyerror!?u32,

    /// Zig files, with `std.zig.Ast`.
    pub const zig: SyntaxCheck = .{ .errors = zigErrors };

    fn zigErrors(_: ?*anyopaque, gpa: Allocator, path: []const u8, text: []const u8) anyerror!?u32 {
        if (!std.mem.endsWith(u8, path, ".zig")) return null;
        const src = try gpa.dupeZ(u8, text);
        defer gpa.free(src);
        var ast = try std.zig.Ast.parse(gpa, src, .zig);
        defer ast.deinit(gpa);
        return @intCast(ast.errors.len);
    }
};

pub const reasons = struct {
    pub const markers = "contains conflict markers";
    pub const dropped = "claims to address a side but drops all of its new identifiers";
    pub const syntax = "introduces syntax errors";
    pub const cancelled = "cancelled";
    pub const too_many = "too many conflict regions";
    pub const malformed = "malformed reply";
    pub const cut_off = "reply cut off";
};

// ------------------------------------------------------------- regions

/// The conflict regions of `change`, allocated in `arena`.
pub fn conflicts(arena: Allocator, store: *Store, change: ObjectId) !ConflictSet {
    const c = try op_mod.read(Change, store, arena, change);
    if (c.tree_terms.len == 1) return error.NotConflicted;
    if (c.tree_terms.len != 3) return error.TooManySides;
    var w: Walker = .{ .arena = arena, .store = store };
    try w.walk("", c.tree_terms[1], c.tree_terms[0], c.tree_terms[2]);
    var sides: [2]Change = .{ c, c };
    if (c.parents.len == 2) {
        for (&sides, c.parents) |*sc, p| sc.* = try op_mod.read(Change, store, arena, p);
    }
    return .{ .change = change, .commit = c, .side_changes = sides, .files = w.files.items, .regions = w.regions.items };
}

const Walker = struct {
    arena: Allocator,
    store: *Store,
    files: std.ArrayList(ConflictFile) = .empty,
    regions: std.ArrayList(Region) = .empty,

    fn tree(w: *Walker, id: ?ObjectId) !Tree {
        const tid = id orelse return .{ .entries = &.{} };
        return op_mod.read(Tree, w.store, w.arena, tid);
    }

    /// Mirrors `TreeMerger.merge3` (the same directory rule), so decided
    /// paths line up with the paths the merger asks about.
    fn walk(w: *Walker, prefix: []const u8, base: ?ObjectId, left: ObjectId, right: ObjectId) anyerror!void {
        if (left.eql(right)) return;
        if (base) |b| if (b.eql(left) or b.eql(right)) return;
        const bt = try w.tree(base);
        const lt = try w.tree(left);
        const rt = try w.tree(right);
        var names: std.StringArrayHashMapUnmanaged(void) = .empty;
        for ([_]Tree{ bt, lt, rt }) |x| for (x.entries) |e| try names.put(w.arena, e.name, {});
        for (names.keys()) |name| {
            const b = bt.find(name);
            const l = lt.find(name);
            const r = rt.find(name);
            if (sameEntry(l, r) or sameEntry(b, l) or sameEntry(b, r)) continue;
            const path = if (prefix.len == 0) name else try std.fmt.allocPrint(w.arena, "{s}/{s}", .{ prefix, name });
            if (isDir(l) and isDir(r) and (b == null or isDir(b))) {
                try w.walk(path, if (b) |x| x.id else null, l.?.id, r.?.id);
                continue;
            }
            try w.file(path, b, l, r);
        }
    }

    fn file(w: *Walker, path: []const u8, b: ?TreeEntry, l: ?TreeEntry, r: ?TreeEntry) !void {
        var f: ConflictFile = .{ .path = path, .entries = .{ l, b, r } };
        const kind: RegionKind = classify(b, l, r) orelse blk: {
            f.kind = mergedKind(b, l.?, r.?) orelse break :blk .mode;
            const bt: []const u8 = if (b) |x| try w.blob(x.id) else "";
            const lt = try w.blob(l.?.id);
            const rt = try w.blob(r.?.id);
            for ([_][]const u8{ bt, lt, rt }) |x| if (content_merge.isBinary(x)) break :blk .binary;
            const vals = try w.arena.dupe([]const u8, &.{ lt, bt, rt });
            const res = try content_merge.mergeContent(w.arena, .{ .values = vals }, .{});
            // Merges cleanly: nothing to decide.
            if (res.clean != null) return;
            f.hunks = res.hunks;
            const fi: u32 = @intCast(w.files.items.len);
            try w.files.append(w.arena, f);
            var n: u32 = 0;
            for (res.hunks, 0..) |h, hi| switch (h) {
                .resolved => {},
                .conflict => |m| {
                    try w.regions.append(w.arena, .{
                        .path = path,
                        .region_idx = n,
                        .kind = .text,
                        .terms = .{ m.values[0], m.values[1], m.values[2] },
                        .file = fi,
                        .hunk = @intCast(hi),
                    });
                    n += 1;
                },
            };
            return;
        };
        try w.regions.append(w.arena, .{ .path = path, .region_idx = 0, .kind = kind, .file = @intCast(w.files.items.len) });
        try w.files.append(w.arena, f);
    }

    fn blob(w: *Walker, id: ObjectId) ![]const u8 {
        var buf: [16 << 10]u8 = undefined;
        var br = try chunker.blobReader(w.store, id, &buf);
        defer br.deinit();
        return br.interface.readAlloc(w.arena, @intCast(br.size));
    }
};

/// The whole-path kind of a two-sided change, or null for text files
/// changed on both sides.
fn classify(b: ?TreeEntry, l: ?TreeEntry, r: ?TreeEntry) ?RegionKind {
    const le = l orelse return .delete;
    const re = r orelse return .delete;
    if (isText(le) and isText(re) and (b == null or isText(b.?))) return null;
    if (le.kind == re.kind and (b == null or b.?.kind == le.kind)) return .other;
    return .type;
}

fn mergedKind(b: ?TreeEntry, l: TreeEntry, r: TreeEntry) ?object.EntryKind {
    if (l.kind == r.kind) return l.kind;
    const bk = (b orelse return null).kind;
    if (bk == l.kind) return r.kind;
    if (bk == r.kind) return l.kind;
    return null;
}

fn isText(e: TreeEntry) bool {
    return e.kind == .file or e.kind == .executable;
}

fn isDir(e: ?TreeEntry) bool {
    return if (e) |x| x.kind == .tree else false;
}

fn sameEntry(a: ?TreeEntry, b: ?TreeEntry) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.kind == b.?.kind and a.?.id.eql(b.?.id);
}

// ------------------------------------------------------------- context

/// The model's view of `region`, allocated in `arena`.
pub fn context(arena: Allocator, set: *const ConflictSet, region: *const Region, o: ResolveOptions) !RegionContext {
    const f = set.files[region.file];
    const sides = try arena.alloc(SideCtx, 2);
    for (sides, set.side_changes, 0..) |*s, c, k| {
        s.* = .{
            .text = region.terms[2 * k],
            .change_id = c.change_id,
            .description = cut(c.description, o.max_description_bytes),
        };
    }
    var before: []const u8 = "";
    var after: []const u8 = "";
    if (region.kind == .text) {
        before = tailLines(try render(arena, f.hunks[0..region.hunk], null, ""), o.context_lines);
        after = headLines(try render(arena, f.hunks[region.hunk + 1 ..], null, ""), o.context_lines);
    }
    return .{
        .path = region.path,
        .region_idx = region.region_idx,
        .base = region.terms[1],
        .sides = sides,
        .before = before,
        .after = after,
        .language = language(region.path),
    };
}

/// `hunks` as text, conflicts as side 1, except hunk `at` as `text`.
fn render(arena: Allocator, hunks: []const MergeHunk, at: ?usize, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (hunks, 0..) |h, i| {
        if (at != null and at.? == i) {
            try out.appendSlice(arena, text);
            continue;
        }
        try out.appendSlice(arena, switch (h) {
            .resolved => |x| x,
            .conflict => |m| m.values[0],
        });
    }
    return out.items;
}

fn cut(s: []const u8, n: usize) []const u8 {
    if (s.len <= n) return s;
    var end = n;
    while (end > 0 and (s[end] & 0xc0) == 0x80) end -= 1;
    return s[0..end];
}

fn tailLines(text: []const u8, n: usize) []const u8 {
    if (n == 0) return "";
    var i = text.len;
    if (i > 0 and text[i - 1] == '\n') i -= 1;
    var seen: usize = 0;
    while (i > 0) : (i -= 1) {
        if (text[i - 1] == '\n') {
            seen += 1;
            if (seen == n) break;
        }
    }
    return text[i..];
}

fn headLines(text: []const u8, n: usize) []const u8 {
    var seen: usize = 0;
    for (text, 0..) |ch, i| {
        if (ch != '\n') continue;
        seen += 1;
        if (seen == n) return text[0 .. i + 1];
    }
    return text;
}

fn language(path: []const u8) ?[]const u8 {
    const base = std.fs.path.basenamePosix(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
    const ext = base[dot..];
    if (dot == 0 or ext.len < 2) return null;
    const map = [_][2][]const u8{
        .{ ".zig", "zig" },   .{ ".c", "c" },           .{ ".h", "c" },           .{ ".cc", "cpp" },
        .{ ".cpp", "cpp" },   .{ ".hpp", "cpp" },       .{ ".rs", "rust" },       .{ ".go", "go" },
        .{ ".py", "python" }, .{ ".js", "javascript" }, .{ ".ts", "typescript" }, .{ ".json", "json" },
        .{ ".toml", "toml" }, .{ ".yaml", "yaml" },     .{ ".yml", "yaml" },      .{ ".md", "markdown" },
        .{ ".sh", "shell" },  .{ ".zon", "zig" },
    };
    for (map) |e| if (std.mem.eql(u8, e[0], ext)) return e[1];
    return ext[1..];
}

/// The request text for `ctx`.
pub fn prompt(arena: Allocator, ctx: *const RegionContext) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.print("File: {s}\nLanguage: {s}\nConflict region: {d}\n\n", .{ ctx.path, ctx.language orelse "unknown", ctx.region_idx + 1 });
    for (ctx.sides, 1..) |s, k| {
        var buf: [32]u8 = undefined;
        try w.print("Side {d} change {s}:\n{s}\n", .{ k, s.change_id.reverseHex(&buf)[0..12], s.description });
        if (s.intent) |i| try w.print("Side {d} task: {s}\n", .{ k, i });
        try w.writeAll("\n");
    }
    try section(w, "before", ctx.before);
    try section(w, "base", ctx.base);
    for (ctx.sides, 1..) |s, k| {
        var name: [16]u8 = undefined;
        try section(w, std.fmt.bufPrint(&name, "side {d}", .{k}) catch unreachable, s.text);
    }
    try section(w, "after", ctx.after);
    return out.written();
}

fn section(w: *std.Io.Writer, name: []const u8, text: []const u8) !void {
    try w.print("<{s}>\n{s}", .{ name, text });
    if (text.len > 0 and text[text.len - 1] != '\n') try w.writeAll("\n");
    try w.print("</{s}>\n", .{name});
}

// ------------------------------------------------------------ proposals

pub const Resolver = struct {
    /// Must be thread-safe: workers allocate from it.
    gpa: Allocator,
    io: std.Io,
    store: *Store,
    model: ports.ModelPort,
    syntax: ?SyntaxCheck = SyntaxCheck.zig,
    options: ResolveOptions = .{},

    /// Regions and contexts for `change`, with every non-text region
    /// already decided `needs_human`. Free with `Run.deinit`.
    pub fn prepare(res: *Resolver, change: ObjectId) !*Run {
        const run = try res.gpa.create(Run);
        run.* = .{ .gpa = res.gpa, .arena_state = .init(res.gpa), .set = undefined, .jobs = &.{} };
        errdefer run.deinit();
        const a = run.arena_state.allocator();
        run.set = try conflicts(a, res.store, change);
        run.jobs = try a.alloc(Job, run.set.regions.len);
        for (run.jobs, run.set.regions, 0..) |*j, *r, i| {
            j.* = .{ .region = r, .arena_state = .init(res.gpa), .ctx = undefined };
            j.proposal = .{ .path = r.path, .region_idx = r.region_idx, .status = .needs_human };
            if (r.kind.reason()) |why| {
                j.proposal.reason = why;
                j.done = true;
            } else if (i >= res.options.max_regions) {
                j.proposal.reason = reasons.too_many;
                j.done = true;
            }
            j.ctx = try context(a, &run.set, r, res.options);
        }
        return run;
    }

    /// Asks the model about every open region of `run`, `parallel` at a
    /// time; a failed or cancelled region becomes `needs_human`.
    pub fn propose(res: *Resolver, run: *Run) !void {
        var next: std.atomic.Value(usize) = .init(0);
        var group: std.Io.Group = .init;
        const n = @max(1, @min(res.options.parallel, run.jobs.len));
        for (0..n) |_| group.async(res.io, worker, .{ res, run, &next });
        try group.await(res.io);
    }

    /// `prepare` and `propose`.
    pub fn proposeForChange(res: *Resolver, change: ObjectId) !*Run {
        const run = try res.prepare(change);
        errdefer run.deinit();
        try res.propose(run);
        return run;
    }

    fn worker(res: *Resolver, run: *Run, next: *std.atomic.Value(usize)) void {
        while (true) {
            const i = next.fetchAdd(1, .monotonic);
            if (i >= run.jobs.len) return;
            const j = &run.jobs[i];
            if (j.done) continue;
            res.proposeOne(run, j) catch |e| {
                j.proposal.status = .needs_human;
                j.proposal.reason = @errorName(e);
            };
            j.done = true;
        }
    }

    fn proposeOne(res: *Resolver, run: *Run, j: *Job) !void {
        const a = j.arena_state.allocator();
        const msgs = try a.dupe(ports.AiMessage, &.{.{ .role = .user, .text = try prompt(a, &j.ctx) }});
        const req: ports.AiRequest = .{
            .system = system_prompt,
            .messages = msgs,
            .json_schema = reply_schema,
            .max_input_tokens = res.options.max_input_tokens,
            .max_output_tokens = res.options.max_output_tokens,
            .cancel = &j.cancel,
        };
        var reply: Reply = .{ .arena = a };
        var sink = reply.sink();
        try res.model.call(&req, &sink);
        const p = &j.proposal;
        if (j.cancel.load(.acquire) or reply.stop == .cancelled) {
            p.reason = reasons.cancelled;
            return;
        }
        if (reply.err) |e| {
            p.reason = try std.fmt.allocPrint(a, "model error: {s}", .{e});
            return;
        }
        if (reply.oom) return error.OutOfMemory;
        if (reply.stop == .max_tokens) {
            p.reason = reasons.cut_off;
            return;
        }
        const doc = if (reply.json.items.len > 0) reply.json.items else stripFences(reply.text.items);
        const ans = std.json.parseFromSliceLeaky(Answer, a, doc, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            p.reason = reasons.malformed;
            return;
        };
        p.text = ans.resolution;
        p.rationale = ans.rationale;
        p.reason = try res.validate(a, &run.set, j.region, ans);
        p.status = if (p.reason == null) .ok else .needs_human;
    }

    /// Why `ans` (for `region` of `set`) needs a human, or null when it
    /// is fine.
    pub fn validate(res: *Resolver, a: Allocator, set: *const ConflictSet, region: *const Region, ans: Answer) !?[]const u8 {
        if (hasNewMarker(ans.resolution, &region.terms)) return reasons.markers;
        const out = try identifiers(a, ans.resolution);
        const base = try identifiers(a, region.terms[1]);
        for (ans.addresses_sides, 0..) |claims, k| {
            if (!claims or k >= 2) continue;
            const side = try identifiers(a, region.terms[2 * k]);
            var added: usize = 0;
            var kept: usize = 0;
            for (side.keys()) |id| {
                if (base.contains(id)) continue;
                added += 1;
                kept += @intFromBool(out.contains(id));
            }
            if (added > 0 and kept == 0) return reasons.dropped;
        }
        if (!res.options.validate_syntax) return null;
        const check = res.syntax orelse return null;
        const f = set.files[region.file];
        const spliced = try render(a, f.hunks, region.hunk, ans.resolution);
        const got = (try check.errors(check.ctx, res.gpa, f.path, spliced)) orelse return null;
        var best: u32 = std.math.maxInt(u32);
        for ([_]usize{ 0, 2 }) |k| {
            const side_file = try render(a, f.hunks, region.hunk, region.terms[k]);
            const e = (try check.errors(check.ctx, res.gpa, f.path, side_file)) orelse return null;
            best = @min(best, e);
        }
        if (got > best) return reasons.syntax;
        return null;
    }
};

pub const Job = struct {
    region: *const Region,
    ctx: RegionContext,
    /// Set (from any thread) to cancel this region only.
    cancel: std.atomic.Value(bool) = .init(false),
    proposal: RegionProposal = undefined,
    done: bool = false,
    /// The proposal's strings; one per job, since jobs run on different
    /// threads.
    arena_state: std.heap.ArenaAllocator,
};

pub const Run = struct {
    gpa: Allocator,
    arena_state: std.heap.ArenaAllocator,
    set: ConflictSet,
    jobs: []Job,

    pub fn deinit(run: *Run) void {
        for (run.jobs) |*j| j.arena_state.deinit();
        run.arena_state.deinit();
        run.gpa.destroy(run);
    }

    /// Cancels region `i`'s request; the others go on.
    pub fn cancel(run: *Run, i: usize) void {
        run.jobs[i].cancel.store(true, .release);
    }

    pub fn proposal(run: *const Run, i: usize) RegionProposal {
        return run.jobs[i].proposal;
    }
};

/// The model's reply.
pub const Answer = struct {
    resolution: []const u8,
    rationale: []const u8 = "",
    addresses_sides: []const bool = &.{},
};

/// Collects one call's reply (callbacks of one call run on one thread).
const Reply = struct {
    arena: Allocator,
    text: std.ArrayList(u8) = .empty,
    json: std.ArrayList(u8) = .empty,
    stop: ?ports.StopReason = null,
    err: ?[]const u8 = null,
    oom: bool = false,

    fn sink(r: *Reply) ports.AiSink {
        return .{ .ctx = r, .onText = onText, .onJson = onJson, .onDone = onDone, .onError = onError };
    }

    fn of(ctx: *anyopaque) *Reply {
        return @ptrCast(@alignCast(ctx));
    }

    fn onText(ctx: *anyopaque, chunk: []const u8) void {
        const r = of(ctx);
        r.text.appendSlice(r.arena, chunk) catch {
            r.oom = true;
        };
    }

    fn onJson(ctx: *anyopaque, chunk: []const u8) void {
        const r = of(ctx);
        r.json.appendSlice(r.arena, chunk) catch {
            r.oom = true;
        };
    }

    fn onDone(ctx: *anyopaque, reason: ports.StopReason, _: ports.Usage) void {
        of(ctx).stop = reason;
    }

    fn onError(ctx: *anyopaque, message: []const u8) void {
        const r = of(ctx);
        r.err = r.arena.dupe(u8, message) catch blk: {
            r.oom = true;
            break :blk "out of memory";
        };
    }
};

/// A reply sent as text: the JSON, with a Markdown fence around it or not.
fn stripFences(text: []const u8) []const u8 {
    var s = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, s, "```")) return s;
    const nl = std.mem.indexOfScalar(u8, s, '\n') orelse return s;
    s = s[nl + 1 ..];
    if (std.mem.lastIndexOf(u8, s, "```")) |end| s = s[0..end];
    return std.mem.trim(u8, s, " \t\r\n");
}

/// Whether `text` has a marker line (seven of `<>=|%+`) that none of the
/// terms has.
fn hasNewMarker(text: []const u8, terms: []const []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    outer: while (it.next()) |line| {
        if (!isMarker(line)) continue;
        for (terms) |t| {
            var tl = std.mem.splitScalar(u8, t, '\n');
            while (tl.next()) |x| if (std.mem.eql(u8, x, line)) continue :outer;
        }
        return true;
    }
    return false;
}

fn isMarker(line: []const u8) bool {
    if (line.len < 7) return false;
    for (line[0..7]) |ch| if (std.mem.indexOfScalar(u8, "<>=|%+", ch) == null) return false;
    return true;
}

fn identifiers(a: Allocator, text: []const u8) !std.StringArrayHashMapUnmanaged(void) {
    var set: std.StringArrayHashMapUnmanaged(void) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (!(std.ascii.isAlphabetic(ch) or ch == '_')) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) i += 1;
        try set.put(a, text[start..i], {});
    }
    return set;
}

// ---------------------------------------------------------------- apply

pub const Applied = struct {
    /// The preview: adopt to apply, discard to drop.
    preview: preview.DetachedOp,
    /// The resolved change, in the preview's view.
    commit: ObjectId,

    /// The review item for this preview.
    pub fn proposal(ap: *const Applied, summary: []const u8, provenance: ports.ProvenanceRecord, rationale: []const u8) ports.Proposal {
        return .{
            .kind = .resolve,
            .preview_op = ap.preview,
            .summary = summary,
            .changes = (&ap.commit)[0..1],
            .provenance = provenance,
            .rationale = rationale,
        };
    }
};

/// Who resolved the regions, for the resolved change's provenance:
/// accepted proposals are the agent's (with the review that accepted
/// them), edited ones the human's. Lines taken from a side keep that
/// side's attribution.
pub const ResolveAttribution = struct {
    agent: prov_record.Actor,
    human: prov_record.Actor,
    review: ?prov_record.ReviewRef = null,
};

/// Rewrites `set.change` resolved by `decisions` (one per region) in a
/// detached preview operation, restacking its descendants.
pub fn applyResolutions(repo: *Repo, set: *const ConflictSet, decisions: []const RegionDecision, meta: op_mod.OpMeta) !Applied {
    return applyResolutionsWith(repo, set, decisions, meta, null);
}

/// `applyResolutions`, also writing the resolved change's provenance
/// manifest when `who` is given (E09.F05.S01.T02).
pub fn applyResolutionsWith(repo: *Repo, set: *const ConflictSet, decisions: []const RegionDecision, meta: op_mod.OpMeta, who: ?ResolveAttribution) !Applied {
    const choices = try repo.gpa.alloc(?RegionDecision.Choice, set.regions.len);
    defer repo.gpa.free(choices);
    @memset(choices, null);
    for (decisions) |d| {
        const i = findRegion(set, d.path, d.region_idx) orelse return error.UnknownRegion;
        choices[i] = d.choice;
    }
    for (choices) |c| if (c == null) return error.MissingDecision;

    const tx = try repo.startTransaction(meta);
    var tx_live = true;
    errdefer if (tx_live) tx.discard();
    const a = tx.arena();
    const m = tx.mutRepo();
    var tm = tree_merge.TreeMerger.init(repo.gpa, repo.store, m.batch);
    defer tm.deinit();
    var overrides: std.StringHashMapUnmanaged(?TreeEntry) = .empty;
    var prov = if (who) |w| try Provenance.init(repo, m.batch, a, set, w, meta.end_ms) else null;

    var ri: usize = 0;
    for (set.files) |f| {
        const name = std.fs.path.basenamePosix(f.path);
        if (f.hunks.len == 0) {
            // A whole-path region.
            const entry: ?TreeEntry = switch (choices[ri].?) {
                .side => |k| if (k < 2) f.entries[2 * k] else return error.BadSide,
                .accept, .edit => |text| .{ .name = name, .kind = .file, .id = try tm.putBlob(text) },
                .keep_conflict => return error.CannotKeepConflict,
            };
            if (prov) |*pv| switch (choices[ri].?) {
                .accept, .edit => |text| try pv.wholeFile(f.path, entry.?.id, text, choices[ri].? == .accept),
                else => {},
            };
            try overrides.put(a, f.path, entry);
            ri += 1;
            continue;
        }
        var text: std.ArrayList(u8) = .empty;
        // Result lines written by the resolver: (start, len, accepted).
        var written: std.ArrayList(Provenance.Span) = .empty;
        for (f.hunks) |h| switch (h) {
            .resolved => |x| try text.appendSlice(a, x),
            .conflict => |cm| {
                const at = attribution.lineCountOf(text.items);
                switch (choices[ri].?) {
                    .accept, .edit => |x| try text.appendSlice(a, x),
                    .side => |k| try text.appendSlice(a, if (k < 2) cm.values[2 * k] else return error.BadSide),
                    .keep_conflict => {
                        var aw: std.Io.Writer.Allocating = .init(a);
                        const one = [_]MergeHunk{h};
                        const file = [_]?[]const u8{ cm.values[0], cm.values[1], cm.values[2] };
                        try mat.materialize(a, .{ .values = &file }, &one, .{ .style = .diff3 }, &aw.writer);
                        try text.appendSlice(a, aw.written());
                    },
                }
                switch (choices[ri].?) {
                    .accept, .edit => |x| try written.append(a, .{ .start = at, .len = attribution.lineCountOf(x), .accepted = choices[ri].? == .accept }),
                    else => {},
                }
                ri += 1;
            },
        };
        const blob = try tm.putBlob(text.items);
        try overrides.put(a, f.path, .{ .name = name, .kind = f.kind, .id = blob });
        if (prov) |*pv| try pv.textFile(f, blob, text.items, written.items);
    }

    tm.overrides = &overrides;
    const terms = set.commit.tree_terms;
    const tree = (try tm.merge3(terms[1], terms[0], terms[2])) orelse return error.Unresolved;
    var c = try m.readChange(a, set.change);
    c.tree_terms = try a.dupe(ObjectId, &.{tree});
    c.sig = null;
    if (prov) |*pv| c.provenance = try pv.finish();
    const new = try m.rewriteChange(set.change, c);
    _ = try m.rebaseDescendants(rebase.reparent, null);
    tx_live = false;
    const d = try preview.commitDetached(tx, .proposal);
    return .{ .preview = d, .commit = new };
}

/// Builds the resolved change's manifest, file by file.
const Provenance = struct {
    ctx: remap.RemapContext,
    arena: Allocator,
    set: *const ConflictSet,
    agent_rec: ObjectId,
    human_rec: ObjectId,
    /// The conflicted change's manifest and the sides'.
    old: ?manifest_mod.ProvenanceManifest,
    sides: [2]?manifest_mod.ProvenanceManifest,
    parent_tree: ?ObjectId,
    files: std.ArrayList(manifest_mod.FileAttribution) = .empty,
    done: std.StringHashMapUnmanaged(void) = .empty,

    const Span = struct { start: u32, len: u32, accepted: bool };

    fn init(repo: *Repo, batch: *store_mod.WriteBatch, a: Allocator, set: *const ConflictSet, w: ResolveAttribution, at_ms: i64) !Provenance {
        var ctx: remap.RemapContext = .{ .gpa = repo.gpa, .store = repo.store, .batch = batch };
        const agent_rec = try remap.writeRecord(&ctx, .{ .actor = w.agent, .created_ms = at_ms, .review = w.review });
        const human_rec = try remap.writeRecord(&ctx, .{ .actor = w.human, .created_ms = at_ms, .review = if (w.review) |r| .{ .review_id = r.review_id, .verbatim = false } else null });
        var p: Provenance = .{ .ctx = ctx, .arena = a, .set = set, .agent_rec = agent_rec, .human_rec = human_rec, .old = null, .sides = .{ null, null }, .parent_tree = null };
        if (set.commit.provenance) |id| p.old = try manifest_mod.read(repo.store, a, id);
        for (&p.sides, set.side_changes) |*sm, sc| {
            if (sc.provenance) |id| sm.* = try manifest_mod.read(repo.store, a, id);
        }
        if (set.commit.parents.len > 0) {
            const parent = try op_mod.read(Change, repo.store, a, set.commit.parents[0]);
            if (parent.tree_terms.len == 1) p.parent_tree = parent.tree_terms[0];
        }
        return p;
    }

    fn wholeFile(p: *Provenance, path: []const u8, blob: ObjectId, text: []const u8, accepted: bool) !void {
        try p.done.put(p.arena, path, {});
        const n = attribution.lineCountOf(text);
        if (n == 0) return;
        const map: attribution.AttributionMap = .{ .runs = try p.arena.dupe(attribution.Run, &.{.{ .start_line = 0, .len = n, .prov = if (accepted) p.agent_rec else p.human_rec }}) };
        try p.files.append(p.arena, try manifest_mod.encodeFile(p.arena, path, blob, map));
    }

    /// A text file: side lines keep the sides' attribution, resolver
    /// lines (`written`) get the agent's or the human's record.
    fn textFile(p: *Provenance, f: ConflictFile, blob: ObjectId, result: []const u8, written: []const Span) !void {
        try p.done.put(p.arena, f.path, {});
        var sides: [2]remap.SideText = undefined;
        for (&sides, 0..) |*side, k| {
            var text: std.ArrayList(u8) = .empty;
            for (f.hunks) |h| switch (h) {
                .resolved => |x| try text.appendSlice(p.arena, x),
                .conflict => |cm| try text.appendSlice(p.arena, cm.values[2 * k]),
            };
            side.* = .{ .text = text.items };
            const fa = if (p.sides[k]) |m| m.find(f.path) else null;
            if (fa) |x| if (f.entries[2 * k]) |e| if (x.blob.eql(e.id)) {
                const m = try x.map(p.arena);
                if (m.lineCount() == attribution.lineCountOf(text.items)) side.map = m;
            };
        }
        const parent = try remap.readFile(p.ctx.store, p.arena, p.parent_tree, f.path);
        const merged = try remap.attributionForMerge(p.ctx.gpa, p.arena, if (parent) |x| x.text else null, &sides, result, attribution.inherited);
        var b = try attribution.Builder.initFrom(p.ctx.gpa, merged);
        defer b.deinit();
        for (written) |w| try b.splice(w.start, w.len, w.len, if (w.accepted) p.agent_rec else p.human_rec, false);
        const map = try b.toMap(p.arena);
        if (map.allInherited()) return;
        try p.files.append(p.arena, try manifest_mod.encodeFile(p.arena, f.path, blob, map));
    }

    /// The manifest: the resolved files, plus the conflicted change's
    /// entries for files the resolution did not touch.
    fn finish(p: *Provenance) !?ObjectId {
        if (p.old) |m| for (m.files) |fa| {
            if (!p.done.contains(fa.path)) try p.files.append(p.arena, fa);
        };
        if (p.files.items.len == 0) return null;
        manifest_mod.sortFiles(p.files.items);
        return try manifest_mod.write(p.ctx.batch, p.ctx.gpa, .{ .files = p.files.items });
    }
};

fn findRegion(set: *const ConflictSet, path: []const u8, idx: u32) ?usize {
    for (set.regions, 0..) |r, i| {
        if (r.region_idx == idx and std.mem.eql(u8, r.path, path)) return i;
    }
    return null;
}

test {
    _ = @import("resolve_test.zig");
}
