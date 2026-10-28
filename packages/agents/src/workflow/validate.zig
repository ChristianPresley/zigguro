//! Static checks for workflow definitions (E13.F08.S01.T01), all before
//! any agent starts: names and unique step ids, exactly one kind per step,
//! paths that read only earlier steps, declared arguments and map items,
//! prompt library references, output schemas that compile and can be
//! satisfied, builtin names, the permission profile `command` steps need,
//! and limits (64 parallel, 1,000 agents, 4,096 map items).

const std = @import("std");
const zg_ai = @import("zg_ai");
const def = @import("def.zig");
const path_mod = @import("path.zig");
const interpolate = @import("interpolate.zig");
const parse = @import("parse.zig");
const PromptLibrary = @import("../library/index.zig");

const Allocator = std.mem.Allocator;
const Diagnostics = parse.Diagnostics;
const Validator = zg_ai.schema.validate.Validator;

pub const SchemaFiles = struct {
    ctx: *anyopaque,
    /// The text of schema file `name` (next to the workflow), or null.
    read: *const fn (ctx: *anyopaque, arena: Allocator, name: []const u8) ?[]const u8,
};

pub const ValidateEnv = struct {
    /// Compiles output schemas (E11's JSON Schema validator in the app);
    /// null only parses them and checks for contradictions.
    validator: ?Validator = null,
    schema_files: ?SchemaFiles = null,
    /// `@id` prompts must exist here; null skips the check.
    library: ?*PromptLibrary = null,
    /// Known builtin names; null skips the check.
    builtins: ?[]const []const u8 = null,
    /// Whether an E16 profile allows `command` steps; null accepts any
    /// named profile.
    commands_allowed: ?*const fn (ctx: ?*anyopaque, profile: []const u8) bool = null,
    commands_ctx: ?*anyopaque = null,
};

/// Adds a diagnostic for every problem in `d`.
pub fn validate(d: *const def.WorkflowDef, env: ValidateEnv, diags: *Diagnostics) Allocator.Error!void {
    var arena: std.heap.ArenaAllocator = .init(diags.arena.child_allocator);
    defer arena.deinit();
    var v: V = .{ .a = arena.allocator(), .d = d, .env = env, .diags = diags };
    try v.run();
}

/// Loads a step's schema text: inline JSON, or a file through `files`.
pub fn schemaText(arena: Allocator, files: ?SchemaFiles, schema: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, schema, " \t\r\n");
    if (t.len > 0 and t[0] == '{') return t;
    const f = files orelse return null;
    return f.read(f.ctx, arena, t);
}

/// "x is required but excluded": a `required` key that is not in
/// `properties` while `additionalProperties` is false, searched through
/// nested object schemas. Returns the key.
pub fn contradiction(schema: std.json.Value) ?[]const u8 {
    if (schema != .object) return null;
    const o = schema.object;
    const props: ?std.json.ObjectMap = if (o.get("properties")) |p| (if (p == .object) p.object else null) else null;
    if (o.get("additionalProperties")) |ap| if (ap == .bool and !ap.bool) {
        if (o.get("required")) |req| if (req == .array) for (req.array.items) |k| {
            if (k != .string) continue;
            if (props == null or props.?.get(k.string) == null) return k.string;
        };
    };
    if (props) |p| {
        var it = p.iterator();
        while (it.next()) |e| if (contradiction(e.value_ptr.*)) |k| return k;
    }
    if (o.get("items")) |items| if (contradiction(items)) |k| return k;
    return null;
}

const Ctx = struct {
    /// Steps whose results this step may read.
    visible: []const []const u8,
    /// Inside a map: its `as` name.
    map_as: ?[]const u8 = null,
    /// Extra `$name` bindings (`$candidates` for vote judges).
    bindings: []const []const u8 = &.{},
};

const all_kinds = "agent, map, parallel, reduce, vote, loop_until, gate, builtin, command";

const V = struct {
    a: Allocator,
    d: *const def.WorkflowDef,
    env: ValidateEnv,
    diags: *Diagnostics,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    all_ids: std.StringHashMapUnmanaged(void) = .empty,
    agents: u64 = 0,

    fn run(v: *V) !void {
        const d = v.d;
        if (d.version != 1) try v.diags.add("", "unsupported version {d} (expected 1)", .{d.version});
        if (!def.validName(d.name)) try v.diags.add("", "name \"{s}\" must match [a-z][a-z0-9-]*", .{d.name});
        try v.limits();
        try v.argDecls();
        if (d.steps.len == 0) try v.diags.add("", "a workflow needs at least one step", .{});
        try v.collectIds(d.steps);
        var visible: std.ArrayList([]const u8) = .empty;
        for (d.steps) |*s| {
            try v.step(s, .{ .visible = visible.items });
            try visible.append(v.a, s.id);
            // Branch results are also readable by their own ids.
            if (s.parallel) |br| for (br) |b| try visible.append(v.a, b.id);
        }
        if (v.agents > d.limits.max_agents) {
            try v.diags.add("", "the workflow can start {d} agents, more than limits.max_agents ({d})", .{ v.agents, d.limits.max_agents });
        }
    }

    fn limits(v: *V) !void {
        const l = v.d.limits;
        if (l.max_parallel == 0 or l.max_parallel > def.max_parallel_cap) try v.diags.add("", "limits.max_parallel must be between 1 and {d}", .{def.max_parallel_cap});
        if (l.max_agents == 0 or l.max_agents > def.max_agents_cap) try v.diags.add("", "limits.max_agents must be between 1 and {d}", .{def.max_agents_cap});
        if (l.max_map_items == 0 or l.max_map_items > def.max_map_items_cap) try v.diags.add("", "limits.max_map_items must be between 1 and {d}", .{def.max_map_items_cap});
    }

    fn argDecls(v: *V) !void {
        for (v.d.args, 0..) |a, i| {
            for (v.d.args[0..i]) |b| if (std.mem.eql(u8, a.name, b.name)) try v.diags.add("", "argument \"{s}\" is declared twice", .{a.name});
            if (a.type == .choice and a.options.len == 0) try v.diags.add("", "argument \"{s}\" is a choice without options", .{a.name});
        }
    }

    fn collectIds(v: *V, steps: []const def.NamedStep) !void {
        for (steps) |*s| {
            try v.all_ids.put(v.a, s.id, {});
            if (s.parallel) |br| try v.collectIds(br);
        }
    }

    fn step(v: *V, s: *const def.NamedStep, ctx: Ctx) Allocator.Error!void {
        if (!def.validStepId(s.id)) try v.diags.add(s.id, "id must match [a-z][a-z0-9_]{{0,31}}", .{});
        const gop = try v.seen.getOrPut(v.a, s.id);
        if (gop.found_existing) try v.diags.add(s.id, "duplicate step id", .{});
        if (s.when) |w| try v.path(s.id, "when", w, ctx);
        if (s.kindCount() != 1) {
            try v.diags.add(s.id, "set exactly one of " ++ all_kinds, .{});
            return;
        }
        switch (s.step().?) {
            .agent, .reduce => |ag| try v.agent(s.id, "", ag, ctx, 1),
            .map => |m| try v.map(s.id, m, ctx),
            .parallel => |br| {
                if (br.len == 0) try v.diags.add(s.id, "parallel needs at least one branch", .{});
                for (br) |*b| {
                    if (b.parallel != null) try v.diags.add(b.id, "parallel branches cannot nest parallel steps", .{});
                    try v.step(b, ctx);
                }
            },
            .vote => |vt| {
                if (vt.n < 2 or vt.n > 9) try v.diags.add(s.id, "vote needs n between 2 and 9", .{});
                try v.agent(s.id, "", vt.agent, ctx, vt.n);
                if (vt.decide == .judge) {
                    if (vt.judge) |j| {
                        var jc = ctx;
                        jc.bindings = &.{"candidates"};
                        try v.agent(s.id, "judge: ", j, jc, 1);
                    } else try v.diags.add(s.id, "decide = .judge needs a judge agent", .{});
                } else if (vt.judge != null) try v.diags.add(s.id, "a judge is only used with decide = .judge", .{});
            },
            .loop_until => |lp| {
                if (lp.max_rounds == 0 or lp.max_rounds > 50) try v.diags.add(s.id, "max_rounds must be between 1 and 50", .{});
                if (lp.stop_when_no_progress == 0) try v.diags.add(s.id, "stop_when_no_progress must be at least 1", .{});
                // The body and the check also see the loop's own last result.
                var lc = ctx;
                lc.visible = try std.mem.concat(v.a, []const u8, &.{ ctx.visible, &.{s.id} });
                lc.bindings = &.{"check"};
                try v.agent(s.id, "", lp.agent, lc, lp.max_rounds);
                const c = lp.check;
                const n = @as(u8, @intFromBool(c.command != null)) + @intFromBool(c.path != null) + @intFromBool(c.judge != null);
                if (n != 1) try v.diags.add(s.id, "check needs exactly one of command, path or judge", .{});
                if (c.command) |argv| try v.commandArgv(s.id, argv);
                if (c.path) |p| try v.path(s.id, "check.path", p, lc);
                if (c.judge) |j| try v.agent(s.id, "check.judge: ", j, lc, lp.max_rounds);
            },
            .gate => |g| {
                if (std.mem.trim(u8, g.title, " ").len == 0) try v.diags.add(s.id, "a gate needs a title", .{});
                if (g.show) |p| try v.path(s.id, "show", p, ctx);
            },
            .builtin => |b| try v.builtin(s.id, b, ctx),
            .command => |c| {
                try v.commandArgv(s.id, c.argv);
                if (c.cwd) |cwd| if (path_mod.isPath(cwd)) try v.path(s.id, "cwd", cwd, ctx);
            },
        }
    }

    fn map(v: *V, id: []const u8, m: def.MapStep, ctx: Ctx) !void {
        try v.path(id, "over", m.over, ctx);
        if (!def.validStepId(m.as)) try v.diags.add(id, "as \"{s}\" must match [a-z][a-z0-9_]*", .{m.as});
        if (m.max_parallel) |mp| if (mp == 0 or mp > def.max_parallel_cap) try v.diags.add(id, "max_parallel must be between 1 and {d}", .{def.max_parallel_cap});
        if (!(m.max_fail_ratio >= 0 and m.max_fail_ratio <= 1)) try v.diags.add(id, "max_fail_ratio must be between 0 and 1", .{});
        const n = @as(u8, @intFromBool(m.agent != null)) + @intFromBool(m.command != null) + @intFromBool(m.builtin != null);
        if (n != 1) {
            try v.diags.add(id, "a map needs exactly one of agent, command or builtin", .{});
            return;
        }
        var mc = ctx;
        mc.map_as = m.as;
        // Map items are not known statically: count one agent per map.
        if (m.agent) |ag| try v.agent(id, "", ag, mc, 1);
        if (m.command) |c| try v.commandArgv(id, c.argv);
        if (m.builtin) |b| try v.builtin(id, b, mc);
    }

    fn builtin(v: *V, id: []const u8, b: def.BuiltinStep, ctx: Ctx) !void {
        if (v.env.builtins) |names| {
            for (names) |n| {
                if (std.mem.eql(u8, n, b.name)) break;
            } else try v.diags.add(id, "unknown builtin \"{s}\"", .{b.name});
        }
        try v.path(id, "input", b.input, ctx);
    }

    fn commandArgv(v: *V, id: []const u8, argv: []const []const u8) !void {
        if (argv.len == 0 or argv[0].len == 0) try v.diags.add(id, "a command needs argv", .{});
        const profile = v.d.profile orelse {
            try v.diags.add(id, "command steps need a permission profile that allows commands (set .profile)", .{});
            return;
        };
        if (v.env.commands_allowed) |f| if (!f(v.env.commands_ctx, profile)) {
            try v.diags.add(id, "profile \"{s}\" does not allow commands", .{profile});
        };
    }

    fn agent(v: *V, id: []const u8, comptime what: []const u8, ag: def.AgentStep, ctx: Ctx, copies: u64) !void {
        v.agents += copies;
        if (ag.prompt.len > 0 and ag.prompt[0] == '@') {
            const ref = ag.prompt[1..];
            if (v.env.library) |lib| if (lib.get(ref) == null) try v.diags.add(id, what ++ "unknown library prompt \"{s}\"", .{ag.prompt});
            for (ag.with) |b| if (path_mod.isPath(b.value)) try v.path(id, what ++ "with." ++ "value", b.value, ctx);
        } else {
            if (std.mem.trim(u8, ag.prompt, " \r\n\t").len == 0) try v.diags.add(id, what ++ "prompt is empty", .{});
            if (ag.with.len > 0) try v.diags.add(id, what ++ "with is only used with @library prompts", .{});
            var at: usize = 0;
            if (interpolate.placeholders(v.a, ag.prompt, &at)) |phs| {
                for (phs) |ph| try v.checkRefs(id, what ++ "prompt", ph.path, ctx);
            } else |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.UnclosedPlaceholder => try v.diags.add(id, what ++ "prompt: unclosed {{{{ at offset {d}", .{at}),
                error.InvalidPath => try v.diags.add(id, what ++ "prompt: invalid path at offset {d}", .{at}),
            }
        }
        if (ag.sources) |p| try v.path(id, what ++ "sources", p, ctx);
        if (ag.max_retries > 10) try v.diags.add(id, what ++ "max_retries must be at most 10", .{});
        if (ag.stall_ms < 1000) try v.diags.add(id, what ++ "stall_ms must be at least 1000", .{});
        if (ag.schema) |sch| try v.schema(id, what, sch);
    }

    fn schema(v: *V, id: []const u8, comptime what: []const u8, sch: []const u8) !void {
        const text = schemaText(v.a, v.env.schema_files, sch) orelse {
            try v.diags.add(id, what ++ "cannot read schema file \"{s}\"", .{sch});
            return;
        };
        const value = std.json.parseFromSliceLeaky(std.json.Value, v.a, text, .{}) catch {
            try v.diags.add(id, what ++ "schema is not valid JSON", .{});
            return;
        };
        if (contradiction(value)) |k| {
            try v.diags.add(id, what ++ "schema can never be satisfied: \"{s}\" is required but additionalProperties is false and it is not in properties", .{k});
            return;
        }
        if (v.env.validator) |val| {
            _ = val.compile(val.ctx, v.a, text) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => try v.diags.add(id, what ++ "schema does not compile", .{}),
            };
        }
    }

    fn path(v: *V, id: []const u8, comptime field: []const u8, text: []const u8, ctx: Ctx) !void {
        var at: usize = 0;
        const p = path_mod.Path.compileDiag(v.a, text, &at) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidPath => {
                try v.diags.add(id, field ++ ": invalid path \"{s}\" at offset {d}", .{ text, at });
                return;
            },
        };
        try v.checkRefs(id, field, p, ctx);
    }

    fn checkRefs(v: *V, id: []const u8, comptime field: []const u8, p: path_mod.Path, ctx: Ctx) !void {
        switch (p.root) {
            .all => {},
            .step => |sid| {
                for (ctx.visible) |x| {
                    if (std.mem.eql(u8, x, sid)) break;
                } else if (v.all_ids.contains(sid)) {
                    try v.diags.add(id, field ++ ": {s} reads step \"{s}\", which has not run yet", .{ p.text, sid });
                } else try v.diags.add(id, field ++ ": {s} reads unknown step \"{s}\"", .{ p.text, sid });
            },
            .args => if (p.segs.len > 0 and p.segs[0] == .key) {
                const name = p.segs[0].key;
                for (v.d.args) |a| {
                    if (std.mem.eql(u8, a.name, name)) break;
                } else try v.diags.add(id, field ++ ": {s} reads undeclared argument \"{s}\"", .{ p.text, name });
            },
            .item, .index => if (ctx.map_as == null) try v.diags.add(id, field ++ ": {s} is only valid inside a map", .{p.text}),
            .binding => |b| {
                for (ctx.bindings) |x| if (std.mem.eql(u8, x, b)) return;
                if (ctx.map_as) |as| if (std.mem.eql(u8, as, b)) return;
                try v.diags.add(id, field ++ ": unknown variable ${s}", .{b});
            },
        }
    }
};
