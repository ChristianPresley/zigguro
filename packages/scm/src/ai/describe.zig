//! The describe pipeline (E09.F06.S01.T01): AI-written change
//! descriptions from a token-budgeted context, reviewed before they apply.
//!
//! `Describer.buildContext` gathers, in priority order, the change's
//! statistics, the intent of the agent sessions that made it (from E10
//! through `IntentPort`) and its current description, the subjects of the
//! last 20 trunk changes touching the same top-level paths plus the
//! repo's CONTRIBUTING rules, and the unified diff cut to what is left
//! (`context.budgetDiff`: generated and lock files first, then the
//! lowest-ranked hunks). Every section passes through the `SecretPort`
//! (E16) before it reaches the prompt (`prompts/describe.md`).
//!
//! `generate` streams the reply to the caller's sink as it arrives,
//! parses the JSON (`schemas/describe.schema.json`, or a "subject, blank
//! line, body" text fallback) and validates it (`validateDescription`).
//! `Agent-Session` and `Model` trailers come from the sessions, never
//! from the model. `propose` rewrites the change in a preview operation
//! and submits a `describe` proposal to review, or adopts it at once
//! under `auto_apply`.
//!
//! Approving a description the reviewer edited goes through `redescribe`:
//! the proposal's preview is rewritten with the reviewer's text and then
//! adopted, in one adopt like an unedited approval. The preview's commit
//! `target` is rewritten with the new description (its descendants in
//! the preview are restacked) as a new detached operation on top of the
//! proposal's preview. It is adopted against the proposal's base, so the
//! op log shows the preview, the edit and the adoption. On `.conflicted`
//! the edited preview is dropped and the original stays, so the reviewer
//! can decide again; once adopted, both previews are gone.

const std = @import("std");
const id_mod = @import("../store/id.zig");
const object = @import("../store/object.zig");
const chunker = @import("../store/chunker.zig");
const op_mod = @import("../oplog/operation.zig");
const repo_mod = @import("../oplog/repo.zig");
const preview = @import("../oplog/preview.zig");
const adopt_mod = @import("../oplog/adopt.zig");
const rebase = @import("../oplog/rebase.zig");
const ports = @import("ports.zig");
const context = @import("context.zig");
const prompts = @import("prompts.zig");
const proposal_files = @import("proposal_files.zig");
const ObjectId = id_mod.ObjectId;
const Change = object.Change;
const Repo = repo_mod.Repo;
const OpMeta = op_mod.OpMeta;
const DetachedOp = preview.DetachedOp;
const Allocator = std.mem.Allocator;

/// The prompt template.
pub const template = @embedFile("prompts/describe.md");
/// The reply's JSON schema.
pub const reply_schema = @embedFile("schemas/describe.schema.json");
pub const system_prompt = "You write change descriptions (commit messages) for a version control system.";

pub const Style = enum { plain, conventional };

pub const DescribeOptions = struct {
    style: Style = .plain,
    max_subject: u8 = 72,
    /// Add `Agent-Session` and `Model` trailers from the sessions.
    add_trailers: bool = true,
    include_sessions: bool = true,
    language: ?[]const u8 = null,
    max_input_tokens: u32 = 24_000,
    max_output_tokens: u32 = 1024,
    /// Adopt the description at once instead of submitting it for review.
    auto_apply: bool = false,
    /// The bookmark whose history shows the repo's conventions.
    trunk: []const u8 = "main",
    /// The model writing, recorded in the proposal's provenance.
    model: []const u8 = "",
};

pub const Trailer = struct { key: []const u8, value: []const u8 };

pub const DescribeOutput = struct {
    subject: []const u8,
    body: []const u8 = "",
    trailers: []const Trailer = &.{},
    confidence: f32 = 0,

    /// The description: subject, body and trailers.
    pub fn text(o: DescribeOutput, arena: Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, o.subject);
        const body = std.mem.trim(u8, o.body, " \t\r\n");
        if (body.len > 0) try out.print(arena, "\n\n{s}", .{body});
        if (o.trailers.len > 0) {
            try out.appendSlice(arena, "\n");
            for (o.trailers, 0..) |tr, i| try out.print(arena, "{s}{s}: {s}", .{ if (i == 0) "\n" else "\n", tr.key, tr.value });
        }
        try out.append(arena, '\n');
        return out.items;
    }
};

/// An agent session that made (part of) a change, from E10.
pub const SessionInfo = struct {
    id: []const u8,
    title: []const u8 = "",
    task_statement: []const u8 = "",
    final_summary: []const u8 = "",
    model: []const u8 = "",
};

/// Implemented by E10: the sessions in a change's provenance.
pub const IntentPort = struct {
    ctx: *anyopaque,
    sessions: *const fn (ctx: *anyopaque, arena: Allocator, change: ObjectId, c: *const Change) anyerror![]const SessionInfo,
};

/// Implemented by E16: masks secrets in text going to or coming from a
/// model.
pub const SecretPort = struct {
    ctx: *anyopaque,
    /// `text` with secrets masked (the same slice when it has none).
    redact: *const fn (ctx: *anyopaque, arena: Allocator, text: []const u8) anyerror![]const u8,

    fn apply(p: SecretPort, arena: Allocator, text: []const u8) ![]const u8 {
        return p.redact(p.ctx, arena, text);
    }
};

pub const Issues = packed struct {
    empty_subject: bool = false,
    /// Lines after the first moved into the body.
    multiline_subject: bool = false,
    /// Cut at a word boundary to `max_subject`.
    subject_truncated: bool = false,
    /// Not `type(scope): ...` with a known type (conventional style).
    bad_type: bool = false,
    /// Secrets were masked.
    secret: bool = false,

    pub fn any(i: Issues) bool {
        return @as(u5, @bitCast(i)) != 0;
    }
};

pub const Validated = struct {
    output: DescribeOutput,
    issues: Issues = .{},
};

const conventional_types = [_][]const u8{ "feat", "fix", "docs", "style", "refactor", "perf", "test", "build", "ci", "chore", "revert" };

/// Checks and normalizes `out`: one non-empty subject line within
/// `max_subject` bytes (cut at a word boundary), a known conventional
/// type when asked for, and no secrets (masked through `secrets`).
pub fn validateDescription(arena: Allocator, out: DescribeOutput, o: DescribeOptions, secrets: ?SecretPort) !Validated {
    var v: Validated = .{ .output = out };
    var subject = std.mem.trim(u8, out.subject, " \t\r\n");
    var body = std.mem.trim(u8, out.body, " \t\r\n");
    if (std.mem.indexOfScalar(u8, subject, '\n')) |nl| {
        v.issues.multiline_subject = true;
        const rest = std.mem.trim(u8, subject[nl + 1 ..], " \t\r\n");
        body = if (body.len == 0) rest else try std.mem.concat(arena, u8, &.{ rest, "\n\n", body });
        subject = std.mem.trimEnd(u8, subject[0..nl], " \t\r");
    }
    if (subject.len > o.max_subject) {
        v.issues.subject_truncated = true;
        var end: usize = o.max_subject;
        while (end > 0 and (subject[end] & 0xc0) == 0x80) end -= 1;
        if (std.mem.lastIndexOfScalar(u8, subject[0..end], ' ')) |sp| {
            if (sp > end / 2) end = sp;
        }
        subject = std.mem.trimEnd(u8, subject[0..end], " ,;:-");
    }
    if (subject.len == 0) v.issues.empty_subject = true;
    if (o.style == .conventional and !conventionalSubject(subject)) v.issues.bad_type = true;
    if (secrets) |sp| {
        const s2 = try sp.apply(arena, subject);
        const b2 = try sp.apply(arena, body);
        if (!std.mem.eql(u8, s2, subject) or !std.mem.eql(u8, b2, body)) v.issues.secret = true;
        subject = s2;
        body = b2;
        const trs = try arena.dupe(Trailer, out.trailers);
        for (trs) |*tr| {
            const x = try sp.apply(arena, tr.value);
            if (!std.mem.eql(u8, x, tr.value)) v.issues.secret = true;
            tr.value = x;
        }
        v.output.trailers = trs;
    }
    v.output.subject = subject;
    v.output.body = body;
    v.output.confidence = std.math.clamp(out.confidence, 0, 1);
    return v;
}

fn conventionalSubject(subject: []const u8) bool {
    const colon = std.mem.indexOf(u8, subject, ": ") orelse return false;
    var head = subject[0..colon];
    if (head.len > 0 and head[head.len - 1] == '!') head = head[0 .. head.len - 1];
    if (std.mem.indexOfScalar(u8, head, '(')) |p| {
        if (head[head.len - 1] != ')' or p + 2 > head.len - 1) return false;
        head = head[0..p];
    }
    for (conventional_types) |ty| if (std.mem.eql(u8, ty, head)) return colon + 2 < subject.len;
    return false;
}

const reserved_trailers = [_][]const u8{ "Agent-Session", "Model" };

/// The model's trailers without reserved keys, then one `Agent-Session`
/// per session and one `Model` per distinct model.
fn mergeTrailers(arena: Allocator, model: []const Trailer, sessions: []const SessionInfo, add: bool) ![]const Trailer {
    if (!add) return &.{};
    var out: std.ArrayList(Trailer) = .empty;
    outer: for (model) |tr| {
        for (reserved_trailers) |r| if (std.ascii.eqlIgnoreCase(r, tr.key)) continue :outer;
        if (tr.key.len == 0 or std.mem.indexOfAny(u8, tr.key, " :\n") != null) continue;
        if (std.mem.indexOfScalar(u8, tr.value, '\n') != null) continue;
        try out.append(arena, tr);
    }
    for (sessions) |s| try out.append(arena, .{ .key = "Agent-Session", .value = s.id });
    for (sessions, 0..) |s, i| {
        if (s.model.len == 0) continue;
        for (sessions[0..i]) |p| {
            if (std.mem.eql(u8, p.model, s.model)) break;
        } else try out.append(arena, .{ .key = "Model", .value = s.model });
    }
    return out.items;
}

pub const DescribeContext = struct {
    request: ports.AiRequest,
    budget: context.ContextBudget,
    stats: context.Stats,
    sessions: []const SessionInfo,
    /// Estimated tokens of the system prompt and message.
    tokens: u32,
    /// Diff hunks left out (generated files count once).
    omitted_hunks: u32,
};

/// What `propose` did.
pub const Proposed = struct {
    validated: Validated,
    /// The preview operation (already adopted under `auto_apply`).
    preview: DetachedOp,
    /// The described commit, in the preview's view.
    commit: ObjectId,
    outcome: union(enum) {
        in_review: ports.ReviewId,
        /// The op head after adopting.
        applied: ObjectId,
    },
};

pub const Describer = struct {
    repo: *Repo,
    model: ports.ModelPort,
    review: ?ports.ReviewPort = null,
    intent: ?IntentPort = null,
    secrets: ?SecretPort = null,
    /// The model's error message after `error.ModelError`.
    last_error: []const u8 = "",

    /// The request for describing `change`, allocated in `arena`.
    pub fn buildContext(d: *Describer, arena: Allocator, change: ObjectId, o: DescribeOptions) !DescribeContext {
        const store = d.repo.store;
        const c = try op_mod.read(Change, store, arena, change);
        const parent: ?Change = if (c.parents.len > 0) try op_mod.read(Change, store, arena, c.parents[0]) else null;
        const pf: proposal_files.ProposalFiles = .{ .store = store };
        const tree = proposal_files.treeOf(c);
        const files = try pf.diffTrees(arena, if (parent) |p| proposal_files.treeOf(p) else null, tree);

        const fixed = context.estimateTokens(system_prompt) + context.estimateTokens(template) + 64;
        const budget = context.ContextBudget.split(o.max_input_tokens -| fixed);
        var spare: u32 = 0;

        // Intent: sessions and the current description.
        var sessions: []const SessionInfo = &.{};
        if (o.include_sessions) if (d.intent) |ip| {
            sessions = try ip.sessions(ip.ctx, arena, change, &c);
        };
        var intent: std.ArrayList(u8) = .empty;
        const per_session: u32 = if (sessions.len == 0) 0 else @min(1500, budget.intent / @as(u32, @intCast(sessions.len)));
        for (sessions) |s| {
            var one: std.ArrayList(u8) = .empty;
            try one.print(arena, "### {s}\n", .{if (s.title.len > 0) s.title else s.id});
            if (s.task_statement.len > 0) try one.print(arena, "Task: {s}\n", .{s.task_statement});
            if (s.final_summary.len > 0) try one.print(arena, "Summary: {s}\n", .{s.final_summary});
            try intent.appendSlice(arena, context.truncate(one.items, per_session));
        }
        const intent_left = budget.intent -| context.estimateTokens(intent.items);
        const existing = context.truncate(std.mem.trim(u8, c.description, " \t\r\n"), @min(intent_left, 500));
        spare += intent_left -| context.estimateTokens(existing);

        // Conventions: trunk subjects nearby, and CONTRIBUTING.
        const subjects = try d.trunkSubjects(arena, files, o.trunk, budget.conventions);
        var conv_left = budget.conventions -| context.estimateTokens(subjects);
        var contributing: []const u8 = "";
        if (tree) |tid| {
            for ([_][]const u8{ "CONTRIBUTING.md", "CONTRIBUTING", "CONTRIBUTING.txt" }) |name| {
                const text = (try rootFile(arena, store, tid, name)) orelse continue;
                contributing = context.truncate(text[0..@min(text.len, 2000)], conv_left);
                break;
            }
        }
        conv_left -|= context.estimateTokens(contributing);
        spare += conv_left;

        // The diff gets the rest.
        const attrs = if (tree) |tid| (try rootFile(arena, store, tid, ".gitattributes")) orelse "" else "";
        const patterns = try context.generatedPatterns(arena, attrs);
        const diff = try context.budgetDiff(arena, files, patterns, budget.diff + spare);

        const stats = try std.fmt.allocPrint(arena, "{d} file{s} changed, {d} insertion{s}(+), {d} deletion{s}(-)", .{
            diff.stats.files,      plural(diff.stats.files),
            diff.stats.insertions, plural(diff.stats.insertions),
            diff.stats.deletions,  plural(diff.stats.deletions),
        });
        var max_subject: [4]u8 = undefined;
        const vars = [_]prompts.Var{
            .{ .name = "conventional", .value = if (o.style == .conventional) "yes" else "" },
            .{ .name = "max_subject", .value = std.fmt.bufPrint(&max_subject, "{d}", .{o.max_subject}) catch unreachable },
            .{ .name = "language", .value = o.language orelse "" },
            .{ .name = "stats", .value = stats },
            .{ .name = "existing", .value = try d.redact(arena, existing) },
            .{ .name = "intent", .value = try d.redact(arena, intent.items) },
            .{ .name = "conventions", .value = try d.redact(arena, subjects) },
            .{ .name = "contributing", .value = try d.redact(arena, contributing) },
            .{ .name = "diff", .value = try d.redact(arena, diff.text) },
        };
        const user = try prompts.render(arena, template, &vars);
        const msgs = try arena.dupe(ports.AiMessage, &.{.{ .role = .user, .text = user }});
        return .{
            .request = .{
                .system = system_prompt,
                .messages = msgs,
                .json_schema = reply_schema,
                .max_input_tokens = o.max_input_tokens,
                .max_output_tokens = o.max_output_tokens,
            },
            .budget = budget,
            .stats = diff.stats,
            .sessions = sessions,
            .tokens = context.estimateTokens(system_prompt) + context.estimateTokens(user),
            .omitted_hunks = diff.omitted,
        };
    }

    fn redact(d: *Describer, arena: Allocator, text: []const u8) ![]const u8 {
        const sp = d.secrets orelse return text;
        if (text.len == 0) return text;
        return sp.apply(arena, text);
    }

    /// Up to 20 subjects of first-parent trunk changes touching the
    /// top-level paths `files` touch, newest first, within `budget`.
    fn trunkSubjects(d: *Describer, arena: Allocator, files: []const proposal_files.FileChange, trunk: []const u8, budget: u32) ![]const u8 {
        const store = d.repo.store;
        var cur = d.repo.view().bookmark(trunk).asNormal() orelse return "";
        var tops: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (files) |f| {
            const end = std.mem.indexOfScalar(u8, f.path, '/') orelse f.path.len;
            try tops.put(arena, f.path[0..end], {});
        }
        var out: std.ArrayList(u8) = .empty;
        var found: usize = 0;
        var walked: usize = 0;
        while (found < 20 and walked < 200) : (walked += 1) {
            const c = try op_mod.read(Change, store, arena, cur);
            if (c.parents.len == 0) break;
            const p = try op_mod.read(Change, store, arena, c.parents[0]);
            if (try touchesTops(arena, store, proposal_files.treeOf(p), proposal_files.treeOf(c), tops.keys())) {
                const subject = std.mem.sliceTo(std.mem.trim(u8, c.description, " \t\r\n"), '\n');
                if (subject.len > 0) {
                    const line = try std.fmt.allocPrint(arena, "- {s}\n", .{subject});
                    if (context.estimateTokens(out.items) + context.estimateTokens(line) > budget) break;
                    try out.appendSlice(arena, line);
                    found += 1;
                }
            }
            cur = c.parents[0];
        }
        return out.items;
    }

    /// Streams the reply to `ui` (if any) and returns it validated, with
    /// the provenance trailers.
    pub fn generate(d: *Describer, arena: Allocator, ctx: *const DescribeContext, o: DescribeOptions, ui: ?*ports.AiSink) !Validated {
        var fwd: Forward = .{ .arena = arena, .ui = ui };
        var sink = fwd.sink();
        try d.model.call(&ctx.request, &sink);
        if (fwd.err) |e| {
            d.last_error = e;
            return error.ModelError;
        }
        if (fwd.oom) return error.OutOfMemory;
        switch (fwd.stop orelse .end) {
            .cancelled => return error.Cancelled,
            .max_tokens => return error.CutOff,
            .end => {},
        }
        const out = try parseReply(arena, fwd.json.items, fwd.text.items);
        var v = try validateDescription(arena, out, o, d.secrets);
        v.output.trailers = try mergeTrailers(arena, v.output.trailers, ctx.sessions, o.add_trailers);
        return v;
    }

    /// Describes `change`: generates, then rewrites it in a preview and
    /// submits that to review, or adopts it under `auto_apply`.
    pub fn propose(d: *Describer, arena: Allocator, change: ObjectId, o: DescribeOptions, meta: OpMeta, ui: ?*ports.AiSink) !Proposed {
        if (!o.auto_apply and d.review == null) return error.NoReviewPort;
        const ctx = try d.buildContext(arena, change, o);
        const v = try d.generate(arena, &ctx, o, ui);
        if (v.issues.empty_subject) return error.EmptyDescription;
        const text = try v.output.text(arena);

        const tx = try d.repo.startTransaction(meta);
        var tx_live = true;
        errdefer if (tx_live) tx.discard();
        const m = tx.mutRepo();
        var c = try m.readChange(tx.arena(), change);
        c.description = try tx.arena().dupe(u8, text);
        c.sig = null;
        const new = try m.rewriteChange(change, c);
        _ = try m.rebaseDescendants(rebase.reparent, null);
        tx_live = false;
        const dop = try preview.commitDetached(tx, .proposal);

        if (o.auto_apply) {
            var res = adopt_mod.adopt(d.repo, dop, meta) catch |e| {
                preview.discard(d.repo, dop.op);
                return e;
            };
            defer res.deinit();
            switch (res) {
                .adopted => |head| return .{ .validated = v, .preview = dop, .commit = new, .outcome = .{ .applied = head } },
                .conflicted => {
                    preview.discard(d.repo, dop.op);
                    return error.Conflicted;
                },
            }
        }
        const session: []const u8 = if (ctx.sessions.len > 0) ctx.sessions[0].id else "";
        const p: ports.Proposal = .{
            .kind = .describe,
            .preview_op = dop,
            .summary = v.output.subject,
            .changes = (&new)[0..1],
            .provenance = .{ .actor = .{ .kind = .agent, .session = session }, .model = o.model },
        };
        const id = d.review.?.submitProposal(&p) catch |e| {
            preview.discard(d.repo, dop.op);
            return e;
        };
        return .{ .validated = v, .preview = dop, .commit = new, .outcome = .{ .in_review = id } };
    }
};

fn plural(n: u32) []const u8 {
    return if (n == 1) "" else "s";
}

/// A root-level file of tree `tree`, or null.
fn rootFile(arena: Allocator, store: anytype, tree: ObjectId, name: []const u8) !?[]const u8 {
    const tr = try op_mod.read(object.Tree, store, arena, tree);
    const e = tr.find(name) orelse return null;
    if (e.kind != .file and e.kind != .executable) return null;
    var buf: [16 << 10]u8 = undefined;
    var br = try chunker.blobReader(store, e.id, &buf);
    defer br.deinit();
    return try br.interface.readAlloc(arena, @intCast(@min(br.size, 64 << 10)));
}

/// Whether trees `a` and `b` differ at any of the top-level names.
fn touchesTops(arena: Allocator, store: anytype, a: ?ObjectId, b: ?ObjectId, tops: []const []const u8) !bool {
    if (a != null and b != null and a.?.eql(b.?)) return false;
    const ta: object.Tree = if (a) |x| try op_mod.read(object.Tree, store, arena, x) else .{ .entries = &.{} };
    const tb: object.Tree = if (b) |x| try op_mod.read(object.Tree, store, arena, x) else .{ .entries = &.{} };
    for (tops) |name| {
        const x = ta.find(name);
        const y = tb.find(name);
        if (x == null and y == null) continue;
        if (x == null or y == null or x.?.kind != y.?.kind or !x.?.id.eql(y.?.id)) return true;
    }
    return false;
}

const Answer = struct {
    subject: []const u8,
    body: []const u8 = "",
    trailers: []const Trailer = &.{},
    confidence: f32 = 0,
};

/// The reply as JSON (structured or in the text), else "subject, blank
/// line, body" text.
fn parseReply(arena: Allocator, json: []const u8, text: []const u8) !DescribeOutput {
    const doc = if (json.len > 0) json else stripFences(text);
    if (std.json.parseFromSliceLeaky(Answer, arena, doc, .{ .ignore_unknown_fields = true, .allocate = .alloc_always })) |a| {
        return .{ .subject = a.subject, .body = a.body, .trailers = a.trailers, .confidence = a.confidence };
    } else |_| {}
    if (json.len > 0 and text.len == 0) return error.Malformed;
    const plain = std.mem.trim(u8, text, " \t\r\n");
    const nl = std.mem.indexOfScalar(u8, plain, '\n') orelse return .{ .subject = plain };
    return .{ .subject = plain[0..nl], .body = std.mem.trim(u8, plain[nl + 1 ..], " \t\r\n") };
}

fn stripFences(text: []const u8) []const u8 {
    var s = std.mem.trim(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, s, "```")) return s;
    const nl = std.mem.indexOfScalar(u8, s, '\n') orelse return s;
    s = s[nl + 1 ..];
    if (std.mem.lastIndexOf(u8, s, "```")) |end| s = s[0..end];
    return std.mem.trim(u8, s, " \t\r\n");
}

/// Gathers a reply and forwards each chunk to the caller's sink as it
/// arrives.
const Forward = struct {
    arena: Allocator,
    ui: ?*ports.AiSink,
    text: std.ArrayList(u8) = .empty,
    json: std.ArrayList(u8) = .empty,
    stop: ?ports.StopReason = null,
    err: ?[]const u8 = null,
    oom: bool = false,

    fn sink(f: *Forward) ports.AiSink {
        return .{ .ctx = f, .onText = onText, .onJson = onJson, .onDone = onDone, .onError = onError };
    }

    fn of(ctx: *anyopaque) *Forward {
        return @ptrCast(@alignCast(ctx));
    }

    fn onText(ctx: *anyopaque, chunk: []const u8) void {
        const f = of(ctx);
        if (f.ui) |u| u.text(chunk);
        f.text.appendSlice(f.arena, chunk) catch {
            f.oom = true;
        };
    }

    fn onJson(ctx: *anyopaque, chunk: []const u8) void {
        const f = of(ctx);
        if (f.ui) |u| u.json(chunk);
        f.json.appendSlice(f.arena, chunk) catch {
            f.oom = true;
        };
    }

    fn onDone(ctx: *anyopaque, reason: ports.StopReason, usage: ports.Usage) void {
        const f = of(ctx);
        if (f.ui) |u| u.done(reason, usage);
        f.stop = reason;
    }

    fn onError(ctx: *anyopaque, message: []const u8) void {
        const f = of(ctx);
        if (f.ui) |u| u.fail(message);
        f.err = f.arena.dupe(u8, message) catch "out of memory";
    }
};

/// Adopts preview `d` with commit `target` (in the preview's view)
/// described as `text`.
pub fn redescribe(repo: *Repo, d: DetachedOp, target: ObjectId, text: []const u8, meta: OpMeta) !adopt_mod.AdoptResult {
    _ = try preview.get(repo, d.op);
    const at = try repo.reopen(d.op, false);
    defer at.close();
    const tx = try at.startTransaction(meta);
    var tx_live = true;
    errdefer if (tx_live) tx.discard();
    const m = tx.mutRepo();
    var c = try m.readChange(tx.arena(), target);
    c.description = try tx.arena().dupe(u8, text);
    c.sig = null;
    // The edit rewrites the proposed commit (which rewrote the original).
    c.predecessors = &.{};
    _ = try m.rewriteChange(target, c);
    _ = try m.rebaseDescendants(rebase.reparent, null);
    tx_live = false;
    var edited = try preview.commitDetached(tx, d.purpose);
    // Adopt against the proposal's base: the edit sits on the preview,
    // which the repo has not seen.
    edited.base_op = d.base_op;
    var res = adopt_mod.adopt(repo, edited, meta) catch |e| {
        preview.discard(repo, edited.op);
        return e;
    };
    switch (res) {
        .adopted => preview.discard(repo, d.op),
        .conflicted => preview.discard(repo, edited.op),
    }
    _ = &res;
    return res;
}

test {
    _ = @import("describe_test.zig");
}

// ---------------------------------------------------------------- tests

const fx = @import("../oplog/test_fixture.zig");
const lt = @import("landing_test.zig");
const t = std.testing;

test "describe: edited description adopted with descendants restacked" {
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    const r0 = try f.initRepo();
    defer r0.close();
    var tx = try r0.startTransaction(fx.meta("setup"));
    var m = tx.mutRepo();
    const root = try lt.commit(m, &.{}, "root", &.{.{ "a", "1" }});
    const c1 = try lt.commit(m, &.{root}, "wip", &.{.{ "a", "2" }});
    const c2 = try lt.commit(m, &.{c1}, "top", &.{.{ "a", "3" }});
    try m.setWcCommit("default", c2);
    const r1 = try tx.commit();
    defer r1.close();

    // The AI proposes "Add two" for c1.
    tx = try r1.startTransaction(fx.meta("propose"));
    m = tx.mutRepo();
    var ch = try m.readChange(tx.arena(), c1);
    ch.description = "Add two";
    const proposed = try m.rewriteChange(c1, ch);
    _ = try m.rebaseDescendants(rebase.reparent, null);
    const d = try preview.commitDetached(tx, .proposal);

    // The reviewer edits it and approves.
    var res = try redescribe(r1, d, proposed, "Add two, edited", fx.meta("approve"));
    defer res.deinit();
    const head = res.adopted;
    const r2 = try r1.reopen(head, false);
    defer r2.close();
    const a = r2.arena_state.allocator();
    const wc = r2.view().wcCommit("default").?;
    const top = try op_mod.read(object.Change, f.store, a, wc);
    try t.expectEqualStrings("top", top.description);
    const mid = try op_mod.read(object.Change, f.store, a, top.parents[0]);
    try t.expectEqualStrings("Add two, edited", mid.description);
    try t.expectEqualSlices(ObjectId, &.{proposed}, mid.predecessors);
    try t.expect(mid.change_id.eql(ch.change_id));
    try t.expectEqual(@as(usize, 1), r2.view().heads.len);
    // Both previews are gone.
    try t.expectError(error.NotDetached, preview.get(r2, d.op));
    const left = try preview.list(r2, t.allocator);
    defer t.allocator.free(left);
    try t.expectEqual(@as(usize, 0), left.len);
}

test "describe: edit adopts over a concurrent unrelated operation" {
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    const r0 = try f.initRepo();
    defer r0.close();
    var tx = try r0.startTransaction(fx.meta("setup"));
    var m = tx.mutRepo();
    const root = try lt.commit(m, &.{}, "root", &.{.{ "a", "1" }});
    const c1 = try lt.commit(m, &.{root}, "wip", &.{.{ "a", "2" }});
    try m.setWcCommit("default", c1);
    const r1 = try tx.commit();
    defer r1.close();

    tx = try r1.startTransaction(fx.meta("propose"));
    m = tx.mutRepo();
    var ch = try m.readChange(tx.arena(), c1);
    ch.description = "Add two";
    const proposed = try m.rewriteChange(c1, ch);
    _ = try m.rebaseDescendants(rebase.reparent, null);
    const d = try preview.commitDetached(tx, .proposal);

    // Meanwhile someone adds an unrelated commit and a bookmark.
    tx = try r1.startTransaction(fx.meta("side"));
    m = tx.mutRepo();
    const side = try lt.commit(m, &.{root}, "side", &.{.{ "b", "1" }});
    var sv: ?ObjectId = side;
    try m.setBookmark("side", fx.target(&sv));
    const r2 = try tx.commit();
    defer r2.close();

    var res = try redescribe(r2, d, proposed, "Edited", fx.meta("approve"));
    defer res.deinit();
    const r3 = try r2.reopen(res.adopted, false);
    defer r3.close();
    const a = r3.arena_state.allocator();
    const wc = try op_mod.read(object.Change, f.store, a, r3.view().wcCommit("default").?);
    try t.expectEqualStrings("Edited", wc.description);
    try t.expect(r3.view().bookmark("side").asNormal().?.eql(side));
}

test "describe: conflicting edit keeps the original preview" {
    var f = try fx.Fixture.init(t.allocator);
    defer f.deinit();
    const r0 = try f.initRepo();
    defer r0.close();
    var tx = try r0.startTransaction(fx.meta("setup"));
    var m = tx.mutRepo();
    const root = try lt.commit(m, &.{}, "root", &.{.{ "a", "1" }});
    const c1 = try lt.commit(m, &.{root}, "wip", &.{.{ "a", "2" }});
    try m.setWcCommit("default", c1);
    const r1 = try tx.commit();
    defer r1.close();

    tx = try r1.startTransaction(fx.meta("propose"));
    m = tx.mutRepo();
    var ch = try m.readChange(tx.arena(), c1);
    ch.description = "Add two";
    const proposed = try m.rewriteChange(c1, ch);
    _ = try m.rebaseDescendants(rebase.reparent, null);
    const d = try preview.commitDetached(tx, .proposal);

    // Meanwhile the user rewords the same commit.
    tx = try r1.startTransaction(fx.meta("reword"));
    m = tx.mutRepo();
    ch = try m.readChange(tx.arena(), c1);
    ch.description = "Mine";
    _ = try m.rewriteChange(c1, ch);
    _ = try m.rebaseDescendants(rebase.reparent, null);
    const r2 = try tx.commit();
    defer r2.close();

    var res = try redescribe(r2, d, proposed, "Edited", fx.meta("approve"));
    defer res.deinit();
    try t.expect(res == .conflicted);
    const left = try preview.list(r2, t.allocator);
    defer t.allocator.free(left);
    try t.expectEqual(@as(usize, 1), left.len);
    try t.expect(left[0].op.eql(d.op));
}
