//! Automation definitions (E13.F02.S01.T03): one `.zigguro/automations/
//! <name>.zon` file per automation, holding its triggers (a cron schedule,
//! a one-off time, file, SCM or task events), what it runs (an agent
//! prompt or a workflow), and the policy it runs under (permission
//! profile, isolation, overlap, catch-up, budgets). Parsing, validation
//! and serialization; the loader watches the directory.

const std = @import("std");
const runs = @import("../runs/root.zig");
const cron = @import("cron.zig");
const zone = @import("zone.zig");

const Allocator = std.mem.Allocator;

pub const format_version = 1;

pub const Schedule = struct {
    cron: []const u8,
    /// Seconds of deterministic delay; null picks the default (none for
    /// schedules more frequent than every 10 minutes).
    jitter_s: ?u32 = null,
};

pub const Once = struct {
    /// Local wall time, `YYYY-MM-DD HH:MM` (or with `T`).
    at: []const u8,
};

pub const EventMask = packed struct {
    created: bool = true,
    modified: bool = true,
    deleted: bool = true,
    renamed: bool = true,
};

pub const FilesTrigger = struct {
    /// Gitignore-style globs relative to the workspace root; a leading
    /// `!` excludes (the last match wins).
    globs: []const []const u8,
    events: EventMask = .{},
    debounce_ms: u32 = 2000,
};

pub const ScmEventKind = enum { change_created, op_committed, lane_landed, conflict_detected, git_fetched, bookmark_moved };

pub const ScmTrigger = struct {
    events: []const ScmEventKind,
    /// Only changes in this revset.
    revset: ?[]const u8 = null,
};

pub const TaskEventKind = enum { created, status_changed, assigned, commented };

pub const TaskTrigger = struct {
    events: []const TaskEventKind,
    /// A task board query (`status:ready label:agent`).
    query: ?[]const u8 = null,
};

pub const Trigger = union(enum) {
    schedule: Schedule,
    once: Once,
    files: FilesTrigger,
    scm: ScmTrigger,
    task: TaskTrigger,

    /// Fires without anyone at the keyboard (all of them, today; kept for
    /// a future manual-only trigger).
    pub fn unattended(t: Trigger) bool {
        _ = t;
        return true;
    }
};

pub const AgentAction = struct {
    prompt: []const u8,
    agent_def: ?[]const u8 = null,
    skill: ?[]const u8 = null,
    skill_args: ?[]const u8 = null,
    model: ?[]const u8 = null,
};

pub const WorkflowAction = struct {
    workflow: []const u8,
    /// JSON text.
    args: ?[]const u8 = null,
};

pub const Action = union(enum) {
    agent: AgentAction,
    workflow: WorkflowAction,
};

/// What happens when a fire comes while the last run is still going.
pub const Overlap = enum { skip, queue, replace };

/// What happens to fires missed while the machine slept or the app was
/// closed: `latest` runs the most recent one once.
pub const CatchUp = enum { latest, none };

pub const Budgets = struct {
    /// Per run. Required for unattended triggers.
    max_cost_micro_usd: ?u64 = null,
    max_wall_ms: ?u64 = null,
    max_turns: ?u32 = null,
    /// Month to date across runs; fires past it are skipped.
    monthly_cap_micro_usd: ?u64 = null,
};

pub const Automation = struct {
    version: u32 = format_version,
    name: []const u8,
    description: []const u8 = "",
    enabled: bool = true,
    triggers: []const Trigger,
    action: Action,
    /// E16 permission profile.
    profile: []const u8 = "unattended-readonly",
    isolation: runs.run.Isolation = .shared,
    overlap: Overlap = .skip,
    catch_up: CatchUp = .latest,
    budgets: Budgets = .{},
    max_runs_per_hour: ?u32 = null,
    /// How many automations may trigger each other in a row.
    max_chain_depth: u8 = 3,

    pub fn hasUnattended(a: *const Automation) bool {
        for (a.triggers) |t| if (t.unattended()) return true;
        return false;
    }

    pub fn schedule(a: *const Automation) ?Schedule {
        for (a.triggers) |t| switch (t) {
            .schedule => |s| return s,
            else => {},
        };
        return null;
    }

    pub fn once(a: *const Automation) ?Once {
        for (a.triggers) |t| switch (t) {
            .once => |o| return o,
            else => {},
        };
        return null;
    }
};

/// A file that failed to parse or validate.
pub const Problem = struct {
    line: u32 = 0,
    column: u32 = 0,
    message: []const u8,
};

/// Parses ZON into `arena`. On failure `problem` says why (its message is
/// in `arena`).
pub fn parse(arena: Allocator, source: [:0]const u8, problem: *Problem) error{ OutOfMemory, Invalid }!Automation {
    var diag: std.zon.parse.Diagnostics = .{};
    defer diag.deinit(arena);
    return std.zon.parse.fromSliceAlloc(Automation, arena, source, &diag, .{ .free_on_error = false }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            var it = diag.iterateErrors();
            const first = it.next() orelse {
                problem.* = .{ .message = "invalid ZON" };
                return error.Invalid;
            };
            const loc = first.getLocation(&diag);
            problem.* = .{
                .line = @intCast(loc.line + 1),
                .column = @intCast(loc.column + 1),
                .message = try std.fmt.allocPrint(arena, "{f}", .{first.fmtMessage(&diag)}),
            };
            return error.Invalid;
        },
    };
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name, 0..) |c, i| switch (c) {
        'a'...'z', '0'...'9' => {},
        '-' => if (i == 0) return false,
        else => return false,
    };
    return true;
}

/// Checks what ZON parsing cannot: the name matches the file stem, the
/// schedules parse, and unattended triggers have a per-run cost cap. Null
/// when valid; the message is static.
pub fn validate(a: *const Automation, stem: []const u8) ?[]const u8 {
    if (a.version != format_version) return "unsupported version";
    if (!validName(a.name)) return "name must match [a-z0-9][a-z0-9-]{0,63}";
    if (!std.mem.eql(u8, a.name, stem)) return "name must match the file name";
    if (a.triggers.len == 0) return "at least one trigger is required";
    for (a.triggers) |t| switch (t) {
        .schedule => |s| _ = cron.CronExpr.parse(s.cron) catch return "invalid cron expression",
        .once => |o| _ = parseLocal(o.at) orelse return "once.at must be YYYY-MM-DD HH:MM",
        .files => |f| if (f.globs.len == 0) return "files trigger needs at least one glob",
        .scm => |s| if (s.events.len == 0) return "scm trigger needs at least one event",
        .task => |k| if (k.events.len == 0) return "task trigger needs at least one event",
    };
    switch (a.action) {
        .agent => |g| if (std.mem.trim(u8, g.prompt, " \t\r\n").len == 0) return "agent prompt is empty",
        .workflow => |w| if (w.workflow.len == 0) return "workflow name is empty",
    }
    if (a.profile.len == 0) return "profile is empty";
    // No unbounded unattended spend.
    if (a.hasUnattended() and a.budgets.max_cost_micro_usd == null) return "budgets.max_cost_micro_usd is required for unattended triggers";
    return null;
}

/// `YYYY-MM-DD HH:MM` or `YYYY-MM-DDTHH:MM`, optionally with `:SS`.
pub fn parseLocal(s: []const u8) ?zone.LocalDateTime {
    if (s.len != 16 and s.len != 19) return null;
    if (s[4] != '-' or s[7] != '-' or (s[10] != ' ' and s[10] != 'T') or s[13] != ':') return null;
    if (s.len == 19 and s[16] != ':') return null;
    const y = std.fmt.parseInt(u16, s[0..4], 10) catch return null;
    const mo = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    const h = std.fmt.parseInt(u8, s[11..13], 10) catch return null;
    const mi = std.fmt.parseInt(u8, s[14..16], 10) catch return null;
    const sec = if (s.len == 19) std.fmt.parseInt(u8, s[17..19], 10) catch return null else 0;
    if (y < 1970 or mo < 1 or mo > 12 or d < 1 or h > 23 or mi > 59 or sec > 59) return null;
    if (d > zone.daysInMonth(y, @intCast(mo))) return null;
    return .{ .year = y, .month = @intCast(mo), .day = @intCast(d), .hour = @intCast(h), .minute = @intCast(mi), .second = @intCast(sec) };
}

/// Writes `a` as ZON (default fields left out).
pub fn serialize(a: *const Automation, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try std.zon.stringify.serialize(a.*, .{ .emit_default_optional_fields = false }, w);
    try w.writeByte('\n');
}

/// Serializes `a` into `gpa` memory.
pub fn toZon(gpa: Allocator, a: *const Automation) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    serialize(a, &out.writer) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

/// A deep copy into `arena` (freed with it).
pub fn clone(arena: Allocator, a: Automation) Allocator.Error!Automation {
    return runs.run.deepClone(Automation, arena, a);
}
