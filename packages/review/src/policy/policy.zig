//! The edit policy (E12.F05.S01.T01): whether a proposed file change is
//! applied at once, queued for review, or refused.
//!
//! Per file, first answer wins:
//! 1. E16 says deny (a deny rule, `plan` mode, managed policy), or the
//!    mode is `plan`: deny, with E16's message.
//! 2. E16's managed policy says ask: review (organisation policy cannot
//!    be weakened).
//! 3. A protected path (`protected.zig` and `review.protected`): review.
//! 4. The permission mode: `accept_edits` or `bypass` auto-applies
//!    creates and modifications inside the workspace (deletes, renames
//!    and mode changes go on to the rules); `dont_ask` queues.
//! 5. The first matching `review_required` rule: review.
//! 6. The first matching `auto_accept` or `review` rule.
//! 7. Review.
//! A rename's old and new paths must both pass. E16 is asked through
//! `SecurityProbe`, which must have no side effects (it never presents an
//! approval); without one the policy fails closed (review).
//!
//! `autoApply` lands the auto-applied files of a submitted changeset and
//! rejects the denied ones; `recentlyAutoApplied` lists what landed so
//! the user can revert it (`Applier.undoApply`). `editorPolicy` answers
//! E05's `ApplyPolicy` for edits to open documents.

const std = @import("std");
const zg_ignore = @import("zg_ignore");
const zg_editor = @import("zg_editor");
const model = @import("../model/root.zig");
const apply = @import("../apply/root.zig");
const rules_mod = @import("rules.zig");
const protected = @import("protected.zig");

const Allocator = std.mem.Allocator;
const GlobSet = zg_ignore.GlobSet;
const Rule = rules_mod.Rule;
const Op = rules_mod.Op;
const OriginKind = rules_mod.OriginKind;
const agent_edit = zg_editor.model.api.agent_edit;
const DocHandle = zg_editor.model.api.registry.DocHandle;

/// E16's permission modes (`zg_security.contracts.PermissionMode`); the
/// app's probe maps them one to one.
pub const Mode = enum { default, accept_edits, plan, dont_ask, bypass };

/// Which E16 layer decided (`zg_security.policy.Step`, reduced).
pub const ProbeLayer = enum { managed, deny_rule, bypass, protected_path, mode, rule, default };

pub const ProbeResult = struct {
    kind: enum { allow, ask, deny },
    layer: ProbeLayer,
    message: []const u8 = "",
};

/// E16, asked about a write without presenting anything.
pub const SecurityProbe = struct {
    ctx: *anyopaque,
    probe: *const fn (ctx: *anyopaque, session: ?u128, path: []const u8, op: Op) ProbeResult,
    mode: *const fn (ctx: *anyopaque, session: ?u128) Mode,

    /// No E16: everything asks, the mode is `default`.
    pub const fail_closed: SecurityProbe = .{ .ctx = @constCast(@as(*const anyopaque, &{})), .probe = askAll, .mode = defaultMode };

    fn askAll(_: *anyopaque, _: ?u128, _: []const u8, _: Op) ProbeResult {
        return .{ .kind = .ask, .layer = .default };
    }

    fn defaultMode(_: *anyopaque, _: ?u128) Mode {
        return .default;
    }
};

/// Counts the lines of a file's base (deletes); null when unknown.
pub const LineCounter = struct {
    ctx: *anyopaque,
    lines: *const fn (ctx: *anyopaque, base: model.BaseRef) ?u32,
};

/// Who proposes: from the changeset's provenance plus what the caller
/// knows.
pub const PolicyCtx = struct {
    origin: OriginKind,
    session: ?u128 = null,
    agent_name: ?[]const u8 = null,
    tool: ?[]const u8 = null,
    security: SecurityProbe = .fail_closed,
    lines: ?LineCounter = null,

    /// The origin and session of `cs`.
    pub fn of(cs: *const model.Changeset) PolicyCtx {
        return .{ .origin = std.meta.activeTag(cs.prov.origin), .session = if (cs.prov.origin.agentRef()) |r| r.session else null };
    }
};

pub const Action = enum { auto_apply, review, deny };

/// Which step decided.
pub const Step = enum { security_deny, plan_mode, managed, protected_path, mode, rule, default };

pub const Verdict = struct {
    action: Action,
    step: Step,
    /// The settings index of the deciding rule.
    rule: ?u32 = null,
    /// Static, or E16's message (borrowed from the probe).
    reason: []const u8,
};

pub const ReviewPolicy = struct {
    gpa: Allocator,
    rules: []Rule,
    protected: GlobSet,
    diagnostics: []const rules_mod.Diagnostic,
    arena: std.heap.ArenaAllocator,

    /// Compiles `settings`; invalid rules are left out and reported in
    /// `diagnostics`.
    pub fn init(gpa: Allocator, settings: rules_mod.Settings) Allocator.Error!*ReviewPolicy {
        const p = try gpa.create(ReviewPolicy);
        errdefer gpa.destroy(p);
        p.* = .{ .gpa = gpa, .rules = &.{}, .protected = undefined, .diagnostics = &.{}, .arena = .init(gpa) };
        errdefer p.arena.deinit();
        const a = p.arena.allocator();
        var diags: std.ArrayList(rules_mod.Diagnostic) = .empty;
        var list: std.ArrayList(Rule) = .empty;
        errdefer {
            for (list.items) |*r| rules_mod.deinit(r);
            list.deinit(gpa);
        }
        for (settings.rules, 0..) |cfg, i| {
            const cfg_copy: rules_mod.RuleConfig = .{
                .paths = try dupeList(a, cfg.paths),
                .tools = try dupeList(a, cfg.tools),
                .agents = try dupeList(a, cfg.agents),
                .origins = try a.dupe(OriginKind, cfg.origins),
                .ops = try a.dupe(Op, cfg.ops),
                .max_changed_lines = cfg.max_changed_lines,
                .action = cfg.action,
            };
            if (try rules_mod.compile(gpa, cfg_copy, @intCast(i), a, &diags)) |r| try list.append(gpa, r);
        }
        var prot: std.ArrayList([]const u8) = .empty;
        try prot.appendSlice(a, &protected.default_protected);
        for (settings.protected) |x| {
            var one = GlobSet.compile(gpa, x, .{}) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    try diags.append(a, .{ .rule = null, .message = try std.fmt.allocPrint(a, "protected path \"{s}\" is invalid ({t}); ignored", .{ x, e }) });
                    continue;
                },
            };
            one.deinit();
            try prot.append(a, x);
        }
        p.protected = rules_mod.compileList(gpa, prot.items) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            // Each entry compiled on its own above.
            else => unreachable,
        };
        p.rules = try list.toOwnedSlice(gpa);
        p.diagnostics = diags.items;
        return p;
    }

    pub fn deinit(p: *ReviewPolicy) void {
        const gpa = p.gpa;
        for (p.rules) |*r| rules_mod.deinit(r);
        gpa.free(p.rules);
        p.protected.deinit();
        p.arena.deinit();
        gpa.destroy(p);
    }

    /// The verdict for one file of a change (see the file comment).
    pub fn decide(p: *const ReviewPolicy, ctx: PolicyCtx, s: rules_mod.Subject) Verdict {
        const sec = ctx.security;
        const mode = sec.mode(sec.ctx, ctx.session);
        // 1–2. E16, for every path the change writes.
        var managed_ask = false;
        for ([_]?[]const u8{ s.path, s.from }) |maybe| {
            const path = maybe orelse continue;
            const r = sec.probe(sec.ctx, ctx.session, path, s.op);
            if (r.kind == .deny) return .{ .action = .deny, .step = .security_deny, .reason = if (r.message.len > 0) r.message else "denied by the security policy" };
            if (r.kind == .ask and r.layer == .managed) managed_ask = true;
        }
        if (mode == .plan) return .{ .action = .deny, .step = .plan_mode, .reason = "plan mode: edits are not allowed" };
        if (managed_ask) return .{ .action = .review, .step = .managed, .reason = "the managed policy requires review" };
        // 3.
        if (p.isProtected(s.path) or (if (s.from) |f| p.isProtected(f) else false))
            return .{ .action = .review, .step = .protected_path, .reason = "protected path" };
        // 4.
        switch (mode) {
            .accept_edits, .bypass => if ((s.op == .create or s.op == .modify) and inWorkspace(s.path))
                return .{ .action = .auto_apply, .step = .mode, .reason = if (mode == .bypass) "bypass mode" else "accept-edits mode" },
            .dont_ask => return .{ .action = .review, .step = .mode, .reason = "don't-ask mode queues edits" },
            .default, .plan => {},
        }
        // 5–6.
        for (p.rules) |*r| if (r.action == .review_required and rules_mod.matches(r, s))
            return .{ .action = .review, .step = .rule, .rule = r.index, .reason = "a review_required rule matched" };
        for (p.rules) |*r| if (r.action != .review_required and rules_mod.matches(r, s)) return switch (r.action) {
            .auto_accept => .{ .action = .auto_apply, .step = .rule, .rule = r.index, .reason = "an auto_accept rule matched" },
            else => .{ .action = .review, .step = .rule, .rule = r.index, .reason = "a review rule matched" },
        };
        return .{ .action = .review, .step = .default, .reason = "review by default" };
    }

    pub fn isProtected(p: *const ReviewPolicy, path: []const u8) bool {
        return p.protected.matches(path);
    }

    /// The verdict for each file of `cs`, into `out` (`cs.files.len`).
    pub fn decideChangeset(p: *const ReviewPolicy, ctx: PolicyCtx, cs: *const model.Changeset, out: []Verdict) void {
        for (cs.files, out) |*f, *v| v.* = p.decide(ctx, subjectOf(ctx, f));
    }

    /// E05's `ApplyPolicy` for edits to open documents (see `EditorPolicy`).
    pub fn editorPolicy(p: *const ReviewPolicy, e: *EditorPolicy) agent_edit.ApplyPolicy {
        e.policy = p;
        return .{ .ctx = e, .decide = EditorPolicy.decideEdit };
    }
};

/// The rule subject of `f`.
pub fn subjectOf(ctx: PolicyCtx, f: *const model.FileChange) rules_mod.Subject {
    const op: Op, const from: ?[]const u8 = switch (f.op) {
        .create => .{ .create, null },
        .modify => .{ .modify, null },
        .delete => .{ .delete, null },
        .rename => |r| .{ .rename, r.from },
        .set_executable => .{ .mode, null },
    };
    const lines: ?u32 = switch (f.op) {
        .delete => if (ctx.lines) |lc| (if (f.base) |b| lc.lines(lc.ctx, b) else null) else null,
        else => blk: {
            const n = f.countLines();
            break :blk n.added + n.removed;
        },
    };
    return .{ .path = f.path, .from = from, .op = op, .origin = ctx.origin, .tool = ctx.tool, .agent = ctx.agent_name, .changed_lines = lines };
}

fn inWorkspace(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or path[0] == '~') return false;
    if (path.len >= 2 and path[1] == ':') return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| if (std.mem.eql(u8, seg, "..")) return false;
    return true;
}

fn dupeList(a: Allocator, xs: []const []const u8) Allocator.Error![]const []const u8 {
    const out = try a.alloc([]const u8, xs.len);
    for (xs, out) |x, *o| o.* = try a.dupe(u8, x);
    return out;
}

/// E05 `ApplyPolicy` adapter: an edit to an open document is a `modify`
/// of its path. The line count is unknown (rules with a limit do not
/// auto-apply it). `pending` is answered for review.
pub const EditorPolicy = struct {
    policy: *const ReviewPolicy = undefined,
    /// The workspace root (absolute, `/`-separated) the document URIs are under.
    root: []const u8,
    /// The policy context of an E05 agent-edit session.
    ctx_of: *const fn (ctx: *anyopaque, session: u64, tool: []const u8) PolicyCtx,
    ctx: *anyopaque,

    fn decideEdit(ctx: *anyopaque, session: u64, _: DocHandle, summary: agent_edit.ProposalSummary) agent_edit.Decision {
        const e: *EditorPolicy = @ptrCast(@alignCast(ctx));
        const rel = e.relative(summary.uri) orelse return .pending;
        const v = e.policy.decide(e.ctx_of(e.ctx, session, summary.tool), .{
            .path = rel,
            .op = .modify,
            .origin = .agent,
            .tool = summary.tool,
            .changed_lines = null,
        });
        return switch (v.action) {
            .auto_apply => .apply,
            .review => .pending,
            .deny => .deny,
        };
    }

    /// `uri` (a path or a `file://` URI) relative to the root.
    fn relative(e: *const EditorPolicy, uri: []const u8) ?[]const u8 {
        const path = if (std.mem.startsWith(u8, uri, "file://")) uri["file://".len..] else uri;
        if (path.len <= e.root.len + 1 or !std.mem.startsWith(u8, path, e.root) or path[e.root.len] != '/') return null;
        return path[e.root.len + 1 ..];
    }
};

pub const AutoApplyResult = struct {
    auto_applied: u32 = 0,
    denied: u32 = 0,
    /// The `History` record of what landed.
    apply: ?u64 = null,
    /// The apply failed (and was rolled back); nothing was decided.
    failed: ?anyerror = null,
};

/// Lands the files of a submitted changeset that the policy auto-applies
/// and rejects the ones it denies, as one apply; the others stay pending.
/// Marks the changeset `auto_applied` when something landed. Owner thread.
pub fn autoApply(p: *const ReviewPolicy, ctx: PolicyCtx, ap: *apply.Applier, cs_id: model.ChangesetId, arena: Allocator) !AutoApplyResult {
    const cs = ap.q.get(cs_id) orelse return error.UnknownChangeset;
    const verdicts = try arena.alloc(Verdict, cs.files.len);
    p.decideChangeset(ctx, cs, verdicts);
    var items: std.ArrayList(apply.ApplyItem) = .empty;
    var out: AutoApplyResult = .{};
    for (verdicts, 0..) |v, i| switch (v.action) {
        .auto_apply => {
            try items.append(arena, .{ .file = @intCast(i), .whole_file = .accept });
            out.auto_applied += 1;
        },
        .deny => {
            try items.append(arena, .{ .file = @intCast(i), .whole_file = .reject });
            out.denied += 1;
        },
        .review => {},
    };
    if (items.items.len == 0) return out;
    switch (try ap.apply(.{ .cs = cs_id, .items = items.items })) {
        .ok => |ok| {
            out.apply = ok.apply;
            if (out.auto_applied > 0) {
                const m = ap.q.getMut(cs_id).?;
                m.auto_applied = true;
                ap.q.persist(cs_id);
            }
        },
        .failed => |f| return .{ .failed = f.err },
    }
    return out;
}

/// Changesets that auto-applied something within `window_ms` of
/// `now_ms`, newest first.
pub fn recentlyAutoApplied(q: *const model.Queue, now_ms: i64, window_ms: i64, gpa: Allocator, out: *std.ArrayList(model.ChangesetId)) Allocator.Error!void {
    const all = q.changesets.values();
    var i = all.len;
    while (i > 0) {
        i -= 1;
        const cs = all[i];
        if (!cs.auto_applied) continue;
        if ((cs.decided_ms orelse cs.created_ms) < now_ms - window_ms) continue;
        try out.append(gpa, cs.id);
    }
}
