//! The command registry: every user-reachable action (keybindings, palette,
//! menus, agents, extensions, macros, the `zg` CLI) is a command with a
//! stable string id, typed args and when-clause enablement.
//! See `packages/config/docs/commands.md`.
//!
//! `CommandId` values are the values of E04 `ActionId`, so E04 converts with
//! `@enumFromInt(@intFromEnum(x))`. Id 0 is `none` (an unbound key: E04 hands
//! the key back to the focused widget).
//!
//! Threading: `execute` runs on the UI thread. `post` may run on any thread;
//! it queues the invocation and posts `ui_msg_kind` so the UI loop calls
//! `drainPosted`, which executes and then calls the completion on the UI
//! thread. Registration may happen from any thread until `freeze`; after
//! that only on the UI thread.

const std = @import("std");
const zg_core = @import("zg_core");
const schema = @import("../schema.zig");
const value_mod = @import("../value.zig");
const zon_load = @import("../zon_load.zig");
const jsonc = @import("../jsonc.zig");
const diag = @import("../diag.zig");
const context = @import("../when/context.zig");
const when_mod = @import("../when/when.zig");

const Allocator = std.mem.Allocator;
const Value = value_mod.Value;
const EvalEnv = context.EvalEnv;
const ContextKeyService = context.ContextKeyService;
const When = when_mod.When;

/// `UiMsg.kind` posted when invocations are queued by `post`.
pub const ui_msg_kind: u32 = 0x1500_0002;

/// Dense command id; `none` is 0. Equal to E04 `ActionId` values.
pub const CommandId = enum(u32) {
    none = 0,
    _,

    fn index(id: CommandId) usize {
        return @intFromEnum(id) - 1;
    }
};

/// What a command may do, for agent permission prompts and the palette.
pub const Effects = packed struct(u8) {
    reads_workspace: bool = false,
    writes_files: bool = false,
    runs_process: bool = false,
    network: bool = false,
    destructive: bool = false,
    ui_only: bool = true,
    _pad: u2 = 0,
};

/// Who registered a command.
pub const Source = union(enum) {
    /// The package name.
    builtin: []const u8,
    /// The extension id.
    extension: []const u8,
    skill: []const u8,
    user_macro,
    agent_defined,

    fn eql(a: Source, b: Source) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .builtin => |x| std.mem.eql(u8, x, b.builtin),
            .extension => |x| std.mem.eql(u8, x, b.extension),
            .skill => |x| std.mem.eql(u8, x, b.skill),
            .user_macro, .agent_defined => true,
        };
    }
};

/// Where an invocation came from.
pub const Origin = union(enum) {
    keybinding,
    palette,
    menu,
    toolbar,
    agent: struct { session: u64, tool_call: u64 },
    extension: []const u8,
    cli,
    macro,
    api,
};

/// Optional structured result for agents and the CLI.
pub const Result = struct {
    arena: Allocator,
    json: ?[]const u8 = null,
    text: ?[]const u8 = null,

    /// Sets a JSON result (copied).
    pub fn setJson(r: *Result, json: []const u8) void {
        r.json = r.arena.dupe(u8, json) catch null;
    }

    /// Sets a plain-text result (copied).
    pub fn setText(r: *Result, t: []const u8) void {
        r.text = r.arena.dupe(u8, t) catch null;
    }
};

/// One execution of a command.
pub const Invocation = struct {
    id: CommandId,
    args: ?*const Value,
    origin: Origin,
    env: *const EvalEnv,
    result: *Result,
    /// Freed when the invocation returns.
    arena: Allocator,
    registry: *CommandRegistry,
};

/// A command implementation.
pub const Handler = struct {
    ctx: ?*anyopaque,
    run: *const fn (ctx: ?*anyopaque, inv: *Invocation) anyerror!void,
};

/// Activates the extension that implements a lazy command. The host calls
/// `setHandler` when the extension has registered, or `failActivation`.
pub const Activator = struct {
    ctx: ?*anyopaque,
    activate: *const fn (ctx: ?*anyopaque, id: CommandId) void,
};

/// A command declaration.
pub const Command = struct {
    id: []const u8,
    title: []const u8,
    category: ?[]const u8 = null,
    description: []const u8 = "",
    keywords: []const []const u8 = &.{},
    icon: ?[]const u8 = null,
    /// Args schema (usually an `object` def); null means no args, a def of
    /// type `any` accepts anything.
    args: ?*const schema.SettingDef = null,
    /// When-clause that must hold for `execute`.
    enablement: ?[]const u8 = null,
    palette: enum { visible, hidden } = .visible,
    palette_when: ?[]const u8 = null,
    agent: enum { never, ask, allow } = .ask,
    effects: Effects = .{},
    /// Whether key auto-repeat re-runs the command (false for toggles).
    repeat: bool = true,
    source: Source = .{ .builtin = "" },
    handler: ?Handler = null,
};

/// Errors of `execute`.
pub const ExecuteError = error{ UnknownCommand, Disabled, InvalidArgs, ActivationFailed, Canceled, NotActivated, OutOfMemory } || anyerror;

/// Called after a posted invocation finishes (on the UI thread).
pub const Completion = struct {
    ctx: ?*anyopaque,
    cb: *const fn (ctx: ?*anyopaque, err: ?anyerror, result: ?*const Result) void,
};

/// One history ring entry.
pub const HistoryEntry = struct {
    id: CommandId,
    origin_tag: std.meta.Tag(Origin),
    t_ns: i96,
    dur_ns: u64,
    ok: bool,
};

/// Errors of `register`.
pub const RegisterError = error{ DuplicateId, InvalidId, InvalidWhen, Frozen, OutOfMemory };

const history_len = 1000;
const max_depth = 16;
const max_queued_per_command = 32;
const max_arg_cache = 4096;

const Record = struct {
    cmd: Command,
    enablement: ?When = null,
    palette_when: ?When = null,
    tombstoned: bool = false,
    activator: ?Activator = null,
    queued: std.ArrayList(Queued) = .empty,
    activation_started_ns: ?i96 = null,
};

const Queued = struct { args: ?Value, origin: Origin, done: ?Completion, arena: std.heap.ArenaAllocator };

const Posted = struct { id: CommandId, args: ?Value, origin: Origin, done: ?Completion, arena: std.heap.ArenaAllocator };

/// Options for `CommandRegistry.init`.
pub const InitOptions = struct {
    runtime: ?*zg_core.Runtime = null,
    io: ?std.Io = null,
    /// Lazy-activation timeout (setting `extensions.activationTimeoutMs`).
    activation_timeout_ms: u64 = 10_000,
};

/// The registry.
pub const CommandRegistry = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    keys: *ContextKeyService,
    runtime: ?*zg_core.Runtime,
    io: ?std.Io,
    records: std.ArrayList(Record) = .empty,
    by_id: std.StringHashMapUnmanaged(CommandId) = .empty,
    gen: u64 = 0,
    frozen: bool = false,
    depth: u32 = 0,
    history_ring: [history_len]HistoryEntry = undefined,
    history_len: usize = 0,
    history_head: usize = 0,
    arg_cache: std.AutoHashMapUnmanaged(usize, Value) = .empty,
    arg_text_cache: std.StringHashMapUnmanaged(Value) = .empty,
    posted_mutex: std.Io.Mutex = .init,
    posted: std.ArrayList(Posted) = .empty,
    env_provider: ?EnvProvider = null,
    activation_timeout_ns: u64,
    default_env: EvalEnv,

    /// Supplies the current focus environment (E04 focus chain + globals).
    pub const EnvProvider = struct {
        ctx: ?*anyopaque,
        get: *const fn (ctx: ?*anyopaque) *const EvalEnv,
    };

    /// Creates a registry. `keys` must outlive it.
    pub fn init(gpa: Allocator, keys: *ContextKeyService, opts: InitOptions) !*CommandRegistry {
        const r = try gpa.create(CommandRegistry);
        r.* = .{
            .gpa = gpa,
            .arena = .init(gpa),
            .keys = keys,
            .runtime = opts.runtime,
            .io = opts.io,
            .activation_timeout_ns = opts.activation_timeout_ms * std.time.ns_per_ms,
            .default_env = .{ .global = keys },
        };
        try r.records.ensureTotalCapacity(gpa, 256);
        return r;
    }

    /// Frees everything; queued invocations are dropped.
    pub fn deinit(r: *CommandRegistry) void {
        for (r.records.items) |*rec| {
            if (rec.enablement) |*w| w.deinit();
            if (rec.palette_when) |*w| w.deinit();
            for (rec.queued.items) |*q| q.arena.deinit();
            rec.queued.deinit(r.gpa);
        }
        for (r.posted.items) |*p| p.arena.deinit();
        r.posted.deinit(r.gpa);
        r.records.deinit(r.gpa);
        r.by_id.deinit(r.gpa);
        r.arg_cache.deinit(r.gpa);
        r.arg_text_cache.deinit(r.gpa);
        r.arena.deinit();
        r.gpa.destroy(r);
    }

    /// Ends the startup registration phase.
    pub fn freeze(r: *CommandRegistry) void {
        r.frozen = true;
    }

    /// Sets the focus environment provider used by `execute` and `isEnabled`.
    pub fn setEnvProvider(r: *CommandRegistry, p: EnvProvider) void {
        r.env_provider = p;
    }

    fn env(r: *const CommandRegistry) *const EvalEnv {
        if (r.env_provider) |p| return p.get(p.ctx);
        return &r.default_env;
    }

    /// Whether `id` is a valid command id: `[A-Za-z0-9_.:-]+`, ≤ 128 bytes.
    pub fn validId(id: []const u8) bool {
        if (id.len == 0 or id.len > 128) return false;
        for (id) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == ':' or c == '-')) return false;
        return true;
    }

    /// Registers a command. Strings are copied. A command without a handler
    /// stays registered but fails with `error.NotActivated` until
    /// `setHandler`.
    pub fn register(r: *CommandRegistry, c: Command) RegisterError!CommandId {
        return r.registerInner(c, null);
    }

    /// Registers a command whose handler arrives when `activate` completes.
    pub fn registerLazy(r: *CommandRegistry, c: Command, activate: Activator) RegisterError!CommandId {
        return r.registerInner(c, activate);
    }

    fn registerInner(r: *CommandRegistry, c: Command, activator: ?Activator) RegisterError!CommandId {
        if (r.frozen) if (r.runtime) |rt| if (rt.ui_thread != null and !rt.isUiThread()) return error.Frozen;
        if (!validId(c.id)) return error.InvalidId;
        if (r.by_id.contains(c.id)) return error.DuplicateId;
        const a = r.arena.allocator();
        var rec: Record = .{ .cmd = try copyCommand(a, c), .activator = activator };
        errdefer {
            if (rec.enablement) |*w| w.deinit();
            if (rec.palette_when) |*w| w.deinit();
        }
        var d = diag.Diags.init(r.gpa);
        defer d.deinit();
        if (c.enablement) |src| rec.enablement = When.compile(r.gpa, src, r.keys, &d) catch |e| return switch (e) {
            error.InvalidWhen => logWhen(c.id, src, &d),
            else => e,
        };
        if (c.palette_when) |src| rec.palette_when = When.compile(r.gpa, src, r.keys, &d) catch |e| return switch (e) {
            error.InvalidWhen => logWhen(c.id, src, &d),
            else => e,
        };
        try r.records.append(r.gpa, rec);
        const id: CommandId = @enumFromInt(r.records.items.len);
        try r.by_id.put(r.gpa, rec.cmd.id, id);
        r.gen += 1;
        return id;
    }

    fn logWhen(id: []const u8, src: []const u8, d: *const diag.Diags) error{InvalidWhen} {
        if (!@import("builtin").is_test) for (d.items()) |x|
            std.log.scoped(.config).err("command '{s}': when '{s}': {s}", .{ id, src, x.message });
        return error.InvalidWhen;
    }

    fn copyCommand(a: Allocator, c: Command) !Command {
        var out = c;
        out.id = try a.dupe(u8, c.id);
        out.title = try a.dupe(u8, c.title);
        out.description = try a.dupe(u8, c.description);
        if (c.category) |x| out.category = try a.dupe(u8, x);
        if (c.icon) |x| out.icon = try a.dupe(u8, x);
        const kws = try a.alloc([]const u8, c.keywords.len);
        for (c.keywords, kws) |k, *o| o.* = try a.dupe(u8, k);
        out.keywords = kws;
        out.enablement = if (c.enablement) |x| try a.dupe(u8, x) else null;
        out.palette_when = if (c.palette_when) |x| try a.dupe(u8, x) else null;
        out.source = switch (c.source) {
            .builtin => |x| .{ .builtin = try a.dupe(u8, x) },
            .extension => |x| .{ .extension = try a.dupe(u8, x) },
            .skill => |x| .{ .skill = try a.dupe(u8, x) },
            else => c.source,
        };
        return out;
    }

    /// Sets (or replaces) the handler of `id` and replays invocations queued
    /// while its extension was activating.
    pub fn setHandler(r: *CommandRegistry, id: CommandId, h: Handler) void {
        const rec = &r.records.items[id.index()];
        rec.cmd.handler = h;
        rec.activation_started_ns = null;
        var queued = rec.queued;
        rec.queued = .empty;
        defer queued.deinit(r.gpa);
        for (queued.items) |*q| {
            defer q.arena.deinit();
            const res = r.runWith(id, if (q.args) |*v| v else null, q.origin, q.arena.allocator());
            complete(q.done, res);
        }
    }

    /// Fails every invocation queued for `id` with `error.ActivationFailed`.
    pub fn failActivation(r: *CommandRegistry, id: CommandId) void {
        const rec = &r.records.items[id.index()];
        rec.activation_started_ns = null;
        for (rec.queued.items) |*q| {
            if (q.done) |d| d.cb(d.ctx, error.ActivationFailed, null);
            q.arena.deinit();
        }
        rec.queued.clearRetainingCapacity();
    }

    /// Fails queued invocations whose activation exceeded the timeout.
    /// The app calls this from its frame loop when the deadline passes.
    pub fn tick(r: *CommandRegistry, now_ns: i96) void {
        for (r.records.items, 0..) |*rec, i| {
            const started = rec.activation_started_ns orelse continue;
            if (now_ns - started >= r.activation_timeout_ns) r.failActivation(@enumFromInt(i + 1));
        }
    }

    /// Removes every command of `s`. Ids are tombstoned, never reused.
    pub fn unregisterSource(r: *CommandRegistry, s: Source) void {
        for (r.records.items) |*rec| {
            if (rec.tombstoned or !rec.cmd.source.eql(s)) continue;
            rec.tombstoned = true;
            _ = r.by_id.remove(rec.cmd.id);
        }
        r.gen += 1;
    }

    /// The id of command string `id`.
    pub fn lookup(r: *const CommandRegistry, id: []const u8) ?CommandId {
        return r.by_id.get(id);
    }

    /// The declaration of `id`.
    pub fn get(r: *const CommandRegistry, id: CommandId) *const Command {
        return &r.records.items[id.index()].cmd;
    }

    /// Whether `id` is registered and not tombstoned.
    pub fn exists(r: *const CommandRegistry, id: CommandId) bool {
        return id != .none and id.index() < r.records.items.len and !r.records.items[id.index()].tombstoned;
    }

    /// Whether the enablement clause of `id` holds in `e`.
    pub fn isEnabled(r: *const CommandRegistry, id: CommandId, e: *const EvalEnv) bool {
        if (!r.exists(id)) return false;
        const rec = &r.records.items[id.index()];
        return if (rec.enablement) |*w| w.eval(e) else true;
    }

    /// Whether the command shows in the palette in `e`.
    pub fn inPalette(r: *const CommandRegistry, id: CommandId, e: *const EvalEnv) bool {
        if (!r.exists(id)) return false;
        const rec = &r.records.items[id.index()];
        if (rec.cmd.palette == .hidden) return false;
        return if (rec.palette_when) |*w| w.eval(e) else true;
    }

    /// Bumps on any (un)registration.
    pub fn generation(r: *const CommandRegistry) u64 {
        return r.gen;
    }

    /// Iterates live commands (for the palette and agent catalogue).
    pub fn iterate(r: *const CommandRegistry) Iterator {
        return .{ .r = r };
    }

    /// Iterator over live commands.
    pub const Iterator = struct {
        r: *const CommandRegistry,
        i: usize = 0,

        /// The next live command.
        pub fn next(it: *Iterator) ?struct { id: CommandId, cmd: *const Command } {
            while (it.i < it.r.records.items.len) {
                const i = it.i;
                it.i += 1;
                if (!it.r.records.items[i].tombstoned) return .{ .id = @enumFromInt(i + 1), .cmd = &it.r.records.items[i].cmd };
            }
            return null;
        }
    };

    /// History, newest first.
    pub fn history(r: *const CommandRegistry, out: []HistoryEntry) []HistoryEntry {
        const n = @min(out.len, r.history_len);
        for (0..n) |i| out[i] = r.history_ring[(r.history_head + history_len - 1 - i) % history_len];
        return out[0..n];
    }

    /// Executes `id` on the UI thread: checks registration, enablement and
    /// args, records history and runs the handler with a per-call arena.
    pub fn execute(r: *CommandRegistry, id: CommandId, args: ?Value, origin: Origin) ExecuteError!void {
        var arena: std.heap.ArenaAllocator = .init(r.gpa);
        defer arena.deinit();
        _ = try r.runWith(id, if (args) |*v| v else null, origin, arena.allocator());
    }

    /// Like `execute`, but returns the handler's result (copied into `arena`).
    pub fn executeForResult(r: *CommandRegistry, arena: Allocator, id: CommandId, args: ?Value, origin: Origin) ExecuteError!Result {
        return r.runWith(id, if (args) |*v| v else null, origin, arena);
    }

    /// Executes with JSON args (agents, ZEP, MCP, CLI).
    pub fn executeJson(r: *CommandRegistry, arena: Allocator, id: CommandId, json: ?[]const u8, origin: Origin) ExecuteError!Result {
        const args: ?Value = if (json) |j| blk: {
            var d = diag.Diags.init(r.gpa);
            defer d.deinit();
            var doc = jsonc.loadJsonc(r.gpa, j, &d) catch return error.InvalidArgs;
            defer doc.deinit();
            break :blk try (try zon_load.toValue(arena, doc.root)).clone(arena);
        } else null;
        return r.runWith(id, if (args) |*v| v else null, origin, arena);
    }

    fn runWith(r: *CommandRegistry, id: CommandId, args: ?*const Value, origin: Origin, arena: Allocator) ExecuteError!Result {
        if (r.runtime) |rt| if (rt.ui_thread != null) std.debug.assert(rt.isUiThread());
        if (!r.exists(id)) return error.UnknownCommand;
        const rec = &r.records.items[id.index()];
        const e = r.env();
        if (rec.enablement) |*w| if (!w.eval(e)) return error.Disabled;
        try checkArgs(rec.cmd.args, args);
        const h = rec.cmd.handler orelse {
            const act = rec.activator orelse return error.NotActivated;
            if (rec.queued.items.len >= max_queued_per_command) return error.Canceled;
            var q: Queued = .{ .args = null, .origin = origin, .done = null, .arena = .init(r.gpa) };
            if (args) |v| q.args = try v.clone(q.arena.allocator());
            try rec.queued.append(r.gpa, q);
            if (rec.activation_started_ns == null) {
                rec.activation_started_ns = r.now();
                act.activate(act.ctx, id);
            }
            return .{ .arena = arena };
        };
        if (r.depth >= max_depth) {
            if (!@import("builtin").is_test) std.log.scoped(.config).err("command '{s}': recursion deeper than {d}", .{ rec.cmd.id, max_depth });
            return error.Canceled;
        }
        r.depth += 1;
        defer r.depth -= 1;
        var result: Result = .{ .arena = arena };
        var inv: Invocation = .{ .id = id, .args = args, .origin = origin, .env = e, .result = &result, .arena = arena, .registry = r };
        const t0 = r.now();
        const res = h.run(h.ctx, &inv);
        r.pushHistory(.{ .id = id, .origin_tag = std.meta.activeTag(origin), .t_ns = t0, .dur_ns = @intCast(@max(0, r.now() - t0)), .ok = if (res) |_| true else |_| false });
        try res;
        return result;
    }

    fn now(r: *const CommandRegistry) i96 {
        const io = r.io orelse return 0;
        return std.Io.Timestamp.now(io, .awake).nanoseconds;
    }

    fn pushHistory(r: *CommandRegistry, e: HistoryEntry) void {
        r.history_ring[r.history_head] = e;
        r.history_head = (r.history_head + 1) % history_len;
        r.history_len = @min(r.history_len + 1, history_len);
    }

    /// Queues `id` from any thread; the UI loop runs it in `drainPosted`.
    pub fn post(r: *CommandRegistry, id: CommandId, args: ?Value, origin: Origin, done: ?Completion) void {
        var p: Posted = .{ .id = id, .args = null, .origin = origin, .done = done, .arena = .init(r.gpa) };
        if (args) |v| p.args = v.clone(p.arena.allocator()) catch {
            p.arena.deinit();
            if (done) |d| d.cb(d.ctx, error.OutOfMemory, null);
            return;
        };
        const io = r.io orelse @panic("CommandRegistry.post needs InitOptions.io");
        r.posted_mutex.lockUncancelable(io);
        r.posted.append(r.gpa, p) catch {
            r.posted_mutex.unlock(io);
            p.arena.deinit();
            if (done) |d| d.cb(d.ctx, error.OutOfMemory, null);
            return;
        };
        r.posted_mutex.unlock(io);
        if (r.runtime) |rt| rt.post(.{ .kind = ui_msg_kind }) catch {};
    }

    /// UI thread: runs every posted invocation and calls its completion.
    pub fn drainPosted(r: *CommandRegistry) void {
        const io = r.io orelse return;
        r.posted_mutex.lockUncancelable(io);
        var batch = r.posted;
        r.posted = .empty;
        r.posted_mutex.unlock(io);
        defer batch.deinit(r.gpa);
        for (batch.items) |*p| {
            defer p.arena.deinit();
            const res = r.runWith(p.id, if (p.args) |*v| v else null, p.origin, p.arena.allocator());
            complete(p.done, res);
        }
    }

    /// Pre-registers parsed args for canonical arg text (keymap build), so
    /// `executeArgText` does no parsing on the key path.
    pub fn internArgs(r: *CommandRegistry, text: []const u8, v: Value) !void {
        try r.arg_cache.put(r.gpa, @intFromPtr(text.ptr), v);
    }

    /// Drops an `internArgs` entry (the keymap that owned `text` is being freed).
    pub fn releaseArgs(r: *CommandRegistry, text: []const u8) void {
        _ = r.arg_cache.remove(@intFromPtr(text.ptr));
    }

    /// Executes with args given as canonical ZON text (E04 `Resolution.action.arg`).
    /// Interned text pointers hit an O(1) map; other text is parsed and cached.
    pub fn executeArgText(r: *CommandRegistry, id: CommandId, arg_text: ?[]const u8, origin: Origin) ExecuteError!void {
        const text = arg_text orelse return r.execute(id, null, origin);
        if (r.arg_cache.get(@intFromPtr(text.ptr))) |v| return r.execute(id, v, origin);
        if (r.arg_text_cache.get(text)) |v| return r.execute(id, v, origin);
        const a = r.arena.allocator();
        var d = diag.Diags.init(r.gpa);
        defer d.deinit();
        const z = try r.gpa.dupeZ(u8, text);
        defer r.gpa.free(z);
        var doc = zon_load.loadZon(r.gpa, z, &d) catch return error.InvalidArgs;
        defer doc.deinit();
        const v = try (try zon_load.toValue(a, doc.root)).clone(a);
        if (r.arg_text_cache.count() < max_arg_cache) try r.arg_text_cache.put(r.gpa, try a.dupe(u8, text), v);
        return r.execute(id, v, origin);
    }
};

fn complete(done: ?Completion, res: ExecuteError!Result) void {
    const d = done orelse return;
    if (res) |x| {
        d.cb(d.ctx, null, &x);
    } else |e| d.cb(d.ctx, e, null);
}

fn checkArgs(def: ?*const schema.SettingDef, args: ?*const Value) ExecuteError!void {
    const d = def orelse {
        if (args != null and args.?.* != .null) return error.InvalidArgs;
        return;
    };
    const v = args orelse return;
    var buf: [128]u8 = undefined;
    if (schema.checkValue(d, v.*, &buf) != null) return error.InvalidArgs;
}

/// Registers the meta commands: `noop`, `workbench.runCommandById`
/// (`{ id, args? }`) and `workbench.runCommands` (`{ commands: [{ id, args? }] }`,
/// sequential, stops at the first error).
pub fn registerBuiltins(r: *CommandRegistry) !void {
    _ = try r.register(.{ .id = "noop", .title = "Do Nothing", .palette = .hidden, .agent = .never, .source = .{ .builtin = "config" }, .handler = .{ .ctx = null, .run = struct {
        fn f(_: ?*anyopaque, _: *Invocation) anyerror!void {}
    }.f } });
    _ = try r.register(.{ .id = "workbench.runCommandById", .title = "Run Command by Id", .palette = .hidden, .args = &run_by_id_args, .source = .{ .builtin = "config" }, .handler = .{ .ctx = null, .run = runById } });
    _ = try r.register(.{ .id = "workbench.runCommands", .title = "Run Commands", .palette = .hidden, .args = &run_commands_args, .source = .{ .builtin = "config" }, .handler = .{ .ctx = null, .run = runCommands } });
}

const run_by_id_args: schema.SettingDef = .{ .key = "args", .type = .object, .properties = &.{
    .{ .key = "id", .type = .string },
    .{ .key = "args", .type = .any },
} };
const run_commands_args: schema.SettingDef = .{ .key = "args", .type = .object, .properties = &.{
    .{ .key = "commands", .type = .array, .items = .object },
} };

fn runOne(inv: *Invocation, spec: Value) anyerror!void {
    const id_s = (spec.get("id") orelse return error.InvalidArgs);
    if (id_s != .string) return error.InvalidArgs;
    const id = inv.registry.lookup(id_s.string) orelse return error.UnknownCommand;
    const res = try inv.registry.runWith(id, if (spec.get("args")) |*a| a else null, .macro, inv.arena);
    if (res.json) |j| inv.result.setJson(j);
    if (res.text) |t| inv.result.setText(t);
}

fn runById(_: ?*anyopaque, inv: *Invocation) anyerror!void {
    try runOne(inv, (inv.args orelse return error.InvalidArgs).*);
}

fn runCommands(_: ?*anyopaque, inv: *Invocation) anyerror!void {
    const list = (inv.args orelse return error.InvalidArgs).get("commands") orelse return error.InvalidArgs;
    for (list.array) |c| try runOne(inv, c);
}
