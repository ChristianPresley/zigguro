//! Per-agent toolsets (E10.F06.S01.T01): allow/deny filters, the plan
//! mode filter, deferred tools and the toolset hash.
//!
//! `AgentTools` is an agent's `deps.Tools`. It builds a new `Toolset` only
//! from `list`, which the loop calls while building a request, so a
//! source change or a `tool_search` promotion takes effect before the
//! next request and never in the middle of one. Every toolset stays
//! alive until the `AgentTools` is freed.

const std = @import("std");
const proto = @import("zg_ai_proto");
const request = @import("../provider/request.zig");
const deps = @import("../loop/deps.zig");
const resume_mod = @import("../session/resume.zig");
const registry = @import("registry.zig");
const search_tools = @import("search_tools.zig");
const readonly = @import("../plan/readonly.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const ToolSpec = proto.ToolSpec;
const log = std.log.scoped(.zg_ai_tools);

pub const PermissionMode = resume_mod.PermissionMode;

/// Tools plan mode keeps besides the read-only ones (F09).
pub const plan_mode_tools = readonly.plan_mode_tools;

pub const ToolsetConfig = struct {
    /// Exact names, `*`, or `prefix*` (e.g. `mcp__github__*`).
    allow: []const []const u8 = &.{"*"},
    /// Same patterns; deny wins and removes the tool from requests.
    deny: []const []const u8 = &.{},
    mode: PermissionMode = .default,
    /// Plan mode keeps `run_command` for read-only commands (checked per
    /// call by the invoke pipeline).
    plan_commands: bool = true,
    /// Above this many tools, `defer_loading` tools are left out until
    /// `tool_search` finds them.
    defer_threshold: u16 = 64,
    /// Deferred tools to declare anyway.
    include_deferred: []const []const u8 = &.{},
};

/// The tools of one request.
pub const Toolset = struct {
    arena: std.heap.ArenaAllocator,
    /// The declared tools, in registry order (`tool_search` last).
    specs: []const ToolSpec,
    decls: []const request.ToolDecl,
    /// Allowed but not declared; `tool_search` looks here.
    deferred: []const ToolSpec,
    /// Covers names, descriptions and schemas of `decls`.
    hash: u64,
    generation: u64,

    pub fn find(t: *const Toolset, name: []const u8) ?*const ToolSpec {
        for (t.specs) |*s| if (std.mem.eql(u8, s.name, name)) return s;
        return null;
    }
};

/// True when `pattern` (exact, `*` or `prefix*`) matches `name`.
pub fn patternMatches(pattern: []const u8, name: []const u8) bool {
    if (std.mem.endsWith(u8, pattern, "*")) return std.mem.startsWith(u8, name, pattern[0 .. pattern.len - 1]);
    return std.mem.eql(u8, pattern, name);
}

fn anyMatches(patterns: []const []const u8, name: []const u8) bool {
    for (patterns) |p| if (patternMatches(p, name)) return true;
    return false;
}

/// Whether `cfg` lets the agent see `s` at all.
pub fn allowed(cfg: *const ToolsetConfig, s: *const ToolSpec) bool {
    if (anyMatches(cfg.deny, s.name)) return false;
    if (!anyMatches(cfg.allow, s.name)) return false;
    if (cfg.mode == .plan) return readonly.planKeeps(s, cfg.plan_commands);
    return true;
}

/// Builds the toolset of `gen` for `cfg`. `promoted` names are declared
/// even when deferred; `search` is added when anything is deferred.
pub fn build(gpa: Allocator, gen: *const registry.Generation, cfg: *const ToolsetConfig, promoted: *const std.StringHashMapUnmanaged(void), search: ?ToolSpec) Allocator.Error!*Toolset {
    const t = try gpa.create(Toolset);
    t.* = .{ .arena = .init(gpa), .specs = &.{}, .decls = &.{}, .deferred = &.{}, .hash = 0, .generation = gen.id };
    errdefer {
        t.arena.deinit();
        gpa.destroy(t);
    }
    const a = t.arena.allocator();
    var visible: std.ArrayList(ToolSpec) = .empty;
    for (gen.specs) |*s| if (allowed(cfg, s)) try visible.append(a, s.*);

    var specs: std.ArrayList(ToolSpec) = .empty;
    var deferred: std.ArrayList(ToolSpec) = .empty;
    const deferring = visible.items.len > cfg.defer_threshold;
    for (visible.items) |s| {
        if (deferring and s.defer_loading and !promoted.contains(s.name) and !anyMatches(cfg.include_deferred, s.name))
            try deferred.append(a, s)
        else
            try specs.append(a, s);
    }
    if (deferred.items.len > 0) if (search) |ss| try specs.append(a, ss);

    const decls = try a.alloc(request.ToolDecl, specs.items.len);
    var h: std.hash.Wyhash = .init(0);
    for (specs.items, decls) |s, *d| {
        d.* = .{ .name = s.name, .description = s.description, .input_schema_json = s.input_schema_json };
        for ([_][]const u8{ s.name, s.description, s.input_schema_json }) |part| {
            h.update(part);
            h.update(&.{0});
        }
    }
    t.specs = specs.items;
    t.decls = decls;
    t.deferred = deferred.items;
    t.hash = h.final();
    return t;
}

/// An agent's tools over a shared registry.
pub const AgentTools = struct {
    gpa: Allocator,
    io: Io,
    reg: *registry.ToolRegistry,
    cfg: ToolsetConfig,
    mutex: Io.Mutex = .init,
    promoted: std.StringHashMapUnmanaged(void) = .empty,
    names: std.heap.ArenaAllocator,
    sets: std.ArrayList(*Toolset) = .empty,
    /// Mode or promotions changed since the last build.
    stale: bool = true,
    /// Warn when a rebuild changes the hash (the provider's prompt cache
    /// starts over); tests turn it off and read `invalidations`.
    warn_invalidations: bool = true,
    invalidations: u32 = 0,
    search: ?ToolSpec = null,

    pub fn init(gpa: Allocator, io: Io, reg: *registry.ToolRegistry, cfg: ToolsetConfig) AgentTools {
        return .{ .gpa = gpa, .io = io, .reg = reg, .cfg = cfg, .names = .init(gpa) };
    }

    pub fn deinit(at: *AgentTools) void {
        for (at.sets.items) |t| {
            t.arena.deinit();
            at.gpa.destroy(t);
        }
        at.sets.deinit(at.gpa);
        at.promoted.deinit(at.gpa);
        at.names.deinit();
    }

    /// The agent's `deps.Tools`. Call it on the `AgentTools` in its final
    /// place: `tool_search` keeps the pointer.
    pub fn tools(at: *AgentTools) deps.Tools {
        if (at.search == null) at.search = search_tools.spec(at);
        return .{ .ctx = at, .vtable = &.{ .list = listFn, .find = findFn } };
    }

    /// Switches the permission mode (plan mode narrows the toolset).
    pub fn setMode(at: *AgentTools, mode: PermissionMode) void {
        at.mutex.lockUncancelable(at.io);
        defer at.mutex.unlock(at.io);
        if (at.cfg.mode != mode) at.stale = true;
        at.cfg.mode = mode;
    }

    /// Declares deferred tools from the next request on.
    pub fn promote(at: *AgentTools, names: []const []const u8) Allocator.Error!void {
        at.mutex.lockUncancelable(at.io);
        defer at.mutex.unlock(at.io);
        for (names) |n| {
            if (at.promoted.contains(n)) continue;
            try at.promoted.put(at.gpa, try at.names.allocator().dupe(u8, n), {});
            at.stale = true;
        }
    }

    /// The toolset for the next request; rebuilt if the registry, the
    /// mode or the promotions changed.
    pub fn refresh(at: *AgentTools) Allocator.Error!*const Toolset {
        const gen = try at.reg.snapshot();
        at.mutex.lockUncancelable(at.io);
        defer at.mutex.unlock(at.io);
        if (at.sets.items.len > 0) {
            const cur = at.sets.items[at.sets.items.len - 1];
            if (!at.stale and cur.generation == gen.id) return cur;
        }
        const t = try build(at.gpa, gen, &at.cfg, &at.promoted, at.search);
        errdefer {
            t.arena.deinit();
            at.gpa.destroy(t);
        }
        if (at.sets.items.len > 0 and at.sets.items[at.sets.items.len - 1].hash != t.hash) {
            at.invalidations += 1;
            if (at.warn_invalidations) log.warn("cache prefix invalidated by tool change", .{});
        }
        try at.sets.append(at.gpa, t);
        at.stale = false;
        return t;
    }

    /// The toolset of the current request (null before the first).
    pub fn current(at: *AgentTools) ?*const Toolset {
        at.mutex.lockUncancelable(at.io);
        defer at.mutex.unlock(at.io);
        return if (at.sets.items.len == 0) null else at.sets.items[at.sets.items.len - 1];
    }

    fn listFn(ctx: *anyopaque) []const ToolSpec {
        const at: *AgentTools = @ptrCast(@alignCast(ctx));
        const t = at.refresh() catch return if (at.current()) |c| c.specs else &.{};
        return t.specs;
    }

    fn findFn(ctx: *anyopaque, name: []const u8) ?*const ToolSpec {
        const at: *AgentTools = @ptrCast(@alignCast(ctx));
        const t = at.current() orelse at.refresh() catch return null;
        return t.find(name);
    }
};
